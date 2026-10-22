#!/usr/bin/env bash
# s12-observe.sh : observation S12 contre hv-hermes-test, comment /usr/bin/ssh reçoit la clé sans argument ni fichier
# Le conteneur doit tourner (hv-ssh-endpoint.sh up). Chaque ssh est tué au bout de 12 s : un essai peut se bloquer
# Les clés de test sont jetables, dans un dossier 0700 supprimé à la fin ; aucune valeur de clé n'est affichée
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
W=$HVW/s12-work
mkdir -m 700 "$W" || exit 1
trap 'trash "$W"' EXIT
/usr/bin/ssh-keygen -q -t ed25519 -N '' -C hv-s12 -f "$W/k" && /usr/bin/ssh-keygen -q -t ed25519 -N '' -C hv-s12-bad -f "$W/bad" || exit 1
"$ENDPOINT" authorize < "$W/k.pub"
H=$SSH_HOST
OPTS=(-F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o "UserKnownHostsFile=$W/kh" -o ConnectTimeout=5 -o LogLevel=ERROR -l hvssh)
limited() { "$@" & local p=$!; ( sleep 12; kill "$p" 2>/dev/null ) & local w=$!; wait "$p"; local rc=$?; kill "$w" 2>/dev/null; return $rc; }
echo "$(/usr/bin/ssh -V 2>&1)"

echo "--- A : -o IdentityFile=/dev/fd/3, la clé dans un tube (tuée au bout de 12 s si elle bloque)"
limited /usr/bin/ssh "${OPTS[@]}" -o IdentityFile=/dev/fd/3 $H id -un 3< <(cat "$W/k"); echo "rc=$?"
echo "--- A2 : -o IdentityFile=/dev/stdin, la clé sur l'entrée standard"
cat "$W/k" | limited /usr/bin/ssh "${OPTS[@]}" -o IdentityFile=/dev/stdin $H id -un; echo "rc=$?"

echo "--- B : ssh-agent privé, clé par ssh-add - (entrée standard), partie publique par ssh-add -L"
S=$W/a.sock
/usr/bin/ssh-agent -D -a "$S" >/dev/null 2>&1 & AP=$!
sleep 0.5
cat "$W/k" | SSH_AUTH_SOCK=$S /usr/bin/ssh-add - ; echo "ssh-add - rc=$?"
SSH_AUTH_SOCK=$S /usr/bin/ssh-add -L > "$W/k.agent.pub"; echo "ssh-add -L rc=$? : $(cut -d' ' -f1,3 "$W/k.agent.pub")"
echo "--- B1 : sans IdentitiesOnly ni -i, ssh essaie aussi les clés par défaut de ~/.ssh"
limited /usr/bin/ssh "${OPTS[@]}" -o IdentityAgent=$S -v $H true 2>&1 | grep -E "identity file .* type|Offering|Authenticated" | sed 's/SHA256:[A-Za-z0-9+\/]*/SHA256:<empreinte>/'
echo "--- B2 : IdentitiesOnly=yes et -i <partie publique>, ssh ne propose que la clé de l'agent"
limited /usr/bin/ssh "${OPTS[@]}" -o IdentityAgent=$S -o IdentitiesOnly=yes -i "$W/k.agent.pub" -v $H true 2>&1 | grep -E "identity file .* type|Offering|Authenticated" | sed 's/SHA256:[A-Za-z0-9+\/]*/SHA256:<empreinte>/'

echo "--- C : redirection locale vers 127.0.0.1:8642 du conteneur"
LP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
/usr/bin/ssh "${OPTS[@]}" -o IdentityAgent=$S -o IdentitiesOnly=yes -i "$W/k.agent.pub" -o ExitOnForwardFailure=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -N -L 127.0.0.1:$LP:127.0.0.1:8642 $H 2>"$W/err.txt" & SP=$!
for _ in $(seq 1 50); do nc -z 127.0.0.1 $LP 2>/dev/null && break; sleep 0.1; done
echo "GET /health par le port local : $(curl -sS -m 3 http://127.0.0.1:$LP/health)"
echo "port distant refusé par PermitOpen (127.0.0.1:22) : $(printf 'x' | limited /usr/bin/ssh "${OPTS[@]}" -o IdentityAgent=$S -o IdentitiesOnly=yes -i "$W/k.agent.pub" -W 127.0.0.1:22 $H 2>&1 | head -c 120)"
kill $SP; wait $SP 2>/dev/null; echo "ssh après SIGTERM : rc=$?"

echo "--- D : mauvaise clé"
S2=$W/b.sock; /usr/bin/ssh-agent -D -a "$S2" >/dev/null 2>&1 & AP2=$!; sleep 0.5
cat "$W/bad" | SSH_AUTH_SOCK=$S2 /usr/bin/ssh-add - 2>&1; SSH_AUTH_SOCK=$S2 /usr/bin/ssh-add -L > "$W/bad.agent.pub"
/usr/bin/ssh "${OPTS[@]}" -o IdentityAgent=$S2 -o IdentitiesOnly=yes -i "$W/bad.agent.pub" -N -L 127.0.0.1:$LP:127.0.0.1:8642 $H; echo "rc=$?"
echo "--- E : hôte injoignable (port fermé)"
/usr/bin/ssh "${OPTS[@]}" -o IdentityAgent=$S -o IdentitiesOnly=yes -i "$W/k.agent.pub" -p 2 -N 127.0.0.1; echo "rc=$?"
echo "--- F : un chemin à espaces dans -o UserKnownHostsFile, avec et sans guillemets (ssh garde la première valeur d'une option : pas d'autre UserKnownHostsFile ici)"
OPTS_F=(-F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o LogLevel=ERROR -l hvssh -o IdentityAgent=$S -o IdentitiesOnly=yes -i "$W/k.agent.pub")
mkdir -p "$W/with space"
limited /usr/bin/ssh "${OPTS_F[@]}" -o "UserKnownHostsFile=$W/with space/kh" $H true; echo "sans guillemets rc=$? ; fichier créé : $([ -s "$W/with space/kh" ] && echo oui || echo non)"
limited /usr/bin/ssh "${OPTS_F[@]}" -o "UserKnownHostsFile=\"$W/with space/kh\"" $H true; echo "avec guillemets rc=$? ; fichier créé : $([ -s "$W/with space/kh" ] && echo oui || echo non)"
kill $AP $AP2 2>/dev/null
