#!/usr/bin/env bash
set -euo pipefail
SK=.cursor/skills/verify-hermed-bots/scripts
EVD=${HV_WORK:-$HOME/hermed-bots-work}/evidence/hd15-orb-$(date +%Y%m%d-%H%M%S)
mkdir -p "$EVD"
bash "$SK/hv-guard.sh" target hv-hermes-test
bash "$SK/hv-guard.sh" snapshot "$EVD/guard-before.txt"
export HV_EVIDENCE=$EVD HV_HERMES_IMAGE=hv-hermes:spike
HV_TEST_API_KEY=$(openssl rand -hex 24)
export HV_TEST_API_KEY
up=0
cleanup() {
  if [ "$up" = 1 ]; then bash "$SK/hv-hermes-env.sh" down orb; fi
  bash "$SK/hv-guard.sh" check "$EVD/guard-before.txt"
}
trap cleanup EXIT
bash "$SK/hv-hermes-env.sh" up orb
up=1
DD=${HV_WORK:-$HOME/hermed-bots-work}/hd15-dd/Build/Products/Debug
xcrun swiftc -parse-as-library -I "$DD" HermedBots/KillSwitch/KillSwitch.swift docs/spike/hd15-instruments/orb-check.swift "$DD/HermesAdapter.o" -o "$EVD/check"
"$EVD/check"
