# TPP Runbook

Environment: EKS `tpp-dev` @ us-west-2 (account ******).
Prerequisite: `aws eks update-kubeconfig --name tpp-dev --region us-west-2`

## Table of Contents

- [Access Endpoints (dev has no Ingress exposed yet)](#access-endpoints-dev-has-no-ingress-exposed-yet)
- [Connecting Your Laptop to TPP for Claude](#connecting-your-laptop-to-tpp-for-claude)
  - [Installing the Tunnel Daemon on a New Machine (one-time)](#installing-the-tunnel-daemon-on-a-new-machine-one-time)
  - [Claude Code with TPP (dual mode)](#claude-code-with-tpp-dual-mode)
  - [Codex CLI with TPP](#codex-cli-with-tpp)
- [Routine Operations](#routine-operations)
  - [TPP Dashboard (unified portal)](#tpp-dashboard-unified-portal)
  - [Per-user quota (USD/day)](#per-user-quota-usdday)
  - [Viewing Channel Quality Scores / Weights](#viewing-channel-quality-scores--weights)
  - [Tuning Scoring Parameters](#tuning-scoring-parameters)
- [RDS Credential Rotation and Automatic Recovery](#rds-credential-rotation-and-automatic-recovery)
- [Scorer Scoring Algorithm](#scorer-scoring-algorithm)
  - [Symbol Definitions](#symbol-definitions)
  - [Severity Coefficients](#severity-coefficients)
  - [Formulas](#formulas)
  - [Operating Rules](#operating-rules)
- [Alert Response](#alert-response)
- [Known Issues / Gotchas](#known-issues--gotchas)
- [Current Environment Registry](#current-environment-registry)

## Access Endpoints (dev has no Ingress exposed yet)
**On machines with the tunnel daemon configured (launchd service `com.tpp.litellm-proxy` running `tpp-tunnels.sh`), just open a browser --
no commands needed**; the "Manual command" column below is only for machines without the daemon.

| Service | Direct URL / credentials | Manual command (fallback) |
|---|---|---|
| LiteLLM API + Admin UI | http://localhost:14000/ui, log in as `admin` / master key (`cd apps && terraform output -raw litellm_master_key`) | `kubectl port-forward -n litellm svc/litellm 14000:4000` |
| Grafana (TPP Overview) | http://localhost:3000, admin / `terraform output -raw grafana_admin_password` | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80` |
| Langfuse UI | http://localhost:3010, admin@tpp.local / `terraform output -raw langfuse_admin_password`; **the local port must be 3010** (bound by NEXTAUTH_URL) | `kubectl port-forward -n langfuse svc/langfuse-web 3010:3000` |
| Prometheus | http://localhost:9090 (no auth) | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090` |
| TPP Dashboard (quotas/channel spend/performance) | http://localhost:3020 (no auth; quotas can be edited directly on the page) | `kubectl port-forward -n dashboard svc/dashboard 3020:8080` |

## Connecting Your Laptop to TPP for Claude

1. Keep the proxy connection alive, pick one of:
   - **launchd resident service (recommended, zero manual work)**: `~/Library/LaunchAgents/com.tpp.litellm-proxy.plist`
     runs `tpp-tunnels.sh`, maintaining all five tunnels at once: LiteLLM (14000) / Grafana (3000) / Langfuse (3010) /
     Prometheus (9090) / TPP Dashboard (3020).
     It starts at login and each tunnel auto-restarts on disconnect; every tunnel has a health-probe watchdog
     (a wedged kubectl -- process alive but forwarding dead -- is auto-restarted within
     ~45 seconds). (The script copy lives in `~/.local/bin/` -- launchd cannot execute scripts under
     Documents due to TCC restrictions; after changing the repo script, copy it over again.) Logs: `/tmp/tpp-proxy.log`.
     Manage with: `launchctl bootout gui/$UID/com.tpp.litellm-proxy` (stop) /
     `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.tpp.litellm-proxy.plist` (start);
   - Manual: `./scripts/tpp-tunnels.sh` (all five tunnels) or `./scripts/tpp-connect.sh` (LiteLLM only,
     default port 14000); runs in the foreground, Ctrl-C to exit.
2. Every machine/person uses their own user + key (do not use the master key); see `/user/new` in the quota section below.
3. Client configuration (pick one; the key goes in `Authorization: Bearer` or `x-api-key` either way):
   - **OpenAI-compatible** (most tools): base_url `http://localhost:14000/v1`,
     env: `OPENAI_BASE_URL=http://localhost:14000/v1`, `OPENAI_API_KEY=<your key>`
   - **Anthropic native** (Anthropic SDK / Claude Code): base_url `http://localhost:14000`
     (the proxy serves `/v1/messages`), env: `ANTHROPIC_BASE_URL=http://localhost:14000`,
     `ANTHROPIC_AUTH_TOKEN=<your key>`
4. Available model names = the model_name entries in the channel registry: `claude-fable-5`, `claude-opus-5`, `claude-sonnet-5`,
   `claude-haiku-4-5` (same names as the official Anthropic model IDs, so most clients need zero configuration), plus
   `gpt-5.6-terra` (an OpenAI model via Bedrock Mantle, used by Codex CLI).
   Each Claude model group = dual-region Bedrock channels (usw2/use1), with requests split by Scorer weights;
   `gpt-5.6-terra` is currently a single usw2 channel.

### Installing the Tunnel Daemon on a New Machine (one-time)

Prerequisites: aws cli installed (with IAM credentials), kubectl installed, and `aws eks update-kubeconfig --name tpp-dev --region us-west-2` already run.

```bash
# 1. Put the script somewhere launchd can execute (macOS TCC blocks launchd from running scripts under Documents)
mkdir -p ~/.local/bin
cp <repo>/scripts/tpp-tunnels.sh ~/.local/bin/ && chmod +x ~/.local/bin/tpp-tunnels.sh

# 2. Create the LaunchAgent
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
# Note: change the path inside ProgramArguments to an absolute path (plists do not expand $HOME)

# 3. Start and verify
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.tpp.litellm-proxy.plist
sleep 8
curl -s -o /dev/null -w "litellm %{http_code}\n"    http://localhost:14000/health/liveliness
curl -s -o /dev/null -w "grafana %{http_code}\n"    http://localhost:3000/api/health
curl -s -o /dev/null -w "langfuse %{http_code}\n"   http://localhost:3010/api/public/health
curl -s -o /dev/null -w "prometheus %{http_code}\n" http://localhost:9090/-/healthy
curl -s -o /dev/null -w "dashboard %{http_code}\n"  http://localhost:3020/healthz
```

### Claude Code with TPP (dual mode)

Same shape as Codex: **plain `claude` = direct Bedrock, `claude-tpp` = via TPP**. Claude Code has no notion of
profiles; this is implemented with a `--settings <file>` overlay (highest precedence; `env` is merged per key and
overrides shell environment variables, see https://code.claude.com/docs/en/cli-reference.md).

1. Keep `~/.claude/settings.json` as the **direct-Bedrock baseline** (full text in
   `docs/claude-code-config-baseline.md`): `CLAUDE_CODE_USE_BEDROCK=true`,
   `AWS_PROFILE=default`, `AWS_REGION=us-west-2`, with model names using Bedrock inference profile ids;
2. Create `~/.claude/tpp.settings.json` (`chmod 600`, contains the TPP key):

   ```json
   {
     "env": {
       "CLAUDE_CODE_USE_BEDROCK": "0",
       "ANTHROPIC_BASE_URL": "http://localhost:14000",
       "ANTHROPIC_AUTH_TOKEN": "<TPP user key; this machine reuses the dev-laptop-codex key from TPP_API_KEY>",
       "ANTHROPIC_MODEL": "claude-fable-5",
       "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4-5"
     },
     "model": "claude-fable-5"
   }
   ```

3. Add an alias to `~/.zshrc`: `alias claude-tpp='claude --settings ~/.claude/tpp.settings.json'`.

- **Usage**: `claude` goes direct; `claude-tpp` goes through TPP (for one-off use you can also run
  `claude --settings ~/.claude/tpp.settings.json` directly). To make TPP the default, merge the overlay's
  `env`/`model` into `settings.json` and remove the `AWS_*` entries;
- **Prerequisite**: the LiteLLM tunnel is running (launchd daemon or `./scripts/tpp-tunnels.sh`, local :14000);
- **Verifying traffic goes through TPP**: in `claude-tpp -p "reply OK" --output-format json`, the `modelUsage`
  keys should be TPP model group names (`claude-fable-5`/`claude-haiku-4-5`) rather than `us.anthropic.*`;
  then check that `/user/info` spend grows (LiteLLM accounting lags by about 5~15 s) or look for a new trace in Langfuse;
- **Rollback**: running without the alias goes direct; if `settings.json` was modified,
  `cp ~/.claude/settings.json.bedrock-backup ~/.claude/settings.json`;
- This machine's user quota is **$100/day** (a full fable-5 exchange costs about $0.4; $20 is not enough for a heavy development day);
- Feature boundary: Bedrock channels have no Anthropic server-side web search (direct Bedrock lacks it too; this is not introduced by TPP);
  Claude Code's WebFetch runs on the local machine and is unaffected.

**Pitfalls already hit**:

- To disable Bedrock in the overlay you must write `"CLAUDE_CODE_USE_BEDROCK": "0"`: this class of variable is
  parsed numerically, and `"false"` is not guaranteed to take effect;
- The direct-Bedrock baseline's `ANTHROPIC_SMALL_FAST_MODEL` used to be `us.anthropic.claude-3-7-sonnet-20250219-v1:0`,
  which has been retired on Bedrock (ResourceNotFoundException: end of life); the symptom was WebFetch and other
  background tasks reporting "issue with the selected model". It has been changed to
  `us.anthropic.claude-haiku-4-5-20251001-v1:0`.

### Codex CLI with TPP

Codex CLI's channel configuration lives in `~/.codex/config.toml`; the current baseline is direct Bedrock
(`model = "openai.gpt-5.6-terra"`, `model_provider = "amazon-bedrock"`),
with a full baseline backup in the repo's `.codex-backup/`. The corresponding TPP channel is the model group `gpt-5.6-terra`
(Bedrock Mantle `openai.gpt-5.6-terra`, single usw2 channel, IRSA auth with no API key needed).

**Going through TPP** (the profile mechanism in Codex >= 0.134: the provider lives in the main config, the profile is a separate file):

1. **Append** the provider to `~/.codex/config.toml` (leave the existing top-level `model`/`model_provider` alone;
   the direct-Bedrock configuration stays as a fallback):

   ```toml
   [model_providers.tpp]
   name = "TPP LiteLLM Proxy"
   base_url = "http://localhost:14000/v1"
   env_key = "TPP_API_KEY"
   wire_api = "responses"
   ```

2. Create `~/.codex/tpp.config.toml` (profile files use top-level keys; do **not** write a `[profiles.tpp]` table again):

   ```toml
   model = "gpt-5.6-terra"
   model_provider = "tpp"
   ```

- **Usage**: `export TPP_API_KEY=<TPP key>` (use your own user key, not the master key;
  see `/user/new` in the quota section), then `codex --profile tpp`. To make TPP the default, change the top-level
  `model` / `model_provider` to `gpt-5.6-terra` / `tpp`;
- **Prerequisite**: the LiteLLM tunnel is running (launchd daemon or `./scripts/tpp-tunnels.sh`, local :14000);
- **Local docker-compose verification**: change `base_url` to `http://localhost:4000/v1` and
  use the local `LITELLM_MASTER_KEY` as the key (the model group has the same name, `gpt-5.6-terra`);
- **Verifying traffic goes through TPP**: after one conversation round, check that `/user/info` spend grows, or look for a new trace in Langfuse
  (same as the Claude Code section);
- **Rolling back to direct Bedrock**: running without `--profile` falls back to the top-level direct configuration; if the top level was changed,
  restore the baseline: `cp .codex-backup/config.toml ~/.codex/config.toml`.

**Pitfalls already hit** (getting any of these wrong prevents codex from starting at all):

- `wire_api` must be `"responses"`: Codex >= 0.151 has deprecated `"chat"`, and writing `"chat"` makes the
  entire `config.toml` fail to parse, so even direct Bedrock without `--profile` fails to start;
- If a `[profiles.tpp]` table remains in the main config, `--profile tpp` errors out immediately; it must be moved to the separate file;
- Codex sends `reasoning.effort = "medium"` by default (the "reasoning effort: none" shown in the UI refers to
  the summary setting), so the TPP channel must use LiteLLM's `bedrock_mantle/openai.gpt-5.6-terra` route
  (OpenAI-compatible endpoint with native passthrough of the Responses API and reasoning). Writing `bedrock/us.openai.*`
  goes through the Claude converse conversion, which translates `reasoning_effort` into `thinking`, and Mantle rejects it with
  `unknown_parameter: thinking`;
- Mantle is a separate IAM service prefix: in addition to `bedrock:Invoke*/Converse*`, LiteLLM's IRSA role
  also needs `bedrock-mantle:CreateInference` (`infra/modules/iam`); without it you get `access_denied`;
- Scorer's `ensure_channels` only checks existence by `model_info.id` and never overwrites the
  `litellm_params` of already-registered channels, so changing an existing channel's `model` field requires an in-place PATCH with the master key:
  `curl -X PATCH :14000/model/<id>/update -d '{"litellm_params":{"model":"..."}}'`,
  then confirm via `/model/info`.

## Routine Operations

**Adding/changing channels**: edit `apps/values/scorer-channels.yaml` -> `cd apps && terraform apply`
(the ConfigMap hash change triggers Scorer and Dashboard restarts; Scorer idempotently registers new channels at startup, and the Dashboard channel table gains the new rows;
new channels ramp up from the cold-start score of 0.5 plus the traffic floor).

### TPP Dashboard (unified portal)

Daily checks start at http://localhost:3020; the page auto-refreshes every 30 seconds, with four sections top to bottom:

| Section | What to look at | Data source |
|---|---|---|
| KPI cards | Total spend and tokens over the last 24h; request count, error count, and error rate in the selected window; circuit-open channels / total channels; total quota and user count | Aggregated from the two tables below |
| User quotas | Each user's spend this period, remaining budget, reset time, daily quota; **the daily-quota cell is editable in place, press Enter to write back**; sorted by spend descending | LiteLLM `/user/list`, written back via `/user/update` |
| Channel spend / health / weights | Each channel's spend over the last 24h, input/output tokens, cache hit rate; health badge; Scorer quality score and weight | Prometheus `litellm_*` / `scorer_*` |
| Channel stability and performance | Per-channel request count in the window; p50 / p90 / p99 of TTFT / TPOT / E2E / TPS; error count, error rate, broken down by `exception_class` | Prometheus histograms |

Reading the numbers:

- **Stats window**: the 15m / 1h / 6h / 24h / 7d selector in the top right only affects performance and errors; spend and tokens always show the last 24h (costs are at daily granularity).
  A channel with no successful requests in the window shows empty percentiles; that is not a failure.
- **Health badge** priority: circuit open (`scorer_circuit_open=1`) > unhealthy (`litellm_deployment_state=2`) > partially unhealthy (`=1`) > healthy.
  Multiple replicas of the same channel take the worst value. For handling circuit-open channels, see `TPPChannelCircuitOpen` under [Alert Response](#alert-response).
- **Cache hit rate** = cache reads / (plain input + cache reads + cache writes), over the last 24h; dual-region traffic splitting depresses this value -- for the reasoning and trade-offs see [ADR-009](ADR.md).
- **TPS** is derived from the TPOT percentiles (1 / TPOT); p99 TPS means "decode throughput of the slowest 1% of requests", not peak throughput.
- **Channel rows** follow the `scorer-channels.yaml` registry; channels with no traffic still appear, just with empty or 0 values.
- The four buttons at the top link to LiteLLM UI / Grafana / Langfuse / Prometheus, pointing at the local tunnel ports by default;
  at deploy time they can be overridden with the environment variables `LINK_LITELLM` / `LINK_GRAFANA` / `LINK_LANGFUSE` / `LINK_PROMETHEUS`.

Troubleshooting:

- Page shows `overview 502`: Prometheus is unreachable or the query failed; `kubectl logs -n dashboard deploy/dashboard`;
- User table is empty or shows `litellm /user/list: 401`: the master key was rotated but `dashboard-env` has not refreshed (its ExternalSecret interval is 1h);
  run `kubectl annotate externalsecret -n dashboard dashboard-env force-sync=$(date +%s) --overwrite` and restart the Pod;
- Editing a quota reports `user not found`: the Dashboard only updates existing users; create new users first with `/user/new` as described below;
- The user list shows at most 100 users (single `/user/list` page); beyond that the backend needs pagination.

**Upgrading the Dashboard**: bump the version in `services/dashboard/pyproject.toml`, build and push a new tag (commands in README deployment section 4),
then change `dashboard_image_tag` in `apps/tpp-dashboard.tf` -> `cd apps && terraform apply`.

### Per-user quota (USD/day)

Prerequisite: `export MASTER_KEY=$(cd apps && terraform output -raw litellm_master_key)`
(having the tunnel daemon online is enough; no manual port-forward needed).

**Dashboard method (recommended for changing quotas)**: http://localhost:3020 -> user quota table -> edit the "daily quota" cell directly.
Writes back with a fixed `budget_duration=1d`; it can only modify existing users -- create new users via the UI or API methods below.

**UI method**: http://localhost:14000/ui -> **Internal Users**: when creating a user, fill in Max Budget (USD) +
Budget Duration (`1d` = daily reset); the list page shows each user's Spend / Max Budget; click a user to Edit the quota.

**API method**:

```bash
# Create a user and assign a daily quota (hand the returned "key" to the user)
curl -s http://localhost:14000/user/new -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"alice","max_budget":10.0,"budget_duration":"1d"}'

# View quota and spend so far (watch spend / max_budget / budget_reset_at)
curl -s "http://localhost:14000/user/info?user_id=alice" -H "Authorization: Bearer $MASTER_KEY"

# Change the quota
curl -s http://localhost:14000/user/update -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" -d '{"user_id":"alice","max_budget":20.0}'

# List all users
curl -s "http://localhost:14000/user/list" -H "Authorization: Bearer $MASTER_KEY"
```

Quota is deducted in real time based on actual USD spend (converted via LiteLLM's built-in price table -- no need to pre-convert token counts). Exceeding it returns
429 `budget_exceeded`, and it resets automatically when the period expires. Each user's current spend / remaining budget / reset time is in the TPP Dashboard user quota table;
global consumption trends are in the "User Remaining Budget (USD)" and "Spend (24h, USD)" panels of the Grafana TPP Overview. There are also team-level (`/team/new`, shared budget) and key-level limits that can be stacked.

### Viewing Channel Quality Scores / Weights

Four entry points:

1. **TPP Dashboard (recommended, current values)**: http://localhost:3020 -> "Channel spend / health / weights" table;
   each channel's quality score, weight, and circuit state is visible in a single row;
2. **Grafana (trends)**: TPP Overview -> the "Channel Quality Score (EWMA)" (`scorer_quality_score`, 0~1)
   and "Channel Weights (Scorer-assigned)" panels, viewed side by side;
3. **Prometheus ad-hoc queries**: `scorer_quality_score`, `scorer_weight`, `scorer_circuit_open`
   (labels: `model_group` / `model_id`);
4. **Command line**:
   ```bash
   kubectl port-forward -n scorer svc/scorer 9100:9100 &
   curl -s http://localhost:9100/metrics | grep -E "^scorer_(quality_score|weight|circuit)"
   kubectl logs -n scorer deploy/scorer | grep "weights updated"   # weight-adjustment history
   ```

Reading the numbers: score = 0.35 x latency score + 0.65 x error score, EWMA-smoothed (time constant about 3 minutes);
channels with fewer than 10 requests in the window do not get score updates (small-sample protection), and groups with no traffic keeping the cold-start score of 0.5 and a 50/50 weight split is by design.
Full formulas are below in [Scorer Scoring Algorithm](#scorer-scoring-algorithm).

### Tuning Scoring Parameters

All parameters are environment variables (defined in `services/scorer/scorer/config.py`).
To change one: add an `env` block to the scorer container in `apps/scorer.tf` -> `cd apps && terraform apply`.
It takes effect in the next cycle (within 60s) after the Pod rolling restart; **EWMA state lives in Redis and survives restarts**.

| Environment variable | Default | Purpose / effect of increasing it |
|---|---|---|
| `W_LAT` / `W_ERR` | 0.35 / 0.65 | Latency/error score weights (sum = 1); larger W_LAT -> speed matters more |
| `ALPHA` | 0.3 | EWMA smoothing; larger -> faster reaction but more jitter |
| `GAMMA` | 2.0 | Score-gap amplification; larger -> a wider traffic gap between good and bad channels |
| `K_ERR` | 8.0 | Steepness of the error penalty (at the default, the score halves at an error rate of 8.6%) |
| `W_FLOOR` | 0.05 | Traffic floor for low-scoring channels (trade-off between exploration samples and wasted traffic) |
| `MIN_SAMPLES` | 10 | Minimum requests in the window; below this the score is not updated |
| `HYSTERESIS` | 0.02 | Weights are written back to LiteLLM only when the change exceeds this value |
| `INTERVAL_SECONDS` / `WINDOW` | 60 / 5m | Scoring interval / metrics observation window |
| `CIRCUIT_ERR_THRESHOLD` | 0.5 | Weighted error rate that trips the circuit breaker |
| `CIRCUIT_RECOVERY_ROUNDS` / `CIRCUIT_RECOVERY_ERR` | 3 / 0.1 | Recovery condition: error rate below the threshold for N consecutive rounds |
| `DEFAULT_Q` | 0.5 | Cold-start score for new channels |

Example (weigh latency more, react faster):

```hcl
env { name = "W_LAT"  value = "0.5" }
env { name = "W_ERR"  value = "0.5" }
env { name = "ALPHA"  value = "0.5" }
```

Notes:
- The **error severity mapping** (Timeout=3.0, 429=1.5, other 4xx=0.5) is in code (`SEVERITY` in `config.py`);
  changing it requires rebuilding the image:
  ```bash
  cd services/scorer && docker buildx build --platform linux/amd64 \
    -t <aws account>.dkr.ecr.us-west-2.amazonaws.com/tpp/scorer:0.1.0 --push .
  kubectl rollout restart deploy/scorer -n scorer
  ```
- After tuning, watch the Grafana "Channel Weights" panel for 15-30 minutes; if the curves oscillate back and forth, `ALPHA`/`GAMMA` are too aggressive.
  When increasing `ALPHA`, also increase `HYSTERESIS` to suppress jitter.

**Pausing smart routing** (weights freeze at their current values; requests are unaffected):
```bash
kubectl scale deploy/scorer -n scorer --replicas=0
```

**Manually changing a channel's weight** (temporary intervention; the next Scorer round will overwrite it, so pause Scorer first):
```bash
curl -X PATCH http://localhost:14000/model/<channel-id>/update \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"litellm_params": {"weight": 0}}'
```

**Cost-saving switch (stop the dev environment after hours)**:
```bash
# Stop: scale nodes to 0 + stop RDS (ElastiCache and the EKS control plane cannot be stopped; ~$85/month floor)
aws eks update-nodegroup-config --cluster-name tpp-dev --nodegroup-name <ng> \
  --scaling-config minSize=0,maxSize=5,desiredSize=0 --region us-west-2
aws rds stop-db-instance --db-instance-identifier tpp-dev --region us-west-2
# Start: reverse the above (a stopped RDS auto-starts after at most 7 days)
```

## RDS Credential Rotation and Automatic Recovery

RDS manages the PostgreSQL master password via `manage_master_user_password=true`; AWS rotates it every **7 days**.
**7 days is the password rotation period, not the platform recovery time.**

```text
RDS/Secrets Manager password rotation
        ↓ (up to 5 minutes)
External Secrets refreshes litellm-env / langfuse-postgres
        ↓ (Secret data changes)
Stakater Reloader detects the change
        ↓ (RollingUpdate)
LiteLLM, Langfuse Web, and Langfuse Worker start with the new password
```

| Item | Implementation |
|---|---|
| Password source | RDS-managed Secrets Manager secret |
| Sync frequency | ESO `refreshInterval` for both `litellm-env` and `langfuse-postgres` is **5m** |
| Automatic restart | `reloader` chart pinned to `2.2.16`, watching Secret changes globally; LiteLLM, Langfuse Web, and Langfuse Worker all carry `reloader.stakater.com/auto: "true"` |
| Maximum credential discovery delay | About 5 minutes, then one regular RollingUpdate to complete; no manual `kubectl rollout restart` needed |
| LiteLLM secrets Secret | `litellm-env` |
| Langfuse secrets Secret | `langfuse-postgres` |

Langfuse's RDS password may contain URI-reserved characters such as `@`, `:`, `/`, `%`, `#`, `?`. The `langfuse-postgres`
ExternalSecret also generates a URL-encoded `database_url` and injects it as `DATABASE_URL` / `DIRECT_URL` into
Web and Worker, avoiding the Prisma `P1013 invalid port number` error. You cannot just hand the raw password to the chart's `DATABASE_PASSWORD`.

Troubleshooting essentials:

- LiteLLM fails to start after rotation: `kubectl get externalsecret -n litellm litellm-env`, check the `SecretSynced` status and last sync time;
  if ESO has synced but the Pod has not restarted, check `kubectl logs -n kube-system deploy/reloader-reloader`;
- Manual acceleration: `kubectl annotate externalsecret -n litellm litellm-env force-sync=$(date +%s) --overwrite` triggers an immediate sync;
- The change list and verification record are in [`rds-rotation-recovery-changes.md`](rds-rotation-recovery-changes.md); design trade-offs in [ADR-001](ADR.md).

## Scorer Scoring Algorithm

Scoring target: a LiteLLM deployment, i.e. a **(channel, model) pair**; comparisons happen only within the same model group.
One round every 60s, over the Prometheus window of the past 5 minutes. Parameter environment variable names and how to tune them are above in [Tuning Scoring Parameters](#tuning-scoring-parameters);
design trade-offs and known gaps are in [ADR-005 / ADR-006](ADR.md).

### Symbol Definitions

| Symbol | Origin | Meaning |
|------|------|------|
| `d` | deployment | The deployment being scored, i.e. a (channel, model) pair |
| `j` | -- | Summation index, ranging over all deployments in the same model group as `d` |
| `cat` | category | Error category; values are in the severity coefficient table below |
| `lat(d)` | latency | End-to-end (E2E) p90 latency of `d` within the window |
| `lat_best` | latency, best | The smallest p90 latency in the model group, i.e. the latency of the fastest member |
| `req(d)` | requests | Total requests of `d` within the window |
| `err(d, cat)` | errors | Number of errors of category `cat` for `d` within the window |
| `sev(cat)` | severity | Severity coefficient of error category `cat` |
| `err_rate(d)` | error rate | Weighted error rate of `d` |
| `score_lat(d)` | score, latency | Latency component score, range [0, 1] |
| `score_err(d)` | score, error | Error component score, range (0, 1] |
| `q_raw(d)` | quality, raw | Raw quality score for this round |
| `q(d, t)` | quality | EWMA-smoothed quality score at round `t`; cold-start initial value for new channels is 0.5 |
| `gamma` | γ | Weight amplification exponent, set to 2, used to amplify score gaps within the group |
| `weight(d)` | weight | Routing weight written back to LiteLLM |

### Severity Coefficients

| Error category `cat` | Severity coefficient `sev(cat)` |
|------|------|
| 5xx / Timeout / connection errors | 3.0 |
| 429 (rate limiting) | 1.5 |
| Other 4xx | 0.5 |

### Formulas

**Weighted error rate** (denominator takes max to avoid division by zero):

```
                ∑  sev(cat) × err(d, cat)
               cat
err_rate(d) = ───────────────────────────
                    max(req(d), 1)
```

**Per-round scores** (the fastest member of the group gets `score_lat = 1`; at `err_rate = 8.6%`, `score_err` drops to 0.5):

```
                     ⎛ lat_best          ⎞
score_lat(d) = clamp ⎜ ──────── , 0 , 1  ⎟
                     ⎝  lat(d)           ⎠

score_err(d) = exp( −8 × err_rate(d) )
```

**Raw quality score** (errors weigh more than latency):

```
q_raw(d) = 0.35 × score_lat(d) + 0.65 × score_err(d)
```

**EWMA smoothing** (time constant about 3 minutes):

```
q(d, t) = 0.3 × q_raw(d) + 0.7 × q(d, t−1)
```

**Routing weight** (normalized within the group by the gamma-th power of the quality score, gamma = 2):

```
                q(d)^gamma
weight(d) = ─────────────────
             ∑  q(j)^gamma
             j
```

Then the exploration floor is applied: `weight(d) ← max(weight(d), 0.05)`, followed by re-normalization, to prevent low-scoring channels from deadlocking.

### Operating Rules

| Stage | Rule |
|------|------|
| Small-sample protection | When `req(d) < 10`, skip this round's update and keep the old score |
| Circuit breaking | When `err_rate(d) > 0.5` and severe categories (5xx/Timeout/connection errors) dominate, set `weight(d) = 0` (takes precedence over the exploration floor) |
| Recovery | Designed to close the circuit after 3 consecutive rounds of `err_rate(d) < 0.1`; **the current implementation has a gap**: a channel with weight 0 gets no samples, the state machine stops evaluating it, and manual intervention is required -- see [ADR-006 §6.3](ADR.md) |
| Write-back | LiteLLM `/model/update` is called only when any weight in the group changes by more than 2 percentage points (hysteresis debouncing) |
| Degradation | When Prometheus / the LiteLLM API is unavailable, weights freeze and an alert fires (Scorer is not on the request path) |
| State persistence | EWMA scores are stored in Redis (`scorer:score:<channel_id>`); restarts are lossless |
| Deployment form | Single-replica Deployment (not a CronJob); it exports the `scorer_quality_score` / `scorer_weight` / `scorer_last_success_timestamp` metrics itself |

## Alert Response

| Alert | Meaning | Response |
|---|---|---|
| TPPScorerStale | Scorer has not scored successfully for >5min; weights are frozen | `kubectl logs -n scorer deploy/scorer`; common causes: Prometheus unreachable, LiteLLM API 401 (ExternalSecret not refreshed after master key rotation) |
| TPPLiteLLMHighErrorRate | Overall error rate >10% | First check the error breakdown in the TPP Dashboard "Channel stability and performance" table to locate the channel (switch the window to 15m); a single-channel failure should already be circuit-broken -- if all channels are affected, check Bedrock service status/IAM |
| TPPLiteLLMDown | All proxy replicas unreachable | `kubectl get pods -n litellm`; check RDS (litellm has a hard startup dependency on the DB) and the most recent apply |
| TPPChannelCircuitOpen | A channel has been circuit-open for >5min | The TPP Dashboard health badge shows "circuit open"; the current implementation **does not recover automatically** (see [ADR-006 §6.3](ADR.md)): first check that region's Bedrock quotas/health, and once confirmed recovered, pause Scorer, manually set the channel's weight back to non-zero and clear Redis `scorer:circuit:<id>`, then resume Scorer |

## Known Issues / Gotchas

- **Channel definitions live only in scorer-channels.yaml**; the LiteLLM config's model_list is intentionally empty
  (models from static config cannot have their weights adjusted via the Management API). Do not add models manually in the LiteLLM UI -- that bypasses the registry.
- Langfuse is v4 (OTel-native): the LiteLLM callback must be `langfuse_otel`; the old `langfuse` callback returns 400.
- Single-node ClickHouse must have `clickhouse.cluster.enabled=false`, otherwise migrations require Keeper.
- The first deployment of the apps layer needs two apply passes (CRD ordering); see apps/README.md.
- `/metrics` is behind authentication; the ServiceMonitor scrapes with the master key as a Bearer token. When rotating the master key, wait for the ExternalSecret refresh (`litellm-env` is now 5m, `dashboard-env` is still 1h) or trigger it manually.
  Both the Dashboard and Scorer hold the master key to call the Management API; after rotation both will get 401s, showing up as an empty Dashboard user table and a `TPPScorerStale` alert.
- **The TPP Dashboard has no authentication of its own**; its security premise is no Ingress exposure and tunnel-only access. It holds the master key and can change quotas --
  do not forward port 3020 to a LAN or the public internet. Before putting it behind an ALB, OIDC must be added first (`docs/scaling-500-users.md` §9).
- The Dashboard depends on Prometheus's `model_id` / `exception_class` / `le` labels and the `scorer-channels.yaml` registry;
  when reducing cardinality or changing the registry format, regression-test both together.
- TTFT metrics are only produced by streaming requests; TPOT uses `litellm_deployment_latency_per_output_token`.
- **launchd cannot execute scripts under `~/Documents`** (macOS TCC, fails with `Operation not permitted`);
  the tunnel script must be the copy under `~/.local/bin/`; **after changing the repo script, `cp` it over and restart the service**.
- **The local LiteLLM port is 14000** (migrated from 4000, which was given to another local application);
  in `14000:4000`, the 4000 on the right is the pod container port, which has never changed on the platform side.
- Manual and daemon port-forwards fight over ports: the tunnel script pkills and takes over similar processes at startup;
  to investigate port conflicts, use `lsof -nP -iTCP:<port> -sTCP:LISTEN` to see the owner.
- Backups of the Claude Code direct-Bedrock baseline configuration: `~/.claude/settings.json.bedrock-backup`
  and `docs/claude-code-config-baseline.md`; for rollback see the "Claude Code with TPP" section.

## Current Environment Registry

- Channel registry: 4 Claude model groups x 2 regions + `gpt-5.6-terra` (Bedrock Mantle, usw2) = **9 channels**;
- Existing users: `dev-laptop` ($100/day), `dev-laptop-codex` ($100/day, this machine's `TPP_API_KEY`, shared by Codex and `claude-tpp`);
- Local Claude Code / Codex: **direct Bedrock by default, switch to TPP on demand** (`claude-tpp` / `codex --profile tpp`);
- Local tunnel daemon: launchd `com.tpp.litellm-proxy` -> five tunnels;
- Repo not yet git committed; the always-on dev environment costs about $400-450/month (cost-saving switch above).
