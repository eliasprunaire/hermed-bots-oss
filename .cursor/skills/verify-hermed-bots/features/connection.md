# Feature Map — Connexion

Écran : Réglages → onglet Connexion (`hd.settings.connection`).

## Saisie

| Contrôle | Identifiant | Rôle |
| --- | --- | --- |
| Alias SSH | `hd.connection.host` | Seul champ éditable du tunnel. Persisté sous `ssh.host`. |
| Connecter | `hd.connection.connect` | Résout l'alias puis ouvre le tunnel. |
| Tester la connexion | `hd.connection.check` | Relit la version Hermes. |
| Fermer | `hd.connection.close` | Ferme la fenêtre Réglages. |

Le champ Utilisateur n'est plus éditable.

## Lecture seule, sans secret

| Contrôle | Identifiant | Source |
| --- | --- | --- |
| Hôte résolu | `hd.connection.resolved-host` | `hostname` de `ssh -G` |
| Utilisateur | `hd.connection.user` | `user` de `ssh -G` |
| Port | `hd.connection.port` | `port` de `ssh -G` |
| Identité | `hd.connection.identity` | agent, certificat ou fichier |
| Clé publique / certificat | `hd.connection.identity-present` | présent ou absent ; jamais une valeur de clé |
| Tunnel | `hd.connection.tunnel-state` | fermé, ouverture, ouvert, réouverture, en échec |
| Version | `hd.connection.version` | version Hermes |
| Message | `hd.connection.message` | échec classé |

Aucune ligne « Clé SSH : … Trousseau ». Aucun chemin d'identité affiché.

## Clé API (inchangé)

| Contrôle | Identifiant |
| --- | --- |
| Profil | `hd.connection.api-profile` |
| Nouvelle clé API | `hd.connection.api-key` |
| Enregistrer la clé | `hd.connection.api-save` |
| Statut | `hd.connection.api-status` |

## Transport

- Résolution : `/usr/bin/ssh -G -vv` suivi des arguments de chaque lancement de `ssh` (tunnel, liste des profils, détection de Hermes Desktop). Chaque lancement est résolu et validé avec ses propres arguments. Le tunnel fournit l'aperçu affiché. Chaque `ssh -G` tourne sous un gardien : l'arrêt de l'app le tue, avec la commande d'un `Match exec`, et le délai de 8 s tue le groupe entier.
- Tunnel : `/usr/bin/ssh` + alias, `-N -T`, `-L 127.0.0.1:<port libre>:127.0.0.1:<remotePort>`, `BatchMode=yes`, `ExitOnForwardFailure=yes`, `ForwardAgent=no`, `ControlMaster=no`, `ControlPath=none`, `ForkAfterAuthentication=no`, `LogLevel=ERROR`, `ConnectTimeout`, `ServerAliveInterval`, `ServerAliveCountMax`.
- `SSH_AUTH_SOCK` vient de la session. `IdentityAgent` de la config ssh a priorité. `IdentityAgent none` désactive l'agent, socket de la session comprise : l'identité affichée est un fichier.
- Liste des profils : second `/usr/bin/ssh` avec l'alias, commande `hermes profile list`.
- Une nouvelle demande de connexion, y compris un refus local (alias vide ou invalide), invalide la génération en cours.

## Échecs

| Cas | Message |
| --- | --- |
| Alias inconnu (aucun bloc `Host` n'écrit l'alias tel quel dans `ssh -G -vv` ; `Host *`, `Host mon*` et tout motif avec joker ne suffisent pas, quelles que soient leurs valeurs ; un bloc nommé aux valeurs standard reste valide) | Cet alias SSH est inconnu. |
| Config qui contient un bloc `Match`, quelle que soit sa forme (`Match all`, `Match user *`, `Match host *`, `Match originalhost *`, `Match exec …`, même nommé sur l'alias) ; le refus vaut aussi pour un `Match` dans un fichier inclus ou après un autre `Host` | Ta config SSH contient un bloc Match. Hermed Bots ne l'interprète pas et refuse l'alias : remplace le bloc Match par des blocs Host. |
| Config que l'app ne lit pas avec certitude : `ssh -G` sort en erreur (guillemet non fermé, option inconnue, argument manquant), `Include` sans fichier, journal `-vv` de 64 Ko ou plus | Hermed Bots ne lit pas cette config SSH avec certitude : erreur de syntaxe, Include sans fichier ou journal trop long. L'alias est refusé. |
| Agent verrouillé ou vide | L'agent SSH est verrouillé ou vide. |
| Certificat expiré | Le certificat SSH a expiré. |
| Serveur refuse l'identité | Le serveur refuse l'identité SSH. |
| Clé d'hôte changée | La clé de l'hôte a changé. |
| Hôte injoignable | Hôte injoignable. |
| `perso-hermes` en mode test, sur l'alias ou sur l'hôte résolu d'un lancement ; l'alias tapé est refusé avant `ssh -G` | Cet hôte est refusé en mode test. |
| `ProxyJump` ou `ProxyCommand`, quelle que soit la valeur (hors `none`), vu par l'un des trois lancements ; tous les modes | Cet alias passe par un relais (ProxyJump ou ProxyCommand). Hermed Bots le refuse : utilise un alias qui se connecte directement à l'hôte. |

## Vérification unitaire

- Parser `ssh -G` simulé : cas `Include` (alias `lab` → `gateway.invalid`) et cas alias inconnu (`unknown-alias.invalid`, port 22).
- `RealSshConfigTests` lance le vrai `/usr/bin/ssh -G -vv -F` : toutes les formes de `Match`, un `Match` hors de portée de l'alias, un journal coupé à 64 Ko, un `Include` sans fichier, une config illisible, les alias nommés ou couverts par un motif.
- Arguments exacts de la résolution : `-G -vv` plus ceux du lancement réel, pour les trois lancements.
- Relais (`ProxyJump` ou `ProxyCommand`, valeurs de toute forme) : refusé en mode test et hors mode test, y compris quand un seul lancement (tunnel, liste des profils, détection) le voit. `none` n'est pas un relais.
- Arguments exacts du tunnel : alias, `ForkAfterAuthentication=no`, `LogLevel=ERROR`, pas de `-F`, `-i`, `-l`, `-p`, agent privé ni `known_hosts` temporaire.
- Recette HD-07 : `new_alias` (`docs/spike/hd07-instruments/lib.sh`) crée une clé éphémère et les alias `hv-hd07` (clé installée dans le conteneur) et `hv-hd07-refused` (clé jamais installée). Il les écrit dans un bloc `Include` marqué en tête de `~/.ssh/config` du compte qui lance la lane. `drop_alias` retire le bloc, puis les clés. Il réécrit la config à travers un lien symbolique et la laisse identique à l'octet près. Si le bloc ne part pas, il échoue avec un message et garde les clés. `new_alias` refuse un lien symbolique sans cible et une config illisible : il n'écrit rien et la config garde ses octets. Test : `test/hd07-alias-lib.test.js`. L'app n'a plus de variable de clé ni d'utilisateur.
- Affichage en lecture seule sans secret.
- Le magasin de secrets ne lit plus de clé SSH dans le Trousseau.
