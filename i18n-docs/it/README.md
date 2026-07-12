#Mac Vault

Mac Vault è il membro macOS nativo della famiglia di prodotti Vault. Combina un motore di policy Swift, un editor WebView, inventario di applicazioni native e adattatori di applicazione, supporto per regole personalizzate e un hub bridge di app Web locale.

Il codice attuale è la fonte della verità. Il riferimento in-app in inglese è [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md).

## Cosa viene implementato

- Gruppi predefiniti per applicazioni macOS selezionate e gruppi personalizzati per regole di policy avanzate.
- Modalità di blocco immediato, indennità e conto alla rovescia.
- Pianificazioni, modalità di blocco, posticipazione dei flussi, importazione/esportazione e stato del gruppo persistente.
- Inventario delle applicazioni, stato delle autorizzazioni di controllo del dispositivo, adattatori di applicazione nativi e una superficie di stato mobile.
- Un runtime di policy JavaScript controllato con registrazione e controllo della sintassi.
- Un hub bridge WebSocket di loopback per gruppi compatibili esplicitamente collegati.
- Un editor WebView con lo stesso modello di gruppo principale della famiglia di prodotti Vault.

## Sviluppo

Esegui i test del pacchetto Swift:

```bash
swift test
```

Il pacchetto include test di policy di base, pianificazione, regole personalizzate, bridge, importazione e controllo macOS.

## Progetto Xcode

Il progetto Xcode opzionale viene generato da [XcodeProject/project.yml](XcodeProject/project.yml):

```bash
cd XcodeProject
./generate.sh
```

Leggi [XcodeProject/README.md](XcodeProject/README.md) prima di configurare le destinazioni di firma o distribuzione.

## Politica di documentazione

I documenti inglesi rimangono canonici. L'interfaccia utente dell'editor dispone di cataloghi locali completi, manuali tradotti disponibili accanto a `WebAssets/manual/en.md` e copie tradotte dei restanti documenti gestiti si trovano in `i18n-docs/<locale>/`.

I termini legali e le informative sulla privacy rimangono documenti legali separati; questo README non li sostituisce.
