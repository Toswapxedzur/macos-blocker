# Gebruikershandleiding Mac Vault

Mac Vault heeft drie pagina's: **Vault** blokkeert native apps, **Classifier** tagt ondersteunde browserinhoud en **Activity** toont geregistreerd gebruik. De browserextensie verzamelt ondersteunde inhoud en past browserblokkering toe. Installeer en verbind de extensie in de browser die je gebruikt.

## Snel starten

1. Voeg in **Vault** een blokkeergroep en Apps-doel toe en selecteer apps met de +-kiezer.
2. Kies het blokkeergedrag van de groep en schakel die in.
3. Maak in **Classifier** een groep, kies de platforms en voeg tags met beschrijvingen toe.
4. Kies een lokaal modelniveau en download het zo nodig. Schakel tagging in bij de Classifier-instellingen en hervat de groep.
5. Open ondersteunde inhoud in de verbonden browser. Stel een tagfilter in een browser-blokkeergroep in als tags de blokkering moeten sturen.

## Blokkeergroepen

Een **blokkeergroep** past een blokkeerbeleid toe. Een **Classifier-groep** wijst tags toe aan inhoud; die blokkeert zelf niets.

1. Voeg een blokkeergroep toe en geef deze een naam.
2. Kies doelen onder **Van toepassing op**.
3. Kies wanneer blokkeren geldt en stel eventueel een schema of toegestane tijd in.
4. Schakel de groep in. De doelen delen het beleid van de groep.

Gewone wijzigingen worden automatisch opgeslagen. Een fout betekent dat de wijziging niet is geaccepteerd; corrigeer het veld en probeer opnieuw. Schakel een groep uit om het beleid te stoppen en de configuratie te behouden. **Groep verwijderen** verwijdert de groep. Sleep groepen om ze te herschikken. Meerdere groepen kunnen hetzelfde doel raken; uitstel van één groep heft de blokkering door een andere niet op.

**Exporteren** kopieert een groepsconfiguratie. **Importeren** vervangt na bevestiging de configuratie van de geselecteerde groep.

### Toegestane tijd en schema

**Onmiddellijk blokkeren** geldt zodra de ingeschakelde groep overeenkomt en het schema actief is. **Blokkeren zodra de toegestane tijd is gebruikt** staat overeenkomstig gebruik toe totdat de tijd op is.

Stel de toegestane tijd in minuten in en het herstelinterval in uren. Een rollende limiet telt gebruik in het voorafgaande tijdvenster. Een herstel om middernacht begint een nieuwe periode om lokale middernacht, ook voor een rollende limiet.

Kies actieve weekdagen en optionele lokale tijdvensters, één per regel, zoals **09:00-12:00**. Zonder vensters geldt het schema de hele geselecteerde dagen. Een venster moet op dezelfde dag later eindigen dan het begint; splits een nachtelijk schema over aparte dagen.

### Uitstel

Stel uitstel in voor elke blokkeergroep. **Blokkering pauzeren** schort het beleid van die groep op gedurende de pauzetijd. **Aan de toegestane tijd toevoegen** voegt bruikbare minuten toe aan een groep met tijdslimiet. Alleen gebruikte extra tijd telt als uitstel. Ongebruikte extra tijd vervalt bij de volgende reset; bij een rollende limiet na één venster, of eerder om middernacht als die optie aanstaat.

**Activeringsvertraging** stelt uitstel uit terwijl de blokkering doorgaat. **Afkoelperiode** is de wachttijd na afloop van uitstel voordat je het opnieuw kunt aanvragen. **Vereiste bevestigingen** bepaalt het aantal bevestigingsstappen. Uitstel is bij een bevroren groep alleen beschikbaar als het vóór het bevriezen is toegestaan.

### Bevriezen en PIN

**Bevriezen** voorkomt gewone wijzigingen. Ontdooien vereist tien bevestigingen met vijf seconden ertussen, plus de ingestelde wachttijd en een zescijferige PIN. **Wacht vóór ontdooien** accepteert 0–72 uur; 0 voegt geen wachttijd toe.

Tijdens het bevriezen kan de wachttijd worden verlengd en kan een PIN worden toegevoegd als die ontbreekt. Deze voorwaarden kunnen niet worden versoepeld voordat de groep is ontdooid. Verwijderen vereist ook naleving van de resterende wachttijd en PIN.

### Gekoppelde groepen

Gebruik **Koppelen** om expliciet geselecteerde groepen in andere Vault-programma's te verbinden. Gekoppelde groepen delen hun naam, ondersteunde beleidsinstellingen, doelen, gebruik en bevriesvoorwaarden. Elk programma bewerkt en handhaaft de doeltypen die het ondersteunt; andere doelen blijven beschikbaar voor gekoppelde programma's. Ontkoppelen behoudt elke groep en de instellingen ervan.

Als een gekoppeld lid offline is, kan bewerken niet beschikbaar zijn. Open Mac Vault en de gekoppelde browser om opnieuw te verbinden. Een lokaal opgeslagen beleid kan actief blijven terwijl een lid offline is.

## Hulp krijgen

Klik op de kleine **i** naast een veld voor uitleg. Klik erbuiten of druk op Escape om te sluiten. Lijsten staan in schuifbare vakken; scroll in het vak voor meer items. Zoeken filtert de zichtbare lijst zonder items te verwijderen.

Aangepaste regels hebben een eigen [Codemanual](../code-manual/nl.md). Daarin staan de editor, activering, logboeken, bestandstoegang en de ondersteunde API uitgelegd.

## Native apps

Gebruik de +-kiezer van een Apps-doel om geïnstalleerde apps te selecteren. **Alle apps behalve deze blokkeren** maakt van de lijst een toestemmingslijst. Systeemapps, browsers en Vault zelf worden uitgesloten van blokkering van native apps.

Een geblokkeerde app krijgt een verzoek om af te sluiten. **Een geblokkeerde app elke (minuten) opnieuw vragen af te sluiten** regelt de nieuwe pogingen. Websiteomleidingen, paginapauzes en het verbergen van feeds worden door de browserextensie afgedwongen; het zijn geen native app-acties.

## Classifier

Een Classifier-groep tagt inhoud van toegewezen platforms met een eigen tagstructuur en modelinstellingen. Elk platform hoort bij één groep. Kies platforms bij het maken van de groep; daarna kunnen ze niet meer worden gewijzigd. Schema's en filters van blokkeergroepen sturen tagging niet.

Schakel tagging in bij de Classifier-instellingen. Gebruik **Tagging pauzeren / Tagging hervatten** apart per groep. Als je de platformfeedregistratie uitschakelt via **Activity → Registratie**, stopt ook tagging daarvan.

### Tags en modelinstellingen

Maak tags, beschrijf hun betekenis en stel bovenliggende tags in de tagstructuur in of verwijder ze. Sleep een tag om de tak te verplaatsen. Duidelijke beschrijvingen helpen het model vergelijkbare tags te onderscheiden. De instellingen van elke groep zijn onafhankelijk.

- **Snelheid ↔ Kwaliteit** kiest een lokaal modelniveau. Grotere modellen gebruiken meer geheugen; snelheid en resultaten hangen af van de Mac en werklast. Downloads worden door groepen gedeeld.
- **Strikt ↔ Breed** stelt betrouwbaarheidsvereisten en standaardaantallen tags in.
- **Minimumtags / Maximumtags** in Meer vervangen die standaardaantallen. Strikt ↔ Breed bepaalt nog steeds de betrouwbaarheid voor extra tags. Laat een veld leeg om de standaardwaarde te gebruiken.
- **Taginstructies** voegt optionele instructies voor deze groep toe.

Gewone Classifier-wijzigingen worden automatisch opgeslagen. Het gekozen niveau moet zijn gedownload voordat het inhoud kan taggen. Groepen met hetzelfde niveau delen een geladen model; maximaal twee niveaus blijven tegelijk geladen.

Corrigeer tags van inhoud in de browserextensie. Klik op **+ tag**, zoek bestaande Classifier-tags en kies er een om toe te voegen. Gebruik de verwijderknop van een tag of selecteer deze en druk eenmaal op Delete om te verwijderen. **Niet getagd** betekent dat tagging klaar is zonder tags; **Tagging** betekent dat een resultaat nog in behandeling is. Correcties helpen toekomstige tagging.

## Knowledge en webonderzoek

Knowledge bewaart korte beschrijvingen op deze Mac voor het lokale taggingmodel. **Inhoudsbronnen** omvat creators, accounts, kanalen en communities. Beschrijvingen van bronnen worden aan hun inhoud gekoppeld. **Bekende termen** gelden wanneer een term in een titel voorkomt.

Voeg een bron of term met beschrijving toe, of laat de beschrijving leeg om onderzoek aan te vragen wanneer dit is ingeschakeld. Creator-suggesties helpen een bron vinden die Classifier al heeft verzameld. Lijsten met zes of meer items hebben direct erboven een zoekveld: Terms en Content sources van elk platform hebben aparte zoekvelden voor naam, identificatie of beschrijving. Een beschrijving aanpassen werkt door in toekomstige tagging; bronkennis verwijderen verhindert niet dat onderzoek die later opnieuw aanmaakt.

### Een onderzoeksprovider instellen

1. Open **Classifier-instellingen → API keys & providers**.
2. Kies een providertype en **Provider toevoegen**. Dit maakt een configuratie aan, geen API key.
3. Vraag gegevens op bij de provider en voer ze in. Configureer bij een compatibel aangepast endpoint ook endpoint- en protocolvelden.
4. Kies in **Webonderzoek** een provider met ingebouwde web search. Haal de modellijst op en selecteer een onderzoeksmodel. Gebruik de zoekfunctie van de modelkiezer om de lijst te beperken; vernieuw om de lijst opnieuw op te halen.
5. Lees de toestemmingsmelding en schakel toestemming in. Kies per groep **Aan**, **Uit** of **Classifier-instellingen volgen**.

**Webonderzoek instellen…** opent de instellingen als configuratie ontbreekt. Een groep kan onderzoekstoestemming niet omzeilen. **Verbinding testen** bevestigt dat de testaanvraag is gelukt, niet dat elk model onderzoek ondersteunt. Het testmodel van een provider verschilt van het geselecteerde onderzoeksmodel.

Keys worden opgeslagen in de supportmap van de app op deze Mac, niet in de system Keychain. Ze verifiëren aanvragen bij de geconfigureerde provider; Vault uploadt ze niet naar een eigen server. Onderzoek stuurt opgeschoonde openbare onderwerpen naar de geselecteerde provider, geen privé-inhoud of samenvattingen. Lees de toestemmingsmelding voor de exacte verzonden fields. Providergebruik omvat ook verbindingstests en verzoeken voor modellijsten, naast onderzoek.

Onderzoeksstatus toont wachtrijverzoeken, afkoelperiodes voor nieuwe pogingen, fouten en tokengebruik van vandaag. **Mislukte onderwerpen nu opnieuw proberen** probeert geschikte fouten opnieuw; het omzeilt daglimieten of toestemming niet.

## Activity

Activity registreert lokaal ingeschakeld appgebruik, websitebezoeken en ondersteunde **Bekeken inhoud**. Grafieken tonen geregistreerde gegevens; een leeg gebied bewijst niet dat de Mac inactief was.

Kies een datumbereik. **Tijdlijn** toont gebruik op het tijdstip van de dag; **Totalen** telt duur op. **Tijdsinterval** combineert gebruik binnen elk interval tot verticale blokken. **Kleuren** is een aanklikbare legenda: selecteer een bron om de grafieken daarop te richten. Selecteer een dag om gebruik vanaf die dag te bekijken.

### Activity-groepen

Maak een groep om de geselecteerde apps en websites samen in Usage weer te geven. **Samenvoegen** gebruikt overal in Activity één naam en kleur voor de leden. Een Activity-groep ordent geregistreerd gebruik en staat los van een blokkeer- of Classifier-groep. Sla de editor van een Activity-groep expliciet op met **Opslaan**.

### Registratie en bewaren

Schakel in **Registratie** registratie in of uit per categorie of afzonderlijke bron. **Bewaren** bepaalt hoe lang geschiedenis wordt bewaard; **Voor altijd** bewaart deze zonder automatische vervaldatum. Individuele keuzes kunnen de bredere instelling volgen. Registratie uitschakelen stopt nieuwe gegevens; geschiedenis verwijderen verwijdert geregistreerde items.

Platformfeeds verzamelen inhoud die op ondersteunde platformpagina's wordt getoond, of deze nu geopend is of niet. Een feed met **Tagging ondersteund** kan Classifier voorzien van gegevens zolang registratie aanstaat. Bewaren van de feed beheert verzamelde inhoud apart van app- en websitegebruik. Een gepauzeerde Classifier-groep schakelt registratie niet zelf uit.

## Classifier-instellingen

**Tagpakketupdates** bepaalt wanneer geverifieerde tagpakketupdates ingaan: **Automatisch**, **Eerst vragen** of **Handmatig**. Dit staat los van het downloaden van het lokale model dat in een groep is gekozen. Modelbestanden worden van Hugging Face gedownload wanneer je **Downloaden** kiest; gebruik tijdens het downloaden de voortgang/status van de groep en **Annuleren**.

Kies de interfacetaal in Settings. Veldtoelichting is beschikbaar via de kleine Info-knoppen in de gekozen interfacetaal.

## Opslaan en problemen oplossen

Gewone Vault- en Classifier-wijzigingen worden automatisch opgeslagen. Een Activity-groep bewerken vereist **Opslaan**. Toevoegen, verwijderen, een model downloaden, verbinding testen en een modellijst ophalen blijven expliciete acties.

Ontbreken tags, controleer dan de browserverbinding, algemene tagging-schakelaar, pauzestatus van de groep, platformregistratie en modeldownload. Werkt onderzoek niet, controleer toestemming, groepskeuze, providergegevens, onderzoeksmodel en onderzoeksstatus. Kan een gekoppelde groep niet worden bewerkt, verbind de programma's opnieuw of hef het bevriezen op zoals aangegeven.
