# S7: reach the nine profiles through one API port

Status: observed. The mechanism is the `/p/<profile>/` path prefix on the single API port, with one key per profile. Feeds the routing of all contracts.

Observed on `hv-hermes-test` (image `hv-hermes:spike`), 2026-10-18. Hermes v0.22.2 (2026.9.24), upstream commit `d923a5eb487a17c0a68801bba9ef0f56c81040a8`. The model is the fake provider (Q6 option s1). Every request carries `Authorization: Bearer ****`. The Mac side port is `127.0.0.1:18642`, published from the container port 8642.

## References

- Doc: [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server), section "Multi-profile routing and ports": with `gateway.multiplex_profiles` the routes are served under `/p/<profile>/`, each named prefix needs that profile's own `API_SERVER_KEY` from `~/.hermes/profiles/<profile>/.env`, the default key gets 401 on named prefixes, and a profile without a key is unreachable. Without multiplexing, each profile needs its own listener port. [Profiles](https://hermes-agent.nousresearch.com/docs/user-guide/profiles) names `gateway.multiplex_profiles` and `profile_routes` and links elsewhere for details.
- Code at `d923a5eb`: `gateway/platforms/api_server.py:4488` (every route is also mounted at `/p/{profile}…`), `:1647` (`_resolve_request_profile`), `:1535` (`_expected_api_key`: the key comes from the profile scope), `:1559` (`_check_auth`: a named profile with no usable key fails closed), `:4421` (startup guard: key of at least 16 characters, not a placeholder). `gateway/config.py:46` (`GATEWAY_MULTIPLEX_PROFILES` overrides the config key). `hermes_cli/profiles.py:1135` (`profiles_to_serve`).

## How the container enables it

`orb/Dockerfile` sets `GATEWAY_MULTIPLEX_PROFILES=true`, `API_SERVER_ENABLED=true` and `API_SERVER_HOST=0.0.0.0` as image environment (inside the container only). `orb/hv-start.sh` writes the common test key into a profile `.env` only when that file has no `API_SERVER_KEY=` line. A distinct key already in a profile `.env` stays after a restart. The write, when it happens, lands in the container volume. It never reaches the Mac disk and is not an image layer. No secret is printed.

The per-profile key is the only documented way to make a prefix reachable. An empty volume therefore gets the common test key on first start. Distinct keys were tested on two profiles (below).

## Result: the nine active profiles

```
profile        GET /p/<profile>/v1/models      model id        POST /p/<profile>/v1/runs
default        200 OK                          hermes-agent    202 {"run_id": "run_51d5…", "status": "started", …}
cyber          200 OK                          cyber           202 …
gaming         200 OK                          gaming          202 …
ia             200 OK                          ia              202 …
perso          200 OK                          perso           202 …
recherches     200 OK                          recherches      202 …
sport          200 OK                          sport           202 …
tiny           200 OK                          tiny            202 …
wikilibriste   200 OK                          wikilibriste    202 …
hv-bot-a       200 OK                          hv-bot-a        202 …
hv-bot-b       200 OK                          hv-bot-b        202 …
hv-old         404 Not Found                   -               404 {"error": "Unknown or unconfigured profile"}
nope           404 Not Found                   -               404 {"error": "Unknown or unconfigured profile"}
```

- The default profile answers at `/p/default/…` and without prefix (`GET /v1/models` returned 200).
- `hv-old` (parked, see S6) and an unknown name get the same 404 body.
- One port serves all of them. A per port layout (8643, 8644, …) was not needed and not tried.

## Keys and isolation

| Check | Observed |
| --- | --- |
| Wrong key on `/p/cyber/…` | 401 `gateway_auth_failed` |
| No key on `/p/cyber/…` and on the unprefixed route | 401 |
| `GET /p/cyber/health` with no key | 200 (`/health` stays open under a prefix) |
| `ia` given its own new key in its `.env` (no restart): the default key | 401 |
| `ia`: its own key | 200 |
| `sport` with no `API_SERVER_KEY` in its `.env`: the default key | 401 (fails closed) |
| The default profile after those changes | 200 |
| Run of `hv-bot-a` read through `/p/hv-bot-b/v1/runs/<id>` | 404 `run_not_found`; the same id on `/p/hv-bot-a/` returns 200 |
| Sessions of `hv-bot-a` listed through `/p/hv-bot-b/api/sessions` | not listed (see S5) |

The key file of a profile is read at request time: the change of the `ia` key took effect without restarting the gateway. The key rows of this table were run on an earlier build of the same image, which differed from the final one only in `orb/fake-llm.py`.

## Consequences recorded, not decided

- Each profile has its own key. The PRD already says "clé(s) `API_SERVER_KEY`" in the Keychain.
- A profile whose `.env` has no `API_SERVER_KEY` is unreachable through the prefix (observed on `sport`).
- The PRD fallback for S7, one port per profile with the amendment of Q3, is not triggered by this result.

## Reproduce

```
for p in default cyber gaming ia perso recherches sport tiny wikilibriste hv-bot-a hv-bot-b hv-old; do
  printf '%s ' "$p"; curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $HV_TEST_API_KEY" "http://127.0.0.1:18642/p/$p/v1/models"
done
```
