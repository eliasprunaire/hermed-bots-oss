# S1: runs, events and terminal state

Status: observed. Feeds the contracts `send_message` and `run_events`.

Observed on `hv-hermes-test` (image `hv-hermes:spike`, base `nousresearch/hermes-agent:latest`), 2026-10-18. Hermes v0.22.2 (2026.9.24), upstream commit `d923a5eb487a17c0a68801bba9ef0f56c81040a8`, base image index digest `sha256:36099926da316742423544e055d4734777105ffe6341873af5459b957d0c2919`, arm64. The model is the fake provider (Q6 option s1). Every request carries `Authorization: Bearer ****`. The profile prefix `/p/hv-bot-a` is explained in [S7](S7-multiplexing.md).

## References

- Doc: [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server), table "Runs API". [Programmatic Integration](https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration), section "Run lifecycle".
- Code at `d923a5eb`: `gateway/platforms/api_server_runs.py:234` (`_http_routes`), `:620` (`_handle_runs`), `:1084` (events stream, `Last-Event-ID`), `:461` (202 admission response). `gateway/platforms/api_server.py:4488` (each route is also mounted under `/p/{profile}`).
- Captured requests and responses: below. They were taken with `curl` and a Python probe that timestamps each frame.

## Create a turn

```
POST /p/hv-bot-a/v1/runs
Content-Type: application/json

{"input":"bonjour hv"}

HTTP/1.1 202 Accepted
{"run_id": "run_2e7f3867da364e8a8f5050c798dfacb0", "status": "started", "replayed": false}
```

Optional body fields seen in the code and exercised here: `session_id` (continue a session, see S4 and S5), `model` (per request model, see S4). Optional header: `Idempotency-Key` (see S2). The run id doubles as the session id when no `session_id` is given.

## Follow the events

```
GET /p/hv-bot-a/v1/runs/run_2e7f3867da364e8a8f5050c798dfacb0/events

HTTP/1.1 200 OK
Content-Type: text/event-stream

: open

id: 0
data: {"event": "message.delta", "run_id": "run_2e7f…", "timestamp": 1792330255.66, "delta": "HV-FAKE-REPLY model=hv-fake-1 user_msgs=1", "seq": 0}

id: 1
data: {"event": "reasoning.available", "run_id": "run_2e7f…", "timestamp": 1792330255.66, "text": "HV-FAKE-REPLY model=hv-fake-1 user_msgs=1", "seq": 1}

id: 2
data: {"event": "run.completed", "run_id": "run_2e7f…", "timestamp": 1792330255.68, "output": "HV-FAKE-REPLY model=hv-fake-1 user_msgs=1", "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0, "cache_read_tokens": 0, "cache_write_tokens": 0}, "runtime": {"provider": "custom", "model": "hv-fake-1", "route_source": "global"}, …}

: stream closed
```

- Each frame has `id: N` (the same number as `seq` in the JSON, starting at 0) and one `data:` line holding a JSON object with the key `event`.
- Event names observed: `message.delta`, `reasoning.available`, `tool.started` (`tool`, `preview`), `tool.completed` (`tool`, `duration`, `error`, `preview`), `approval.request`, `run.completed`, `run.failed`, `run.cancelled`, `run.interrupted`.
- The server sends `: open` first, `: keepalive` every 10 s of silence, and `: stream closed` after the terminal event.
- The server does not close the connection after `: stream closed`. A client that waits for end of file stays blocked (observed: the read timed out after 60 s). The client has to stop at the terminal event.
- A subscriber that attaches after the run ended still receives the full backlog from `id: 0`.
- The stream is `text/event-stream` with no request body. Authentication is the bearer header.

## Poll the state

```
GET /p/hv-bot-a/v1/runs/run_2c6b…

{"object": "hermes.run", "run_id": "run_2c6b…", "status": "completed", "created_at": 1792330255.35, "updated_at": 1792330255.68, "session_id": "run_2c6b…", "model": "hermes-agent", "last_event": "run.completed", "output": "HV-FAKE-REPLY model=hv-fake-1 user_msgs=1", "usage": {…}, "runtime": {"provider": "custom", "model": "hv-fake-1", "route_source": "global"}, "completed": true, "partial": false, "interrupted": false}
```

## Terminal states observed

| State | How it arises | Terminal event | Status fields |
| --- | --- | --- | --- |
| `completed` | the model answers | `run.completed` | `completed: true` |
| `failed` | provider answers HTTP 400 (not retried) | `run.failed` after 0.8 s | `status: "failed"`, `error: "HTTP 400: hv fake provider failure"` |
| `cancelled` | `POST /v1/runs/{id}/stop` (S3) | `run.cancelled` with `turn_exit_reason: "interrupted_by_user"` | `interrupted: true`, `completed: false` |
| `interrupted` | the gateway restarted before the run settled (S2) | `run.interrupted` (status only after the restart) | `error: "The gateway restarted before this run settled."` |

Non terminal states seen: `running`, `waiting_for_approval` (`last_event: "approval.request"`), and the `stopping` answer of the stop route.

A provider HTTP 500 is retried by Hermes: the run stayed `running` for more than 3.5 minutes with no event (seen on an earlier build of the image whose fake provider answered 500; the final build answers 400). `POST …/stop` cancelled it in under 2 s. A client needs its own deadline.

## Approval, seen on the way

A tool that matches a danger pattern (here `python3 -c …`) pauses the run:

```
data: {"event": "approval.request", "request_id": "9816837a9119492499b3e40aac19a1e3", "command": "python3 -c \"…\"", "pattern_key": "script execution via -e/-c flag", "description": "script execution via -e/-c flag", "choices": ["once", "session", "always", "deny"], "allow_permanent": true, "allow_session": true, "run_id": "run_4e53…", "seq": 1}

POST /p/hv-bot-a/v1/runs/run_4e53…/approval
{"request_id":"9816837a9119492499b3e40aac19a1e3","choice":"once"}

HTTP/1.1 200 OK
{"object": "hermes.run.approval_response", "run_id": "run_4e53…", "choice": "once", "request_id": "9816837a9119492499b3e40aac19a1e3", "resolved": 1}
```

The doc names a third field, `execution_generation`. It was not needed here. `GET /v1/runs/{id}` returned `pending_controls: null` while the run waited, so the status did not carry the request. The request is in the event stream only.

## Other turn routes seen

- `POST /api/sessions/{id}/chat` answers once, without events: `{"object": "hermes.session.chat.completion", "session_id": …, "message": {"role": "assistant", "content": …}, "usage": …, "runtime": …}`.
- `POST /api/sessions/{id}/chat/stream` streams named SSE events (`event: run.started`, `message.started`, `assistant.delta`, … each with `seq`, `run_id`, `session_id`). Its vocabulary differs from `/v1/runs/{id}/events`: `assistant.delta` instead of `message.delta`. The terminal event of that stream was not captured here.
- `POST /v1/chat/completions` and `POST /v1/responses` were not observed.

## Timing

- `POST /v1/runs` answered in 5 to 12 ms.
- From the POST to the first event (`id: 0`), measured by the probe, which opens the stream after the POST: 748, 728, 719, 837 and 830 ms over five cycles (median 748 ms).

## Reproduce

```
export HV_TEST_API_KEY=$(openssl rand -hex 24)
.cursor/skills/verify-hermes-desktop/scripts/hv-hermes-env.sh up orb
curl -sS -H "Authorization: Bearer $HV_TEST_API_KEY" -H 'Content-Type: application/json' -d '{"input":"bonjour hv"}' http://127.0.0.1:18642/p/hv-bot-a/v1/runs
curl -sS -N -m 10 -H "Authorization: Bearer $HV_TEST_API_KEY" http://127.0.0.1:18642/p/hv-bot-a/v1/runs/<run_id>/events
```

Trigger words of the fake provider (`orb/fake-llm.py`): `HV_SLOW` streams for about 20 s, `HV_FAIL` returns HTTP 400, `HV_TOOL_SLEEP`, `HV_TOOL_DETACH` and `HV_TOOL_BG` call the `terminal` tool.
