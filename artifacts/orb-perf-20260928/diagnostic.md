# Diagnostic Orb Tauri — 28 septembre 2026

## Mesures

31 relevés sur 62,7 secondes, espacés de deux secondes environ. CPU calculé par delta du temps CPU cumulé / temps réel : 100 % = un cœur. Trois profils natifs de cinq secondes, intervalle 10 ms, et une carte mémoire WebKit. Aucun processus arrêté, aucun changement applicatif effectué pour ce diagnostic.

Session de développement active dans `sandboxed_sh-orb-client`, processus Orb 71777, lancé peu avant les relevés. WebKit 71872, GPU 71870 et Networking 71879 associés par leur démarrage concomitant ; attribution temporelle, pas une preuve fournie par leur PPID (launchd). Les anciens processus WebKit ont été exclus. Les outils de développement et workers sont présentés séparément.

| Groupe | CPU moyen, un cœur | RSS min–max |
|---|---:|---:|
| Orb Rust | 5.64% | 124.1–133.0 MiB |
| WebKit content | 2.65% | 138.8–391.0 MiB |
| WebKit GPU + network | 2.20% | 47.1–91.3 MiB |
| 7 context workers | 2.47% | 89.2–90.0 MiB |
| Development tools | 1.21% | 41.6–172.9 MiB |

Les RSS ne sont pas des empreintes physiques privées additionnables : pages partagées, compression et mémoire non résidente faussent une somme. `sample` indique 45,4 Mio d'empreinte physique native et 378,1 Mio pour WebKit. Plus tard, `vmmap` indique 434,8 Mio pour WebKit, pic de vie 499,6 Mio. Ne pas interpréter les centaines de Gio d'espace virtuel réservé comme de la RAM utilisée. Les variations de RSS ne prouvent ni une fuite ni une libération équivalente du heap.

Machine : 16 Gio RAM. Une compilation rustc externe à l'arbre de l'application était active (instantané ~91 % CPU et 1,82 Gio RSS). La visibilité, les interactions et les changements de données n'ont pas été contrôlés. Il ne s'agit pas d'un benchmark au repos ou d'une mesure de version distribuée. Les échantillonneurs peuvent perturber légèrement les mesures. Pas de preuve de fuite sur cette fenêtre courte.

## Diagnostic et priorités

1. **CPU natif : collecte système permanente.** `orb/src-tauri/src/machine_metrics.rs:60–159` parcourt tous les processus, recrée la liste des disques et lance `ioreg` à chaque cycle, puis attend trois secondes, indépendamment du panneau affiché. Ces chemins apparaissent dans le profil Rust. La plupart des piles sont toutefois en attente ; on ne peut attribuer tout le CPU natif à cette collecte. Optimisation : abonnements au panneau métriques, collecte minimale hors panneau, rafraîchissement processus limité aux champs nécessaires, cache disques à cadence lente et collecte GPU moins fréquente. Mesurer ensuite le CPU à écran identique.

2. **Réveils et E/S de fond : workers de contexte.** Sept processus persistent, dont des contextes de validation. `orb/src-tauri/src/project_context.rs:221–245` synchronise toutes les deux secondes. Le profil du worker 97573 montre `Replica::save`, écritures atomiques et `sync_all`, ainsi que scan de répertoire. Les appels bloquants ne sont pas une mesure du CPU consommé. Optimisation : notifications de fichiers, backoff sur projets inchangés, regroupement des synchronisations et absence de réécriture lorsque l'état durable ne change pas. Garder la durabilité des mutations et la synchronisation indépendante de l'UI ; ne pas tuer arbitrairement les workers.

3. **Mémoire : historiques et préchargement à borner par octets.** WebKit domine l'empreinte mesurée. `pageCache.ts` limite à 32 entrées, pas à un budget mémoire. `missionCache.ts` conserve événements et transcript dérivé ; chaque récupération peut charger jusqu'à 4 000 événements (`stream.ts:47`). `App.tsx:1141` précharge toutes les missions actives, sans file de concurrence dans `prefetchTranscript`. C'est un risque identifié dans le code, pas une attribution du heap actuel. Optimisation : budget en octets, préchargement des seules conversations récentes/survolées avec concurrence bornée, chargement de la fin de conversation puis pagination, rendu limité à la zone visible pour les longues conversations. Vérifier les chemins de navigation et ancres de défilement.

4. **Polling frontend.** Liste globale toutes les cinq secondes, état local toutes les deux secondes, questions natives toutes les 350 ms, deux lectures cloud toutes les trois secondes. Certaines boucles respectent déjà la visibilité ; celles du cloud et des interactions natives ne le font pas. Optimisation : événements natifs/SSE avec réconciliation lente, identité des objets conservée si inchangés, un seul rafraîchissement en vol, cadence selon activité. Éviter de retarder les questions nécessitant une réponse humaine.

## Vérifications suivantes

- Comparer la même conversation : repos visible, fenêtre masquée, flux actif, longue conversation, pendant plusieurs minutes chacun.
- Profiler le heap JavaScript pour attribuer la mémoire aux objets retenus ; les profils natifs ne donnent pas les noms des composants Solid responsables.
- Valider sur un build distribué sans Vite/HMR, séparément du mode dev.
- Mesurer CPU, empreinte physique, requêtes/minute et latence d'ouverture avant/après chaque optimisation. Aucun gain chiffré promis avant comparaison contrôlée.

## Artefacts

- `process-samples.json` : série brute des processus ciblés, sans environnement ni secrets.
- `native.sample.txt`, `webcontent.sample.txt`, `context-worker.sample.txt` : profils de piles.
- `webcontent.vmmap.txt` : répartition mémoire.
