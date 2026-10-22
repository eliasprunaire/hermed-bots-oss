# S8: read the Hermes version

Status: observed. Feeds `version` (information only, A7) and the degraded mode of HD-04.

Observed on `hv-hermes-test` (image `hv-hermes:spike`), 2026-10-18. Hermes v0.22.2 (2026.9.24), upstream commit `d923a5eb487a17c0a68801bba9ef0f56c81040a8`. The model is the fake provider (Q6 option s1). Every request that needs a key carries `Authorization: Bearer ****`. The key is random and lives in the container only.

## Result

The API tells its version. `GET /health` answers without a key and carries a `version` field. The PRD wording "source `unknown`" is replaced by this source. `GET /v1/capabilities` lists features and endpoints, never a number, as the doc says.

## References

- Doc: [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server) for `/health` and `/v1/capabilities`.
- Code at `d923a5eb`, read in the container (`/opt/hermes`), not modified:
  - `gateway/platforms/api_server.py:2425` (`_handle_health`) returns `{"status", "platform", "version"}`. `:209` (`_hermes_version`) returns `get_version_info().base_version`.
  - `hermes_cli/version_info.py:26` (`VersionInfo`): `base_version` comes from the install stamp, then from git, and falls back to the literal `unknown` when neither exists (`:171`, `:254`). The `unknown` value was not observed.
  - `gateway/platforms/api_server.py:2512` (`_handle_capabilities`), flags at `:67`, endpoint table at `:78`.
  - `gateway/platforms/api_server.py:1685` (`_handle_profile_ingress`), registered last at `:4492`, and `:1700` (profile prefix middleware).

## Where the version is

| Source | Key | Answer |
| --- | --- | --- |
| `GET /health` | no | `{"status": "ok", "platform": "hermes-agent", "version": "0.22.2"}` |
| `GET /p/hv-bot-a/health` | yes | same body |
| `GET /health/detailed` | yes | `status`, `readiness`, `version: "0.22.2"`, `gateway_state`, `platforms` |
| `hermes --version` | shell on the host | `Hermes Agent v0.22.2 (2026.9.24) · upstream d923a5eb` |
| `GET /v1/capabilities` | yes (401 without) | no version field |

- The `version` of the API is the base version `0.22.2`. It has no build date and no commit. `hermes --version` needs the second command channel (S6), so the app does not use it.
- `GET /health` has no profile prefix. HD-02 recorded it as the contract `version` in both fixtures: `0.22.2` in `hermes-current`, `0.22.1` in `hermes-previous` (container `hv-hermes:previous`). This session did not run 0.22.1 again.

## `/v1/capabilities`

```
GET /v1/capabilities   (also under /p/hv-bot-a/)
HTTP/1.1 200 OK
{"object": "hermes.api_server.capabilities", "platform": "hermes-agent", "model": "hermes-agent", "auth": {…}, "runtime": {…}, "features": {…}, "endpoints": {…}}
```

- `features` holds booleans such as `run_approval_response`, `session_model_lock`, `session_chat` and `session_resources`, plus `runs_idempotency` and `browser_extension_control` objects.
- `endpoints` maps a name to a method and a path, for example `run_approval` to `POST /v1/runs/{run_id}/approval`, `session_model_lock` to `POST /api/sessions/{session_id}/model` and `sessions` to `GET /api/sessions`.
- No key of the body holds a version or a number. The table `endpoints` could list the routes in one request. HD-04 does not use it: neither fixture nor the fake server has the route, so the probe would prove nothing on them.

## How a missing route looks

HD-04 disables a contract when its route answers 404. A 404 also means a missing profile, session or run, so the shape of the body decides.

| Request | Status | Body |
| --- | --- | --- |
| `GET /p/hv-bot-a/v1/nope`, `PUT /p/hv-bot-a/api/sessions` (route absent, profile served) | 404 | `text/plain`: `Unknown or unconfigured profile` |
| `GET /p/nope/v1/models` (profile not served) | 404 | JSON `{"error": "Unknown or unconfigured profile"}` |
| `POST /p/hv-bot-a/api/sessions/hd-probe/chat` and `…/model` (session absent) | 404 | JSON `error.code: "session_not_found"` |
| `GET /p/hv-bot-a/v1/runs/hd-probe/events` and `POST …/approval` (run absent) | 404 | JSON `error.code: "run_not_found"` |
| `POST /p/hv-bot-a/v1/runs {"input": ""}` | 400 | JSON `Missing 'input' field` |
| `POST /p/hv-bot-a/api/sessions` with `{pas du json` or an empty body | 400 | JSON `Invalid JSON in request body` |
| `GET /p/hv-bot-a/api/sessions` | 200 | JSON `{"object": "list", "data": [], "limit": 50, "offset": 0, "has_more": false}` |

- The session list held 0 entries before and after the two `POST /api/sessions` calls that failed with 400. An invalid body creates no session, so `new_session` has a probe without side effect.
- `OPTIONS /p/hv-bot-a/api/sessions` answers 403. It cannot tell which methods a path takes.
- The fake server answers a dropped route with JSON `{"error": "404: Not Found"}`, the real server with `text/plain`. A probe must treat both as "route absent". A 404 carries a route only when `error.code` is `session_not_found` or `run_not_found`.
- The real server never dropped a route in this session. Only the fake server does (`HV_FAKE_MODE=drop-route`).

## Not observed

- A `base_version` of `unknown`, or any version other than 0.22.2 on a live container.
- A route removed from a real Hermes.
- `GET /p/<profile>/health` without a key.

## Reproduce

```
export HV_TEST_API_KEY=$(openssl rand -hex 24)
.cursor/skills/verify-hermed-bots/scripts/hv-hermes-env.sh up orb
curl -sS http://127.0.0.1:18642/health
curl -sS -H "Authorization: Bearer $HV_TEST_API_KEY" http://127.0.0.1:18642/v1/capabilities
curl -sS -H "Authorization: Bearer $HV_TEST_API_KEY" http://127.0.0.1:18642/p/hv-bot-a/v1/nope
docker exec hv-hermes-test hermes --version
.cursor/skills/verify-hermed-bots/scripts/hv-hermes-env.sh down orb
```
