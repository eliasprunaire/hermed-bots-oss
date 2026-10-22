# Swarm : app macOS native qui pilote les bots Hermes

> Spec v2 (16 sections), 18/10/2026, heure de Paris. Source : `prd-consolide.md` (même dossier). Aucun bot, groupe ou routine n'est créé par ce document : tout ce qui suit est une description et des propositions.

## 1. PRD digest
- **Résultats** : liste des bots (9 profils actifs), conversation, `/model`, approbation oui/non, outil en cours, `/new`, fils passés ; reprise après veille ; l'app ne s'arrête jamais quand Hermes évolue (mode dégradé). Acceptation : six actions sur les 9 profils (instance OrbStack), aucune connexion hors tunnel SSH, trois tests de robustesse passés, test quotidien stable, validation finale de l'utilisateur.
- **Dans le périmètre** : les 8 points du PRD (dont garde-fou de boucle et mode dégradé). **Hors** : iOS, fichiers, voix, cron, éditeurs, notifications générales, création de profil, Internet, profils décommissionnés, tout autre transport, toute action d'un bot sur perso-hermes.
- **Sources de vérité** : `hermes profile list` (14/10), doc Hermes (3 pages), code Hermes testé (lecture seule), sessions sur perso-hermes, fixtures par version.
- **Actions irréversibles** : approbation d'outil (utilisateur) ; activation du serveur API sur perso-hermes (utilisateur lui-même) ; commandes sur le Mac (approuvées une à une) ; dépense (accord écrit) ; merge (règle poteto) ; kill switch (Ayo).
- **Cadence** : app à la demande ; test quotidien de compatibilité à 13 h 00 Europe/Paris ; rapports Markdown datés dans `/workspace/dev-roster/` (chemin exact par Dev Lead).
- **Contraintes** : macOS natif ; tunnel SSH vers `127.0.0.1:8642` ; rien dans `~/.hermes/hermes-agent` ni `~/.local/bin/hermes` ; jamais perso-hermes ; Trousseau ; couche d'adaptation unique ; aucune route affirmée avant le spike.
- **Fin / arrêt** : §14. **Budget** : `unknown`, aucune dépense nouvelle sans accord écrit (§15). **Vérification** : Engineer exécute, Dev Lead vérifie, utilisateur valide (§16).

## 2. Assumptions and unknowns
| Affirmation | Nature | Si c'est faux, ce qui casse |
|---|---|---|
| Le serveur API Hermes expose runs, sessions, annulation | unknown (S1–S5) | Actions, reprise, kill switch K1 |
| Un port 8642 sert 9 profils (préfixe `/p/<profil>/`) | unknown, d'après la doc (S7) | Contrainte « transport unique » à amender |
| La version de Hermes est lisible par l'API | unknown (S8) | Mode dégradé fondé sur les seuls tests de contrat |
| Les tokens par run sont disponibles | unknown (S10) | Signal « tokens » du garde-fou désactivé |
| Desktop est détectable dans les deux ordres | unknown (S9) | Risque d'écriture concurrente |
| Hermes tourne proprement dans un conteneur OrbStack | assumption | Recette impossible sur le Mac sans toucher macOS ; replan |
| La couche d'adaptation compile et se teste sous Linux (Swift) | assumption | Tests de contrat seulement sur macOS |
| Exception Mac d'Engineer validée le 17/10 à 12 h 05 | user-stated, déjà dans la CHARTE | — |
| Code écrit sur le Mac par Claude Code et Codex | user-stated, contraire à la CHARTE actuelle | Blocage jusqu'à Q1 et mise à jour de la CHARTE par Manager |
| L'utilisateur est présent à 13 h 00 | user-stated | Test quotidien « non exécuté » |
| Version macOS du MacBook | user-stated : macOS 27.0.1 (relevé le 19/10/2026) ; Q4 tranchée le 19/10 à 06 h 37 : d1, minimum macOS 27 | Version minimale (Q4) |

## 3. Why this topology
Un projet de développement unique, déjà couvert par le Roster Dev (Dev Lead chef, Engineer environnement/vérification/CI), plus Designer pour l'interface. Le code est produit par des outils (Claude Code, Codex) conduits par l'utilisateur sur son Mac, pas par un bot du roster. Pas de nouveau crew : la chaîne SkeinBot → Dev Lead → production du code → PR → verdict indépendant existe déjà. Un seul chef (Dev Lead), conformément à la CHARTE.

## 4. Human authority
- **Ayo** : kill switch (moyen recommandé K1 + K3, §14) ; les deux questions de la liste et du libellé.
- **Utilisateur** : validation finale ; approbation de chaque commande sur le Mac ; toute dépense ; activation du serveur API sur perso-hermes, faite par lui-même ; décision si le spike constate une impossibilité ; réponses aux questions de validation finale du PRD.
- Aucun bot ne devient le décideur responsable. Aucun bot n'agit sur perso-hermes.

## 5. Roster
| Siège | Statut | Rôle sur ce projet | Lit | Écrit | Interdit |
|---|---|---|---|---|---|
| SkeinBot | existant | PRD et spec ; mises à jour après décisions | `/workspace/skein/` | `/workspace/skein/app-macos-bots-hermes-v1/` | Code, déploiement, création de bot |
| Dev Lead | existant (chef) | Plan poteto, briefs, propositions de seuils, lancement du vérificateur indépendant, verdict des rapports d'Engineer | PRD, spec, rapports | `/workspace/dev-roster/hermes-v1/` (plan, briefs, verdicts) | Exécuter sur le Mac, merger sans verdict |
| Engineer | existant + exception Mac | Instance OrbStack, spike pratique, CI, recette, test quotidien 13 h 00, contrôle des chemins protégés | Dépôt (lecture), fixtures | Rapports datés ; dossier de travail dédié sur le Mac ; conteneur dédié | `~/.hermes/hermes-agent`, `~/.local/bin/hermes`, perso-hermes, push sur main, toute autre action sur le Mac |
| Designer | existant (Atelier UI) | Maquettes des écrans (liste, conversation, approbation, mode dégradé, pause de boucle), identifiants d'accessibilité proposés | PRD, spec | Maquettes | Coder, merger, vérifier les PR |
| Claude Code, Codex | outils, pas des bots | Écriture du code sur le Mac, conduits par l'utilisateur (sous réserve de Q1) | — | Branches et PR | Se vérifier eux-mêmes ; push sur main |
| Manager | existant | Mise à jour de la CHARTE si Q1 = (a) ; vérification avant toute modification de fiche | CHARTE | CHARTE | Entrer dans le salon de métier |
| dr eggbot | existant | Modification de fiche seulement après feu vert écrit de Manager (si nécessaire) | — | Fiches | Agir sans Manager |

**Aucun nouveau bot n'est proposé** : Dev Lead, Engineer et Designer couvrent tous les besoins. Le test quotidien est une routine d'Engineer, pas un bot.

## 6. Rooms and handoffs
- Pas de nouveau salon : échanges Dev Lead ↔ Engineer dans le cadre existant du Roster Dev.
- **SkeinBot → Dev Lead** : `prd-consolide.md` + `spec.md` + réponses de l'utilisateur aux questions de validation.
- **Dev Lead → Engineer** (brief obligatoire, refusé si un champ manque) : chemins à lire et écrire, critère de fin, unfinished, cible (instance OrbStack uniquement), liste des chemins protégés.
- **Dev Lead → Designer** : écrans et états à maquetter, critère de fin.
- **Engineer → Dev Lead** : rapport daté (format §16). Dev Lead → utilisateur : seulement FAIL, chemin protégé modifié, besoin de décision.
- **Dev Lead → producteur de code** : brief de tâche issu du plan poteto ; retour par PR.

## 7. Shared state
- `/workspace/skein/app-macos-bots-hermes-v1/` : PRD, spec, triple vérification.
- `/workspace/dev-roster/hermes-v1/` (proposé) : `plan.md`, `spike/` (S1–S12), `rapports/AAAA-MM-JJ-1300.md`, `verdicts/`, `couts.md`.
- Dépôt GitHub : code, fixtures `Fixtures/<version-hermes>/`, workflow CI.
- **Journal de vérification** : `rapports/` (test quotidien et recette) + commentaires de verdict sur les PR.
- Aucun secret dans ces emplacements.

## 8. Skills vs routines
| Élément | Type | Siège | Critère d'arrêt (§14) | Budget (§15) |
|---|---|---|---|---|
| Spike S1–S12 | tâche ponctuelle | Dev Lead (doc), Engineer (OrbStack) | Chaque point constaté ou déclaré impossible | Aucune dépense ; modèle gratuit ou rejeu |
| Recette | tâche par build candidat | Engineer | Chemin protégé modifié ; perte d'approbation ; FAIL bloquant | Idem |
| **Test quotidien 13 h 00** | **routine candidate** (non créée) | Engineer | Utilisateur absent → « non exécuté » ; chemin protégé modifié → arrêt ; 2 FAIL consécutifs identiques → pause et décision de Dev Lead (proposition) | Aucune dépense nouvelle |
| Vérification poteto des PR | skill existante | Dev Lead (vérificateur) | Règle poteto | `couts.md` |
La routine n'est créée qu'après validation du PRD, par le circuit Manager → dr eggbot. Ce document ne la crée pas.

## 9. Approval matrix
| Action | Engineer | Dev Lead | Producteur de code | Utilisateur | Ayo |
|---|---|---|---|---|---|
| Commande sur le Mac | propose | — | — | **approuve chaque commande** | — |
| Toucher perso-hermes | jamais | jamais | jamais | lui-même seulement | — |
| Activer le serveur API sur perso-hermes | jamais | jamais | jamais | **fait lui-même** | — |
| Merge | jamais sur main | verdict | propriétaire de PR après verdict | — | — |
| Ajouter une version aux fixtures | propose | verdict | PR | informé | — |
| Dépense payante (API, runner, Apple) | demande | demande | — | **accord écrit** | — |
| raise-budget-cap | — | ask | — | **décide** | — |
| stop / kill switch | peut stopper sa passe | peut stopper le plan | — | toujours | **toujours (responsable)** |

## 10. Marketplace option (per seat)
Sans objet : tous les sièges existent. Aucun siège à recruter.

## 11. First-week rollout
- **Jour 0** : l'utilisateur répond aux questions de validation finale (Q1 en premier) ; Manager met à jour la CHARTE si besoin.
- **Jour 1 – Spike, partie documentaire** : Dev Lead lit doc et code Hermes en lecture seule, remplit S1–S10 avec « à vérifier » ou une référence.
- **Jour 2 – Spike, partie OrbStack** : Engineer, à 13 h 00 avec l'utilisateur, monte l'instance propre (contrôle des chemins protégés avant/après), active le serveur API dans le conteneur seulement, constate S1–S12. Le premier passage est vérifié comme le dit §16 (Dev Lead relit le rapport) avant toute discussion de routine.
- **Jour 3** : rapport du spike ; décision utilisateur si un point est impossible ; Dev Lead écrit le plan poteto.
- **Jours 4–5** : premières tâches : couche d'adaptation + fixtures (CI Linux) ; maquettes Designer ; premier test quotidien manuel.

**Plan poteto (ordre)** :
1. Spike S1–S12 (sortie : rapport).
2. Paquet Swift de la couche d'adaptation, décodage tolérant, fixtures version actuelle et précédente, CI Linux.
3. Garde-fou de boucle (logique pure, CI Linux).
4. Tunnel SSH + Trousseau + mode de test sans Trousseau (macOS).
5. Interface : liste, conversation, approbation, outil en cours, `/new`, fils passés, mode dégradé, pause (identifiants d'accessibilité).
6. Reprise après veille, anti-doublon.
7. Concurrence Desktop.
8. Kill switch K1.
9. Recette complète, puis test quotidien sur 5 jours ouvrés, puis validation finale.

## 12. Risks
| Risque (propre à ce PRD) | Probabilité | Impact | Parade | Responsable |
|---|---|---|---|---|
| Route absente pour une action, la reprise ou l'annulation | unknown | Élevé | Spike d'abord ; décision utilisateur | Dev Lead |
| Écriture dans `~/.hermes/hermes-agent` ou `~/.local/bin/hermes` (updater Desktop bloqué) | unknown | Élevé | Conteneur sans montage ; contrôle avant/après ; arrêt immédiat | Engineer |
| Contact avec perso-hermes pendant les tests | unknown | Élevé | Cible unique OrbStack ; aucun secret de prod côté test | Engineer |
| Test quotidien bloqué (utilisateur absent à 13 h 00) | unknown | Moyen | Rapport « non exécuté » | Engineer |
| Code produit sur le Mac hors CHARTE | unknown | Moyen | Q1 + mise à jour CHARTE avant tout code | Utilisateur / Manager |
| Producteur de code qui se vérifie seul | unknown | Moyen | Verdict indépendant poteto + rapport d'Engineer | Dev Lead |
| Seuils de boucle mal calibrés | unknown | Moyen | Démarrage à froid ; calibrage | Dev Lead |
| Dépense involontaire (runner macOS GitHub) | unknown | Moyen | CI Linux par défaut ; accord écrit | Dev Lead |
| Fuite de secret de test (credential bleed sur ordinateur partagé) | unknown | Élevé | Trousseau / secrets CI ; rien dans les fichiers | Engineer |

## 13. Open questions
- S1–S12 (spike), tous `unknown`.
- Questions d'Ayo, recopiées telles quelles : « La liste montre tous les profils actifs, ou seulement une liste épinglée. » ; « Le texte exact du bouton de nouvelle session. »
- Questions pour validation finale Q1–Q13 du PRD (Q1 conditionne le roster).
- Chemin exact des rapports dans `/workspace/dev-roster/` : Dev Lead.

## 14. Done and stop criteria
| Niveau | Fini quand | Stop / pause quand | Qui arrête | Comment |
|---|---|---|---|---|
| tour (app) | événement terminal affiché | signal de boucle A2 | l'app (auto), puis l'utilisateur | pause + notification, jamais silencieux |
| passe de test | rapport écrit | chemin protégé modifié ; utilisateur absent ; cible ≠ OrbStack | Engineer | arrêt immédiat, rapport, alerte |
| spike | S1–S12 constatés | point bloquant impossible | Dev Lead → utilisateur | rapport, décision utilisateur |
| routine test quotidien | — (continue pendant le projet) | 2 FAIL identiques (proposition) ; exception révoquée | Dev Lead, utilisateur | pause de la routine |
| projet v1 | acceptation + validation finale | décision utilisateur | utilisateur | arrêt du plan |
Kill switch : **Ayo** ; K1 bouton « Tout arrêter » (annulation API si S3 la confirme) puis K3 arrêt du processus Hermes sur la VM. Couper le tunnel ne suffit pas. Travail en cours : sessions conservées sur la VM, rien supprimé ; branches et rapports gardés.

## 15. Budget
| Poste | Plafond | Par | Siège | Si atteint |
|---|---|---|---|---|
| Tokens / modèles | unknown (pas de plafond chiffré, décision utilisateur) | — | Dev Lead | garde-fou relatif (pause) ; aucune dépense nouvelle |
| Crédits API payantes nouvelles | unknown | — | Dev Lead | aucune dépense sans accord écrit |
| Runner macOS GitHub | unknown | — | Engineer | quota gratuit seulement, sinon accord écrit |
| Argent (€), compte Apple | unknown | — | utilisateur | aucune dépense sans accord écrit |
Coûts de vérification suivis dans `couts.md` (règle poteto).

## 16. Verification
| Sortie | Preuve | Vérificateur (pas seulement le producteur) | Échantillon | Preuve conservée |
|---|---|---|---|---|
| Rapport de spike | Chaque S a une référence (doc, code, observation) ou un constat d'impossibilité ; aucune route inventée | Dev Lead + utilisateur | tous les points | `spike/` |
| Couche d'adaptation | Tests de contrat sur les fixtures (2 versions), robustesse champs/route | CI Linux + vérificateur Dev Lead | chaque PR | PR + CI |
| App | Recette du PRD (six actions, approbation, veille, coupures, fils passés, Desktop, boucle, connexions, captures) | Engineer exécute, Dev Lead vérifie | chaque build candidat | `rapports/` |
| Test quotidien | Rapport : date/heure Paris, version Hermes, PASS/FAIL par contrat, écarts, durée, chemins protégés | Engineer → Dev Lead | chaque jour 13 h 00 | `rapports/` |
| Kill switch | Le travail s'arrête côté VM de test | Ayo + Engineer | avant livraison | `rapports/` |
| v1 | Tests à la main (visuel, veille réelle, Trousseau) | Utilisateur | une fois | `rapports/validation-finale.md` |
Échec d'un contrôle : correction par PR puis nouvelle passe ; chemin protégé modifié ou contact perso-hermes → arrêt et alerte immédiate à l'utilisateur ; impossibilité → décision utilisateur.
