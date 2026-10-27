# Hermed Bots plan

Hermed Bots is a native macOS app (SwiftUI and AppKit) that lists the user's Hermes bots, chats with them, switches the session model, and answers tool approvals over one SSH tunnel to the Hermes API server. The sources are `docs/prd/prd-consolide.md` and `docs/prd/spec.md`.
The program enforces one rule. No agent reads, reaches, or holds a credential for example-host. Every spike step and every test runs against the disposable OrbStack container `hv-hermes-test` or the fixture fake server.
Phase 1 is the spike, PRD items S1 to S7, in HD-01 and HD-02. Phase 2 is the adapter layer in HD-03 to HD-05. Phase 3 is the macOS shell in HD-06 and HD-07. Phase 4 is the interface in HD-08 to HD-12. Phase 5 is resume, concurrency, the kill switch, and the daily test in HD-13 to HD-16.
PRD items S8 to S12 ride with the PR that needs them. S8 lands in HD-04, S10 and S11 in HD-05, S12 in HD-07, and S9 in HD-14.
No API route is a fact before HD-01 merges. Contract names such as `list_profiles` and `send_message` are logical names, and every path stays to be verified until a spike file cites it.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a screenshot, a test run, or a SHA. The body is a how-to. The appendices explain and record.

The program runs `.cursor/skills/poteto-mode/playbooks/autopilot-full.md`. Each owner squash-merges its own PR after the root swarm posts a marked verdict. HD-06 to HD-15 change an interaction, so they stop at merge-ready until the operator reviews them. The user keeps the PRD gates, Q1 to Q13, the approval of every command on the Mac, and any spend.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

## Program checklist

### Arm the program

- [ ] State the protocol and this plan to the operator, then stop. Start execution only on the operator's explicit go.
- [ ] Read these from trunk at program start. Re-read them at every tick.
  - [ ] `git show origin/main:.cursor/skills/poteto-mode/playbooks/autopilot-full.md`
  - [ ] `git show origin/main:.cursor/skills/swarm/SKILL.md`
  - [ ] `git show origin/main:.cursor/skills/control-cli/SKILL.md`
  - [ ] `git show origin/main:.cursor/skills/verify-hermed-bots/SKILL.md`
  - [ ] `git show origin/main:.cursor/skills/poteto-mode/playbooks/opening-a-pr.md`
  - [ ] `git show origin/main:.cursor/skills/poteto-mode/playbooks/babysit.md`
  - [ ] `git show origin/main:.cursor/skills/poteto-mode/playbooks/shipping.md`
  - [ ] `git show origin/main:.cursor/rules/babysit-pr.mdc`
  - [ ] `git show origin/main:.cursor/skills/show-me-your-work/SKILL.md`
  - [ ] `git show origin/main:.cursor/skills/deslop/SKILL.md`
- [x] Q1 (where code is written) is answered. On 2026-10-18 at 13:26 Paris the user validated in writing the PRD recommendations for Q1 to Q13, so Q1 is option (a). Claude Code and Codex write the code on the Mac, driven by the user. Source is the Dev Lead log `dev-roster/hermed-bots/etat.md` (19/10 13:53 entry, « validation écrite des 13 recommandations du 18/10 13:26 »). The CHARTE condition is met. Line 52 of the CHARTE allows the Mac as primary for hermes-desktop since the agreement of 2026-10-18 at 13:27 Paris. This repo is `eliasprunaire/hermes-desktop` renamed, as Manager checked in the `etat.md` backups and Dev Lead confirmed on 2026-10-21.
- [x] Q3 (API server only in OrbStack) is answered by the same validation of 2026-10-18 at 13:26 Paris. The API server runs only in the OrbStack test instance. On 2026-10-18 at 16:15 Paris the user added that keys per profile are turned on by the user after the acceptance test ([issue #6 comment](https://github.com/eliasprunaire/hermed-bots/issues/6#issuecomment-6250948948)). S7 found one multiplexed port, so the Q3 port amendment is not needed.
- [x] Q6 (test model without new spend) is answered. The choice is s1 for the CI and most tests and s2 for the end-to-end tests, with no paid API ([issue #5 comment](https://github.com/eliasprunaire/hermed-bots/issues/5#issuecomment-6250312790), validated 2026-10-18 at 13:26 Paris, recorded in `docs/spike/README.md`). The s2 path is not exercised yet, since `hv-hermes:spike` always starts the fake provider. The closing acceptance pass must add an s2 run before delivery.
- [x] Q10 (no example-host access) is answered by the same validation of 2026-10-18 at 13:26 Paris. No agent touches example-host, and the ban below stays in force.
- [x] Q11 (Hermes versions for the test instance) is answered. On 2026-10-18 at 15:11 Paris the user chose `latest` for the test container, and the previous version is the release just before it ([issue #5 comment](https://github.com/eliasprunaire/hermed-bots/issues/5#issuecomment-6250324290), recorded in `docs/spike/README.md`).
- [x] Ayo answered the two Ayo questions. On 2026-10-19 at 13:55 and 13:57 Paris, in the Dev Lead chat, Ayo chose all active profiles, not a pinned list, and the new session button label « Nouvelle session », which sends `/new`, never `/reset`. HD-08 and HD-09 may open.
- [x] Q5 (macOS CI) is answered by the same validation of 2026-10-18 at 13:26 Paris. The CI stays on Linux, Engineer runs the macOS tests on the MacBook, and a macOS GitHub runner needs the free quota or the user's written approval. Source is `dev-roster/hermed-bots/etat.md` (18/10 21:04 entry) and issue #15.
- [x] Q4 (macOS minimum and distribution) is answered. On 2026-10-19 at 06:37 Paris the user chose option d1, a local ad hoc signed app, with the macOS minimum set to the MacBook's version, not below macOS 14. The MacBook runs macOS 27.0.1, so the minimum is macOS 27. HD-06 may open.
- [x] Q2 (kill switch means) is answered. On 2026-10-18 at 13:26 Paris the user chose K1 and K3. K1 is a « Tout arrêter » button that calls the API cancel, if S3 confirms it. K3 is the guaranteed fallback. Ayo stops the Hermes process of the profile on the VM. Cutting the tunnel is not enough. HD-15 may open.
- [x] Q8 (pause notification form) is answered. On 2026-10-18 at 13:26 Paris the user chose both an in-app banner and a macOS notification, the only exception to the out-of-scope « Notifications ». HD-12 may open.
- [ ] Hold the production-host ban. No agent opens SSH to that host, reads its files or history, calls its network address, or stores its keys. `scripts/hv-guard.sh target` refuses `$HV_FORBIDDEN_HOST` with code 22. The name is not in the repo.
- [ ] On the operator's go, arm the audit tick as `/loop 1h` with the tick prompt below. Never leave the cadence to memory.
- [ ] Use this tick prompt, verbatim. "Re-read the execution playbook from trunk. Audit the operation against it and fix drift in this tick. Probe every active lane and judge progress by side effects only. Stand down a stuck lane and dispatch its replacement now. Then post a short status message to the operator in chat only when the audit found a tracked change that no earlier status message reported, such as a PR opened, a code-ready head, a round launched or closed, a verdict, a merge, a stuck agent and the action taken, a blocker added or cleared, or a decision only the operator can make. Name every such change and nothing else. Do not repeat a table, the merged list, or an unchanged blocker. If the audit found none, end the turn with no reply text. Either way, log this tick's row in your decision trail. The row names the items reported, or none."
- [ ] On the operator's hold or stand-down, send every owner a zero-writes order at once.

### Spawn owners

- [ ] Spawn one owner per PR with the full lifecycle the execution playbook names.
- [ ] Follow this dependency graph. Start dependent work only after its parent merges, because autopilot-full never stacks.
  - [ ] HD-01 is first. It branches from `main`.
  - [ ] HD-02 after HD-01.
  - [ ] HD-03 after HD-02.
  - [ ] HD-04 and HD-05 after HD-03. They are independent of each other.
  - [ ] HD-06 after HD-03 and HD-04.
  - [ ] HD-07 after HD-06.
  - [ ] HD-08 after HD-04 and HD-07.
  - [ ] HD-09 after HD-08.
  - [ ] HD-10 and HD-11 after HD-09. They are independent of each other.
  - [ ] HD-12 after HD-05 and HD-09.
  - [ ] HD-13 after HD-11 and HD-12.
  - [ ] HD-14 and HD-15 after HD-11. They are independent of each other.
  - [ ] HD-16 after HD-08 to HD-15.
- [ ] Hold the file boundaries.
  - [ ] HD-01 touches only `docs/spike/**` and `.cursor/skills/verify-hermed-bots/**`.
  - [ ] HD-02 touches only `.cursor/skills/verify-hermed-bots/**`.
  - [ ] HD-03 to HD-05 touch only `Packages/HermesAdapter/**`, `docs/spike/**`, and, for HD-03 only, `.github/workflows/ci.yml`.
  - [ ] HD-06 to HD-15 touch only `HermedBots/**`, `HermedBotsUITests/**`, `HermedBots.xcodeproj/**`, `docs/spike/**`, and `docs/runbook/**`.
  - [ ] HD-16 touches only `.cursor/skills/verify-hermed-bots/**`.
  - [ ] No PR touches `.claude/`, `.codex/`, or `.mcp.json`.
  - [ ] No PR and no lane writes `~/.hermes/hermes-agent` or `~/.local/bin/hermes` on the Mac.
- [ ] Hold the review gate. HD-06 to HD-15 change an interaction. They wait for the operator's review in chat with screenshots and a video before merge.

### PR mechanics, for every PR

- [ ] Resolve the forge once. Default to `gh`; if `command -v origin` succeeds and Origin can resolve the repository, use `origin pr` for every PR operation. Record any fallback to `gh`. Never require `gt`.
- [ ] Open the PR ready, never draft, per **Opening a PR**. Use the run's built-in PR tool when it has one, else `origin pr create --status open --base main` or `gh pr create --base main` according to the resolved forge. A stack child targets its parent branch.
- [ ] Run the repo's lint and typecheck once before the PR-facing push. That is `npm run lint` and `npm test`, plus `swift build` and `swift test --package-path Packages/HermesAdapter` from HD-03 on. Push with hooks on.
- [ ] Run `deslop` before each commit and `/no-comments` before review.
- [ ] Triage every Bugbot and security-reviewer comment per `.cursor/skills/poteto-mode/references/bugbot-triage.md`.
- [ ] Rebase onto current trunk before the code-ready report and babysit. Keep that merge base in fix rounds. Rebase again only at merge prep, on a `git merge-tree` conflict with trunk, or on a CI failure that comes from a change on trunk.
- [ ] Write the PR title in Conventional Commits form. List every agent that worked the PR as `bc-` ids under `## Agents`, and add a Blast Radius section. Add no Co-authored-by trailer and no agent footer.

### Verdict and merge, for every PR

- [ ] A full swarm runs once, at the code-ready head. Another full swarm runs only for new behavior, a redesign, or a large new diff. A rebase, a merge-conflict resolution, or a minor fix gets a single verifier at the new head. Run each full swarm per `.cursor/skills/swarm/SKILL.md`. One gates lane. The ten live lanes from the PR's **Verify, live** block. The perf lane from its **Verify, perf** block. Two or more audit lanes, each with its own focus, that read the diff and the receipts and distrust the PR body. The root audits the receipts in the merge-ready report before the verdict.
- [ ] Clean only when every lane is `PASS`. Findings go back to the owner, including a defect that a lane filed as a note. A new head gets a fresh verdict, except for results that stay valid under the patch-id rule in `.cursor/skills/poteto-mode/playbooks/shipping.md`.
- [ ] The owner squash-merges its own PR with the base-revision copy of `scripts/squash-merge.js`, per `playbooks/shipping.md`. It merges only when a marked `PASS` or `PASS+NOTES` comment with `<!-- dev-lead-verifier -->` cites the head SHA or a SHA with the same `git patch-id`, the comment login differs from the PR author login, and `verdict-gate` is success on that head. The author never launches the verifier. Codex verifies a Claude author and Claude verifies a Codex author.

### Boot recipe, for every live lane

Each live lane runs on its own cloud VM at the PR head. Drive through `control-ui` at `.cursor/skills/control-ui/SKILL.md` or `control-cli` at `.cursor/skills/control-cli/SKILL.md`. A lane marked Mac is the exception, because XCUITest and OrbStack need the user's MacBook. Paths `scripts/hv-*` below sit under `.cursor/skills/verify-hermed-bots/`.

- [ ] `git fetch origin <head-branch> && git checkout <head SHA>`.
- [ ] Start the backend. A cloud lane runs `HV_FAKE_VERSION=current HV_FAKE_MODE=normal scripts/hv-hermes-env.sh up fake`, or the version and mode the lane names. A Mac lane runs through the Mac launchd runner as `HV_UNDER_RUNNER=1 scripts/hv-run.sh <api|ui|compat|daily> orb` against `hv-hermes-test` only, with the user present to approve each command.
- [ ] Wait for ready. `scripts/hv-hermes-env.sh doctor <mode>` answers and the profile list returns `hv-bot-a` and `hv-bot-b`.
- [ ] Snapshot the protected paths with `scripts/hv-guard.sh snapshot` before the lane and run `scripts/hv-guard.sh check` after it. A change stops the lane with code 20 and alerts the user.
- [ ] Deliver input only through `control-cli` commands, `hd-probe` from HD-03 on, or XCUITest through `scripts/hv-run.sh ui`. The read-only diagnostics are `scripts/hv-hermes-env.sh doctor`, `scripts/hv-guard.sh snapshot`, `GET /_hv/log` on the fake server, `docker exec hv-hermes-test ps` on the Mac, and the evidence folder `$HV_WORK/evidence/`.
- [ ] Never target example-host. A lane that needs a host other than `127.0.0.1` stops and reports BLOCKED.
- [ ] Save every screenshot to `/tmp/swarm-<pr-id>/worker-<n>/<slug>.png` and return the paths with the report. A CLI lane saves a PNG of its terminal transcript. A Mac lane copies the `HVShot` capture from `$HV_SHOTS`.

## Record the spike S1 to S7 against the OrbStack Hermes (HD-01)

**Depends on.** None.

**Files.**

- [ ] Create `docs/spike/README.md` with one row per item S1 to S7.
- [ ] Create `docs/spike/S1-runs.md`, `docs/spike/S2-resume.md`, `docs/spike/S3-cancel.md`, `docs/spike/S4-model-and-new.md`, `docs/spike/S5-sessions.md`, `docs/spike/S6-profiles.md`, and `docs/spike/S7-multiplexing.md`.
- [ ] Create `.cursor/skills/verify-hermed-bots/orb/Dockerfile` for the image `hv-hermes:spike`.
- [ ] Edit `.cursor/skills/verify-hermed-bots/scripts/hv-hermes-env.sh` for the real port relay and profile seeding in orb mode.
- [ ] Edit `.cursor/skills/verify-hermed-bots/scripts/hv-selftest.sh` for the new orb relay case.

**Build.**

- [ ] Pin the image to the Hermes version the user names per Q11. Enable `API_SERVER_ENABLED=true` inside the container only, with a test-only `API_SERVER_KEY` from `HV_TEST_API_KEY`. Run it with no `-v` and no `--mount`.
- [ ] Seed the test-only profiles `hv-bot-a`, `hv-bot-b`, and the inactive `hv-old`. Seed the nine active profile names from the PRD as empty test profiles for S6 and S7.
- [ ] Use a fake model provider or replayed responses (Q6 option s1), or a free local model in the container (option s2). Use no new paid API.
- [ ] Read the three Hermes doc pages and the code of the tested version read-only first. Then observe each item on `hv-hermes-test`.
- [ ] Give each item a reference, a doc anchor, a code path at a commit, or a captured request and response. Name the contract it feeds. S1 feeds `send_message` and `run_events`, S2 the replay of `run_events`, S3 `cancel_run`, S4 `set_model` and `new_session`, S5 `list_sessions`, S6 `list_profiles`, and S7 the routing of all of them.
- [ ] Record an item that cannot work as an impossibility finding and stop for the user's decision. The spike does not propose a replacement.
- [ ] Hold the target. Only `hv-hermes-test` on `127.0.0.1:18642`. No SSH, no read, no key, and no network call to example-host.
- [ ] Settle how a cloud lane worker dispatches a Mac lane to the launchd runner and reads `$HV_WORK/evidence/`. Record it in `docs/spike/README.md` before the swarm.

**You see.**

- [ ] `docs/spike/README.md` shows seven rows, S1 to S7, each marked observed or impossible, each linked to its evidence file.
- [ ] `scripts/hv-hermes-env.sh doctor orb` prints the label `hv.owner=verify-hermed-bots`, no mount, and a healthy API.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `scripts/hv-selftest.sh` gains a case where the orb relay refuses a mount under `/.hermes`. Run `.cursor/skills/verify-hermed-bots/scripts/hv-selftest.sh` and get every case PASS.
- [ ] Run `npm test` and `npm run lint`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe. Every lane is a Mac lane.

- [ ] Lane 1. Regression lane against trunk. Trunk has no spike report and no orb image, so record that `scripts/hv-hermes-env.sh up orb` fails there with a code from 30 to 34. Then run `scripts/hv-run.sh api orb` at head. Save `hd01-api-orb.png`. Pass when every contract the report marks observed returns the recorded shape.
- [ ] Lane 2. S1. Send one message to `hv-bot-a` and follow its events to a terminal state with the requests the report records. Save `hd01-s1-run.png`. Pass when the route, the event sequence, and the terminal state match `docs/spike/S1-runs.md`.
- [ ] Lane 3. S2. Run `docker network disconnect bridge hv-hermes-test` mid-turn, reconnect, and resume by the recorded id. Save `hd01-s2-resume.png`. Pass when the turn completes once, the session holds one user message, and the replay matches `docs/spike/S2-resume.md`.
- [ ] Lane 4. S3. Cancel a turn while a long tool runs. Save `hd01-s3-cancel.png`. Pass when the server reports the cancelled state and `docker exec hv-hermes-test ps` shows the tool process as `docs/spike/S3-cancel.md` records it.
- [ ] Lane 5. S4. Send `/model` to an open session, then `/new`. Save `hd01-s4-model-new.png`. Pass when the model holds on that session only, `/new` opens an empty session, and both match `docs/spike/S4-model-and-new.md`.
- [ ] Lane 6. S5. List the past sessions of `hv-bot-a` and reopen one. Save `hd01-s5-sessions.png`. Pass when the list and the reopened transcript match `docs/spike/S5-sessions.md`.
- [ ] Lane 7. S6. Read the profile list from the source the report names. Save `hd01-s6-profiles.png`. Pass when the nine seeded active profiles appear and `hv-old` is excluded or flagged as `docs/spike/S6-profiles.md` records.
- [ ] Lane 8. S7. Reach each of the nine seeded profiles through the API port. Save `hd01-s7-multiplex.png`. Pass when every profile answers through the mechanism `docs/spike/S7-multiplexing.md` records, a `/p/<profile>/` prefix or one port per profile.
- [ ] Lane 9. Protected paths. Run `scripts/hv-guard.sh snapshot` before lanes 2 to 8 and `scripts/hv-guard.sh check` after them. Save `hd01-guard.png`. Pass when the check exits 0 and both paths stay absent.
- [ ] Lane 10. No production-host contact. Run `scripts/hv-netwatch.sh` during lanes 2 to 8, then `scripts/hv-guard.sh target "$HV_FORBIDDEN_HOST"`. Save `hd01-netwatch.png`. Pass when every connection goes to `127.0.0.1:18642` and the target check exits 22.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time from `scripts/hv-hermes-env.sh up orb` to a ready `doctor orb`, and time from `send_message` to the first event. Trunk lacks the orb image, so both are absolute budgets on the diff-added work.
- [ ] Probe. At head, run up, doctor, one turn, and down five times, timed by the `run.log` stamps. At trunk, run the same up command once between head runs and record its exit code.
- [ ] Baseline. Record the trunk exit code first.
- [ ] Rule. Fail when the median ready time exceeds 180 s or the median first-event time exceeds 5 s. Both budgets are proposals, not measurements.

**Review gate.** None. HD-01 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR.

## Replace the contract fixtures with the spike observations (HD-02)

**Depends on.** HD-01.

**Files.**

- [ ] Edit `.cursor/skills/verify-hermed-bots/fixtures/hermes-current/contract.json`.
- [ ] Edit `.cursor/skills/verify-hermed-bots/fixtures/hermes-previous/contract.json`.
- [ ] Edit `.cursor/skills/verify-hermed-bots/fixtures/README.md`.
- [ ] Edit `.cursor/skills/verify-hermed-bots/scripts/hv-fake-hermes.py` and `.cursor/skills/verify-hermed-bots/scripts/hv-contract-check.py`.
- [ ] Edit `.cursor/skills/verify-hermed-bots/features/*.md` where a route is now observed.

**Build.**

- [ ] Replace every method, path, and field in `hermes-current` with the shape the spike files record. Keep the logical contract names and the deliberate unknown event.
- [ ] Build `hermes-previous` from a second container on the previous version the user names per Q11, with the same seeding as HD-01.
- [ ] Make `hv-fake-hermes.py` serve the observed paths in every mode, `normal`, `slow`, `down`, `drop-route`, and `fields`.
- [ ] Make `hv-contract-check.py` probe the edges against the observed routes, an empty message, an unknown id, a negative id, invalid JSON, and a missing key.
- [ ] Keep the marker `À VÉRIFIER (spike)` only on items the spike recorded as impossible.

**You see.**

- [ ] `hv-contract-check.py` against `hv-hermes-test` and against the fake server prints PASS for every contract.
- [ ] `rg 'À VÉRIFIER' .cursor/skills/verify-hermed-bots/fixtures` returns only items the spike marked impossible.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `hv-selftest.sh` gains a case that loads both fixtures and checks each contract has a method, a path, and a response. Run `.cursor/skills/verify-hermed-bots/scripts/hv-selftest.sh` and get every case PASS.
- [ ] Run `npm test` and `npm run lint`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `scripts/hv-run.sh compat` at trunk and at head on the fake server. Save `hd02-compat.png`. Pass when head passes the three robustness tests with the observed fixtures and the trunk result is recorded next to it.
- [ ] Lane 2. Cloud. Run `hv-contract-check.py` against the fake server with `hermes-current`. Save `hd02-check-current.png`. Pass when every contract and every edge probe reports PASS.
- [ ] Lane 3. Cloud. Run the same check with `HV_FAKE_VERSION=previous` and `hermes-previous`. Save `hd02-check-previous.png`. Pass when every contract reports PASS.
- [ ] Lane 4. Mac. Run `scripts/hv-run.sh api orb` against `hv-hermes-test`. Save `hd02-check-orb.png`. Pass when every contract reports PASS against the real Hermes.
- [ ] Lane 5. Mac. Diff the contract set and field names that the fake server and `hv-hermes-test` return. Save `hd02-fake-vs-orb.png`. Pass when the only differences are the `/_hv/*` test routes.
- [ ] Lane 6. Cloud. Run the check with `HV_FAKE_MODE=fields`. Save `hd02-fields.png`. Pass when `zz_new_field` is ignored and the removed optional field takes its default.
- [ ] Lane 7. Cloud. Run the check with `HV_FAKE_MODE=drop-route HV_DROP=set_model`. Save `hd02-drop-route.png`. Pass when only `set_model` reports 404 and every other contract passes.
- [ ] Lane 8. Cloud. Run the check with `HV_FAKE_MODE=down`. Save `hd02-down.png`. Pass when every contract reports FAIL with status 503 and the run ends in under 10 s.
- [ ] Lane 9. Mac. Run the edge probes against `hv-hermes-test`. Save `hd02-edges-orb.png`. Pass when each probe returns the status code the fixture records for it.
- [ ] Lane 10. Cloud. Search every evidence file for the value of `HV_TEST_API_KEY`. Save `hd02-secret.png`. Pass when the value appears in no file.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of one `hv-contract-check.py` run against the fake server, with the fixture of each side.
- [ ] Probe. Run the check five times at trunk and five times at head, interleaved, on the same cloud VM.
- [ ] Baseline. Record the trunk median first.
- [ ] Rule. Fail when the head median exceeds 1.5 times the trunk median.

**Review gate.** None. HD-02 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR.

## Build the HermesAdapter package with tolerant decoding (HD-03)

**Depends on.** HD-02.

**Files.**

- [ ] Create `Packages/HermesAdapter/Package.swift`.
- [ ] Create `Packages/HermesAdapter/Sources/HermesAdapter/` for contracts, decoding, and the client.
- [ ] Create `Packages/HermesAdapter/Sources/hd-probe/main.swift`.
- [ ] Create `Packages/HermesAdapter/Tests/HermesAdapterTests/`.
- [ ] Edit `.github/workflows/ci.yml` to add a Linux job that runs `swift test --package-path Packages/HermesAdapter`.

**Build.**

- [ ] Write `HermesAdapter` as the one versioned layer that calls Hermes. No UI dependency, so it builds on Linux.
- [ ] Expose the six client actions as methods on `HermesClient`, open a profile, send, read the text of a turn, approve, set the model, and start a new session.
- [ ] Decode tolerantly. Ignore unknown fields and unknown event types. Give a missing expected field its default value, such as the profile id when `display_name` is missing.
- [ ] Load the contract table from the logical names in the fixtures. Keep paths in one table so a route change touches one place.
- [ ] Add the `hd-probe` executable that runs each action against a base URL and prints the result, so lanes can drive the adapter through `control-cli`.
- [ ] Keep the Linux CI job on the free runner. Add no macOS runner without the user's written approval per Q5.

**You see.**

- [ ] The Linux CI job `swift test` is green on the PR.
- [ ] `swift run --package-path Packages/HermesAdapter hd-probe list-profiles --url http://127.0.0.1:18642` prints `hv-bot-a` and `hv-bot-b`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Write `Packages/HermesAdapter/Tests/HermesAdapterTests/DecodingTests.swift` before the code. It decodes both fixtures, the `fields` variant, the unknown event, and a profile without `display_name`. Run `swift test --package-path Packages/HermesAdapter`.
- [ ] Run `npm test` and `npm run lint`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Trunk has no adapter, so record that. At head, run the six `hd-probe` actions against the fake server on `hermes-current`. Save `hd03-six-actions.png`. Pass when each action exits 0 and prints the fixture result.
- [ ] Lane 2. Cloud. Run the six actions with `HV_FAKE_VERSION=previous`. Save `hd03-previous.png`. Pass when each action exits 0.
- [ ] Lane 3. Mac. Run the six actions against `hv-hermes-test` on `hv-bot-a`. Save `hd03-orb.png`. Pass when each action exits 0 and the session on the server shows the sent message.
- [ ] Lane 4. Cloud. Run `hd-probe list-profiles` with `HV_FAKE_MODE=fields`. Save `hd03-fields.png`. Pass when the profile without `display_name` prints its id and nothing crashes.
- [ ] Lane 5. Cloud. Run `hd-probe read-turn` on a stream with `hv.unknown_future_event`. Save `hd03-unknown-event.png`. Pass when the turn ends in state completed.
- [ ] Lane 6. Cloud. Inject `run.completed` with states failed, cancelled, and interrupted through `/_hv/inject`. Save `hd03-terminal-states.png`. Pass when `hd-probe` prints each real state.
- [ ] Lane 7. Cloud. Run `hd-probe send` with `HV_FAKE_MODE=down`. Save `hd03-down.png`. Pass when it exits non-zero with a clear error in under 10 s.
- [ ] Lane 8. Cloud. Run `hd-probe send` with `HV_FAKE_MODE=slow`. Save `hd03-slow.png`. Pass when it waits and `/_hv/log` shows one `send_message` request.
- [ ] Lane 9. Cloud. Send an empty message, then a message of 100 000 characters. Save `hd03-edges.png`. Pass when the empty message is refused before any request and the long one is sent once.
- [ ] Lane 10. Mac. Run `hd-probe list-profiles` and `hd-probe send` on each of the nine seeded profiles through the S7 mechanism. Save `hd03-nine-profiles.png`. Pass when all nine answer.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Decode time of a 10 000-event stream, and `hd-probe send` to terminal state against the fake server. Trunk lacks the package, so both are absolute budgets.
- [ ] Probe. Run `swift test --package-path Packages/HermesAdapter --filter PerfTests` and five timed `hd-probe send` runs at head. At trunk, record that the package path is absent.
- [ ] Baseline. Record the trunk absence first.
- [ ] Rule. Fail when decoding exceeds 200 ms on the Linux CI runner or the median send to terminal exceeds 1 s in `normal` mode. Both budgets are proposals.

**Review gate.** None. HD-03 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR.

## Disable only the affected feature in degraded mode and read the version (HD-04)

**Depends on.** HD-03.

**Files.**

- [ ] Create `docs/spike/S8-version.md`.
- [ ] Create `Packages/HermesAdapter/Sources/HermesAdapter/Capabilities.swift`.
- [ ] Edit `Packages/HermesAdapter/Sources/hd-probe/main.swift` to add `hd-probe capabilities`.
- [ ] Create `Packages/HermesAdapter/Tests/HermesAdapterTests/CapabilitiesTests.swift`.

**Build.**

- [ ] Observe S8 on `hv-hermes-test` first. Record how to read the Hermes version, or that no source exists, in `docs/spike/S8-version.md`. The doc says `/v1/capabilities` lists features, not a number, and that stays to be verified.
- [ ] Add `CapabilityMap` with one state per contract, available or disabled with a user message.
- [ ] Disable a contract alone when its route answers 404 or changes shape. Keep every other contract available.
- [ ] Read the version at start for information only. An unknown version sets degraded mode and never refuses the connection.

**You see.**

- [ ] `hd-probe capabilities` against `HV_FAKE_MODE=drop-route HV_DROP=set_model` prints `set_model disabled` with its message and every other contract available.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `CapabilitiesTests.swift` gains a case per dropped route, `set_model`, `approve`, and `list_sessions`, and a case where an unknown version sets degraded mode and still connects. Run `swift test --package-path Packages/HermesAdapter`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `scripts/hv-run.sh compat` at trunk and head, then `hd-probe capabilities` at head, which trunk lacks. Save `hd04-compat.png`. Pass when compat passes on both and head prints a full capability map.
- [ ] Lane 2. Cloud. Drop `set_model`. Save `hd04-drop-set-model.png`. Pass when only `set_model` is disabled and `hd-probe send` still works.
- [ ] Lane 3. Cloud. Drop `approve`. Save `hd04-drop-approve.png`. Pass when only `approve` is disabled with its message.
- [ ] Lane 4. Cloud. Drop `list_sessions`. Save `hd04-drop-sessions.png`. Pass when only `list_sessions` is disabled and `list-profiles` still works.
- [ ] Lane 5. Cloud. Run on `HV_FAKE_VERSION=previous`. Save `hd04-previous.png`. Pass when the map shows no degraded flag and every contract is available.
- [ ] Lane 6. Cloud. Serve an unknown version string. Save `hd04-unknown-version.png`. Pass when the probe reports degraded mode and still runs `send` to completion.
- [ ] Lane 7. Cloud. Run with `HV_FAKE_MODE=fields`. Save `hd04-fields.png`. Pass when no contract is disabled.
- [ ] Lane 8. Mac. Run `hd-probe capabilities` against `hv-hermes-test`. Save `hd04-orb-version.png`. Pass when the version line matches `docs/spike/S8-version.md`, or prints the recorded absence.
- [ ] Lane 9. Cloud. Drop `set_model`, restart the fake server in `normal` mode, and probe again. Save `hd04-restore.png`. Pass when `set_model` is available on the second probe.
- [ ] Lane 10. Cloud. Run with `HV_FAKE_MODE=down`. Save `hd04-down.png`. Pass when the probe reports the API unreachable, not degraded, in under 10 s.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of `hd-probe capabilities` from start to the printed map. Trunk lacks the command, so it is an absolute budget.
- [ ] Probe. Run it five times at head on the fake server. At trunk, record that the command is absent.
- [ ] Baseline. Record the trunk absence first.
- [ ] Rule. Fail when the median exceeds 500 ms. The budget is a proposal.

**Review gate.** None. HD-04 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR.

## Pause a looping turn with the loop guard (HD-05)

**Depends on.** HD-03.

**Files.**

- [ ] Create `docs/spike/S10-tokens.md` and `docs/spike/S11-thresholds.md`.
- [ ] Create `Packages/HermesAdapter/Sources/LoopGuard/LoopGuard.swift`.
- [ ] Edit `Packages/HermesAdapter/Sources/hd-probe/main.swift` to add `hd-probe loop-guard`.
- [ ] Create `Packages/HermesAdapter/Tests/LoopGuardTests/`.

**Build.**

- [ ] Observe S10 first. Record the source of tokens per run, or its absence, in `docs/spike/S10-tokens.md`.
- [ ] Write `LoopGuard.evaluate` as a pure function over the turn events and the profile history. It returns continue or pause with a cause. It never cancels.
- [ ] Implement the PRD signals. The same tool call with the same arguments 3 times in a row. Tool calls above 3 times the profile's 95th percentile. Tokens above 5 times the profile median. No new assistant message for X minutes.
- [ ] Use cautious cold-start values until a profile has 20 turns of history. Mark every value as unmeasured.
- [ ] Disable and report the token signal when S10 finds no source. Keep the other signals active.
- [ ] Record the calibration run in `docs/spike/S11-thresholds.md` with X proposed and marked unmeasured, per Q7.
- [ ] When S3 shows no server pause or cancel, return suspend display and send, notify, and offer the kill switch.

**You see.**

- [ ] `hd-probe loop-guard --events <fixture>` on a repeated tool call prints `pause cause=repeated-tool-call count=3`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `LoopGuardTests` gains a case per signal, a cold-start case, a token-source-absent case, and a normal turn that never pauses. Write them before the code. Run `swift test --package-path Packages/HermesAdapter`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Trunk has no guard, so record that. At head, inject three identical tool calls through `/_hv/inject` and run `hd-probe loop-guard`. Save `hd05-repeat.png`. Pass when it prints a pause with cause repeated-tool-call.
- [ ] Lane 2. Cloud. Inject tool calls above 3 times the history p95. Save `hd05-tool-count.png`. Pass when it pauses with cause tool-count.
- [ ] Lane 3. Cloud. Inject a token count above 5 times the median. Save `hd05-tokens.png`. Pass when it pauses with cause tokens.
- [ ] Lane 4. Cloud. Hold the stream silent past X. Save `hd05-silence.png`. Pass when it pauses with cause silence.
- [ ] Lane 5. Cloud. Run a profile with 5 turns of history. Save `hd05-cold-start.png`. Pass when the cold-start values apply and the output says so.
- [ ] Lane 6. Cloud. Remove the token field from the stream. Save `hd05-no-tokens.png`. Pass when the token signal reports disabled and a repeated tool call still pauses.
- [ ] Lane 7. Mac. Provoke a loop on `hv-hermes-test` with the fake model provider. Save `hd05-orb-loop.png`. Pass when the guard pauses within the third identical call.
- [ ] Lane 8. Cloud. Replay the normal fixture stream 100 times. Save `hd05-no-false-pause.png`. Pass when no run pauses.
- [ ] Lane 9. Cloud. Run with `cancel_run` dropped. Save `hd05-no-cancel.png`. Pass when the guard returns suspend display and send with the kill switch offer.
- [ ] Lane 10. Mac. Run 20 turns per seeded test profile on `hv-hermes-test`. Save `hd05-calibration.png`. Pass when `docs/spike/S11-thresholds.md` holds the measured values next to the proposals, marked not representative.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Time per `LoopGuard.evaluate` call. Trunk lacks the guard, so it is an absolute budget.
- [ ] Probe. Run `swift test --package-path Packages/HermesAdapter --filter LoopGuardPerfTests` over 10 000 events, five times at head. At trunk, record the absence.
- [ ] Baseline. Record the trunk absence first.
- [ ] Rule. Fail when the p95 exceeds 1 ms per event. The budget is a proposal.

**Review gate.** None. HD-05 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR.

## Open the app shell with stable accessibility ids (HD-06)

**Depends on.** HD-03 and HD-04.

**Files.**

- [ ] Create `HermedBots.xcodeproj` with the scheme `HermedBots`.
- [ ] Create `HermedBots/App/HermedBotsApp.swift`.
- [ ] Create `HermedBots/Shared/AccessibilityID.swift`.
- [ ] Create `HermedBots/Secrets/SecretStore.swift` with `KeychainSecretStore` and `InMemorySecretStore`.
- [ ] Create `HermedBotsUITests/HVShot.swift` and `HermedBotsUITests/LaunchTests.swift`.

**Build.**

- [ ] Set the macOS minimum to the MacBook's version, not below macOS 14, per Q4. Build a local ad hoc signed app, distribution option d1.
- [ ] Link the `HermesAdapter` package. Make every Hermes call go through it.
- [ ] Define every `hd.*` id once in the `AccessibilityID` enum, shared by the app and the UI test target.
- [ ] Inject `InMemorySecretStore` when `HV_TEST_MODE=1`, only under `#if DEBUG`. Read the test key from `HV_TEST_API_KEY` and never call `SecItem*` in test mode.
- [ ] Show the window with `hd.status.version` and an empty `hd.bots.list`.

**You see.**

- [ ] `scripts/hv-run.sh ui fake` launches the app and `hd.status.version` shows the fake server's version.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] A spy `KeychainSecretStore` fails the test when it is called in test mode, and a Release build test checks that `HV_TEST_MODE` is ignored. Run `xcodebuild test -scheme HermedBots -destination 'platform=macOS'`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe. Every lane is a Mac lane.

- [ ] Lane 1. Regression lane against trunk. Trunk has no app, so record that. At head, run `LaunchTests` through `scripts/hv-run.sh ui fake`. Save `hd06-launch.png`. Pass when the window opens and `hd.status.version` reads the fake version.
- [ ] Lane 2. Run the same launch against `hv-hermes-test`. Save `hd06-launch-orb.png`. Pass when `hd.status.version` matches `docs/spike/S8-version.md`.
- [ ] Lane 3. Launch in test mode and read `log show --predicate 'subsystem == "com.apple.securityd"' --last 5m`. Save `hd06-no-keychain.png`. Pass when no line names HermedBots.
- [ ] Lane 4. Build Release and launch it with `HV_TEST_MODE=1`. Save `hd06-release.png`. Pass when the app ignores test mode and asks for no test key.
- [ ] Lane 5. Launch with `HV_FAKE_MODE=down`. Save `hd06-down.png`. Pass when the window opens, does not crash, and shows the version as unknown.
- [ ] Lane 6. Read `hd.status.version` through the AX fallback with JXA. Save `hd06-ax.png`. Pass when the `AXIdentifier` matches the XCUITest id.
- [ ] Lane 7. Run `scripts/hv-netwatch.sh` during lane 1. Save `hd06-netwatch.png`. Pass when the only connection goes to `127.0.0.1:18642`.
- [ ] Lane 8. Run `scripts/hv-guard.sh snapshot` and `check` around lanes 1 to 7. Save `hd06-guard.png`. Pass when the check exits 0.
- [ ] Lane 9. Launch and quit the app 10 times in a row. Save `hd06-relaunch.png`. Pass when every launch shows the window and no crash report appears.
- [ ] Lane 10. Launch with `-AppleLanguages (fr)` and then `(en)`. Save `hd06-languages.png`. Pass when every `hd.*` id stays the same in both languages.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Cold launch to `hd.status.version` visible. Trunk lacks the app, so it is an absolute budget.
- [ ] Probe. Run five cold launches at head through XCUITest with timestamps in `run.log`. At trunk, record the missing scheme.
- [ ] Baseline. Record the trunk absence first.
- [ ] Rule. Fail when the median exceeds 2 s. The budget is a proposal.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 1 and lane 5 screenshots into `$HV_WORK/review/hd06-review-<slug>.png`.
- [ ] Record a 30 to 60 second video of the change on a lane VM. Save it as `$HV_WORK/review/hd06-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR after the operator's click.

## Open the SSH tunnel from an SSH alias (HD-07)

**Depends on.** HD-06.

**Files.**

- [ ] Create `docs/spike/S12-tunnel.md`.
- [ ] Create `HermedBots/Transport/SSHTunnel.swift`.
- [ ] Create `HermedBots/Settings/ConnectionView.swift`.
- [ ] Create `HermedBotsUITests/TunnelTests.swift`.
- [ ] Edit `HermedBots/App/HermedBotsApp.swift` to route the adapter through the tunnel.

**Build.**

- [ ] Observe S12 first. Compare system `ssh` with a library for a local forward to `127.0.0.1:8642`, with the identity that the user's SSH config names for the alias. A key management service manages the keys outside the app, and the app never asks for a private key. Record the chosen option in `docs/spike/S12-tunnel.md`.
- [ ] Start the `ssh` child in its own process group and kill the group on quit and on timeout, so no orphan survives.
- [ ] Keep the key out of argv, logs, files, and screenshots.
- [ ] In test mode, open the tunnel to an SSH endpoint inside `hv-hermes-test`. Refuse the test-mode forbidden host. The compiled tests still own that check. `example-host` in this plan is a docs placeholder, not a name to type into the app.
- [ ] Reopen the tunnel when it drops. Show a clear message on a wrong key, with no retry loop.

**You see.**

- [ ] `hd.status.version` reads the version through the tunnel, and the connection view shows the host and the key state.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `SSHTunnelTests` gains a case that the argument list carries no secret and a case that the test-mode forbidden host is refused. Run `xcodebuild test -scheme HermedBots -destination 'platform=macOS'`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe. Every lane is a Mac lane.

- [ ] Lane 1. Regression lane against trunk. Trunk connects straight to `127.0.0.1:18642`. Run the launch test at trunk, then at head through the tunnel to `hv-hermes-test`. Save `hd07-tunnel.png`. Pass when both read the same version and head goes through the tunnel.
- [ ] Lane 2. Open the connection view. Save `hd07-connection.png`. Pass when it shows the host and a key state without the key value.
- [ ] Lane 3. Kill the `ssh` child mid-session. Save `hd07-reopen.png`. Pass when the tunnel reopens and the next action succeeds.
- [ ] Lane 4. Quit the app and list processes. Save `hd07-no-orphan.png`. Pass when no `ssh` process from the app's group remains.
- [ ] Lane 5. Use a wrong test key. Save `hd07-wrong-key.png`. Pass when a clear message shows and the logs show one attempt, not a loop.
- [ ] Lane 6. Run `scripts/hv-netwatch.sh` during a session. Save `hd07-netwatch.png`. Pass when the only outbound connection is the tunnel.
- [ ] Lane 7. Read `ps -o args` for the `ssh` child and search the evidence folder for the key. Save `hd07-no-secret.png`. Pass when the key value appears nowhere.
- [ ] Lane 8. Run `testAHostThatNamesPersoHermesIsRefusedBeforeAnyConnection` and `testAPersoHermesHostInTheEnvironmentNeverStartsSsh`. Save `hd07-refuse-prod.png`. Pass when both tests pass and no ssh starts. Do not type `example-host` into the app. That string is a docs placeholder. The compiled guard still uses the existing fixtures.
- [ ] Lane 9. Run `docker network disconnect bridge hv-hermes-test`, wait 30 s, and reconnect. Save `hd07-network-cut.png`. Pass when the tunnel reopens without user action.
- [ ] Lane 10. Run `scripts/hv-guard.sh snapshot` and `check` around lanes 1 to 9. Save `hd07-guard.png`. Pass when the check exits 0.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Time from launch to the first API reply. Trunk has it over the direct connection and head has it over the tunnel.
- [ ] Probe. Run five launches at trunk and five at head, interleaved, against `hv-hermes-test`.
- [ ] Baseline. Record the trunk median first.
- [ ] Rule. Fail when the head median exceeds the trunk median by more than 2 s.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 2 and lane 5 screenshots into `$HV_WORK/review/hd07-review-<slug>.png`.
- [ ] Record a 30 to 60 second video of the change on a lane VM. Save it as `$HV_WORK/review/hd07-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR after the operator's click.

## List the bots and their past threads (HD-08)

**Depends on.** HD-04 and HD-07.

**Files.**

- [ ] Create `HermedBots/Bots/BotListView.swift` and `HermedBots/Bots/ThreadsView.swift`.
- [ ] Create `HermedBotsUITests/SixActions.swift` with `testListBots`.
- [ ] Edit `HermedBots/Shared/AccessibilityID.swift`.

**Build.**

- [ ] Read the list through `list_profiles` from the source `docs/spike/S6-profiles.md` names. Show all active profiles, not a pinned list, as Ayo decided on 2026-10-19.
- [ ] Never show a decommissioned profile. Show a list change only after the user validates it.
- [ ] List past threads under each bot through `list_sessions`. HD-09 reopens a thread with its transcript.
- [ ] Expose `hd.bots.list`, `hd.bots.row.<profileId>`, its `.name`, `.model`, and `.threads`, and `hd.threads.row.<sessionId>`.
- [ ] Disable the threads alone when `list_sessions` is disabled in the capability map.

**You see.**

- [ ] The sidebar shows `hd.bots.row.hv-bot-a` and `hd.bots.row.hv-bot-b`, and no `hd.bots.row.hv-old`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `SixActions.testListBots` and a threads test written before the view. Run `HV_UNDER_RUNNER=1 scripts/hv-run.sh ui fake`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe. Every lane is a Mac lane.

- [ ] Lane 1. Regression lane against trunk. Trunk shows an empty `hd.bots.list`, so record that. At head, run `testListBots` on the fake server. Save `hd08-bots.png`. Pass when both active rows exist.
- [ ] Lane 2. Look for `hd.bots.row.hv-old`. Save `hd08-no-old.png`. Pass when it does not exist.
- [ ] Lane 3. Expand `hv-bot-a`. Save `hd08-threads.png`. Pass when `hd.threads.row.s-past-1` shows under it and `/_hv/log` holds one `list_sessions` and no `send_message`.
- [ ] Lane 4. Run with `HV_FAKE_MODE=fields`. Save `hd08-fields.png`. Pass when the row without `display_name` shows the profile id.
- [ ] Lane 5. Serve a fixture with no profile. Save `hd08-empty.png`. Pass when a clear empty message shows and nothing crashes.
- [ ] Lane 6. Serve a 300-character name, an emoji name, and a right-to-left name. Save `hd08-long-names.png`. Pass when each row is truncated and readable.
- [ ] Lane 7. Add a profile on the fake server while the app runs. Save `hd08-list-change.png`. Pass when the new row appears only after the validation prompt is accepted.
- [ ] Lane 8. Run against `hv-hermes-test`. Save `hd08-orb-nine.png`. Pass when the nine seeded active profiles show and no decommissioned name shows.
- [ ] Lane 9. Drop `list_sessions`. Save `hd08-drop-sessions.png`. Pass when the threads are disabled with a message and the bot list works.
- [ ] Lane 10. Run `scripts/hv-netwatch.sh` and the guard around lanes 1 to 9. Save `hd08-net-guard.png`. Pass when only the test endpoint is reached and the guard exits 0.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Launch to every bot row visible with nine profiles, and expanding a bot with 200 threads. Trunk lacks the list, so both are absolute budgets.
- [ ] Probe. Run five launches and five expansions at head through XCUITest. At trunk, record the empty list.
- [ ] Baseline. Record the trunk state first.
- [ ] Rule. Fail when the median launch exceeds 1.5 s or the median expansion exceeds 500 ms. Both budgets are proposals.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 1, lane 3, and lane 7 screenshots into `$HV_WORK/review/hd08-review-<slug>.png`.
- [ ] Record a 30 to 60 second video of the change on a lane VM. Save it as `$HV_WORK/review/hd08-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR after the operator's click.

## Chat with a bot and start a new session (HD-09)

**Depends on.** HD-08.

**Files.**

- [ ] Create `HermedBots/Conversation/ConversationView.swift` and `HermedBots/Conversation/ComposerView.swift`.
- [ ] Edit `HermedBots/Bots/ThreadsView.swift` to open a thread in the conversation.
- [ ] Edit `HermedBotsUITests/SixActions.swift` to add `testConversation`.
- [ ] Edit `HermedBots/Shared/AccessibilityID.swift`.

**Build.**

- [ ] Reopen a past thread from `hd.threads.row.<sessionId>` with its transcript in `hd.conversation.view`, per `docs/spike/S5-sessions.md`.
- [ ] Send through `send_message` and stream the reply from `run_events` into `hd.conversation.message.<server-index>`.
- [ ] Show the real terminal state in `hd.conversation.state`, completed, failed, cancelled, or interrupted.
- [ ] Disable `hd.composer.send` for an empty or blank message. Send once on a double click.
- [ ] Add `hd.session.new` with the label « Nouvelle session », as Ayo decided on 2026-10-19. It sends `/new`, never `/reset`, and the old session appears as a past thread.

**You see.**

- [ ] After a send, the reply from the fixture shows and `hd.conversation.state` reads completed.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `SixActions.testConversation`, a reopen-thread test, and a terminal-state test written before the view. Run `HV_UNDER_RUNNER=1 scripts/hv-run.sh ui fake`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe. Every lane is a Mac lane.

- [ ] Lane 1. Regression lane against trunk. Trunk has no composer, so record that. At head, send a message on the fake server. Save `hd09-send.png`. Pass when the reply shows, the state reads completed, and `/_hv/log` holds one `send_message`.
- [ ] Lane 2. Send a message to `hv-bot-a` on `hv-hermes-test`. Save `hd09-orb-send.png`. Pass when the reply shows and the server session holds the message once.
- [ ] Lane 3. Inject `run.completed` with state failed. Save `hd09-failed.png`. Pass when `hd.conversation.state` reads failed.
- [ ] Lane 4. Inject state cancelled, then interrupted. Save `hd09-cancelled.png`. Pass when each real state shows.
- [ ] Lane 5. Stream `hv.unknown_future_event`. Save `hd09-unknown.png`. Pass when the turn completes with no error.
- [ ] Lane 6. Type only spaces. Save `hd09-blank.png`. Pass when `hd.composer.send` is disabled.
- [ ] Lane 7. Paste 100 000 characters and send. Save `hd09-long.png`. Pass when the window stays responsive and one request goes out.
- [ ] Lane 8. Double click `hd.composer.send`. Save `hd09-double.png`. Pass when `/_hv/log` holds one `send_message`.
- [ ] Lane 9. Send while a turn runs. Save `hd09-busy.png`. Pass when the app shows the defined busy behavior and sends nothing extra.
- [ ] Lane 10. Click `hd.session.new`. Save `hd09-new.png`. Pass when the conversation is empty and the old session shows as `hd.threads.row.<id>`. Then click `hd.threads.row.s-past-1` and pass when `hd.conversation.view` shows its messages.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Delay from an emitted `message.delta` to its text on screen, and main-thread hang time while sending 100 000 characters. Trunk lacks the view, so both are absolute budgets.
- [ ] Probe. Run 20 injected deltas and five long sends at head with XCUITest timestamps. At trunk, record the missing composer.
- [ ] Baseline. Record the trunk state first.
- [ ] Rule. Fail when the p95 delay exceeds 300 ms or any hang exceeds 250 ms. Both budgets are proposals.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 1, lane 3, and lane 10 screenshots into `$HV_WORK/review/hd09-review-<slug>.png`.
- [ ] Record a 30 to 60 second video of the change on a lane VM. Save it as `$HV_WORK/review/hd09-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR after the operator's click.

## Switch the session model with /model (HD-10)

**Depends on.** HD-09.

**Files.**

- [ ] Create `HermedBots/Conversation/ModelPicker.swift`.
- [ ] Edit `HermedBotsUITests/SixActions.swift` to add `testModelSwitch`.

**Build.**

- [ ] Send `/model` through `set_model` on the open session only, as `docs/spike/S4-model-and-new.md` records. Never write the profile model.
- [ ] Expose `hd.model.picker` and `hd.model.option.<modelId>`. Show an unknown model name as the server sends it.
- [ ] Disable the picker alone with its message when `set_model` is disabled.

**You see.**

- [ ] Picking `model-y` shows it in `hd.model.picker` and `/_hv/log` holds one `set_model` with `model-y`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `SixActions.testModelSwitch` written before the picker. Run `HV_UNDER_RUNNER=1 scripts/hv-run.sh ui fake`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe. Every lane is a Mac lane.

- [ ] Lane 1. Regression lane against trunk. Trunk has no picker, so record that. At head, pick `model-y`. Save `hd10-pick.png`. Pass when the picker shows `model-y` and one `set_model` request goes out.
- [ ] Lane 2. Pick a model, click `hd.session.new`, and read the picker. Save `hd10-persist.png`. Pass when the new session shows the profile model.
- [ ] Lane 3. Serve an unknown model name. Save `hd10-unknown.png`. Pass when the name shows as sent and nothing crashes.
- [ ] Lane 4. Drop `set_model`. Save `hd10-drop.png`. Pass when the picker is disabled with its message and sending still works.
- [ ] Lane 5. Switch the model on `hv-hermes-test`. Save `hd10-orb.png`. Pass when the next reply comes from the chosen model per the S4 evidence.
- [ ] Lane 6. Select the same option twice fast. Save `hd10-double.png`. Pass when one `set_model` request goes out.
- [ ] Lane 7. Switch while a turn runs. Save `hd10-busy.png`. Pass when the app shows the defined behavior and the running turn is not broken.
- [ ] Lane 8. Run with `HV_FAKE_MODE=slow`. Save `hd10-slow.png`. Pass when the picker shows a wait state and the window stays responsive.
- [ ] Lane 9. Reopen a past thread whose session had another model. Save `hd10-thread-model.png`. Pass when the picker shows that session's model.
- [ ] Lane 10. Run the netwatch and the guard around lanes 1 to 9. Save `hd10-net-guard.png`. Pass when only the test endpoint is reached and the guard exits 0.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Time from the option click to the confirmed model in the picker. Trunk lacks the picker, so it is an absolute budget.
- [ ] Probe. Run 10 switches at head through XCUITest. At trunk, record the missing picker.
- [ ] Baseline. Record the trunk state first.
- [ ] Rule. Fail when the median exceeds 500 ms in `normal` mode. The budget is a proposal.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 1 and lane 4 screenshots into `$HV_WORK/review/hd10-review-<slug>.png`.
- [ ] Record a 30 to 60 second video of the change on a lane VM. Save it as `$HV_WORK/review/hd10-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR after the operator's click.

## Answer tool approvals and show the current tool (HD-11)

**Depends on.** HD-09.

**Files.**

- [ ] Create `HermedBots/Approval/ApprovalSheet.swift` and `HermedBots/Conversation/CurrentToolRow.swift`.
- [ ] Edit `HermedBotsUITests/SixActions.swift` to add `testApprovalYes`, `testApprovalNo`, and `testCurrentTool`.

**Build.**

- [ ] Show `hd.tool.current` with the tool name while a tool runs.
- [ ] Open `hd.approval.sheet` on `approval.requested` with `hd.approval.tool` and `hd.approval.params` before any answer. Scroll long parameters, never truncate them silently.
- [ ] Send one decision through `approve` for `hd.approval.yes` or `hd.approval.no`, even on a double click.
- [ ] Keep a pending approval on screen across a cut and send the decision once when the link returns.

**You see.**

- [ ] The sheet shows `file.write` and `/tmp/hv.txt` before any click, and `hd.tool.current` shows `shell.exec` during the call.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] The three approval tests written before the sheet. Run `HV_UNDER_RUNNER=1 scripts/hv-run.sh ui fake`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe. Every lane is a Mac lane.

- [ ] Lane 1. Regression lane against trunk. Trunk has no sheet, so record that. At head, trigger the fixture approval. Save `hd11-sheet.png`. Pass when the tool and the parameters show before any answer.
- [ ] Lane 2. Click `hd.approval.yes`. Save `hd11-yes.png`. Pass when one `approve` with yes goes out and the turn completes.
- [ ] Lane 3. Click `hd.approval.no`. Save `hd11-no.png`. Pass when one `approve` with no goes out and the real end state shows.
- [ ] Lane 4. Watch `hd.tool.current` during `tool.started`. Save `hd11-current-tool.png`. Pass when it reads `shell.exec` and clears on `tool.finished`.
- [ ] Lane 5. Serve parameters of 200 000 characters and binary bytes. Save `hd11-huge-params.png`. Pass when the sheet scrolls and marks any cut.
- [ ] Lane 6. Double click `hd.approval.yes`. Save `hd11-double.png`. Pass when one decision goes out.
- [ ] Lane 7. Cut the link with `/_hv/cut` while the sheet waits, then answer. Save `hd11-cut.png`. Pass when the sheet stays and the decision goes out once after the link returns.
- [ ] Lane 8. Drop `approve`. Save `hd11-drop.png`. Pass when the sheet shows the request with the disabled message and the kill switch pointer.
- [ ] Lane 9. Trigger an approval on `hv-hermes-test` with the fake model provider. Save `hd11-orb.png`. Pass when yes runs the tool in the container and no does not.
- [ ] Lane 10. Leave the sheet waiting 60 s. Save `hd11-wait.png`. Pass when the screen shows that the bot waits for the user and the window stays responsive.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Delay from `approval.requested` to the sheet on screen. Trunk lacks the sheet, so it is an absolute budget.
- [ ] Probe. Inject 10 approvals at head and read XCUITest timestamps. At trunk, record the missing sheet.
- [ ] Baseline. Record the trunk state first.
- [ ] Rule. Fail when the median exceeds 500 ms. The budget is a proposal.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 1, lane 4, and lane 7 screenshots into `$HV_WORK/review/hd11-review-<slug>.png`.
- [ ] Record a 30 to 60 second video of the change on a lane VM. Save it as `$HV_WORK/review/hd11-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR after the operator's click.

## Show degraded mode, errors, and the loop pause (HD-12)

**Depends on.** HD-05 and HD-09.

**Files.**

- [ ] Create `HermedBots/Banners/DegradedBanner.swift`, `HermedBots/Banners/ErrorBanner.swift`, and `HermedBots/Banners/LoopPauseBanner.swift`.
- [ ] Create `HermedBotsUITests/Compat.swift` and `HermedBotsUITests/Errors.swift`.

**Build.**

- [ ] Show `hd.banner.degraded` with one `hd.banner.degraded.feature.<contract>` per disabled contract from the capability map.
- [ ] Show `hd.banner.error` with `hd.banner.error.retry` when the API is unreachable, slow, or refuses the key. Never retry in a loop on a refused key.
- [ ] Show the loop guard pause with its cause in the app, and a macOS notification too, as Q8 decided on 2026-10-18. Never cancel silently.
- [ ] Show the token signal as disabled when S10 found no source.

**You see.**

- [ ] With `set_model` dropped, `hd.banner.degraded.feature.set_model` explains it and the conversation still works.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `Compat.testRouteRemoved`, `Compat.testFieldsAddedRemoved`, `Compat.testRecentVersion`, `Errors.testApiUnreachable`, and `Errors.testApiSlow` written before the banners. Run `HV_UNDER_RUNNER=1 scripts/hv-run.sh ui fake`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe. Every lane is a Mac lane.

- [ ] Lane 1. Regression lane against trunk. Trunk shows no banner when `set_model` is dropped, so record that. At head, drop `set_model`. Save `hd12-degraded.png`. Pass when the feature banner explains it and a send still completes.
- [ ] Lane 2. Drop `approve`. Save `hd12-drop-approve.png`. Pass when its feature banner shows and the bot list works.
- [ ] Lane 3. Run with `HV_FAKE_MODE=down`. Save `hd12-down.png`. Pass when `hd.banner.error` shows in under 10 s with `hd.banner.error.retry`.
- [ ] Lane 4. Run with `HV_FAKE_MODE=slow`. Save `hd12-slow.png`. Pass when a wait state shows and no second request goes out.
- [ ] Lane 5. Use a wrong key. Save `hd12-401.png`. Pass when a clear message shows and `/_hv/log` holds one attempt.
- [ ] Lane 6. Provoke a repeated tool call. Save `hd12-loop-pause.png`. Pass when the pause banner names the cause and the macOS notification fires too, as Q8 decided.
- [ ] Lane 7. Remove the token field. Save `hd12-no-tokens.png`. Pass when the token signal shows as disabled.
- [ ] Lane 8. Run on `HV_FAKE_VERSION=previous`. Save `hd12-previous.png`. Pass when no degraded banner shows and `hd.status.version` shows the version.
- [ ] Lane 9. Start in `down`, switch the fake server to `normal`, and click retry. Save `hd12-retry.png`. Pass when the error banner clears and the list loads.
- [ ] Lane 10. Serve an unknown version on `hv-hermes-test` per S8. Save `hd12-orb-unknown.png`. Pass when the app stays open in degraded mode and the six actions still run.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Delay from a dropped route at launch to its feature banner, and from a pause decision to the pause banner. Trunk lacks the banners, so both are absolute budgets.
- [ ] Probe. Run five launches and five provoked pauses at head with XCUITest timestamps. At trunk, record the missing banners.
- [ ] Baseline. Record the trunk state first.
- [ ] Rule. Fail when either median exceeds 1 s. Both budgets are proposals.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 1, lane 3, and lane 6 screenshots into `$HV_WORK/review/hd12-review-<slug>.png`.
- [ ] Record a 30 to 60 second video of the change on a lane VM. Save it as `$HV_WORK/review/hd12-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR after the operator's click.

## Resume a turn after sleep without a duplicate send (HD-13)

**Depends on.** HD-11 and HD-12.

**Files.**

- [ ] Create `HermedBots/Transport/ResumeStore.swift`.
- [ ] Edit `HermedBotsUITests/SixActions.swift` to add `testResumeAfterSleep`.
- [ ] Create `HermedBotsUITests/Events.swift` with `testUnknownEventIgnored`.

**Build.**

- [ ] Store only the session id and the run id needed to resume, nothing else, on the Mac.
- [ ] On wake or reconnect, reopen the tunnel and replay the turn from the stored id per `docs/spike/S2-resume.md`.
- [ ] Never send a message twice. Use the idempotence key if S2 found one, else the recorded dedup rule.
- [ ] Keep a pending approval on screen across the cut.

**You see.**

- [ ] After a 10 s cut mid-turn, the turn's result shows and `/_hv/log` holds one `send_message`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `SixActions.testResumeAfterSleep` and `Events.testUnknownEventIgnored` written before the store. Run `HV_UNDER_RUNNER=1 scripts/hv-run.sh ui fake`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe. Every lane is a Mac lane.

- [ ] Lane 1. Regression lane against trunk. Cut the fake server for 10 s mid-turn at trunk and at head. Save `hd13-cut.png`. Pass when head shows the result with one `send_message` and the trunk outcome is recorded next to it.
- [ ] Lane 2. Disconnect `hv-hermes-test` from its network mid-turn, then reconnect. Save `hd13-orb-cut.png`. Pass when the result shows and the session holds the message once.
- [ ] Lane 3. Inject `run.completed` during the cut. Save `hd13-inject.png`. Pass when the completed state shows after reconnect.
- [ ] Lane 4. Cut for 0 s. Save `hd13-zero.png`. Pass when nothing duplicates and nothing freezes.
- [ ] Lane 5. Cut for 10 minutes. Save `hd13-ten-min.png`. Pass when the result shows after reconnect and the error banner showed during the cut.
- [ ] Lane 6. Cut while an approval waits. Save `hd13-approval-cut.png`. Pass when the sheet stays and one decision goes out.
- [ ] Lane 7. Cut between the send and its acknowledgement. Save `hd13-send-cut.png`. Pass when `/_hv/log` holds one `send_message`.
- [ ] Lane 8. Quit and relaunch the app mid-turn. Save `hd13-relaunch.png`. Pass when the app resumes the turn from the stored ids.
- [ ] Lane 9. Read the app's stored state on disk. Save `hd13-local-state.png`. Pass when it holds only session and run ids, with no transcript and no secret.
- [ ] Lane 10. Run the netwatch and the guard around lanes 1 to 9. Save `hd13-net-guard.png`. Pass when only the test endpoint is reached and the guard exits 0.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Time from the link's return to the turn's result on screen. Trunk lacks resume, so it is an absolute budget.
- [ ] Probe. Run five 10 s cuts at head. At trunk, run five cuts interleaved and record the outcome.
- [ ] Baseline. Record the trunk outcome first.
- [ ] Rule. Fail when the head median exceeds 5 s. The budget is a proposal.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 1 and lane 6 screenshots into `$HV_WORK/review/hd13-review-<slug>.png`.
- [ ] Record a 30 to 60 second video of the change on a lane VM. Save it as `$HV_WORK/review/hd13-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR after the operator's click.

## Refuse a profile that Hermes Desktop holds (HD-14)

**Depends on.** HD-11.

**Files.**

- [ ] Create `docs/spike/S9-desktop.md`.
- [ ] Create `HermedBots/Transport/ProfileLock.swift`.
- [ ] Create `HermedBotsUITests/ConcurrencyTests.swift`.

**Build.**

- [ ] Observe S9 first on `hv-hermes-test`. Record how to detect a profile held by Desktop in both orders, and whether the API server counts as the holder.
- [ ] Refuse to open a held profile and show the reason. Stop sending when Desktop takes the profile during use and show it.
- [ ] Keep other profiles usable.
- [ ] If Desktop cannot run against OrbStack without touching `~/.hermes/hermes-agent` or `~/.local/bin/hermes`, simulate the hold on the fake server and leave the real two-order test to the user by hand.

**You see.**

- [ ] With the profile held, the bot row shows the reason and `hd.composer.send` is disabled.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `ConcurrencyTests` covers both orders on the fake server, written before `ProfileLock`. Run `HV_UNDER_RUNNER=1 scripts/hv-run.sh ui fake`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe. Every lane is a Mac lane.

- [ ] Lane 1. Regression lane against trunk. Trunk opens a held profile, so record that. At head, hold `hv-bot-a` before launch. Save `hd14-held.png`. Pass when the app refuses to open it and shows the reason.
- [ ] Lane 2. Take `hv-bot-a` during use. Save `hd14-taken.png`. Pass when sending stops and the reason shows.
- [ ] Lane 3. Check `/_hv/log` after lane 2. Save `hd14-no-write.png`. Pass when no `send_message` goes out after the hold.
- [ ] Lane 4. Hold `hv-bot-a` and use `hv-bot-b`. Save `hd14-other.png`. Pass when `hv-bot-b` works normally.
- [ ] Lane 5. Release the hold. Save `hd14-release.png`. Pass when `hv-bot-a` opens again.
- [ ] Lane 6. Take the profile while an approval waits. Save `hd14-approval.png`. Pass when no decision goes out and the reason shows.
- [ ] Lane 7. Run the S9 mechanism on `hv-hermes-test`. Save `hd14-orb.png`. Pass when the detection matches `docs/spike/S9-desktop.md`, or the lane records that S9 is manual-only.
- [ ] Lane 8. Drop the detection route if S9 uses one. Save `hd14-drop.png`. Pass when the app shows the feature as degraded and does not send to an unknown-state profile.
- [ ] Lane 9. Run the guard around lanes 1 to 8. Save `hd14-guard.png`. Pass when the check exits 0 and both protected paths stay absent.
- [ ] Lane 10. Run the netwatch around lanes 1 to 8. Save `hd14-netwatch.png`. Pass when only the test endpoint is reached.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Delay from the hold to the stop of sending. Trunk lacks detection, so it is an absolute budget.
- [ ] Probe. Run five holds at head on the fake server. At trunk, run five interleaved and record that sending continues.
- [ ] Baseline. Record the trunk outcome first.
- [ ] Rule. Fail when the head median exceeds 5 s. The budget is a proposal.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 1 and lane 2 screenshots into `$HV_WORK/review/hd14-review-<slug>.png`.
- [ ] Record a 30 to 60 second video of the change on a lane VM. Save it as `$HV_WORK/review/hd14-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR after the operator's click.

## Stop every running turn with the kill switch (HD-15)

**Depends on.** HD-11.

**Files.**

- [ ] Create `HermedBots/KillSwitch/StopAllButton.swift`.
- [ ] Create `docs/runbook/kill-switch.md` with the K3 procedure for Ayo.
- [ ] Create `HermedBotsUITests/KillSwitchTests.swift`.

**Build.**

- [ ] Add the stop-all button, K1, as Q2 decided. It calls `cancel_run` for every running turn on every profile, per `docs/spike/S3-cancel.md`.
- [ ] Keep sessions and transcripts on the server. Delete nothing.
- [ ] When `cancel_run` is disabled or the tunnel is down, disable the button with a message that points to K3.
- [ ] Write the K3 procedure for Ayo, stop the Hermes gateway process of the profile on the VM. No agent runs it.

**You see.**

- [ ] After the click, every running turn shows cancelled and the server reports the cancelled state.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `KillSwitchTests` covers three running turns, no running turn, and a dropped `cancel_run`, written before the button. Run `HV_UNDER_RUNNER=1 scripts/hv-run.sh ui fake`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe. Every lane is a Mac lane.

- [ ] Lane 1. Regression lane against trunk. Trunk has no button, so record that. At head, start turns on three profiles and click stop-all. Save `hd15-stop-all.png`. Pass when the three turns show cancelled and `/_hv/log` holds three `cancel_run`.
- [ ] Lane 2. Start a long tool on `hv-hermes-test` and click stop-all. Save `hd15-orb-tool.png`. Pass when the run is cancelled and `docker exec hv-hermes-test ps` shows the tool as S3 records.
- [ ] Lane 3. Click stop-all with no running turn. Save `hd15-idle.png`. Pass when a clear message shows and no request goes out.
- [ ] Lane 4. Cut the tunnel and click stop-all. Save `hd15-no-tunnel.png`. Pass when the button shows that cutting the tunnel does not stop the VM and points to K3.
- [ ] Lane 5. Drop `cancel_run`. Save `hd15-drop.png`. Pass when the button is disabled with the K3 pointer.
- [ ] Lane 6. Double click stop-all. Save `hd15-double.png`. Pass when one `cancel_run` goes out per run.
- [ ] Lane 7. Click stop-all, then list the sessions. Save `hd15-kept.png`. Pass when every session and transcript is still listed.
- [ ] Lane 8. Click stop-all while an approval waits. Save `hd15-approval.png`. Pass when the run is cancelled and the sheet closes with the real state.
- [ ] Lane 9. Ayo, with Engineer, clicks stop-all during a turn on `hv-hermes-test`. Save `hd15-<USER>.png`. Pass when the work stops in the container and Ayo records the result.
- [ ] Lane 10. Run the netwatch and the guard around lanes 1 to 9. Save `hd15-net-guard.png`. Pass when only the test endpoint is reached and the guard exits 0.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Time from the click to every run in the cancelled state on the server. Trunk lacks the button, so it is an absolute budget.
- [ ] Probe. Run five stop-all clicks with three running turns at head. At trunk, record the missing button.
- [ ] Baseline. Record the trunk state first.
- [ ] Rule. Fail when the median exceeds 3 s. The budget is a proposal.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 1, lane 4, and lane 5 screenshots into `$HV_WORK/review/hd15-review-<slug>.png`.
- [ ] Record a 30 to 60 second video of the change on a lane VM. Save it as `$HV_WORK/review/hd15-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR after the operator's click.

## Run the daily compatibility test and the acceptance pass (HD-16)

**Depends on.** HD-08, HD-09, HD-10, HD-11, HD-12, HD-13, HD-14, and HD-15.

**Files.**

- [ ] Edit `.cursor/skills/verify-hermed-bots/scripts/hv-run.sh` for the `daily` and acceptance runs.
- [ ] Edit `.cursor/skills/verify-hermed-bots/SKILL.md` to drop the draft markers the program resolved.
- [ ] Edit `.cursor/skills/verify-hermed-bots/scripts/hv-selftest.sh`.

**Build.**

- [ ] Make `scripts/hv-run.sh daily orb` run the contracts, the three robustness tests, the six actions on the nine seeded profiles, the netwatch, and the guard.
- [ ] Write the report with the Paris date and time, the Hermes version, PASS or FAIL per contract, the gaps, the duration, the guard result, and the exit code.
- [ ] Write `ALERTE` only on a FAIL or a changed protected path. Write not run with its cause when the user is absent. Never invent a result.
- [ ] Fall back to `fake` when OrbStack is absent and say so in the report.
- [ ] Create no routine. The routine goes through Manager and dr eggbot after the PRD is validated.

**You see.**

- [ ] `HV_UNDER_RUNNER=1 scripts/hv-run.sh daily orb` writes `rapport-quotidien.md` with every field and exits 0 on a clean run.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `hv-selftest.sh` gains cases for a not-run report, a FAIL with `ALERTE`, and a clean run without `ALERTE`. Run `.cursor/skills/verify-hermed-bots/scripts/hv-selftest.sh`.
- [ ] Run `npm test` and `npm run lint`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `scripts/hv-run.sh daily fake` at trunk and head. Save `hd16-daily-fake.png`. Pass when both exit 0 and head's report carries every field.
- [ ] Lane 2. Mac. Run `scripts/hv-run.sh daily orb`. Save `hd16-daily-orb.png`. Pass when the six actions pass on the nine seeded profiles and the report is complete.
- [ ] Lane 3. Cloud. Run with the user marked absent. Save `hd16-absent.png`. Pass when the report says not run with its cause and holds no result.
- [ ] Lane 4. Cloud. Change a protected path in a temporary HOME during the run. Save `hd16-guard.png`. Pass when the run exits 20 and `ALERTE` exists.
- [ ] Lane 5. Cloud. Drop `approve` during the run. Save `hd16-fail.png`. Pass when the report shows FAIL for `approve` and `ALERTE` exists.
- [ ] Lane 6. Cloud. Run a clean pass. Save `hd16-clean.png`. Pass when no `ALERTE` exists.
- [ ] Lane 7. Mac. Run with OrbStack stopped. Save `hd16-fallback.png`. Pass when the run falls back to `fake` and the report says so.
- [ ] Lane 8. Cloud. Create `~/<INFRA>/PAUSE` and run. Save `hd16-pause.png`. Pass when the run exits 3 and starts nothing.
- [ ] Lane 9. Cloud. Hold the lock and run. Save `hd16-lock.png`. Pass when the run exits 4.
- [ ] Lane 10. Cloud. Search the report and evidence for the test key. Save `hd16-secret.png`. Pass when the key value appears nowhere.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of `scripts/hv-run.sh daily` in `fake` mode at trunk and head, and in `orb` mode at head.
- [ ] Probe. Run `daily fake` three times at trunk and three times at head, interleaved, then `daily orb` once at head.
- [ ] Baseline. Record the trunk `fake` median first.
- [ ] Rule. Fail when the head `fake` median exceeds 1.25 times trunk, or the `orb` run exceeds 15 minutes. The orb budget is a proposal.

**Review gate.** None. HD-16 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] Engineer runs the full acceptance pass on `hv-hermes-test` and Dev Lead checks its report.
- [ ] The daily test produces a complete report for five consecutive working days, per Q12.
- [ ] Ayo tests the kill switch with Engineer before delivery.
- [ ] The user validates by hand, the visual judgment, a real Mac sleep, and the Keychain at first launch, in `rapports/validation-finale.md`.
- [ ] Reply to the operator with the report the execution playbook names.

## Appendix A. Prototype evidence

No prototype ran before this plan. The issue limits this PR to the plan. HD-01 is the prototype for every open question, and each `docs/spike/S*.md` file is its artifact.

Unproven until HD-01 merges. Every route and field in the fixtures. Whether one port serves the nine profiles (S7). Whether cancel stops a running tool (S3). Whether resume has an idempotence key (S2). Whether Hermes runs cleanly in an OrbStack container with no mount. Whether XCUITest runs headless from the launchd runner.

Unproven until later PRs. The version source (S8, HD-04). Desktop detection (S9, HD-14). The token source (S10, HD-05). The loop thresholds (S11, HD-05). The tunnel option (S12, HD-07).

## Appendix B. Alternatives rejected

| Option | Why it lost |
| --- | --- |
| One PR per spike item S1 to S7 | The seven items share one container, one seeding, and one report. Seven PRs would rebuild the same environment seven times. |
| All twelve spike items in phase 1 | The issue bounds phase 1 to S1 to S7. S8 to S12 each feed one later PR, so they ride with it. |
| `playbooks/autopilot-stack.md` | AGENTS.md names autopilot-full for a one-off stacked effort, and owners merge their own PRs. |
| Dashboard OAuth ticket and `/api/ws` | 2320 failures between 29 August and 14 October 2026, per the PRD. |
| ACP over SSH | The turn dies with the connection. |
| A local Hermes runtime or CLI on macOS | The Desktop updater blocks when `~/.hermes/hermes-agent` or `~/.local/bin/hermes` exists. |
| A macOS GitHub runner by default | Minutes may cost money. Q5 keeps it to the free quota or a written approval. |
| OrbStack machines (`orb create`) | They mount `/Users` by default, per the verify skill. |

## Appendix C. Risks

| Risk | PR | What the owner watches |
| --- | --- | --- |
| A spike item is impossible, so v1 is not deliverable as written | HD-01 | Stop and hand the decision to the user. Propose no replacement. |
| Contact with example-host | Every PR | `hv-guard.sh target` code 22, the netwatch, and no production key in any test environment. |
| A pass writes `~/.hermes/hermes-agent` or `~/.local/bin/hermes` | Every Mac lane | The guard before and after every pass, and code 20 stops the pass. |
| The macOS surface has no cloud control skill, so Mac lanes need the user's MacBook and the user present | HD-01 to HD-16 | The owner of HD-01 settles, before its swarm, how a cloud lane worker dispatches a Mac lane to the launchd runner and reads `$HV_WORK/evidence/`. Every later PR reuses that mechanism. |
| Code on the Mac outside the CHARTE | HD-01 | Q1 answered and the CHARTE updated by Manager before any code. |
| Fixtures pass against the fake server but not against real Hermes | HD-02, HD-03 | Lane 4 and lane 5 of HD-02 compare the fake server with `hv-hermes-test`. |
| Unmeasured loop thresholds pause too often or too late | HD-05, HD-12 | Cold start, the S11 run, and recalibration after 20 real turns per profile. |
| An orphan `ssh` or `xcodebuild` child survives a timeout | HD-07, HD-16 | Process groups killed as a group, and `ps -Ao pcpu,etime,comm -r` after each run. |
| A test secret leaks into a file, a log, or a screenshot | HD-02, HD-07, HD-16 | The secret search lanes and `hv-selftest.sh`. |
| Cancel does not stop a running tool, so K1 is incomplete | HD-15 | S3 evidence and the K3 runbook for Ayo. |
| Desktop cannot run against OrbStack without touching the protected paths | HD-14 | The fake-server hold, and the two-order test by the user by hand. |
| Budgets in the perf blocks are proposals, not measurements | Every PR | Record each measured value and replace the proposal in a follow-up. |

## Appendix D. Links and reading list

- Read `docs/prd/prd-consolide.md` and `docs/prd/spec.md` before any PR.
- Read the three Hermes doc pages the PRD lists, Programmatic Integration, Profiles, and API Server, before HD-01.
- Read `.cursor/skills/verify-hermed-bots/SKILL.md` and its `features/` maps before any PR that adds a screen.
- Run `.cursor/skills/how/SKILL.md` before HD-03, HD-06, and HD-07, the PRs that set structure.
- Run `.cursor/skills/interrogate/SKILL.md` on HD-01, HD-05, HD-13, and HD-15, the PRs with the highest cost of a wrong assumption.
- Keep the trail per `.cursor/skills/show-me-your-work/SKILL.md`, with the decision log and the subagent register at the paths in `docs/decisions/README.md`.
