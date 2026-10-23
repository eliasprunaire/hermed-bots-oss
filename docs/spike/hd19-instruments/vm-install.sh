#!/bin/bash
# Installs the published cask in the throwaway VM, then reads Gatekeeper, the signature and the bundle versions
# Run from the repository root: zsh <vm-test-script> exec bash docs/spike/hd19-instruments/vm-install.sh
# PLISTBUDDY replaces the system tool in test/distribution/vm-install.test.js
set -euo pipefail
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
# The VM blocks github.com: <vm-test-script> serves the public release bytes from a local mirror on the loopback
if [ -n "${HV_MIRROR_URL:-}" ]; then export HOMEBREW_ARTIFACT_DOMAIN=$HV_MIRROR_URL HOMEBREW_ARTIFACT_DOMAIN_NO_FALLBACK=1; fi
# <vm-test-script> brings back only the directories created under evidence
out=${HV_WORK:-$HOME/hermed-bots-work}/evidence/hd19-$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"
{
  curl -sS -m 10 -o /dev/null -w 'github.com: HTTP %{http_code}\n' https://github.com || echo 'github.com: unreachable'
  brew install --cask eliasprunaire/tap/hermed-bots || { echo "brew install rc=$?"; exit 1; }
  app=/Applications/HermedBots.app
  spctl -a -vv --type execute "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  xcrun stapler validate "$app"
  for key in CFBundleShortVersionString CFBundleVersion; do "${PLISTBUDDY:-/usr/libexec/PlistBuddy}" -c "Print :$key" "$app/Contents/Info.plist"; done
} 2>&1 | tee "$out/install.txt"
