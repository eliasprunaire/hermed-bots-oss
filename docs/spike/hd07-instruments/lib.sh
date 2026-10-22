# source ce fichier : variables et fonctions communes des lanes HD-07
# Les lanes tournent sur le Mac contre hv-hermes-test seulement ; /usr/bin/ssh n'est lancé que par l'app, vers ce conteneur
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
HVW=${HV_WORK:-$HOME/hermed-bots-work}
SK=$REPO/.cursor/skills/verify-hermed-bots/scripts
ENDPOINT=$HERE/hv-ssh-endpoint.sh
APPD=${APPD:-$HVW/dd/Build/Products/Debug/HermedBots.app/Contents/MacOS/HermedBots}
# dossier de la clé de test : chemin fixe, créé puis supprimé dans la même fonction, hors de tout dossier de preuves
KEYDIR=$HVW/hd07-key
SSH_HOST=host.example
export PATH="$PATH:/usr/sbin"

say() { printf '[%s Paris] %s\n' "$(TZ=Europe/Paris date +%H:%M:%S)" "$*"; }
# affiche la commande puis son résultat ; ne propage pas le code (il est imprimé)
cmd() { printf '$ %s\n' "$*"; "$@"; local rc=$?; printf 'rc=%s\n' "$rc"; return 0; }

# new_keys : exporte HV_TEST_SSH_KEY (clé acceptée par le conteneur) et HV_TEST_SSH_WRONG_KEY (clé jamais installée), sans les montrer
# les deux clés privées ne vivent sur le disque que le temps de cette fonction ; la clé publique de la bonne est installée pour hvssh
new_keys() {
  mkdir -m 700 "$KEYDIR" || return 1
  /usr/bin/ssh-keygen -q -t ed25519 -N '' -C hv-hd07 -f "$KEYDIR/good" && /usr/bin/ssh-keygen -q -t ed25519 -N '' -C hv-hd07-wrong -f "$KEYDIR/bad" || return 1
  "$ENDPOINT" authorize < "$KEYDIR/good.pub"
  HV_TEST_SSH_KEY=$(cat "$KEYDIR/good"); HV_TEST_SSH_WRONG_KEY=$(cat "$KEYDIR/bad")
  export HV_TEST_SSH_KEY HV_TEST_SSH_WRONG_KEY
  trash "$KEYDIR"
}

# start_app [LOG] : lance l'app en mode test avec le tunnel ; APP_PID reçoit son pid
# HV_SSH_HOST / HV_SSH_USER viennent de l'appelant, avec des valeurs par défaut vers le conteneur
start_app() {
  HV_TEST_MODE=1 HV_SSH_HOST=${HV_SSH_HOST:-$SSH_HOST} HV_SSH_USER=${HV_SSH_USER:-hvssh} HV_TEST_SSH_KEY=${HV_TEST_SSH_KEY:-} \
    "$APPD" -AppleLanguages "(${LANG_APP:-fr})" > "${1:-/dev/null}" 2>&1 &
  APP_PID=$!
}
stop_app() { kill -TERM "$1" 2>/dev/null; for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.5; done; kill -KILL "$1" 2>/dev/null; }

# lignes ps (pid ppid pgid args) des enfants directs de l'app
app_children() { ps -Ao pid,ppid,pgid,args | awk -v a="$1" '$2==a'; }
# pid du ssh enfant de l'app
ssh_child() { app_children "$1" | awk '$4=="/usr/bin/ssh"{print $1; exit}'; }
# le port local du tunnel, lu dans l'argument -L du ssh
tunnel_port() { ps -o args= -p "$1" | sed -n 's/.* -L 127.0.0.1:\([0-9]*\):.*/\1/p'; }

# capture de la fenêtre de l'app : window_png PID sortie.png
# winid est compilé une fois : l'interpréteur `swift` recompile le script à chaque appel
window_png() {
  local id winid=$HVW/hd07-winid
  [ "$winid" -nt "$HERE/winid.swift" ] || swiftc -O "$HERE/winid.swift" -o "$winid" || return 1
  id=$("$winid" "$1" 10) || { echo "NO WINDOW pid=$1"; return 1; }
  sleep 0.8  # laisse SwiftUI finir son rendu
  /usr/sbin/screencapture -x -o -l"$id" "$2"
}

# sshd du conteneur : nombre de refus de clé publique depuis le début du journal
sshd_failures() { "$ENDPOINT" log | grep -c "Failed publickey" || true; }
sshd_accepts() { "$ENDPOINT" log | grep -c "Accepted publickey" || true; }
