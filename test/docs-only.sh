#!/usr/bin/env bash
# Temporary git repo cases for scripts/docs-only.sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script=$root/scripts/docs-only.sh
fail=0

git_in() {
  local cwd=$1
  shift
  git -c core.hooksPath=/dev/null -C "$cwd" "$@"
}

setup() {
  dir=$(mktemp -d "${TMPDIR:-/tmp}/docs-only-XXXXXX")
  git_in "$dir" init -q -b main
  git_in "$dir" config user.email t@example.test
  git_in "$dir" config user.name t
  git_in "$dir" config commit.gpgsign false
}

teardown() {
  rm -rf "$dir"
}

expect() {
  local want_status=$1 want_kind=$2
  shift 2
  local got
  set +e
  got=$(cd "$dir" && bash "$script" "$@" 2>/dev/null)
  local st=$?
  set -e
  case $got in
    "DOCS-ONLY: $want_kind reason="*)
      kind_ok=1
      ;;
    *)
      kind_ok=0
      ;;
  esac
  if [ "$st" -ne "$want_status" ] || [ "$kind_ok" -ne 1 ]; then
    printf 'FAIL status=%s want=%s out=%s\n' "$st" "$want_status" "$got"
    fail=1
  fi
}

setup
printf 'a\n' >"$dir/README.md"
git_in "$dir" add -A
git_in "$dir" commit -q -m init
base=$(git_in "$dir" rev-parse HEAD)
mkdir -p "$dir/docs"
printf 'n\n' >"$dir/docs/note.md"
git_in "$dir" add -A
git_in "$dir" commit -q -m doc
expect 0 yes "$base" HEAD
teardown

setup
printf 'a\n' >"$dir/README.md"
git_in "$dir" add -A
git_in "$dir" commit -q -m init
base=$(git_in "$dir" rev-parse HEAD)
mkdir -p "$dir/src"
printf 'let x = 1\n' >"$dir/src/App.swift"
git_in "$dir" add -A
git_in "$dir" commit -q -m swift
expect 1 no "$base" HEAD
teardown

setup
printf 'a\n' >"$dir/README.md"
git_in "$dir" add -A
git_in "$dir" commit -q -m init
base=$(git_in "$dir" rev-parse HEAD)
mkdir -p "$dir/.cursor"
printf 'x\n' >"$dir/.cursor/x.md"
git_in "$dir" add -A
git_in "$dir" commit -q -m cursor
expect 1 no "$base" HEAD
teardown

setup
printf 'a\n' >"$dir/README.md"
git_in "$dir" add -A
git_in "$dir" commit -q -m init
base=$(git_in "$dir" rev-parse HEAD)
printf '# agents\n' >"$dir/AGENTS.md"
git_in "$dir" add -A
git_in "$dir" commit -q -m agents
expect 1 no "$base" HEAD
teardown

setup
mkdir -p "$dir/docs"
printf 'same content\nline two\nline three\n' >"$dir/docs/a.md"
git_in "$dir" add -A
git_in "$dir" commit -q -m init
base=$(git_in "$dir" rev-parse HEAD)
mkdir -p "$dir/src"
git_in "$dir" mv docs/a.md src/a.md
git_in "$dir" commit -q -m move
expect 1 no "$base" HEAD
teardown

setup
mkdir -p "$dir/docs"
printf 'x\n' >"$dir/docs/a.md"
git_in "$dir" add -A
git_in "$dir" commit -q -m init
base=$(git_in "$dir" rev-parse HEAD)
git_in "$dir" rm -q docs/a.md
git_in "$dir" commit -q -m delete
expect 0 yes "$base" HEAD
teardown

setup
printf 'a\n' >"$dir/README.md"
git_in "$dir" add -A
git_in "$dir" commit -q -m init
base=$(git_in "$dir" rev-parse HEAD)
git_in "$dir" commit -q --allow-empty -m empty
expect 2 error "$base" HEAD
teardown

if [ "$fail" -ne 0 ]; then
  exit 1
fi
printf 'ok\n'
