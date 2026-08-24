"""打分核心:纯函数,不做任何 IO,便于单测。算法见 docs/architecture.md §3。"""

import math
from dataclasses import dataclass, field

from .config import Config, SEVERITY, SEVERITY_DEFAULT, SEVERE_CLASSES


@dataclass
class ChannelMetrics:
    """一个渠道(deployment)在窗口内的观测值。"""

    model_group: str
    channel_id: str
    p90_latency: float | None  # 秒;窗口内无成功请求时为 None
    requests: float
    errors_by_class: dict[str, float] = field(default_factory=dict)


def weighted_error_rate(m: ChannelMetrics) -> float:
    weighted = sum(
        SEVERITY.get(cls, SEVERITY_DEFAULT) * cnt for cls, cnt in m.errors_by_class.items()
    )
    return weighted / max(m.requests, 1.0)


def severe_dominant(m: ChannelMetrics) -> bool:
    total = sum(m.errors_by_class.values())
    if total <= 0:
        return False
    severe = sum(cnt for cls, cnt in m.errors_by_class.items() if cls in SEVERE_CLASSES)
    return severe / total >= 0.5


def raw_score(m: ChannelMetrics, best_latency: float | None, cfg: Config) -> float:
    if m.p90_latency is None or best_latency is None or m.p90_latency <= 0:
        s_lat = 0.0 if m.requests > 0 else cfg.default_q
    else:
        s_lat = max(0.0, min(1.0, best_latency / m.p90_latency))
    s_err = math.exp(-cfg.k_err * weighted_error_rate(m))
    return cfg.w_lat * s_lat + cfg.w_err * s_err


def ewma(prev: float | None, raw: float, alpha: float) -> float:
    if prev is None:
        return raw
    return alpha * raw + (1 - alpha) * prev


def circuit_should_open(m: ChannelMetrics, cfg: Config) -> bool:
    return weighted_error_rate(m) > cfg.circuit_err_threshold and severe_dominant(m)


def weights_from_scores(
    scores: dict[str, float], circuit_open: set[str], cfg: Config
) -> dict[str, float]:
    """分数 -> 归一化权重。熔断渠道置 0;非熔断渠道有 w_floor 保底。"""
    active = {cid: q for cid, q in scores.items() if cid not in circuit_open}
    if not active:
        # 全部熔断:均分,避免流量无处可去(LiteLLM 自身 cooldown 仍会兜底)
        return {cid: 1.0 / len(scores) for cid in scores}

    powered = {cid: max(q, 1e-6) ** cfg.gamma for cid, q in active.items()}
    total = sum(powered.values())
    weights = {cid: v / total for cid, v in powered.items()}

    # 保底 + 重归一化
    floored = {cid: max(w, cfg.w_floor) for cid, w in weights.items()}
    total = sum(floored.values())
    weights = {cid: w / total for cid, w in floored.items()}

    for cid in circuit_open:
        if cid in scores:
            weights[cid] = 0.0
    return weights


def max_delta(a: dict[str, float], b: dict[str, float]) -> float:
    keys = set(a) | set(b)
    return max((abs(a.get(k, 0.0) - b.get(k, 0.0)) for k in keys), default=0.0)


def to_litellm_weights(weights: dict[str, float]) -> dict[str, int]:
    """归一化权重 -> LiteLLM 的整数 weight(0-100)。"""
    return {cid: round(w * 100) for cid, w in weights.items()}
