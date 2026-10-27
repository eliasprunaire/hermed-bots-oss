# source ce fichier : variables et fonctions communes des lanes HD-07
# Les lanes tournent sur le Mac contre hv-hermes-test seulement ; /usr/bin/ssh n'est lancé que par l'app, vers ce conteneur
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
HVW=${HV_WORK:-$HOME/hermed-bots-work}
SK=$REPO/.cursor/skills/verify-hermed-bots/scripts
ENDPOINT=$HERE/hv-ssh-endpoint.sh
APPD=${APPD:-$HVW/dd/Build/Products/Debug/HermedBots.app/Contents/MacOS/HermedBots}
# dossier des clés de test : chemin fixe, hors de tout dossier de preuves, supprimé par drop_alias
KEYDIR=$HVW/hd07-key
SSH_HOST=host.example
: "${HV_FORBIDDEN_HOST:=example-host.invalid}"
export HV_FORBIDDEN_HOST
# alias de la config OpenSSH écrits par new_alias : le premier est accepté par le conteneur, le second jamais (sa clé n'est pas installée)
SSH_ALIAS=hv-hd07
SSH_ALIAS_REFUSED=hv-hd07-refused
SSH_CONFIG=$HOME/.ssh/config
export PATH="$PATH:/usr/sbin"

say() { printf '[%s Paris] %s\n' "$(TZ=Europe/Paris date +%H:%M:%S)" "$*"; }
# affiche la commande puis son résultat ; ne propage pas le code (il est imprimé)
cmd() { printf '$ %s\n' "$*"; "$@"; local rc=$?; printf 'rc=%s\n' "$rc"; return 0; }

# alias_block <alias> <fichier-de-clé> : un bloc Host vers le conteneur, identité de fichier seule, sans agent
alias_block() {
  cat <<EOF
Host $1
  HostName $SSH_HOST
  User hvssh
  IdentityFile $2
  IdentitiesOnly yes
  IdentityAgent none
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $KEYDIR/known_hosts
EOF
}

# new_alias : l'app lit l'identité dans la config OpenSSH du compte qui la lance (ssh -G, ni -F ni -i) : la lane crée un alias et une clé éphémères
# deux clés ed25519 dans $KEYDIR (700), dont la publique de la bonne est installée pour hvssh ; $KEYDIR/config nomme $SSH_ALIAS et $SSH_ALIAS_REFUSED
# ~/.ssh/config reçoit en tête `# hv-hd07 begin`, `Include $KEYDIR/config`, `# hv-hd07 end` ; drop_alias retire ce bloc et les clés
# l'appelant qui crée l'alias le retire : un script lancé par lui voit HV_ALIAS_READY et ne crée ni ne retire rien
new_alias() {
  [ -z "${HV_ALIAS_READY:-}" ] || return 0
  if grep -qs '^# hv-hd07 begin$' "$SSH_CONFIG"; then echo "bloc hv-hd07 déjà dans $SSH_CONFIG : une lane précédente s'est arrêtée sans drop_alias" >&2; return 1; fi
  if [ -L "$SSH_CONFIG" ] && [ ! -e "$SSH_CONFIG" ]; then echo "$SSH_CONFIG est un lien symbolique sans cible : bloc hv-hd07 non écrit" >&2; return 1; fi
  mkdir -m 700 "$KEYDIR" || return 1
  /usr/bin/ssh-keygen -q -t ed25519 -N '' -C hv-hd07 -f "$KEYDIR/good" && /usr/bin/ssh-keygen -q -t ed25519 -N '' -C hv-hd07-wrong -f "$KEYDIR/bad" \
    && { alias_block "$SSH_ALIAS" "$KEYDIR/good"; alias_block "$SSH_ALIAS_REFUSED" "$KEYDIR/bad"; } > "$KEYDIR/config" \
    && "$ENDPOINT" authorize < "$KEYDIR/good.pub" \
    && { [ -d "$(dirname "$SSH_CONFIG")" ] || mkdir -m 700 "$(dirname "$SSH_CONFIG")"; } || { trash "$KEYDIR"; return 1; }
  [ -e "$SSH_CONFIG" ] && : > "$KEYDIR/had-config"
  # une config illisible arrête la fonction avant toute écriture : sinon le bloc remplacerait le contenu
  { printf '# hv-hd07 begin\nInclude %s\n# hv-hd07 end\n' "$KEYDIR/config"; if [ -e "$SSH_CONFIG" ]; then cat "$SSH_CONFIG"; fi; } > "$KEYDIR/config.new" \
    || { echo "$SSH_CONFIG est illisible : bloc hv-hd07 non écrit, config inchangée" >&2; trash "$KEYDIR"; return 1; }
  cat "$KEYDIR/config.new" > "$SSH_CONFIG" || { trash "$KEYDIR"; return 1; }
  export HV_ALIAS_READY=1 HV_ALIAS_OWNER=$$
}

# drop_alias : retire le bloc de ~/.ssh/config, puis les clés ; sans effet pour un script qui n'a pas créé l'alias
# la config est réécrite à travers un éventuel lien symbolique (sed -i le remplacerait par un fichier ordinaire)
# si le bloc ne part pas, la fonction échoue avec un message et garde les clés, que le bloc Include nomme encore
drop_alias() {
  [ "${HV_ALIAS_OWNER:-}" = "$$" ] || return 0
  if [ -e "$SSH_CONFIG" ]; then
    sed '/^# hv-hd07 begin$/,/^# hv-hd07 end$/d' "$SSH_CONFIG" > "$KEYDIR/config.rm" && cat "$KEYDIR/config.rm" > "$SSH_CONFIG" \
      || { echo "drop_alias : le bloc hv-hd07 reste dans $SSH_CONFIG ; retire-le à la main, les clés restent dans $KEYDIR" >&2; return 1; }
    [ -e "$KEYDIR/had-config" ] || [ -s "$SSH_CONFIG" ] || trash "$SSH_CONFIG" \
      || { echo "drop_alias : $SSH_CONFIG vide n'a pas été mis à la corbeille" >&2; return 1; }
  fi
  trash "$KEYDIR" || { echo "drop_alias : $KEYDIR n'a pas été mis à la corbeille" >&2; return 1; }
  unset HV_ALIAS_READY HV_ALIAS_OWNER
}

# start_app [LOG] : lance l'app en mode test avec le tunnel ; APP_PID reçoit son pid
# HV_SSH_HOST reçoit l'alias : HV_SSH_ALIAS de l'appelant, par défaut $SSH_ALIAS ; l'app ignore l'utilisateur et la clé de l'environnement
start_app() {
  HV_TEST_MODE=1 HV_SSH_HOST=${HV_SSH_ALIAS:-$SSH_ALIAS} \
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
