---
style_gate: pass
---

# S9. Détecter un profil tenu par Hermes Desktop

Le backend Desktop porte `HERMES_DESKTOP=1` et exécute la commande `serve`.
Le Gateway API exécute `gateway` et ne compte pas comme détenteur Desktop.
La sonde lit les processus du compte SSH et leurs fichiers ouverts.
Elle ne lance aucun backend et ne prend aucun verrou.

```text
SSH -> processus Desktop -> profils tenus -> garde des écritures -> message dans l'app
```

## Observation sur hv-hermes-test

La passe du 21 octobre 2026 utilise l'image `hv-hermes:spike`, Hermes 0.22.2.
Le conteneur ne monte aucun dossier de l'hôte.
[hd14-s9.json](hd14-s9.json) conserve les résultats des deux ordres.

1. Le Gateway seul rend `held=[]`.
2. Le backend Desktop démarré avant la lecture API rend `held=["hv-bot-a"]`.
3. Le backend Desktop démarré après la lecture API rend le même résultat.
4. La fin du backend rend `held=[]`.

Les deux profils répondent HTTP 200 au Gateway pendant la prise.
Le serveur ne protège donc pas lui-même ces écritures.
La garde côté client reste nécessaire.

La sonde utilise `--profile` ou `-p`, puis `HERMES_HOME` pour identifier le profil principal.
Elle ajoute les profils dont ce backend garde `state.db` ou ses fichiers WAL ouverts.
Elle ignore les processus disparus pendant la lecture.
Une permission refusée, une dépendance absente ou une sortie invalide produit un état inconnu.
Cet état bloque les écritures.

La source installée de Desktop confirme ce lancement dans `buildSpawnCommand`.
Elle emploie `env HERMES_DESKTOP=1 hermes --profile <profil> serve --isolated`.
Desktop permet un chemin Hermes distant explicite.
Aucune installation ni modification de Desktop n'a été nécessaire.
La documentation officielle décrit les [profils Hermes](https://hermes-agent.nousresearch.com/docs/user-guide/profiles).

## Reproduction

Exécuter depuis la racine du dépôt, sur le seul conteneur jetable nommé `hv-hermes-test`.
La clé de test reste dans son environnement.

```bash
docker cp docs/spike/hd14-instruments/s9.py hv-hermes-test:/tmp/hd14-s9.py
docker exec -i -u hermes hv-hermes-test python3 /tmp/hd14-s9.py < docs/spike/hd14-instruments/probe.py
```

La sonde de production est intégrée dans `ProfileLock.swift`.
`probe.py` conserve le même programme pour la reproduction sur OrbStack.
`python3` et `psutil` doivent être disponibles dans le PATH du compte SSH.
Leur absence affiche le mode dégradé et bloque les écritures.

## Limites observées

Cette passe lance le backend réel de Desktop dans le conteneur Linux.
Elle ne pilote pas l'application graphique Desktop.
Le conteneur Linux ne peut pas exécuter cette application macOS.
Le lanceur ne relie pas encore la VM macOS à OrbStack.
Les deux ordres avec les deux applications graphiques restent manuels.
Aucun parcours UI ne tourne sur l'hôte.

La détection relit les processus chaque seconde.
Chaque écriture relit aussi la détection avant son appel API.
Un backend apparu après cette dernière lecture peut encore croiser une requête déjà partie.
Hermes ne fournit pas de réservation atomique du profil par cette API.
Un tour déjà accepté peut continuer sur Hermes après le blocage local.

Les tests UI indépendants injectent un relevé libre en mode test Debug.
`ConcurrencyTests` active `HV_PROFILE_LOCKS=1` et utilise le proxy `fake.py`.
Ce proxy ajoute le relevé simulé sans refuser les écritures.
Les tests doivent donc eux-mêmes prouver leur absence dans `/_hv/log`.
La Release ignore ce mode test.

## Recette UI et mesure

La recette s'exécute exclusivement dans la VM du lanceur.
La référence vient du commit `e2b98b8f07ebe91bc147bdb506670efb0f367bb8`.
L'archive reste un fichier de travail local.

```bash
git archive e2b98b8f07ebe91bc147bdb506670efb0f367bb8 HermedBots HermedBots.xcodeproj Packages > docs/spike/hd14-instruments/trunk-source.tar
timeout 3600 zsh ~/<INFRA>/<vm-test-script> exec bash docs/spike/hd14-instruments/run-all.sh
timeout 3600 zsh ~/<INFRA>/<vm-test-script> ui fake
```

Le harnais exécute les lanes successivement.
Il alterne ensuite cinq prises sur trunk et cinq prises sur la branche.
Il produit enfin les captures horodatées du film.
`render-review.py` assemble ces captures sans accéder à l'écran de l'hôte.

[hd14-evidence.json](hd14-evidence.json) conserve les valeurs mesurées dans cette session.
La médiane des cinq paires alternées atteint 247 ms sur le faux serveur en VM Debug.
Les cinq prises consécutives atteignent une médiane de 933 ms.
Les deux séries respectent le budget proposé de 5 s.
La valeur `-1` du journal trunk signifie que l'envoi continue.
Elle ne représente aucune durée négative.
Ces valeurs incluent le contrôle du faux serveur et l'observation XCUITest.
Elles ne mesurent pas la latence SSH de production.

La scrutation attend une seconde entre deux relevés.
Elle explique les délais proches d'une seconde dans la série consécutive.
Le relevé hôte précédant la passe indique une charge de 4,20 pour 18 cœurs.
Aucun gain de vitesse sur trunk n'est revendiqué.

Les captures des lanes 7, 9 et 10 transcrivent leurs journaux en images.
Les autres captures proviennent des fenêtres réelles de l'app dans la VM.
La garde conserve les deux chemins protégés absents.
Le relevé réseau observe uniquement `127.0.0.1:18642` pour l'app.
Le film dure 41 secondes.
