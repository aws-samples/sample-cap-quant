# infra — Terraform 基础设施(Milestone 1)

State 1:VPC / EKS / RDS / ElastiCache / S3 / IRSA。模块职责见 docs/architecture.md §2。

前置条件:
- 建 state 用 S3 bucket + DynamoDB lock 表(一次性,可手动或 bootstrap 脚本)
- 确定 region(tfvars 变量,建议 us-west-2:Bedrock Claude 模型可用性好)
- 确定 VPC CIDR(默认 10.80.0.0/16,避免与公司网段冲突)

用法(模块就绪后):
```bash
cd envs/dev && terraform init && terraform plan
```
