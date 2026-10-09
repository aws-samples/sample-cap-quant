# infra — Terraform Infrastructure

State 1: VPC / EKS / RDS or Aurora / ElastiCache / S3 / IRSA. Module responsibilities are described in docs/architecture.md §2.

Prerequisites:
- Create the versioned S3 bucket for state (one-time; Terraform ≥ 1.10 uses S3 native locking, no DynamoDB table)
- Decide on the region (a tfvars variable; us-west-2 recommended: good Bedrock Claude model availability)
- Decide on the VPC CIDR (dev 10.80.0.0/16, prod 10.81.0.0/16; avoid conflicts with corporate address space)

Full runbooks: [docs/deploy-dev-50-users.md](../docs/deploy-dev-50-users.md) and
[docs/deploy-prod-500-users.md](../docs/deploy-prod-500-users.md).

## Environments

| | envs/dev | envs/prod (500 users) |
|---|---|---|
| NAT | single gateway | one per AZ |
| EKS nodes | one managed group, 3 × m7i.large | `system` managed group (2–4 × m7i.large) + Karpenter IAM; workload pools are NodePools in apps/karpenter.tf |
| Ledger | RDS PostgreSQL db.t4g.medium, single AZ, shared with langfuse | Aurora PostgreSQL writer + reader (db.r7g.large), deletion protection |
| Langfuse metadata | same instance as the ledger | own RDS instance db.m7g.large, Multi-AZ |
| Redis | one cache.t4g.micro, no TLS/AUTH | router (cache.m7g.large) + queue (cache.r7g.large, noeviction), each primary + replica, TLS + AUTH |
| Secrets | `tpp/*` | `tpp/prod/*` (Redis AUTH tokens are written here for the apps layer) |

Both compositions use the same modules; prod-only inputs (`node_groups`, `enable_karpenter`, `auth_token`, `db_name`, …)
default to the dev behaviour, so `envs/dev` plans unchanged.

Usage:
```bash
cd envs/dev  && terraform init && terraform plan
cd envs/prod && terraform init && terraform plan   # backend key infra/prod/terraform.tfstate
```

Bedrock quota (cross-account sharding, extra Regions, Provisioned Throughput) is deliberately not modeled here;
see docs/scaling-500-users.md §3.
