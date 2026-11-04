# Feature Map — À propos

Écran : Réglages → onglet À propos (`hd.settings.updates`).

## Versions

Une valeur absente ou vide s'affiche `inconnue`, sans erreur.

| Contrôle | Identifiant | Source |
| --- | --- | --- |
| Version de l'app | `hd.about.app-version` | `CFBundleShortVersionString` |
| Hermes CLI | `hd.about.hermes` | version détectée pour la connexion active |
| macOS | `hd.about.macos` | version du système |
| Compatibilité | `hd.about.compat` | version testée / non testée, fonctions disponibles |

## Action

| Contrôle | Identifiant | Rôle |
| --- | --- | --- |
| Rechercher les mises à jour… | `hd.updates.check` | Démarre la recherche Sparkle. Dernier contrôle de l'onglet. |
