# PR-1: Hermes authentication and TLS facade

Status: implemented in `scripts/hermes-facade.js`, tested by `test/hermes-facade.test.js` (29 tests) and by a live pass on the dedicated test instance on 2026-10-29. Step 2 of the PR-0 spike (the write routes) is done here, on the test instance only. No production Hermes was touched.

The facade is the answer of PR-0 to a target with no TLS, no per-device token and no operator revocation. It terminates TLS, authenticates one token per device, and talks to Hermes over the host loopback only. The Hermes credentials never leave the facade process.

## Decisions of the user, applied

| Decision | Where it is applied |
| --- | --- |
| Facade route | one Node file, no dependency but `openssl` for the certificates |
| Step 2 of the spike included | the write routes below, observed through the facade |
| TLS option (a): dedicated internal CA, server certificate pinned by the clients | `init-tls` creates the CA and the server certificate. `pinnedTlsOptions` is the client rule: the CA is the only anchor and the SPKI hash of the server certificate has to match the pin |
| One-time enrolment code, short life | 5 minutes, single use |
| Opaque per-device tokens, immediate revocation, admin and normal roles, UTC audit, rate limit | see the table of values |
| The Hermes dashboard stays reachable on the host only | the facade refuses any upstream that is not the loopback, forwards no dashboard route, and `check-local` tests the port from the host |

## Values fixed in this PR

| Value | Setting |
| --- | --- |
| Enrolment code | 12 characters from a 32 letter alphabet (60 bits), valid 5 minutes (`ENROL_CODE_TTL_MS`), single use (the file is renamed, so one of two concurrent uses wins), stored as a SHA-256 hash. An unknown, expired or used code gets the same answer (403 `invalid_code`) |
| Device token | `<device id>.<secret>`, 256 bit secret, stored as a SHA-256 hash, no expiry. Only a revocation ends it |
| Roles | `admin`: Hermes routes, list devices, create enrolment codes, revoke a device. `normal`: Hermes routes |
| TLS | 1.3 only. ECDSA P-256. Server certificate 365 days, CA 10 years. The server key is kept at renewal, so the pin stays |
| Pin | base64 SHA-256 of the server public key (SPKI) |
| Rate limits | per device 20 requests per second with a burst of 60. Writes 5 per second with a burst of 20. Failed authentication 10 per minute per address, enrolment 5 per minute per address and 30 per minute in total. Answer 429 with `Retry-After` |
| Idempotency | a write needs `Idempotency-Key` (1 to 128 visible ASCII characters). One file per key in the journal (`<data>/idempotency`), kept 24 hours, at most 10 000 keys. A full journal refuses a new key (503 `idempotency_journal_full`) and never forgets a live one. See "Idempotency journal" |
| Limits | request body 1 MiB, upstream timeout 30 s |
| Audit | one JSON line per event in `audit.log`, time in UTC (`Z`). It holds device ids, roles, routes and statuses. It holds no token, code or Hermes key. A failed authentication is written until its address reaches the limit. The 429 answers given before authentication are not written, so a flood of bad tokens cannot fill the disk. The CLI commands `revoke` and `enrol-code` append their own line (`source: "cli"`) to the same file |

## How it works

```
 device ---TLS 1.3, pinned CA---> facade ---HTTP, host loopback only---> Hermes
   token per device                 | role, rate limit, allowlist,        (own key, never
                                    | idempotency, audit                   seen by the device)
```

1. The operator runs `init-tls` once, then `enrol-code admin`. The device receives the code, the CA certificate and the pin through a channel outside the facade.
2. The device enrols with `POST /facade/enrol` over TLS validated by that CA and that pin. It gets `{device_id, role, token}` once.
3. Every other request carries `Authorization: Bearer <token>`. Without a valid token the answer is 401 for every path, so a path cannot be probed.
4. The facade checks the role and the limits, matches the route against the allowlist, replaces the authorization with the Hermes key of the profile, and forwards. The answer keeps only `content-type`, `cache-control`, `retry-after`, `idempotency-replayed` and the `content-length` of a buffered answer.
5. An upstream 401 or redirect becomes 502 (`upstream_rejected`, `upstream_redirect`): a device never reads a Hermes credential error or a Hermes address.

The device and the Hermes key: `FACADE_UPSTREAM_KEY` is the key of the unprefixed routes **and the fallback of every profile that `FACADE_UPSTREAM_KEYS` does not list**. `FACADE_UPSTREAM_KEYS` (JSON) gives one key per `/p/<profile>/` prefix. The facade fails closed (502 `upstream_key_missing`) only when no key applies: no `FACADE_UPSTREAM_KEY` and no entry for the profile. To give each profile its own key and nothing else, set `FACADE_UPSTREAM_KEYS` alone. The key goes to Hermes on the loopback and never to a device.

## Routes behind the facade (step 2 of the spike)

Observed on the test instance (the API server platform of Hermes 0.22.2, fake model provider, zero cost) through the facade, with a normal device, on the unprefixed routes and on a `/p/hv-bot-a/` profile. Every write needs a key. Hermes keeps a durable key on `/v1/runs` only, so the facade deduplicates the others itself.

| Route | Use in the product | Observed through the facade | Deduplicated by |
| --- | --- | --- | --- |
| `POST /v1/runs` | send a prompt | 202 `{run_id, status: "started"}`. Same key and body: 202, `Idempotency-Replayed: true`, same `run_id`. Same key, other body: 409 `idempotency_key_conflict`. No key: 400 `idempotency_key_required` | Hermes (the key is sent as `<device id>:<key>`) and the facade |
| `POST /v1/runs/{id}/approval` | answer an approval | 200 `{resolved: 1, choice: "deny"}`. Replay: same body, `Idempotency-Replayed: true` | the facade |
| `POST /v1/runs/{id}/stop` | cancel a turn | 200 `{status: "stopping"}`, then `run.cancelled`, run status `cancelled`, no `sleep 300` process left in the container. Replay: same body | the facade |
| `POST /api/sessions` | new session | 201 with the session id. Replay: same session id | the facade |
| `POST /api/sessions/{id}/model` | model lock | 200 `model_lock: accepted` | the facade |
| `POST /api/sessions/{id}/chat` | send a prompt that honors the lock | 200, model `hv-fake-2`, `route_source: session_model_lock`. Send plus replay left one user message in the session | the facade |
| `GET /v1/runs/{id}/events` | follow a turn | streamed as Hermes produces it (`message.delta`, `reasoning.available`, `approval.request`, `tool.started`, `run.completed`, `run.cancelled`). `Last-Event-ID` is forwarded | not a write |
| `GET /v1/runs/{id}`, `GET /api/sessions`, `GET /api/sessions/{id}/messages`, `GET /health`, `GET /v1/capabilities` | reads | 200 | not a write |

Allowed but not exercised in the live pass: `GET /v1/models`, `GET /api/sessions/{id}`. They are covered by the route table and not by a request.

Not forwarded on purpose: `POST /api/sessions/{id}/chat/stream` (a streamed answer cannot be replayed for an idempotent retry; the choice between it and `/chat` belongs to the app PR), and every other route, among them `/api/config`, `/api/env`, `/auth/*` and the dashboard. All of them answer 404 `route_not_allowed`.

The `hermes serve` 0.22.5 target of PR-0 serves the dashboard routes, not `/v1/*`. The facade is the same there, but its write routes are **not proven**: the allowlist would need the routes of that target, and a test instance of 0.22.5 was not available.

## Idempotency journal

The facade keeps one record per write key in `<data>/idempotency/<sha256 of device, method, path, key>.json` (mode 0600, the key itself is not stored). The record is written **before** the request leaves for Hermes, so a restart or a lost answer leaves a trace.

| State of the record | Meaning | Answer to the same key and body |
| --- | --- | --- |
| `pending` | written, no answer yet. After a restart, nothing finishes it | 502 `write_outcome_unknown`, Hermes is not called |
| `done` | Hermes answered. Status, `content-type`, `cache-control`, `retry-after` and the body (up to 16 KiB) are kept | the kept answer with `Idempotency-Replayed: true`. A body over 16 KiB: 409 `idempotency_replay_unavailable` |
| `unknown` | the connection broke, timed out or was reset after the request was sent, the answer could not be read completely, or Hermes answered 5xx | 502 `write_outcome_unknown`, Hermes is not called. The first request got the 5xx of Hermes as it was |
| no file, or the record expired (24 hours) | new write | sent to Hermes |

A file that cannot be read or parsed, or that has no numeric `expires` (`{}`, `null`, empty), counts as `unknown`. It keeps its key for 24 hours after its last write (the modification time of the file), on read, on the hourly purge, on the purge of a full journal and at startup. A restart never frees the key of an invalid record. The same key with another body gives 409 `idempotency_key_conflict` only when the record keeps the fingerprint of the first body (the SHA-256 of the body, written with the record). A record with no fingerprint (damaged, empty, `null`, `{}`) cannot compare bodies: any body, the same or another, gets 502 `write_outcome_unknown`.

What frees the key (the next send reaches Hermes):

- Hermes certainly did not run the write: the connection was refused, Hermes answered 401 (`upstream_rejected`) or a redirect (`upstream_redirect`).
- Hermes refused for a later retry: 408 or 429. The answer reaches the device with its `Retry-After`, and the record is not kept.

A 5xx answer does not free the key: Hermes can answer 5xx after it ran the write, and a second send would run it twice. The device gets the 5xx once. The same key then gets 502 `write_outcome_unknown`. Every other failure keeps the key in `unknown` too. A device that gets `write_outcome_unknown` does not retry with the same key: it reads the state on Hermes (`GET /v1/runs/{id}`, `GET /api/sessions/{id}/messages`), then sends a new write with a new key if the first did not happen. The doubt ends with the 24 hours of the key.

Two requests with the same key at the same time share one Hermes call.

## Failure modes and the test that covers each

| Failure mode | Result | Test |
| --- | --- | --- |
| No token, wrong scheme, empty, garbage, wrong secret, path traversal in the id | 401 `invalid_token`, nothing reaches Hermes, unknown paths also give 401 | 1 |
| Device file damaged (no hash, broken JSON, empty) | 401, never a 500 | 1b |
| Revoked token (API or CLI, no restart) | 401 on the next request. An open event stream is cut within one second | 2, 2b |
| Other CA as anchor, wrong pin, system roots only, TLS 1.2 client | handshake or pin error | 3 |
| Plain HTTP on the facade port | no HTTP answer | 4 |
| Upstream that is not `127.0.0.1` or `::1` over plain HTTP, with credentials, path or another scheme | the facade refuses to start | 4 |
| Device credentials, cookies or forwarding headers sent to Hermes | not forwarded. Hermes receives its own key | 4 |
| Hermes `server`, `set-cookie`, `www-authenticate`, `location` in an answer | removed or replaced by 502 | 4, 4b |
| Hermes down, redirect, or rejecting its own key | 502 `upstream_unavailable`, `upstream_redirect`, `upstream_rejected` | 4b |
| No Hermes key for a profile and no global key | 502 `upstream_key_missing` | 4c |
| Profile not listed in `FACADE_UPSTREAM_KEYS` while `FACADE_UPSTREAM_KEY` is set | the global key is used | 4c2 |
| Hermes port reachable on a non-loopback address of the host | `check-local` exits 1 | 4d |
| Code unknown, used, expired (to the millisecond), concurrent use | 403 `invalid_code`, one winner | 5 |
| Code or token written in clear on disk | not stored in clear | 5b |
| Code guessing | 429 | 5c |
| Write with no key, with a bad key, same key with another body, concurrent same key, other device, after 24 hours | 400, 400, 409, one Hermes call, independent, new call | 6 |
| Hermes 5xx on a write (500, 502, 503, 504) after it ran the write | the 5xx reaches the device once. The same key gets 502 `write_outcome_unknown`, another body 409, a new key is sent. One effect for three sends. After 24 hours: sent | 6b |
| Body over the limit | 413, Hermes is not called | 6b |
| Response lost after the request was sent (connection dropped) | 502 `write_outcome_unknown`. The same key never reaches Hermes again. Another body: 409. A new key: sent. After 24 hours: sent | 6c |
| Hermes refused the connection or answered 401 | 502 `upstream_unavailable` or `upstream_rejected`. The same key is sent again | 6d |
| Hermes answered 408 or 429 | the answer and its `Retry-After` reach the device. The key is not kept, the retry reaches Hermes | 6e |
| Restart of the facade, with a finished write and with a write cut in flight | the finished write replays with `Idempotency-Replayed: true`, the cut write gives `write_outcome_unknown`. One Hermes call each | 6f |
| Journal record damaged, empty, `null`, `{}` or left `pending` | 502 `write_outcome_unknown`, Hermes is not called | 6g |
| Invalid record (`{}`, no numeric `expires`, `null`, empty, broken JSON) at a restart, at the purge of a full journal, and after 24 hours | kept: the key stays `unknown`, the journal stays full. It ends 24 hours after its last write, on read and on purge | 6i |
| Journal full | 503 `idempotency_journal_full`, Hermes is not called. A live key still replays. Expired keys leave | 6h |
| Route outside the allowlist, traversal, wrong method, bad query | 404, 404, 405, 400 | 7 |
| Normal role on a management route | 403 | 8 |
| Burst over the limit, failed authentication flood | 429. A valid token is never locked out by the failures of its address. The flood adds no audit line beyond the limit | 9 |
| Audit time zone, content and secrets | UTC, complete, no secret | 10 |
| `revoke` and `enrol-code` run from the CLI | a line with `source: "cli"`, in UTC, no secret | 10b |
| Bad or missing configuration | the facade does not start | 11 |

## Not done, and risks

1. The pinning rule exists as `pinnedTlsOptions` for Node and as the `curl` options below. The **app (Swift) does not use the facade yet**: pinning in the app is the next PR. Until then no client of the product speaks to the facade.
2. A device has to trust the CA before it enrols, because TLS is validated before the code is sent. The CA certificate and the pin travel with the code, outside the facade. A device that gets a wrong CA from that channel is exposed.
3. The CA key stays in the data folder of the host. Move it offline after the server certificate is issued.
4. The idempotency keys survive a restart (journal on disk). The rate limit counters and the revocation sweep live in the process memory. The journal is written without `fsync`: it survives the end of the process, not a power cut. It holds the answers of Hermes up to 16 KiB in clear (mode 0600), for 24 hours, in the data folder: protect that folder like the audit.
   The limit of 10 000 keys is global and the write limit is per device: one device that writes at the sustained limit (5 per second) fills the journal in about 33 minutes, and every device then gets 503 `idempotency_journal_full` until keys expire. A limit per device is the next step.
   A 5xx answer of Hermes keeps the key as `unknown` (see "Idempotency journal"). A device that wants to retry after a 5xx reads the state on Hermes, then uses a new key. A 5xx that Hermes sent before it ran the write blocks the key for 24 hours, and the facade cannot tell the two cases apart.
5. A token has no expiry and the audit file has no rotation.
6. The facade reads and writes small files synchronously. It is sized for a few devices.
7. The dashboard of the real target was not inspected: only the test instance was reachable. On the real host, run `check-local <hermes-port>` and `check-local <dashboard-port>` before opening the facade port.
8. A client that sends a body over the limit while the facade answers 413 can read a connection reset instead of the 413. The status is correct for clients that send the body with the headers.

## Reproduce

```
export FACADE_DATA=<data-folder>
node scripts/hermes-facade.js init-tls --san IP:<address devices use>
node scripts/hermes-facade.js enrol-code admin
FACADE_UPSTREAM=http://127.0.0.1:<hermes-port> FACADE_UPSTREAM_KEY=<from the environment> \
  FACADE_LISTEN_HOST=<address devices use> FACADE_LISTEN_PORT=<facade-port> node scripts/hermes-facade.js serve
node scripts/hermes-facade.js check-local <hermes-port>
node scripts/hermes-facade.js devices
node scripts/hermes-facade.js revoke <device id>
curl --cacert <ca.crt> --pinnedpubkey 'sha256//<pin>' -H 'Authorization: Bearer <token>' https://<address>:<facade-port>/health
npm test
```

## Live pass of 2026-10-29 (test instance only)

Setup: the facade started from the command line (`serve`) on the loopback of the test machine, in front of the dedicated test instance (Hermes 0.22.2, fake provider). Certificates and state in a throwaway folder outside the repository. The Hermes key was read from the environment and never printed. The paths that must not change were measured before and after (`GUARD OK` both times). Raw output stays on the machine that produced it.

Lane names: `accept-N` is the acceptance test N of the issue. `temps-2` is the identification of the write routes. The driver is a script outside the repository: it starts the facade with `serve`, calls it with the pinned client and with `curl`, and uses the CLI for `init-tls`, `enrol-code`, `revoke` and `check-local`.

```
init-tls rc=0 ca_sha256=<hash> server_pin=<pin>
enrol-code rc=0 code=**** role=normal expires_at=2026-10-29T15:12:37.661Z
serve: facade listening on 127.0.0.1:<facade-port>, upstream http://127.0.0.1:<test-port>
PASS accept-1 no access without a valid token: statuses 401,401,401,401,401
PASS accept-5 enrolment code single use: first 201 role=admin, reuse 403 invalid_code
PASS roles admin creates a code, normal device enrols: code 201 enrol 201 role normal code_expires_at 2026-10-29T15:12:37.789Z
PASS roles normal device refused on management routes: admin 200 (4 devices), normal 403
PASS accept-3 node client, pinned CA and SPKI pin: GET /health 200
PASS accept-3 wrong pin, other CA, system roots, TLS 1.2 refused: wrong pin refused (server certificate pin mismatch); other CA refused (SELF_SIGNED_CERT_IN_CHAIN); system roots refused (SELF_SIGNED_CERT_IN_CHAIN); TLS 1.2 refused (EPROTO)
PASS accept-4 plain HTTP on the facade port gets no HTTP answer: refused (ECONNRESET)
PASS accept-3 curl --cacert --pinnedpubkey: curl 8.7.1: right pin http 200 rc=0; wrong pin rc=90; --tls-max 1.2 rc=35
PASS temps-2 reads through the facade (default profile): /health 200, /v1/capabilities 200, /api/sessions 200
  default events: message.delta > reasoning.available > run.completed; run status=completed
  default approval run tail: message.delta > reasoning.available > run.completed
  default stop: terminal run.cancelled; run status=cancelled; "sleep 300" left in container: false
  default POST /v1/runs (no key) -> 400 idempotency_key_required
  default POST /v1/runs (key) -> 202 run_id=run_7a9f3cd84c6d495990ec6d588ed33f78 status=started
  default POST /v1/runs (same key, same body) -> 202 replayed same run_id=true
  default POST /v1/runs (same key, other body) -> 409 idempotency_key_conflict
  default POST /v1/runs/{id}/approval -> 200 resolved=1 choice=deny
  default POST /v1/runs/{id}/approval (replay) -> 200 replayed same body=true
  default POST /v1/runs/{id}/stop -> 200 status=stopping
  default POST /v1/runs/{id}/stop (replay) -> 200 replayed same body=true
  default POST /api/sessions -> 201 session=api_1793286458_f9932d10
  default POST /api/sessions (replay) -> 201 replayed same session=true
  default POST /api/sessions/{id}/model -> 200 model_lock=accepted
  default POST /api/sessions/{id}/chat -> 200 model=hv-fake-2 route_source=session_model_lock
  default POST /api/sessions/{id}/chat (replay) -> 200 replayed same body=true
  default GET /api/sessions/{id}/messages -> 200 user messages=1 (one send, one replay)
PASS temps-2 default send prompt, replay, conflict, events
PASS temps-2 default approval answer is idempotent
PASS temps-2 default cancel is idempotent and stops the tool
PASS accept-6 default new session, model lock, chat: one execution per key
  pause 5 s: the per-device write limit (burst 20, 5 per second) refills
  hv-bot-a events: message.delta > reasoning.available > run.completed; run status=completed
  hv-bot-a approval run tail: message.delta > reasoning.available > run.completed
  hv-bot-a stop: terminal run.cancelled; run status=cancelled; "sleep 300" left in container: false
  hv-bot-a POST /v1/runs (no key) -> 400 idempotency_key_required
  hv-bot-a POST /v1/runs (key) -> 202 run_id=run_02e6e55282414e7f8d69f54b9d068561 status=started
  hv-bot-a POST /v1/runs (same key, same body) -> 202 replayed same run_id=true
  hv-bot-a POST /v1/runs (same key, other body) -> 409 idempotency_key_conflict
  hv-bot-a POST /v1/runs/{id}/approval -> 200 resolved=1 choice=deny
  hv-bot-a POST /v1/runs/{id}/approval (replay) -> 200 replayed same body=true
  hv-bot-a POST /v1/runs/{id}/stop -> 200 status=stopping
  hv-bot-a POST /v1/runs/{id}/stop (replay) -> 200 replayed same body=true
  hv-bot-a POST /api/sessions -> 201 session=api_1793286464_27367094
  hv-bot-a POST /api/sessions (replay) -> 201 replayed same session=true
  hv-bot-a POST /api/sessions/{id}/model -> 200 model_lock=accepted
  hv-bot-a POST /api/sessions/{id}/chat -> 200 model=hv-fake-2 route_source=session_model_lock
  hv-bot-a POST /api/sessions/{id}/chat (replay) -> 200 replayed same body=true
  hv-bot-a GET /api/sessions/{id}/messages -> 200 user messages=1 (one send, one replay)
PASS temps-2 hv-bot-a send prompt, replay, conflict, events
PASS temps-2 hv-bot-a approval answer is idempotent
PASS temps-2 hv-bot-a cancel is idempotent and stops the tool
PASS accept-6 hv-bot-a new session, model lock, chat: one execution per key
PASS allowlist routes outside the list never reach Hermes: POST /api/sessions/x/chat/stream 404 route_not_allowed; GET /api/config 404 route_not_allowed; GET /api/env 404 route_not_allowed; GET /auth/native/authorize 404 route_not_allowed; GET /p/hv-bot-a/v1/runs/../../api/env 404 route_not_allowed
PASS accept-2 revoked token refused at once (CLI revoke, no restart): before 200, revoke rc=0 in 109 ms, next request 401 1 ms after
PASS accept-2 revocation cuts the open event stream: stream closed 54 ms after revoke
PASS accept-2 revoke through the admin API, other devices unaffected: revoke 200, revoked device 401, other device 200
PASS rate limit per device answers 429 with Retry-After: 100 quick requests: {"200":62,"429":38,"retry":"1"}
PASS audit is UTC and holds no key, token or code: 185 lines, events {"code.create":5,"auth.fail":7,"enrol.ok":4,"enrol.fail":1,"request":166,"revoke":2}
  audit sample: ts=2026-10-29T15:07:38.630Z event=request route=run.stop status=200 role=normal
  docker port: 8642/tcp -> 127.0.0.1:<test-port>
  listening sockets in the Hermes container: any:8642 loopback:<provider-port>
  host addresses outside the loopback checked: 23
PASS dashboard local-only: published Hermes port answers on the loopback only: check-local <test-port> rc=0: check-local: ok, the port answers on the loopback only
PASS dashboard local-only: dashboard port 9119 answers nowhere outside the loopback: check-local 9119 rc=0: check-local: ok, the port answers on the loopback only
  waiting 291 s for the enrolment code to expire
PASS accept-5 expired enrolment code refused (real clock): 302 s after creation, ttl 300 s -> 403 invalid_code
serve child stopped: true
SUMMARY 26/26 lanes pass in 303 s
driver rc=0
wrapper rc=0
GUARD OK: chemins protégés inchangés
guard rc=0
```

Notes on this pass:

1. The output above is the pass on commit `ec49030` (the idempotency journal, the 408 and 429 rule, the CLI audit). A new pass ran on commit `1d379db` (a 5xx keeps the key as `unknown`, an invalid record keeps its key for 24 hours): 26 of 26 lanes, 303 s, driver rc=0, wrapper rc=0, `GUARD OK`, audit 185 lines, the Hermes key found in no file of the evidence or of the repository. Passes on the earlier head `2a30e85` gave 26 of 26, then 25 of 26 (the driver sent more than 20 writes in a few seconds with one device and got 429, which is the write limit working; the driver now waits 5 seconds between the two profiles), then 26 of 26 again.
2. The lanes `temps-2` and `accept-6` exercise the journal path (record written before the request, replay, conflict) on the test instance. The restart, the lost response, the 5xx answers, the 408 and 429 answers, the invalid records and the full journal have no live lane: tests 6b to 6i cover them against a fake upstream (the test instance does not answer 5xx after a write on demand).
3. The `stop` lane checks the container process list: no `sleep 300` is left after the cancel.
4. The test instance runs the API server platform and a fake model provider. It has no dashboard process (its listening sockets are the API port and the provider), so `check-local` proves that the published API port answers on the loopback only. It does not prove the dashboard of the real target. See item 7 of "Not done, and risks".
5. Everything ran on the loopback of one machine. A device on a real network was not tested.
6. The paths that must not change were measured before and after the pass.
7. The audit of this pass has two `revoke` lines: one from the CLI (`source: "cli"`) and one from the admin API. The earlier pass had only the API line.
