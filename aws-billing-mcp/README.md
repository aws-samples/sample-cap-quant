# aws-billing-mcp

MCP server that exposes AWS Billing and Cost Management data for the current AWS account via the local AWS CLI, so MCP clients such as Quick Desktop can analyze spend and usage. Written in TypeScript; compiled output lives in `dist/`.

## Prerequisites

- Node.js ≥ 18
- AWS CLI v2, with working credentials for the default profile (or the profile set via `AWS_PROFILE`)
- IAM permissions: `ce:Get*`, `budgets:ViewBudget`, `sts:GetCallerIdentity`

Optional: set the `EXPECTED_ACCOUNT` environment variable to the target AWS account ID. When set, the server verifies via `sts get-caller-identity` on the first tool call that the current credentials actually belong to that account, and fails immediately on a mismatch — preventing accidental queries against the wrong account. When unset, the server simply uses whatever account the current credentials resolve to.

## Install and build

```bash
cd <project directory>
npm install
npm run build   # tsc compiles to dist/
```

During development you can skip the build and run the TypeScript source directly:

```bash
npm run dev     # tsx src/index.ts
```

## Smoke test

```bash
npm test        # tsx src/test-client.ts
```

This lists all tools, queries this month's top 5 costs grouped by service, and runs a cost forecast through the end of the month.

## Connecting to Quick Desktop

Add the following to Quick Desktop's MCP server configuration (Settings → Integrations/MCP servers, or its JSON config file). Run `npm run build` first, and replace both paths with the actual absolute paths on your machine:

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

> Note: GUI apps do not inherit your shell's PATH at launch, so `command` should be the
> absolute path to node (check with `which node`, especially for node installed via nvm),
> and the `PATH` in `env` should include the directory containing `aws` (check with
> `which aws`). Do not use `~` in the JSON config — many clients do not expand it.

## Tools

| Tool | Purpose |
|---|---|
| `get_cost_and_usage` | Core query: cost/usage for any time period, with grouping by SERVICE, USAGE_TYPE, REGION, TAG, etc. (up to 2 groups), Cost Explorer filter expressions, and automatic pagination |
| `get_dimension_values` | Enumerate the values of a dimension that actually incurred cost (service names, regions, etc.), to determine exact filter values |
| `get_cost_forecast` | Cost forecast for a future time period (with 80% prediction interval) |
| `get_cost_anomalies` | Cost anomalies detected by Cost Anomaly Detection, including root causes |
| `describe_budgets` | Budgets in the account, with actual/forecasted spend against each |
| `get_cost_allocation_tags` | Cost allocation tag keys/values seen in billing data, for use with TAG grouping |
| `get_commitment_utilization` | Savings Plans / RI utilization and coverage |

## Example analysis questions (in Quick Desktop)

- "How much has this account spent this month? Rank the top 10 by service."
- "What's the daily Bedrock spend trend over the last 30 days — any unusual spikes?"
- "Forecast the total bill through the end of the month."
- "Break EC2 costs down by usage type — which part is growing fastest?"

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `EXPECTED_ACCOUNT` | (unset) | Optional. When set, only this AWS account may be accessed; mismatched credentials are rejected |
| `AWS_PROFILE` | (system default) | AWS CLI profile to use |
| `AWS_CLI_BIN` | `aws` | Path to the AWS CLI executable |
