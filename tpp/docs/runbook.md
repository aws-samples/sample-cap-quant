# TPP Runbook

环境:EKS `tpp-dev` @ us-west-2(账号 ******)。
前置:`aws eks update-kubeconfig --name tpp-dev --region us-west-2`

## 目录

- [访问入口(dev 尚未暴露 Ingress)](#访问入口dev-尚未暴露-ingress)
- [本机(laptop)接入 TPP 调 Claude](#本机laptop接入-tpp-调-claude)
  - [新机器安装隧道守护(一次性)](#新机器安装隧道守护一次性)
  - [Claude Code 接入 TPP(双模式)](#claude-code-接入-tpp双模式)
  - [Codex CLI 接入 TPP](#codex-cli-接入-tpp)
- [日常操作](#日常操作)
  - [TPP Dashboard(统一入口)](#tpp-dashboard统一入口)
  - [Per-user quota(USD/天)](#per-user-quotausd天)
  - [查看渠道质量分 / 权重](#查看渠道质量分--权重)
  - [调整打分参数](#调整打分参数)
- [RDS 凭证轮转与自动恢复](#rds-凭证轮转与自动恢复)
- [Scorer 打分算法](#scorer-打分算法)
  - [符号定义](#符号定义)
  - [严重性系数](#严重性系数)
  - [计算公式](#计算公式)
  - [运行规则](#运行规则)
- [告警响应](#告警响应)
- [已知事项 / 陷阱](#已知事项--陷阱)
- [当前环境登记](#当前环境登记)

## 访问入口(dev 尚未暴露 Ingress)
**已配隧道守护的机器(launchd 服务 `com.tpp.litellm-proxy` 运行 `tpp-tunnels.sh`)直接开浏览器,
无需任何命令**;下表"手动命令"仅供未配守护的机器使用。

| 服务 | 直接访问地址 / 凭据 | 手动命令(备用) |
|---|---|---|
| LiteLLM API + Admin UI | http://localhost:14000/ui,登录 `admin` / master key(`cd apps && terraform output -raw litellm_master_key`) | `kubectl port-forward -n litellm svc/litellm 14000:4000` |
| Grafana(TPP Overview) | http://localhost:3000,admin / `terraform output -raw grafana_admin_password` | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80` |
| Langfuse UI | http://localhost:3010,admin@tpp.local / `terraform output -raw langfuse_admin_password`;**本地端口必须 3010**(NEXTAUTH_URL 绑定) | `kubectl port-forward -n langfuse svc/langfuse-web 3010:3000` |
| Prometheus | http://localhost:9090(无认证) | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090` |
| TPP Dashboard(配额/渠道消费/性能) | http://localhost:3020(无认证;配额可在页面直接改) | `kubectl port-forward -n dashboard svc/dashboard 3020:8080` |

## 本机(laptop)接入 TPP 调 Claude

1. 保持代理连接,二选一:
   - **launchd 常驻服务(推荐,零手动)**:`~/Library/LaunchAgents/com.tpp.litellm-proxy.plist`
     运行 `tpp-tunnels.sh`,同时维持 LiteLLM(14000)/ Grafana(3000)/ Langfuse(3010)/
     Prometheus(9090)/ TPP Dashboard(3020)五条隧道,
     登录自启、断线各自自动拉起,每条隧道带健康探测看门狗(kubectl 僵死——进程在但转发不通——
     约 45 秒内自动重启)(脚本副本在 `~/.local/bin/`——launchd 无法执行 Documents 下的
     脚本,TCC 限制;改仓库脚本后需同步复制过去)。日志:`/tmp/tpp-proxy.log`。
     管理:`launchctl bootout gui/$UID/com.tpp.litellm-proxy`(停)/
     `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.tpp.litellm-proxy.plist`(启);
   - 手动:`./scripts/tpp-tunnels.sh`(五条隧道)或 `./scripts/tpp-connect.sh`(仅 LiteLLM,
     默认端口 14000),前台运行,Ctrl-C 退出。
2. 每台机器/每个人用自己的 user + key(不要用 master key),见下文 quota 章节的 `/user/new`。
3. 客户端配置(二选一,key 均放 `Authorization: Bearer` 或 `x-api-key`):
   - **OpenAI 兼容**(大多数工具):base_url `http://localhost:14000/v1`,
     env:`OPENAI_BASE_URL=http://localhost:14000/v1`、`OPENAI_API_KEY=<你的key>`
   - **Anthropic 原生**(Anthropic SDK / Claude Code):base_url `http://localhost:14000`
     (proxy 提供 `/v1/messages`),env:`ANTHROPIC_BASE_URL=http://localhost:14000`、
     `ANTHROPIC_AUTH_TOKEN=<你的key>`
4. 可用模型名 = 渠道注册表里的 model_name:`claude-fable-5`、`claude-opus-5`、`claude-sonnet-5`、
   `claude-haiku-4-5`(与 Anthropic 官方模型 ID 同名,多数客户端零配置),以及
   `gpt-5.6-terra`(OpenAI 模型经 Bedrock Mantle,Codex CLI 用)。
   Claude 每个模型组 = Bedrock 双 region 渠道(usw2/use1),请求按 Scorer 权重分流;
   `gpt-5.6-terra` 目前为 usw2 单渠道。

### 新机器安装隧道守护(一次性)

前置:装好 aws cli(有 IAM 凭据)、kubectl,并执行过 `aws eks update-kubeconfig --name tpp-dev --region us-west-2`。

```bash
# 1. 脚本放到 launchd 可执行的位置(Documents 下受 macOS TCC 限制,launchd 无法执行)
mkdir -p ~/.local/bin
cp <repo>/scripts/tpp-tunnels.sh ~/.local/bin/ && chmod +x ~/.local/bin/tpp-tunnels.sh

# 2. 创建 LaunchAgent
cat > ~/Library/LaunchAgents/com.tpp.litellm-proxy.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.tpp.litellm-proxy</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>REPLACE_WITH_$HOME/.local/bin/tpp-tunnels.sh</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>AWS_PROFILE</key><string>default</string>
    </dict>
    <key>StandardOutPath</key><string>/tmp/tpp-proxy.log</string>
    <key>StandardErrorPath</key><string>/tmp/tpp-proxy.log</string>
</dict>
</plist>
EOF
# 注意:把 ProgramArguments 里的路径改成绝对路径(plist 不展开 $HOME)

# 3. 启动并验证
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.tpp.litellm-proxy.plist
sleep 8
curl -s -o /dev/null -w "litellm %{http_code}\n"    http://localhost:14000/health/liveliness
curl -s -o /dev/null -w "grafana %{http_code}\n"    http://localhost:3000/api/health
curl -s -o /dev/null -w "langfuse %{http_code}\n"   http://localhost:3010/api/public/health
curl -s -o /dev/null -w "prometheus %{http_code}\n" http://localhost:9090/-/healthy
curl -s -o /dev/null -w "dashboard %{http_code}\n"  http://localhost:3020/healthz
```

### Claude Code 接入 TPP(双模式)

与 Codex 同构:**默认 `claude` = Bedrock 直连,`claude-tpp` = 走 TPP**。Claude Code 没有
profile 概念,靠 `--settings <file>` 覆盖层实现(优先级最高,`env` 按键合并并覆盖 shell
环境变量,见 https://code.claude.com/docs/en/cli-reference.md)。

1. `~/.claude/settings.json` 保持 **Bedrock 直连基线**(全文见
   `docs/claude-code-config-baseline.md`),`CLAUDE_CODE_USE_BEDROCK=true`、
   `AWS_PROFILE=default`、`AWS_REGION=us-west-2`,模型名用 Bedrock inference profile id;
2. 新建 `~/.claude/tpp.settings.json`(`chmod 600`,含 TPP key):

   ```json
   {
     "env": {
       "CLAUDE_CODE_USE_BEDROCK": "0",
       "ANTHROPIC_BASE_URL": "http://localhost:14000",
       "ANTHROPIC_AUTH_TOKEN": "<TPP user key,本机复用 TPP_API_KEY 那把 dev-laptop-codex 的 key>",
       "ANTHROPIC_MODEL": "claude-fable-5",
       "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4-5"
     },
     "model": "claude-fable-5"
   }
   ```

3. `~/.zshrc` 加别名:`alias claude-tpp='claude --settings ~/.claude/tpp.settings.json'`。

- **使用**:`claude` 直连;`claude-tpp` 走 TPP(临时用也可直接
  `claude --settings ~/.claude/tpp.settings.json`);要改为默认走 TPP,把覆盖层里的
  `env`/`model` 合进 `settings.json` 并删掉 `AWS_*`;
- **前提**:LiteLLM 隧道在跑(launchd 守护或 `./scripts/tpp-tunnels.sh`,本地 :14000);
- **验证走了 TPP**:`claude-tpp -p "reply OK" --output-format json` 的 `modelUsage`
  键应是 TPP 模型组名(`claude-fable-5`/`claude-haiku-4-5`)而非 `us.anthropic.*`;
  再看 `/user/info` 的 spend 增长(LiteLLM 落账有约 5~15 s 延迟)或 Langfuse 新 trace;
- **回滚**:不带别名运行即直连;若 `settings.json` 被改过,
  `cp ~/.claude/settings.json.bedrock-backup ~/.claude/settings.json`;
- 本机用户 quota 为 **$100/天**(fable-5 一次完整问答约 $0.4,重度开发日 $20 不够用);
- 功能边界:Bedrock 渠道无 Anthropic 服务端 web search(直连时同样没有,非 TPP 引入);
  Claude Code 的 WebFetch 在本机执行,不受影响。

**已踩过的坑**:

- 覆盖层禁用 Bedrock 必须写 `"CLAUDE_CODE_USE_BEDROCK": "0"`:该类变量按数值解析,
  `"false"` 不保证生效;
- 直连基线的 `ANTHROPIC_SMALL_FAST_MODEL` 曾是 `us.anthropic.claude-3-7-sonnet-20250219-v1:0`,
  该模型已在 Bedrock 下线(ResourceNotFoundException: end of life),表现为 WebFetch 等
  后台任务报 "issue with the selected model";已改为
  `us.anthropic.claude-haiku-4-5-20251001-v1:0`。

### Codex CLI 接入 TPP

Codex CLI 的渠道配置在 `~/.codex/config.toml`,当前基线是 Bedrock 直连
(`model = "openai.gpt-5.6-terra"`,`model_provider = "amazon-bedrock"`),
完整基线备份在仓库 `.codex-backup/`。TPP 侧对应渠道为模型组 `gpt-5.6-terra`
(Bedrock Mantle `openai.gpt-5.6-terra`,usw2 单渠道,IRSA 鉴权无需 API key)。

**走 TPP**(Codex ≥ 0.134 的 profile 机制:provider 写在主配置,profile 是独立文件):

1. 在 `~/.codex/config.toml` **追加** provider(不动现有顶层 `model`/`model_provider`,
   直连配置保留作 fallback):

   ```toml
   [model_providers.tpp]
   name = "TPP LiteLLM Proxy"
   base_url = "http://localhost:14000/v1"
   env_key = "TPP_API_KEY"
   wire_api = "responses"
   ```

2. 新建 `~/.codex/tpp.config.toml`(profile 文件用顶层键,**不要**再写 `[profiles.tpp]` 表):

   ```toml
   model = "gpt-5.6-terra"
   model_provider = "tpp"
   ```

- **使用**:`export TPP_API_KEY=<TPP key>`(用自己的 user key,不要用 master key,
  见 quota 章节 `/user/new`)后 `codex --profile tpp`;要改为默认走 TPP,把顶层
  `model` / `model_provider` 改成 `gpt-5.6-terra` / `tpp`;
- **前提**:LiteLLM 隧道在跑(launchd 守护或 `./scripts/tpp-tunnels.sh`,本地 :14000);
- **本地 docker-compose 验证**:`base_url` 换成 `http://localhost:4000/v1`,
  key 用 local 的 `LITELLM_MASTER_KEY`(模型组同名 `gpt-5.6-terra`);
- **验证走了 TPP**:发一轮对话后查 `/user/info` 的 spend 增长,或 Langfuse 看新 trace
  (同 Claude Code 章节);
- **回滚到 Bedrock 直连**:不带 `--profile` 运行即回落到顶层直连配置;若顶层已改,
  恢复基线:`cp .codex-backup/config.toml ~/.codex/config.toml`。

**已踩过的坑**(任一项出错 codex 都跑不起来):

- `wire_api` 必须是 `"responses"`:Codex ≥ 0.151 已废弃 `"chat"`,写成 `"chat"` 会导致
  整个 `config.toml` 解析失败,连不带 `--profile` 的 Bedrock 直连也一起启动不了;
- 主配置里残留 `[profiles.tpp]` 表时 `--profile tpp` 直接报错,必须迁到独立文件;
- Codex 默认发 `reasoning.effort = "medium"`(界面显示的 "reasoning effort: none" 指的
  是摘要项),所以 TPP 渠道必须是 LiteLLM 的 `bedrock_mantle/openai.gpt-5.6-terra` 路由
  (OpenAI 兼容端点,原生透传 Responses API 与 reasoning)。写成 `bedrock/us.openai.*`
  会走 Claude 的 converse 转换,把 `reasoning_effort` 译成 `thinking`,Mantle 以
  `unknown_parameter: thinking` 拒绝;
- Mantle 是独立 IAM 服务前缀:LiteLLM 的 IRSA role 除 `bedrock:Invoke*/Converse*` 外
  还需 `bedrock-mantle:CreateInference`(`infra/modules/iam`),缺失时报 `access_denied`;
- Scorer 的 `ensure_channels` 只按 `model_info.id` 判存在、不会覆盖已注册渠道的
  `litellm_params`,所以改已有渠道的 `model` 字段要额外用 master key 就地 PATCH:
  `curl -X PATCH :14000/model/<id>/update -d '{"litellm_params":{"model":"..."}}'`,
  再用 `/model/info` 确认。

## 日常操作

**加/改渠道**:编辑 `apps/values/scorer-channels.yaml` → `cd apps && terraform apply`
(ConfigMap 哈希变化触发 Scorer 与 Dashboard 重启,Scorer 启动时幂等注册新渠道,Dashboard 渠道表随之多出新行;
新渠道从冷启动分 0.5 + 保底流量爬坡)。

### TPP Dashboard(统一入口)

日常巡检从 http://localhost:3020 开始,页面每 30 秒自动刷新,四个区块自上而下:

| 区块 | 看什么 | 数据来源 |
|---|---|---|
| KPI 卡片 | 近 24h 总消费与 tokens;所选窗口内请求数、错误数、错误率;熔断渠道数 / 总渠道数;配额总额与用户数 | 下方两表的汇总 |
| 用户配额 | 每人本期已消费、剩余、重置时间、日配额;**日配额单元格可直接编辑,回车写回**,按消费降序 | LiteLLM `/user/list`,写回 `/user/update` |
| 渠道消费 · 健康度 · 权重 | 每条渠道近 24h 消费、输入 / 输出 tokens、缓存命中率;健康徽章;Scorer 质量分与权重 | Prometheus `litellm_*` / `scorer_*` |
| 渠道稳定性与性能 | 每条渠道窗口内请求数;TTFT / TPOT / E2E / TPS 的 p50 / p90 / p99;错误次数、错误率、按 `exception_class` 分类 | Prometheus 直方图 |

读数说明:

- **统计窗口**:右上角 15m / 1h / 6h / 24h / 7d 只影响性能与错误;消费与 tokens 固定看近 24h(费用按日粒度)。
  窗口内无成功请求的渠道,分位数显示为空,不是故障。
- **健康徽章**优先级:熔断(`scorer_circuit_open=1`)> 异常(`litellm_deployment_state=2`)> 部分异常(`=1`)> 健康。
  同一渠道多副本取最差值。熔断的处置见[告警响应](#告警响应)的 `TPPChannelCircuitOpen`。
- **缓存命中率** = 缓存读 / (普通输入 + 缓存读 + 缓存写),近 24h;双 region 分流会压低该值,原因与取舍见 [ADR-009](ADR.md)。
- **TPS** 由 TPOT 分位数换算(1 / TPOT),p99 TPS 表示"最慢 1% 请求的解码吞吐",不是峰值吞吐。
- **渠道行**以 `scorer-channels.yaml` 注册表为准,无流量的渠道也会显示,只是数值为空或 0。
- 顶部四个按钮跳转 LiteLLM UI / Grafana / Langfuse / Prometheus,默认指向本地隧道端口;
  部署时可用环境变量 `LINK_LITELLM` / `LINK_GRAFANA` / `LINK_LANGFUSE` / `LINK_PROMETHEUS` 覆盖。

排障:

- 页面报 `overview 502`:Prometheus 不可达或查询失败,`kubectl logs -n dashboard deploy/dashboard`;
- 用户表为空或报 `litellm /user/list: 401`:master key 已轮转而 `dashboard-env` 未刷新(ExternalSecret 为 1h),
  `kubectl annotate externalsecret -n dashboard dashboard-env force-sync=$(date +%s) --overwrite` 后重启 Pod;
- 改配额报 `user not found`:Dashboard 只更新已存在的用户,新用户先按下文 `/user/new` 创建;
- 用户列表最多显示 100 人(`/user/list` 单页),超过需改后端分页。

**升级 Dashboard**:改 `services/dashboard/pyproject.toml` 的 version,构建推送新 tag(命令见 README 部署 §4),
再改 `apps/tpp-dashboard.tf` 的 `dashboard_image_tag` → `cd apps && terraform apply`。

### Per-user quota(USD/天)

前置:`export MASTER_KEY=$(cd apps && terraform output -raw litellm_master_key)`
(隧道守护在线即可,无需手动 port-forward)。

**Dashboard 方式(推荐,改额度)**:http://localhost:3020 → 用户配额表 → 直接编辑"日配额"单元格。
写回时固定 `budget_duration=1d`;只能改已存在的用户,建新用户用下面的 UI 或 API 方式。

**UI 方式**:http://localhost:14000/ui → **Internal Users**:Create User 时填 Max Budget(USD)+
Budget Duration(`1d` = 每日重置);列表页直接显示每人 Spend / Max Budget;点用户可 Edit 改额度。

**API 方式**:

```bash
# 建用户并分配每日 quota(返回的 "key" 交给用户)
curl -s http://localhost:14000/user/new -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"alice","max_budget":10.0,"budget_duration":"1d"}'

# 查看 quota 与已消费(关注 spend / max_budget / budget_reset_at)
curl -s "http://localhost:14000/user/info?user_id=alice" -H "Authorization: Bearer $MASTER_KEY"

# 修改额度
curl -s http://localhost:14000/user/update -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" -d '{"user_id":"alice","max_budget":20.0}'

# 列出所有用户
curl -s "http://localhost:14000/user/list" -H "Authorization: Bearer $MASTER_KEY"
```

quota 按实际 USD spend 实时扣减(LiteLLM 内置价格表折算,无需预折算 token 数),超额返回
429 `budget_exceeded`,到期自动重置。每人当前消费 / 剩余 / 重置时间看 TPP Dashboard 用户配额表;
全局消耗趋势看 Grafana TPP Overview 的"用户剩余预算" 与 "Spend (24h)" 面板。另有 team 级(`/team/new`,共享预算)和 key 级限额可叠加。

### 查看渠道质量分 / 权重

四个入口:

1. **TPP Dashboard(推荐,看当前值)**:http://localhost:3020 → "渠道消费 · 健康度 · 权重"表,
   每条渠道的质量分、权重、熔断状态一行看全;
2. **Grafana(看趋势)**:TPP Overview → "渠道质量分(EWMA)"(`scorer_quality_score`,0~1)
   和 "渠道权重(Scorer 分配)" 两个面板对照看;
3. **Prometheus 即席查询**:`scorer_quality_score`、`scorer_weight`、`scorer_circuit_open`
   (label:`model_group` / `model_id`);
4. **命令行**:
   ```bash
   kubectl port-forward -n scorer svc/scorer 9100:9100 &
   curl -s http://localhost:9100/metrics | grep -E "^scorer_(quality_score|weight|circuit)"
   kubectl logs -n scorer deploy/scorer | grep "weights updated"   # 调权历史
   ```

读数说明:分数 = 0.35×延迟分 + 0.65×错误分,EWMA 平滑(时间常数约 3 分钟);
窗口内请求数 <10 的渠道不更新分数(小样本保护),无流量的组保持冷启动分 0.5、权重 50/50 是设计行为。
完整公式见下文 [Scorer 打分算法](#scorer-打分算法)。

### 调整打分参数

所有参数都是环境变量(定义:`services/scorer/scorer/config.py`),
改法:在 `apps/scorer.tf` 的 scorer container 里加 `env` 块 → `cd apps && terraform apply`。
Pod 滚动重启后下一个周期(60s 内)生效;**EWMA 状态在 Redis,重启不丢**。

| 环境变量 | 默认 | 作用 / 调大的效果 |
|---|---|---|
| `W_LAT` / `W_ERR` | 0.35 / 0.65 | 延迟分/错误分权重(和=1);W_LAT 大 → 更看重速度 |
| `ALPHA` | 0.3 | EWMA 平滑;大 → 反应快但易抖动 |
| `GAMMA` | 2.0 | 分差放大;大 → 好坏渠道流量差距更悬殊 |
| `K_ERR` | 8.0 | 错误惩罚陡度(默认 ê=8.6% 时分数掉一半) |
| `W_FLOOR` | 0.05 | 低分渠道保底流量(探索样本 vs 浪费流量的权衡) |
| `MIN_SAMPLES` | 10 | 窗口内最少请求数,低于则不更新分数 |
| `HYSTERESIS` | 0.02 | 权重变化超过该值才写回 LiteLLM |
| `INTERVAL_SECONDS` / `WINDOW` | 60 / 5m | 打分周期 / 指标观察窗口 |
| `CIRCUIT_ERR_THRESHOLD` | 0.5 | 熔断触发的加权错误率 |
| `CIRCUIT_RECOVERY_ROUNDS` / `CIRCUIT_RECOVERY_ERR` | 3 / 0.1 | 恢复条件:连续 N 轮错误率低于阈值 |
| `DEFAULT_Q` | 0.5 | 新渠道冷启动分 |

示例(更看重延迟、反应更快):

```hcl
env { name = "W_LAT"  value = "0.5" }
env { name = "W_ERR"  value = "0.5" }
env { name = "ALPHA"  value = "0.5" }
```

注意:
- **错误严重性映射**(Timeout=3.0、429=1.5、其它 4xx=0.5)在代码里(`config.py` 的 `SEVERITY`),
  改动需重建镜像:
  ```bash
  cd services/scorer && docker buildx build --platform linux/amd64 \
    -t <aws account>.dkr.ecr.us-west-2.amazonaws.com/tpp/scorer:0.1.0 --push .
  kubectl rollout restart deploy/scorer -n scorer
  ```
- 调参后观察 Grafana "渠道权重" 面板 15–30 分钟,曲线来回震荡说明 `ALPHA`/`GAMMA` 过激;
  `ALPHA` 调大时建议同步调大 `HYSTERESIS` 压制抖动。

**暂停智能调度**(权重冻结在当前值,不影响请求):
```bash
kubectl scale deploy/scorer -n scorer --replicas=0
```

**手动改某渠道权重**(临时干预;下轮 Scorer 会覆盖,先暂停 Scorer):
```bash
curl -X PATCH http://localhost:14000/model/<channel-id>/update \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"litellm_params": {"weight": 0}}'
```

**省钱开关(下班停 dev 环境)**:
```bash
# 停:节点缩 0 + 停 RDS(ElastiCache/EKS 控制面无法停,~$85/月底座)
aws eks update-nodegroup-config --cluster-name tpp-dev --nodegroup-name <ng> \
  --scaling-config minSize=0,maxSize=5,desiredSize=0 --region us-west-2
aws rds stop-db-instance --db-instance-identifier tpp-dev --region us-west-2
# 起:反向操作(RDS 自动停最多 7 天后会自启)
```

## RDS 凭证轮转与自动恢复

RDS 通过 `manage_master_user_password=true` 托管 PostgreSQL 主密码;AWS 每 **7 天**轮转一次。
**7 天是密码轮转周期,不是平台恢复时间。**

```text
RDS/Secrets Manager 密码轮转
        ↓(最多 5 分钟)
External Secrets 刷新 litellm-env / langfuse-postgres
        ↓(Secret data 变化)
Stakater Reloader 检测变化
        ↓(RollingUpdate)
LiteLLM、Langfuse Web、Langfuse Worker 使用新密码启动
```

| 项 | 实现 |
|---|---|
| 密码来源 | RDS 托管的 Secrets Manager secret |
| 同步频率 | `litellm-env`、`langfuse-postgres` 的 ESO `refreshInterval` 均为 **5m** |
| 自动重启 | `reloader` chart 固定 `2.2.16`,全局监听 Secret 变化;LiteLLM、Langfuse Web、Langfuse Worker 都带 `reloader.stakater.com/auto: "true"` |
| 最大凭证发现延迟 | 约 5 分钟,之后等待一次常规 RollingUpdate 完成;无需人工 `kubectl rollout restart` |
| LiteLLM 密钥 Secret | `litellm-env` |
| Langfuse 密钥 Secret | `langfuse-postgres` |

Langfuse 的 RDS 密码可能包含 `@`、`:`、`/`、`%`、`#`、`?` 等 URI 保留字符。`langfuse-postgres`
ExternalSecret 会同时生成 URL-encoded 的 `database_url`,并以 `DATABASE_URL` / `DIRECT_URL` 注入
Web 与 Worker,避免 Prisma `P1013 invalid port number` 错误。不能只把原始密码交给 chart 的 `DATABASE_PASSWORD`。

排障要点:

- 轮转后 LiteLLM 起不来:`kubectl get externalsecret -n litellm litellm-env`,看 `SecretSynced` 状态与最近同步时间;
  若 ESO 已同步但 Pod 未重启,查 `kubectl logs -n kube-system deploy/reloader-reloader`;
- 手动加速:`kubectl annotate externalsecret -n litellm litellm-env force-sync=$(date +%s) --overwrite` 触发立即同步;
- 变更清单与验证记录见 [`rds-rotation-recovery-changes.md`](rds-rotation-recovery-changes.md);设计取舍见 [ADR-001](ADR.md)。

## Scorer 打分算法

评分对象:LiteLLM deployment,即 **(渠道, 模型) 二元组**,只在同一模型组内互比。
每 60s 一轮,取 Prometheus 过去 5 分钟窗口。参数的环境变量名与调整方法见上文[调整打分参数](#调整打分参数);
设计取舍与已知缺口见 [ADR-005 / ADR-006](ADR.md)。

### 符号定义

| 符号 | 来源 | 含义 |
|------|------|------|
| `d` | deployment | 被评分的 deployment,即(渠道, 模型)二元组 |
| `j` | — | 求和下标,遍历与 `d` 同模型组内的所有 deployment |
| `cat` | category | 错误类别,取值见下方严重性系数表 |
| `lat(d)` | latency | `d` 在窗口内的端到端(E2E)p90 延迟 |
| `lat_best` | latency, best | 同模型组内最小的 p90 延迟,即组内最快者的延迟 |
| `req(d)` | requests | `d` 在窗口内的请求总数 |
| `err(d, cat)` | errors | `d` 在窗口内类别为 `cat` 的错误数 |
| `sev(cat)` | severity | 错误类别 `cat` 的严重性系数 |
| `err_rate(d)` | error rate | `d` 的加权错误率 |
| `score_lat(d)` | score, latency | 延迟单项得分,取值范围 [0, 1] |
| `score_err(d)` | score, error | 错误单项得分,取值范围 (0, 1] |
| `q_raw(d)` | quality, raw | 本轮的原始质量分 |
| `q(d, t)` | quality | 第 `t` 轮 EWMA 平滑后的质量分;新渠道冷启动初始值 0.5 |
| `gamma` | γ | 权重放大指数,取 2,用于放大组内分差 |
| `weight(d)` | weight | 写回 LiteLLM 的路由权重 |

### 严重性系数

| 错误类别 `cat` | 严重性系数 `sev(cat)` |
|------|------|
| 5xx / Timeout / 连接错误 | 3.0 |
| 429(限流) | 1.5 |
| 其它 4xx | 0.5 |

### 计算公式

**加权错误率**(分母取 max 防止除零):

```
                ∑  sev(cat) × err(d, cat)
               cat
err_rate(d) = ───────────────────────────
                    max(req(d), 1)
```

**单轮得分**(组内最快者 `score_lat = 1`;`err_rate = 8.6%` 时 `score_err` 降至 0.5):

```
                     ⎛ lat_best          ⎞
score_lat(d) = clamp ⎜ ──────── , 0 , 1  ⎟
                     ⎝  lat(d)           ⎠

score_err(d) = exp( −8 × err_rate(d) )
```

**原始质量分**(错误权重高于延迟):

```
q_raw(d) = 0.35 × score_lat(d) + 0.65 × score_err(d)
```

**EWMA 平滑**(时间常数约 3 分钟):

```
q(d, t) = 0.3 × q_raw(d) + 0.7 × q(d, t−1)
```

**路由权重**(组内按质量分的 gamma 次幂归一化,gamma = 2):

```
                q(d)^gamma
weight(d) = ─────────────────
             ∑  q(j)^gamma
             j
```

随后施加探索保底:`weight(d) ← max(weight(d), 0.05)`,再重新归一化,防止低分渠道死锁。

### 运行规则

| 环节 | 规则 |
|------|------|
| 小样本保护 | `req(d) < 10` 时跳过本轮更新,沿用旧分 |
| 熔断 | `err_rate(d) > 0.5` 且 severe 类(5xx/Timeout/连接错误)主导时,置 `weight(d) = 0`(优先于探索保底) |
| 恢复 | 设计为连续 3 轮 `err_rate(d) < 0.1` 后关闭熔断;**当前实现有缺口**:权重 0 的渠道拿不到样本,状态机不再评估,需人工干预,详见 [ADR-006 §6.3](ADR.md) |
| 写回 | 组内任一权重变化超过 2 个百分点才调用 LiteLLM `/model/update`(迟滞防抖) |
| 降级 | Prometheus / LiteLLM API 不可用时,权重冻结并告警(Scorer 不在请求路径上) |
| 状态持久化 | EWMA 分数存 Redis(`scorer:score:<channel_id>`),重启无损 |
| 部署形态 | 单副本 Deployment(非 CronJob),自身导出 `scorer_quality_score` / `scorer_weight` / `scorer_last_success_timestamp` 指标 |

## 告警响应

| 告警 | 含义 | 处置 |
|---|---|---|
| TPPScorerStale | Scorer >5min 未成功打分,权重冻结 | `kubectl logs -n scorer deploy/scorer`;常见:Prometheus 不可达、LiteLLM API 401(master key 轮转后 ExternalSecret 未刷新) |
| TPPLiteLLMHighErrorRate | 整体错误率 >10% | 先看 TPP Dashboard "渠道稳定性与性能"表的错误分类定位渠道(窗口切 15m);单渠道故障应已被熔断,若是全渠道则查 Bedrock 服务状态/IAM |
| TPPLiteLLMDown | proxy 全副本失联 | `kubectl get pods -n litellm`;查 RDS(litellm 启动强依赖 DB)与最近 apply |
| TPPChannelCircuitOpen | 渠道被熔断 >5min | TPP Dashboard 健康徽章显示"熔断";当前实现**不会自动恢复**(见 [ADR-006 §6.3](ADR.md)):先查该 region 的 Bedrock 配额/健康,确认恢复后暂停 Scorer、手动把该渠道权重改回非 0 并清 Redis `scorer:circuit:<id>`,再恢复 Scorer |

## 已知事项 / 陷阱

- **渠道定义只在 scorer-channels.yaml**,LiteLLM config 的 model_list 故意为空
  (静态 config 模型无法被 Management API 调权)。不要在 LiteLLM UI 里手工加模型,会绕开注册表。
- Langfuse 是 v4(OTel-native):LiteLLM callback 必须用 `langfuse_otel`,旧 `langfuse` callback 会 400。
- 单节点 ClickHouse 必须 `clickhouse.cluster.enabled=false`,否则迁移要求 Keeper。
- apps 层首次部署需两段 apply(CRD 时序),见 apps/README.md。
- `/metrics` 受认证保护,ServiceMonitor 用 master key Bearer 抓取;轮转 master key 要同步等 ExternalSecret 刷新(`litellm-env` 现为 5m,`dashboard-env` 仍为 1h)或手动触发。
  Dashboard 与 Scorer 都持有 master key 调 Management API,轮转后两者会 401,表现为 Dashboard 用户表为空、`TPPScorerStale` 告警。
- **TPP Dashboard 无自身认证**,安全前提是不暴露 Ingress、只经隧道访问;它持有 master key 且能改配额,
  不要把 3020 端口转发到局域网或公网。上 ALB 前必须先补 OIDC(`docs/scaling-500-users.md` §9)。
- Dashboard 依赖 Prometheus 的 `model_id` / `exception_class` / `le` label 与 `scorer-channels.yaml` 注册表;
  降基数或改注册表格式时要一起回归。
- TTFT 指标仅流式请求产生;TPOT 用 `litellm_deployment_latency_per_output_token`。
- **launchd 无法执行 `~/Documents` 下的脚本**(macOS TCC,报 `Operation not permitted`),
  隧道脚本必须用 `~/.local/bin/` 下的副本;**改仓库脚本后要 `cp` 同步过去并重启服务**。
- **本地 LiteLLM 端口是 14000**(从 4000 迁移而来,4000 让给了本机其他应用);
  `14000:4000` 中右侧 4000 是 pod 容器端口,平台侧从未变更。
- 手动/守护的 port-forward 会互抢端口:隧道脚本启动时会 pkill 接管同类进程;
  排查端口冲突用 `lsof -nP -iTCP:<port> -sTCP:LISTEN` 看属主。
- Claude Code 直连 Bedrock 的基线配置备份:`~/.claude/settings.json.bedrock-backup`
  与 `docs/claude-code-config-baseline.md`,回滚见"Claude Code 接入 TPP"章节。

## 当前环境登记

- 渠道注册表:4 个 Claude 模型组 × 2 region + `gpt-5.6-terra`(Bedrock Mantle,usw2)= **9 渠道**;
- 已建用户:`dev-laptop`($100/天)、`dev-laptop-codex`($100/天,本机 `TPP_API_KEY`,Codex 与 `claude-tpp` 共用);
- 本机 Claude Code / Codex:**默认 Bedrock 直连,按需切 TPP**(`claude-tpp` / `codex --profile tpp`);
- 本机隧道守护:launchd `com.tpp.litellm-proxy` → 五条隧道;
- 仓库未 git commit;dev 环境常驻成本约 $400–450/月(省钱开关见上文)。
