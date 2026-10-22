# S5: list the past sessions of a profile and reopen one

Status: observed. Feeds `list_sessions`.

Observed on `hv-hermes-test` (image `hv-hermes:spike`), 2026-10-18. Hermes v0.22.2 (2026.9.24), upstream commit `d923a5eb487a17c0a68801bba9ef0f56c81040a8`. The model is the fake provider (Q6 option s1). Every request carries `Authorization: Bearer ****`.

## References

- Doc: [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server), table "Session endpoints": `GET /api/sessions` accepts `limit`, `offset`, `source`, `include_children`. The doc also says API sessions cannot bind a session owned by another surface (CLI, TUI, Desktop, ACP, messaging): HTTP 409 `permission_denied`. [Programmatic Integration](https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration) documents listing only for the TUI gateway (`session.list`).
- Code at `d923a5eb`: `gateway/platforms/api_server.py:3066` (`_handle_list_sessions`), route table `:1718`.

## List

```
GET /p/hv-bot-a/api/sessions?limit=3&offset=0
HTTP/1.1 200 OK
{"object": "list", "data": [ {session}, {session}, {session} ], "limit": 3, "offset": 0, "has_more": <bool>}
```

One entry of `data`:

```
{"id": "run_8f44ca45dab94e098821d727257cd7a0", "source": "api_server", "user_id": null, "model": "hv-fake-1", "title": "HV-FAKE-REPLY model=hv-fake-1 user_msgs=1 #2", "started_at": 1792331163.4, "ended_at": null, "end_reason": null, "message_count": 2, "tool_call_count": 0, "input_tokens": 0, "output_tokens": 0, "last_active": 1792331165.43, "preview": "HV_SLOW go", "pinned": false, "archived": false, "hidden": false, "has_system_prompt": true, "has_model_config": true, "is_internal_child": false, "parent_session_id": null, …}
```

- The list is ordered by most recent activity first.
- `GET /api/sessions` is scoped to the profile of the prefix: with 14 sessions created through `/p/hv-bot-a`, the prefixes `/p/hv-bot-b`, `/p/cyber` and the unprefixed default profile each listed one session (made by the S7 probe).
- The `source` of an entry says which surface created the session. Runs made through the API have `api_server`. A session made with `hermes -p hv-bot-a chat -q "…"` inside the container has `oneshot` (id `20261018_134700_18375c`) and is listed without any filter. `?source=api_server` returned the API sessions, `?source=cli` returned none, `?source=oneshot` returned the one.
- The sessions of the Telegram, TUI, Desktop or other messaging surfaces were not created here, so their `source` values and the 409 of the doc were not observed.

## Reopen

```
GET /p/hv-bot-a/api/sessions/run_8f44ca45dab94e098821d727257cd7a0
{"object": "hermes.session", "session": {…same fields as a list entry, without "preview"…}}

GET /p/hv-bot-a/api/sessions/run_8f44ca45dab94e098821d727257cd7a0/messages
{"object": "list", "session_id": "run_8f44…", "data": [
  {"id": 13, "role": "user", "content": "HV_SLOW go", "timestamp": 1792331163.4, "tool_calls": null, "tool_name": null, "finish_reason": null, …},
  {"id": 14, "role": "assistant", "content": "slow0 slow1 … slow19", "finish_reason": "stop", …} ],
 "pagination": {"limit": 500, "offset": 0, "order": "latest", "returned": 2}}
```

- The message `id` is a database row number across the profile, not an index inside the session.
- The messages route takes `include_compacted` and `inline_images` (doc), not exercised.
- The transcript of a turn cut by a gateway restart holds the user message only (see S2).

## Continue a reopened session

```
POST /p/hv-bot-a/v1/runs   {"input":"suite apres reouverture","session_id":"run_8f44…"}
-> reply "HV-FAKE-REPLY model=hv-fake-1 user_msgs=2"
GET  …/messages -> [("user","HV_SLOW go"), ("assistant","slow0 slow1 slow2 slow3 …"), ("user","suite apres reouverture"), ("assistant","HV-FAKE-REPLY model=hv-fake-1 user_msgs=2")]
```

The same worked on the `oneshot` session (`/v1/runs` and `/api/sessions/{id}/chat`, both answered, no 409).

The sessions survived `docker restart hv-hermes-test`: the list after the restart still held the sessions made before it (they live in the container volume).

## Reproduce

```
curl -sS -H "Authorization: Bearer $HV_TEST_API_KEY" 'http://127.0.0.1:18642/p/hv-bot-a/api/sessions?limit=5'
curl -sS -H "Authorization: Bearer $HV_TEST_API_KEY" http://127.0.0.1:18642/p/hv-bot-a/api/sessions/<session_id>/messages
```
