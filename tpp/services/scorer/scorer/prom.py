"""Prometheus 查询封装。指标名/label 以 LiteLLM OSS /metrics 实际输出为准。"""

import httpx

from .config import Config
from .scoring import ChannelMetrics

# LiteLLM 指标里区分 deployment 的 label(已按 OSS /metrics 实际输出校准:
# 分组 = requested_model,渠道 = model_id)
ID_LABEL = "model_id"
GROUP_LABEL = "requested_model"
EXC_LABEL = "exception_class"


class PromClient:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.http = httpx.Client(base_url=cfg.prometheus_url, timeout=10.0)

    def _query(self, promql: str) -> list[dict]:
        r = self.http.get("/api/v1/query", params={"query": promql})
        r.raise_for_status()
        body = r.json()
        if body.get("status") != "success":
            raise RuntimeError(f"prometheus query failed: {body}")
        return body["data"]["result"]

    def fetch_metrics(self, model_groups: list[str]) -> dict[str, ChannelMetrics]:
        """返回 {channel_id: ChannelMetrics},只含窗口内有数据的渠道。"""
        w = self.cfg.window
        out: dict[str, ChannelMetrics] = {}

        p90 = self._query(
            f'histogram_quantile(0.90, sum by (le, {ID_LABEL}, {GROUP_LABEL}) '
            f"(rate(litellm_request_total_latency_metric_bucket[{w}])))"
        )
        for s in p90:
            cid = s["metric"].get(ID_LABEL)
            if not cid:
                continue
            val = float(s["value"][1])
            out[cid] = ChannelMetrics(
                model_group=s["metric"].get(GROUP_LABEL, ""),
                channel_id=cid,
                p90_latency=None if val != val else val,  # NaN -> None
                requests=0.0,
            )

        reqs = self._query(
            f"sum by ({ID_LABEL}, {GROUP_LABEL}) "
            f"(increase(litellm_deployment_total_requests_total[{w}]))"
        )
        for s in reqs:
            cid = s["metric"].get(ID_LABEL)
            if not cid:
                continue
            m = out.setdefault(
                cid,
                ChannelMetrics(
                    model_group=s["metric"].get(GROUP_LABEL, ""),
                    channel_id=cid,
                    p90_latency=None,
                    requests=0.0,
                ),
            )
            m.requests = float(s["value"][1])

        fails = self._query(
            f"sum by ({ID_LABEL}, {EXC_LABEL}) "
            f"(increase(litellm_deployment_failure_responses_total[{w}]))"
        )
        for s in fails:
            cid = s["metric"].get(ID_LABEL)
            if cid in out:
                cls = s["metric"].get(EXC_LABEL, "Unknown")
                out[cid].errors_by_class[cls] = float(s["value"][1])

        # 只保留我们管理的模型组
        groups = set(model_groups)
        return {cid: m for cid, m in out.items() if m.model_group in groups}
