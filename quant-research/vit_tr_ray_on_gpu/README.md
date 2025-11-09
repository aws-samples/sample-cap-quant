# Quant Research using Amazon EKS,Kuberay,CNCF Fluid (using GPU)

## Overview
This project aims to investigate the feasibility of performing quantitative research by leveraging [Amazon Elastic Kubernetes Service (EKS)](https://aws.amazon.com/eks/), [KubeRay](https://github.com/ray-project/kuberay), and [CNCF Fluid](https://github.com/fluid-cloudnative/fluid) as the underlying infrastructure components. Both Amazon Trainium and Nvidia GPU have been used for deep learning model training.

## Pre-requisites
- *Make sure the laptop has the right permission to access the resources on AWS account.*
- *Make sure the laptop has [docker.deksptop app](https://docs.docker.com/desktop/setup/install/mac-install/) installed*
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
- Update variables.tf "Name of the VPC and EKS Cluster" and "region"
  ```tf
	variable "name" {
	  description = "Name of the VPC and EKS Cluster"
	  type        = string
	  default     = "mc5"  # needs update accordingly
	}
	variable "region" {
	  description = "region"
	  type        = string
	  default     = "us-east-1"  # needs update accordingly
	}
  ```
- EKS Cluster Provision
  ```sh
  chmod +x 1_install_platform.sh
  ./1_install_platform.sh
  ```
  It takes 20+ minutes for the resource to be provisioned and setup.

- add EKS cluster context in the MacOS jumpserver, so that the jumpserver can access EKS cluster.
  ```sh
  aws eks --region <region id> update-kubeconfig --name <eks cluster name>      # region id like us-east-1

  kubectl get nodes      # there should be 5 nodes: 3 core nodes, 2 g6 2xlarge GPU nodes
  ```
- (Optional) Test EKS Cluster EC2 nodes able to visit port 6379, if cannot, revise EC2's Security Group.
  ```
  redis-cli -h <redis endpoint url> -p 6379 ping
  ```
- Update 2_install_fluid.sh according to your environment's specific context.
  - 1/Get the endpoint url of the provisioned Redis cluster from previous step, and revise 2_install_fluid.sh per below;
  - 2/Configure specific AK & SK;
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: jfs-secret
type: Opaque
stringData:
  name: "jfs"                # JuiceFS File System Name
  metaurl: "<redis cluster endpoint url>:6379/1"     # e.g. "mc7.fkdmm8.0001.use1.cache.amazonaws.com:6379/3"
  access-key: {access-key-id}                     # AWS Account Access Key ID
  secret-key: {secrect-key-id}                     # AWS Account Secret Key ID
```
-  
  - 3/Configure specific s3 bucket for raw data storage location.
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
        bucket: "<s3 bucket https endpoint url2>"        #  e.g. "https://s3.us-west-2.amazonaws.com/nov6-vit-2"  to store raw data
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
      cd /data
      aws s3 cp s3://<s3 bucket name>/data . --recursive
      ```

- ECR Image Creation
  - Open docker.desktop app.
  - Update cnn-gpu-kuberay-build-image-m4.sh line34 region id (e.g. us-east-1) to your specific context
  - Update ray.ddp.py line147 storage_path to s3 bucket that is created before to store the training results of the Ray cluster.
  
  ```sh
  cd quant-research/vit_tr_ray_on_gpu/app
  chmod 700 cnn-gpu-kuberay-build-image-m4.sh
  ./cnn-gpu-kuberay-build-image-m4.sh
  #input the ECR version, e.g. V0.1
  ```
  - Update raycluster-with-jfs.yaml line33 & line85 with the specific ECR url, e.g. <aws-account-id>.dkr.ecr.us-east-1.amazonaws.com/kuberay_cnn_gpu:V0.9.2
  
- Raycluster Creation
  first time ray cluster pods creation needs to wait for 5-6 minutes, cause the ECR Image is 14GB large.
  ```sh
  kubectl create -f raycluster-with-jfs.yaml
  ```
- Rayjob Submission
  ```sh
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
- Ray metrics are not enabled by Prometheus and Grafana by default. Enable Ray metrics by running the follow command
  ```sh
  cd quant-research/vit_tr_ray_on_gpu/app
  kubectl create -f ray-servicemonitor.yaml
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



