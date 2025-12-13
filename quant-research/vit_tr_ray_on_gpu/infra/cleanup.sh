#!/bin/bash

TERRAFORM_COMMAND="terraform destroy -auto-approve"
CLUSTERNAME=$TF_VAR_name
REGION=$TF_VAR_region

echo "Destroying Terraform $CLUSTERNAME"
echo "Destroying RayService..."

TMPFILE=$(mktemp)
terraform output -raw configure_kubectl > "$TMPFILE"
if [[ ! $(cat $TMPFILE) == *"No outputs found"* ]]; then
  source "$TMPFILE"
  
  echo "Uninstalling Helm releases..."
  helm list -A --short | while read release; do
    namespace=$(helm list -A | grep "^$release" | awk '{print $2}')
    echo "Uninstalling $release from namespace $namespace..."
    helm uninstall "$release" -n "$namespace" --wait=false --timeout=30s || true
  done
  
  echo "Deleting Ray resources..."
  kubectl delete rayjob -A --all --wait=false --timeout=30s || true
  kubectl delete rayservice -A --all --wait=false --timeout=30s || true
  
  sleep 10
fi

targets=(
  "module.eks"
  "module.vpc"
)

for target in "${targets[@]}"
do
  echo "Destroying module $target..."
  destroy_output=$($TERRAFORM_COMMAND -target="$target" 2>&1 | tee /dev/tty)
  if [[ ${PIPESTATUS[0]} -eq 0 && $destroy_output == *"Destroy complete"* ]]; then
    echo "SUCCESS: Terraform destroy of $target completed successfully"
  else
    echo "FAILED: Terraform destroy of $target failed"
    exit 1
  fi
done

echo "Destroying Load Balancers..."
for arn in $(aws resourcegroupstaggingapi get-resources \
  --resource-type-filters elasticloadbalancing:loadbalancer \
  --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTERNAME" \
  --query 'ResourceTagMappingList[].ResourceARN' \
  --region $REGION \
  --output text); do \
    aws elbv2 delete-load-balancer --region $REGION --load-balancer-arn "$arn"; \
  done

echo "Destroying Target Groups..."
for arn in $(aws resourcegroupstaggingapi get-resources \
  --resource-type-filters elasticloadbalancing:targetgroup \
  --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTERNAME" \
  --query 'ResourceTagMappingList[].ResourceARN' \
  --region $REGION \
  --output text); do \
    aws elbv2 delete-target-group --region $REGION --target-group-arn "$arn"; \
  done

echo "Destroying Security Groups..."
for sg in $(aws ec2 describe-security-groups \
  --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTERNAME" \
  --region $REGION \
  --query 'SecurityGroups[].GroupId' --output text); do \
    aws ec2 delete-security-group --no-cli-pager --region $REGION --group-id "$sg"; \
  done

echo "Destroying remaining resources..."
destroy_output=$($TERRAFORM_COMMAND -var="region=$REGION" 2>&1 | tee /dev/tty)
if [[ ${PIPESTATUS[0]} -eq 0 && $destroy_output == *"Destroy complete"* ]]; then
  echo "SUCCESS: Terraform destroy of all modules completed successfully"
else
  echo "FAILED: Terraform destroy of all modules failed"
  exit 1
fi
