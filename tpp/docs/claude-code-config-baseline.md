# Claude Code 配置基线(Bedrock 直连)

用途:`~/.claude/settings.json` 就是这份直连基线,`claude` 默认直连;走 TPP 用
`claude-tpp`(`--settings ~/.claude/tpp.settings.json` 覆盖层,见 runbook
"Claude Code 接入 TPP")。如 `settings.json` 被改坏,
**把下面这份 JSON 原样覆盖回 `~/.claude/settings.json`,重启 Claude Code 会话即可**
(本机同内容备份:`~/.claude/settings.json.bedrock-backup`)。
`~/.zshrc` 中与渠道相关的只有 `TPP_API_KEY` 导出和 `claude-tpp` 别名;项目级
`.claude/settings*.json` 无渠道相关配置。

## `~/.claude/settings.json` 原文

```json
{
  "env": {
    "AWS_PROFILE": "default",
    "CLAUDE_CODE_USE_BEDROCK": "true",
    "ANTHROPIC_MODEL": "us.anthropic.claude-fable-5",
    "ANTHROPIC_SMALL_FAST_MODEL": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
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
  "model": "us.anthropic.claude-fable-5-1",
  "effortLevel": "high",
  "tui": "fullscreen"
}
```

## 要点

- 直连模式由 `CLAUDE_CODE_USE_BEDROCK=true` 驱动,AWS 凭据来自本机 `~/.aws` 的
  `default` profile(本机 IAM user),region `us-west-2`;
- 主模型 `us.anthropic.claude-fable-5-1`(顶层 `model`,`/model` 可改;`ANTHROPIC_MODEL`
  仍为 fable-5 作兜底),后台快速模型 `us.anthropic.claude-haiku-4-5-20251001-v1:0`
  (原 `claude-3-7-sonnet-20250219-v1:0` 已在 Bedrock 下线,已更换);
- `permissions` / `effortLevel` / `tui` 与渠道无关,切换 TPP 时保持不动;
- 切 TPP **不改这份文件**,用覆盖层 `~/.claude/tpp.settings.json`:
  `CLAUDE_CODE_USE_BEDROCK="0"`(必须是 `"0"`,按数值解析)、
  `ANTHROPIC_BASE_URL=http://localhost:14000`、`ANTHROPIC_AUTH_TOKEN=<TPP user key>`,
  两个模型名与顶层 `"model"` 用 TPP 注册表名(`claude-fable-5` / `claude-haiku-4-5`)。
