#!/usr/bin/env bash
# hv-guard.sh — garde des chemins protégés (A8, A12). Modèle : aucun (script).
# Usage :
#   hv-guard.sh snapshot <fichier>          # relève existence, mtime, hash
#   hv-guard.sh check <fichier-avant>       # recompare ; arrêt si changement
#   hv-guard.sh target <hôte>               # refuse ${HV_PROTECTED_HOST}
# Codes : 0 OK ; 2 usage ; 20 chemin protégé modifié ; 21 chemin protégé présent
#         avant la passe ; 22 cible interdite (${HV_PROTECTED_HOST}).
# Compatible bash 3.2 (macOS) et Linux. HOME surchargeable pour l'auto-test.
set -euo pipefail

PROTECTED=("$HOME/.hermes/hermes-agent" "$HOME/.local/bin/hermes")

_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
_sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1; else sha256sum | cut -d' ' -f1; fi; }

_state() { # une ligne par chemin : chemin|existe|mtime|hash
  local p h
  for p in "${PROTECTED[@]}"; do
    if [ -e "$p" ] || [ -L "$p" ]; then
      if [ -d "$p" ]; then
        h=$(cd "$p" && find . -print0 | LC_ALL=C sort -z | xargs -0 ls -ld 2>/dev/null | _sha)
      elif [ -L "$p" ]; then
        h=$(readlink "$p" | _sha)
      else
        h=$(_sha < "$p")
      fi
      printf '%s|1|%s|%s\n' "$p" "$(_mtime "$p")" "$h"
    else
      printf '%s|0|-|-\n' "$p"
    fi
  done
}

cmd=${1:-}; arg=${2:-}
case "$cmd" in
  snapshot)
    [ -n "$arg" ] || { echo "usage: $0 snapshot <fichier>" >&2; exit 2; }
    _state > "$arg"
    if grep -q '|1|' "$arg" && [ "${HV_ALLOW_PREEXISTING:-0}" != 1 ]; then
      echo "GUARD FAIL (21): chemin protégé déjà présent avant la passe :" >&2
      grep '|1|' "$arg" >&2; exit 21
    fi
    echo "GUARD OK: snapshot -> $arg" ;;
  check)
    [ -f "$arg" ] || { echo "usage: $0 check <fichier-avant>" >&2; exit 2; }
    now=$(_state)
    if [ "$now" != "$(cat "$arg")" ]; then
      echo "GUARD FAIL (20): chemin protégé modifié pendant la passe" >&2
      diff <(cat "$arg") <(printf '%s\n' "$now") >&2 || true
      exit 20
    fi
    echo "GUARD OK: chemins protégés inchangés" ;;
  target)
    [ -n "$arg" ] || { echo "usage: $0 target <hôte>" >&2; exit 2; }
    # HV_PROTECTED_HOST : jeton d'hôte interdit (fourni par l'environnement du lanceur).
    # Si la variable manque, le jeton littéral sert de motif : le selftest refuse
    # HV_PROTECTED_HOST.invalid sans citer d'hôte réel. Comparaison insensible à la casse.
    _deny=$(printf '%s' "${HV_PROTECTED_HOST:-HV_PROTECTED_HOST}" | tr '[:upper:]' '[:lower:]')
    case "$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')" in
      *${_deny}*) echo "GUARD FAIL (22): cible interdite : $arg" >&2; exit 22 ;;
    esac
    echo "GUARD OK: cible $arg autorisée" ;;
  *) echo "usage: $0 {snapshot|check|target} <arg>" >&2; exit 2 ;;
esac
