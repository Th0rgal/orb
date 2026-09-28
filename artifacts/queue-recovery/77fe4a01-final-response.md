J'ai terminé la revue du dépôt sandboxed.sh (sur `origin/master` à jour) et voici le plan de refactor. Je n'ai rien modifié ni supprimé : tout le nettoyage passera par des PR que tu valideras.

## Ce qu'il faut régler avant le refactor

1. **Des accès de production sont publiés.** Le dépôt est public (Th0rgal et KultureElectric), et `DEBUGGING.md` lignes 7-9 donne les commandes SSH root avec les IP d'agent-core, d'old-agent et du serveur de Ben. Il faut les retirer tout de suite. Elles restent dans l'historique git et dans les forks, donc il vaut aussi mieux vérifier que le SSH root n'accepte que des clés et qu'il est filtré par IP. `.claude/settings.json` autorise aussi `rm`, `ssh` et `curl` sans confirmation.
2. **L'image Docker ne se construit probablement plus**, alors que c'est l'installation mise en avant par le README :
   - elle ne copie ni `Cargo.lock`, ni `build.rs`, ni `catalog/`, `shared/` ou `scripts/`, et elle régénère le lockfile ;
   - elle ne construit pas `automation-manager-mcp`, que le serveur lance pourtant ;
   - l'étape de cache échoue en silence (`|| true`).

   La CI ne construit jamais cette image.
3. **Une protection est écrite mais jamais branchée.** Le détecteur de flux dégénéré de Claude (`text_buffer_stream_looks_degenerate`) n'est appelé que par les tests, alors que sa doc dit l'inverse.
4. **Cinq définitions de « statut terminal » se contredisent** dans le backend : certaines incluent `Acknowledged`, d'autres `Paused`, d'autres excluent `Blocked`. Ça peut donner des comportements incohérents entre le board, l'auto-reprise et Paloma.
5. **Les erreurs 502 masquent les messages.** Le backend renvoie 502 pour des erreurs normales (échec de dispatch, Telegram, providers), et Cloudflare remplace ces réponses par sa propre page. C'est la cause du « Can't reach the backend » d'hier.
6. **La CI iOS ne peut sans doute plus construire** : elle tourne avec Xcode 16 alors que le projet cible iOS 26. Elle ne lance aucun test, et un test d'interface vise un écran qui n'existe plus.

## Le constat en chiffres

| Zone | Taille | Principaux problèmes |
|---|---|---|
| Backend Rust | ~310k lignes | `control/mod.rs` 39k lignes, dont une fonction `control_actor_loop` de ~6 100 lignes ; `ai_providers.rs` 12k ; le trait `MissionStore` a 199 méthodes ; 264 erreurs ignorées (`let _ =`) dans control, y compris sur les écritures de statut ; code mort (`dispatch_remote_mission_mvp`, `agent_config.rs` et `api/agents.rs` jamais compilés, ancien chemin OpenCode `/api/task*`) ; des outils listés qui ne peuvent jamais s'exécuter ; MCP JSON-RPC copié dans 5 binaires ; refresh OAuth copié 3 fois ; ~8 vérifications de chemins différentes ; SQLite bloquant sur le runtime async |
| Orb (client) | 22k TS + 7k Rust | `App.tsx` 2 673 lignes, dont un mode démo « Lorem » encore livré ; 102 lignes de plus de 300 caractères ; accès à Tauri réimplémenté dans 13 fichiers ; 94 sélecteurs CSS définis deux fois ; ~60 classes CSS mortes ; aucun linter ni formateur ; les tests ne sont pas vérifiés par TypeScript ; la partie Rust `src-tauri` n'est ni compilée ni testée en CI ; une commande Tauri sensible (`local_agents_start_authorized`) exposée sans raison |
| Dashboard web | 69k lignes | plus l'UI principale mais encore servi par Docker ; 6 fichiers morts, 7 dépendances inutiles ; découpage de l'API à moitié fait (types en double qui ont déjà divergé) ; e2e jamais lancés en CI |
| docs-site | 4k lignes | aucun commit depuis 5 mois ; 5 endpoints documentés qui n'existent plus ; doublon de `docs/` ; liens « modifier la page » cassés (`main` au lieu de `master`) |
| iOS | 31k lignes | ~15 600 lignes de l'ancienne interface inaccessibles depuis la bascule vers Orb ; deux moteurs Markdown, deux couches d'API ; les liens `sandboxed://mission/…` ne font probablement plus rien |
| Android | 9k lignes | aucun commit depuis 3 mois, aucune parité avec Orb, aucun test |
| Racine et docs | — | 13 PNG, 8 `.md` obsolètes, `claude.md` (un simple lien vers `agents.md`), `.claude/CLAUDE.md` (copie d'`INSTALL.md`), des affirmations fausses dans `agents.md` (X11/Xvfb, harness `chatgpt_ui` absent, rien sur Orb), ~20 docs périmées ou en double, ~10 scripts qui ne servent plus |

Les types échangés entre le backend et les clients (`Mission`, `StoredEvent`…) sont écrits à la main dans le dashboard, dans Orb et dans iOS, et ont déjà divergé.

## Le plan, par phases

Principe commun : une PR petite et mécanique à la fois, jamais de changement de fonctionnalité, et un filet de tests en place avant de déplacer du code.

**Phase 0 : urgences (1 PR par point, ~1 jour)**
- Retirer les IP et commandes SSH de `DEBUGGING.md` et resserrer `.claude/settings.json`.
- Réparer le Dockerfile (lockfile, `build.rs`, fichiers annexes, les 8 binaires, cache) et ajouter un job CI qui construit l'image.
- Brancher le détecteur de flux dégénéré, ou le supprimer si c'est voulu.
- Remplacer les 502 par 503 ou 424 avec un corps JSON.
- Désenregistrer `local_agents_start_authorized` côté Tauri.

**Phase 1 : grand ménage sans risque**
- Racine : supprimer les 13 PNG, `DEPLOYMENT_v0.7.8.md`, `claude.md`, `.claude/CLAUDE.md`, `ci-debounced.yml.example`, `scripts/check.sh` et `check-memory.sh`, les captures non référencées, `orb/VERIFICATION.md`, `LAUNCH-VERIFICATION.md`, les JSON de benchmark et `ios_dashboard/Package.swift`.
- Rapports de conception : déplacer dans `docs/` ou `docs/archive/` (`ASK_ASSISTANT_DESIGN`, `PROVIDERS`, `backend/*.md`, `PERSISTENT_SESSIONS_DESIGN`, les plans et audits datés).
- **Un seul `AGENTS.md` réécrit** : architecture actuelle (backend, Orb, iOS), commandes de build et de test par composant, conventions, liens vers les docs de référence. Pas de `CLAUDE.md`.
- Supprimer le code mort confirmé : les deux fichiers Rust non compilés, `dispatch_remote_mission_mvp`, `collect_project_board_tasks`, les routes factices `/api/runs` et `/api/memory`, la dépendance `reqwest-eventsource`, le pin `idna_adapter`, les fichiers et dépendances morts du dashboard, les exports et le CSS morts d'Orb, et le mode démo « Lorem ».

**Phase 2 : filet de tests et CI (avant tout gros refactor)**
- CI : compiler et tester `orb/src-tauri`, lancer les tests unitaires iOS sur un runner iOS 26, lancer les tests Python de `scripts/`, le lint du dashboard, construire docs-site s'il est gardé, et signaler le code mort (`-W dead_code`).
- Orb : ajouter Biome (formateur et linter), vérifier les tests avec TypeScript, activer `noUnusedLocals`.
- Rust : sérialiser les tests qui modifient des variables d'environnement (ils se font concurrence aujourd'hui) et remplacer les attentes par `sleep` par du temps simulé.
- Ajouter des tests de caractérisation sur les zones qu'on va découper : boucle de contrôle, runners Claude, Codex et OpenCode, `Composer` et resync d'Orb, synchro du contexte.
- Réparer ou supprimer les tests cassés (`provider-reconnect`, `HermesConversationUITests`, `tests/agents.spec.ts`).

**Phase 3 : backend (le plus gros morceau, ~15 à 20 PR mécaniques)**
1. Une seule règle `MissionStatus::is_terminal` ; des enums à la place des statuts et des noms de backend en chaînes brutes.
2. Découper `control/mod.rs` en ~15 modules (`create`, `remote_jobs`, `events_api`, `stream_ws`, `automations`, `telegram_api`…), puis `control_actor_loop` en un gestionnaire par commande. Sortir les tests dans `control/tests/`.
3. Découper `mission_runner.rs` (comptes Codex, parseur SSE OpenCode, préflight) et fusionner les deux chemins d'exécution d'un tour, qui ont déjà divergé.
4. Store : un type d'erreur typé à la place des `Result<_, String>`, un helper `with_conn` (qui supprime ~500 lignes répétitives), plus de SQL brut dans control, migrations versionnées, sous-traits.
5. `ai_providers.rs` : une seule routine de refresh OAuth (ce qui corrigera au passage le garde manquant côté Google), un client HTTP partagé avec timeouts, découpage en modules.
6. Un crate ou module MCP commun pour les 5 binaires ; `desktop-mcp` réutilise `tools::desktop`.
7. Un module unique de validation de chemins, et un helper de configuration qui gère les alias d'environnement (`SANDBOXED_`, `OPEN_AGENT_`…) et les documente.
8. Ne plus ignorer les erreurs importantes (au minimum les logger) ; mettre SQLite et les appels `ss`/`kill` hors du runtime async.
9. Retirer l'ancien chemin OpenCode `/api/task*` et `FileMissionStore`, après vérification des derniers appelants.

**Phase 4 : Orb**
- Découper `App.tsx` en `Composer`, `Sidebar`, `Titlebar`, `NewAgent`, `MissionView` et `MissionDock`, avec des hooks pour l'état.
- Un seul `tauri.ts` et un seul client API (`apiRaw` fusionné dans `api()`), un helper `errorMessage`, un helper `isClientPlaced`, et plus d'erreurs avalées sans trace.
- Dédoublonner `styles.css` bloc par bloc et le découper par écran.

**Phase 5 : types partagés**
- Générer les types TypeScript (et si possible Swift) depuis les structs Rust avec ts-rs ou specta, en commençant par `Mission` et `StoredEvent`. C'est ce qui empêchera les clients de diverger à nouveau.

**Phase 6 : dashboard web et docs-site**
- Terminer ou annuler le découpage de l'API du dashboard, et geler les fonctionnalités qu'Orb couvre déjà.
- docs-site : le fondre dans `docs/`, ou le générer depuis `docs/`.

**Phase 7 : mobile**
- iOS : supprimer les ~15 600 lignes mortes, fusionner `APIService` et `OrbCore`, réparer les liens `sandboxed://…`, réécrire le README, aligner la version de XcodeGen.
- Android : geler (README « non maintenu ») ou supprimer, selon ta décision.

**Phase 8 : dépendances**
- Rust : axum 0.8, tower-http 0.6 (supprime un doublon), thiserror 2, rusqlite, rand, jsonwebtoken ; retirer `ureq` et `md5` ; remplacer `serde_yaml`, qui n'est plus maintenu. Une PR par montée de version majeure, après la phase 2.
- JS : aligner Next et Playwright, et épingler la version de Bun en CI.

## Ce qu'il faut que tu décides

1. **Dashboard web** : je propose de le garder comme console d'admin (bibliothèque, secrets, console, sauvegarde), le temps de porter ces écrans dans Orb, puis de le supprimer. D'accord ?
2. **docs-site** : le fondre dans `docs/`, ou garder un site public généré depuis `docs/` ?
3. **Android** : geler ou supprimer ?
4. **Gestionnaire de paquets JS** : garder pnpm pour Orb et Bun pour le reste, ou tout unifier ?
5. **Hygiène git** : ~40 worktrees locaux et des dizaines de branches `orb/*` distantes, et ton `master` local a 9 jours de retard avec des modifications non commitées. On fait un tri ?

Je peux commencer tout de suite par les phases 0 et 1 sur une branche dédiée, qui sont sans risque et règlent les urgences. J'ai laissé une copie de travail propre d'`origin/master` dans `/tmp/sbx-review` pour la suite.