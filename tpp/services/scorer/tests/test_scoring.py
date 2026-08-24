import math

from scorer.config import Config
from scorer.scoring import (
    ChannelMetrics,
    circuit_should_open,
    ewma,
    max_delta,
    raw_score,
    to_litellm_weights,
    weighted_error_rate,
    weights_from_scores,
)

CFG = Config(litellm_master_key="test")


def _m(cid="a", group="g", p90=1.0, reqs=100.0, errors=None):
    return ChannelMetrics(
        model_group=group,
        channel_id=cid,
        p90_latency=p90,
        requests=reqs,
        errors_by_class=errors or {},
    )


def test_weighted_error_rate_severity():
    m = _m(reqs=100, errors={"Timeout": 2, "RateLimitError": 2, "BadRequestError": 2})
    # 3.0*2 + 1.5*2 + 0.5*2 = 10 -> 0.10
    assert abs(weighted_error_rate(m) - 0.10) < 1e-9


def test_raw_score_perfect_channel():
    m = _m(p90=1.0)
    assert abs(raw_score(m, best_latency=1.0, cfg=CFG) - 1.0) < 1e-9


def test_raw_score_slow_channel_penalized():
    fast = raw_score(_m(p90=1.0), 1.0, CFG)
    slow = raw_score(_m(p90=4.0), 1.0, CFG)
    assert slow < fast
    # 只有延迟差时,错误分保持满分
    assert slow >= CFG.w_err - 1e-9


def test_raw_score_errors_dominate():
    bad = raw_score(_m(errors={"Timeout": 20}), 1.0, CFG)  # ê=0.6
    assert bad < 0.4


def test_ewma_smoothing():
    assert ewma(None, 0.8, 0.3) == 0.8
    assert abs(ewma(1.0, 0.0, 0.3) - 0.7) < 1e-9


def test_weights_floor_prevents_starvation():
    w = weights_from_scores({"a": 1.0, "b": 0.01}, set(), CFG)
    assert w["b"] >= CFG.w_floor * 0.9  # 归一化后允许轻微缩水
    assert abs(sum(w.values()) - 1.0) < 1e-9


def test_weights_circuit_open_gets_zero():
    w = weights_from_scores({"a": 1.0, "b": 0.9}, {"b"}, CFG)
    assert w["b"] == 0.0
    assert abs(w["a"] - 1.0) < 1e-9


def test_weights_all_circuit_open_falls_back_to_even():
    w = weights_from_scores({"a": 0.5, "b": 0.5}, {"a", "b"}, CFG)
    assert abs(w["a"] - 0.5) < 1e-9


def test_circuit_opens_on_severe_errors():
    m = _m(reqs=10, errors={"Timeout": 3})  # ê=0.9, severe 占比 100%
    assert circuit_should_open(m, CFG)
    ok = _m(reqs=100, errors={"BadRequestError": 3})
    assert not circuit_should_open(ok, CFG)


def test_gamma_amplifies_gap():
    w = weights_from_scores({"a": 0.9, "b": 0.6}, set(), CFG)
    assert w["a"] / w["b"] > 0.9 / 0.6  # γ=2 放大比例


def test_max_delta():
    assert abs(max_delta({"a": 0.5, "b": 0.5}, {"a": 0.6, "b": 0.4}) - 0.1) < 1e-9


def test_to_litellm_weights():
    assert to_litellm_weights({"a": 0.85, "b": 0.15}) == {"a": 85, "b": 15}
