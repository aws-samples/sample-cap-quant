#!/bin/bash
ECR_REPO_NAME="kuberay_cnn_gpu"
REGION_ID=$(cd ../infra && terraform output -raw region_id)
AWS_ACCOUNT_ID=$(cd ../infra && terraform output -raw aws_account_id)


# Check that we are running on an x86_64 instance to avoid issues with docker build
# arch=$(uname -m)
# if [[ ! "$arch" = "x86_64" ]]; then
#   echo "Error: please run this script on an x86_64-based instance"
#   exit 1
# fi

# Check if docker is installed
# junk=$(which docker 2>&1 > /dev/null)
# if [[ "$?" -ne 0 ]]; then
#   echo "Error: please install docker and try again. ex: for AL2023 you can run:"
#   echo "  sudo yum install docker -y"
#   echo "  sudo systemctl start docker"
#   echo "  sudo usermod -aG docker ec2-user"
#   echo "  newgrp docker"
#   exit 1
# fi

# Check that AWS CLI is installed and configured
junk=$(aws sts get-caller-identity)
if [[ "$?" -ne 0 ]]; then
  echo "Error: please make sure that the AWS CLI is installed and configured using 'aws configure'."
  exit 1
fi

# Prompt user for desired region
#read -p "Enter the ECR version (e.g.: V0.4): " ecr_version

ecr_version="latest"

region=$REGION_ID
echo $region > .eks_region


# Check if the ECR repository exists
if aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$region" >/dev/null 2>&1; then
  echo "ECR repository '$ECR_REPO_NAME' already exists."

  # Get the ECR_REPO_URI for the existing repository
  ECR_REPO_URI=$(aws ecr describe-repositories --repository-name "$ECR_REPO_NAME" --query 'repositories[0].repositoryUri' --region "$region" --output text)
  echo "Repository URL: $ECR_REPO_URI"
else
  # Create the ECR repository
  aws ecr create-repository --repository-name "$ECR_REPO_NAME" --region "$region"

  # Get the ECR_REPO_URI for the newly created repository
  ECR_REPO_URI=$(aws ecr describe-repositories --repository-name "$ECR_REPO_NAME" --query 'repositories[0].repositoryUri' --region "$region" --output text)
  echo "ECR repository '$ECR_REPO_NAME' created successfully."
  echo "Repository URL: $ECR_REPO_URI"
fi

# Store ECR REPO URI for later use
echo $ECR_REPO_URI > .ecr_repo_uri

# Login to ECR
echo -e "\nLogging in to ECR"
aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin $ECR_REPO_URI
aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.${region}.amazonaws.com/pytorch-training-neuronx

# Login to ECR Public Registry (required for pulling public images)
echo -e "\nLogging in to ECR Public Registry"
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws

# Create and use a new builder instance for multi-arch builds
# docker buildx create --use --name mybuilder --driver docker-container
# docker buildx inspect mybuilder --bootstrap

# If using docker desktop app, run below: (by default)
echo -e "\nBuilding kuberay_gpu docker image" \
  && docker buildx build --platform linux/amd64 -t $ECR_REPO_URI:$ecr_version --build-arg REGION=$region . --push \
  && echo -e "\nImage successfully pushed to ECR"

# If using podman desktop, run below:
# echo -e "\nBuilding kuberay_gpu docker image" \
#   && docker build --platform linux/amd64 -t $ECR_REPO_URI:$ecr_version --build-arg REGION=$region . \
#   && docker push $ECR_REPO_URI:$ecr_version \
#   && echo -e "\nImage successfully pushed to ECR"
 
