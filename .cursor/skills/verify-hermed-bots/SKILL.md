---
name: verify-hermed-bots
description: Mandatory live checks for HermedBots, including Sparkle updates. Use after an app change, a distribution change, or any update install.
---

# Verify HermedBots

Run these checks on the installed app, not only on unit tests. Feature maps live in `features/`.

## Mandatory after every Sparkle update

An update must replace the previous HermedBots bundle. It must not leave a second copy on disk.

After the installer finishes and the app has relaunched:

1. Count bundles whose `CFBundleIdentifier` is `com.hermedbots.HermedBots`.
2. Combine Spotlight (`mdfind "kMDItemCFBundleIdentifier == 'com.hermedbots.HermedBots'"`) with `path:` rows from `lsregister -dump` whose identifier matches.
3. Drop paths that no longer exist, and paths still under the current pass build folder (`SPARKLE_PROOF_BUILD_DIR`).
4. Require exactly one remaining copy, at the target version.

Evidence is `scripts/sparkle-update-proof.sh`. The proof is a failure (nonzero) unless the `SPARKLE-PROOF*` line contains `single-copy pass`. `single-copy fail` is a failed verification.

See `features/sparkle-update.md`.
