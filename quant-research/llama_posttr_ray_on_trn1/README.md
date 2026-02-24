# Quant Research using Amazon EKS + Kuberay + Pytorch + CNCF Fluid (using Trainium1)

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

- Pre-requisites
  - Make sure there is at least one VPC quota available in the target region, because the HCL will create a VPC.
  - Make sure there is at least one EIP quota available in the target region, because the EKS cluster will use one EIP for its NAT Gateway.
  - Create 2 s3 buckets in the target region. One is to store the raw data of JuiceFS, the other is to store the training results of the Ray cluster.

- Clone the repo
  ```sh
  git clone https://github.com/aws-samples/sample-cap-quant.git
  cd quant-research/llama3.1_8B_finetune_ray_on_trn1/infra  
  ```

- Update the below variables in 00_init_variables.sh according to your specific context and save the file.
  ```sh
  # Basic configuration
  export TF_VAR_name="<eks-cluster-name>"
  export TF_VAR_region="<region-id>"
  export TF_VAR_s3_bucket_name1="<name-of-the-bucket-for-filesystem-metadata-storage>"
  export TF_VAR_s3_bucket_name2="<name-of-the-bucket-for-storing-ray-training-result>"
  export TF_VAR_aws_account_id="<your-aws-account-id>"
  export TF_VAR_prefix_name="ray-results"
  ```
- And then run the following command
  ```sh
  chmod +x 00_init_variables.sh
  source ./00_init_variables.sh
  ```

- EKS Cluster Provision
  ```sh
  cd quant-research/llama3.1_8B_finetune_ray_on_trn1/infra
  ./01_install_platform.sh
  ```
  It takes 20+ minutes for the resource to be provisioned and setup.
  ```sh
  aws eks --region us-east-1 update-kubeconfig --name <eks cluster name>
  kubectl get nodes      # there should be 5 nodes: 3 core nodes, 2 trn1.32xlarge nodes
  ```
- Install Fluid
  ```sh
  chmod +x 02_install_fluid.sh
  ./02_install_fluid.sh
  ```
- ECR Image Creation
  - Open docker.desktop app.
  - build image
    ```sh
    cd quant-research/llama3.1_8B_finetune_ray_on_trn1/app/ 
    chmod +x 0-kuberay-trn1-llama3-finetune-build-image.sh
    ./0-kuberay-trn1-llama3-finetune-build-image.sh
    ```
  Initially, it takes 60+ minutes around to create the ECR image.
    
- Raycluster Creation
  - run the following command to create the ray cluster
  ```sh
  kubectl create -f 1-llama3-finetune-trn1-create-raycluster.yaml
  ```
  first time ray cluster pods creation needs to wait for 7-8 minutes, cause the ECR Image is 16GB+ large.

- Rayjob Submission
  ```sh
  kubectl create -f 2-llama3-finetune-trn1-rayjob-create-data.yaml #create data
  kubectl create -f 3-llama3-finetune-trn1-rayjob-submit-finetuning-job.yaml #submit finetuning job
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


