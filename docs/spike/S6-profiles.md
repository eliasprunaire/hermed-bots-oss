# S6: the profile list, its source, and the inactive profile

Status: observed. Feeds `list_profiles`. No HTTP route of the API server lists the profiles. The source found is the Hermes CLI and the profile directories. Whether the app may use a second channel to read it is a decision for the user (see the README).

Observed on `hv-hermes-test` (image `hv-hermes:spike`), 2026-10-18. Hermes v0.22.2 (2026.9.24), upstream commit `d923a5eb487a17c0a68801bba9ef0f56c81040a8`. Every request carries `Authorization: Bearer ****`. The seeded profiles: `default` (the Hermes home itself), the eight other active names of the PRD (`cyber`, `gaming`, `ia`, `perso`, `recherches`, `sport`, `tiny`, `wikilibriste`), the test profiles `hv-bot-a` and `hv-bot-b`, and the inactive `hv-old`.

## References

- Doc: [Profiles](https://hermes-agent.nousresearch.com/docs/user-guide/profiles): `hermes profile list` "show all profiles with status", each profile is a directory under `~/.hermes/profiles/`, a directory counts as a profile only if it holds an identity file, the default profile is `~/.hermes` itself. The page has no state called "inactive". [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server): no profile list route.
- Code at `d923a5eb`: `hermes_cli/profiles.py:1135` (`profiles_to_serve`: the default plus every live named profile, skipping tombstoned, `gateway.standalone` and parked ones), `:1123` (`parked_marker_path`: the file `gateway.parked` in the profile directory, written by `hermes -p X gateway stop`). `gateway/platforms/api_server.py:1647` (`_resolve_request_profile`: a prefix outside that set gets HTTP 404). Route table: `gateway/platforms/api_server.py:1718`.

## HTTP: no list

Six probes returned HTTP 404: `GET /api/profiles`, `/v1/profiles`, `/profiles`, `/api/profile`, `/p/`, `/p`. `GET /health/detailed` and `GET /v1/capabilities` carry no profile list. `GET /v1/models` returns one entry named after the profile of the prefix (`hermes-agent` for the default).

What the API port does tell, for a name already known: `GET /p/<name>/v1/models` answers 200 when the profile is served and 404 `{"error": "Unknown or unconfigured profile"}` when it is not.

## CLI: the list

```
$ docker exec -u hermes -e HOME=/opt/data hv-hermes-test hermes profile list

 Profile          Model                        Gateway      Alias        Distribution
 ◆default         hv-fake-1                    running      —            —
  cyber           hv-fake-1                    running      —            —
  gaming          hv-fake-1                    running      —            —
  hv-bot-a        hv-fake-1                    running      —            —
  hv-bot-b        hv-fake-1                    running      —            —
  hv-old          hv-fake-1                    stopped      —            —
  ia              hv-fake-1                    running      —            —
  perso           hv-fake-1                    running      —            —
  recherches      hv-fake-1                    running      —            —
  sport           hv-fake-1                    running      —            —
  tiny            hv-fake-1                    running      —            —
  wikilibriste    hv-fake-1                    running      —            —
```

The output is a text table. `hermes profile list --help` shows no option except `-h`, so there is no JSON mode in this version. The `◆` marks the sticky default.

## The inactive profile

`hv-old` is seeded with the marker `gateway.parked`. Two readings of it:

| Source | `hv-old` |
| --- | --- |
| `hermes profile list` | listed, with Gateway `stopped` while the others show `running` |
| `GET /p/hv-old/v1/models` and `POST /p/hv-old/v1/runs` | HTTP 404 "Unknown or unconfigured profile" |
| directory `profiles/` in the container | present (`profiles/hv-old/`) |

Hermes has no state named "inactive" or "decommissioned". A parked profile is the nearest thing seen. Deleting a profile writes a tombstone before the directory is removed (`hermes_cli/profiles.py:1840`, `mark_named_profile_deleted`; not run here). Which of these means "decommissioned" for Ayo's list (`lead-x`, `buzz`, …) is the user's question and this spike does not settle it.

## Reproduce

```
docker exec -u hermes -e HOME=/opt/data hv-hermes-test hermes profile list
curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $HV_TEST_API_KEY" http://127.0.0.1:18642/p/hv-old/v1/models
```
