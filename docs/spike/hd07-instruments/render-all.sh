#!/usr/bin/env bash
# render-all.sh <dossier-de-preuves-final> <dossier-de-sortie> : produit les PNG hd07-*.png de la PR
# Une capture d'écran de l'app (XCUITest ou screencapture) accompagne la transcription de la lane quand la fenêtre montre le résultat ;
# les lanes qui se lisent dans un terminal (processus, réseau, secret, garde) sont rendues en transcription seule
# Chaque PNG porte en tête le SHA de code et l'heure de rendu : c'est une sortie de terminal rendue en image, pas une capture d'écran du Mac
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EVD=${1:?usage: render-all.sh <preuves> <sortie>}; OUT=${2:?}
mkdir -p "$OUT" "$EVD/sections" "$EVD/render"
SHA=$(git -C "$REPO" rev-parse --short HEAD)
CODE_SHA=${CODE_SHA:-$SHA}
WHEN=$(TZ=Europe/Paris date '+%Y-%m-%d %H:%M:%S')
FONT=/System/Library/Fonts/Menlo.ttc

# découpe lanes.log : une section par ligne « ================ nom »
python3 - "$EVD/lanes.log" "$EVD/sections" <<'PY'
import re, sys, os
log, out = sys.argv[1], sys.argv[2]
cur, buf = "00-preambule", []
sections = {}
for line in open(log, errors="replace"):
    m = re.match(r"=+ (lanes? [0-9a-z]+.*?)( : code \d+)?$", line.rstrip())
    if m and not m.group(2):
        sections[cur] = buf
        cur, buf = m.group(1), []
        continue
    buf.append(line)
sections[cur] = buf
for name, lines in sections.items():
    open(os.path.join(out, re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") + ".txt"), "w").write("".join(lines))
PY

# transcription -> image : text_png <fichier-texte> <titre> <sortie.png>
text_png() {
  { echo "HD-07 code=$CODE_SHA rendu=$WHEN Paris (transcription de terminal rendue en image)"; echo "$2"; echo; fold -w 165 -s "$1"; } > "$EVD/render/$(basename "$3").txt"
  magick -background '#1e1e1e' -fill '#e6e6e6' -font "$FONT" -pointsize 15 "label:@$EVD/render/$(basename "$3").txt" -bordercolor '#1e1e1e' -border 16 "$3"
}
# captures + transcription : shots_png <fichier-texte> <titre> <sortie.png> <image...>
shots_png() {
  local text=$1 title=$2 out=$3; shift 3
  local imgs=() i
  for i in "$@"; do imgs+=("$i"); done
  magick "${imgs[@]}" -resize 1100x -background '#1e1e1e' +append "$EVD/render/row.png"
  text_png "$text" "$title" "$EVD/render/caption.png"
  local width; width=$(magick identify -format '%w' "$EVD/render/row.png")
  magick "$EVD/render/row.png" \( "$EVD/render/caption.png" -background '#1e1e1e' -gravity West -extent "${width}x" \) -append "$out"
}

S=$EVD/sections
# les noms de section viennent des titres de lanes-all.sh
sec() { ls "$S"/*"$1"*.txt 2>/dev/null | head -1; }

# le runner XCUITest est sandboxé : les captures des tests UI sortent des xcresult
for pair in "lane2-8:hd07-connection hd07-refuse-prod" "lane5:hd07-wrong-key" "lane8:hd07-refuse-launch"; do
  # shellcheck disable=SC2086
  "$SK/hv-shotdiff.sh" --export "$EVD/${pair%%:*}/result.xcresult" "$EVD/${pair%%:*}/shots" ${pair#*:} | tail -1
done

# lane 9 : LANE9_DIR et LANE9_LOG désignent une relance de la seule lane 9 quand la capture « après » de la passe complète a manqué
LANE9_DIR=${LANE9_DIR:-$EVD/lane9}
LANE9_LOG=${LANE9_LOG:-$(sec lane-9)}

shots_png "$(sec lane-1)" "Lane 1 : le même lancement au trunk (connexion directe 127.0.0.1:18642) puis au head (tunnel). Capture : le head, vue Connexion ouverte" "$OUT/hd07-tunnel.png" "$EVD/lane1/head/shots/hd07-tunnel.png"
shots_png "$(sec lanes-2)" "Lane 2 : la vue Connexion montre l'hôte, l'état de la clé, sans sa valeur (XCUITest : aucun fragment de la clé dans l'interface)" "$OUT/hd07-connection.png" "$EVD/lane2-8/shots/hd07-connection.png"
shots_png "$(sec lane-3)" "Lane 3 : le ssh enfant est tué en pleine session, le tunnel se rouvre (gauche : avant, droite : après)" "$OUT/hd07-reopen.png" "$EVD/lane3/kill-before.png" "$EVD/lane3/kill-after.png"
text_png "$(sec lane-4)" "Lane 4 : quitter l'app (Cmd-Q, puis terminate) ne laisse aucun processus du groupe" "$OUT/hd07-no-orphan.png"
shots_png "$(sec lane-5)" "Lane 5 : une clé refusée, un message, une seule tentative dans le journal de sshd" "$OUT/hd07-wrong-key.png" "$EVD/lane5/shots/hd07-wrong-key.png"
text_png "$(sec lane-6)" "Lane 6 : hv-netwatch.sh pendant une session, la seule connexion sortante est le tunnel" "$OUT/hd07-netwatch.png"
text_png "$(sec lane-7)" "Lane 7 : la valeur de la clé n'apparaît ni dans ps, ni dans les preuves, ni dans le dépôt" "$OUT/hd07-no-secret.png"
cat "$(sec lanes-2)" "$(sec lane-8)" > "$EVD/render/lane8-text.txt"
shots_png "$EVD/render/lane8-text.txt" "Lane 8 : un hôte qui contient perso-hermes est refusé avant toute connexion (gauche : saisi dans la vue, droite : donné au lancement)" "$OUT/hd07-refuse-prod.png" "$EVD/lane2-8/shots/hd07-refuse-prod.png" "$EVD/lane8/shots/hd07-refuse-launch.png"
shots_png "$LANE9_LOG" "Lane 9 : réseau du conteneur coupé 30 s puis rétabli (gauche : pendant la coupure, droite : après)" "$OUT/hd07-network-cut.png" "$LANE9_DIR/network-during.png" "$LANE9_DIR/network-after.png"
text_png "$(sec lane-10)" "Lane 10 : hv-guard.sh snapshot avant les lanes 1 à 9, check après" "$OUT/hd07-guard.png"
ls -la "$OUT"/hd07-*.png
