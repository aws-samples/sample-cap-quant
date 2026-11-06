# aigw-scorer

Quality-based traffic weighting for the Envoy AI Gateway, ported from the TPP scorer. Every 60 s it reads the
trailing window from Prometheus, scores each channel (model × backend) against the other channels of the same
model, and patches `backendRefs[].weight` in the AIGatewayRoute. Not on the request path: if it dies, weights freeze.

```
score_lat = 0.6 · (best_ttft_p90 / ttft_p90) + 0.4 · (best_e2e_p90 / e2e_p90)      relative, within the model
score_err = exp(−8 · weighted_error_rate)                                           every upstream error = severity 3.0
q_raw     = 0.35 · score_lat + 0.65 · score_err
q         = 0.3 · q_raw + 0.7 · q_prev                                              EWMA, state in Redis
weight_i  ∝ prior_i · q_i²   floored at 5 %, renormalized                           prior = configured split (90/10)
```

Rules: < 5 requests in the window → keep the old score and never *gain* share; weighted error rate > 50 % → breaker
opens, channel keeps a 1 % probe share; 3 consecutive rounds under 10 % error → breaker closes; write back only
when a weight moves more than 2 pp. Breaker here is minute-level and global; Envoy's outlier detection
(`13-backend-traffic-policy.yaml`) is the second-level layer in front of it.

Differences from TPP: TTFT is part of the latency score; the configured weights act as a prior (equal quality keeps
90/10 instead of drifting to 50/50 — prompt cache is per Region); only one error class exists because gen_ai_*
metrics carry no status code per channel.

Metrics on :9100: `scorer_quality_score`, `scorer_weight`, `scorer_circuit_open`, `scorer_p90_ttft_seconds`,
`scorer_error_rate`, `scorer_last_success_timestamp`, `scorer_cycles_total`, `scorer_weight_writes_total`.

Pause (freeze weights): `kubectl -n scorer scale deploy/scorer --replicas=0`. Reset state: delete `scorer:*` keys in Redis.

```bash
pip install -e '.[dev]' && pytest -q                 # unit tests
scripts/deploy.sh scorer                            # build/push image, deploy
```
