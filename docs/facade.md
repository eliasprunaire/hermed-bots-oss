# Hermes facade

The facade sits in front of the target Hermes instance. It ends TLS, authenticates each device with its own token, and talks to Hermes on the loopback of the host only. The Hermes credential never leaves the host.

Background and decisions are in `docs/spike/pr0-api-feasibility.md`. The write routes found on a test instance are in `docs/spike/pr1-write-routes.md`.

## What it guarantees

| Guarantee | How |
| --- | --- |
| No access without a valid token | Every route except `POST /facade/enroll` needs `Authorization: Bearer <device token>`. The answer for a missing, wrong or revoked token is the same `401`. |
| Immediate revocation | A revoked device is refused on its next call, an open socket is closed at once, and a revocation made on the host (CLI) applies on the next call. |
| TLS with a pinned anchor | A dedicated internal CA signs the server certificate. Clients trust that CA alone and check the SHA-256 of the server public key (SPKI) against a pin. TLS 1.3 only. |
| Hermes never seen over HTTP | The facade has no plain HTTP listener. Hermes is reached on the loopback only. Replies carry a short list of headers, no cookie, no redirect. The facade refuses to start when the Hermes port answers on a non-loopback interface. |
| One-use enrollment | A code is valid 5 minutes, works once, and an expired, reused or unknown code gets the same `401 enrollment_invalid`. |
| Roles | `admin` and `normal`. Only an admin creates codes, lists devices, revokes, reads the audit. |
| Audit | One JSON line per event, timestamps in UTC. Tokens and codes are never written. |
| Rate limit | 120 calls a minute per device by default, 10 enrollment attempts per 5 minutes per source, and a source is blocked after 30 failed authentications in a minute. |
| Idempotent writes | A write carries `params.idempotency_key`. It runs once per device and key, and a retry gets the first answer. |

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
| `GET /api/ws` (WebSocket) | any device | JSON-RPC bridge to the Hermes gateway, checked message by message. |

### Socket methods

Default deny. A device reaches these methods and no other.

- Reads, both roles: `ping`, `session.list`, `session.most_recent`, `session.active_list`, `session.resume`, `session.events.since`, `session.events.stats`, `approval.pending`.
- Writes, both roles: `session.create`, `session.close`, `prompt.submit`, `approval.respond`, `session.interrupt`.
- Writes, admin only: `session.delete`, `session.archive`, `session.title`.

A refused method gets JSON-RPC error `4003`. Hermes exposes shell, configuration, vault and connector methods on the same socket. None of them is reachable.

### Writes and idempotency

A write needs a string or number `id` and `params.idempotency_key` (8 to 128 characters from `A-Z a-z 0-9 . _ : -`). The facade removes the key before it forwards the call, because Hermes rejects unknown parameters.

| Case | Answer |
| --- | --- |
| First call | Forwarded. A success is kept 24 hours. |
| Same key, same request | The first result again, with `"idempotent_replay": true`. Hermes is not called. |
| Same key, call still running | The caller waits and gets the same result. |
| Same key, different request | Error `4009`. |
| First call failed | The key is freed. Retry with the same key. |
| Outcome lost (Hermes dropped the socket) | Error `4010` for that key. It is never run again. Check the session, then use a new key. |
| No key | Error `4004`. Nothing reaches Hermes. |

Keys are kept in memory. A restart of the facade forgets them.

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
5. Check the exposure at any time with `check-exposure`. It exits non-zero when the Hermes port is reachable through a non-loopback interface.

Other host commands: `enroll [--role]`, `devices`, `revoke <device-id>`.

## Pinning on the client

Trust the CA from `ca.crt` as the only anchor, then compare the SHA-256 of the server SubjectPublicKeyInfo with the pin. `facade/src/tls.js` (`pinnedClientOptions`) is the reference. A client must not fall back to the system roots.

## Tests

`npm test` runs the six acceptance tests (`test/facade/acceptance.test.js`) and the unit tests. `facade/testkit/live-smoke.js` runs the same facade against a Hermes **test** instance. See `docs/spike/pr1-write-routes.md`.
