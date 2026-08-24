"""Scorer 配置:全部来自环境变量,便于 ConfigMap/Helm 覆盖。"""

import os
from dataclasses import dataclass, field


def _f(name: str, default: float) -> float:
    return float(os.environ.get(name, default))


def _i(name: str, default: int) -> int:
    return int(os.environ.get(name, default))


@dataclass(frozen=True)
class Config:
    prometheus_url: str = os.environ.get("PROMETHEUS_URL", "http://localhost:9090")
    litellm_url: str = os.environ.get("LITELLM_URL", "http://localhost:4000")
    litellm_master_key: str = os.environ.get("LITELLM_MASTER_KEY", "")
    redis_host: str = os.environ.get("REDIS_HOST", "localhost")
    redis_port: int = _i("REDIS_PORT", 6379)
    channels_file: str = os.environ.get("CHANNELS_FILE", "/etc/scorer/channels.yaml")
    metrics_port: int = _i("METRICS_PORT", 9100)

    interval_seconds: int = _i("INTERVAL_SECONDS", 60)
    window: str = os.environ.get("WINDOW", "5m")

    # 打分参数(见 docs/architecture.md §3)
    alpha: float = _f("ALPHA", 0.3)            # EWMA 平滑系数
    gamma: float = _f("GAMMA", 2.0)            # 分差放大指数
    k_err: float = _f("K_ERR", 8.0)            # 错误率衰减系数
    w_lat: float = _f("W_LAT", 0.35)           # 延迟分权重
    w_err: float = _f("W_ERR", 0.65)           # 错误分权重
    w_floor: float = _f("W_FLOOR", 0.05)       # 探索保底权重
    min_samples: int = _i("MIN_SAMPLES", 10)   # 小样本保护阈值
    hysteresis: float = _f("HYSTERESIS", 0.02) # 写回迟滞(权重变化 > 2pp 才更新)
    default_q: float = _f("DEFAULT_Q", 0.5)    # 新渠道冷启动分

    # 熔断
    circuit_err_threshold: float = _f("CIRCUIT_ERR_THRESHOLD", 0.5)
    circuit_recovery_rounds: int = _i("CIRCUIT_RECOVERY_ROUNDS", 3)
    circuit_recovery_err: float = _f("CIRCUIT_RECOVERY_ERR", 0.1)


# 错误类别 -> 严重性权重。LiteLLM failure 指标的 exception_class label。
SEVERITY: dict[str, float] = {
    "Timeout": 3.0,
    "APIConnectionError": 3.0,
    "InternalServerError": 3.0,
    "ServiceUnavailableError": 3.0,
    "APIError": 3.0,
    "RateLimitError": 1.5,
}
SEVERITY_DEFAULT = 0.5  # 其余 4xx(认证/参数),多为调用方问题
SEVERE_CLASSES = {k for k, v in SEVERITY.items() if v >= 3.0}
