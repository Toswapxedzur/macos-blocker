# Guide de publication de Mac Vault

Ce guide suit les scripts de build archivés. Il ne contient intentionnellement aucune identité de signature personnelle, profil de notarisation, mot de passe ou données de compte.

## Avant une sortie

1. Exécutez `swift test` à partir de la racine du référentiel.
2. Définissez la version et le numéro de build dans la configuration de projet/build contrôlé.
3. Consultez le manuel en anglais, les manuels localisés et l'audit de traduction de l'éditeur.
4. Vérifiez la stratégie de branche de publication, de balise et de jalon avant de publier un artefact.

## Pipeline DMG du site Web

Les scripts résident dans `scripts/release/`. Leurs valeurs par défaut peuvent être remplacées par des variables d'environnement, notamment `APP_NAME`, `BUNDLE_ID`, `TEAM_ID`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `VERSION` et `BUILD_NUMBER`.

Exécutez le pipeline complet uniquement sur une machine de signature configurée :

```bash
VERSION=<version> BUILD_NUMBER=<build> scripts/release/full_release_dmg.sh
```

Le pipeline compose les scripts de construction, de signature, de DMG, de notarisation et de vérification existants. Traitez sa sortie comme une version candidate jusqu'à ce que l'étape de vérification réussisse.

## Cibles de distribution Xcode

Générez le projet Xcode à partir de `XcodeProject/project.yml`, configurez l'équipe de signature et les fonctionnalités appropriées dans l'environnement approuvé, puis archivez la cible appropriée. Ne validez pas les informations d’identification générées, les fichiers de provisionnement ou les profils de notarisation.

## Après une sortie

1. Créez la balise de version immuable et la branche de version permanente conformément à la politique de gestion des versions.
2. Publiez l'artefact de version et la somme de contrôle.
3. Mettez à jour le registre des versions publiques uniquement une fois que l'URL de l'artefact est définitive.
4. Conservez les notes de version en anglais, à moins qu'une note de version localisée révisée ne soit fournie.
