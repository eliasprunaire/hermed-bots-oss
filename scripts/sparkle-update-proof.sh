#!/bin/bash
# Proves the Sparkle update from version N (VERSION) to N+1 with local builds, a local feed and an Ed25519 key pair
# created for this run and discarded at exit. Nothing is published and no production key is read.
#   bash scripts/sparkle-update-proof.sh prepare   builds both versions, signs the feed, checks the signatures; launches nothing
#   bash scripts/sparkle-update-proof.sh           also starts the builds: needs a macOS GUI session, run it in a disposable VM
# Optional environment: PROOF_OUT (parent of the evidence folder), SOURCE_PACKAGES (resolved SwiftPM folder for an offline build)
set -euo pipefail
set +x
umask 077
unset SPARKLE_PRIVATE_KEY

cd "$(dirname "$0")/.."
mode=${1:-run}
case "$mode" in prepare|run) ;; *) echo 'Usage: sparkle-update-proof.sh [prepare|run]' >&2; exit 2 ;; esac
if [ "$(uname -s)" != Darwin ]; then
  echo 'The update proof needs macOS with the Xcode toolchain' >&2
  exit 2
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
pass update install appcast.xml "HermedBots-$n1.zip"
installed_after_update=$relaunched
pass feed-signature refuse appcast-altered-signature.xml "HermedBots-$n1.zip"
pass archive refuse appcast.xml "HermedBots-$n1-altered.zip"
say "SPARKLE-PROOF N=$n N1=$n1 feed-signature=pass install=pass installed-after-relaunch=$installed_after_update altered-feed=refused altered-archive=refused"
