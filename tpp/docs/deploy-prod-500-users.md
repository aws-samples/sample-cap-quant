# Deployment Runbook — prod (500 users)

This builds the 500-seat shape from [scaling-500-users.md](scaling-500-users.md): `infra/envs/prod` plus the `apps`
layer driven by `apps/envs/prod.tfvars`. It shares every Terraform module and every `.tf` file with dev; the
differences are variable values. Platform cost is on the order of $5,000–7,000 a month; the tokens flowing through it
cost ten to thirty times that.

**Out of scope here, and the item with the longest lead time:** Bedrock quota. 60 million tokens per minute is not
granted to one account in one Region. Cross-account sharding, adding us-east-2 and possibly Provisioned Throughput are
business conversations that take weeks; start them before this runbook, not after (scaling doc §3).

Read [deploy-dev-50-users.md](deploy-dev-50-users.md) first if you have never deployed TPP: this document only spells
out what differs.

## 0. Decisions and prerequisites (half a day, mostly waiting on other people)

| Decision | Default in code | Where to change |
|---|---|---|
| Same AWS account as dev? | Yes. Names are disjoint: cluster `tpp-prod`, VPC 10.81.0.0/16, secrets `tpp/prod/*`, ECR `tpp-prod/*`, IAM roles `tpp-prod-*` | `infra/envs/prod/variables.tf`, `apps/envs/prod.tfvars` (`secret_prefix`, `ecr_prefix`); a different account only needs a different AWS profile |
| LiteLLM image version | `ghcr.io/berriai/litellm:main-stable` — **a placeholder** | `apps/envs/prod.tfvars` → `litellm_image`. Pin a version tag. With PgBouncer the pods skip schema migrations; a floating tag can pull an image that expects a schema the migration Job never applied |
| Public hostname and certificate | Ingress disabled | `litellm_ingress` in prod.tfvars, step 7 |
| WAF | none | `litellm_ingress.wafv2_acl_arn` |
| Aurora / RDS / Redis instance classes | r7g.large ×2, m7g.large Multi-AZ, m7g.large + r7g.large | `infra/envs/prod/variables.tf` |

Tooling is the same as dev with one addition: Terraform **≥ 1.10 is mandatory** (`use_lockfile`, `optional()` object
attributes). Check `terraform version` before anything else.

Edit `infra/envs/prod/versions.tf`: replace `<aws account>` (or pass `-backend-config="bucket=..."` at init). The apps
backend is overridden at init time (step 3); `apps/providers.tf` derives the state bucket from the caller's account ID
automatically.

Bedrock model access must be enabled in us-west-2 and us-east-1 exactly as for dev; the channel registry
(`apps/values/scorer-channels.yaml`) is shared between environments.

## 1. State 1 — infrastructure (25–35 minutes)

```bash
cd infra/envs/prod
terraform init
terraform plan
```

The plan should contain, and you should recognize: a VPC with **three** NAT gateways; EKS `tpp-prod` with one managed
node group `system` (2–4 × m7i.large, label `tpp.io/pool=system`); Karpenter IAM roles, SQS queue and EventBridge
rules; an Aurora PostgreSQL cluster `tpp-prod-ledger` with two instances; an RDS instance `tpp-prod-langfuse`
(Multi-AZ); two ElastiCache replication groups `tpp-prod-router` and `tpp-prod-queue` (2 nodes each, TLS, AUTH) plus a
`noeviction` parameter group; two Secrets Manager secrets `tpp/prod/redis-router` and `tpp/prod/redis-queue`; the
Langfuse bucket; IRSA roles.

```bash
terraform apply
aws eks update-kubeconfig --name tpp-prod --region us-west-2
kubectl get nodes -L tpp.io/pool      # 3 Ready nodes, all labelled system
terraform output                      # confirm karpenter_iam_role_arn, redis_router_endpoint, langfuse_rds_address are non-empty
```

Those three outputs are how the apps layer detects the prod shape (`try(local.infra.<prod output>, <dev output>)`).

## 2. Scorer image with Redis TLS support (10 minutes, can run in parallel with step 1)

The Scorer in prod talks to the router Redis over TLS with an AUTH token. Build from a checkout that contains
`REDIS_SSL` / `REDIS_PASSWORD` handling in `services/scorer/scorer/config.py`, and push to the **prod** repository
name once step 3 pass 3 has created it — or create the ECR repositories first with a targeted apply:

```bash
cd apps
export TF_DATA_DIR=.terraform-prod
terraform init -backend-config="key=apps/prod/terraform.tfstate"
terraform apply -var-file=envs/prod.tfvars -target=aws_ecr_repository.scorer -target=aws_ecr_repository.dashboard

# prod runs in us-east-1, so its ECR registry is us-east-1 -- not the us-west-2 one dev uses
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.us-east-1.amazonaws.com
cd ../services/scorer
docker buildx build --platform linux/amd64 -t $ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/tpp-prod/scorer:0.2.0 --push .
cd ../dashboard
docker buildx build --platform linux/amd64 -t $ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/tpp-prod/dashboard:0.1.3 --push .
```

Set `scorer_image_tag = "0.2.0"` in `apps/envs/prod.tfvars` (the variable is declared in `apps/scorer.tf`).
`dashboard_image_tag` is `0.1.3`: 0.1.3 is the first image that renders the `TPP_ENV` header badge. Build and
push it **before** applying, or the dashboard Deployment rolls into `ImagePullBackOff`.

`TF_DATA_DIR=.terraform-prod` keeps the prod backend configuration and provider cache apart from the dev init in the
same directory. Export it in every shell that touches the prod apps state; forgetting it makes Terraform complain
about a changed backend, not silently use the wrong state.

## 3. State 2 — applications (30–45 minutes, three passes)

```bash
cd apps
export TF_DATA_DIR=.terraform-prod
terraform init -backend-config="key=apps/prod/terraform.tfstate"   # no-op if step 2 ran

# Pass 1: platform charts that ship CRDs
terraform apply -var-file=envs/prod.tfvars \
  -target=kubernetes_storage_class_v1.gp3 -target=helm_release.alb_controller \
  -target=helm_release.external_secrets -target=helm_release.kube_prometheus_stack \
  -target=helm_release.karpenter -target=helm_release.keda

# Pass 2: EC2NodeClass + the three NodePools
terraform apply -var-file=envs/prod.tfvars \
  -target=kubernetes_manifest.karpenter_node_class -target=kubernetes_manifest.karpenter_node_pool

# Pass 3: everything
terraform apply -var-file=envs/prod.tfvars
```

Why three passes: pass 1 installs the CRDs that passes 2 and 3 plan against (ClusterSecretStore, ServiceMonitor,
NodePool, ScaledObject). Pass 2 exists because every workload carries `nodeSelector tpp.io/pool=…`; without NodePools
they would stay Pending and the Deployment resources would time out waiting for rollout.

What to expect in pass 3, in order:

1. `kubernetes_job_v1.langfuse_db_bootstrap` connects to the `postgres` maintenance database on the Langfuse RDS instance and finds `langfuse` already present.
2. `kubernetes_deployment_v1.pgbouncer` comes up (2 replicas on the data-plane pool; Karpenter launches the first m7i nodes here).
3. `kubernetes_job_v1.litellm_migrate-<hash>` runs `litellm --skip_server_startup` against `DATABASE_URL_DIRECT` (the Aurora writer) and exits 0. **If it fails, the apply stops here; LiteLLM is never rolled with an unmigrated schema.**
4. `kubernetes_deployment_v1.litellm` rolls 4 replicas with `DISABLE_SCHEMA_UPDATE=true`, pooled `DATABASE_URL`, `REDIS_SSL=True`.
5. `helm_release.langfuse` (web 3, worker 4) on the observability pool; ClickHouse on the tainted clickhouse pool (an r7i node appears).
6. `kubernetes_manifest.litellm_scaled_object` creates the HPA through KEDA.

Known pull-time issue: the Karpenter chart comes from `oci://public.ecr.aws/karpenter`. A stale Helm registry login
to public ECR breaks the anonymous pull with 401/403; `helm registry logout public.ecr.aws` and re-run pass 1.

## 4. Verification (30 minutes)

Each check corresponds to an assumption about a third-party component that could not be verified without a live
cluster. Do them in this order; each later one depends on the earlier ones.

| # | Check | Command | Pass criterion |
|---|---|---|---|
| 1 | Schema migrated out of band | `kubectl -n litellm logs job -l app=litellm-migrate` | Prisma reports migrations applied; LiteLLM pods show no schema warnings |
| 2 | Cardinality control works | `kubectl -n litellm port-forward svc/litellm 24000:4000`, then `curl -s -H "Authorization: Bearer $MASTER_KEY" localhost:24000/metrics/ \| grep -c hashed_api_key` | `0`. Then confirm every family the Dashboard, Scorer and Grafana use is present: `litellm_deployment_total_requests_total`, `litellm_deployment_failure_responses_total`, `litellm_request_total_latency_metric_bucket`, `litellm_llm_api_time_to_first_token_metric_bucket`, `litellm_deployment_latency_per_output_token_bucket`, `litellm_spend_metric_total`, `litellm_input_tokens_metric_total`, `litellm_proxy_total_requests_metric_total`, `litellm_remaining_user_budget_metric`. A missing family means a name in `prometheus_metrics_config` does not match this LiteLLM version. |
| 3 | Scorer ↔ router Redis over TLS | `kubectl -n scorer logs deploy/scorer` | `managing 9 channels` and, after traffic, `weights updated`; no `AUTH` or SSL errors |
| 4 | Langfuse ↔ queue Redis over TLS | `kubectl -n langfuse logs deploy/langfuse-worker` | queue consumers start; no `NOAUTH` / TLS errors |
| 5 | Karpenter pools | `kubectl get nodepools; kubectl get nodes -L tpp.io/pool` | three pools; litellm/pgbouncer/scorer on data-plane, prometheus/langfuse on observability, clickhouse on clickhouse; nothing but controllers on system |
| 6 | KEDA | `kubectl -n litellm get scaledobject,hpa` | ScaledObject READY=True, ACTIVE reflects traffic; HPA shows the request-rate metric |
| 7 | PgBouncer actually pooling | `kubectl -n litellm exec deploy/pgbouncer -- psql -p 5432 -U tpp pgbouncer -c "SHOW POOLS;"` (password from Secret `litellm-env`) | `cl_active` far above `sv_active`; Aurora `DatabaseConnections` in CloudWatch stays near `replicas × DEFAULT_POOL_SIZE`, not `pods × 10` |
| 8 | End to end | smoke request through a tunnel, as in the dev runbook | Dashboard request count, Langfuse trace, Scorer log |

Then the standard dev checklist (pods Running, Dashboard lists 9 channels, Grafana panels, streaming request for TTFT).

## 5. Load test before onboarding (Phase 0 of the scaling plan)

Every capacity number in the scaling document is an estimate. Replay realistic agent traffic (long streaming turns,
tens of thousands of prompt tokens) and record:

- LiteLLM p99 end-to-end latency and the pod count KEDA settles on at 40 RPS (expect about 8; adjust `rps_per_replica` if the real stream duration differs from 35 s).
- Aurora `DatabaseConnections` and `CPUUtilization` with PgBouncer in front.
- Prometheus RSS (target: under 4Gi with the source-side label whitelist) and `prometheus_tsdb_head_series`.
- Queue Redis `used_memory` and Langfuse worker lag.
- ClickHouse disk growth per day, which decides when §7 of the scaling plan (sampling, TTL, clustering) becomes urgent.

Backfill the numbers in scaling-500-users.md §1 and §13.

## 6. Onboarding users

Same mechanics as dev (`/user/new` with `max_budget` and `budget_duration: 1d`), but at 500 seats do it from a script
that maps your IdP groups to users and teams, and set `rpm_limit` / `tpm_limit` per key so one batch job cannot drain the
Bedrock quota. The self-service key broker and OIDC in front of the Dashboard are Phase 3 items (scaling doc §9) and
are not in this repository yet; until then, the Dashboard stays tunnel-only and quota edits are an operator action.

## 7. Exposing the API (after ACM and DNS exist)

```hcl
# apps/envs/prod.tfvars
litellm_ingress = {
  enabled         = true
  hostname        = "llm.example.com"
  certificate_arn = "arn:aws:acm:us-west-2:<account>:certificate/<id>"
  wafv2_acl_arn   = ""   # optional
}
```

```bash
cd apps && export TF_DATA_DIR=.terraform-prod
terraform apply -var-file=envs/prod.tfvars
kubectl -n litellm get ingress litellm      # ADDRESS = ALB DNS name
```

Create a CNAME from the hostname to the ALB address. The ALB idle timeout is set to 600 s so long agent streams are
not cut; the health check is `/health/liveliness`. Only the LiteLLM API is exposed; Grafana, Langfuse, Prometheus and
the Dashboard remain tunnel-only until OIDC.

Client overlay files (`~/.claude/tpp-prod.settings.json`, Codex `tpp-prod` profile) then point at
`https://llm.example.com` instead of `http://localhost:24000`.

## 8. Operating differences from dev

| Topic | dev | prod |
|---|---|---|
| Changing LiteLLM replicas | edit `litellm_replicas` (then `kubectl scale`, the count is ignored after creation) | do not; KEDA owns it. Change `litellm_autoscaling` min/max or `rps_per_replica` |
| Upgrading LiteLLM | change the image, apply, pods migrate on startup | change `litellm_image` **and** bump `litellm_schema_revision`; the migration Job runs first, then the rollout |
| Scorer / Dashboard images | `tpp/scorer`, `tpp/dashboard` | `tpp-prod/scorer`, `tpp-prod/dashboard`; Scorer needs the TLS-capable build |
| Redis | one instance, no auth | router + queue, TLS + AUTH; tokens in `tpp/prod/redis-*`. Rotating a token = `terraform apply` in infra (new random), then Reloader restarts LiteLLM/Scorer/Langfuse when External Secrets re-syncs (≤ 5 min) |
| Database password rotation | RDS → ESO → Reloader (runbook.md) | identical, plus PgBouncer is restarted by Reloader too; Aurora rotates the ledger password, the Langfuse instance rotates its own |
| Metric labels | everything LiteLLM emits | whitelist in `litellm-config-prod.yaml`; adding a Grafana panel on a new family means adding it there first |
| Pausing after hours | nodes to 0, RDS stopped | not supported: Aurora, Multi-AZ RDS and HA Redis are meant to stay up |
| Alerts | 4 PrometheusRules | same rules; add CloudWatch alarms on Aurora connections/CPU and on the queue Redis memory (open item) |

## 9. Rollback

- **Apps layer:** every prod feature is a variable. Flipping `pgbouncer.enabled`, `keda.enabled` or `redis_tls_enabled`
  back to false and applying returns that component to the dev behaviour (for Redis, only if the ElastiCache group has
  TLS off, so in practice Redis TLS is not rolled back independently).
- **LiteLLM version:** set `litellm_image` to the previous tag, bump `litellm_schema_revision`, apply. Prisma `migrate deploy`
  does not roll schemas backward; a version whose migration dropped columns needs a database restore (Aurora backtrack
  or snapshot).
- **Infra layer:** Aurora and the Langfuse RDS have `deletion_protection = true`; a destroy requires flipping it in
  `infra/envs/prod/main.tf` and applying first. Destroy order is apps → infra, as for dev; empty the Langfuse bucket
  before destroying the infra state.

## 10. What this runbook does not cover (open items in scaling-500-users.md §15)

ClickHouse clustering, payload sampling and TTL/S3 tiering (§7); OIDC, the key broker and Dashboard authentication (§9);
daily billing export to S3/Athena (§5); the Scorer's quota-exhausted state and half-open breaker (§10); and all of the
Bedrock quota work (§3).
