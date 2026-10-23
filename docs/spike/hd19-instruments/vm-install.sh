#!/bin/bash
# Installs the published cask in the throwaway VM, then reads Gatekeeper and the bundle versions
# Run from the repository root: zsh <vm-test-script> exec bash docs/spike/hd19-instruments/vm-install.sh
# PLISTBUDDY replaces the system tool in test/distribution/vm-install.test.js
set -euo pipefail
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
curl -sS -m 10 -o /dev/null -w 'github.com: HTTP %{http_code}\n' https://github.com || echo 'github.com: unreachable'
brew install --cask eliasprunaire/tap/hermed-bots || { echo "brew install rc=$?"; exit 1; }
app=/Applications/HermedBots.app
spctl -a -vv --type execute "$app"
xcrun stapler validate "$app"
for key in CFBundleShortVersionString CFBundleVersion; do "${PLISTBUDDY:-/usr/libexec/PlistBuddy}" -c "Print :$key" "$app/Contents/Info.plist"; done
