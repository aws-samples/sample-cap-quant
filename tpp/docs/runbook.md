# TPP Runbook

环境:EKS `tpp-dev` @ us-west-2(账号 ******)。
前置:`aws eks update-kubeconfig --name tpp-dev --region us-west-2`

## 访问入口(dev 尚未暴露 Ingress)
**已配隧道守护的机器(launchd 服务 `com.tpp.litellm-proxy` 运行 `tpp-tunnels.sh`)直接开浏览器,
无需任何命令**;下表"手动命令"仅供未配守护的机器使用。

| 服务 | 直接访问地址 / 凭据 | 手动命令(备用) |
|---|---|---|
| LiteLLM API + Admin UI | http://localhost:14000/ui,登录 `admin` / master key(`cd apps && terraform output -raw litellm_master_key`) | `kubectl port-forward -n litellm svc/litellm 14000:4000` |
| Grafana(TPP Overview) | http://localhost:3000,admin / `terraform output -raw grafana_admin_password` | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80` |
| Langfuse UI | http://localhost:3010,admin@tpp.local / `terraform output -raw langfuse_admin_password`;**本地端口必须 3010**(NEXTAUTH_URL 绑定) | `kubectl port-forward -n langfuse svc/langfuse-web 3010:3000` |
| Prometheus | http://localhost:9090(无认证) | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090` |

## 本机(laptop)接入 TPP 调 Claude

1. 保持代理连接,二选一:
   - **launchd 常驻服务(推荐,零手动)**:`~/Library/LaunchAgents/com.tpp.litellm-proxy.plist`
     运行 `tpp-tunnels.sh`,同时维持 LiteLLM(14000)/ Grafana(3000)/ Langfuse(3010)/
     Prometheus(9090)四条隧道,
     登录自启、断线各自自动拉起(脚本副本在 `~/.local/bin/`——launchd 无法执行 Documents 下的
     脚本,TCC 限制;改仓库脚本后需同步复制过去)。日志:`/tmp/tpp-proxy.log`。
     管理:`launchctl bootout gui/$UID/com.tpp.litellm-proxy`(停)/
     `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.tpp.litellm-proxy.plist`(启);
   - 手动:`./scripts/tpp-tunnels.sh`(四条隧道)或 `./scripts/tpp-connect.sh`(仅 LiteLLM,
     默认端口 14000),前台运行,Ctrl-C 退出。
2. 每台机器/每个人用自己的 user + key(不要用 master key),见下文 quota 章节的 `/user/new`。
3. 客户端配置(二选一,key 均放 `Authorization: Bearer` 或 `x-api-key`):
   - **OpenAI 兼容**(大多数工具):base_url `http://localhost:14000/v1`,
     env:`OPENAI_BASE_URL=http://localhost:14000/v1`、`OPENAI_API_KEY=<你的key>`
   - **Anthropic 原生**(Anthropic SDK / Claude Code):base_url `http://localhost:14000`
     (proxy 提供 `/v1/messages`),env:`ANTHROPIC_BASE_URL=http://localhost:14000`、
     `ANTHROPIC_AUTH_TOKEN=<你的key>`
4. 可用模型名 = 渠道注册表里的 model_name:`claude-fable-5`、`claude-opus-5`、`claude-sonnet-5`、
   `claude-haiku-4-5`(与 Anthropic 官方模型 ID 同名,多数客户端零配置)。
   每个模型组 = Bedrock 双 region 渠道(usw2/use1),请求按 Scorer 权重分流。

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
```

### Claude Code 接入 TPP(本机已于 2026-08-24 完成切换)

Claude Code 的渠道配置在 `~/.claude/settings.json`。**走 TPP 的配置**(本机当前状态):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:14000",
    "ANTHROPIC_AUTH_TOKEN": "<TPP key,本机为 dev-laptop 用户的 key>",
    "ANTHROPIC_MODEL": "claude-fable-5",
    "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4-5",
    "MAX_THINKING_TOKENS": "1024"
  },
  "model": "claude-fable-5"
}
```
(`permissions`/`effortLevel`/`tui` 等与渠道无关的字段保持原样。)

- **切换生效**:修改后需重启 Claude Code 会话(运行中的会话环境已定型);
- **验证走了 TPP**:新会话问答一次,然后
  `curl -s "http://localhost:14000/user/info?user_id=<user>" -H "Authorization: Bearer $MASTER_KEY"`
  看 spend 是否增长(或 Langfuse 里看新 trace);
- **回滚到 Bedrock 直连**(一条命令 + 重启会话):
  ```bash
  cp ~/.claude/settings.json.bedrock-backup ~/.claude/settings.json
  ```
  直连基线配置全文见 `docs/claude-code-config-baseline.md`;
- 本机用户 `dev-laptop` quota 为 **$100/天**(fable-5 一次完整问答约 $0.4,重度开发日 $20 不够用);
- 功能边界:Bedrock 渠道无 Anthropic 服务端 web search(直连时同样没有,非 TPP 引入);
  Claude Code 的 WebFetch 在本机执行,不受影响。

## 日常操作

**加/改渠道**:编辑 `apps/values/scorer-channels.yaml` → `cd apps && terraform apply`
(ConfigMap 哈希变化触发 Scorer 重启,启动时幂等注册新渠道;新渠道从冷启动分 0.5 + 保底流量爬坡)。

### Per-user quota(USD/天)

前置:`export MASTER_KEY=$(cd apps && terraform output -raw litellm_master_key)`
(隧道守护在线即可,无需手动 port-forward)。

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
429 `budget_exceeded`,到期自动重置。全局消耗趋势看 Grafana TPP Overview 的
"用户剩余预算" 与 "Spend (24h)" 面板。另有 team 级(`/team/new`,共享预算)和 key 级限额可叠加。

### 查看渠道质量分 / 权重

三个入口:

1. **Grafana(推荐)**:TPP Overview → "渠道质量分(EWMA)"(`scorer_quality_score`,0~1)
   和 "渠道权重(Scorer 分配)" 两个面板对照看;
2. **Prometheus 即席查询**:`scorer_quality_score`、`scorer_weight`、`scorer_circuit_open`
   (label:`model_group` / `model_id`);
3. **命令行**:
   ```bash
   kubectl port-forward -n scorer svc/scorer 9100:9100 &
   curl -s http://localhost:9100/metrics | grep -E "^scorer_(quality_score|weight|circuit)"
   kubectl logs -n scorer deploy/scorer | grep "weights updated"   # 调权历史
   ```

读数说明:分数 = 0.35×延迟分 + 0.65×错误分,EWMA 平滑(时间常数约 3 分钟);
窗口内请求数 <10 的渠道不更新分数(小样本保护),无流量的组保持冷启动分 0.5、权重 50/50 是设计行为。

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
    -t <aws account number>.dkr.ecr.us-west-2.amazonaws.com/tpp/scorer:0.1.0 --push .
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

## 告警响应

| 告警 | 含义 | 处置 |
|---|---|---|
| TPPScorerStale | Scorer >5min 未成功打分,权重冻结 | `kubectl logs -n scorer deploy/scorer`;常见:Prometheus 不可达、LiteLLM API 401(master key 轮转后 ExternalSecret 未刷新) |
| TPPLiteLLMHighErrorRate | 整体错误率 >10% | 看 dashboard Error Rate 面板定位渠道;单渠道故障应已被熔断,若是全渠道则查 Bedrock 服务状态/IAM |
| TPPLiteLLMDown | proxy 全副本失联 | `kubectl get pods -n litellm`;查 RDS(litellm 启动强依赖 DB)与最近 apply |
| TPPChannelCircuitOpen | 渠道被熔断 >5min | 通常无需动作(自动恢复);持续不恢复则查该 region 的 Bedrock 配额/健康 |

## 已知事项 / 陷阱

- **渠道定义只在 scorer-channels.yaml**,LiteLLM config 的 model_list 故意为空
  (静态 config 模型无法被 Management API 调权)。不要在 LiteLLM UI 里手工加模型,会绕开注册表。
- Langfuse 是 v4(OTel-native):LiteLLM callback 必须用 `langfuse_otel`,旧 `langfuse` callback 会 400。
- 单节点 ClickHouse 必须 `clickhouse.cluster.enabled=false`,否则迁移要求 Keeper。
- apps 层首次部署需两段 apply(CRD 时序),见 apps/README.md。
- `/metrics` 受认证保护,ServiceMonitor 用 master key Bearer 抓取;轮转 master key 要同步等 ExternalSecret 刷新(1h)或手动触发。
- TTFT 指标仅流式请求产生;TPOT 用 `litellm_deployment_latency_per_output_token`。
- **launchd 无法执行 `~/Documents` 下的脚本**(macOS TCC,报 `Operation not permitted`),
  隧道脚本必须用 `~/.local/bin/` 下的副本;**改仓库脚本后要 `cp` 同步过去并重启服务**。
- **本地 LiteLLM 端口是 14000**(2026-08-24 从 4000 迁移,4000 让给了本机其他应用);
  `14000:4000` 中右侧 4000 是 pod 容器端口,平台侧从未变更。
- 手动/守护的 port-forward 会互抢端口:隧道脚本启动时会 pkill 接管同类进程;
  排查端口冲突用 `lsof -nP -iTCP:<port> -sTCP:LISTEN` 看属主。
- Claude Code 直连 Bedrock 的基线配置备份:`~/.claude/settings.json.bedrock-backup`
  与 `docs/claude-code-config-baseline.md`,回滚见"Claude Code 接入 TPP"章节。

## 当前环境登记(2026-08-24)

- 渠道注册表:4 模型组 × 2 region = **8 渠道**(fable-5 / opus-5 / sonnet-5 / haiku-4-5,均为 Bedrock usw2+use1);
- 已建用户:`dev-laptop`($100/天,本机 Claude Code 在用);
- 本机 Claude Code:**已走 TPP**(2026-08-24 切换);
- 本机隧道守护:launchd `com.tpp.litellm-proxy` → 四条隧道;
- 仓库未 git commit;dev 环境常驻成本约 $400–450/月(省钱开关见上文)。
