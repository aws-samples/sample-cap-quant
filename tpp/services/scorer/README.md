# scorer

Every 60s: query Prometheus (E2E p90 / error breakdown per channel x model) -> score (EWMA smoothing) ->
adjust deployment weight via the LiteLLM Management API. Full algorithm in docs/architecture.md §3.

Tech stack: Python 3.12 + httpx + prometheus-client; state in Redis; single-replica Deployment.
Implementation checklist:
- [ ] scorer/config.py — all weight coefficients/thresholds configurable (env or ConfigMap)
- [ ] scorer/prom.py — PromQL query wrapper
- [ ] scorer/scoring.py — pure functions: metrics -> scores -> weights (unit tests cover circuit breaker/floor/hysteresis branches)
- [ ] scorer/litellm_client.py — Management API wrapper
- [ ] scorer/main.py — main loop + own metrics exposure
- [ ] tests/ — unit tests for scoring functions and edge cases
