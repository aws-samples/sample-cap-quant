# Deployment Runbook — dev (about 50 heavy users)

This is the environment the rest of the documentation describes: `infra/envs/dev` plus the `apps` layer with default
variables. It carries roughly 50 heavy Claude Code / Codex CLI users, costs about $400–450 a month always-on, and exposes
nothing to the internet (access is through `kubectl port-forward` tunnels).

For the 500-user shape see [deploy-prod-500-users.md](deploy-prod-500-users.md). For day-two operations (users, quotas,
Scorer tuning, alerts, RDS rotation) see [runbook.md](runbook.md).

## 0. Prerequisites (15 minutes)

| Item | Requirement | Check |
|---|---|---|
| Tools | Terraform ≥ 1.10, AWS CLI v2, kubectl, Docker with buildx | `terraform version`, `aws --version`, `kubectl version --client`, `docker buildx version` |
| AWS credentials | Administrator-equivalent in the target account | `aws sts get-caller-identity` |
| Region | us-west-2 (default); the channel registry also uses us-east-1 | — |
| Bedrock model access | Anthropic Claude models enabled in **both** us-west-2 and us-east-1; the Mantle OpenAI model (`openai.gpt-5.6-terra`) in us-west-2 if Codex CLI is used | Bedrock console → Model access, or `aws bedrock get-foundation-model-availability` |
| VPC CIDR | 10.80.0.0/16 must not collide with corporate address space; change `infra/envs/dev/variables.tf` if it does | — |

Decide the AWS account ID now; it appears in three backend blocks below.

## 1. Bootstrap the Terraform state bucket (one-time, 2 minutes)

Both states share one versioned S3 bucket. Terraform ≥ 1.10 uses S3 native locking, so no DynamoDB table.

```bash
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws s3api create-bucket --bucket tpp-tfstate-$ACCOUNT --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2
aws s3api put-bucket-versioning --bucket tpp-tfstate-$ACCOUNT \
  --versioning-configuration Status=Enabled
```

Replace `<aws account>` with the account ID in:

- `infra/envs/dev/versions.tf`
- `apps/versions.tf`

Or leave the files alone and pass `-backend-config="bucket=tpp-tfstate-$ACCOUNT"` to every `terraform init`.
The `terraform_remote_state` block in `apps/providers.tf` derives the bucket from the caller's account ID
automatically — no edit needed there.

## 2. Optional: validate the LiteLLM wiring locally first (10 minutes)

The docker-compose stack runs the same LiteLLM configuration on a laptop and catches config mistakes before any AWS
resource exists.

```bash
cd local
cp .env.example .env            # one channel API key is enough
docker compose up -d            # LiteLLM + Postgres + Redis + Prometheus + Grafana
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-5","messages":[{"role":"user","content":"hello"}]}'
docker compose down
```

## 3. State 1 — infrastructure (about 20 minutes)

```bash
cd infra/envs/dev
terraform init
terraform plan                  # expect: VPC, EKS cluster tpp-dev, RDS, ElastiCache, S3 bucket, IRSA roles
terraform apply
aws eks update-kubeconfig --name tpp-dev --region us-west-2
kubectl get nodes               # 3 Ready nodes
```

What exists afterwards: VPC with one NAT gateway and an S3 gateway endpoint; EKS 1.33 with one managed node group
(3 × m7i.large); RDS PostgreSQL db.t4g.medium with a Secrets-Manager-managed master password; one ElastiCache Redis
node (no TLS); the Langfuse events bucket; IRSA roles for LiteLLM (Bedrock), Langfuse (S3), External Secrets
(Secrets Manager) and the ALB controller.

## 4. State 2 — in-cluster applications (about 20 minutes, two passes)

The first apply **must** be split: CRDs (ClusterSecretStore, ServiceMonitor, …) are installed by charts in pass 1, and
the resources that use them cannot even be planned before that.

```bash
cd apps
terraform init

# Pass 1: platform charts
terraform apply -target=kubernetes_storage_class_v1.gp3 \
  -target=helm_release.alb_controller -target=helm_release.external_secrets \
  -target=helm_release.kube_prometheus_stack

# Pass 2: everything else (LiteLLM, Langfuse + ClickHouse, Scorer, Dashboard, Grafana dashboard, alerts)
terraform apply
```

Expected during pass 2:

- `kubernetes_job_v1.langfuse_db_bootstrap` runs to completion (creates the `langfuse` database on the shared RDS instance).
- `helm_release.langfuse` takes several minutes (ClickHouse migrations).
- Scorer and Dashboard pods sit in `ImagePullBackOff`. That is expected until step 5.

No Secret is created by hand: the apply writes the LiteLLM master key (`tpp/litellm`) and the Langfuse bootstrap
credentials (`tpp/langfuse`) to Secrets Manager, and External Secrets syncs them into the cluster.

## 5. Build and push the in-house images (10 minutes, first time only)

```bash
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.us-west-2.amazonaws.com

cd services/scorer
docker buildx build --platform linux/amd64 \
  -t $ACCOUNT.dkr.ecr.us-west-2.amazonaws.com/tpp/scorer:0.1.0 --push .
kubectl rollout restart deploy/scorer -n scorer

cd ../dashboard
docker buildx build --platform linux/amd64 \
  -t $ACCOUNT.dkr.ecr.us-west-2.amazonaws.com/tpp/dashboard:0.1.2 --push .
kubectl rollout restart deploy/dashboard -n dashboard
```

The tags must match `scorer_image_tag` (apps/scorer.tf) and `dashboard_image_tag` (apps/tpp-dashboard.tf).
To ship a new image later: push a new tag, change the variable, `terraform apply`.

On startup the Scorer registers the nine channels from `apps/values/scorer-channels.yaml` into the LiteLLM database
through `/model/new`. Watch for it:

```bash
kubectl logs -n scorer deploy/scorer | grep -E "managing|registered|weights"
```

## 6. Access and smoke test (5 minutes)

```bash
./scripts/tpp-tunnels.sh        # LiteLLM :14000, Grafana :3000, Langfuse :3010, Prometheus :9090, Dashboard :3020
export MASTER_KEY=$(cd apps && terraform output -raw litellm_master_key)
curl http://localhost:14000/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-5","messages":[{"role":"user","content":"hello"}]}'
```

Verification checklist, in order:

1. `kubectl get pods -A` — every pod in litellm, langfuse, scorer, dashboard, monitoring is Running.
2. TPP Dashboard (http://localhost:3020) lists all 9 channels; the channel that served the smoke request shows a non-zero request count.
3. Grafana (http://localhost:3000, admin / `terraform output -raw grafana_admin_password`) → TPP Overview shows request metrics.
4. Langfuse (http://localhost:3010, admin@tpp.local / `terraform output -raw langfuse_admin_password`) shows the trace.
5. Once traffic flows, `kubectl logs -n scorer deploy/scorer` prints `weights updated`.
6. Send one **streaming** request: TTFT panels are only populated by streaming calls (non-streaming smoke tests leave them empty by design).

## 7. First users (5 minutes)

Never hand out the master key. Each person or machine gets a user with a USD-per-day budget:

```bash
curl -s http://localhost:14000/user/new -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"alice","max_budget":20.0,"budget_duration":"1d"}'
```

The response contains the user's key. A full Claude Fable 5 exchange in Claude Code costs about $0.40, so $20/day
is a light-use quota and $100/day is a heavy developer's. Client setup (`claude-tpp` alias, `codex --profile tpp`)
is in [runbook.md → Connecting Your Laptop](runbook.md#connecting-your-laptop-to-tpp-for-claude).

## 8. Cost control

Always-on: about $400–450/month. After hours:

```bash
# stop: nodes to 0, RDS stopped (ElastiCache and the EKS control plane cannot be stopped; ~$85/month floor)
cd infra/envs/dev && terraform apply -var node_desired_size=0
aws rds stop-db-instance --db-instance-identifier tpp-dev --region us-west-2
# start
aws rds start-db-instance --db-instance-identifier tpp-dev --region us-west-2
cd infra/envs/dev && terraform apply -var node_desired_size=3
```

RDS auto-restarts a stopped instance after seven days.

## 9. Things that bite on first deployment

| Symptom | Cause | Fix |
|---|---|---|
| Pass 2 plan fails with "no matches for kind ClusterSecretStore" | Pass 1 skipped or incomplete | Re-run pass 1 with the targets above |
| Langfuse pods crash with `P1013 invalid port number` | Raw RDS password used in a URL | Already handled by the ExternalSecret template (`urlquery`); check the `langfuse-postgres` Secret exists |
| Scorer `401` from the Management API, `TPPScorerStale` fires | Master key rotated, External Secrets not yet re-synced (5 min) | Wait one refresh interval or `kubectl rollout restart deploy/scorer -n scorer` |
| PATCH weight "succeeds" but nothing changes | Channel defined in LiteLLM's static `model_list` | Keep `model_list: []`; channels live only in `scorer-channels.yaml` |
| Dashboard quota edit says `user not found` | Dashboard only updates existing users | Create the user with `/user/new` first |
| Tunnel listens but every request times out | Zombie port-forward after laptop sleep | `./scripts/tpp-tunnels.sh` again; the script probes health every 15 s and reconnects |

## 10. Tear down

```bash
cd apps && terraform destroy
cd ../infra/envs/dev && terraform destroy
aws s3 rm s3://tpp-dev-langfuse-$ACCOUNT --recursive && aws s3 rb s3://tpp-dev-langfuse-$ACCOUNT
# optional: the state bucket, once both states are gone
```

The ECR repositories are removed with the apps state. Secrets Manager secrets (`tpp/litellm`, `tpp/langfuse`) are
scheduled for deletion with a recovery window; the RDS-managed master secret disappears with the instance.
