# Manuale utente di Mac Vault

Mac Vault ha tre pagine: **Vault** blocca le app native, **Content tagging** assegna tag ai contenuti browser supportati e **Activity** mostra l’uso registrato. L’estensione browser raccoglie i contenuti supportati e applica il blocco nel browser. Installala e collegala al browser usato.

## Avvio rapido

1. In **Vault**, aggiungi un blocking group e un target Apps, poi seleziona le app con il selettore +.
2. Scegli il comportamento di blocco e attiva il gruppo.
3. In **Content tagging**, crea un gruppo, scegli le piattaforme e aggiungi tag con descrizioni.
4. In Settings → **AI connections**, scegli ChatGPT subscription, OpenAI API, Gemini API o Grok API. Collega l’account o inserisci la chiave e recupera i modelli; poi scegli connessione/modello nel gruppo. Attiva il tagging e riprendi il gruppo.
5. Apri contenuti supportati nel browser collegato. Configura un filtro tag in un browser blocking group se vuoi che i tag controllino il blocco.

## Gruppi di blocco

Un **blocking group** applica una politica di blocco. Un gruppo **Content tagging** assegna tag ai contenuti e non blocca da solo. Aggiungi e nomina il gruppo, scegli i target in **Applies to**, stabilisci quando applicare il blocco e imposta calendario o disponibilità di tempo, poi abilitalo. Le modifiche ordinarie si salvano automaticamente. Un errore indica che la modifica non è stata accettata: correggi il campo e riprova. Disattivare il gruppo ferma la politica ma conserva la configurazione; **Delete group** lo elimina. Trascina i gruppi per riordinarli. Più gruppi possono interessare lo stesso target; lo snooze di uno non rimuove il blocco di un altro. **Export** copia la configurazione; **Import** sostituisce quella del gruppo scelto dopo conferma.

### Disponibilità di tempo e calendario

**Block immediately** si applica quando il gruppo attivo corrisponde e il calendario è attivo. **Block when the time allowance is used** consente l’uso finché la disponibilità non termina. Imposta i minuti e l’intervallo di reset in ore. Un limite mobile conta l’uso nella finestra precedente. Il reset a mezzanotte avvia un nuovo periodo alla mezzanotte locale, anche per un limite mobile. Scegli i giorni attivi e finestre facoltative di ora locale, una per riga, come **09:00-12:00**. Una lista vuota vale per tutti i giorni scelti. La finestra deve terminare dopo l’inizio nello stesso giorno; dividi un orario notturno su più giorni.

### Snooze

Configura lo snooze in ogni blocking group. **Pause blocking** sospende la politica per la durata impostata. **Add to the time allowance** aggiunge minuti utilizzabili a un gruppo a tempo. Solo la quota extra consumata conta come snoozed time. Quella inutilizzata scade al reset successivo; per un limite mobile dopo una finestra, o prima a mezzanotte se abilitato. **Activation delay** rinvia lo snooze mentre il blocco continua. **Cooldown** è l’attesa dopo la fine dello snooze prima di una nuova richiesta. **Required confirmations** stabilisce i passaggi di conferma. Lo snooze è disponibile su un gruppo frozen solo se autorizzato prima del freeze.

### Freeze e PIN

**Freeze** impedisce le modifiche ordinarie. Per unfreeze servono dieci conferme a cinque secondi di distanza, l’eventuale attesa configurata e un PIN di sei cifre. **Wait before unfreezing** accetta 0–72 ore; 0 non aggiunge attesa. Durante il freeze si può prolungare l’attesa e aggiungere un PIN se assente, ma non indebolire i vincoli finché il gruppo non è scongelato. Anche l’eliminazione rispetta attesa residua e PIN.

### Gruppi collegati

Usa **Link** per collegare gruppi selezionati esplicitamente in altri programmi Vault. Condividono nome, impostazioni supportate, target, uso e condizioni di freeze. Ogni programma modifica e applica i tipi di target supportati; gli altri restano disponibili ai programmi collegati. **Unlink** separa i gruppi mantenendoli con le impostazioni. Se un membro è offline, apri Mac Vault e il browser collegato per riconnetterli. Una politica salvata localmente può continuare ad applicarsi offline.

## Assistenza

Fai clic sulla piccola **i** accanto a un campo per la spiegazione; fai clic fuori o premi Escape per chiuderla. Le liste sono in riquadri scorrevoli; la ricerca filtra gli elementi visibili senza eliminarli. Il [Manuale del codice](../code-manual/it.md) per le regole personalizzate spiega editor, attivazione, log, file e API.

## App native

Usa il selettore + di Apps per scegliere app installate o in esecuzione; riaprilo per aggiornare la lista dopo aver avviato un’app da un’altra cartella. **Block every app except these** trasforma la lista in allowlist. Mac Vault può bloccare normali app Apple e browser interi; Mac Vault e ogni app con lo stesso bundle identifier restano protetti. A un’app bloccata viene chiesto di uscire; **Ask a blocked app to quit again every (minutes)** controlla i tentativi. Reindirizzamenti web, pause di pagina e occultamento feed sono compiti dell’estensione, non azioni native.

## Content tagging

Il gruppo assegna tag ai contenuti delle piattaforme associate con il proprio albero tag e le impostazioni del modello. Ogni piattaforma appartiene a un gruppo; sceglila alla creazione, non si può cambiare dopo. Calendari e filtri di blocco non controllano il tagging. Attivalo in Settings e usa **Pause tagging / Resume tagging** separatamente per ogni gruppo. Disattivare la registrazione del feed in **Activity → Recording** ferma anche il suo tagging.

### Tag e impostazioni del modello

Crea tag, descrivine il significato e imposta o rimuovi i genitori nell’albero; trascinare sposta il ramo. Descrizioni chiare aiutano il modello a distinguere tag simili. Le impostazioni di ogni gruppo sono indipendenti. **Minimum confidence** imposta il grado di prova richiesto per ogni tag previsto da 1 a 5; i nuovi gruppi iniziano a 4 (supporto forte). Non c’è un numero obiettivo; un elemento può non ricevere tag. **Tagging instructions** conserva le preferenze del gruppo. Le modifiche ordinarie si salvano automaticamente; ogni gruppo usa una connessione, un modello e un reasoning effort selezionati esplicitamente.

### Connessioni IA

Settings offre ChatGPT subscription, OpenAI API, Gemini API e Grok API. L’abbonamento usa l’accesso Vault e un piano idoneo. Le chiavi API seguono fatturazione e limiti del provider selezionato. Scegli il provider e inserisci la chiave sotto il menu condiviso; le modifiche si salvano automaticamente e svuotare il campo elimina la chiave. **Fetch model list** recupera i modelli, ma non ne sceglie uno: selezionalo nel gruppo Content tagging o custom-rule.

**Reasoning effort** regola quanto pensa il modello: Model default, Low, Medium o High se supportati. Le nuove scelte iniziano a Medium; quelle esistenti restano salvate. Un livello maggiore può aumentare tempo e token. La ricerca Web è sempre attiva per il tagging; il modello decide quando usarla. Scegli un modello che supporti ricerca e tagging strutturato. Le richieste fallite o non disponibili mantengono risultati validi in cache; i nuovi elementi restano irrisolti finché non scegli **Retry cloud classification**. Vault non cambia provider automaticamente; ogni connessione ha intervallo di retry e limite di tentativi propri. Correggi i tag nell’estensione: **+ tag**, ricerca e scelta per aggiungere; controllo di rimozione o Delete una volta per eliminare. **Untagged** significa tagging completato senza tag; **Tagging** indica risultato in attesa. La correzione è autorevole per quell’elemento.

## Activity

Activity registra localmente uso delle app abilitate, visite ai siti e **Content viewed** supportato. I grafici riflettono i dati registrati; uno spazio vuoto non prova che il Mac fosse inattivo. Scegli un intervallo di date. **Timeline** mostra l’ora del giorno, **Totals** somma le durate e **Time interval** raggruppa l’uso di ciascun intervallo in blocchi verticali. **Colors** è una legenda cliccabile; seleziona una fonte per focalizzare i grafici. Scegli un giorno per vedere l’uso da quel giorno.

### Gruppi Activity

Crea un gruppo per mostrare insieme in Usage app e siti scelti. **Merge** usa un solo nome e colore per i membri in Activity. Il gruppo organizza l’uso registrato ed è distinto dai gruppi di blocco e Content tagging. Salva esplicitamente l’editor con **Save**.

### Registrazione e conservazione

In **Recording**, attiva o disattiva la registrazione per categoria o singola fonte. **Keep** determina per quanto conservare la cronologia; **Forever** non prevede scadenza automatica. Le scelte individuali possono seguire l’impostazione più ampia. Disattivare la registrazione ferma i nuovi dati; eliminare la cronologia rimuove le voci registrate. I feed raccolgono contenuti mostrati nelle pagine supportate, aperte o meno. Un feed **Tagging supported** può fornire dati a Content tagging mentre la registrazione è attiva. La sua conservazione è separata dall’uso di app e siti. Mettere in pausa il gruppo di tagging non arresta la registrazione.

## Settings

Scegli la lingua dell’interfaccia in Settings. I pulsanti Info mostrano le spiegazioni dei campi nella lingua selezionata.

## Salvataggio e risoluzione dei problemi

Le modifiche ordinarie a Vault e Content tagging si salvano automaticamente; l’editor Activity richiede **Save**. Aggiunta, eliminazione, test di connessione e recupero dei modelli sono azioni esplicite. Se mancano tag, controlla connessione browser, interruttore globale, pausa del gruppo, registrazione della piattaforma, connessione/modello scelti e credenziali. Per richieste IA fallite controlla anche limiti del provider e Log del gruppo. Se un gruppo collegato non è modificabile, riconnetti i programmi o scongelalo come indicato.
