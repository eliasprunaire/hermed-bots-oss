# Hermes product API

This folder holds the contract of the API that Hermed Bots clients (Mac, iOS) use to read and write on a Hermes instance. The clients talk to the TLS facade of `scripts/hermes-facade.js` (PR-1). The facade forwards an allowlist of Hermes routes to a Hermes that listens on the host loopback only.

| File | Content |
| --- | --- |
| `hermes-product.openapi.json` | The contract, OpenAPI 3.1. 14 Hermes routes (reads and writes) and 4 facade routes (enrolment and devices) |
| `README.md` | This guide, with examples |
| `../../test/hermes-api-contract.test.js` | The contract tests. They call every route through the facade with a fake Hermes and fail when the contract and the facade differ |

Run the tests with `npm test`, or `node --test test/hermes-api-contract.test.js` for this file alone.

## One bot, one profile

One Hermed bot is one named Hermes profile. The bot id is the name of the profile, the same string. It is the `{profile}` segment of every product path:

```
/p/{profile}/health
/p/{profile}/v1/runs
/p/{profile}/api/sessions/{session_id}/chat
```

The profile `default` is a profile like any other (`/p/default/v1/runs`). A bot has no other address. The facade also forwards the unprefixed routes as an alias of `default`. Clients do not use them.

The API does not list the profiles. The client knows its bots from its own settings. A profile that Hermes does not serve answers 404 on `GET /p/{profile}/v1/models`.

## Who holds which secret

| Secret | Held by | Never seen by |
| --- | --- | --- |
| Hermes API key of each profile | The facade, from its environment | Every client, every example, every answer |
| Device token | The device that enrolled | Hermes (the facade replaces the authorization on each request) |
| Enrolment code | An admin, then the device that redeems it once | Hermes |

A client never holds the Hermes API key. A device sends only its own token. If Hermes rejects the key of the facade, the device gets 502 `upstream_rejected`, not the Hermes answer.

## Connect

The facade answers TLS 1.3 only, with a certificate from an internal CA. The device trusts that CA and pins the public key of the server certificate. The CA certificate and the pin reach the device with the enrolment code, outside the facade. Placeholders below: `<facade-host>`, `<facade-port>`, `<ca.crt>`, `<pin>`.

```
FACADE=https://<facade-host>:<facade-port>
TLS="--cacert <ca.crt> --pinnedpubkey sha256//<pin>"
```

Enrol once. The code is valid 5 minutes and works once.

```
curl $TLS -X POST $FACADE/facade/enrol -H 'Content-Type: application/json' -d '{"code":"<enrolment code>","name":"phone"}'
```

```
{"device_id":"<device id>","role":"normal","token":"<device id>.<secret>"}
```

The token is shown once. Store it in the system keychain. Every other request carries it:

```
TOKEN=<device token>
curl $TLS -H "Authorization: Bearer $TOKEN" $FACADE/p/<profile>/health
```

An admin creates codes (`POST /facade/enrol-codes`), lists devices (`GET /facade/devices`) and revokes a device (`POST /facade/devices/{device_id}/revoke`). A revoked token is refused on the next request and its open event streams are cut within one second.

## Read

```
curl $TLS -H "Authorization: Bearer $TOKEN" "$FACADE/p/<profile>/api/sessions?limit=20&offset=0"
curl $TLS -H "Authorization: Bearer $TOKEN" $FACADE/p/<profile>/api/sessions/<session id>/messages
curl $TLS -H "Authorization: Bearer $TOKEN" $FACADE/p/<profile>/v1/runs/<run id>
```

The query of a read passes to Hermes. A query with a character outside `A-Za-z0-9_.~%+,=&:-` or over 512 characters gets 400 `invalid_query`. The query of a write is dropped.

## Write, with an idempotency key

Every write is a `POST` and needs `Idempotency-Key`: 1 to 128 visible ASCII characters, new for each write, reused only to retry the same write.

```
curl $TLS -X POST $FACADE/p/<profile>/v1/runs \
  -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: send-0001' \
  -H 'Content-Type: application/json' -d '{"input":"Hello"}'
```

```
HTTP/1.1 202
{"run_id":"<run id>","status":"started","replayed":false}
```

Follow the run:

```
curl $TLS -N -H "Authorization: Bearer $TOKEN" -H 'Last-Event-ID: 4' $FACADE/p/<profile>/v1/runs/<run id>/events
```

| Write | Route | Body |
| --- | --- | --- |
| Start a turn | `POST /p/{profile}/v1/runs` | `{"input": "...", "session_id": "...", "model": "..."}` (`session_id` and `model` are optional) |
| Answer an approval | `POST /p/{profile}/v1/runs/{run_id}/approval` | `{"request_id": "...", "choice": "once"}` (`once`, `session`, `always` or `deny`) |
| Cancel a turn | `POST /p/{profile}/v1/runs/{run_id}/stop` | none |
| Create a session | `POST /p/{profile}/api/sessions` | `{}` |
| Lock the model of a session | `POST /p/{profile}/api/sessions/{session_id}/model` | `{"model": "..."}` |
| Send a prompt and read the whole answer | `POST /p/{profile}/api/sessions/{session_id}/chat` | `{"input": "..."}` |

## What the key guarantees

The facade keeps one record per key for 24 hours, per device, method and path. It writes the record before the request leaves for Hermes.

| Situation | Answer |
| --- | --- |
| First send | The answer of Hermes |
| Same key, same body, after the first answer | The kept answer, same status and body, header `Idempotency-Replayed: true`. Hermes is not called |
| Same key, another body, the record holds the fingerprint of the first body | 409 `idempotency_key_conflict` |
| Same key, first answer over 16 KiB | 409 `idempotency_replay_unavailable` |
| Same key, the first send is still running | One Hermes call. Both sends get the same answer |
| The outcome is unknown: the connection broke or timed out after the request left, or Hermes answered 5xx | The first send gets the 5xx of Hermes, or 502 `write_outcome_unknown`. The same key then gets 502 `write_outcome_unknown` and is never sent again |
| The record is damaged and holds no fingerprint | 502 `write_outcome_unknown` for any body |
| Hermes certainly did not run the write: connection refused, Hermes 401 or redirect | 502 `upstream_unavailable`, `upstream_rejected`, `upstream_redirect`. The key stays free: send it again |
| Hermes answered 408 or 429 | The answer and its `Retry-After`. The key stays free |
| The journal holds 10 000 keys | 503 `idempotency_journal_full` for a new key. A live key still replays |

The id of a write is the id in its answer: `run_id` for a run, `session.id` for a session. A replay returns the same id. The facade has no lookup from a key to its answer.

After `write_outcome_unknown`, do not send the same key again. Read the state on Hermes (`GET /p/{profile}/v1/runs/{run_id}`, `GET /p/{profile}/api/sessions/{session_id}/messages`). If the write did not happen, send it again with a new key. For `POST /v1/runs` the client has no `run_id` in that case: list the sessions of the bot, read the last messages, then decide.

## Errors

The facade writes its own errors as `{"error": "<code>"}`. Hermes answers other than 401 and redirects pass through with their status and body.

| Status | Code | When |
| --- | --- | --- |
| 400 | `idempotency_key_required`, `idempotency_key_invalid`, `invalid_query`, `invalid_json`, `invalid_role` | The request is not valid |
| 401 | `invalid_token` | No valid token. Every path answers the same |
| 403 | `forbidden`, `invalid_code` | The role is not admin, or the enrolment code is unknown, used or expired |
| 404 | `route_not_allowed` | The facade does not forward the route. `POST .../chat/stream`, `/api/config`, `/api/env`, `/auth/*` and the dashboard are in this case |
| 404 | `unknown_device`, `not_found` | Management routes |
| 404 | Hermes body | Unknown or parked profile, `session_not_found`, `run_not_found` |
| 405 | `method_not_allowed` | The route exists for another method |
| 408 | Hermes body | Hermes did not run a write. Header `Retry-After` when Hermes sends it. The key stays free: send it again after the delay |
| 409 | `idempotency_key_conflict`, `idempotency_replay_unavailable` | See "What the key guarantees" |
| 413 | `body_too_large` | Body over 1 MiB (4 KiB on enrolment) |
| 429 | `rate_limited`, or a Hermes body | Over the limit. Header `Retry-After` in seconds |
| 500 | `internal_error` | A fault of the facade |
| 502 | `upstream_unavailable`, `upstream_timeout`, `upstream_rejected`, `upstream_redirect`, `upstream_key_missing`, `write_outcome_unknown` | Hermes did not give a usable answer |
| 503 | `idempotency_journal_full` | The facade keeps no new key |

Limits per device: 20 requests per second with a burst of 60, and 5 writes per second with a burst of 20. A failed authentication counts per address: 10 per minute.

## Out of the contract

- `POST /api/sessions/{session_id}/chat/stream`: a streamed answer cannot be replayed for an idempotent retry. Use `session.chat` or `run.create` with `run.events`.
- A WebSocket or JSON-RPC bridge, `/api/config`, `/api/env`, `/auth/*` and the dashboard.
- A list of the profiles. Hermes has no route for it.
- A lookup from an idempotency key to its operation.

## Keep the contract and the facade together

The test file compares the operation ids of the contract with `ROUTES` in `scripts/hermes-facade.js`, one by one. It calls every route through the facade and checks that each status and each JSON body is declared in the contract. Add a route to the facade without the contract, or the other way round, and `npm test` fails.

The response bodies of Hermes in the contract come from the observations in `docs/spike/` (Hermes 0.22.2). They name the fields that the Mac client reads and leave the others open. The tests do not call a real Hermes.
