# SSH identity preview and unreachable diagnosis plan

The Connexion pane can show a file identity while Connect uses another agent. A tunnel that dies then reads as host unreachable. This program makes the preview match the agent Connect will use, then names four SSH failures without secrets. SI-01 closes issue 53. SI-02 closes issue 55 and needs SI-01. Keys stay in an external agent. The app never stores a private key.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a screenshot, a test run, or a SHA. The body is a how-to. The appendices explain and record.

The program runs `pstack/skills/poteto-mode/playbooks/autopilot-full.md`. The repository owner squash-merges SI-01 and SI-02. This agent never launches a verifier and never posts a verdict marker. The operator already named the preview rule and the four failure cases, so neither PR waits on a screenshot click.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

## Program checklist

### Arm the program

- [ ] State the protocol and this plan to the operator, then stop. Start execution only on the operator's explicit go.
- [ ] Read these from trunk at program start. Re-read them at every tick. Cite only paths that exist on `origin/main`.
  - [ ] `git show origin/main:AGENTS.md`
  - [ ] `git show origin/main:docs/distribution.md`
  - [ ] `git show origin/main:HermedBots/App/AppModel.swift`
  - [ ] `git show origin/main:HermedBots/Transport/SSHConfig.swift`
  - [ ] `git show origin/main:HermedBots/Transport/SSHTunnel.swift`
  - [ ] `git show origin/main:Packages/HermesAdapter/Sources/AppSettings/SSHEndpoint.swift`
  - [ ] `git show origin/main:scripts/check-plan.mjs`
- [ ] On the operator's go, arm the audit tick as `/loop 1h` with the tick prompt below. Never leave the cadence to memory.
- [ ] Use this tick prompt, verbatim. "Re-read the execution playbook from trunk. Audit the operation against it and fix drift in this tick. Probe every active lane and judge progress by side effects only. Stand down a stuck lane and dispatch its replacement now. Then post a short status message to the operator in chat only when the audit found a tracked change that no earlier status message reported, such as a PR opened, a code-ready head, a round launched or closed, a verdict, a merge, a stuck agent and the action taken, a blocker added or cleared, or a decision only the operator can make. Name every such change and nothing else. Do not repeat a table, the merged list, or an unchanged blocker. If the audit found none, end the turn with no reply text. Either way, log this tick's row in your decision trail. The row names the items reported, or none."
- [ ] On the operator's hold or stand-down, send every owner a zero-writes order at once.

### Spawn owners

- [ ] Spawn one owner per PR with the full lifecycle the execution playbook names.
- [ ] Follow this dependency graph. Start dependent work only after its parent is code-ready. Stack SI-02 on the SI-01 branch because SI-02 reads the launch identity that SI-01 adds. Do not wait for a merge to `main`.
  - [ ] SI-01 is independent and first. It branches from `main`.
  - [ ] SI-02 after SI-01. Its PR targets the SI-01 branch until SI-01 lands, then retargets `main`.
- [ ] Hold the file boundaries. SI-01 touches only `HermedBots/App/AppModel.swift`, `HermedBots/Transport/SSHConfig.swift`, `HermedBots/Settings/ConnectionView.swift`, `HermedBotsTests/SSHConfigTests.swift`, `HermedBotsTests/AppModel*.swift` if a preview case already lives there, `Packages/HermesAdapter/Sources/AppSettings/**` only for a launch-identity helper that Linux can test, `Packages/HermesAdapter/Tests/AppSettingsTests/**`, `Packages/HermesAdapter/Package.swift` if a new file needs a target, `.cursor/skills/verify-hermed-bots/features/connection.md`, `docs/distribution.md`, and `docs/plans/ssh-identity-preview.md`. SI-02 touches only `Packages/HermesAdapter/Sources/AppSettings/**`, `Packages/HermesAdapter/Tests/AppSettingsTests/**`, `HermedBots/Transport/SSHTunnel.swift`, `HermedBots/Transport/SSHConfig.swift`, `HermedBots/App/AppModel.swift`, `HermedBots/Settings/ConnectionView.swift`, `HermedBots/Bots/BotListView.swift` only if the bots error line must drop a host, `HermedBotsTests/SSHTunnelTests.swift`, `HermedBotsTests/EphemeralSSHAgentTests.swift`, `HermedBotsTests/SSHConfigTests.swift`, `test/ephemeral-ssh-agent.test.js`, `.cursor/skills/verify-hermed-bots/features/connection.md`, and `docs/distribution.md`. No PR touches `.claude/`, `.codex/`, or `.mcp.json`.
- [ ] Hold the review gate. No PR in this program waits on an operator screenshot review.

### PR mechanics, for every PR

- [ ] Resolve the forge once. Default to `gh`; if `command -v origin` succeeds and Origin can resolve the repository, use `origin pr` for every PR operation. Record any fallback to `gh`. Never require `gt`.
- [ ] Open the PR ready, never draft, per **Opening a PR**. Use the run's built-in PR tool when it has one, else `origin pr create --status open --base <base-branch>` or `gh pr create --base <base-branch>` according to the resolved forge. A stack child targets its parent branch.
- [ ] Run the repo's lint and typecheck once before the PR-facing push. Push with hooks on.
- [ ] Run `/deslop` before each commit and `/no-comments` before review.
- [ ] Triage every Bugbot and security-reviewer comment per `../references/bugbot-triage.md`.
- [ ] Rebase onto current trunk before the code-ready report and babysit. Keep that merge base in fix rounds. Rebase again only at merge prep, on a `git merge-tree` conflict with trunk, on a CI failure that comes from a change on trunk, or when a known concurrent change to the same files lands.

### Verdict and merge, for every PR

- [ ] A full swarm runs once, at the code-ready head. Another full swarm runs only for new behavior, a redesign, or a large new diff. A rebase, a merge-conflict resolution, or a minor fix gets a single verifier at the new head, and a wording-only change gets none. This run does not launch that swarm and does not post `<!-- dev-lead-verifier -->`. An independent verifier outside this agent owns the marked comment. The root still audits unit, lint, and CI receipts in the merge-ready report.
- [ ] Judge every finding by the execution playbook's blocking rule. The verdict is clean when none blocks. A failure on trunk behavior in a lane marked `Regression lane against trunk.` is recorded against trunk and does not block the PR. A new head gets a fresh verdict, except for results that stay valid under the patch-id rule in `playbooks/shipping.md`.
- [ ] Stop at merge-ready. The repository owner squash-merges with `scripts/squash-merge.js` after a marked `PASS` or `PASS+NOTES` comment with `<!-- dev-lead-verifier -->` on the head SHA, `verdict-gate` green, all CI green, no conflict with `main`, and a non-draft PR. This agent never squash-merges, never force-pushes `main`, and never posts the marker.

### Boot recipe, for every live lane

Each live lane runs on its own cloud VM at the PR head. Drive through `npm test`, `npm run lint`, `swift test --package-path Packages/HermesAdapter --skip PerfTests`, and source reads. Do not launch the macOS app and do not run XCUITest.

- [ ] `git fetch origin <head-branch> && git checkout <head SHA>`.
- [ ] Confirm Node 26 is present. Then run `npm ci`.
- [ ] Deliver input only through `npm test`, `npm run lint`, and `swift test --package-path Packages/HermesAdapter --skip PerfTests`. The read-only diagnostics are `git diff origin/main --stat` and `rg` over the Swift files.
- [ ] Save every screenshot to `/tmp/swarm-<pr-id>/worker-<n>/<slug>.png` and return the paths with the report.

## Align identity preview with the launch agent (SI-01)

**Depends on.** None.

**Files.**

- [ ] Edit `HermedBots/App/AppModel.swift` so `refreshPreview` and the connect preview use the selected `authMode`.
- [ ] Edit `HermedBots/Transport/SSHConfig.swift` so parse can name the launch identity, not only the session dump.
- [ ] Edit `HermedBots/Settings/ConnectionView.swift` so a mode change refreshes the preview.
- [ ] Edit `HermedBots/Transport/SSHConfig.swift` `SSHConnector` so the connect path writes the same preview Connect will use.
- [ ] Create or edit `Packages/HermesAdapter/Sources/AppSettings/SSHIdentityPreview.swift` for the pure overlay Linux can test.
- [ ] Edit `Packages/HermesAdapter/Tests/AppSettingsTests/AppSettingsTests.swift` with overlay cases.
- [ ] Edit `HermedBotsTests/SSHConfigTests.swift` so an ephemeral mode dump no longer shows a session file identity.
- [ ] Edit `.cursor/skills/verify-hermed-bots/features/connection.md` and `docs/distribution.md` so the preview sentence matches launch.
- [ ] Create `docs/plans/ssh-identity-preview.md` as the committed copy of this plan.

**Build.**

- [ ] Keep `SSHConfig.parse` as the `ssh -G` reader. Add one overlay that takes `SSHAuthMode`. In `ephemeralAgent`, the shown kind is `agent` even when the session dump lists default identity files. In `sessionAgent`, keep today's parse. In `wrapper`, keep today's parse.
- [ ] Call `resolver.dump` without a private socket for the Settings preview. Do not start `ssh-agent` to draw Identite. Presence in ephemeral mode is true when a key command is set, or when the dump already names a non-none `identityagent` that is not only `SSH_AUTH_SOCK`.
- [ ] On Connect, keep writing `preview` from the overlay of the dump plus the mode that `openTunnel` receives. Do not replace it with a later session dump.
- [ ] Refresh the preview when `authMode` changes. Persist still writes no secret.
- [ ] Target macOS 27 and Swift 6. Add no fallback for older systems.

**You see.**

- [ ] With Mode SSH set to Agent temporaire, Identite reads `agent SSH` and does not read `fichier` from default identity files.
- [ ] With Mode SSH set to Agent de session, Identite still follows `identityagent` and identity files as today.
- [ ] Labels still hide paths, hosts, and keys.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `AppSettingsTests` gains a case that ephemeral mode overlays a session file dump to agent, a case that session mode keeps file, and a case that labels omit `/tmp`. Run `swift test --package-path Packages/HermesAdapter --filter AppSettingsTests`.
- [ ] `SSHConfigTests` gains a case that connector or parse overlay matches ephemeral launch. Run `npm test` and `npm run lint`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh-fast` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `swift test --package-path Packages/HermesAdapter --filter AppSettingsTests` at trunk and at head. Save `si01-regression.png`. Pass when trunk has no overlay case and head passes the three overlay cases.
- [ ] Lane 2. Read `AppModel.refreshPreview` and `ConnectionView` for `authMode`. Save `si01-refresh.png`. Pass when a mode change refreshes preview and preview parse receives the selected mode.
- [ ] Lane 3. Read the connect callback in `AppModel.connect`. Save `si01-connect.png`. Pass when the preview assigned there uses the same `authMode` as `SSHClientSettings`.
- [ ] Lane 4. Search user-facing preview strings for `BEGIN`, `PRIVATE`, and `/Users`. Save `si01-secrets.png`. Pass when none appear.
- [ ] Lane 5. Read `SSHIdentityPreview` or the overlay helper. Save `si01-overlay.png`. Pass when ephemeral plus default identity files yields agent.
- [ ] Lane 6. Run `npm test` and `npm run lint` at head. Save `si01-node.png`. Pass when both exit 0.
- [ ] Lane 7. Confirm `MACOSX_DEPLOYMENT_TARGET` is `27.0` and `SWIFT_VERSION` is `6.0`. Save `si01-toolchain.png`. Pass when both values hold and the diff adds no `#available` fallback.
- [ ] Lane 8. Run `node scripts/infra-guard-ci.js` on the diff. Save `si01-infra.png`. Pass when the scan exits 0 and the diff has no local paths, host names, or private IPs.
- [ ] Lane 9. Read `connection.md` for the preview sentence. Save `si01-docs.png`. Pass when it says the pane shows the agent Connect uses.
- [ ] Lane 10. Confirm issue 53 is closed by the PR body with `Closes #53`. Save `si01-issue.png`. Pass when that line exists and the PR is not a draft.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of 10_000 overlay calls of a session dump plus `ephemeralAgent`. Trunk lacks the helper, so this is an absolute budget on the diff-added work plus the wait for `AppSettingsTests` to print `passed`.
- [ ] Probe. At head, run `swift test --package-path Packages/HermesAdapter --filter AppSettingsTests` five times, timed by `/usr/bin/time`. At trunk, run the same filter once between head runs and record that the overlay case is absent.
- [ ] Baseline. Record the trunk absence first.
- [ ] Rule. Fail when the head median exceeds 2 s on the Linux CI runner.

**Review gate.** None. SI-01 is not review-gated.

**Merge.**

- [ ] Independent marked `PASS` or `PASS+NOTES` on the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The repository owner squash-merges SI-01. This agent does not merge.

## Default the temporary agent and name SSH failures (SI-02)

**Depends on.** SI-01.

**Files.**

- [ ] Edit `Packages/HermesAdapter/Sources/AppSettings/SSHEndpoint.swift` so a missing user choice is distinct from an explicit picker value.
- [ ] Create `Packages/HermesAdapter/Sources/AppSettings/SSHAuthModeChoice.swift` for the default rule.
- [ ] Create `Packages/HermesAdapter/Sources/AppSettings/SSHExitClassification.swift` for stderr plus exit status.
- [ ] Edit `Packages/HermesAdapter/Tests/AppSettingsTests/AppSettingsTests.swift` for default mode and the four failure cases.
- [ ] Edit `HermedBots/App/AppModel.swift` to apply the default when the dump names an external `identityagent` and the user has not chosen.
- [ ] Edit `HermedBots/Transport/SSHTunnel.swift` so `classify` takes status, maps the four cases, and stops treating a closed tunnel as unreachable.
- [ ] Edit `HermedBots/Transport/SSHTunnel.swift` `prepareIdentity` so ephemeral mode with an empty key command uses the resolved `identityagent` and does not start an empty private agent.
- [ ] Edit `HermedBotsTests/SSHTunnelTests.swift` and `HermedBotsTests/EphemeralSSHAgentTests.swift` for status-based classify and the empty key-command path.
- [ ] Edit `test/ephemeral-ssh-agent.test.js` if the Swift scan must allow the new symbols.
- [ ] Edit `.cursor/skills/verify-hermed-bots/features/connection.md` and `docs/distribution.md` for default mode and the four messages.

**Build.**

- [ ] Detect an external agent when `ssh -G` prints `identityagent` that is not `none` and not only `SSH_AUTH_SOCK`. No external agent when the line is missing or `none`.
- [ ] If the user has not chosen a mode, set `ephemeralAgent` when an external agent is present, else `sessionAgent`. An explicit picker value always wins. Persist the choice flag only from the picker `onChange`, not from Connect.
- [ ] In `ephemeralAgent` with a non-empty key command, keep the private `ssh-agent` and `ssh-add -` from issue 52. With an empty key command and a resolved external `identityagent`, pass that socket to ssh and skip `ssh-add`. Never write a private key. Never paste one.
- [ ] Add `SSHFailure.tunnelClosed` (or the same case under a package name mapped in the app). `retries` stays true only for a real unreachable host, not for auth, agent, or a server close.
- [ ] `classify(stderr:status:)` reads both. Host unreachable for connection refused, no route, and timeout. Auth refused for `Permission denied`. Agent missing or empty for the current agent strings. Tunnel closed for reset, closed by remote, and a missing watchdog after a start. Each public `message` is a fixed French line plus an action. Strip host, path, and key material. Drop `sshLine` as the user-visible string.
- [ ] Target macOS 27 and Swift 6. Add no fallback for older systems.

**You see.**

- [ ] An alias whose dump names an external IdentityAgent opens on Agent temporaire unless the user picked another mode.
- [ ] An alias with no IdentityAgent still opens on Agent de session.
- [ ] After a tunnel drop, the bots line names tunnel closed or auth or agent, not host unreachable, when stderr and status match those cases.
- [ ] No message contains a host, a path, or a key.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `AppSettingsTests` gains default-mode cases (external agent, none, explicit user choice) and one classify case per named failure, each with stderr and status. Run `swift test --package-path Packages/HermesAdapter --filter AppSettingsTests`.
- [ ] `SSHTunnelTests` asserts each public message omits host, path, and key, and that a closed tunnel does not retry as unreachable. Run `npm test` and `npm run lint`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh-fast` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `swift test --package-path Packages/HermesAdapter --filter AppSettingsTests` at trunk and at head. Save `si02-regression.png`. Pass when trunk lacks the default-mode cases and head passes them plus the four classify cases.
- [ ] Lane 2. Read `SSHAuthModeChoice` for the three default inputs. Save `si02-default.png`. Pass when external agent selects ephemeral, none selects session, and an explicit value is unchanged.
- [ ] Lane 3. Read `prepareIdentity` for an empty key command. Save `si02-attach.png`. Pass when that path uses the resolved IdentityAgent and does not call `ssh-add`.
- [ ] Lane 4. Read `SSHFailure.retries` and the closed-tunnel throws. Save `si02-retry.png`. Pass when auth, agent, and closed tunnel do not retry, and only unreachable does.
- [ ] Lane 5. Search every new `message` string for `@`, `/Users`, `BEGIN`, and `PRIVATE`. Save `si02-copy.png`. Pass when none hit.
- [ ] Lane 6. Run `npm test` and `npm run lint` at head. Save `si02-node.png`. Pass when both exit 0.
- [ ] Lane 7. Confirm `MACOSX_DEPLOYMENT_TARGET` is `27.0` and `SWIFT_VERSION` is `6.0`. Save `si02-toolchain.png`. Pass when both values hold and the diff adds no `#available` fallback.
- [ ] Lane 8. Run `node scripts/infra-guard-ci.js` on the diff. Save `si02-infra.png`. Pass when the scan exits 0.
- [ ] Lane 9. Read `connection.md` for the four user messages. Save `si02-docs.png`. Pass when each case has a named action and no secret.
- [ ] Lane 10. Confirm the PR body has `Closes #55` and states that it stacks on SI-01 when the base is not `main`. Save `si02-issue.png`. Pass when that is true and the PR is not a draft.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of 10_000 `classify` calls over the four fixture stderr blobs plus status 255. Trunk lacks the package classifier, so this is an absolute budget on the diff-added work plus the wait for `AppSettingsTests` to print `passed`.
- [ ] Probe. At head, run `swift test --package-path Packages/HermesAdapter --filter AppSettingsTests` five times, timed by `/usr/bin/time`. At trunk, run the same filter once between head runs and record that the classify cases are absent.
- [ ] Baseline. Record the trunk absence first.
- [ ] Rule. Fail when the head median exceeds 2 s on the Linux CI runner.

**Review gate.** None. SI-02 is not review-gated.

**Merge.**

- [ ] Independent marked `PASS` or `PASS+NOTES` on the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged. If SI-01 has landed, the base is `main`.
- [ ] The repository owner squash-merges SI-02. This agent does not merge.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] Reply to the operator with the report the execution playbook names.

## Appendix A. Prototype evidence

No prototype ran. Issue 53 names the session dump at `AppModel` connect. Issue 55 names the default mode, the preview link to 53, and four failure classes with tests on ssh stderr and status. The empty key-command path is the 0.1.6 note on issue 55. Unproven until a Mac test VM launches the app. Identite chrome and the bots error banner. That launch is forbidden on this cloud VM.

## Appendix B. Alternatives rejected

| Option | Why it lost |
| --- | --- |
| Keep preview on the session dump after Connect | Issue 53 exists because that dump is not the launch agent. |
| Default ephemeral for every alias | Issue 55 limits the default to a resolved external IdentityAgent. |
| Require a key command in ephemeral mode | The 0.1.6 note shows that path stops with a missing key while keys already live in the external agent. |
| Show the last ssh line as the user message | Issue 55 forbids host, path, and key in the copy. |
| `playbooks/autopilot-stack.md` as the named run | The operator asked for autopilot-full, then kept merge with the repository owner and forbade this agent from posting a verdict. |

## Appendix C. Risks

| Risk | PR | What the owner watches |
| --- | --- | --- |
| Overlay marks agent before a private agent exists | SI-01 | Presence must follow key command or a resolved IdentityAgent, not a missing socket. |
| Auto default overrides a saved session mode from 0.1.6 | SI-02 | Treat a missing choice flag as unset. Persist the flag only from the picker. |
| Attaching to IdentityAgent skips the private agent watchdog | SI-02 | Still refuse to launch ssh when the socket is missing. Name missing agent. |
| Linux cannot run `HermedBotsTests` | SI-01 and SI-02 | Keep the new rules in `AppSettings` so `swift test --package-path Packages/HermesAdapter` covers them. |
| The macOS app is not launched here | SI-01 and SI-02 | Live lanes use package tests, `npm test`, and source reads. |

## Appendix D. Links and reading list

- Read issue 53, issue 55, and GitHub PR 52 before editing.
- Read `HermedBots/App/AppModel.swift` preview and connect, `HermedBots/Transport/SSHConfig.swift` parse, and `SSHFailure.classify` in `HermedBots/Transport/SSHTunnel.swift`.
- Read `Packages/HermesAdapter/Sources/AppSettings/SSHEndpoint.swift` for persisted mode.
- Keep the trail in the agent store per `pstack/skills/show-me-your-work/SKILL.md`. SI-01 does not need `pstack/skills/how/SKILL.md`. SI-02 does, because attaching to an external IdentityAgent redesigns ephemeral prepare. Run `pstack/skills/interrogate/SKILL.md` only if two attach designs still compete after the first SI-02 draft.
