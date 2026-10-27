#!/bin/bash
set -euo pipefail
set +x

cask=eliasprunaire/tap/hermed-bots
token=hermed-bots
app_name=HermedBots.app
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
homebrew_no_install_from_api_owned=0

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

restore_homebrew_install_from_api() {
  if [ "${homebrew_no_install_from_api_owned:-0}" = 1 ]; then
    unset HOMEBREW_NO_INSTALL_FROM_API
    homebrew_no_install_from_api_owned=0
  fi
}

plist_value() {
  "${PLISTBUDDY:-/usr/libexec/PlistBuddy}" -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}

app_pids() {
  [ -n "$binary" ] || return 0
  pgrep -f "$binary" || true
}

stop_app() {
  local pid
  local -a pids
  pids=()
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    pids+=("$pid")
  done < <(app_pids)
  [ "${#pids[@]}" -gt 0 ] || return 0
  # PATH kill, not the bash builtin
  env kill -TERM "${pids[@]}" 2>/dev/null || true
  for _ in $(seq 1 30); do
    [ -z "$(app_pids)" ] && return 0
    sleep 0.5
  done
  pids=()
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    pids+=("$pid")
  done < <(app_pids)
  [ "${#pids[@]}" -eq 0 ] || env kill -KILL "${pids[@]}" 2>/dev/null || true
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

launch_wait=${HOMEBREW_PROOF_LAUNCH_WAIT:-20}

open_app() {
  "$python" - "$app" "$launch_wait" <<'PY'
import subprocess, sys
app, limit = sys.argv[1], int(sys.argv[2])
try:
    run = subprocess.run(
        ["open", "-n", "-g", "-j", app],
        timeout=limit,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
except subprocess.TimeoutExpired:
    sys.exit(124)
sys.exit(run.returncode)
PY
}

launch_reason=

launch_app() {
  launch_reason=
  open_app || true
  if ! wait_until "$launch_wait" running; then
    launch_reason=missing
    return 1
  fi
  sleep 1
  if ! running; then
    launch_reason=died
    return 1
  fi
  return 0
}

bind_binary() {
  local exec_name=HermedBots
  if [ -d "$app" ]; then
    exec_name=$(plist_value "$app" CFBundleExecutable || true)
    exec_name=${exec_name:-HermedBots}
  fi
  binary="$app/Contents/MacOS/$exec_name"
}

report() {
  restore_homebrew_install_from_api
  printf '%s\n' "HOMEBREW-INSTALL-PROOF version=${installed_version:-none} expected=${expected:-none} install=$install version-check=$version_check codesign=$codesign_verdict spctl=$spctl_verdict launch=$launch uninstall=$uninstall"
  [ "$outcome" = pass ] && exit 0
  exit 1
}

uninstall_and_record() {
  stop_app || true
  if uninstall_cask; then
    uninstall=pass
    pass "brew uninstall --cask $cask"
    return 0
  fi
  uninstall=fail
  fail_step "brew uninstall --cask $cask"
  return 1
}

if [ "$mode" = run ]; then
  trap 'stop_app || true; uninstall_cask || true; restore_homebrew_install_from_api' EXIT
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

bind_binary
if cask_listed || [ -e "$app" ]; then
  if uninstall_cask; then
    pass "leftover uninstall"
  else
    fail_step "leftover uninstall"
    report
  fi
else
  stop_app
  pass "no leftover cask"
fi
bind_binary

if brew install --cask --appdir="$appdir" "$cask"; then
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
bind_binary
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
  stop_app
  if running; then
    launch=fail
    fail_step "app did not quit"
  else
    launch=pass
    pass "launch and quit"
  fi
else
  launch=fail
  if [ "$launch_reason" = died ]; then
    fail_step "app exited before quit"
  else
    fail_step "app did not launch"
  fi
fi

uninstall_and_record || true
trap - EXIT
if [ "$launch" = pass ] && [ "$uninstall" = pass ]; then
  outcome=pass
fi
report
