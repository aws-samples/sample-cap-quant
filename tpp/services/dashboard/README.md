# tpp-dashboard

TPP 独立运营 dashboard(M7):单容器 = FastAPI 聚合后端 + 纯静态单页前端。

展示:

1. **用户配额**(USD/day,`budget_duration=1d`)——页面上可直接改,写回 LiteLLM
   `/user/update`;
2. **渠道消费 / 健康度 / 权重**——9 条 region×模型渠道(近 24h 消费与 tokens、
   `scorer_quality_score`、`scorer_weight`、熔断与 `litellm_deployment_state`);
3. **渠道稳定性与性能**——TTFT / TPOT / E2E / TPS 的 p50/p90/p99 与错误分类,
   统计窗口可选(15m/1h/6h/24h/7d);TPS 由 TPOT 直方图分位数换算(1/TPOT);
4. 4 个既有 dashboard(LiteLLM / Grafana / Langfuse / Prometheus)跳转链接。

数据源:Prometheus(`litellm_*` / `scorer_*` 指标,渠道粒度靠 `model_id` label)
与 LiteLLM Management API(master key 由 ExternalSecret 注入,仅服务端持有)。
安全模型与 Prometheus 相同:自身无认证、不暴露 Ingress,仅经 kubectl 隧道访问
(本地端口约定 3020,见 `scripts/tpp-tunnels.sh`)。

## 本地开发

```bash
pip install -e .
PROMETHEUS_URL=http://localhost:9090 \
LITELLM_URL=http://localhost:14000 \
LITELLM_MASTER_KEY=$(cd ../../apps && terraform output -raw litellm_master_key) \
CHANNELS_FILE=../../apps/values/scorer-channels.yaml \
PORT=3020 dashboard
```

## 构建镜像

```bash
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin <aws account>.dkr.ecr.us-west-2.amazonaws.com
docker buildx build --platform linux/amd64 \
  -t <aws account>.dkr.ecr.us-west-2.amazonaws.com/tpp/dashboard:0.1.0 --push .
```

部署见 `apps/tpp-dashboard.tf`(改版本号要同步 `var.dashboard_image_tag`)。
