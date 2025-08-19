## Quant Research using Amazon EKS, Kuberay,CNCF Fluid

# Overview
This project aims to investigate the feasibility of performing quantitative research by leveraging [Amazon Elastic Kubernetes Service (EKS)](https://aws.amazon.com/eks/), [KubeRay](https://github.com/ray-project/kuberay), and [CNCF Fluid](https://github.com/fluid-cloudnative/fluid) as the underlying infrastructure components.

# Pre-requisites
*Make sure the laptop or EC2 server has the right permission to access the resources on AWS account.*
- **Use MacOS laptop**
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
- **Use Linux OS EC2 Server**
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

# Deployment - llama_ptr_ray_on_trn1
- EKS Cluster Provision
  ```sh
  cd quant-research/llama_ptr_ray_on_trn1/infra
  ./1_install_platform.sh
  ```
  It takes 20+ minutes for the resource to be provisioned and setup.
- Get the endpoint url of the provisioned valkey cluster from previous step, and revise 2_install_fluid.sh per below. Configure specific s3 bucket for s3 data storage location as well
  ```yaml
  apiVersion: v1
  kind: Secret
  metadata:
    name: jfs-secret
  type: Opaque
  stringData:
    name: "my-jfs"               
    metaurl: "<valkey cluster endpoint url>:6379/1"
    storage: "s3"                
    bucket: "https://<s3 bucket name>.s3.amazonaws.com"
    access-key: {access-key-id}
    secret-key: {secrect-key-id}
  ```
- JuiceFS@Fluid Setup
  ```sh
  cd quant-research/llama_ptr_ray_on_trn1/infra
  ./2_install_fluid.sh
  ```
- Raycluster Creation
  ```sh
  cd quant-research/llama_ptr_ray_on_trn1/app
  kubectl create -f llama2-pretrain-trn1-raycluster.yaml  
  ```
- Rayjob Submission
  ```sh
  cd quant-research/llama_ptr_ray_on_trn1/app
  #generate test data
  kubectl create -f 1-llama2-pretrain-trn1-rayjob-create-test-data.yaml
  #model precompile
  kubectl create -f  2-llama2-pretrain-trn1-rayjob-precompilation.yaml
  #model pretrain
  kubectl create -f 3-llama2-pretrain-trn1-rayjob.yaml
  ```
# Deployment - vit_tr_ray_on_gpu
- EKS Cluster Provision
  ```sh
  cd quant-research/vit_tr_ray_on_gpu/infra
  ./1_install_platform.sh
  ```
  It takes 20+ minutes for the resource to be provisioned and setup.
- Get the endpoint url of the provisioned valkey cluster from previous step, and revise 2_install_fluid.sh per below. Configure specific s3 bucket for s3 data storage location as well
  ```yaml
  apiVersion: v1
  kind: Secret
  metadata:
    name: jfs-secret
  type: Opaque
  stringData:
    name: "my-jfs"               
    metaurl: "<valkey cluster endpoint url>:6379/1"
    storage: "s3"                
    bucket: "https://<s3 bucket name>.s3.amazonaws.com"
    access-key: {access-key-id}
    secret-key: {secrect-key-id}
  ```
- JuiceFS@Fluid Setup
  ```sh
  cd quant-research/vit_tr_ray_on_gpu/infra
  ./2_install_fluid.sh
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
# Observability
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
# Clean up
```sh
cd quant-research/vit_tr_ray_on_gpu/infra #cd quant-research/llama_ptr_ray_on_trn1/infra
./cleanup.sh
```

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

