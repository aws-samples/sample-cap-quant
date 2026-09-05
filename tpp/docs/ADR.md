# TPP Architecture Design Records (ADR)

This document collects the key architecture decisions already made for TPP (Token Proxy Platform). Each record answers three questions:
**what problem we faced at the time, which option we chose, and what price we paid**. Decisions that already have dedicated documents are only summarized here with links;
decisions that had no document yet (tunnel watchdog, dual-mode access, prompt cache trade-off) are systematically written up here for the first time.

Division of labor between documents: [`README.md`](../README.md) covers architecture components, repository layout, and deployment steps;
[`docs/runbook.md`](runbook.md) covers day-to-day operations, the RDS credential rotation recovery chain, the Scorer scoring algorithm and runtime rules, and alert response;
this document only records "why it was designed this way". All descriptions follow the code and configuration currently in the repository;
where the runbook disagrees, the code behavior noted here takes precedence.

| ID | Area | Topic |
|---|---|---|
| [ADR-001](#adr-001-security-automatic-reconnection-after-rds-credential-rotation) | Security | Automatic reconnection after RDS credential rotation |
| [ADR-002](#adr-002-resiliency-health-probe-watchdog-for-local-tunnels) | Resiliency | Health-probe watchdog for local tunnels |
| [ADR-003](#adr-003-resiliency-client-switching-between-tpp-and-direct-model-access) | Resiliency | Client switching between TPP and direct model access |
| [ADR-004](#adr-004-ops-installing-the-tunnel-daemon-on-a-new-machine) | Ops | Installing the tunnel daemon on a new machine |
| [ADR-005](#adr-005-ops-channel-weight-scoring-mechanism) | Ops | Channel weight scoring mechanism |
| [ADR-006](#adr-006-ops-scorer-runtime-rules) | Ops | Scorer runtime rules (small samples, circuit breaking, recovery, write-back, degradation) |
| [ADR-007](#adr-007-ops-in-house-unified-portal-dashboard) | Ops | In-house unified portal Dashboard |
| [ADR-008](#adr-008-scaling-architecture-changes-for-500-users) | Scaling | Architecture changes for 500 users |
| [ADR-009](#adr-009-trade-off-stability-first-design-lowers-prompt-cache-hit-rate) | Trade-off | Stability-first design lowers prompt cache hit rate |

---

## ADR-001 [Security] Automatic Reconnection After RDS Credential Rotation

**Status**: implemented. For the recovery chain, Secret names, and troubleshooting notes see the
"RDS Credential Rotation and Automatic Recovery" section of [`docs/runbook.md`](runbook.md#rds-credential-rotation-and-automatic-recovery);
the detailed change list is in [`docs/rds-rotation-recovery-changes.md`](rds-rotation-recovery-changes.md).

### Background

RDS manages the PostgreSQL master password with `manage_master_user_password=true`, and AWS rotates it automatically every **7 days**.
LiteLLM and Langfuse both read the database connection string from environment variables at startup and never re-read it while the process is alive.
Even after External Secrets Operator (ESO) syncs the new password into the Kubernetes Secret, already-running Pods still hold the old password.
The symptom: after rotation, LiteLLM fails to start or Langfuse Prisma connections are refused, requiring a manual `kubectl rollout restart`.

### Decision

Do not change application code and do not attempt in-process reconnection; instead **let a password change trigger a rolling restart**:

```text
RDS / Secrets Manager password rotation
  → ESO polls with a 5m refreshInterval; litellm-env / langfuse-postgres refresh within at most 5 minutes
  → Stakater Reloader detects the Secret data change
  → LiteLLM, Langfuse Web, and Langfuse Worker roll-restart
  → New Pods start with the new password
```

"5 minutes" is ESO's active polling period and the maximum credential-discovery delay; it is not the rotation period, which remains 7 days.

### Implementation notes

- The `refreshInterval` of the `litellm-env` and `langfuse-postgres` ExternalSecrets was reduced from `1h` to `5m`
  (`apps/litellm.tf`, `apps/langfuse.tf`).
- `apps/platform.tf` adds a Reloader Helm release (chart `2.2.16`, namespace `kube-system`) that watches
  Secrets / ConfigMaps globally but only restarts workloads annotated with `reloader.stakater.com/auto: "true"`.
- Reloader triggers restarts by injecting a checksum environment variable into the container. The LiteLLM Deployment is managed
  with native Terraform resources, so the first env `STAKATER_LITELLM_ENV_SECRET` is reserved and its value is ignored via
  `lifecycle.ignore_changes`; otherwise the next `terraform apply` would wipe Reloader's change and roll everything back.
- Langfuse uses Prisma; when the password contains URI-reserved characters such as `@ : / % # ?` it fails with `P1013 invalid port number`.
  The ExternalSecret template therefore encodes the password with `urlquery`, generates the complete `database_url` directly,
  and injects it as `DATABASE_URL` / `DIRECT_URL` rather than handing the raw password to the chart for string concatenation.

### Alternatives

| Option | Why not adopted |
|---|---|
| Disable managed rotation, use a static password | Gives up the security benefit of managed rotation; credentials end up in tfstate |
| Detect connection failure in-app and re-read the Secret | LiteLLM / Langfuse are both third-party images; the change is costly and breaks on every upgrade |
| CronJob rollout every 7 days | Cannot align precisely with AWS's rotation moment; errors still occur inside the window |

### Consequences and trade-offs

- Every 7 days each of the three workloads roll-restarts once. LiteLLM has 2 replicas with readiness probes in place,
  so new requests are unaffected during the restart, but **streaming requests on the Pod being rolled are interrupted** and clients must retry.
- Maximum credential-discovery delay is 5 minutes. If LiteLLM restarts for any other reason inside that window, it starts with the old
  password and fails; the startupProbe holds it until the next sync round.
- ESO's call rate to Secrets Manager increases 12x; at dev scale the cost is negligible.
- Any field change in the same Secret (e.g. master key rotation) also triggers a restart; this is the desired behavior.
- `dashboard-env` still refreshes at `1h`; it only contains the master key, not the RDS password, and is out of scope for this decision.

---

## ADR-002 [Resiliency] Health-Probe Watchdog for Local Tunnels

**Status**: implemented. Code in [`scripts/tpp-tunnels.sh`](../scripts/tpp-tunnels.sh). First written up here.

### Background

The dev environment exposes no Ingress; the local machine reaches LiteLLM (14000), Grafana (3000),
Langfuse (3010), Prometheus (9090), and TPP Dashboard (3020) through `kubectl port-forward` tunnels.
The tunnel script's original recovery model was "re-launch when the kubectl process exits". In practice a failure mode showed up:
**after the laptop switches networks or wakes from sleep, kubectl's connection to the API server is dead, but the process does not exit;
the local port keeps listening and every forwarded request times out**. This "zombie" state is completely invisible to
"reconnect on process exit"; clients such as `claude-tpp` keep reporting connection timeouts and the process must be killed manually.

### Decision

Add a **watchdog based on local HTTP probing** to each tunnel's supervision loop, changing the definition of
"tunnel usable" from process liveness to end-to-end reachability:

```text
forward <name> <namespace> <service> <local:remote> <health probe URL>
  ┌─ start kubectl port-forward in the background, record pid
  │  loop (while pid is alive):
  │    sleep 15
  │    curl -sf -m 5 <health probe URL>
  │      success → fails = 0
  │      failure → fails += 1; fails ≥ 3 → kill pid, break
  │  wait pid; sleep 3
  └─ back to the top, re-launch
```

### Implementation notes

- **Probe every 15 seconds; 3 consecutive failures mean zombie**, each curl timing out at 5 seconds.
  Worst-case detection time ≈ 3 × (15 + 5) = 60 seconds, typically about 45 seconds, matching the runbook's
  "auto-restarts within about 45 seconds".
- Probe targets are each service's own lightweight health endpoint: no authentication, no business side effects:

  | Tunnel | Probe URL |
  |---|---|
  | LiteLLM | `/health/liveliness` |
  | Grafana | `/api/health` |
  | Langfuse | `/api/public/health` |
  | Prometheus | `/-/healthy` |
  | Dashboard | `/healthz` |

- kubectl is now started in the background with process substitution `> >(sed ...)` for log prefixing, instead of the original
  pipeline `kubectl | sed`. With the pipeline, `$!` returns sed's pid, making it impossible to locate and kill kubectl;
  fixing this is a precondition for the watchdog to work at all.
- A probe failure only kills kubectl and never exits the script; the outer `while true` reconnects after 3 seconds,
  reusing the existing reconnect path.
- On startup the script `pkill`s port-forward processes of the same kind to enforce a "single owner",
  preventing manual tunnels and daemon tunnels from fighting over ports.
- Each of the five tunnels has its own independent watchdog; one zombie tunnel does not restart the other four.
- launchd (`KeepAlive`) handles restarting after the script itself crashes, with `ThrottleInterval 10` preventing crash storms.
  The watchdog and launchd are two layers: launchd keeps the script alive, the watchdog keeps the tunnels open.

### Alternatives

| Option | Why not adopted |
|---|---|
| Rely on kubectl's own timeout options | `port-forward` has no heartbeat/timeout option for established connections |
| Unconditionally restart all tunnels every N minutes | Interrupts in-flight streaming requests, and the zombie window can still reach N minutes |
| Replace port-forward with SSM / VPN / Ingress | The right direction at 500-user scale (see ADR-008 §9), but the cost does not fit the single-person dev stage |

### Consequences and trade-offs

- **False kills are accepted**: probes hit the service health endpoints, so during backend Pod rolling restarts
  (e.g. ADR-001's restarts every 7 days) probes fail and the tunnel gets killed and reconnected. This is actually beneficial:
  a `port-forward` to a Service binds to the specific Pod selected at startup; once that Pod is gone the tunnel is dead anyway,
  and only a reconnect binds it to a new Pod.
- When the backend is genuinely down, the tunnel enters a "kill every ~1 minute, reconnect after 3 seconds" loop and
  `/tmp/tpp-proxy.log` keeps growing. Acceptable at dev stage; long-term operation would need log rotation or exponential backoff.
- Each tunnel makes one local HTTP request every 15 seconds; the five tunnels together are about 20 requests/minute,
  negligible for the servers.
- The script exists in two copies (the repo and `~/.local/bin/`; see ADR-004 for why). **After changing the repo script you must
  copy it over**, or launchd keeps running the old logic. The two copies are currently verified identical.

---

## ADR-003 [Resiliency] Client Switching Between TPP and Direct Model Access

**Status**: implemented. Steps in the "Connecting Claude Code to TPP" and "Connecting Codex CLI to TPP"
sections of [`docs/runbook.md`](runbook.md); baseline configuration in
[`docs/claude-code-config-baseline.md`](claude-code-config-baseline.md). First written up here.

### Background

TPP is itself the thing being developed and debugged. If AI coding assistants like Claude Code / Codex can **only** reach models
through TPP, then whenever TPP breaks (zombie tunnel, LiteLLM rolling restart, RDS rotation failure, channel circuit breaking,
quota exhaustion), the AI assistant needed for troubleshooting fails along with it, creating the deadlock of
"fixing the broken thing with the broken thing". On the other hand, day-to-day traffic should go through TPP
to exercise the quota, trace, and scoring paths.

### Decision

Clients keep **two non-interfering access paths: direct by default, switch to TPP on demand**:

| | Direct Bedrock (default) | Via TPP |
|---|---|---|
| Dependencies | Local AWS IAM credentials, Bedrock service | All of the above + tunnel + LiteLLM + RDS + Redis + TPP user key |
| Claude Code | `claude`, reads `~/.claude/settings.json` | `claude-tpp` = `claude --settings ~/.claude/tpp.settings.json` |
| Codex CLI | `codex`, reads top level of `~/.codex/config.toml` | `codex --profile tpp`, profile in `~/.codex/tpp.config.toml` |
| Model names | Bedrock inference profile id (`us.anthropic.*`) | TPP model group names (`claude-fable-5` etc.) |
| Rollback | Running with no flags is the rollback | Run without `--settings` / `--profile` to fall back |

Three design principles:

1. **Baseline files are never polluted by TPP configuration.** TPP configuration lives only in overlay files
   (Claude Code's `--settings` overlay, Codex's separate profile file); "rollback" requires editing no files,
   just running a different command.
2. **Both paths hit the same set of models.** The TPP channel registry contains only Bedrock channels, using the same account
   and the same inference profiles as direct access, so switching changes only whether traffic goes through the proxy,
   not model capability.
3. **The baseline has offline backups.** Three backups: `~/.claude/settings.json.bedrock-backup`,
   `docs/claude-code-config-baseline.md`, and the repo's `.codex-backup/`; even if the overlay is accidentally merged into
   the baseline, a single `cp` restores it.

### Implementation notes

- Claude Code has no profile concept; the `--settings <file>` overlay does the job: `env` merges per key and overrides shell
  environment variables with the highest priority. The overlay must set `"CLAUDE_CODE_USE_BEDROCK": "0"` (parsed numerically;
  `"false"` is not guaranteed to work) and simultaneously change `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`,
  both model names, and the top-level `model`.
- In Codex ≥ 0.134 a profile is a separate file using top-level keys; the provider definition lives in the main config's
  `[model_providers.tpp]`, and `wire_api` must be `"responses"` (`"chat"` is deprecated and makes the whole config.toml
  fail to parse, taking direct access down with it).
- On the TPP side a dedicated `gpt-5.6-terra` model group is registered for Codex (Bedrock Mantle; the `bedrock_mantle/` route
  passes through the Responses API and reasoning), and IRSA additionally needs `bedrock-mantle:CreateInference`.
- To verify traffic really goes through TPP: with Claude Code use `-p ... --output-format json` and check whether the
  `modelUsage` key shows a TPP model group name; or watch spend growth on LiteLLM `/user/info` (posting delay about 5-15 seconds)
  and new Langfuse traces.

### Consequences and trade-offs

- **Direct traffic lives outside TPP**: it does not count against per-user quota, produces no traces, does not participate in scoring,
  and is not subject to TPP's dual-region traffic split. This is a deliberate price paid so the assistant stays available
  during troubleshooting.
- Two credential sets coexist (IAM user credentials + TPP user key), enlarging the leak surface; the TPP key file needs `chmod 600`.
- Model names differ between the two paths; scripts or prompts that reference model names must be adjusted per path.
- Direct access is pinned to the single region `us-west-2`, while TPP splits between usw2 / use1 by weight;
  prompt cache behavior differs between the two — see ADR-009.
- User habit cost: two commands to remember, plus the reflex "when TPP misbehaves, switch to direct first, then debug".

---

## ADR-004 [Ops] Installing the Tunnel Daemon on a New Machine

**Status**: implemented. Full commands in the "Installing the tunnel daemon on a new machine (one-time)" section of [`docs/runbook.md`](runbook.md).

### Background

The tunnel script (ADR-002) must stay resident on the dev machine, start at login, restart after crashes, and be transparent to the user:
open a browser and Grafana / Langfuse just work; run `claude-tpp` and LiteLLM is reachable — without first opening a terminal to run a command.

### Decision

Run `tpp-tunnels.sh` permanently via a **macOS launchd user-level LaunchAgent** (`com.tpp.litellm-proxy`),
with a copy of the script in `~/.local/bin/` rather than pointing directly at the repo path.

### Implementation notes

- **The script must be copied to `~/.local/bin/`**: macOS TCC (Transparency, Consent, and Control) forbids launchd
  from executing files under `~/Documents`; pointing directly at the repo path fails with `Operation not permitted`.
  This is where the operational rule "after changing the repo script, `cp` it over and restart the service" comes from.
- Key plist entries: `RunAtLoad` (start at login), `KeepAlive` (restart on exit), `ThrottleInterval 10` (minimum restart interval),
  an explicit `PATH` (launchd does not read shell rc files and must be able to find kubectl / aws under `/opt/homebrew/bin`),
  and `AWS_PROFILE=default` (needed by the kubeconfig's exec credential plugin).
- stdout / stderr both go to `/tmp/tpp-proxy.log`, with the script's `[name]` prefixes distinguishing the five tunnels.
- The plist does not expand `$HOME`; `ProgramArguments` must use absolute paths.
- After installation, verify with five `curl`s against the respective health endpoints — the same set of URLs the watchdog uses.
- Prerequisites: aws cli (with IAM credentials), kubectl, and `aws eks update-kubeconfig --name tpp-dev --region us-west-2` already run.
  On startup the script checks that the current kubecontext is `tpp-dev` and otherwise exits immediately with a message.

### Alternatives

| Option | Why not adopted |
|---|---|
| Provide only the manual scripts `tpp-connect.sh` / `tpp-tunnels.sh` | Must be run manually after every boot; forgetting means connection failures; kept as a fallback path |
| Homebrew services / resident tmux | Still depends on the user starting it once manually; launchd is macOS's native mechanism |
| Expose Ingress + domain | At dev stage there is no OIDC / WAF, so exposure equals unauthenticated public access; listed under ADR-008 §9 |

### Consequences and trade-offs

- Covers macOS only; Linux / Windows dev machines would need a systemd user unit or equivalent, which does not exist yet.
- One-time manual installation per machine, no automated distribution. Once headcount grows, this should be replaced by the
  Ingress approach rather than mass-distributing plists.
- The dual-copy script problem (see ADR-002 consequences) is a direct cost of this decision.

---

## ADR-005 [Ops] Channel Weight Scoring Mechanism

**Status**: implemented. Full formulas and symbol table in the "Scorer Scoring Algorithm" section of
[`docs/runbook.md`](runbook.md#scorer-scoring-algorithm); parameter tuning in the same document's
"Tuning Scoring Parameters". Code in `services/scorer/scorer/scoring.py` (pure functions) and `config.py`.

### Background

A single model group (e.g. `claude-fable-5`) has multiple channels in LiteLLM (two Bedrock regions, usw2 / use1).
LiteLLM's built-in routing strategies are only static weights or simple latency/usage strategies; they lack a quality assessment
that combines errors and latency, is smoothed, and is explainable — and they have no globally consistent view across replicas.
An independent component is needed to adjust each channel's traffic share dynamically based on observed quality.

### Decision

Build an in-house **Scorer**: every 60 seconds it queries Prometheus over the trailing 5-minute window,
scores the channels within each model group against one another, and writes the normalized weights back through the
LiteLLM Management API `PATCH /model/{id}/update`.
**The Scorer is not on the request path**; at request time LiteLLM only reads the weights in its own DB and does
weighted random selection (`simple-shuffle`).

### Algorithm summary

The scoring unit is a deployment, i.e. a (channel, model) pair; comparison happens only within the same model group.

```text
err_rate(d)   = Σ_cat sev(cat) × err(d, cat) / max(req(d), 1)       weighted error rate

score_lat(d)  = clamp(lat_best / lat_p90(d), 0, 1)                   fastest in the group gets 1
score_err(d)  = exp(−K_ERR × err_rate(d))                            K_ERR = 8; drops to 0.5 at err_rate = 8.6%

q_raw(d)      = W_LAT × score_lat(d) + W_ERR × score_err(d)          W_LAT = 0.35, W_ERR = 0.65
q(d, t)       = ALPHA × q_raw(d) + (1 − ALPHA) × q(d, t−1)           ALPHA = 0.3, time constant about 3 minutes

weight(d)     = q(d)^GAMMA / Σ_j q(j)^GAMMA                          GAMMA = 2, amplifies in-group differences
weight(d)     ← max(weight(d), W_FLOOR), then renormalize            W_FLOOR = 0.05, exploration floor
```

Error severity coefficients `sev(cat)`: Timeout / connection errors / 5xx-class are 3.0, 429 rate limiting is 1.5, other 4xx are 0.5.

### Key trade-offs and rationale

| Trade-off | Choice | Rationale |
|---|---|---|
| Errors vs latency weighting | Errors 0.65 > latency 0.35 | One failure hurts a user far more than a few hundred extra milliseconds; latency scores are only compared relatively within the group, avoiding absolute thresholds |
| Latency percentile | E2E p90 | p50 hides the tail; p99 is too noisy at small sample sizes |
| Error score function | Exponential decay rather than linear | Sensitive in the low-error-rate range, drops toward zero quickly at high error rates, and stays within (0, 1] with no negative values |
| Error category weighting | Three tiers by `exception_class` | 4xx is mostly a caller problem and should not penalize the channel; 429 is a quota signal, somewhere in between |
| Smoothing | EWMA, state in Redis | Suppresses single-round jitter; Redis persistence means a Scorer restart loses no history and avoids cold starts |
| Weight amplification | `GAMMA = 2` | Under linear normalization, channels at 0.9 vs 0.6 split only 60/40; squared it is about 69/31, moving traffic off bad channels faster |
| Exploration floor | 5% minimum | No traffic means no samples and scores never update; 5% is the compromise between "keep observability" and "waste little traffic" |
| Deployment form | Single-replica Deployment, not a CronJob | Multiple replicas would write conflicting weights concurrently; a Deployment also makes exporting its own metrics easy |
| Where channels are defined | `scorer-channels.yaml` registry; LiteLLM static `model_list` left empty | Models in static config cannot be re-weighted via the Management API; they must go through `store_model_in_db` |

### Consequences and trade-offs

- Weights are written back as **integers 0-100**; differences below 0.5% are rounded away.
- When a group has only one channel (e.g. `gpt-5.6-terra`), scoring still runs but the weight is always 100; it is observation only.
- All parameters are environment variables; changing one requires `terraform apply` to trigger a Pod restart.
  The severity mapping lives in code; changing it requires rebuilding the image.
- Scoring depends on Prometheus's `model_id` label; any cardinality-reduction work (ADR-008 §8) must preserve that label.

---

## ADR-006 [Ops] Scorer Runtime Rules

**Status**: implemented, with one known gap (see "Recovery"). Code in `services/scorer/scorer/main.py`.
The "runtime rules" table at the end of the "Scorer Scoring Algorithm" section of
[`docs/runbook.md`](runbook.md#scorer-scoring-algorithm) is the short version of this record;
this record expands each rule according to the code.

### Decision overview

The Scorer's runtime rules revolve around one principle: **better to do nothing than to do the wrong thing**.
Any uncertainty (insufficient samples, unavailable dependencies) leads to "keep last round's result";
weights change only when the evidence is solid.

### 6.1 Small-sample protection

- Condition: within the window, the channel has `req(d) < MIN_SAMPLES` (default 10), or Prometheus has no series for the channel at all.
- Behavior: no new score is computed; the old score in Redis is kept; a never-scored new channel cold-starts at `DEFAULT_Q = 0.5`.
- Rationale: 1 timeout out of 10 requests is a 10% weighted error rate times 3 (severity), enough to halve the score;
  small-sample scores are noise.
- Side effect: a model group with no traffic stays at 0.5 / 0.5 with weights 50 / 50 forever — designed behavior, not a fault.
- Note: **with small samples the circuit-breaker state machine is not evaluated either**, which is the root cause of the gap in 6.3.

### 6.2 Circuit breaking

- Trigger conditions (both must hold):
  1. `err_rate(d) > CIRCUIT_ERR_THRESHOLD` (default 0.5);
  2. **Severe errors dominate**: the **counts** of Timeout / connection errors / 5xx-class errors make up ≥ 50% of all error counts.
- Behavior: set `scorer:circuit:<id> = 1`; the channel's weight is set straight to 0, **taking precedence over the exploration floor**;
  the remaining channels in the group are renormalized. If the whole group is broken, weights are split evenly so traffic has
  somewhere to go, relying on LiteLLM's own cooldown as the fallback.
- Rationale:
  - The second condition separates "channel broken" from "channel rate limited". 429 (`RateLimitError`) has severity 1.5 and is not
    in the severe set, so **rate limiting never trips the breaker; it only lowers the weight through the score**. In a dual-region
    topology this is correct: a rate-limited channel can still serve part of the requests.
    Revisit after multi-account multi-region sharding, see ADR-008 §10.
  - Weight 0 rather than the 5% floor, because severe-error dominance means the channel is most likely completely unusable;
    5% traffic would just be 5% failures.
- Relationship with LiteLLM's own circuit breaking: LiteLLM's `allowed_fails: 3` / `cooldown_time: 60` is the first layer —
  **on the request path, independent per proxy replica, second-level granularity**; Scorer circuit breaking is the second layer —
  **globally consistent, minute-level, based on 5-minute window statistics**. The former is fast but narrow-sighted;
  the latter is slow but will not misjudge on one replica's sporadic failures. The two layers back each other up.

### 6.3 Recovery

- Design intent (runbook rules table): after `CIRCUIT_RECOVERY_ROUNDS = 3` consecutive rounds with
  `err_rate(d) < CIRCUIT_RECOVERY_ERR = 0.1`, close the breaker, restore the channel to the floor weight,
  and let the score climb back up.
- Code behavior: the good-round counter lives in Redis `scorer:circuit_good:<id>`; any round that misses the bar resets it to zero;
  when the counter reaches 3 the breaker closes.
- **Known gap**: the recovery check runs only in the `req(d) ≥ MIN_SAMPLES` branch. But after the breaker opens the weight is 0,
  LiteLLM `simple-shuffle` assigns no traffic to a weight-0 deployment, the sample count drops to zero once the 5-minute window
  slides past, the state machine is never evaluated again, and **the breaker never closes automatically**.
  Today the only real ways it can recover are: all other channels in the group entering LiteLLM cooldown so traffic falls onto it;
  or a human changing the weight with the master key / clearing the Redis keys. The `TPPChannelCircuitOpen` alert's claim of
  "usually no action needed (recovers automatically)" is premised on this and does not currently hold.
  The runbook's rules table has been annotated with this gap.
- Suggested fix directions (not implemented): keep a tiny probe weight (e.g. 1%) on broken channels; or move to a time-based
  "half-open" state after tripping and use LiteLLM `/health` active probing instead of traffic samples.

### 6.4 Write-back (hysteresis debouncing)

- Each round reads the current weights from LiteLLM `/model/info`, normalizes them per group, and compares them with this round's
  result; `PATCH /model/{id}/update` is called only if any channel's weight in the group changed by more than
  `HYSTERESIS = 0.02` (2 percentage points).
- Rationale: after weights are written to the LiteLLM DB, every proxy replica must reload its routing table;
  frequent writes both cost overhead and turn the Grafana weight curves into pure spikes.
- `PATCH` only changes `litellm_params.weight`, leaving the channel's other parameters untouched.
- Side effect: if `ALPHA` is raised (faster reaction), `HYSTERESIS` should be raised in step,
  or the oscillation passes straight through to the write-back.

### 6.5 Degradation

- Any exception during a round (Prometheus unreachable, LiteLLM API 401 / timeout, Redis unavailable) → the whole round is skipped;
  weights stay frozen at LiteLLM's previous values; `scorer_cycles_total{result="error"}` is recorded and
  `scorer_last_success_timestamp` stops advancing.
- 5 minutes without a success triggers the `TPPScorerStale` alert; the alert text states explicitly that
  "frozen weights do not affect the request path".
- Rationale: the Scorer is off the request path; if it dies you only lose "intelligence", not "service" —
  so it prefers to stop rather than make half-finished updates.
- Common root causes: 401 because the ExternalSecret has not refreshed after master key rotation;
  Prometheus OOM due to cardinality blow-up.

### 6.6 State persistence and startup

- EWMA scores, breaker state, and recovery counters all live in Redis
  (`scorer:score:<id>` / `scorer:circuit:<id>` / `scorer:circuit_good:<id>`), so a Scorer restart is lossless;
  a rolling restart after a parameter change does not send weights back to 50 / 50.
- On startup `ensure_channels` syncs the registry into the LiteLLM DB; **idempotency is judged solely by whether
  `model_info.id` exists**, so it never overwrites the `litellm_params` of already-registered channels.
  Changing an existing channel's `model` field requires a manual PATCH (documented in the runbook).
- The Redis dependency is "soft": if Redis is unavailable, the round errors out and weights freeze; there is no crash exit.

### 6.7 Pausing and manual intervention

- `kubectl scale deploy/scorer --replicas=0` freezes the weights with no impact on requests. Always pause before manually
  PATCHing weights, or the next round (≤ 60 seconds) will overwrite them.

---

## ADR-007 [Ops] In-House Unified Portal Dashboard

**Status**: implemented. Architecture and data flow in [`docs/architecture.md` §5](architecture.md),
usage and troubleshooting in the "TPP Dashboard (Unified Portal)" section of
[`docs/runbook.md`](runbook.md#tpp-dashboard-unified-portal),
source in `services/dashboard/`, deployment in `apps/tpp-dashboard.tf`.

### Background

The platform already has four UIs, each covering only one facet:

| UI | Good at | Missing |
|---|---|---|
| LiteLLM UI | Creating users, issuing keys, changing budgets | No channel health or performance; a form-style admin UI unsuited to inspection rounds |
| Grafana TPP Overview | Time-series trends, alerts | Cannot change configuration; per-user quota/spend tables cobbled together from Prometheus labels, unreliable |
| Langfuse | Per-call traces | No channel / quota dimension |
| Prometheus | Ad-hoc queries | No readability |

The three most frequent daily ops questions — "who is about to burn through today's quota", "which channel is unhealthy and how is the
Scorer splitting traffic right now", "a user complains it's slow; which channel's TTFT regressed" — cannot be answered on one screen
by any of them, let alone with an inline quota edit.

### Decision

Build an in-house unified portal Dashboard that **only aggregates and stores nothing**: a single container = FastAPI aggregation
backend + static single-page frontend, with Prometheus and the LiteLLM Management API as the only data sources,
serving as the jump-off point to the other four UIs.

Three design principles:

1. **No new source of truth.** Every number can be found identically in Prometheus or the LiteLLM DB;
   the Dashboard only queries, aggregates, and derives (cache hit rate, TPS, error rate) and has no database of its own.
2. **Channel semantics identical to the Scorer's.** Channel rows are rendered from the `scorer-channels.yaml` registry,
   sharing the same ConfigMap with the Scorer; channel granularity relies on the `model_id` label — the same key the Scorer scores by.
3. **Writes minimized and fixed in semantics.** The only write is changing a user's daily quota: the write pins
   `budget_duration=1d` and first verifies the user exists, avoiding LiteLLM `/user/update`'s implicit creation of nonexistent users.
   User creation and key issuance stay in the LiteLLM UI / API.

### Implementation notes

- **Two time frames coexist**: spend and tokens are fixed at the trailing 24h (cost is a daily-granularity question),
  while performance and errors follow the page window (15m / 1h / 6h / 24h / 7d; the whitelist constrains both the dropdown
  options and the PromQL range). This avoids the misreading of "switch to 15m for errors and spend becomes 15m too".
- **The health badge** combines two sources: the Scorer's `scorer_circuit_open` (global, minute-level) and LiteLLM's
  `litellm_deployment_state` (per replica, second-level), taking the worst across replicas.
  For the relationship between the two circuit-breaker layers see ADR-006 §6.2.
- **Derived metrics**: cache hit rate = cache reads / (plain input + cache reads + cache writes), the direct observation point
  for ADR-009's cost; TPS = 1 / TPOT percentile, where p99 TPS is the decode throughput of the slowest 1% of requests.
- **Credential boundary**: the master key is injected into the container by the ExternalSecret `dashboard-env`;
  the browser talks only to the Dashboard backend and never sees the master key.
- **Security model aligned with Prometheus**: no auth of its own, no Ingress exposure, reachable only through the kubectl tunnel
  (local 3020), kept alive by the tunnel daemon (ADR-002 / ADR-004).
- Single replica, `50m` CPU / `128Mi` memory; the frontend polls `/api/overview` every 30 seconds,
  roughly 30 ad-hoc Prometheus queries per half minute.
- Like the Scorer it is a self-built image (`tpp/dashboard`), built and pushed manually, with the tag managed by a Terraform variable.

### Alternatives

| Option | Why not adopted |
|---|---|
| Grafana only, with more panels | Grafana cannot write quotas back; the per-user spend table depends on high-cardinality per-user labels like `hashed_api_key` — exactly what ADR-008 §8 wants to labeldrop |
| Extend the LiteLLM UI | Third-party frontend, not customizable; no concept of the Scorer or histogram percentiles |
| Grafana + a separate "quota editor" tool | Two entry points; inspection and action split apart — the very problem this decision is meant to solve |
| Adopt a general BI / internal-tools platform (Retool-like) | Introducing a new platform and credential surface at dev stage; benefit out of proportion |

### Consequences and trade-offs

- **Yet another self-built component to maintain**: image builds, version numbers, and dependence on Prometheus metric names
  and LiteLLM API shapes. If a LiteLLM upgrade renames metrics or changes the `/user/list` response structure,
  the Dashboard breaks before any other component.
- **Larger master key exposure surface**: the Dashboard is the third component holding the master key
  (the other two being the Scorer and the ServiceMonitor). It can change quotas, so the "no auth" premise is more sensitive
  than for Prometheus; OIDC must be added before putting it behind an ALB (ADR-008 §9),
  and port 3020 must never be forwarded onto a LAN.
- After master key rotation, `dashboard-env` can take up to 1h to refresh, during which the user table returns 401.
  The divergence from ADR-001's 5m is intentional: this Secret contains no RDS password and rotates rarely.
- Prometheus cardinality reduction (ADR-008 §8) must preserve the `model_id` / `exception_class` / `le` labels —
  a hard dependency shared by the Dashboard and the Scorer.
- `/user/list` returns 100 users per page; 500-user scale needs pagination or a per-team view. This aligns with ADR-008 §9's
  self-service direction; at that point the Dashboard's write capability should grow into
  "user self-service + team-admin approval" rather than being rewritten.

---

## ADR-008 [Scaling] Architecture Changes for 500 Users

**Status**: proposal stage, not implemented. Full plan, capacity estimates, and rollout order in
[`docs/scaling-500-users.md`](scaling-500-users.md).
All capacity numbers are order-of-magnitude estimates based on the current configuration, not load-test results.

### Background

The current architecture is deployed at dev size and comfortably carries about 50 heavy users.
500 seats, estimated at the all-heavy upper bound, come to a peak of about 42 RPS, about 1500 concurrent streams, 60M TPM;
the real data-plane pressure is the number of concurrent streams, not RPS.

### Decision summary

| Layer | Change | Nature |
|---|---|---|
| Bedrock quota | Multi-account × 3-region sharding; quota buckets = accounts × calling regions | Commercial + new; weeks of lead time; **start first** |
| Data plane | LiteLLM stays single worker / pod, scale by adding pods; KEDA + Prometheus scaler instead of CPU HPA | Scale-out |
| Ledger | PgBouncer in front; Aurora PG; separate litellm / langfuse databases; SpendLogs retention policy | Resize + split |
| Redis | Split into one set for router / rate limiting and one for the Langfuse queue, both HA + TLS | Split and rebuild |
| Trace storage | Payload sampling first (about 5x benefit), then ClickHouse clustering + TTL + S3 tiering | Change of implementation |
| Metrics | ServiceMonitor cardinality reduction; keep only `model_id` / `requested_model` / `exception_class` / `le` | Config + scale |
| Access layer | ALB + OIDC + self-service key broker + per-key rate limiting; add auth to dashboard | New build |
| Scorer | Stay single-replica; add a "quota exhausted" state and distinguish throttling from failure | Minor change |
| Nodes | 3 node groups + Karpenter; one NAT per AZ | Restructure |

### Rollout order (dictated by dependencies)

```text
Phase 0  quota requests + load-test baseline
Phase 1  PgBouncer → Redis split → Prometheus cardinality reduction → Karpenter → LiteLLM HPA
Phase 2  Langfuse sampling → ClickHouse clustering → worker KEDA
Phase 3  ALB → OIDC → key broker → per-key rate limiting → dashboard auth
```

Two hard dependencies: PgBouncer must come before the HPA (otherwise scaling replicas saturates RDS connections);
Prometheus cardinality reduction must come before user growth (otherwise the Scorer and the dashboard go blind at the same time).

### Core judgment

Platform infrastructure cost (about $5-7k/month) is a rounding error next to token cost (about $40k-170k).
**Do not sacrifice HA to save platform money**; the savings genuinely worth engineering effort are raising the
prompt cache hit rate and routing requests to cheaper models. This leads directly to ADR-009.

---

## ADR-009 [Trade-off] Stability-First Design Lowers Prompt Cache Hit Rate

**Status**: cost accepted for now, listed for optimization. First written up here.

### Background

Anthropic models' prompt caching hits on "exactly identical prefixes"; cache entries live on the Bedrock side,
**scoped to calling account + calling region + model**, with a default TTL of about 5 minutes refreshed on every hit.
Agent workloads like Claude Code / Codex are the best-case scenario for prompt cache: every turn of a session carries the same
system prompt, tool definitions, and an ever-growing conversation history; the prefix is often tens of thousands of tokens,
with only a few hundred tokens appended at the end each turn.

TPP did three things for stability, and each of them breaks the hit precondition
"the same prefix repeatedly lands in the same place":

1. **Dual-region channels**: each Claude model group registers both usw2 and use1 channels, so a failure or rate limiting in
   either region keeps service alive, while also yielding two independent quota buckets (ADR-008 §3).
2. **Weighted random routing**: LiteLLM `simple-shuffle` draws by weight **independently for every request**, unaware of sessions.
3. **Dynamic re-weighting with an exploration floor**: the Scorer keeps nudging weights and guarantees bad channels
   at least 5% of traffic (ADR-005 / ADR-006).

### Quantifying the cost

Let `p_same` be the probability that two consecutive turns of the same session land in the same region.
Under independent weighted draws:

```text
p_same = Σ_i weight(i)²
```

| Weight split | p_same | Meaning |
|---|---|---|
| 50 / 50 (cold start, no traffic, both regions equally good) | 0.50 | Half of all turns miss the cache |
| 80 / 20 | 0.68 | |
| 95 / 5 (floor limit) | 0.905 | Even with one side nearly all-bad, about 10% of turns still miss |
| 100 / 0 (direct or single region) | 1.00 | Theoretical ceiling |

Compared with single-region direct access (ADR-003's default path), at TPP's dev-normal 50 / 50 weights,
**the session-level prompt cache hit-rate ceiling is cut in half**. This is not a rare tail event — it happens every other turn.

The cost of one miss (using Anthropic's public price ratios, with base input price as 1):

```text
hit:  cache_read  = 0.1  × prefix tokens
miss: cache_write = 1.25 × prefix tokens          → that part of the turn costs about 12.5x
```

On the TTFT side, a miss means the whole prefix is prefilled again. For a prefix of tens of thousands of tokens,
time-to-first-token degrades from sub-second to several seconds, and users directly feel the "stutter" in agent interaction.
This is the most direct conflict between the "performance" metrics (TTFT / TPOT / E2E) listed in the README's architecture
component table and the "stability" goal.

Another diluted effect is the **cache TTL**: after a miss, the cache newly written in the other region only pays off if it is
hit again; if the next turn draws the original region back, both sides each write once and each read once, doubling the write cost.

### Decision

**Accept this cost at the current stage; stability and quota redundancy take priority over hit rate**, because:

- At dev stage there are few users and per-session cost is bearable (the runbook records about $0.4 for one full fable-5 Q&A turn),
  while a single-region outage or rate limiting means "everyone stops working" — the two are not comparable.
- Dual region is the foundation of the quota-sharding plan (ADR-008 §3); cutting it means abandoning the future scaling path.
- The hit rate is observable: the TPP Dashboard already computes the 24-hour `cache_hit_rate` per channel
  (`litellm_input_cached_tokens_metric_total` / all input), and TTFT percentiles are on the same page,
  so the cost can be quantified continuously instead of guessed at.

### Identified mitigation directions (not implemented, by priority)

| Direction | Approach | Benefit | Cost |
|---|---|---|---|
| Session-sticky routing | Evaluate LiteLLM's prompt-caching-aware pre-check (stick to the deployment holding the cached prefix), or hash `user` / session id to pick a channel | Pushes `p_same` close to 1 while keeping region-level failover | Depends on LiteLLM version capability; stickiness must be coordinated with weight scheduling — sessions on a bad channel will not migrate away automatically |
| Primary/standby instead of splitting | One primary channel per group, the other only in LiteLLM `fallbacks`; the Scorer only decides which is primary | 100% hits in steady state, failover still possible | Standby gets no steady-state traffic so the Scorer is blind to it; only one quota bucket is used |
| Steeper weights | Raise `GAMMA`, lower `W_FLOOR` | No code change; `p_same` rises as weight concentrates | Only works when the two regions differ in quality; useless at 50 / 50 |
| Pin region per user / team | LiteLLM tag routing, binding different groups of people to different regions | High hit rate and both quota buckets stay utilized | Loses individual-level failover; requires more ops configuration |

### Consequences

- Until a mitigation lands, the TPP path's per-token cost and TTFT are both worse than the direct path's;
  evaluations of TPP's value should factor this in, rather than looking only at proxy-layer resource cost.
- Any change toward "raise the hit rate" must also answer "how do sessions migrate when a region fails" and
  "can the Scorer still observe the standby channel"; otherwise it trades stability for cost,
  the opposite of this decision's premise.
- This is the concrete landing point, in the current architecture, of ADR-008's conclusion that
  "prompt cache hit rate is the biggest cost-saving lever"; it should be settled before Phase 1 of the 500-user plan.

---

## Appendix: How the Decisions Relate

```text
ADR-001 RDS rotation restarts ──→ LiteLLM rolls every 7 days ──→ tunnel backend briefly unavailable ──→ ADR-002 watchdog false-kills and reconnects (beneficial)
ADR-002 watchdog ──→ script must stay resident ──→ ADR-004 launchd + ~/.local/bin dual copies; one of the five tunnels is ADR-007's Dashboard
ADR-003 dual-mode access ──→ troubleshooting does not depend on TPP; direct is single-region ──→ the contrast exposes ADR-009's hit-rate gap
ADR-005 scoring ──→ ADR-006 runtime rules; together they determine the weight distribution ──→ which determines ADR-009's p_same
ADR-006 circuit breaking / ADR-009 hit rate ──→ directly visible on the ADR-007 Dashboard as the health badge / cache hit-rate column
ADR-008 scaling ──→ quota sharding depends on dual region ──→ locks ADR-009 out of simply falling back to a single region
ADR-008 §8 cardinality reduction ──→ must keep model_id and other labels ──→ shared hard dependency of the ADR-005 Scorer and the ADR-007 Dashboard
ADR-008 §9 access governance ──→ ADR-007 Dashboard's no-auth premise no longer holds; OIDC must come first
```
