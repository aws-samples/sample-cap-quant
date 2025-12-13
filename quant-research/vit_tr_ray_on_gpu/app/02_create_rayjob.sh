export RAY_CLUSTER_RESULT_S3BUCKET_URL=$(cd ../infra && terraform output -raw ray_cluster_result_s3bucket_url)
envsubst < rayjob-training.yaml | kubectl create -f -
