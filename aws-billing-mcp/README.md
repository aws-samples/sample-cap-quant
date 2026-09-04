# aws-billing-mcp

MCP server——通过本机 AWS CLI 访问当前 AWS 账号的 Billing and Cost Management 数据，供 Quick Desktop 等 MCP 客户端做消费用量分析。TypeScript 编写，编译产物在 `dist/`。

## 前置条件

- Node.js ≥ 18
- AWS CLI v2，且 default profile（或 `AWS_PROFILE` 指定的 profile）有可用凭证
- IAM 权限：`ce:Get*`、`budgets:ViewBudget`、`sts:GetCallerIdentity`

可选：设置环境变量 `EXPECTED_ACCOUNT` 为目标 AWS 账号 ID。设置后，服务器在第一次调用工具时会用 `sts get-caller-identity` 校验当前凭证确实属于该账号，不匹配时直接报错，防止误查其他账号；不设置则直接使用当前凭证对应的账号。

## 安装与构建

```bash
cd <项目目录>
npm install
npm run build   # tsc 编译到 dist/
```

开发时可以不构建，直接运行 TypeScript 源码：

```bash
npm run dev     # tsx src/index.ts
```

## 冒烟测试

```bash
npm test        # tsx src/test-client.ts
```

会列出全部工具、查询本月按服务分组的成本 Top5，并做一次到月底的成本预测。

## 接入 Quick Desktop

在 Quick Desktop 的 MCP 服务器配置（Settings → 集成/MCP servers，或其 JSON 配置文件）中添加（先 `npm run build`，并把两处路径替换为你机器上的实际绝对路径）：

```json
{
  "mcpServers": {
    "aws-billing": {
      "command": "/absolute/path/to/node",
      "args": ["/absolute/path/to/aws-billing-mcp/dist/index.js"],
      "env": {
        "AWS_PROFILE": "default",
        "PATH": "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
      }
    }
  }
}
```

> 注意：GUI 应用启动时不继承你 shell 的 PATH，所以 `command` 建议写 node 的绝对路径
> （用 `which node` 查看，尤其是通过 nvm 安装的 node），并在 `env` 的 `PATH` 里包含
> `aws` 所在目录（用 `which aws` 查看）。JSON 配置中不要使用 `~`，很多客户端不会展开它。

## 工具列表

| 工具 | 用途 |
|---|---|
| `get_cost_and_usage` | 核心查询：任意时间段的成本/用量，支持按 SERVICE、USAGE_TYPE、REGION、TAG 等分组（最多 2 个），支持 Cost Explorer filter 表达式，自动翻页 |
| `get_dimension_values` | 枚举某维度实际产生费用的取值（服务名、区域等），用于确定精确的过滤值 |
| `get_cost_forecast` | 未来时间段的成本预测（含 80% 置信区间） |
| `get_cost_anomalies` | Cost Anomaly Detection 检测到的成本异常及根因 |
| `describe_budgets` | 账号下的 Budgets 及实际/预测执行情况 |
| `get_cost_allocation_tags` | 计费数据中的成本分配标签 key/value，配合 TAG 分组使用 |
| `get_commitment_utilization` | Savings Plans / RI 的 utilization 与 coverage |

## 典型分析提问（在 Quick Desktop 中）

- “这个账号本月花了多少钱？按服务排一下 Top 10。”
- “最近 30 天每天的 Bedrock 消费趋势，有没有异常尖峰？”
- “预测一下月底的总账单。”
- “EC2 的费用按 usage type 拆开看，哪部分涨得最快？”

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `EXPECTED_ACCOUNT` | （未设置） | 可选。设置后仅允许访问该 AWS 账号，凭证不匹配即拒绝 |
| `AWS_PROFILE` | （系统默认） | 使用的 AWS CLI profile |
| `AWS_CLI_BIN` | `aws` | AWS CLI 可执行文件路径 |
