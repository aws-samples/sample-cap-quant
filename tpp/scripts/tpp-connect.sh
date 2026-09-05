#!/usr/bin/env bash
# TPP local access: keeps the port-forward to the LiteLLM proxy up, reconnecting automatically on disconnect.
# Usage: ./scripts/tpp-connect.sh [local port, default 14000]
# Note: after editing this file, copy it to ~/.local/bin/ as well (the launchd service uses that copy)
set -u

PORT="${1:-14000}"

if ! kubectl config current-context 2>/dev/null | grep -q tpp-dev; then
  echo "Current kubecontext is not tpp-dev; run this first:"
  echo "  aws eks update-kubeconfig --name tpp-dev --region us-west-2"
  exit 1
fi

# Port in use: if it's a leftover litellm port-forward, take it over; otherwise suggest another port
if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  if pgrep -f "kubectl port-forward -n litellm" >/dev/null 2>&1; then
    echo "Found an existing litellm port-forward, taking it over..."
    pkill -f "kubectl port-forward -n litellm"
    sleep 1
  else
    echo "Port ${PORT} is in use by another process:"
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN | tail -n +2
    echo "Run with a different port, e.g.: $0 14000"
    exit 1
  fi
fi

echo "TPP proxy -> http://localhost:${PORT}  (Ctrl-C to exit)"
while true; do
  kubectl port-forward -n litellm svc/litellm "${PORT}:4000"
  echo "port-forward disconnected, reconnecting in 3 seconds..."
  sleep 3
done
