# Riferimento funzionale dell'app desktop Vault

## Scopo e confine

Questo è il riferimento autorevole per l'interfaccia dell'applicazione desktop Vault. È intenzionalmente separato dal manuale dell'estensione del browser Vault.

L'app desktop gestisce le **applicazioni native e le finestre delle applicazioni**. L'estensione del browser gestisce siti Web, schede del browser e feed di piattaforme Web supportate. Condividono le stesse idee (gruppi, pianificazioni, timer, blocchi, posticipi, regole personalizzate e bridge opzionale), ma non hanno la stessa superficie di applicazione.

Utilizza questo documento per configurare, verificare, riprodurre o mantenere il comportamento dell'app desktop. Il codice è canonico se un'implementazione e questo manuale differiscono.

## 1. Ciò che l'app desktop può e non può controllare

Vault valuta la policy di messa a fuoco per le applicazioni native selezionate. Quando la sua funzionalità di applicazione nativa è disponibile, può applicare il piano corrente alle destinazioni dell'applicazione corrispondenti e segnalare un risultato di protezione/stato all'interfaccia utente dell'host.

Può:

- creare, abilitare, disabilitare, riordinare, importare, esportare, bloccare, posticipare e rimuovere gruppi;
- scegliere come target le applicazioni native selezionate tramite il selettore di applicazioni;
- applicare un blocco immediato, un'indennità temporizzata o un timer di solo conteggio;
- limitare i gruppi normali ai giorni feriali e alle finestre orarie locali;
- eseguire regole di policy JavaScript personalizzate per gli eventi del ciclo di vita dell'applicazione;
- mostrare informazioni sullo stato/pannello nativo creato dalla regola attraverso l'host;
- gestire una cartella locale opzionale per le richieste di file con regole personalizzate supportate;
- unisciti a gruppi compatibili esplicitamente collegati tramite il bridge Vault locale.

Non può:

- agire come un'estensione del browser, ispezionare il DOM di un sito web o manipolare le schede dei feed del browser;
- garantire che un sistema operativo consenta il controllo di ogni applicazione, processo, finestra o servizio di sistema;
- trasformare la selezione dell'applicazione in amministrazione remota, sorveglianza del dispositivo o firewall;
- far sì che gli helper personalizzati solo del browser come DOM, navigazione, reindirizzamento o controllo schede funzionino nel runtime nativo;
- sincronizzare automaticamente ogni gruppo semplicemente perché il bridge locale è in funzione.

## 2. Vocabolario

| Termine | Significato |
| --- | --- |
| Gruppo | Un oggetto policy di focus denominato. I nomi dei gruppi devono essere univoci all'interno dell'endpoint Vault corrente. |
| Obiettivo | Un'identità dell'applicazione nativa selezionata per un gruppo. |
| Gruppo di applicazioni predefinito | Un gruppo normale i cui obiettivi sono applicazioni native del selettore app. |
| Custom group | A group whose JavaScript rule reacts to application-policy events. |
| Partita | L'applicazione in primo piano/in esecuzione corrente corrisponde a una destinazione di gruppo abilitata e attiva o a una condizione di regola personalizzata. |
| Attivo | Abilitato, nell'ambito della pianificazione normale e non posticipato attivamente. |
| Piano di esecuzione | La conseguente decisione di autorizzazione/protezione/stato dell'host nativo dopo aver valutato i gruppi applicabili. |
| Congelare | Protezione contro la modifica ordinaria di un gruppo. |
| Posticipa | Un'eccezione temporanea da una normale politica di gruppo. |

## 3. Identità di destinazione e selezione dell'applicazione

Seleziona le applicazioni tramite il selettore **++** in un gruppo di applicazioni predefinito. Vault archivia un'identità normalizzata e un nome visualizzato.

| Ospite | Identità di destinazione utilizzata per la corrispondenza |
| --- | --- |
| macOS | Identificatore del bundle dell'applicazione, ove disponibile. |
| Finestre | Percorso eseguibile normalizzato o nome del processo fornito dal selettore dell'applicazione. |

Il nome visualizzato è per l'editor. Il valore normalizzato è l'identità utilizzata dal livello di applicazione nativa. Rinominare un'applicazione nell'interfaccia utente non ne modifica l'identità. Una destinazione può anche contenere tag per l'utilizzo della policy con regole personalizzate.

Non inserire l'URL di un sito Web in un campo di destinazione dell'applicazione e aspettarsi l'applicazione nativa dell'applicazione. Utilizza il gruppo Sito dell'estensione per il blocco dei siti web.

## 4. Ciclo di vita e precedenza del gruppo

Per impostazione predefinita è abilitato un nuovo gruppo. L'elenco dei gruppi supporta la selezione, l'attivazione/disattivazione, l'ordinamento del trascinamento, l'aggiunta, la cancellazione, l'importazione, l'esportazione e l'eliminazione. Il gruppo selezionato si apre nell'editor.

Le normali modifiche ai campi vengono salvate tramite la politica di salvataggio automatico dell'editor. Un gruppo congelato disabilita i normali controlli di modifica. Una sorgente personalizzata è diversa: il salvataggio del testo non lo rende attivo; **Esegui** è l'operazione che carica l'origine corrente nel runtime della policy.

Diversi gruppi possono corrispondere alla stessa applicazione. Vault valuta i criteri di gruppo in ordine memorizzato e crea un piano di applicazione nativo. Mantieni le sovrapposizioni intenzionali, soprattutto quando i gruppi utilizzano policy con tempistiche diverse o regole personalizzate emettono decisioni di autorizzazione/protezione. Riordinare i gruppi per rendere chiara la precedenza prevista; non fare affidamento sul fatto che una configurazione in conflitto venga risolta in un modo particolarmente intuitivo.

## 5. Gruppi di applicazioni normali

### 5.1 Stato del gruppo

| Campo | Contratto funzionale |
| --- | --- |
| Nome | Non vuoto, tagliato, univoco senza distinzione tra maiuscole e minuscole all'interno di questo endpoint. |
| Abilitato | I gruppi disabili vengono mantenuti ma non prendono parte alla normale applicazione delle norme. |
| Obiettivi | Una o più identità dell'applicazione selezionate dal selettore. |
| Comportamento | Blocco immediato, blocco dopo un permesso o timer/conteggio progressivo. |
| Programma | Giorni feriali selezionati e finestre orarie locali opzionali. |
| Congelare | Nessuno, Bloccato, Bloccato rigorosamente o Bloccato dai genitori. |
| Posticipa | Politica di eccezione temporanea per gruppo. |
| Messaggio di fallback/stato | Messaggio che l'host nativo può mostrare quando applica una risposta di scudo/stato. |

Un gruppo predefinito vuoto non ha una destinazione dell'applicazione selezionata e pertanto non corrisponde a un'applicazione semplicemente esistendo.

### 5.2 Comportamenti bloccanti

| Comportamento | Risultato |
| --- | --- |
| Blocca immediatamente | Un bersaglio attivo corrispondente produce una decisione nativa immediata di blocco/scudo. |
| Blocca dopo un certo numero di minuti | L'utilizzo corrispondente viene imputato all'indennità di gruppo. Quando la capacità è esaurita, il gruppo produce una decisione nativa di blocco/scudo fino a quando il suo periodo di utilizzo non viene ripristinato o un altro stato rende il gruppo inattivo. |
| Timer (conteggio progressivo, nessun blocco) | L'utilizzo corrispondente viene misurato e può essere visualizzato, ma quel timer da solo non produce mai un blocco. |

I nuovi gruppi utilizzano un limite di 15 minuti e un intervallo di ripristino di 24 ore, a meno che non vengano modificati. L'utilizzo temporizzato appartiene al gruppo, quindi tutte le destinazioni corrispondenti condividono quella policy di gruppo. La risposta esatta a un blocco viene implementata dall'host nativo ed è vincolata dalle autorizzazioni del sistema operativo e dal meccanismo di imposizione supportato.

### 5.3 Orari

Gli orari si applicano ai gruppi normali. Un gruppo personalizzato prende le proprie decisioni temporali in JavaScript.

Seleziona qualsiasi combinazione da lunedì a domenica. Ogni finestra temporale è una riga nell'ora locale:

```text
0900-1200
1330-1730
```

L'esatto formato accettato è HHMM-HHMM. Le ore devono essere comprese tra 00 e 23, i minuti tra 00 e 59 e l'inizio deve essere precedente alla fine dello stesso giorno. Una finestra include il suo inizio ed esclude la sua fine. Non sono accettate finestre oltre la mezzanotte. Le finestre vuote indicano l'intero giorno selezionato.

Il gruppo normale è attivo solo quando:

1. è abilitato;
2. viene selezionato il giorno della settimana corrente;
3. l'ora locale è all'interno di una finestra configurata, oppure il gruppo non ha finestre;
4. non è in modalità snooze attiva.

### 5.4 Posticipa

La posticipazione rimuove temporaneamente un gruppo normale dall'applicazione attiva. Le sue fasi sono:

| Fase | Risultato |
| --- | --- |
| In attesa | La richiesta esiste ma il ritardo di attivazione non è trascorso; il gruppo rimane attivo. |
| Attivo | Il gruppo è temporaneamente inattivo per la durata della posticipazione. |
| Raffreddamento | La posticipazione è terminata e il gruppo è di nuovo attivo, ma una nuova posticipazione non è ancora disponibile. |

| Impostazione | Regola |
| --- | --- |
| Consenti posticipazione | Quando è disattivato, il gruppo non può essere normalmente posticipato. |
| Durata posticipo | Numero positivo di minuti. Il valore predefinito per un nuovo gruppo è 30 minuti. |
| Ritardo di attivazione | Zero o più minuti prima che la funzione snooze diventi attiva. |
| Raffreddamento | Da zero a cinque minuti dopo la fine della ripetizione attiva. |
| Conferme | Numero intero non negativo di interazioni di conferma richieste. |

Una posticipazione attiva è un'eccezione temporanea alle policy, non un'eliminazione o uno sblocco. La configurazione del gruppo rimane intatta.

### 5.5 Congelare

Il congelamento è una barriera alla modifica deliberata.

| Modalità | Contratto |
| --- | --- |
| Congelato | Le modifiche ordinarie e i cambiamenti dello stato ordinario rimangono bloccati finché il flusso di conferma dello sblocco del prodotto non ha esito positivo. |
| Rigorosamente congelato | Il gruppo non può essere sbloccato prima del termine del periodo di blocco rigoroso. La durata è positiva e limitata a 72 ore. |
| Parentale congelato | Per le azioni di blocco/sblocco è necessaria la gestione della password del tutore. |

La scelta di una modalità nell'editor non congela il gruppo di per sé; utilizzare l'azione di congelamento per applicarla. Un gruppo collegato tramite bridge può anche bloccare i controlli di blocco coordinati mentre un membro richiesto è offline.

## 6. Applicazione nativa e controllo dei dispositivi

L'editor può salvare con precisione un gruppo anche quando il sistema operativo non ha concesso la possibilità di imporlo. Controlla sempre **Impostazioni → Controllo dispositivo** e lo stato nativo live dopo aver modificato le autorizzazioni.

L'host nativo decide quali azioni sono possibili per il sistema operativo, l'applicazione, la finestra e lo stato di autorizzazione correnti. Una regola può essere configurata correttamente ma non avere alcun effetto visibile quando:

- Il Controllo del Dispositivo non è stato concesso o è stato revocato;
- il gruppo è disabilitato, programmato o posticipato attivamente;
- il processo focalizzato non corrisponde a un obiettivo normalizzato selezionato;
- il sistema operativo rifiuta un'azione per quel target;
- Una dipendenza del bridge è offline per un'azione che richiede uno stato coordinato.

Non considerare un salvataggio riuscito come prova della disponibilità di un'applicazione attiva. Testa il target selezionato mentre il gruppo è attivo e controlla lo stato dell'host.

## 7. Gruppi personalizzati e regole di policy native

I gruppi personalizzati vengono eseguiti nel runtime della policy JavaScript nativa. Non sono regole personalizzate del browser. Il DOM del browser, le schede, la navigazione, il reindirizzamento degli URL e il comportamento di controllo dei feed non sono intenzionalmente disponibili.

### 7.1 Ciclo di vita della sorgente

Use a function expression:

```js
(events, helpers) => {
  events.on("focusEvent", "shield-focus", (event, h) => {
    if (event.target?.id) event.setResult(-1);
  });
}
```

Run loads the source and its event registrations. Running again unloads the old source and resets its rule-owned handlers, timers, panels, persistence, and dynamic app blocklist. A source that does not evaluate to a function cannot be loaded.

### 7.2 Eventi nativi integrati

| Evento | Significato |
| --- | --- |
| tickEvento | Ticchettio periodico dell'ospite. Un'opzione di registrazione intervalMs può limitare la velocità di un gestore. |
| timerFine | Il conto alla rovescia gestito da una regola raggiunge lo zero. |
| snoozePremere | L'utente preme Avvia posticipazione per un gruppo personalizzato. |
| pannelloEvento | Viene utilizzato un controllo del pannello personalizzato. |
| eventoFilelocale | Viene completata un'azione richiesta della cartella locale. |
| openAppEvent | Si apre un'applicazione tracciata. |
| closeAppEvent | Un'applicazione tracciata si chiude. |
| focusEvento | L'applicazione in primo piano si trasforma in un'applicazione. |
| unfocusEvento | L'applicazione in primo piano cambia da applicazione. |
| minimizzaEvento / unminimizeEvent | L'host segnala una transizione di minimizzazione della finestra supportata. |
| switchAppEvent | L'applicazione in primo piano cambia da un'app all'altra. |
| appChangedEvent | Evento di modifica/ciclo di vita generale dell'applicazione. |

L'oggetto evento contiene tipo, groupId/groupID, groupName, URL/nome host equivalenti, ora, dati e destinazione. Per un'applicazione nativa, target espone un id, kind, displayName, valore normalizzato e tag quando la destinazione del focus corrisponde a una destinazione configurata.

I dati sugli eventi del ciclo di vita dell'applicazione includono l'ID/nome dell'app corrente, il nome del gruppo, uno snapshot dell'app in esecuzione serializzata e valori specifici dell'evento come bundleId, previousAppId, currentAppId o il motivo della modifica.

### 7.3 API degli eventi e decisioni

Il registro fornisce on/register, off/unregister, unregisterAll, countRegistered, getEvent e getEvents. La priorità più alta viene eseguita per prima; la stessa priorità preserva l'ordine di registrazione. Il registro ha un limite di gestori per gruppo.

L'oggetto evento supporta:

| Metodo | Risultato |
| --- | --- |
| setRisultato(-1) | Produrre una decisione nativa di scudo/blocco. Anche il risultato di una stringa diventa un blocco nativo perché le regole desktop non hanno una destinazione di reindirizzamento del browser. |
| consentire(motivo) o setResult(1) | Produrre una decisione di autorizzazione per l'evento. |
| setShieldMessage(messaggio) | Imposta il messaggio di stato/schermo rivolto verso l'uomo per un blocco nativo. |
| stopPropagazione() | Arresta i gestori successivi per l'evento corrente. |
| blocca(appId), sblocca(appId) | Aggiungi/rimuovi un blocco di applicazione nativa dinamica. |
| chiudi(appId), apri(appId) | Richiedi un'azione di chiusura/apertura nativa supportata. |
| post(tipo, dati) | Invia un evento personalizzato nidificato all'interno del runtime nativo. |

Il runtime dell'app consente timer, persistenza, pannelli, registri, operazioni di cartelle locali, helper della finestra dell'applicazione e utilità di classificazione degli URL. Tratta deliberatamente il DOM, la navigazione, il reindirizzamento e gli helper delle schede del browser come non disponibili/inerti.

### 7.4 Aiutanti nativi

| Aiutante | Comportamento nativo |
| --- | --- |
| getLogHelper | Emette decisioni su app/popup/registro schermo. |
| getTimerHelper | Crea timer avanti/indietro con limiti, passaggi, predicati di ambito/dominio, pausa/ripresa, ispezione dello stato e transizioni timerEnded. I timer non si proteggono da soli. |
| getPersistenceHelper | Stato JSON per gruppo: ottieni, imposta, elimina, ha, chiavi, voci, cancella, dimensione. |
| getStorageHelper | Persistenza più segnaposto di richiesta asincrona dell'host; non assumere una risposta esterna sincrona. |
| getWindowHelper | Legge le applicazioni correnti/in esecuzione e richiede azioni di chiusura/apertura/blocco/sblocco dell'applicazione. |
| getPanelHelper | Crea istantanee, controlli, gestori in linea e reazioni panelEvent nativi convalidati del pannello. |
| getLocalFolderHelper | Le code consentivano operazioni .txt, .csv e .json relative nella root concessa dall'utente. Il completamento è localFileEvent. |
| getDomainHelper / getDomainUtility | Classificatori di URL e piattaforma per regole che ragionano anche su valori simili a URL. |
| getPlatformHelper / piattaforma | I classificatori URL rimangono disponibili; le chiamate di controllo feed/DOM native sono inerti perché l'host desktop non ha DOM del sito web. |

I pannelli personalizzati utilizzano lo stesso vocabolario di controllo dichiarativo del runtime del browser: testo, casella di controllo, selezione, textInput, textarea, pulsante, sezione, timer, numberInput, intervallo, attiva/disattiva, radio, data, ora, colore, pin e html ripulito. L'host nativo decide quanto pannello può essere visualizzato sulla piattaforma corrente.

## 8. Cartella file locale

La cartella file locale è un limite facoltativo concesso dall'utente per le regole personalizzate. Le regole possono richiedere letture, scritture, aggiunte, elenchi, test di esistenza e operazioni JSON di testo/CSV/JSON. I percorsi sono sempre relativi alla radice selezionata. I percorsi assoluti, i segmenti attraversanti, i componenti del percorso nascosti, le estensioni non supportate e le operazioni esterne alla radice vengono rifiutati.

Revocare la cartella quando una regola non ne ha più bisogno. Una regola deve gestire le autorizzazioni non disponibili e i risultati localFileEvent non riusciti; non deve presupporre che una cartella selezionata rimanga autorizzata dopo un riavvio.

## 9. Ponte tra app Web

Il bridge è una sincronizzazione locale opzionale tra programmi Vault compatibili. Un'app desktop nativa può ospitare l'hub locale; i client si connettono all'indirizzo locale supportato.

Gli stati di connessione sono Disattivato, Connessione in corso, Disconnesso, Connesso/In esecuzione ed Errore. Il collegamento di un programma non unisce tutti i gruppi. L'utente deve collegare in modo esplicito i gruppi corrispondenti idonei.

Per un collegamento di gruppo:

1. Avvia l'hub nativo in Impostazioni.
2. Connetti l'altro endpoint Vault compatibile.
3. Crea gruppi corrispondenti e sbloccati con lo stesso nome e tipo.
4. Nella sezione Bridge di gruppo, scegli il programma e collega il gruppo.

Un gruppo collegato forma un cluster. I valori dei criteri comuni supportati, l'utilizzo e lo stato di posticipazione possono essere sincronizzati mentre i membri sono connessi. La disconnessione sospende la sincronizzazione e preserva i gruppi locali. Non è garantito il trasferimento di target solo browser, azioni personalizzate non supportate e campi specifici della piattaforma.

## 10. Importa, esporta, ripristina e controlla

L'esportazione salva una rappresentazione di gruppo compatibile. L'importazione convalida/normalizza i dati dei gruppi compatibili e applica comunque l'unicità del nome locale. Elimina gruppo rimuove il gruppo selezionato e il relativo stato associato. Cancella rimuove tutti i gruppi dopo la conferma. Il ripristino delle impostazioni predefinite influisce sulle impostazioni globali dell'editor; esportare tutto ciò che deve essere conservato per primo.

Prima di affidarsi a una regola desktop:

1. Verificare che il controllo del dispositivo sia concesso.
2. Verificare l'identità normalizzata del target selezionato.
3. Verificare lo stato di attivazione, la pianificazione, lo stato di blocco e la fase di posticipazione.
4. Testare separatamente il comportamento immediato, temporizzato e di conteggio.
5. Per un gruppo personalizzato, esegui l'origine esatta e testa ogni evento dell'app registrato.
6. Verificare gli errori della cartella locale e le operazioni riuscite.
7. Verificare il comportamento offline/connesso del bridge se il gruppo è collegato.

## 11. Note specifiche della piattaforma

I concetti fondamentali della policy sono condivisi, ma l'applicazione nativa è specifica dell'host:

| macOS | Finestre |
| --- | --- |
| Le destinazioni normalmente si risolvono in identificatori del bundle dell'applicazione. Controllo dispositivo e attuale applicazione del gate dello stato delle autorizzazioni di macOS. | Le destinazioni normalmente si risolvono in un percorso eseguibile normalizzato o in un nome di processo. Il livello di applicazione di Windows decide quali finestre/processi correnti possono essere gestiti. |

Questo riferimento desktop non descrive deliberatamente le blocklist dei siti web, i selettori dei feed, la classificazione dei creatori di YouTube, i reindirizzamenti del browser o le azioni delle schede del browser. Quelli appartengono al manuale di estensione di Vault.
