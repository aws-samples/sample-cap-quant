# TPP Architecture Design

LiteLLM + Langfuse + self-hosted kube-prometheus-stack + RDS/ElastiCache,
deployed on EKS, with Terraform managing infrastructure + Helm managing applications.

## 1. Architecture Diagram

![TPP architecture diagram](architecture-diagram.png)

Vector version [`architecture-diagram.svg`](architecture-diagram.svg); editable source [`architecture-diagram.html`](architecture-diagram.html)
(light theme, with built-in PNG / PDF export). To change the diagram, edit `architecture-diagram.gen.py` and regenerate.


## 2. Terraform Layout

```
infra/                          # state 1: infrastructure (changes infrequently)
├── envs/{dev,prod}/            # composition layer: main.tf / backend.tf / terraform.tfvars
└── modules/
    ├── network/                # VPC, public/private subnets, NAT, VPC Endpoints (S3/ECR/Bedrock)
    ├── eks/                    # cluster, managed node groups, IRSA OIDC, core addons
    ├── rds/                    # PostgreSQL: litellm + langfuse databases (single instance in dev, splittable in prod)
    ├── elasticache/            # Redis
    ├── s3/                     # Langfuse events bucket
    └── iam/                    # IRSA roles: LiteLLM (bedrock:InvokeModel*/Converse* + bedrock-mantle:CreateInference),
                                #   Langfuse (S3), ESO (SecretsManager read)
apps/                           # state 2: in-cluster applications (changes frequently, helm_release)
    platform.tf                 # alb-controller, external-secrets, reloader, kube-prometheus-stack
    litellm.tf  langfuse.tf  scorer.tf
    tpp-dashboard.tf            # TPP Dashboard (unified portal)
    dashboards.tf               # Grafana TPP Overview dashboard + PrometheusRule alerts
```

Why two states: a plan/apply for a channel-config change never touches the infrastructure, keeping the blast radius small;
the whole setup can later be migrated to ArgoCD as-is. All secrets flow through Secrets Manager → ESO and never land in tfstate.

## 3. RDS Credential Rotation and Automatic Recovery

RDS uses `manage_master_user_password=true` to manage the PostgreSQL master password. The password rotates automatically every **7 days**;
application recovery requires no manual intervention:

```text
RDS-managed secret rotates
  → External Secrets (5-minute polling) updates the Kubernetes Secret
  → Stakater Reloader observes the Secret data change
  → LiteLLM / Langfuse Web / Langfuse Worker restart via rolling update
  → New Pods read the new database credentials from the Secret
```

| Item | Implementation |
|---|---|
| Password source | RDS-managed Secrets Manager secret |
| Sync interval | `5m` for both `litellm-env` and `langfuse-postgres` |
| Automatic restart | `reloader` chart `2.2.16`; each Deployment uses `reloader.stakater.com/auto: "true"` |
| Max credential discovery delay | About 5 minutes, then wait for the regular RollingUpdate to complete |
| LiteLLM secrets Secret | `litellm-env` |
| Langfuse secrets Secret | `langfuse-postgres` |

Langfuse uses Prisma, and RDS-generated passwords may contain URI-reserved characters. Therefore `langfuse-postgres` must
URL-encode the password when building `database_url`, and inject it into Web and Worker via `DATABASE_URL` and `DIRECT_URL`.
Handing only the raw password to the chart's `DATABASE_PASSWORD` is not enough — it can result in Prisma `P1013 invalid port number`.

## 4. Scorer Scoring Algorithm

Scoring target: a LiteLLM deployment, i.e. a **(channel, model) pair**, compared only against others within the same model group.
One round every 60s, over the past 5-minute Prometheus window.

### Symbol definitions

| Symbol | Origin | Meaning |
|------|------|------|
| `d` | deployment | the deployment being scored, i.e. a (channel, model) pair |
| `j` | — | summation index over all deployments in the same model group as `d` |
| `cat` | category | error category; possible values are listed in the severity coefficient table below |
| `lat(d)` | latency | end-to-end (E2E) p90 latency of `d` within the window |
| `lat_best` | latency, best | smallest p90 latency within the model group, i.e. the latency of the fastest member |
| `req(d)` | requests | total number of requests for `d` within the window |
| `err(d, cat)` | errors | number of errors of category `cat` for `d` within the window |
| `sev(cat)` | severity | severity coefficient of error category `cat` |
| `err_rate(d)` | error rate | weighted error rate of `d` |
| `score_lat(d)` | score, latency | latency sub-score, in the range [0, 1] |
| `score_err(d)` | score, error | error sub-score, in the range (0, 1] |
| `q_raw(d)` | quality, raw | raw quality score for this round |
| `q(d, t)` | quality | EWMA-smoothed quality score at round `t`; new channels cold-start at an initial value of 0.5 |
| `gamma` | γ | weight amplification exponent, set to 2, used to widen score gaps within the group |
| `weight(d)` | weight | routing weight written back to LiteLLM |

### Severity coefficients

| Error category `cat` | Severity coefficient `sev(cat)` |
|------|------|
| 5xx / Timeout / connection errors | 3.0 |
| 429 (rate limited) | 1.5 |
| Other 4xx | 0.5 |

### Formulas

**Weighted error rate** (the denominator takes max to prevent division by zero):

```
                ∑  sev(cat) × err(d, cat)
               cat
err_rate(d) = ───────────────────────────
                    max(req(d), 1)
```

**Per-round scores** (the fastest in the group gets `score_lat = 1`; `score_err` drops to 0.5 at `err_rate = 8.6%`):

```
                     ⎛ lat_best          ⎞
score_lat(d) = clamp ⎜ ──────── , 0 , 1  ⎟
                     ⎝  lat(d)           ⎠

score_err(d) = exp( −8 × err_rate(d) )
```

**Raw quality score** (errors weigh more than latency):

```
q_raw(d) = 0.35 × score_lat(d) + 0.65 × score_err(d)
```

**EWMA smoothing** (time constant about 3 minutes):

```
q(d, t) = 0.3 × q_raw(d) + 0.7 × q(d, t−1)
```

**Routing weight** (normalized within the group by the gamma-th power of the quality score, gamma = 2):

```
                q(d)^gamma
weight(d) = ─────────────────
             ∑  q(j)^gamma
             j
```

An exploration floor is then applied: `weight(d) ← max(weight(d), 0.05)`, followed by renormalization, to prevent low-scoring channels from being locked out permanently.

### Operating rules

| Stage | Rule |
|------|------|
| Small-sample protection | when `req(d) < 10`, skip this round's update and keep the old score |
| Circuit breaking | when `err_rate(d) > 0.5` and severe categories (5xx/Timeout/connection errors) dominate, set `weight(d) = 0` (takes precedence over the exploration floor) |
| Recovery | after 3 consecutive rounds with `err_rate(d) < 0.1`, restore to the floor weight and ramp back up |
| Write-back | LiteLLM `/model/update` is called only when any weight within the group changes by more than 2 percentage points (hysteresis debouncing) |
| Degradation | when Prometheus / the LiteLLM API is unavailable, weights are frozen and an alert fires (the Scorer is not on the request path) |
| State persistence | EWMA scores are stored in Redis (`scorer:score:{model}:{provider}`); restarts are lossless |
| Deployment form | single-replica Deployment (not a CronJob); exports its own `scorer_quality_score` / `scorer_weight` / `scorer_last_success_timestamp` metrics |

## 5. TPP Dashboard (Unified Portal)

The LiteLLM UI, Langfuse UI, Grafana, and Prometheus each cover only one facet of the platform; the
"quotas / spend / channel health / performance" that day-to-day operations needs most is scattered across four places. The TPP Dashboard is the in-house **unified portal**:
a single container serves both a FastAPI aggregation backend and a static single-page frontend, reading only existing data sources and introducing no new storage.

```text
Browser (localhost:3020, via kubectl tunnel)
  → dashboard Pod (namespace dashboard, single replica)
      ├─ Prometheus  /api/v1/query   ← litellm_* / scorer_* metrics; channel granularity via the model_id label
      ├─ LiteLLM Management API      ← /user/list, /user/info, /user/update (master key held server-side only)
      └─ channel registry ConfigMap  ← shares the same scorer-channels.yaml as the Scorer, keeping channel definitions consistent
```

| Item | Implementation |
|---|---|
| Page sections | KPI cards (total spend over the last 24h, requests and error rate within the window, number of circuit-broken channels, total quota) / user quota table (daily quotas editable in place and written back) / channel spend, health, and weight table / channel stability and performance table (p50 / p90 / p99 of TTFT / TPOT / E2E / TPS plus error breakdown) / links to the four existing dashboards |
| Statistics window | spend and tokens are fixed to the last 24h (cost at daily granularity); performance and errors follow the page selection: 15m / 1h / 6h / 24h / 7d |
| Channel row source | all channels are rendered from the registry; channels with no traffic do not disappear just because Prometheus has no series for them |
| Health | combines `scorer_circuit_open` and `litellm_deployment_state` (0 healthy / 1 partially degraded / 2 unhealthy); worst value across replicas |
| Derived metrics | cache hit rate = cache reads / (regular input + cache reads + cache writes); TPS = 1 / TPOT percentile |
| Quota write-back | fixed semantics of USD/day: writes also pin `budget_duration=1d`; the user's existence is validated first to avoid `/user/update` implicitly creating users |
| Credentials | master key injected by the ExternalSecret `dashboard-env` (`1h` refresh), never visible in the browser |
| Security model | same as Prometheus: no authentication of its own, no Ingress exposure, access via kubectl tunnel only; OIDC must be added before putting it behind an ALB (see `docs/scaling-500-users.md` §9) |
| Deployment | `apps/tpp-dashboard.tf`; the `tpp/dashboard` image is built and pushed manually; a registry ConfigMap hash change triggers a rolling restart |
