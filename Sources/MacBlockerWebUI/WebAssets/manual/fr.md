# Manuel utilisateur de Mac Vault

Mac Vault comprend trois pages : **Vault** bloque les apps natives, **Content tagging** étiquette le contenu navigateur pris en charge et **Activity** affiche l’utilisation enregistrée. L’extension recueille le contenu pris en charge et applique le blocage dans le navigateur. Installez-la et connectez-la dans votre navigateur.

## Démarrage rapide

1. Dans **Vault**, ajoutez un groupe de blocage et une cible Apps, puis choisissez des apps avec le sélecteur +.
2. Choisissez le comportement de blocage et activez le groupe.
3. Dans **Content tagging**, créez un groupe, choisissez ses plateformes et ajoutez des tags avec descriptions.
4. Dans Réglages → ### AI connections

**AI connections**, choisissez ChatGPT subscription, OpenAI API, Gemini API ou Grok API. Connectez le compte ou saisissez sa clé et récupérez les modèles, puis choisissez une connexion/un modèle dans le groupe. Activez le tagging et reprenez le groupe.
5. Ouvrez du contenu pris en charge dans le navigateur connecté. Ajoutez un filtre de tags à un groupe de blocage navigateur si vous voulez que les tags déterminent le blocage.

## Groupes de blocage

Un **blocking group** applique une politique de blocage. Un groupe **Content tagging** attribue des tags sans bloquer par lui-même. Ajoutez un groupe et nommez-le, choisissez les cibles dans **Applies to**, définissez quand bloquer et configurez calendrier ou quota de temps, puis activez le groupe.

Les modifications courantes sont enregistrées automatiquement. Une erreur signifie que la modification n’a pas été acceptée. Désactiver arrête la politique sans supprimer sa configuration ; **Delete group** la supprime. Faites glisser les groupes pour les réordonner. Plusieurs groupes peuvent viser la même cible ; le snooze de l’un ne lève pas le blocage de l’autre. **Export** copie la configuration ; **Import** remplace celle du groupe sélectionné après confirmation.

### Quota de temps et calendrier

**Block immediately** bloque quand le groupe activé correspond et que son calendrier est actif. **Block when the time allowance is used** autorise l’usage jusqu’à épuisement du quota. Réglez le quota en minutes et l’intervalle de réinitialisation en heures. Une limite glissante compte l’usage de la fenêtre précédente. Choisissez les jours et des plages horaires locales facultatives, une par ligne, par exemple **09:00-12:00**. Sans plage, toute la journée sélectionnée s’applique ; divisez un horaire nocturne entre deux jours.

### Snooze

Configurez le snooze dans chaque groupe. **Pause blocking** suspend la politique pendant la durée choisie. **Add to the time allowance** ajoute des minutes utilisables à un groupe limité dans le temps ; seule la durée supplémentaire consommée compte, le reste expire à la réinitialisation. **Activation delay**, **Cooldown** et **Required confirmations** règlent respectivement le délai initial, l’attente après la pause et le nombre de confirmations. ### Freeze et PIN

**Freeze** empêche les modifications habituelles. Le dégel exige dix confirmations espacées de cinq secondes, l’attente configurée et un PIN à six chiffres. **Wait before unfreezing** accepte 0 à 72 heures ; 0 n’ajoute aucun délai. En mode gelé, on peut prolonger l’attente et ajouter un PIN, mais pas assouplir ces conditions ; la suppression les respecte aussi.

### Freeze et PIN

**Freeze** empêche les modifications courantes. Le dégel exige dix confirmations espacées de cinq secondes, l’attente configurée et un PIN à six chiffres. **Wait before unfreezing** accepte 0–72 heures ; 0 n’ajoute aucun délai. En mode gelé, on peut prolonger l’attente et ajouter un PIN, mais pas assouplir ces conditions avant le dégel. La suppression respecte également l’attente restante et le PIN.

### Groupes liés

**Link** relie les groupes explicitement choisis dans d’autres programmes Vault. Ils partagent nom, réglages pris en charge, cibles, usage et conditions de gel. Chaque programme modifie et applique les types de cibles qu’il prend en charge. **Unlink** dissocie les groupes sans les supprimer. Si un membre est hors ligne, ouvrez Mac Vault et le navigateur lié pour rétablir la connexion.

## Aide

Cliquez sur le petit **i** à côté d’un champ pour afficher son explication ; cliquez à l’extérieur ou appuyez sur Échap pour fermer. Les listes restent dans des zones défilantes ; la recherche filtre les éléments visibles sans les supprimer. Les règles personnalisées ont leur [manuel de code](../code-manual/fr.md), qui explique l’éditeur, l’activation, les journaux, les fichiers et l’API.

## Apps natives

Cliquez sur le petit **i** d’un champ pour son explication ; cliquez ailleurs ou appuyez sur Échap pour fermer. Les listes restent dans des zones défilantes ; la recherche filtre les éléments visibles sans les supprimer. Le [manuel du code](../code-manual/fr.md) décrit l’éditeur des règles personnalisées, l’activation, les journaux, l’accès aux fichiers et l’API.

Le sélecteur + d’une cible Apps affiche les apps installées ou ouvertes ; rouvrez-le pour actualiser la liste après avoir lancé une app depuis un autre dossier. **Block every app except these** transforme la liste en liste d’autorisation. Mac Vault peut bloquer les apps Apple ordinaires et des navigateurs entiers ; Mac Vault et toute app partageant son bundle ID restent protégés. Une app bloquée reçoit une demande de fermeture ; **Ask a blocked app to quit again every (minutes)** règle les nouvelles tentatives. Les redirections web, pauses de page et masquage de flux relèvent de l’extension.

## Content tagging

Un groupe Content tagging étiquette le contenu de ses plateformes avec son arbre de tags et ses réglages de modèle. Chaque plateforme appartient à un groupe ; choisissez-les à la création car elles ne sont plus modifiables ensuite. Les horaires et filtres de blocage ne contrôlent pas le tagging. Activez-le dans Réglages et mettez chaque groupe en pause/reprise séparément. Désactiver l’enregistrement du flux dans **Activity → Recording** arrête aussi son tagging.

### Tags et réglages du modèle

Créez des tags, décrivez leur sens et définissez ou retirez leurs parents dans l’arbre. Le glisser-déposer déplace une branche. **Minimum confidence** définit le niveau de preuve de 1 à 5 ; les nouveaux groupes commencent à 4 (preuve forte). Aucun nombre de tags n’est imposé ; un élément peut n’en recevoir aucun. **Tagging instructions** mémorise les préférences du groupe. Les modifications s’enregistrent automatiquement ; chaque groupe utilise connexion, modèle et effort explicitement choisis.

### AI connections

**AI connections** propose ChatGPT subscription, OpenAI API, Gemini API et Grok API. L’abonnement utilise la connexion Vault et un forfait admissible ; les clés API suivent la facturation et les limites du fournisseur. Choisissez le fournisseur et saisissez la clé sous la liste commune ; elle est enregistrée automatiquement, la vider la supprime. **Fetch model list** récupère les modèles sans en choisir un. **Reasoning effort** propose modèle par défaut, Low, Medium ou High selon prise en charge. Les nouveaux choix commencent à Medium ; les anciens restent enregistrés. Un effort plus élevé peut prendre du temps et utiliser plus de jetons. La recherche Web est toujours activée pour le tagging ; le modèle décide quand l’utiliser. En cas d’échec, les résultats valides en cache restent ; les nouveaux éléments restent en attente jusqu’à **Retry cloud classification**. Aucun changement automatique de fournisseur ; chaque connexion a son intervalle et sa limite d’essais. Corrigez les tags dans l’extension avec **+ tag** ; commande de retrait ou Delete une fois pour supprimer. **Untagged** signifie terminé sans tag ; **Tagging** signifie en attente. Votre correction fait autorité.

## Activity

### Activity groups

Créez un groupe pour afficher ensemble ses apps et sites sélectionnés dans Usage. **Merge** donne un nom et une couleur communs à ses membres dans Activity. Ce groupe organise l’utilisation enregistrée ; il est distinct des groupes de blocage et de tagging. Enregistrez explicitement l’éditeur avec **Save**.

### Recording and retention

Dans **Recording**, activez ou arrêtez l’enregistrement par catégorie ou source. **Keep** règle la conservation ; **Forever** évite l’expiration automatique. L’arrêt empêche de nouveaux enregistrements ; supprimer l’historique retire les entrées. Les flux de plateforme recueillent le contenu affiché sur les pages prises en charge, qu’elles aient été ouvertes ou non. Un flux **Tagging supported** peut alimenter le tagging pendant l’enregistrement ; sa conservation est indépendante de l’usage des apps et sites. Mettre en pause un groupe de tagging n’arrête pas l’enregistrement.


Créez un groupe pour afficher ensemble apps et sites choisis dans Usage. **Merge** donne un nom et une couleur communs aux membres dans Activity. Il est distinct des groupes de blocage et de tagging. Enregistrez explicitement avec **Save**.


Dans **Recording**, activez ou désactivez chaque catégorie ou source. **Keep** définit la durée de conservation ; **Forever** évite l’expiration automatique. Les choix individuels peuvent suivre le réglage général. Arrêter l’enregistrement empêche les nouveaux enregistrements ; supprimer l’historique retire les entrées. Les flux recueillent le contenu affiché sur les pages prises en charge, ouvertes ou non. Un flux **Tagging supported** peut alimenter le tagging quand l’enregistrement est actif. Sa conservation est séparée de l’usage des apps/sites. Mettre en pause un groupe de tagging n’arrête pas l’enregistrement.

## Settings

Choisissez la langue dans Réglages ; les boutons Info affichent les explications dans cette langue.

## Saving and troubleshooting

Les modifications courantes de Vault/tagging sont automatiques ; les groupes Activity nécessitent **Save**. Ajout, suppression, tests de connexion et récupération des modèles sont des actions explicites. Si des tags manquent, vérifiez le navigateur, l’activation globale, la pause, l’enregistrement de la plateforme, la connexion/le modèle et les identifiants. Pour une requête IA échouée, vérifiez aussi les limites fournisseur et le journal du groupe. Reconnectez les programmes d’un groupe lié ou dégèlez-le comme indiqué.
