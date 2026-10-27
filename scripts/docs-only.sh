#!/usr/bin/env bash
# Classify a git range as documentation-only against scripts/docs-only-allowlist.txt.
# Usage: scripts/docs-only.sh <base> <head>
set -u

finish() {
  printf 'DOCS-ONLY: %s reason=%s\n' "$1" "$2"
  exit "$3"
}

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  finish error usage 2
fi

base=$1
head=$2
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || finish error script-dir 2
allowlist=$here/docs-only-allowlist.txt

if [ ! -f "$allowlist" ]; then
  finish error missing-allowlist 2
fi

rules=()
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case $line in
    '' | \#*) continue ;;
  esac
  rules+=("$line")
done <"$allowlist"

if [ "${#rules[@]}" -eq 0 ]; then
  finish error empty-allowlist 2
fi

glob_to_ere() {
  local glob=$1
  local i c out n
  n=${#glob}
  if [ "$n" -eq 0 ]; then
    printf '%s' '^$'
    return
  fi
  case $glob in
    */*)
      case $glob in
        /*) glob=${glob#/} ;;
      esac
      out='^'
      ;;
    *)
      out='^(.*/)?'
      ;;
  esac
  n=${#glob}
  i=0
  while [ "$i" -lt "$n" ]; do
    c=${glob:i:1}
    if [ "$c" = '*' ]; then
      if [ $((i + 1)) -lt "$n" ] && [ "${glob:i+1:1}" = '*' ]; then
        out+='.*'
        i=$((i + 2))
        continue
      fi
      out+='[^/]*'
      i=$((i + 1))
      continue
    fi
    if [ "$c" = '?' ]; then
      out+='[^/]'
      i=$((i + 1))
      continue
    fi
    case $c in
      '.' | '[' | ']' | '^' | '$' | '(' | ')' | '+' | '{' | '}' | '|')
        out+="\\$c"
        ;;
      *)
        out+=$c
        ;;
    esac
    i=$((i + 1))
  done
  out+='$'
  printf '%s' "$out"
}

path_allowed() {
  local path=$1
  local rule pat ere last=
  for rule in "${rules[@]}"; do
    case $rule in
      !*) pat=${rule#!} ;;
      *) pat=$rule ;;
    esac
    ere=$(glob_to_ere "$pat")
    if [[ $path =~ $ere ]]; then
      case $rule in
        !*) last=0 ;;
        *) last=1 ;;
      esac
    fi
  done
  [ "$last" = 1 ]
}

if ! diff_out=$(git diff --name-status -M "${base}...${head}" 2>/dev/null); then
  finish error git 2
fi

if [ -z "$diff_out" ]; then
  finish error empty-diff 2
fi

while IFS=$'\t' read -r status p1 p2; do
  p1=${p1:-}
  p2=${p2:-}
  [ -n "$status" ] || continue
  case $status in
    [RC]*)
      if [ -z "${p1:-}" ] || [ -z "${p2:-}" ]; then
        finish error unreadable-diff 2
      fi
      if ! path_allowed "$p1" || ! path_allowed "$p2"; then
        finish no "$p2" 1
      fi
      ;;
    D)
      if [ -z "${p1:-}" ]; then
        finish error unreadable-diff 2
      fi
      if ! path_allowed "$p1"; then
        finish no "$p1" 1
      fi
      ;;
    A | M | T)
      if [ -z "${p1:-}" ]; then
        finish error unreadable-diff 2
      fi
      if ! path_allowed "$p1"; then
        finish no "$p1" 1
      fi
      ;;
    *)
      finish error unreadable-diff 2
      ;;
  esac
done <<<"$diff_out"

finish yes allowlist 0
