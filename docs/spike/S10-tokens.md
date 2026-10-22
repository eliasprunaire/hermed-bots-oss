# S10: tokens per run

Status: observed. Feeds the token signal of the loop guard (HD-05). `run_events` gives a token count at the terminal event only. No count reaches the client while the turn runs.

Observed on `hv-hermes-test` (image `hv-hermes:spike`), 2026-10-18. Hermes v0.22.2 (2026.9.24), upstream commit `d923a5eb487a17c0a68801bba9ef0f56c81040a8`. The model is the fake provider (Q6 option s1). Every request carries `Authorization: Bearer ****`; the key is random and lives in the container only.

## References

- Doc: [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server) for `/v1/runs` and the run events.
- Code at `d923a5eb`, read in the container (`/opt/hermes`), not modified:
  - `gateway/platforms/api_server_runs.py:86` (`_USAGE_FIELDS`, comment "Terminal usage payload") and `:759` (`_run_usage`): the payload is read from the agent counters `session_prompt_tokens`, `session_completion_tokens`, `session_total_tokens`, `session_cache_read_tokens` and `session_cache_write_tokens`.
  - `:986`: `_finish(status, fields, output=…, usage=usage, runtime=…)` passes the counters to the terminal event when the agent returns.
  - `:93` (`_FIXED_EVENT_FIELDS`): `tool.started` carries `tool` and `preview`, `tool.completed` carries `tool`, `duration`, `error`, `preview`. No token field.
  - `gateway/platforms/api_server.py:2986` (`_session_response`): the session row exposes `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `reasoning_tokens` and `tool_call_count`.

## Result in one table

| Place | When it holds a value | Seen on this instance |
| --- | --- | --- |
| `run.completed`, field `usage` (`input_tokens`, `output_tokens`, `total_tokens`, `cache_read_tokens`, `cache_write_tokens`) | at the terminal event only | all five fields `0` |
| `run.cancelled`, `run.failed`, `run.interrupted` | not read in code; `run.cancelled` was captured | no `usage` key |
| `GET /p/{profile}/v1/runs/{run}`, field `usage` | `null` while the run is `running`; filled after `run.completed` | `null` on four polls 3 s apart during an `HV_SLOW` turn, then all fields `0` |
| `message.delta`, `reasoning.available`, `tool.started`, `tool.completed`, `approval.*` | never | no `usage` key |
| `GET /p/{profile}/api/sessions`, row fields `input_tokens`, `output_tokens` | session counters; whether they move during a turn with a real provider is not established | `0` during and after the turn |
| `GET /p/{profile}/api/sessions`, row field `tool_call_count` | moves during the turn | `1` one second after `tool.started`, while the run was `running` |

The fake provider reports `total_tokens: 2` in its non streaming answer (`orb/fake-llm.py:88`), yet every Hermes counter reads `0` on this instance. The cause was not investigated. No token value above zero was observed, so no figure here is a measured token count.

## What this means for the guard

This is a record. The implementation follows from it.

- The token source for a turn in progress is absent. The only count is `usage.total_tokens` on the terminal event.
- `LoopGuard.evaluate` reads `usage.total_tokens` from any event that carries it. With Hermes 0.22.2 the stream has none until the end, so the report shows `tokens: disabled reason=no-usage-in-stream`. The other three signals stay active.
- A tokens pause computed on the terminal event comes after the turn. It tells the user the cause. It cannot stop that turn.
- The history of a profile takes `usage.total_tokens` of each terminal event as the token count of one turn. A cancelled turn has no `usage`, so its count is `null` and the median skips it.
- Not established: whether `usage` counts one run or the whole session. The agent counters are named `session_*`. The fake provider cannot tell.
- Not established: whether the session counters move during a turn with a real provider. A polling source on `GET /api/sessions` is possible only if they do. The guard does not poll.

## Reproduce

```
curl -sS -X POST -H "Authorization: Bearer $HV_TEST_API_KEY" -H 'Content-Type: application/json' -d '{"input":"HV_SLOW go"}' http://127.0.0.1:18642/p/hv-bot-a/v1/runs
curl -sS -H "Authorization: Bearer $HV_TEST_API_KEY" http://127.0.0.1:18642/p/hv-bot-a/v1/runs/<run_id>
curl -sS -H "Authorization: Bearer $HV_TEST_API_KEY" http://127.0.0.1:18642/p/hv-bot-a/api/sessions
docker exec hv-hermes-test grep -n "usage" /opt/hermes/gateway/platforms/api_server_runs.py
```

Poll the second command every 3 s during the turn. `usage` is `null` until the run is `completed`.
