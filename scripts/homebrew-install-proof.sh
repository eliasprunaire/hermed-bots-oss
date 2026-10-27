#!/bin/bash
# Proves brew install --cask of HermedBots from the project tap on a fresh macOS test machine.
# No production secret is read. Nothing is published.
#   bash scripts/homebrew-install-proof.sh dry-run   checks brew and the published cask; installs nothing
#   bash scripts/homebrew-install-proof.sh           also installs, checks version, codesign, and Gatekeeper, launches, quits, uninstalls
# Optional environment: HOMEBREW_PROOF_VERSION (expected short version; default is the version the tap publishes),
# HOMEBREW_PROOF_APPDIR (applications folder that brew used; default /Applications)
set -euo pipefail
set +x

cask=eliasprunaire/tap/hermed-bots
token=hermed-bots
app_name=HermedBots.app
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1

mode=${1:-run}
case "$mode" in dry-run|run) ;; *) echo 'Usage: homebrew-install-proof.sh [dry-run|run]' >&2; exit 2 ;; esac
if [ "$(uname -s)" != Darwin ]; then
  echo 'The Homebrew install proof needs macOS with Homebrew' >&2
  exit 2
fi

python=/usr/bin/python3
[ -x "$python" ] || python=python3
command -v brew >/dev/null || { echo 'brew is required' >&2; exit 1; }
command -v "$python" >/dev/null || { echo 'python3 is required' >&2; exit 1; }

appdir=${HOMEBREW_PROOF_APPDIR:-/Applications}
app="$appdir/$app_name"
install=skip
version_check=skip
codesign_verdict=skip
spctl_verdict=skip
launch=skip
uninstall=skip
expected=${HOMEBREW_PROOF_VERSION:-}
installed_version=none
binary=''
outcome=fail

say() { printf '%s\n' "$*"; }
pass() { say "PASS: $*"; }
fail_step() { say "FAIL: $*"; }

plist_value() {
  "${PLISTBUDDY:-/usr/libexec/PlistBuddy}" -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}

app_pids() {
  [ -n "$binary" ] || return 0
  pgrep -f "$binary" || true
}

stop_app() {
  local pids
  pids=$(app_pids)
  [ -n "$pids" ] || return 0
  # PATH kill, not the bash builtin
  # shellcheck disable=SC2086
  env kill -TERM $pids 2>/dev/null || true
  for _ in $(seq 1 30); do
    [ -z "$(app_pids)" ] && return 0
    sleep 0.5
  done
  pids=$(app_pids)
  # shellcheck disable=SC2086
  [ -z "$pids" ] || env kill -KILL $pids 2>/dev/null || true
}

cask_listed() {
  brew list --cask "$token" >/dev/null 2>&1
}

uninstall_cask() {
  local st=0
  stop_app
  if cask_listed; then
    brew uninstall --cask --force "$cask" >/dev/null || st=$?
  fi
  if [ -e "$app" ]; then
    rm -rf "$app" || st=1
  fi
  if [ "$st" != 0 ] || cask_listed || [ -e "$app" ]; then
    return 1
  fi
  return 0
}

cask_version() {
  brew info --cask --json=v2 "$cask" | "$python" -c 'import json,sys
data=json.load(sys.stdin)
casks=data.get("casks") or []
if not casks:
    raise SystemExit(1)
version=(casks[0].get("version") or "").strip()
if not version:
    raise SystemExit(1)
print(version)
'
}

wait_until() {
  local limit=$1
  shift
  for _ in $(seq 1 "$limit"); do
    "$@" && return 0
    sleep 1
  done
  return 1
}

running() { [ -n "$(app_pids)" ]; }

launch_app() {
  open -n -g -j "$app" >/dev/null 2>&1 || true
  wait_until 20 running && return 0
  nohup "$binary" >/dev/null 2>&1 &
  wait_until 20 running
}

report() {
  printf '%s\n' "HOMEBREW-INSTALL-PROOF version=${installed_version:-none} expected=${expected:-none} install=$install version-check=$version_check codesign=$codesign_verdict spctl=$spctl_verdict launch=$launch uninstall=$uninstall"
  [ "$outcome" = pass ] && exit 0
  exit 1
}

if [ "$mode" = run ]; then
  trap 'stop_app || true; uninstall_cask || true' EXIT
  trap 'exit 130' INT TERM HUP
fi

if expected_tap=$(cask_version); then
  pass "cask $cask version=$expected_tap"
else
  fail_step "cask $cask is not readable from the tap"
  expected=${expected:-none}
  report
fi
if [ -z "$expected" ]; then
  expected=$expected_tap
elif [ "$expected" != "$expected_tap" ]; then
  fail_step "HOMEBREW_PROOF_VERSION=$expected does not match tap version=$expected_tap"
  report
fi

if [ "$mode" = dry-run ]; then
  pass "dry-run (no install)"
  installed_version=$expected
  outcome=pass
  report
fi

if cask_listed || [ -e "$app" ]; then
  if uninstall_cask; then
    pass "leftover uninstall"
  else
    fail_step "leftover uninstall"
    report
  fi
else
  pass "no leftover cask"
fi

if brew install --cask "$cask"; then
  install=pass
  pass "brew install --cask $cask"
else
  install=fail
  fail_step "brew install --cask $cask"
  report
fi

if [ ! -d "$app" ]; then
  version_check=fail
  fail_step "installed app missing"
  report
fi
installed_version=$(plist_value "$app" CFBundleShortVersionString || true)
installed_version=${installed_version:-none}
bundle_version=$(plist_value "$app" CFBundleVersion || true)
exec_name=$(plist_value "$app" CFBundleExecutable || true)
exec_name=${exec_name:-HermedBots}
binary="$app/Contents/MacOS/$exec_name"
if [ "$installed_version" = "$expected" ] && [ "$bundle_version" = "$expected" ]; then
  version_check=pass
  pass "installed version=$installed_version"
else
  version_check=fail
  fail_step "installed version=$installed_version bundle=$bundle_version expected=$expected"
  report
fi

if codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
  codesign_verdict=pass
  pass "codesign --verify"
else
  codesign_verdict=fail
  fail_step "codesign --verify"
  report
fi

if spctl --assess --type execute "$app" >/dev/null 2>&1; then
  spctl_verdict=pass
  pass "spctl --assess"
else
  spctl_verdict=fail
  fail_step "spctl --assess"
  report
fi

if launch_app; then
  sleep 1
  if ! running; then
    launch=fail
    fail_step "app exited before quit"
    report
  fi
  stop_app
  if running; then
    launch=fail
    fail_step "app did not quit"
    report
  fi
  launch=pass
  pass "launch and quit"
else
  launch=fail
  fail_step "app did not launch"
  report
fi

if uninstall_cask; then
  uninstall=pass
  pass "brew uninstall --cask $cask"
else
  uninstall=fail
  fail_step "brew uninstall --cask $cask"
  report
fi

trap - EXIT
outcome=pass
report
