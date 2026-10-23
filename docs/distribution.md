---
style_gate: pass
---

# Distribuer Hermed Bots

La chaîne produit une archive ZIP signée Developer ID, notarisée et agrafée, un appcast Sparkle signé et un cask Homebrew.
Elle cible macOS 27 au minimum.
Le dépôt source est public.

```text
VERSION sur main -> tag vX.Y.Z -> archive Release -> Developer ID
    -> notarytool -> staple -> Gatekeeper -> ZIP et appcast signés
    -> dépôt public approuvé -> cask Homebrew -> mises à jour Sparkle
```

## Dépôts de publication

La chaîne écrit dans deux dépôts publics.
`eliasprunaire/hermed-bots-releases` reçoit les archives, le flux Sparkle, les empreintes et le SHA source.
`eliasprunaire/homebrew-tap` reçoit le cask `Casks/hermed-bots.rb`.

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
Une configuration incomplète produit `Distribution skipped` et ignore le job macOS sans échec, sauf en répétition : elle échoue.
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

Le workflow **Release macOS** accepte l'option `rehearsal` quand un opérateur le lance à la main.
Il construit, signe, notarise et agrafe le commit lancé avec les vraies clés.
Il génère le flux Sparkle signé et le cask.
Il ne publie rien et n'exige pas de tag sur `main`.
Le champ `tag` reçoit `v` suivi du contenu de `VERSION` sur ce commit.

L'environnement `release` n'autorise que la branche `main`.
GitHub refuse un lancement depuis une autre branche avant la première étape, donc avant tout accès aux secrets.
La répétition se lance depuis `main`.
Autoriser une autre branche est un réglage du dépôt, hors de ce workflow.

```bash
gh workflow run release.yml --ref main -f tag=v$(cat VERSION) -f rehearsal=true
```

Une répétition échoue quand la configuration est incomplète.
Un run vert prouve donc que le build, la signature, la notarisation et l'agrafage ont tourné.
Le résumé du job donne l'identifiant du run et le résultat de ces quatre étapes.
L'étape de publication reste ignorée.

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
| `stages.txt` | Les étapes `build`, `signature`, `notarization` et `stapling` réussies, une par ligne. |
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

## Prouver la mise à jour de N vers N+1 sans publier

Le script `scripts/sparkle-update-proof.sh` prouve le passage de la version N à la version N+1 par le flux Sparkle signé.
N est le contenu de `VERSION`. N+1 est la version de patch suivante.
Le script ne publie rien et ne lit aucune clé de production.

1. Il crée une paire Ed25519 jetable dans un dossier temporaire.
2. Il construit N puis N+1 en Release, avec le même flux local et la même clé publique.
3. Il génère l'appcast des deux builds et contrôle sa signature avec `sign_update --verify`.
4. Il sert le flux sur la boucle locale.
5. Il démarre N. L'app trouve N+1, vérifie la signature du flux, télécharge l'archive et l'installe à sa fermeture.
6. Il relance le bundle installé et lit ses deux champs de version. Ils doivent valoir N+1.
7. Il refait la passe avec une signature de flux altérée, puis avec une archive altérée. L'app doit refuser et rester en N.
8. Il supprime la paire de clés, les builds et les caches de la passe.

Les builds de la preuve ont leur propre identifiant de bundle, `com.hermedbots.HermedBots.updateproof`.
Ils ne touchent ni les réglages ni le Trousseau d'une app installée.
Le script démarre les apps et exige une session graphique macOS.
Sur le Mac de développement, la passe tourne dans la VM jetable :

```bash
zsh ~/<INFRA>/<vm-test-script> exec bash -c 'PROOF_OUT=$HOME/<WORK>/evidence/sparkle-update-proof SOURCE_PACKAGES=$HOME/<WORK>/sp bash scripts/sparkle-update-proof.sh'
```

`PROOF_OUT` désigne le dossier des preuves. Il reste hors du dépôt.
`SOURCE_PACKAGES` désigne des paquets Swift déjà résolus, pour une construction sans réseau.
La dernière ligne de sortie commence par `SPARKLE-PROOF` et donne N, N+1 et le résultat de chaque contrôle.
`bash scripts/sparkle-update-proof.sh prepare` construit et signe sans démarrer d'app.
Cette passe `prepare` ne prouve pas l'installation.

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

Le script `docs/spike/hd19-instruments/vm-install.sh` fait les étapes 1, 2 et 5 pour la version installée.
La section « Installation de la version 0.1.0 prouvée » donne son résultat.

Toutes les passes UI utilisent exclusivement `zsh ~/<INFRA>/<vm-test-script> ui fake` ou `<vm-test-script> exec` depuis la racine.
Un délai extérieur de 3 600 secondes laisse au lanceur le temps de préparer la VM.
La VM de recette bloque Internet par pf.
Une recette publique Homebrew et Sparkle exige donc un transport de recette approuvé vers les archives et le flux.
Cette PR ne modifie aucune règle réseau de la VM.
Une passe de fixtures ne prouve ni Gatekeeper, ni l'installation Homebrew, ni le passage N vers N+1.
Une ligne `HV-UI SAUTÉE` conserve la passe UI en attente de la VM.

## Release 0.1.0

La release 0.1.0 est publiée.
Le tag léger `v0.1.0` pointe sur le commit `e33d36ec828f6afd88ddba38ea1aa2a91f84d80d` de `main`.
Le run 39966068978 de **Release macOS** est la répétition de ce commit. Ses étapes `build`, `signature`, `notarization` et `stapling` ont réussi.
Le run 39967121968 de **Freeze version** a créé le tag, puis publié la release.

La release `v0.1.0` de `eliasprunaire/hermed-bots-releases` n'est pas un brouillon.
Elle contient `HermedBots-0.1.0.zip`, `appcast.xml`, `hermed-bots.rb`, `SHA256SUMS` et `commit.txt`.
Le cask `Casks/hermed-bots.rb` de `eliasprunaire/homebrew-tap` porte la version 0.1.0.
La preuve du run 39967121968 donne le statut de notarisation `Accepted` et la décision Gatekeeper `accepted`.

Le résumé Actions n'affiche le bloc de preuve que pour une répétition.
Un vrai run garde sa preuve dans l'artefact `distribution-proof`, conservé un jour.

## Installation de la version 0.1.0 prouvée

La passe `vm-install.sh` installe la version 0.1.0 depuis le tap dans la VM de recette jetable.
Elle a réussi avec le code 0.
Elle exécute la commande de l'utilisateur : `brew install --cask eliasprunaire/tap/hermed-bots`.
Le tap `eliasprunaire/tap` et le cask `hermed-bots` ont donc répondu à cette commande exacte.

La passe part de la racine du dépôt.

```bash
zsh ~/<INFRA>/<vm-test-script> exec bash docs/spike/hd19-instruments/vm-install.sh 0.1.0
```

La dernière ligne du lanceur est `HV-UI chemin=vm rc=0 durée=264s`.
La sortie utile suit, caviardée.

```text
github.com: unreachable
archive: copied from the local mirror into the Homebrew cache
==> Installing Cask hermed-bots
==> Moving App 'HermedBots.app' to '~/Applications/HermedBots.app'
hermed-bots was successfully installed!
~/Applications/HermedBots.app: accepted
source=Notarized Developer ID
override=security disabled
origin=<signing identity redacted>
~/Applications/HermedBots.app: valid on disk
~/Applications/HermedBots.app: satisfies its Designated Requirement
stapler: online validation failed, reading the stapled ticket file instead
CFBundleShortVersionString: 0.1.0
CFBundleVersion: 0.1.0
HOMEBREW-PROOF version=0.1.0 install=pass gatekeeper=pass signature=pass staple=ticket-file-only versions=pass
```

Cette preuve a six limites.

1. La VM bloque `github.com`. Le lanceur sert l'archive de la release `v0.1.0` depuis un miroir local sur la boucle locale.
   Le script copie cette archive dans le cache de Homebrew. Homebrew la compare au SHA-256 du cask.
   La preuve ne couvre pas le téléchargement depuis `github.com`.
2. Le tap de la VM vient d'un miroir local du dépôt public du tap.
3. La VM ajoute `override=security disabled` au verdict de `spctl`.
   Ce verdict ne prouve donc pas seul que Gatekeeper applique la règle sur le Mac d'un utilisateur.
   La décision Gatekeeper de la release elle-même figure dans la section « Release 0.1.0 ».
4. `xcrun stapler validate` exige l'accès aux serveurs d'Apple, selon sa page de manuel. La VM n'y accède pas. Hors ligne, `stapler` sort avec le code 68. Le script lit alors le fichier du ticket agrafé, qui commence par `s8ch`. Il montre que le ticket est présent. Il ne vérifie pas sa validité. Les codes 65 (ticket invalide), 66 (ticket absent) et 77 (ticket révoqué) arrêtent le script avec ce code. Aucun repli ne s'applique. La validité de l'agrafe vient de l'étape `stapling` du run 39967121968.
5. Le script ne démarre pas l'app. Une première tentative avec `open` est restée bloquée 16 minutes, et le processus de l'app est resté arrêté.
   La cause n'est pas confirmée. Une app en quarantaine demande peut-être une confirmation à sa première ouverture, que la VM sans écran ne donne pas.
   Le verdict de `spctl` reste le contrôle de lancement.
6. Le compte de la VM n'est pas administrateur. Le script installe donc l'app dans `~/Applications` avec `--appdir`.
   La commande de l'utilisateur n'a pas besoin de cette option.

## Mise à jour de 0.1.0 vers 0.1.1 : preuve en attente

La mise à jour de 0.1.0 vers 0.1.1 n'est pas prouvée.
La publication de 0.1.1 démarre quand le changement de `VERSION` à `0.1.1` arrive sur `main`.
**Freeze version** crée alors le tag, puis **Release macOS** publie la release sans clic.

L'app lit le flux à une adresse GitHub en HTTPS.
Le flux public de la release courante répond HTTP 200 sans authentification, contrôlé depuis le poste de développement.
La VM bloque cette adresse. Le miroir local sert seulement la disposition de Homebrew, en HTTP.
La preuve de mise à jour exige donc un transport de recette approuvé vers le flux HTTPS et vers l'archive de 0.1.1.
