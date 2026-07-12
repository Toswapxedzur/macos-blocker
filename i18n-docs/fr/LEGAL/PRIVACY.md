# Politique de confidentialité d'Adamancia Vault

Dernière mise à jour : 7 juillet 2026

Adamancia Vault est une application de concentration et de blocage. Cette politique décrit la version de l'application macOS.

## Résumé

Adamancia Vault est conçu pour conserver les règles de blocage et l'état d'utilisation locaux sur votre Mac par défaut. L'application ne vend pas de données personnelles, n'affiche pas de publicités et ne partage pas de données personnelles avec des courtiers en données.

## Données stockées localement

L'application peut stocker les données locales suivantes sur votre Mac :

- Blocage des groupes, des horaires, des minuteries, de l'état de gel/répétition et des paramètres de l'application.
- Stockage de l'éditeur Web local mis en miroir à partir de l'interface Web fournie.
- État du pont/lien local lorsque vous connectez l'application macOS aux extensions de navigateur.
- Fichiers de stratégie d'application des applications utilisés par le moteur de blocage macOS.
- Données de conteneur de groupe d'applications lorsqu'une build ou une extension de l'App Store utilise un groupe d'applications.

Les chemins locaux connus sont documentés dans `RELEASE.md` et dans le script de désinstallation.

## Utilisation du réseau

L'application peut ouvrir un écouteur de réseau local pour son pont d'application Web afin que les extensions de navigateur puissent se connecter à l'application Mac. L'application peut également effectuer des requêtes réseau si une fonctionnalité groupée doit communiquer avec les services Adamancia, par exemple un compte facultatif ou des fonctionnalités liées à la synchronisation.

## Analyses et annonces

L'application macOS n'inclut pas de SDK publicitaires tiers. Il ne doit pas envoyer d'analyses à moins qu'une fonctionnalité n'indique explicitement qu'elle utilise un service en ligne.

## Comptes facultatifs et synchronisation

Si les fonctionnalités de compte ou de synchronisation sont activées dans une version, ces fonctionnalités peuvent envoyer le minimum de données nécessaires pour fournir cette fonctionnalité, telles que l'identité du compte et les charges utiles de synchronisation. Les téléchargements et le blocage local ne doivent pas nécessiter de compte.

## Autorisations

En fonction du canal et des fonctionnalités activées, Adamancia Vault peut demander à macOS des autorisations telles que l'accessibilité, l'accès au réseau, l'enregistrement des éléments de connexion ou l'accès au groupe d'applications. Ces autorisations sont utilisées pour fournir des fonctionnalités de blocage, de lancement d'application, de pont et de persistance.

## Désinstallation

Le DMG inclut `uninstall.command`. Il demande une confirmation, quitte l'application si elle est en cours d'exécution, désenregistre l'élément de connexion de l'application lorsque cela est possible, supprime `/Applications/AdamanciaVault.app` et supprime éventuellement uniquement les fichiers connus créés par cette application.

## Contacter

Pour les questions de confidentialité, ouvrez un problème dans le référentiel public GitHub ou utilisez le canal de contact publié sur le site Web Adamancia Vault.
