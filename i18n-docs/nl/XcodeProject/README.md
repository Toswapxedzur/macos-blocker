# Mac Vault Xcode-project

`project.yml` is de ingecheckte XcodeGen-specificatie voor de macOS- en iOS-doelen die het gedeelde Swift-pakket gebruiken.

## Genereer het project

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

Genereer opnieuw na het wijzigen van `project.yml`, doelen, rechten of bronlidmaatschap. Gebruik geen gegenereerde projectbestanden als de canonieke configuratie.

## Huidige doelfamilies

- `AdamanciaVaultMac` is het macOS-toepassingsdoel ondersteund door `MacBlockerAppFeature`.
- `macosBlocker` is het doel van de iOS-applicatie.
- Het iOS-project omvat de uitbreidingen Apparaatactiviteit, Shield-configuratie en Shield Action.

De huidige ID's, implementatiedoelen, versievelden en mogelijkheden worden gedefinieerd in `project.yml` en de rechtenbestanden waarnaar wordt verwezen. Controleer ze in de ondertekenomgeving voordat u ze distribueert.

## Ondertekening en mogelijkheden

Gebruik een team- en bundel-ID die bij het distributieaccount horen. Bevestig de capaciteiten die vereist zijn voor het doel dat u aan het bouwen bent. Voeg nooit ondertekeningsgeheimen, inrichtingsprofielen of accountreferenties toe aan deze opslagplaats.

## Eerst testen

Voer de gedeelde pakkettests uit voordat u een archief maakt:

```bash
cd ..
swift test
```
