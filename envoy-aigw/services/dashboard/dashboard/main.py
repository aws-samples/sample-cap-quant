"""Backend for the Envoy AI Gateway ops dashboard.

Same shape as the TPP dashboard it is modelled on: one container = FastAPI aggregation backend + a static
single-page frontend, no storage of its own. Three data sources:

- Prometheus: gen_ai_* (tokens, TTFT, TPOT, E2E, per model / per client) and envoy_* (in-flight, status classes)
- Kubernetes API: the AIGatewayRoute is the model registry (public name -> backend / Bedrock id); AIServiceBackend,
  Gateway and Deployment status feed the health strip; BackendTrafficPolicy supplies the per-client limits
- API keys: the k8s Secret `aigw-api-keys` lists client ids (keys are never returned); Secrets Manager is the
  source of truth and the only thing this service writes (create / rotate / revoke a client key)

No authentication of its own: it is reached only through the ALB Cognito login (k8s/ingress) or a kubectl tunnel.
"""

import asyncio
import json
import os
import re
import secrets
from pathlib import Path

import boto3
import httpx
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from kubernetes import client as k8s, config as k8s_config
from pydantic import BaseModel

PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://kube-prometheus-stack-prometheus.monitoring:9090")
AIGW_ENV = os.environ.get("AIGW_ENV", "dev")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-2")

API_KEYS_SECRET_ID = os.environ.get("API_KEYS_SECRET_ID", f"aigw/{AIGW_ENV}/api-keys")
API_KEYS_K8S_SECRET = os.environ.get("API_KEYS_K8S_SECRET", "aigw-api-keys")
GATEWAY_NAMESPACE = os.environ.get("GATEWAY_NAMESPACE", "aigw")
ROUTE_NAME = os.environ.get("AIGATEWAYROUTE_NAME", "aigw")
GATEWAY_NAME = os.environ.get("GATEWAY_NAME", "aigw")
TRAFFIC_POLICY_NAME = os.environ.get("BACKENDTRAFFICPOLICY_NAME", "aigw")
ENVOY_NAMESPACE = os.environ.get("ENVOY_NAMESPACE", "envoy-gateway-system")

LINKS = {
    "Grafana": os.environ.get("LINK_GRAFANA", "http://localhost:3000"),
    "Prometheus": os.environ.get("LINK_PROMETHEUS", "http://localhost:9090"),
}

WINDOWS = ("15m", "1h", "6h", "24h", "7d")
TOKEN_TYPES = ("input", "output", "cached_input", "cache_creation_input", "reasoning")
CLIENT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{1,62}$")
PROTECTED_CLIENTS = {"admin"}

STATIC_DIR = Path(__file__).parent / "static"

app = FastAPI(title="aigw-dashboard")

# ---------- Kubernetes ----------

try:
    k8s_config.load_incluster_config()
except k8s_config.ConfigException:
    k8s_config.load_kube_config()
core = k8s.CoreV1Api()
apps = k8s.AppsV1Api()
custom = k8s.CustomObjectsApi()


def _cond(obj: dict, ctype: str) -> bool | None:
    for c in (obj.get("status") or {}).get("conditions", []):
        if c.get("type") == ctype:
            return c.get("status") == "True"
    return None


def load_models() -> list[dict]:
    """AIGatewayRoute rules -> one entry per public model name with its channels:
    [{name, upstream_model, channels: [{backend, weight, priority}]}]. The registry every table is rendered from."""
    route = custom.get_namespaced_custom_object(
        "aigateway.envoyproxy.io", "v1beta1", GATEWAY_NAMESPACE, "aigatewayroutes", ROUTE_NAME
    )
    out = []
    for rule in route["spec"].get("rules", []):
        name = None
        for m in rule.get("matches", []):
            for h in m.get("headers", []):
                if h.get("name") == "x-ai-eg-model":
                    name = h.get("value")
        refs = rule.get("backendRefs", [])
        if not name or not refs:
            continue
        out.append({
            "name": name,
            "upstream_model": refs[0].get("modelNameOverride", name),
            "channels": [{"backend": b["name"], "weight": b.get("weight", 1), "priority": b.get("priority", 0)} for b in refs],
        })
    return out


def load_limits() -> dict:
    """Per-client limits from the BackendTrafficPolicy global rate-limit rules (static for every client)."""
    out = {"tokens": None, "tokens_unit": None, "requests": None, "requests_unit": None}
    try:
        btp = custom.get_namespaced_custom_object(
            "gateway.envoyproxy.io", "v1alpha1", GATEWAY_NAMESPACE, "backendtrafficpolicies", TRAFFIC_POLICY_NAME
        )
    except k8s.ApiException:
        return out
    for rule in (((btp.get("spec") or {}).get("rateLimit") or {}).get("global") or {}).get("rules", []):
        lim = rule.get("limit", {})
        if "cost" in rule and (rule["cost"].get("response") or {}).get("from") == "Metadata":
            out["tokens"], out["tokens_unit"] = lim.get("requests"), lim.get("unit")
        else:
            out["requests"], out["requests_unit"] = lim.get("requests"), lim.get("unit")
    return out


def gateway_status() -> dict:
    gw = custom.get_namespaced_custom_object(
        "gateway.networking.k8s.io", "v1", GATEWAY_NAMESPACE, "gateways", GATEWAY_NAME
    )
    backends = custom.list_namespaced_custom_object(
        "aigateway.envoyproxy.io", "v1beta1", GATEWAY_NAMESPACE, "aiservicebackends"
    )["items"]
    pods = core.list_namespaced_pod(
        ENVOY_NAMESPACE, label_selector=f"gateway.envoyproxy.io/owning-gateway-name={GATEWAY_NAME}"
    ).items
    ready = sum(1 for p in pods if any(c.type == "Ready" and c.status == "True" for c in (p.status.conditions or [])))

    def deploy_ready(ns: str, name: str) -> dict:
        try:
            d = apps.read_namespaced_deployment(name, ns)
            return {"ready": d.status.ready_replicas or 0, "desired": d.spec.replicas or 0}
        except k8s.ApiException:
            return {"ready": 0, "desired": 0}

    return {
        "gateway_programmed": _cond(gw, "Programmed"),
        "envoy_pods": {"ready": ready, "total": len(pods)},
        "backends": [{"name": b["metadata"]["name"], "schema": b["spec"]["schema"]["name"], "accepted": _cond(b, "Accepted")}
                     for b in backends],
        "ratelimit": deploy_ready(ENVOY_NAMESPACE, "envoy-ratelimit"),
        "redis": deploy_ready("redis-system", "redis"),
        "controller": deploy_ready("envoy-ai-gateway-system", "ai-gateway-controller"),
    }


# ---------- Prometheus ----------

async def prom_query(client: httpx.AsyncClient, promql: str) -> list[dict]:
    r = await client.get(f"{PROMETHEUS_URL}/api/v1/query", params={"query": promql})
    r.raise_for_status()
    body = r.json()
    if body.get("status") != "success":
        raise HTTPException(502, f"prometheus query failed: {promql}")
    return body["data"]["result"]


def by_label(series: list[dict], label: str) -> dict[str, float]:
    """{label value: value}; drop NaN (histogram_quantile returns NaN with no samples)."""
    out = {}
    for s in series:
        key = s["metric"].get(label)
        if key is None:
            continue
        v = float(s["value"][1])
        if v == v:
            out[key] = v
    return out


def by_two(series: list[dict], l1: str, l2: str) -> dict[str, dict[str, float]]:
    out: dict[str, dict[str, float]] = {}
    for s in series:
        a, b = s["metric"].get(l1), s["metric"].get(l2)
        if a is None or b is None:
            continue
        v = float(s["value"][1])
        if v == v:
            out.setdefault(a, {})[b] = v
    return out


async def gather(q: dict[str, str]) -> dict[str, list[dict]]:
    async with httpx.AsyncClient(timeout=15.0) as client:
        keys = list(q)
        results = await asyncio.gather(*(prom_query(client, q[k]) for k in keys))
    return dict(zip(keys, results))


REQ = "gen_ai_server_request_duration_seconds_count"
TOK = "gen_ai_client_token_usage_sum"
HISTS = {
    "ttft": "gen_ai_server_time_to_first_token_seconds_bucket",
    "tpot": "gen_ai_server_time_per_output_token_seconds_bucket",
    "e2e": "gen_ai_server_request_duration_seconds_bucket",
}
QUANTILES = {"p50": 0.5, "p90": 0.9, "p99": 0.99}


def perf_queries(dim: str, w: str) -> dict[str, str]:
    q = {
        "requests": f"sum by ({dim}) (increase({REQ}[{w}]))",
        "failures": f'sum by ({dim}) (increase({REQ}{{error_type!=""}}[{w}]))',
        "tokens_24h": f"sum by ({dim}, gen_ai_token_type) (increase({TOK}[24h]))",
    }
    for h, metric in HISTS.items():
        for p, qv in QUANTILES.items():
            q[f"{h}_{p}"] = f"histogram_quantile({qv}, sum by (le, {dim}) (rate({metric}[{w}])))"
    return q


def perf_row(flat: dict, toks: dict, key: str) -> dict:
    g = lambda k: flat[k].get(key)  # noqa: E731
    t = {tt: (toks.get(key) or {}).get(tt, 0.0) for tt in TOKEN_TYPES}
    prompt_total = t["input"] + t["cached_input"] + t["cache_creation_input"]
    reqs, fails = g("requests") or 0.0, g("failures") or 0.0
    row = {
        "requests": reqs,
        "failures": fails,
        "error_rate": (fails / reqs) if reqs > 0 else None,
        "tokens_24h": t,
        "cache_hit_rate": (t["cached_input"] / prompt_total) if prompt_total > 0 else None,
    }
    for h in HISTS:
        row[h] = {p: g(f"{h}_{p}") for p in QUANTILES}
    row["tps"] = {p: (1.0 / row["tpot"][p]) if row["tpot"][p] else None for p in QUANTILES}
    return row


# ---------- API ----------

@app.get("/healthz")
async def healthz():
    return {"ok": True}


@app.get("/api/config")
async def config():
    return {
        "env": AIGW_ENV,
        "links": LINKS,
        "models": load_models(),
        "limits": load_limits(),
        "windows": list(WINDOWS),
        "protected_clients": sorted(PROTECTED_CLIENTS),
    }


@app.get("/api/overview")
async def overview(window: str = Query("1h")):
    if window not in WINDOWS:
        raise HTTPException(400, f"window must be one of {WINDOWS}")
    w = window
    q = perf_queries("gen_ai_original_model", w)
    q["inflight"] = "sum(envoy_http_downstream_rq_active)"
    q["status_classes"] = f"sum by (envoy_response_code_class) (increase(envoy_http_downstream_rq_xx[{w}]))"
    q["by_operation"] = f"sum by (gen_ai_operation_name) (increase({REQ}[{w}]))"
    q["by_backend"] = f"sum by (gen_ai_backend) (increase({REQ}[{w}]))"
    # Per channel (model x backend): share of traffic, errors, TTFT p90 -- the scorer's view
    q["ch_requests"] = f"sum by (gen_ai_original_model, gen_ai_backend) (increase({REQ}[{w}]))"
    q["ch_failures"] = f'sum by (gen_ai_original_model, gen_ai_backend) (increase({REQ}{{error_type!=""}}[{w}]))'
    q["ch_ttft_p90"] = (f"histogram_quantile(0.9, sum by (le, gen_ai_original_model, gen_ai_backend) "
                        f"(rate({HISTS['ttft']}[{w}])))")
    # Scorer output (services/scorer): EWMA quality, assigned weight, breaker state per model x channel
    q["sc_quality"] = "max by (model, channel) (scorer_quality_score)"
    q["sc_weight"] = "max by (model, channel) (scorer_weight)"
    q["sc_circuit"] = "max by (model, channel) (scorer_circuit_open)"
    q["sc_last"] = "max(scorer_last_success_timestamp)"
    raw = await gather(q)

    skip = ("tokens_24h", "inflight", "status_classes", "by_operation", "by_backend", "ch_requests", "ch_failures", "ch_ttft_p90",
            "sc_quality", "sc_weight", "sc_circuit", "sc_last")
    flat = {k: by_label(v, "gen_ai_original_model") for k, v in raw.items() if k not in skip}
    toks = by_two(raw["tokens_24h"], "gen_ai_original_model", "gen_ai_token_type")
    ch = {k: by_two(raw[k], "gen_ai_original_model", "gen_ai_backend") for k in ("ch_requests", "ch_failures", "ch_ttft_p90")}
    sc = {k: by_two(raw[k], "model", "channel") for k in ("sc_quality", "sc_weight", "sc_circuit")}
    scorer_last = float(raw["sc_last"][0]["value"][1]) if raw["sc_last"] else None

    models = []
    for m in load_models():
        row = {**m, **perf_row(flat, toks, m["name"])}
        total = sum((ch["ch_requests"].get(m["name"]) or {}).values()) or 0.0
        for c in row["channels"]:
            key = f"{GATEWAY_NAMESPACE}/{c['backend']}"  # gen_ai_backend label is namespace/name
            reqs = (ch["ch_requests"].get(m["name"]) or {}).get(key, 0.0)
            fails = (ch["ch_failures"].get(m["name"]) or {}).get(key, 0.0)
            c.update({
                "requests": reqs,
                "share": (reqs / total) if total > 0 else None,
                "error_rate": (fails / reqs) if reqs > 0 else None,
                "ttft_p90": (ch["ch_ttft_p90"].get(m["name"]) or {}).get(key),
                "quality": (sc["sc_quality"].get(m["name"]) or {}).get(c["backend"]),
                "scorer_weight": (sc["sc_weight"].get(m["name"]) or {}).get(c["backend"]),
                "circuit_open": ((sc["sc_circuit"].get(m["name"]) or {}).get(c["backend"]) or 0.0) > 0.5,
            })
        models.append(row)
    inflight = raw["inflight"][0]["value"][1] if raw["inflight"] else 0
    return {
        "window": w,
        "models": models,
        "gateway": {
            "inflight": float(inflight),
            "status_classes": by_label(raw["status_classes"], "envoy_response_code_class"),
            "by_operation": by_label(raw["by_operation"], "gen_ai_operation_name"),
            "by_backend": by_label(raw["by_backend"], "gen_ai_backend"),
            "scorer_last_success": scorer_last,
            **gateway_status(),
        },
    }


# ---------- Clients (API keys) ----------

def _k8s_client_ids() -> list[str]:
    try:
        sec = core.read_namespaced_secret(API_KEYS_K8S_SECRET, GATEWAY_NAMESPACE)
    except k8s.ApiException as e:
        if e.status == 404:
            return []
        raise
    return sorted((sec.data or {}).keys())


def _sm():
    return boto3.client("secretsmanager", region_name=AWS_REGION)


def _sm_read() -> dict[str, str]:
    return json.loads(_sm().get_secret_value(SecretId=API_KEYS_SECRET_ID)["SecretString"])


def _sm_write(keys: dict[str, str]) -> None:
    _sm().put_secret_value(SecretId=API_KEYS_SECRET_ID, SecretString=json.dumps(keys))


def _k8s_set_key(client_id: str, key: str) -> None:
    core.patch_namespaced_secret(API_KEYS_K8S_SECRET, GATEWAY_NAMESPACE, {"stringData": {client_id: key}})


def _k8s_remove_key(client_id: str) -> None:
    core.patch_namespaced_secret(
        API_KEYS_K8S_SECRET, GATEWAY_NAMESPACE, [{"op": "remove", "path": f"/data/{client_id}"}]
    )


@app.get("/api/clients")
async def clients(window: str = Query("1h")):
    if window not in WINDOWS:
        raise HTTPException(400, f"window must be one of {WINDOWS}")
    w = window
    limits = load_limits()
    tok_unit = {"Second": "1s", "Minute": "1m", "Hour": "1h", "Day": "24h"}.get(limits["tokens_unit"] or "", "1h")
    req_unit = {"Second": "1s", "Minute": "1m", "Hour": "1h", "Day": "24h"}.get(limits["requests_unit"] or "", "1m")
    q = perf_queries("gen_ai_client_id", w)
    # Usage against the rate-limit windows: the token rule charges input+output (TotalToken)
    q["tokens_limit_window"] = (
        f'sum by (gen_ai_client_id) (increase({TOK}{{gen_ai_token_type=~"input|output"}}[{tok_unit}]))'
    )
    q["requests_limit_window"] = f"sum by (gen_ai_client_id) (increase({REQ}[{req_unit}]))"
    q["requests_15m"] = f"sum by (gen_ai_client_id) (increase({REQ}[15m]))"
    q["models_used"] = f"sum by (gen_ai_client_id, gen_ai_original_model) (increase({REQ}[{w}]))"
    raw = await gather(q)

    flat = {k: by_label(v, "gen_ai_client_id") for k, v in raw.items() if k not in ("tokens_24h", "models_used")}
    toks = by_two(raw["tokens_24h"], "gen_ai_client_id", "gen_ai_token_type")
    used = by_two(raw["models_used"], "gen_ai_client_id", "gen_ai_original_model")

    ids = _k8s_client_ids()
    # clients present in metrics but no longer in the Secret (revoked) still show up, flagged
    for cid in flat["requests"]:
        if cid not in ids:
            ids.append(cid)
    rows = []
    for cid in ids:
        row = {"client_id": cid, "active_key": cid in _k8s_client_ids(), "protected": cid in PROTECTED_CLIENTS,
               **perf_row(flat, toks, cid)}
        row["tokens_limit_window"] = flat["tokens_limit_window"].get(cid, 0.0)
        row["requests_limit_window"] = flat["requests_limit_window"].get(cid, 0.0)
        row["requests_15m"] = flat["requests_15m"].get(cid, 0.0)
        # increase() yields 0 for every series that merely exists in the window; only count real traffic
        row["models_used"] = sorted(m for m, n in (used.get(cid) or {}).items() if n > 0.5)
        rows.append(row)
    rows.sort(key=lambda r: -(r["tokens_24h"]["input"] + r["tokens_24h"]["output"]))
    return {"window": w, "limits": limits, "clients": rows}


class ClientCreate(BaseModel):
    client_id: str


def _new_key() -> str:
    return "sk-aigw-" + secrets.token_hex(24)


@app.post("/api/clients")
async def create_client(req: ClientCreate):
    cid = req.client_id.strip()
    if not CLIENT_ID_RE.match(cid):
        raise HTTPException(400, "client_id: 2-63 chars, lowercase letters, digits, . _ -")
    keys = _sm_read()
    if cid in keys:
        raise HTTPException(409, f"client already exists: {cid}")
    key = _new_key()
    keys[cid] = key
    _sm_write(keys)  # Secrets Manager first: it is the source of truth deploy.sh re-syncs from
    _k8s_set_key(cid, key)
    return {"ok": True, "client_id": cid, "api_key": key}  # shown once; never retrievable from this UI again


@app.post("/api/clients/{client_id}/rotate")
async def rotate_client(client_id: str):
    keys = _sm_read()
    if client_id not in keys:
        raise HTTPException(404, f"client not found: {client_id}")
    key = _new_key()
    keys[client_id] = key
    _sm_write(keys)
    _k8s_set_key(client_id, key)
    return {"ok": True, "client_id": client_id, "api_key": key}


@app.delete("/api/clients/{client_id}")
async def revoke_client(client_id: str):
    if client_id in PROTECTED_CLIENTS:
        raise HTTPException(403, f"{client_id} is protected; rotate it instead")
    keys = _sm_read()
    if client_id not in keys:
        raise HTTPException(404, f"client not found: {client_id}")
    del keys[client_id]
    _sm_write(keys)
    try:
        _k8s_remove_key(client_id)
    except k8s.ApiException as e:
        if e.status not in (404, 422):
            raise
    return {"ok": True, "client_id": client_id}


@app.get("/")
async def index():
    return FileResponse(STATIC_DIR / "index.html")


def main():
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))


if __name__ == "__main__":
    main()
