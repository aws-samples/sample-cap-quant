# ---------- M6:Grafana dashboard + 告警规则 ----------

# kube-prometheus-stack 的 grafana sidecar 自动加载带 grafana_dashboard label 的 ConfigMap
resource "kubernetes_config_map_v1" "tpp_dashboard" {
  metadata {
    name      = "tpp-overview-dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "tpp-overview.json" = file("${path.module}/values/tpp-overview-dashboard.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_manifest" "tpp_alerts" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "tpp-alerts"
      namespace = "monitoring"
    }
    spec = {
      groups = [
        {
          name = "tpp"
          rules = [
            {
              alert  = "TPPScorerStale"
              expr   = "time() - max(scorer_last_success_timestamp) > 300"
              for    = "1m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "Scorer 超过 5 分钟没有成功打分,渠道权重已冻结"
                description = "检查 scorer pod 日志与 Prometheus/LiteLLM 可达性。权重冻结不影响请求链路。"
              }
            },
            {
              alert  = "TPPLiteLLMHighErrorRate"
              expr   = "sum(rate(litellm_deployment_failure_responses_total[5m])) / sum(rate(litellm_deployment_total_requests_total[5m])) > 0.1"
              for    = "10m"
              labels = { severity = "critical" }
              annotations = {
                summary     = "LiteLLM 整体错误率超过 10% 持续 10 分钟"
                description = "查看 TPP Overview dashboard 的渠道 Error Rate 面板定位渠道;确认 Scorer 熔断是否生效。"
              }
            },
            {
              alert  = "TPPLiteLLMDown"
              expr   = "sum(up{job=\"litellm\", namespace=\"litellm\"}) == 0 or absent(up{namespace=\"litellm\"})"
              for    = "3m"
              labels = { severity = "critical" }
              annotations = {
                summary     = "LiteLLM 所有副本不可抓取"
                description = "kubectl get pods -n litellm;检查 RDS/Redis 连接与最近变更。"
              }
            },
            {
              alert  = "TPPChannelCircuitOpen"
              expr   = "max by (model_group, model_id) (scorer_circuit_open) == 1"
              for    = "5m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "渠道 {{ $labels.model_id }} 被熔断超过 5 分钟"
                description = "该渠道 severe 错误占比过高被置零流量,恢复需连续 3 轮加权错误率 < 10%。"
              }
            }
          ]
        }
      ]
    }
  }
}
