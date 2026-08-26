/**
 * Smoke test: lists tools, queries this month's cost grouped by service,
 * and runs a cost forecast. Requires valid AWS credentials for the target
 * account. Run with: npm test (uses tsx; spawns the server from src via tsx).
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const transport = new StdioClientTransport({
  command: "npx",
  args: ["tsx", "src/index.ts"],
});
const client = new Client({ name: "test", version: "1.0.0" });
await client.connect(transport);

const tools = await client.listTools();
console.log("TOOLS:", tools.tools.map((t) => t.name).join(", "));

interface Group {
  Keys: string[];
  Metrics: { UnblendedCost: { Amount: string } };
}

// Query from the start of the current month (previous month if today is the
// 1st, since start must be before end) through today.
const fmt = (d: Date) => d.toISOString().slice(0, 10);
const now = new Date();
const today = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
const monthStart =
  today.getUTCDate() === 1
    ? new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth() - 1, 1))
    : new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1));

const res = await client.callTool({
  name: "get_cost_and_usage",
  arguments: {
    start: fmt(monthStart),
    end: fmt(today),
    granularity: "MONTHLY",
    metrics: ["UnblendedCost"],
    group_by: [{ type: "DIMENSION", key: "SERVICE" }],
  },
});
const content = res.content as { type: string; text: string }[];
const data = JSON.parse(content[0].text);
const groups = (data.ResultsByTime[0].Groups as Group[])
  .map((g): [string, number] => [g.Keys[0], parseFloat(g.Metrics.UnblendedCost.Amount)])
  .sort((a, b) => b[1] - a[1])
  .slice(0, 5);
console.log("TOP5 SERVICES:", JSON.stringify(groups, null, 1));

// Forecast from tomorrow to the end of its month (forecast start must not be
// in the past, and the range must span at least one day).
const tomorrow = new Date(today);
tomorrow.setUTCDate(tomorrow.getUTCDate() + 1);
const forecastEnd = new Date(Date.UTC(tomorrow.getUTCFullYear(), tomorrow.getUTCMonth() + 1, 1));

const fc = await client.callTool({
  name: "get_cost_forecast",
  arguments: { start: fmt(tomorrow), end: fmt(forecastEnd) },
});
const fcContent = fc.content as { type: string; text: string }[];
console.log("FORECAST:", fcContent[0].text.slice(0, 300));

await client.close();
