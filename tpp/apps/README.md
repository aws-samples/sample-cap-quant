# apps — 集群内应用层(Milestone 2-5)

State 2:通过 Terraform helm provider 部署集群内应用,依赖 infra state 的 output
(cluster endpoint、RDS endpoint、IRSA role ARN 等,经 terraform_remote_state 读取)。

**首次部署(或环境重建)需要两段 apply**——ClusterSecretStore 的 CRD 随 external-secrets
chart 安装,plan 阶段 CRD 不存在会直接报错:

```bash
terraform apply -target=kubernetes_storage_class_v1.gp3 \
  -target=helm_release.alb_controller -target=helm_release.external_secrets \
  -target=helm_release.kube_prometheus_stack
terraform apply   # 第二次全量,补 ClusterSecretStore 等 CRD 资源
```

- platform.tf — aws-load-balancer-controller、external-secrets、kube-prometheus-stack
- litellm.tf — LiteLLM Proxy(config 与 local/config/litellm-config.yaml 同构)
- langfuse.tf — Langfuse(含 ClickHouse 子 chart;Postgres/Redis/S3 指向 AWS 托管资源)
- scorer.tf — 自建 Scorer(chart 在 ../charts/scorer)
