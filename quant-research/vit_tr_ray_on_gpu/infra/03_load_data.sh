#!/bin/bash

kubectl apply -f data-load-pod.yaml
echo "please wait for data loading..."

while true; do
    size=$(kubectl exec data-load-pod -- stat -c %s /data/cifar-10-python.tar.gz 2>/dev/null)
    if [ "$size" = "170498071" ]; then
        echo "data load success"
        break
    fi
    sleep 10
done
