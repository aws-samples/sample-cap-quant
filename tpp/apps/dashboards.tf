# ---------- M6: Grafana dashboard + alerting rules ----------

# The kube-prometheus-stack grafana sidecar auto-loads ConfigMaps carrying the grafana_dashboard label
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
                summary     = "Scorer has not scored successfully for over 5 minutes, channel weights are frozen"
                description = "Check scorer pod logs and Prometheus/LiteLLM reachability. Frozen weights do not affect the request path."
              }
            },
            {
              alert  = "TPPLiteLLMHighErrorRate"
              expr   = "sum(rate(litellm_deployment_failure_responses_total[5m])) / sum(rate(litellm_deployment_total_requests_total[5m])) > 0.1"
              for    = "10m"
              labels = { severity = "critical" }
              annotations = {
                summary     = "LiteLLM overall error rate above 10% for 10 minutes"
                description = "Check the channel Error Rate panel on the TPP Overview dashboard to locate the channel; confirm whether the Scorer circuit breaker has kicked in."
              }
            },
            {
              alert  = "TPPLiteLLMDown"
              expr   = "sum(up{job=\"litellm\", namespace=\"litellm\"}) == 0 or absent(up{namespace=\"litellm\"})"
              for    = "3m"
              labels = { severity = "critical" }
              annotations = {
                summary     = "All LiteLLM replicas are unscrapeable"
                description = "kubectl get pods -n litellm; check RDS/Redis connectivity and recent changes."
              }
            },
            {
              alert  = "TPPChannelCircuitOpen"
              expr   = "max by (model_group, model_id) (scorer_circuit_open) == 1"
              for    = "5m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "Channel {{ $labels.model_id }} has been circuit-broken for over 5 minutes"
                description = "This channel's severe error ratio was too high, so its traffic was set to zero; recovery requires 3 consecutive rounds with weighted error rate < 10%."
              }
            }
          ]
        }
      ]
    }
  }
}
