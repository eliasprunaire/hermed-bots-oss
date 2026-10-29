# Hermes API facade plan

The spike PR-0 showed that the reachable Hermes service has no TLS, no per-device token and no usable revocation. This program puts a facade in front of the target Hermes instance. The facade ends TLS with a dedicated internal CA and a pinned server key, issues one opaque token per device, and talks to Hermes on the host loopback only.
The same PR holds step 2 of the spike. It names the write routes behind the facade, on a test instance only.
The program enforces one rule. The Hermes credential and the Hermes port never reach a device.
FA-01 is the only PR. The Swift client that pins the certificate is a later program.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a test run, or a SHA. The body is a how-to. The appendices explain and record.

The program runs `pstack/skills/poteto-mode/playbooks/autopilot-full.md`. The owner squash-merges FA-01 after an independent marked verdict. The root never posts that verdict. The operator named the facade route, TLS option (a), the five minute code and the inclusion of step 2, so FA-01 is not an operator screenshot review item.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

## Program checklist

### Arm the program

- [x] State the protocol and this plan to the operator, then stop. The operator's brief in issue 58 is the go. Evidence is the brief itself.
- [ ] Read these from trunk at program start. Re-read them at every tick.
  - [ ] `git show origin/main:pstack/skills/poteto-mode/playbooks/autopilot-full.md`
  - [ ] `git show origin/main:pstack/skills/swarm/SKILL.md`
  - [ ] `git show origin/main:pstack/skills/control-cli/SKILL.md`
  - [ ] `git show origin/main:pstack/skills/poteto-mode/playbooks/opening-a-pr.md`
  - [ ] `git show origin/main:pstack/skills/poteto-mode/playbooks/babysit.md`
  - [ ] `git show origin/main:pstack/skills/poteto-mode/playbooks/shipping.md`
  - [ ] `git show origin/main:pstack/skills/show-me-your-work/SKILL.md`
- [ ] On the operator's go, arm the audit tick as `/loop 1h` with the tick prompt below. Never leave the cadence to memory.
- [ ] Use this tick prompt, verbatim. "Re-read the execution playbook from trunk. Audit the operation against it and fix drift in this tick. Probe every active lane and judge progress by side effects only. Stand down a stuck lane and dispatch its replacement now. Then post a short status message to the operator in chat only when the audit found a tracked change that no earlier status message reported, such as a PR opened, a code-ready head, a round launched or closed, a verdict, a merge, a stuck agent and the action taken, a blocker added or cleared, or a decision only the operator can make. Name every such change and nothing else. Do not repeat a table, the merged list, or an unchanged blocker. If the audit found none, end the turn with no reply text. Either way, log this tick's row in your decision trail. The row names the items reported, or none."
- [ ] On the operator's hold or stand-down, send every owner a zero-writes order at once.

### Spawn owners

- [x] Spawn one owner per PR with the full lifecycle the execution playbook names. Evidence is the branch `feat/hermes-facade-pr1-acb6`.
- [ ] Follow this dependency graph. Start dependent work only after its parent merges, or base it on the parent branch when the execution playbook stacks.
  - [x] FA-01 is independent and first. It branches from `main`.
- [x] Hold the file boundaries. FA-01 touches only `facade/**`, `test/facade/**`, `docs/facade.md`, `docs/spike/pr1-write-routes.md`, `docs/plans/hermes-facade.md`, `README.md` and `package.json`. No PR touches `.claude/`, `.codex/`, or `.mcp.json`. Evidence is `git diff origin/main --stat`.
- [ ] Hold the review gate. No PR in this program waits on an operator screenshot review.

### PR mechanics, for every PR

- [ ] Resolve the forge once. Default to `gh`; if `command -v origin` succeeds and Origin can resolve the repository, use `origin pr` for every PR operation. Record any fallback to `gh`. Never require `gt`.
- [ ] Open the PR ready, never draft, per **Opening a PR**. Use the run's built-in PR tool when it has one, else `origin pr create --status open --base main` or `gh pr create --base main` according to the resolved forge. A stack child targets its parent branch.
- [ ] Run the repo's lint and typecheck once before the PR-facing push. Push with hooks on.
- [ ] Run `/deslop` before each commit and `/no-comments` before review.
- [ ] Triage every Bugbot and security-reviewer comment per `../references/bugbot-triage.md`.
- [ ] Rebase onto current trunk before the code-ready report and babysit. Keep that merge base in fix rounds. Rebase again only at merge prep, on a `git merge-tree` conflict with trunk, or on a CI failure that comes from a change on trunk.

### Verdict and merge, for every PR

- [ ] A full swarm runs once, at the code-ready head. Another full swarm runs only for new behavior, a redesign, or a large new diff. A rebase, a merge-conflict resolution, or a minor fix gets a single verifier at the new head. Run each full swarm per `pstack/skills/swarm/SKILL.md`. One gates lane. The ten live lanes from the PR's **Verify, live** block. The perf lane from its **Verify, perf** block. Two or more audit lanes, each with its own focus, that read the diff and the receipts and distrust the PR body. The root audits the receipts in the merge-ready report before the verdict.
- [ ] Clean only when every lane is `PASS`. Findings go back to the owner, including a defect that a lane filed as a note. A new head gets a fresh verdict, except for results that stay valid under the patch-id rule in `playbooks/shipping.md`.
- [ ] The owner squash-merges FA-01 with `scripts/squash-merge.js` after a marked `PASS` or `PASS+NOTES` comment with `<!-- dev-lead-verifier -->` on the head SHA, `verdict-gate` green, all CI green, no conflict with `main`, and a non-draft PR. The owner never launches the verifier and never posts the marker.

### Boot recipe, for every live lane

Each live lane runs on its own cloud VM at the PR head. Drive through `control-cli`. Do not launch the macOS app and do not run XCUITest.

- [ ] `git fetch origin <head-branch> && git checkout <head SHA>`.
- [ ] Install Node 22 with `npm ci`. The facade tests need `openssl` on the path.
- [ ] Deliver input only through `npm test`, `npm run lint`, `node scripts/infra-guard-ci.js` and the files under `facade/testkit/`. The read-only diagnostics are `git diff origin/main --stat` and `rg` over the facade files.
- [ ] Save every artifact to `/tmp/swarm-fa-01/worker-<n>/<slug>.txt` and return the paths with the report.

## Put an authentication and TLS facade in front of Hermes (FA-01)

**Depends on.** None.

**Files.**

- [x] Create `facade/src/config.js`, `facade/src/store.js`, `facade/src/audit.js`, `facade/src/ratelimit.js`, `facade/src/idempotency.js` and `facade/src/policy.js`.
- [x] Create `facade/src/tls.js`, `facade/src/websocket.js`, `facade/src/bridge.js`, `facade/src/proxy.js`, `facade/src/exposure.js` and `facade/src/server.js`.
- [x] Create `facade/bin/hermes-facade.js`.
- [x] Create `facade/testkit/fake-hermes.js`, `client.js`, `stack.js`, `live-smoke.js` and `perf-probe.js`.
- [x] Create `test/facade/acceptance.test.js` and `test/facade/behaviour.test.js`.
- [x] Create `docs/facade.md` and `docs/spike/pr1-write-routes.md`.
- [x] Create `docs/plans/hermes-facade.md`.
- [x] Edit `README.md` to point at `docs/facade.md` and `package.json` to require Node 22.

**Build.**

- [x] End TLS 1.3 in the facade with a dedicated internal CA and an EC server key. Offer no plain HTTP listener. Give clients `pinnedClientOptions`, which trusts that CA alone and checks the SHA-256 of the server public key.
- [x] Issue opaque device tokens (`hbf_` and 256 random bits), keep SHA-256 hashes only, and reload the state file when it changes so a revocation made on the host applies on the next call. Close the open sockets of a revoked device.
- [x] Mint one-use enrollment codes (100 random bits, 5 minutes) from the host CLI or from an admin device. Answer an unknown, expired or reused code with the same `401`.
- [x] Give each device the role `admin` or `normal`. Serve admin routes to admins only.
- [x] Write an audit line in UTC for every enrollment, denial, revocation, write and request. Mask any secret-looking key.
- [x] Limit each device per minute, each source on enrollment, and each source on failed authentication.
- [x] Talk to Hermes on the loopback only. Refuse a non-loopback Hermes host, refuse to start when a non-loopback interface reaches the Hermes port, and expose `check-exposure`.
- [x] Serve a read allowlist over HTTP, project the Hermes status to four fields, drop every Hermes response header except five, and refuse a redirect.
- [x] Bridge the JSON-RPC socket message by message with a default-deny method list. Strip `idempotency_key` before Hermes sees the call.
- [x] Make writes idempotent per device and key, replay a success, free a failed key, and refuse a key whose outcome is unknown.
- [x] Identify the write routes on a Hermes test instance and record them in `docs/spike/pr1-write-routes.md`.
- [x] Target Node 22 and the TLS 1.3 stack only. Add no fallback for older versions.

**You see.**

- [x] An operator runs `init-tls`, `serve` and `enroll --role admin` on the host, enrolls a device with the code, and the device reads sessions over pinned TLS.
- [x] An admin device lists devices and revokes one. That device is refused on its next call and its socket closes.
- [x] A prompt, an approval and a cancel sent twice with one key reach Hermes once.
- [x] `shell.exec`, `config.set` and `vault.add` sent over the socket come back refused.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [x] `test/facade/acceptance.test.js` holds the six acceptance tests, numbered 1 to 6 in their titles. Run `node --test test/facade/acceptance.test.js`.
- [x] `test/facade/behaviour.test.js` covers roles, rate limits, the socket codec, the store, the audit file, the policy, the configuration, the pin and the CLI.
- [x] Run `npm test` and `npm run lint`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh-fast` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `node --test test/facade/acceptance.test.js` at trunk and at head. Save `fa01-regression.txt`. Pass when trunk reports no such file and head passes all numbered tests.
- [ ] Lane 2. Mutate `facade/src/store.js` so a revoked device still authenticates, then run the acceptance file. Save `fa01-mutation-revoke.txt`. Pass when test 2 fails, and restore the file afterwards.
- [ ] Lane 3. Mutate `facade/src/bridge.js` so the idempotency check is skipped, then run the acceptance file. Save `fa01-mutation-idempotency.txt`. Pass when test 6 fails, and restore the file afterwards.
- [ ] Lane 4. Mutate `facade/src/proxy.js` so `set-cookie` crosses the facade, then run the acceptance file. Save `fa01-mutation-headers.txt`. Pass when test 4 fails, and restore the file afterwards.
- [ ] Lane 5. Read `facade/src/policy.js` and the Hermes method list at tag `v0.22.5`. Save `fa01-policy.txt`. Pass when every allowed method exists upstream and no shell, config, vault, connector or file method is allowed.
- [ ] Lane 6. Run `node facade/bin/hermes-facade.js enroll`, `devices` and `revoke` on a scratch state directory. Save `fa01-cli.txt`. Pass when the code is printed once, the device lists, and the revoked device shows as revoked.
- [ ] Lane 7. Start a Hermes test instance on the loopback with a throwaway data directory, then run `facade/testkit/live-smoke.js` against it. Save `fa01-live.txt`. Pass when every line is `PASS`. Stay on a test instance and write nothing to a real one.
- [ ] Lane 8. Run `npm test` and `npm run lint` at head. Save `fa01-node.txt`. Pass when both exit 0.
- [ ] Lane 9. Read the new files for the Hermes credential, device tokens and enrollment codes in any log, audit or error text. Save `fa01-secrets.txt`. Pass when none is printed, stored or returned outside its one issuing reply.
- [ ] Lane 10. Run `node scripts/infra-guard-ci.js` on the diff and read the diff for addresses, host names, user names and local paths. Save `fa01-infra.txt`. Pass when the scan exits 0 and the diff has none.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Median time added by the facade on one `GET /api/sessions`, over 300 sequential calls on a kept-alive pinned TLS connection, against the stand-in for Hermes.
- [ ] Probe. At head, run `node facade/testkit/perf-probe.js` three times. At trunk, record that the probe is absent.
- [ ] Baseline. Record the trunk absence first. The probe prints its own direct baseline on each run, about 0.1 ms.
- [ ] Rule. Fail when the added median exceeds 5 ms on the Linux CI runner.

**Review gate.** None. FA-01 has no screen, so no screenshot, video or operator review gates it. The operator validates the program in the end.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] Reply to the operator with the report the execution playbook names.

## Appendix A. Prototype evidence

A throwaway `hermes serve` 0.22.5 ran on the loopback of the build machine with an empty data directory and no model provider. The facade ran in front of it with a generated CA. `facade/testkit/live-smoke.js` printed `PASS` on every check, including a session created twice with one key and a prompt submitted twice with one key that left one row.
Hermes alone does not do that. Two identical `prompt.submit` calls gave `streaming` and then `queued`, so the facade owns idempotency. The same run showed that the root page of the headless backend writes the process token into the page, which is why the facade refuses to start when the Hermes port is reachable beyond the loopback.
Unproven. A real model turn with a tool approval, the gated mode of Hermes, and the Swift client that pins the certificate.

## Appendix B. Alternatives rejected

| Option | Why it lost |
| --- | --- |
| Use the native bearer flow of Hermes | It needs an interactive login, works only behind the gated bind, and has no device identity. |
| Reverse proxy with a stock web server | It does not give one token per device, immediate revocation, role rules on socket methods or idempotent writes. |
| A public certificate authority | The operator chose option (a), a dedicated internal CA with pinning. |
| Idempotency inside Hermes | Hermes is not ours to change, and the run showed it queues a duplicate. |
| REST write routes on the facade | The writes live on the JSON-RPC socket. A second surface would double the policy. |
| `playbooks/autopilot-stack.md` | There is one PR, and the owner has merge authority after the independent verdict. |

## Appendix C. Risks

| Risk | PR | What the owner watches |
| --- | --- | --- |
| The Hermes root page exposes the process token to anyone who reaches the port | FA-01 | The start check and `check-exposure` fail closed. The host stays single-purpose. |
| Idempotency keys live in memory | FA-01 | A restart forgets them. A later PR may persist them. |
| The method allowlist drifts from Hermes | FA-01 | Lane 5 compares it with the Hermes source at each Hermes version. |
| The pin changes when the server key changes | FA-01 | `init-tls` keeps the key on renewal. A new key means a new pin for every client. |
| The approval round trip is not proven with a model provider | FA-01 | Appendix A names it. A later run on a test instance with a provider closes it. |

## Appendix D. Links and reading list

- Read `docs/spike/pr0-api-feasibility.md`, `docs/spike/pr1-write-routes.md` and `docs/facade.md` before editing.
- Read `facade/src/policy.js` for the allowlist and `facade/src/bridge.js` for the write path.
- Keep the trail per `pstack/skills/show-me-your-work/SKILL.md`.
