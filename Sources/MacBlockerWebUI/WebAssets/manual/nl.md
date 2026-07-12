# Functionele referentie voor Vault desktop-app

## Doel en grens

Dit is de gezaghebbende referentie voor de Vault-desktopapplicatie-interface. Het staat opzettelijk los van de Vault-browserextensiehandleiding.

De desktop-app beheert **native applicaties en applicatievensters**. De browserextensie beheert websites, browsertabbladen en ondersteunde webplatformfeeds. Ze delen dezelfde ideeën (groepen, schema's, timers, bevriezingen, snoozes, aangepaste regels en de optionele brug), maar ze hebben niet hetzelfde handhavingsoppervlak.

Gebruik dit document om het gedrag van de desktop-app te configureren, controleren, reproduceren of onderhouden. De code is canoniek als een implementatie en deze handleiding verschillen.

## 1. Wat de desktop-app wel en niet kan controleren

Vault evalueert het focusbeleid voor geselecteerde native applicaties. Wanneer de eigen handhavingsmogelijkheden beschikbaar zijn, kan het het huidige plan toepassen op overeenkomende applicatiedoelen en een schild-/statusresultaat rapporteren aan de host-UI.

Het kan:

- groepen maken, inschakelen, uitschakelen, opnieuw rangschikken, importeren, exporteren, bevriezen, snoozen en verwijderen;
- target native applicaties geselecteerd via de applicatiekiezer;
- een onmiddellijke blokkering, een getimede vergoeding of een timer die alleen optelt, toepassen;
- beperk normale groepen tot weekdagen en lokale tijdvensters;
- Aangepaste JavaScript-beleidsregels uitvoeren voor gebeurtenissen in de levenscyclus van applicaties;
- door regels gemaakte native status-/paneelinformatie weergeven via de host;
- beheer een optionele lokale map voor ondersteunde bestandsaanvragen met aangepaste regels;
- sluit u aan bij compatibele, expliciet gekoppelde groepen via de lokale Vault-brug.

Het kan niet:

- fungeren als een browserextensie, inspecteren van de DOM van een website of het manipuleren van browserfeedkaarten;
- garanderen dat een besturingssysteem het mogelijk maakt elke applicatie, proces, venster of systeemservice te controleren;
- applicatieselectie omzetten in beheer op afstand, apparaatbewaking of een firewall;
- Aangepaste helpers voor alleen browsers, zoals DOM, navigatie, omleiding of tabbladcontrole, laten werken in de native runtime;
- synchroniseer elke groep automatisch, alleen maar omdat de lokale bridge actief is.

## 2. Woordenschat

| Termijn | Betekenis |
| --- | --- |
| Groep | Een benoemd focus-beleidsobject. Groepsnamen moeten uniek zijn binnen het huidige Vault-eindpunt. |
| Doel | Een systeemeigen applicatie-identiteit geselecteerd voor een groep. |
| Standaard applicatiegroep | Een normale groep waarvan de doelen native applicaties uit de app-kiezer zijn. |
| Custom group | A group whose JavaScript rule reacts to application-policy events. |
| Overeenkomen | De huidige toepassing op de voorgrond/actieve toepassing komt overeen met een ingeschakeld en actief groepsdoel of aangepaste regelvoorwaarde. |
| Actief | Ingeschakeld, binnen het normale schema, en niet actief gesnoozed. |
| Handhavingsplan | De resulterende beslissing over toestaan/afschermen/status van de systeemeigen host nadat toepasselijke groepen zijn geëvalueerd. |
| Bevriezen | Bescherming tegen gewone wijziging van een groep. |
| Snoozen | Een tijdelijke uitzondering op een normaal groepsbeleid. |

## 3. Doelidentiteit en applicatiekiezer

Selecteer applicaties via de **+**-kiezer in een standaardapplicatiegroep. Vault slaat een genormaliseerde identiteit en een weergavenaam op.

| Gastheer | Doelidentiteit gebruikt voor matching |
| --- | --- |
| macOS | Applicatiebundel-ID, indien beschikbaar. |
| Windows | Genormaliseerd uitvoerbaar pad of procesnaam geleverd door de applicatiekiezer. |

De weergavenaam is voor de editor. De genormaliseerde waarde is de identiteit die wordt gebruikt door de native handhavingslaag. Het hernoemen van een applicatie in de gebruikersinterface verandert de identiteit niet. Een doel kan ook tags bevatten voor gebruik van aangepast regelbeleid.

Voer geen website-URL in een applicatiedoelveld in en verwacht dat de applicatie wordt afgedwongen. Gebruik de sitegroep van de extensie voor het blokkeren van websites.

## 4. Levenscyclus en prioriteit van groepen

Standaard is een nieuwe groep ingeschakeld. De groepslijst ondersteunt selectie, in-/uitschakelen, slepen, toevoegen, wissen, importeren, exporteren en verwijderen. De geselecteerde groep wordt geopend in de editor.

Normale veldbewerkingen worden opgeslagen via het autosave-beleid van de editor. Een bevroren groep schakelt de gewone bewerkingsopties uit. Een aangepaste bron is anders: het opslaan van tekst maakt deze niet actief; **Uitvoeren** is de bewerking waarmee de huidige bron in de beleidsruntime wordt geladen.

Meerdere groepen kunnen overeenkomen met dezelfde toepassing. Vault evalueert het groepsbeleid in opgeslagen volgorde en stelt een eigen handhavingsplan op. Zorg ervoor dat er geen overlappingen zijn, vooral wanneer groepen verschillende getimede beleidsregels gebruiken of aangepaste regels beslissingen over toestaan/afschermen afgeven. Herschik de groepen om de beoogde prioriteit duidelijk te maken; vertrouw er niet op dat een conflicterende configuratie op een bijzonder gebruiksvriendelijke manier wordt opgelost.

## 5. Normale applicatiegroepen

### 5.1 Groepsstatus

| Veld | Functioneel contract |
| --- | --- |
| Naam | Niet-leeg, bijgesneden, uniek en hoofdletterongevoelig binnen dit eindpunt. |
| Ingeschakeld | Groepen met een handicap blijven behouden, maar nemen niet deel aan de normale handhaving. |
| Doelstellingen | Een of meer applicatie-identiteiten geselecteerd uit de kiezer. |
| Gedrag | Onmiddellijk blokkeren, blokkeren na een vergoeding, of timer/optellen. |
| Schema | Geselecteerde weekdagen en optionele lokale tijdvensters. |
| Bevriezen | Geen, Bevroren, Strikt bevroren of Ouderlijk bevroren. |
| Snoozen | Tijdelijk uitzonderingsbeleid per groep. |
| Terugval-/statusbericht | Bericht dat de native host kan weergeven wanneer deze een schild-/statusreactie toepast. |

Een lege standaardgroep heeft geen geselecteerd applicatiedoel en komt daarom niet overeen met een applicatie alleen maar omdat deze bestaat.

### 5.2 Gedrag blokkeren

| Gedrag | Resultaat |
| --- | --- |
| Direct blokkeren | Een passend actief doelwit produceert onmiddellijk een native block/shield-beslissing. |
| Blokkeren na een aantal minuten | Het matchinggebruik komt ten laste van de collectiviteitstoeslag. Wanneer de hoeveelheid is opgebruikt, maakt de groep een native block/shield-beslissing totdat de gebruiksperiode wordt gereset of een andere status de groep inactief maakt. |
| Timer (optellen, geen blokkering) | Het bijbehorende gebruik wordt gemeten en eventueel weergegeven, maar die timer alleen levert nooit een blok op. |

Nieuwe groepen gebruiken een periode van 15 minuten en een reset-interval van 24 uur, tenzij er wijzigingen worden aangebracht. Getimed gebruik behoort tot de groep, dus alle overeenkomende doelen delen dat groepsbeleid. De exacte reactie op een blokkering wordt geïmplementeerd door de native host en wordt beperkt door de machtigingen van het besturingssysteem en het ondersteunde handhavingsmechanisme.

### 5.3 Schema's

Voor normale groepen gelden de roosters. Een aangepaste groep neemt zijn eigen tijdbeslissingen in JavaScript.

Selecteer een combinatie van maandag tot en met zondag. Elk tijdvenster is één regel in de lokale tijd:

```text
0900-1200
1330-1730
```

Het exacte geaccepteerde formaat is HHMM-UHMM. De uren moeten van 00 tot en met 23 zijn, de minuten van 00 tot en met 59 en de start moet eerder zijn dan het einde op dezelfde dag. Een venster omvat het begin ervan en sluit het einde ervan uit. Tussen middernacht-vensters worden niet geaccepteerd. Lege vensters betekenen de gehele geselecteerde dag.

De normale groep is alleen actief wanneer:

1. het is ingeschakeld;
2. de huidige weekdag is geselecteerd;
3. de lokale tijd valt binnen een geconfigureerd venster, of de groep heeft geen vensters;
4. het bevindt zich niet in een actieve snooze.

### 5.4 Snooze

Snooze verwijdert tijdelijk een normale groep van actieve handhaving. De fasen zijn:

| Fase | Resultaat |
| --- | --- |
| In behandeling | Het verzoek bestaat, maar de activeringsvertraging is niet verstreken; de groep blijft actief. |
| Actief | De groep is tijdelijk inactief gedurende de sluimerduur. |
| Afkoeling | De snooze is afgelopen en de groep is weer actief, maar een nieuwe snooze is nog niet beschikbaar. |

| Instelling | Regel |
| --- | --- |
| Snooze toestaan ​​| Als deze optie is uitgeschakeld, kan de groep niet normaal op snooze worden gezet. |
| Sluimerduur | Positief aantal minuten. De standaardwaarde voor een nieuwe groep is 30 minuten. |
| Activeringsvertraging | Nul of meer minuten voordat de snooze actief wordt. |
| Afkoeling | Nul tot en met vijf minuten nadat de actieve snooze is geëindigd. |
| Bevestigingen | Niet-negatief geheel aantal vereiste bevestigingsinteracties. |

Een actieve snooze is een tijdelijke beleidsuitzondering, en geen verwijdering of het opheffen van de bevriezing. De groepsconfiguratie blijft intact.

### 5.5 Bevriezen

Freeze is een doelbewuste wijzigingsbarrière.

| Modus | Overeenkomst |
| --- | --- |
| Bevroren | Gewone bewerkingen en gewone statuswijzigingen blijven vergrendeld totdat de bevestigingsstroom voor het ontdooien van het product slaagt. |
| Strikt bevroren | De groep kan niet worden gedeblokkeerd voordat de strikte bevriezingsduur is verstreken. De duur is positief en beperkt tot 72 uur. |
| Ouderlijk bevroren | Guardian-wachtwoordbeheer is vereist voor acties voor bevriezen/deblokkeren. |

Het kiezen van een modus in de editor bevriest de groep niet vanzelf; gebruik de bevriezingsactie om het toe te passen. Een aan een brug gekoppelde groep kan ook gecoördineerde bevriezingscontroles vergrendelen terwijl een vereist lid offline is.

## 6. Native handhaving en apparaatcontrole

De editor kan een groep nauwkeurig opslaan, zelfs als het besturingssysteem niet de mogelijkheid heeft gegeven om deze af te dwingen. Controleer altijd **Instellingen → Apparaatbeheer** en de live native status na het wijzigen van machtigingen.

De native host bepaalt welke acties mogelijk zijn voor het huidige besturingssysteem, de applicatie, het venster en de machtigingsstatus. Een regel kan correct zijn geconfigureerd maar geen zichtbaar effect hebben wanneer:

- Device Control wordt niet verleend of is ingetrokken;
- de groep is uitgeschakeld, gepland of actief op snooze gezet;
- het gerichte proces komt niet overeen met een geselecteerd genormaliseerd doel;
- het besturingssysteem wijst een actie voor dat doel af;
- een brugafhankelijkheid is offline voor een actie waarvoor een gecoördineerde status vereist is.

Beschouw een succesvolle save-toast niet als bewijs dat er actieve handhaving mogelijk is. Test het geselecteerde doel terwijl de groep actief is en inspecteer de hoststatus.

## 7. Aangepaste groepen en native beleidsregels

Aangepaste groepen worden uitgevoerd in de native JavaScript-beleidsruntime. Het zijn geen aangepaste browserregels. Browser-DOM, tabblad, navigatie, URL-omleiding en feedcontrolegedrag zijn opzettelijk niet beschikbaar.

### 7.1 Bronlevenscyclus

Use a function expression:

```js
(events, helpers) => {
  events.on("focusEvent", "shield-focus", (event, h) => {
    if (event.target?.id) event.setResult(-1);
  });
}
```

Run loads the source and its event registrations. Running again unloads the old source and resets its rule-owned handlers, timers, panels, persistence, and dynamic app blocklist. A source that does not evaluate to a function cannot be loaded.

### 7.2 Native ingebouwde gebeurtenissen

| Evenement | Betekenis |
| --- | --- |
| tickEvent | Periodieke gastheertik. Een intervalMs-registratieoptie kan een handler een snelheidslimiet geven. |
| timerBeëindigd | Een aftelling op basis van een regel bereikt nul. |
| snoozeDruk op | De gebruiker drukt op Snooze starten voor een aangepaste groep. |
| paneelGebeurtenis | Er wordt gebruik gemaakt van een aangepast paneelbesturingselement. |
| localFileEvent | Een gevraagde actie voor een lokale map is voltooid. |
| openAppEvent | Er wordt een bijgehouden toepassing geopend. |
| closeAppEvent | Een gevolgde applicatie wordt gesloten. |
| focusEvent | De voorgrondapplicatie verandert in een applicatie. |
| unfocusEvent | De voorgrondtoepassing wijkt af van een toepassing. |
| minimaliserenEvent / unminimizeEvent | De host rapporteert een ondersteunde overgang naar vensterminimalisatie. |
| switchAppEvent | De voorgrondapplicatie verandert van de ene app naar de andere. |
| appChangedEvent | Algemene levenscyclus/wijzigingsgebeurtenis van applicaties. |

Het gebeurtenisobject bevat type, groupId/groupID, groupName, URL/hostnaam-equivalenten, tijd, gegevens en doel. Voor een systeemeigen toepassing geeft doel een id, soort, displayName, genormaliseerde waarde en tags weer wanneer het focusdoel overeenkomt met een geconfigureerd doel.

Gegevens over gebeurtenissen in de levenscyclus van toepassingen omvatten de huidige app-id/-naam, groepsnaam, een geserialiseerde momentopname van de actieve app en gebeurtenisspecifieke waarden zoals bundelId, previousAppId, currentAppId of wijzigingsreden.

### 7.3 Gebeurtenis-API en beslissingen

Het register biedt aan/registreren, uit/uitschrijven, unregisterAll, countRegistered, getEvent en getEvents. Hogere prioriteit wordt eerst uitgevoerd; gelijke prioriteit behoudt de registratievolgorde. Het register heeft een handlerlimiet per groep.

Het gebeurtenisobject ondersteunt:

| Werkwijze | Resultaat |
| --- | --- |
| setResultaat(-1) | Maak een native schild-/blokbeslissing. Een tekenreeksresultaat wordt ook een native blok omdat desktopregels geen browseromleidingsdoel hebben. |
| allow(reden) of setResult(1) | Maak een toestemmingsbesluit voor de gebeurtenis. |
| setShieldMessage(bericht) | Stel het naar de mens gerichte schild/statusbericht in voor een native blok. |
| stopPropagation() | Stop latere handlers voor de huidige gebeurtenis. |
| blokkeren(appId), deblokkeren(appId) | Een dynamisch native applicatieblok toevoegen/verwijderen. |
| close(appId), open(appId) | Vraag een ondersteunde native sluit/open-actie aan. |
| post(type, gegevens) | Verzend een geneste aangepaste gebeurtenis binnen de systeemeigen runtime. |

De app-runtime maakt timers, persistentie, panelen, logboeken, bewerkingen in lokale mappen, hulpprogramma's voor toepassingsvensters en hulpprogramma's voor URL-classificatie mogelijk. Het beschouwt DOM, navigatie, omleiding en browsertabbladhelpers opzettelijk als niet beschikbaar/inert.

### 7.4 Inheemse helpers

| Helper | Inheems gedrag |
| --- | --- |
| getLogHelper | Zendt app-/pop-up-/schermlogboekbeslissingen uit. |
| getTimerHelper | Creëert voorwaartse/achterwaartse timers met grenzen, stappen, reikwijdte/domeinpredikaten, pauzeren/hervatten, statusinspectie en timerEnded-overgangen. Timers beschermen niet op zichzelf. |
| getPersistentieHelper | JSON-status per groep: ophalen, instellen, verwijderen, heeft, sleutels, vermeldingen, wissen, grootte. |
| getStorageHelper | Persistentie plus tijdelijke aanduidingen voor async-verzoeken van host; ga niet uit van een synchrone externe reactie. |
| getWindowHelper | Leest huidige/actieve applicaties en vraagt ​​om acties voor het sluiten/openen/blokkeren/deblokkeren van applicaties. |
| getPanelHelper | Creëert gevalideerde native panel-snapshots, bedieningselementen, inline-handlers en panelEvent-reacties. |
| getLocalFolderHelper | Wachtrijen stonden relatieve .txt-, .csv- en .json-bewerkingen toe onder de door de gebruiker toegekende root. De voltooiing is localFileEvent. |
| getDomainHelper / getDomainUtility | URL- en platformclassificaties voor regels die ook redeneren over URL-achtige waarden. |
| getPlatformHelper / platform | URL-classificatoren blijven beschikbaar; native feed/DOM-besturingsaanroepen zijn inert omdat de desktophost geen website-DOM heeft. |

Aangepaste panelen gebruiken dezelfde declaratieve controlewoordenschat als de browserruntime: tekst, selectievakje, selectie, textInput, textarea, knop, sectie, timer, numberInput, bereik, toggle, radio, datum, tijd, kleur, pincode en opgeschoonde html. De native host bepaalt hoeveel van een paneel op het huidige platform kan worden weergegeven.

## 8. Lokale bestandsmap

De lokale bestandsmap is een optionele, door de gebruiker toegekende grens voor aangepaste regels. Regels kunnen verzoeken om tekst/CSV/JSON-lees-, schrijf-, appends-, lijsten-, bestaanstests en JSON-bewerkingen. Paden zijn altijd relatief ten opzichte van de geselecteerde wortel. Absolute paden, traversal-segmenten, verborgen padcomponenten, niet-ondersteunde extensies en bewerkingen buiten de root worden afgewezen.

Trek de map in wanneer een regel deze niet langer nodig heeft. Een regel moet niet-beschikbare toestemming en mislukte localFileEvent-resultaten afhandelen; er mag niet van worden uitgegaan dat een geselecteerde map na een herstart geautoriseerd blijft.

## 9. Web-app-bridge

De bridge is optionele lokale synchronisatie tussen compatibele Vault-programma's. Een native desktop-app kan de lokale hub hosten; clients maken verbinding op het ondersteunde lokale adres.

Verbindingsstatussen zijn Uit, Bezig met verbinden, Verbinding verbroken, Verbonden/actief en Fout. Door een programma te koppelen worden niet alle groepen samengevoegd. De gebruiker moet in aanmerking komende overeenkomende groepen expliciet koppelen.

Voor een groepslink:

1. Start de native hub in Instellingen.
2. Verbind het andere compatibele Vault-eindpunt.
3. Maak bijpassende, niet-bevroren groepen met dezelfde naam en hetzelfde type.
4. Kies in het gedeelte Groepsbrug het programma en verbind de groep.

Een gekoppelde groep vormt een cluster. Ondersteunde algemene beleidswaarden, gebruik en snooze-status kunnen worden gesynchroniseerd terwijl leden verbonden zijn. Als u de verbinding verbreekt, wordt de synchronisatie onderbroken en blijven lokale groepen behouden. Het is niet gegarandeerd dat browserdoelen, niet-ondersteunde aangepaste acties en platformspecifieke velden worden overgedragen.

## 10. Importeren, exporteren, resetten en auditen

Exporteren slaat één compatibele groepsrepresentatie op. Import valideert/normaliseert compatibele groepsgegevens en dwingt nog steeds de uniciteit van de lokale naam af. Groep verwijderen verwijdert de geselecteerde groep en de bijbehorende status. Clear verwijdert alle groepen na bevestiging. Het terugzetten naar de standaardwaarden heeft invloed op de globale editorinstellingen; exporteer alles wat eerst moet worden bewaard.

Voordat u op een desktopregel vertrouwt:

1. Controleer of Apparaatbeheer is verleend.
2. Controleer de genormaliseerde identiteit van het geselecteerde doel.
3. Controleer de ingeschakelde status, planning, bevriezingsstatus en snooze-fase.
4. Test onmiddellijk, getimed en optelgedrag afzonderlijk.
5. Voer voor een aangepaste groep de exacte bron uit en test elke geregistreerde app-gebeurtenis.
6. Controleer zowel fouten in lokale mappen als succesvolle bewerkingen.
7. Controleer het offline/verbonden gedrag van de brug als de groep is gekoppeld.

## 11. Platformspecifieke opmerkingen

De kernbeleidsconcepten worden gedeeld, maar native handhaving is hostspecifiek:

| macOS | Windows |
| --- | --- |
| Doelen worden normaal gesproken omgezet in applicatiebundel-ID's. Apparaatbeheer en de huidige poorthandhaving van de macOS-toestemmingsstatus. | Doelen worden normaal gesproken omgezet in een genormaliseerd uitvoerbaar pad of procesnaam. De Windows-handhavingslaag bepaalt welke huidige vensters/processen kunnen worden beheerd. |

Deze desktopreferentie beschrijft met opzet geen websiteblokkeringslijsten, feedselectors, YouTube-creatorsclassificatie, browseromleidingen of browsertabbladacties. Deze horen bij de Vault-extensiehandleiding.
