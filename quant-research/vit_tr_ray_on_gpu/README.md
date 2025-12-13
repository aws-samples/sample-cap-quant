# Quant Research using Amazon EKS,Kuberay,CNCF Fluid (using GPU)

## Overview
This project aims to investigate the feasibility of performing quantitative research by leveraging [Amazon Elastic Kubernetes Service (EKS)](https://aws.amazon.com/eks/), [KubeRay](https://github.com/ray-project/kuberay), and [CNCF Fluid](https://github.com/fluid-cloudnative/fluid) as the underlying infrastructure components. Both Amazon Trainium and Nvidia GPU have been used for deep learning model training.

## Pre-requisites
- *Make sure the laptop has the right permission to access the resources on AWS account.*
- *Make sure the laptop has [docker.desktop app](https://docs.docker.com/desktop/setup/install/mac-install/) installed*
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
  - install gettext
    ```sh
    brew install gettext
    export PATH="/opt/homebrew/opt/gettext/bin:$PATH"
    ```
## Deployment - vit_tr_ray_on_gpu
- Pre-requisites
  - Make sure there is at least one VPC quota available in the target region, because the HCL will create a VPC.
  - Make sure there is at least one EIP quota available in the target region, because the EKS cluster will use one EIP for its NAT Gateway.
  - Create 2 s3 buckets in the target region. One is to store the raw data of JuiceFS, the other is to store the training results of the Ray cluster.

- Clone the repo
  ```sh
  git clone https://github.com/aws-samples/sample-cap-quant.git
  cd quant-research/vit_tr_ray_on_gpu/infra  
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
  chmod +x 01_install_platform.sh
  ./01_install_platform.sh
  ```
  It takes 20+ minutes for the resource to be provisioned and setup.

- add EKS cluster context in the MacOS jumpserver, so that the jumpserver can access EKS cluster.
  ```sh
  aws eks --region <region id> update-kubeconfig --name <eks cluster name>      # region id like us-east-1

  kubectl get nodes      # there should be 5 nodes: 3 core nodes, 2 g6 2xlarge GPU nodes
  ```
- Install Fluid
  ```sh
  chmod +x 02_install_fluid.sh
  ./02_install_fluid.sh
  ```

- Training Data Preparation and Caching by creating data-load-pod
  ```sh
  kubectl create -f data-load-pod.yaml

  #wait for 2-3 minutes for the data to be downloaded
  kubectl exec -it data-load-pod -- /bin/bash -c "cd /data && ls -la"  
  ```

- ECR Image Creation
  - Open docker.desktop app.
  - build image
    ```sh
    cd quant-research/vit_tr_ray_on_gpu/app/ 
    chmod +x 00_build_image.sh
    ./00_build_image.sh
    ```
  Initially, it takes 40-60 minutes around to create the ECR image.
    
- Raycluster Creation
  - run the following command to create the ray cluster
  ```sh
  chmod +x 01_deploy_ray_cluster.sh
  ./01_deploy_ray_cluster.sh
  ```
  first time ray cluster pods creation needs to wait for 5-6 minutes, cause the ECR Image is 14GB large.

- Rayjob Submission
  ```sh
  chmod +x 02_create_rayjob.sh
  ./02_create_rayjob.sh
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
cd quant-research/vit_tr_ray_on_gpu/infra
chmod +x cleanup.sh
./cleanup.sh
```

# Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

# License

This library is licensed under the MIT-0 License. See the [LICENSE](https://github.com/aws-samples/sample-cap-quant/blob/main/LICENSE) file.



