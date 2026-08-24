# Claude Code 配置基线(切换 TPP 前,2026-08-24 采集)

用途:laptop 上 Claude Code 从"Bedrock 直连"切到 TPP 后,如需回滚,
**把下面这份 JSON 原样覆盖回 `~/.claude/settings.json`,重启 Claude Code 会话即可**。
没有其他残留点(已确认 `~/.zshrc`、`~/.zprofile`、项目级 `.claude/settings*.json` 均无渠道相关配置)。

## `~/.claude/settings.json` 原文

```json
{
  "env": {
    "AWS_PROFILE": "default",
    "CLAUDE_CODE_USE_BEDROCK": "true",
    "ANTHROPIC_MODEL": "us.anthropic.claude-fable-5",
    "ANTHROPIC_SMALL_FAST_MODEL": "us.anthropic.claude-3-7-sonnet-20250219-v1:0",
    "AWS_REGION": "us-west-2",
    "MAX_THINKING_TOKENS": "1024"
  },
  "permissions": {
    "allow": [
      "Bash",
      "Read",
      "Write",
      "Edit",
      "Glob",
      "Grep",
      "Agent",
      "WebFetch",
      "NotebookEdit",
      "mcp__pencil"
    ]
  },
  "model": "us.anthropic.claude-fable-5",
  "effortLevel": "high",
  "tui": "fullscreen"
}
```

## 要点

- 直连模式由 `CLAUDE_CODE_USE_BEDROCK=true` 驱动,AWS 凭据来自本机 `~/.aws` 的
  `default` profile(本机 IAM user),region `us-west-2`;
- 主模型 `us.anthropic.claude-fable-5`,后台快速模型 `us.anthropic.claude-3-7-sonnet-20250219-v1:0`;
- `permissions` / `effortLevel` / `tui` 与渠道无关,切换 TPP 时保持不动;
- 切 TPP 需要改的:`env` 里删 `CLAUDE_CODE_USE_BEDROCK`、`AWS_PROFILE`、`AWS_REGION`,
  加 `ANTHROPIC_BASE_URL=http://localhost:14000` + `ANTHROPIC_AUTH_TOKEN=<TPP key>`
  (本地端口 2026-08-24 起为 14000,4000 让给了其他应用),
  两个模型名与顶层 `"model"` 改为 TPP 注册表名(`claude-fable-5` / `claude-haiku-4-5`,
  fable-5 渠道已于 2026-08-24 注册进 scorer-channels.yaml)。
