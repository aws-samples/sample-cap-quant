# TPP — Token Proxy Platform

- 统一接入多个 LLM token 渠道(Anthropic 官网 / OpenAI 官网 / 聚合商 / AWS Bedrock 等云厂商)的代理平台
- 提供 per-user 每日 USD quota、渠道×模型 metrics、调用 trace,以及基于质量打分的智能渠道流量调度
- 部署目标:AWS EKS,Terraform + Helm 管理。

## 架构组件

| 能力 | 实现 |
|---|---|
| 渠道接入 / 路由 / USD budget | LiteLLM Proxy |
| Metrics(TTFT / TPOT / E2E / Error) | kube-prometheus-stack(自建,EKS 内) |
| Trace | Langfuse(自托管,含 ClickHouse) |
| 智能权重调度 | 自建 Scorer(每分钟查 Prometheus 打分 → LiteLLM Management API 调 weight) |
| Dashboard | **TPP Dashboard**(自建统一入口:用户配额可改、渠道消费 / 健康度 / 权重、TTFT / TPOT / E2E / TPS 分位数)+ 跳转 LiteLLM UI / Langfuse UI / Grafana / Prometheus |
| 元数据存储 | RDS PostgreSQL + ElastiCache Redis |

## 架构图

![TPP 架构图](docs/architecture-diagram.png)


## 仓库结构

```
docs/                 架构设计文档
local/                Milestone 0:docker-compose 本地验证环境
infra/                Terraform:AWS 基础设施(envs/ + modules/)
apps/                 Terraform helm_release:集群内应用层(独立 state)
charts/               自建组件的 Helm chart(scorer 等)
services/scorer/      智能权重调度服务源码
services/dashboard/   TPP Dashboard(统一入口)源码:FastAPI 聚合后端 + 静态单页前端
```
## Terraform 结构

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
    tpp-dashboard.tf            # TPP Dashboard(统一入口):ECR repo、Deployment、共用渠道注册表 ConfigMap
    dashboards.tf               # Grafana TPP Overview 面板 + PrometheusRule 告警
```

分两个 state 的理由:改渠道配置的 plan/apply 不碰基础设施,爆炸半径小;
后续可整体平移到 ArgoCD。密钥全部走 Secrets Manager → ESO,不进 tfstate。

## 部署

两条路径:**本地 docker-compose**(快速验证配置与链路)与 **AWS EKS 全量部署**(生产形态)。

### 方式一:本地验证(docker-compose)

```bash
cd local
cp .env.example .env          # 填入至少一个渠道的 API key
docker compose up -d          # LiteLLM + Postgres + Redis + Prometheus + Grafana
docker compose --profile trace up -d   # 可选:附带 Langfuse(含 ClickHouse/MinIO)
```

冒烟测试(本地 LiteLLM 监听 4000):

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model": "claude-opus-5", "messages": [{"role": "user", "content": "hello"}]}'
```

### 方式二:AWS EKS 全量部署

部署顺序固定:**bootstrap(一次性)→ infra(state 1)→ apps(state 2)→ Scorer / Dashboard 镜像 → 接入验证**。

#### 0. 前置条件

| 项 | 要求 |
|------|------|
| 工具 | Terraform ≥ 1.10、AWS CLI v2、kubectl、Docker(含 buildx) |
| AWS 凭证 | 管理员(或等效)权限,`aws sts get-caller-identity` 正常返回 |
| Region | 建议 us-west-2(Bedrock Claude 模型可用性好);默认渠道注册表还用到 us-east-1 |
| Bedrock | 在两个 region 均已开通 Anthropic Claude 模型访问(Model access);us-west-2 另需开通 Mantle 的 OpenAI 模型(`openai.gpt-5.6-terra`) |
| VPC CIDR | 默认 10.80.0.0/16,与现有网段冲突时改 `infra/envs/dev/variables.tf` |

#### 1. Bootstrap:tfstate 存储(一次性)

两个 state 共用一个 S3 bucket;Terraform ≥ 1.10 用 S3 原生锁(`use_lockfile`),无需 DynamoDB:

```bash
aws s3api create-bucket --bucket tpp-tfstate-<aws account> --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2
aws s3api put-bucket-versioning --bucket tpp-tfstate-<aws account> \
  --versioning-configuration Status=Enabled
```

然后把 `infra/envs/dev/versions.tf`、`apps/versions.tf`、`apps/providers.tf` 中 backend 的 bucket 名
`tpp-tfstate-<aws account>` 里的 `<aws account>` 换成自己的账号 ID;不想改文件也可以在 init 时覆盖:

```bash
terraform init -backend-config="bucket=tpp-tfstate-<aws account>"
```

#### 2. State 1 — 基础设施(infra/)

```bash
cd infra/envs/dev
terraform init
terraform plan
terraform apply        # 约 20 分钟,EKS 控制面与 RDS 创建慢
```

产出:VPC(公私子网 + NAT + S3/ECR/Bedrock VPC Endpoints)、EKS 集群 `tpp-dev`(managed node group + IRSA OIDC)、RDS PostgreSQL(litellm / langfuse 两库)、ElastiCache Redis、Langfuse events S3 bucket,以及三组 IRSA role(LiteLLM→Bedrock、Langfuse→S3、ESO→SecretsManager)。所有 output 供 state 2 经 `terraform_remote_state` 读取。

配置 kubeconfig:

```bash
aws eks update-kubeconfig --name tpp-dev --region us-west-2
```

#### 3. State 2 — 集群内应用(apps/)

**首次部署(或环境重建)必须两段 apply**:ClusterSecretStore 等 CRD 资源依赖 external-secrets chart 先装进集群,一步到位的 plan 会因 CRD 不存在直接报错:

```bash
cd apps
terraform init

# 第一段:平台组件(StorageClass、ALB controller、external-secrets、kube-prometheus-stack)
terraform apply -target=kubernetes_storage_class_v1.gp3 \
  -target=helm_release.alb_controller -target=helm_release.external_secrets \
  -target=helm_release.kube_prometheus_stack

# 第二段:全量(LiteLLM、Langfuse、Scorer、Grafana dashboards 及 CRD 资源)
terraform apply
```

密钥链路全自动,无需手工创建任何 Secret:apply 时生成 LiteLLM master key(Secrets Manager `tpp/litellm`)与 Langfuse 初始化凭证(`tpp/langfuse`),经 ESO 同步为集群内 Secret;RDS 密码直接引用 RDS 托管 secret。RDS 密码轮转的自动恢复机制见 [Runbook:RDS 凭证轮转与自动恢复](docs/runbook.md#rds-凭证轮转与自动恢复)。

#### 4. Scorer 与 Dashboard 镜像(首次一次)

apps apply 已创建 ECR repo `tpp/scorer` 与 `tpp/dashboard`,但两个自建组件的镜像都需要手动构建推送
(在此之前 scorer / dashboard pod 处于 ImagePullBackOff,属预期):

```bash
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin <aws account>.dkr.ecr.us-west-2.amazonaws.com

# Scorer
cd services/scorer
docker buildx build --platform linux/amd64 \
  -t <aws account>.dkr.ecr.us-west-2.amazonaws.com/tpp/scorer:0.1.0 --push .
kubectl rollout restart deploy/scorer -n scorer

# TPP Dashboard
cd ../dashboard
docker buildx build --platform linux/amd64 \
  -t <aws account>.dkr.ecr.us-west-2.amazonaws.com/tpp/dashboard:0.1.2 --push .
kubectl rollout restart deploy/dashboard -n dashboard
```

镜像 tag 分别对应 `apps/scorer.tf` 的 `scorer_image_tag`(默认 `0.1.0`)与 `apps/tpp-dashboard.tf` 的
`dashboard_image_tag`(默认 `0.1.2`);升级镜像时改 tag 再 `terraform apply`。

#### 5. 渠道注册

渠道注册表在 `apps/values/scorer-channels.yaml`(默认 5 个模型组共 9 条 Bedrock 渠道:4 个 Claude 组 × usw2/use1 两 region,外加 `gpt-5.6-terra`(Bedrock Mantle 上的 OpenAI 模型)usw2 单渠道)。Scorer 启动时经 LiteLLM Management API `/model/new` 幂等写入 DB —— 特意不走 LiteLLM 静态 config,因为静态模型无法被 Management API 动态调权。Bedrock 渠道经 IRSA 鉴权,无需任何 API key。

加/改渠道:编辑该文件 → `cd apps && terraform apply`(ConfigMap 变化触发 Scorer 滚动重启,启动时自动注册;新渠道从冷启动分 0.5 + 保底流量开始爬坡)。

#### 6. 接入与验证

dev 环境未暴露公网 Ingress,通过 port-forward 隧道访问(常驻 launchd 守护的装法见 Runbook):

```bash
./scripts/tpp-tunnels.sh   # LiteLLM :14000 / Grafana :3000 / Langfuse :3010 / Prometheus :9090 / TPP Dashboard :3020
```

日常从 **TPP Dashboard(http://localhost:3020)** 进入:首页汇总用户配额、渠道消费 / 健康度 / 权重、
渠道性能分位数,并提供另外四个 dashboard 的跳转链接。

冒烟测试:

```bash
export MASTER_KEY=$(cd apps && terraform output -raw litellm_master_key)
curl http://localhost:14000/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model": "claude-sonnet-5", "messages": [{"role": "user", "content": "hello"}]}'
```

验证清单:

- `kubectl get pods -A` —— litellm / langfuse / scorer / dashboard / monitoring 各 namespace 全部 Running;
- TPP Dashboard(:3020)渠道表列出全部 9 条渠道,上面冒烟请求所在渠道的"请求数"变为非零;
- Grafana(:3000)的 TPP Overview dashboard 出现请求指标;
- Langfuse(:3010)能看到上面冒烟请求的 trace;
- 有流量后 `kubectl logs -n scorer deploy/scorer` 出现 `weights updated`。

部署完成后的日常操作(建用户与 per-user quota、调打分参数、省钱开关)、RDS 凭证轮转恢复链路与 Scorer 打分算法见 [Runbook](docs/runbook.md);

关键架构决策及其取舍见 [ADR](docs/ADR.md)。
