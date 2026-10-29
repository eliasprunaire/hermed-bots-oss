# Hermes API facade plan

The spike PR-0 showed that the reachable Hermes service has no TLS, no per-device token and no usable revocation. This program puts a facade in front of the target Hermes instance. The facade ends TLS with a dedicated internal CA and a pinned server key, issues one opaque token per device, and talks to Hermes on the host loopback only.
The same PR holds step 2 of the spike. It names the write routes behind the facade, on a test instance only.
The program enforces one rule. The Hermes credential and the Hermes port never reach a device.
FA-01 is the only PR. The Swift client that pins the certificate is a later program.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a test run, or a SHA. The body is a how-to. The appendices explain and record.

The program runs the execution playbooks/ that the operator names. The owner squash-merges FA-01 after an independent marked verdict. The author never posts that verdict. The operator named the facade route, TLS option (a), the five minute code and the inclusion of step 2, so FA-01 is not an operator screenshot review item.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

## Program checklist

### Arm the program

- [x] State the protocol and this plan to the operator, then stop. The operator's brief in issue 58 is the go. Evidence is the brief itself.
- [ ] Read the rules from trunk at program start and re-read them at every tick.
  - [ ] `git show origin/main:AGENTS.md`
  - [ ] `git show origin/main:docs/plans/README.md`
- [ ] On the operator's go, arm the audit tick as `/loop 1h` with the tick prompt below. Never leave the cadence to memory.
- [ ] Use this tick prompt, verbatim. "Re-read the rules from trunk. Audit the program against them and fix drift in this tick. Judge progress by side effects only. Post a short status message to the operator only when the audit found a tracked change that no earlier status message reported, such as a PR opened, a head ready for review, a verdict, a merge, a blocker added or cleared, or a decision only the operator can make. Name every such change and nothing else. If the audit found none, end the turn with no reply text."
- [ ] On the operator's hold or stand-down, stop every owner at once and write nothing more.

### Spawn owners

- [x] Spawn one owner per PR. Evidence is the branch `feat/hermes-facade-pr1-acb6`.
- [ ] Follow this dependency graph. Start dependent work only after its parent merges.
  - [x] FA-01 is independent and first. It branches from `main`.
- [x] Hold the file boundaries. FA-01 touches only `facade/**`, `test/facade/**`, `docs/facade.md`, `docs/spike/pr1-write-routes.md`, `docs/plans/hermes-facade.md`, `README.md` and `package.json`. No PR touches `.claude/`, `.codex/`, or `.mcp.json`. Evidence is `git diff origin/main --stat`.
- [ ] Hold the review gate. No PR in this program waits on an operator screenshot review.

### PR mechanics, for every PR

- [ ] Open the PR ready, never draft, against `main`.
- [ ] Run `npm test` and `npm run lint` before the PR-facing push. Push with hooks on.
- [ ] Triage every automated review comment before the verdict.
- [ ] Rebase onto current trunk before the head is declared ready. Keep that merge base in fix rounds. Rebase again only at merge prep, on a conflict with trunk, or on a failure that comes from a change on trunk.

### Verdict and merge, for every PR

- [ ] An independent verifier reads the diff and the receipts at the head SHA and distrusts the PR body. A new head gets a fresh verdict, except for results that stay valid under the patch-id rule of the repository.
- [ ] Clean only when the verdict is `PASS` or `PASS+NOTES`. Findings go back to the owner, including a defect that the verifier filed as a note.
- [ ] The owner squash-merges FA-01 with `scripts/squash-merge.js` after a marked verdict on the head SHA, `verdict-gate` green, all CI green, no conflict with `main`, and a non-draft PR. The owner never posts the verdict or the marker.

### Boot recipe, for every live lane

Each live lane runs in a clean checkout at the PR head. Do not launch the macOS app and do not run UI tests.

- [ ] `git fetch origin <head-branch> && git checkout <head SHA>`.
- [ ] Install Node 22 with `npm ci`. The facade tests need `openssl` on the path.
- [ ] Deliver input only through `npm test`, `npm run lint`, `node scripts/infra-guard-ci.js` and the files under `facade/testkit/`. The read-only diagnostics are `git diff origin/main --stat` and a text search over the facade files.
- [ ] Save every artifact to `<scratch dir>/worker-<n>/<slug>.txt` and return the paths with the report.

## Put an authentication and TLS facade in front of Hermes (FA-01)

**Depends on.** None.

**Files.**

- [x] Create `facade/src/config.js`, `facade/src/store.js`, `facade/src/audit.js`, `facade/src/ratelimit.js`, `facade/src/idempotency.js` and `facade/src/policy.js`.
- [x] Create `facade/src/tls.js`, `facade/src/websocket.js`, `facade/src/bridge.js`, `facade/src/proxy.js`, `facade/src/exposure.js` and `facade/src/server.js`.
- [x] Create `facade/bin/hermes-facade.js`.
- [x] Create the test kit under `facade/testkit/`, with the Hermes stand-in, the pinned client, the stack, the child process helper, the address helpers, the disposable-instance guard, the live smoke script and the perf probe.
- [x] Create `test/facade/acceptance.test.js`, `behaviour.test.js`, `hardening.test.js`, `integrity.test.js` and `contract.test.js`.
- [x] Create `docs/facade.md` and `docs/spike/pr1-write-routes.md`.
- [x] Create `docs/plans/hermes-facade.md`.
- [x] Edit `README.md` to point at `docs/facade.md` and `package.json` to require Node 22.

**Build.**

- [x] End TLS 1.3 in the facade with a dedicated internal CA and an EC server key. Offer no plain HTTP listener. Give clients `pinnedClientOptions`, which trusts that CA alone and checks the SHA-256 of the server public key.
- [x] Issue opaque device tokens (`hbf_` and 256 random bits), keep SHA-256 hashes only, and reload the state file when it changes so a revocation made on the host applies before the next call and before the next relayed event. Close the open sockets of a revoked device.
- [x] Mint one-use enrollment codes (100 random bits, 5 minutes) from the host CLI or from an admin device. Answer an unknown, expired or reused code with the same `401`.
- [x] Give each device the role `admin` or `normal`. Serve admin routes to admins only. Count only active devices against the limit of 200.
- [x] Write an audit line in UTC for every enrollment, denial, revocation, write and request, including the host commands. Never write a device-controlled value raw. Mask by field name, by credential shape and by any configured secret whatever its length, and require a credential of at least 16 characters.
- [x] Limit each device per minute, each source on enrollment, and each source on failed authentication.
- [x] Talk to Hermes on the loopback only. Refuse a wildcard or non-loopback Hermes host. Refuse to start, and fail `check-exposure`, when any non-loopback address of the host reaches the Hermes port or when a probe proves nothing. Only a refusal proves a port closed.
- [x] Serve a read allowlist over HTTP, project the Hermes status to four fields, drop every Hermes response header except five, and refuse a redirect.
- [x] Bridge the JSON-RPC socket message by message with a default-deny method list. Send every request to Hermes under an id the facade made, and match each response by that id. Strip `idempotency_key` before Hermes sees the call.
- [x] Make writes idempotent per device and key, replay a success, free a failed key, and refuse a key whose outcome is unknown. Keep the keys in a synced journal that survives a restart or a crash.
- [x] Identify the write routes on a Hermes test instance and record them in `docs/spike/pr1-write-routes.md`.
- [x] Let the live smoke script write only to a marked disposable instance that reports the marked data directory.
- [x] Target Node 22 and the TLS 1.3 stack only. Add no fallback for older versions.

**You see.**

- [x] An operator runs `init-tls`, `serve` and `enroll --role admin` on the host, enrolls a device with the code, and the device reads sessions over pinned TLS.
- [x] An admin device lists devices and revokes one. That device is refused on its next call and its socket closes.
- [x] A prompt, an approval and a cancel sent twice with one key reach Hermes once.
- [x] `shell.exec`, `config.set` and `vault.add` sent over the socket come back refused.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [x] `test/facade/acceptance.test.js` holds the six acceptance tests, numbered 1 to 6 in their titles. Run `node --test test/facade/acceptance.test.js`.
- [x] `test/facade/hardening.test.js` covers the malformed upgrade target, the journal across a restart and a SIGKILL, audit masking by value and the device limit.
- [x] `test/facade/integrity.test.js` covers id collisions between reads and writes, the exposure check through the real probe, secrets of any length, audited host commands, revocation before a relayed event and the disposable-instance guard.
- [x] `test/facade/behaviour.test.js` covers roles, rate limits, the socket codec, the store, the audit file, the policy, the configuration, the pin and the CLI. `test/facade/contract.test.js` keeps addresses, host names and local paths out of the facade files.
- [x] Run `npm test` and `npm run lint`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `the verifier worker model` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `node --test test/facade/acceptance.test.js` at trunk and at head. Save `fa01-regression.txt`. Pass when trunk reports no such file and head passes all numbered tests.
- [ ] Lane 2. Mutate `facade/src/store.js` so a revoked device still authenticates, then run the acceptance file. Save `fa01-mutation-revoke.txt`. Pass when test 2 fails, and restore the file afterwards.
- [ ] Lane 3. Mutate `facade/src/bridge.js` so the idempotency check is skipped, then run the acceptance file. Save `fa01-mutation-idempotency.txt`. Pass when test 6 fails, and restore the file afterwards.
- [ ] Lane 4. Mutate `facade/src/proxy.js` so `set-cookie` crosses the facade, then run the acceptance file. Save `fa01-mutation-headers.txt`. Pass when test 4 fails, and restore the file afterwards.
- [ ] Lane 5. Read `facade/src/policy.js` and the Hermes method list at tag `v0.22.5`. Save `fa01-policy.txt`. Pass when every allowed method exists upstream and no shell, config, vault, connector or file method is allowed.
- [ ] Lane 6. Run `node facade/bin/hermes-facade.js enroll`, `devices` and `revoke` on a scratch state directory. Save `fa01-cli.txt`. Pass when the code is printed once, the device lists, the revoked device shows as revoked, and the audit file holds one line per command.
- [ ] Lane 7. Start a Hermes test instance on the loopback with a throwaway data directory marked as disposable, then run `facade/testkit/live-smoke.js` against it. Save `fa01-live.txt`. Pass when every line is `PASS`, and when the same run without the marker stops with `refusing to write`. Write nothing to a real instance.
- [ ] Lane 8. Run `npm test` and `npm run lint` at head. Save `fa01-node.txt`. Pass when both exit 0.
- [ ] Lane 9. Read the new files for the Hermes credential, device tokens and enrollment codes in any log, audit or error text. Save `fa01-secrets.txt`. Pass when none is printed, stored or returned outside its one issuing reply.
- [ ] Lane 10. Run `node scripts/infra-guard-ci.js` on the diff and read the diff for addresses, host names, user names, local paths and topology. Save `fa01-infra.txt`. Pass when the scan exits 0 and the diff has none beyond the two generic loopback examples.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Median time added by the facade on one `GET /api/sessions`, over 300 sequential calls on a kept-alive pinned TLS connection, against the stand-in for Hermes.
- [ ] Probe. At head, run `node facade/testkit/perf-probe.js` three times. At trunk, record that the probe is absent.
- [ ] Baseline. Record the trunk absence first. The probe prints its own direct baseline on each run, about 0.1 ms.
- [ ] Rule. Fail when the added median exceeds 5 ms on the Linux CI runner.

**Review gate.** None. FA-01 has no screen, so no screenshot, video or operator review gates it. The operator validates the program in the end.

**Merge.**

- [ ] A clean independent verdict at the exact head SHA.
- [ ] Automated review comments triaged.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] Reply to the operator with a report of what shipped, what was verified and what remains.

## Appendix A. Prototype evidence

A throwaway `hermes serve` 0.22.5 ran on the loopback with an empty data directory marked as disposable and no model provider. The facade ran in front of it with a generated CA. `facade/testkit/live-smoke.js` printed `PASS` on every check, including a session created twice with one key and a prompt submitted twice with one key that left one row, and it refused to run once the marker was removed.
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
| Reuse the device ids toward Hermes | A read and a write could share an id, and a response could settle the wrong call. The facade makes its own ids. |

## Appendix C. Risks

| Risk | PR | What the owner watches |
| --- | --- | --- |
| The Hermes root page exposes the process token to anyone who reaches the port | FA-01 | The start check and `check-exposure` fail closed. The host stays single-purpose. |
| The idempotency journal holds results and grows with traffic | FA-01 | It is private to the state directory, compacts at start and every 5000 records, and drops entries after 24 hours. |
| The method allowlist drifts from Hermes | FA-01 | Lane 5 compares it with the Hermes source at each Hermes version. |
| The pin changes when the server key changes | FA-01 | `init-tls` keeps the key on renewal. A new key means a new pin for every client. |
| The approval round trip is not proven with a model provider | FA-01 | Appendix A names it. A later run on a test instance with a provider closes it. |

## Appendix D. Links and reading list

- Read `docs/spike/pr0-api-feasibility.md`, `docs/spike/pr1-write-routes.md` and `docs/facade.md` before editing.
- Read `facade/src/policy.js` for the allowlist and `facade/src/bridge.js` for the write path.
