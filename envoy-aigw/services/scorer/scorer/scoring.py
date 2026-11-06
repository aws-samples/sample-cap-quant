"""Scoring core: pure functions, no IO. Ported from the TPP scorer with two changes:

- latency score blends TTFT p90 and E2E p90 (TPP used E2E only; for agent traffic TTFT is what users feel);
- weights are prior-weighted: weight_i ∝ prior_i · q_i^gamma, where the prior is the weight configured in the
  AIGatewayRoute when the scorer first saw the channel (90/10 here). Equal quality therefore keeps the configured
  split instead of drifting to 50/50, which matters because prompt cache is per Region.
"""

import math
from dataclasses import dataclass, field

from .config import Config, SEVERITY, SEVERITY_DEFAULT, SEVERE_CLASSES


@dataclass
class ChannelMetrics:
    """Observations for one channel (model x backend) within the window."""

    model: str
    channel_id: str  # backend name, e.g. bedrock-anthropic-use2
    requests: float
    p90_ttft: float | None = None  # seconds; None when the window has no successful streaming requests
    p90_e2e: float | None = None
    errors_by_class: dict[str, float] = field(default_factory=dict)


def weighted_error_rate(m: ChannelMetrics) -> float:
    weighted = sum(SEVERITY.get(cls, SEVERITY_DEFAULT) * cnt for cls, cnt in m.errors_by_class.items())
    return weighted / max(m.requests, 1.0)


def severe_dominant(m: ChannelMetrics) -> bool:
    total = sum(m.errors_by_class.values())
    if total <= 0:
        return False
    severe = sum(cnt for cls, cnt in m.errors_by_class.items() if cls in SEVERE_CLASSES)
    return severe / total >= 0.5


def _rel(best: float | None, mine: float | None) -> float | None:
    """best/mine clamped to [0, 1]; None when either side is unknown."""
    if best is None or mine is None or mine <= 0:
        return None
    return max(0.0, min(1.0, best / mine))


def latency_score(m: ChannelMetrics, best_ttft: float | None, best_e2e: float | None, cfg: Config) -> float | None:
    """Blend of relative TTFT and relative E2E. Falls back to whichever is available; None if neither."""
    s_ttft, s_e2e = _rel(best_ttft, m.p90_ttft), _rel(best_e2e, m.p90_e2e)
    if s_ttft is None and s_e2e is None:
        return None
    if s_ttft is None:
        return s_e2e
    if s_e2e is None:
        return s_ttft
    return cfg.w_ttft * s_ttft + (1.0 - cfg.w_ttft) * s_e2e


def raw_score(m: ChannelMetrics, best_ttft: float | None, best_e2e: float | None, cfg: Config) -> float:
    s_lat = latency_score(m, best_ttft, best_e2e, cfg)
    if s_lat is None:
        # requests but no latency samples = every request failed before first byte
        s_lat = 0.0 if m.requests > 0 else cfg.default_q
    s_err = math.exp(-cfg.k_err * weighted_error_rate(m))
    return cfg.w_lat * s_lat + cfg.w_err * s_err


def ewma(prev: float | None, raw: float, alpha: float) -> float:
    if prev is None:
        return raw
    return alpha * raw + (1 - alpha) * prev


def circuit_should_open(m: ChannelMetrics, cfg: Config) -> bool:
    return weighted_error_rate(m) > cfg.circuit_err_threshold and severe_dominant(m)


def weights_from_scores(
    scores: dict[str, float], prior: dict[str, float], circuit_open: set[str], cfg: Config
) -> dict[str, float]:
    """Scores -> normalized weights.

    weight_i ∝ prior_i · q_i^gamma for healthy channels, floored at w_floor and renormalized. Tripped channels get
    the probe share w_probe (below the floor) so they keep producing samples for the recovery rule.
    """
    open_ids = {cid for cid in circuit_open if cid in scores}
    active = {cid: q for cid, q in scores.items() if cid not in open_ids}
    if not active:
        # Every channel tripped: split evenly so traffic still has somewhere to go (Envoy outlier detection remains)
        return {cid: 1.0 / len(scores) for cid in scores}

    pri_total = sum(prior.get(cid, 1.0) for cid in active) or 1.0
    powered = {cid: (prior.get(cid, 1.0) / pri_total) * max(q, 1e-6) ** cfg.gamma for cid, q in active.items()}
    total = sum(powered.values())
    weights = {cid: v / total for cid, v in powered.items()}

    # Exact floor: channels under w_floor get exactly w_floor, the rest share what remains proportionally
    # (TPP floored then renormalized, which left the floor slightly under 5 %).
    low = {cid for cid, w in weights.items() if w < cfg.w_floor}
    if low and len(low) < len(weights):
        rest = 1.0 - cfg.w_floor * len(low)
        high_total = sum(w for cid, w in weights.items() if cid not in low) or 1.0
        weights = {cid: (cfg.w_floor if cid in low else w / high_total * rest) for cid, w in weights.items()}

    probe_total = min(cfg.w_probe * len(open_ids), 0.5)
    weights = {cid: w * (1.0 - probe_total) for cid, w in weights.items()}
    for cid in open_ids:
        weights[cid] = probe_total / len(open_ids)
    return weights


def max_delta(a: dict[str, float], b: dict[str, float]) -> float:
    keys = set(a) | set(b)
    return max((abs(a.get(k, 0.0) - b.get(k, 0.0)) for k in keys), default=0.0)


def to_route_weights(weights: dict[str, float]) -> dict[str, int]:
    """Normalized weights -> integer backendRef weights (1-100). A non-zero share never rounds to 0:
    Envoy sends a weight-0 locality nothing, which would defeat the probe share."""
    return {cid: (max(1, round(w * 100)) if w > 0 else 0) for cid, w in weights.items()}
