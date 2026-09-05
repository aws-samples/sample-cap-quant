# RDS 密码轮转自动恢复：文件变更说明

本文件记录本次为 LiteLLM 与 Langfuse 增加 RDS 密码轮转自动恢复能力所做的代码与文档变更。

## 背景

RDS 托管主密码每 7 天自动轮转。此前 External Secrets 即使更新了 Kubernetes Secret，已经运行的 Pod
也不会自动刷新环境变量，LiteLLM 和 Langfuse 会继续使用旧密码。

当前恢复链路为：

```text
RDS / Secrets Manager 密码轮转
  → External Secrets 最多 5 分钟内刷新 Kubernetes Secret
  → Stakater Reloader 发现 Secret data 变化
  → LiteLLM、Langfuse Web、Langfuse Worker 滚动重启
  → 新 Pod 使用新密码启动
```

## 应用配置变更

### `apps/langfuse.tf`

- 将 `langfuse-postgres` ExternalSecret 的 `refreshInterval` 从 `1h` 调整为 `5m`。
- 使用 `urlquery` 对 RDS 密码进行 URL 编码。
- 在 Secret 中生成 `database_url`：

  ```text
  postgresql://tpp:<url-encoded-password>@<rds-address>:5432/langfuse
  ```

- 增加 Langfuse Web 与 Worker Deployment 的 Reloader 注解资源：

  ```text
  reloader.stakater.com/auto: "true"
  ```

### `apps/values/langfuse-values.yaml.tftpl`

- 为 Langfuse Web 与 Worker 注入：

  - `DATABASE_URL`
  - `DIRECT_URL`

- 两个变量均引用 `langfuse-postgres` Secret 的 `database_url`。
- 避免 Prisma 因 RDS 密码包含 `@`、`:`、`/`、`%`、`#`、`?` 等保留字符而报：

  ```text
  P1013: invalid port number in database URL
  ```

### `apps/litellm.tf`

- 将 `litellm-env` ExternalSecret 的 `refreshInterval` 从 `1h` 调整为 `5m`。
- 为 LiteLLM Deployment 增加 Reloader 注解。
- 预留并忽略 Reloader 写入的动态 checksum 环境变量，避免后续 `terraform apply` 移除它并破坏自动重载行为。

### `apps/platform.tf`

- 新增 Stakater Reloader Helm release：

  ```text
  chart: reloader
  version: 2.2.16
  namespace: kube-system
  ```

- Reloader 全局监听 ConfigMap 与 Secret 变化，并只重启带有自动重载注解的工作负载。

## 文档变更

### `README.md`

- 更新 `platform.tf` 组件说明，包含 Reloader。
- 新增“RDS 凭证轮转与自动恢复”章节。
- 说明：

  - RDS 轮转周期仍为 7 天；
  - 5 分钟是 External Secrets 检测新密码的最长轮询间隔；
  - Reloader 自动触发 LiteLLM 与 Langfuse 的滚动重启；
  - Langfuse 数据库 URL 必须编码密码。

### `docs/architecture.md`

- 更新 `platform.tf` 组件说明，包含 Reloader。
- 新增“RDS 凭证轮转与自动恢复”架构章节。
- 记录 RDS Secret、ESO、Reloader 和三个应用工作负载之间的恢复链路。
- 记录 Langfuse `DATABASE_URL` / `DIRECT_URL` 的编码要求。

## 验证结果

- LiteLLM 已成功使用轮转后的 RDS 密码启动。
- Langfuse Web 与 Worker 已成功连接 PostgreSQL，Prisma migration 无待执行项。
- 通过向 `litellm-env` 与 `langfuse-postgres` 注入临时、非凭证 Secret data 更新进行了验证：

  - Reloader 检测到 Secret data 变化；
  - LiteLLM 自动滚动重启；
  - Langfuse Web 与 Worker 自动滚动重启；
  - 三个工作负载均恢复为 Ready。

- External Secrets 后续同步已移除测试使用的临时 Secret data。
