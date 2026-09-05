# TPP 500 用户规模架构调整方案

现有架构（`docs/architecture.md`）按 dev 规格部署，舒适承载约 50 名重度用户。
接入 500 人需要**三处换实现**（ClickHouse、Redis 拓扑、接入层身份）、
**一处靠 AWS 商务解决**（Bedrock 配额），其余为扩容与补件。

> 本文所有容量数字均为基于当前 Terraform/values 配置的量级推算，**非压测结果**。
> Phase 0 的压测完成后应回填真实值。

## 1. 设计目标

500 席位的负载取决于人群构成，取两个模型：

```text
混合人群（更接近真实内部平台）
  重度 15% =  75 人 × 800 req/天 × 20M tok/天
  中度 50% = 250 人 × 200 req/天 ×  5M tok/天
  轻度 35% = 175 人 ×  40 req/天 ×  1M tok/天
  → 117k req/天，2.9B tok/天，峰值 ~12 RPS，均值 ~6M TPM

全重度（上界）
  500 人 × 800 req/天 × 20M tok/天
  → 400k req/天，10B tok/天，峰值 ~42 RPS，均值 ~21M TPM
```

数据面的真实压力是并发流数量，不是 RPS：

```text
in_flight = peak_rps × avg_stream_seconds
          = 42 × 35s ≈ 1470
```

**设计指标（按上界，混合人群则有 3× 余量）：**

| 指标 | 目标值 |
|---|---|
| 持续 / 峰值 RPS | 40 / 60 |
| 并发流 | 2000 |
| 请求量 | 400k/天 |
| 峰值 TPM | 60M |

## 2. 改动总览

| 层 | 现状 | 500 人目标 | 改动性质 |
|---|---|---|---|
| 配额层 | 2 region × 单账户 | N 账户 × 3 region 分片 | **商务 + 新增** |
| 接入层 | ClusterIP + kubectl 隧道 | ALB + OIDC + 自助发 key | **新建** |
| 数据面 | LiteLLM 2 副本单进程 | HPA 4→20 + PgBouncer | 扩容 + 补件 |
| 账本 | db.t4g.medium 单实例双库 | Aurora PG + 库分离 + 保留策略 | 换规格 + 拆分 |
| 缓存/队列 | cache.t4g.micro 一套共用 | 拆两套，均 HA + TLS | **拆分重建** |
| 链路存储 | ClickHouse 单 pod 50Gi | 集群化 + 采样 + TTL | **换实现** |
| 指标 | Prometheus 2Gi 全 label | 降基数 + 独立节点 | 配置 + 扩容 |
| 调权 | Scorer 单副本 | 保持单副本，加配额感知 | 小改 |
| 节点 | 3×m7i.large 无自动扩 | 3 个 node group + Karpenter | 重构 |

## 3. Bedrock 配额分片

**唯一工程解决不了的一环，lead time 数周，必须最先启动。**

关键机制：`us.anthropic.*` 前缀本身就是跨区 inference profile，推理会在
us-east-1 / us-east-2 / us-west-2 之间分散，**但配额记在调用方 region 的账户桶上**。

```text
配额桶数 = 账户数 × 调用 region 数
```

- 现状（`apps/values/scorer-channels.yaml`）：2 个调用 region → 2 个桶
- 加 us-east-2 → 3 个桶
- 60M TPM 峰值：单账户单 region 拿到 20M TPM 就需要与 AWS 客户团队协商，
  因此基本必然需要**跨账户分片**（M 账户 × 3 region = 3M 个桶，配额彼此独立）
- 可选：Provisioned Throughput 覆盖基线负载，突发走 on-demand

实现要点：

| 项 | 变更 |
|---|---|
| 渠道注册表 | 从 9 条扩到 `账户数 × 3 region × 模型数` 量级 |
| IAM | LiteLLM IRSA 增加 `sts:AssumeRole`，每渠道挂跨账户 role |
| 排空枯竭桶 | 复用 Scorer 现有动态调权机制（见 §10） |

## 4. 数据面（LiteLLM）

- **保持 1 uvicorn worker / pod，靠加 pod 扩容**，不要用 `--num_workers`：
  多 worker 复制 Python 内存，且 HPA 粒度变粗
- 规格：`cpu req 1 / limit 2`，`mem req 1Gi / limit 3Gi`
- 单 pod 安全承载 ~150–200 条并发流 → `2000 / 175 ≈ 12` pod 峰值，**HPA 4 → 20**
- **HPA 不要用 CPU 指标**：流式转发是 I/O 密集，CPU 滞后于真实压力。
  用 **KEDA + Prometheus scaler**，按 `litellm_proxy_total_requests` 速率或在途请求数扩容
  （kube-prometheus-stack 已在，KEDA 是最小增量）
- 补 PodDisruptionBudget + `topologySpreadConstraints` 跨 3 AZ

## 5. 账本层（RDS）

**PgBouncer 是扩副本的前置条件。** Prisma 每个 pod 开独立连接池，
20 pod × 默认池大小 ≈ 200–340 连接，而 db.t4g.medium 最大连接数仅 ~340
—— 不上连接池，LiteLLM 一扩副本就打满 RDS 连接数。

| 项 | 变更 |
|---|---|
| 连接池 | PgBouncer（transaction 模式）或 RDS Proxy；`DATABASE_URL` 加 `pgbouncer=true` |
| 库分离 | litellm 账本与 langfuse 元数据拆成两个实例（现挤在同一 t4g.medium） |
| 账本实例 | Aurora PostgreSQL，writer `db.r7g.large` + 1 reader，Multi-AZ |
| 高可用 | `infra/envs/dev/main.tf:36-40` 的 `multi_az` / `deletion_protection` 翻为 true |
| 保留策略 | `maximum_spend_logs_retention_period` 设 30–90d |
| 长期账单 | 日聚合 ETL 到 S3 + Athena |

选 Aurora 的理由：每请求写一行 SpendLog，同时批量更新 key/user/team 的 spend 行
—— 同一 key 的高并发请求会在同一行上争锁。Aurora 提供 reader 卸载、秒级故障转移、存储自动扩。

SpendLogs 在 400k 请求/天下是无界增长表，保留策略为必须项而非优化项。

## 6. 缓存/队列（Redis）

现状 `cache.t4g.micro`（0.5 GiB）同时装 LiteLLM router 状态与 Langfuse 摄取队列。
**危险点：队列被 evict 是静默丢链路数据，不报错。** 必须拆两套。

### A. Router / 限流 Redis

`cache.m7g.large`，主从 + 自动故障转移。

这套承担 per-key 的 rpm/tpm 限流，**在请求路径上是强依赖** ——
挂了就是全站限流失效或全站 5xx，HA 不可省。

### B. Langfuse 摄取队列 Redis

按容忍的 worker 滞后定容：

```text
queue_bytes = peak_rps × event_kb × tolerated_lag_seconds
            = 40 × 120KB × 300s ≈ 1.4 GB
```

取 `cache.r7g.large`（13 GiB）留足余量。

两套均需开 **TLS + AUTH**
（`apps/values/langfuse-values.yaml.tftpl` 现为 `auth.enabled: false`，注释已标注 dev 取舍）。

## 7. 链路存储（ClickHouse）

单 pod / 单副本 / 50Gi / 无 TTL，在 500 人下无论怎么扩卷都撑不住，
且 pod 挂了链路观测直接停摆。

### 7.1 采样先做 —— 比扩容有效约 5 倍

```text
全量 payload：400k req/天 → ~12 GB/天（压缩后）
metadata 100% + payload 20% 采样 → 3–4 GB/天 → 90 天约 320 GB
```

做质量分析不需要 100% 捕获 50k-token 的完整 prompt。

### 7.2 集群化

| 方案 | 说明 |
|---|---|
| Altinity ClickHouse Operator | 3 分片 × 2 副本 + ClickHouse Keeper；**`apps/values/langfuse-values.yaml.tftpl` 的 `cluster.enabled` 必须翻为 true**，否则 Langfuse 迁移不会用 ReplicatedMergeTree |
| ClickHouse Cloud | 运维最省，但数据离开自有账户，需评估合规 |

### 7.3 其他

- ClickHouse TTL（90d）+ S3 冷分层（`storage_policy` 挂 S3 disk）；
  Langfuse blob 已落 S3，该部分设计无需改动
- Langfuse web 3 副本；worker 4–6 副本 + **KEDA 按 Redis 队列深度扩容**
  （现 values 未设 replicas，走 chart 默认）

## 8. 指标层（Prometheus）

**500 用户对 Prometheus 是一次基数攻击。** LiteLLM 指标带
`hashed_api_key` / `api_key_alias` / `end_user` 等 per-user label，
`500 key × 9+ 渠道 × 十几个指标族` → 百万级 series，2Gi 必死。

处方：在 `apps/litellm.tf:270` 的 ServiceMonitor 加 `metricRelabelConfigs`，
**labeldrop 掉 per-key / per-user label，只保留 `model_id`、`requested_model`、
`exception_class`、`le`** —— 这四个正是 `services/scorer/scorer/prom.py`
与 tpp-dashboard 唯一依赖的 label。per-user 归属应在 RDS 账本和 Langfuse 中查，不进时序库。

降基数后：Prometheus 独占节点，8Gi，200Gi 卷，保留 30d。
**保留期不能低于 7d** —— dashboard 的统计窗口白名单含 `7d`。

## 9. 接入层与身份

500 人规模下最被低估的工作量。现状是 ClusterIP + kubectl 隧道 +
运维在 dashboard 上手工改配额，这条路走不通。

| 项 | 说明 |
|---|---|
| 边缘 | ALB + ACM + Route53 + WAF（`apps/platform.tf:17` 的 LB controller 已装好） |
| 身份 | OIDC（Okta/Entra）→ key broker 调 LiteLLM `/key/generate`，把 IdP group 映射为 team + `max_budget` + `budget_duration` + `rpm_limit`/`tpm_limit` |
| 自助化 | 复用 tpp-dashboard 已有的 `/user/update` 写回能力，从"运维手改"扩成"用户自助 + 团队管理员审批"，无需重写 |
| per-key 限流 | **硬需求**：不设则单个用户跑批处理即可吃光全公司 Bedrock 配额；依赖 router Redis，因此绕回 §6.A 的 HA 要求 |
| dashboard 自身认证 | 现无认证，安全模型建立在"不暴露 Ingress"（`apps/tpp-dashboard.tf:4`）；上 ALB 后该前提失效，必须补 OIDC |

## 10. 调权层（Scorer）

单副本、不在请求路径、挂了只是权重冻结 —— 该设计在 500 人下依然成立，
**必须保持单副本**（多副本会并发写权重冲突）。两点需改：

1. **`w_floor = 0.05` 的代价**：配额打满的渠道仍保底 5% 流量，
   40 RPS 下即稳定 2 RPS 的 429。建议增加"配额枯竭"状态，
   `RateLimitError` 占比持续偏高时将该渠道 floor 压到 0.005 或临时置 0。
2. **区分节流与故障**：`RateLimitError` severity 1.5 且不在 `SEVERE_CLASSES`，
   因此节流永不熔断、只调权 —— 这在 2 渠道时正确，
   但在 N 账户 × 3 region 的多桶拓扑下，需要能明确表达"该桶今日到顶"与"该渠道损坏"的差别。

## 11. 节点拓扑

拆 3 个 node group，并且**必须加 Karpenter 或 cluster-autoscaler**
—— 现在完全没有节点自动扩容，`node_max_size = 5` 只是死上限。

| node group | 实例 | 用途 |
|---|---|---|
| data-plane | m7i.xlarge × 3–8，3 AZ，on-demand | LiteLLM + Scorer，延迟敏感 |
| observability | m7i.2xlarge × 2 | Prometheus / Grafana / Langfuse web+worker |
| clickhouse | r7i.2xlarge × 3，taint 独占 | ClickHouse（内存密集） |

另：`single_nat_gateway = true`（`infra/envs/dev/main.tf:17`）需改为每 AZ 一个，
否则单 AZ NAT 故障将导致全站出网中断。

## 12. 落地顺序

顺序由依赖关系决定，而非重要性。

### Phase 0 — 立刻启动（lead time 最长）

- Bedrock 配额提升申请 + 跨账户分片方案敲定
- 用真实流量压测拿基线：LiteLLM p99、RDS `CPUCreditBalance`、
  Redis `used_memory`、ClickHouse 磁盘增速
- 压测完成后回填本文所有推算值

### Phase 1 — 解除扩容硬阻塞（顺序不可反）

```text
PgBouncer → Redis 拆两套 → Prometheus 降基数 → Karpenter → LiteLLM HPA
```

两条硬依赖：

- PgBouncer 必须在 HPA 之前，否则扩副本即打满 RDS 连接数
- Prometheus 降基数必须在用户数上量之前，否则 Prometheus 挂掉会让
  Scorer 与 dashboard 同时失明

### Phase 2 — 可观测性重构

```text
Langfuse 采样 → ClickHouse 集群化 + TTL + S3 分层 → Langfuse worker KEDA 扩容
```

先做采样：成本最低、收益最大。

### Phase 3 — 接入治理

```text
ALB + ACM + WAF → OIDC → 自助发 key broker → per-key 限流 → dashboard 认证
```

## 13. 成本量级与核心判断

平台侧月成本粗估（不含 token）：

| 项 | 估算 |
|---|---|
| Aurora 双实例 + langfuse RDS | ~$700 |
| 两套 Redis 含副本 | ~$600 |
| EKS 节点 | ~$3,000–4,500 |
| 存储 / NAT / ALB / S3 | ~$500 |
| **合计** | **~$5–7k/月** |

而 2.9B tokens/天 的 Bedrock 费用，即便按重度缓存折扣后的混合单价估算，
也在 **$40k–170k/月** 量级。

> **本方案最重要的结论：平台基础设施成本相对 token 成本是零头（1–2 个数量级差距）。**
> 不要为省平台的钱牺牲 HA —— ClickHouse 单点、Redis 共用、RDS 单 AZ 省下的几百美元，
> 一次故障造成的 500 人停工与计费数据丢失就远超了。
>
> 真正值得投入工程的省钱方向是**提高 prompt cache 命中率**和
> **把请求路由到更便宜的模型**，那才是动辄数万美元的杠杆。

## 14. 待决事项

| 事项 | 需要的决策 |
|---|---|
| Bedrock 跨账户分片 | 账户数量、账户归属与计费主体 |
| ClickHouse 托管 vs 自管 | 数据出账户是否触及合规红线 |
| OIDC provider | Okta / Entra / 其他 |
| 域名与证书 | 对外域名、ACM 证书归属 |
| SpendLogs 保留期 | 30d / 90d，及长期账单是否需要 Athena 查询 |
| Langfuse 采样率 | payload 采样 20% 是否满足质量分析需求 |
