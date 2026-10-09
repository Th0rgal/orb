# Proposition : vitesse Codex dans Orb

Statut au 9 octobre 2026 : proposition vérifiée sur les métadonnées du compte
local, fonctionnalité non implémentée. Aucun appel d'inférence Ultra Fast n'a
été exécuté et les autres comptes connectés n'ont pas encore été sondés.

## Interface proposée

Ajouter un sélecteur compact après le modèle et l'effort dans la barre du
composeur : `Standard ▾`, puis `Fast` et `Ultra Fast` selon les capacités
connues. Réutiliser le Picker et les styles existants. Ne pas ajouter de carte
ni de réglage global qui contournerait les capacités du modèle choisi.

Le menu indique le compte utilisé et le coût d'usage. Une capacité inconnue
affiche un état de vérification ; elle ne devient pas disponible par défaut.
Une option indisponible explique pourquoi. Le contrôle disparaît si aucun mode
accéléré n'est pris en charge. Un changement pendant une réponse s'applique au
prochain message, avec le même comportement que le sélecteur d'effort.

## Disponibilité et coût

La [documentation OpenAI sur la vitesse](https://learn.chatgpt.com/docs/agent-configuration/speed)
annonce Ultra Fast pour GPT-6.1 Sol et GPT-6 Astra, sur Pro 500 $ et certains
plans Enterprise/Edu. Les autorisations du workspace et la résidence des données
peuvent restreindre l'accès. L'usage inclus est consommé à 8× le tarif Standard ;
les crédits à 6×. La facturation par clé API est distincte.

Ne pas déduire l'accès du seul nom du plan. Découvrir les capacités pour le
triplet compte/modèle/machine via `account/read` et `model/list` de l'app-server
effectivement utilisé. Mettre en cache les résultats avec date, version du
client, état et raison ; invalider au changement de compte, de machine ou de
connexion. Les refus du serveur restent autoritaires.

Le sondage local avec Codex CLI 0.161.0, sans création de thread ni inférence,
a retourné `planType: promax`. Pour `gpt-6.1-sol` et `gpt-6-astra`,
`serviceTiers` expose `priority` et `ultrafast`, et `additionalSpeedTiers`
expose `fast` et `ultrafast`. Pour `gpt-6-sol` et `gpt-6-luna`, seul Fast est
annoncé. Distinguer les identifiants du catalogue du format accepté par la
configuration ; ne pas recopier aveuglément `priority` comme valeur de requête.

## Compte et continuité

Pour une nouvelle conversation, filtrer les comptes compatibles avant la
sélection selon les quotas. Afficher le compte retenu avant l'envoi. Ne pas
basculer implicitement vers une clé API payante.

Pour une conversation existante, conserver son compte lié. Si ce compte est
compatible, appliquer le mode au prochain tour dans le même thread. Sinon,
proposer une continuation explicite sur un compte compatible par le mécanisme
de checkpoint/handoff ; ne pas déplacer le thread ni retirer sa protection
d'identité. Voir le [contrat de continuité](../codex-native-continuity.md).

Le pool CLIProxy est actuellement une identité opaque pour le runner Codex
(`collect_codex_credentials` dans `src/api/mission_runner.rs`). La sélection
d'un compte précis demande une capacité de routage correspondante dans le
proxy ou un chemin OAuth natif. Tant que cette garantie manque, ne pas annoncer
Ultra Fast disponible sur cette route.

## Travail d'implémentation

1. Introduire un mode typé Standard/Fast/Ultra Fast, compatible avec les anciennes
   valeurs `fast_mode`. Propager le choix dans les requêtes, files d'attente,
   sauvegardes, reprises et exécutions Core, locales et SSH.
2. Étendre la découverte des capacités et le filtrage des comptes. Le modèle et
   le mode doivent être validés ensemble avant de réserver le compte.
3. Étendre `CodexConfig`, les paramètres `thread/start` et `thread/resume`,
   `orb/src-tauri/src/local_agents.rs` et le driver distant. Aujourd'hui, le
   runner Core utilise `serviceTier` pour Fast ; la requête native locale ne
   transporte aucun mode de vitesse.
4. Exposer le sélecteur dans les composeurs nouveau/existant et le compte
   sélectionné. Distinguer mode demandé et mode accepté. L'accusé de réception
   de configuration ne prouve pas à lui seul la classe d'inférence réellement
   servie ; ne pas l'inférer de la latence.
5. Conserver le message en cas de refus. Pas de repli silencieux vers Standard,
   de double soumission ni de nouvelle tentative après un résultat ambigu.

## Recette avant livraison

- Matrice compte/modèle/machine : disponible, refusé, inconnu, compte expiré,
  politique workspace, quota épuisé et ancien client.
- Vérifier les transitions Standard → Ultra Fast → Standard, y compris après
  reprise et dans une file de messages ; aucun ancien mode ne doit persister.
- Vérifier le compte lié, l'absence de repli API implicite, et le handoff explicite.
- Dans un projet local jetable, envoyer un court message pour chaque mode ;
  conserver les identifiants de thread/tour, les paramètres et réponses RPC
  expurgés, et le compte effectif. Tester ensuite Core et SSH séparément.
- Valider clavier, IME, thème clair/sombre, erreur conservant la saisie et
  changement pendant un tour. Ne déclarer la fonctionnalité livrée qu'après
  ces essais réels depuis Orb, et pas seulement après des tests de catalogue.
