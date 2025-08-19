#!/bin/bash

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
  name: "my-jfs"              
  metaurl: "vk7.fkdmm8.ng.0001.use1.cache.amazonaws.com:6379/1"  
  storage: "s3"                 # 存储类型
  bucket: "https://cnn-aug13.us-east-1.s3.amazonaws.com"           #"https://mybucket.s3.amazonaws.com"
  access-key: {access-key-id}
  secret-key: {secrect-key-id}
EOF

# Create JuiceFS Dataset
kubectl apply -f - <<EOF
apiVersion: data.fluid.io/v1alpha1
kind: Dataset
metadata:
  name: jfs-dataset
spec:
  mounts:
    - name: minio
      mountPoint: "juicefs:///"     # Refers to the subdirectory of JuiceFS, starts with `juicefs://`. Required.
      options:
        bucket: "https://cnn-aug13.us-east-1.s3.amazonaws.com"             # Bucket URL. Not required, if your filesystem is already formatted, can be empty.
        storage: "s3"
      encryptOptions:
        - name: metaurl                 # Connection URL for metadata engine. Required.
          valueFrom:
            secretKeyRef:
              name: jfs-secret
              key: metaurl
        - name: access-key              # Access key of object storage. Not required, if your filesystem is already formatted, can be empty.
          valueFrom:
            secretKeyRef:
              name: jfs-secret
              key: access-key
        - name: secret-key              # Secret key of object storage. Not required, if your filesystem is already formatted, can be empty.
          valueFrom:
            secretKeyRef:
              name: jfs-secret
              key: secret-key
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

# Create JuiceFS DataLoad
kubectl apply -f - <<EOF
apiVersion: data.fluid.io/v1alpha1
kind: DataLoad
metadata:
  name: jfs-dataload
spec:
  dataset:
    name: jfs-dataset
    namespace: default
  loadMetadata: true
  target:
    - path: /
      replicas: 1
  accessModes:
    - ReadWriteMany
EOF

echo "JuiceFS with Fluid deployment completed!"
echo "Check the status with:"
echo "  kubectl get pods -n fluid-system"
echo "  kubectl get dataset"
echo "  kubectl get juicefsruntime"
echo "  kubectl get dataload"
