# Runbook：在 Amazon Quick Desktop 中接入 aws-billing MCP Server

- 适用对象：想让 Amazon Quick Desktop（Quick Work）直接查询/分析自己 AWS 账号 Billing and Cost Management 数据的 macOS 用户
- MCP Server 来源：<https://github.com/aws-samples/sample-cap-quant/tree/main/aws-billing-mcp>
- 验证环境：macOS，Amazon Quick Desktop v0.1000.x，Node.js 24，AWS CLI v2（2026-09-04 验证）
- 阅读约定：
  - `<HOME>` 表示你的家目录绝对路径，用 `echo $HOME` 取得（例如 `/Users/alice`）
  - `<NODE>` 表示 node 可执行文件的绝对路径，用 `which node` 取得（Homebrew 常见为 `/opt/homebrew/bin/node`，nvm 为 `<HOME>/.nvm/versions/node/vXX/bin/node`；nvm 路径会随 node 升级而变化，之后需要在 Quick 里同步改 Command，或改用 Homebrew 的固定路径）
  - `<PROFILE>` 表示 Quick 当前登录 profile 的数据目录名，见 4.5 节的取法
  - 截图中出现的 `/Users/wshiyang/...` 是作者机器上的示例路径，请替换成你自己的

---

## 1. 前置条件检查

| 项目 | 要求 | 检查方法 |
|---|---|---|
| Node.js | ≥ 18 | `node --version`；记下 `which node` 的输出，后面要用绝对路径 |
| AWS CLI | v2 | `aws --version`；记下 `which aws` 所在目录（常见 `/usr/local/bin` 或 `/opt/homebrew/bin`） |
| AWS 凭证 | 有一个可用的 profile（本文用 `default`） | `~/.aws/credentials` 或 `~/.aws/config` 中存在该 profile，且已配置 region |
| IAM 权限 | `ce:Get*`、`budgets:ViewBudget`、`sts:GetCallerIdentity` | 见下方命令；Cost Explorer 需要在 Billing 控制台启用过一次 |
| Quick Desktop | 已安装并登录 | `/Applications/Amazon Quick.app` 或 `/Applications/Amazon Quick 2.app`，两者共用同一配置目录 |

检查命令（把日期改成上个月）：

```bash
node --version && which node
aws --version && which aws
aws sts get-caller-identity
aws ce get-cost-and-usage --time-period Start=2026-08-01,End=2026-09-01 \
  --granularity MONTHLY --metrics UnblendedCost
```

最后一条能返回数字即说明 Cost Explorer 权限 OK。

> 如果 Quick 是 GUI 启动的，它**不继承你 shell 里 export 的 AK/SK**。凭证必须写在 `~/.aws/credentials`，或通过 SSO/assume-role 等配置在 `~/.aws/config` 里。

## 2. 安装与构建

```bash
# 拉取仓库（只需要 aws-billing-mcp 子目录）
cd /tmp && git clone --depth 1 https://github.com/aws-samples/sample-cap-quant.git
mkdir -p ~/mcp-servers
cp -R /tmp/sample-cap-quant/aws-billing-mcp ~/mcp-servers/aws-billing-mcp

# 构建
cd ~/mcp-servers/aws-billing-mcp
npm install
npm run build          # tsc 编译到 dist/index.js
```

安装目录可以自选，本文后续统一用 `<HOME>/mcp-servers/aws-billing-mcp`。

## 3. 命令行冒烟测试（接入 Quick 之前先跑）

```bash
cd ~/mcp-servers/aws-billing-mcp
npm test
```

预期输出：

- `aws-billing-mcp ready (expected account: any, aws cli: aws)`
- `TOOLS:` 列出 7 个工具：`get_cost_and_usage, get_dimension_values, get_cost_forecast, get_cost_anomalies, describe_budgets, get_cost_allocation_tags, get_commitment_utilization`
- `TOP5 SERVICES:` 本月按服务 Top5
- `FORECAST:` 到月底的预测

这一步不通就先别接 Quick，通常是凭证或 IAM 权限问题。

## 4. 接入 Amazon Quick Desktop（桌面 App GUI）

> 前提：第 2 节的 `dist/index.js` 已构建好，第 3 节冒烟测试通过。

### 4.1 打开 MCP 添加入口

1. 打开 **Amazon Quick** 桌面 App。
2. 左侧导航 **Settings → Capabilities**，进入 **Connectors** 标签页。
3. 点右上角 **+ Create** 下拉，选 **MCP server**。

   ![Capabilities 页面，Create 下拉菜单中的 MCP server](aws-billing-mcp-runbook-screenshots/01-capabilities-create-menu.png)

4. 弹出 **Add MCP** 表单，Connection type 保持默认 **Local**（"Run a command on your machine"）。

   ![空的 Add MCP 表单](aws-billing-mcp-runbook-screenshots/02-add-mcp-form-empty.png)

### 4.2 用 Paste JSON 一键填表

1. 点表单顶部的 **Paste JSON** 按钮。
2. 先在终端生成一份填好绝对路径的 JSON 并复制到剪贴板：

```bash
AWS_BIN_DIR=$(dirname "$(which aws)")
cat <<EOF | pbcopy
{
  "command": "$(which node)",
  "args": ["$HOME/mcp-servers/aws-billing-mcp/dist/index.js"],
  "env": {
    "AWS_PROFILE": "default",
    "PATH": "$AWS_BIN_DIR:/usr/bin:/bin:/opt/homebrew/bin"
  }
}
EOF
pbpaste   # 看一眼，确认路径都是绝对路径、没有 ~
```

   生成结果形如：

```json
{
  "command": "<NODE>",
  "args": ["<HOME>/mcp-servers/aws-billing-mcp/dist/index.js"],
  "env": {
    "AWS_PROFILE": "default",
    "PATH": "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
  }
}
```

   注意：
   - 这里是**单个 server 的对象**，不要带 `mcpServers` 外层，否则 Quick 解析不出来，Apply 按钮保持灰色。
   - `command` 必须是 node 的绝对路径。GUI 应用不继承 shell 的 PATH，写 `node` 会找不到。
   - `env.PATH` 必须包含 `aws` 所在目录，server 内部是调用 AWS CLI 取数的。
   - 如果你的凭证不叫 `default`，把 `AWS_PROFILE` 改成对应名字。
   - 可选：加 `"EXPECTED_ACCOUNT": "<12 位账号 ID>"`，server 会在首次调用时校验凭证归属，防止误查其他账号。

3. 粘贴到对话框里，点 **Apply**。Command、Arguments、Environment variables 三块会被自动填好。

   ![Paste JSON config 对话框，已粘入配置](aws-billing-mcp-runbook-screenshots/03-paste-json-dialog.png)

### 4.3 补齐其余字段

| 字段 | 填写内容 |
|---|---|
| Name（必填） | `aws-billing`（Quick 列表里会显示成 "Aws Billing"） |
| Command（必填） | `<NODE>`（已由 JSON 带入） |
| Arguments | `<HOME>/mcp-servers/aws-billing-mcp/dist/index.js`（已带入） |
| Description | 例如 `AWS Billing and Cost Management (Cost Explorer, Budgets, Anomalies, Forecast) via AWS CLI` |
| Environment variables | `AWS_PROFILE`、`PATH`（已带入，值以掩码显示） |
| Timeout (seconds) | 默认 30，够用 |

填完后的表单上半部分：

![Name、Command、Arguments、Description 已填写](aws-billing-mcp-runbook-screenshots/04-form-filled.png)

向下滚动，环境变量、Timeout 和底部按钮：

![Environment variables、Timeout、Test connection 与 Add MCP 按钮](aws-billing-mcp-runbook-screenshots/05-form-env-timeout-buttons.png)

### 4.4 测试并保存

1. 点底部 **Test connection**。会弹 macOS 原生确认框 **"Allow MCP server "aws-billing"?"**，列出将要执行的命令和环境变量名，核对无误后点 **Add server** 允许。

   ![Allow MCP server 确认框](aws-billing-mcp-runbook-screenshots/06-allow-dialog.png)

   测试成功时界面上没有持久提示。想确认可以看日志（见 4.6），会有 `Received mcp_test_connection` 且几百毫秒内完成。
2. 点 **+ Add MCP**。会**再弹一次**同样的确认框，再点 **Add server**。
3. 表单关闭后，MCP SERVERS 列表里出现 **Aws Billing**。刚出现时可能显示 `0 tools · Disabled`，点搜索框右边的 **刷新图标**（或等几秒）即变成 **`7 tools · 7 write · Connected`**，开关为打开状态。

   ![MCP SERVERS 列表中 Aws Billing 显示 7 tools Connected](aws-billing-mcp-runbook-screenshots/07-connected-7-tools.png)

到这里就可以在 Quick 里直接提问了，例如："上个月这个账号总共花了多少钱？按服务排 Top 10。"

### 4.5 GUI 方式在后台做了什么

Quick 的 MCP 配置是**按登录 profile 存放**的：

```
~/.quickwork/profiles/<PROFILE>/mcp_config.json
```

`<PROFILE>` 的取法：

```bash
python3 -c "import json;p=json.load(open('$HOME/.quickwork/profiles.json'));print([e['data_path'] for e in p['entries']], 'active:', p['last_active'])"
```

`data_path` 就是目录名，`last_active` 是当前活动 profile。企业 Federate 登录通常是 `profiles/federate-prod`。顶层的 `~/.quickwork/mcp_config.json` 是旧版遗留文件，Quick 已不再读取，改它不会有任何效果。

通过 GUI 添加后，Quick 会自动把条目写进上面的文件，并且**env 的值不落盘**，改成 secret 引用：

```json
"aws-billing": {
  "description": "AWS Billing and Cost Management (...) via AWS CLI",
  "command": "<NODE>",
  "args": ["<HOME>/mcp-servers/aws-billing-mcp/dist/index.js"],
  "env": {
    "AWS_PROFILE": "secret://aws-billing::e::aws_profile",
    "PATH": "secret://aws-billing::e::path"
  }
}
```

其他要点：

- **不需要重启 Quick**。通过 GUI 增删 server 时 agent 会热加载，日志里是 `[UserMCP] Config changed, reloading servers...`。
- 保存后约 1 秒内日志出现 `aws-billing-mcp ready` → `Started ... with 7 tools` → `Loaded 1/1 servers (0 failed), 7 total tools`。
- 卸载也走 GUI：Aws Billing 行右侧 **⋮ → Remove**，日志是 `[UserMCP] Removed server 'aws-billing'`，并清理对应的 secret 与权限偏好。

### 4.6 命令行验证

```bash
# server 进程已被 Quick 拉起（backend 和 worker 各一个，看到 1~2 个属正常）
pgrep -fl "aws-billing-mcp/dist/index.js"

# 日志确认（按 UTC 小时滚动）
grep -E "UserMCP|aws-billing-mcp ready" \
  ~/Library/Logs/quickwork/quickwork-$(date -u +%Y-%m-%d-%H).log | grep -v discover_connectors | tail
```

## 5. 常见问题

| 现象 | 排查 |
|---|---|
| Paste JSON 后 Apply 灰色 / 表单没填上 | 粘贴的 JSON 带了 `mcpServers` 外层。只接受单个 server 对象（`command` / `args` / `env`） |
| 保存后列表显示 `0 tools · Disabled` | 列表没刷新。点刷新图标或等几秒；日志里若已有 `Loaded 1/1 servers` 说明实际已经跑起来了 |
| Test connection / Add MCP 点了没反应 | macOS 原生的 "Allow MCP server" 确认框可能被挡在后面，必须点 Add server |
| 日志 `Loaded 0/1 servers (1 failed)` | server 启动失败，看同一时间点 `[UserMCP]` 附近的 stderr。通常是 node 路径不是绝对路径，或 `env.PATH` 没包含 `aws` 所在目录 |
| server 报 `aws: command not found` | `env.PATH` 未包含 `dirname $(which aws)` |
| `Unable to locate credentials` | GUI 不读 shell 里 export 的 AK/SK，凭证要写在 `~/.aws/credentials`；或检查 `AWS_PROFILE` 名字是否正确 |
| `AccessDeniedException ... ce:GetCostAndUsage` | IAM 缺 `ce:Get*`；Cost Explorer 需在 Billing 控制台启用过一次 |
| `EXPECTED_ACCOUNT` 不匹配报错 | 当前凭证不是目标账号，`aws sts get-caller-identity` 确认 |
| 改了 server 源码后行为没变 | 改了 `src/` 需要重新 `npm run build`，Quick 用的是 `dist/index.js`；然后在 GUI 里 Remove 再 Add，或重启 Quick |
