#!/bin/bash

# Initialize variables for Terraform deployment with Pod Identity
# Replace placeholder values with your actual configuration

# Basic configuration
export TF_VAR_name="mcp2"
export TF_VAR_region="us-west-2"

# S3 bucket endpoints
export TF_VAR_raw_data_s3bucket_https_endpoint_url="https://s3.us-west-2.amazonaws.com/raw-data-nov16"
export TF_VAR_ray_cluster_result_s3bucket_url="s3://ray-nov16/ray-results"

# ECR repository URL
export TF_VAR_ecr_url="135709585800.dkr.ecr.us-west-2.amazonaws.com/kuberay_cnn_gpu:V0.3"

# Service account for pod identity
export TF_VAR_service_account_name="ray-service-account"
export TF_VAR_iam_role_arn="arn:aws:iam::135709585800:role/ray-pod-identity-role"

echo "Variables initialized with pod identity configuration."
echo "Ensure your pods use service account: $TF_VAR_service_account_name"
