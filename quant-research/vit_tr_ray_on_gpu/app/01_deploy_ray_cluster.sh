#!/bin/bash
export ECR_URL=$(cd ../infra && terraform output -raw ecr_url)
envsubst < raycluster-with-jfs.yaml | kubectl apply -f -
