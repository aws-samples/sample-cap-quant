#!/bin/bash

# Initialize variables for Terraform deployment with Pod Identity
# Replace placeholder values with your actual configuration

# Basic configuration
export TF_VAR_name="mcp2"
export TF_VAR_region="us-west-2"
export TF_VAR_s3_bucket_name1="<s3-bucket-name1>"
export TF_VAR_s3_bucket_name2="<s3-bucket-name2>"
export TF_VAR_aws_account_id="<aws-account-id>"
export TF_VAR_prefix_name="<prefix-name>"

# S3 bucket endpoints
export TF_VAR_raw_data_s3bucket_https_endpoint_url="https://s3.us-west-2.amazonaws.com/${TF_VAR_s3_bucket_name1}"
export TF_VAR_ray_cluster_result_s3bucket_url="s3://${TF_VAR_s3_bucket_name2}/${TF_VAR_prefix_name}"

# ECR repository URL
export TF_VAR_ecr_url="${TF_VAR_aws_account_id}.dkr.ecr.us-west-2.amazonaws.com/kuberay_cnn_gpu:V0.3"

# Service account for pod identity
export TF_VAR_service_account_name="ray-service-account"
export TF_VAR_iam_role_arn="arn:aws:iam::${TF_VAR_aws_account_id}:role/ray-pod-identity-role"

echo "Variables initialized with pod identity configuration."
echo "Ensure your pods use service account: $TF_VAR_service_account_name"
