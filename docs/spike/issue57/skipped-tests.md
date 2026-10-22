---
style_gate: pass
---

# Inventaire des tests ignorés

La passe HD17 avant #56 compte 52 tests ignorés.
La source est `evidence/hd17/ui-full-summary.log`.
La PR #59 ajoute un test LiveTunnel distinct, décrit après le tableau.

Neuf tests préparent désormais leurs préconditions ou évitent un prérequis SSH inutile.
Les autres gardent leurs contrôles de préconditions.
Chaque proxy est un serveur intermédiaire propre à un scénario de test.
Les proxies spécialisés ne partagent pas le même serveur HTTP que la suite ordinaire.

| Test | Décision | Motif ou précondition |
| --- | --- | --- |
| `BotsPerfProbe/testExpandingABotWithTwoHundredThreads` | Maintenu | La fixture dédiée exige neuf profils et 200 fils. Lane `docs/spike/hd08-instruments/perf.sh`. |
| `BotsPerfProbe/testLaunchToEveryBotRowVisible` | Maintenu | La fixture dédiée exige neuf profils et 200 fils. Lane `docs/spike/hd08-instruments/perf.sh`. |
| `ConcurrencyTests/test01HeldBeforeLaunch` | Maintenu | Le proxy HD14 fournit `/_hv/hold` et le canal de détection. Lane `docs/spike/hd14-instruments/run-ui.sh`. |
| `ConcurrencyTests/test02TakenDuringUse` | Maintenu | Le proxy HD14 fournit `/_hv/hold` et le canal de détection. Lane `docs/spike/hd14-instruments/run-ui.sh`. |
| `ConcurrencyTests/test03NoWriteAfterHold` | Maintenu | Le proxy HD14 fournit `/_hv/hold` et le canal de détection. Lane `docs/spike/hd14-instruments/run-ui.sh`. |
| `ConcurrencyTests/test04OtherProfile` | Maintenu | Le proxy HD14 fournit `/_hv/hold` et le canal de détection. Lane `docs/spike/hd14-instruments/run-ui.sh`. |
| `ConcurrencyTests/test05Release` | Maintenu | Le proxy HD14 fournit `/_hv/hold` et le canal de détection. Lane `docs/spike/hd14-instruments/run-ui.sh`. |
| `ConcurrencyTests/test06ApprovalTaken` | Maintenu | Le proxy HD14 fournit `/_hv/hold` et le canal de détection. Lane `docs/spike/hd14-instruments/run-ui.sh`. |
| `ConcurrencyTests/test08DetectionDropped` | Maintenu | Le proxy HD14 fournit `/_hv/hold` et le canal de détection. Lane `docs/spike/hd14-instruments/run-ui.sh`. |
| `ConcurrencyTests/testPerfFiveHolds` | Maintenu | Le proxy HD14 fournit `/_hv/hold` et le canal de détection. Lane `docs/spike/hd14-instruments/run-ui.sh`. |
| `ConcurrencyTests/testPerfOneHold` | Maintenu | Le proxy HD14 fournit `/_hv/hold` et le canal de détection. Lane `docs/spike/hd14-instruments/run-ui.sh`. |
| `ConcurrencyTests/testRecordedReview` | Maintenu | Le proxy HD14 fournit `/_hv/hold` et le canal de détection. Lane `docs/spike/hd14-instruments/run-ui.sh`. |
| `KillSwitchTests/test01ThreeRunningTurns` | Maintenu | Le proxy HD15 produit des tours annulables et les capacités stop. Lane `docs/spike/hd15-instruments/run-ui.sh`. |
| `KillSwitchTests/test03Idle` | Maintenu | Le proxy HD15 produit des tours annulables et les capacités stop. Lane `docs/spike/hd15-instruments/run-ui.sh`. |
| `KillSwitchTests/test04NoTunnel` | Maintenu | Le proxy HD15 produit des tours annulables et les capacités stop. Lane `docs/spike/hd15-instruments/run-ui.sh`. |
| `KillSwitchTests/test05DroppedCancel` | Maintenu | Le proxy HD15 produit des tours annulables et les capacités stop. Lane `docs/spike/hd15-instruments/run-ui.sh`. |
| `KillSwitchTests/test06DoubleClick` | Maintenu | Le proxy HD15 produit des tours annulables et les capacités stop. Lane `docs/spike/hd15-instruments/run-ui.sh`. |
| `KillSwitchTests/test07KeptSessions` | Maintenu | Le proxy HD15 produit des tours annulables et les capacités stop. Lane `docs/spike/hd15-instruments/run-ui.sh`. |
| `KillSwitchTests/test08WaitingApproval` | Maintenu | Le proxy HD15 produit des tours annulables et les capacités stop. Lane `docs/spike/hd15-instruments/run-ui.sh`. |
| `KillSwitchTests/testPerfFiveStops` | Maintenu | Le proxy HD15 produit des tours annulables et les capacités stop. Lane `docs/spike/hd15-instruments/run-ui.sh`. |
| `NativeNotifications/testLoopPauseNotificationDelivery` | Maintenu | macOS refuse la remise des notifications dans la VM. Le test tente la remise avant son skip. |
| `ProfileKeys/testAllNineProfilesWithDistinctKeys` | Maintenu | Les deux tests exigent des clés distinctes et leur serveur authentifié. Lane `docs/spike/hd17-instruments/run-ui.sh`. |
| `ProfileKeys/testCrossedKeyShowsTheAuthenticationError` | Maintenu | Les deux tests exigent des clés distinctes et leur serveur authentifié. Lane `docs/spike/hd17-instruments/run-ui.sh`. |
| `ResumeBaseline/testTrunkCutOutcome` | Maintenu | Ce témoin mesure le code historique trunk, pas le comportement du head. Lane `HV13_BASELINE=1`. |
| `ResumeLanes/testApprovalAcrossCut` | Maintenu | Le proxy HD13 coupe les flux et simule les reprises. Lane `docs/spike/hd13-instruments/run-ui.sh ResumeLanes`. |
| `ResumeLanes/testApprovalWithDetectorCut` | Maintenu | Le proxy HD13 coupe les flux et simule les reprises. Lane `docs/spike/hd13-instruments/run-ui.sh ResumeLanes`. |
| `ResumeLanes/testCompletedDuringCut` | Maintenu | Le proxy HD13 coupe les flux et simule les reprises. Lane `docs/spike/hd13-instruments/run-ui.sh ResumeLanes`. |
| `ResumeLanes/testCutBeforeAcknowledgement` | Maintenu | Le proxy HD13 coupe les flux et simule les reprises. Lane `docs/spike/hd13-instruments/run-ui.sh ResumeLanes`. |
| `ResumeLanes/testLoopGuardCountsAcrossReplay` | Maintenu | Le proxy HD13 coupe les flux et simule les reprises. Lane `docs/spike/hd13-instruments/run-ui.sh ResumeLanes`. |
| `ResumeLanes/testNetworkGuardCapture` | Maintenu | Le proxy HD13 coupe les flux et simule les reprises. Lane `docs/spike/hd13-instruments/run-ui.sh ResumeLanes`. |
| `ResumeLanes/testOnlyIDsPersist` | Maintenu | Le proxy HD13 coupe les flux et simule les reprises. Lane `docs/spike/hd13-instruments/run-ui.sh ResumeLanes`. |
| `ResumeLanes/testRelaunchMidTurn` | Maintenu | Le proxy HD13 coupe les flux et simule les reprises. Lane `docs/spike/hd13-instruments/run-ui.sh ResumeLanes`. |
| `ResumeLanes/testResumeBudget` | Maintenu | Le proxy HD13 coupe les flux et simule les reprises. Lane `docs/spike/hd13-instruments/run-ui.sh ResumeLanes`. |
| `ResumeLanes/testTenMinuteCut` | Maintenu | Le proxy HD13 coupe les flux et simule les reprises. Lane `docs/spike/hd13-instruments/run-ui.sh ResumeLanes`. |
| `ResumeLanes/testZeroSecondCut` | Maintenu | Le proxy HD13 coupe les flux et simule les reprises. Lane `docs/spike/hd13-instruments/run-ui.sh ResumeLanes`. |
| `SixActions/testADroppedApproveRouteShowsTheRequestWithTheDisabledMessageAndTheKillSwitch` | Réactivé | Le test configure sa fixture, puis rétablit la configuration après son exécution. |
| `SixActions/testAnEmptyProfileListShowsAClearMessage` | Réactivé | Le test configure sa fixture, puis rétablit la configuration après son exécution. |
| `SixActions/testAProfileAddedWhileTheAppRunsShowsOnlyAfterTheValidation` | Réactivé | Le test configure sa fixture, puis rétablit la configuration après son exécution. |
| `SixActions/testASlowServerShowsAWaitStateAndTheWindowStaysResponsive` | Réactivé | Le test configure sa fixture, puis rétablit la configuration après son exécution. |
| `SixActions/testDroppingListSessionsDisablesTheThreadsAloneWithAMessage` | Réactivé | Le test configure sa fixture, puis rétablit la configuration après son exécution. |
| `SixActions/testDroppingSetModelDisablesThePickerAloneWithItsMessageAndSendingStillWorks` | Réactivé | Le test configure sa fixture, puis rétablit la configuration après son exécution. |
| `SixActions/testLongEmojiAndRightToLeftNamesAreTruncatedAndReadable` | Réactivé | Le test configure sa fixture, puis rétablit la configuration après son exécution. |
| `SixActions/testSendingToTheOrbInstanceGetsTheModelReplyOnceInTheServerSession` | Maintenu | Cette lane exige les profils et les réponses de `hv-hermes-test`, via le tunnel VM. |
| `SixActions/testTheSeededProfilesOfTheOrbInstanceShowAndTheParkedOneDoesNot` | Maintenu | Cette lane exige les profils et les réponses de `hv-hermes-test`, via le tunnel VM. |
| `SixActions/testWithoutNamesTheRowsShowTheProfileIdAndTheThreadsShowTheirId` | Réactivé | Le test configure sa fixture, puis rétablit la configuration après son exécution. |
| `TunnelTests/testAHostThatNamesPersoHermesIsRefusedBeforeAnyConnection` | Maintenu | Ces tests exigent un sshd, des clés SSH éphémères et un échantillonneur de processus. Lane HD07 dédiée. |
| `TunnelTests/testAPersoHermesHostInTheEnvironmentNeverStartsSsh` | Réactivé | Le refus intervient avant SSH. Aucun sshd n’est nécessaire. |
| `TunnelTests/testAWrongKeyShowsOneClearMessageAndStopsWithoutARetryLoop` | Maintenu | Ces tests exigent un sshd, des clés SSH éphémères et un échantillonneur de processus. Lane HD07 dédiée. |
| `TunnelTests/testQuittingWithCommandQClosesTheAppAndItsTunnel` | Maintenu | Ces tests exigent un sshd, des clés SSH éphémères et un échantillonneur de processus. Lane HD07 dédiée. |
| `TunnelTests/testTerminateClosesTheAppAndItsTunnel` | Maintenu | Ces tests exigent un sshd, des clés SSH éphémères et un échantillonneur de processus. Lane HD07 dédiée. |
| `TunnelTests/testTheConnectionViewShowsTheHostAndTheKeyStateButNeverTheKey` | Maintenu | Ces tests exigent un sshd, des clés SSH éphémères et un échantillonneur de processus. Lane HD07 dédiée. |
| `TunnelTests/testTheVersionComesThroughTheTunnelNotThroughTheDirectPort` | Maintenu | Ces tests exigent un sshd, des clés SSH éphémères et un échantillonneur de processus. Lane HD07 dédiée. |

Le test `LiveTunnel/testRealTestProfilesThroughTheVMTunnel` reste réservé à `hv-vm-ui.py`.
Il exige le tunnel inverse et les deux clés privées de test.
Sa présence porte le total historique après #59 à 53 tests ignorés.

La suite ordinaire attend donc 43 tests ignorés parmi les 52 initiaux, plus le test LiveTunnel.
Les résultats de cette session figurent dans `evidence/issue57/`.

Aucun test ni contrôle ne passe lorsque son prérequis manque.
Aucun budget de performance ni autorisation macOS ne change.
