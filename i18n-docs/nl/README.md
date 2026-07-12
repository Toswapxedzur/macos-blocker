# Mac-kluis

Mac Vault is het native macOS-lid van de Vault-productfamilie. Het combineert een Swift-beleidsengine, een WebView-editor, native applicatie-inventarisatie en handhavingsadapters, ondersteuning voor aangepaste regels en een lokale web-app-bridge-hub.

De huidige code is de bron van de waarheid. De Engelse in-app-referentie is [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md).

## Wat is geïmplementeerd

- Standaardgroepen voor geselecteerde macOS-applicaties en aangepaste groepen voor geavanceerde beleidsregels.
- Onmiddellijke, toegestane en aftellende blokkeermodi.
- Schema's, bevriezingsmodi, snooze-stromen, import/export en aanhoudende groepsstatus.
- Applicatie-inventarisatie, toestemmingsstatus voor apparaatbeheer, native handhavingsadapters en een zwevend statusoppervlak.
- Een gecontroleerde JavaScript-beleidsruntime met logboekregistratie en syntaxiscontrole.
- Een loopback WebSocket-bridgehub voor expliciet gekoppelde compatibele groepen.
- Een WebView-editor met hetzelfde kerngroepmodel als de Vault-productfamilie.

## Ontwikkeling

Voer de Swift-pakkettests uit:

```bash
swift test
```

Het pakket omvat kernbeleids-, plannings-, aangepaste regel-, bridge-, import- en macOS-controletests.

## Xcode-project

Het optionele Xcode-project wordt gegenereerd op basis van [XcodeProject/project.yml](XcodeProject/project.yml):

```bash
cd XcodeProject
./generate.sh
```

Lees [XcodeProject/README.md](XcodeProject/README.md) voordat u ondertekenings- of distributiedoelen configureert.

## Documentatiebeleid

Engelse documenten blijven canoniek. De gebruikersinterface van de editor beschikt over volledige locale catalogi, vertaalde handleidingen staan ​​live naast `WebAssets/manual/en.md`, en vertaalde kopieën van de resterende bijgehouden documenten staan ​​onder `i18n-docs/<locale>/`.

Juridische voorwaarden en privacyverklaringen blijven afzonderlijke juridische documenten; deze README vervangt ze niet.
