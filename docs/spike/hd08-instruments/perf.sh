#!/usr/bin/env bash
# perf.sh <dossier-de-preuves> : la perf de HD-08, au trunk puis au head, contre le faux serveur de la fixture perf
# Fixture perf : les neuf profils actifs du PRD, 200 fils par bot. Le faux serveur tourne sur 127.0.0.1:18642 (le conteneur hv-hermes-test ne doit pas tourner)
# Baseline : au trunk la liste est vide (LaunchTests), il n'y a donc rien à chronométrer ; les deux budgets sont absolus
# Sonde : BotsPerfProbe par XCUITest, cinq lancements à froid jusqu'à ce que les neuf lignes soient visibles, cinq dépliages d'un bot de 200 fils
# Règle : échec quand la médiane du lancement dépasse 1,5 s ou la médiane du dépli dépasse 500 ms (budgets proposés par le plan)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$HERE/orb.sh"
EVD=${1:?usage: perf.sh <dossier-de-preuves>}
mkdir -p "$EVD"; export EVD
HEAD_RUN=$(xctestrun dd); TRUNK_RUN=$(xctestrun dd-trunk)
python3 "$HERE/mk-fixtures.py" "$FIXDIR" > /dev/null
trap 'fake_down' EXIT
say "tête de code $(git -C "$REPO" rev-parse --short HEAD), trunk $(git -C "$HVW/trunk-wt" rev-parse --short HEAD), $(sw_vers -productName) $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string)"
# un conteneur d'une passe précédente publie 18642 : il part (seul celui qui porte notre label)
orb_down
fake_up perf normal || exit 1
say "le serveur annonce $(curl -fsS "$URL/_hv/profile-list" | awk 'NF >= 3 && $1 != "Profile" && $1 !~ /─/' | wc -l | tr -d ' ') profils actifs et $(curl -fsS "$URL/p/cyber/api/sessions" | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)["data"]))') fils pour cyber"
echo "================ baseline : trunk"
run_ui "$EVD/trunk" "$TRUNK_RUN" LaunchTests/testWindowOpensWithTheServerVersionAndAnEmptyBotList; rc_t=$?
say "baseline trunk rc=$rc_t : la liste est vide, aucune ligne à chronométrer"
echo "================ head : lancement jusqu'aux neuf lignes"
TEST_RUNNER_HV_EXPECT_BOT_COUNT=9 run_ui "$EVD/head-launch" "$HEAD_RUN" BotsPerfProbe/testLaunchToEveryBotRowVisible; rc_l=$?
echo "================ head : dépli d'un bot de 200 fils"
TEST_RUNNER_HV_EXPAND_BOT=cyber TEST_RUNNER_HV_EXPECT_LAST_THREAD=s-t-200 run_ui "$EVD/head-expand" "$HEAD_RUN" BotsPerfProbe/testExpandingABotWithTwoHundredThreads; rc_e=$?
echo "================ verdict"
grep -h "HV-PERF08 .* median_ms" "$EVD/head-launch/xcodebuild.log" "$EVD/head-expand/xcodebuild.log" | sort -u
say "rc trunk=$rc_t lancement=$rc_l dépli=$rc_e"
if [ $rc_t -eq 0 ] && [ $rc_l -eq 0 ] && [ $rc_e -eq 0 ]; then say "RESULT OK : médianes sous 1500 ms et 500 ms"; exit 0; fi
say "RESULT FAIL"; exit 1
