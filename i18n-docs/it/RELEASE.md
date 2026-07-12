# Guida al rilascio di Mac Vault

Questa guida segue gli script di build archiviati. Non contiene intenzionalmente alcuna identità di firma personale, profilo di autenticazione, password o dati dell'account.

## Prima del rilascio

1. Eseguire `swift test` dalla radice del repository.
2. Impostare la versione di rilascio e il numero di build nella configurazione controllata di progetto/build.
3. Revisione del manuale in inglese, dei manuali localizzati e della verifica della traduzione dell'editor.
4. Verificare il ramo di rilascio, il tag e la policy dell'elemento cardine prima di pubblicare un artefatto.

## Gasdotto DMG del sito web

Gli script risiedono in `scripts/release/`. Le loro impostazioni predefinite possono essere sovrascritte con variabili di ambiente, tra cui `APP_NAME`, `BUNDLE_ID`, `TEAM_ID`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `VERSION` e `BUILD_NUMBER`.

Esegui la pipeline completa solo su una macchina per la firma configurata:

```bash
VERSION=<version> BUILD_NUMBER=<build> scripts/release/full_release_dmg.sh
```

La pipeline compone gli script esistenti di build, firma, DMG, autenticazione e verifica. Tratta il suo output come una candidata al rilascio finché il passaggio di verifica non ha esito positivo.

## Obiettivi di distribuzione Xcode

Genera il progetto Xcode da `XcodeProject/project.yml`, configura il team di firma e le funzionalità appropriati nell'ambiente approvato, quindi archivia la destinazione pertinente. Non impegnare credenziali generate, file di provisioning o profili di autenticazione.

## Dopo un rilascio

1. Creare il tag di versione immutabile e il ramo di rilascio permanente in base alla politica di gestione del rilascio.
2. Pubblicare l'artefatto di rilascio e il checksum.
3. Aggiorna il registro delle versioni pubbliche solo dopo che l'URL dell'elemento è definitivo.
4. Conservare le note di rilascio in inglese a meno che non venga fornita una nota di rilascio localizzata revisionata.
