# S4: `/model` and `/new` through the API

Status: observed, with one difference from the PRD wording. The text commands `/model` and `/new` are not interpreted by the API server. Dedicated routes do the same jobs. Feeds `set_model` and `new_session`.

Observed on `hv-hermes-test` (image `hv-hermes:spike`), 2026-10-18. Hermes v0.22.2 (2026.9.24), upstream commit `d923a5eb487a17c0a68801bba9ef0f56c81040a8`. The model is the fake provider (Q6 option s1): its reply names the model it was asked for, which makes the held model visible. Two models exist there, `hv-fake-1` (the profile default) and `hv-fake-2`. Every request carries `Authorization: Bearer ****`.

## References

- Doc: [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server): "Model selection: `model`, `provider`, and `model_options` can be set per request on the chat, responses, runs, and session-chat endpoints", and the session table (`POST /api/sessions`). [Programmatic Integration](https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration): `/model` is documented through the TUI gateway RPC `command.dispatch`, `/new` is not mentioned for the API server.
- Code at `d923a5eb`: `gateway/platforms/api_server.py:3773` (`_handle_session_model_lock`), `:2100` to `:2125` (the lock is read and the route source becomes `session_model_lock`), `:3570` (`_handle_session_chat`), `:3121` (`_handle_create_session`). `GET /v1/capabilities` lists `session_model_lock: true` and `session_resources: true`.

## `/new`: an empty session

```
POST /p/hv-bot-a/api/sessions   {}
HTTP/1.1 201 Created
{"object": "hermes.session", "session": {"id": "api_1792330365_9618ddbc", "source": "api_server", "model": null, "title": null, "message_count": 0, "has_system_prompt": false, "has_model_config": false, …}}

GET /p/hv-bot-a/api/sessions/api_1792331267_fb879fe3/messages
{"object": "list", "session_id": "api_1792331267_fb879fe3", "data": [], "pagination": {"limit": 500, "offset": 0, "order": "latest", "returned": 0}}
```

The new session is empty (0 messages, no model) and appears in `GET /api/sessions`. The first turn on it goes through `POST /v1/runs` with `session_id`, or through `POST /api/sessions/{id}/chat`.

## `/model`: the session lock

```
POST /p/hv-bot-a/api/sessions/api_1792331267_fb879fe3/model   {"model":"hv-fake-2"}
HTTP/1.1 200 OK
{"object": "hermes.session.model_lock", "session_id": "api_1792331267_fb879fe3", "runtime": {"provider": "", "model": "hv-fake-2", "route_source": "raw_request", "requested": {"provider": "", "model": "hv-fake-2"}, "model_lock": "accepted"}}
```

Effect of the lock, with a second session `api_1792331268_69b773f2` that was never locked:

| Turn | Model that answered | `route_source` |
| --- | --- | --- |
| `POST /api/sessions/{locked}/chat` | `hv-fake-2` | `session_model_lock` |
| `POST /api/sessions/{other}/chat` | `hv-fake-1` | `global` |
| `POST /v1/runs` with `session_id` of the locked session | `hv-fake-1` | `global` |

- The model holds on that session only. The other session and the profile default (`default: hv-fake-1` in `profiles/hv-bot-a/config.yaml`, unchanged) keep their model.
- The lock is applied by the session chat routes. `POST /v1/runs` ignores it in this version, even with the `session_id` of a locked session.
- `GET /api/sessions/{id}` shows `"model": "hv-fake-2"` after the lock.

## Model per request

```
POST /p/hv-bot-a/v1/runs   {"input":"avec model","model":"hv-fake-2"}
-> output "HV-FAKE-REPLY model=hv-fake-2 user_msgs=1"   runtime {"provider": "custom", "model": "hv-fake-2", "route_source": "raw_request"}

POST /p/hv-bot-a/v1/runs   {"input":"sans model","session_id":"<same run id>"}
-> output "HV-FAKE-REPLY model=hv-fake-1 user_msgs=2"   runtime {"provider": "custom", "model": "hv-fake-1", "route_source": "global"}
```

A `model` field on a run applies to that run only. It is not sticky for the next run of the session, although `GET /api/sessions/{id}` then reports `"model": "hv-fake-2"`.

## The text commands

`/model hv-fake-2` and `/new` were sent as `input` to `POST /v1/runs` and to `POST /api/sessions/{id}/chat`. The fake provider log shows both reached the model as ordinary user text (`last_role=user user='/model hv-fake-2'`), the session grew (`msgs=4`, then `msgs=6`), and the model did not change.

## Reproduce

```
curl -sS -X POST -H "Authorization: Bearer $HV_TEST_API_KEY" -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:18642/p/hv-bot-a/api/sessions
curl -sS -X POST -H "Authorization: Bearer $HV_TEST_API_KEY" -H 'Content-Type: application/json' -d '{"model":"hv-fake-2"}' http://127.0.0.1:18642/p/hv-bot-a/api/sessions/<session_id>/model
curl -sS -X POST -H "Authorization: Bearer $HV_TEST_API_KEY" -H 'Content-Type: application/json' -d '{"input":"hello"}' http://127.0.0.1:18642/p/hv-bot-a/api/sessions/<session_id>/chat
```
