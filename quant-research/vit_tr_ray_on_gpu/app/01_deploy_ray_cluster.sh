#!/bin/bash

# 从Terraform输出获取ECR URL
export ECR_URL=$(cd ../infra && terraform output -raw ecr_url)

# 使用envsubst替换模板变量并部署
envsubst < raycluster-with-jfs.yaml | kubectl apply -f -
