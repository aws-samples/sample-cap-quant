#!/usr/bin/env bash
# TPP local access: keeps the port-forward to the LiteLLM proxy up, reconnecting automatically on disconnect.
# Usage: ./scripts/tpp-connect.sh [local port]
#        TPP_ENV=prod ./scripts/tpp-connect.sh
# Default port follows the per-environment block in tpp-tunnels.sh: dev 14000, prod 24000.
# Note: after editing this file, copy it to ~/.local/bin/ as well (the launchd service uses that copy)
set -u

TPP_ENV="${TPP_ENV:-dev}"

case "$TPP_ENV" in
  dev)  CLUSTER=tpp-dev;  REGION=us-west-2; DEFAULT_PORT=14000 ;;
  prod) CLUSTER=tpp-prod; REGION=us-east-1; DEFAULT_PORT=24000 ;;
  *)    echo "Unknown TPP_ENV='${TPP_ENV}' (expected 'dev' or 'prod')"; exit 1 ;;
esac

PORT="${1:-$DEFAULT_PORT}"

# Resolve the context explicitly rather than trusting the current one: the reconnect loop below outlives
# a `kubectl config use-context`, which would otherwise re-point a live tunnel at the other cluster.
CTX="${TPP_CONTEXT:-$(kubectl config get-contexts -o name 2>/dev/null | grep -E "(^|/)${CLUSTER}$" | head -1)}"
if [ -z "$CTX" ]; then
  echo "No kubecontext found for cluster '${CLUSTER}'; run this first:"
  echo "  aws eks update-kubeconfig --name ${CLUSTER} --region ${REGION}"
  echo "(or set TPP_CONTEXT to the context name explicitly)"
  exit 1
fi

# Port in use: if it's a leftover litellm port-forward for *this* environment, take it over; otherwise
# suggest another port. Matching on --context is what keeps this from stealing the other env's tunnel.
if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  if pgrep -f "kubectl port-forward --context ${CTX} -n litellm" >/dev/null 2>&1; then
    echo "Found an existing ${TPP_ENV} litellm port-forward, taking it over..."
    pkill -f "kubectl port-forward --context ${CTX} -n litellm"
    sleep 1
  else
    echo "Port ${PORT} is in use by another process:"
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN | tail -n +2
    echo "Run with a different port, e.g.: $0 ${DEFAULT_PORT}"
    exit 1
  fi
fi

echo "TPP proxy [${TPP_ENV}] ${CLUSTER} -> http://localhost:${PORT}  (Ctrl-C to exit)"
while true; do
  kubectl port-forward --context "$CTX" -n litellm svc/litellm "${PORT}:4000"
  echo "port-forward disconnected, reconnecting in 3 seconds..."
  sleep 3
done
