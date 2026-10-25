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
| ProxyJump | `hd.connection.jumps` | nombre de sauts |
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

- Résolution : `/usr/bin/ssh -G -vv <alias>`.
- Tunnel : `/usr/bin/ssh` + alias, `-N -T`, `-L 127.0.0.1:<port libre>:127.0.0.1:<remotePort>`, `BatchMode=yes`, `ExitOnForwardFailure=yes`, `ForwardAgent=no`, `ControlMaster=no`, `ControlPath=none`, `ForkAfterAuthentication=no`, `LogLevel=ERROR`, `ConnectTimeout`, `ServerAliveInterval`, `ServerAliveCountMax`.
- `SSH_AUTH_SOCK` vient de la session. `IdentityAgent` de la config ssh a priorité.
- Liste des profils : second `/usr/bin/ssh` avec l'alias, commande `hermes profile list`.
- Une nouvelle demande de connexion, y compris un refus local (alias vide ou invalide), invalide la génération en cours.

## Échecs

| Cas | Message |
| --- | --- |
| Alias inconnu (`ssh -G -vv` n'applique aucun bloc Host nommé ; un bloc Host aux valeurs standard reste valide) | Cet alias SSH est inconnu. |
| Agent verrouillé ou vide | L'agent SSH est verrouillé ou vide. |
| Certificat expiré | Le certificat SSH a expiré. |
| Serveur refuse l'identité | Le serveur refuse l'identité SSH. |
| Clé d'hôte changée | La clé de l'hôte a changé. |
| Hôte injoignable | Hôte injoignable. |
| `perso-hermes` en mode test, sur l'alias ou l'hôte résolu ; l'alias tapé est refusé avant `ssh -G` | Cet hôte est refusé en mode test. |

## Vérification unitaire

- Parser `ssh -G` simulé : cas `Include` (alias `lab` → `gateway.invalid`) et cas alias inconnu (`unknown-alias.invalid`, port 22).
- Arguments exacts du tunnel : alias, `ForkAfterAuthentication=no`, `LogLevel=ERROR`, pas de `-F`, `-i`, `-l`, `-p`, agent privé ni `known_hosts` temporaire.
- Affichage en lecture seule sans secret.
- Le magasin de secrets ne lit plus de clé SSH dans le Trousseau.
