#!/usr/bin/env bash
# render-all.sh <dossier-de-preuves> <dossier-de-sortie> : produit les PNG hd08-*.png de la PR
# Chaque PNG est une capture de la fenêtre de l'app (prise par XCUITest, HVShot) au-dessus de la transcription de la lane ;
# la lane 10 se lit dans un terminal : transcription seule
# Chaque PNG porte en tête le SHA de code et l'heure de rendu : la transcription est une sortie de terminal rendue en image, pas une capture d'écran du Mac
# CODE_SHA donne le SHA du code testé quand il diffère du HEAD courant (les commits suivants ne changent que docs/spike)
# PERF_LOG (facultatif) : le journal de perf.sh, rendu en hd08-perf.png
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EVD=${1:?usage: render-all.sh <preuves> <sortie>}; OUT=${2:?}
mkdir -p "$OUT" "$EVD/sections" "$EVD/render"
CODE_SHA=${CODE_SHA:-$(git -C "$REPO" rev-parse --short HEAD)}
WHEN=$(TZ=Europe/Paris date '+%Y-%m-%d %H:%M:%S')
FONT=/System/Library/Fonts/Menlo.ttc
S=$EVD/sections

# découpe lanes.log : une section par ligne « ================ nom », sans la ligne de pied « : code N »
python3 -I - "$EVD/lanes.log" "$S" <<'PY'
import os, re, sys
log, out = sys.argv[1], sys.argv[2]
cur, buf, sections = "00-preambule", [], {}
for line in open(log, errors="replace"):
    m = re.match(r"=+ (lane .+?)( : code \d+)?$", line.rstrip())
    if m and not m.group(2):
        sections[cur] = buf
        cur, buf = m.group(1), []
        continue
    if m:
        continue
    buf.append(line)
sections[cur] = buf
for name, lines in sections.items():
    open(os.path.join(out, re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") + ".txt"), "w").write("".join(lines))
PY

text_png() { # text_png <fichier-texte> <titre> <sortie.png>
  { echo "HD-08 code=$CODE_SHA rendu=$WHEN Paris (transcription de terminal rendue en image)"; echo "$2"; echo; fold -w 118 -s "$1"; } > "$EVD/render/$(basename "$3").txt"
  magick -background '#1e1e1e' -fill '#e6e6e6' -font "$FONT" -pointsize 15 "label:@$EVD/render/$(basename "$3").txt" -bordercolor '#1e1e1e' -border 16 "$3"
}
shots_png() { # shots_png <fichier-texte> <titre> <sortie.png> <image...>
  local text=$1 title=$2 out=$3; shift 3
  magick "$@" -resize 1100x -background '#1e1e1e' +append "$EVD/render/row.png"
  text_png "$text" "$title" "$EVD/render/caption.png"
  local width; width=$(magick identify -format '%w' "$EVD/render/row.png")
  magick "$EVD/render/row.png" \( "$EVD/render/caption.png" -background '#1e1e1e' -gravity West -extent "${width}x" \) -append "$out"
}
sec() { ls "$S"/lane-"$1"-*.txt 2>/dev/null | head -1; }

shots_png "$(sec 1)" "Lane 1 : à gauche le trunk (liste vide), à droite le head (testListBots, les deux lignes actives)" "$OUT/hd08-bots.png" "$EVD/lane1/trunk/shots/launch.png" "$EVD/lane1/head/shots/hd08-bots.png"
shots_png "$(sec 2)" "Lane 2 : aucune ligne hv-old, la liste affichée est celle des profils actifs du serveur" "$OUT/hd08-no-old.png" "$EVD/lane2/shots/hd08-no-old.png"
shots_png "$(sec 3)" "Lane 3 : hv-bot-a déplié, hd.threads.row.s-past-1 sous lui, une requête list_sessions et aucun POST" "$OUT/hd08-threads.png" "$EVD/lane3/shots/hd08-threads.png"
shots_png "$(sec 4)" "Lane 4 : mode fields, un fil sans titre montre son identifiant, un bot montre l'id du profil" "$OUT/hd08-fields.png" "$EVD/lane4/shots/hd08-fields.png"
shots_png "$(sec 5)" "Lane 5 : aucun profil, un message clair, l'app tourne encore" "$OUT/hd08-empty.png" "$EVD/lane5/shots/hd08-empty.png"
shots_png "$(sec 6)" "Lane 6 : un nom de 300 caractères, un nom emoji, un nom de droite à gauche" "$OUT/hd08-long-names.png" "$EVD/lane6/shots/hd08-long-names.png"
shots_png "$(sec 7)" "Lane 7 : à gauche l'invite, hv-new absent ; à droite après « Afficher la nouvelle liste », hv-new listé" "$OUT/hd08-list-change.png" "$EVD/lane7/shots/hd08-list-change-prompt.png" "$EVD/lane7/shots/hd08-list-change.png"
shots_png "$(sec 8)" "Lane 8 : hv-hermes-test, la liste vient de hermes profile list par ssh, hv-old absent" "$OUT/hd08-orb-nine.png" "$EVD/lane8/shots/hd08-orb-nine.png"
shots_png "$(sec 9)" "Lane 9 : list_sessions supprimée, les fils sont désactivés avec un message, la liste des bots marche" "$OUT/hd08-drop-sessions.png" "$EVD/lane9/shots/hd08-drop-sessions.png"
cat "$S/00-preambule.txt" "$S"/lane-10-sonde-*.txt "$S"/lane-10-fin.txt > "$EVD/render/lane10-text.txt"
text_png "$EVD/render/lane10-text.txt" "Lane 10 : hv-guard.sh avant et après, destinations réseau vues par lsof pendant les lanes 1 à 9" "$OUT/hd08-net-guard.png"
text_png "$(sec 11)" "Lane 11 : 201 fils sur le vrai Hermes, deux pages de list_sessions (limit=200 puis offset=200), HermesClient.listSessions les rend tous" "$OUT/hd08-pagination.png"
shots_png "$(sec 12)" "Lane 12 : table de hermes profile list de plus de 8 Kio lue par ssh, les neuf profils actifs, aucun profil stopped ; l'ancien code (525db18) échoue" "$OUT/hd08-wide-table.png" "$EVD/lane12/head/shots/hd08-wide-table.png"
shots_png "$(sec 13)" "Lane 13 : noms affichés lus dans hermes profile list par ssh (nom affiché (identifiant)), la ligne porte l'identifiant, hv-old arrêté absent ; l'ancien code (940ba52) échoue" "$OUT/hd08-display-names.png" "$EVD/lane13/head/shots/hd08-display-names.png"
shots_png "$(sec 14)" "Lane 14 : modèle à parenthèses par ssh, cyber et gaming gardent leur id ; l'ancien code (f8242b1) échoue" "$OUT/hd08-model-parens.png" "$EVD/lane14/head/shots/hd08-model-parens.png"
# la perf se lance à part (perf.sh) : PERF_LOG donne son journal
[ -n "${PERF_LOG:-}" ] && text_png "$PERF_LOG" "Perf : lancement jusqu'aux neuf lignes et dépli d'un bot de 200 fils, cinq mesures chacun (perf.sh)" "$OUT/hd08-perf.png"
ls -la "$OUT"/hd08-*.png
