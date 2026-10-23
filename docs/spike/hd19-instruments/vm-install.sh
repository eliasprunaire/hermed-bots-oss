#!/bin/bash
# Installs the published cask in the throwaway VM, then reads Gatekeeper, the signature, the staple, the bundle versions and the launch
# Run from the repository root: zsh <vm-test-script> exec bash docs/spike/hd19-instruments/vm-install.sh 0.1.0
# The argument is the version the tap publishes: both bundle versions must equal it
# PLISTBUDDY and HV_APPDIR replace the system tool and /Applications in test/distribution/vm-install.test.js
set -euo pipefail
version=${1:-}
[ -n "$version" ] || { echo 'Usage: vm-install.sh <published version, for example 0.1.0>' >&2; exit 2; }
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
cask=eliasprunaire/tap/hermed-bots
# <vm-test-script> brings back only the directories created under evidence
out=${HV_WORK:-$HOME/hermed-bots-work}/evidence/hd19-$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"
{
  reachable=1
  curl -sS -m 10 -o /dev/null -w 'github.com: HTTP %{http_code}\n' https://github.com || { echo 'github.com: unreachable'; reachable=0; }
  # The VM blocks github.com: HV_MIRROR_URL (a loopback copy of the public release, set by <vm-test-script>) fills the Homebrew download cache
  # Homebrew still checks that archive against the SHA-256 written in the cask of the tap
  if [ "$reachable" = 0 ] && [ -n "${HV_MIRROR_URL:-}" ]; then
    cache=$(brew --cache --cask "$cask")
    mkdir -p "$(dirname "$cache")"
    curl -fsS -o "$cache" "$HV_MIRROR_URL/github.com/eliasprunaire/hermed-bots-releases/releases/download/v$version/HermedBots-$version.zip"
    echo 'archive: copied from the local mirror into the Homebrew cache'
  fi
  # The VM account is not an administrator: without write access to the applications directory, brew asks for a sudo password
  appdir=${HV_APPDIR:-/Applications}
  if [ ! -w "$appdir" ]; then appdir="$HOME/Applications"; mkdir -p "$appdir"; export HOMEBREW_CASK_OPTS="--appdir=$appdir"; fi
  brew install --cask "$cask" || { echo "brew install rc=$?"; exit 1; }
  app="$appdir/HermedBots.app"
  spctl -a -vv --type execute "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  # stapler asks Apple's servers, which the VM cannot reach: offline, the stapled ticket file (it starts with s8ch) is the only evidence
  staple=validated
  if ! xcrun stapler validate "$app"; then
    echo 'stapler: online validation failed, reading the stapled ticket file instead'
    [ "$(head -c 4 "$app/Contents/CodeResources")" = s8ch ]
    staple=ticket-file-only
  fi
  for key in CFBundleShortVersionString CFBundleVersion; do
    found=$("${PLISTBUDDY:-/usr/libexec/PlistBuddy}" -c "Print :$key" "$app/Contents/Info.plist")
    echo "$key: $found"
    [ "$found" = "$version" ] || { echo "$key is $found, expected $version"; exit 1; }
  done
  binary="$app/Contents/MacOS/HermedBots"
  open -n -g -j "$app"
  started=0
  for _ in $(seq 1 20); do
    if pgrep -f "$binary" > /dev/null; then started=1; break; fi
    sleep 1
  done
  # A crash on launch shows within a few seconds
  if [ "$started" = 1 ]; then sleep 5; pgrep -f "$binary" > /dev/null || started=0; fi
  pkill -TERM -f "$binary" || true
  [ "$started" = 1 ] || { echo 'launch: the app did not stay running'; exit 1; }
  echo "HOMEBREW-PROOF version=$version install=pass gatekeeper=pass signature=pass staple=$staple versions=pass launch=pass"
} 2>&1 | tee "$out/install.txt"
