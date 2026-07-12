# Informativa sulla privacy di Adamancia Vault

Ultimo aggiornamento: 7 luglio 2026

Adamancia Vault è un'app di concentrazione e blocco. Questa policy descrive la versione dell'app macOS.

## Riepilogo

Adamancia Vault è progettato per mantenere le regole di blocco e lo stato di utilizzo locali sul tuo Mac per impostazione predefinita. L'app non vende dati personali, non visualizza annunci pubblicitari e non condivide dati personali con intermediari di dati.

## Dati archiviati localmente

L'app potrebbe archiviare i seguenti dati locali sul tuo Mac:

- Blocco di gruppi, pianificazioni, timer, stato di blocco/posticipazione e impostazioni dell'app.
- Archiviazione dell'editor web locale con mirroring dall'interfaccia web in bundle.
- Stato del bridge/collegamento locale quando colleghi l'app macOS alle estensioni del browser.
- File dei criteri di applicazione delle app utilizzati dal motore di blocco di macOS.
- Dati contenitore del gruppo di app quando una build dell'App Store o una build di estensione utilizza un gruppo di app.

I percorsi locali noti sono documentati in `RELEASE.md` e nello script di disinstallazione.

## Utilizzo della rete

L'app può aprire un ascoltatore di rete locale per il suo bridge di app Web in modo che le estensioni del browser possano connettersi all'app Mac. L'app può anche effettuare richieste di rete se una funzionalità in bundle deve comunicare con i servizi Adamancia, ad esempio funzionalità relative all'account o alla sincronizzazione opzionali.

## Analisi e annunci

L'app macOS non include SDK pubblicitari di terze parti. Non dovrebbe inviare analisi a meno che una funzionalità non indichi esplicitamente che sta utilizzando un servizio online.

## Account e sincronizzazione opzionali

Se le funzionalità di account o di sincronizzazione sono abilitate in una versione, tali funzionalità potrebbero inviare i dati minimi necessari per fornire tale funzionalità, come l'identità dell'account e i payload di sincronizzazione. I download e il blocco locale non devono richiedere un account.

## Autorizzazioni

A seconda del canale e delle funzionalità abilitate, Adamancia Vault potrebbe richiedere a macOS autorizzazioni quali Accessibilità, accesso alla rete, registrazione di elementi di accesso o accesso al gruppo di app. Queste autorizzazioni vengono utilizzate per fornire funzionalità di blocco, avvio di app, bridge e persistenza.

## Disinstallazione

Il DMG include `uninstall.command`. Chiede conferma, chiude l'app se in esecuzione, annulla la registrazione dell'elemento di accesso dell'app quando possibile, rimuove `/Applications/AdamanciaVault.app` e facoltativamente rimuove solo i file conosciuti creati da questa app.

##Contatto

Per domande sulla privacy, apri un problema nel repository GitHub pubblico o utilizza il canale di contatto pubblicato sul sito Web Adamancia Vault.
