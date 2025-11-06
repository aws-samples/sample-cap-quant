# Quant Research using Amazon EKS,Kuberay,CNCF Fluid (using GPU)

## Overview
This project aims to investigate the feasibility of performing quantitative research by leveraging [Amazon Elastic Kubernetes Service (EKS)](https://aws.amazon.com/eks/), [KubeRay](https://github.com/ray-project/kuberay), and [CNCF Fluid](https://github.com/fluid-cloudnative/fluid) as the underlying infrastructure components. Both Amazon Trainium and Nvidia GPU have been used for deep learning model training.

## Pre-requisites
*Make sure the laptop or EC2 server has the right permission to access the resources on AWS account.*
### **Use MacOS laptop**
  - install AWS CLI
    ```sh
    # Using Homebrew
    brew install awscli
    # Verify installation
    aws --version
    ```
  - install kubectl
    ```sh
    # Using Homebrew
    brew install kubectl
    # Verify installation
    kubectl version --client
    ```
  - install eksctl
    ```sh
    # Using Homebrew
    brew tap weaveworks/tap
    brew install weaveworks/tap/eksctl
    # Verify installation
    eksctl version
    ```
  - install Helm
    ```sh
    # Using Homebrew
    brew install helm
    # Verify installation
    helm version
    ```
  - install Terraform
    ```sh
    # Using Homebrew
    brew tap hashicorp/tap
    brew install hashicorp/tap/terraform
    # Verify installation
    terraform version
    ```
### **Use Linux OS EC2 Server**
  - Install AWS CLI
    ```sh
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install --update
    ```
  - Install kubectl
    ```sh
    curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.30.4/2024-09-11/bin/linux/amd64/kubectl
    chmod +x ./kubectl
    mkdir -p $HOME/bin && cp ./kubectl $HOME/bin/kubectl && export PATH=$HOME/bin:$PATH
    echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
  - Install eksctl
    ```sh
    # for ARM systems, set ARCH to: `arm64`, `armv6` or `armv7`
    ARCH=amd64
    PLATFORM=$(uname -s)_$ARCH
    curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
    # (Optional) Verify checksum
    curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" | grep $PLATFORM | sha256sum --check
    tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz
    sudo mv /tmp/eksctl /usr/local/bin
  - Install Helm
    ```sh
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
  - Install Terraform
    ```sh
    # Download the latest Terraform binary
    wget https://releases.hashicorp.com/terraform/1.9.4/terraform_1.9.4_linux_amd64.zip
    # Install unzip if not already installed
    sudo apt-get update && sudo apt-get install -y unzip
    # Unzip the downloaded file
    unzip terraform_1.9.4_linux_amd64.zip
    # Move the binary to a directory in your PATH
    sudo mv terraform /usr/local/bin/
    # Make it executable
    sudo chmod +x /usr/local/bin/terraform
    # Verify installation
    terraform version
    # Clean up the downloaded zip file
    rm terraform_1.9.4_linux_amd64.zip

## Deployment - vit_tr_ray_on_gpu
- Clone the repo
  ```sh
  git clone https://github.com/aws-samples/sample-cap-quant.git
  ```
- EKS Cluster Provision
  ```sh
  cd quant-research/vit_tr_ray_on_gpu/infra
  chmod +x 1_install_platform.sh
  ./1_install_platform.sh
  ```
  It takes 20+ minutes for the resource to be provisioned and setup.
- add EKS cluster context in the jumpserver, so that the jumpserver can access EKS cluster.
  ```sh
  aws eks --region us-east-1 update-kubeconfig --name <eks cluster name>
  ```
- revise Redis Security Group, test EKS Cluster EC2 nodes able to visit port 6379.
  ```
  redis-cli -h <redis endpoint url> -p 6379 ping
  ```

- Revise 2_install_fluid.sh according to your environment's specific context.
  - 1/Get the endpoint url of the provisioned Redis cluster from previous step, and revise 2_install_fluid.sh per below;
  - 2/Configure specific s3 bucket for meta data storage location as well;
  - 3/Configure specific AK & SK;
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: jfs-secret
type: Opaque
stringData:
  name: "jfs"                # JuiceFS File System Name
  metaurl: "<redis cluster endpoint url>:6379/1"     # e.g. "mc7.fkdmm8.0001.use1.cache.amazonaws.com:6379/3"
  storage: "s3"                 # Backend Storage Type
  bucket: "<s3 bucket https endpoint url1>"           # e.g. "https://o3-vit.s3.amazonaws.com", to store meta data
  access-key: {access-key-id}                     # AWS Account Access Key ID
  secret-key: {secrect-key-id}                     # AWS Account Secret Key ID
```
  
  - 4/Configure specific s3 bucket for raw data storage location.
```yaml
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
        bucket: "<s3 bucket https endpoint url2>"        # e.g. "https://o5-vit.s3.amazonaws.com"m to store raw data
        storage: "s3"
      readOnly: false
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
```


- JuiceFS@Fluid Setup
  ```sh
  cd quant-research/vit_tr_ray_on_gpu/infra
  chmod -x 2_install_fluid.sh
  ./2_install_fluid.sh
  ```
- Training Data Caching
  - Run [get_cifar10.py](https://github.com/aws-samples/sample-cap-quant/blob/main/quant-research/vit_tr_ray_on_gpu/training-data/get_cifar10.py) to download the training data to local.
  - Copy the training data to S3 bucket using command below
    ```sh
    cd /training-data
    aws s3 cp . s3://<s3 bucket name>/ --recursive
    ```
    The dir structure is shown per below:
    ```txt
    --training-data
            |--data.lock
            |--data
                 |--cifar-10-python.tar.gz
                 |--cifar-10-batched-py
                             |--batches.meta
                             |--data_batch_1
                                ... ...
                             |--data_batch_5
                             |--readme.html
                             |--test_batch 
    ```
  - Initially, cache these data on-to JuiceFS dataset jfs-data
    - Create a pod using [data-load-pod.yaml](https://github.com/aws-samples/sample-cap-quant/blob/main/quant-research/vit_tr_ray_on_gpu/infra/data-load-pod.yaml)
      ```sh
      kubectl create -f data-load-pod.yaml
      ```
    - Login to that pod to load the training data to JuiceFS mount point /data
      ```sh
      kubectl exec -it <data-load-pod name> -- /bin/bash
      cd /
      aws s3 cp aws s3 cp s3://<s3 bucket name>/data.lock data.lock
      cd /data
      aws s3 cp aws s3 cp s3://<s3 bucket name>/data . --recursive
      ```
  
- Raycluster Creation
  ```sh
  cd quant-research/vit_tr_ray_on_gpu/app
  kubectl create -f raycluster-with-jfs.yaml
  ```
- Rayjob Submission
  ```sh
  cd quant-research/vit_tr_ray_on_gpu/app
  #model train
  kubectl create -f 1-rayjob-training.yaml
  ```

## Observability
- Ray Dashboard
  ```sh
  kubectl port-forward service/kuberay-gpu-head-svc 8265:8265
  ```
- Prometheus Dashboard
  ```sh
  kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n kube-prometheus-stack
  ```
- Grafana Dashboard
  ```sh
  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n kube-prometheus-stack
  ```
## Clean up
```sh
cd quant-research/vit_tr_ray_on_gpu/infra #cd quant-research/llama_ptr_ray_on_trn1/infra
./cleanup.sh
```

# Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

# License

This library is licensed under the MIT-0 License. See the [LICENSE](https://github.com/aws-samples/sample-cap-quant/blob/main/LICENSE) file.



