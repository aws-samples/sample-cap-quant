"""Scorer configuration: everything comes from environment variables (k8s/scorer/10-deployment.yaml.tmpl)."""

import os
from dataclasses import dataclass


def _f(name: str, default: float) -> float:
    return float(os.environ.get(name, default))


def _i(name: str, default: int) -> int:
    return int(os.environ.get(name, default))


@dataclass(frozen=True)
class Config:
    prometheus_url: str = os.environ.get("PROMETHEUS_URL", "http://kube-prometheus-stack-prometheus.monitoring:9090")
    redis_host: str = os.environ.get("REDIS_HOST", "redis.redis-system.svc.cluster.local")
    redis_port: int = _i("REDIS_PORT", 6379)
    redis_password: str = os.environ.get("REDIS_PASSWORD", "")
    redis_ssl: bool = os.environ.get("REDIS_SSL", "false").strip().lower() in ("1", "true", "yes")
    metrics_port: int = _i("METRICS_PORT", 9100)

    # The AIGatewayRoute whose backendRefs[].weight this scorer owns
    route_namespace: str = os.environ.get("ROUTE_NAMESPACE", "aigw")
    route_name: str = os.environ.get("ROUTE_NAME", "aigw")

    interval_seconds: int = _i("INTERVAL_SECONDS", 60)
    window: str = os.environ.get("WINDOW", "10m")  # dev traffic is thin; 10m lets the 10% channel collect samples

    # Scoring (TPP algorithm with two additions: TTFT in the latency score, prior = configured weights)
    alpha: float = _f("ALPHA", 0.3)            # EWMA smoothing factor (time constant ~3 rounds)
    gamma: float = _f("GAMMA", 2.0)            # score-gap amplification exponent
    k_err: float = _f("K_ERR", 8.0)            # error-rate decay coefficient: s_err = exp(-k_err * err_rate)
    w_lat: float = _f("W_LAT", 0.35)           # latency score weight
    w_err: float = _f("W_ERR", 0.65)           # error score weight
    w_ttft: float = _f("W_TTFT", 0.6)          # share of the latency score taken by TTFT (rest: E2E p90)
    w_floor: float = _f("W_FLOOR", 0.05)       # exploration floor: every healthy channel keeps >= 5 %
    w_probe: float = _f("W_PROBE", 0.01)       # probe share for a tripped channel so recovery can be observed
    min_samples: int = _i("MIN_SAMPLES", 5)    # small-sample protection threshold (requests in window)
    hysteresis: float = _f("HYSTERESIS", 0.02) # write back only when some weight moves > 2 pp
    default_q: float = _f("DEFAULT_Q", 0.8)    # cold-start score for a channel never scored

    # Circuit breaker (minute-level, global; Envoy's outlier detection is the second-level layer in front)
    circuit_err_threshold: float = _f("CIRCUIT_ERR_THRESHOLD", 0.5)
    circuit_recovery_rounds: int = _i("CIRCUIT_RECOVERY_ROUNDS", 3)
    circuit_recovery_err: float = _f("CIRCUIT_RECOVERY_ERR", 0.1)


# Error class -> severity. The AI Gateway only emits a generic error_type on gen_ai_* metrics (no status
# code per channel: Envoy's per-status stats are per cluster, and both channels share one cluster), so
# every upstream failure is one class. A 429 storm and a 5xx storm therefore look the same here, which
# is the behaviour we want: either way the channel should lose traffic until it recovers.
SEVERITY: dict[str, float] = {"upstream_error": 3.0}
SEVERITY_DEFAULT = 3.0
SEVERE_CLASSES = {"upstream_error"}
