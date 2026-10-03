# Manuel utilisateur de Mac Vault

Mac Vault comporte trois pages : **Vault** bloque les applications natives, **Classificateur** attribue des tags au contenu des navigateurs pris en charge et **Activité** affiche l’utilisation enregistrée. L’extension collecte le contenu pris en charge et applique le blocage dans le navigateur. Installez-la et connectez-la dans le navigateur que vous utilisez.

## Démarrage rapide

1. Dans **Vault**, ajoutez un groupe de blocage et une cible Applications, puis choisissez des applications avec le sélecteur +.
2. Choisissez le comportement de blocage du groupe et activez-le.
3. Dans **Classificateur**, créez un groupe, choisissez ses plateformes et ajoutez des tags avec leurs descriptions.
4. Choisissez un niveau de modèle local et téléchargez-le si nécessaire. Activez le tagging dans les paramètres du Classificateur et reprenez le groupe.
5. Ouvrez du contenu pris en charge dans le navigateur connecté. Configurez un filtre de tags dans un groupe de blocage du navigateur pour utiliser les tags dans le blocage.

## Groupes de blocage

Un **groupe de blocage** applique une politique de blocage. Un **groupe du Classificateur** attribue des étiquettes au contenu ; il ne bloque rien à lui seul.

1. Ajoutez un groupe de blocage et donnez-lui un nom.
2. Choisissez les cibles sous **S’applique à**.
3. Choisissez quand le blocage s’applique, puis définissez les horaires ou le temps autorisé nécessaires.
4. Activez le groupe. Ses cibles partagent sa politique.

Les modifications courantes sont enregistrées automatiquement. Une erreur signifie que la modification n’a pas été acceptée ; corrigez le champ et réessayez. Désactivez un groupe pour arrêter sa politique tout en conservant sa configuration. **Supprimer le groupe** le retire. Faites glisser les groupes pour les réordonner. Plusieurs groupes peuvent s’appliquer à une cible ; mettre l’un en pause ne lève pas le blocage d’un autre.

**Exporter** copie la configuration d’un groupe. **Importer** remplace la configuration du groupe sélectionné après confirmation.

### Temps autorisé et horaires

**Bloquer immédiatement** s’applique dès que le groupe activé correspond et que ses horaires sont actifs. **Bloquer lorsque le temps autorisé est épuisé** permet l’utilisation correspondante jusqu’à épuisement du temps disponible.

Définissez le temps autorisé en minutes et l’intervalle de réinitialisation en heures. Une limite glissante compte l’utilisation dans la fenêtre précédente. La réinitialisation à minuit commence une nouvelle période à minuit local, y compris pour une limite glissante.

Choisissez les jours actifs et, éventuellement, des plages horaires locales, une par ligne, par exemple **09:00-12:00**. Une liste vide s’applique pendant toute la journée des jours sélectionnés. Une plage doit se terminer après son début le même jour ; répartissez un horaire nocturne sur des jours distincts.

### Pause

Configurez la pause dans chaque groupe de blocage. **Mettre le blocage en pause** suspend la politique du groupe pendant la durée de pause. **Ajouter au temps autorisé** ajoute des minutes utilisables à un groupe limité dans le temps. Seul le temps supplémentaire consommé compte comme temps de pause. Le temps supplémentaire inutilisé expire à la prochaine réinitialisation ; pour une limite glissante, après une fenêtre, ou plus tôt à minuit si cette option est activée.

**Délai d’activation** reporte la pause tandis que le blocage continue. **Délai après la pause** est l’attente entre la fin d’une pause et une nouvelle demande. **Confirmations requises** définit le nombre d’étapes de confirmation. La pause n’est disponible dans un groupe verrouillé que si elle était autorisée avant le verrouillage.

### Verrouillage et PIN

**Verrouiller les modifications** empêche les modifications courantes. Le déverrouillage exige dix confirmations espacées de cinq secondes, ainsi que l’attente configurée et le PIN à six chiffres, le cas échéant. **Attente avant le déverrouillage** accepte 0–72 heures ; 0 n’ajoute aucune attente.

Pendant le verrouillage, l’attente peut être prolongée et un PIN ajouté s’il n’en existe pas. Ces conditions ne peuvent pas être assouplies avant le déverrouillage du groupe. La suppression respecte également l’attente restante et le PIN.

### Groupes liés

Utilisez **Lier** pour connecter des groupes explicitement sélectionnés dans d’autres programmes Vault. Les groupes liés partagent leur nom, les paramètres de politique pris en charge, les cibles, l’utilisation et les conditions de verrouillage. Chaque programme modifie et applique les types de cibles qu’il prend en charge ; les autres entrées restent accessibles aux programmes liés. Délier conserve chaque groupe et ses paramètres.

Si un membre lié est hors ligne, les modifications peuvent être indisponibles. Ouvrez Mac Vault et le navigateur lié pour les reconnecter. Une politique locale enregistrée peut continuer à s’appliquer pendant qu’un membre est hors ligne.

## Obtenir de l’aide

Cliquez sur le petit **i** près d’un champ pour voir son explication. Cliquez à l’extérieur ou appuyez sur Échap pour la fermer. Les listes restent dans des zones défilantes ; faites défiler la zone pour atteindre d’autres entrées. La recherche filtre la liste visible sans supprimer d’entrées.

Les règles personnalisées ont leur propre [Manuel de code](../code-manual/fr.md). Il explique l’éditeur, l’activation, les journaux, l’accès aux fichiers et l’API prise en charge.

## Applications natives

Utilisez le sélecteur + d’une cible Applications pour choisir les applications installées. **Bloquer toutes les applications sauf celles-ci** transforme la liste en liste d’autorisation. Les applications système, les navigateurs et Vault lui-même sont exclus du blocage des applications natives.

Une application bloquée reçoit une demande de fermeture. **Redemander la fermeture d’une application bloquée toutes les (minutes)** règle les nouvelles tentatives. Les redirections de sites, les pauses de pages et le masquage des fils sont appliqués par l’extension ; ils ne deviennent pas des actions sur les applications natives.

## Classificateur

Un groupe du Classificateur attribue des tags au contenu de ses plateformes avec son propre arbre de tags et ses paramètres de modèle. Chaque plateforme appartient à un groupe. Choisissez les plateformes à la création du groupe ; elles ne peuvent plus être modifiées ensuite. Les horaires et filtres des groupes de blocage ne contrôlent pas le tagging.

Activez le tagging dans les paramètres du Classificateur. Utilisez séparément **Suspendre le tagging / Reprendre le tagging** dans chaque groupe. Désactiver l’enregistrement du fil d’une plateforme dans **Activité → Enregistrement** arrête également son tagging.

### Tags et paramètres du modèle

Créez des tags, décrivez leur sens et définissez ou supprimez leurs parents dans l’arbre. Faites glisser un tag pour déplacer sa branche. Des descriptions claires aident le modèle à distinguer les tags similaires. Les paramètres de chaque groupe sont indépendants.

- **Vitesse ↔ Qualité** sélectionne un niveau de modèle local. Les modèles plus grands utilisent plus de mémoire ; la vitesse et les résultats dépendent du Mac et de la charge. Les téléchargements sont partagés entre les groupes.
- **Strict ↔ Large** définit les exigences de confiance et les nombres de tags par défaut.
- **Tags minimum / Tags maximum** dans Plus remplacent ces nombres par défaut. Strict ↔ Large contrôle toujours la confiance des tags supplémentaires. Laissez un champ vide pour utiliser sa valeur par défaut.
- **Instructions de tagging** ajoute des instructions facultatives pour ce groupe.

Les modifications courantes du Classificateur sont enregistrées automatiquement. Le niveau sélectionné doit être téléchargé avant de pouvoir attribuer des tags. Les groupes utilisant le même niveau partagent un modèle chargé ; deux niveaux au maximum restent chargés à la fois.

Corrigez les tags d’un contenu dans l’extension. Cliquez sur **+ tag**, recherchez les tags existants du Classificateur et choisissez-en un pour l’ajouter. Utilisez la commande de suppression d’un tag, ou sélectionnez-le et appuyez une fois sur Suppr, pour le retirer. **Sans tag** signifie que le tagging est terminé sans tags ; **Tagging en cours** indique qu’un résultat est attendu. Les corrections servent au tagging futur.

## Connaissances et recherche web

Les Connaissances stockent de courtes descriptions sur ce Mac pour le modèle local de tagging. Les **Sources de contenu** comprennent les créateurs, comptes, chaînes et communautés. Leurs descriptions accompagnent leur contenu. Les **Termes connus** s’appliquent lorsqu’un terme apparaît dans un titre.

Ajoutez une source ou un terme avec sa description, ou laissez la description vide pour demander une recherche lorsque celle-ci est activée. Les suggestions de créateurs aident à trouver une source collectée par le Classificateur. Les listes d’au moins six entrées ont une recherche juste au-dessus : les Termes et les Sources de contenu de chaque plateforme ont des recherches séparées par nom, identifiant ou description. Modifier une description affecte le tagging futur ; supprimer les connaissances d’une source n’empêche pas une recherche ultérieure de les recréer.

### Configurer un fournisseur de recherche

1. Ouvrez **Paramètres du Classificateur → Clés API et fournisseurs**.
2. Choisissez un type de fournisseur et **Ajouter un fournisseur**. Cela crée une configuration ; aucune clé API n’est délivrée.
3. Obtenez les identifiants auprès de ce fournisseur et saisissez-les. Pour un endpoint personnalisé compatible, configurez également son endpoint et les champs de protocole.
4. Dans **Recherche web**, choisissez un fournisseur avec recherche web intégrée. Récupérez sa liste de modèles et sélectionnez un modèle de recherche. Utilisez la recherche du sélecteur pour réduire la liste ; actualisez-la pour la récupérer à nouveau.
5. Lisez la déclaration de consentement et donnez votre consentement. Choisissez **Activé**, **Désactivé** ou **Suivre les paramètres du Classificateur** dans chaque groupe.

**Configurer la recherche web…** ouvre les paramètres si la configuration manque. Un groupe ne peut pas contourner le consentement à la recherche. **Tester la connexion** confirme la réussite de la requête de test, sans garantir que chaque modèle prend en charge la recherche. Le modèle de test du fournisseur est distinct du modèle de recherche sélectionné.

Les clés sont stockées dans le dossier de support de l’application sur ce Mac, pas dans le trousseau système. Elles authentifient les requêtes auprès du fournisseur configuré ; Vault ne les envoie pas à son propre serveur. La recherche envoie des sujets publics nettoyés au fournisseur choisi, pas le corps de contenus privés ni leurs résumés. Lisez la déclaration de consentement pour connaître les champs envoyés. L’utilisation du fournisseur comprend les tests de connexion et les requêtes de listes de modèles ainsi que la recherche.

L’état de la recherche affiche les requêtes en attente, les délais avant nouvelle tentative, les échecs et les tokens utilisés dans la journée. **Réessayer les sujets en échec maintenant** relance les échecs admissibles ; cela ne contourne pas l’allocation quotidienne ni le consentement.

## Activité

Activité enregistre localement l’utilisation des applications activée, les visites de sites et le **Contenu consulté** pris en charge. Ses graphiques reflètent les données enregistrées ; une zone vide ne prouve pas que le Mac était inactif.

Choisissez une période. **Chronologie** affiche l’utilisation selon l’heure ; **Totaux** additionne les durées. **Intervalle de temps** regroupe l’utilisation de chaque intervalle en blocs verticaux. **Couleurs** est une légende cliquable : sélectionnez une source pour centrer les graphiques sur elle. Sélectionnez un jour pour voir l’utilisation depuis ce jour.

### Groupes d’Activité

Créez un groupe pour afficher ensemble ses applications et sites sélectionnés dans Utilisation. **Fusionner** utilise un nom et une couleur pour ses membres dans toute l’Activité. Un groupe d’Activité organise l’utilisation enregistrée ; il est distinct d’un groupe de blocage ou du Classificateur. Enregistrez explicitement l’éditeur de groupe d’Activité avec **Enregistrer**.

### Enregistrement et conservation

Dans **Enregistrement**, activez ou désactivez l’enregistrement par catégorie ou par source. **Conserver** contrôle la durée de conservation de l’historique ; **Toujours** le garde sans expiration automatique. Les choix individuels peuvent suivre le réglage général. Désactiver l’enregistrement arrête les nouveaux enregistrements ; supprimer l’historique efface les entrées enregistrées.

Les fils de plateforme collectent le contenu affiché sur les pages prises en charge, qu’il soit ouvert ou non. Un fil marqué **Tagging pris en charge** peut alimenter le Classificateur tant que l’enregistrement est activé. Sa conservation contrôle le contenu collecté séparément de l’utilisation des applications et sites. Suspendre un groupe du Classificateur ne désactive pas l’enregistrement.

## Paramètres du Classificateur

**Mises à jour des paquets de tags** choisit quand les mises à jour vérifiées prennent effet : **Automatique**, **Demander d’abord** ou **Manuel**. Ce réglage est distinct du téléchargement du modèle local choisi dans un groupe. Les modèles sont téléchargés depuis Hugging Face lorsque vous choisissez **Télécharger** ; utilisez les commandes de progression, d’état et **Annuler** du groupe pendant le téléchargement.

Choisissez la langue de l’interface dans les Paramètres. Les petits boutons Info expliquent les champs dans la langue sélectionnée.

## Enregistrement et dépannage

Les modifications courantes de Vault et du Classificateur sont enregistrées automatiquement. Les groupes d’Activité utilisent **Enregistrer**. L’ajout, la suppression, le téléchargement d’un modèle, le test d’une connexion et la récupération d’une liste de modèles restent des actions explicites.

Si les tags manquent, vérifiez la connexion au navigateur, le commutateur global de tagging, la suspension du groupe, l’enregistrement de la plateforme et le téléchargement du modèle. Si la recherche ne fonctionne pas, vérifiez le consentement, le choix du groupe, les identifiants du fournisseur, le modèle et l’état de la recherche. Si un groupe lié ne peut pas être modifié, reconnectez ses programmes ou déverrouillez-le comme indiqué.
