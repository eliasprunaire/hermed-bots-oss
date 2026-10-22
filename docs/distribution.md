---
style_gate: pass
---

# Distribuer Hermed Bots

La chaîne produit une archive ZIP signée Developer ID, notarisée et agrafée, un appcast Sparkle signé et un cask Homebrew.
Elle cible macOS 27 au minimum.
Le dépôt source reste privé.

```text
VERSION sur main -> tag vX.Y.Z -> archive Release -> Developer ID
    -> notarytool -> staple -> Gatekeeper -> ZIP et appcast signés
    -> dépôt public approuvé -> cask Homebrew -> mises à jour Sparkle
```

## Dépôts de publication

La chaîne écrit dans deux dépôts publics.
`eliasprunaire/hermed-bots-releases` reçoit les archives, le flux Sparkle, les empreintes et le SHA source.
`eliasprunaire/homebrew-tap` reçoit le cask `Casks/hermed-bots.rb`.
Le code source, les certificats et la documentation interne restent dans le dépôt privé.

Le dépôt du tap se déduit du propriétaire de `DISTRIBUTION_REPOSITORY` : `<propriétaire>/homebrew-tap`.
Homebrew nomme ce tap `<propriétaire>/tap`.

Le flux utilise `https://github.com/<propriétaire>/<dépôt>/releases/latest/download/appcast.xml`.
Les archives utilisent `https://github.com/<propriétaire>/<dépôt>/releases/download/vX.Y.Z/HermedBots-X.Y.Z.zip`.
Ces adresses doivent répondre sans authentification depuis le Mac installé.
Aucun jeton GitHub n'entre dans l'app.

Un administrateur configure les éléments suivants dans le dépôt source.

| Type | Nom | Valeur attendue |
| --- | --- | --- |
| Variable | `DISTRIBUTION_REPOSITORY` | Le dépôt public des releases, sous la forme `propriétaire/dépôt`. |
| Variable | `DISTRIBUTION_APPROVED` | `true` après l'accord utilisateur sur la publication des binaires. |
| Variable | `SPARKLE_PUBLIC_KEY` | La clé publique Ed25519 fournie par Sparkle. |
| Secret | `DISTRIBUTION_TOKEN` | Un jeton limité à `Contents: read and write` sur le dépôt des releases et sur le tap. |
| Secret | `SPARKLE_PRIVATE_KEY` | La clé privée exportée par `generate_keys`. |

Les deux dépôts publics doivent avoir une branche par défaut initialisée.
Le workflow vérifie leur visibilité et les droits d'écriture avant la signature.
Il ne crée aucun dépôt et ne change aucune visibilité.
Un appcast placé dans les releases privées du dépôt source ne convient pas aux installations sans jeton.

## Préparer les clés Apple

Utiliser un abonnement Apple Developer actif.
Les secrets se configurent dans **Settings > Secrets and variables > Actions** du dépôt source.
Ne jamais coller leurs valeurs dans une issue, une PR ou un journal.

| Secret | Origine |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer, **Membership details**, champ Team ID. |
| `DEVELOPER_ID_P12` | Certificat **Developer ID Application**, exporté avec sa clé privée depuis Trousseaux d'accès, puis encodé en base64. |
| `DEVELOPER_ID_P12_PASSWORD` | Le mot de passe choisi pour protéger cet export P12. |
| `ASC_KEY_ID` | App Store Connect, **Users and Access > Integrations > App Store Connect API**, identifiant de la clé d'équipe. |
| `ASC_ISSUER_ID` | Issuer ID affiché sur cette même page. |
| `ASC_KEY_P8` | Le contenu PEM du fichier `.p8`, téléchargé une seule fois sur cette page. |

Créer le certificat depuis [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).
Conserver le certificat et sa clé privée ensemble lors de l'export P12.
Utiliser une clé d'équipe App Store Connect avec le rôle Developer pour `notarytool`.
Le titulaire du compte doit avoir accepté la dernière version du contrat Apple Developer Program License Agreement.
Sans cette acceptation, `notarytool` répond `HTTP status code: 403. A required agreement is missing or has expired` et la release s'arrête avant l'agrafage.
Consulter [les clés API Apple](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api).

Le workflow importe le P12 dans un trousseau temporaire du runner GitHub jetable.
Le nettoyage retire ce trousseau et les fichiers privés, même après un échec.
Aucun certificat n'est importé sur le Mac de développement par le script.
Aucun secret n'est inclus dans les artefacts Actions.
Une configuration incomplète produit `Distribution skipped` et ignore le job macOS sans échec.
Une clé présente mais invalide provoque un échec réel.

## Préparer Sparkle

Utiliser les outils de Sparkle 2.10.0, la version épinglée dans le projet et dans `Package.resolved`.
La résolution Xcode les place dans `artifacts/sparkle/Sparkle/bin` du dossier des packages.
Suivre [la procédure de sécurité Sparkle](https://sparkle-project.org/documentation/#3-segue-for-security-concerns) pour créer et exporter la paire Ed25519.
Cette opération de provisionnement nécessite l'accord portant sur les clés.
Conserver la même paire entre les versions.

`SPARKLE_PUBLIC_KEY` devient `SUPublicEDKey` dans l'app signée.
`SPARKLE_PRIVATE_KEY` arrive sur l'entrée standard des outils de signature.
`generate_appcast` signe les archives et le flux.
`sign_update --verify` contrôle le flux avant publication.
`SURequireSignedFeed` et `SUVerifyUpdateBeforeExtraction` imposent la vérification avant extraction.

Sparkle démarre dans les builds Release.
Les builds Debug ne lancent aucun contrôle de mise à jour, notamment pendant XCUITest.
Les contrôles et les téléchargements automatiques sont activés dans le bundle.
Sparkle installe les mises à jour selon son cycle standard, notamment à la fermeture de l'app.
La première installation reste manuelle.
Aucune compilation locale n'est nécessaire ensuite.
Le réglage de connexion et les secrets du Trousseau restent hors du bundle remplacé.

## Figer une version

1. Augmenter `VERSION` dans une PR, par exemple de `0.1.0` à `0.1.1`.
2. Fusionner cette PR après les portes habituelles du dépôt.
3. Attendre les workflows **Freeze version** et **Release macOS**.
4. Contrôler les preuves de distribution dans Actions.

`VERSION` désigne une version figée.
Une modification de code sans changement de `VERSION` ne crée aucune release.
Le workflow crée un tag léger `vX.Y.Z` sur le commit exact de `main`, sans push sur cette branche.
Il appelle directement le workflow réutilisable de release.
Un tag créé avec `GITHUB_TOKEN` ne déclenche pas un autre workflow par son événement `push`.
Cette limite est décrite dans [la documentation GitHub](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).

Un opérateur peut aussi lancer **Freeze version** à la main pour figer la valeur actuelle de `VERSION`, sans la modifier.
Le lancement depuis une branche autre que celle de production ne fait rien.
Un tag poussé par un opérateur autorisé déclenche aussi **Release macOS**.
**Run workflow** accepte un tag existant pour reprendre une publication ignorée après configuration des clés.
Le tag doit pointer sur un ancêtre de `main` et correspondre à `VERSION` dans son arbre.
Les versions finales suivent les limites Apple de `CFBundleVersion`, soit `9999.99.99` au maximum.
Les deux champs de version de l'app reçoivent la version du tag.

Le runner utilise l'image GitHub `xcode-27` et le Xcode stable installé le plus récent.
Le workflow ignore les Xcode bêta, y compris un lien qui pointe sur une bêta.
La garde refuse un système, un SDK ou un Xcode antérieur à 27.
Si l'image GitHub n'offre pas ces versions, le build s'arrête.
Aucun chemin de compatibilité descendante n'existe.

## Répéter une release sans publier

Le workflow **Release macOS** accepte l'option `rehearsal` quand un opérateur le lance à la main depuis une branche.
Il construit, signe, notarise et agrafe cette branche avec les vraies clés.
Il génère le flux Sparkle signé et le cask.
Il ne publie rien et n'exige pas de tag sur `main`.
Le champ `tag` reçoit alors `v` suivi du contenu de `VERSION` sur la branche.
L'artefact `distribution-proof` contient le résultat.
Cette répétition teste les scripts avant leur fusion : un tag exécute toujours les scripts de son propre commit.

```bash
gh workflow run release.yml --ref <branche> -f tag=v$(cat VERSION) -f rehearsal=true
```

## Lire les preuves et reprendre un échec

La chaîne archive puis exporte avec la méthode `developer-id`.
Elle soumet le ZIP à `notarytool` et exige le statut `Accepted`.
Elle agrafe l'app, valide l'agrafe et exige le succès de `spctl -a -vv --type execute`.
Le ZIP distribué est créé après l'agrafage.
La publication reste en brouillon jusqu'au téléversement de tous les fichiers.

L'artefact Actions `distribution-proof` contient les éléments suivants.

| Fichier | Preuve |
| --- | --- |
| `notary.json` | Le statut et l'identifiant de la soumission Apple. |
| `spctl.txt` | La décision Gatekeeper sur l'app exportée et agrafée. |
| `HermedBots-X.Y.Z.zip` | L'archive finale de l'app. |
| `appcast.xml` | Le flux et ses signatures EdDSA. |
| `hermed-bots.rb` | Le cask avec le SHA-256 de cette archive. |
| `SHA256SUMS` | Les empreintes du ZIP, du flux et du cask. |
| `commit.txt` | Le commit source complet. |

Une version publiée ne peut pas être remplacée par d'autres octets.
Une version antérieure ne peut pas remplacer la release courante.
Une reprise avec les mêmes artefacts peut terminer la mise à jour du tap.
Un rebuild produit une nouvelle version si ses empreintes diffèrent.
Le tap utilise le SHA du fichier courant pour empêcher l'écrasement d'une modification concurrente.
Le journal conserve tout échec GitHub, Apple ou Sparkle.
Un succès de préflight ne prouve aucune signature ni installation.

## Installer avec Homebrew

Après la première release, la commande est la suivante.

```bash
brew install --cask eliasprunaire/tap/hermed-bots
```

Le cask installe `HermedBots.app` dans Applications.
Il utilise `auto_updates true`, car Sparkle gère les versions suivantes.
Il exige macOS 27, nommé `golden_gate` par Homebrew.
Aucun cask avec une empreinte inventée n'est livré dans le dépôt source.
Le script le génère à partir du ZIP réellement notarisé.
Consulter [le format des casks](https://docs.brew.sh/Cask-Cookbook).

## Brancher l'app sur Hermes de production

Cette configuration s'effectue sur le Mac de l'utilisateur après installation.
La recette de développement reste limitée à `hv-hermes-test`.
Aucune commande de cette PR ne se connecte à la production.

1. Faire provisionner la clé SSH dans le Trousseau par l'administrateur de la connexion.
2. Ouvrir **Connexion** dans l'app.
3. Saisir l'hôte et l'utilisateur SSH de production.
4. Cliquer sur **Connecter**.
5. Choisir chaque profil dans **Clé API par profil**.
6. Saisir sa clé dans **Nouvelle clé API**.
7. Cliquer sur **Enregistrer la clé**.
8. Contrôler la liste des bots et la version Hermes affichée.

La clé SSH est un mot de passe générique du service `com.hermedbots.HermedBots`, compte `hermes-ssh-key`.
Sa valeur contient la clé privée SSH, sans passphrase interactive.
L'interface actuelle ne sait pas importer cette clé.
Le provisionnement initial du Trousseau reste une opération distincte autorisée par l'utilisateur.
Les clés API utilisent le même service, avec le compte `hermes-api-key:<profil>`.
Les réglages d'hôte et d'utilisateur persistent automatiquement.
Le tunnel expose l'API distante uniquement sur la boucle locale.
Une mise à jour ne modifie pas ces réglages.

## Recetter dans Tart

Les signatures Apple exigent les clés configurées et une publication approuvée.
Le scénario complet exige deux versions publiées, N et N+1.
Il ne peut pas être remplacé par un test du générateur de cask.

1. Installer N dans la VM via le cask du tap approuvé.
2. Contrôler Gatekeeper avec `spctl -a -vv --type execute` sur l'app installée.
3. Publier N+1 avec la même paire Sparkle.
4. Laisser Sparkle télécharger puis installer N+1 dans la VM.
5. Relire les deux champs de version du bundle installé.
6. Vérifier la conservation des réglages de connexion.

Toutes les passes UI utilisent exclusivement `zsh ~/<INFRA>/vm.sh ui fake` ou `vm.sh exec` depuis la racine.
Un délai extérieur de 3 600 secondes laisse au lanceur le temps de préparer la VM.
La VM de recette bloque Internet par pf.
Une recette publique Homebrew et Sparkle exige donc un transport de recette approuvé vers les archives et le flux.
Cette PR ne modifie aucune règle réseau de la VM.
Une passe de fixtures ne prouve ni Gatekeeper, ni l'installation Homebrew, ni le passage N vers N+1.
Une ligne `HV-UI SAUTÉE` conserve la passe UI en attente de la VM.
