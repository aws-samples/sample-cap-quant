# TPP — Token Proxy Platform

统一接入多个 LLM token 渠道(Anthropic 官网 / OpenAI 官网 / 聚合商 / AWS Bedrock 等云厂商)的代理平台,
提供 per-user 每日 USD quota、渠道×模型 metrics、调用 trace,以及基于质量打分的智能渠道流量调度。
部署目标:AWS EKS,Terraform + Helm 管理。

## 架构组件

| 能力 | 实现 |
|---|---|
| 渠道接入 / 路由 / USD budget | LiteLLM Proxy |
| Metrics(TTFT / TPOT / E2E / Error) | kube-prometheus-stack(自建,EKS 内) |
| Trace | Langfuse(自托管,含 ClickHouse) |
| 智能权重调度 | 自建 Scorer(每分钟查 Prometheus 打分 → LiteLLM Management API 调 weight) |
| Dashboard | LiteLLM UI + Langfuse UI + Grafana |
| 元数据存储 | RDS PostgreSQL + ElastiCache Redis |

详细设计见 [docs/architecture.md](docs/architecture.md)。

## 架构图
<img width="1189" height="914" alt="Screenshot 2026-08-24 at 20 02 36" src="https://github.com/user-attachments/assets/ca1fd2f9-25e9-4c96-9d41-41c785838a36" />


## 仓库结构

```
docs/                 架构设计文档
local/                Milestone 0:docker-compose 本地验证环境
infra/                Terraform:AWS 基础设施(envs/ + modules/)
apps/                 Terraform helm_release:集群内应用层(独立 state)
charts/               自建组件的 Helm chart(scorer 等)
services/scorer/      智能权重调度服务源码
```

## 快速开始(本地验证,Milestone 0)

```bash
cd local
cp .env.example .env          # 填入至少一个渠道的 API key
docker compose up -d          # LiteLLM + Postgres + Redis + Prometheus + Grafana
docker compose --profile trace up -d   # 可选:附带 Langfuse(含 ClickHouse/MinIO)
```

- LiteLLM Proxy / Admin UI: http://localhost:4000 (UI 在 /ui,master key 见 .env)
- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000 (admin/admin)
- Langfuse(trace profile): http://localhost:3001

冒烟测试:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model": "claude-opus-5", "messages": [{"role": "user", "content": "hello"}]}'
```

## [Runbook](docs/runbook.md)
