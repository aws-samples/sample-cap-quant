"""Pure-function tests for the scoring core and the run_cycle state machine with in-memory stand-ins."""

import math

from scorer.config import Config
from scorer.main import Scorer
from scorer.scoring import (ChannelMetrics, circuit_should_open, max_delta, raw_score, to_route_weights,
                            weighted_error_rate, weights_from_scores)

CFG = Config()
M, P, S = "claude-haiku-5-5", "bedrock-anthropic-use2", "bedrock-anthropic-use1"
PRIOR = {P: 0.9, S: 0.1}


def cm(cid, reqs, errors=0.0, ttft=1.0, e2e=3.0):
    return ChannelMetrics(model=M, channel_id=cid, requests=reqs, p90_ttft=ttft, p90_e2e=e2e,
                          errors_by_class={"upstream_error": errors} if errors else {})


def test_equal_quality_keeps_prior():
    w = weights_from_scores({P: 0.95, S: 0.95}, PRIOR, set(), CFG)
    assert abs(w[P] - 0.9) < 1e-6 and abs(w[S] - 0.1) < 1e-6


def test_degraded_primary_loses_share():
    w = weights_from_scores({P: 0.5, S: 0.95}, PRIOR, set(), CFG)
    assert w[P] < 0.9 and w[S] > 0.1
    w2 = weights_from_scores({P: 0.3, S: 0.95}, PRIOR, set(), CFG)
    assert w2[S] > w[S]  # monotone


def test_floor_and_probe():
    w = weights_from_scores({P: 1.0, S: 0.05}, PRIOR, set(), CFG)
    assert abs(w[S] - CFG.w_floor) < 1e-9 and abs(sum(w.values()) - 1.0) < 1e-9
    w = weights_from_scores({P: 1.0, S: 1.0}, PRIOR, {S}, CFG)
    assert abs(w[S] - CFG.w_probe) < 1e-9 and abs(sum(w.values()) - 1.0) < 1e-9


def test_all_open_splits_evenly():
    w = weights_from_scores({P: 0.1, S: 0.1}, PRIOR, {P, S}, CFG)
    assert w == {P: 0.5, S: 0.5}


def test_error_rate_and_breaker():
    m = cm(P, 100, errors=60)
    assert math.isclose(weighted_error_rate(m), 1.8)
    assert circuit_should_open(m, CFG)
    assert not circuit_should_open(cm(P, 100, errors=10), CFG)


def test_raw_score_ttft_dominates_latency():
    fast, slow = cm(P, 50, ttft=1.0, e2e=3.0), cm(S, 50, ttft=4.0, e2e=3.0)
    assert raw_score(fast, 1.0, 3.0, CFG) > raw_score(slow, 1.0, 3.0, CFG)
    # TTFT share 0.6: slow TTFT (0.25 rel) blended with equal E2E -> 0.6*0.25 + 0.4*1 = 0.55 latency score
    assert math.isclose(raw_score(slow, 1.0, 3.0, CFG), CFG.w_lat * 0.55 + CFG.w_err * 1.0)


def test_route_weights_never_round_probe_to_zero():
    assert to_route_weights({P: 0.995, S: 0.005}) == {P: 100, S: 1}
    assert max_delta({P: 0.9, S: 0.1}, {P: 0.88, S: 0.12}) < 0.03


# ---- run_cycle with fakes ----

class FakeRedis:
    def __init__(self): self.d = {}
    def get(self, k): return self.d.get(k)
    def set(self, k, v): self.d[k] = str(v)
    def incr(self, k): self.d[k] = str(int(self.d.get(k, "0")) + 1); return int(self.d[k])


class FakeProm:
    def __init__(self): self.metrics = {}
    def fetch_metrics(self, models): return dict(self.metrics)


class FakeRoute:
    def __init__(self):
        self.w = {P: 90.0, S: 10.0}
        self.writes = []
    def load_channels(self):
        return [{"model": M, "channel_id": P, "rule_index": 0, "ref_index": 0, "weight": self.w[P]},
                {"model": M, "channel_id": S, "rule_index": 0, "ref_index": 1, "weight": self.w[S]}]
    def current_weights(self, channels):
        t = sum(self.w.values()); return {M: {k: v / t for k, v in self.w.items()}}
    def update_weights(self, channels, model, weights):
        self.w.update({k: float(v) for k, v in weights.items()}); self.writes.append(dict(weights))


def make():
    s = Scorer.__new__(Scorer); s.cfg = CFG; s.redis = FakeRedis(); s.prom = FakeProm(); s.route = FakeRoute(); return s


def test_healthy_steady_state_does_not_write():
    s = make()
    s.prom.metrics = {(M, P): cm(P, 100), (M, S): cm(S, 12)}
    for _ in range(3): s.run_cycle()
    assert s.route.writes == []


def test_secondary_without_samples_cannot_gain():
    s = make()
    # primary degraded (10 % real errors -> weighted 0.3, below the breaker) but the secondary is silent
    s.prom.metrics = {(M, P): cm(P, 100, errors=10, ttft=3.0)}
    for _ in range(5): s.run_cycle()
    assert s.route.writes == []  # no evidence about the secondary -> hold


def test_tripped_primary_shifts_even_without_secondary_samples():
    s = make()
    s.prom.metrics = {(M, P): cm(P, 100, errors=60)}  # hard failure, secondary silent
    s.run_cycle()
    assert s.is_circuit_open(M, P)
    assert s.route.writes and s.route.writes[-1][S] > s.route.writes[-1][P]


def test_primary_failure_shifts_then_trips_and_recovers():
    s = make()
    s.prom.metrics = {(M, P): cm(P, 100, errors=70, ttft=None, e2e=None), (M, S): cm(S, 12)}
    for _ in range(3): s.run_cycle()
    assert s.is_circuit_open(M, P)
    last = s.route.writes[-1]
    assert last[P] <= 2 and last[S] >= 98  # probe share only
    # recovery: clean rounds on probe traffic
    s.prom.metrics = {(M, P): cm(P, 3), (M, S): cm(S, 100)}
    for _ in range(CFG.circuit_recovery_rounds): s.run_cycle()
    assert not s.is_circuit_open(M, P)
    # with evidence again the primary climbs back towards the prior
    s.prom.metrics = {(M, P): cm(P, 50), (M, S): cm(S, 50)}
    for _ in range(12): s.run_cycle()
    assert s.route.w[P] > s.route.w[S]
