# Tabbed Settings window plan

The macOS app still keeps connection fields and the on-demand update action on the main window and in the connection sheet. This program moves those controls into the system Settings window, with one tab per group. The stored SSH endpoint survives a quit. The user never sees loopback ports, feed URLs, or other plumbing. macOS 27 and Swift 6 only.
The program enforces one rule. Settings live in `Settings`, not in the main split view.
ST-01 is the only PR.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a screenshot, a test run, or a SHA. The body is a how-to. The appendices explain and record.

The program runs `pstack/skills/poteto-mode/playbooks/autopilot-full.md`. The owner squash-merges ST-01 after an independent marked verdict. The root never posts that verdict. The operator already named the tabbed Settings window and the move of `Rechercher les mises à jour…`, so ST-01 is not an operator screenshot review item.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

## Program checklist

### Arm the program

- [ ] State the protocol and this plan to the operator, then stop. Start execution only on the operator's explicit go.
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

- [ ] Spawn one owner per PR with the full lifecycle the execution playbook names.
- [ ] Follow this dependency graph. Start dependent work only after its parent merges, or base it on the parent branch when the execution playbook stacks.
  - [ ] ST-01 is independent and first. It branches from `main`.
- [ ] Hold the file boundaries. ST-01 touches only `Packages/HermesAdapter/Sources/AppSettings/**`, `Packages/HermesAdapter/Tests/AppSettingsTests/**`, `Packages/HermesAdapter/Package.swift`, `HermedBots/App/**`, `HermedBots/Settings/**`, `HermedBots/Shared/AccessibilityID.swift`, `HermedBotsTests/**`, `HermedBotsUITests/**`, `HermedBots.xcodeproj/**`, `docs/distribution.md`, and `docs/plans/settings-window.md`. No PR touches `.claude/`, `.codex/`, or `.mcp.json`.
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
- [ ] The owner squash-merges ST-01 with `scripts/squash-merge.js` after a marked `PASS` or `PASS+NOTES` comment with `<!-- dev-lead-verifier -->` on the head SHA, `verdict-gate` green, all CI green, no conflict with `main`, and a non-draft PR. The owner never launches the verifier and never posts the marker.

### Boot recipe, for every live lane

Each live lane runs on its own cloud VM at the PR head. Drive through `control-cli`. Do not launch the macOS app and do not run XCUITest.

- [ ] `git fetch origin <head-branch> && git checkout <head SHA>`.
- [ ] Install Node 22 with `npm ci`.
- [ ] Deliver input only through `npm test`, `npm run lint`, and `swift test --package-path Packages/HermesAdapter`. The read-only diagnostics are `git diff origin/main --stat` and `rg` over the Swift files.
- [ ] Save every screenshot to `/tmp/swarm-st-01/worker-<n>/<slug>.png` and return the paths with the report.

## Move app settings into a tabbed Settings window (ST-01)

**Depends on.** None.

**Files.**

- [ ] Create `Packages/HermesAdapter/Sources/AppSettings/SettingsPane.swift`.
- [ ] Create `Packages/HermesAdapter/Sources/AppSettings/SSHEndpoint.swift`.
- [ ] Create `Packages/HermesAdapter/Tests/AppSettingsTests/AppSettingsTests.swift`.
- [ ] Edit `Packages/HermesAdapter/Package.swift` to add the `AppSettings` library and its tests.
- [ ] Edit `HermedBots/App/AppEnvironment.swift` so it uses the package `SSHEndpoint` and keeps a `UserDefaults` store.
- [ ] Edit `HermedBots/App/HermedBotsApp.swift` to add a `Settings` scene, drop the connection sheet, and keep the app-menu update command.
- [ ] Edit `HermedBots/Settings/ConnectionView.swift` so it is the Connexion pane and no longer hosts the update button.
- [ ] Create `HermedBots/Settings/UpdatesSettingsView.swift` for the update action.
- [ ] Create `HermedBots/Settings/SettingsWindow.swift` that builds one `Tab` per `SettingsPane`.
- [ ] Edit `HermedBots/Shared/AccessibilityID.swift` to add settings tab ids.
- [ ] Edit `HermedBotsTests/AppEnvironmentTests.swift` and `HermedBotsTests/AccessibilityIDTests.swift` for the moved types.
- [ ] Edit `HermedBotsUITests/TunnelTests.swift` and `HermedBotsUITests/ProfileKeys.swift` so they open Settings instead of the sheet.
- [ ] Edit `HermedBots.xcodeproj/project.pbxproj` so the app and the unit-test target link `AppSettings`.
- [ ] Edit `docs/distribution.md` so the connection steps name Settings.
- [ ] Create `docs/plans/settings-window.md`.

**Build.**

- [ ] Encode panes as `SettingsPane` cases `connection` and `updates`. Titles are `Connexion` and `Mises à jour`. The view iterates `allCases`.
- [ ] Move `SSHEndpoint` into `AppSettings` with the same `ssh.host` key and no user or port key. The SSH alias gives the user, the port, and the identity. A later `stored(in:)` reads what `save(to:)` wrote.
- [ ] Persist a non-empty host from the Connexion pane without waiting for Connect. Test mode still skips user defaults.
- [ ] Add `Settings { SettingsWindow(model:) }`. Replace the sidebar sheet button with `SettingsLink`. Remove `.sheet` for connection.
- [ ] Put `Rechercher les mises à jour…` on the updates pane. Keep the app-menu command. Remove that button from `ConnectionView`.
- [ ] Show tunnel state as closed, opening, open, reopening, or failed. Do not print a loopback bind. Do not print Sparkle internals.
- [ ] Target macOS 27 and Swift 6. Add no fallback for older systems.

**You see.**

- [ ] The main window has bots, chat, and the kill switch. It has no connection form and no update button.
- [ ] Settings has two tabs. Connexion keeps the SSH alias and Connect, with no user field, no port field, and no API key fields (removed). Mises a jour runs the update action.
- [ ] A later launch fills the SSH alias from the last saved endpoint.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `AppSettingsTests` gains a case that `SettingsPane.allCases` is Connexion then Mises a jour, a case that save then stored returns the same endpoint, and a case that the updates copy starts one `UpdateCheck` driver session. Run `swift test --package-path Packages/HermesAdapter --filter AppSettingsTests`.
- [ ] Run `npm test` and `npm run lint`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh-fast` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `swift test --package-path Packages/HermesAdapter --filter AppSettingsTests` at trunk and at head. Save `st01-regression.png`. Pass when trunk reports a missing filter and head passes the three cases above.
- [ ] Lane 2. Read `HermedBots/Settings/SettingsWindow.swift` for `SettingsPane.allCases`. Save `st01-tabs.png`. Pass when the window builds one `Tab` per case and the titles are `Connexion` and `Mises à jour`.
- [ ] Lane 3. Read `HermedBots/App/HermedBotsApp.swift` for `Settings`. Save `st01-scene.png`. Pass when a `Settings` scene hosts `SettingsWindow` and `ContentView` has no connection `.sheet`.
- [ ] Lane 4. Read `HermedBots/Settings/UpdatesSettingsView.swift` and `ConnectionView.swift`. Save `st01-updates.png`. Pass when the updates pane uses `SettingsCopy.checkForUpdates` and `ConnectionView` does not.
- [ ] Lane 5. Search new UI strings for Sparkle, `SUFeedURL`, `appcast`, and loopback binds. Save `st01-copy.png`. Pass when none of those strings appear in user-facing text.
- [ ] Lane 6. Save an endpoint, construct a new store, and read `stored(in:)`. Save `st01-persist.png`. Pass when the host matches.
- [ ] Lane 7. Run `UpdatesSettingsAction.perform` twice on a fake driver before `noteSessionEnded()`. Save `st01-once.png`. Pass when the driver records one start.
- [ ] Lane 8. Run `npm test` and `npm run lint` at head. Save `st01-node.png`. Pass when both exit 0.
- [ ] Lane 9. Confirm `MACOSX_DEPLOYMENT_TARGET` is `27.0` and `SWIFT_VERSION` is `6.0`. Save `st01-toolchain.png`. Pass when both values hold and the diff adds no `#available` fallback.
- [ ] Lane 10. Run `node scripts/infra-guard-ci.js` on the diff. Save `st01-infra.png`. Pass when the scan exits 0 and the diff has no local paths, host names, or private IPs.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of 10_000 `stored(in:)` reads after one save. Trunk lacks `AppSettings`, so this is an absolute budget on the diff-added work plus the wait for the test process to print `passed`.
- [ ] Probe. At head, run `swift test --package-path Packages/HermesAdapter --filter AppSettingsTests` five times, timed by `/usr/bin/time`. At trunk, run the same filter once between head runs and record that the test target is absent.
- [ ] Baseline. Record the trunk absence first.
- [ ] Rule. Fail when the head median exceeds 2 s on the Linux CI runner.

**Review gate.** None. ST-01 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] Reply to the operator with the report the execution playbook names.

## Appendix A. Prototype evidence

No prototype ran. SU-01 parked tabbed settings as the next PR and already proved `UpdateCheck`. Persistence keys already exist on `SSHEndpoint` in `AppEnvironment.swift`. The Settings scene is the macOS 27 control for this window.
Unproven until the Mac test VM runs the app. The real Settings window chrome. That launch is forbidden on this cloud VM.

## Appendix B. Alternatives rejected

| Option | Why it lost |
| --- | --- |
| Keep the sheet and add tabs inside it | The operator asked for the system Settings window. |
| A third tab for Hermes version | Version stays a status in the sidebar, not a setting. |
| Drop the app-menu update command | SU-01 named that command. This PR only moves the sheet button. |
| `playbooks/autopilot-stack.md` | There is one PR, and the owner has merge authority after the independent verdict. |

## Appendix C. Risks

| Risk | PR | What the owner watches |
| --- | --- | --- |
| XCUITest still clicks `hd.connection.open` on a sheet | ST-01 | Point that id at `SettingsLink` or update the two UI tests that open Connexion. |
| Saving on every keystroke writes empty hosts | ST-01 | Persist only a non-empty host, and skip test mode. |
| Linux cannot import SwiftUI | ST-01 | Keep `AppSettings` free of SwiftUI in the package. |
| The macOS app is not launched here | ST-01 | Live lanes use `swift test`, `npm test`, and source reads. The Mac test VM is the only place that may launch the app. |

## Appendix D. Links and reading list

- Read `docs/plans/on-demand-sparkle.md` and `HermedBots/Settings/ConnectionView.swift` before editing.
- Read `Packages/HermesAdapter/Sources/UpdateCheck/UpdateCheck.swift` for the injected driver.
- Keep the trail per `pstack/skills/show-me-your-work/SKILL.md`.
