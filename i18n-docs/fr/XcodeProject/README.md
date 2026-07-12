# Projet Mac Vault Xcode

`project.yml` est la spécification XcodeGen enregistrée pour les cibles macOS et iOS qui utilisent le package Swift partagé.

## Générer le projet

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

Régénérez après avoir modifié `project.yml`, les cibles, les droits ou l'appartenance à la source. N'utilisez pas les fichiers de projet générés comme configuration canonique.

## Familles cibles actuelles

- `AdamanciaVaultMac` est la cible de l'application macOS soutenue par `MacBlockerAppFeature`.
- `macosBlocker` est la cible de l'application iOS.
- Le projet iOS comprend les extensions Device Activity, Shield Configuration et Shield Action.

Les identifiants actuels, les cibles de déploiement, les champs de version et les fonctionnalités sont définis dans `project.yml` et les fichiers de droits référencés. Examinez-les dans l’environnement de signature avant la distribution.

## Signature et capacités

Utilisez une équipe et regroupez les identifiants appartenant au compte de distribution. Confirmez les capacités requises par la cible que vous construisez. N'ajoutez jamais de secrets de signature, de profils de provisionnement ou d'informations d'identification de compte à ce référentiel.

## Testez d'abord

Exécutez les tests du package partagé avant de créer une archive :

```bash
cd ..
swift test
```
