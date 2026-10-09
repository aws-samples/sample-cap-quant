#!/usr/bin/env bash
# TPP local tunnel daemon: keeps the LiteLLM / Grafana / Langfuse / Prometheus / Dashboard port-forwards up
# simultaneously, each reconnecting on its own after a disconnect, and probes each tunnel's local health,
# restarting any zombie (process alive, forwarding dead) automatically.
# Runs persistently under launchd (com.tpp.litellm-proxy); manual runs also work (Ctrl-C to exit).
# Note: after editing this file, copy it to ~/.local/bin/ as well (launchd uses that copy, due to TCC restrictions).
#
# Usage:
#   ./tpp-tunnels.sh              # TPP_ENV defaults to dev
#   TPP_ENV=prod ./tpp-tunnels.sh
#
# dev and prod use disjoint local port blocks, so both can be tunneled at the same time and the port
# itself tells you which environment you are looking at. A localhost URL carries no other environment
# identity -- do not rely on "which context was current when I started this".
#
#   service     dev     prod
#   LiteLLM    14000    24000   (UI: /ui)
#   Grafana     3000     4000
#   Langfuse    3010     4010   bound to NEXTAUTH_URL; must match apps var langfuse.nextauth_url
#   Prometheus  9090     9091
#   Dashboard   3020     4020
set -u

TPP_ENV="${TPP_ENV:-dev}"

case "$TPP_ENV" in
  dev)
    CLUSTER=tpp-dev
    REGION=us-west-2
    P_LITELLM=14000; P_GRAFANA=3000; P_LANGFUSE=3010; P_PROM=9090; P_DASH=3020
    ;;
  prod)
    CLUSTER=tpp-prod
    REGION=us-east-1
    P_LITELLM=24000; P_GRAFANA=4000; P_LANGFUSE=4010; P_PROM=9091; P_DASH=4020
    ;;
  *)
    echo "Unknown TPP_ENV='${TPP_ENV}' (expected 'dev' or 'prod')"
    exit 1
    ;;
esac

# Resolve the kubecontext for this environment explicitly and pass --context to every port-forward.
# Relying on the *current* context is not enough: the reconnect loops below outlive a `kubectl config
# use-context`, so a context switch would silently re-point live tunnels at the other cluster.
CTX="${TPP_CONTEXT:-$(kubectl config get-contexts -o name 2>/dev/null | grep -E "(^|/)${CLUSTER}$" | head -1)}"
if [ -z "$CTX" ]; then
  echo "No kubecontext found for cluster '${CLUSTER}'; run this first:"
  echo "  aws eks update-kubeconfig --name ${CLUSTER} --region ${REGION}"
  echo "(or set TPP_CONTEXT to the context name explicitly)"
  exit 1
fi

# Take over: kill any existing port-forwards of the same kind *for this environment only*.
# The --context in the pattern is what keeps this from killing the other environment's tunnels.
for ns_svc in "litellm" \
              "monitoring svc/kube-prometheus-stack-grafana" \
              "monitoring svc/kube-prometheus-stack-prometheus" \
              "langfuse svc/langfuse-web" \
              "dashboard svc/dashboard"; do
  pkill -f "kubectl port-forward --context ${CTX} -n ${ns_svc}" 2>/dev/null
done
sleep 1

forward() { # $1=name $2=namespace $3=service $4=local-port:remote-port $5=health-probe URL
  while true; do
    kubectl port-forward --context "$CTX" -n "$2" "svc/$3" "$4" > >(sed "s/^/[$1] /") 2>&1 &
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

echo "TPP tunnels [${TPP_ENV}] cluster=${CLUSTER} region=${REGION}"
echo "  litellm->${P_LITELLM}  grafana->${P_GRAFANA}  langfuse->${P_LANGFUSE}  prometheus->${P_PROM}  dashboard->${P_DASH}"
forward litellm    litellm    litellm                          "${P_LITELLM}:4000"  "http://localhost:${P_LITELLM}/health/liveliness" &
forward grafana    monitoring kube-prometheus-stack-grafana    "${P_GRAFANA}:80"    "http://localhost:${P_GRAFANA}/api/health" &
forward langfuse   langfuse   langfuse-web                     "${P_LANGFUSE}:3000" "http://localhost:${P_LANGFUSE}/api/public/health" &
forward prometheus monitoring kube-prometheus-stack-prometheus "${P_PROM}:9090"     "http://localhost:${P_PROM}/-/healthy" &
forward dashboard  dashboard  dashboard                        "${P_DASH}:8080"     "http://localhost:${P_DASH}/healthz" &

wait
