#!/usr/bin/env bash
# lane-wrongkey.sh <dossier-de-preuves> : lane 5, une clé refusée donne un message clair et une seule tentative
# Compte les refus de clé publique dans le journal sshd du conteneur avant et après le test UI de la clé refusée
# Une boucle de relance ferait monter ce compte ; le test attend 6 s après l'apparition du message (le premier délai de relance est 1 s)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EVD=${1:?usage: lane-wrongkey.sh <dossier-de-preuves>}
mkdir -p "$EVD"
failed0=$(sshd_failures); accepted0=$(sshd_accepts)
say "journal sshd avant : Failed publickey=$failed0, Accepted publickey=$accepted0"
"$HERE/lane-processes.sh" "$EVD" testAWrongKeyShowsOneClearMessageAndStopsWithoutARetryLoop; rc=$?
failed1=$(sshd_failures); accepted1=$(sshd_accepts)
say "journal sshd après : Failed publickey=$failed1, Accepted publickey=$accepted1"
say "tentatives refusées pendant le test : $((failed1 - failed0)), acceptées : $((accepted1 - accepted0))"
"$ENDPOINT" log | grep -E "Failed publickey|Connection closed by authenticating user" | tail -4 | sed -E 's/SHA256:[A-Za-z0-9+\/]+/SHA256:<empreinte>/'
if [ $((failed1 - failed0)) -eq 1 ] && [ $((accepted1 - accepted0)) -eq 0 ] && [ $rc -eq 0 ]; then say "RESULT OK : un refus, aucune relance"; exit 0; fi
say "RESULT FAIL"; exit 1
