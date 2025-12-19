#!/bin/bash
set -e

# Load variables
CLUSTERNAME=$(terraform output -raw name)
REGION=$(terraform output -raw region_id)

echo "=== Cleanup for cluster: $CLUSTERNAME in region: $REGION ==="

# Get VPC ID
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$CLUSTERNAME" --query 'Vpcs[0].VpcId' --output text --region $REGION 2>/dev/null || echo "None")
echo "VPC ID: $VPC_ID"

# Step 1: Configure kubectl if EKS exists
echo "=== Step 1: Configuring kubectl ==="
if aws eks describe-cluster --name $CLUSTERNAME --region $REGION &>/dev/null; then
  aws eks update-kubeconfig --name $CLUSTERNAME --region $REGION
  
  # Delete K8s resources that create AWS resources
  echo "Deleting Kubernetes resources..."
  kubectl delete rayjob -A --all --wait=false --timeout=30s 2>/dev/null || true
  kubectl delete rayservice -A --all --wait=false --timeout=30s 2>/dev/null || true
  kubectl delete ingress -A --all --wait=false --timeout=30s 2>/dev/null || true
  kubectl delete svc -A -l 'service.kubernetes.io/aws-load-balancer-type' --wait=false --timeout=30s 2>/dev/null || true
  
  # Uninstall Helm releases
  echo "Uninstalling Helm releases..."
  for release in $(helm list -A --short 2>/dev/null); do
    ns=$(helm list -A | grep "^$release" | awk '{print $2}')
    echo "Uninstalling $release from $ns..."
    helm uninstall "$release" -n "$ns" --wait=false --timeout=30s 2>/dev/null || true
  done
  sleep 15
fi

# Step 2: Delete Load Balancers in VPC
echo "=== Step 2: Deleting Load Balancers ==="
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  for arn in $(aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text --region $REGION 2>/dev/null); do
    echo "Deleting LB: $arn"
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region $REGION 2>/dev/null || true --no-cli-pager
  done
  sleep 10
  
  # Delete Target Groups
  echo "Deleting Target Groups..."
  for arn in $(aws elbv2 describe-target-groups --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text --region $REGION 2>/dev/null); do
    echo "Deleting TG: $arn"
    aws elbv2 delete-target-group --target-group-arn "$arn" --region $REGION 2>/dev/null || true --no-cli-pager
  done
fi

# Step 3: Delete ElastiCache
echo "=== Step 3: Deleting ElastiCache ==="
if aws elasticache describe-cache-clusters --cache-cluster-id $CLUSTERNAME --region $REGION &>/dev/null; then
  echo "Deleting ElastiCache cluster: $CLUSTERNAME"
  aws elasticache delete-cache-cluster --cache-cluster-id $CLUSTERNAME --region $REGION 2>/dev/null || true --no-cli-pager
  echo "Waiting for ElastiCache deletion (this may take a few minutes)..."
  aws elasticache wait cache-cluster-deleted --cache-cluster-id $CLUSTERNAME --region $REGION 2>/dev/null || true --no-cli-pager
fi

# Step 4: Delete EKS Node Groups first
echo "=== Step 4: Deleting EKS Node Groups ==="
if aws eks describe-cluster --name $CLUSTERNAME --region $REGION &>/dev/null; then
  for ng in $(aws eks list-nodegroups --cluster-name $CLUSTERNAME --query 'nodegroups[]' --output text --region $REGION 2>/dev/null); do
    echo "Deleting node group: $ng"
    aws eks delete-nodegroup --cluster-name $CLUSTERNAME --nodegroup-name $ng --region $REGION 2>/dev/null || true --no-cli-pager
  done
  
  # Wait for node groups to be deleted
  echo "Waiting for node groups deletion..."
  while true; do
    ngs=$(aws eks list-nodegroups --cluster-name $CLUSTERNAME --query 'nodegroups[]' --output text --region $REGION 2>/dev/null)
    [ -z "$ngs" ] && break
    echo "Still waiting for node groups: $ngs"
    sleep 30
  done
fi

# Step 5: Delete EKS Cluster
echo "=== Step 5: Deleting EKS Cluster ==="
if aws eks describe-cluster --name $CLUSTERNAME --region $REGION &>/dev/null; then
  echo "Deleting EKS cluster: $CLUSTERNAME"
  aws eks delete-cluster --name $CLUSTERNAME --region $REGION 2>/dev/null || true --no-cli-pager
  
  echo "Waiting for EKS cluster deletion..."
  aws eks wait cluster-deleted --name $CLUSTERNAME --region $REGION 2>/dev/null || true --no-cli-pager
fi

# Step 6: Delete VPC Endpoints
echo "=== Step 6: Deleting VPC Endpoints ==="
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  endpoints=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query 'VpcEndpoints[].VpcEndpointId' --output text --region $REGION 2>/dev/null)
  for ep in $endpoints; do
    echo "Deleting VPC Endpoint: $ep"
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $ep --region $REGION 2>/dev/null || true --no-cli-pager
  done
  sleep 5
fi

# Step 7: Delete NAT Gateways
echo "=== Step 7: Deleting NAT Gateways ==="
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  for nat in $(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" --query 'NatGateways[].NatGatewayId' --output text --region $REGION 2>/dev/null); do
    echo "Deleting NAT Gateway: $nat"
    aws ec2 delete-nat-gateway --nat-gateway-id $nat --region $REGION 2>/dev/null || true --no-cli-pager
  done
  
  # Wait for NAT Gateways to be deleted
  echo "Waiting for NAT Gateway deletion..."
  while true; do
    nats=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending,deleting" --query 'NatGateways[].NatGatewayId' --output text --region $REGION 2>/dev/null)
    [ -z "$nats" ] && break
    echo "Still waiting for NAT Gateways..."
    sleep 15
  done
fi

# Step 8: Delete Network Interfaces (orphaned ENIs)
echo "=== Step 8: Deleting orphaned Network Interfaces ==="
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  for eni in $(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text --region $REGION 2>/dev/null); do
    echo "Deleting ENI: $eni"
    aws ec2 delete-network-interface --network-interface-id $eni --region $REGION 2>/dev/null || true --no-cli-pager
  done
fi

# Step 9: Detach and Delete Internet Gateway
echo "=== Step 9: Deleting Internet Gateway ==="
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  for igw in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[].InternetGatewayId' --output text --region $REGION 2>/dev/null); do
    echo "Detaching and deleting IGW: $igw"
    aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $VPC_ID --region $REGION 2>/dev/null || true --no-cli-pager
    aws ec2 delete-internet-gateway --internet-gateway-id $igw --region $REGION 2>/dev/null || true --no-cli-pager
  done
fi

# Step 10: Release Elastic IPs
echo "=== Step 10: Releasing Elastic IPs ==="
for eip in $(aws ec2 describe-addresses --filters "Name=tag:Blueprint,Values=$CLUSTERNAME" --query 'Addresses[].AllocationId' --output text --region $REGION 2>/dev/null); do
  echo "Releasing EIP: $eip"
  aws ec2 release-address --allocation-id $eip --region $REGION 2>/dev/null || true --no-cli-pager
done

# Also release unassociated EIPs that might be orphaned
for eip in $(aws ec2 describe-addresses --filters "Name=domain,Values=vpc" --query 'Addresses[?AssociationId==null].AllocationId' --output text --region $REGION 2>/dev/null); do
  echo "Releasing orphaned EIP: $eip"
  aws ec2 release-address --allocation-id $eip --region $REGION 2>/dev/null || true --no-cli-pager
done

# Step 11: Delete Subnets
echo "=== Step 11: Deleting Subnets ==="
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  for subnet in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text --region $REGION 2>/dev/null); do
    echo "Deleting Subnet: $subnet"
    aws ec2 delete-subnet --subnet-id $subnet --region $REGION 2>/dev/null || true --no-cli-pager
  done
fi

# Step 12: Delete Route Tables (non-main)
echo "=== Step 12: Deleting Route Tables ==="
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  for rtb in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text --region $REGION 2>/dev/null); do
    # Disassociate first
    for assoc in $(aws ec2 describe-route-tables --route-table-ids $rtb --query 'RouteTables[].Associations[?!Main].RouteTableAssociationId' --output text --region $REGION 2>/dev/null); do
      aws ec2 disassociate-route-table --association-id $assoc --region $REGION 2>/dev/null || true --no-cli-pager
    done
    echo "Deleting Route Table: $rtb"
    aws ec2 delete-route-table --route-table-id $rtb --region $REGION 2>/dev/null || true --no-cli-pager
  done
fi

# Step 13: Delete Security Groups (non-default)
echo "=== Step 13: Deleting Security Groups ==="
# if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
#   # First, remove all ingress/egress rules that reference other SGs
#   for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region $REGION 2>/dev/null); do
#     echo "Revoking rules for SG: $sg"
#     # Revoke ingress rules
#     aws ec2 describe-security-groups --group-ids $sg --query 'SecurityGroups[0].IpPermissions' --output json --region $REGION 2>/dev/null | \
#       jq -c 'if . then . else [] end' | \
#       xargs -I {} aws ec2 revoke-security-group-ingress --group-id $sg --ip-permissions '{}' --region $REGION 2>/dev/null || true > c.txt
#     # Revoke egress rules
#     aws ec2 describe-security-groups --group-ids $sg --query 'SecurityGroups[0].IpPermissionsEgress' --output json --region $REGION 2>/dev/null | \
#       jq -c 'if . then . else [] end' | \
#       xargs -I {} aws ec2 revoke-security-group-egress --group-id $sg --ip-permissions '{}' --region $REGION 2>/dev/null || true > c.txt
#   done
  
#   # Now delete security groups
#   for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region $REGION 2>/dev/null); do
#     echo "Deleting Security Group: $sg"
#     aws ec2 delete-security-group --group-id $sg --region $REGION 2>/dev/null || true > c.txt
#   done
# fi

if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  # First, remove all ingress/egress rules that reference other SGs
  for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region $REGION 2>/dev/null); do
    echo "Revoking inbound rules for $sg..."
    INGRESS_RULES=$(aws ec2 describe-security-groups --group-ids $sg --query "SecurityGroups[0].IpPermissions" --region $REGION --output json)
    if [ "$INGRESS_RULES" != "[]" ]; then
        aws ec2 revoke-security-group-ingress --group-id $sg --ip-permissions "$INGRESS_RULES" --region $REGION --no-cli-pager
    else
        echo "No inbound rules to revoke."
    fi

    # 2. Remove all Outbound (Egress) Rules
    echo "Revoking outbound rules for $sg..."
    EGRESS_RULES=$(aws ec2 describe-security-groups --group-ids $sg --query "SecurityGroups[0].IpPermissionsEgress" --region $REGION --output json)
    if [ "$EGRESS_RULES" != "[]" ]; then
        aws ec2 revoke-security-group-egress --group-id $sg --ip-permissions "$EGRESS_RULES" --region $REGION --no-cli-pager
    else
        echo "No outbound rules to revoke."
    fi
  done

  # Now delete security groups
  for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region $REGION ); do
    echo "Deleting Security Group: $sg"
    aws ec2 delete-security-group --group-id $sg --region $REGION --no-cli-pager || true --no-cli-pager
  done
fi

# Step 14: Delete VPC
echo "=== Step 14: Deleting VPC ==="
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  echo "Deleting VPC: $VPC_ID"
  aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION 2>/dev/null || true --no-cli-pager
fi

# Step 15: Cleanup remaining Terraform state
echo "=== Step 15: Cleaning up Terraform state ==="
if [ -f "terraform.tfstate" ]; then
  terraform init -reconfigure 2>/dev/null || true --no-cli-pager
  terraform destroy -auto-approve 2>/dev/null || true --no-cli-pager
fi

# Step 16: Delete CloudWatch Log Groups
echo "=== Step 16: Deleting CloudWatch Log Groups ==="
for lg in $(aws logs describe-log-groups --log-group-name-prefix "/aws/eks/$CLUSTERNAME" --query 'logGroups[].logGroupName' --output text --region $REGION 2>/dev/null); do
  echo "Deleting Log Group: $lg"
  aws logs delete-log-group --log-group-name "$lg" --region $REGION 2>/dev/null || true --no-cli-pager
done
for lg in $(aws logs describe-log-groups --log-group-name-prefix "/aws/elasticache/$CLUSTERNAME" --query 'logGroups[].logGroupName' --output text --region $REGION 2>/dev/null); do
  echo "Deleting Log Group: $lg"
  aws logs delete-log-group --log-group-name "$lg" --region $REGION 2>/dev/null || true --no-cli-pager
done

echo "=== Cleanup@Script Complete ==="
