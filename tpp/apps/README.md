# apps — In-cluster Application Layer

State 2: deploys in-cluster applications via the Terraform helm provider, depending on the infra state's outputs
(cluster endpoint, RDS endpoint, IRSA role ARNs, etc., read via terraform_remote_state).

**The first deployment (or an environment rebuild) requires two apply passes** — the ClusterSecretStore CRD is installed
with the external-secrets chart, and the plan phase fails outright if the CRD does not exist:

```bash
terraform apply -target=kubernetes_storage_class_v1.gp3 \
  -target=helm_release.alb_controller -target=helm_release.external_secrets \
  -target=helm_release.kube_prometheus_stack
terraform apply   # second full pass, adding ClusterSecretStore and other CRD resources
```

- platform.tf — aws-load-balancer-controller, external-secrets, kube-prometheus-stack
- litellm.tf — LiteLLM Proxy (config mirrors local/config/litellm-config.yaml)
- langfuse.tf — Langfuse (with the ClickHouse subchart; Postgres/Redis/S3 point to AWS-managed resources)
- scorer.tf — in-house Scorer (chart in ../charts/scorer)
