#!/usr/bin/env bash
# Smoke-test the gateway through a port-forward (no public ingress needed).
#   scripts/smoke.sh            # all five model families, OpenAI chat + Anthropic messages + Responses
#   AIGW_URL=https://llm.example.com scripts/smoke.sh   # against the public hostname instead
set -euo pipefail
REGION="${AIGW_REGION:-us-east-2}" # pinned; the operator shell may default to another region
KEY="${AIGW_API_KEY:-$(aws secretsmanager get-secret-value --region "$REGION" --secret-id aigw/dev/api-keys --query SecretString --output text | jq -r .admin)}"

PF_PID=""
if [[ -z "${AIGW_URL:-}" ]]; then
  kubectl -n envoy-gateway-system port-forward svc/aigw-envoy 18080:80 >/dev/null 2>&1 &
  PF_PID=$!; trap 'kill $PF_PID 2>/dev/null || true' EXIT
  AIGW_URL="http://localhost:18080"
  for i in $(seq 1 20); do curl -s -o /dev/null -m 2 "$AIGW_URL/" && break; sleep 1; done
fi
set +e # report each probe; do not abort on the first failing curl

chat() { # model
  printf '%-16s chat/completions  ' "$1"
  curl -s -m 60 "$AIGW_URL/v1/chat/completions" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$1\",\"max_tokens\":40,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one word: ok\"}]}" \
    | jq -r 'if .choices then "OK  " + (.choices[0].message.content|tostring|.[0:40]) + "  tokens=" + (.usage.total_tokens|tostring) else "FAIL " + (.|tostring|.[0:200]) end'
}
anthropic() { # model
  printf '%-16s anthropic/messages ' "$1"
  curl -s -m 60 "$AIGW_URL/anthropic/v1/messages" -H "x-api-key: $KEY" -H 'anthropic-version: 2023-06-01' -H 'Content-Type: application/json' \
    -d "{\"model\":\"$1\",\"max_tokens\":40,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one word: ok\"}]}" \
    | jq -r 'if .content then "OK  " + (.content[0].text|.[0:40]) + "  in=" + (.usage.input_tokens|tostring) + " out=" + (.usage.output_tokens|tostring) else "FAIL " + (.|tostring|.[0:200]) end'
}
responses() { # model
  printf '%-16s responses          ' "$1"
  curl -s -m 60 "$AIGW_URL/v1/responses" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$1\",\"input\":\"Reply with one word: ok\"}" \
    | jq -r 'if .output then "OK  " + ([.output[]|select(.type=="message")|.content[0].text]|join("")|.[0:40]) else "FAIL " + (.|tostring|.[0:200]) end'
}
stream() { # model: first SSE chunk latency
  printf '%-16s SSE first-chunk    ' "$1"
  curl -s -N -m 60 -o /dev/null -w 'TTFB=%{time_starttransfer}s total=%{time_total}s\n' "$AIGW_URL/v1/chat/completions" \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$1\",\"stream\":true,\"max_tokens\":60,\"messages\":[{\"role\":\"user\",\"content\":\"Count from 1 to 20.\"}]}"
}

echo "== auth check (expect 401)"; curl -s -o /dev/null -w 'no key -> HTTP %{http_code}\n' "$AIGW_URL/v1/models"
echo "== models"; curl -s "$AIGW_URL/v1/models" -H "Authorization: Bearer $KEY" | jq -r '.data[].id' | tr '\n' ' '; echo
echo "== chat completions"; for m in claude-haiku-5-5 claude-sonnet-5-5 gpt-5.6-terra gpt-oss-120b kimi-k3 deepseek-v3.2 glm-5 glm-5.3; do chat "$m"; done
echo "== anthropic messages (Claude Code path)"; anthropic claude-haiku-5-5
echo "== responses (Codex path)"; responses gpt-oss-120b; responses gpt-5.6-terra
echo "== streaming"; stream claude-haiku-5-5
