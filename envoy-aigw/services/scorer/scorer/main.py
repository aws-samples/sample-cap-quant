"""Scorer main loop: every interval, query Prometheus -> score each channel -> rewrite AIGatewayRoute weights.

Design (inherited from the TPP scorer):
- not on the request path; any failure skips the round and leaves weights frozen;
- EWMA scores, breaker state and priors live in Redis, so restarts are lossless;
- small-sample protection, circuit breaking with a probe share for recovery, exploration floor, write hysteresis.

Additions for this gateway:
- prior = the weights configured in the route when a model is first seen (90/10): equal quality keeps that split;
- a channel without fresh samples in the window may lose share but never gain it (no evidence, no promotion).
"""

import json
import logging
import time
from collections import defaultdict

import redis as redis_lib
from prometheus_client import Counter, Gauge, start_http_server

from .config import Config
from .prom import PromClient
from .route_client import RouteClient
from . import scoring

log = logging.getLogger("scorer")

QUALITY = Gauge("scorer_quality_score", "EWMA quality score", ["model", "channel"])
WEIGHT = Gauge("scorer_weight", "assigned weight (0-1)", ["model", "channel"])
CIRCUIT = Gauge("scorer_circuit_open", "circuit breaker state", ["model", "channel"])
RAW_TTFT = Gauge("scorer_p90_ttft_seconds", "observed p90 TTFT in window", ["model", "channel"])
RAW_ERR = Gauge("scorer_error_rate", "observed weighted error rate in window", ["model", "channel"])
LAST_SUCCESS = Gauge("scorer_last_success_timestamp", "unix ts of last successful cycle")
CYCLES = Counter("scorer_cycles_total", "cycles run", ["result"])
WRITES = Counter("scorer_weight_writes_total", "route patches", ["model"])


class Scorer:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.prom = PromClient(cfg)
        self.route = RouteClient(cfg.route_namespace, cfg.route_name)
        self.redis = redis_lib.Redis(host=cfg.redis_host, port=cfg.redis_port, password=cfg.redis_password or None,
                                     ssl=cfg.redis_ssl, decode_responses=True)

    # ---- Redis state ----
    @staticmethod
    def _k(kind: str, model: str, cid: str) -> str:
        return f"scorer:{kind}:{model}:{cid}"

    def get_score(self, model: str, cid: str) -> float | None:
        v = self.redis.get(self._k("score", model, cid))
        return float(v) if v is not None else None

    def set_score(self, model: str, cid: str, q: float) -> None:
        self.redis.set(self._k("score", model, cid), q)

    def circuit_rounds(self, model: str, cid: str, good: bool) -> int:
        key = self._k("circuit_good", model, cid)
        if good:
            return self.redis.incr(key)
        self.redis.set(key, 0)
        return 0

    def is_circuit_open(self, model: str, cid: str) -> bool:
        return self.redis.get(self._k("circuit", model, cid)) == "1"

    def set_circuit(self, model: str, cid: str, is_open: bool) -> None:
        self.redis.set(self._k("circuit", model, cid), "1" if is_open else "0")

    def prior(self, model: str, configured: dict[str, float]) -> dict[str, float]:
        """Configured split the first time a model is seen, persisted so later scorer writes never become the prior."""
        key = f"scorer:prior:{model}"
        saved = self.redis.get(key)
        if saved:
            p = json.loads(saved)
            if set(p) == set(configured):
                return p
        self.redis.set(key, json.dumps(configured))
        log.info("model=%s prior set from configured weights: %s", model, configured)
        return configured

    def _evaluate_recovery(self, model: str, cid: str, m: scoring.ChannelMetrics) -> None:
        cfg = self.cfg
        if scoring.weighted_error_rate(m) < cfg.circuit_recovery_err:
            if self.circuit_rounds(model, cid, good=True) >= cfg.circuit_recovery_rounds:
                self.set_circuit(model, cid, False)
                self.circuit_rounds(model, cid, good=False)
                log.info("model=%s channel=%s circuit closed after %d good rounds", model, cid, cfg.circuit_recovery_rounds)
        else:
            self.circuit_rounds(model, cid, good=False)

    # ---- One cycle ----
    def run_cycle(self) -> None:
        cfg = self.cfg
        channels = self.route.load_channels()
        by_model: dict[str, list[dict]] = defaultdict(list)
        for c in channels:
            by_model[c["model"]].append(c)
        metrics = self.prom.fetch_metrics(sorted(by_model))
        current = self.route.current_weights(channels)

        for model, chans in by_model.items():
            cids = [c["channel_id"] for c in chans]
            if len(cids) < 2:
                continue  # nothing to shift
            group = {cid: metrics[(model, cid)] for cid in cids if (model, cid) in metrics}
            best_ttft = min((m.p90_ttft for m in group.values() if m.p90_ttft is not None and m.requests >= cfg.min_samples), default=None)
            best_e2e = min((m.p90_e2e for m in group.values() if m.p90_e2e is not None and m.requests >= cfg.min_samples), default=None)

            scores: dict[str, float] = {}
            circuit_open: set[str] = set()
            fresh: set[str] = set()

            for cid in cids:
                m = group.get(cid)
                prev = self.get_score(model, cid)
                if m is None or m.requests < cfg.min_samples:
                    q = prev if prev is not None else cfg.default_q
                    if m is not None and m.requests > 0 and self.is_circuit_open(model, cid):
                        self._evaluate_recovery(model, cid, m)
                else:
                    fresh.add(cid)
                    q = scoring.ewma(prev, scoring.raw_score(m, best_ttft, best_e2e, cfg), cfg.alpha)
                    if scoring.circuit_should_open(m, cfg):
                        if not self.is_circuit_open(model, cid):
                            log.warning("model=%s channel=%s circuit opened: err_rate=%.2f reqs=%.0f", model, cid,
                                        scoring.weighted_error_rate(m), m.requests)
                        self.set_circuit(model, cid, True)
                        self.circuit_rounds(model, cid, good=False)
                    elif self.is_circuit_open(model, cid):
                        self._evaluate_recovery(model, cid, m)
                    RAW_TTFT.labels(model, cid).set(m.p90_ttft if m.p90_ttft is not None else float("nan"))
                    RAW_ERR.labels(model, cid).set(scoring.weighted_error_rate(m))

                self.set_score(model, cid, q)
                scores[cid] = q
                if self.is_circuit_open(model, cid):
                    circuit_open.add(cid)
                QUALITY.labels(model, cid).set(q)
                CIRCUIT.labels(model, cid).set(1 if cid in circuit_open else 0)

            cur = current.get(model, {})
            prior = self.prior(model, cur)
            weights = scoring.weights_from_scores(scores, prior, circuit_open, cfg)

            # No fresh evidence for a channel -> it may not gain share this round. Exception: a tripped channel is a
            # hard failure, and shifting away from it must not wait for samples on the alternative (Envoy's retries
            # will produce them within a round anyway).
            if fresh and len(fresh) < len(cids) and not circuit_open:
                # unobserved channels are pinned at min(computed, current); observed ones share the remainder
                pinned = {cid: min(w, cur.get(cid, w)) for cid, w in weights.items() if cid not in fresh}
                rest = max(0.0, 1.0 - sum(pinned.values()))
                fresh_total = sum(weights[cid] for cid in fresh) or 1.0
                weights = {**pinned, **{cid: weights[cid] / fresh_total * rest for cid in fresh}}
            elif not fresh:
                weights = dict(cur)  # nothing observed anywhere: hold

            for cid, w in weights.items():
                WEIGHT.labels(model, cid).set(w)

            if scoring.max_delta(weights, cur) > cfg.hysteresis:
                self.route.update_weights(channels, model, scoring.to_route_weights(weights))
                WRITES.labels(model).inc()
                log.info("model=%s scores=%s weights %s -> %s", model,
                         {k: round(v, 3) for k, v in scores.items()},
                         {k: round(v, 2) for k, v in cur.items()}, {k: round(v, 2) for k, v in weights.items()})

    def run_forever(self) -> None:
        chans = self.route.load_channels()
        log.info("managing %d channels across %d models in %s/%s", len(chans), len({c['model'] for c in chans}),
                 self.cfg.route_namespace, self.cfg.route_name)
        while True:
            started = time.time()
            try:
                self.run_cycle()
                LAST_SUCCESS.set(time.time())
                CYCLES.labels("ok").inc()
            except Exception:
                log.exception("cycle failed, weights frozen")
                CYCLES.labels("error").inc()
            time.sleep(max(1.0, self.cfg.interval_seconds - (time.time() - started)))


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)  # one Prometheus query per line otherwise
    cfg = Config()
    start_http_server(cfg.metrics_port)
    Scorer(cfg).run_forever()


if __name__ == "__main__":
    main()
