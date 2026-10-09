"""Circuit-breaker state machine through Scorer.run_cycle with in-memory stand-ins for Redis, Prometheus, and LiteLLM.

Covers the recovery path specifically: a tripped channel only receives probe traffic, which stays below
MIN_SAMPLES, so recovery must be evaluated in the small-sample branch (ADR-006 §6.3).
"""

from scorer.config import Config
from scorer.main import Scorer
from scorer.scoring import ChannelMetrics

CFG = Config(litellm_master_key="test")
GROUP = "g"
GOOD, BAD = "good", "bad"


class FakeRedis:
    def __init__(self):
        self.d: dict[str, str] = {}

    def get(self, k):
        return self.d.get(k)

    def set(self, k, v):
        self.d[k] = str(v)

    def incr(self, k):
        self.d[k] = str(int(self.d.get(k, "0")) + 1)
        return int(self.d[k])


class FakeProm:
    def __init__(self):
        self.metrics: dict[str, ChannelMetrics] = {}

    def fetch_metrics(self, groups):
        return dict(self.metrics)


class FakeLiteLLM:
    def __init__(self):
        self.weights: dict[str, int] = {GOOD: 50, BAD: 50}
        self.writes: list[dict[str, int]] = []

    def current_weights(self, channels):
        return {cid: float(w) for cid, w in self.weights.items()}

    def update_weight(self, cid, w):
        self.weights[cid] = w
        if not self.writes or cid in self.writes[-1]:
            self.writes.append({})
        self.writes[-1][cid] = w


def make_scorer() -> Scorer:
    s = Scorer.__new__(Scorer)
    s.cfg = CFG
    s.redis = FakeRedis()
    s.prom = FakeProm()
    s.litellm = FakeLiteLLM()
    s.channels = [
        {"model_name": GROUP, "model_info": {"id": GOOD}},
        {"model_name": GROUP, "model_info": {"id": BAD}},
    ]
    s.groups = [GROUP]
    s.ids_by_group = {GROUP: [GOOD, BAD]}
    return s


def metrics(cid, reqs, errors=None, p90=1.0):
    return ChannelMetrics(model_group=GROUP, channel_id=cid, p90_latency=p90, requests=reqs, errors_by_class=errors or {})


def trip(s: Scorer) -> None:
    s.prom.metrics = {GOOD: metrics(GOOD, 100), BAD: metrics(BAD, 100, {"Timeout": 60})}
    s.run_cycle()
    assert s.is_circuit_open(BAD)


def test_trip_sets_probe_weight_not_zero():
    s = make_scorer()
    trip(s)
    assert s.litellm.weights[BAD] == round(CFG.w_probe * 100)
    assert s.litellm.weights[GOOD] == 100 - s.litellm.weights[BAD]


def test_breaker_closes_on_probe_samples_below_min_samples():
    s = make_scorer()
    trip(s)
    # The window slides past the outage: only 1% probe traffic reaches the channel, far below MIN_SAMPLES
    s.prom.metrics = {GOOD: metrics(GOOD, 100), BAD: metrics(BAD, 2)}
    for _ in range(CFG.circuit_recovery_rounds - 1):
        s.run_cycle()
        assert s.is_circuit_open(BAD)
    s.run_cycle()
    assert not s.is_circuit_open(BAD)
    # Back in the group with at least the exploration floor, written to LiteLLM
    assert s.litellm.weights[BAD] >= round(CFG.w_floor * 100)
    assert s.redis.get(f"scorer:circuit_good:{BAD}") == "0"


def test_probe_error_resets_recovery_counter():
    s = make_scorer()
    trip(s)
    s.prom.metrics = {GOOD: metrics(GOOD, 100), BAD: metrics(BAD, 2)}
    s.run_cycle()
    s.run_cycle()
    assert s.redis.get(f"scorer:circuit_good:{BAD}") == "2"
    # One probe request times out: weighted error rate 3 * 1 / 2 = 1.5, counter resets, breaker stays open
    s.prom.metrics = {GOOD: metrics(GOOD, 100), BAD: metrics(BAD, 2, {"Timeout": 1})}
    s.run_cycle()
    assert s.is_circuit_open(BAD)
    assert s.redis.get(f"scorer:circuit_good:{BAD}") == "0"


def test_no_probe_samples_leaves_breaker_and_counter_untouched():
    s = make_scorer()
    trip(s)
    s.prom.metrics = {GOOD: metrics(GOOD, 100), BAD: metrics(BAD, 2)}
    s.run_cycle()
    # A round with no samples for the tripped channel must not count as good or bad
    s.prom.metrics = {GOOD: metrics(GOOD, 100)}
    s.run_cycle()
    assert s.is_circuit_open(BAD)
    assert s.redis.get(f"scorer:circuit_good:{BAD}") == "1"


def test_small_samples_never_trip_the_breaker():
    s = make_scorer()
    # 3 timeouts in 5 requests is a 180% weighted error rate, but below MIN_SAMPLES it is noise
    s.prom.metrics = {GOOD: metrics(GOOD, 100), BAD: metrics(BAD, 5, {"Timeout": 3})}
    s.run_cycle()
    assert not s.is_circuit_open(BAD)
