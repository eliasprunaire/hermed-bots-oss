#!/usr/bin/env bash
# hv-hermes-env.sh — Hermes jetable dans un conteneur OrbStack, ou faux serveur
# Modèle : aucun (script)
# Usage :
#   hv-hermes-env.sh up      [orb|fake]   # crée + amorce ; écrit $HV_EVIDENCE/env.json
#   hv-hermes-env.sh doctor  [orb|fake]   # lecture seule
#   hv-hermes-env.sh down    [orb|fake]   # détruit ce que up a créé (pas les preuves)
# Variables : HV_TEST_API_KEY (secret, obligatoire en mode orb, jamais écrit sur le disque du Mac),
#   HV_CONTAINER (défaut hv-hermes-test), HV_PORT (défaut 18642, côté Mac),
#   HV_HERMES_IMAGE (défaut hv-hermes:spike, reconstruite à chaque up avec la base latest tirée ; une image fournie n'est construite que si absente),
#   HV_FAKE_VERSION (défaut current), HV_FAKE_MODE (normal|slow|down|drop-route|fields)
# Codes : 0 OK ; 2 usage ; 30 OrbStack absent ; 31 montage interdit détecté ;
#         32 secret absent ou de moins de 16 caractères ; 33 Hermes pas prêt ; 34 faux serveur pas prêt ; 35 build de l'image impossible
# Relais de port (mode orb) : Hermes écoute sur 0.0.0.0:8642 DANS le conteneur et docker publie ce port
# sur 127.0.0.1:$HV_PORT du Mac seulement. Ni socat ni tunnel
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CT=${HV_CONTAINER:-hv-hermes-test}
PORT=${HV_PORT:-18642}
EVD=${HV_EVIDENCE:-/tmp/hv-evidence}
mkdir -p "$EVD"
cmd=${1:-}; mode=${2:-${HV_MODE:-orb}}

"$HERE/hv-guard.sh" target "$CT" >/dev/null

_mounts_ok() { # aucun montage hôte : ni bind, ni ~/.hermes, ni ~/.local/bin (le volume anonyme de l'image reste interne)
  local m
  m=$(docker inspect -f '{{range .Mounts}}{{.Type}} {{.Source}}{{"\n"}}{{end}}' "$CT" 2>/dev/null || true)
  if printf '%s\n' "$m" | grep -Eq '(^bind |/\.hermes|/\.local/bin)'; then
    echo "ENV FAIL (31): montage interdit sur $CT :" >&2; printf '%s\n' "$m" >&2; return 31
  fi
  # OrbStack monte aussi /Users dans ses machines Linux ; on exige un conteneur docker, pas une machine orb
}

_ready() { # readiness=ok sur /health/detailed (authentifié) ; "degraded" est transitoire au démarrage (gateway starting)
  printf 'header = "Authorization: Bearer %s"\n' "$HV_TEST_API_KEY" |
    curl -fsS -m 3 -K - "http://127.0.0.1:${PORT}/health/detailed" 2>/dev/null | grep -q '"readiness": {"status": "ok"'
}

_version() { curl -fsS -m 2 "http://127.0.0.1:${PORT}/health" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p'; }

_profiles_ok() { # les profils de test répondent par le préfixe /p/<profil>/ (clé par stdin, jamais en argument)
  local p
  for p in hv-bot-a hv-bot-b; do
    printf 'header = "Authorization: Bearer %s"\n' "$HV_TEST_API_KEY" |
      curl -fsS -m 3 -K - "http://127.0.0.1:${PORT}/p/${p}/v1/models" >/dev/null 2>&1 || return 1
  done
}

case "$mode:$cmd" in
  orb:up)
    if ! command -v orb >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then { echo "ENV FAIL (30): OrbStack absent, utiliser le mode fake" >&2; exit 30; }; fi
    key=${HV_TEST_API_KEY:-}
    [ "${#key}" -ge 16 ] || { echo "ENV FAIL (32): HV_TEST_API_KEY absent ou de moins de 16 caractères (Hermes refuse de démarrer sinon)" >&2; exit 32; }
    IMG=${HV_HERMES_IMAGE:-hv-hermes:spike}
    if [ -n "$(docker ps -aq --filter "name=^${CT}$")" ]; then { echo "ENV FAIL (33): le conteneur $CT existe déjà, lancer down orb" >&2; exit 33; }; fi
    # Q11 : latest. L'image par défaut se reconstruit à chaque passe, base tirée (--pull) : une nouvelle release upstream est prise
    # Une image fournie par HV_HERMES_IMAGE n'est construite que si elle manque. La version testée sort de /health (env.json)
    if [ -z "${HV_HERMES_IMAGE:-}" ] || ! docker image inspect "$IMG" >/dev/null 2>&1; then
      docker build -q --pull -t "$IMG" "$HERE/../orb" >/dev/null || { echo "ENV FAIL (35): build de $IMG impossible (base nousresearch/hermes-agent:latest non tirée)" >&2; exit 35; }
    fi
    # Aucun -v / --mount : le volume anonyme de l'image reste interne. Port publié sur 127.0.0.1 du Mac seulement
    # La clé passe par l'environnement du processus (--env NOM sans valeur), jamais en argument ni en fichier
    docker run -d --name "$CT" --label hv.owner=verify-hermed-bots \
      -p "127.0.0.1:${PORT}:8642" --env HV_TEST_API_KEY "$IMG" >/dev/null
    if ! _mounts_ok; then docker rm -f -v "$CT" >/dev/null 2>&1 || true; exit 31; fi
    for _ in $(seq 1 90); do
      [ "$(docker inspect -f '{{.State.Running}}' "$CT" 2>/dev/null)" = true ] || break
      if _ready && _profiles_ok; then
        ver=$(_version)
        printf '{"mode":"orb","container":"%s","url":"http://127.0.0.1:%s","version":"%s"}\n' "$CT" "$PORT" "$ver" > "$EVD/env.json"; echo "ENV OK orb (Hermes ${ver:-?})"; exit 0
      fi; sleep 1
    done
    docker logs --tail 15 "$CT" 2>&1 | sed -E 's/(API_SERVER_KEY[=:] *)[^ ]+/\1****/' >> "$EVD/env.log" || true
    echo "ENV FAIL (33): Hermes pas prêt (voir $EVD/env.log)" >&2; exit 33 ;;
  orb:doctor)
    echo "container=$CT running=$(docker inspect -f '{{.State.Running}}' "$CT")"
    echo "hv.owner=$(docker inspect -f '{{index .Config.Labels "hv.owner"}}' "$CT")"
    _mounts_ok
    echo "mounts: aucun montage hôte (volume anonyme interne de l'image seulement)"
    docker exec "$CT" sh -c 'test ! -e /proc/1/root/Users' || echo "WARN: /Users visible dans le conteneur" >&2
    : "${HV_TEST_API_KEY:?HV_TEST_API_KEY absent}"
    _ready || { echo "ENV FAIL (33): API pas prête (readiness différent de ok sur /health/detailed)" >&2; exit 33; }
    echo "api: readiness=ok hermes=$(_version)"
    _profiles_ok || { echo "ENV FAIL (33): hv-bot-a ou hv-bot-b ne répond pas par /p/<profil>/" >&2; exit 33; }
    echo "profils: hv-bot-a hv-bot-b répondent par /p/<profil>/" ;;
  orb:down)
    # Ne supprime que le conteneur portant notre label
    if [ "$(docker inspect -f '{{index .Config.Labels "hv.owner"}}' "$CT" 2>/dev/null || true)" = verify-hermed-bots ]; then
      docker rm -f -v "$CT" >/dev/null; echo "ENV down orb"
    else echo "ENV: rien à détruire (ou conteneur non créé par nous)"; fi ;;
  fake:up)
    python3 "$HERE/hv-fake-hermes.py" --port "$PORT" --version "${HV_FAKE_VERSION:-current}" \
      --mode "${HV_FAKE_MODE:-normal}" --fixtures "$HERE/../fixtures" > "$EVD/fake-server.log" 2>&1 &
    echo $! > "$EVD/fake-server.pid"
    for _ in $(seq 1 25); do
      if curl -fsS -m 1 "http://127.0.0.1:${PORT}/_hv/ready" >/dev/null 2>&1; then
        printf '{"mode":"fake","version":"%s","url":"http://127.0.0.1:%s"}\n' "${HV_FAKE_VERSION:-current}" "$PORT" > "$EVD/env.json"; echo "ENV OK fake"; exit 0
      fi; sleep 0.2
    done
    echo "ENV FAIL (34): faux serveur pas prêt" >&2; exit 34 ;;
  fake:doctor) curl -fsS -m 2 "http://127.0.0.1:${PORT}/_hv/ready" ;;
  fake:down)
    if [ -f "$EVD/fake-server.pid" ]; then kill "$(cat "$EVD/fake-server.pid")" 2>/dev/null || true; rm -f "$EVD/fake-server.pid"; fi
    echo "ENV down fake" ;;
  *) echo "usage: $0 {up|doctor|down} [orb|fake]" >&2; exit 2 ;;
esac
