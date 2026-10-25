# Feature: Sparkle update

## Behavior

A Sparkle update replaces the installed HermedBots app. After install and relaunch there is one bundle for the identifier of the app under test, at the version the update targeted. The identifier is `com.hermedbots.HermedBots.updateproof` for the local proof builds and `com.hermedbots.HermedBots` for the published release.

## Mandatory verification

After every update, before the proof or the verifier may pass:

| Check | Pass when |
| --- | --- |
| Copy count | Combined Spotlight + Launch Services list, minus missing paths and the source and build folders of the pass, has length 1 |
| Version | That copy's `CFBundleShortVersionString` equals the target version |
| Proof line | `SPARKLE-PROOF` or `SPARKLE-PROOF-PUBLISHED` contains `single-copy pass` |

Fail when the count is not 1, when the only copy is the wrong version, when a discovery tool fails, or when the line contains `single-copy fail`.

Discovery:

- `mdfind "kMDItemCFBundleIdentifier == '<identifier>'"`
- `lsregister -dump` rows `path:` whose identifier is `<identifier>`
- Exclude the folders of `SPARKLE_PROOF_BUILD_DIR` (colon separated): `dd`, `v<N>`, `v<N+1>` in the `run` mode, the extracted previous release in the `published` mode
- Ignore paths that are gone from disk
- A missing tool or a nonzero exit of `mdfind` or `lsregister` fails the check (`single-copy discovery-failed source=<tool>`), because the list would be incomplete
- Another identifier is never counted: an independent production install does not hide a second proof copy, and does not count as one

Printed copy paths must be relative or redacted (`~` for the home prefix). The mechanism is `count_hermedbots_copies` in `scripts/sparkle-update-proof.sh`.
