# Hermes facade

The facade sits in front of the target Hermes instance. It ends TLS, authenticates each device with its own token, and talks to Hermes on the loopback of the host only. The Hermes credential never leaves the host.

Background and decisions are in `docs/spike/pr0-api-feasibility.md`. The write routes found on a test instance are in `docs/spike/pr1-write-routes.md`.

## What it guarantees

| Guarantee | How |
| --- | --- |
| No access without a valid token | Every route except `POST /facade/enroll` needs `Authorization: Bearer <device token>`. The answer for a missing, wrong or revoked token is the same `401`. |
| Immediate revocation | A revoked device is refused on its next call, an open socket is closed at once, and a revocation made on the host (CLI) is seen before the next call and before the next event relayed to a device. |
| TLS with a pinned anchor | A dedicated internal CA signs the server certificate. Clients trust that CA alone and check the SHA-256 of the server public key (SPKI) against a pin. TLS 1.3 only. |
| Hermes never seen over HTTP | The facade has no plain HTTP listener. Hermes is reached on the loopback only. Replies carry a short list of headers, no cookie, no redirect. The facade refuses to start when the Hermes port answers on any non-loopback address of the host (a scoped, interface-local address included), when that cannot be verified, or when the configured Hermes host is a wildcard or any non-loopback value. |
| One-use enrollment | A code is valid 5 minutes, works once, and an expired, reused or unknown code gets the same `401 enrollment_invalid`. |
| Roles | `admin` and `normal`. Only an admin creates codes, lists devices, revokes, reads the audit. Up to 200 active devices. A revoked device no longer counts. |
| Audit | One JSON line per event, timestamps in UTC. A value a device controls (method name, device name, path) is never written raw: methods are logged as a short digest, device names not at all, paths of unknown routes as `[unlisted]`. Every value is also masked when it has the shape of a credential, or contains the Hermes credential (also in its URL-encoded form), and a field named like a secret is always masked. The Hermes credential must be at least 16 characters with no whitespace, and the audit masks a configured secret whatever its length. The host commands `enroll` and `revoke` write audit lines too (`enrollment_created`, `revoke`, `revoke_denied`), and the audit route reads them from the file. |
| Rate limit | 120 calls a minute per device by default, 10 enrollment attempts per 5 minutes per source, and a source is blocked after 30 failed authentications in a minute. |
| Idempotent writes | A write carries `params.idempotency_key`. It runs once per device and key, and a retry gets the first answer, also after a restart or a crash of the facade process. |

## Routes

All routes are under TLS.

| Route | Who | Purpose |
| --- | --- | --- |
| `POST /facade/enroll` | anyone with a code | Body `{"code", "name"}`. Returns `{"device_id", "role", "token"}` once. |
| `GET /facade/whoami` | any device | Device id, name, role. |
| `GET /facade/status` | any device | `hermes_version`, `gateway_running`, `active_sessions`, `overall`. |
| `POST /facade/enrollments` | admin | Body `{"role"}`. Returns a code and its expiry. |
| `GET /facade/devices` | admin | Devices, never their tokens. |
| `DELETE /facade/devices/{id}` | admin | Revokes one device. |
| `GET /facade/audit?limit=` | admin | Recent audit events. |
| `GET /api/sessions...` | any device | The read routes named in `facade/src/policy.js`. Anything else under `/api/` is `403`. |
| `GET /api/ws` (WebSocket) | any device | JSON-RPC bridge to the Hermes gateway, checked message by message. A message is at most 1 MiB and at most 64 fragments, empty ones included. A device that goes over either limit is closed with `1009`. Each continuation frame, an empty one included, also costs one call of the device rate budget, and a device that spends it is closed with `1008`. |

### Socket methods

Default deny. A device reaches these methods and no other.

- Reads, both roles: `ping`, `session.list`, `session.most_recent`, `session.active_list`, `session.resume`, `session.events.since`, `session.events.stats`, `approval.pending`.
- Writes, both roles: `session.create`, `session.close`, `prompt.submit`, `approval.respond`, `session.interrupt`.
- Writes, admin only: `session.delete`, `session.archive`, `session.title`.

Every request, read or write, leaves the facade under an id the facade made (unique per socket). A response is matched by that id and gets the device's own id back, so a device that reuses an id, or one that a running write holds, cannot complete, fail or free another call. An id must be a string, a number or `null`. A response that matches no request is dropped. A refused method gets JSON-RPC error `4003`. A request target that cannot be parsed gets `400` before any authentication. Hermes exposes shell, configuration, vault and connector methods on the same socket. None of them is reachable.

### Writes and idempotency

A write needs a string or number `id` and `params.idempotency_key` (8 to 128 characters from `A-Z a-z 0-9 . _ : -`). The facade removes the key before it forwards the call, because Hermes rejects unknown parameters.

| Case | Answer |
| --- | --- |
| First call | Forwarded. A success is kept 24 hours. |
| Same key, same request | The first result again, with `"idempotent_replay": true`. Hermes is not called. |
| Same key, call still running | The caller waits and gets the same result. |
| Same key, different request | Error `4009`. |
| First call failed (Hermes answered with an error) | The key is freed. Retry with the same key. If the journal cannot record the release, the key becomes "unknown" instead (error `4010`, see below). |
| Facade stopped or crashed while the call ran | Error `4010` for that key, as below. |
| Outcome lost (Hermes dropped the socket) | Error `4010` for that key. It is never run again. Check the session, then use a new key. |
| No key | Error `4004`. Nothing reaches Hermes. |
| Journal cannot record the start of the call | Error `4012`. Nothing reaches Hermes. |
| Journal cannot record the end of the call (result or release) | The caller still gets Hermes' answer, and callers waiting on the same key are answered `4010`. The key becomes "unknown" (error `4010`) and is never run again, also after a restart. |

The keys live in a journal, `idempotency.jsonl` in the state directory (mode 600). Each change is appended and synced before the facade goes on, and `begin` is on disk before a write is forwarded to Hermes. A record is written whole: a short write is completed. A write that fails midway refuses the change, and the next record starts on a new line, so the torn line cannot swallow it. At start the journal is replayed, a write that was still running becomes "unknown" (error `4010`, never run again), expired entries are dropped, and the file is rewritten through a temporary file, a sync and a rename. The same rewrite runs after 5000 records, once the change that reached that count is applied, so the rewrite keeps it. The rewrite is built in a temporary file whose descriptor becomes the journal descriptor, so no failure after the rename can leave the facade appending to a replaced file. A rewrite that fails up to the rename leaves the current file and its descriptor in use, removes the temporary file, and is tried again at the next change. The directory is not synced after the rename, so a power loss right after a rewrite is not covered. A torn last line left by a crash is ignored. A result over 64 KiB is not kept, and its key answers "unknown". Journal errors are handled by the moment they happen. Before the call is forwarded, a `begin` that cannot be written refuses the write with error `4012` and nothing reaches Hermes. After Hermes has answered, a result, release or "unknown" record that cannot be written (for example EIO) is audited as `journal_error`; the key leaves "running" at once and becomes "unknown" in memory, waiters are woken with error `4010`, and the call is not run again. A restart agrees, because the `begin` record is then the last one on disk and replays as "unknown". The replay of a result and the release of a failed call are therefore guaranteed only while the journal can be written; the guarantee that never breaks is that a key is not run twice. The journal holds results, so keep the state directory private.

## Set up on the host

The facade needs Node 22 or later and `openssl`.

1. Make Hermes listen on the loopback only, with a fixed session token, and keep its port closed to the network.
2. Create the internal CA and the server certificate. Pass every name or address the devices use as `--host`.

   ```
   HERMES_FACADE_STATE_DIR=<state dir> node facade/bin/hermes-facade.js init-tls --host <name>
   ```

   The command prints the **pin**. Give devices `ca.crt` (never `ca.key`) and the pin by a channel that is not the facade. A renewal that keeps `server.key` keeps the pin.
3. Start it.

   ```
   HERMES_FACADE_STATE_DIR=<state dir> \
   HERMES_FACADE_LISTEN_HOST=<address to listen on> HERMES_FACADE_LISTEN_PORT=<port> \
   HERMES_FACADE_UPSTREAM_PORT=<Hermes port> HERMES_FACADE_UPSTREAM_TOKEN_FILE=<file with the Hermes token> \
   node facade/bin/hermes-facade.js serve
   ```

   The facade listens on `127.0.0.1` unless `HERMES_FACADE_LISTEN_HOST` says otherwise. It refuses a Hermes host that is not a loopback address.
4. Enroll the first admin on the host with `enroll --role admin`. Type the code into the device within 5 minutes.
5. Check the exposure at any time with `check-exposure`. It exits non-zero when the Hermes port is reachable on any non-loopback address, scoped addresses included, when a probe proves nothing (only a refusal by the host proves a port closed, so a timeout or any other error fails the check), or when the configured Hermes host is not a loopback address.

Other host commands: `enroll [--role]`, `devices`, `revoke <device-id>`. `enroll` and `revoke` are audited.

## Pinning on the client

Trust the CA from `ca.crt` as the only anchor, then compare the SHA-256 of the server SubjectPublicKeyInfo with the pin. `facade/src/tls.js` (`pinnedClientOptions`) is the reference. A client must not fall back to the system roots.

## Tests

`npm test` runs the six acceptance tests (`test/facade/acceptance.test.js`) and the unit tests. `facade/testkit/live-smoke.js` runs the same facade against a Hermes **test** instance, and writes nothing until the instance is proven disposable (see `docs/spike/pr1-write-routes.md`).

## Decisions and limits

- The facade, not Hermes, owns idempotency, because Hermes queues a second identical prompt.
- The writes ride the JSON-RPC socket, so the policy is a method allowlist on that socket and not a second set of REST routes.
- TLS uses a dedicated internal CA with pinning, not a public authority. The pin changes only when the server key changes, so `init-tls` keeps the key on renewal and a new key means a new pin for every client.
- The Hermes root page hands the process token to anyone who can open the Hermes port. The facade cannot remove that. It fails closed on exposure, and the host must stay single-purpose.
- The idempotency journal holds results and grows with traffic. It is private to the state directory, compacts at start and every 5000 records, and drops entries after 24 hours.
- The method allowlist must be compared with the Hermes source at each Hermes version.
- Not proven: a real model turn with a tool approval, the gated mode of Hermes, and a client that pins the certificate.
