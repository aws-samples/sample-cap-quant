"""Scoring core: pure functions with no IO, easy to unit test. Algorithm in docs/architecture.md §3."""

import math
from dataclasses import dataclass, field

from .config import Config, SEVERITY, SEVERITY_DEFAULT, SEVERE_CLASSES


@dataclass
class ChannelMetrics:
    """Observations for one channel (deployment) within the window."""

    model_group: str
    channel_id: str
    p90_latency: float | None  # seconds; None when the window has no successful requests
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
    """Scores -> normalized weights.

    Circuit-open channels get the probe weight w_probe (below the exploration floor) so they keep
    producing samples and the recovery rule can be evaluated; the remaining channels share the rest,
    with a w_floor floor applied before renormalization.
    """
    open_ids = {cid for cid in circuit_open if cid in scores}
    active = {cid: q for cid, q in scores.items() if cid not in open_ids}
    if not active:
        # All circuits open: split evenly so traffic still has somewhere to go (LiteLLM's own cooldown remains as fallback)
        return {cid: 1.0 / len(scores) for cid in scores}

    powered = {cid: max(q, 1e-6) ** cfg.gamma for cid, q in active.items()}
    total = sum(powered.values())
    weights = {cid: v / total for cid, v in powered.items()}

    # Apply floor + renormalize
    floored = {cid: max(w, cfg.w_floor) for cid, w in weights.items()}
    total = sum(floored.values())
    weights = {cid: w / total for cid, w in floored.items()}

    # Tripped channels take a fixed probe share; active channels scale down to make room
    probe_total = min(cfg.w_probe * len(open_ids), 0.5)
    weights = {cid: w * (1.0 - probe_total) for cid, w in weights.items()}
    for cid in open_ids:
        weights[cid] = probe_total / len(open_ids)
    return weights


def max_delta(a: dict[str, float], b: dict[str, float]) -> float:
    keys = set(a) | set(b)
    return max((abs(a.get(k, 0.0) - b.get(k, 0.0)) for k in keys), default=0.0)


def to_litellm_weights(weights: dict[str, float]) -> dict[str, int]:
    """Normalized weights -> LiteLLM integer weight (0-100).

    A non-zero weight never rounds down to 0: LiteLLM sends a weight-0 deployment no traffic at all,
    which would silently defeat the probe weight.
    """
    return {cid: (max(1, round(w * 100)) if w > 0 else 0) for cid, w in weights.items()}
