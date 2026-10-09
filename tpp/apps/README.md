# apps — In-cluster Application Layer

State 2: deploys in-cluster applications via the Terraform helm provider, depending on the infra state's outputs
(cluster endpoint, RDS endpoint, IRSA role ARNs, etc., read via terraform_remote_state).

Full runbooks: [docs/deploy-dev-50-users.md](../docs/deploy-dev-50-users.md) and
[docs/deploy-prod-500-users.md](../docs/deploy-prod-500-users.md). This file is the short reference.

One code base serves both environments. Every prod-only feature (PgBouncer, KEDA, Karpenter pools, Redis TLS,
ALB ingress, bigger Prometheus / ClickHouse) is behind a variable whose default is the dev behaviour; `envs/prod.tfvars`
turns them on. `terraform plan` with no var file must therefore always be a no-op for an existing dev deployment.

## dev

**The first deployment (or an environment rebuild) requires two apply passes** — the ClusterSecretStore CRD is installed
with the external-secrets chart, and the plan phase fails outright if the CRD does not exist:

```bash
terraform init
terraform apply -target=kubernetes_storage_class_v1.gp3 \
  -target=helm_release.alb_controller -target=helm_release.external_secrets \
  -target=helm_release.kube_prometheus_stack
terraform apply   # second full pass, adding ClusterSecretStore and other CRD resources
```

## prod (500 users, pairs with infra/envs/prod)

The backend key in `versions.tf` is the dev one; point prod at its own state at init time and always pass the var file:

```bash
terraform init -backend-config="key=apps/prod/terraform.tfstate"

# Pass 1: platform charts that ship CRDs (External Secrets, Prometheus Operator, Karpenter, KEDA)
terraform apply -var-file=envs/prod.tfvars \
  -target=kubernetes_storage_class_v1.gp3 -target=helm_release.alb_controller \
  -target=helm_release.external_secrets -target=helm_release.kube_prometheus_stack \
  -target=helm_release.karpenter -target=helm_release.keda

# Pass 2: node pools, so workloads with nodeSelector tpp.io/pool=... have somewhere to land
terraform apply -var-file=envs/prod.tfvars \
  -target=kubernetes_manifest.karpenter_node_class -target=kubernetes_manifest.karpenter_node_pool

# Pass 3: everything
terraform apply -var-file=envs/prod.tfvars
```

What prod.tfvars changes, and where it is implemented:

| Concern | Variable(s) | File |
|---|---|---|
| Separate secret / ECR names when dev and prod share an account | `secret_prefix`, `ecr_prefix` | litellm.tf, langfuse.tf, scorer.tf, tpp-dashboard.tf |
| LiteLLM sizing: 1 vCPU / 4Gi per pod, 4 replicas, PDB 2 | `litellm_resources`, `litellm_replicas`, `litellm_pdb_min_available` | litellm.tf |
| LiteLLM autoscaling 4 → 20 on request rate (KEDA + Prometheus) | `keda`, `litellm_autoscaling` | platform.tf, litellm.tf |
| PgBouncer + out-of-band schema migration Job | `pgbouncer`, `litellm_image`, `litellm_schema_revision` | pgbouncer.tf, litellm.tf |
| Metric cardinality control at the source | `litellm_config_file` → values/litellm-config-prod.yaml | litellm.tf |
| Redis TLS + AUTH for LiteLLM, Scorer, Langfuse | `redis_tls_enabled` | litellm.tf, scorer.tf, langfuse.tf, values/langfuse-values.yaml.tftpl |
| Karpenter controller + data-plane / observability / clickhouse pools | `karpenter`, `node_selectors`, `clickhouse_tolerations` | karpenter.tf and every Deployment |
| Prometheus 30d / 200Gi / 8Gi on the observability pool | `prometheus_values_file` → values/kube-prometheus-stack-prod.yaml | platform.tf |
| ClickHouse 500Gi / 4 vCPU / 16Gi on the tainted pool | `clickhouse` | langfuse.tf |
| Langfuse web 3 / worker 4 | `langfuse` | langfuse.tf |
| Internet-facing ALB for the LiteLLM API | `litellm_ingress` (off until ACM + hostname exist) | litellm.tf |

Checks to run after the first prod apply, in this order (each is an assumption the code makes about a third-party component):

1. `kubectl -n litellm logs job/litellm-migrate-...` ends with the Prisma migrations applied; LiteLLM pods log no schema warnings (`DISABLE_SCHEMA_UPDATE=true`).
2. `curl -H "Authorization: Bearer $MASTER_KEY" https://.../metrics/ | grep -c hashed_api_key` returns 0, and every metric the Dashboard and the Scorer query is present (`prometheus_metrics_config` only exports what it lists).
3. Scorer log shows `weights updated`: it reached the router Redis over TLS with the AUTH token.
4. Langfuse worker logs show the ingestion queue draining: it reached the queue Redis over TLS with the AUTH token (`redis.tls` / `redis.auth.existingSecret` in the chart values).
5. `kubectl get nodepools` shows the three pools and `kubectl get nodes -L tpp.io/pool` shows workloads on Karpenter nodes, not on the system group.
6. `kubectl -n litellm get scaledobject litellm` is Ready and `kubectl -n litellm get hpa` shows the current request rate.
7. Pin `litellm_image` to the digest or version tag you validated; with `main-stable` floating, a new image could expect a schema the migration Job never applied.

## Files

- platform.tf — gp3 StorageClass, aws-load-balancer-controller, external-secrets, reloader, kube-prometheus-stack, KEDA (prod)
- karpenter.tf — Karpenter controller, EC2NodeClass, three NodePools (prod)
- litellm.tf — LiteLLM Proxy: Secrets, Deployment, PDB, ServiceMonitor, KEDA ScaledObject (prod), ALB Ingress (prod)
- pgbouncer.tf — PgBouncer Deployment/Service/PDB and the LiteLLM schema migration Job (prod)
- langfuse.tf — Langfuse chart, ClickHouse StatefulSet, bootstrap Job, Redis AUTH ExternalSecret (prod)
- scorer.tf / tpp-dashboard.tf — in-house Scorer and Dashboard
- dashboards.tf — Grafana TPP Overview dashboard + PrometheusRule alerts
- envs/prod.tfvars — the 500-user shape
