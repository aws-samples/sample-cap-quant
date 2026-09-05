module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = var.vpc_cidr

  azs = var.azs
  # /20 private subnets (main address consumption by nodes/Pods), /24 public subnets (ALB/NAT only)
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

# S3 via gateway endpoint, so Langfuse event uploads and ECR image layer downloads bypass NAT (saves data transfer costs)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
}
