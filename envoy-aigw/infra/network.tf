locals {
  name = "aigw-${var.env}"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = local.name
  cidr = var.vpc_cidr
  azs  = var.azs

  # /20 private (nodes + pods), /24 public (ALB + NAT only)
  private_subnets = [for i in range(length(var.azs)) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(length(var.azs)) : cidrsubnet(var.vpc_cidr, 8, i + 200)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # dev: one NAT; model traffic uses VPC endpoints, NAT is ops egress only
  enable_dns_support   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# ---- VPC endpoints: all model traffic stays on PrivateLink ----
resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name}-vpce"
  description = "HTTPS from the VPC to interface endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# bedrock-runtime: Claude / Kimi / DeepSeek / GLM (InvokeModel, Converse)
# bedrock-mantle:  GPT via the OpenAI-compatible endpoint
resource "aws_vpc_endpoint" "bedrock" {
  for_each = toset(["bedrock-runtime", "bedrock-mantle"])

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name}-${each.key}" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = { Name = "${local.name}-s3" }
}
