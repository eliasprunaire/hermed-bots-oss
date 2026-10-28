# PRD : app macOS native pour piloter les bots Hermes

> Statut : PRD consolidé, 18/10/2026 (heure de Paris). Il remplace `prd.md` et la version finale v2 du 17/10, amendements A1 à A12 intégrés au corps du texte. `prd.md` reste inchangé comme archive.
> Ce document ne demande ni d'écrire du code, ni d'ouvrir SSH, ni de modifier example-host. Aucune route d'API n'est affirmée : toute route citée est **« à vérifier »** jusqu'au spike de faisabilité, qui ouvre le plan.

## Résultats attendus (Outcomes)
- Depuis le Mac, l'utilisateur voit la liste de ses bots. Chaque bot correspond à un profil Hermes actif sur la VM example-host.
- Il ouvre un bot, discute avec lui et change le modèle de la session en cours, sans passer par Hermes Desktop.
- Quand le bot attend une approbation, la demande s'affiche (outil, paramètres) et l'utilisateur répond oui ou non. L'écran ne semble jamais figé sans raison.
- Un tour lancé avant la mise en veille du Mac se termine sur la VM, puis s'affiche au réveil.
- Une nouvelle version de Hermes ne casse jamais l'app : au pire, les seules fonctions touchées sont désactivées, avec un message clair.
- **Acceptation de la v1** (observable) :
  1. Les six actions client passent sur chacun des 9 profils actifs (instance de test OrbStack pour la recette automatisée ; validation finale par l'utilisateur).
  2. L'app n'ouvre aucune connexion sortante autre que le tunnel SSH. Aucune requête vers `/api/ws` ni vers le ticket OAuth du dashboard. Vérifié en observant les connexions sortantes pendant la recette.
  3. Les trois tests de robustesse (version récente, champs ajoutés ou retirés, route supprimée) laissent l'app utilisable, avec un message clair.
  4. Le test quotidien de compatibilité produit un rapport complet (voir « Vérification ») pendant 5 jours ouvrés consécutifs. Ce nombre est une proposition, voir Q12.
- **Acceptation de la semaine 1** : le spike a rendu un résultat (réponse documentée ou constat d'impossibilité) pour chaque point de la section « Spike », et le premier test quotidien a produit un rapport daté.

## Critères de fin et d'arrêt (Done and stop)
- **Un tour est fini** quand le serveur renvoie un événement terminal : terminé, échoué, annulé ou interrompu. L'app affiche l'état réel, y compris un échec.
- **Le spike est fini** quand chaque point listé dans « Spike de faisabilité » a une réponse documentée ou un constat d'impossibilité.
- **La v1 est finie** quand le périmètre v1 est livré, que les critères d'acceptation sont remplis, que tous les scénarios de « Vérification » sont passés et que l'utilisateur a donné sa validation finale.
- **Prérequis de la première recette** : spike terminé ; instance de test OrbStack en place ; exception Mac d'Engineer appliquée à sa fiche (voir « Contraintes »). La recette n'est **pas** conditionnée à un plafond de tokens.
- **Arrêt automatique d'un tour en cas de boucle (garde-fou relatif)** : le tour est mis **en pause**, puis l'utilisateur reçoit une notification qui donne la cause. Jamais d'annulation silencieuse. Signaux (propositions de Dev Lead, **non mesurées**, à calibrer pendant le spike) :
  - le même appel d'outil, avec les mêmes arguments, répété 3 fois de suite dans un tour ;
  - le nombre d'appels d'outils du tour dépasse 3 fois le 95e centile du profil ;
  - les tokens du tour dépassent 5 fois la médiane du profil ;
  - aucun nouveau message de l'assistant pendant X minutes (X `unknown`, voir Q7) ;
  - démarrage à froid : valeurs prudentes jusqu'à 20 tours d'historique par profil (valeurs prudentes `unknown`, à proposer par Dev Lead au spike).
  - La mise en pause dépend d'un moyen de pause ou d'annulation côté serveur, `unknown` (spike, point S3). Si aucun n'existe, l'app suspend l'affichage et l'envoi, notifie l'utilisateur et lui propose le kill switch.
- **Arrêt automatique de concurrence** : si Hermes Desktop tient déjà le profil, l'app refuse de l'ouvrir et affiche la raison. Si Desktop prend le profil pendant l'usage, l'app cesse d'envoyer et l'affiche. Mécanisme de détection `unknown` (spike, S9).
- **Pas d'arrêt sur changement de version** : l'app ne s'arrête jamais et ne refuse jamais la connexion parce que la version de Hermes a changé. Elle passe en mode dégradé (voir « Version et compatibilité »).
- **Kill switch** : responsable **Ayo**. Il doit arrêter le travail côté VM : couper le tunnel ne suffit pas, car le tour continue sur la VM. Moyen technique : voir « Points ouverts traités », K. Travail en cours à l'arrêt : le tour est annulé ou interrompu côté VM ; la session et son transcript restent enregistrés sur la VM ; rien n'est supprimé.
- **Arrêt d'une passe de test** (Engineer) : arrêt immédiat si un chemin protégé (`~/.hermes/hermes-agent`, `~/.local/bin/hermes`) a changé entre avant et après la passe, puis alerte à l'utilisateur.

## Périmètre v1 (In scope)
1. La liste des bots, écran d'accueil.
2. La conversation du bot ouvert.
3. Le changement de modèle de la session en cours, par `/model`.
4. Une demande d'approbation visible : outil nommé, paramètres montrés, réponse oui ou non.
5. Une ligne qui nomme l'outil en cours.
6. Un bouton « Nouvelle session » qui envoie `/new` (jamais `/reset`). Libellé exact : question d'Ayo.
7. Les fils passés du bot, listés sous lui, et leur réouverture. Ils relèvent des actions « ouvrir le profil » et « lire le texte ».
8. Le garde-fou de boucle (pause + notification dans l'app) et l'affichage du mode dégradé.

Le client ne code que **six actions** : ouvrir le profil (session courante ou fil passé), envoyer, lire le texte, approuver (oui ou non), changer le modèle, lancer `/new`. Il ignore les événements et champs inconnus.

Exigences de testabilité : identifiants d'accessibilité stables sur tous les contrôles (pilotage XCUITest) ; un mode de test qui n'utilise pas le Trousseau réel ; toutes les fonctions passent par la couche d'adaptation unique.

Forme visée : celle de Grok Bot et d'OpenBot (agents nommés, conversation, sélecteur de modèle). **Pas un clone de Hermes Desktop.**

## Hors périmètre v1 (Out of scope)
- iOS ; fichiers et pièces jointes ; voix ; cron.
- Éditeur de skills, de mémoire, édition de `SOUL.md`.
- Notifications système générales. Seule exception : la notification de pause du garde-fou de boucle (forme à décider, Q8).
- Création d'un profil ; exposition sur Internet ; import du cache de Hermes Desktop.
- Affichage des profils décommissionnés : `lead-x`, `lead-x-analyst`, `lead-x-dm-manager`, `lead-x-growth-desk`, `lead-x-hook-writer`, `lead-x-ideator`, `lead-x-planner`, `buzz`.
- Tout transport autre que le tunnel SSH vers le serveur API.
- `session.compress` : la v1 n'utilise que `/new`.
- Toute action d'un bot du roster sur la production example-host.

## Sources de vérité (Sources of truth)
- **Profils actifs**, d'après `hermes profile list` le 14/10/2026 : `default`, `cyber`, `gaming`, `ia`, `perso`, `recherches`, `sport`, `tiny`, `wikilibriste`. L'app lit la liste dans Hermes (source `unknown`, spike S6) ; un changement de liste n'est affiché qu'après validation par l'utilisateur.
- **Documentation Hermes**, à respecter sans la contredire : [Programmatic Integration](https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration), [Profiles](https://hermes-agent.nousresearch.com/docs/user-guide/profiles), [API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server).
- **Code de la version de Hermes testée**, lu en lecture seule pendant le spike.
- **Sessions** : enregistrées sur example-host. L'app ne garde localement que les identifiants de session et de tour nécessaires à la reprise.
- **Fixtures de contrat** : une par version de Hermes prise en charge (au minimum l'actuelle et la précédente). Elles font foi pour la couche d'adaptation.

## Décisions prises

### Transport
- L'app ouvre un **tunnel SSH** vers example-host. De l'autre côté, le **serveur API Hermes** écoute seulement sur `127.0.0.1:8642`. Rien sur le réseau local, rien depuis Internet.
- Le serveur API n'est pas le TUI, mais c'est le même agent et le même profil.
- Le serveur API est aujourd'hui désactivé (`API_SERVER_ENABLED=false`). D'après la doc, l'activer demande `API_SERVER_ENABLED=true` et une clé `API_SERVER_KEY`, obligatoire même en local. Activation : voir « Points ouverts traités », A.
- Secrets (clé(s) `API_SERVER_KEY`) dans le **Trousseau macOS**, jamais en clair sur le disque, jamais dans le chat ni dans un fichier du dépôt. L'identité SSH vient de la config OpenSSH de l'utilisateur (alias, agent ou certificat).
- Veille : le tour continue sur la VM. Au réveil, l'app rouvre le tunnel et relit le tour depuis l'identifiant conservé, sans renvoyer un message déjà reçu. Point d'entrée `unknown` (S2).

### Transports écartés
- Ticket OAuth et WebSocket `/api/ws` du dashboard : 2320 échecs entre le 29/08 et le 14/10/2026 (« Could not reach the remote Hermes gateway while refreshing its WebSocket ticket »).
- ACP par SSH : le tour meurt avec la connexion.
- Page web intégrée : pas de liste des bots.
- CLI Hermes sur le Mac pointé vers la VM : impossible (`HERMES_TUI_GATEWAY_URL` interne au dashboard).
- Runtime Hermes local sur macOS : interdit (l'updater de Hermes Desktop se bloque si `~/.hermes/hermes-agent` ou `~/.local/bin/hermes` existe).

### Contexte et tokens
- Le fil affiché n'est pas le contexte envoyé au modèle.
- `/new` ferme la session ; le message suivant part sans l'ancien transcript. L'ancienne session reste un fil passé sous le bot ; la rouvrir lui rend son contexte.

### Modèle
- Le sélecteur du dashboard écrit le modèle du profil (nouvelles sessions seulement). `/model` change le modèle de la session ouverte. **La v1 appelle `/model`.** Point d'entrée `unknown` (S4).

### Version et compatibilité (l'app ne s'arrête jamais)
- Tous les appels à Hermes passent par **une seule couche d'adaptation, versionnée**. Aucun appel direct ailleurs.
- La version de Hermes est lue au démarrage, à titre d'information (source `unknown`, S8).
- Version inconnue → **mode dégradé** : l'app reste ouverte, signale l'écart et désactive seulement les fonctions touchées.
- Champs inconnus ignorés. Champ attendu manquant → valeur par défaut, pas de plantage.
- Route disparue ou changée → la fonction concernée est désactivée seule, avec un message clair ; les autres continuent.
- Contrats (routes, champs) décrits dans des fixtures, une par version prise en charge (au minimum l'actuelle et la précédente).
- Un test quotidien de compatibilité signale une rupture avant que l'utilisateur la subisse (voir « Cadence »).

### Concurrence
- Deux processus n'écrivent jamais la même session en cours (doc Profiles). Refus d'ouverture si Desktop tient le profil ; arrêt d'envoi si Desktop le prend ensuite. Détection et statut du serveur API comme « processus tenant le profil » : `unknown` (S9).

### Environnement de développement et de test
- **Code** : écrit sur le Mac de l'utilisateur par Claude Code et Codex, sous la conduite de l'utilisateur. Voir la tension avec la CHARTE dans « Contraintes » et Q1.
- **CI GitHub** : runner Linux par défaut ; runner macOS possible.
  - Testable sous Linux : la couche d'adaptation (paquet Swift sans dépendance UI), le décodage tolérant, les fixtures de contrat, le garde-fou de boucle (logique pure), les tests contre un faux serveur ou contre une instance Hermes en conteneur.
  - Demande macOS : l'interface SwiftUI/AppKit, XCUITest, les captures de référence, le Trousseau, le tunnel SSH réel, la veille réelle.
- **Tests sur le MacBook de l'utilisateur**, contre un **Hermes propre dans un conteneur OrbStack**, sans montage sur `~/.hermes/hermes-agent` ni `~/.local/bin/hermes`. Jamais rien à ces chemins sur macOS. **Jamais de test sur la production example-host.**
- **Recette et test quotidien** : exécutés par **Engineer**, à **13 h 00, heure de Paris**, quand l'utilisateur est présent pour approuver chaque commande. Rapport à Dev Lead. **Validation finale : l'utilisateur.**
- **Exception Mac d'Engineer**, validée par écrit par l'utilisateur le 17/10/2026 à 12 h 05 (heure de Paris) : conteneur OrbStack dédié et dossier de travail dédié ; recette et test en lecture seule, avec rapport ; interdit d'écrire dans `~/.hermes/hermes-agent`, `~/.local/bin/hermes` et sur example-host, toute autre action sur le Mac, tout push sur main ; chemins protégés vérifiés avant et après chaque passe, arrêt immédiat si l'un change ; chaque commande approuvée par l'utilisateur ; durée du projet Hermes v1, révocable. La CHARTE (§ Roster Dev) la mentionne déjà.

## Spike de faisabilité (première étape du plan)
- Avant tout code de l'app. Il constate, il ne tranche pas. Critère de sortie par point : réponse documentée (route, format, comportement observé) ou constat d'impossibilité.
- Ordre : (1) documentation et code de Hermes en lecture seule ; (2) instance Hermes propre dans OrbStack sur le MacBook. **Jamais contre example-host.**
- L'accès à la VM example-host, même en lecture, demande l'accord écrit de l'utilisateur ; le spike recommandé n'en a pas besoin (voir A).
- Points à constater (tout est `unknown` aujourd'hui) :

| Id | Point | Ce qu'il faut rendre |
|---|---|---|
| S1 | Runs : créer un tour, suivre ses événements (flux ou interrogation), état terminal | Route et format, à vérifier |
| S2 | Reprise d'un tour par identifiant après coupure ; anti-doublon d'envoi | Route, clé d'idempotence ou non |
| S3 | Annulation (et pause, si elle existe) d'un tour, y compris des outils en cours | Route ; effet réel sur les outils |
| S4 | Envoi de `/model` et `/new` par l'API | Route ; persistance du modèle par session |
| S5 | Sessions : lister les fils passés d'un profil, en rouvrir un | Route |
| S6 | Liste des profils : source, et exclusion des décommissionnés (autorisation ou exclusion) | Source ; ne tranche pas la question d'Ayo |
| S7 | Multiplexage des 9 profils sur `8642` : routage multi-profils (préfixe `/p/<profil>/`, clé par profil, d'après la doc, à vérifier) ou un port par profil | Mécanisme réel ; si un port par profil, amendement à décider (Q3) |
| S8 | Version de Hermes : comment la lire (`/v1/capabilities` donne des fonctions, pas un numéro, d'après la doc) | Source ou constat d'absence |
| S9 | Détection de Desktop dans les deux ordres ; le serveur API compte-t-il comme processus tenant le profil | Mécanisme |
| S10 | Tokens par run : source du relevé, pour le garde-fou A2 | Source ou constat d'absence |
| S11 | Calibrage des seuils de boucle sur l'instance de test | Valeurs proposées par Dev Lead, marquées non mesurées si pas de données |
| S12 | Faisabilité du tunnel SSH depuis l'app (ssh système ou bibliothèque) | Option retenue proposée |

- Si un point qui conditionne une des six actions, la reprise après veille, la concurrence ou le garde-fou se révèle impossible, la v1 n'est pas livrable telle qu'écrite : l'utilisateur décide de la suite. Le spike ne propose pas de remplacement de lui-même.

## Points ouverts traités (options et recommandation)

### K. Kill switch : moyen technique (responsable : Ayo)
- K1. Bouton « Tout arrêter » dans l'app, qui annule les tours en cours de tous les profils via la route d'annulation (S3, à vérifier). Rapide, mais dépend de l'app et du tunnel.
- K2. Arrêt du serveur API sur la VM par Ayo (service arrêté ou `API_SERVER_ENABLED=false` puis redémarrage). Effet sur un tour et des outils en cours : `unknown`.
- K3. Arrêt du processus Hermes (gateway) du profil sur la VM par Ayo. Le plus sûr, mais coupe aussi les autres clients du profil.
- Couper le tunnel : **insuffisant** (accepté par l'utilisateur).
- **Recommandation** : K1 comme premier niveau si S3 le confirme, et K3 comme recours garanti, procédure écrite dans le runbook. Choix final : Q2.

### A. Serveur API : activation
- A-a. Spike et recette entièrement sur l'instance OrbStack, serveur API activé seulement là (par Engineer, dans le conteneur). Activation sur example-host plus tard, **par l'utilisateur lui-même**, après la recette.
- A-b. Activation sur example-host dès le spike. Rejetée : contredit « ne jamais toucher à la production example-host ».
- **Recommandation** : A-a. Aucun bot n'active rien sur example-host. Q3 couvre aussi le routage (S7).

### M. Version minimale de macOS et distribution
- Version du MacBook : `unknown`.
- Options de version minimale : macOS 14, 15 ou 26. **Recommandation** : la version installée sur le MacBook, sans descendre sous macOS 14 (API SwiftUI récentes), à confirmer après relevé de la version.
- Distribution : (d1) build local signé ad hoc, usage personnel, aucune dépense ; (d2) Developer ID signé et notarisé, demande un compte Apple Developer payant, donc une dépense à accord écrit ; (d3) Mac App Store, bac à sable difficile avec un tunnel SSH, rejetée.
- **Recommandation** : d1 pour la v1. Q4.

### S. Secrets de test
- Les clés de l'instance OrbStack sont générées pour le test seulement ; elles ne servent jamais pour example-host.
- Stockage : sur le Mac, Trousseau (trousseau de test dédié ou mode de test sans Trousseau réel) ; en CI, secrets GitHub chiffrés. Jamais dans le chat, le dépôt ou un fichier du dossier SkeinBot.
- Modèle pour la recette : (s1) faux fournisseur de modèle ou rejeu de réponses enregistrées, aucun coût ; (s2) modèle local gratuit dans le conteneur, coût nul, ressources du Mac ; (s3) abonnement ou quota déjà payé, sans dépense nouvelle ; (s4) API payante nouvelle, interdite sans accord écrit.
- **Recommandation** : s1 pour la CI et la majorité des tests, s2 ou s3 pour les tests de bout en bout. Q6.

### B. Seuils de boucle
- Valeurs A2 ci-dessus : propositions de Dev Lead, non mesurées.
- Options de calibrage : (b1) garder les valeurs proposées et le démarrage à froid, recalibrer après 20 tours réels par profil ; (b2) calibrer sur l'instance de test pendant le spike (données peu représentatives) ; (b3) lire l'historique de example-host en lecture seule (demande l'accord de l'utilisateur, déconseillé).
- **Recommandation** : b1 + b2. X minutes reste `unknown` ; Dev Lead propose une valeur au spike. Q7.

### Ci. CI macOS
- (c1) Linux seul ; tests macOS faits par Engineer sur le MacBook à 13 h 00. (c2) runner macOS GitHub en plus : minutes macOS facturées si le dépôt est privé et le quota dépassé, coût `unknown`.
- **Recommandation** : c1, et c2 seulement dans le quota gratuit ou après accord écrit. Q5.

## Vérification (Verification)
Le producteur du code (Claude Code, Codex) ne vérifie jamais seul. Engineer exécute, Dev Lead vérifie le rapport, l'utilisateur valide.

| Ce qui est vérifié | Comment | Qui | Fréquence |
|---|---|---|---|
| Couche d'adaptation contre les fixtures (version actuelle et précédente) | Tests automatiques, CI Linux | CI + Dev Lead (verdict indépendant) | Chaque PR |
| Les six actions par l'API, sur chaque profil actif : liste, conversation, `/model`, approbation, outil en cours, reprise après veille simulée (coupure réseau ou événement injecté) | Tests automatiques contre l'instance OrbStack | Engineer, rapport à Dev Lead | Chaque recette |
| Robustesse 1 : version récente de Hermes | L'app reste utilisable, message clair | Engineer | Chaque recette |
| Robustesse 2 : réponse avec champs ajoutés ou retirés | Idem | Engineer (fixture) | Chaque PR et recette |
| Robustesse 3 : route supprimée | Seule la fonction touchée est désactivée, message clair | Engineer (fixture) | Chaque PR et recette |
| API injoignable ou lente | Erreur propre, pas de gel | Engineer | Chaque recette |
| Captures de référence du rendu | XCUITest + comparaison | Engineer (macOS) | Chaque recette |
| Aucun profil décommissionné affiché ; changement de liste validé avant affichage | Comparaison à la liste active | Engineer, puis utilisateur | Chaque recette |
| Approbation oui et non, outil et paramètres visibles | Provoquer une demande, répondre oui puis non | Engineer | Chaque recette |
| Événement inconnu ignoré ; état terminal d'échec affiché | Injection d'événement ; tour échoué, annulé, interrompu | Engineer | Chaque recette |
| Coupure pendant un envoi ; pendant une approbation en attente | Pas de doublon ; approbation toujours affichée | Engineer | Chaque recette |
| Fils passés listés et rouvrables | `/new`, puis réouverture | Engineer | Chaque recette |
| Concurrence Desktop (deux ordres) | Selon S9 ; si Desktop n'est pas testable contre OrbStack, test manuel | Engineer ou utilisateur | Avant livraison |
| Garde-fou de boucle : pause + notification, jamais silencieux | Boucle provoquée sur l'instance de test | Engineer | Chaque recette |
| Kill switch | Déclenchement pendant un tour ; le travail s'arrête côté VM (test) | Ayo, avec Engineer | Avant livraison |
| Aucune connexion hors tunnel | Observation des connexions sortantes | Engineer | Avant livraison |
| Chemins protégés inchangés | Contrôle avant et après chaque passe | Engineer | Chaque passe |
| Tests à la main : jugement visuel final, veille réelle du Mac, Trousseau au premier lancement | Manuel | Utilisateur | Avant livraison |
| **Test quotidien de compatibilité** | Rapport daté : date et heure (Paris), version de Hermes, PASS/FAIL par contrat, écarts, durée, vérification des chemins protégés | Engineer → Dev Lead ; alerte utilisateur seulement si FAIL ou chemin protégé modifié | Chaque jour, 13 h 00 (Paris) |
| Validation finale de la v1 | Revue des rapports + tests à la main | Utilisateur | Une fois |

## Actions irréversibles (Irreversible actions)
| Action | Qui peut | Qui doit approuver |
|---|---|---|
| Approuver ou refuser un outil demandé par un bot | L'utilisateur, dans l'app, après avoir vu outil et paramètres | L'utilisateur, à chaque demande |
| Activer le serveur API sur example-host | L'utilisateur lui-même, hors roster | L'utilisateur (Ayo décide) |
| Toute commande sur le Mac (conteneur, tests) | Engineer, dans le périmètre de son exception | L'utilisateur, commande par commande |
| Ajouter ou retirer une version prise en charge (fixtures) | Dev Lead via PR | Verdict indépendant + l'utilisateur |
| Dépense payante nouvelle (API, runner macOS, compte Apple) | Personne sans accord | L'utilisateur, par écrit |
| Merge | Propriétaire de la PR, après verdict indépendant (règle poteto) ; jamais de push sur main par Engineer | Verdict Dev Lead + CI verte |
| Envoyer, publier, supprimer, engagement juridique | L'app ne le fait pas elle-même ; un outil d'un bot passe par l'approbation | L'utilisateur, à chaque demande |
| Kill switch | Ayo | Aucune (immédiat) |

## Budget (Budget)
| Poste | Plafond | Par | Si le plafond est atteint |
|---|---|---|---|
| Tokens et usage des modèles | `unknown` (l'utilisateur refuse un plafond chiffré) | — | Pas de plafond : le garde-fou relatif (A2) met en pause ; aucune dépense payante nouvelle sans accord écrit |
| Crédits d'API payantes nouvelles | `unknown` | — | Aucune dépense tant que l'utilisateur ne l'a pas autorisée par écrit |
| Runner macOS GitHub, compte Apple Developer | `unknown` | — | Idem |
| Argent (€) | `unknown` | — | Idem |

Le relevé de tokens par run est automatique (source `unknown`, S10) et nourrit le garde-fou. Il n'est pas un plafond.

## Cadence et livraison (Cadence and delivery)
- App : usage à la demande, conversationnel.
- Test quotidien de compatibilité : chaque jour à 13 h 00, heure de Paris (Europe/Paris), Engineer, utilisateur présent pour approuver. Si l'utilisateur est absent, le test est sauté et noté « non exécuté » dans le rapport (jamais simulé).
- Rapports : fichiers datés dans l'état du Roster Dev (`/workspace/dev-roster/`, chemin exact à fixer par Dev Lead), format Markdown.
- Livraison v1 : app macOS native, distribution selon Q4.

## Modes d'échec (Failure mode)
- Tunnel coupé ou Mac en veille : le tour continue sur la VM ; reprise par identifiant, sans doublon ; approbation en attente toujours affichée.
- Tour échoué, annulé ou interrompu : état réel affiché, jamais masqué.
- Version de Hermes inconnue ou route changée : mode dégradé, fonctions touchées désactivées, message clair. Jamais d'arrêt de l'app.
- Profil tenu par Desktop : refus d'ouverture ou arrêt d'envoi, avec la raison.
- Boucle détectée : pause + notification ; jamais d'annulation silencieuse.
- Source des tokens absente : le signal « tokens » est désactivé et signalé ; les autres signaux restent actifs.
- Test quotidien non exécuté (utilisateur absent, conteneur en panne) : rapport « non exécuté » avec la cause. Jamais de résultat inventé.
- Chemin protégé modifié : arrêt immédiat de la passe, alerte utilisateur.
- Point impossible au spike : v1 non livrable telle qu'écrite ; l'utilisateur décide.

## Contraintes (Constraints)
- macOS natif. Un seul transport : tunnel SSH vers le serveur API sur `127.0.0.1:8642` (sous réserve de S7).
- Aucun runtime ni CLI Hermes sur macOS ; rien dans `~/.hermes/hermes-agent` ni `~/.local/bin/hermes`.
- Aucune modification ni test sur la production example-host par un bot.
- Six actions client seulement ; une seule couche d'adaptation versionnée.
- Secrets dans le Trousseau macOS (ou secrets CI chiffrés) ; jamais en clair, jamais dans le chat.
- Aucune route d'API affirmée avant le spike.
- **Tension avec la CHARTE** : la CHARTE (§ Roster Dev) dit « aucun clone sur le Mac ; code, tests et vérif sur cloud agents Cursor ». Le nouveau contexte (code écrit sur le Mac par Claude Code et Codex) s'en écarte. Ce PRD ne tranche pas : décision utilisateur (Q1), puis mise à jour de la CHARTE par Manager seul.

## Risques (Risks)
| Risque propre au projet | Probabilité | Impact | Parade | Responsable |
|---|---|---|---|---|
| Une route nécessaire (run, reprise, annulation, `/model`, sessions, profils) n'existe pas dans l'API | `unknown` | Élevé | Spike d'abord ; constat par point ; décision utilisateur | Dev Lead |
| Une mise à jour de Hermes casse une fonction | `unknown` | Moyen (mode dégradé) | Couche d'adaptation unique, fixtures par version, test quotidien | Engineer |
| Le test quotidien est bloqué faute d'approbation (utilisateur absent à 13 h 00) | `unknown` | Moyen | Créneau fixe choisi par l'utilisateur ; rapport « non exécuté » visible | Engineer |
| Une passe de test écrit dans `~/.hermes/hermes-agent` ou `~/.local/bin/hermes` et bloque l'updater de Desktop | `unknown` | Élevé | Conteneur sans montage, contrôle avant/après, arrêt immédiat | Engineer |
| Un test ou une commande touche example-host | `unknown` | Élevé | Cible unique OrbStack ; aucun secret de prod dans l'environnement de test | Engineer |
| L'annulation côté serveur n'arrête pas un outil déjà lancé (kill switch incomplet) | `unknown` | Élevé | S3 vérifie l'effet réel ; recours K3 | Ayo |
| Les seuils de boucle, non mesurés, mettent en pause trop souvent ou trop tard | `unknown` | Moyen | Démarrage à froid, calibrage au spike puis après 20 tours | Dev Lead |
| Pas de source de tokens par run : un signal du garde-fou manque | `unknown` | Moyen | Signal désactivé et signalé ; autres signaux actifs | Dev Lead |
| Code sur le Mac hors du cadre de la CHARTE | `unknown` | Moyen | Q1 ; mise à jour de la CHARTE par Manager avant tout code | Utilisateur |
| L'app et Desktop écrivent la même session | `unknown` | Élevé | Refus et arrêt d'envoi ; mécanisme S9 | Dev Lead |
| Serveur API exposé au-delà de `127.0.0.1` | `unknown` | Élevé | Écoute locale, tunnel seul, clé obligatoire | Ayo |
| Message envoyé deux fois après coupure | `unknown` | Moyen | Reprise par identifiant (S2), scénario de recette | Engineer |
| Dépense involontaire (runner macOS, API payante) | `unknown` | Moyen | Aucune dépense sans accord écrit | Dev Lead |

## Décideur humain (Human executive)
- **Ayo** : kill switch, et les deux questions ci-dessous.
- **L'utilisateur** : validation finale, toute dépense, activation du serveur API sur example-host, approbation de chaque commande sur le Mac, suite à donner si le spike constate une impossibilité, questions de la dernière section.

## Questions ouvertes (Open questions)
**À trancher par Ayo, recopiées telles quelles :**
- La liste montre tous les profils actifs, ou seulement une liste épinglée.
- Le texte exact du bouton de nouvelle session.

**Techniques** : les points S1 à S12 du spike, tous `unknown` jusqu'à son rapport.

## Historique des décisions (heure de Paris)
- 14/10/2026 : profils actifs relevés ; PRD d'origine (`prd.md`).
- 17/10/2026 11 h 43 : triple vérification ; version finale v2.
- 17/10/2026 11 h 53 et 11 h 55 : pas de plafond de tokens, budget `unknown` sans dépense nouvelle (A1) ; garde-fou de boucle relatif (A2) ; tâches automatisées (A3) ; spike (A4) ; testabilité (A5). Acceptés : couper le tunnel ne suffit pas, point 7 « fils passés », `/reset` retiré, Trousseau, spike.
- 17/10/2026 12 h 00 : l'app ne s'arrête jamais sur évolution de Hermes (A7) ; tests sur le MacBook avec Hermes dans OrbStack, jamais en production (A8).
- 17/10/2026 12 h 02 – 12 h 03 : Engineer responsable proposé du test quotidien (A9) ; couche d'adaptation versionnée et fixtures (A10).
- 17/10/2026 12 h 04 – 12 h 05 : test quotidien à créneau fixe, 13 h 00 (A11) ; exception Mac d'Engineer validée par écrit (A12).
- 18/10/2026 : consolidation ; code écrit sur le Mac par Claude Code et Codex ; CI Linux avec runner macOS possible ; recette et test quotidien confiés à Engineer.

## Porte de clôture (auto-contrôle)
- Kill switch avec responsable nommé : **oui** (Ayo ; moyen recommandé K1 + K3, choix Q2).
- Budget plafonné ou `unknown` sans dépense : **oui** (`unknown`, aucune dépense payante nouvelle sans accord écrit).
- Vérification pas faite par le seul producteur : **oui** (Engineer exécute, Dev Lead vérifie, l'utilisateur valide).
- Au moins un risque propre au PRD : **oui** (chemins protégés de Desktop, test bloqué à 13 h 00, routes absentes…).
- Rubriques obligatoires : toutes présentes ; les inconnues sont marquées `unknown` avec ce qui casse.

## Questions pour validation finale
1. **Où s'écrit le code ?** La CHARTE interdit tout clone sur le Mac. Options : (a) code sur le Mac par Claude Code et Codex, usage humain conduit par l'utilisateur, CHARTE mise à jour par Manager ; (b) code sur cloud agents Cursor, Mac réservé aux tests d'Engineer. **Recommandé : (a), avec mise à jour écrite de la CHARTE avant tout code.**
2. **Kill switch, moyen technique.** **Recommandé : bouton « Tout arrêter » (annulation API, si S3 la confirme) + arrêt du processus Hermes sur la VM par Ayo en recours garanti.**
3. **Serveur API et routage.** **Recommandé : activé seulement dans l'instance OrbStack pour le spike et la recette ; sur example-host, activé plus tard par l'utilisateur lui-même ; routage multi-profils sur 8642 si S7 le confirme, sinon décision d'amender le port unique.**
4. **macOS et distribution.** **Recommandé : version minimale = celle du MacBook (au moins macOS 14) ; build local signé ad hoc, sans compte Apple payant.**
5. **CI macOS.** **Recommandé : CI Linux pour la couche d'adaptation et les fixtures ; tests macOS par Engineer sur le MacBook ; runner macOS GitHub seulement dans le quota gratuit ou après accord écrit.**
6. **Modèle et secrets de test.** **Recommandé : faux fournisseur ou rejeu en CI ; modèle local gratuit ou quota déjà payé pour le bout en bout ; clés de test générées pour OrbStack, au Trousseau et dans les secrets CI.**
7. **Seuils de boucle et X minutes.** **Recommandé : valeurs A2 de Dev Lead + démarrage à froid, calibrage au spike puis après 20 tours ; X proposé par Dev Lead au spike, non mesuré.**
8. **Forme de la notification de pause.** Options : bannière dans l'app seulement, ou notification macOS en plus. **Recommandé : les deux (seule exception au hors-périmètre « Notifications »).**
9. **Test quotidien manqué.** **Recommandé : rapport « non exécuté », pas de rattrapage automatique ; l'utilisateur peut le relancer à la main.**
10. **Spike contre la VM.** **Recommandé : aucun accès à example-host pendant le spike ; documentation, code et OrbStack suffisent.**
11. **Version de Hermes pour l'instance de test.** **Recommandé : la même que example-host (relevée par l'utilisateur, pas par un bot) et la précédente, pour les fixtures.**
12. **Critère de stabilité du test quotidien.** **Recommandé : 5 jours ouvrés consécutifs avec rapport complet avant livraison.**
13. **Questions d'Ayo** (liste tous profils ou épinglée ; libellé du bouton). **Recommandé : Ayo les tranche avant la recette ; ce PRD ne les tranche pas.**
