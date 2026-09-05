# TPP 架构设计记录(ADR,Architecture Design Record)

本文汇总 TPP(Token Proxy Platform)已经做出的关键架构决策。每条记录回答三个问题:
**当时面对什么问题、选了什么方案、付出了什么代价**。已有独立文档的决策只做摘要并给出链接,
尚无文档的决策(隧道看门狗、双模式接入、prompt cache 取舍)在这里首次系统整理。

文档分工:[`README.md`](../README.md) 负责架构组件、仓库结构与部署步骤;
[`docs/runbook.md`](runbook.md) 负责日常操作、RDS 凭证轮转恢复链路、Scorer 打分算法与运行规则、告警响应;
本文只记录"为什么这样设计"。所有描述以当前仓库中的代码与配置为准;
与 runbook 描述不一致处,以本文标注的代码行为为准。

| 编号 | 领域 | 主题 |
|---|---|---|
| [ADR-001](#adr-001-security-rds-凭证轮转后的自动重连) | Security | RDS 凭证轮转后的自动重连 |
| [ADR-002](#adr-002-resiliency-本地隧道的健康探测看门狗) | Resiliency | 本地隧道的健康探测看门狗 |
| [ADR-003](#adr-003-resiliency-客户端在-tpp-与直连模型之间切换) | Resiliency | 客户端在 TPP 与直连模型之间切换 |
| [ADR-004](#adr-004-ops-新机器安装隧道守护) | Ops | 新机器安装隧道守护 |
| [ADR-005](#adr-005-ops-渠道权重的打分机制) | Ops | 渠道权重的打分机制 |
| [ADR-006](#adr-006-ops-scorer-运行规则) | Ops | Scorer 运行规则(小样本、熔断、恢复、写回、降级) |
| [ADR-007](#adr-007-ops-自建统一入口-dashboard) | Ops | 自建统一入口 Dashboard |
| [ADR-008](#adr-008-scaling-500-用户规模的架构调整) | Scaling | 500 用户规模的架构调整 |
| [ADR-009](#adr-009-trade-off-稳定性优先导致-prompt-cache-命中率下降) | Trade-off | 稳定性优先导致 prompt cache 命中率下降 |

---

## ADR-001 [Security] RDS 凭证轮转后的自动重连

**状态**:已实施。恢复链路、Secret 名称与排障要点见 [`docs/runbook.md`](runbook.md#rds-凭证轮转与自动恢复)
"RDS 凭证轮转与自动恢复"章节;详细变更清单见 [`docs/rds-rotation-recovery-changes.md`](rds-rotation-recovery-changes.md)。

### 背景

RDS 以 `manage_master_user_password=true` 托管 PostgreSQL 主密码,AWS 每 **7 天**自动轮转。
LiteLLM 与 Langfuse 都在启动时从环境变量读取数据库连接串,进程存活期间不会重新读取。
External Secrets Operator(ESO)即使把新密码同步进了 Kubernetes Secret,已运行的 Pod 仍持有旧密码,
表现为轮转后 LiteLLM 启动失败或 Langfuse Prisma 连接被拒,需要人工 `kubectl rollout restart`。

### 决策

不改应用代码、不做进程内重连,而是**让密码变化触发滚动重启**:

```text
RDS / Secrets Manager 密码轮转
  → ESO 以 5m refreshInterval 轮询,最多 5 分钟内刷新 litellm-env / langfuse-postgres
  → Stakater Reloader 发现 Secret data 变化
  → LiteLLM、Langfuse Web、Langfuse Worker 滚动重启
  → 新 Pod 使用新密码启动
```

"5 分钟"是 ESO 的主动探测周期,也是凭证发现的最长延迟;它不是轮转周期,轮转周期仍是 7 天。

### 实现要点

- `litellm-env` 与 `langfuse-postgres` 两个 ExternalSecret 的 `refreshInterval` 从 `1h` 缩到 `5m`
  (`apps/litellm.tf`、`apps/langfuse.tf`)。
- `apps/platform.tf` 新增 Reloader Helm release(chart `2.2.16`,namespace `kube-system`),
  全局监听 Secret / ConfigMap,只重启带 `reloader.stakater.com/auto: "true"` 注解的工作负载。
- Reloader 触发重启的方式是往容器注入一个 checksum 环境变量。LiteLLM Deployment 用 Terraform 原生资源管理,
  因此预留了首个 env `STAKATER_LITELLM_ENV_SECRET` 并在 `lifecycle.ignore_changes` 中忽略其值,
  否则下一次 `terraform apply` 会抹掉 Reloader 的改动并回滚重启。
- Langfuse 走 Prisma,密码含 `@ : / % # ?` 等 URI 保留字符时会报 `P1013 invalid port number`。
  因此在 ExternalSecret 模板里用 `urlquery` 编码密码,直接生成完整的 `database_url`,
  以 `DATABASE_URL` / `DIRECT_URL` 注入,而不是把裸密码交给 chart 拼接。

### 备选方案

| 方案 | 未采用原因 |
|---|---|
| 关闭托管轮转,使用静态密码 | 放弃了托管轮转带来的安全收益,凭证进入 tfstate |
| 应用内检测连接失败后重读 Secret | LiteLLM / Langfuse 均为第三方镜像,改造成本高且升级即失效 |
| CronJob 每 7 天定时 rollout | 与 AWS 轮转时刻无法精确对齐,窗口内仍会出错 |

### 后果与权衡

- 每 7 天三个工作负载各滚动重启一次。LiteLLM 有 2 副本且 readiness 探针到位,
  重启期间新请求不受影响,但**正在滚动的那个 Pod 上的流式请求会中断**,客户端需重试。
- 凭证发现最长延迟 5 分钟。窗口内 LiteLLM 若因其他原因重启,会用旧密码启动失败,由 startupProbe 兜住等待下一轮同步。
- ESO 对 Secrets Manager 的调用频率提高 12 倍,dev 规模下成本可忽略。
- 同一 Secret 内任何字段变化(如 master key 轮转)也会触发重启,这是期望行为。
- `dashboard-env` 仍为 `1h` 刷新,它只含 master key,不含 RDS 密码,不在本决策范围内。

---

## ADR-002 [Resiliency] 本地隧道的健康探测看门狗

**状态**:已实施。代码见 [`scripts/tpp-tunnels.sh`](../scripts/tpp-tunnels.sh)。本条为首次成文。

### 背景

dev 环境不暴露 Ingress,本机通过 `kubectl port-forward` 隧道访问 LiteLLM(14000)、Grafana(3000)、
Langfuse(3010)、Prometheus(9090)、TPP Dashboard(3020)。
隧道脚本原先的恢复模型是"kubectl 进程退出就重新拉起"。实际运行中发现一种失效模式:
**笔记本切换网络或睡眠唤醒后,kubectl 与 API server 的连接已断,但进程不退出,本地端口仍在监听,
所有转发请求超时**。这种"僵死"对"进程退出才重连"完全不可见,`claude-tpp` 等客户端持续报连接超时,
需要人工 kill 进程。

### 决策

在每条隧道的守护循环里加一个**基于本地 HTTP 探测的看门狗**,把"隧道是否可用"的判断从进程存活
改为端到端可达:

```text
forward <名字> <namespace> <service> <本地:远端> <健康探测 URL>
  ┌─ 后台启动 kubectl port-forward,记录 pid
  │  循环(pid 存活期间):
  │    sleep 15
  │    curl -sf -m 5 <健康探测 URL>
  │      成功 → fails = 0
  │      失败 → fails += 1;fails ≥ 3 → kill pid,跳出
  │  wait pid;sleep 3
  └─ 回到顶部重新拉起
```

### 实现要点

- **探测周期 15 秒,连续 3 次失败判定僵死**,每次 curl 超时 5 秒。
  最坏检测时间 ≈ 3 × (15 + 5) = 60 秒,典型约 45 秒,与 runbook 中"约 45 秒内自动重启"一致。
- 探测目标是各服务自己的轻量健康端点,不经过认证,不产生业务副作用:

  | 隧道 | 探测 URL |
  |---|---|
  | LiteLLM | `/health/liveliness` |
  | Grafana | `/api/health` |
  | Langfuse | `/api/public/health` |
  | Prometheus | `/-/healthy` |
  | Dashboard | `/healthz` |

- kubectl 改为后台启动并用进程替换 `> >(sed ...)` 加日志前缀,而不是原先的管道 `kubectl | sed`。
  管道方式下 `$!` 拿到的是 sed 的 pid,无法定位并 kill kubectl,这是看门狗能成立的前提。
- 探测失败只 kill kubectl,不退出脚本;外层 `while true` 负责 3 秒后重连,复用了原有的断线重连路径。
- 脚本启动时 `pkill` 同类 port-forward 进程实现"单一属主",避免手动隧道与守护隧道互抢端口。
- 五条隧道各自独立看门狗,互不影响;一条僵死不会重启其他四条。
- launchd(`KeepAlive`)负责脚本整体崩溃后的重启,`ThrottleInterval 10` 防止崩溃风暴。
  看门狗与 launchd 是两层:launchd 保脚本活着,看门狗保隧道通着。

### 备选方案

| 方案 | 未采用原因 |
|---|---|
| 依赖 kubectl 自身超时参数 | `port-forward` 没有针对已建立连接的心跳/超时选项 |
| 每 N 分钟无条件重启全部隧道 | 会中断正在进行的流式请求,且僵死窗口仍可达 N 分钟 |
| 用 SSM / VPN / Ingress 替代 port-forward | 是 500 人规模的正确方向(见 ADR-008 §9),但 dev 单人阶段成本不匹配 |

### 后果与权衡

- **误杀是被接受的**:探测打的是服务健康端点,后端 Pod 滚动重启(例如 ADR-001 每 7 天的重启)期间
  探测会失败,隧道会被杀并重连。这实际上是有益的:`port-forward` 到 Service 时绑定的是启动时选中的
  某一个 Pod,该 Pod 消失后隧道本就不可用,重连才能绑到新 Pod。
- 后端真的宕机时,隧道会进入"每 ~1 分钟杀一次、3 秒后重连"的循环,`/tmp/tpp-proxy.log` 会持续增长。
  dev 阶段可接受;若长期运行需要加日志轮转或指数退避。
- 每条隧道每 15 秒一次本地 HTTP 请求,五条隧道合计约 20 请求/分钟,对服务端可忽略。
- 脚本存在两份副本(仓库与 `~/.local/bin/`,原因见 ADR-004),**改动仓库脚本后必须同步复制**,
  否则 launchd 跑的还是旧逻辑。当前两份已核对一致。

---

## ADR-003 [Resiliency] 客户端在 TPP 与直连模型之间切换

**状态**:已实施。操作步骤见 [`docs/runbook.md`](runbook.md) 的
"Claude Code 接入 TPP"与"Codex CLI 接入 TPP"章节,基线配置见
[`docs/claude-code-config-baseline.md`](claude-code-config-baseline.md)。本条为首次成文。

### 背景

TPP 本身是被开发和排障的对象。如果 Claude Code / Codex 这类 AI 编程助手**只能**经 TPP 访问模型,
那么 TPP 一旦出问题(隧道僵死、LiteLLM 滚动重启、RDS 轮转失败、渠道熔断、配额耗尽),
排障所依赖的 AI 助手也同时失效,形成"用坏掉的东西修坏掉的东西"的死锁。
另一方面,日常又希望流量走 TPP,以便验证配额、trace、打分链路。

### 决策

客户端保持**两条互不干扰的接入路径,默认直连,按需切 TPP**:

| | 直连 Bedrock(默认) | 经 TPP |
|---|---|---|
| 依赖 | 本机 AWS IAM 凭据、Bedrock 服务 | 上面全部 + 隧道 + LiteLLM + RDS + Redis + TPP user key |
| Claude Code | `claude`,读 `~/.claude/settings.json` | `claude-tpp` = `claude --settings ~/.claude/tpp.settings.json` |
| Codex CLI | `codex`,读 `~/.codex/config.toml` 顶层 | `codex --profile tpp`,profile 在 `~/.codex/tpp.config.toml` |
| 模型名 | Bedrock inference profile id(`us.anthropic.*`) | TPP 模型组名(`claude-fable-5` 等) |
| 回滚方式 | 不带参数运行即是 | 不带 `--settings` / `--profile` 运行即回落 |

三条设计原则:

1. **基线文件永不被 TPP 配置污染**。TPP 配置只存在于覆盖层文件(Claude Code 的 `--settings`
   叠加、Codex 的独立 profile 文件),"回滚"不需要编辑任何文件,只需换一个命令。
2. **两条路径打到同一批模型**。TPP 渠道注册表里全部是 Bedrock 渠道,与直连使用同一账户、
   同一批 inference profile,因此切换不改变模型能力,只改变是否经过代理。
3. **基线有离线备份**。`~/.claude/settings.json.bedrock-backup`、`docs/claude-code-config-baseline.md`
   与仓库 `.codex-backup/` 三处备份,即使覆盖层误合入基线也能一条 `cp` 恢复。

### 实现要点

- Claude Code 没有 profile 概念,靠 `--settings <file>` 覆盖层实现:`env` 按键合并并覆盖 shell 环境变量,
  优先级最高。覆盖层里必须写 `"CLAUDE_CODE_USE_BEDROCK": "0"`(按数值解析,`"false"` 不保证生效),
  并同时改 `ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`、两个模型名与顶层 `model`。
- Codex ≥ 0.134 的 profile 是独立文件、用顶层键;provider 定义写在主配置的 `[model_providers.tpp]`,
  `wire_api` 必须是 `"responses"`(`"chat"` 已废弃且会导致整个 config.toml 解析失败,连直连也一起挂)。
- TPP 侧为 Codex 单独注册 `gpt-5.6-terra` 模型组(Bedrock Mantle,`bedrock_mantle/` 路由透传 Responses API 与 reasoning),
  IRSA 需额外授予 `bedrock-mantle:CreateInference`。
- 验证是否真的走了 TPP:Claude Code 用 `-p ... --output-format json` 看 `modelUsage` 键是否为 TPP 模型组名;
  或看 LiteLLM `/user/info` 的 spend 增长(落账延迟约 5~15 秒)、Langfuse 新 trace。

### 后果与权衡

- **直连流量游离于 TPP 之外**:不计入 per-user quota,没有 trace,不参与打分,也不受 TPP 的
  双 region 分流。这是有意为之的代价,换取排障期间助手可用。
- 两套凭证并存(IAM user 凭据 + TPP user key),泄露面变大;TPP key 文件需 `chmod 600`。
- 模型名在两条路径下不同,涉及模型名的脚本或提示词需按路径调整。
- 直连固定 `us-west-2` 单 region,TPP 在 usw2 / use1 之间按权重分流,两者的 prompt cache 表现不同,见 ADR-009。
- 用户习惯成本:需要记住两个命令,以及"TPP 出问题时先切直连再排查"这个动作。

---

## ADR-004 [Ops] 新机器安装隧道守护

**状态**:已实施。完整命令见 [`docs/runbook.md`](runbook.md) 的"新机器安装隧道守护(一次性)"章节。

### 背景

隧道脚本(ADR-002)需要在开发机上常驻、登录自启、崩溃自拉起,并且对使用者透明:
打开浏览器就能访问 Grafana / Langfuse,运行 `claude-tpp` 就能连上 LiteLLM,不需要先手动开终端跑命令。

### 决策

用 **macOS launchd 用户级 LaunchAgent**(`com.tpp.litellm-proxy`)常驻运行 `tpp-tunnels.sh`,
脚本副本放在 `~/.local/bin/`,而不是直接指向仓库路径。

### 实现要点

- **脚本必须复制到 `~/.local/bin/`**:macOS TCC(Transparency, Consent, and Control)禁止 launchd
  执行 `~/Documents` 下的文件,直接指向仓库路径会报 `Operation not permitted`。
  这也是"改仓库脚本后要同步 `cp` 过去并重启服务"这条运维纪律的来源。
- plist 关键项:`RunAtLoad`(登录自启)、`KeepAlive`(退出即重启)、`ThrottleInterval 10`(重启间隔下限)、
  显式 `PATH`(launchd 不读 shell rc,需要能找到 `/opt/homebrew/bin` 下的 kubectl / aws)、
  `AWS_PROFILE=default`(kubeconfig 的 exec 凭据插件需要)。
- stdout / stderr 统一到 `/tmp/tpp-proxy.log`,配合脚本内的 `[名字]` 前缀区分五条隧道。
- plist 不展开 `$HOME`,`ProgramArguments` 里必须写绝对路径。
- 安装后用五条 `curl` 打各自的健康端点验证,与看门狗使用同一组 URL。
- 前置条件:aws cli(含 IAM 凭据)、kubectl、已执行 `aws eks update-kubeconfig --name tpp-dev --region us-west-2`。
  脚本启动时会检查当前 kubecontext 是否为 `tpp-dev`,否则直接退出并提示。

### 备选方案

| 方案 | 未采用原因 |
|---|---|
| 仅提供手动脚本 `tpp-connect.sh` / `tpp-tunnels.sh` | 每次开机都要手动跑,忘记就报连接失败;保留为备用路径 |
| Homebrew services / tmux 常驻 | 仍依赖用户手动启动一次;launchd 是 macOS 的原生方案 |
| 暴露 Ingress + 域名 | dev 阶段没有 OIDC / WAF,暴露即等于公网无认证;列入 ADR-008 §9 |

### 后果与权衡

- 只覆盖 macOS;Linux / Windows 开发机需要 systemd user unit 或等价方案,目前没有。
- 每台机器一次性手工安装,没有自动化分发。人数上量后应替换为 Ingress 方案而非批量分发 plist。
- 脚本双副本问题(见 ADR-002 后果)是本决策的直接代价。

---

## ADR-005 [Ops] 渠道权重的打分机制

**状态**:已实施。完整公式与符号表见 [`docs/runbook.md`](runbook.md#scorer-打分算法) "Scorer 打分算法"章节,
参数调整方法见同文档"调整打分参数"。代码在 `services/scorer/scorer/scoring.py`(纯函数)与 `config.py`。

### 背景

同一模型组(如 `claude-fable-5`)在 LiteLLM 里有多个渠道(usw2 / use1 两个 Bedrock region)。
LiteLLM 自带的路由策略只有静态权重或简单的延迟/用量策略,缺乏"综合错误与延迟、平滑、可解释"的
质量评估,也没有跨副本一致的全局视角。需要一个独立组件按观测到的质量动态调整各渠道流量占比。

### 决策

自建 **Scorer**:每 60 秒查询 Prometheus 过去 5 分钟窗口,对同一模型组内的渠道互相打分,
把归一化权重经 LiteLLM Management API `PATCH /model/{id}/update` 写回。
**Scorer 不在请求路径上**,LiteLLM 在请求时只读自身 DB 里的 weight 做加权随机(`simple-shuffle`)。

### 算法摘要

评分对象是 deployment,即(渠道, 模型)二元组,只在同一模型组内比较。

```text
err_rate(d)   = Σ_cat sev(cat) × err(d, cat) / max(req(d), 1)       加权错误率

score_lat(d)  = clamp(lat_best / lat_p90(d), 0, 1)                   组内最快者得 1
score_err(d)  = exp(−K_ERR × err_rate(d))                            K_ERR = 8,err_rate = 8.6% 时降至 0.5

q_raw(d)      = W_LAT × score_lat(d) + W_ERR × score_err(d)          W_LAT = 0.35,W_ERR = 0.65
q(d, t)       = ALPHA × q_raw(d) + (1 − ALPHA) × q(d, t−1)           ALPHA = 0.3,时间常数约 3 分钟

weight(d)     = q(d)^GAMMA / Σ_j q(j)^GAMMA                          GAMMA = 2,放大组内分差
weight(d)     ← max(weight(d), W_FLOOR),再归一化                     W_FLOOR = 0.05,探索保底
```

错误严重性系数 `sev(cat)`:Timeout / 连接错误 / 5xx 类为 3.0,429 限流为 1.5,其余 4xx 为 0.5。

### 关键取舍及理由

| 取舍 | 选择 | 理由 |
|---|---|---|
| 错误 vs 延迟的权重 | 错误 0.65 > 延迟 0.35 | 一次失败对用户的伤害远大于慢几百毫秒;延迟分只在组内相对比较,避免绝对阈值 |
| 延迟分位 | E2E p90 | p50 掩盖尾部,p99 在小样本下噪声太大 |
| 错误分函数 | 指数衰减而非线性 | 让低错误率区间敏感、高错误率区间迅速趋零,同时保证 (0, 1] 不出负数 |
| 错误分类加权 | 按 `exception_class` 分三档 | 4xx 多为调用方问题,不应惩罚渠道;429 是配额信号,介于两者之间 |
| 平滑方式 | EWMA,状态存 Redis | 抑制单轮抖动;Redis 持久化让 Scorer 重启不丢历史、不回到冷启动 |
| 权重放大 | `GAMMA = 2` | 线性归一化下 0.9 vs 0.6 的渠道只有 60/40 分流,平方后约 69/31,更快把流量从劣质渠道挪走 |
| 探索保底 | 5% 下限 | 没有流量就没有样本,分数永远不更新;5% 是"保留观测能力"与"少浪费流量"的折中 |
| 部署形态 | 单副本 Deployment,非 CronJob | 多副本会并发写权重冲突;Deployment 便于导出自身指标 |
| 渠道定义位置 | `scorer-channels.yaml` 注册表,LiteLLM 静态 `model_list` 留空 | 静态 config 里的模型无法被 Management API 调权,必须走 `store_model_in_db` |

### 后果与权衡

- 权重是**整数 0–100**写回,小于 0.5% 的差异会被四舍五入抹平。
- 组内只有一条渠道时(如 `gpt-5.6-terra`),打分仍运行但权重恒为 100,只起观测作用。
- 所有参数都是环境变量,改参数需 `terraform apply` 触发 Pod 重启;严重性映射在代码里,改动需重建镜像。
- 打分依赖 Prometheus 的 `model_id` label,任何降基数改造(ADR-008 §8)必须保留该 label。

---

## ADR-006 [Ops] Scorer 运行规则

**状态**:已实施,存在一处已知缺口(见"恢复")。代码在 `services/scorer/scorer/main.py`。
[`docs/runbook.md`](runbook.md#scorer-打分算法) "Scorer 打分算法"末尾的"运行规则"表是本条的简版,本条按代码逐条展开。

### 决策总览

Scorer 的运行规则围绕一个原则:**宁可不动,不可乱动**。任何不确定(样本不足、依赖不可用)
都导向"沿用上一轮结果",只有证据充分时才改权重。

### 6.1 小样本保护

- 条件:窗口内该渠道 `req(d) < MIN_SAMPLES`(默认 10),或 Prometheus 里根本没有该渠道的序列。
- 行为:不计算新分,沿用 Redis 里的旧分;从未打过分的新渠道用 `DEFAULT_Q = 0.5` 冷启动。
- 理由:10 个请求里 1 个超时就是 10% 加权错误率的 3 倍,足以把分数砍掉一半;小样本下的分数是噪声。
- 副作用:无流量的模型组永远保持 0.5 / 0.5,权重 50 / 50,这是设计行为不是故障。
- 注意:**小样本时熔断状态机也不评估**,这是 6.3 缺口的根源。

### 6.2 熔断

- 触发条件(两者同时满足):
  1. `err_rate(d) > CIRCUIT_ERR_THRESHOLD`(默认 0.5);
  2. **严重错误占主导**:Timeout / 连接错误 / 5xx 类错误的**计数**占全部错误计数的 ≥ 50%。
- 行为:置 `scorer:circuit:<id> = 1`,该渠道权重直接置 0,**优先于探索保底**;
  同组其余渠道重新归一化。全组都熔断时均分权重,避免流量无处可去,此时靠 LiteLLM 自身 cooldown 兜底。
- 理由:
  - 第二个条件把"渠道坏了"与"渠道被限流"区分开。429(`RateLimitError`)严重性 1.5,不在 severe 集合,
    因此**限流永不触发熔断,只会通过分数降低权重**。在双 region 拓扑下这是对的:限流的渠道仍能服务一部分请求。
    多账户多 region 分片后需要重新审视,见 ADR-008 §10。
  - 权重 0 而非保底 5%,因为 severe 错误主导意味着渠道大概率完全不可用,5% 流量只是 5% 的失败。
- 与 LiteLLM 自身熔断的关系:LiteLLM `allowed_fails: 3` / `cooldown_time: 60` 是**请求路径上、每个 proxy
  副本独立、秒级**的第一层;Scorer 熔断是**全局一致、分钟级、基于 5 分钟窗口统计**的第二层。
  前者快但视野窄,后者慢但不会因某个副本的偶发失败误判。两层互为双保险。

### 6.3 恢复

- 设计意图(runbook 运行规则表):连续 `CIRCUIT_RECOVERY_ROUNDS = 3` 轮 `err_rate(d) < CIRCUIT_RECOVERY_ERR = 0.1`
  后关闭熔断,恢复到保底权重再靠分数爬坡。
- 代码行为:好轮次计数存 Redis `scorer:circuit_good:<id>`,任一轮不达标即清零;计数达到 3 关闭熔断。
- **已知缺口**:恢复判断只在 `req(d) ≥ MIN_SAMPLES` 的分支里执行。而熔断后权重为 0,
  LiteLLM `simple-shuffle` 对 weight 0 的 deployment 不分配流量,该渠道在 5 分钟窗口滑过之后
  样本数归零,状态机不再被评估,**熔断永远不会自动关闭**。
  目前能让它恢复的实际途径只有:同组其他渠道全部进入 LiteLLM cooldown 导致流量落到它身上;
  或人工用 master key 改权重 / 清 Redis 键。`TPPChannelCircuitOpen` 告警"通常无需动作(自动恢复)"的说法
  以此为前提,目前并不成立。runbook 的运行规则表已同步标注该缺口。
- 建议修复方向(未实施):熔断渠道保留极小探测权重(如 1%),或熔断后按时间进入"半开"状态、
  用 LiteLLM `/health` 主动探测代替流量样本。

### 6.4 写回(迟滞防抖)

- 每轮从 LiteLLM `/model/info` 读当前 weight 并按组归一化,与本轮计算结果比较;
  组内任一渠道权重变化超过 `HYSTERESIS = 0.02`(2 个百分点)才调用 `PATCH /model/{id}/update`。
- 理由:权重写入 LiteLLM DB 后各 proxy 副本要重新加载路由表,频繁写既有开销也让 Grafana 权重曲线全是毛刺。
- `PATCH` 只改 `litellm_params.weight`,不动渠道其余参数。
- 副作用:`ALPHA` 调大(反应更快)时应同步调大 `HYSTERESIS`,否则震荡直接透传到写回。

### 6.5 降级

- 一轮中任何异常(Prometheus 不可达、LiteLLM API 401 / 超时、Redis 不可用)→ 整轮跳过,
  权重冻结在 LiteLLM 里的上一轮值,记 `scorer_cycles_total{result="error"}`,`scorer_last_success_timestamp` 停止推进。
- 5 分钟未成功即触发 `TPPScorerStale` 告警;告警文案明确"权重冻结不影响请求链路"。
- 理由:Scorer 不在请求路径上,它挂了只是失去"智能",不失去"服务";因此宁可停手,不做半截更新。
- 常见根因:master key 轮转后 ExternalSecret 未刷新导致 401;Prometheus 因基数过高 OOM。

### 6.6 状态持久化与启动

- EWMA 分数、熔断状态、恢复计数全部在 Redis(`scorer:score:<id>` / `scorer:circuit:<id>` / `scorer:circuit_good:<id>`),
  Scorer 重启无损,参数调整后的滚动重启不会导致权重回到 50 / 50。
- 启动时 `ensure_channels` 把注册表同步进 LiteLLM DB,**幂等判断只按 `model_info.id` 是否存在**,
  不会覆盖已注册渠道的 `litellm_params`。改已有渠道的 `model` 字段需人工 PATCH(runbook 有记录)。
- 与 Redis 的关系是"软"依赖:Redis 不可用时本轮报错、权重冻结,不会崩溃退出。

### 6.7 暂停与人工干预

- `kubectl scale deploy/scorer --replicas=0` 即冻结权重,请求不受影响;人工 PATCH 权重前必须先暂停,
  否则下一轮(≤ 60 秒)会被覆盖。

---

## ADR-007 [Ops] 自建统一入口 Dashboard

**状态**:已实施。架构与数据流见 [`docs/architecture.md` §5](architecture.md),
使用与排障见 [`docs/runbook.md`](runbook.md#tpp-dashboard统一入口) "TPP Dashboard(统一入口)"章节,
源码在 `services/dashboard/`,部署在 `apps/tpp-dashboard.tf`。

### 背景

平台已有四个界面,各自只覆盖一个切面:

| 界面 | 擅长 | 缺什么 |
|---|---|---|
| LiteLLM UI | 建用户、发 key、改预算 | 没有渠道健康与性能,表格式操作界面不适合巡检 |
| Grafana TPP Overview | 时序趋势、告警 | 不能改配置;每人配额 / 消费的表格视图靠 Prometheus label 拼,不可靠 |
| Langfuse | 单次调用 trace | 没有渠道 / 配额维度 |
| Prometheus | 即席查询 | 无可读性 |

运维日常最高频的三个问题:"谁快把今天的额度用完了"、"哪条渠道不健康、Scorer 现在怎么分流"、
"用户抱怨慢,是哪条渠道的 TTFT 退化了",没有一个界面能一屏回答,更不能顺手改配额。

### 决策

自建一个**只聚合、不存储**的统一入口 Dashboard:单容器 = FastAPI 聚合后端 + 静态单页前端,
数据源只有 Prometheus 与 LiteLLM Management API,并作为其他四个界面的跳转起点。

三条设计原则:

1. **不引入新的事实来源**。所有数字都能在 Prometheus 或 LiteLLM DB 里找到同样的值,
   Dashboard 只做查询、汇总与派生(缓存命中率、TPS、错误率),没有自己的数据库。
2. **渠道口径与 Scorer 完全一致**。渠道行以 `scorer-channels.yaml` 注册表为准渲染,
   与 Scorer 共用同一份 ConfigMap;渠道粒度靠 `model_id` label,与 Scorer 打分用的是同一个键。
3. **写操作最小化且语义固定**。唯一的写是改用户日配额:写入时钉住 `budget_duration=1d`,
   且先校验用户存在,避免 LiteLLM `/user/update` 对不存在的用户隐式建用户。建用户、发 key 仍留在 LiteLLM UI / API。

### 实现要点

- **两种时间口径并存**:消费与 tokens 固定近 24h(费用是日粒度问题),性能与错误跟随页面窗口
  (15m / 1h / 6h / 24h / 7d,白名单同时约束下拉选项与 PromQL range)。
  这避免了"切到 15m 看错误、消费也跟着变成 15m"的误读。
- **健康徽章**综合两个来源:Scorer 的 `scorer_circuit_open`(全局、分钟级)与 LiteLLM 的
  `litellm_deployment_state`(每副本、秒级),多副本取最差。两层熔断的关系见 ADR-006 §6.2。
- **派生指标**:缓存命中率 = 缓存读 / (普通输入 + 缓存读 + 缓存写),是 ADR-009 代价的直接观测口;
  TPS = 1 / TPOT 分位数,p99 TPS 表示最慢 1% 请求的解码吞吐。
- **凭证边界**:master key 由 ExternalSecret `dashboard-env` 注入容器,浏览器只与 Dashboard 后端通信,
  永远拿不到 master key。
- **安全模型与 Prometheus 对齐**:自身无认证,不暴露 Ingress,只经 kubectl 隧道(本地 3020)访问,
  由隧道守护(ADR-002 / ADR-004)保活。
- 单副本、`50m` CPU / `128Mi` 内存,前端每 30 秒轮询一次 `/api/overview`,对 Prometheus 约 30 条即席查询 / 半分钟。
- 与 Scorer 同样是自建镜像(`tpp/dashboard`),手动构建推送,tag 由 Terraform 变量管理。

### 备选方案

| 方案 | 未采用原因 |
|---|---|
| 只用 Grafana,加更多面板 | Grafana 不能写回配额;用户级消费表依赖 `hashed_api_key` 等 per-user label,正是 ADR-008 §8 要 labeldrop 掉的高基数 label |
| 扩展 LiteLLM UI | 第三方前端,不可定制;没有 Scorer 与直方图分位数的概念 |
| Grafana + 独立"配额编辑器"小工具 | 两处入口,巡检与操作割裂,与本决策要解决的问题相同 |
| 引入通用 BI / 内部工具平台(Retool 类) | dev 阶段引入新平台与新凭证面,收益不成比例 |

### 后果与权衡

- **又一个要维护的自建组件**:构建镜像、版本号、对 Prometheus 指标名与 LiteLLM API 形状的依赖。
  LiteLLM 升级改了指标名或 `/user/list` 响应结构,Dashboard 会先于其他组件出错。
- **master key 暴露面扩大**:Dashboard 是持有 master key 的第三个组件(另两个是 Scorer、ServiceMonitor)。
  它能改配额,因此"无认证"这一前提比 Prometheus 更敏感;上 ALB 前必须先补 OIDC(ADR-008 §9),
  且 3020 端口不得转发到局域网。
- master key 轮转后 `dashboard-env` 要等最长 1h 刷新,期间用户表 401;与 ADR-001 的 5m 口径不一致,
  是有意的:该 Secret 不含 RDS 密码,轮转频率低。
- Prometheus 降基数(ADR-008 §8)必须保留 `model_id` / `exception_class` / `le` 三个 label,
  这是 Dashboard 与 Scorer 共同的硬依赖。
- `/user/list` 单页 100 人,500 人规模需要分页或改为按团队视图;这与 ADR-008 §9 的自助化方向一致,
  届时 Dashboard 的写回能力应扩展为"用户自助 + 团队管理员审批",而非重写。

---

## ADR-008 [Scaling] 500 用户规模的架构调整

**状态**:方案阶段,未实施。完整方案、容量推算与落地顺序见 [`docs/scaling-500-users.md`](scaling-500-users.md)。
所有容量数字均为基于当前配置的量级推算,非压测结果。

### 背景

现有架构按 dev 规格部署,舒适承载约 50 名重度用户。500 席位按全重度上界推算为
峰值约 42 RPS、约 1500 并发流、60M TPM;数据面的真实压力是并发流数量而非 RPS。

### 决策摘要

| 层 | 改动 | 性质 |
|---|---|---|
| Bedrock 配额 | 多账户 × 3 region 分片,配额桶数 = 账户数 × 调用 region 数 | 商务 + 新增,lead time 数周,**最先启动** |
| 数据面 | LiteLLM 保持单 worker / pod,靠加 pod;KEDA + Prometheus scaler 而非 CPU HPA | 扩容 |
| 账本 | PgBouncer 前置;Aurora PG;litellm / langfuse 分库;SpendLogs 保留策略 | 换规格 + 拆分 |
| Redis | 拆成 router / 限流一套、Langfuse 队列一套,均 HA + TLS | 拆分重建 |
| 链路存储 | 先做 payload 采样(约 5 倍收益),再 ClickHouse 集群化 + TTL + S3 分层 | 换实现 |
| 指标 | ServiceMonitor 降基数,只保留 `model_id` / `requested_model` / `exception_class` / `le` | 配置 + 扩容 |
| 接入层 | ALB + OIDC + 自助发 key broker + per-key 限流;dashboard 补认证 | 新建 |
| Scorer | 保持单副本;增加"配额枯竭"状态与节流 / 故障区分 | 小改 |
| 节点 | 3 个 node group + Karpenter;NAT 每 AZ 一个 | 重构 |

### 落地顺序(由依赖决定)

```text
Phase 0  配额申请 + 压测基线
Phase 1  PgBouncer → Redis 拆分 → Prometheus 降基数 → Karpenter → LiteLLM HPA
Phase 2  Langfuse 采样 → ClickHouse 集群化 → worker KEDA
Phase 3  ALB → OIDC → key broker → per-key 限流 → dashboard 认证
```

两条硬依赖:PgBouncer 必须先于 HPA(否则扩副本即打满 RDS 连接数);
Prometheus 降基数必须先于用户上量(否则 Scorer 与 dashboard 同时失明)。

### 核心判断

平台基础设施月成本(约 $5–7k)相对 token 成本(约 $40k–170k)是零头。
**不要为省平台的钱牺牲 HA**;真正值得投入工程的省钱方向是提高 prompt cache 命中率与把请求路由到更便宜的模型。
这直接引出 ADR-009。

---

## ADR-009 [Trade-off] 稳定性优先导致 prompt cache 命中率下降

**状态**:已接受当前代价,列为待优化。本条为首次成文。

### 背景

Anthropic 模型的 prompt caching 按"完全相同的前缀"命中,缓存条目在 Bedrock 侧、
**以调用账户 + 调用 region + 模型为作用域**,默认约 5 分钟 TTL 且每次命中刷新。
Claude Code / Codex 这类 agent 的工作负载是 prompt cache 的最佳场景:一个会话内每一轮都带着
同样的系统提示、工具定义和越来越长的对话历史,前缀部分往往是几万 token,每轮只在末尾追加几百 token。

TPP 为了稳定性做了三件事,每一件都在破坏"同一前缀反复打到同一处"这个命中前提:

1. **双 region 渠道**:每个 Claude 模型组注册 usw2 与 use1 两条渠道,任何一个 region 故障或限流都能继续服务,
   同时得到两个独立的配额桶(ADR-008 §3)。
2. **加权随机路由**:LiteLLM `simple-shuffle` 按 weight 对**每个请求独立**抽签,不感知会话。
3. **动态调权与探索保底**:Scorer 持续微调权重并保证劣质渠道至少 5% 流量(ADR-005 / ADR-006)。

### 代价量化

记同一会话相邻两轮请求落到同一 region 的概率为 `p_same`。在按权重独立抽签下:

```text
p_same = Σ_i weight(i)²
```

| 权重分布 | p_same | 含义 |
|---|---|---|
| 50 / 50(冷启动、无流量、两 region 质量相当) | 0.50 | 一半的轮次缓存落空 |
| 80 / 20 | 0.68 | |
| 95 / 5(保底下限) | 0.905 | 即便一侧几乎全劣,仍有约 10% 的轮次落空 |
| 100 / 0(直连或单 region) | 1.00 | 理论上限 |

相比单 region 直连(ADR-003 的默认路径),TPP 在 dev 常态的 50 / 50 权重下,
**会话级 prompt cache 命中率上限被砍半**。这不是概率上的小概率事件,而是每两轮就发生一次。

一次落空的代价(取 Anthropic 公开定价比例,以基础输入价为 1):

```text
命中:cache_read  = 0.1  × 前缀 token
落空:cache_write = 1.25 × 前缀 token          → 单轮该部分成本约 12.5 倍
```

TTFT 方面,落空意味着整段前缀重新 prefill。对几万 token 的前缀,首字延迟从亚秒级退化到数秒级,
用户在 agent 交互中能直接感知到"卡一下"。这是 README 架构组件表里列出的"性能"指标(TTFT / TPOT / E2E)与
"稳定性"目标之间最直接的一处冲突。

另一处被稀释的效果是**缓存 TTL**:落空后在另一 region 新建的缓存要再被命中才有价值,
若下一轮又抽回原 region,两边各写一次、各读一次,写入成本翻倍。

### 决策

**当前阶段接受这一代价,稳定性与配额冗余优先于命中率**,理由:

- dev 阶段用户少、单次会话成本可承受(runbook 记录 fable-5 一轮完整问答约 $0.4),
  而单 region 故障或限流造成的是"全员停工",两者不对等。
- 双 region 是配额分片方案(ADR-008 §3)的基础,砍掉它等于放弃未来的扩容路径。
- 命中率是可观测的:TPP Dashboard 已按渠道计算 24 小时 `cache_hit_rate`
  (`litellm_input_cached_tokens_metric_total` / 全部输入),TTFT 分位数也已在同一页面,
  可以持续量化代价而不是靠猜。

### 已识别的缓解方向(未实施,按优先级)

| 方向 | 做法 | 收益 | 代价 |
|---|---|---|---|
| 会话粘性路由 | 评估 LiteLLM 的 prompt-caching 感知预检(按已缓存前缀粘到同一 deployment),或按 `user` / 会话 id 哈希选渠道 | 把 `p_same` 提到接近 1,同时保留 region 级 failover | 依赖 LiteLLM 版本能力;粘性与权重调度需协调,劣质渠道上的会话不会自动迁走 |
| 主备而非分流 | 每组一条主渠道,另一条只作 LiteLLM `fallbacks`,Scorer 只决定谁是主 | 常态 100% 命中,故障时仍能切换 | 备渠道无常态流量,Scorer 对其失明;配额只用一个桶 |
| 权重更陡峭 | 调大 `GAMMA`、调小 `W_FLOOR` | 无代码改动,`p_same` 随权重集中而上升 | 只在两 region 质量有差异时生效;50 / 50 时无效 |
| 按用户 / 团队固定 region | LiteLLM tag routing,把不同人群绑到不同 region | 命中率高且配额桶仍被用满 | 失去个体层面的 failover,需要更多运维配置 |

### 后果

- 在缓解方案落地前,TPP 路径的单位 token 成本与 TTFT 均劣于直连路径;
  评估 TPP 的价值时应把这一项算进去,而不是只看代理层的资源成本。
- 任何往"提高命中率"方向的改动,都要同时回答"region 故障时会话如何迁移"和
  "Scorer 还能不能观测到备渠道",否则是在用稳定性换成本,与本条决策的前提相反。
- 这是 ADR-008 结论"prompt cache 命中率是最大的省钱杠杆"在当前架构下的具体落点,
  应在 500 人方案的 Phase 1 之前给出结论。

---

## 附:决策之间的关系

```text
ADR-001 RDS 轮转重启 ──→ LiteLLM 每 7 天滚动 ──→ 隧道后端短暂不可用 ──→ ADR-002 看门狗误杀并重连(有益)
ADR-002 看门狗 ──→ 脚本需常驻 ──→ ADR-004 launchd + ~/.local/bin 双副本;五条隧道之一是 ADR-007 的 Dashboard
ADR-003 双模式接入 ──→ 排障期间不依赖 TPP;直连单 region ──→ 对照出 ADR-009 的命中率差距
ADR-005 打分 ──→ ADR-006 运行规则;两者共同决定权重分布 ──→ 决定 ADR-009 的 p_same
ADR-006 熔断 / ADR-009 命中率 ──→ 在 ADR-007 Dashboard 上以健康徽章 / 缓存命中率列直接可见
ADR-008 扩容 ──→ 配额分片依赖双 region ──→ 锁定 ADR-009 不能简单退回单 region
ADR-008 §8 降基数 ──→ 必须保留 model_id 等 label ──→ ADR-005 Scorer 与 ADR-007 Dashboard 的共同硬依赖
ADR-008 §9 接入治理 ──→ ADR-007 Dashboard 无认证前提失效,须先补 OIDC
```
