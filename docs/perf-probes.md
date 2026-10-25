# Run performance probes apart from a pull request

The pull request pass keeps functional tests only. It skips Swift classes whose names contain `PerfTests` and it skips the XCUITest probe classes listed in the `HermedBots` scheme.

Run the probes on their own after merge, on a schedule, or by hand.

## Swift package probes

These two classes live in `Packages/HermesAdapter`. They decode a 10 000 event stream and time `LoopGuard.evaluate`.

The dedicated workflow `Perf probes` runs them on `main`, every Monday, and on `workflow_dispatch`.

To run the same filter locally:

```
swift test --package-path Packages/HermesAdapter --filter PerfTests
```

To run the pull request filter locally:

```
swift test --package-path Packages/HermesAdapter --skip PerfTests
```

## XCUITest probes

The shared scheme skips `ApprovalPerfProbe`, `BannerPerfProbe`, `BotsPerfProbe`, `ColdLaunchProbe`, `ConversationPerfProbe`, and `ModelPerfProbe`. It also skips `ConcurrencyTests/testPerfFiveHolds`, `ConcurrencyTests/testPerfOneHold`, and `KillSwitchTests/testPerfFiveStops`.

Select one class with `-only-testing`. Example:

```
xcodebuild test -scheme HermedBots -destination 'platform=macOS' -only-testing:HermedBotsUITests/ColdLaunchProbe
```

Repeat with each skipped class. Existing spike scripts under `docs/spike/` already wrap those classes (`hd07-instruments/perf.sh`, `hd08-instruments/perf.sh`, and the `run-ui.sh` files that take a probe class as an argument).
