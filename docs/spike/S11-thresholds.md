# S11: loop thresholds

Status: proposed, unmeasured. Every value below is a proposal of the author (PRD A2, Q7). The calibration run is real but not representative: the model is the fake provider and the prompts are fixed words.

Run on `hv-hermes-test` (image `hv-hermes:spike`), 2026-10-18. Hermes v0.22.2 (2026.9.24), upstream commit `d923a5eb`. Every request carried `Authorization: Bearer ****`. The loop guard is `Packages/HermesAdapter/Sources/LoopGuard/LoopGuard.swift`. The token source is in [S10-tokens.md](S10-tokens.md).

## Proposed values

| Signal | PRD rule | Cold start (fewer than 20 turns of history) | After 20 turns | Status |
| --- | --- | --- | --- | --- |
| `repeated-tool-call` | the same tool call with the same arguments 3 times in a row | 3 | 3 | PRD value, unmeasured |
| `tool-count` | tool calls of the turn above 3 times the 95th percentile of the profile | 30 calls | 3 × p95 (nearest rank); stays 30 when p95 is 0 | proposal, unmeasured |
| `tokens` | tokens of the turn above 5 times the median of the profile | 500 000 total tokens | 5 × median, integer part of the product (a median of 101.5 gives 507, the half unit counts); stays 500 000 when the median is 0 or no turn has a count | proposal, unmeasured |
| `silence` | no new assistant message for X minutes | X = 300 s | 300 s | proposal, X unknown per Q7, unmeasured |

No data supports 30 calls or 500 000 tokens: they are round numbers chosen to stay far above the one tool call per turn seen in the calibration run. The cold start has no measured base by definition. The `measured=no` field of the probe output states this on every run.

X = 300 s rests on two facts and one risk:

- S1: a provider stuck in retries kept a run `running` for more than 3.5 minutes with no event.
- The keepalive comment every 10 s is not an assistant message, so it does not reset the clock.
- Risk: a foreground tool that runs longer than 300 s produces no assistant message and pauses the turn. The S3 tool `sleep 300` sits at the limit. A false pause costs one confirmation. Raise X if real turns show it often.

## Rules fixed by the implementation

These are not in the PRD. Each one is covered by a unit test.

- The identity of a tool call is the pair (`tool`, `preview`). The `run_events` stream carries no arguments (S1); `preview` is the argument summary of `tool.started`. Its length is capped by `display.tool_preview_length` (`agent/display.py:114`, 0 = unlimited in code; the gateway value was not read). Two different commands with the same capped preview count as the same call.
- A different tool call resets the repeat count. Assistant messages between two identical calls do not.
- Only a `message.delta` restarts the silence clock. Tool events do not. Before the first message the clock starts at the first event.
- The silence clock stops while an approval is pending and restarts when it is answered. A finished turn is never silent.
- A gap between two events of the stream counts as silence, so a replay of a captured stream finds the pause the live guard would have found.
- A history base of zero (no tool call in 20 turns, or no token count) keeps the cold start value. A relative rule on a zero base would pause on the first tool call or the first token.
- `tool-count` and `tokens` pause when the value is above the limit, not at it.
- Numbers from outside have bounds. The silence signal ignores a timestamp or an evaluation time that is not finite or lies beyond 10^15 s in absolute value; the other signals stay active. `hd-probe` rejects `--now` outside that range (exit 2) and a history count outside 0 to 10^12 (exit 1). A limit whose product overflows `Int` keeps the cold start value. The seconds in a `silence` cause are rounded up, so a pause never shows `seconds` equal to the limit.
- On stdin, `hd-probe` reads the clock again after every line and every 0.25 s. An open stream with no new message pauses at X without waiting for the end of the stream. `--now` freezes the clock for a replay.
- The guard returns advice and cancels nothing. With `cancel_run` available (S3) the remedy is `stop-run`: the app offers the stop and the user confirms. Without it the remedy is `suspend-display-and-send`: the app suspends display and send, notifies, and offers the kill switch.

## Calibration run (lane 10 of HD-05)

For each seeded profile `hv-bot-a` and `hv-bot-b`: 20 turns, one after the other. Turns 4, 8, 12, 16 and 20 sent `HV_TOOL_SLEEP go` and were stopped with `POST …/stop` once `tool.started` arrived. The 15 others sent `bonjour <n>`. The tool calls come from `tool.started` events and the token count from `usage.total_tokens` of the terminal event. The history files are [S11-history-hv-bot-a.json](S11-history-hv-bot-a.json) and [S11-history-hv-bot-b.json](S11-history-hv-bot-b.json).

| Profile | Turns | Terminal events | Tool calls per turn | p95 of tool calls | Token count per turn | Median tokens |
| --- | --- | --- | --- | --- | --- | --- |
| `hv-bot-a` | 20 | 15 `run.completed`, 5 `run.cancelled` | 15 × 0, 5 × 1 | 1 | 15 × 0, 5 × no count (cancelled) | 0 |
| `hv-bot-b` | 20 | 15 `run.completed`, 5 `run.cancelled` | 15 × 0, 5 × 1 | 1 | 15 × 0, 5 × no count (cancelled) | 0 |

Measured next to proposed:

| Value | Proposed (cold start) | From the measured history | Reading |
| --- | --- | --- | --- |
| `tool-count` limit | 30 | 3 (3 × p95 of 1) | not representative: the mix of turns is the author's, not a real workload. A real turn with 4 tool calls would pause on this history |
| `tokens` limit | 500 000 | 500 000 (median 0, cold start kept) | no token count above zero exists on this instance (S10) |
| `silence` X | 300 s | 300 s | no gap between assistant messages was timed in this run |

The run was repeated on 2026-10-19 on a new instance (Hermes 0.22.2, same fake provider, image `hv-hermes:hd05`): the two history files came out byte for byte identical to the committed ones, and `hv-bot-a` and `hv-bot-b` each held 20 sessions (15 with `tool_call_count` 0, 5 with 1). The capture is [hd05-calibration.png](hd05-calibration.png) and the raw text of the live pass is [hd05-live.txt](hd05-live.txt).

Both rows marked "not representative" stay proposals until a profile has 20 turns with a real provider (PRD Q7, option b1).

Cross check on `GET /p/<profile>/api/sessions` after the run: `hv-bot-b` held 20 sessions, 15 with `tool_call_count` 0 and 5 with 1. `hv-bot-a` held 23: the same 20 plus 3 runs of the S10 observation (a plain turn, an `HV_SLOW` turn and a stopped `HV_TOOL_SLEEP` turn).

## Probe output

```
$ hd-probe loop-guard --events Tests/LoopGuardTests/Fixtures/repeated-tool-call.sse --history docs/spike/S11-history-hv-bot-a.json
thresholds: basis=history turns=20/20 measured=no repeat=3 tool-calls=3 tokens=500000 silence=300s
tokens: disabled reason=no-usage-in-stream
pause cause=repeated-tool-call count=3
remedy: stop-run (cancel_run disponible, l'utilisateur confirme, le garde n'annule rien)

$ hd-probe loop-guard --events Tests/LoopGuardTests/Fixtures/normal-turn.sse --history Tests/LoopGuardTests/Fixtures/history-5-turns.json
thresholds: basis=cold-start turns=5/20 measured=no repeat=3 tool-calls=30 tokens=500000 silence=300s
tokens: active
continue
```

## Reproduce

```
curl -sS -X POST -H "Authorization: Bearer $HV_TEST_API_KEY" -H 'Content-Type: application/json' -d '{"input":"bonjour 0"}' http://127.0.0.1:18642/p/hv-bot-a/v1/runs
curl -sS -N -m 10 -H "Authorization: Bearer $HV_TEST_API_KEY" http://127.0.0.1:18642/p/hv-bot-a/v1/runs/<run_id>/events | swift run --package-path Packages/HermesAdapter hd-probe loop-guard --events -
```

Repeat the first command 20 times per profile, with `HV_TOOL_SLEEP go` on every fourth turn and a `POST …/stop` after `tool.started`, to rebuild the history files.
