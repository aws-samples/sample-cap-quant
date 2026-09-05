#!/usr/bin/env bash
# TPP local tunnel daemon: keeps the LiteLLM / Grafana / Langfuse port-forwards up simultaneously,
# each reconnecting on its own after a disconnect, and probes each tunnel's local health,
# restarting any zombie (process alive, forwarding dead) automatically.
# Runs persistently under launchd (com.tpp.litellm-proxy); manual runs also work (Ctrl-C to exit).
# Note: after editing this file, copy it to ~/.local/bin/ as well (launchd uses that copy, due to TCC restrictions).
#
# Local port conventions:
#   LiteLLM    http://localhost:14000   (UI: /ui)
#   Grafana    http://localhost:3000
#   Langfuse   http://localhost:3010    (fixed at 3010, bound to NEXTAUTH_URL)
#   Prometheus http://localhost:9090
#   Dashboard  http://localhost:3020    (TPP standalone ops dashboard)
set -u

if ! kubectl config current-context 2>/dev/null | grep -q tpp-dev; then
  echo "Current kubecontext is not tpp-dev; run this first:"
  echo "  aws eks update-kubeconfig --name tpp-dev --region us-west-2"
  exit 1
fi

# Take over: kill any existing port-forwards of the same kind to guarantee a single owner
pkill -f "kubectl port-forward -n litellm" 2>/dev/null
pkill -f "kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana" 2>/dev/null
pkill -f "kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus" 2>/dev/null
pkill -f "kubectl port-forward -n langfuse svc/langfuse-web" 2>/dev/null
pkill -f "kubectl port-forward -n dashboard svc/dashboard" 2>/dev/null
sleep 1

forward() { # $1=name $2=namespace $3=service $4=local-port:remote-port $5=health-probe URL
  while true; do
    kubectl port-forward -n "$2" "svc/$3" "$4" > >(sed "s/^/[$1] /") 2>&1 &
    local pid=$!
    # Watchdog: after losing the API server connection, kubectl may hang as a zombie without exiting
    # (port still listening but forwarding dead; common after network switches or sleep/wake).
    # "Reconnect only when the process exits" cannot catch this, so we must probe the local port.
    local fails=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 15
      if curl -sf -m 5 -o /dev/null "$5"; then
        fails=0
      else
        fails=$((fails + 1))
        if [ "$fails" -ge 3 ]; then
          echo "[$1] health probe failed ${fails} times in a row, killing zombie tunnel..."
          kill "$pid" 2>/dev/null
          break
        fi
      fi
    done
    wait "$pid" 2>/dev/null
    echo "[$1] disconnected, reconnecting in 3 seconds..."
    sleep 3
  done
}

echo "TPP tunnels: litellm->14000  grafana->3000  langfuse->3010  prometheus->9090  dashboard->3020"
forward litellm    litellm    litellm                          14000:4000 http://localhost:14000/health/liveliness &
forward grafana    monitoring kube-prometheus-stack-grafana    3000:80    http://localhost:3000/api/health &
forward langfuse   langfuse   langfuse-web                     3010:3000  http://localhost:3010/api/public/health &
forward prometheus monitoring kube-prometheus-stack-prometheus 9090:9090  http://localhost:9090/-/healthy &
forward dashboard  dashboard  dashboard                        3020:8080  http://localhost:3020/healthz &

wait
