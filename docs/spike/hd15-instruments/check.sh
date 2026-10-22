#!/usr/bin/env bash
set -euo pipefail
DD=${HV_WORK:-$HOME/hermed-bots-work}/hd15-dd/Build/Products/Debug
OUT=${HV_WORK:-$HOME/hermed-bots-work}/hd15-check
xcrun swiftc -parse-as-library -I "$DD" HermedBots/KillSwitch/KillSwitch.swift HermedBots/Conversation/Conversation.swift HermedBots/Conversation/ConversationMachine.swift docs/spike/hd15-instruments/StopAllCheck.swift "$DD/HermesAdapter.o" -o "$OUT"
"$OUT"
