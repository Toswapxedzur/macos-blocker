# Référence fonctionnelle de l'application de bureau Vault

## Objectif et limites

Il s'agit de la référence faisant autorité pour l'interface de l'application de bureau Vault. Il est intentionnellement séparé du manuel de l'extension du navigateur Vault.

L'application de bureau gère les **applications natives et les fenêtres d'application**. L'extension de navigateur gère les sites Web, les onglets du navigateur et les flux de plateforme Web pris en charge. Ils partagent les mêmes idées (groupes, planifications, minuteries, gels, répétitions, règles personnalisées et pont facultatif), mais ils n'ont pas la même surface d'application.

Utilisez ce document pour configurer, auditer, reproduire ou maintenir le comportement de l'application de bureau. Le code est canonique si une implémentation et ce manuel diffèrent.

## 1. Ce que l'application de bureau peut et ne peut pas contrôler

Vault évalue la stratégie de focus pour les applications natives sélectionnées. Lorsque sa capacité d'application native est disponible, il peut appliquer le plan actuel aux cibles d'application correspondantes et signaler un résultat de bouclier/statut à l'interface utilisateur hôte.

Il peut :

- créer, activer, désactiver, réorganiser, importer, exporter, geler, répéter et supprimer des groupes ;
- cibler les applications natives sélectionnées via le sélecteur d'applications ;
- appliquer un blocage immédiat, une allocation chronométrée ou un compte à rebours uniquement ;
- restreindre les groupes normaux aux jours de semaine et aux plages horaires locales ;
- exécuter des règles de politique JavaScript personnalisées pour les événements du cycle de vie des applications ;
- afficher les informations natives sur l'état/le panneau créées par des règles via l'hôte ;
- gérer un dossier local facultatif pour les demandes de fichiers de règles personnalisées prises en charge ;
- Rejoignez des groupes compatibles explicitement liés via le pont Vault local.

Il ne peut pas :

- agir comme une extension de navigateur, inspecter le DOM d'un site Web ou manipuler les cartes de flux du navigateur ;
- garantir qu'un système d'exploitation permettra de contrôler chaque application, processus, fenêtre ou service système ;
- transformez la sélection d'applications en administration à distance, surveillance des appareils ou pare-feu ;
- faire fonctionner les aides personnalisées du navigateur uniquement, telles que le DOM, la navigation, la redirection ou le contrôle des onglets, dans le runtime natif ;
- synchroniser automatiquement chaque groupe simplement parce que le pont local est en cours d'exécution.

## 2. Vocabulaire

| Terme | Signification |
| --- | --- |
| Groupe | Un objet de stratégie de focus nommé. Les noms de groupe doivent être uniques au sein du point de terminaison Vault actuel. |
| Cible | Identité d'application native sélectionnée pour un groupe. |
| Groupe d'applications par défaut | Un groupe normal dont les cibles sont les applications natives du sélecteur d'applications. |
| Custom group | A group whose JavaScript rule reacts to application-policy events. |
| Correspondance | L’application de premier plan/en cours d’exécution correspond à une cible de groupe activée et active ou à une condition de règle personnalisée. |
| Actif | Activé, selon le calendrier normal, et non activement mis en veille. |
| Plan d'exécution | Décision d'autorisation/bouclier/statut résultante de l'hôte natif après avoir évalué les groupes applicables. |
| Geler | Protection contre la modification ordinaire d'un groupe. |
| Répéter | Une exception temporaire à une politique de groupe normale. |

## 3. Sélecteur d'identité cible et d'application

Sélectionnez les applications via le sélecteur ****** dans un groupe d'applications par défaut. Vault stocke une identité normalisée ainsi qu'un nom d'affichage.

| Hôte | Identité cible utilisée pour la mise en correspondance |
| --- | --- |
| macOS | Identifiant du bundle d’applications, le cas échéant. |
| Fenêtres | Chemin d'accès exécutable normalisé ou nom de processus fourni par le sélecteur d'application. |

Le nom d'affichage est celui de l'éditeur. La valeur normalisée est l'identité utilisée par la couche d'application native. Renommer une application dans l’interface utilisateur ne modifie pas l’identité. Une cible peut également contenir des balises pour une utilisation de stratégie de règle personnalisée.

N'entrez pas l'URL d'un site Web dans un champ cible d'application et attendez-vous à une application native de l'application. Utilisez le groupe Site de l'extension pour bloquer les sites Web.

## 4. Cycle de vie et priorité du groupe

Un nouveau groupe est activé par défaut. La liste de groupes prend en charge la sélection, l'activation/désactivation, l'ordre de glissement, l'ajout, l'effacement, l'importation, l'exportation et la suppression. Le groupe sélectionné s'ouvre dans l'éditeur.

Les modifications normales des champs sont enregistrées via la politique de sauvegarde automatique de l'éditeur. Un groupe gelé désactive les contrôles d'édition ordinaires. Une source personnalisée est différente : l’enregistrement du texte ne la rend pas active ; **Exécuter** est l'opération qui charge la source actuelle dans le runtime de la stratégie.

Plusieurs groupes peuvent correspondre à une même application. Vault évalue la stratégie de groupe dans l'ordre stocké et crée un plan d'application natif. Gardez les chevauchements intentionnels, en particulier lorsque les groupes utilisent des politiques temporelles différentes ou des décisions d'autorisation/de protection émises par des règles personnalisées. Réorganisez les groupes pour clarifier la priorité souhaitée ; ne comptez pas sur la résolution d’une configuration conflictuelle d’une manière particulièrement conviviale.

## 5. Groupes d'applications normaux

### 5.1 État du groupe

| Champ | Contrat fonctionnel |
| --- | --- |
| Nom | Non vide, tronqué, unique, sans tenir compte de la casse au sein de ce point de terminaison. |
| Activé | Les groupes handicapés sont retenus mais ne participent pas à l'application normale. |
| Cibles | Une ou plusieurs identités d'application sélectionnées dans le sélecteur. |
| Comportement | Blocage immédiat, blocage après une allocation ou minuterie/compte à rebours. |
| Calendrier | Jours de semaine sélectionnés et fenêtres horaires locales facultatives. |
| Geler | Aucun, Gelé, Gelé strict ou Gelé parental. |
| Répéter | Politique d’exception temporaire par groupe. |
| Message de secours/d'état | Message que l'hôte natif peut afficher lorsqu'il applique une réponse de bouclier/statut. |

Un groupe par défaut vide n'a pas de cible d'application sélectionnée et ne correspond donc pas à une application simplement par son existence.

### 5.2 Comportements bloquants

| Comportement | Résultat |
| --- | --- |
| Bloquer immédiatement | Une cible active correspondante produit une décision native immédiate de blocage/bouclier. |
| Bloquer après quelques minutes | L'utilisation correspondante s'accumule sur l'allocation de groupe. Lorsque l'allocation est épuisée, le groupe produit une décision native de blocage/bouclier jusqu'à ce que sa période d'utilisation soit réinitialisée ou qu'un autre état rende le groupe inactif. |
| Minuterie (compte croissant, pas de blocage) | L'utilisation correspondante est mesurée et peut être affichée, mais cette minuterie à elle seule ne produit jamais de blocage. |

Les nouveaux groupes utilisent une allocation de 15 minutes et un intervalle de réinitialisation de 24 heures, sauf modification. L'utilisation programmée appartient au groupe, donc toutes les cibles correspondantes partagent cette stratégie de groupe. La réponse exacte à un blocage est implémentée par l'hôte natif et est limitée par les autorisations du système d'exploitation et le mécanisme d'application pris en charge.

### 5.3 Horaires

Les horaires s'appliquent aux groupes normaux. Un groupe personnalisé prend ses propres décisions temporelles en JavaScript.

Sélectionnez n’importe quelle combinaison du lundi au dimanche. Chaque fenêtre horaire correspond à une ligne en heure locale :

```text
0900-1200
1330-1730
```

Le format exact accepté est HHMM-HHMM. Les heures doivent être de 00 à 23, les minutes de 00 à 59 et le début doit être plus tôt que la fin du même jour. Une fenêtre inclut son début et exclut sa fin. Les fenêtres traversant minuit ne sont pas acceptées. Les fenêtres vides signifient toute la journée sélectionnée.

Le groupe normal est actif uniquement lorsque :

1. il est activé ;
2. le jour de la semaine actuel est sélectionné ;
3. l'heure locale se trouve dans une fenêtre configurée ou le groupe n'a pas de fenêtre ;
4. il n'est pas en mode répétition active.

### 5.4 Répéter

Snooze supprime temporairement un groupe normal de l'application active. Ses phases sont :

| Phases | Résultat |
| --- | --- |
| En attente | La demande existe mais le délai d'activation n'est pas écoulé ; le groupe reste actif. |
| Actif | Le groupe est temporairement inactif pendant sa durée de répétition. |
| Temps de recharge | La répétition est terminée et le groupe est à nouveau actif, mais une nouvelle répétition n'est pas encore disponible. |

| Paramètre | Règle |
| --- | --- |
| Autoriser la répétition | Lorsqu'il est désactivé, le groupe ne peut pas être normalement mis en veille. |
| Durée de répétition | Nombre de minutes positif. La durée par défaut pour un nouveau groupe est de 30 minutes. |
| Délai d'activation | Zéro ou plusieurs minutes avant que la répétition ne devienne active. |
| Temps de recharge | Zéro jusqu'à cinq minutes après la fin de la répétition active. |
| Confirmations | Nombre entier non négatif d’interactions de confirmation requises. |

Une répétition active est une exception temporaire aux règles, et non une suppression ou un dégel. La configuration du groupe reste intacte.

### 5.5 Geler

Le gel est une barrière de modification délibérée.

| Mode | Contrat |
| --- | --- |
| Congelé | Les modifications ordinaires et les changements d'état ordinaires restent verrouillés jusqu'à ce que le flux de confirmation de dégel du produit réussisse. |
| Strictement congelé | Le groupe ne peut pas être dégelé avant la fin de sa durée de gel strict. La durée est positive et limitée à 72 heures. |
| Gelé parental | La gestion du mot de passe du tuteur est requise pour les actions de gel/dégel. |

Le choix d'un mode dans l'éditeur ne fige pas automatiquement le groupe ; utilisez l’action de gel pour l’appliquer. Un groupe lié par pont peut également verrouiller les commandes de gel coordonnées lorsqu'un membre requis est hors ligne.

## 6. Application native et contrôle des appareils

L'éditeur peut enregistrer avec précision un groupe même lorsque le système d'exploitation n'a pas accordé la possibilité de l'appliquer. Vérifiez toujours **Paramètres → Contrôle des appareils** et l'état natif en direct après avoir modifié les autorisations.

L'hôte natif décide quelles actions sont possibles pour le système d'exploitation, l'application, la fenêtre et l'état d'autorisation actuels. Une règle peut être correctement configurée sans avoir d'effet visible dans les cas suivants :

- Le contrôle des appareils n'est pas accordé ou a été révoqué ;
- le groupe est désactivé, programmé ou activement mis en veille ;
- le processus ciblé ne correspond pas à une cible normalisée sélectionnée ;
- le système d'exploitation rejette une action pour cette cible ;
- une dépendance de pont est hors ligne pour une action qui nécessite un état coordonné.

Ne considérez pas un toast de sauvegarde réussi comme une preuve qu’une application active est disponible. Testez la cible sélectionnée pendant que le groupe est actif et inspectez l'état de l'hôte.

## 7. Groupes personnalisés et règles de stratégie natives

Les groupes personnalisés s’exécutent dans le runtime de stratégie JavaScript natif. Ce ne sont pas des règles personnalisées du navigateur. Le DOM du navigateur, les onglets, la navigation, la redirection d'URL et le comportement de contrôle du flux sont intentionnellement indisponibles.

### 7.1 Cycle de vie des sources

Use a function expression:

```js
(events, helpers) => {
  events.on("focusEvent", "shield-focus", (event, h) => {
    if (event.target?.id) event.setResult(-1);
  });
}
```

Run loads the source and its event registrations. Running again unloads the old source and resets its rule-owned handlers, timers, panels, persistence, and dynamic app blocklist. A source that does not evaluate to a function cannot be loaded.

### 7.2 Événements natifs intégrés

| Événement | Signification |
| --- | --- |
| tickEvénement | Tique hôte périodique. Une option d’enregistrement intervalMs peut limiter le débit d’un gestionnaire. |
| minuterieFin | Un compte à rebours appartenant à une règle atteint zéro. |
| snoozePresse | L'utilisateur appuie sur Start Snooze pour un groupe personnalisé. |
| panneauÉvénement | Un contrôle de panneau personnalisé est utilisé. |
| localFileEvent | Une action de dossier local demandée se termine. |
| openAppEvent | Une application suivie s'ouvre. |
| closeAppEvent | Une application suivie se ferme. |
| focusÉvénement | L'application de premier plan se transforme en application. |
| unfocusEvent | L'application de premier plan change d'application. |
| minimiserEvent / unminimizeEvent | L’hôte signale une transition de réduction de fenêtre prise en charge. |
| switchAppEvent | L'application au premier plan change d'une application à l'autre. |
| appChangedEvent | Événement général de cycle de vie/changement d’application. |

L'objet événement contient le type, groupId/groupID, groupName, les équivalents URL/nom d'hôte, l'heure, les données et la cible. Pour une application native, target expose un identifiant, un genre, un displayName, une valeur normalisée et des balises lorsque la cible de focus correspond à une cible configurée.

Les données d'événement du cycle de vie de l'application incluent l'ID/nom de l'application actuelle, le nom du groupe, un instantané sérialisé de l'application en cours d'exécution et des valeurs spécifiques à l'événement telles que bundleId, previousAppId, currentAppId ou le motif de modification.

### 7.3 API d'événement et décisions

Le registre fournit on/registered, off/unregister, unregisterAll, countRegistered, getEvent et getEvents. La priorité la plus élevée s'exécute en premier ; une priorité égale préserve l’ordre d’enregistrement. Le registre a une limite de gestionnaire par groupe.

L'objet événement prend en charge :

| Méthode | Résultat |
| --- | --- |
| setResult(-1) | Produire une décision native de bouclier/blocage. Un résultat de chaîne devient également un bloc natif car les règles de bureau n'ont pas de cible de redirection du navigateur. |
| allow(reason) ou setResult(1) | Produisez une décision d’autorisation pour l’événement. |
| setShieldMessage(message) | Définissez le message de bouclier/statut face à l'homme pour un bloc natif. |
| stopPropagation() | Arrêtez les gestionnaires ultérieurs pour l'événement en cours. |
| bloquer (appId), débloquer (appId) | Ajouter/supprimer un bloc d'application natif dynamique. |
| fermer (appId), ouvrir (appId) | Demandez une action de fermeture/ouverture native prise en charge. |
| post(type, données) | Distribuez un événement personnalisé imbriqué dans le runtime natif. |

Le runtime de l'application autorise les minuteries, la persistance, les panneaux, les journaux, les opérations sur les dossiers locaux, les assistants de fenêtre d'application et les utilitaires de classification d'URL. Il traite délibérément les aides DOM, de navigation, de redirection et d'onglets de navigateur comme indisponibles/inertes.

### 7.4 Aides autochtones

| Aide | Comportement autochtone |
| --- | --- |
| getLogHelper | Émet des décisions de journal d’application/popup/écran. |
| getTimerHelper | Crée des minuteries avant/arrière avec des limites, des étapes, des prédicats de portée/domaine, une pause/reprise, une inspection d'état et des transitions timerEnded. Les minuteries ne protègent pas par elles-mêmes. |
| getPersistenceHelper | État JSON par groupe : obtenir, définir, supprimer, possède, clés, entrées, effacer, taille. |
| getStorageHelper | Persistance plus héberger des espaces réservés pour les demandes asynchrones ; ne supposez pas une réponse externe synchrone. |
| getWindowHelper | Lit les applications actuelles/en cours d’exécution et demande des actions de fermeture/ouverture/blocage/déblocage d’application. |
| getPanelHelper | Crée des instantanés de panneau natifs validés, des contrôles, des gestionnaires en ligne et des réactions panelEvent. |
| getLocalFolderHelper | Les files d'attente autorisaient les opérations relatives .txt, .csv et .json sous la racine accordée par l'utilisateur. L'achèvement est localFileEvent. |
| getDomainHelper / getDomainUtility | Classificateurs d'URL et de plate-forme pour les règles qui raisonnent également sur les valeurs de type URL. |
| getPlatformHelper / plateforme | Les classificateurs d'URL restent disponibles ; Les appels de contrôle de flux/DOM natifs sont inertes car l’hôte de bureau n’a pas de DOM de site Web. |

Les panneaux personnalisés utilisent le même vocabulaire de contrôle déclaratif que le moteur d'exécution du navigateur : texte, case à cocher, sélection, entrée de texte, zone de texte, bouton, section, minuterie, entrée de nombre, plage, bascule, radio, date, heure, couleur, code PIN et code HTML nettoyé. L'hôte natif décide de la quantité de panneau qui peut être affichée sur la plateforme actuelle.

## 8. Dossier de fichiers local

Le dossier de fichiers local est une limite facultative accordée par l'utilisateur pour les règles personnalisées. Les règles peuvent demander des lectures, des écritures, des ajouts, des listes, des tests d'existence et des opérations JSON au format texte/CSV/JSON. Les chemins sont toujours relatifs à la racine sélectionnée. Les chemins absolus, les segments de parcours, les composants de chemin cachés, les extensions non prises en charge et les opérations en dehors de la racine sont rejetés.

Révoquez le dossier lorsqu'une règle n'en a plus besoin. Une règle doit gérer les autorisations indisponibles et les résultats d'échec de localFileEvent ; il ne faut pas supposer qu'un dossier sélectionné reste autorisé après un redémarrage.

## 9. Pont d'application Web

Le pont est une synchronisation locale facultative entre les programmes Vault compatibles. Une application de bureau native peut héberger le hub local ; les clients se connectent à l'adresse locale prise en charge.

Les états de connexion sont Désactivé, En cours de connexion, Déconnecté, Connecté/En cours d'exécution et Erreur. La connexion d'un programme ne fusionne pas tous les groupes. L'utilisateur doit lier explicitement les groupes correspondants éligibles.

Pour un lien de groupe :

1. Démarrez le hub natif dans Paramètres.
2. Connectez l'autre point de terminaison Vault compatible.
3. Créez des groupes correspondants et non gelés avec le même nom et le même type.
4. Dans la section Pont de groupe, choisissez le programme et connectez le groupe.

Un groupe lié forme un cluster. Les valeurs de stratégie communes prises en charge, l'utilisation et l'état de répétition peuvent être synchronisés lorsque les membres sont connectés. La déconnexion interrompt la synchronisation et préserve les groupes locaux. Le transfert des cibles réservées au navigateur, des actions personnalisées non prises en charge et des champs spécifiques à la plate-forme n'est pas garanti.

## 10. Importer, exporter, réinitialiser et auditer

L'exportation enregistre une représentation de groupe compatible. L'importation valide/normalise les données de groupe compatibles tout en appliquant l'unicité du nom local. Supprimer le groupe supprime le groupe sélectionné et son état associé. Clear supprime tous les groupes après confirmation. La réinitialisation aux valeurs par défaut affecte les paramètres globaux de l'éditeur ; exporter tout ce qui doit être conservé en premier.

Avant de vous fier à une règle de bureau :

1. Vérifiez que le contrôle des appareils est accordé.
2. Vérifiez l'identité normalisée de la cible sélectionnée.
3. Vérifiez l'état activé, la planification, l'état de gel et la phase de répétition.
4. Testez séparément les comportements immédiats, chronométrés et à compte croissant.
5. Pour un groupe personnalisé, exécutez la source exacte et testez chaque événement d'application enregistré.
6. Vérifiez les échecs du dossier local ainsi que les opérations réussies.
7. Vérifiez le comportement du pont hors ligne/connecté si le groupe est lié.

## 11. Notes spécifiques à la plateforme

Les concepts de stratégie de base sont partagés, mais l'application native est spécifique à l'hôte :

| macOS | Fenêtres |
| --- | --- |
| Les cibles sont normalement résolues en identifiants de bundle d’applications. Contrôle des appareils et application actuelle des portes d’état des autorisations macOS. | Les cibles sont normalement résolues en un chemin d'exécutable ou un nom de processus normalisé. La couche d'application de Windows décide quelles fenêtres/processus actuels peuvent être gérés. |

Cette référence de bureau ne décrit délibérément pas les listes de blocage de sites Web, les sélecteurs de flux, la classification des créateurs YouTube, les redirections de navigateur ou les actions des onglets du navigateur. Ceux-ci appartiennent au manuel de l'extension Vault.
