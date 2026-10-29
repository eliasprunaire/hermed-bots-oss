# PR-1: write routes behind the facade (step 2 of the spike)

Status: done on 2026-10-29, on a **test instance only**. No production Hermes was touched, inventoried or written to.

PR-0 ([pr0-api-feasibility.md](pr0-api-feasibility.md)) deferred the single write to PR-1. This note records which routes carry the writes of the product (send a prompt, approve, cancel), what the facade does with them, and what was not proven.

## Test instance

| Item | Value |
| --- | --- |
| Software | `hermes serve` 0.22.5, built from tag `v0.22.5` (commit `bf0203a794a07aac3ff764972ab9087baa4e4f4e`) of the public repository |
| Data | an empty throwaway data directory, deleted after the run |
| Network | bound to the loopback only |
| Credential | a throwaway process-wide session token (`HERMES_DASHBOARD_SESSION_TOKEN`), valid for that process only |
| Model provider | none configured. Turns fail inside Hermes, which is enough to prove the routes and costs nothing |

## Where the writes are

The writes are **not** REST routes. `hermes serve` carries them on one JSON-RPC WebSocket, `/api/ws`, the gateway the desktop app uses. The REST surface under `/api/sessions` is read and administration.

| Product action | JSON-RPC method | Request parameters | Reply on the test instance |
| --- | --- | --- | --- |
| New session | `session.create` | none | `result.session_id` (live id), `result.stored_session_id` (stored id) |
| Send a prompt | `prompt.submit` | `session_id`, `text` | `result.status` is `streaming` with `user_row_id`, or `queued` when a turn already runs |
| Approve or deny a tool | `approval.respond` | `session_id`, `choice`, optional `request_id`, `all` | `result.status` (`resolved` or `expired`); error `5032` while no model provider is connected |
| Cancel the turn | `session.interrupt` | `session_id` | `result.status` is `interrupted` |
| Read pending approvals | `approval.pending` | `session_id` | error `5032` while no provider is connected. The success shape (`approvals`) comes from the code read, not from a live call |

Reads that the product needs are `session.list`, `session.most_recent`, `session.active_list`, `session.resume`, `session.events.since`, `session.events.stats`, `ping`, and the REST routes `GET /api/sessions`, `/api/sessions/search`, `/api/sessions/stats`, `/api/sessions/{id}`, `/messages`, `/messages/around`, `/timeline`.

## What the run showed

1. The credential is accepted as `X-Hermes-Session-Token` or `Authorization: Bearer` on REST, and as the `token` query parameter on the WebSocket. The facade holds it. A device never sees it.
2. Hermes validates parameters strictly. An unknown key is refused with error `4000` ("Extra inputs are not permitted"). The facade therefore strips `idempotency_key` before it forwards a write.
3. Hermes is **not idempotent**. Two identical `prompt.submit` calls on one session gave `streaming` for the first and `queued` for the second: the prompt would run twice. The idempotency belongs to the facade.
4. `session.interrupt` and `approval.respond` accept a live session id from a second connection. A write is not bound to the connection that opened the session. The facade scopes idempotency keys by device, not by socket, so a retry on a new connection is replayed.
5. The same socket exposes `shell.exec`, `cli.exec`, `config.set`, `vault.*`, `connectors.*`, `slash.exec` and about a hundred more methods. The facade serves an allowlist and refuses the rest, for every role.
6. `GET /api/status` returns install paths and an installation identifier. The facade does not serve it. `GET /facade/status` answers with four fields.
7. **Risk.** The root page of the headless backend, `GET /`, needs no credential and writes the process session token into the page (`window.__HERMES_SESSION_TOKEN__`). Whoever can open the Hermes port gets the credential, and with it every write route and the shell methods. The facade does not remove that. It keeps Hermes off every interface but the loopback (it refuses to start otherwise, see `check-exposure`), and it serves nothing outside its allowlist. Any process of a user who has a shell on the host can still read the token, so the host must be single-purpose and the Hermes port must stay closed to the network.

## What this run does not prove

- A real turn with a model provider, so the tool-approval round trip (`approval.respond` with a live `request_id`) was not run end to end. The route and its error path are proven, the successful `resolved` reply is not.
- The gated mode (non-loopback bind, provider login). The facade targets the loopback mode.
- `/model` and `/new` from the product, which map to methods this note does not allow yet (`config.set`, `slash.exec`).
- Behaviour across a Hermes restart. The facade marks an in-flight write as unknown when Hermes drops the socket, and never runs it again.

## Reproduce

```
hermes serve --port <test port>        # on a throwaway data directory, loopback only
HERMES_TEST_PORT=<test port> HERMES_TEST_TOKEN=<throwaway token> HERMES_TEST_HOME=<throwaway data directory> node facade/testkit/live-smoke.js
```

The script starts the facade with a generated internal CA, enrolls devices, and prints one `PASS` or `FAIL` line per check. It prints no credential.

**Guard.** The script writes only to a disposable instance, and it checks that before any write. The operator marks the throwaway data directory by creating the file `.hermed-bots-disposable` in it with the text `disposable test instance, writes allowed` and a newline. The script then reads `GET /api/status` (a read) and requires the instance to report that same directory. With no marker, a wrong marker text, a missing report or a different directory, it stops with `refusing to write` and has sent nothing but that one read.
