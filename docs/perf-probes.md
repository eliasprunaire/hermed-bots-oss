# Run performance probes apart from a pull request

The pull request pass keeps functional tests only. The `CI` Swift job uses `--skip PerfTests`. The `HermedBots` scheme skips the XCUITest probe classes and the budget methods listed there.

Run the probes on their own after merge, on a schedule, or by hand. Use the `HermedBotsPerf` scheme for XCUITest. That scheme does not skip those classes, so `-only-testing` can still start them.

## Swift package probes

These two classes live in `Packages/HermesAdapter`. They decode a 10 000 event stream and time `LoopGuard.evaluate`.

The dedicated workflow `Perf probes` runs them on `main`, on a weekly schedule, and on `workflow_dispatch`. GitHub only lists that workflow after it exists on `main`.

To run the same filter locally:

```
swift test --package-path Packages/HermesAdapter --filter PerfTests
```

To run the pull request filter locally:

```
swift test --package-path Packages/HermesAdapter --skip PerfTests
```

## XCUITest probes

The `HermedBots` scheme skips `ApprovalPerfProbe`, `BannerPerfProbe`, `BotsPerfProbe`, `ColdLaunchProbe`, `ConversationPerfProbe`, and `ModelPerfProbe`. It also skips `ConcurrencyTests/testPerfFiveHolds`, `ConcurrencyTests/testPerfOneHold`, `KillSwitchTests/testPerfFiveStops`, `LaunchTests/testColdLaunchToVersionVisibleStaysUnderTwoSeconds`, and `ResumeLanes/testResumeBudget`.

Select one class on the scheme that does not skip them. Example:

```
xcodebuild test -scheme HermedBotsPerf -destination 'platform=macOS' -only-testing:HermedBotsUITests/ColdLaunchProbe
```

Repeat with each skipped class. Existing spike scripts under `docs/spike/` already wrap those classes (`hd07-instruments/perf.sh`, `hd08-instruments/perf.sh`, and the `run-ui.sh` files that take a probe class as an argument).
