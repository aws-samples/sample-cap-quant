# TPP Architecture Adjustment Plan for 500 Users

The current architecture (`docs/architecture.md`) is deployed at dev spec and comfortably supports about 50 heavy users.
Onboarding 500 people requires **three implementation swaps** (ClickHouse, Redis topology, ingress-layer identity),
**one item resolved via AWS business channels** (Bedrock quota), and the rest is scaling up and filling gaps.

> All capacity numbers in this document are order-of-magnitude estimates based on the current Terraform/values configuration, **not load-test results**.
> Real values should be backfilled after the Phase 0 load test is complete.

## 1. Design Targets

The load from 500 seats depends on the user mix; we take two models:

```text
Mixed population (closer to a real internal platform)
  Heavy 15% =  75 users × 800 req/day × 20M tok/day
  Medium 50% = 250 users × 200 req/day ×  5M tok/day
  Light 35% = 175 users ×  40 req/day ×  1M tok/day
  → 117k req/day, 2.9B tok/day, peak ~12 RPS, average ~6M TPM

All-heavy (upper bound)
  500 users × 800 req/day × 20M tok/day
  → 400k req/day, 10B tok/day, peak ~42 RPS, average ~21M TPM
```

The real pressure on the data plane is the number of concurrent streams, not RPS:

```text
in_flight = peak_rps × avg_stream_seconds
          = 42 × 35s ≈ 1470
```

**Design targets (at the upper bound; the mixed population leaves 3× headroom):**

| Metric | Target |
|---|---|
| Sustained / peak RPS | 40 / 60 |
| Concurrent streams | 2000 |
| Request volume | 400k/day |
| Peak TPM | 60M |

## 2. Change Overview

| Layer | Current state | Target for 500 users | Nature of change |
|---|---|---|---|
| Quota layer | 2 regions × single account | N accounts × 3-region sharding | **Business + new** |
| Ingress layer | ClusterIP + kubectl tunnel | ALB + OIDC + self-service key issuance | **New build** |
| Data plane | LiteLLM 2 replicas, single process | HPA 4→20 + PgBouncer | Scaling out + gap filling |
| Ledger | db.t4g.medium single instance, two databases | Aurora PG + database separation + retention policy | Spec change + split |
| Cache/queue | One shared cache.t4g.micro | Split into two, both HA + TLS | **Split and rebuild** |
| Trace storage | ClickHouse single pod 50Gi | Clustering + sampling + TTL | **Implementation swap** |
| Metrics | Prometheus 2Gi, all labels | Cardinality reduction + dedicated node | Config + scaling up |
| Weight tuning | Scorer single replica | Keep single replica, add quota awareness | Minor change |
| Nodes | 3×m7i.large, no autoscaling | 3 node groups + Karpenter | Restructure |

## 3. Bedrock Quota Sharding

**The only piece engineering cannot solve; lead time is weeks, so it must start first.**

Key mechanism: the `us.anthropic.*` prefix is itself a cross-region inference profile — inference spreads across
us-east-1 / us-east-2 / us-west-2, **but quota is charged to the account bucket of the calling region**.

```text
quota_buckets = num_accounts × num_calling_regions
```

- Current state (`apps/values/scorer-channels.yaml`): 2 calling regions → 2 buckets
- Add us-east-2 → 3 buckets
- 60M TPM peak: getting 20M TPM for a single account in a single region already requires negotiating with the AWS account team,
  so **cross-account sharding** is essentially inevitable (M accounts × 3 regions = 3M buckets with mutually independent quotas)
- Optional: Provisioned Throughput to cover baseline load, with bursts on on-demand

Implementation points:

| Item | Change |
|---|---|
| Channel registry | Grow from 9 entries to the order of `num_accounts × 3 regions × num_models` |
| IAM | Add `sts:AssumeRole` to the LiteLLM IRSA; attach a cross-account role per channel |
| Draining exhausted buckets | Reuse the Scorer's existing dynamic weight-tuning mechanism (see §10) |

## 4. Data Plane (LiteLLM)

- **Keep 1 uvicorn worker per pod and scale out by adding pods**; do not use `--num_workers`:
  multiple workers duplicate Python memory, and HPA granularity gets coarser
- Specs: `cpu req 1 / limit 2`, `mem req 1Gi / limit 3Gi`
- A single pod safely carries ~150–200 concurrent streams → `2000 / 175 ≈ 12` pods at peak, **HPA 4 → 20**
- **Do not use CPU metrics for HPA**: streaming forwarding is I/O-bound and CPU lags real pressure.
  Use **KEDA + Prometheus scaler**, scaling on the `litellm_proxy_total_requests` rate or in-flight request count
  (kube-prometheus-stack is already in place; KEDA is the minimal increment)
- Add PodDisruptionBudget + `topologySpreadConstraints` across 3 AZs

## 5. Ledger Layer (RDS)

**PgBouncer is a prerequisite for scaling out replicas.** Prisma opens an independent connection pool per pod;
20 pods × default pool size ≈ 200–340 connections, while db.t4g.medium's max connections is only ~340
— without a connection pooler, scaling LiteLLM replicas immediately saturates RDS connections.

| Item | Change |
|---|---|
| Connection pool | PgBouncer (transaction mode) or RDS Proxy; add `pgbouncer=true` to `DATABASE_URL` |
| Database separation | Split the litellm ledger and langfuse metadata into two instances (currently crammed into the same t4g.medium) |
| Ledger instance | Aurora PostgreSQL, writer `db.r7g.large` + 1 reader, Multi-AZ |
| High availability | Flip `multi_az` / `deletion_protection` in `infra/envs/dev/main.tf:36-40` to true |
| Retention policy | Set `maximum_spend_logs_retention_period` to 30–90d |
| Long-term billing | Daily aggregation ETL to S3 + Athena |

Rationale for Aurora: every request writes one SpendLog row and batch-updates the spend rows of key/user/team
— highly concurrent requests on the same key contend for locks on the same row. Aurora provides reader offloading, second-level failover, and automatic storage scaling.

At 400k requests/day, SpendLogs is an unbounded-growth table; a retention policy is a requirement, not an optimization.

## 6. Cache/Queue (Redis)

The current `cache.t4g.micro` (0.5 GiB) holds both LiteLLM router state and the Langfuse ingestion queue.
**Danger point: queue eviction silently loses trace data without erroring.** It must be split into two.

### A. Router / Rate Limiting Redis

`cache.m7g.large`, primary/replica + automatic failover.

This one carries per-key rpm/tpm rate limiting and is a **hard dependency on the request path** —
if it goes down, either rate limiting fails site-wide or the whole site returns 5xx; HA cannot be skipped.

### B. Langfuse Ingestion Queue Redis

Sized by the tolerated worker lag:

```text
queue_bytes = peak_rps × event_kb × tolerated_lag_seconds
            = 40 × 120KB × 300s ≈ 1.4 GB
```

Take `cache.r7g.large` (13 GiB) to leave ample headroom.

Both need **TLS + AUTH** enabled
(`apps/values/langfuse-values.yaml.tftpl` currently has `auth.enabled: false`; the comment notes the dev trade-off).

## 7. Trace Storage (ClickHouse)

Single pod / single replica / 50Gi / no TTL cannot hold up under 500 users no matter how much the volume is expanded,
and if the pod dies, trace observability halts outright.

### 7.1 Sampling First — About 5× More Effective Than Scaling Up

```text
Full payload: 400k req/day → ~12 GB/day (compressed)
metadata 100% + payload 20% sampling → 3–4 GB/day → ~320 GB over 90 days
```

Quality analysis does not need 100% capture of full 50k-token prompts.

### 7.2 Clustering

| Option | Notes |
|---|---|
| Altinity ClickHouse Operator | 3 shards × 2 replicas + ClickHouse Keeper; **`cluster.enabled` in `apps/values/langfuse-values.yaml.tftpl` must be flipped to true**, otherwise Langfuse migrations will not use ReplicatedMergeTree |
| ClickHouse Cloud | Least operational burden, but data leaves the self-owned account; compliance needs assessment |

### 7.3 Others

- ClickHouse TTL (90d) + S3 cold tiering (attach an S3 disk via `storage_policy`);
  Langfuse blobs already land in S3, so that part of the design needs no change
- Langfuse web 3 replicas; worker 4–6 replicas + **KEDA scaling on Redis queue depth**
  (the current values do not set replicas and use chart defaults)

## 8. Metrics Layer (Prometheus)

**500 users amounts to a cardinality attack on Prometheus.** LiteLLM metrics carry per-user labels such as
`hashed_api_key` / `api_key_alias` / `end_user`;
`500 keys × 9+ channels × a dozen metric families` → millions of series; 2Gi is certain death.

Prescription: add `metricRelabelConfigs` to the ServiceMonitor at `apps/litellm.tf:270`,
**labeldrop the per-key / per-user labels and keep only `model_id`, `requested_model`,
`exception_class`, `le`** — these four are exactly the only labels `services/scorer/scorer/prom.py`
and tpp-dashboard depend on. Per-user attribution should be looked up in the RDS ledger and Langfuse, not stored in the time-series database.

After cardinality reduction: Prometheus on a dedicated node, 8Gi, 200Gi volume, 30d retention.
**Retention must not go below 7d** — the dashboard's statistics window whitelist includes `7d`.

## 9. Ingress Layer and Identity

The most underestimated workload at 500-user scale. The current state is ClusterIP + kubectl tunnel +
operators manually editing quotas on the dashboard; that path does not scale.

| Item | Notes |
|---|---|
| Edge | ALB + ACM + Route53 + WAF (the LB controller at `apps/platform.tf:17` is already installed) |
| Identity | OIDC (Okta/Entra) → a key broker calls LiteLLM `/key/generate`, mapping IdP groups to team + `max_budget` + `budget_duration` + `rpm_limit`/`tpm_limit` |
| Self-service | Reuse tpp-dashboard's existing `/user/update` write-back capability, expanding from "operators edit by hand" to "user self-service + team admin approval"; no rewrite needed |
| Per-key rate limiting | **Hard requirement**: without it, a single user running batch jobs can consume the entire company's Bedrock quota; it depends on the router Redis, which loops back to the HA requirement in §6.A |
| Dashboard's own authentication | Currently unauthenticated; the security model rests on "no exposed Ingress" (`apps/tpp-dashboard.tf:4`); once behind ALB that premise fails and OIDC must be added |

## 10. Weight Tuning Layer (Scorer)

Single replica, not on the request path, and an outage only freezes weights — this design still holds at 500 users,
and it **must remain a single replica** (multiple replicas would conflict on concurrent weight writes). Two changes are needed:

1. **The cost of `w_floor = 0.05`**: a channel whose quota is exhausted still keeps a 5% traffic floor,
   which at 40 RPS means a steady 2 RPS of 429s. Recommend adding a "quota exhausted" state that
   presses the channel's floor down to 0.005 or temporarily to 0 when the `RateLimitError` share stays persistently high.
2. **Distinguish throttling from failure**: `RateLimitError` has severity 1.5 and is not in `SEVERE_CLASSES`,
   so throttling never trips the circuit breaker and only adjusts weight — correct with 2 channels,
   but under the N accounts × 3 regions multi-bucket topology, the system needs to clearly express the difference between
   "this bucket is maxed out for today" and "this channel is broken".

## 11. Node Topology

Split into 3 node groups, and **Karpenter or cluster-autoscaler must be added**
— there is currently no node autoscaling at all; `node_max_size = 5` is just a hard ceiling.

| Node group | Instances | Purpose |
|---|---|---|
| data-plane | m7i.xlarge × 3–8, 3 AZs, on-demand | LiteLLM + Scorer, latency-sensitive |
| observability | m7i.2xlarge × 2 | Prometheus / Grafana / Langfuse web+worker |
| clickhouse | r7i.2xlarge × 3, taint-dedicated | ClickHouse (memory-intensive) |

Also: `single_nat_gateway = true` (`infra/envs/dev/main.tf:17`) needs to change to one per AZ,
otherwise a single-AZ NAT failure takes down egress for the entire site.

## 12. Rollout Order

The order is determined by dependencies, not importance.

### Phase 0 — Start Immediately (Longest Lead Time)

- Bedrock quota increase request + finalize the cross-account sharding plan
- Load-test with real traffic to get baselines: LiteLLM p99, RDS `CPUCreditBalance`,
  Redis `used_memory`, ClickHouse disk growth rate
- Backfill all estimates in this document after the load test completes

### Phase 1 — Remove Hard Blockers to Scaling Out (Order Cannot Be Reversed)

```text
PgBouncer → split Redis into two → Prometheus cardinality reduction → Karpenter → LiteLLM HPA
```

Two hard dependencies:

- PgBouncer must come before HPA, otherwise scaling out replicas immediately saturates RDS connections
- Prometheus cardinality reduction must land before user volume ramps up, otherwise a Prometheus outage would blind
  the Scorer and the dashboard simultaneously

### Phase 2 — Observability Restructure

```text
Langfuse sampling → ClickHouse clustering + TTL + S3 tiering → Langfuse worker KEDA scaling
```

Do sampling first: lowest cost, biggest payoff.

### Phase 3 — Ingress Governance

```text
ALB + ACM + WAF → OIDC → self-service key broker → per-key rate limiting → dashboard authentication
```

## 13. Cost Magnitude and Core Judgment

Rough monthly cost estimate on the platform side (excluding tokens):

| Item | Estimate |
|---|---|
| Aurora two instances + langfuse RDS | ~$700 |
| Two Redis sets incl. replicas | ~$600 |
| EKS nodes | ~$3,000–4,500 |
| Storage / NAT / ALB / S3 | ~$500 |
| **Total** | **~$5–7k/month** |

Meanwhile, the Bedrock cost of 2.9B tokens/day, even estimated at a blended unit price after heavy cache discounts,
is on the order of **$40k–170k/month**.

> **The most important conclusion of this plan: platform infrastructure cost is a rounding error relative to token cost (1–2 orders of magnitude apart).**
> Do not sacrifice HA to save platform money — the few hundred dollars saved by a single-point ClickHouse, shared Redis, or single-AZ RDS
> is far outweighed by one outage that idles 500 people and loses billing data.
>
> The cost-saving directions truly worth engineering investment are **raising the prompt cache hit rate** and
> **routing requests to cheaper models** — those are the levers worth tens of thousands of dollars.

## 14. Open Items

| Item | Decision needed |
|---|---|
| Bedrock cross-account sharding | Number of accounts, account ownership, and billing entity |
| ClickHouse managed vs self-hosted | Whether data leaving the account crosses a compliance red line |
| OIDC provider | Okta / Entra / other |
| Domain and certificates | External domain, ACM certificate ownership |
| SpendLogs retention | 30d / 90d, and whether long-term billing needs Athena queries |
| Langfuse sampling rate | Whether 20% payload sampling satisfies quality analysis needs |
