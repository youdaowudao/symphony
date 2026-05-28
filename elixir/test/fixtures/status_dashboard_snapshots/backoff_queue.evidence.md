```text
╭─ SYMPHONY STATUS
│ Agents: 1/20
│ Throughput: 15 tps
│ Runtime: 45m 0s
│ Tokens: in 18,000 | out 2,200 | total 20,200
│ Rate Limits: gpt-5 | primary 0/20,000 reset 95s | secondary 0/60 reset 45s | credits none
│ Projects: enabled 0 / active 0
│ Tracker: n/a
│ Next refresh: n/a
├─ Running
│
│   ID             STAGE          PID      AGE / TURN   TOKENS     SESSION
│   ─────────────────────────────────────────────────────────────────────────────
│ ● MT-638         running        4242     20m 25s / 7      14,200 thre...567890
│   latest event: agent message streaming: waiting on rate-limit backoff window                     · 5 分钟前更新
│
├─ Backoff queue
│
│  ↻ MT-450 attempt=4 in 1.250s error=rate limit exhausted
│  ↻ MT-451 attempt=2 in 3.900s error=retrying after API timeout with jitter
│  ↻ MT-452 attempt=6 in 8.100s error=worker crashed restarting cleanly
│  ↻ MT-453 attempt=1 in 11.000s error=fourth queued retry should also render after removing the top-three limit
╰─
```
