# On-demand Sparkle check plan

The macOS app already starts Sparkle in Release and checks the feed on its own cycle. This program gives the user the moment of the check. One command in the app menu and one button in the existing connection sheet both start a Sparkle check. The controls disable while a check is running. The sheet stays a single form. Tabbed settings stay out of this PR. The user never sees Sparkle internals, the feed URL, or other plumbing. macOS 27 and Swift 6 only.
The program enforces one rule. Automatic Sparkle checks and silent installs are off. A check starts only from those two controls.
SU-01 is the only PR.

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a screenshot, a test run, or a SHA. The body is a how-to. The appendices explain and record.

The program runs `pstack/skills/poteto-mode/playbooks/autopilot-full.md`. The owner squash-merges SU-01 after an independent marked verdict. The root never posts that verdict. The operator already named the menu copy and the sheet placement, so SU-01 is not an operator screenshot review item.

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
  - [ ] SU-01 is independent and first. It branches from `main`.
- [ ] Hold the file boundaries. SU-01 touches only `Packages/HermesAdapter/Sources/UpdateCheck/**`, `Packages/HermesAdapter/Tests/UpdateCheckTests/**`, `Packages/HermesAdapter/Package.swift`, `HermedBots/App/**`, `HermedBots/Settings/ConnectionView.swift`, `HermedBots/Shared/AccessibilityID.swift`, `HermedBots.xcodeproj/**`, `Config/Info.plist`, `test/distribution/sparkle-update.test.js`, `docs/distribution.md`, `docs/plans/on-demand-sparkle.md`, and `.github/workflows/ci.yml` only if the existing `swift test --package-path Packages/HermesAdapter` job needs a flag. No PR touches `.claude/`, `.codex/`, or `.mcp.json`.
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
- [ ] The owner squash-merges SU-01 with `scripts/squash-merge.js` after a marked `PASS` or `PASS+NOTES` comment with `<!-- dev-lead-verifier -->` on the head SHA, `verdict-gate` green, all CI green, no conflict with `main`, and a non-draft PR. The owner never launches the verifier and never posts the marker.

### Boot recipe, for every live lane

Each live lane runs on its own cloud VM at the PR head. Drive through `control-cli`. Do not launch the macOS app and do not run XCUITest.

- [ ] `git fetch origin <head-branch> && git checkout <head SHA>`.
- [ ] Install Node 22 with `npm ci`.
- [ ] Deliver input only through `npm test`, `npm run lint`, and `swift test --package-path Packages/HermesAdapter`. The read-only diagnostics are `git diff origin/main --stat` and `rg` over the Swift and plist files.
- [ ] Save every screenshot to `/tmp/swarm-su-01/worker-<n>/<slug>.png` and return the paths with the report.

## Add an on-demand Sparkle check (SU-01)

**Depends on.** None.

**Files.**

- [ ] Create `Packages/HermesAdapter/Sources/UpdateCheck/UpdateCheck.swift`.
- [ ] Create `Packages/HermesAdapter/Tests/UpdateCheckTests/UpdateCheckTests.swift`.
- [ ] Edit `Packages/HermesAdapter/Package.swift` to add the `UpdateCheck` library and its tests.
- [ ] Create `HermedBots/Updates/SparkleUpdateDriver.swift`.
- [ ] Edit `HermedBots/App/HermedBotsApp.swift` to own `UpdateCheck`, add the app-menu command, and start Sparkle only in Release.
- [ ] Edit `HermedBots/Settings/ConnectionView.swift` to add the same action on the existing form.
- [ ] Edit `HermedBots/Shared/AccessibilityID.swift` to add `hd.updates.check`.
- [ ] Edit `HermedBots.xcodeproj/project.pbxproj` so the app and the unit-test target link `UpdateCheck`.
- [ ] Edit `Config/Info.plist` to turn off automatic checks and silent installs.
- [ ] Edit `test/distribution/sparkle-update.test.js` so those keys must be false.
- [ ] Edit `docs/distribution.md` so the published docs match the new check policy.
- [ ] Create `docs/plans/on-demand-sparkle.md`.

**Build.**

- [ ] Encode the check as `UpdateCheck` plus `UpdateDriver`. `checkForUpdates()` calls the driver once when a check can start, then sets `isChecking`. A second call is a no-op until `noteSessionEnded()`.
- [ ] Keep Sparkle behind `SparkleUpdateDriver` in the app. Debug builds keep the controls and use a driver that records calls without starting Sparkle.
- [ ] Add `CommandGroup(after: .appInfo)` with the label `Rechercher les mises à jour…`. Disable it while `isChecking` is true.
- [ ] Add a button with the same label on `ConnectionView`. Do not add tabs. Do not print the feed URL, the public key, Sparkle's name, or other internals.
- [ ] Set `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` to false. Keep signed-feed verification on.
- [ ] Target macOS 27 and Swift 6. Add no fallback for older systems.

**You see.**

- [ ] The app menu and the connection sheet both offer `Rechercher les mises à jour…`.
- [ ] A check in progress greys both controls. The sheet still has one form and no technical caption.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] `UpdateCheckTests` gains a case that a ready action starts one driver check, a case that a second action during `isChecking` starts none, and a case that `canCheck` is false during the session. Run `swift test --package-path Packages/HermesAdapter --filter UpdateCheckTests`.
- [ ] `test/distribution/sparkle-update.test.js` requires automatic checks and silent installs to be false. Run `npm test` and `npm run lint`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `grok-4.7-xhigh-fast` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `npm test -- test/distribution/sparkle-update.test.js` at trunk and at head. Save `su01-plist.png`. Pass when trunk still requires `SUEnableAutomaticChecks` true and head requires it false, and signed-feed keys stay true on both.
- [ ] Lane 2. Run `swift test --package-path Packages/HermesAdapter --filter UpdateCheckTests`. Save `su01-unit.png`. Pass when the three cases above pass.
- [ ] Lane 3. Read `HermedBots/App/HermedBotsApp.swift` for the app-menu command. Save `su01-menu.png`. Pass when the command label is `Rechercher les mises à jour…` and the action calls `UpdateCheck.checkForUpdates()`.
- [ ] Lane 4. Read `HermedBots/Settings/ConnectionView.swift`. Save `su01-sheet.png`. Pass when the same label and action exist on the existing form and no `TabView` is added.
- [ ] Lane 5. Search the new UI strings for Sparkle, `SUFeedURL`, `appcast`, and the public key. Save `su01-copy.png`. Pass when none of those strings appear in user-facing text.
- [ ] Lane 6. Read the Debug Sparkle start path. Save `su01-debug.png`. Pass when `SPUStandardUpdaterController(startingUpdater: true` remains inside `#if !DEBUG`.
- [ ] Lane 7. Run a double `checkForUpdates()` on a fake driver before `noteSessionEnded()`. Save `su01-once.png`. Pass when the driver records one start.
- [ ] Lane 8. Run `checkForUpdates()` while the driver reports not ready. Save `su01-not-ready.png`. Pass when the driver records zero starts and `canCheck` is false.
- [ ] Lane 9. Run `npm test` and `npm run lint` at head. Save `su01-node.png`. Pass when both exit 0.
- [ ] Lane 10. Run `node scripts/infra-guard-ci.js` on the diff. Save `su01-infra.png`. Pass when the scan exits 0 and the diff has no local paths, host names, or private IPs.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Wall time of 10_000 `checkForUpdates()` calls against a fake driver that is already checking. Trunk lacks `UpdateCheck`, so this is an absolute budget on the diff-added work plus the wait for the test process to print `passed`.
- [ ] Probe. At head, run `swift test --package-path Packages/HermesAdapter --filter UpdateCheckTests` five times, timed by `/usr/bin/time`. At trunk, run the same filter once between head runs and record that the test target is absent.
- [ ] Baseline. Record the trunk absence first.
- [ ] Rule. Fail when the head median exceeds 2 s on the Linux CI runner.

**Review gate.** None. SU-01 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner squash-merges its own PR.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] Reply to the operator with the report the execution playbook names.

## Appendix A. Prototype evidence

No prototype ran. The driver protocol is the same shape as `KillSwitch`'s injected `cancel` collaborator, which already has passing tests in `HermedBotsTests/KillSwitchMessageTests.swift`. Sparkle's current start site is `HermedBotsApp.swift` under `#if !DEBUG`. Automatic checks are on in `Config/Info.plist`.
Unproven until SU-01's Mac test VM runs the app. The Sparkle dialog after a real feed check. That launch is forbidden on this cloud VM.

## Appendix B. Alternatives rejected

| Option | Why it lost |
| --- | --- |
| Call `SPUStandardUpdaterController` from the views | The behavior tests would need Sparkle and an app launch. |
| Keep automatic checks and only add a menu item | The user asked to choose the moment of the check. |
| Tabbed settings in this PR | The operator parked that work as the next PR. |
| `playbooks/autopilot-stack.md` | There is one PR, and the owner has merge authority after the independent verdict. |

## Appendix C. Risks

| Risk | PR | What the owner watches |
| --- | --- | --- |
| Observation does not refresh the menu from a nested object | SU-01 | Keep `isChecking` on an `@Observable` type the scene already reads, or bump a field on `AppModel`. |
| A Debug menu click starts Sparkle during XCUITest | SU-01 | Keep `startingUpdater: true` in Release only. |
| Linux cannot import Observation | SU-01 | Keep `UpdateCheck` free of Observation in the package. |
| The macOS app is not launched here | SU-01 | Live lanes use `swift test`, `npm test`, and source reads. The Mac test VM is the only place that may launch the app. |

## Appendix D. Links and reading list

- Read `docs/distribution.md` and `Config/Info.plist` before editing.
- Read `HermedBots/KillSwitch/KillSwitch.swift` for the injected-collaborator pattern.
- Keep the trail per `pstack/skills/show-me-your-work/SKILL.md`.
