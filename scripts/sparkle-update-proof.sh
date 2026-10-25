#!/bin/bash
# Proves the Sparkle update from version N (VERSION) to N+1 with local builds, a local feed and an Ed25519 key pair
# created for this run and discarded at exit. Nothing is published and no production key is read.
#   bash scripts/sparkle-update-proof.sh prepare   builds both versions, signs the feed, checks the signatures; launches nothing
#   bash scripts/sparkle-update-proof.sh           also starts the builds: needs a macOS GUI session, run it in a disposable VM
#   bash scripts/sparkle-update-proof.sh published no build: installs the previous published release, then the next through the public feed
# Optional environment: PROOF_OUT (parent of the evidence folder), SOURCE_PACKAGES (resolved SwiftPM folder for an offline build),
# SPARKLE_PROOF_BUILD_DIR (extra folders, separated by a colon: bundle paths under them are not counted as installed copies)
set -euo pipefail
set +x
umask 077
unset SPARKLE_PRIVATE_KEY

_sparkle_python() {
  if [ -x /usr/bin/python3 ]; then
    printf '%s\n' /usr/bin/python3
  else
    command -v python3
  fi
}

# An update must replace the installed app, never leave a second copy of the identifier under test
# Union of Spotlight hits and Launch Services path: rows for SPARKLE_PROOF_BUNDLE_ID
# Skips missing paths and anything under the folders of SPARKLE_PROOF_BUILD_DIR (colon separated)
# Prints the count and each copy's version with a redacted path. Exit 0 only when
# there is exactly one remaining copy at SPARKLE_PROOF_TARGET_VERSION
count_hermedbots_copies() {
  local target=${SPARKLE_PROOF_TARGET_VERSION:?SPARKLE_PROOF_TARGET_VERSION is required}
  local bundle=${SPARKLE_PROOF_BUNDLE_ID:?SPARKLE_PROOF_BUNDLE_ID is required}
  local py
  py=$(_sparkle_python)
  [ -n "$py" ] || { echo 'python3 is required to count app copies' >&2; return 1; }
  "$py" - "$bundle" "$target" "${SPARKLE_PROOF_BUILD_DIR:-}" \
    "${SPARKLE_PROOF_MDFIND_FILE:-}" "${SPARKLE_PROOF_LSREGISTER_FILE:-}" <<'PY'
import os, re, sys

bundle_id, target, build_dir, md_file, ls_file = sys.argv[1:6]

def read_text(path):
    if not path:
        return ""
    try:
        return open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""

def lsregister_paths(text, ident):
    rec = {"identifier": None, "paths": []}
    found = []

    def flush():
        if rec["identifier"] == ident:
            found.extend(rec["paths"])

    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("---") or re.match(r"(?i)^bundle\b", stripped):
            flush()
            rec = {"identifier": None, "paths": []}
        ident_match = re.search(r"(?i)\bidentifier:\s+(\S+)", line)
        if ident_match:
            rec["identifier"] = ident_match.group(1).strip()
        path_match = re.search(r"(?i)\bpath:\s+(\S.*?)\s*$", line)
        if path_match:
            path = re.sub(r"\s+\([^)]*\)\s*$", "", path_match.group(1).strip())
            if path:
                rec["paths"].append(path)
    flush()
    return found

def exists(path):
    return os.path.exists(path)

def real(path):
    return os.path.realpath(path)

def under_build(path, roots):
    try:
        rp = real(path)
        for root in roots.split(os.pathsep):
            if root:
                rr = real(root)
                if rp == rr or rp.startswith(rr + os.sep):
                    return True
    except OSError:
        pass
    return False

def redact(path):
    home = os.environ.get("HOME") or ""
    try:
        home_real = real(home) if home else ""
        rp = real(path) if exists(path) else path
    except OSError:
        home_real, rp = home.rstrip("/"), path
    if home_real and (rp == home_real or rp.startswith(home_real + os.sep)):
        return "~" + rp[len(home_real):]
    if home and (path == home or path.startswith(home.rstrip("/") + "/")):
        return "~" + path[len(home.rstrip("/")):]
    if os.path.isabs(rp) or os.path.isabs(path):
        name = os.path.basename(str(rp).rstrip(os.sep)) or os.path.basename(str(path).rstrip(os.sep))
        return "<ABS>/" + (name or "path")
    return rp

def short_version(app):
    plist = os.path.join(app, "Contents", "Info.plist")
    buddy = "/usr/libexec/PlistBuddy"
    if os.path.isfile(plist) and os.access(buddy, os.X_OK):
        import subprocess
        run = subprocess.run(
            [buddy, "-c", "Print :CFBundleShortVersionString", plist],
            capture_output=True, text=True,
        )
        if run.returncode == 0:
            value = run.stdout.strip()
            return value if value else "none"
        return "none"
    if not os.path.isfile(plist):
        return "none"
    text = open(plist, encoding="utf-8", errors="replace").read()
    match = re.search(
        r"<key>CFBundleShortVersionString</key>\s*<string>([^<]*)</string>",
        text,
    )
    return match.group(1) if match else "none"

paths = []
for line in read_text(md_file).splitlines():
    line = line.strip()
    if line:
        paths.append(line)
paths.extend(lsregister_paths(read_text(ls_file), bundle_id))

unique = []
seen = set()
for path in paths:
    if not exists(path):
        continue
    if under_build(path, build_dir):
        continue
    key = real(path)
    if key in seen:
        continue
    seen.add(key)
    unique.append(key)

print("single-copy count=%d" % len(unique))
versions = []
for path in unique:
    version = short_version(path)
    versions.append(version)
    print("copy version=%s path=%s" % (version, redact(path)))

ok = len(unique) == 1 and versions[0] == target
sys.exit(0 if ok else 1)
PY
}

# Live discovery on the machine that ran the install. Simulated files skip this.
# A discovery tool that is missing or exits nonzero fails the check: its list would be incomplete
prove_single_copy() {
  local target=$1 bundle=$2
  local tmp md dump lsregister=lsregister st=0 rc
  # The identifier reaches the Spotlight query: only the characters of a bundle identifier
  [[ $bundle =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'single-copy discovery-failed source=bundle-id'; return 1; }
  command -v lsregister >/dev/null 2>&1 \
    || lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sparkle-single-copy.XXXXXX") || return 1
  md="$tmp/mdfind.txt"
  dump="$tmp/lsregister.txt"
  mdfind "kMDItemCFBundleIdentifier == '$bundle'" > "$md" 2>/dev/null || { rc=$?; echo "single-copy discovery-failed source=mdfind rc=$rc"; st=1; }
  "$lsregister" -dump > "$dump" 2>/dev/null || { rc=$?; echo "single-copy discovery-failed source=lsregister rc=$rc"; st=1; }
  if [ "$st" = 0 ]; then
    SPARKLE_PROOF_BUNDLE_ID=$bundle \
      SPARKLE_PROOF_TARGET_VERSION=$target \
      SPARKLE_PROOF_MDFIND_FILE=$md \
      SPARKLE_PROOF_LSREGISTER_FILE=$dump \
      count_hermedbots_copies || st=$?
  fi
  rm -rf "${tmp:?}"
  return "$st"
}

if [ "${SPARKLE_PROOF_SOURCE:-}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

cd "$(dirname "$0")/.."
mode=${1:-run}
case "$mode" in prepare|run|published) ;; *) echo 'Usage: sparkle-update-proof.sh [prepare|run|published]' >&2; exit 2 ;; esac
if [ "$(uname -s)" != Darwin ]; then
  echo 'The update proof needs macOS with the Xcode toolchain' >&2
  exit 2
fi

# Automatic Sparkle checks are off. The proof clicks the same app-menu command a user would.
request_user_check() {
  local pid=$1
  [ -n "$pid" ] || return 1
  osascript - "$pid" <<'APPLESCRIPT' >/dev/null
on run argv
  set targetPid to item 1 of argv as integer
  tell application "System Events"
    set p to first application process whose unix id is targetPid
    tell p
      set frontmost to true
      delay 0.4
      click (first menu item of menu 1 of menu bar item 1 of menu bar 1 whose name contains "mises")
    end tell
  end tell
end run
APPLESCRIPT
}

confirm_sparkle_install() {
  local pid=$1
  [ -n "$pid" ] || return 0
  osascript - "$pid" <<'APPLESCRIPT' >/dev/null || true
on run argv
  set targetPid to item 1 of argv as integer
  tell application "System Events"
    set p to first application process whose unix id is targetPid
    repeat 45 times
      tell p
        repeat with w in windows
          repeat with b in buttons of w
            set n to name of b
            if n contains "Install" or n contains "Installer" or n contains "Mettre" then
              click b
              return
            end if
          end repeat
        end repeat
      end tell
      delay 1
    end repeat
  end tell
end run
APPLESCRIPT
}

prove_published() {
  local from='' to='' expected_from='' feed=fail install=fail installed_after=none codesign_verdict=fail spctl_verdict=fail single_copy=fail
  local work app bundle_id python zip extract releases_repo published_feed
  # Same public releases repository as scripts/release-macos.sh and docs/distribution.md
  releases_repo=eliasprunaire/hermed-bots-releases
  published_feed="https://github.com/$releases_repo/releases/latest/download/appcast.xml"
  # Distinct from usage (2) and from a failed proof (1): the mode does not run offline
  if ! curl -fsS -o /dev/null --max-time 15 --max-redirs 5 https://github.com/; then
    echo 'No HTTPS connection to github.com' >&2
    exit 3
  fi
  python=/usr/bin/python3
  [ -x "$python" ] || python=python3
  work=$(mktemp -d "${TMPDIR:-/tmp}/sparkle-proof-published.XXXXXX")
  work=$(cd "$work" && pwd -P)
  app="$work/run/HermedBots.app"
  cleanup_published() {
    if [ -d "$app" ]; then
      local pids
      pids=$(pgrep -f "$app/Contents/MacOS/HermedBots" || true)
      if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill -TERM $pids 2>/dev/null || true
        sleep 1
        pids=$(pgrep -f "$app/Contents/MacOS/HermedBots" || true)
        # shellcheck disable=SC2086
        [ -z "$pids" ] || kill -KILL $pids 2>/dev/null || true
      fi
    fi
    [ -z "${bundle_id:-}" ] || defaults delete "$bundle_id" >/dev/null 2>&1 || true
    [ -z "${bundle_id:-}" ] || rm -rf "${HOME:?}/Library/Caches/${bundle_id:?}"
    rm -rf "${work:?}"
  }
  trap cleanup_published EXIT
  trap 'exit 130' INT TERM HUP
  report_published() {
    printf '%s\n' "SPARKLE-PROOF-PUBLISHED from=${from:-none} to=${to:-none} feed=$feed install=$install installed-after-relaunch=$installed_after codesign=$codesign_verdict spctl=$spctl_verdict single-copy $single_copy"
    if [ "$feed" = published ] && [ "$install" = pass ] && [ "$installed_after" = "$to" ] && [ "$codesign_verdict" = pass ] && [ "$spctl_verdict" = pass ] && [ "$single_copy" = pass ]; then
      exit 0
    fi
    exit 1
  }
  plist_published() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
  wait_published() { local limit=$1; shift; for _ in $(seq 1 "$limit"); do "$@" && return 0; sleep 1; done; return 1; }
  version_published() { [ "$(plist_published "$1" CFBundleShortVersionString)" = "$2" ] && [ "$(plist_published "$1" CFBundleVersion)" = "$2" ]; }
  app_running() { [ -n "$(pgrep -f "$1/Contents/MacOS/HermedBots" || true)" ]; }
  launch_published() {
    open -n -g -j "$1" >/dev/null 2>&1 || true
    wait_published 20 app_running "$1" && return 0
    nohup "$1/Contents/MacOS/HermedBots" >/dev/null 2>&1 &
    wait_published 20 app_running "$1"
  }
  stop_published() {
    local pids
    pids=$(pgrep -f "$1/Contents/MacOS/HermedBots" || true)
    [ -n "$pids" ] || return 0
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    for _ in $(seq 1 30); do
      [ -z "$(pgrep -f "$1/Contents/MacOS/HermedBots" || true)" ] && return 0
      sleep 0.5
    done
    pids=$(pgrep -f "$1/Contents/MacOS/HermedBots" || true)
    # shellcheck disable=SC2086
    [ -z "$pids" ] || kill -KILL $pids 2>/dev/null || true
  }
  installer_published() { ps -Ao command= | grep -F Autoupdate | grep -F "$bundle_id" >/dev/null; }
  sparkle_progress() {
    local cache="${HOME:?}/Library/Caches/${bundle_id:?}"
    version_published "$app" "$to" && return 0
    installer_published && return 0
    [ -d "$cache" ] || return 1
    [ "$(find "$cache" -type f 2>/dev/null | wc -l)" -gt 0 ]
  }
  if ! curl -fsS -o "$work/releases.json" --max-time 30 --max-redirs 5 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$releases_repo/releases"; then
    echo 'The published releases list could not be downloaded' >&2
    exit 1
  fi
  if ! "$python" - "$work/releases.json" > "$work/versions.txt" 2>/dev/null <<'PY'
import json, re, sys
pattern = re.compile(r"^v([0-9]+)\.([0-9]+)\.([0-9]+)$")
releases = json.load(open(sys.argv[1], encoding="utf-8"))
versions = []
for item in releases:
    if item.get("draft") or item.get("prerelease"):
        continue
    match = pattern.match(item.get("tag_name") or "")
    if match:
        versions.append((int(match.group(1)), int(match.group(2)), int(match.group(3))))
versions = sorted(set(versions))
if len(versions) < 2:
    sys.exit(1)
previous, latest = versions[-2], versions[-1]
print(".".join(map(str, previous)))
print(".".join(map(str, latest)))
PY
  then
    echo 'Need two published releases' >&2
    exit 1
  fi
  expected_from=$(sed -n 1p "$work/versions.txt")
  to=$(sed -n 2p "$work/versions.txt")
  from=$expected_from
  mkdir -p "$work/download" "$work/run"
  if ! curl --fail --location -sS -o "$work/download/SHA256SUMS" --max-time 60 --max-redirs 5 \
    "https://github.com/$releases_repo/releases/download/v$expected_from/SHA256SUMS"; then
    echo 'SHA256SUMS could not be downloaded' >&2
    report_published
  fi
  zip="$work/download/HermedBots-$expected_from.zip"
  if ! curl --fail --location -sS -o "$zip" --max-time 120 --max-redirs 5 \
    "https://github.com/$releases_repo/releases/download/v$expected_from/HermedBots-$expected_from.zip"; then
    echo 'The previous published archive could not be downloaded' >&2
    report_published
  fi
  if ! (cd "$work/download" && grep -F "HermedBots-$expected_from.zip" SHA256SUMS | shasum -a 256 -c - >/dev/null); then
    echo 'The archive does not match SHA256SUMS' >&2
    report_published
  fi
  extract="$work/extract"
  mkdir "$extract"
  if ! ditto -x -k "$zip" "$extract" >/dev/null 2>&1; then
    echo 'The archive could not be unpacked' >&2
    report_published
  fi
  if [ ! -d "$extract/HermedBots.app" ]; then
    echo 'The archive has no app bundle' >&2
    report_published
  fi
  ditto "$extract/HermedBots.app" "$app" >/dev/null 2>&1
  xattr -dr com.apple.quarantine "$app" >/dev/null 2>&1 || true
  from=$(plist_published "$app" CFBundleShortVersionString)
  [ -n "$from" ] || { echo 'The installed app has no short version' >&2; from=none; report_published; }
  [ "$from" = "$expected_from" ] || { echo 'The installed app version is not the previous published release' >&2; report_published; }
  [ "$(plist_published "$app" CFBundleVersion)" = "$from" ] || { echo 'The installed app reports mismatched versions' >&2; report_published; }
  bundle_id=$(plist_published "$app" CFBundleIdentifier)
  [ -n "$bundle_id" ] || { echo 'The installed app has no bundle identifier' >&2; report_published; }
  if [ "$(plist_published "$app" SUFeedURL)" = "$published_feed" ]; then
    feed=published
  else
    echo 'The installed app does not use the published feed' >&2
    report_published
  fi
  defaults delete "$bundle_id" >/dev/null 2>&1 || true
  rm -rf "${HOME:?}/Library/Caches/${bundle_id:?}"
  launch_published "$app" || { echo 'The previous published app did not start' >&2; report_published; }
  request_user_check "$(pgrep -f "$app/Contents/MacOS/HermedBots" | head -1)" || true
  confirm_sparkle_install "$(pgrep -f "$app/Contents/MacOS/HermedBots" | head -1)"
  wait_published 180 sparkle_progress || true
  sleep 30
  stop_published "$app"
  if wait_published 120 version_published "$app" "$to"; then
    install=pass
  fi
  launch_published "$app" || { echo 'The installed bundle did not start again' >&2; installed_after=$(plist_published "$app" CFBundleShortVersionString || true); installed_after=${installed_after:-none}; report_published; }
  sleep 5
  installed_after=$(plist_published "$app" CFBundleShortVersionString || true)
  installed_after=${installed_after:-none}
  stop_published "$app"
  SPARKLE_PROOF_BUILD_DIR="$work/extract${SPARKLE_PROOF_BUILD_DIR:+:$SPARKLE_PROOF_BUILD_DIR}"
  if copies_out=$(prove_single_copy "$to" "$bundle_id"); then single_copy=pass; else single_copy=fail; fi
  printf '%s\n' "$copies_out"
  if codesign --verify --deep --strict "$app" >/dev/null 2>&1; then codesign_verdict=pass; fi
  if spctl -a --type execute "$app" >/dev/null 2>&1; then spctl_verdict=pass; fi
  report_published
}

if [ "$mode" = published ]; then
  prove_published
  exit 1
fi

# Own bundle identifier: the proof builds never touch the preferences or the Keychain items of an installed app
bundle_id=com.hermedbots.HermedBots.updateproof
version_pattern='^([0-9]+)\.([0-9]+)\.([0-9]+)$'
n=$(tr -d '[:space:]' < VERSION)
[[ $n =~ $version_pattern ]] || { echo 'VERSION must be X.Y.Z' >&2; exit 2; }
n1="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((10#${BASH_REMATCH[3]} + 1))"

work=$(mktemp -d "${TMPDIR:-/tmp}/sparkle-proof.XXXXXX")
# Resolved path: the process list shows the real path, and pgrep must match it exactly
work=$(cd "$work" && pwd -P)
out="${PROOF_OUT:-$PWD/.audit/sparkle-update-proof}"
mkdir -p "$out"
out="$out/$(date +%Y%m%d-%H%M%S)"
mkdir "$out"
summary="$out/summary.txt"
: > "$summary"
# The key pair, the builds and the served folder stay in $work; only logs and the signed feed go to the evidence folder
secrets="$work/secrets"
mkdir "$secrets"
key="$secrets/ed25519.key"
serve="$work/serve"
mkdir "$serve"
server=''
mark=0

say() { printf '%s\n' "$*" | tee -a "$summary"; }
current=''
since=''
# State of the pass in progress, kept for the evidence folder when a pass fails or ends
collect() {
  [ -n "$current" ] && [ -d "$out/$current" ] || return 0
  tail -n +"$((mark + 1))" "$out/server.log" > "$out/$current/server.log" 2>/dev/null || true
  ps -Ao pid=,command= | grep -F -e Autoupdate -e Updater -e HermedBots | grep -F -e "$bundle_id" -e "$work" > "$out/$current/processes.txt" || true
  find "${HOME:?}/Library/Caches/${bundle_id:?}" -maxdepth 6 > "$out/$current/cache-tree.txt" 2>&1 || true
  log show --style compact --info --debug --start "$since" \
    --predicate 'subsystem == "org.sparkle-project.Sparkle" OR process CONTAINS "Autoupdate" OR process CONTAINS "Updater"' > "$out/$current/sparkle.log" 2>&1 || true
}
# Every process and launchd job that can take part in the install, with parent and age
snapshot() { # label
  [ -d "$out/$current" ] || return 0
  {
    ps -Ao pid=,ppid=,etime=,stat=,user=,command= | grep -i -e sparkle -e updater -e autoupdate -e HermedBots | grep -v -e grep -e "ps -Ao" || true
    echo "--- launchd"
    launchctl list 2>&1 | grep -i -e sparkle -e hermed -e updater || true
    echo "--- apps"
    lsappinfo list 2>&1 | grep -i -e hermed -e updater -e bundle\ path | grep -i -e hermed -e updater || true
  } > "$out/$current/snapshot-$1.txt" 2>&1
}
fail() { say "FAIL: $*"; snapshot failure; collect; exit 1; }

app_pids() { pgrep -f "$1/Contents/MacOS/HermedBots" || true; }

# SIGTERM first so the installer sees a normal exit, SIGKILL if the process stays
stop_app() {
  local pids
  pids=$(app_pids "$1")
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086 # one pid per line, word splitting is wanted
  kill -TERM $pids 2>/dev/null || true
  for _ in $(seq 1 30); do
    [ -z "$(app_pids "$1")" ] && return 0
    sleep 0.5
  done
  pids=$(app_pids "$1")
  # shellcheck disable=SC2086
  [ -z "$pids" ] || kill -KILL $pids 2>/dev/null || true
}

cleanup() {
  local app
  for app in "$work"/run-*/HermedBots.app; do [ ! -d "$app" ] || stop_app "$app"; done
  [ -z "$server" ] || kill "$server" 2>/dev/null || true
  defaults delete "$bundle_id" >/dev/null 2>&1 || true
  rm -rf "${HOME:?}/Library/Caches/${bundle_id:?}" "${work:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
wait_until() { local limit=$1; shift; for _ in $(seq 1 "$limit"); do "$@" && return 0; sleep 1; done; return 1; }

# Key pair of this run: a 32-byte seed in the format of Sparkle's --ed-key-file, and its public key
cat > "$secrets/genkey.swift" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
xcrun swiftc -o "$secrets/genkey" "$secrets/genkey.swift" 2> "$out/genkey.log"
"$secrets/genkey" > "$secrets/pair.txt"
sed -n 1p "$secrets/pair.txt" > "$key"
public_key=$(sed -n 2p "$secrets/pair.txt")
rm -f "$secrets/genkey" "$secrets/genkey.swift" "$secrets/pair.txt"

python=/usr/bin/python3
[ -x "$python" ] || python=python3
port=$("$python" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
feed_url="http://127.0.0.1:$port/appcast.xml"

packages="${SOURCE_PACKAGES:-$work/packages}"
resolution=()
if [ -n "${SOURCE_PACKAGES:-}" ]; then resolution=(-disableAutomaticPackageResolution -skipPackageUpdates); fi

build() { # version
  xcodebuild build -project HermedBots.xcodeproj -scheme HermedBots -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$work/dd" -clonedSourcePackagesDirPath "$packages" \
    ${resolution[@]+"${resolution[@]}"} \
    MARKETING_VERSION="$1" CURRENT_PROJECT_VERSION="$1" PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
    SPARKLE_FEED_URL="$feed_url" SPARKLE_PUBLIC_KEY="$public_key" > "$out/build-$1.log" 2>&1 \
    || { tail -30 "$out/build-$1.log" >&2; fail "build $1 failed"; }
  mkdir "$work/v$1"
  ditto "$work/dd/Build/Products/Release/HermedBots.app" "$work/v$1/HermedBots.app"
  codesign --verify --deep --strict "$work/v$1/HermedBots.app"
  [ "$(plist_value "$work/v$1/HermedBots.app" CFBundleShortVersionString)" = "$1" ] || fail "build $1 reports another short version"
  [ "$(plist_value "$work/v$1/HermedBots.app" CFBundleVersion)" = "$1" ] || fail "build $1 reports another bundle version"
  [ "$(plist_value "$work/v$1/HermedBots.app" SUFeedURL)" = "$feed_url" ] || fail "build $1 carries another feed URL"
  [ "$(plist_value "$work/v$1/HermedBots.app" SUPublicEDKey)" = "$public_key" ] || fail "build $1 carries another public key"
}

say "Sparkle update proof: N=$n, N+1=$n1"
build "$n"
build "$n1"
say "builds: pass (Release, signed ad hoc, same feed URL and public key)"

tools="$packages/artifacts/sparkle/Sparkle/bin"
[ -x "$tools/generate_appcast" ] && [ -x "$tools/sign_update" ] || fail 'Sparkle tools are missing from the resolved packages'
archives="$work/archives"
mkdir "$archives"
for version in "$n" "$n1"; do
  ditto -c -k --sequesterRsrc --keepParent "$work/v$version/HermedBots.app" "$archives/HermedBots-$version.zip"
done
# Deltas would give the app a second download path; this proof follows the full archive
"$tools/generate_appcast" --ed-key-file "$key" --maximum-deltas 0 --download-url-prefix "http://127.0.0.1:$port/" "$archives" \
  > "$out/generate_appcast.log" 2>&1 || { cat "$out/generate_appcast.log" >&2; fail 'generate_appcast failed'; }
cp "$archives/appcast.xml" "$out/appcast.xml"
for version in "$n" "$n1"; do
  grep -q "<sparkle:version>$version</sparkle:version>" "$archives/appcast.xml" || fail "the feed has no item for $version"
done
"$tools/sign_update" --verify --ed-key-file "$key" "$archives/appcast.xml" > "$out/feed-verify.log" 2>&1 \
  || { cat "$out/feed-verify.log" >&2; fail 'the feed signature does not verify'; }
say "feed signature check: pass (both versions in the feed)"

# The altered inputs of the two refusal passes, and proof that the signing tool itself rejects them
"$python" - "$archives" "$n1" <<'PY'
import re, sys
archives, n1 = sys.argv[1:]
feed = open(f"{archives}/appcast.xml", encoding="utf-8").read()
# Flip the first character of the feed signature: still valid base64 of 64 bytes, no longer the signature of the feed
def flip(match):
    return match.group(1) + ("B" if match.group(2) == "A" else "A")
altered, count = re.subn(r"(edSignature: )([A-Za-z0-9+/])", flip, feed, count=1)
assert count == 1, "no feed signature found"
open(f"{archives}/appcast-altered-signature.xml", "w", encoding="utf-8").write(altered)
# Flip one byte in the middle of the N+1 archive: same length, different content
data = bytearray(open(f"{archives}/HermedBots-{n1}.zip", "rb").read())
data[len(data) // 2] ^= 0xFF
open(f"{archives}/HermedBots-{n1}-altered.zip", "wb").write(data)
PY
if "$tools/sign_update" --verify --ed-key-file "$key" "$archives/appcast-altered-signature.xml" > "$out/feed-altered-verify.log" 2>&1; then
  fail 'sign_update accepted a feed with an altered signature'
fi
archive_signature=$(grep -A2 "HermedBots-$n1.zip" "$archives/appcast.xml" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -1)
[ -n "$archive_signature" ] || fail "the feed has no archive signature for $n1"
"$tools/sign_update" --verify --ed-key-file "$key" "$archives/HermedBots-$n1.zip" "$archive_signature" > "$out/archive-verify.log" 2>&1 \
  || fail 'the N+1 archive does not verify against the feed'
if "$tools/sign_update" --verify --ed-key-file "$key" "$archives/HermedBots-$n1-altered.zip" "$archive_signature" > "$out/archive-altered-verify.log" 2>&1; then
  fail 'sign_update accepted an altered archive'
fi
say "signing tool: rejects the altered feed signature and the altered archive"
if [ "$mode" = prepare ]; then
  say 'prepare mode: no app was started'
  exit 0
fi

# Local feed: serves whatever the current pass copied into $serve
"$python" -u -m http.server "$port" --bind 127.0.0.1 --directory "$serve" > "$out/server.log" 2>&1 &
server=$!
wait_until 60 curl -s -o /dev/null "http://127.0.0.1:$port/" || fail 'the local feed did not start'

running() { [ -n "$(app_pids "$1")" ]; }
launch_app() { # open registers the app in the GUI session; a direct start is the fallback
  open -n -g -j "$1" > /dev/null 2>&1 || true
  wait_until 20 running "$1" && return 0
  nohup "$1/Contents/MacOS/HermedBots" > /dev/null 2>&1 &
  wait_until 20 running "$1"
}

requested() { tail -n +"$((mark + 1))" "$out/server.log" | grep "GET /$1 " > /dev/null; }
installer_up() { ps -Ao command= | grep -F Autoupdate | grep -F -e "$bundle_id" -e "$work" > /dev/null; }
version_is() { [ "$(plist_value "$1" CFBundleShortVersionString)" = "$2" ] && [ "$(plist_value "$1" CFBundleVersion)" = "$2" ]; }

# One pass: a fresh copy of N finds the feed, then the app quits the way a user quits it, then it starts again
# expect=install: the installed bundle must be N+1; expect=refuse: it must stay N and the archive must not be installed
pass() { # name, expect, feed file and N+1 archive file served in this pass, both from $archives
  local name=$1 expect=$2 dir="$work/run-$1" app want
  current=$name
  app="$dir/HermedBots.app"
  mkdir -p "$dir" "$out/$name"
  ditto "$work/v$n/HermedBots.app" "$app"
  defaults delete "$bundle_id" >/dev/null 2>&1 || true
  rm -rf "${HOME:?}/Library/Caches/${bundle_id:?}"
  rm -f "$serve"/*
  cp "$archives/$3" "$serve/appcast.xml"
  cp "$archives/HermedBots-$n.zip" "$serve/"
  cp "$archives/$4" "$serve/HermedBots-$n1.zip"
  mark=$(wc -l < "$out/server.log")
  since=$(date '+%Y-%m-%d %H:%M:%S')
  launch_app "$app" || fail "$name: build $n did not start"
  wait_until 20 request_user_check "$(app_pids "$app" | head -1)" || fail "$name: the check menu could not be clicked"
  if [ "$name" != feed-signature ]; then confirm_sparkle_install "$(app_pids "$app" | head -1)"; fi
  wait_until 120 requested appcast.xml || fail "$name: build $n never asked for the feed"
  if [ "$name" = feed-signature ]; then
    sleep 30
    ! requested "HermedBots-$n1.zip" || fail "$name: the app downloaded the archive of an unsigned feed"
  else
    wait_until 120 requested "HermedBots-$n1.zip" || fail "$name: the app never downloaded $n1"
    if [ "$expect" = install ]; then wait_until 90 installer_up || true; fi
    sleep 30
    ps -Ao pid=,command= | grep -F Autoupdate | grep -F -e "$bundle_id" -e "$work" > "$out/$name/installer.txt" || true
    if [ "$expect" = refuse ] && installer_up; then fail "$name: an installer started for the altered archive"; fi
  fi
  snapshot before-quit
  stop_app "$app"
  sleep 5
  snapshot after-quit
  if [ "$expect" = install ]; then
    wait_until 120 version_is "$app" "$n1" || fail "$name: the installed bundle did not become $n1"
  else
    sleep 30
    version_is "$app" "$n" || fail "$name: the installed bundle changed"
  fi
  launch_app "$app" || fail "$name: the installed bundle did not start again"
  sleep 5
  relaunched=$(plist_value "$app" CFBundleShortVersionString)
  want=$n
  [ "$expect" != install ] || want=$n1
  [ "$relaunched" = "$want" ] || fail "$name: the relaunched bundle is $relaunched, expected $want"
  lsappinfo info -only bundlepath -only version "$(lsappinfo find "pid=$(app_pids "$app" | head -1)" 2>/dev/null)" > "$out/$name/running.txt" 2>&1 || true
  stop_app "$app"
  collect
  say "$name: pass (bundle after relaunch: $relaunched)"
}

relaunched=''
single_copy=fail
pass update install appcast.xml "HermedBots-$n1.zip"
installed_after_update=$relaunched
SPARKLE_PROOF_BUILD_DIR="$work/dd:$work/v$n:$work/v$n1${SPARKLE_PROOF_BUILD_DIR:+:$SPARKLE_PROOF_BUILD_DIR}"
if copies_out=$(prove_single_copy "$n1" "$bundle_id"); then single_copy=pass; else single_copy=fail; fi
say "$copies_out"
pass feed-signature refuse appcast-altered-signature.xml "HermedBots-$n1.zip"
pass archive refuse appcast.xml "HermedBots-$n1-altered.zip"
say "SPARKLE-PROOF N=$n N1=$n1 feed-signature=pass install=pass installed-after-relaunch=$installed_after_update altered-feed=refused altered-archive=refused single-copy $single_copy"
[ "$single_copy" = pass ] || exit 1
