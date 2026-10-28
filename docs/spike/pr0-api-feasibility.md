# PR-0: Hermes API feasibility spike

Status: step 1 (read-only inventory) done on 2026-10-28. Step 2 (the single write on a test session) is **deferred to PR-1** by decision of the user on 2026-10-28. No write was made. No production system was touched or inventoried.

Conclusion: the observed target is `hermes serve` 0.22.5, authenticated by the dashboard. It serves the dashboard HTTP routes (for example `GET /api/sessions`) but no OpenAI-compatible `/v1/*` API. It accepts a bearer token, but only a token issued after an interactive login (native-app flow) or a process-wide session token. It has no native TLS, no per-device token and no operator revocation of one device. PR-1 is therefore a **facade** that adds authentication, per-device tokens, revocation and TLS.

## References

| Item | Value |
| --- | --- |
| Public documentation | [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server), read on 2026-10-28. It describes the OpenAI-compatible API server, not `hermes serve`. |
| Documented version | none. The page states no version number. It carries a "Breaking change (July 2026)" notice. |
| Observed target | `hermes serve` 0.22.5, as recorded in the decision of the user on 2026-10-28 |
| Code read | Public repository [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) at tag `v0.22.5`, commit `bf0203a794a07aac3ff764972ab9087baa4e4f4e`, read-only. Files: `hermes_cli/main.py`, `hermes_cli/subcommands/dashboard.py`, `hermes_cli/web_server.py`, `hermes_cli/web_server_lifecycle.py`, `hermes_cli/web_routers/sessions.py`, `hermes_cli/dashboard_auth/` (`middleware.py`, `routes.py`, `native_flow.py`, `token_auth.py`, `base.py`, `public_paths.py`), `gateway/platforms/api_server_room_grants.py`, `gateway/hosted_rooms.py`. |
| Command outputs | `hermes --version`, `hermes serve --help` and `hermes serve --status` were run on a local test instance at Hermes v0.22.2 (2026.9.24), upstream commit `d923a5eb`. They were not re-run at 0.22.5: the 0.22.5 build was not installed. The help strings were re-read in the 0.22.5 source (`hermes_cli/subcommands/dashboard.py`). |

A statement "the page does not mention X" means the page-to-text output did not contain X. A statement "no call made" means the code shows the route or mechanism, and no request was sent to it.

## Scope of the inventory

- Done: `hermes --version`, `hermes serve --help`, `hermes serve --status` (0.22.2 instance), and a code read at tag `v0.22.5`.
- Not done: any write, any authenticated call, any call to `hermes serve` 0.22.5, any inventory of a production Hermes. The issue forbids a production change, and no read-only access to production is part of the repository.
- The earlier spikes [S5-sessions.md](S5-sessions.md) and [S8-version.md](S8-version.md) (2026-10-18) stay the evidence for the sessions and capabilities routes of the separate API server platform. They were not replayed.

## Table

`ok` = proven by a tool result of this spike, by a cited earlier spike, or by the code read at tag `v0.22.5` (the code read proves that a route or mechanism exists, not that a call succeeds). `absent` = proven missing in the code read. `unknown` = not proven.

| Capability | Status | Evidence | Gap with the product needs |
| --- | --- | --- | --- |
| Service on the target | ok | `hermes serve` runs `cmd_dashboard` with `headless_backend` (`hermes_cli/main.py`), which calls `web_server.start_server(headless=True)`: the same FastAPI `app` as the dashboard, without the web UI (`app.state.serves_spa = not headless`). Help string: "the JSON-RPC/WebSocket gateway the desktop app and remote clients connect to". Defaults: host `127.0.0.1`, port 9119 (`subcommands/dashboard.py`). | The help string names JSON-RPC/WebSocket, while the same process also serves the HTTP routes below. Which of them match the product contract is not verified |
| OpenAI-compatible API with bearer token on the target | absent | Not reachable on the observed target (decision of 2026-10-28). The `/v1/*` routes belong to the API server gateway platform (`gateway/platforms/api_server*.py`). The routers imported by `web_server.py` are the `hermes_cli/web_routers/` modules. | The product routes under `/v1/` (`/v1/runs`) are not served by the target |
| Sessions list: `GET /api/sessions` | ok | `hermes_cli/web_routers/sessions.py` declares `@list_router.get("/api/sessions")` (query: `limit` up to 100, `offset`, `order`, `archived`, `source`, `full`, `profile`). `web_server.py` includes it with `app.include_router(_sessions_routes.list_router)`. The same module declares `/api/sessions/{session_id}`, `/messages`, `/timeline`, `/export`. Code read only, no call made. | Compatibility of the request and response with the product contract ([S5-sessions.md](S5-sessions.md)) is **unknown** |
| Read: sessions and messages, call result | unknown | Documented and observed on the API server platform only (S1, S5, S8). Not tried on `hermes serve`. | Reads have to be re-proven behind the facade |
| Read: runs, models, jobs | unknown | Same as above. No `/v1/runs` route on the target. | Reads have to be re-proven behind the facade |
| Write: runs, sessions, chat | unknown | Observed on the API server platform only (S1, S3, S4). Not tried on `hermes serve`. | Writes have to be re-proven behind the facade |
| The single write of this spike | deferred | Deferred to PR-1 by decision of the user on 2026-10-28. | none |
| TLS (native) | absent | `uvicorn.Config(...)` in `_build_uvicorn_server` (`web_server.py`) and in `web_server_lifecycle.py` sets no `ssl_keyfile` or `ssl_certfile`; `rg "ssl_keyfile\|ssl_certfile" hermes_cli gateway` returns 0 match. The code expects a TLS terminator in front (`proxy_headers=bool(app.state.auth_required)`, comment "Gated mode runs behind a TLS terminator"). | A link that leaves the host has no encryption from Hermes. The facade has to provide TLS |
| Bind: loopback | ok | `hermes serve --host` defaults to `127.0.0.1`. | Matches the PRD: SSH tunnel to loopback |
| Bind: beyond loopback | ok | `should_require_auth(host)` is true for any non-loopback host. Startup exits (`SystemExit`) when the gate is on and no auth provider is registered. `--insecure` is "DEPRECATED / NO-OP"; "a public bind always requires an auth provider (password or OAuth)"; advice: "Bind 127.0.0.1 + tunnel to keep it local". Real reach from another host: **unknown**, not tested. | The PRD risk "server exposed beyond loopback" stays gated by an auth provider, in plain HTTP |
| Auth: native method | ok | `dashboard_auth/base.py`: an interactive `Session` (user id, e-mail, org, access and refresh tokens) from a password or OAuth provider. Two ways to carry it: session cookies (browser), or the native-app flow below (no cookie). Providers register through `dashboard_auth/registry.py`. | Login by a person. No credential the app can mint alone |
| Auth: bearer token from the native-app flow (RFC 8252) | ok | `dashboard_auth/routes.py`: `GET /auth/native/authorize` (PKCE `S256`, loopback `redirect_uri`, interactive provider login), `POST /auth/native/token` (code and verifier to tokens), `POST /auth/native/refresh` (refresh token rotation, 401 `session_expired` when it fails). Tokens are in the JSON body, no cookie. `dashboard_auth/middleware.py` (`gated_auth_middleware`) accepts `Authorization: Bearer <provider access token>` on any non-public path, so it reaches `/api/sessions`. Code read only, no call made. | The gate runs only when `app.state.auth_required` is true: a non-loopback bind, or a non-loopback `dashboard.public_url`. On the loopback bind of the SSH tunnel it is not engaged. Whether the app can run the interactive login through a tunnel is **unknown** |
| Auth: process-wide session token (ungated loopback bind) | ok | `web_server.py`: `_SESSION_TOKEN` is `HERMES_DASHBOARD_SESSION_TOKEN` or a fresh `secrets.token_urlsafe(32)` per start. `auth_middleware` requires it on `/api/*` (except the public paths) as header `X-Hermes-Session-Token` or as `Authorization: Bearer <token>`. | One shared token that dies with the process, not one per device. How a remote client obtains it from `hermes serve` (the code comment says it is injected into the web UI page, which `serve` does not mount) is **unknown** |
| Auth: service tokens (`register_token_route`) | absent for the product routes | `dashboard_auth/token_auth.py`: a service bearer token is accepted only on exact paths registered with `register_token_route`. The only caller outside tests is the drain route of a plugin (`plugins/dashboard_auth/drain/__init__.py`). This mechanism is separate from the native-app bearer above. | No service token reaches a session or run route |
| Auth: per-device token | absent | The native token payload carries `access_token`, `refresh_token`, `token_type`, `expires_at`, `provider`, `user_id` (`_bearer_payload`). `Session` and `TokenPrincipal` have no device field. `rg -i device hermes_cli/dashboard_auth` finds only the viewport meta tag in `login_page.py`. | The facade has to issue one token per device |
| Auth: revocation of one client | absent as an operator action | `dashboard_auth/base.py` defines `revoke_session(refresh_token)`. Its only caller is `POST /auth/logout`, which reads the refresh token from the session cookies (`read_session_cookies`) and revokes it "best-effort". The native-app flow sets no cookie and has no logout or revoke route. No operator route revokes a chosen device or token. | The facade has to let an operator revoke one device without touching the others |
| Room grants (`HermesRoom`) | ok on the API server platform, unknown for the product | `gateway/platforms/api_server_room_grants.py`: short-lived signed grants with a permission check. Revocation lookups are `room_grant_is_revoked` and `peer_room_grant_is_current` in `gateway/hosted_rooms.py`. Routes `/v1/room-members/invitations`, `/capabilities`, `/grants/refresh`, `/grants/revoke`. The grant is minted through an endpoint that already requires the general API key, for a room member of a trusted home gateway. | These grants are not the general user keys and not per-device tokens. They are not served by `hermes serve`. Their fit for the client is not verified |
| Browser CORS | unknown | Not read for `hermes serve`. | none for a native app |

## Gap with the product needs

The product needs (PRD): one transport, an SSH tunnel to a loopback port, one credential the app can store, no connection outside the tunnel.

1. Met today: loopback bind by default, and an authentication gate on any non-loopback bind.
2. Native TLS is absent. A path that does not go through the SSH tunnel has no encryption from Hermes.
3. Bearer tokens exist but do not fit. The native-app bearer needs an interactive login and works only behind the gate (non-loopback bind). The loopback session token is shared by all clients and its delivery to a remote client is unknown. Service tokens do not reach the session routes.
4. No per-device token exists. A native-app login creates one provider session with no device identity.
5. A session ends only when its holder logs out through the cookie route (`revoke_session`). An operator cannot revoke one device. `HermesRoom` grants revoke, but they serve another purpose and another surface.
6. `GET /api/sessions` is served by the target. Its fit with the product contract is not verified.
7. The code was read at tag `v0.22.5`. No call was made to a 0.22.5 server.

## Decision for PR-1

PR-1 builds a facade in front of the target. The facade provides:

1. authentication of the client;
2. one token per device;
3. revocation of one device;
4. TLS.

The facade is the place where the reads and writes of the product are proven again. It also proves again the `GET /api/sessions` contract against the product.

## Step 2: the single write (deferred)

The user deferred the write to PR-1 on 2026-10-28. The write targets a dedicated test session, never production. The request and the target are chosen in PR-1, against the facade, with the explicit GO of the user.

## Reproduce

Command outputs (0.22.2 instance):

```
hermes --version
hermes serve --help
hermes serve --status
```

Code read (public repository, tag `v0.22.5`):

```
git clone --depth 1 --branch v0.22.5 https://github.com/NousResearch/hermes-agent.git
rg -n "ssl_keyfile|ssl_certfile" hermes_cli gateway
rg -n "/auth/native|_extract_bearer" hermes_cli/dashboard_auth
rg -n "register_token_route" --glob '!tests/**' .
rg -n '"/api/sessions"' hermes_cli/web_routers/sessions.py
rg -n -i "device" hermes_cli/dashboard_auth
rg -n "revoke_session" hermes_cli/dashboard_auth
```
