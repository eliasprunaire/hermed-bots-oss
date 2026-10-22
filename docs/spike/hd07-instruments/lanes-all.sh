#!/usr/bin/env bash
# lanes-all.sh <dossier-de-preuves> : les dix lanes de HD-07 à la suite, contre hv-hermes-test, sur le Mac
# Le conteneur doit tourner avec son sshd (hv-ssh-endpoint.sh up). HV_XCTESTRUN et HV_XCTESTRUN_TRUNK donnent les deux builds de tests
# La lane 10 entoure les autres : hv-guard.sh snapshot au début, check à la fin, sur les chemins protégés
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EVD=${1:?usage: lanes-all.sh <dossier-de-preuves>}
mkdir -p "$EVD"
results=()
lane() { # lane <nom> <commande...> : lance, garde le code
  local name=$1; shift
  echo; echo "================ $name"
  "$@"; local rc=$?
  echo "================ $name : code $rc"
  results+=("$name=$rc")
}
say "tête de code $(git -C "$REPO" rev-parse --short HEAD), $(/usr/bin/ssh -V 2>&1), macOS $(sw_vers -productVersion)"
say "lane 10, début : snapshot des chemins protégés"
"$SK/hv-guard.sh" snapshot "$EVD/guard-before.txt"; g=$?
# 20 et 21 : arrêt avant toute opération de test
[ "$g" = 0 ] || { echo "RESULT FAIL : hv-guard.sh snapshot code $g, aucune lane lancée"; exit "$g"; }
results+=("guard-snapshot=0")
# les codes de target sont imposés : tout écart arrête la passe avant la première lane
"$SK/hv-guard.sh" target perso-hermes.invalid; g=$?
echo "hv-guard.sh target perso-hermes.invalid : code $g (22 attendu)"
[ "$g" = 22 ] || { echo "RESULT FAIL : hv-guard.sh target perso-hermes.invalid code $g, 22 attendu, aucune lane lancée"; exit 1; }
"$SK/hv-guard.sh" target host.example; g=$?
echo "hv-guard.sh target host.example : code $g (0 attendu)"
[ "$g" = 0 ] || { echo "RESULT FAIL : hv-guard.sh target host.example code $g, 0 attendu, aucune lane lancée"; exit 1; }

lane "lane 1 trunk contre head" "$HERE/lane-regression.sh" "$EVD/lane1"
lane "lanes 2 et 8 (saisie), tests UI" "$HERE/run-ui.sh" "$EVD/lane2-8" testTheConnectionViewShowsTheHostAndTheKeyStateButNeverTheKey testAHostThatNamesPersoHermesIsRefusedBeforeAnyConnection
lane "lane 3 ssh tué" "$HERE/lane-reopen.sh" "$EVD/lane3" kill
lane "lane 4 quitter" "$HERE/lane-processes.sh" "$EVD/lane4" testQuittingWithCommandQClosesTheAppAndItsTunnel testTerminateClosesTheAppAndItsTunnel
lane "lane 5 clé refusée" "$HERE/lane-wrongkey.sh" "$EVD/lane5"
lane "lane 6 netwatch" "$HERE/lane-netwatch.sh" "$EVD/lane6"
lane "lane 7 clé nulle part" "$HERE/lane-secret.sh" "$EVD/lane7"
lane "lane 8 hôte au lancement" "$HERE/lane-processes.sh" "$EVD/lane8" testAPersoHermesHostInTheEnvironmentNeverStartsSsh
lane "lane 9 réseau coupé" "$HERE/lane-reopen.sh" "$EVD/lane9" network

echo; echo "================ lane 10, fin"
"$SK/hv-guard.sh" check "$EVD/guard-before.txt"; g=$?
results+=("guard-check=$g")
echo "hv-guard.sh check : code $g"
echo; echo "RÉSUMÉ : ${results[*]}"
for r in "${results[@]}"; do [ "${r#*=}" = 0 ] || { echo "RESULT FAIL"; exit 1; }; done
echo "RESULT OK"
