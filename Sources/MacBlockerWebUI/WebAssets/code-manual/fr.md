# Manuel de code de Mac Vault

[Manuel d’utilisation](../manual/fr.md)

## Contrat des règles

Source : une expression de fonction `(on, v) => { ... }`. Seuls JavaScript synchrone et l’API ci-dessous sont pris en charge ; aucun rappel de planification JavaScript, réseau, API système native ni accès aux pages du navigateur. Les règles temporelles utilisent les minuteurs/suivis gérés ci-dessous, ou `ev.now` et des événements. Les règles Safari utilisent le manuel de code du navigateur et s’exécutent dans l’application conteneur propre à Safari Vault.

- L’édition enregistre un brouillon ; **Exécuter** l’active et active le groupe. Les groupes verrouillés ne peuvent pas l’exécuter. Une source vide décharge la règle.
- Une exécution réussie remplace les gestionnaires/panneaux et efface l’ensemble d’applications bloquées du groupe, en conservant `v.state`. Une erreur de compilation/enregistrement conserve la règle précédente ; un délai dépassé peut l’arrêter. Le redémarrage réenregistre la dernière source activée ; les variables de fermeture et ensembles de blocage sont réinitialisés.
- L’enregistrement peut initialiser l’état, enregistrer les gestionnaires, afficher des panneaux et journaliser. Les actions sur applications/fichiers et émissions appartiennent aux gestionnaires ; leur file durant l’enregistrement est supprimée.
- Désactiver supprime les gestionnaires actifs et lève panneaux/blocages d’applications. Activer reprend la règle chargée et ses panneaux/blocages conservés. Supprimer retire ses gestionnaires/état/effets. Les applications précédemment fermées ne sont pas rouvertes ; les écritures de fichiers ne sont pas annulées.
- Les événements ne sont pas limités par les cibles ordinaires du groupe ; sélectionnez les applications dans la règle. Les actions sont mises en file puis appliquées après la distribution. Une exception arrête ce gestionnaire sans annuler son état/actions ; les suivants peuvent s’exécuter. Seules les actions de fichiers ont des événements de résultat.

## Minuteurs gérés et utilisation sur fenêtre glissante

`v.timer(id, {direction:"down", durationMs:300000})` crée ou renvoie un compte à rebours nommé, initialement en pause. Utilisez `{direction:"up"}` pour un chronomètre croissant. L’objet propose `start()`, `pause()`, `resume()`, `reset()` et `snapshot()`. Démarrer/reprendre sont idempotents ; réinitialiser remet le minuteur en pause avec un temps écoulé nul. Les champs de l’instantané comprennent `ready`, `error`, `elapsedMs`, `remainingMs` (null pour un chronomètre croissant), `running` et `completed`.

Les minuteurs en cours avancent selon le temps réel écoulé lorsque l’application/le navigateur est fermé ou que la règle est désactivée. Un compte à rebours terminé transmet `timerEnded` avec `{id, direction, durationMs, generation, incarnation}` une fois par incarnation et génération du minuteur à chaque membre lorsque sa règle s’exécute à nouveau ; Exécuter ne le rejoue pas. La transmission dépend des événements de l’hôte ; ce n’est pas une alarme en temps réel. Ajoutez `{type:"timer", timerId:"focus", label:"Focus"}` à un panneau pour l’afficher avec le contrôle de texte existant.

`v.rolling(id, {windowMs:3600000, limitMs:600000})` crée ou renvoie un suivi nommé de l’utilisation active. `assign({websites:["youtube.com","reddit.com"], apps:[]})` remplace les affectations de cibles de ce membre. Les règles natives peuvent affecter à la place des identifiants d’applications de la plateforme. Les domaines incluent les sous-domaines. Un suivi regroupe ses cibles ; les autres identifiants ont des quotas indépendants. `snapshot()` renvoie `ready`, `error`, `usedMs`, `remainingMs`, `available` et `nextReturnAtMs` (la prochaine milliseconde où une utilisation enregistrée expire). `available(target?)` vérifie aussi l’affectation lorsqu’une cible est fournie. `reset()` efface l’historique de cet objet.

Toute utilisation admissible observée est comptabilisée, y compris au-delà du quota ; le suivi lui-même ne bloque aucune page/application. Les intervalles de pages visibles qui se chevauchent ne sont comptés qu’une fois, et les applications natives comptabilisent l’utilisation observée au premier plan. Les règles désactivées n’ajoutent aucune utilisation ; l’historique continue d’expirer aux limites exactes des intervalles. La disponibilité ne revient que lorsque l’historique restant est inférieur à la limite. Les échantillons périodiques sont limités à cinq secondes ; les interruptions dues à la fermeture ou à la désactivation ne créent pas d’activité. Les événements émis par l’utilisateur n’ajoutent aucune utilisation.

Les mêmes identifiants d’objet dans des groupes personnalisés liés partagent une autorité locale dans le hub natif. La liaison combine l’historique et les affectations des suivis et conserve l’état du minuteur initiateur ; les configurations incompatibles empêchent la liaison. Chaque membre reçoit son propre événement de fin. La déconnexion rend les suivis partagés indisponibles et refuse les commandes de minuteur jusqu’au retour d’une autorité à jour. Lors de la dissociation, chaque membre conserve l’utilisation partagée finale et l’état du minuteur, restaure ses propres cibles et abandonne les commandes de l’ancienne liaison. Le hub conserve l’instantané final jusqu’à ce que le membre de retour l’enregistre et en accuse réception ; les transferts en attente se terminent avant qu’une nouvelle liaison soit disponible.

Les objets nommés survivent à Exécuter et au redémarrage dans le champ réservé `v.state.$vaultTime` ; ne modifiez pas ce champ directement. Supprimez-les explicitement avec `v.removeTime(id)`. Les identifiants comportent de 1 à 80 lettres ASCII, chiffres, `_` ou `-` ; les noms de propriété réservés sont refusés. Jusqu’à 32 objets partagent la limite d’état de la règle de 64 Kio en UTF-8. Les durées sont des millisecondes entières jusqu’à 365 jours. L’historique glissant est limité à 1024 compartiments d’une minute et 2048 intervalles fusionnés. Les erreurs de capacité de l’historique laissent le suivi indisponible jusqu’à sa réinitialisation explicite ; les configurations invalides et les enregistrements trop volumineux signalent des erreurs sans effacer les données enregistrées.

```js
(on, v) => {
  const timer = v.timer("focus", {durationMs: 300000});
  v.panel("focus", {controls: [
    {type: "timer", timerId: "focus", label: "Focus"},
    {id: "start", type: "button", label: "Start"},
    {id: "pause", type: "button", label: "Pause"},
    {id: "reset", type: "button", label: "Reset"}
  ]});
  on("panel", ev => {
    if (ev.data.eventName !== "click") return;
    if (ev.data.controlId === "start") timer.start();
    if (ev.data.controlId === "pause") timer.pause();
    if (ev.data.controlId === "reset") timer.reset();
  });
  on("timerEnded", ev => v.log("Finished", ev.data.id));
}
```

## API

- `on(type, handler)` → booléen. Enregistre `handler(ev)` ; plusieurs handlers s’exécutent dans l’ordre d’enregistrement. False indique des arguments invalides ou la limite de handlers atteinte. `ev = { type: string, now: number, origin: "host" | "user" | "rule", data }` ; `now` est en millisecondes Unix. Une entrée de panneau natif a `origin: "user"` ; `v.emit` a `origin: "rule"`.
- `v.state` : objet JSON modifiable, persisté après la distribution de l’événement. Initialisez les champs absents au lieu d’écraser l’état existant. Affecter une valeur non objet ou un tableau le réinitialise à `{}` ; les mises à jour non sérialisables/trop grandes ne sont pas persistées.
- `v.log(...values)` : ajoute des entrées au Journal de ce groupe. Les échecs d’exécution et de transmission apparaissent sous forme d’entrées d’erreur explicites dans le même flux. Les journaux/Effacer sont indépendants par groupe. Les erreurs de chargement apparaissent aussi dans l’état d’exécution ; les événements partiellement exécutés ne sont pas rejoués automatiquement.
- `v.emit(type, data)` : met en file une copie JSON de `data` pour les gestionnaires de ce groupe après l’événement courant, avec un nouveau `now` ; ce n’est pas un appel synchrone.
- `v.panel(id, spec)` : remplace le panneau flottant nommé de ce groupe ; null `spec` le retire. Voir Panneaux.
- `v.file(op, path, payload?)` → chaîne ID de requête. Voir Fichiers.
- `v.store(request)` → chaîne d’identifiant de requête. Voir Enregistrements du groupe.
- `v.block(appId, on)` : true maintient un blocage d’application, false retire celui de ce groupe. Les blocages se combinent entre groupes actifs ; cet appel ne peut pas lever une cible d’un autre groupe. Le blocage demande une fermeture normale et réessaie selon l’intervalle des Paramètres ; il n’empêche pas le lancement du processus et ne garantit pas que l’application accepte Quitter.
- `v.quit(appId)` : une demande de fermeture normale, soumise à la même politique de protection/nouvelles tentatives ; aucun blocage continu.
- `v.open(appId)` : demande à macOS d’ouvrir une application installée ; aucun rappel de réussite.

Les autres appels renvoient `undefined`. Les IDs d’application sont des identifiants de bundle (par exemple `com.valvesoftware.steam`), disponibles dans les événements. Bloquer/Fermer peuvent cibler les applications Apple et des navigateurs entiers. Ils ignorent l’identifiant de bundle de Mac Vault et ses auxiliaires, y compris toute autre application partageant cette identité, ainsi que les IDs vides. Les IDs de panneau et l’état appartiennent à un groupe, pas à son nom affiché.

## Événements

La notation des données ci-dessous décrit des types ; ce n’est pas du code exécutable. `?` marque les champs facultatifs.

```text
tick (~1 second): { frontmost: App | null, running: App[] }
app: { kind: "launch" | "quit" | "focus" | "blur" | "hide" | "unhide",
       appId: string, name: string, previousAppId?: string | null }
snooze: {}
panel: { panelId: string, controlId: string, eventName: string,
         value: string, values: { [controlId: string]: string } }
file: see Files
record: { requestId: string, ok: boolean, op?: string, key?: string,
          record?: Record | null, entries?: Header[], next?: string | null,
          deleted?: number, error?: string }
App = { appId: string, name: string }
```

- `tick` est approximatif ; utilisez des horodatages, pas un compte de ticks. Les applications en cours incluent les processus `.app` au premier plan, de barre de menus et d’arrière-plan avec identifiants de bundle ; pas tous les processus Unix. L’application au premier plan peut être null ou avoir un ID vide.
- `app` signale les changements de cycle de vie observés avant l’événement `tick` de ce tick. Seul le focus comprend `previousAppId` (null si inconnu). Les noms sont affichés, sans être des IDs stables.
- `snooze` signifie que le bouton Pause du groupe a été pressé. Il n’applique aucune pause par lui-même.
- Les réponses de fichiers visent le groupe demandeur. Associez `requestId`, vérifiez `ok` et fixez une échéance avec les ticks : des réponses peuvent être perdues si la règle est rechargée/désactivée. Les IDs de requête peuvent se répéter après Exécuter ; les requêtes en attente ne sont pas un travail durable.

## Panneaux

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

Valeurs par défaut : position en bas à droite, largeur 300px ; les tailles petite/moyenne/grande valent 220/280/360px ; une largeur numérique est limitée à 180–520px et accepte les chaînes en pixels. Les panneaux/sections natifs empilent les commandes verticalement ; les champs de disposition, alignement, rôle, autofocus et dimensions du navigateur n’affectent pas le rendu natif.

Les IDs sont normalisés en lettres/chiffres ASCII/`_`/`-` (80 max) ; choisissez des IDs uniques et stables. Un ID de commande omis devient `control-N`, un type omis/inconnu devient du texte. Texte/listes omis sont vides ; disabled vaut false. Chaque appel remplace toute la spécification. Une `value` explicite remplace la saisie stockée ; une valeur omise utilise la dernière valeur d’événement puis la normalisation du type. Les événements natifs fournissent des chaînes : convertissez-les dans le type déclaré avant de réafficher le panneau. Les champs inconnus sont ignorés ; les couleurs/polices/CSS du panneau appartiennent à Vault.

Champs des commandes et valeurs initiales :

- `text` : chaîne `text` ; label par défaut. `html` : chaîne `html`, nettoyée et affichée en texte brut sur Mac.
- `button` : `label`, `action: "submit" | "cancel" | "close"` facultatif. La valeur du clic est la chaîne d’action, ou vide. Les actions ne soumettent/ferment rien automatiquement.
- `checkbox`, `toggle` : `value` booléenne (false par défaut) ; la valeur d’événement est `"true"`/`"false"`.
- `select`, `radio` : `options: (string | { value: string, label?: string })[]` ; chaîne (vide par défaut). Les valeurs d’option vides sont retirées ; les labels utilisent la valeur par défaut. Mettez à jour la valeur typée du panneau après sélection.
- `textInput`, `textarea` : chaîne (vide par défaut) ; `placeholder` pour textInput ; `rows` 1–12 pour textarea (3 par défaut). La zone de texte native ignore placeholder.
- `numberInput`, `range` : valeur numérique (0 par défaut), `min`, `max`, `step` positif. Les mises à jour du panneau bornent les valeurs ; les bornes de normalisation non précisées sont −1000000…1000000. Le champ numérique natif est une saisie de texte : validez vous-même `Number(event.value)` ; min/max/step ne limitent pas la frappe. Le curseur natif vaut 0…100 par défaut avec un pas de 1.
- `date`, `time` : saisie de texte ; formats initiaux `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` (formats initiaux invalides vidés). Validez les modifications vous-même. `color` : `#RRGGBB` (`#000000` par défaut).
- `pin` : chaîne de chiffres ; `length` 3–12 (6 par défaut), `masked` true par défaut, `autoSubmit` false. `section` : `text`, `controls` ; les sections enfants à la profondeur 3 n’ont pas d’enfants (commandes racines à la profondeur 0).

Événements des panneaux : les entrées ordinaires envoient `change` ; les boutons uniquement `click` ; le PIN envoie `change`, puis `submit` si autoSubmit le remplit. Aucun événement natif mount/unmount/focus/key. Les valeurs sont des chaînes, y compris nombres/booléens. `values` contient les entrées de l’instantané rendu et peut être en retard sur la modification déclenchante ; `value` identifie cette modification. Enregistrez-la dans `v.state` et rendez des valeurs typées pour des formulaires fiables. Les événements autres que click sont regroupés sur 100ms par commande ; ne comptez pas les événements comme des frappes.

Limites de texte : titre/label 240 ; description/texte 1000 ; HTML 20000 ; placeholder 500 ; texte saisi 2000 ; autres chaînes de valeur 512 ; valeur/label d’option 256. Le surplus est tronqué.

## Fichiers

`op` : `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`. Nécessite **Dossier des règles personnalisées** dans les Paramètres et son autorisation.

- `path` est relatif ; `/` sépare les répertoires. Les segments autorisent lettres/chiffres ASCII, espaces et `_.,@()-` ; aucun point initial, `.`/`..`, chemin absolu ou URL. Suffixes : `.txt`, `.csv`, `.json` (sans distinction de casse). Le chemin de liste est un répertoire ; `""` liste la racine choisie. Les chemins sortant du dossier choisi, notamment par lien symbolique, sont rejetés.
- Lire renvoie du texte UTF-8. Écrire remplace/crée ; ajouter crée/ajoute sans nouvelle ligne automatique. Les répertoires parents sont créés lors des écritures. Une chaîne est écrite telle quelle ; les autres contenus JSON sont sérialisés ; null/omis signifie texte vide. L’analyse JSON/CSV revient à la règle. Taille maximale : 1048576 octets UTF-8.
- Lister renvoie les sous-répertoires visibles immédiats et fichiers pris en charge. Entrées : `{ name: string, path: string, kind: "directory" | "file", extension?: string }` ; l’extension inclut le point pour les fichiers. Exists renvoie un booléen pour un chemin de fichier pris en charge.

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

Les champs de résultat inutilisés sont null ; la réussite a une erreur vide. Les échecs incluent chemin invalide, type non pris en charge, dossier indisponible, fichier manquant et fichier trop grand. Traitez error comme une chaîne, pas comme une énumération exhaustive fixe. Aucune API de transaction ; sérialisez les opérations lecture-modification-écriture par chemin.

## Enregistrements du groupe

`v.store(request)` lance une opération asynchrone d’enregistrement JSON dans un handler. Les enregistrements sont privés au groupe, persistent après Run et redémarrage, et sont supprimés avec le groupe. Les groupes liés ont des enregistrements séparés. La règle choisit clés, valeurs, versions, invalidation du cache et priorité des retours. Mac et navigateur utilisent la même API, mais chaque app/navigateur a son stockage.

| Requête | Résultat |
|---|---|
| `{op:"get", key}` | `record` ou `null` |
| `{op:"put", key, value, version?, ifRevision?}` | `record` enregistré |
| `{op:"delete", key, ifRevision?}` | `record: null` |
| `{op:"list", prefix?, after?, limit?}` | `entries` triées et `next` |
| `{op:"clear", prefix?}` | nombre `deleted` |

Chaque enregistrement contient `{value, revision, version, updatedAt}`. revision est opaque et change lors d’une vraie écriture ; `version` est une métadonnée de l’appelant. `list` renvoie les en-têtes sans valeurs ; `get` lit un enregistrement et `after: next` demande la page suivante. Sans `put`/`delete`, `ifRevision`, put/delete sont inconditionnels ; `null` exige une clé absente, une chaîne exige une correspondance exacte. En cas de conflit, retour `ok:false`, `error:"store-conflict"` et `record` courant. Cela évite qu’une réponse automatique tardive remplace un retour utilisateur. `v.context.revision` est un marqueur opaque de configuration que la règle peut inclure à sa version ; le framework n’impose pas de politique de cache.

Limites : clé 1–2048 caractères, version ≤128, valeur JSON ≤64KiB, profondeur ≤32, 10000 clés par groupe et document entier de16MiB. `list` renvoie au plus100 en-têtes et96KiB par page. Maximum32 requêtes par groupe et128 démarrages par seconde au total ; en surcharge, une erreur `store-busy` par groupe/seconde puis les suivantes sont abandonnées. Les erreurs de stockage renvoient `ok:false` ; un document futur ou mal formé est conservé et signale `store-unavailable`. Pas de nouvel essai ni éviction automatiques ; utiliser ticks pour les délais.

## Limites

Par événement et groupe : 256 actions en file, 200 appels de journal, 64 émissions ; le surplus est abandonné. Par règle : 1000 gestionnaires, 24 panneaux ; chaque liste de commandes contient 32 entrées et chaque choix 64 options ; le surplus est ignoré/tronqué. Les chaînes d’émission s’arrêtent après 16 générations. Limite d’état sérialisé : 65536 octets UTF-8. Gardez l’enregistrement et l’ensemble des gestionnaires de chaque événement sous 1 seconde ; les dépassements répétés ou un délai strict dépassé arrêtent la règle jusqu’à Exécuter. Le journal conserve 200 entrées par groupe. Les délais/réponses sont fournis au mieux, sans garantie de temps réel.

## Règle complète

Steam est bloqué sauf pendant une pause de cinq minutes déclenchée par Pause ou le bouton de son panneau :

```javascript
(on, v) => {
  v.state.pauseUntil ??= 0;
  const pause = ev => { v.state.pauseUntil = ev.now + 300000; };
  v.panel("pause", { controls: [{ id: "pause", type: "button", label: "Pause 5 min" }] });
  on("snooze", pause);
  on("panel", ev => {
    if (ev.data.panelId === "pause" && ev.data.controlId === "pause" && ev.data.eventName === "click") pause(ev);
  });
  on("tick", ev => v.block("com.valvesoftware.steam", ev.now >= v.state.pauseUntil));
}
```


## Appels IA depuis une règle active

Chaque groupe personnalisé choisit une connexion/un modèle et un effort de raisonnement dans **AI calls**. Mac et navigateur utilisent la même API ; les requêtes navigateur nécessitent Mac Vault connecté et les identifiants du fournisseur y restent. Les groupes liés partagent le choix et une limite quotidienne facultative. Vide signifie aucune limite de groupe ; les limites du compte s’appliquent. La limite suit le jour UTC, persiste après redémarrage et compte toutes les tentatives soumises, y compris échouées. Le lien combine l’usage existant ; la dissociation conserve l’usage antérieur.

`v.ai({ prompt, input? })` renvoie immédiatement un identifiant de requête. Appelez-la dans un handler, pas lors de l’enregistrement de la règle. `input` accepte toute valeur JSON ; chaque prompt/input est limité à20KB. Les réponses arrivent comme événements `ai` : `{requestId, ok, text, citations, error}`. Texte réussi jusqu’à48KB ; citations `{url,title}`. Gardez les liens de sources visibles et cliquables pour les réponses de recherche Web. La recherche est toujours disponible au modèle. Aucun délai fixe de l’app ; concurrence bornée ; aucun repli de fournisseur ni nouvel essai automatique. Les réponses sont des données, jamais exécutées comme JavaScript ; la règle décide des actions existantes.

Pour un panneau avec un bouton `ask` et un champ `note` :

```javascript
(on, v) => {
  let pending = null;
  on("panel", ({ data }) => {
    if (data.controlId !== "ask" || pending) return;
    pending = v.ai({ prompt: "Summarize this text.", input: data.values?.note ?? "" });
  });
  on("ai", ({ data }) => {
    if (data.requestId !== pending) return;
    pending = null;
    if (!data.ok) { v.log("AI request failed:", data.error); return; }
    v.log(data.text, data.citations);
  });
}
```

Les appels en attente ne sont pas rejoués après redémarrage. Run, désactivation/réactivation et suppression écartent les anciennes réponses ; un navigateur déconnecté signale `ai-unavailable`. Autres erreurs : `ai-not-configured`, `ai-invalid-input`, `ai-busy`, `ai-daily-limit`, `ai-request-failed`, `ai-usage-storage-unavailable`. Un appel échoué ne remplace pas un résultat antérieur conservé par la règle. La limite d’état reste64KB.

Découvrez les choix sans identifiants avec `rule_ai_models` sur Mac ou `settings-rule-ai-models` dans le navigateur ; configurez `ruleAI` via le chemin set-group existant. Champs : `providerModel`, `accountID`, `reasoningEffort` (`default`, `low`, `medium`, `high`) et `dailyRequestLimit` (null ou1–100000). Utilisez un choix retourné ; ne placez ni clé ni URL fournisseur dans le code source.
