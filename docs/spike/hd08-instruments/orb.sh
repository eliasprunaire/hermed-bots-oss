# shellcheck shell=bash
# source ce fichier après lib.sh : orb_up et orb_down, l'instance hv-hermes-test avec un sshd pour l'utilisateur hermes (HD-08, lane 8)
# L'image hv-hermes:hd07 (HD-07) a déjà un sshd, mais son utilisateur hvssh ne lit pas /opt/data (0700 hermes) et lirait une autre liste de profils
# Ici l'utilisateur du ssh est hermes, celui qui possède l'installation, comme sur une VM réelle ; la config n'existe que dans le conteneur
# Aucun montage : hv-hermes-env.sh refuse tout montage de l'hôte (code 31)
# orb_up exporte HV_TEST_API_KEY et HV_TEST_SSH_KEY sans les afficher ; l'appelant les transmet à XCUITest par TEST_RUNNER_*
KEYDIR=$HVW/hd08-key

orb_up() {
  "$SK/hv-guard.sh" target "$CT" >/dev/null || return $?
  [ -n "$(docker image ls -q hv-hermes:hd07)" ] || { echo "ORB FAIL : l'image hv-hermes:hd07 manque (docs/spike/hd07-instruments/hv-ssh-endpoint.sh la construit)"; return 1; }
  # un conteneur laissé par une passe précédente : hv-hermes-env.sh ne détruit que celui qui porte notre label
  HV_EVIDENCE=${EVD:-/tmp} "$SK/hv-hermes-env.sh" down orb
  HV_TEST_API_KEY=$(openssl rand -hex 16); export HV_TEST_API_KEY
  HV_HERMES_IMAGE=hv-hermes:hd07 HV_EVIDENCE=${EVD:-/tmp} "$SK/hv-hermes-env.sh" up orb || return $?
  docker exec -i -u root "$CT" sh -c 'cat > /etc/ssh/sshd_config.d/hv.conf' < "$HERE/sshd-hermes.conf" || return 1
  docker exec -u root "$CT" sh -c 'ln -sf /opt/hermes/bin/hermes /usr/local/bin/hermes && install -d -o hermes -g hermes -m 0700 /opt/data/.ssh && /usr/sbin/sshd -t' || return 1
  docker exec -u root -d "$CT" /usr/sbin/sshd -D -E /var/log/hv-sshd.log
  mkdir -m 700 "$KEYDIR" || return 1
  /usr/bin/ssh-keygen -q -t ed25519 -N '' -C hv-hd08 -f "$KEYDIR/good" || return 1
  docker exec -i -u root "$CT" sh -c 'cat > /opt/data/.ssh/authorized_keys && chown hermes:hermes /opt/data/.ssh/authorized_keys && chmod 600 /opt/data/.ssh/authorized_keys' < "$KEYDIR/good.pub" || return 1
  HV_TEST_SSH_KEY=$(cat "$KEYDIR/good"); export HV_TEST_SSH_KEY
  trash "$KEYDIR"
  for _ in $(seq 1 30); do nc -z -w 1 "$SSH_HOST" 22 2>/dev/null && { say "SSH OK $SSH_HOST:22 user=hermes"; return 0; }; sleep 1; done
  echo "ORB FAIL : $SSH_HOST:22 injoignable depuis le Mac"; return 1
}

orb_down() { HV_EVIDENCE=${EVD:-/tmp} "$SK/hv-hermes-env.sh" down orb; }
