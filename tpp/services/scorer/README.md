# scorer

每 60s:查 Prometheus(渠道×模型的 E2E p90 / 错误分类)→ 打分(EWMA 平滑)→
经 LiteLLM Management API 调整 deployment weight。算法全文见 docs/architecture.md §3。

技术栈:Python 3.12 + httpx + prometheus-client;状态存 Redis;单副本 Deployment。
实现清单:
- [ ] scorer/config.py — 权重系数/阈值全部可配(env 或 ConfigMap)
- [ ] scorer/prom.py — PromQL 查询封装
- [ ] scorer/scoring.py — 纯函数:指标 → 分数 → 权重(单测覆盖熔断/保底/迟滞分支)
- [ ] scorer/litellm_client.py — Management API 封装
- [ ] scorer/main.py — 主循环 + 自身指标暴露
- [ ] tests/ — 打分函数与边界场景单测
