# tpp-dashboard

TPP standalone ops dashboard (M7): a single container = FastAPI aggregation backend + pure static single-page frontend.

Displays:

1. **User quotas** (USD/day, `budget_duration=1d`) -- editable directly on the page,
   written back via LiteLLM `/user/update`;
2. **Channel spend / health / weight** -- 9 region x model channels (last-24h spend
   and tokens, `scorer_quality_score`, `scorer_weight`, circuit breaker status and
   `litellm_deployment_state`);
3. **Channel stability and performance** -- p50/p90/p99 for TTFT / TPOT / E2E / TPS
   plus error breakdown by class, with a selectable stat window (15m/1h/6h/24h/7d);
   TPS is derived from TPOT histogram quantiles (1/TPOT);
4. Jump links to the 4 existing dashboards (LiteLLM / Grafana / Langfuse / Prometheus).

Data sources: Prometheus (`litellm_*` / `scorer_*` metrics, per-channel granularity
via the `model_id` label) and the LiteLLM Management API (master key injected via
ExternalSecret, held server-side only).
Same security model as Prometheus: no auth of its own, no Ingress exposure, accessed
only via kubectl tunnel (local port convention 3020, see `scripts/tpp-tunnels.sh`).

## Local development

```bash
pip install -e .
PROMETHEUS_URL=http://localhost:9090 \
LITELLM_URL=http://localhost:14000 \
LITELLM_MASTER_KEY=$(cd ../../apps && terraform output -raw litellm_master_key) \
CHANNELS_FILE=../../apps/values/scorer-channels.yaml \
PORT=3020 dashboard
```

## Building the image

```bash
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin <aws account>.dkr.ecr.us-west-2.amazonaws.com
docker buildx build --platform linux/amd64 \
  -t <aws account>.dkr.ecr.us-west-2.amazonaws.com/tpp/dashboard:0.1.0 --push .
```

For deployment see `apps/tpp-dashboard.tf` (when bumping the version, also update `var.dashboard_image_tag`).
