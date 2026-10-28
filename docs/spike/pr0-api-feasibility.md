# PR-0: Hermes API feasibility spike

Status: step 1 (read-only inventory) done on 2026-10-28. Step 2 (the single write on a dedicated test session) is **not done**: it waits for an explicit GO from the user. No production system was touched or inventoried.

## References

| Item | Value |
| --- | --- |
| Public documentation | [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server), read on 2026-10-28 |
| Documented version | none. The page states no version number. It carries a "Breaking change (July 2026)" notice. |
| Observed version | Hermes v0.22.2 (2026.9.24), upstream commit `d923a5eb`, on the local test container (`GET /health`, `hermes --version`) |
| Code read | `gateway/platforms/api_server.py`, `gateway/platforms/tcp_site.py`, `gateway/platforms/base.py` at the observed version, read inside the test container, not modified |

The documented page was read through a page-to-text tool. Lines quoted below come from its output. A statement "the page does not mention X" means the tool output did not contain X.

## Scope of the inventory

- Allowed and done: `GET /health` (no key), `GET /v1/capabilities` without a key (expects 401), one HTTPS request to the plain port, and a code read.
- Authenticated reads were not repeated in this session: the test key is not in the author environment, and the author does not read it from the container. The authenticated reads of S5 and S8 (`GET /api/sessions`, `GET /v1/capabilities`, `GET /health/detailed`) from 2026-10-18 stay the evidence for those routes, see [S5-sessions.md](S5-sessions.md) and [S8-version.md](S8-version.md).
- Not done: any inventory of a production Hermes. The issue forbids a production change, and no read-only access to production is part of the repository.

## Table

`ok` = proven by a tool result of this spike or by a cited earlier spike. `absent` = proven missing. `unknown` = not proven.

| Capability | Status | Evidence | Gap with the product needs |
| --- | --- | --- | --- |
| Read: health | ok | `GET /health` without key: 200, `{"status": "ok", "platform": "hermes-agent", "version": "0.22.2"}` (this session). The doc lists `GET /health`, `GET /v1/health`, authenticated `GET /health/detailed`. | none |
| Read: capabilities | ok | `GET /v1/capabilities` without key: 401 (this session). With key: 200, features and endpoint table (S8, 2026-10-18). | none |
| Read: sessions, messages, runs, models, jobs | ok (routes documented), observed for sessions and messages | Doc routes: `GET /api/sessions`, `/api/sessions/{id}`, `/api/sessions/{id}/messages`, `GET /v1/runs/{run_id}`, `/v1/runs/{run_id}/events` (SSE), `GET /v1/models`, `GET /api/jobs`. Observed: sessions and run events in S1 and S5. `GET /api/jobs` and `GET /v1/responses/{id}` were not observed. | Jobs list: `unknown` on the live API |
| Write: runs, sessions, chat | ok on the test container (earlier spikes), not repeated here | Doc: `POST /v1/runs`, `POST /v1/runs/{id}/stop`, `POST /api/sessions`, `POST /api/sessions/{id}/chat`. Observed in S1, S3, S4 on 2026-10-18. | none |
| Write: the single write of this spike | not done | Waits for the explicit GO of the user. See "Step 2". | none |
| Write: jobs, PATCH and DELETE of sessions, `resolve-unknown`, `clarify` | unknown | Documented, never called. | Only relevant if API v1 needs them |
| TLS (native) | absent | Doc does not mention TLS, HTTPS or certificates. Code: `ssl_context` appears nowhere in `gateway/` (`grep` returned no match). `web.TCPSite(runner, host, port, ...)` is created without it (`tcp_site.py:51`, `:62`). Observed: `https://` to the plain listener fails with `tlsv1 alert protocol version` (this session). | Any link that leaves the host needs a TLS terminator or an SSH tunnel outside Hermes |
| TLS behind a reverse proxy | unknown | Doc gives no reverse-proxy guidance. Not tested. | Not proven either way |
| Bind: loopback | ok | `API_SERVER_HOST` defaults to `127.0.0.1`, `API_SERVER_PORT` to `8642` (doc; `api_server.py:216`, `:227`). | matches the PRD (tunnel to `127.0.0.1:8642`) |
| Bind: beyond loopback | ok in code, reachability beyond the test container unknown | Setting `API_SERVER_HOST` to a non-loopback address is accepted. `is_network_accessible(host)` (`base.py:253`) only drives a warning when the terminal backend is `local` (`api_server.py:4501`). The doc gives no requirement for this case. The test container listens on all its interfaces and answers through a loopback-published port (S8). | PRD risk "API server exposed beyond `127.0.0.1`" can move from `unknown` to "possible, warned by Hermes, plain HTTP". Network reach on a real host: `unknown` |
| Auth: bearer | ok | One `Authorization: Bearer` check, `hmac.compare_digest` against one expected key (`api_server.py:1559` to `:1582`). Doc: "`API_SERVER_KEY` is required for every deployment, including the default loopback bind." Startup refuses a missing or weak key (`:4422`). | matches the PRD (key required) |
| Auth: per-profile key | ok | Doc: `/p/<profile>/v1/...` needs that profile's own key; a named profile without key fails closed. Code: `_check_auth` returns 401 for it (`:1565` to `:1572`). Observed in S7. | One key per profile to provision |
| Auth: beyond one bearer per profile (per-user keys, scopes, roles, OAuth/OIDC, mTLS) | absent on the user routes | `_check_auth` compares one value. The doc lists no other method. The only other mechanism found is the JWT verifier of `POST /api/cron/fire` (`api_server.py:3985`), for a hosted cron service, not for users. | A single shared secret per profile gives no per-user identity and no revocation of one client |
| Browser CORS | ok, off by default | Doc: not enabled by default; allowlist in `API_SERVER_CORS_ORIGINS`. Not tested. | none for a native app |

## Gap with the product needs

The product needs (PRD): one transport, an SSH tunnel to `127.0.0.1:8642`, a key per profile, no connection outside the tunnel.

1. Needs met today: loopback bind by default, bearer key mandatory, key per profile, health and capabilities readable.
2. Native TLS is absent. A path that does not go through the SSH tunnel has no encryption from Hermes.
3. Auth is one shared bearer per profile. No per-client identity, scope or revocation exists on the user routes.
4. The doc warns that the API gives full access to the toolset, including terminal commands. Hermes warns at startup when the bind is network-accessible and the terminal backend is `local`.
5. A version number exists only at runtime (`/health`). The doc has none, so "documented version" stays empty until the page carries one.

## Step 2: the single write (not done)

Waiting for the explicit GO of the user. The write must target a dedicated test session on the local test container. It is not run in this PR. Production is out of scope.

Proposed target, to confirm with the GO:

| Field | Value |
| --- | --- |
| Request | `POST /api/sessions` with an empty JSON body `{}` |
| Where | the local test container, profile `hv-bot-a`, key from the environment |
| Expected | 200 or 201 with a session id; `GET /api/sessions` lists it once more |
| Cleanup | none requested; the container is thrown away by `down orb` |

This request is a proposal. The user can name another write.

## Reproduce

```
curl -sS http://127.0.0.1:<published-port>/health
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:<published-port>/v1/capabilities
curl -sS https://127.0.0.1:<published-port>/health
docker exec hv-hermes-test hermes --version
```
