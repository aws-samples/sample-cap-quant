# Claude Code Configuration Baseline (Direct Bedrock Connection)

Purpose: `~/.claude/settings.json` is this direct-connection baseline; `claude` connects directly by default. To go through TPP, use
`claude-tpp` (the `--settings ~/.claude/tpp.settings.json` overlay; see the runbook section
"Connecting Claude Code to TPP"). If `settings.json` gets broken,
**overwrite `~/.claude/settings.json` verbatim with the JSON below and restart the Claude Code session**
(a local backup with the same content: `~/.claude/settings.json.bedrock-backup`).
The only channel-related items in `~/.zshrc` are the `TPP_API_KEY` export and the `claude-tpp` alias; the project-level
`.claude/settings*.json` files contain no channel-related configuration.

## `~/.claude/settings.json` Verbatim

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

## Key Points

- Direct-connection mode is driven by `CLAUDE_CODE_USE_BEDROCK=true`; AWS credentials come from the
  `default` profile in the local `~/.aws` (a local IAM user), region `us-west-2`;
- Primary model `us.anthropic.claude-fable-5-1` (the top-level `model`, changeable via `/model`; `ANTHROPIC_MODEL`
  stays at fable-5 as a fallback), background fast model `us.anthropic.claude-haiku-4-5-20251001-v1:0`
  (the previous `claude-3-7-sonnet-20250219-v1:0` was retired on Bedrock and has been replaced);
- `permissions` / `effortLevel` / `tui` are channel-agnostic; leave them untouched when switching to TPP;
- Switching to TPP **does not modify this file**; use the overlay `~/.claude/tpp.settings.json`:
  `CLAUDE_CODE_USE_BEDROCK="0"` (must be `"0"`, parsed numerically),
  `ANTHROPIC_BASE_URL=http://localhost:14000`, `ANTHROPIC_AUTH_TOKEN=<TPP user key>`,
  and set the two model names plus the top-level `"model"` to the TPP registry names (`claude-fable-5` / `claude-haiku-4-5`).
