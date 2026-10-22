---
style_gate: pass
---

# Arrêter les tours Hermes

Ayo possède le recours K3.
Un agent ne l'exécute jamais.

1. Cliquez sur **Tout arrêter** pour demander K1, l'annulation API des tours suivis par l'app sur la connexion courante.
2. Attendez la confirmation serveur.
3. Si l'annulation reste indisponible ou incomplète, appliquez K3 sur le profil concerné.

Couper le tunnel ne stoppe pas Hermes sur la VM.
K1 conserve les sessions et les transcripts.
Un outil démarré avec `background=true` peut survivre au tour selon [S3](../spike/S3-cancel.md).
Utilisez K3 pour ce cas.
Les tours d'une connexion quittée nécessitent leur propre connexion ou K3.

```text
Tout arrêter -> cancel_run -> état terminal confirmé
                    |
                    +-> panne ou outil détaché -> K3 par Ayo
```

## Appliquer K3 sur la VM

L'arrêt du gateway coupe aussi les autres clients du profil.
Les données du profil restent sur le serveur.

1. Identifiez l'hôte VM et le profil dans la connexion de l'app.
2. Remplacez `HOTE_VM` et `PROFIL` dans les commandes suivantes.
3. Vérifiez la cible avant chaque commande distante.
4. Lisez l'état du gateway.

```sh
vssh HOTE_VM 'hermes -p PROFIL gateway status'
```

5. Arrêtez le gateway du seul profil concerné.

```sh
vssh HOTE_VM 'hermes -p PROFIL gateway stop'
```

6. Relisez l'état du gateway.

```sh
vssh HOTE_VM 'hermes -p PROFIL gateway status'
```

7. Vérifiez les processus d'outil qui vous inquiètent.

```sh
vssh HOTE_VM 'ps -eo pid,ppid,pgid,sid,etime,args'
```

Si le gateway ou l'outil reste actif, l'arrêt reste incomplet.
N'effacez aucune session ni aucun transcript.
Consignez le profil, l'heure, l'état du gateway et les processus restants.

Sur `hv-hermes-test`, plusieurs profils partagent le gateway du conteneur selon [S7](../spike/S7-multiplexing.md).
La commande par profil peut seulement parquer le profil.
Si le gateway est partagé, Ayo arrête son service hôte depuis le profil par défaut.
Cette commande coupe tous les profils servis.

```sh
vssh HOTE_VM 'hermes gateway stop'
```

Un profil parqué ne prouve pas l'arrêt du processus partagé.
Ayo doit alors identifier le PID exact du gateway dans `ps`.
Ayo arrête ce processus sur la VM et contrôle son absence.
Cet arrêt touche tous les profils du gateway partagé.

```sh
vssh HOTE_VM 'kill -TERM PID_GATEWAY'
vssh HOTE_VM 'ps -eo pid,ppid,pgid,sid,etime,args'
```

Si le même PID reste actif, Ayo vérifie son identité avant l'arrêt forcé.

```sh
vssh HOTE_VM 'kill -KILL PID_GATEWAY'
```

Un superviseur peut relancer le gateway.
Ayo doit aussi arrêter son service superviseur avant de conclure K3.
Ayo contrôle les processus d'outil séparés et les arrête par leur PID exact si nécessaire.
Cette procédure n'a pas été exécutée par l'auteur.

Références officielles consultées le 21 octobre 2026.
La [documentation API Hermes](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server) décrit l'annulation et ses états.
La [documentation des gateways par profil](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/multi-profile-gateways.md) décrit son arrêt.
