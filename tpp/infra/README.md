# infra — Terraform Infrastructure

State 1: VPC / EKS / RDS / ElastiCache / S3 / IRSA. Module responsibilities are described in docs/architecture.md §2.

Prerequisites:
- Create the S3 bucket + DynamoDB lock table for state (one-time; manually or via a bootstrap script)
- Decide on the region (a tfvars variable; us-west-2 recommended: good Bedrock Claude model availability)
- Decide on the VPC CIDR (default 10.80.0.0/16; avoid conflicts with corporate address space)

Usage (once the modules are ready):
```bash
cd envs/dev && terraform init && terraform plan
```
