# Script de publication : publication du verdict et réessai passager du lanceur (sourcé par le lanceur, 2026-10-22, issue #62)
# Copie de référence testée par test/runner-publish.test.js ; la copie active vit dans le dossier local du lanceur (hors dépôt).
# Attend : R, S, NAME, REPO, LOG et les fonctions log et notify (script de notification) et gh_post (script d'appel GitHub, règle 13)
typeset -f gh_post >/dev/null 2>&1 || source "$R/gh-post.sh"

valid_verdict(){ # $1 fichier $2 sha -> 0 si la 1re ligne est « VERDICT: … @ sha » et que le marqueur est présent
  head -1 "$1" 2>/dev/null | grep -qE "^VERDICT: (PASS|PASS\+NOTES|FAIL) @ $2$" && grep -q '<!-- dev-lead-verifier -->' "$1" 2>/dev/null; }

transient_retry(){ # $1 pr $2 sha $3 type d'alerte $4 détail ; pose $S/$2.transient-until (délai 120 s x 2^(n-1), plafond 1800 s) ; renvoie tn et dl
  tn=$(( $(cat "$S/$2.transient" 2>/dev/null || echo 0)+1 )); print $tn > "$S/$2.transient"
  if [ $tn -ge 5 ]; then dl=1800; else dl=$(( 120 * (1 << (tn-1)) )); fi; # plafond posé avant le décalage : 1 << 63 déborde
  print $(( $(date +%s)+dl )) > "$S/$2.transient-until"
  [ $tn -ge 3 ] && notify "$REPO" "$3" "$1" "" "$2" "$4 ($tn échecs de suite)"
  return 0; }

publish_verdict(){ # $1 pr $2 sha $3 fichier verdict -> 0 publié ; 1 erreur passagère (jeton ou API), réessai posé, fichier gardé ; exit 1 si le commentaire n'a pas l'auteur de l'app
  local vt res rc
  vt=$("$R/app-token.sh" 2>/dev/null) || { transient_retry $1 $2 token-transient "PR #$1 : jeton app indisponible, verdict non publié @ $2"
    log "PR #$1 jeton app indisponible (erreur passagère n°$tn), publication du verdict retentée dans $((dl/60)) min"; return 1; }
  res=$(GH_TOKEN=$vt gh_post api repos/$REPO/issues/$1/comments -F body=@"$3" -q '"\(.id) \(.user.login)"' 2>>"$LOG"); rc=$?; unset vt
  if [ $rc -ne 0 ] || [ -z "$res" ]; then transient_retry $1 $2 token-transient "PR #$1 : publication du verdict refusée par l'API @ $2"
    log "PR #$1 publication du verdict en échec côté API (rc=$rc, erreur passagère n°$tn), nouvel essai dans $((dl/60)) min"; return 1; fi
  if [ "${res#* }" != "app-pilote-verifier[bot]" ]; then
    gh api -X DELETE repos/$REPO/issues/comments/${res%% *} 2>/dev/null
    log "STOP verdict non publié sous l'app (auteur=${res#* }), PAUSE-$NAME posé"; touch "$R/PAUSE-$NAME"
    notify "$REPO" paused "$1" "" "$2" "PR #$1 : verdict publié par ${res#* } et non par l'app, PAUSE-$NAME posé @ $2"; exit 1; fi
  touch "$S/$2.posted"; rm -f "$S/$2.transient" "$S/$2.transient-until"
  log "PR #$1 verdict publié par l'app : $(head -1 "$3")"; }
