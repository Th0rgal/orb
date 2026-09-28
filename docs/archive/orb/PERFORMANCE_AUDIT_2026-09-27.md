# Orb — audit de performances du 27 septembre 2026

> État historique avant la refonte complète. Voir [l’architecture implémentée et les nouvelles mesures](../../../orb/docs/EVENT_ARCHITECTURE.md) pour le résultat final.

## Résultat et périmètre

Les interactions locales utilisent désormais un abonnement natif : un état initial, puis uniquement les changements. Le polling toutes les 350 ms disparaît sur le nouveau binaire. L’identité d’une question inchangée reste stable, y compris pour les snapshots distants, ce qui conserve le champ, le focus et la sélection.

L’audit couvre l’architecture du client Orb : shell Solid, état des missions, streaming, transcript, caches, fichiers, interactions, IPC, agents locaux et collecte de métriques. Les serveurs distants, les modèles et la transcription vocale en charge n’ont pas été profilés. Les recommandations ci-dessous ne sont pas toutes implémentées.

Le correctif est isolé dans le worktree `sandboxed_sh-orb-events-perf`, branche `fix/orb-interaction-events`, basé sur `72dddf68`. L’instance principale avait de nombreuses modifications locales et hébergeait des agents actifs : son processus natif n’a pas été redémarré. La validation native a utilisé une seconde instance Tauri, un autre identifiant d’application et un répertoire de compilation séparé. Pour bénéficier du correctif dans l’instance principale, il faudra intégrer cette branche puis redémarrer son binaire lorsque ses agents pourront être interrompus.

## Mesures réelles

### Instance de travail, visible au premier plan

Fenêtre observée pendant 30 secondes après confirmation de l’utilisateur. Instrumentation temporaire du transport `fetch`, des mutations DOM et de `requestAnimationFrame`; échantillonnage des processus en parallèle. Le protocole IPC Tauri passe lui aussi par `fetch`. La tentative d’interception directe de `invoke`, en lecture seule, n’a pas fonctionné; les comptes viennent du transport, pas de cette interception.

- 2 569 éléments DOM au début et à la fin; 64 mutations, **aucun nœud ajouté ou supprimé**.
- Intervalles rAF : médiane 17 ms, p95 18 ms; trois intervalles au-delà de 50 ms. Ce sont des intervalles de callback, pas une mesure du temps GPU ni du coût de rendu.
- **61 appels `local_bindings`**, 15 `local_origin_list`, 16 `local_agents_poll`.
- **6 lectures de l’historique `/missions/:id/events`**, 6 de la liste des missions et 6 de la queue; 3 lectures de la mission sélectionnée.
- Pas de question active pendant cette fenêtre : elle ne constitue pas une mesure avant/après du correctif des interactions.

| Processus de l’instance principale | CPU moyen, % d’un cœur | RSS moyen |
|---|---:|---:|
| Orb natif | 6,78 % | 395,0 Mio |
| WebContent | 5,72 % | 211,7 Mio |
| Networking | 0,81 % | 38,0 Mio |
| GPU auxiliaire | 0,28 % | 15,7 Mio |
| Vite | 0,03 % | 44,2 Mio |

CPU calculé par différence des temps CPU cumulés sur 32 secondes (31 relevés), plutôt que par moyenne du `%CPU` instantané de `ps`. RSS n’est pas l’empreinte physique; additionner les RSS compterait potentiellement de la mémoire partagée plusieurs fois. Les agents enfants et l’application de test ne sont pas inclus. Ce relevé mesure un scénario donné, avec instrumentation et autres applications ouvertes, pas un budget universel au repos.

Les principaux consommateurs **par processus** sont le natif et le renderer. Les samples natifs montrent notamment des chemins `sysinfo`, `sysctl` et `proc_info`, ainsi que des écritures de fichiers. Les samples incluent des attentes et ne permettent pas d’attribuer un pourcentage CPU fiable à chaque fonction. Les durées réseau cumulées ne sont pas du CPU.

Sources : [fenêtre native](performance-20260927/native-foreground-30s.json), [processus](performance-20260927/process-summary.json). Les samples bruts restent dans le checkout de travail sous `orb/artifacts/performance-20260927/`; ils ne sont pas nécessaires pour exécuter le correctif.

### Comparaison des interactions dans Tauri/WKWebView

Deux phases de 10 secondes dans la même instance native de test : ancienne boucle explicitement reproduite, puis nouveau helper. App masquée pour cette comparaison IPC, sans demande active ni appel de modèle.

| Mécanisme | Abonnement | Lectures périodiques | Nettoyage |
|---|---:|---:|---:|
| Lecture initiale + intervalle 350 ms | 0 | 29 lectures au total | arrêt du timer |
| Nouveau channel | 1 | **0** | 1 désabonnement |

Un snapshot initial reçu, aucune erreur. Cela démontre la suppression du trafic périodique de cette fonction; aucun gain global CPU en pourcentage n’est revendiqué. [Résultat brut](performance-20260927/interaction-before-after.json).

### Transcript synthétique dans une vraie WebView Tauri

Composants réels `Transcript`, `buildTranscript`, `applyStreamEvent`, `NativeInteraction`; données synthétiques contenant messages utilisateur, outils, Markdown et blocs de code. 100 fragments ajoutés à 16 ms d’intervalle; lecture de `offsetHeight` après mise à jour pour inclure le layout synchrone. Une passe ascendante, build dev, résolution du timer parfois de 1 ms : les zéros signifient « sous la résolution mesurée ».

| Échanges | Reconstruction des événements | Montage initial | Mise à jour p95 | Maximum | Éléments DOM |
|---|---:|---:|---:|---:|---:|
| 30 | < 1 ms | 25 ms | 1 ms | 3 ms | 1 223 |
| 300 | 5 ms | 82 ms | 5 ms | 10 ms | 12 023 |
| 1 000 | 11 ms | 161 ms | 8 ms | 13 ms | 40 023 |

Aucun des 100 fragments n’a pris plus de 16 ms dans ces scénarios. Un nœud ajouté, aucun supprimé pendant chaque séquence de streaming : la réconciliation conserve bien l’historique. L’ouverture d’un long historique et la croissance du DOM sont des cibles plus nettes que le remplacement complet du moteur Markdown. Les temps n’incluent pas une garantie sur la peinture GPU, les pièces jointes lourdes, les formules nombreuses ou tous les types de messages.

Une question a également reçu 20 snapshots équivalents : même élément `input`, focus conservé, texte et sélection `[2,5]` inchangés. [Résultats](performance-20260927/tauri-lab.json), [fixture](../../../orb/tests/performance-native.tsx).

### Hypothèse testée et non retenue

Le collecteur natif parcourt les processus toutes les trois secondes. Un exemple Rust compare le rafraîchissement par défaut et celui limité à la mémoire, avec deux instances `System`, un échauffement et 12 relevés alternés. Sur une première exécution, les médianes étaient environ 3,12 / 3,01 ms; sur la seconde, **6,73 / 6,82 ms**. Aucun gain robuste n’est établi. Ne pas présenter la restriction des champs comme une optimisation significative du CPU global.

Le coût du collecteur complet (disques, `ioreg`, classification et scans) reste à isoler. Adapter la cadence à la demande est une piste à mesurer; supprimer les métriques de fond sans préserver leur historique changerait le produit. [Exemple](../../../orb/src-tauri/examples/profile_process_refresh.rs), [seconde exécution](performance-20260927/process-refresh.json).

## Architecture et refactors proposés

| Couche | Architecture actuelle | Direction proposée |
|---|---|---|
| Shell / mission | `App.tsx` mélange navigation, chargement, réconciliation locale et état de la mission | Extraire les stores mission et session locale; la vue s’abonne à des sélecteurs stables |
| Interaction | Le processus possède la demande et le canal de réponse | Channel snapshot + changements, implémenté ici; UI strictement consommatrice |
| Streaming local | `local_stream.rs` possède le flux; `localStream.ts` regroupe les mises à jour | Conserver le snapshot atomique et le regroupement; réutiliser ce modèle |
| Streaming distant | SSE, récupération d’historique et timers de statut coexistent | Un propriétaire du curseur, rattrapage incrémental, regroupement des fragments de texte |
| Transcript | Réconciliation par clés et parsing Markdown; DOM proportionnel à l’historique | Conserver les clés; afficher progressivement ou virtualiser les anciens tours |
| Cache | Cache partagé borné en nombre d’entrées, déduplication des requêtes en vol | Validité par révision et budget en octets; conserver les résultats vides valides |
| Fichiers / contexte | Lectures périodiques pour détecter les modifications et conflits | Watchers natifs + événements de version, fallback lent pour récupération |
| Agents natifs | Adaptateurs de harness, processus, buffers, interactions dans un gros module | Séparer cycle de vie, adaptateurs et transport; notification de fin plutôt que réveils fréquents |
| Métriques | Worker permanent, snapshots mis en cache, scans globaux | Mesurer chaque phase; distinguer historique agrégé et détails à la demande |

### P1 — Bindings locaux : une source native, notifications et écritures idempotentes

**Preuve :** 61 IPC en 30 s. Les traces d’appel distinguent `restoreLocalBindings` depuis `localMessageQueue.ts` et `rememberBinding → reconcileLocalRun → App.tsx`. Le compteur mélange lectures et écritures; il ne représente pas 61 écritures disque.

`localMessageQueue.ts` se réveille toutes les secondes et restaure les bindings lorsqu’il trouve des lignes, avant certains filtres. La vue de mission restaure aussi les bindings et réconcilie toutes les deux secondes. `rememberBinding` persiste même une session inchangée; la commande native réécrit le fichier. L’effet de `App.tsx` dépend de l’objet mission entier et peut redémarrer lors d’un simple rafraîchissement. Son callback `refreshLocal` ne renvoie pas la promesse de réconciliation, ce qui neutralise la protection contre le chevauchement du helper de polling.

**Refactor :** snapshot initial des bindings, flux natif des modifications, cache frontend dérivé, comparaison avant persistance. Observer des clés stables (`id`, origine, génération) plutôt que l’objet mission complet. Renvoyer/attendre les promesses tant que les timers existent. Réveiller la queue sur ajout, fin de run et reconnexion, avec récupération lente pour les états incertains. Ne pas créer une seconde source de vérité ni perdre les reçus de lancement.

**Critères :** aucune écriture pour un binding inchangé; aucun IPC récurrent de bindings sur une session stable; aucune réconciliation concurrente par mission; récupération correcte après reload et fin de processus.

### P1 — Historiques : séparer rafraîchissement de statut et contenu

**Preuve :** six lectures `/events` en 30 s; `getMissionEvents` demande jusqu’à 4 000 événements. Les traces confirment `fetchTranscript → getMissionEvents`; elles ne suffisent pas à attribuer chaque lecture à un appelant supérieur précis.

`missionCache.ts` déduplique les appels en vol, mais `loadTranscript` peut relire l’historique à chaque invocation. Plusieurs surfaces demandent le transcript (mission, préchargement, survol); un historique vide n’est pas toujours considéré prêt. SSE et récupération doivent partager la même notion de version.

**Refactor :** store de transcript par mission et connexion, curseur/revision explicite; statut indépendant du contenu; cache des historiques vides; rattrapage des événements manquants. Garder le resync sur reconnexion/trou de séquence et les protections contre les courses avec la queue. Vérifier les points d’invalidation avant de supprimer des lectures.

**Critères :** zéro relecture complète d’un historique stable avec SSE sain; après reconnexion, aucun événement perdu/dupliqué; rafraîchir le statut ne reconstruit pas les messages.

### P2 — Longues conversations : réduire le montage et le DOM

**Preuve :** 161 ms au montage et 40 023 éléments à 1 000 échanges, contre 8 ms p95 par fragment. La stabilité des nœuds pendant le streaming est déjà bonne.

**Refactor :** commencer par un chargement progressif des anciens tours; si nécessaire, virtualiser les tours complets avec hauteurs mesurées, ancrage du scroll et suraffichage. Éviter de démonter une zone contenant le focus, une sélection, une recherche ou un outil ouvert. Maintenir une stratégie pour la recherche dans tout l’historique et les liens vers un ancien message.

**Critères :** DOM borné par la fenêtre visible; ouverture de 1 000 échanges sans tâche longue de montage sur le matériel de référence; pas de saut de scroll ni de perte de sélection. Répéter les mesures à froid/chaud avant de fixer un budget de release.

### P2 — Polling de contexte, fichiers et cycle de vie des agents

`ContextBadge.tsx` vérifie toutes les trois secondes; le worker natif du contexte travaille déjà périodiquement. L’éditeur de fichiers relit toutes les cinq secondes. `local_agents.rs` vérifie la sortie des processus toutes les 80 ms; certains abonnés attendent par boucles à 40 ms.

**Refactor :** publier la version de contexte et les changements du fichier depuis leur propriétaire; watch du processus/condition de fin pour réveiller les abonnés. Conserver la détection de conflits et la récupération après débordement d’un watcher ou fichier remplacé atomiquement. Les notifications déclenchent une lecture de la version autoritative, pas une écriture aveugle.

**Critères :** aucun réveil fréquent pour une ressource inchangée, fermeture qui libère immédiatement les abonnés, modifications externes visibles, brouillons locaux préservés. Gains CPU à mesurer : aucune estimation chiffrée ici.

### P3 — Métriques et bornes de mémoire

Le collecteur `machine_metrics.rs` rafraîchit CPU, mémoire, processus et disques, lance `ioreg`, puis classe les processus par ascendance. La classification par enfants du PID Orb n’inclut pas nécessairement les services WebKit lancés par macOS. Afficher cette somme comme mémoire totale d’Orb serait trompeur.

**Refactor :** instrumenter séparément ces phases; réutiliser la liste de disques et espacer ses rescans; détails par processus à la demande tout en conservant l’historique global. Définir explicitement le périmètre mémoire. Pour `pageCache.ts`, compléter la limite de 32 entrées par un budget de taille; un transcript volumineux n’équivaut pas à une petite entrée de hauteur.

Le build produit un chunk principal de 530,74 ko minifié (174,04 ko gzip). Vite signale des imports à la fois statiques et dynamiques pour `api`, `projectContext` et `localAgents` : ces imports dynamiques ne créent donc pas de séparation effective. Extraire les stores du shell facilitera un découpage par page; son bénéfice concerne surtout le démarrage, pas les réveils périodiques mesurés.

Le travailleur de coloration, le chargement différé du PDF, les transforms de l’image et le throttling de l’inventaire logiciel sont des choix à conserver. Ils n’ont pas été identifiés comme goulots dans cette mesure. Pas de réécriture générale des composants graphiques sans workload représentatif.

## Détails du correctif livré

- `interactions.rs` garde l’état autoritatif dans le processus. Le snapshot initial et l’inscription partagent le verrou des transitions : aucun changement ne tombe entre lecture et abonnement.
- Publication à la création, réponse, annulation, remplacement et fin de génération valide. Une ancienne génération ne peut pas annuler la nouvelle.
- Jeton d’abonnement propre à chaque consommateur; désabonnement au démontage, y compris si la réponse d’inscription arrive tard.
- `nativeInteractionStream.ts` ne poll pas sur le nouveau natif. Ancien binaire seulement : fallback séquentiel toutes les 1,5 seconde, sans chevauchement. Une vraie erreur d’abonnement s’affiche avec Retry au lieu d’être masquée par un polling.
- `NativeInteraction` conserve l’identité des demandes structurellement identiques. Pas de réponse automatique ni de changement du protocole d’approbation.
- 14 tests frontend ciblés, build de production Vite/TypeScript et 5 tests Rust d’interactions réussis. La fixture native valide également focus et transport réel. Ces validations ne constituent pas un test exhaustif de tous les harnesses.

## Reproduire

Depuis `orb/` :

```sh
pnpm exec vitest run tests/native-interaction.test.tsx tests/native-interaction-stream.test.ts
pnpm exec tsc --noEmit
cargo test --manifest-path src-tauri/Cargo.toml interactions::tests
cargo run --manifest-path src-tauri/Cargo.toml --example profile_process_refresh
```

Sur macOS, générer les ressources de l’icône comme pour le dev habituel si `src-tauri/gen/app-icon` manque (`scripts/build-macos-icon.mjs`). Utiliser un `CARGO_TARGET_DIR` séparé si une instance active doit rester intacte.

Pour la fixture, démarrer Vite sur un port libre puis une instance `tauri dev --no-watch --config <config-json>` avec un autre identifiant et `build.devUrl` pointant vers `/tests/performance-native.html`, `build.beforeDevCommand` vide. Depuis l’inspecteur WebView :

```js
await window.perfHarness.stableQuestion();
await window.perfHarness.transcript(30, 100);
await window.perfHarness.transcript(300, 100);
await window.perfHarness.transcript(1000, 100);
window.perfHarness.status();
window.perfHarness.stop();
```

La fixture conservée ne contient aucun websocket d’évaluation de code ni connexion à un modèle. Les sondes temporaires utilisées pour piloter la mesure sont retirées de l’instance de travail après l’audit. Pour établir un budget de release, répéter chaque scénario plusieurs fois, distinguer froid/chaud et visible/masqué, et profiler des historiques réels lourds dans un build de production.
