"""TPP 独立运营 dashboard 后端。

聚合两个数据源,喂给 static/index.html 单页前端:
- Prometheus:litellm_* / scorer_* 指标,渠道粒度靠 model_id label
  (= scorer-channels.yaml 里的 model_info.id)
- LiteLLM Management API:用户配额读写(master key 认证,只在服务端持有)

安全模型与 Prometheus 相同:自身无认证,不暴露 Ingress,仅经 kubectl 隧道访问。
"""

import asyncio
import os
from pathlib import Path

import httpx
import yaml
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel

PROMETHEUS_URL = os.environ.get(
    "PROMETHEUS_URL", "http://kube-prometheus-stack-prometheus.monitoring:9090"
)
LITELLM_URL = os.environ.get("LITELLM_URL", "http://litellm.litellm:4000")
LITELLM_MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY", "")
CHANNELS_FILE = os.environ.get("CHANNELS_FILE", "/etc/dashboard/channels.yaml")

# 4 个既有 dashboard 的跳转链接;默认按本地隧道端口(tpp-tunnels.sh 约定)
LINKS = {
    "LiteLLM": os.environ.get("LINK_LITELLM", "http://localhost:14000/ui"),
    "Grafana": os.environ.get("LINK_GRAFANA", "http://localhost:3000"),
    "Langfuse": os.environ.get("LINK_LANGFUSE", "http://localhost:3010"),
    "Prometheus": os.environ.get("LINK_PROMETHEUS", "http://localhost:9090"),
}

# 性能/错误统计窗口白名单(下拉选项与 PromQL range 共用)
WINDOWS = ("15m", "1h", "6h", "24h", "7d")

STATIC_DIR = Path(__file__).parent / "static"

app = FastAPI(title="tpp-dashboard")


def load_channels() -> list[dict]:
    """渠道注册表 → [{model_group, channel_id, region, provider}]。

    以注册表为准渲染全部渠道行,避免"没流量的渠道在 Prometheus 里无 series 就消失"。
    """
    with open(CHANNELS_FILE) as f:
        doc = yaml.safe_load(f)
    out = []
    for ch in doc["channels"]:
        params = ch["litellm_params"]
        out.append(
            {
                "model_group": ch["model_name"],
                "channel_id": ch["model_info"]["id"],
                "region": params.get("aws_region_name", ""),
                "provider": params["model"].split("/", 1)[0],
            }
        )
    return out


async def prom_query(client: httpx.AsyncClient, promql: str) -> list[dict]:
    r = await client.get(
        f"{PROMETHEUS_URL}/api/v1/query", params={"query": promql}
    )
    r.raise_for_status()
    body = r.json()
    if body.get("status") != "success":
        raise HTTPException(502, f"prometheus query failed: {promql}")
    return body["data"]["result"]


def by_channel(series: list[dict]) -> dict[str, float]:
    """{model_id: value},NaN 丢弃(histogram_quantile 无样本时返回 NaN)。"""
    out = {}
    for s in series:
        cid = s["metric"].get("model_id")
        if not cid:
            continue
        v = float(s["value"][1])
        if v == v:  # not NaN
            out[cid] = v
    return out


@app.get("/healthz")
async def healthz():
    return {"ok": True}


@app.get("/api/config")
async def config():
    return {"links": LINKS, "channels": load_channels(), "windows": list(WINDOWS)}


@app.get("/api/overview")
async def overview(window: str = Query("1h")):
    if window not in WINDOWS:
        raise HTTPException(400, f"window must be one of {WINDOWS}")
    w = window

    q = {
        # 消费与用量固定看 24h(需求是"费用情况"日粒度);性能/错误跟随窗口选择
        "spend_24h": "sum by (model_id) (increase(litellm_spend_metric_total[24h]))",
        "tokens_in_24h": "sum by (model_id) (increase(litellm_input_tokens_metric_total[24h]))",
        "tokens_out_24h": "sum by (model_id) (increase(litellm_output_tokens_metric_total[24h]))",
        # prompt cache:litellm_input_tokens 不含缓存部分,读/写单独计
        "cache_read_24h": "sum by (model_id) (increase(litellm_input_cached_tokens_metric_total[24h]))",
        "cache_write_24h": "sum by (model_id) (increase(litellm_input_cache_creation_tokens_metric_total[24h]))",
        "requests": f"sum by (model_id) (increase(litellm_deployment_total_requests_total[{w}]))",
        "failures": f"sum by (model_id) (increase(litellm_deployment_failure_responses_total[{w}]))",
        "quality": "max by (model_id) (scorer_quality_score)",
        "weight": "max by (model_id) (scorer_weight)",
        "circuit": "max by (model_id) (scorer_circuit_open)",
        # 同一渠道多副本/多 api_base 会有多条 state,取最差(0 健康 / 1 部分 / 2 异常)
        "dstate": "max by (model_id) (litellm_deployment_state)",
    }
    hists = {
        "ttft": "litellm_llm_api_time_to_first_token_metric_bucket",
        "e2e": "litellm_request_total_latency_metric_bucket",
        "tpot": "litellm_deployment_latency_per_output_token_bucket",
    }
    quantiles = {"p50": 0.5, "p90": 0.9, "p99": 0.99}
    for hname, metric in hists.items():
        for pname, qv in quantiles.items():
            q[f"{hname}_{pname}"] = (
                f"histogram_quantile({qv}, sum by (le, model_id) (rate({metric}[{w}])))"
            )
    q["errors_by_class"] = (
        f"sum by (model_id, exception_class) "
        f"(increase(litellm_deployment_failure_responses_total[{w}]))"
    )

    async with httpx.AsyncClient(timeout=15.0) as client:
        keys = list(q)
        results = await asyncio.gather(*(prom_query(client, q[k]) for k in keys))
    raw = dict(zip(keys, results))

    flat = {k: by_channel(v) for k, v in raw.items() if k != "errors_by_class"}
    err_cls: dict[str, dict[str, float]] = {}
    for s in raw["errors_by_class"]:
        cid = s["metric"].get("model_id")
        n = float(s["value"][1])
        if cid and n > 0.5:
            err_cls.setdefault(cid, {})[
                s["metric"].get("exception_class", "Unknown")
            ] = round(n)

    channels = []
    for ch in load_channels():
        cid = ch["channel_id"]
        g = lambda k: flat[k].get(cid)  # noqa: E731
        reqs, fails = g("requests") or 0.0, g("failures") or 0.0
        tok_in = g("tokens_in_24h") or 0.0
        c_read = g("cache_read_24h") or 0.0
        c_write = g("cache_write_24h") or 0.0
        prompt_total = tok_in + c_read + c_write
        row = {
            **ch,
            "spend_24h": g("spend_24h") or 0.0,
            "tokens_in_24h": tok_in,
            "tokens_out_24h": g("tokens_out_24h") or 0.0,
            "cache_read_24h": c_read,
            "cache_write_24h": c_write,
            # 命中率 = 缓存读 / 全部输入(普通输入+缓存读+缓存写),近 24h
            "cache_hit_rate": (c_read / prompt_total) if prompt_total > 0 else None,
            "requests": reqs,
            "failures": fails,
            "error_rate": (fails / reqs) if reqs > 0 else None,
            "errors_by_class": err_cls.get(cid, {}),
            "quality": g("quality"),
            "weight": g("weight"),
            "circuit_open": (g("circuit") or 0.0) > 0.5,
            "deployment_state": g("dstate"),
        }
        for h in hists:
            row[h] = {p: g(f"{h}_{p}") for p in quantiles}
        # TPS 由 TPOT 直方图分位数换算(1/TPOT):pXX TPS = pXX-慢请求的解码吞吐
        row["tps"] = {
            p: (1.0 / row["tpot"][p]) if row["tpot"][p] else None for p in quantiles
        }
        channels.append(row)

    return {"window": w, "channels": channels}


# ---------- 用户配额(USD/day) ----------

def _llm_headers() -> dict:
    return {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}


@app.get("/api/users")
async def users():
    async with httpx.AsyncClient(timeout=15.0) as client:
        r = await client.get(
            f"{LITELLM_URL}/user/list",
            params={"page": 1, "page_size": 100},
            headers=_llm_headers(),
        )
    if r.status_code != 200:
        raise HTTPException(502, f"litellm /user/list: {r.status_code} {r.text[:200]}")
    out = []
    for u in r.json().get("users", []):
        out.append(
            {
                "user_id": u["user_id"],
                "alias": u.get("user_alias"),
                "max_budget": u.get("max_budget"),
                "spend": u.get("spend", 0.0),
                "budget_duration": u.get("budget_duration"),
                "budget_reset_at": u.get("budget_reset_at"),
                "key_count": u.get("key_count", 0),
            }
        )
    out.sort(key=lambda u: -(u["spend"] or 0.0))
    return {"users": out}


class BudgetUpdate(BaseModel):
    user_id: str
    max_budget: float


@app.post("/api/users/budget")
async def update_budget(req: BudgetUpdate):
    if req.max_budget < 0:
        raise HTTPException(400, "max_budget must be >= 0")
    async with httpx.AsyncClient(timeout=15.0) as client:
        # /user/update 对不存在的 user 会隐式创建,先校验存在,只做更新
        info = await client.get(
            f"{LITELLM_URL}/user/info",
            params={"user_id": req.user_id},
            headers=_llm_headers(),
        )
        if info.status_code != 200:
            raise HTTPException(404, f"user not found: {req.user_id}")
        # 配额语义固定为 USD/day:写入时同时钉住 budget_duration=1d
        r = await client.post(
            f"{LITELLM_URL}/user/update",
            json={
                "user_id": req.user_id,
                "max_budget": req.max_budget,
                "budget_duration": "1d",
            },
            headers=_llm_headers(),
        )
    if r.status_code != 200:
        raise HTTPException(502, f"litellm /user/update: {r.status_code} {r.text[:200]}")
    return {"ok": True, "user_id": req.user_id, "max_budget": req.max_budget}


@app.get("/")
async def index():
    return FileResponse(STATIC_DIR / "index.html")


def main():
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))


if __name__ == "__main__":
    main()
