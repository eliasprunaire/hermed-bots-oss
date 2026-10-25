---
name: verify-hermed-bots
description: Mandatory live checks for HermedBots, including Sparkle updates. Use after an app change, a distribution change, or any update install.
---

# Verify HermedBots

Run these checks on the installed app, not only on unit tests. Feature maps live in `features/`.

## Mandatory after every Sparkle update

An update must replace the previous HermedBots bundle. It must not leave a second copy on disk.

After the installer finishes and the app has relaunched:

1. Count bundles whose `CFBundleIdentifier` is the identifier of the app under test: `com.hermedbots.HermedBots.updateproof` in the local `run` mode, the identifier read from the installed app in the `published` mode (`com.hermedbots.HermedBots`).
2. Combine Spotlight (`mdfind "kMDItemCFBundleIdentifier == '<identifier>'"`) with `path:` rows from `lsregister -dump` whose identifier matches.
3. Drop paths that no longer exist, and paths under the source and build folders of the pass (`SPARKLE_PROOF_BUILD_DIR`, colon separated): `dd`, `v<N>` and `v<N+1>` in the `run` mode, the extracted previous release in the `published` mode.
4. Require exactly one remaining copy, at the target version.
5. Fail when `mdfind` or `lsregister` is missing or exits nonzero. The line then holds `single-copy discovery-failed source=<tool>`.

Evidence is `scripts/sparkle-update-proof.sh`. The proof is a failure (nonzero) unless the `SPARKLE-PROOF*` line contains `single-copy pass`. `single-copy fail` is a failed verification.

See `features/sparkle-update.md`.
