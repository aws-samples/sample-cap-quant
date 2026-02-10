# Quant Research using Amazon EKS,Kuberay,Pytorch,CNCF Fluid (using Trainium1)

## Overview
This project aims to investigate the feasibility of performing quantitative research by leveraging [Amazon Elastic Kubernetes Service (EKS)](https://aws.amazon.com/eks/), [KubeRay](https://github.com/ray-project/kuberay), and [CNCF Fluid](https://github.com/fluid-cloudnative/fluid) as the underlying infrastructure components. Amazon Trainium1 is used as DL model training power. 

## Pre-requisites
*Make sure the laptop has the right permission to access the resources on AWS account.*
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

## Deployment - llama3.1_8B_finetune_ray_on_trn1
- Clone the repo
  ```sh
  git clone https://github.com/aws-samples/sample-cap-quant.git
  ```
- EKS Cluster Provision
  ```sh
  cd quant-research/llama3.1_8B_finetune_ray_on_trn1/infra
  ./1_install_platform.sh
  ```
  It takes 20+ minutes for the resource to be provisioned and setup.
  ```sh
  aws eks --region us-east-1 update-kubeconfig --name <eks cluster name>
  ```
  
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



