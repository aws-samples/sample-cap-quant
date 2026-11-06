# aigw-dashboard

Ops dashboard for the Envoy AI Gateway, modelled on the TPP dashboard: one container = FastAPI aggregation backend
+ static single-page frontend, no storage of its own.

Shows:

1. **KPIs** — requests / errors in the window, tokens 24h, prompt-cache hit rate, in-flight streams, 4xx/5xx, clients;
2. **Gateway health** — Gateway programmed, Envoy pods ready, each AIServiceBackend accepted, rate-limit / Redis / controller;
3. **Clients** — one row per API key: requests, tokens 24h, usage against the per-client token and request limits
   (read from the BackendTrafficPolicy), models used, errors. **Create / rotate / revoke** keys here: Secrets Manager
   is written first (source of truth), then the `aigw-api-keys` Secret, which Envoy picks up within seconds;
4. **Models** — public name → Bedrock model, tokens by type, cache hit rate, health; 24h token bar chart;
5. **Model performance** — p50/p90/p99 TTFT / TPOT / E2E / TPS and errors, window 15m–7d.

Data: Prometheus (`gen_ai_*` from the extproc sidecar, `envoy_*`), Kubernetes API (AIGatewayRoute = model registry,
AIServiceBackend / Gateway status, BackendTrafficPolicy limits), the API-key Secret (client ids only).
No auth of its own: exposed only behind the ALB Cognito login (`dashboard.<host>`) or a kubectl tunnel.

## Local development

```bash
pip install -e .
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
PROMETHEUS_URL=http://localhost:9090 AWS_REGION=us-east-2 PORT=3020 dashboard   # uses your kubeconfig + AWS creds
```

## Build and deploy

`scripts/deploy.sh dashboard` builds `linux/amd64`, pushes to the ECR repo created by `apps/dashboard.tf`, and applies
`k8s/dashboard/`. Bump `version` in `pyproject.toml` and `DASHBOARD_TAG` in `scripts/deploy.sh` together.
