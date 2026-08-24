# TPP 架构设计

LiteLLM + Langfuse + 自建 kube-prometheus-stack + RDS/ElastiCache,
EKS 部署,Terraform 管基础设施 + Helm 管应用。

## 1. [架构图](./architecture-diagram.html)

## 2. Terraform 划分

```
infra/                          # state 1:基础设施(变更频率低)
├── envs/{dev,prod}/            # 组装层:main.tf / backend.tf / terraform.tfvars
└── modules/
    ├── network/                # VPC、公私子网、NAT、VPC Endpoints(S3/ECR/Bedrock)
    ├── eks/                    # 集群、managed node groups、IRSA OIDC、核心 addon
    ├── rds/                    # PostgreSQL:litellm + langfuse 两库(dev 单实例,prod 可拆)
    ├── elasticache/            # Redis
    ├── s3/                     # Langfuse events bucket
    └── iam/                    # IRSA roles:LiteLLM(bedrock:InvokeModel*)、
                                #   Langfuse(S3)、ESO(SecretsManager 读)
apps/                           # state 2:集群内应用(变更频率高,helm_release)
    platform.tf                 # alb-controller、external-secrets、kube-prometheus-stack
    litellm.tf  langfuse.tf  scorer.tf
```

分两个 state 的理由:改渠道配置的 plan/apply 不碰基础设施,爆炸半径小;
后续可整体平移到 ArgoCD。密钥全部走 Secrets Manager → ESO,不进 tfstate。

## 3. Scorer 打分算法

评分对象:LiteLLM deployment,即 **(渠道, 模型) 二元组**,只在同一模型组内互比。
每 60s 一轮,取 Prometheus 过去 5 分钟窗口。

```
输入:   L_d = E2E p90 延迟;N_d = 请求数;E_d,c = 按类别错误数
严重性: 5xx/Timeout/Conn → 3.0;429 → 1.5;其它 4xx → 0.5
加权错误率: ê = Σ severity_c × E_c / max(N, 1)

单轮分:  S_lat = clamp(L_best / L_d, 0, 1)        # 组内最快者得 1
         S_err = exp(−8 × ê)                       # ê=8.6% 时掉到 0.5
         Q_raw = 0.35 × S_lat + 0.65 × S_err       # 错误权重高于延迟

平滑:    Q(t) = 0.3 × Q_raw + 0.7 × Q(t−1)         # EWMA,时间常数约 3 分钟
         N < 10 时跳过更新沿用旧分(小样本保护);新渠道冷启动 Q=0.5

权重:    w_d = Q_d² / Σ Q_j²                        # γ=2 放大分差
         w_d = max(w_d, 5%) 后归一化                # 探索保底,防低分渠道死锁

熔断:    ê > 0.5 且 severe 类主导 → w=0(优先于保底);连续 3 轮 ê < 0.1 恢复至保底爬坡
写回:    组内任一权重变化 > 2pp 才调 LiteLLM `/model/update`(迟滞防抖)
降级:    Prometheus/API 不可用 → 权重冻结 + 告警(Scorer 不在请求路径上)
状态:    EWMA 存 Redis(scorer:score:{model}:{provider}),重启无损
部署:    单副本 Deployment(非 CronJob),自身导出 scorer_quality_score /
         scorer_weight / scorer_last_success_timestamp 指标
```

