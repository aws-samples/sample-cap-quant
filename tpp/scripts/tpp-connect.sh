#!/usr/bin/env bash
# TPP 本地接入:保持到 LiteLLM proxy 的 port-forward,断线自动重连。
# 用法: ./scripts/tpp-connect.sh [本地端口,默认 14000]
# 注意:改动本文件后要同步复制到 ~/.local/bin/(launchd 服务用的是那份副本)
set -u

PORT="${1:-14000}"

if ! kubectl config current-context 2>/dev/null | grep -q tpp-dev; then
  echo "当前 kubecontext 不是 tpp-dev,先执行:"
  echo "  aws eks update-kubeconfig --name tpp-dev --region us-west-2"
  exit 1
fi

# 端口被占:如果是残留的 litellm port-forward 就接管,否则提示换端口
if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  if pgrep -f "kubectl port-forward -n litellm" >/dev/null 2>&1; then
    echo "发现已有 litellm port-forward,接管之..."
    pkill -f "kubectl port-forward -n litellm"
    sleep 1
  else
    echo "端口 ${PORT} 被其他进程占用:"
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN | tail -n +2
    echo "换个端口运行,如: $0 14000"
    exit 1
  fi
fi

echo "TPP proxy -> http://localhost:${PORT}  (Ctrl-C 退出)"
while true; do
  kubectl port-forward -n litellm svc/litellm "${PORT}:4000"
  echo "port-forward 断开,3 秒后重连..."
  sleep 3
done
