# Manuale utente Mac Vault

Mac Vault ha tre pagine: **Vault** blocca le app native, **Classifier** applica tag ai contenuti browser supportati e **Activity** mostra l'uso registrato. L'estensione browser raccoglie i contenuti supportati e applica i blocchi nel browser. Installala e connettila nel browser che usi.

## Avvio rapido

1. In **Vault**, aggiungi un gruppo di blocco e un obiettivo Apps, poi seleziona le app con il selettore +.
2. Scegli il comportamento di blocco del gruppo e attivalo.
3. In **Classifier**, crea un gruppo, scegli le piattaforme e aggiungi tag con descrizioni.
4. Scegli un livello di modello locale e scaricalo se necessario. Attiva l'applicazione dei tag nelle impostazioni di Classifier e riprendi il gruppo.
5. Apri contenuti supportati nel browser collegato. Configura un filtro tag nel gruppo di blocco del browser se vuoi che i tag controllino il blocco.

## Gruppi di blocco

Un **gruppo di blocco** applica una policy di blocco. Un **gruppo Classifier** assegna tag ai contenuti; da solo non blocca nulla.

1. Aggiungi un gruppo di blocco e assegnagli un nome.
2. Scegli gli obiettivi in **Si applica a**.
3. Scegli quando applicare il blocco, poi imposta un programma o un tempo consentito, se necessario.
4. Attiva il gruppo. I suoi obiettivi condividono la policy del gruppo.

Le modifiche ordinarie si salvano automaticamente. Un errore indica che la modifica non è stata accettata; correggi il campo e riprova. Disattiva un gruppo per sospenderne la policy mantenendo la configurazione. **Elimina gruppo** lo rimuove. Trascina i gruppi per riordinarli. Più gruppi possono applicarsi allo stesso obiettivo; posticiparne uno non rimuove il blocco di un altro.

**Esporta** copia la configurazione di un gruppo. **Importa** sostituisce la configurazione del gruppo selezionato dopo la conferma.

### Tempo consentito e programma

**Blocca subito** si applica quando il gruppo attivo corrisponde e il programma è in corso. **Blocca quando si esaurisce il tempo consentito** permette l'uso corrispondente finché il tempo consentito non termina.

Imposta il tempo consentito in minuti e l'intervallo di ripristino in ore. Un limite mobile conteggia l'uso nella finestra temporale precedente. Il ripristino a mezzanotte avvia un nuovo periodo alla mezzanotte locale, anche per un limite mobile.

Scegli i giorni attivi della settimana e gli intervalli di ora locale facoltativi, uno per riga, ad esempio **09:00-12:00**. Senza intervalli, il gruppo si applica per tutti i giorni selezionati. Un intervallo deve terminare più tardi rispetto all'inizio nello stesso giorno; dividi un programma notturno su giorni diversi.

### Posticipa

Configura il posticipo in ogni gruppo di blocco. **Sospendi il blocco** sospende la policy del gruppo per la durata impostata. **Aggiungi al tempo consentito** aggiunge minuti utilizzabili a un gruppo con limite temporale. Solo il tempo aggiuntivo consumato viene conteggiato come posticipo. Il tempo aggiuntivo non utilizzato scade al ripristino successivo; per un limite mobile scade dopo una finestra, o prima a mezzanotte se l'opzione è attiva.

**Ritardo di attivazione** posticipa il rinvio mentre il blocco continua. **Intervallo di attesa** indica quanto attendere dalla fine del posticipo prima di richiederlo di nuovo. **Conferme richieste** imposta il numero di passaggi di conferma. Il posticipo è disponibile per un gruppo congelato solo se consentito prima del congelamento.

### Congelamento e PIN

**Congela** impedisce le modifiche ordinarie. Per scongelare servono dieci conferme a distanza di cinque secondi, oltre all'eventuale attesa configurata e a un PIN di sei cifre. **Attendi prima di scongelare** accetta 0–72 ore; 0 non aggiunge attesa.

Mentre il gruppo è congelato, l'attesa può essere prolungata e si può aggiungere un PIN se non è già presente. Queste condizioni non possono essere allentate finché il gruppo non viene scongelato. Anche l'eliminazione rispetta l'attesa restante e il PIN.

### Gruppi collegati

Usa **Collega** per connettere gruppi selezionati esplicitamente in altri programmi Vault. I gruppi collegati condividono nome, impostazioni di policy supportate, obiettivi, utilizzo e condizioni di congelamento. Ogni programma modifica e applica i tipi di obiettivo supportati; le altre voci restano disponibili ai programmi collegati. Scollegare mantiene ciascun gruppo e le sue impostazioni.

Se un membro collegato è offline, potrebbe non essere possibile modificarlo. Apri Mac Vault e il browser collegato per riconnetterti. Una policy salvata localmente può continuare ad applicarsi quando il membro è offline.

## Assistenza

Fai clic sulla piccola **i** accanto a un campo per leggerne la spiegazione. Fai clic all'esterno o premi Escape per chiuderla. Gli elenchi restano in riquadri scorrevoli; scorri il riquadro per visualizzare altre voci. La ricerca filtra l'elenco visibile senza eliminare voci.

Le regole personalizzate hanno un [Manuale del codice](../code-manual/it.md) dedicato, che spiega l'editor, l'attivazione, i log, l'accesso ai file e l'API supportata.

## App native

Usa il selettore + di un obiettivo Apps per scegliere le app installate. **Blocca tutte le app tranne queste** trasforma l'elenco in una lista consentita. App di sistema, browser e Vault stesso sono esclusi dal blocco delle app native.

A un'app bloccata viene richiesto di chiudersi. **Richiedi nuovamente la chiusura dell'app bloccata ogni (minuti)** controlla i tentativi. Reindirizzamenti dei siti, pause delle pagine e occultamento dei feed sono applicati dall'estensione browser; non diventano azioni dell'app nativa.

## Classifier

Un gruppo Classifier applica tag ai contenuti delle piattaforme assegnate usando il proprio albero di tag e le impostazioni del modello. Ogni piattaforma appartiene a un solo gruppo. Scegli le piattaforme durante la creazione; non potrai cambiarle in seguito. Programmi e filtri dei gruppi di blocco non controllano l'applicazione dei tag.

Attiva l'applicazione dei tag nelle impostazioni Classifier. Usa **Sospendi tag / Riprendi tag** separatamente per ciascun gruppo. Disattivare la registrazione del feed di una piattaforma in **Activity → Registrazione** ne interrompe anche l'applicazione dei tag.

### Tag e impostazioni del modello

Crea tag, descrivine i significati e imposta o rimuovi i relativi tag principali nell'albero. Trascina un tag per spostare il ramo. Descrizioni chiare aiutano il modello a distinguere tag simili. Le impostazioni di ogni gruppo sono indipendenti.

- **Velocità ↔ Qualità** seleziona un livello di modello locale. I modelli più grandi usano più memoria; velocità e risultati dipendono dal Mac e dal carico di lavoro. I download sono condivisi tra gruppi.
- **Rigoroso ↔ Ampio** imposta il livello di affidabilità richiesto e il numero predefinito di tag.
- **Tag minimi / Tag massimi** in Altro sostituisce quei numeri predefiniti. Rigoroso ↔ Ampio continua a controllare l'affidabilità dei tag aggiuntivi. Lascia vuoto un campo per usare il relativo valore predefinito.
- **Istruzioni per i tag** aggiunge istruzioni facoltative per questo gruppo.

Le modifiche ordinarie di Classifier si salvano automaticamente. Il livello selezionato deve essere scaricato prima di poter applicare tag. I gruppi che usano lo stesso livello condividono il modello caricato; possono restare caricati fino a due livelli contemporaneamente.

Correggi i tag di un contenuto nell'estensione browser. Fai clic su **+ tag**, cerca i tag esistenti di Classifier e scegline uno da aggiungere. Usa il comando di rimozione del tag oppure selezionalo e premi Delete una volta. **Senza tag** significa che l'applicazione dei tag è terminata senza tag; **Tagging in corso** indica un risultato in attesa. Le correzioni migliorano le assegnazioni future.

## Knowledge e ricerca web

Knowledge memorizza brevi descrizioni su questo Mac per il modello di tagging locale. **Fonti dei contenuti** include creator, account, canali e community. Le descrizioni della fonte accompagnano i suoi contenuti. **Termini noti** si applica quando un termine appare in un titolo.

Aggiungi una fonte o un termine con la relativa descrizione, oppure lasciala vuota per richiedere una ricerca quando attiva. I suggerimenti per i creator aiutano a trovare una fonte già raccolta da Classifier. Gli elenchi con almeno sei voci hanno una ricerca subito sopra: Terms e le Content sources di ciascuna piattaforma hanno ricerche separate per nome, identificatore o descrizione. Modificare una descrizione influisce sui tag futuri; eliminare la conoscenza di una fonte non impedisce alla ricerca di ricrearla.

### Dizionari ufficiali e personali

Apri **Impostazioni → Classificatore → Dizionari ufficiali** per configurare i dizionari ufficiali. **Conoscenze** mostra le versioni installate e un collegamento rapido a questi controlli. Vault verifica gli aggiornamenti all’avvio; usa **Controlla gli aggiornamenti** e i pulsanti di download per installarli. Non serve una tua chiave API IA.

- **Termini** viene scaricato per la ricerca locale.
- **Cache + ricerca online** conserva fino a 10.000 voci di creator per impostazione predefinita; puoi cambiare il limite. Se un creator non è nella cache, il suo ID pubblico associato alla piattaforma viene inviato al servizio dei dizionari.
- **Download completo · ricerca offline** cerca i creator localmente dopo il download. Scegli questa modalità e scarica il dizionario.

Le tue descrizioni personali, incluse quelle del provider di ricerca, hanno la precedenza su quelle ufficiali. In **Importa / esporta il tuo dizionario** puoi esportare le voci personali o importare un file JSON; le voci ufficiali non sono incluse nell’esportazione personale.

**Aiuta a migliorare il dizionario dei creator** è attivo per impostazione predefinita e viene spiegato prima del primo contributo. Disattivalo qui per interrompere quelli futuri e annullare le richieste in sospeso. Se attivo, Vault invia solo un campione di ID pubblici di creator mancanti e i conteggi pubblici disponibili di follower/iscritti; non invia titoli, cronologia di navigazione o descrizioni personali. Consulta l’informativa per limiti e conservazione. La ricerca sul Web ha consenso e impostazioni del provider separati.

### Configura un provider di ricerca

1. Apri **Impostazioni Classifier → API keys & providers**.
2. Scegli un tipo di provider e **Aggiungi provider**. Crea una configurazione, non emette una API key.
3. Ottieni le credenziali dal provider e inseriscile. Per un endpoint personalizzato compatibile, configura anche endpoint e protocollo.
4. In **Ricerca web**, scegli un provider con web search integrata. Recupera l'elenco dei modelli e seleziona un modello di ricerca. Usa la ricerca del selettore per filtrare l'elenco; aggiornalo per scaricarlo di nuovo.
5. Leggi l'informativa sul consenso e attivalo. In ciascun gruppo scegli **Attivo**, **Disattivo** o **Segui impostazioni Classifier**.

**Configura ricerca web…** apre le impostazioni se la configurazione manca. Un gruppo non può ignorare il consenso alla ricerca. **Verifica connessione** conferma che la richiesta di prova è riuscita, non che ogni modello supporti la ricerca. Il modello di prova di un provider è distinto dal modello di ricerca selezionato.

Le keys sono archiviate nella cartella support dell'app su questo Mac, non nel system Keychain. Autenticano le richieste al provider configurato; Vault non le carica sul proprio server. La ricerca invia al provider selezionato argomenti pubblici ripuliti, non corpi o riepiloghi di contenuti privati. Leggi l'informativa sul consenso per sapere quali fields vengono inviati. L'uso del provider include verifiche di connessione e richieste di elenchi modelli oltre alla ricerca.

Lo stato della ricerca mostra richieste in coda, intervalli di attesa prima dei nuovi tentativi, errori e uso giornaliero dei token. **Riprova ora i soggetti non riusciti** ritenta gli errori idonei; non ignora il limite giornaliero né il consenso.

## Activity

Activity registra localmente l'uso delle app attivate, le visite ai siti e i **Contenuti visualizzati** supportati. I grafici mostrano i dati registrati; un'area vuota non dimostra che il Mac fosse inattivo.

Scegli un intervallo di date. **Sequenza temporale** mostra l'uso nell'ora del giorno; **Totali** somma le durate. **Intervallo di tempo** riunisce l'uso di ciascun intervallo in barre verticali. **Colori** è una legenda selezionabile: scegli una fonte per mettere a fuoco i grafici. Seleziona un giorno per visualizzare l'uso da quel giorno.

### Gruppi Activity

Crea un gruppo per mostrare insieme in Usage le app e i siti selezionati. **Unisci** usa un unico nome e colore per i membri in tutta Activity. Un gruppo Activity organizza l'uso registrato; è distinto da un gruppo di blocco o Classifier. Salva esplicitamente l'editor del gruppo Activity con **Salva**.

### Registrazione e conservazione

In **Registrazione**, attiva o disattiva la registrazione per categoria o singola fonte. **Conserva** controlla per quanto tempo vengono mantenuti i dati storici; **Per sempre** li conserva senza scadenza automatica. Le scelte individuali possono seguire l'impostazione generale. Disattivare la registrazione ferma i nuovi dati; eliminare la cronologia rimuove le voci registrate.

I feed delle piattaforme raccolgono i contenuti mostrati nelle pagine supportate, aperte o meno. Un feed con **Tagging supportato** può fornire dati a Classifier quando la registrazione è attiva. La sua conservazione controlla i contenuti raccolti separatamente dall'uso di app e siti. Sospendere un gruppo Classifier non disattiva la registrazione.

## Impostazioni

Scegli la lingua dell'interfaccia in Settings. Le spiegazioni dei campi sono disponibili tramite i piccoli pulsanti Info nella lingua selezionata.

## Salvataggio e risoluzione dei problemi

Le modifiche ordinarie di Vault e Classifier si salvano automaticamente. Modificare un gruppo Activity richiede **Salva**. Aggiungere, eliminare, scaricare un modello, verificare una connessione e recuperare un elenco di modelli sono azioni esplicite.

Se mancano tag, controlla la connessione browser, l'interruttore globale di tagging, lo stato di pausa del gruppo, la registrazione della piattaforma e il download del modello. Se la ricerca non parte, controlla consenso, gruppo scelto, credenziali provider, modello di ricerca e stato. Se non puoi modificare un gruppo collegato, riconnetti i programmi o scongelalo come indicato.
