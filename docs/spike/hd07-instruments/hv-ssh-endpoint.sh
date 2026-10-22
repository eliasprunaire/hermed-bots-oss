#!/usr/bin/env bash
# hv-ssh-endpoint.sh, un sshd dans hv-hermes-test pour les lanes du tunnel (HD-07). Modèle : aucun (script)
# Usage :
#   hv-ssh-endpoint.sh up          # lance hv-hermes-test (image hv-hermes:hd07), démarre sshd, imprime l'hôte et le port SSH
#   hv-ssh-endpoint.sh authorize   # lit une clé publique sur stdin et l'installe pour l'utilisateur hvssh
#   hv-ssh-endpoint.sh log         # journal sshd du conteneur
#   hv-ssh-endpoint.sh down        # supprime le conteneur (seulement s'il porte notre label)
# La clé d'API du conteneur est tirée au hasard ici et ne sort jamais du script
# Aucun port 22 n'est publié sur le Mac : OrbStack route le nom <conteneur>.host.example vers le conteneur
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SK=$HERE/../../../.cursor/skills/verify-hermed-bots/scripts
CT=hv-hermes-test
IMAGE=hv-hermes:hd07
HOST=$host.example

case "${1:-}" in
  up)
    "$SK/hv-guard.sh" target "$CT" >/dev/null
    [ -n "$(docker image ls -q "$IMAGE")" ] || docker build -q -t "$IMAGE" "$HERE" >/dev/null
    HV_TEST_API_KEY=$(openssl rand -hex 16) HV_HERMES_IMAGE=$IMAGE HV_EVIDENCE=${HV_EVIDENCE:-/tmp/hv-evidence} "$SK/hv-hermes-env.sh" up orb
    docker exec -u root -d "$CT" /usr/sbin/sshd -D -E /var/log/hv-sshd.log
    for _ in $(seq 1 30); do
      nc -z -w 1 "$HOST" 22 2>/dev/null && { echo "SSH OK $HOST:22 user=hvssh"; exit 0; }
      sleep 1
    done
    echo "SSH FAIL: $HOST:22 injoignable depuis le Mac" >&2; exit 1 ;;
  authorize)
    docker exec -i -u root "$CT" sh -c 'cat > /.ssh/authorized_keys && chown hvssh:hvssh /.ssh/authorized_keys && chmod 600 /.ssh/authorized_keys' ;;
  log) docker exec -u root "$CT" cat /var/log/hv-sshd.log ;;
  down) HV_EVIDENCE=${HV_EVIDENCE:-/tmp/hv-evidence} "$SK/hv-hermes-env.sh" down orb ;;
  *) sed -n '2,9p' "$0" >&2; exit 2 ;;
esac
