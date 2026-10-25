# Feature: Sparkle update

## Behavior

A Sparkle update replaces the installed HermedBots app. After install and relaunch there is one bundle for `com.hermedbots.HermedBots`, at the version the update targeted.

## Mandatory verification

After every update, before the proof or the verifier may pass:

| Check | Pass when |
| --- | --- |
| Copy count | Combined Spotlight + Launch Services list, minus missing paths and the current build folder, has length 1 |
| Version | That copy's `CFBundleShortVersionString` equals the target version |
| Proof line | `SPARKLE-PROOF` or `SPARKLE-PROOF-PUBLISHED` contains `single-copy pass` |

Fail when the count is not 1, when the only copy is the wrong version, or when the line contains `single-copy fail`.

Discovery:

- `mdfind "kMDItemCFBundleIdentifier == 'com.hermedbots.HermedBots'"`
- `lsregister -dump` rows `path:` whose identifier is `com.hermedbots.HermedBots`
- Exclude `SPARKLE_PROOF_BUILD_DIR`
- Ignore paths that are gone from disk

Printed copy paths must be relative or redacted (`~` for the home prefix). The mechanism is `count_hermedbots_copies` in `scripts/sparkle-update-proof.sh`.
