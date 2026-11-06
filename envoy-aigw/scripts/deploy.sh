#!/usr/bin/env bash
# Deploy the in-cluster layer of the Envoy AI Gateway dev environment.
# Prereqs: infra/ applied, apps/ applied (pod identity), kubeconfig pointing at aigw-dev.
#
#   scripts/deploy.sh platform   # ALB controller + Envoy Gateway + Envoy AI Gateway (helm)
#   scripts/deploy.sh gateway    # k8s/ai-gateway manifests + API-key Secret
#   scripts/deploy.sh ingress    # render + apply the ALB Ingress (needs ACM cert from apps/ Terraform)
#   scripts/deploy.sh monitoring # kube-prometheus-stack + gateway scrape targets + Grafana dashboards
#   scripts/deploy.sh dashboard  # build/push services/dashboard image, deploy it (then re-run ingress for the public host)
#   scripts/deploy.sh all
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Pinned: the operator shell may carry AWS_REGION=us-west-2 (profile default); everything here lives in us-east-2.
REGION="${AIGW_REGION:-us-east-2}"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
CLUSTER="${CLUSTER:-aigw-dev}"

EG_VERSION="v1.9.3"          # Envoy Gateway
AIGW_VERSION="v1.2.0"        # Envoy AI Gateway
ALB_CHART_VERSION="3.6.2"    # aws-load-balancer-controller chart (IAM policy vendored for v3.6.2)
KPS_CHART_VERSION="92.17.1"  # kube-prometheus-stack (Prometheus Operator v0.94)
DASHBOARD_TAG="0.1.4"        # services/dashboard image tag (= pyproject version)
SCORER_TAG="0.1.1"           # services/scorer image tag (= pyproject version)

log() { printf '\n==> %s\n' "$*"; }

need_context() {
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ "$ctx" == *"$CLUSTER"* ]] || { echo "kubectl context '$ctx' is not $CLUSTER; run: aws eks update-kubeconfig --name $CLUSTER --region $REGION" >&2; exit 1; }
}

platform() {
  need_context
  local vpc_id; vpc_id="$(cd "$ROOT/infra" && terraform output -raw vpc_id)"

  log "AWS Load Balancer Controller $ALB_CHART_VERSION"
  helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
  helm repo update eks >/dev/null
  helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
    --version "$ALB_CHART_VERSION" -n kube-system \
    --set clusterName="$CLUSTER" --set region="$REGION" --set vpcId="$vpc_id" \
    --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller \
    --set replicaCount=1 --wait

  log "Envoy Gateway $EG_VERSION"
  helm upgrade -i eg oci://docker.io/envoyproxy/gateway-helm --version "$EG_VERSION" \
    -n envoy-gateway-system --create-namespace \
    -f "$ROOT/k8s/helm/envoy-gateway-values.yaml"
  kubectl wait --timeout=3m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

  log "Envoy AI Gateway $AIGW_VERSION (CRDs, then controller)"
  helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm --version "$AIGW_VERSION" \
    -n envoy-ai-gateway-system --create-namespace
  helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm --version "$AIGW_VERSION" \
    -n envoy-ai-gateway-system --create-namespace \
    -f "$ROOT/k8s/helm/ai-gateway-values.yaml"
  kubectl wait --timeout=3m -n envoy-ai-gateway-system deployment/ai-gateway-controller --for=condition=Available

  # Envoy Gateway must be restarted once so it picks up the extension-manager config pointing at the AI Gateway controller
  kubectl rollout restart -n envoy-gateway-system deployment/envoy-gateway
  kubectl rollout status -n envoy-gateway-system deployment/envoy-gateway --timeout=3m
}

api_key_secret() {
  # One admin client to start with. Keys are stored in Secrets Manager (aigw/<env>/api-keys) so they survive
  # cluster rebuilds and are never written into the repo.
  local sm_name="aigw/dev/api-keys"
  if ! aws secretsmanager describe-secret --region "$REGION" --secret-id "$sm_name" >/dev/null 2>&1; then
    local key; key="sk-aigw-$(openssl rand -hex 24)"
    aws secretsmanager create-secret --region "$REGION" --name "$sm_name" \
      --secret-string "{\"admin\":\"$key\"}" >/dev/null
    log "created Secrets Manager secret $sm_name with client 'admin'"
  fi
  local json; json="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$sm_name" --query SecretString --output text)"
  local args=(); while IFS='=' read -r k v; do args+=("--from-literal=$k=$v"); done < <(echo "$json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
  kubectl create secret generic aigw-api-keys -n aigw "${args[@]}" --dry-run=client -o yaml | kubectl apply -f -
}

gateway() {
  need_context
  log "AI Gateway resources (namespace aigw)"
  kubectl apply -f "$ROOT/k8s/ai-gateway/00-namespaces.yaml"
  api_key_secret
  kubectl apply -f "$ROOT/k8s/ai-gateway/"
  log "waiting for Envoy data-plane pods"
  kubectl wait --timeout=4m -n envoy-gateway-system pods \
    -l gateway.envoyproxy.io/owning-gateway-name=aigw --for=condition=Ready
  kubectl get gateway -n aigw
  kubectl get aigatewayroute,aiservicebackend,backendsecuritypolicy -n aigw
}

ingress() {
  need_context
  local cert host
  cert="$(cd "$ROOT/apps" && terraform output -raw acm_certificate_arn 2>/dev/null || true)"
  host="$(cd "$ROOT/apps" && terraform output -raw gateway_hostname 2>/dev/null || true)"
  [[ -n "$cert" && -n "$host" ]] || { echo "apps/ has no acm_certificate_arn / gateway_hostname output; set var.ingress and apply first" >&2; exit 1; }
  local cog; cog="$(cd "$ROOT/apps" && terraform output -json cognito 2>/dev/null || echo '{}')"
  export CERT_ARN="$cert" HOSTNAME="$host"
  export COGNITO_USER_POOL_ARN="$(echo "$cog" | jq -r '.user_pool_arn // ""')"
  export COGNITO_CLIENT_ID="$(echo "$cog" | jq -r '.client_id // ""')"
  export COGNITO_DOMAIN="$(echo "$cog" | jq -r '.domain // ""')"

  log "ALB Ingress (group aigw) for $host"
  envsubst '${CERT_ARN} ${HOSTNAME}' < "$ROOT/k8s/ingress/alb-ingress.yaml.tmpl" | kubectl apply -f -
  if kubectl get ns monitoring >/dev/null 2>&1 && [[ -n "$COGNITO_USER_POOL_ARN" ]]; then
    log "Grafana / Prometheus Ingresses (grafana.$host, prometheus.$host)"
    envsubst '${CERT_ARN} ${HOSTNAME} ${COGNITO_USER_POOL_ARN} ${COGNITO_CLIENT_ID} ${COGNITO_DOMAIN}' \
      < "$ROOT/k8s/ingress/monitoring-ingress.yaml.tmpl" | kubectl apply -f -
  fi
  kubectl wait --timeout=5m -n envoy-gateway-system ingress/aigw --for=jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  kubectl get ingress -A | grep -E 'NAMESPACE|alb'
  echo "Now set ingress.alb_ready = true in apps/terraform.tfvars and 'terraform apply' so the Route 53 aliases pick up the ALB."
}

monitoring() {
  need_context
  log "StorageClass gp3 (default)"
  kubectl apply -f "$ROOT/k8s/monitoring/00-storageclass-gp3.yaml"

  log "kube-prometheus-stack $KPS_CHART_VERSION"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community >/dev/null
  helm upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --version "$KPS_CHART_VERSION" -n monitoring --create-namespace \
    -f "$ROOT/k8s/helm/kube-prometheus-stack-values.yaml" --wait --timeout 10m

  log "gateway scrape targets"
  kubectl apply -f "$ROOT/k8s/monitoring/10-monitors.yaml"

  log "Grafana dashboards (ConfigMaps picked up by the sidecar)"
  for f in "$ROOT"/k8s/monitoring/dashboards/*.json; do
    name="$(basename "$f" .json)"
    # Imported dashboards carry an ${DS_PROMETHEUS} input; the chart's datasource uid is `prometheus`.
    sed 's/\${DS_PROMETHEUS}/prometheus/g' "$f" | jq 'del(.__inputs, .__requires)' > "/tmp/dash-$name.json"
    kubectl create configmap "dash-$name" -n monitoring --from-file="$name.json=/tmp/dash-$name.json" \
      --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client \
      | kubectl annotate --local -f - grafana_folder="Envoy AI Gateway" -o yaml --dry-run=client | kubectl apply -f -
    rm -f "/tmp/dash-$name.json"
  done

  echo
  echo "Grafana:    kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80   (admin / see below)"
  echo "Prometheus: kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
  echo "Grafana admin password: kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d"
}

dashboard() {
  need_context
  local repo host
  repo="$(cd "$ROOT/apps" && terraform output -raw dashboard_ecr_repository_url)"
  host="$(cd "$ROOT/apps" && terraform output -raw gateway_hostname 2>/dev/null || echo localhost)"
  local image="$repo:$DASHBOARD_TAG"

  log "build + push $image (linux/amd64)"
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${repo%%/*}" >/dev/null
  docker buildx build --platform linux/amd64 -t "$image" --push "$ROOT/services/dashboard"

  log "dashboard manifests"
  kubectl apply -f "$ROOT/k8s/dashboard/00-namespace-rbac.yaml"
  IMAGE="$image" AIGW_ENV="${AIGW_ENV:-dev}" HOSTNAME="$host" envsubst '${IMAGE} ${AIGW_ENV} ${HOSTNAME}' \
    < "$ROOT/k8s/dashboard/10-deployment.yaml.tmpl" | kubectl apply -f -
  kubectl -n dashboard rollout status deploy/dashboard --timeout=3m
  echo "Tunnel: kubectl -n dashboard port-forward svc/dashboard 3020:80  ->  http://localhost:3020"
  echo "Public: run 'scripts/deploy.sh ingress' (dashboard.$host, behind Cognito)"
}

scorer() {
  need_context
  local repo; repo="$(cd "$ROOT/apps" && terraform output -raw scorer_ecr_repository_url)"
  local image="$repo:$SCORER_TAG"
  log "build + push $image (linux/amd64)"
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${repo%%/*}" >/dev/null
  docker buildx build --platform linux/amd64 -t "$image" --push "$ROOT/services/scorer"
  log "scorer manifests"
  kubectl apply -f "$ROOT/k8s/scorer/00-namespace-rbac.yaml"
  IMAGE="$image" envsubst '${IMAGE}' < "$ROOT/k8s/scorer/10-deployment.yaml.tmpl" | kubectl apply -f -
  kubectl -n scorer rollout status deploy/scorer --timeout=3m
  kubectl -n scorer logs deploy/scorer --tail=5
}

case "${1:-}" in
  platform)   platform ;;
  gateway)    gateway ;;
  ingress)    ingress ;;
  monitoring) monitoring ;;
  dashboard)  dashboard ;;
  scorer)     scorer ;;
  all)        platform; gateway; monitoring; dashboard; scorer ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
