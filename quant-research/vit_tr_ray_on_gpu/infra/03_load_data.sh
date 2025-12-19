#!/bin/bash

kubectl apply -f data-load-pod.yaml
kubectl wait --for=condition=Ready pod/data-load-pod --timeout=160s
echo "please wait for data loading..."

if kubectl exec data-load-pod -- ls /data/cifar-10-python.tar.gz &>/dev/null; then
    echo "data loading success"
else
    echo "data loading failed"
fi
