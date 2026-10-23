# Spike S1 to S7 (HD-01)

Status: the spike ran on 2026-10-18 against `hv-hermes-test`. Seven items observed, none impossible. Five findings need a decision from the user; they are listed below as questions, without a proposed replacement.

Source: `docs/plans/hermed-bots.md`, section "Record the spike S1 to S7 against the OrbStack Hermes (HD-01)". Item definitions: `docs/prd/prd-consolide.md`, spike table.

## Decisions

The plan says HD-01 does not start without Q6 and Q11. The user answered both in comments on issue #5.

| Id | Question | Decision | Source |
| --- | --- | --- | --- |
| Q6 | Which test model source? | s1 (fake provider or replayed recorded responses, zero cost) for the CI and most tests. s2 (free local model in the container) for the end-to-end tests. No paid API. Option s4 stays out. | [issue #5, comment 6250312790](https://github.com/eliasprunaire/hermed-bots/issues/5#issuecomment-6250312790), validated by the user on 18/10 at 13:26 |
| Q11 | Which Hermes version does `hv-hermes:spike` use? | The latest published Hermes (`latest`). The OrbStack test container follows `latest`. The exact version observed goes in each report and each fixture. The daily compatibility test runs against `latest`. The "previous version" of #6 is the release just before `latest`. | [issue #5, comment 6250324290](https://github.com/eliasprunaire/hermed-bots/issues/5#issuecomment-6250324290), decided by the user on 18/10 at 15:11 |

The user then decided on the spike findings (issue #6). Findings 1 and 2 below are settled by S6 and S4. The contracts apply S6 and S4 (`fixtures/README.md`).

| Id | Question | Decision | Source |
| --- | --- | --- | --- |
| S6 | Where does the profile list come from? | A second SSH channel, read only, runs `hermes profile list`. "Decommissioned" means a stopped profile (Gateway `stopped`, 404 on the API), not a deleted one. | [issue #6, comment 6250948948](https://github.com/eliasprunaire/hermed-bots/issues/6#issuecomment-6250948948), decided by the user on 18/10 at 16:15 |
| S4 | How do `/model` and `/new` reach Hermes? | The app uses the session chat routes, which honor the model lock. `/model` and `/new` are sent as real commands, never as text. | same comment |
| S3 | Emergency stop | K1 (API cancel) first, then K3 (stop the Hermes process of the profile) if a background process survives. | same comment |
| S7 | Keys | The user turns on `API_SERVER_KEY` per profile after the acceptance test. Until then, tests run on `hv-hermes-test` only. | same comment |
| S2 | Gateway restart | Accepted. The app shows "interrupted" and offers to run the turn again. | same comment |
| Lane | Mac lane from the cloud | A GitHub issue queue (dedicated label) read by the Mac runner, which posts the evidence as a comment. Zero cost. | same comment |

The first comment on issue #5 also says to pin the version installed in `hv-hermes-test` while Q11 is open. The second comment answers Q11 with `latest` and replaces that instruction.

This spike used Q6 option s1 only. The fake provider is a model stand-in, not a Hermes stand-in: every route, event and field below comes from a real Hermes process. Option s2 (a free local model) was not run. The `hv-fake-hermes.py` fake server was not used for any observation.

## Version observed

| Item | Value |
| --- | --- |
| Hermes | v0.22.2 (2026.9.24), `hermes --version` and `GET /health` |
| Upstream commit | `d923a5eb487a17c0a68801bba9ef0f56c81040a8` (tag `v0.22.2`) |
| Base image | `nousresearch/hermes-agent:latest`, index digest `sha256:36099926da316742423544e055d4734777105ffe6341873af5459b957d0c2919`, arm64, Python 3.14.7 |
| Spike image | `hv-hermes:spike`, built from `.cursor/skills/verify-hermed-bots/orb/Dockerfile` |
| Doc pages read | [Programmatic Integration](https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration), [Profiles](https://hermes-agent.nousresearch.com/docs/user-guide/profiles), [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server) |
| Code read | a read only shallow clone of the tag, in a scratch folder outside the repository |

`latest` and `v0.22.2` carried the same image digests on Docker Hub on 2026-10-18. `hermes --version` prints `Hermes Agent v0.22.2 (2026.9.24) · upstream d923a5eb`, and `d923a5eb` is the commit of the tag `v0.22.2`.

## Items

Each report holds the doc anchor, the code path at the commit above, the captured requests and responses, and a "Reproduce" block.

| Item | Point | Feeds | Status | Evidence file | Finding |
| --- | --- | --- | --- | --- | --- |
| S1 | Runs: create a turn, follow its events, reach a terminal state | `send_message`, `run_events` | observed | [S1-runs.md](S1-runs.md) | `POST /v1/runs` then `GET /v1/runs/{id}/events` (SSE with `Last-Event-ID`); states `completed`, `failed`, `cancelled`, `interrupted` seen |
| S2 | Resume a turn by id after a cut, and avoid a double send | replay of `run_events` | observed | [S2-resume.md](S2-resume.md) | `Last-Event-ID` replays; `Idempotency-Key` returns the same run; no key means a double send; after a gateway restart the run is `interrupted` and its events are gone |
| S3 | Cancel a turn, including a running tool | `cancel_run` | observed | [S3-cancel.md](S3-cancel.md) | `POST /v1/runs/{id}/stop` ends the turn and the foreground process tree in about 1 s; a `background=true` process outlives the run |
| S4 | Send `/model` and `/new` through the API | `set_model`, `new_session` | observed | [S4-model-and-new.md](S4-model-and-new.md) | the text commands are not interpreted; `POST /api/sessions` makes an empty session; `POST /api/sessions/{id}/model` locks the model on that session for the session chat routes only |
| S5 | List the past sessions of a profile and reopen one | `list_sessions` | observed | [S5-sessions.md](S5-sessions.md) | `GET /api/sessions` and `/api/sessions/{id}/messages`, scoped to the profile; sessions of any `source` are listed |
| S6 | Profile list: source, and exclusion of the inactive `hv-old` | `list_profiles` | observed | [S6-profiles.md](S6-profiles.md) | no HTTP route; the source is `hermes profile list` (CLI) and `profiles/`; a parked profile shows `stopped` and gets 404 on the API |
| S7 | Reach the nine profiles through the API port | routing of all contracts | observed | [S7-multiplexing.md](S7-multiplexing.md) | `/p/<profile>/` prefix on one port, one key per profile; the nine active profiles answer, `hv-old` and unknown names get 404 |

## Findings that wait for a decision

These are facts the plan or the PRD did not expect. The spike does not propose a replacement for any of them.

1. S6, transport (settled by the S6 decision above: SSH read-only `hermes profile list`, stopped profiles excluded). No HTTP route lists the profiles. The PRD makes the SSH tunnel to the API port the only transport. Reading the list from `hermes profile list` needs a second command channel on the Hermes host. On the API port alone, the app can only test a known name (`/p/<name>/v1/models`: 200 served, 404 not served). Which of these the app does is the user's decision, as is what "decommissioned" means among `parked`, `stopped` and deleted.
2. S4, the PRD wording (settled by the S4 decision above: session chat routes). `/model` and `/new` typed as text are sent to the model as plain text. The two jobs have their own routes. The model lock is read by `POST /api/sessions/{id}/chat` and `…/chat/stream`; `POST /v1/runs` ignores it. The contracts `set_model` and `new_session` must name these routes, and `send_message` must pick the turn route that honors the lock, or pass `model` on every run.
3. S3, kill switch coverage. A `background=true` process belongs to the gateway and survives `stop`, also when the turn is over. The PRD levels K1 (API cancel) and K3 (stop the Hermes process) differ on that case.
4. S7, keys. Each profile needs its own `API_SERVER_KEY` in its `.env`. A profile without one is unreachable through its prefix. If the real profiles have no such key today, each of the nine needs one, and the PRD leaves the activation to the user.
5. S2, restart. After a gateway restart a running turn is not resumed: status `interrupted`, no events, partial answer not kept. Only the user message is in the transcript.

## Cloud lane worker to Mac lane

The plan asks to settle how a cloud lane worker dispatches a Mac lane to the scheduled launcher task and reads `$HV_WORK/evidence/`. Result: decision pending. No such mechanism exists on this Mac today.

- The installed runner is the scheduled launcher task. It discovers the repositories by a GitHub topic and runs the per-repository runner for each.
- The per-repository runner writes `heartbeat.json` and `lock.json` on the branch `runner-heartbeat` of the repository, and takes the open issues labeled `dev-lead:task`. While `lock.json` says `owner: cloud`, the Mac executes nothing. `AGENTS.md` says the cloud agents take over when the Mac heartbeat is older than 10 minutes.
- Neither launcher script contains `hv-run`, `HV_WORK`, `evidence` or `lane`. They never call `hv-run.sh` and never read `$HV_WORK/evidence/`. The local work folder does not exist on the Mac.
- `hv-run.sh` can be started by hand: `HV_UNDER_RUNNER=1 scripts/hv-run.sh api orb`. It writes its evidence under `$HV_WORK/evidence/<mode>-<stamp>/`.

What the user has to decide: the channel a cloud worker uses to ask for a Mac lane, and the channel it uses to read the evidence back. This spike did not invent one.

## Test environment

- Image: `FROM nousresearch/hermes-agent:latest` (Q11). It adds `fake-llm.py` (Q6 s1), `hv-start.sh`, and sets `API_SERVER_ENABLED=true`, `API_SERVER_HOST=0.0.0.0`, `GATEWAY_MULTIPLEX_PROFILES=true` as image environment, so the API server is on inside this container only.
- Key: `HV_TEST_API_KEY` reaches the container with `docker run --env HV_TEST_API_KEY` (no value on the command line). `hv-start.sh` copies it into `API_SERVER_KEY` and into the `.env` of every profile, inside the container volume. Hermes refuses to start with a key under 16 characters; `up orb` exits 32 in that case. The selftest checks that the key never appears in the `docker` arguments.
- Port relay: Hermes listens on `0.0.0.0:8642` inside the container and `docker run -p 127.0.0.1:18642:8642` publishes it on the Mac loopback only. A loopback bind inside the container would not be reachable through the published port. No socat and no tunnel.
- Mounts: `docker run` has no `-v` and no `--mount`. The base image declares `VOLUME /opt/data`, so Docker creates one anonymous volume. It is internal and `docker rm -v` removes it. `hv-hermes-env.sh` refuses any bind mount and any source under `/.hermes` or `/.local/bin` (exit 31) and removes the container.
- Profiles seeded by `hermes profile create <name> --no-alias --no-skills`: `default` (the Hermes home), `cyber`, `gaming`, `ia`, `perso`, `recherches`, `sport`, `tiny`, `wikilibriste`, `hv-bot-a`, `hv-bot-b`, and `hv-old` with the `gateway.parked` marker file. Each profile config points to the fake provider (`model.provider: custom`, `base_url: http://127.0.0.1:9999/v1`).
- Fake provider triggers: `HV_SLOW`, `HV_FAIL`, `HV_TOOL_SLEEP`, `HV_TOOL_LONG` (`sleep 400`, HD-05), `HV_TOOL_DETACH`, `HV_TOOL_BG`, `HV_LOOP` (the same tool call six times, HD-05; see `orb/fake-llm.py`).
- Readiness: `up orb` waits for `readiness: ok` on `GET /health/detailed` (authenticated) and for `GET /p/hv-bot-a/v1/models` and `/p/hv-bot-b/v1/models` to answer. `readiness` is `degraded` for a few seconds after start (gateway `starting`), so `/health` alone is too early.
- `doctor orb` prints `container=… running=true`, `hv.owner=verify-hermed-bots`, the no mount line, `api: readiness=ok hermes=0.22.2`, and the profile line. It exits 31 on a mount and 33 when the API is not ready.

## Measurements

Five cycles on code commit `fa45516`, each `up orb`, `doctor orb`, one turn, `down orb`. Those cycles ran before `up orb` rebuilt the image with `docker build --pull` on every run (see the "Captures" item under "Not done in this PR"), so the `up` column does not include that rebuild. The median is not measured on the current head. The numbers are wall times on this Mac (Apple silicon, OrbStack), image already built. The first event is timed from the `POST /v1/runs` to the first `data:` line of the event stream.

| Cycle | `up` to ready `doctor` | `send_message` to first event |
| --- | --- | --- |
| 1 | 28.2 s | 708 ms |
| 2 | 29.4 s | 787 ms |
| 3 | 29.0 s | 845 ms |
| 4 | 27.6 s | 870 ms |
| 5 | 27.4 s | 698 ms |
| median, measured on `fa45516` | 28.2 s | 787 ms |

The budgets of the plan are 180 s and 5 s. Both are proposals, not measurements; these values are under both.

Trunk (`origin/main` at `31b568965ef989b2c3a4882b3c4b9157c4fb90ac`) gave two exit codes for `up orb`. With no `hv-hermes:spike` image: 125, the exit code of `docker run` ("pull access denied"). The plan expected a code from 30 to 34. With the image present, run once between cycles 2 and 3: 33 after 125.1 s, because trunk passes `API_SERVER_HOST=127.0.0.1` into the container and the published port cannot reach it.

## Not done in this PR

- Branch history: `origin/runner/issue-5` still held the two commits of PR #7, which `main` already has as one squash commit. They are joined by a merge commit that keeps this branch's tree (`git merge -s ours`). No history was rewritten and nothing was force pushed.
- Captures: the `hd01-*.png` files in this folder are renders of the terminal output of one live pass at code commit `678b995` (ImageMagick, `label:@file` on the text; not window screenshots). They are: [hd01-api-orb.png](hd01-api-orb.png) (lane 1), [hd01-s1-run.png](hd01-s1-run.png), [hd01-s2-resume.png](hd01-s2-resume.png), [hd01-s3-cancel.png](hd01-s3-cancel.png), [hd01-s4-model-new.png](hd01-s4-model-new.png), [hd01-s5-sessions.png](hd01-s5-sessions.png), [hd01-s6-profiles.png](hd01-s6-profiles.png), [hd01-s7-multiplex.png](hd01-s7-multiplex.png), [hd01-guard.png](hd01-guard.png) (lane 9), [hd01-netwatch.png](hd01-netwatch.png) (lane 10) and [hd01-env.png](hd01-env.png) (`up orb`, `doctor orb`, `down orb`). The raw text of the pass is [hd01-live.txt](hd01-live.txt). The author does not launch a verifier. The reduced scope of the issue (comment of 18/10 16:40) makes S1 to S6 mandatory; S7 stays in the PR as an extra observation and is judged under #9. `up orb` rebuilds `hv-hermes:spike` with `docker build --pull` on every run (Q11, latest); the tested version, `0.22.2`, comes from `/health` and goes in `env.json` and in the daily report. Lane 3 is covered by the real cut: `docker network disconnect bridge hv-hermes-test` during a `HV_SLOW` turn, refused connection during the cut, `docker network connect`, resume by `Last-Event-ID`, one turn, one user message.
- Lane 1: `scripts/hv-spike-probe.py` replays the shapes recorded in S1 to S7 (nine probes: send and events, failed run, resume and idempotency, network cut with `docker network disconnect`, cancel with the tool process, new session and model lock, session list and reopen, profile list, nine profile prefixes). `hv-run.sh api orb` runs it instead of the invented fixture and exits 0 at head. HD-02 replaced the fixtures with the recorded shapes (`fixtures/README.md`), and `hv-run.sh api orb` runs `hv-contract-check.py` before this probe. The probe does not cover the items listed in the next line.
- Not observed: `POST /v1/chat/completions`, `POST /v1/responses`, the terminal event of `…/chat/stream`, the 409 `permission_denied` for a session of another surface (Telegram, TUI, Desktop), `POST /v1/runs/{id}/resolve-unknown`, a network cut longer than six seconds, and the option s2 model.

## Reproduce

```
export HV_TEST_API_KEY=$(openssl rand -hex 24)
.cursor/skills/verify-hermed-bots/scripts/hv-hermes-env.sh up orb
.cursor/skills/verify-hermed-bots/scripts/hv-hermes-env.sh doctor orb
# requests: see the "Reproduce" block of each S file
.cursor/skills/verify-hermed-bots/scripts/hv-hermes-env.sh down orb
.cursor/skills/verify-hermed-bots/scripts/hv-selftest.sh
```
