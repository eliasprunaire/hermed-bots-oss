# Hermes API product contract plan (PR-2)

PR-0 and PR-1 of the Hermes API program are on `main`. The facade in `scripts/hermes-facade.js` ends TLS, holds per-device tokens, and forwards an allowlisted HTTP surface to a loopback Hermes. No product client consumes that surface yet. This program publishes the product contract for that surface, with mapping, errors, and contract tests, and it corrects the two doc NOTES left by PR #60. HA-02 is the only PR. Mac `APITransport` and certificate pinning stay out (PR-3). iOS stays out (PR-6). No host production activation runs in this PR.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a screenshot, a test run, or a SHA. The body is a how-to. The appendices explain and record.

The program follows the boxes in this plan. No playbooks/ tree exists on origin/main. The owner squash-merges HA-02 after an independent marked verdict. The root never posts that verdict. The operator already named the product contract and the NOTES fixes, so HA-02 is not an operator screenshot review item.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

## Program checklist

### Arm the program

- [ ] State the protocol and this plan to the operator, then stop. Start execution only on the operator's explicit go.
- [ ] Read these from trunk at program start. Re-read them at every tick. Cite only paths that exist on `origin/main`.
  - [ ] `git show origin/main:AGENTS.md`
  - [ ] `git show origin/main:docs/prd/prd-consolide.md`
  - [ ] `git show origin/main:docs/spike/pr1-facade.md`
  - [ ] `git show origin/main:scripts/hermes-facade.js`
  - [ ] `git show origin/main:test/hermes-facade.test.js`
  - [ ] `git show origin/main:scripts/infra-guard-ci.js`
  - [ ] `git show origin/main:scripts/check-plan.mjs`
- [ ] On the operator's go, arm the audit tick as `/loop 1h` with the tick prompt below. Never leave the cadence to memory.
- [ ] Use this tick prompt, verbatim. "Re-read this plan and `git show origin/main:AGENTS.md`. Audit the operation against them and fix drift in this tick. Probe every active lane and judge progress by side effects only. Stand down a stuck lane and dispatch its replacement now. Then post a short status message to the operator in chat only when the audit found a tracked change that no earlier status message reported, such as a PR opened, a code-ready head, a round launched or closed, a verdict, a merge, a stuck agent and the action taken, a blocker added or cleared, or a decision only the operator can make. Name every such change and nothing else. Do not repeat a table, the merged list, or an unchanged blocker. If the audit found none, end the turn with no reply text. Either way, log this tick's row in your decision trail. The row names the items reported, or none."
- [ ] On the operator's hold or stand-down, send every owner a zero-writes order at once.

### Spawn owners

- [ ] Spawn one owner per PR. That owner carries the PR from branch to squash-merge as this plan names.
- [ ] Follow this dependency graph. Start dependent work only after its parent merges. HA-02 does not stack.
  - [ ] HA-02 is independent and first. It branches from `main`.
- [ ] Hold the file boundaries. HA-02 touches only `docs/api/**`, `docs/spike/pr1-facade.md`, `docs/plans/hermes-api-pr2.md`, `scripts/hermes-facade.js` only when a contract gap forces a small allowlist or error-shape fix, `test/hermes-api-contract.test.js`, and `package.json` only if a new test script is required. No PR touches Swift, `.claude/`, `.codex/`, or `.mcp.json`.
- [ ] Hold the review gate. No PR in this program waits on an operator screenshot review.

### PR mechanics, for every PR

- [ ] Resolve the forge once. Default to `gh`; if `command -v origin` succeeds and Origin can resolve the repository, use `origin pr` for every PR operation. Record any fallback to `gh`. Never require `gt`.
- [ ] Open the PR ready, never draft. Use the run's built-in PR tool when it has one, else `origin pr create --status open --base main` or `gh pr create --base main` according to the resolved forge. A stack child targets its parent branch.
- [ ] Run the repo's lint and typecheck once before the PR-facing push. Push with hooks on.
- [ ] Run `npm test` and `npm run lint` before every commit, as `git show origin/main:AGENTS.md` names. Do not add comments that restate the code.
- [ ] Triage every Bugbot and security-reviewer comment. Fix a real defect. Dismiss noise with a concrete reason written on the thread.
- [ ] Rebase onto current trunk before the code-ready report and babysit. Keep that merge base in fix rounds. Rebase again only at merge prep, on a `git merge-tree` conflict with trunk, or on a CI failure that comes from a change on trunk.

### Verdict and merge, for every PR

- [ ] A full swarm runs once, at the code-ready head. Another full swarm runs only for new behavior, a redesign, or a large new diff. A rebase, a merge-conflict resolution, or a minor fix gets a single verifier at the new head. One gates lane. The ten live lanes from the PR's **Verify, live** block. The perf lane from its **Verify, perf** block. Two or more audit lanes, each with its own focus, that read the diff and the receipts and distrust the PR body. The root audits the receipts in the merge-ready report before the verdict.
- [ ] Clean only when every lane is `PASS`. Findings go back to the owner, including a defect that a lane filed as a note. A new head gets a fresh verdict, except when `git patch-id --stable`, `git patch-id --verbatim`, and the exact replay tree against the PR base all match a prior marked SHA of this PR. Read `git show origin/main:AGENTS.md` for that rule.
- [ ] The owner squash-merges HA-02 with `scripts/squash-merge.js` after a marked `PASS` or `PASS+NOTES` comment with `<!-- dev-lead-verifier -->` on the head SHA, `verdict-gate` green, all CI green, no conflict with `main`, and a non-draft PR. The owner never launches the verifier and never posts the marker.

### Boot recipe, for every live lane

Each live lane runs on its own cloud VM at the PR head. Do not launch the macOS app and do not run XCUITest. Node 26 is a prerequisite. `npm ci` installs dependencies. It does not install Node. Do not change CI in this program.

- [ ] `git fetch origin <head-branch> && git checkout <head SHA>`.
- [ ] Confirm Node 26 is present. Then run `npm ci`.
- [ ] Deliver input only through `npm test`, `npm run lint`, and reads of the OpenAPI file plus `test/hermes-api-contract.test.js`. The read-only diagnostics are `git diff origin/main --stat` and `rg` over `docs/api` and `scripts/hermes-facade.js`.
- [ ] Save every screenshot to `/tmp/swarm-ha-02/worker-<n>/<slug>.png` and return the paths with the report.

## Publish the Hermes product API contract (HA-02)

**Depends on.** PR-1 facade on `main` (merged as GitHub PR #60).

**Files.**

- [ ] Create `docs/api/hermes-product.openapi.yaml` (or `.json`) for the product surface behind the facade.
- [ ] Create `docs/api/README.md` with examples that contain no secret, no host, no local path, and no machine name.
- [ ] Create `docs/plans/hermes-api-pr2.md` (this plan).
- [ ] Create `test/hermes-api-contract.test.js` so every socle route in the contract has a green assertion against the facade with a fake upstream.
- [ ] Edit `docs/spike/pr1-facade.md` to replace the stale "28 tests" line with "29 tests", and to state that a 409 on a reused idempotency key requires a preserved body fingerprint, while a missing fingerprint and a different body yield 502.
- [ ] Edit `scripts/hermes-facade.js` only if a contract gap forces a documented error shape or a missing operation-id lookup that the PRD already requires. Keep the HTTP allowlist. Do not add a WebSocket bridge in this PR.

**Build.**

- [ ] Encode the socle read and write routes already allowlisted by the facade as the product contract. Reads cover health, sessions list or get, models or capabilities as exposed. Writes cover run create, approval, stop, session create, session model, and session chat. Mark `chat/stream` as out of contract (not replayable).
- [ ] Encode the mapping rule as one Hermed bot to one named Hermes profile (default after PR-1 evidence). Document the stable bot id and the profile id fields. Do not invent a second mapping style in the same PR.
- [ ] Encode idempotency. Writes require `Idempotency-Key`. The contract documents replay, 409 on same key with different body when a fingerprint exists, and 502 `write_outcome_unknown` when the outcome is unsure. Document an operation id the client can read back when the facade already exposes one. If none exists yet, add the smallest lookup that the contract promises and test it.
- [ ] Encode error shapes used by the facade (`401`, `403`, `404` `route_not_allowed`, `409`, `429` with `Retry-After`, `502`, `503`) without secrets in examples.
- [ ] Keep TLS, audit, and rate-limit behaviour as already shipped in PR-1. The contract names them. It does not re-implement them.
- [ ] Keep Hermes credentials and the root API key off every example and every client-facing doc line.

**You see.**

- [ ] A reviewer can open `docs/api/` and learn the product surface without reading the facade source.
- [ ] Contract tests fail on trunk (no file) and pass on the head.
- [ ] The two NOTES from PR #60 are gone from `docs/spike/pr1-facade.md`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Contract tests cover every socle route in the OpenAPI file against the facade with a fake upstream, including one idempotent write replay and one auth failure. Run `npm test` and `npm run lint`.
- [ ] `rg` over `docs/api` finds no private IP, no local absolute path, and no machine or user name. Run `git diff origin/main...HEAD | node scripts/infra-guard-ci.js --diff`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh-fast` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run the new contract test file at trunk and at head. Save `ha02-regression.png`. Pass when trunk reports a missing file or filter and head passes every case.
- [ ] Lane 2. Parse the OpenAPI file with the Node test harness (or a tiny schema load). Save `ha02-openapi.png`. Pass when the file loads and lists every socle path named in Build.
- [ ] Lane 3. Read the mapping section of the contract and of `docs/api/README.md`. Save `ha02-mapping.png`. Pass when one bot maps to one named profile and no second mapping style appears.
- [ ] Lane 4. Read the idempotency section. Save `ha02-idempotency.png`. Pass when replay, 409-with-fingerprint, and 502-without-certainty are all named, matching the facade behaviour on `main`.
- [ ] Lane 5. Search `docs/api` for secrets, bearer samples that look real, private IPs, local paths, and machine names. Save `ha02-redact.png`. Pass when none appear.
- [ ] Lane 6. Diff `docs/spike/pr1-facade.md` against trunk. Save `ha02-notes.png`. Pass when the test count says 29 and the 409 fingerprint note is present.
- [ ] Lane 7. Confirm no Swift file and no WebSocket bridge file appears in `git diff --name-only origin/main...HEAD`. Save `ha02-scope.png`. Pass when the diff stays inside the file boundaries above.
- [ ] Lane 8. Run `npm test` and `npm run lint` at head. Save `ha02-node.png`. Pass when both exit 0.
- [ ] Lane 9. Confirm the root API key never appears in `docs/api` examples and that the contract tells clients they never hold it. Save `ha02-root-key.png`. Pass when both hold.
- [ ] Lane 10. Run `git diff origin/main...HEAD | node scripts/infra-guard-ci.js --diff`. Save `ha02-infra.png`. Pass when the scan exits 0.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of the new contract test file on the Linux CI runner.
- [ ] Probe. At head, run `npm test -- test/hermes-api-contract.test.js` five times, timed by `/usr/bin/time`. At trunk, run the same filter once between head runs and record that the file is absent (or the filter fails).
- [ ] Baseline. Record the trunk absence first.
- [ ] Rule. Fail when the head median exceeds 15 s on the Linux CI runner.

**Review gate.** None. HA-02 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] Reply to the operator with a short status of every box and its evidence.

## Appendix A. Prototype evidence

PR-1 on `main` already proves TLS, per-device tokens, enrolment, revocation, roles, audit, rate limits, and idempotent HTTP writes against a fake upstream and a test Hermes API server. The product OpenAPI file and its contract tests are new. No prototype of the YAML ran outside this plan.

Unproven until a later PR. A real product client (Mac or iOS). A WebSocket JSON-RPC bridge. Host production activation of the facade listener. Certificate pinning inside the macOS app.

## Appendix B. Alternatives rejected

| Option | Why it lost |
| --- | --- |
| Start Mac `APITransport` and pinning in this PR | That is PR-3 in the product PRD. The contract must land first. |
| Port the closed PR #59 WebSocket bridge into this PR | `main` ships the HTTP facade from #60. A bridge is a separate verifiable unit and needs an explicit operator go. |
| Activate the facade on the production Hermes host in this PR | Activation needs a named operator go. This PR stays on docs, tests, and optional tiny facade fixes against a fake upstream or a test instance. |
| Bundle iOS skeleton work | That is PR-6 and depends on this contract. |
| A stacked autopilot playbook | There is one PR, and the owner has merge authority after the independent verdict. |

## Appendix C. Risks

| Risk | PR | What the owner watches |
| --- | --- | --- |
| Contract drifts from the allowlist in `scripts/hermes-facade.js` | HA-02 | Generate or assert the path list from one source in the contract test. |
| Mapping choice is wrong for a later bot model | HA-02 | Keep one style (bot to named profile). A later PR can add an alternate with its own tests. |
| A facade tweak breaks PR-1 acceptance tests | HA-02 | Re-run the full `hermes-facade` suite. Prefer doc-only changes when possible. |
| Infra leaks into OpenAPI examples | HA-02 | Lane 5 and infra-guard. Use placeholders only. |

## Appendix D. Links and reading list

- Read `docs/spike/pr1-facade.md` and `scripts/hermes-facade.js` before editing.
- Read the product PRD section on PR-2 (API operationnelle) for the socle, mapping, and idempotency rules. Do not copy any local infra file into the repository.
- Keep a local decision trail in the owner chat. Each tick row names the items reported, or none.
