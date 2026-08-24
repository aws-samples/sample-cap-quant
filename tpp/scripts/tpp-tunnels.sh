#!/usr/bin/env bash
# TPP 本地隧道守护:同时保持 LiteLLM / Grafana / Langfuse 的 port-forward,断线各自自动重连。
# 由 launchd(com.tpp.litellm-proxy)常驻运行;手动运行也可(Ctrl-C 退出)。
# 注意:改动本文件后要同步复制到 ~/.local/bin/(launchd 用的是那份副本,TCC 限制)。
#
# 本地端口约定:
#   LiteLLM    http://localhost:14000   (UI: /ui)
#   Grafana    http://localhost:3000
#   Langfuse   http://localhost:3010    (固定 3010,NEXTAUTH_URL 绑定)
#   Prometheus http://localhost:9090
set -u

if ! kubectl config current-context 2>/dev/null | grep -q tpp-dev; then
  echo "当前 kubecontext 不是 tpp-dev,先执行:"
  echo "  aws eks update-kubeconfig --name tpp-dev --region us-west-2"
  exit 1
fi

# 接管:清掉已存在的同类 port-forward,保证单一属主
pkill -f "kubectl port-forward -n litellm" 2>/dev/null
pkill -f "kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana" 2>/dev/null
pkill -f "kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus" 2>/dev/null
pkill -f "kubectl port-forward -n langfuse svc/langfuse-web" 2>/dev/null
sleep 1

forward() { # $1=名字 $2=namespace $3=service $4=本地端口:远端端口
  while true; do
    kubectl port-forward -n "$2" "svc/$3" "$4" 2>&1 | sed "s/^/[$1] /"
    echo "[$1] 断开,3 秒后重连..."
    sleep 3
  done
}

echo "TPP tunnels: litellm->14000  grafana->3000  langfuse->3010  prometheus->9090"
forward litellm    litellm    litellm                          14000:4000 &
forward grafana    monitoring kube-prometheus-stack-grafana    3000:80    &
forward langfuse   langfuse   langfuse-web                     3010:3000  &
forward prometheus monitoring kube-prometheus-stack-prometheus 9090:9090  &

wait
