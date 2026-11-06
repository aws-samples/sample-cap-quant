"""Prometheus queries against the Envoy AI Gateway metrics (gen_ai_* from the extproc sidecar).

A channel is (model, backend): gen_ai_original_model x gen_ai_backend. gen_ai_backend is "namespace/name"; the
namespace prefix is stripped so channel ids match the backendRef names in the AIGatewayRoute.
"""

import httpx

from .config import Config
from .scoring import ChannelMetrics

MODEL = "gen_ai_original_model"
BACKEND = "gen_ai_backend"
REQ = "gen_ai_server_request_duration_seconds_count"
TTFT = "gen_ai_server_time_to_first_token_seconds_bucket"
E2E = "gen_ai_server_request_duration_seconds_bucket"


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

    @staticmethod
    def _key(s: dict) -> tuple[str, str] | None:
        model, backend = s["metric"].get(MODEL), s["metric"].get(BACKEND)
        if not model or not backend:
            return None
        return model, backend.split("/", 1)[-1]

    @staticmethod
    def _val(s: dict) -> float | None:
        v = float(s["value"][1])
        return None if v != v else v  # NaN -> None

    def fetch_metrics(self, models: list[str]) -> dict[tuple[str, str], ChannelMetrics]:
        """{(model, channel_id): ChannelMetrics} for channels with any series in the window."""
        w = self.cfg.window
        out: dict[tuple[str, str], ChannelMetrics] = {}

        def get(model: str, cid: str) -> ChannelMetrics:
            return out.setdefault((model, cid), ChannelMetrics(model=model, channel_id=cid, requests=0.0))

        for s in self._query(f"sum by ({MODEL}, {BACKEND}) (increase({REQ}[{w}]))"):
            if k := self._key(s):
                get(*k).requests = self._val(s) or 0.0
        for s in self._query(f'sum by ({MODEL}, {BACKEND}) (increase({REQ}{{error_type!=""}}[{w}]))'):
            if (k := self._key(s)) and (v := self._val(s)):
                if v > 0:
                    get(*k).errors_by_class["upstream_error"] = v
        # Latency over successful requests only: failures return fast and would otherwise win the latency score
        ok = '{error_type=""}'
        for s in self._query(f"histogram_quantile(0.90, sum by (le, {MODEL}, {BACKEND}) (rate({TTFT}{ok}[{w}])))"):
            if k := self._key(s):
                get(*k).p90_ttft = self._val(s)
        for s in self._query(f"histogram_quantile(0.90, sum by (le, {MODEL}, {BACKEND}) (rate({E2E}{ok}[{w}])))"):
            if k := self._key(s):
                get(*k).p90_e2e = self._val(s)

        managed = set(models)
        return {k: m for k, m in out.items() if k[0] in managed}
