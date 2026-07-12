# Mac Vault-releasegids

Deze handleiding volgt de ingecheckte buildscripts. Het bevat opzettelijk geen persoonlijke ondertekeningsidentiteit, notariële profiel, wachtwoord of accountgegevens.

## Vóór een release

1. Voer `swift test` uit vanuit de hoofdmap van de repository.
2. Stel de releaseversie en het buildnummer in de gecontroleerde project-/buildconfiguratie in.
3. Bekijk de Engelse handleiding, gelokaliseerde handleidingen en de vertalingsaudit van de redacteur.
4. Controleer het releasebranch-, tag- en mijlpaalbeleid voordat u een artefact publiceert.

## Website DMG-pijplijn

De scripts staan in `scripts/release/`. Hun standaardwaarden kunnen worden overschreven door omgevingsvariabelen, waaronder `APP_NAME`, `BUNDLE_ID`, `TEAM_ID`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `VERSION` en `BUILD_NUMBER`.

Voer de volledige pijplijn alleen uit op een geconfigureerde ondertekeningsmachine:

```bash
VERSION=<version> BUILD_NUMBER=<build> scripts/release/full_release_dmg.sh
```

De pijplijn bevat de bestaande build-, ondertekenings-, DMG-, notarisatie- en verificatiescripts. Behandel de uitvoer ervan als een release candidate totdat de verificatiestap slaagt.

## Xcode-distributiedoelen

Genereer het Xcode-project vanuit `XcodeProject/project.yml`, configureer het juiste ondertekeningsteam en de juiste mogelijkheden in de goedgekeurde omgeving en archiveer vervolgens het relevante doel. Leg geen gegenereerde inloggegevens, inrichtingsbestanden of notariële profielen vast.

## Na een vrijlating

1. Maak de onveranderlijke versietag en permanente release-vertakking volgens het releasebeheerbeleid.
2. Publiceer het release-artefact en de controlesom.
3. Werk het openbare releaseregister pas bij nadat de artefact-URL definitief is.
4. Houd de release-opmerkingen in het Engels, tenzij er een beoordeelde, gelokaliseerde release-opmerking wordt meegeleverd.
