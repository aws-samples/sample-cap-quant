#!/bin/bash

# Initialize variables for Terraform deployment
# Replace placeholder values with your actual configuration

# Basic configuration
export TF_VAR_name="your-cluster-name"
export TF_VAR_region="us-west-2"

# AWS credentials (use AWS CLI or IAM roles instead of hardcoding)
export TF_VAR_accesskey="YOUR_ACCESS_KEY"
export TF_VAR_secrectkey="YOUR_SECRET_KEY"

# S3 bucket endpoints
export TF_VAR_raw_data_s3bucket_https_endpoint_url="https://s3.us-west-2.amazonaws.com/your-raw-data-bucket"

# ECR repository URL
export TF_VAR_ecr_url="YOUR_ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/your-repo:tag"

echo "Variables initialized."
