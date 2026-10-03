# Manuel de code de Mac Vault

[Manuel d’utilisation](../manual/fr.md)

## Contrat des règles

Source : une expression de fonction `(on, v) => { ... }`. Seuls JavaScript synchrone et l’API ci-dessous sont pris en charge ; aucun minuteur, réseau, API système native ni accès aux pages du navigateur. Les règles temporelles utilisent `ev.now` et les événements. Les règles Safari utilisent le manuel de code du navigateur et s’exécutent dans l’application conteneur propre à Safari Vault.

- L’édition enregistre un brouillon ; **Exécuter** l’active et active le groupe. Les groupes verrouillés ne peuvent pas l’exécuter. Une source vide décharge la règle.
- Une exécution réussie remplace les gestionnaires/panneaux et efface l’ensemble d’applications bloquées du groupe, en conservant `v.state`. Une erreur de compilation/enregistrement conserve la règle précédente ; un délai dépassé peut l’arrêter. Le redémarrage réenregistre la dernière source activée ; les variables de fermeture et ensembles de blocage sont réinitialisés.
- L’enregistrement peut initialiser l’état, enregistrer les gestionnaires, afficher des panneaux et journaliser. Les actions sur applications/fichiers et émissions appartiennent aux gestionnaires ; leur file durant l’enregistrement est supprimée.
- Désactiver supprime les gestionnaires actifs et lève panneaux/blocages d’applications. Activer reprend la règle chargée et ses panneaux/blocages conservés. Supprimer retire ses gestionnaires/état/effets. Les applications précédemment fermées ne sont pas rouvertes ; les écritures de fichiers ne sont pas annulées.
- Les événements ne sont pas limités par les cibles ordinaires du groupe ; sélectionnez les applications dans la règle. Les actions sont mises en file puis appliquées après la distribution. Une exception arrête ce gestionnaire sans annuler son état/actions ; les suivants peuvent s’exécuter. Seules les actions de fichiers ont des événements de résultat.

## API

- `on(type, handler)` → booléen. Enregistre `handler(ev)` ; plusieurs gestionnaires s’exécutent dans l’ordre d’enregistrement. False signifie des arguments invalides ou une limite de gestionnaires atteinte. `ev = { type: string, now: number, data }` ; `now` est en millisecondes Unix.
- `v.state` : objet JSON modifiable, persisté après la distribution de l’événement. Initialisez les champs absents au lieu d’écraser l’état existant. Affecter une valeur non objet ou un tableau le réinitialise à `{}` ; les mises à jour non sérialisables/trop grandes ne sont pas persistées.
- `v.log(...values)` : seul producteur du Journal de ce groupe. Les journaux/Effacer sont indépendants par groupe. Les erreurs de chargement apparaissent dans l’état d’exécution ; les diagnostics des gestionnaires ne remplissent pas le Journal.
- `v.emit(type, data)` : met en file une copie JSON de `data` pour les gestionnaires de ce groupe après l’événement courant, avec un nouveau `now` ; ce n’est pas un appel synchrone.
- `v.panel(id, spec)` : remplace le panneau flottant nommé de ce groupe ; null `spec` le retire. Voir Panneaux.
- `v.file(op, path, payload?)` → chaîne ID de requête. Voir Fichiers.
- `v.block(appId, on)` : true maintient un blocage d’application, false retire celui de ce groupe. Les blocages se combinent entre groupes actifs ; cet appel ne peut pas lever une cible d’un autre groupe. Le blocage demande une fermeture normale et réessaie selon l’intervalle des Paramètres ; il n’empêche pas le lancement du processus et ne garantit pas que l’application accepte Quitter.
- `v.quit(appId)` : une demande de fermeture normale, soumise à la même politique de protection/nouvelles tentatives ; aucun blocage continu.
- `v.open(appId)` : demande à macOS d’ouvrir une application installée ; aucun rappel de réussite.

Les autres appels renvoient `undefined`. Les IDs d’application sont des identifiants de bundle (par exemple `com.valvesoftware.steam`), disponibles dans les événements. Bloquer/Fermer ignorent `com.apple.*`, les navigateurs, Vault et ses auxiliaires, et les IDs vides. Les IDs de panneau et l’état appartiennent à un groupe, pas à son nom affiché.

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

## Limites

Par événement et groupe : 256 actions en file, 200 appels de journal, 64 émissions ; le surplus est ignoré. Par règle : 1000 gestionnaires, 24 panneaux ; chaque liste de commandes contient 32 entrées et chaque choix 64 options ; le surplus est ignoré/tronqué. Les chaînes d’émission s’arrêtent après 16 générations. Limite d’état sérialisé : 65536 caractères de chaîne JavaScript. Gardez l’enregistrement et tous les gestionnaires d’un événement sous 1 seconde ; les dépassements répétés ou un délai strict dépassé arrêtent la règle jusqu’à Exécuter. Le journal conserve 200 entrées par groupe. Délais/réponses sont au mieux, sans garantie de temps réel.

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
