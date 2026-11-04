# Feature Map — À propos

Écran : Réglages → onglet À propos (`hd.settings.updates`).
Le titre affiché est « À propos ». L'identifiant reste `hd.settings.updates`.

## Versions

Une valeur absente ou vide s'affiche `inconnue`, sans erreur.
L'onglet n'affiche ni le build (`CFBundleVersion`) ni un canal de mise à jour.

| Contrôle | Identifiant | Source |
| --- | --- | --- |
| Version de l'app | `hd.about.app-version` | `CFBundleShortVersionString` |
| Hermes CLI | `hd.about.hermes` | version détectée pour la connexion active |
| macOS | `hd.about.macos` | version du système |

## Action

| Contrôle | Identifiant | Rôle |
| --- | --- | --- |
| Rechercher les mises à jour… | `hd.updates.check` | Démarre la recherche Sparkle. Dernier contrôle de l'onglet, sous les versions. Désactivé tant qu'une recherche n'est pas possible. |
| Mettre à jour | `hd.updates.install` | Visible seulement quand une mise à jour est disponible. Installe la version proposée. |

Sous le formulaire, une ligne d'état reprend le résultat Sparkle : à jour, recherche en cours, version disponible, ou échec.
Le même libellé « Rechercher les mises à jour… » existe aussi dans le menu de l'app.
