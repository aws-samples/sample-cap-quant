# TPP 架构设计

LiteLLM + Langfuse + 自建 kube-prometheus-stack + RDS/ElastiCache,
EKS 部署,Terraform 管基础设施 + Helm 管应用。

## 1. 架构图

![TPP 架构图](architecture-diagram.png)

矢量版 [`architecture-diagram.svg`](architecture-diagram.svg);可编辑源 [`architecture-diagram.html`](architecture-diagram.html)
(浅色主题,自带 PNG / PDF 导出),改图请改 `architecture-diagram.gen.py` 后重新生成。


## 2. Terraform 划分

```
infra/                          # state 1:基础设施(变更频率低)
├── envs/{dev,prod}/            # 组装层:main.tf / backend.tf / terraform.tfvars
└── modules/
    ├── network/                # VPC、公私子网、NAT、VPC Endpoints(S3/ECR/Bedrock)
    ├── eks/                    # 集群、managed node groups、IRSA OIDC、核心 addon
    ├── rds/                    # PostgreSQL:litellm + langfuse 两库(dev 单实例,prod 可拆)
    ├── elasticache/            # Redis
    ├── s3/                     # Langfuse events bucket
    └── iam/                    # IRSA roles:LiteLLM(bedrock:InvokeModel*/Converse* + bedrock-mantle:CreateInference)、
                                #   Langfuse(S3)、ESO(SecretsManager 读)
apps/                           # state 2:集群内应用(变更频率高,helm_release)
    platform.tf                 # alb-controller、external-secrets、reloader、kube-prometheus-stack
    litellm.tf  langfuse.tf  scorer.tf
    tpp-dashboard.tf            # TPP Dashboard(统一入口)
    dashboards.tf               # Grafana TPP Overview 面板 + PrometheusRule 告警
```

分两个 state 的理由:改渠道配置的 plan/apply 不碰基础设施,爆炸半径小;
后续可整体平移到 ArgoCD。密钥全部走 Secrets Manager → ESO,不进 tfstate。

## 3. RDS 凭证轮转与自动恢复

RDS 使用 `manage_master_user_password=true` 管理 PostgreSQL 主密码。密码每 **7 天**自动轮转；
应用恢复不依赖人工操作:

```text
RDS 托管 secret 轮转
  → External Secrets（5 分钟轮询）更新 Kubernetes Secret
  → Stakater Reloader 观察到 Secret data 变化
  → LiteLLM / Langfuse Web / Langfuse Worker 滚动重启
  → 新 Pod 从 Secret 读取新数据库凭证
```

| 项 | 实现 |
|---|---|
| 密码来源 | RDS 托管的 Secrets Manager secret |
| 同步频率 | `litellm-env`、`langfuse-postgres` 均为 `5m` |
| 自动重启 | `reloader` chart `2.2.16`；各 Deployment 使用 `reloader.stakater.com/auto: "true"` |
| 最大凭证发现延迟 | 约 5 分钟，之后等待常规 RollingUpdate 完成 |
| LiteLLM 密钥 Secret | `litellm-env` |
| Langfuse 密钥 Secret | `langfuse-postgres` |

Langfuse 使用 Prisma；RDS 生成的密码可能包含 URI 保留字符。因此 `langfuse-postgres` 必须把密码
URL-encode 后生成 `database_url`，并通过 `DATABASE_URL` 和 `DIRECT_URL` 注入 Web 与 Worker。
不能只把原始密码交给 chart 的 `DATABASE_PASSWORD`，否则可能出现 Prisma `P1013 invalid port number`。

## 4. Scorer 打分算法

评分对象:LiteLLM deployment,即 **(渠道, 模型) 二元组**,只在同一模型组内互比。
每 60s 一轮,取 Prometheus 过去 5 分钟窗口。

### 符号定义

| 符号 | 来源 | 含义 |
|------|------|------|
| `d` | deployment | 被评分的 deployment,即(渠道, 模型)二元组 |
| `j` | — | 求和下标,遍历与 `d` 同模型组内的所有 deployment |
| `cat` | category | 错误类别,取值见下方严重性系数表 |
| `lat(d)` | latency | `d` 在窗口内的端到端(E2E)p90 延迟 |
| `lat_best` | latency, best | 同模型组内最小的 p90 延迟,即组内最快者的延迟 |
| `req(d)` | requests | `d` 在窗口内的请求总数 |
| `err(d, cat)` | errors | `d` 在窗口内类别为 `cat` 的错误数 |
| `sev(cat)` | severity | 错误类别 `cat` 的严重性系数 |
| `err_rate(d)` | error rate | `d` 的加权错误率 |
| `score_lat(d)` | score, latency | 延迟单项得分,取值范围 [0, 1] |
| `score_err(d)` | score, error | 错误单项得分,取值范围 (0, 1] |
| `q_raw(d)` | quality, raw | 本轮的原始质量分 |
| `q(d, t)` | quality | 第 `t` 轮 EWMA 平滑后的质量分;新渠道冷启动初始值 0.5 |
| `gamma` | γ | 权重放大指数,取 2,用于放大组内分差 |
| `weight(d)` | weight | 写回 LiteLLM 的路由权重 |

### 严重性系数

| 错误类别 `cat` | 严重性系数 `sev(cat)` |
|------|------|
| 5xx / Timeout / 连接错误 | 3.0 |
| 429(限流) | 1.5 |
| 其它 4xx | 0.5 |

### 计算公式

**加权错误率**(分母取 max 防止除零):

```
                ∑  sev(cat) × err(d, cat)
               cat
err_rate(d) = ───────────────────────────
                    max(req(d), 1)
```

**单轮得分**(组内最快者 `score_lat = 1`;`err_rate = 8.6%` 时 `score_err` 降至 0.5):

```
                     ⎛ lat_best          ⎞
score_lat(d) = clamp ⎜ ──────── , 0 , 1  ⎟
                     ⎝  lat(d)           ⎠

score_err(d) = exp( −8 × err_rate(d) )
```

**原始质量分**(错误权重高于延迟):

```
q_raw(d) = 0.35 × score_lat(d) + 0.65 × score_err(d)
```

**EWMA 平滑**(时间常数约 3 分钟):

```
q(d, t) = 0.3 × q_raw(d) + 0.7 × q(d, t−1)
```

**路由权重**(组内按质量分的 gamma 次幂归一化,gamma = 2):

```
                q(d)^gamma
weight(d) = ─────────────────
             ∑  q(j)^gamma
             j
```

随后施加探索保底:`weight(d) ← max(weight(d), 0.05)`,再重新归一化,防止低分渠道死锁。

### 运行规则

| 环节 | 规则 |
|------|------|
| 小样本保护 | `req(d) < 10` 时跳过本轮更新,沿用旧分 |
| 熔断 | `err_rate(d) > 0.5` 且 severe 类(5xx/Timeout/连接错误)主导时,置 `weight(d) = 0`(优先于探索保底) |
| 恢复 | 连续 3 轮 `err_rate(d) < 0.1` 后,恢复至保底权重再爬坡 |
| 写回 | 组内任一权重变化超过 2 个百分点才调用 LiteLLM `/model/update`(迟滞防抖) |
| 降级 | Prometheus / LiteLLM API 不可用时,权重冻结并告警(Scorer 不在请求路径上) |
| 状态持久化 | EWMA 分数存 Redis(`scorer:score:{model}:{provider}`),重启无损 |
| 部署形态 | 单副本 Deployment(非 CronJob),自身导出 `scorer_quality_score` / `scorer_weight` / `scorer_last_success_timestamp` 指标 |

## 5. TPP Dashboard(统一入口)

LiteLLM UI、Langfuse UI、Grafana、Prometheus 各自只覆盖平台的一个切面,运维日常最需要的
"配额 / 消费 / 渠道健康 / 性能"分散在四处。TPP Dashboard 是自建的**统一入口**:
一个容器同时提供 FastAPI 聚合后端与静态单页前端,只读取既有数据源,不引入新的存储。

```text
浏览器(localhost:3020,经 kubectl 隧道)
  → dashboard Pod(namespace dashboard,单副本)
      ├─ Prometheus  /api/v1/query   ← litellm_* / scorer_* 指标,渠道粒度靠 model_id label
      ├─ LiteLLM Management API      ← /user/list、/user/info、/user/update(master key 仅服务端持有)
      └─ 渠道注册表 ConfigMap        ← 与 Scorer 共用同一份 scorer-channels.yaml,保证渠道口径一致
```

| 项 | 实现 |
|---|---|
| 页面区块 | KPI 卡片(近 24h 总消费、窗口内请求数与错误率、熔断渠道数、配额总额)/ 用户配额表(可直接改日配额并写回)/ 渠道消费 · 健康度 · 权重表 / 渠道稳定性与性能表(TTFT / TPOT / E2E / TPS 的 p50 / p90 / p99 与错误分类)/ 四个既有 dashboard 的跳转链接 |
| 统计窗口 | 消费与 tokens 固定近 24h(费用按日粒度);性能与错误跟随页面选择:15m / 1h / 6h / 24h / 7d |
| 渠道行来源 | 以注册表为准渲染全部渠道,无流量的渠道不会因 Prometheus 无 series 而消失 |
| 健康度 | 综合 `scorer_circuit_open` 与 `litellm_deployment_state`(0 健康 / 1 部分异常 / 2 异常),多副本取最差 |
| 派生指标 | 缓存命中率 = 缓存读 / (普通输入 + 缓存读 + 缓存写);TPS = 1 / TPOT 分位数 |
| 配额写回 | 固定语义 USD/天:写入时同时钉住 `budget_duration=1d`;先校验用户存在,避免 `/user/update` 隐式建用户 |
| 凭证 | master key 由 ExternalSecret `dashboard-env` 注入(`1h` 刷新),浏览器端不可见 |
| 安全模型 | 与 Prometheus 相同:自身无认证,不暴露 Ingress,仅经 kubectl 隧道访问;上 ALB 前必须补 OIDC(见 `docs/scaling-500-users.md` §9) |
| 部署 | `apps/tpp-dashboard.tf`;镜像 `tpp/dashboard` 手动构建推送;注册表 ConfigMap 哈希变化触发滚动重启 |
