#!/usr/bin/env bash
# lanes-all.sh <dossier-de-preuves> : les quatorze lanes de HD-08 à la suite, sur le Mac
# Les lanes 1 à 7 et 9 tournent contre le faux serveur sur 127.0.0.1:18642 (une variante de fixture par lane), la lane 8 contre hv-hermes-test
# Prérequis : build-for-testing du head dans $HV_WORK/dd et du trunk dans $HV_WORK/dd-trunk (worktree $HV_WORK/trunk-wt)
# La lane 10 entoure les autres : hv-guard.sh snapshot au début, check à la fin, et un échantillonnage lsof de l'app pendant tout le reste
# Le conteneur hv-hermes-test ne tourne pas pendant les lanes sur le faux serveur : il publie le même port. La lane 8 le crée, la lane 11 le supprime
# La lane 11 (ajoutée au correctif de pagination) lit 201 fils sur le vrai Hermes de hv-hermes-test avec hd-probe list-sessions
# La lane 12 (ajoutée au correctif de la sortie standard) lit par ssh une table de plus de 8 Kio ; elle exige aussi dd-old, le build de 525db18 (git archive), qui doit échouer
# La lane 13 (ajoutée au correctif des noms affichés) lit par ssh une table où des profils ont un nom affiché ; elle exige aussi dd-prev, le build de 940ba52 (git archive), qui doit échouer
# La lane 14 (ajoutée au correctif de la colonne Model) lit par ssh une table où un modèle contient des espaces et des parenthèses ; elle exige aussi dd-prev2, le build de f8242b1 (git archive), qui doit échouer
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$HERE/orb.sh"
EVD=${1:?usage: lanes-all.sh <dossier-de-preuves>}
mkdir -p "$EVD"; export EVD
HEAD_RUN=$(xctestrun dd); TRUNK_RUN=$(xctestrun dd-trunk); OLD_RUN=$(xctestrun dd-old 2>/dev/null); PREV_RUN=$(xctestrun dd-prev 2>/dev/null); PREV2_RUN=$(xctestrun dd-prev2 2>/dev/null)
results=()
lane() { # lane <nom> <fonction> : lance, garde le code
  local name=$1; shift
  echo; echo "================ $name"
  "$@"; local rc=$?
  echo "================ $name : code $rc"
  results+=("$name=$rc")
}
crash_reports() { find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -iname "HermedBots*" 2>/dev/null | wc -l | tr -d " "; }

say "tête de code $(git -C "$REPO" rev-parse --short HEAD), trunk $(git -C "$HVW/trunk-wt" rev-parse --short HEAD), macOS $(sw_vers -productVersion), $(xcodebuild -version | head -1)"
say "lane 10, début : snapshot des chemins protégés, contrôle des cibles, échantillonnage réseau"
"$SK/hv-guard.sh" snapshot "$EVD/guard-before.txt"; g=$?
[ "$g" = 0 ] || { echo "RESULT FAIL : hv-guard.sh snapshot code $g, aucune lane lancée"; exit "$g"; }
"$SK/hv-guard.sh" target example-host.invalid; g=$?
echo "hv-guard.sh target example-host.invalid : code $g (22 attendu)"
[ "$g" = 22 ] || { echo "RESULT FAIL : target example-host.invalid code $g, 22 attendu, aucune lane lancée"; exit 1; }
"$SK/hv-guard.sh" target "$SSH_HOST"; g=$?
echo "hv-guard.sh target $SSH_HOST : code $g (0 attendu)"
[ "$g" = 0 ] || { echo "RESULT FAIL : target $SSH_HOST code $g, 0 attendu, aucune lane lancée"; exit 1; }
python3 "$HERE/mk-fixtures.py" "$FIXDIR" > /dev/null
# le conteneur d'une passe précédente publie 18642 : il part (seul celui qui porte notre label), la lane 8 en recrée un
orb_down
STOP_FAKE="$EVD/stop-net-fake"; STOP_ORB="$EVD/stop-net-orb"; STOP_ORB12="$EVD/stop-net-orb12"; STOP_ORB13="$EVD/stop-net-orb13"; STOP_ORB14="$EVD/stop-net-orb14"
"$HERE/netsample.sh" "$EVD/net-fake.txt" "$STOP_FAKE" & SAMPLER=$!
trap 'touch "$STOP_FAKE" "$STOP_ORB" "$STOP_ORB12" "$STOP_ORB13" "$STOP_ORB14"; fake_down; orb_down; wait "$SAMPLER" 2>/dev/null' EXIT

lane1() {
  fake_up base normal || return 1
  say "trunk : LaunchTests contre $URL, la liste doit être vide"
  run_ui "$EVD/lane1/trunk" "$TRUNK_RUN" LaunchTests/testWindowOpensWithTheServerVersionAndAnEmptyBotList; local rc_t=$?
  export_shots "$EVD/lane1/trunk" launch || rc_t=1
  say "head : SixActions.testListBots, hv-netwatch.sh sur l'app pendant le test"
  ( for _ in $(seq 1 240); do pid=$(pgrep -nx HermedBots) && break; sleep 0.25; done
    [ -n "${pid:-}" ] && "$SK/hv-netwatch.sh" "$pid" 6 "$EVD/lane1/netwatch.txt" "$PORT" ) > "$EVD/lane1-netwatch.out" 2>&1 &
  local nw=$!
  run_ui "$EVD/lane1/head" "$HEAD_RUN" SixActions/testListBots; local rc_h=$?
  export_shots "$EVD/lane1/head" hd08-bots || rc_h=1
  wait "$nw"; say "hv-netwatch.sh sur l'app : $(cat "$EVD/lane1-netwatch.out" | tr '\n' ' ')"
  say "journal du faux serveur : $(log_count '' '') requêtes, routes de contrat :"; log_routes | sort | uniq -c
  [ $rc_t -eq 0 ] && [ $rc_h -eq 0 ]
}

lane2() {
  fake_up base normal || return 1
  run_ui "$EVD/lane2" "$HEAD_RUN" SixActions/testADecommissionedProfileIsNeverListedAndEveryActiveOneIs; local rc=$?
  export_shots "$EVD/lane2" hd08-no-old || rc=1
  say "table du serveur : hv-old au Gateway stopped :"; curl -fsS "$URL/_hv/profile-list" | grep -E "hv-old|hv-bot-a"
  return $rc
}

lane3() {
  fake_up base normal || return 1
  run_ui "$EVD/lane3" "$HEAD_RUN" SixActions/testExpandingABotListsItsPastThreadsWithOneRequest; local rc=$?
  export_shots "$EVD/lane3" hd08-threads || rc=1
  local lists posts
  lists=$(log_count /p/hv-bot-a/api/sessions GET); posts=$(log_count '' POST)
  say "/_hv/log du serveur (routes de contrat) :"; log_routes
  say "list_sessions=$lists (1 attendu), POST de toute sorte, send_message compris=$posts (0 attendu)"
  [ "$lists" = 1 ] && [ "$posts" = 0 ] && return $rc
  return 1
}

lane4() {
  fake_up base fields || return 1
  say "mode fields : le serveur retire title des réponses et ajoute un champ inconnu"; curl -fsS "$URL/p/hv-bot-a/api/sessions" | python3 -I -c "
import json, sys
d = json.load(sys.stdin)
print('entrée de list_sessions :', {k: v for k, v in d['data'][0].items() if k in ('id', 'title', 'zz_new_field')})"
  run_ui "$EVD/lane4" "$HEAD_RUN" SixActions/testWithoutNamesTheRowsShowTheProfileIdAndTheThreadsShowTheirId; local rc=$?
  export_shots "$EVD/lane4" hd08-fields || rc=1
  return $rc
}

lane5() {
  fake_up empty normal || return 1
  say "table du serveur : $(curl -fsS "$URL/_hv/profile-list" | grep -vc '^\s*$') lignes (en-tête et filet seulement)"
  local before after; before=$(crash_reports)
  run_ui "$EVD/lane5" "$HEAD_RUN" SixActions/testAnEmptyProfileListShowsAClearMessage; local rc=$?
  export_shots "$EVD/lane5" hd08-empty || rc=1
  after=$(crash_reports)
  say "rapports de plantage de HermedBots dans DiagnosticReports : $before avant, $after après"
  [ "$before" = "$after" ] && return $rc
  return 1
}

lane6() {
  fake_up long normal || return 1
  say "noms servis : $(curl -fsS "$URL/_hv/profile-list" | awk 'NF >= 3 && $1 != "Profile" && $1 !~ /─/ { n = $1; sub(/^◆/, "", n); printf "%d caractères (%s…) ", length(n), substr(n, 1, 8) }')"
  run_ui "$EVD/lane6" "$HEAD_RUN" SixActions/testLongEmojiAndRightToLeftNamesAreTruncatedAndReadable; local rc=$?
  export_shots "$EVD/lane6" hd08-long-names || rc=1
  return $rc
}

lane7() {
  fake_up base normal || return 1
  ( TEST_RUNNER_HV_EXPECT_CHANGE=hv-new run_ui "$EVD/lane7" "$HEAD_RUN" SixActions/testAProfileAddedWhileTheAppRunsShowsOnlyAfterTheValidation > "$EVD/lane7.out" 2>&1 ) &
  local bg=$!
  for _ in $(seq 1 240); do pgrep -x HermedBots > /dev/null && break; sleep 0.5; done
  sleep 8
  say "le serveur ajoute hv-new : il redémarre sur le même port avec la fixture added (l'app tourne depuis 8 s)"
  fake_up added normal || return 1
  say "table du serveur après l'ajout : $(curl -fsS "$URL/_hv/profile-list" | grep -c 'hv-new') ligne hv-new"
  wait "$bg"; local rc=$?
  cat "$EVD/lane7.out"
  export_shots "$EVD/lane7" hd08-list-change-prompt hd08-list-change || rc=1
  return $rc
}

lane9() {
  fake_up base drop-route list_sessions || return 1
  say "route supprimée : GET /p/hv-bot-a/api/sessions -> $(curl -s -o /dev/null -w '%{http_code}' "$URL/p/hv-bot-a/api/sessions")"
  run_ui "$EVD/lane9" "$HEAD_RUN" SixActions/testDroppingListSessionsDisablesTheThreadsAloneWithAMessage; local rc=$?
  export_shots "$EVD/lane9" hd08-drop-sessions || rc=1
  say "routes de contrat reçues :"; log_routes
  return $rc
}

lane8() {
  fake_down
  orb_up || return 1
  say "référence (S6) : hermes profile list dans le conteneur"
  docker exec -u hermes -e HOME=/opt/data "$CT" hermes profile list
  "$HERE/netsample.sh" "$EVD/net-orb.txt" "$STOP_ORB" & local sampler=$!
  TEST_RUNNER_HV_API_URL='' TEST_RUNNER_HV_SSH_HOST=$SSH_HOST TEST_RUNNER_HV_SSH_USER=hermes \
    TEST_RUNNER_HV_TEST_SSH_KEY=$HV_TEST_SSH_KEY TEST_RUNNER_HV_TEST_API_KEY=$HV_TEST_API_KEY \
    TEST_RUNNER_HV_EXPECT_BOTS=default,cyber,gaming,ia,perso,recherches,sport,tiny,wikilibriste TEST_RUNNER_HV_EXPECT_ABSENT=hv-old \
    run_ui "$EVD/lane8" "$HEAD_RUN" SixActions/testTheSeededProfilesOfTheOrbInstanceShowAndTheParkedOneDoesNot; local rc=$?
  touch "$STOP_ORB"; wait "$sampler" 2>/dev/null
  export_shots "$EVD/lane8" hd08-orb-nine || rc=1
  say "sshd du conteneur : $(docker exec -u root "$CT" grep -c 'Accepted publickey for hermes' /var/log/hv-sshd.log) connexion(s) acceptée(s) pour hermes, $(docker exec -u root "$CT" grep -c 'Failed publickey' /var/log/hv-sshd.log) refus"
  say "Hermes réel : limit de list_sessions (défaut, 200, 500) ; la clé passe par l'entrée standard de curl"
  for q in "" "?limit=200" "?limit=500"; do
    printf 'header = "Authorization: Bearer %s"\n' "$HV_TEST_API_KEY" | curl -sS -K - -o "$EVD/limit.json" -w "GET /p/hv-bot-a/api/sessions$q -> HTTP %{http_code} " "$URL/p/hv-bot-a/api/sessions$q"
    python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print('limit=%s has_more=%s n=%d' % (d.get('limit'), d.get('has_more'), len(d.get('data', []))))" "$EVD/limit.json"
  done
  return $rc
}

# lane 11 : 201 fils sur le vrai Hermes (conteneur de la lane 8, encore levé), lus page par page par HermesClient.listSessions
# Hermes plafonne limit à 200 : sans suivre has_more, le client rendrait 200 fils et perdrait le plus ancien
lane11() {
  [ -n "$(docker ps -q --filter "label=hv.owner=verify-hermed-bots")" ] || { echo "LANE 11 FAIL : le conteneur $CT ne tourne pas"; return 1; }
  local before; before=$(printf 'header = "Authorization: Bearer %s"\n' "$HV_TEST_API_KEY" | curl -sS -K - "$URL/p/hv-bot-a/api/sessions?limit=200" | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)["data"]))')
  say "fils de hv-bot-a avant la création : $before"
  # la clé passe par l'environnement du processus Python, jamais par un argument
  python3 -I - "$URL/p/hv-bot-a/api/sessions" $((201 - before)) <<'PY' || return 1
import json, os, sys, urllib.request
url, count = sys.argv[1], int(sys.argv[2])
for _ in range(max(count, 0)):
    request = urllib.request.Request(url, data=b"{}", method="POST", headers={"Authorization": "Bearer " + os.environ["HV_TEST_API_KEY"], "Content-Type": "application/json"})
    assert urllib.request.urlopen(request, timeout=30).status in (200, 201)
print("sessions créées par POST /p/hv-bot-a/api/sessions :", max(count, 0))
PY
  local raw
  for q in "?limit=200" "?limit=200&offset=200"; do
    printf 'header = "Authorization: Bearer %s"\n' "$HV_TEST_API_KEY" | curl -sS -K - -o "$EVD/page.json" -w "GET /p/hv-bot-a/api/sessions$q -> HTTP %{http_code} " "$URL/p/hv-bot-a/api/sessions$q"
    python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print('limit=%s offset=%s has_more=%s n=%d' % (d.get('limit'), d.get('offset'), d.get('has_more'), len(d.get('data', []))))" "$EVD/page.json"
  done
  local bin; bin=$(cd "$REPO/Packages/HermesAdapter" && swift build --show-bin-path)/hd-probe
  say "hd-probe list-sessions --url $URL --profile hv-bot-a (HermesClient.listSessions de la tête de code)"
  raw=$("$bin" list-sessions --url "$URL" --profile hv-bot-a); local rc=$?
  echo "$raw"; echo "rc=$rc"
  say "hd-probe list-sessions --profile hv-bot-b (aucun fil créé, une seule requête suffit)"
  "$bin" list-sessions --url "$URL" --profile hv-bot-b
  orb_down
  [ $rc -eq 0 ] && grep -qx 'sessions: 201' <<< "$raw" && grep -qx 'distinct: 201' <<< "$raw"
}

# lane 12 : une table de plus de 8 Kio lue par le vrai ssh (défaut du vérificateur sur 525db18 : Spawn.run coupait stdout à 8 192 octets, code de sortie 0)
# Les profils créés après le démarrage de Hermes sont stopped, puis Hermes les sert et ils passent running au bout de 60 s environ (mesuré)
# Chaque profil reçoit donc le marqueur gateway.parked, celui de hv-old : il reste stopped, gonfle la table et ne devient jamais un bot
# Triés avant ia, perso, recherches, sport, tiny et wikilibriste, ils repoussent ces six profils actifs au-delà de l'octet 8 192
# L'ancien code (dd-old, 525db18) doit échouer sur cette lane, le code de la tête doit la passer
lane12_ui() { # lane12_ui <dossier> <xctestrun>
  TEST_RUNNER_HV_API_URL='' TEST_RUNNER_HV_SSH_HOST=$SSH_HOST TEST_RUNNER_HV_SSH_USER=hermes \
    TEST_RUNNER_HV_TEST_SSH_KEY=$HV_TEST_SSH_KEY TEST_RUNNER_HV_TEST_API_KEY=$HV_TEST_API_KEY \
    TEST_RUNNER_HV_EXPECT_BOTS=default,cyber,gaming,ia,perso,recherches,sport,tiny,wikilibriste \
    TEST_RUNNER_HV_EXPECT_ABSENT=hv-old,hv-wide-profile-001,hv-wide-profile-100 TEST_RUNNER_HV_SHOT_NAME=hd08-wide-table \
    run_ui "$1" "$2" SixActions/testTheSeededProfilesOfTheOrbInstanceShowAndTheParkedOneDoesNot
}
lane12() {
  [ -n "$OLD_RUN" ] || { echo "LANE 12 FAIL : dd-old manque (build-for-testing de 525db18, extrait par git archive)"; return 1; }
  orb_up || return 1
  docker exec -u hermes -e HOME=/opt/data "$CT" sh -c 'seq -w 1 100 | xargs -P 8 -I{} hermes profile create hv-wide-profile-{} --no-alias --no-skills > /dev/null 2>&1' || return 1
  docker exec -u hermes -e HOME=/opt/data "$CT" sh -c 'for d in /opt/data/profiles/hv-wide-profile-*; do touch "$d/gateway.parked"; done' || return 1
  say "référence : hermes profile list dans le conteneur, 100 profils hv-wide-profile-NNN créés après le démarrage"
  docker exec -u hermes -e HOME=/opt/data "$CT" hermes profile list > "$EVD/wide-table.txt" || return 1
  local bytes seen
  bytes=$(wc -c < "$EVD/wide-table.txt" | tr -d ' ')
  seen=$(head -c 8192 "$EVD/wide-table.txt" | grep -cE '^ +(ia|perso|recherches|sport|tiny|wikilibriste) ')
  say "table : $bytes octets, $(wc -l < "$EVD/wide-table.txt" | tr -d ' ') lignes, $(grep -c ' running ' "$EVD/wide-table.txt") running, $(grep -c ' stopped ' "$EVD/wide-table.txt") stopped"
  say "profils actifs lisibles dans les 8 192 premiers octets parmi ia, perso, recherches, sport, tiny, wikilibriste : $seen sur 6"
  head -n 8 "$EVD/wide-table.txt"; echo "..."; tail -n 7 "$EVD/wide-table.txt"
  [ "$bytes" -gt 8192 ] && [ "$seen" = 0 ] || { echo "LANE 12 FAIL : la table doit dépasser 8 192 octets et perdre ces six profils actifs à 8 192 octets"; return 1; }
  "$HERE/netsample.sh" "$EVD/net-orb12.txt" "$STOP_ORB12" & local sampler=$!
  say "ancien code 525db18 (dd-old) : la lane doit échouer, la table est coupée à 8 192 octets"
  lane12_ui "$EVD/lane12/old" "$OLD_RUN"; local rc_old=$?
  say "ancien code : rc=$rc_old (non nul attendu) ; message du test :"
  grep -E "manque :|HV-BOTS" "$EVD/lane12/old/xcodebuild.log" | cut -c1-400 | head -3
  say "code de la tête : la lane doit passer, les neuf profils actifs, aucun profil stopped"
  lane12_ui "$EVD/lane12/head" "$HEAD_RUN"; local rc_head=$?
  touch "$STOP_ORB12"; wait "$sampler" 2>/dev/null
  export_shots "$EVD/lane12/head" hd08-wide-table || rc_head=1
  # le test compare des identifiants exacts : une ligne lue de travers (« hv-wide-profile-001 hv-fake-1 ») y échapperait, la lane cherche donc le préfixe
  local wide; wide=$(grep -E "^HV-BOTS orb" "$EVD/lane12/head/xcodebuild.log" | grep -c "hv-wide")
  say "lignes de bot affichées par la tête qui portent le préfixe hv-wide (profils stopped) : $wide (0 attendu)"
  local stopped; stopped=$(docker exec -u hermes -e HOME=/opt/data "$CT" hermes profile list | grep -c ' stopped ')
  say "profils stopped à la fin de la lane : $stopped (101 attendus : hv-old et les 100 hv-wide)"
  orb_down
  [ "$stopped" = 101 ] && [ $rc_old -ne 0 ] && grep -q "manque :" "$EVD/lane12/old/xcodebuild.log" && [ $rc_head -eq 0 ] && [ "$wide" = 0 ]
}

# lane 13 : de vrais noms affichés sur le vrai Hermes (défaut du vérificateur sur 940ba52 : « Cyber (cyber) » devenait l'identifiant, « Mon bot (hv-old) » arrêté devenait le bot « Mon »)
# Hermes écrit alors `nom affiché (identifiant)` (format_profile_label) ; la CLI 0.22.2 n'a aucune commande pour le nom affiché, la lane appelle la fonction officielle set_profile_display_name
# Les libellés couvrent : court (« Cyber (cyber) »), plus large que la colonne (« Wiki libriste (wikilibriste) »), parenthèses dans le nom, le mot running dans le nom, le profil par défaut (« ◆Moi (default) »), un profil arrêté (hv-old)
# L'ancien code (dd-prev, 940ba52) doit échouer sur cette lane, le code de la tête doit la passer
lane13_ui() { # lane13_ui <dossier> <xctestrun>
  TEST_RUNNER_HV_API_URL='' TEST_RUNNER_HV_SSH_HOST=$SSH_HOST TEST_RUNNER_HV_SSH_USER=hermes \
    TEST_RUNNER_HV_TEST_SSH_KEY=$HV_TEST_SSH_KEY TEST_RUNNER_HV_TEST_API_KEY=$HV_TEST_API_KEY \
    TEST_RUNNER_HV_EXPECT_BOTS=default,cyber,gaming,ia,perso,recherches,sport,tiny,wikilibriste \
    TEST_RUNNER_HV_EXPECT_ABSENT=hv-old,Mon TEST_RUNNER_HV_SHOT_NAME=hd08-display-names \
    TEST_RUNNER_HV_EXPECT_NAMES='default=Moi,cyber=Cyber,ia=Mon bot running,sport=Sport (beta),wikilibriste=Wiki libriste' \
    run_ui "$1" "$2" SixActions/testTheSeededProfilesOfTheOrbInstanceShowAndTheParkedOneDoesNot
}
lane13() {
  [ -n "$PREV_RUN" ] || { echo "LANE 13 FAIL : dd-prev manque (build-for-testing de 940ba52, extrait par git archive)"; return 1; }
  orb_up || return 1
  docker exec -u hermes -e HOME=/opt/data "$CT" python3 -c "
from hermes_cli.profiles import set_profile_display_name
for profile, name in [('default', 'Moi'), ('cyber', 'Cyber'), ('wikilibriste', 'Wiki libriste'), ('sport', 'Sport (beta)'), ('ia', 'Mon bot running'), ('hv-old', 'Mon bot')]:
    print('nom affiché de', profile, ':', set_profile_display_name(profile, name))" || return 1
  say "référence : hermes profile list dans le conteneur, noms affichés posés avec set_profile_display_name"
  docker exec -u hermes -e HOME=/opt/data "$CT" hermes profile list > "$EVD/names-table.txt" || return 1
  cat "$EVD/names-table.txt"
  grep -q '◆Moi (default)' "$EVD/names-table.txt" && grep -q 'Mon bot (hv-old) .* stopped' "$EVD/names-table.txt" || { echo "LANE 13 FAIL : la table ne montre pas les libellés attendus"; return 1; }
  "$HERE/netsample.sh" "$EVD/net-orb13.txt" "$STOP_ORB13" & local sampler=$!
  say "ancien code 940ba52 (dd-prev) : la lane doit échouer, « Cyber (cyber) » devient l'identifiant de la ligne"
  lane13_ui "$EVD/lane13/old" "$PREV_RUN"; local rc_old=$?
  say "ancien code : rc=$rc_old (non nul attendu) ; message du test :"
  grep -E "SixActions.swift:[0-9]+: error:|HV-BOTS" "$EVD/lane13/old/xcodebuild.log" | cut -c1-500 | head -3
  say "code de la tête : la lane doit passer, les neuf profils actifs par identifiant, les noms affichés, ni hv-old ni « Mon »"
  lane13_ui "$EVD/lane13/head" "$HEAD_RUN"; local rc_head=$?
  touch "$STOP_ORB13"; wait "$sampler" 2>/dev/null
  export_shots "$EVD/lane13/head" hd08-display-names || rc_head=1
  orb_down
  # l'ancien code échoue sur une assertion du test (la ligne `default` est absente, ou un identifiant manque), pas sur un autre défaut
  [ $rc_old -ne 0 ] && grep -qE "SixActions.swift:[0-9]+: error:.*(manque :|absent)" "$EVD/lane13/old/xcodebuild.log" && [ $rc_head -eq 0 ]
}

# lane 14 : un modèle à espaces et à parenthèses sur le vrai Hermes (défaut du vérificateur sur f8242b1 : « my (local) model » donnait l'identifiant « local » et les fils partaient vers /p/local/)
# La colonne Model de `hermes profile list` écrit le modèle tel que config.yaml le donne (coupé à 26) : la lane le pose avec la CLI officielle `hermes config set model.default`
# cyber a un nom affiché et gaming n'en a pas : les deux libellés du défaut (« Cyber (cyber) » et « gaming ») suivis du modèle
# L'ancien code (dd-prev2, f8242b1) doit échouer sur cette lane, le code de la tête doit la passer
lane14_ui() { # lane14_ui <dossier> <xctestrun>
  TEST_RUNNER_HV_API_URL='' TEST_RUNNER_HV_SSH_HOST=$SSH_HOST TEST_RUNNER_HV_SSH_USER=hermes \
    TEST_RUNNER_HV_TEST_SSH_KEY=$HV_TEST_SSH_KEY TEST_RUNNER_HV_TEST_API_KEY=$HV_TEST_API_KEY \
    TEST_RUNNER_HV_EXPECT_BOTS=default,cyber,gaming,ia,perso,recherches,sport,tiny,wikilibriste \
    TEST_RUNNER_HV_EXPECT_ABSENT=hv-old,local TEST_RUNNER_HV_SHOT_NAME=hd08-model-parens \
    TEST_RUNNER_HV_EXPECT_NAMES='cyber=Cyber,gaming=gaming' \
    TEST_RUNNER_HV_EXPECT_MODELS='cyber=my (local) model,gaming=my (local) model,ia=hv-fake-1' \
    run_ui "$1" "$2" SixActions/testTheSeededProfilesOfTheOrbInstanceShowAndTheParkedOneDoesNot
}
lane14() {
  [ -n "$PREV2_RUN" ] || { echo "LANE 14 FAIL : dd-prev2 manque (build-for-testing de f8242b1, extrait par git archive)"; return 1; }
  orb_up || return 1
  docker exec -u hermes -e HOME=/opt/data "$CT" python3 -c "
from hermes_cli.profiles import set_profile_display_name
print('nom affiché de cyber :', set_profile_display_name('cyber', 'Cyber'))" || return 1
  local profile
  for profile in cyber gaming; do
    docker exec -u hermes -e HOME=/opt/data "$CT" hermes -p "$profile" config set model.default "my (local) model" || return 1
  done
  say "référence : hermes profile list dans le conteneur, modèle « my (local) model » posé sur cyber (nom affiché Cyber) et gaming"
  docker exec -u hermes -e HOME=/opt/data "$CT" hermes profile list > "$EVD/model-table.txt" || return 1
  cat "$EVD/model-table.txt"
  grep -q 'Cyber (cyber) .* my (local) model .* running' "$EVD/model-table.txt" && grep -q ' gaming .* my (local) model .* running' "$EVD/model-table.txt" || { echo "LANE 14 FAIL : la table ne montre pas les libellés et les modèles attendus"; return 1; }
  "$HERE/netsample.sh" "$EVD/net-orb14.txt" "$STOP_ORB14" & local sampler=$!
  say "ancien code f8242b1 (dd-prev2) : la lane doit échouer, « my (local) model » donne l'identifiant « local » à cyber et à gaming"
  lane14_ui "$EVD/lane14/old" "$PREV2_RUN"; local rc_old=$?
  say "ancien code : rc=$rc_old (non nul attendu) ; message du test :"
  grep -E "SixActions.swift:[0-9]+: error:|HV-BOTS" "$EVD/lane14/old/xcodebuild.log" | cut -c1-500 | head -3
  say "code de la tête : la lane doit passer, cyber et gaming par identifiant, leur modèle entier, ni hv-old ni « local »"
  lane14_ui "$EVD/lane14/head" "$HEAD_RUN"; local rc_head=$?
  touch "$STOP_ORB14"; wait "$sampler" 2>/dev/null
  export_shots "$EVD/lane14/head" hd08-model-parens || rc_head=1
  orb_down
  # l'ancien code échoue sur une assertion du test (cyber et gaming manquent), pas sur un autre défaut
  [ $rc_old -ne 0 ] && grep -qE "SixActions.swift:[0-9]+: error:.*manque :" "$EVD/lane14/old/xcodebuild.log" && [ $rc_head -eq 0 ]
}

lane "lane 1 trunk contre head" lane1
lane "lane 2 aucun profil décommissionné" lane2
lane "lane 3 fils d'un bot" lane3
lane "lane 4 mode fields" lane4
lane "lane 5 liste vide" lane5
lane "lane 6 noms longs" lane6
lane "lane 7 changement de liste" lane7
lane "lane 9 list_sessions supprimée" lane9
# sonde de la lane 10 : l'app lancée à la main contre un serveur lent garde sa connexion ouverte, donc lsof et hv-netwatch.sh la voient
netprobe() {
  fake_up base slow || return 1
  local app="$HVW/dd/Build/Products/Debug/HermedBots.app/Contents/MacOS/HermedBots"
  HV_TEST_MODE=1 HV_API_URL=$URL "$app" -AppleLanguages "(fr)" > "$EVD/netprobe-app.log" 2>&1 &
  local pid=$!
  say "app lancée à la main (pid $pid) contre un serveur lent : GET /health met 8 s à répondre, la connexion reste ouverte"
  sleep 1.5
  "$SK/hv-netwatch.sh" "$pid" 6 "$EVD/netprobe-lsof.txt" "$PORT"; local rc=$?
  kill -TERM "$pid"; wait "$pid" 2>/dev/null
  say "connexions vues par lsof sur l'app (pid $pid), avec leur nombre d'échantillons :"
  awk '{print $1, $9, $10}' "$EVD/netprobe-lsof.txt" | sort | uniq -c
  [ "$(wc -l < "$EVD/netprobe-lsof.txt" | tr -d ' ')" -gt 0 ] || { echo "SONDE VIDE : lsof n'a vu aucune connexion, la sonde ne prouve rien"; return 1; }
  return $rc
}

# l'échantillonneur du faux serveur s'arrête avant la lane 8 : le ssh de cette lane va au conteneur et a son propre échantillonneur
touch "$STOP_FAKE"; wait "$SAMPLER" 2>/dev/null
lane "lane 10 sonde réseau, serveur lent" netprobe
lane "lane 8 instance OrbStack" lane8
lane "lane 11 pagination, 201 fils sur Hermes réel" lane11
lane "lane 12 table de plus de 8 Kio par ssh" lane12
lane "lane 13 noms affichés par ssh" lane13
lane "lane 14 modèle à parenthèses par ssh" lane14

echo; echo "================ lane 10, fin"
peers() { grep -oE -- '->[^ ]+' "$1" | sed 's/^->//' | sort | uniq -c | sort -rn; }
say "lanes 1 à 7 et 9 (faux serveur) : $(wc -l < "$EVD/net-fake.txt" | tr -d ' ') sockets vus par lsof (échantillon toutes les 0,3 s sur l'app et ses enfants), destinations avec leur nombre d'échantillons :"
peers "$EVD/net-fake.txt"
others=$(peers "$EVD/net-fake.txt" | awk '$2 != "127.0.0.1:18642"')
say "destinations autres que $URL : ${others:-aucune}"
say "limite : une requête loopback dure quelques millisecondes et échappe souvent à lsof ; la preuve que les requêtes de l'app atteignent bien le serveur est son journal (lanes 1, 3 et 9), la preuve qu'elles n'atteignent rien d'autre est ce balayage, hv-netwatch.sh (lane 1) et les sites d'appel réseau du code :"
grep -rnE "URLSession|HermesClient\(|URLRequest|NWConnection|CFStream|URL\(string" "$REPO/HermedBots" --include='*.swift' | sed "s#$REPO/##" | cut -c1-170
CONTAINER_IP=$(python3 -I -c "import socket; print(socket.gethostbyname('$SSH_HOST'))" 2>/dev/null)
cat "$EVD/net-orb.txt" "$EVD/net-orb12.txt" "$EVD/net-orb13.txt" "$EVD/net-orb14.txt" > "$EVD/net-orb-all.txt" 2>/dev/null
say "lanes 8 et 12 à 14 (instance OrbStack) : $(wc -l < "$EVD/net-orb-all.txt" | tr -d ' ') sockets vus, le ssh va au conteneur $CONTAINER_IP:22 :"
peers "$EVD/net-orb-all.txt"
orb_others=$(peers "$EVD/net-orb-all.txt" | awk -v ip="$CONTAINER_IP" '$2 != ip":22" && $2 !~ /^127\.0\.0\.1:/')
say "destinations des lanes 8 et 12 à 14 hors tunnel ($CONTAINER_IP:22) et hors boucle locale : ${orb_others:-aucune}"
"$SK/hv-guard.sh" check "$EVD/guard-before.txt"; g=$?
results+=("guard-check=$g")
echo "hv-guard.sh check : code $g"
[ -z "$others" ] && [ -z "$orb_others" ] && results+=("net=0") || results+=("net=1")
echo; echo "RÉSUMÉ : ${results[*]}"
for r in "${results[@]}"; do [ "${r#*=}" = 0 ] || { echo "RESULT FAIL"; exit 1; }; done
echo "RESULT OK"
