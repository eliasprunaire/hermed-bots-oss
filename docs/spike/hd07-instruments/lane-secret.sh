#!/usr/bin/env bash
# lane-secret.sh <dossier-de-preuves> : lane 7, la valeur de la clé n'apparaît ni dans ps, ni dans les preuves, ni dans le dépôt
# La clé existe sur le disque, dans $KEYDIR, le temps de la lane : ssh la lit par l'IdentityFile de l'alias. La lane cherche sa valeur partout ailleurs
# 1. lance l'app à la main avec l'alias de test, lit `ps -o args=` de chaque processus enfant (gardien, ssh) et leur environnement
# 2. lance la suite des tests UI avec le même alias : elle produit captures, xcresult et journaux dans le dossier de preuves
# 3. cherche des fragments de la clé dans tout le dossier de preuves de HD-07 et dans le dépôt (arbre de travail et historique)
# Les fragments passent par un descripteur de fichier, jamais en argument : un grep -F "fragment" les montrerait dans ps
# Une recherche témoin cherche une chaîne connue dans un dossier témoin, pour prouver que la recherche ne reste pas aveugle
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EVD=${1:?usage: lane-secret.sh <dossier-de-preuves>}
mkdir -p "$EVD"
new_alias || exit 1
trap drop_alias EXIT
# fragments : 40 caractères du début et de la fin du corps base64 de chaque clé privée (hors lignes -----)
fragments() { printf '%s\n' "$1" | grep -v -- '-----' | tr -d '\n' | awk '{print substr($0,1,40); print substr($0,length($0)-39,40)}'; }
FRAGS=$( { fragments "$(cat "$KEYDIR/good")"; fragments "$(cat "$KEYDIR/bad")"; } )
[ "$(printf '%s\n' "$FRAGS" | grep -c .)" -eq 4 ] || { say "FAIL: fragments de clé inattendus"; exit 1; }
found() { grep -qFf <(printf '%s\n' "$FRAGS") ; }

say "1. processus enfants de l'app, arguments (ps -o args=)"
start_app "$EVD/app-secret.log"
trap 'stop_app "$APP_PID"; drop_alias' EXIT
for _ in $(seq 1 40); do S=$(ssh_child "$APP_PID"); [ -n "$S" ] && break; sleep 0.25; done
sleep 1
leaks=0
while read -r pid; do
  echo "pid $pid : $(ps -o args= -p "$pid" | cut -c1-220)"
  ps -o args= -p "$pid" | found && { echo "  FUITE dans les arguments de $pid"; leaks=$((leaks + 1)); }
  # ps eww montre l'environnement des processus de l'utilisateur
  ps eww -o command= -p "$pid" | found && { echo "  FUITE dans l'environnement de $pid"; leaks=$((leaks + 1)); }
done < <(app_children "$APP_PID" | awk '{print $1}')
echo "contrôle : l'environnement de l'app elle-même ne contient pas la clé : $(ps eww -o command= -p "$APP_PID" | found && echo FUITE || echo oui)"
say "arguments du ssh enfant en entier :"; ps -o args= -p "$S" | fold -w 150
stop_app "$APP_PID"; trap drop_alias EXIT

say "2. suite des tests UI avec le même alias, dans le dossier de preuves"
"$HERE/run-ui.sh" "$EVD/ui" 2>&1 | tail -12

say "3. recherche des fragments de clé"
# témoin : une chaîne connue dans un dossier témoin
CONTROL=$HVW/hd07-control
mkdir -p "$CONTROL" && printf 'HV-CONTROL-FRAGMENT-0123456789-abcdefghij\n' > "$CONTROL/control.txt"
printf 'HV-CONTROL-FRAGMENT-0123456789-abcdefghij\n' | grep -rFal -f /dev/stdin "$CONTROL" >/dev/null && echo "témoin : la recherche trouve la chaîne connue (positif)"
# xcresult : les journaux et pièces jointes sont dans des blobs ; on cherche aussi dans leur lecture par xcresulttool
for bundle in "$EVD"/ui/result.xcresult; do
  xcrun xcresulttool get object --legacy --path "$bundle" --format json 2>/dev/null > "$EVD/ui/xcresult-summary.json"
done
files=$(find "$HVW/evidence" -path "*hd07*" -type f | wc -l | tr -d ' ')
bytes=$(find "$HVW/evidence" -path "*hd07*" -type f -exec stat -f %z {} + | awk '{s+=$1} END {print s}')
say "dossier de preuves HD-07 : $files fichiers, $bytes octets"
hits=$(grep -rFal -f <(printf '%s\n' "$FRAGS") "$HVW"/evidence/hd07* 2>/dev/null | head -5)
[ -n "$hits" ] && { echo "FUITE dans les preuves : $hits"; leaks=$((leaks + 1)); } || echo "preuves : aucun fragment des deux clés"
repo_hits=$(grep -rFal -f <(printf '%s\n' "$FRAGS") "$REPO/HermedBots" "$REPO/HermedBotsTests" "$REPO/HermedBotsUITests" "$REPO/docs" "$REPO/Packages/HermesAdapter/Sources" 2>/dev/null | head -5)
[ -n "$repo_hits" ] && { echo "FUITE dans le dépôt : $repo_hits"; leaks=$((leaks + 1)); } || echo "dépôt (arbre de travail) : aucun fragment"
if git -C "$REPO" log --all -p --format= -- . 2>/dev/null | found; then echo "FUITE dans l'historique git"; leaks=$((leaks + 1)); else echo "historique git (toutes les branches) : aucun fragment"; fi
if [ "$leaks" -eq 0 ]; then say "RESULT OK : la valeur de la clé n'apparaît nulle part"; exit 0; fi
say "RESULT FAIL : $leaks fuite(s)"; exit 1
