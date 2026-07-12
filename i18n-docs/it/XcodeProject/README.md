# Progetto Xcode per Mac Vault

`project.yml` è la specifica XcodeGen archiviata per le destinazioni macOS e iOS che utilizzano il pacchetto Swift condiviso.

## Genera il progetto

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

Rigenera dopo aver modificato `project.yml`, destinazioni, diritti o appartenenza all'origine. Non utilizzare i file di progetto generati come configurazione canonica.

## Attuali famiglie target

- `AdamanciaVaultMac` è la destinazione dell'applicazione macOS supportata da `MacBlockerAppFeature`.
- `macosBlocker` è la destinazione dell'applicazione iOS.
- Il progetto iOS include le estensioni Attività dispositivo, Configurazione scudo e Azione scudo.

Gli identificatori correnti, gli obiettivi di distribuzione, i campi della versione e le funzionalità sono definiti in `project.yml` e nei file di autorizzazione a cui si fa riferimento. Esaminarli nell'ambiente di firma prima della distribuzione.

## Firma e capacità

Utilizza identificatori di team e bundle che appartengono all'account di distribuzione. Conferma le capacità richieste dal target che stai costruendo. Non aggiungere mai segreti di firma, profili di provisioning o credenziali di account a questo repository.

## Prova prima

Esegui i test del pacchetto condiviso prima di creare un archivio:

```bash
cd ..
swift test
```
