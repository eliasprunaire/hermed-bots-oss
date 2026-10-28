# PR-0: Hermes API feasibility spike

Status: step 1 (read-only inventory) done on 2026-10-28. Step 2 (the single write on a test session) is **deferred to PR-1** by decision of the user on 2026-10-28. No write was made. No production system was touched or inventoried.

Conclusion: the observed target is `hermes serve`, authenticated by the dashboard. It has no reachable OpenAI-compatible API with a bearer token, no native TLS and no per-device token. PR-1 is therefore a **facade** that adds authentication, per-device tokens, revocation and TLS.

## References

| Item | Value |
| --- | --- |
| Public documentation | [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server), read on 2026-10-28. It describes the OpenAI-compatible API server, not `hermes serve`. |
| Documented version | none. The page states no version number. It carries a "Breaking change (July 2026)" notice. |
| Observed target | `hermes serve` 0.22.5, as recorded in the decision of the user on 2026-10-28 |
| Version read by the author | Hermes v0.22.2 (2026.9.24), upstream commit `d923a5eb`, on a local test instance (`hermes --version`). The 0.22.5 build was not available to the author: the code reading below is at 0.22.2 and is not re-checked at 0.22.5. |
| Code read | `hermes_cli/web_server.py`, `hermes_cli/dashboard_auth/` (`token_auth.py`, `base.py`, `registry.py`), `gateway/platforms/api_server_room_grants.py`, `hermes serve --help`. Read-only, nothing modified. |

A statement "the page does not mention X" means the page-to-text output did not contain X.

## Scope of the inventory

- Done: `hermes --version`, `hermes serve --help`, `hermes serve --status`, and a code read on a local test instance.
- Not done: any write, any authenticated call, any inventory of a production Hermes. The issue forbids a production change, and no read-only access to production is part of the repository.
- The earlier spikes [S5-sessions.md](S5-sessions.md) and [S8-version.md](S8-version.md) (2026-10-18) stay the evidence for the sessions and capabilities routes of the separate API server platform. They were not replayed.

## Table

`ok` = proven by a tool result of this spike or by a cited earlier spike. `absent` = proven missing in the code read. `unknown` = not proven.

| Capability | Status | Evidence | Gap with the product needs |
| --- | --- | --- | --- |
| Service on the target | ok | `hermes serve --help`: "the JSON-RPC/WebSocket gateway the desktop app and remote clients connect to", default host `127.0.0.1`, default port 9119. | The product speaks HTTP and SSE to the API server surface, not JSON-RPC over WebSocket |
| OpenAI-compatible API with bearer token on the target | absent | Not reachable on the observed target (decision of 2026-10-28). The API server is a separate gateway platform (`gateway/platforms/api_server.py`) and is not started by `hermes serve`. | The product routes (`/v1/runs`, `/api/sessions`) are not served by the target |
| Read: sessions, messages, runs, models, jobs | unknown on the target | Documented and observed on the API server platform only (S1, S5, S8). Not tried on `hermes serve`. | Reads have to be re-proven behind the facade |
| Write: runs, sessions, chat | unknown on the target | Same as above. Observed on the API server platform only (S1, S3, S4). | Writes have to be re-proven behind the facade |
| The single write of this spike | deferred | Deferred to PR-1 by decision of the user on 2026-10-28. | none |
| TLS (native) | absent | `uvicorn.Config(...)` in `_build_uvicorn_server` (`web_server.py`) sets no `ssl_keyfile` or `ssl_certfile`; `grep ssl_keyfile\|ssl_certfile web_server.py` returns 0 match. The code expects a TLS terminator in front (`proxy_headers` for gated mode, comment "runs behind a TLS terminator"). | A link that leaves the host has no encryption from Hermes. The facade has to provide TLS |
| Bind: loopback | ok | `hermes serve --host` defaults to `127.0.0.1`. | Matches the PRD: SSH tunnel to loopback |
| Bind: beyond loopback | ok in code, reachability unknown | `hermes serve --help`: `--insecure` is a no-op since the June 2026 hardening; "a public bind always requires an auth provider (password or OAuth)"; advice: "Bind 127.0.0.1 + tunnel to keep it local". Real reach from another host: not tested. | The PRD risk "server exposed beyond loopback" stays gated by an auth provider, in plain HTTP |
| Auth: native method | ok, dashboard providers | `dashboard_auth/base.py`: interactive `Session` (user id, e-mail, org, access and refresh tokens) from a password or OAuth provider, kept in a cookie. Providers register through `dashboard_auth/registry.py`. | Interactive login for a person, not a credential a native app stores |
| Auth: bearer token | absent for the product routes | `dashboard_auth/token_auth.py`: a bearer token is accepted only on exact paths registered with `register_token_route`. The only registration found is the drain route of a plugin (`plugins/dashboard_auth/drain`). | No bearer token reaches a session or run route |
| Auth: per-device token | absent | `TokenPrincipal` carries one opaque `principal` and optional `scopes` per provider. No device concept appears in `dashboard_auth/` (`grep` finds "device" only in `login_page.py`). | The facade has to issue one token per device |
| Auth: revocation of one client | absent as an operator action | `dashboard_auth/base.py` defines `revoke_session(refresh_token)`, called "on logout (best-effort, must not raise)". It ends the session of the holder of the refresh token. No operator route that revokes a chosen device or token appears in `dashboard_auth/`. | The facade has to let an operator revoke one device without touching the others |
| Room grants (`HermesRoom`) | ok on the API server platform, unknown for the product | `gateway/platforms/api_server_room_grants.py`: short-lived signed grants with a permission check and a revocation lookup (`room_grant_is_revoked`, `peer_room_grant_is_current`). Routes `/v1/room-members/invitations`, `/capabilities`, `/grants/refresh`, `/grants/revoke`. The grant is minted through an endpoint that already requires the general API key, for a room member of a trusted home gateway. | These grants are not the general user keys and not per-device tokens. They are not served by `hermes serve`. Their fit for the client is not verified |
| Browser CORS | unknown | Not read for `hermes serve`. | none for a native app |

## Gap with the product needs

The product needs (PRD): one transport, an SSH tunnel to a loopback port, one credential the app can store, no connection outside the tunnel.

1. Met today: loopback bind by default, an authentication gate on any non-loopback bind.
2. Native TLS is absent. A path that does not go through the SSH tunnel has no encryption from Hermes.
3. Authentication is interactive (dashboard login). No bearer token reaches the product routes, and no per-device token exists.
4. On the dashboard path, a session ends only when its holder logs out (`revoke_session`). An operator cannot revoke one device. `HermesRoom` grants revoke, but they serve another purpose and another surface.
5. The version of the target (0.22.5) comes from the decision of the user. The author read 0.22.2.

## Decision for PR-1

PR-1 builds a facade in front of the target. The facade provides:

1. authentication of the client;
2. one token per device;
3. revocation of one device;
4. TLS.

The facade is the place where the reads and writes of the product are proven again.

## Step 2: the single write (deferred)

The user deferred the write to PR-1 on 2026-10-28. The write targets a dedicated test session, never production. The request and the target are chosen in PR-1, against the facade, with the explicit GO of the user.

## Reproduce

```
hermes --version
hermes serve --help
hermes serve --status
```
