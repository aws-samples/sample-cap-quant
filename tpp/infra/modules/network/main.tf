module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = var.vpc_cidr

  azs = var.azs
  # /20 私有子网(节点/Pod 主要地址消耗),/24 公有子网(仅 ALB/NAT)
  private_subnets = [for i in range(length(var.azs)) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(length(var.azs)) : cidrsubnet(var.vpc_cidr, 8, i + 200)]

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_support   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# S3 走网关端点,Langfuse 事件上传与 ECR 镜像层下载不出 NAT(省流量费)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
}
