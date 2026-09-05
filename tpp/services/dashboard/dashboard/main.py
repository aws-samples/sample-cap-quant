"""Backend for the TPP standalone ops dashboard.

Aggregates two data sources and feeds the static/index.html single-page frontend:
- Prometheus: litellm_* / scorer_* metrics, per-channel granularity via the
  model_id label (= model_info.id in scorer-channels.yaml)
- LiteLLM Management API: user quota read/write (master key auth, held
  server-side only)

Same security model as Prometheus: no auth of its own, no Ingress exposure,
accessed only via kubectl tunnel.
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

# Jump links to the 4 existing dashboards; defaults follow the local tunnel ports (tpp-tunnels.sh convention)
LINKS = {
    "LiteLLM": os.environ.get("LINK_LITELLM", "http://localhost:14000/ui"),
    "Grafana": os.environ.get("LINK_GRAFANA", "http://localhost:3000"),
    "Langfuse": os.environ.get("LINK_LANGFUSE", "http://localhost:3010"),
    "Prometheus": os.environ.get("LINK_PROMETHEUS", "http://localhost:9090"),
}

# Whitelist of performance/error stat windows (shared by the dropdown options and the PromQL range)
WINDOWS = ("15m", "1h", "6h", "24h", "7d")

STATIC_DIR = Path(__file__).parent / "static"

app = FastAPI(title="tpp-dashboard")


def load_channels() -> list[dict]:
    """Channel registry -> [{model_group, channel_id, region, provider}].

    Render all channel rows from the registry, so that channels with no
    traffic don't vanish just because they have no series in Prometheus.
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
    """{model_id: value}; drop NaN (histogram_quantile returns NaN when there are no samples)."""
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
        # Spend and usage are fixed at 24h (the requirement is daily-granularity "cost overview"); performance/errors follow the selected window
        "spend_24h": "sum by (model_id) (increase(litellm_spend_metric_total[24h]))",
        "tokens_in_24h": "sum by (model_id) (increase(litellm_input_tokens_metric_total[24h]))",
        "tokens_out_24h": "sum by (model_id) (increase(litellm_output_tokens_metric_total[24h]))",
        # prompt cache: litellm_input_tokens excludes the cached portion; reads/writes are counted separately
        "cache_read_24h": "sum by (model_id) (increase(litellm_input_cached_tokens_metric_total[24h]))",
        "cache_write_24h": "sum by (model_id) (increase(litellm_input_cache_creation_tokens_metric_total[24h]))",
        "requests": f"sum by (model_id) (increase(litellm_deployment_total_requests_total[{w}]))",
        "failures": f"sum by (model_id) (increase(litellm_deployment_failure_responses_total[{w}]))",
        "quality": "max by (model_id) (scorer_quality_score)",
        "weight": "max by (model_id) (scorer_weight)",
        "circuit": "max by (model_id) (scorer_circuit_open)",
        # A channel with multiple replicas/api_bases has multiple state series; take the worst (0 healthy / 1 partial / 2 unhealthy)
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
            # Hit rate = cache reads / all input (regular input + cache reads + cache writes), last 24h
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
        # TPS derived from TPOT histogram quantiles (1/TPOT): pXX TPS = decode throughput of the pXX-slow request
        row["tps"] = {
            p: (1.0 / row["tpot"][p]) if row["tpot"][p] else None for p in quantiles
        }
        channels.append(row)

    return {"window": w, "channels": channels}


# ---------- User quotas (USD/day) ----------

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
        # /user/update implicitly creates nonexistent users; verify existence first so this is update-only
        info = await client.get(
            f"{LITELLM_URL}/user/info",
            params={"user_id": req.user_id},
            headers=_llm_headers(),
        )
        if info.status_code != 200:
            raise HTTPException(404, f"user not found: {req.user_id}")
        # Quota semantics are fixed to USD/day: pin budget_duration=1d on every write
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
