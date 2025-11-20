#!/bin/bash
RAW_DATA_S3_URL=$(terraform output -raw raw_data_s3bucket_https_endpoint_url)
CACHE_URL=$(terraform output -raw elastic_cache_redis_endpoint)

kubectl create namespace fluid-system

# Install Helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# Add Fluid repository
helm repo add fluid https://fluid-cloudnative.github.io/charts
helm repo update

# Install Fluid
helm install fluid fluid/fluid \
  --namespace fluid-system \
  --set runtime.juicefs.enabled=true \
  --set csi.kubelet.rootDir=/var/lib/kubelet \
  --set csi.tolerations[0].operator=Exists \
  --set csi.nodeSelector."kubernetes\.io/os"=linux \
  --set csi.useNodeAuthorization=false \
  --set webhook.reinvocationPolicy=IfNeeded

# Create JuiceFS Secret
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: jfs-secret
type: Opaque
stringData:
  name: "jfs"                # JuiceFS File System Name
  metaurl: "${CACHE_URL}:6379/1"     # e.g. "mc7.fkdmm8.0001.use1.cache.amazonaws.com:6379/3"
EOF

# Create JuiceFS Dataset
kubectl apply -f - <<EOF
apiVersion: data.fluid.io/v1alpha1
kind: Dataset
metadata:
  name: jfs-dataset
spec:
  accessModes:
    - ReadWriteMany
  mounts:
    - name: minio
      mountPoint: 'juicefs:///'   
      options:
        bucket: $RAW_DATA_S3_URL        # e.g. "https://s3.us-west-2.amazonaws.com/nov6-vit-2"  to store raw data
        storage: "s3"
      readOnly: false
      encryptOptions:
        - name: metaurl                 # Connection URL for metadata engine. Required.
          valueFrom:
            secretKeyRef:
              name: jfs-secret
              key: metaurl
EOF

# Create JuiceFS Runtime
kubectl apply -f - <<EOF
apiVersion: data.fluid.io/v1alpha1
kind: JuiceFSRuntime
metadata:
  name: jfs-dataset
spec:
  replicas: 1
  tieredstore:
    levels:
      - mediumtype: MEM
        path: /dev/shm
        quota: "1Gi"
        low: "0.1"
EOF


echo "JuiceFS with Fluid deployment completed!"
echo "Check the status with:"
echo "  kubectl get pods -n fluid-system"
echo "  kubectl get dataset"
echo "  kubectl get juicefsruntime"
