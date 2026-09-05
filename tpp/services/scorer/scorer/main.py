"""Scorer main loop: every interval, query Prometheus -> score -> adjust LiteLLM weights.

Design highlights (docs/architecture.md §3):
- EWMA state lives in Redis, so restarts are lossless;
- small-sample protection, circuit breaking, floor weight, hysteresis;
- if any dependency is unavailable -> skip this round (weights frozen), own metrics exposed for alerting.
"""

import logging
import time
from collections import defaultdict

import redis as redis_lib
from prometheus_client import Counter, Gauge, start_http_server

from .config import Config
from .litellm_client import LiteLLMClient
from .prom import PromClient
from . import scoring

log = logging.getLogger("scorer")

QUALITY = Gauge("scorer_quality_score", "EWMA quality score", ["model_group", "model_id"])
WEIGHT = Gauge("scorer_weight", "assigned weight (0-1)", ["model_group", "model_id"])
CIRCUIT = Gauge("scorer_circuit_open", "circuit breaker state", ["model_group", "model_id"])
LAST_SUCCESS = Gauge("scorer_last_success_timestamp", "unix ts of last successful cycle")
CYCLES = Counter("scorer_cycles_total", "cycles run", ["result"])


class Scorer:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.prom = PromClient(cfg)
        self.litellm = LiteLLMClient(cfg.litellm_url, cfg.litellm_master_key)
        self.redis = redis_lib.Redis(host=cfg.redis_host, port=cfg.redis_port, decode_responses=True)
        self.channels = self.litellm.load_channels_spec(cfg.channels_file)
        self.groups = sorted({ch["model_name"] for ch in self.channels})
        self.ids_by_group: dict[str, list[str]] = defaultdict(list)
        for ch in self.channels:
            self.ids_by_group[ch["model_name"]].append(ch["model_info"]["id"])

    # ---- Redis state ----
    def _score_key(self, cid: str) -> str:
        return f"scorer:score:{cid}"

    def get_score(self, cid: str) -> float | None:
        v = self.redis.get(self._score_key(cid))
        return float(v) if v is not None else None

    def set_score(self, cid: str, q: float) -> None:
        self.redis.set(self._score_key(cid), q)

    def circuit_rounds(self, cid: str, good: bool) -> int:
        key = f"scorer:circuit_good:{cid}"
        if good:
            return self.redis.incr(key)
        self.redis.set(key, 0)
        return 0

    def is_circuit_open(self, cid: str) -> bool:
        return self.redis.get(f"scorer:circuit:{cid}") == "1"

    def set_circuit(self, cid: str, is_open: bool) -> None:
        self.redis.set(f"scorer:circuit:{cid}", "1" if is_open else "0")

    # ---- Single cycle ----
    def run_cycle(self) -> None:
        cfg = self.cfg
        metrics = self.prom.fetch_metrics(self.groups)
        current = self.litellm.current_weights(self.channels)

        for group in self.groups:
            cids = self.ids_by_group[group]
            group_metrics = {cid: metrics[cid] for cid in cids if cid in metrics}

            best_lat = min(
                (m.p90_latency for m in group_metrics.values() if m.p90_latency is not None),
                default=None,
            )

            scores: dict[str, float] = {}
            circuit_open: set[str] = set()

            for cid in cids:
                m = group_metrics.get(cid)
                prev = self.get_score(cid)

                if m is None or m.requests < cfg.min_samples:
                    # Small-sample protection: keep the old score; new channels get the cold-start score
                    q = prev if prev is not None else cfg.default_q
                else:
                    q = scoring.ewma(prev, scoring.raw_score(m, best_lat, cfg), cfg.alpha)

                    # Circuit breaker state machine
                    if scoring.circuit_should_open(m, cfg):
                        self.set_circuit(cid, True)
                        self.circuit_rounds(cid, good=False)
                    elif self.is_circuit_open(cid):
                        err = scoring.weighted_error_rate(m)
                        if err < cfg.circuit_recovery_err:
                            if self.circuit_rounds(cid, good=True) >= cfg.circuit_recovery_rounds:
                                self.set_circuit(cid, False)
                        else:
                            self.circuit_rounds(cid, good=False)

                self.set_score(cid, q)
                scores[cid] = q
                if self.is_circuit_open(cid):
                    circuit_open.add(cid)

                QUALITY.labels(group, cid).set(q)
                CIRCUIT.labels(group, cid).set(1 if cid in circuit_open else 0)

            weights = scoring.weights_from_scores(scores, circuit_open, cfg)
            for cid, w in weights.items():
                WEIGHT.labels(group, cid).set(w)

            group_current = {cid: current.get(cid, 0.0) for cid in cids}
            total = sum(group_current.values()) or 1.0
            group_current = {cid: w / total for cid, w in group_current.items()}

            if scoring.max_delta(weights, group_current) > cfg.hysteresis:
                for cid, w in scoring.to_litellm_weights(weights).items():
                    self.litellm.update_weight(cid, w)
                log.info("group=%s weights updated: %s", group, weights)

    def run_forever(self) -> None:
        self.litellm.ensure_channels(self.channels)
        log.info("managing %d channels in %d groups", len(self.channels), len(self.groups))
        while True:
            started = time.time()
            try:
                self.run_cycle()
                LAST_SUCCESS.set(time.time())
                CYCLES.labels("ok").inc()
            except Exception:
                # Weights stay frozen at last round's values; the Scorer is off the request path, so failures are tolerable
                log.exception("cycle failed, weights frozen")
                CYCLES.labels("error").inc()
            time.sleep(max(1.0, self.cfg.interval_seconds - (time.time() - started)))


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    cfg = Config()
    start_http_server(cfg.metrics_port)
    Scorer(cfg).run_forever()


if __name__ == "__main__":
    main()
