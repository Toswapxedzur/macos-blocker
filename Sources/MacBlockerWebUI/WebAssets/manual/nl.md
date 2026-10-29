# Mac Vault-gebruikershandleiding

Mac Vault heeft drie pagina’s: **Vault** blokkeert native apps, **Content taggen** tagt ondersteunde browserinhoud en **Activiteit** toont vastgelegd gebruik. De browserextensie verzamelt ondersteunde inhoud en past browserblokkeringen toe. Installeer en verbind haar in de browser die je gebruikt.

## Snelstart

1. Voeg in **Vault** een blokkeergroep en een Apps-doel toe en kies apps met de + kiezer.
2. Kies het blokkeergedrag en schakel de groep in.
3. Maak in **Content taggen** een groep, kies de platforms en voeg tags met beschrijvingen toe.
4. Kies in Instellingen → **AI-verbindingen** ChatGPT subscription, OpenAI API, Gemini API of Grok API. Verbind het account of voer de sleutel in en haal modellen op; kies daarna een verbinding/model in de groep. Schakel tagging in en hervat de groep.
5. Open ondersteunde inhoud in de verbonden browser. Stel een tagfilter in een browser-blokkeergroep in als tags de blokkering moeten bepalen.

## Blokkeergroepen

Een **blokkeergroep** past een blokkeerbeleid toe. Een **Content taggen** kent tags toe en blokkeert zelf niets. Voeg de groep toe en geef haar een naam, kies doelen onder **Van toepassing op**, bepaal wanneer blokkeren geldt en stel planning of tijdslimiet in; schakel daarna de groep in. Gewone wijzigingen worden automatisch opgeslagen. Een fout betekent dat de wijziging niet is geaccepteerd; herstel het veld en probeer opnieuw. Uitschakelen stopt het beleid en behoudt de configuratie; **Groep verwijderen** verwijdert de groep. Sleep groepen om ze te ordenen. Meerdere groepen kunnen hetzelfde doel raken; snooze van één groep heft een blokkering van een andere niet op. **Exporteren** kopieert de configuratie; **Importeren** vervangt die van de gekozen groep na bevestiging.

### Tijdslimiet en planning

**Block immediately** blokkeert wanneer de ingeschakelde groep overeenkomt en de planning actief is. **Block when the time allowance is used** staat gebruik toe tot de limiet op is. Stel de limiet in minuten en de resetperiode in uren in. Een rollende limiet telt gebruik in het voorafgaande venster. Een reset om middernacht begint een nieuwe lokale periode, ook voor rollende limieten. Kies actieve weekdagen en optionele lokale tijdvensters, één per regel, zoals **09:00-12:00**. Zonder vensters geldt de instelling de hele gekozen dag. Een venster moet op dezelfde dag later eindigen dan het begint; verdeel een nachtplanning over aparte dagen.

### Pauzeren

Stel snooze per blokkeergroep in. **Pause blocking** onderbreekt het groepsbeleid gedurende de pauze. **Add to the time allowance** voegt bruikbare minuten toe aan een groep met een tijdslimiet. Alleen verbruikte extra limiet telt als snoozetijd. Ongebruikte extra limiet vervalt bij de volgende reset; bij een rollende limiet na één venster of eerder om middernacht als dat is ingeschakeld. **Activation delay** stelt snooze uit terwijl blokkeren doorgaat. **Cooldown** is de wachttijd na snooze voordat een nieuw verzoek kan volgen. **Required confirmations** bepaalt het aantal bevestigingen. Snooze is bij een bevroren groep alleen beschikbaar als dit vóór het bevriezen is toegestaan.

### Freeze en PIN

**Freeze** verhindert gewone wijzigingen. Ontdooien vereist tien bevestigingen met vijf seconden ertussen, plus de ingestelde wachttijd en een PIN van zes cijfers. **Wait before unfreezing** accepteert 0–72 uur; 0 voegt geen wachttijd toe. Tijdens freeze kan de wachttijd worden verlengd en een ontbrekende PIN worden toegevoegd; voorwaarden kunnen pas na ontdooien worden versoepeld. Verwijderen houdt ook rekening met resterende wachttijd en PIN.

### Gekoppelde groepen

Gebruik **Koppelen** om expliciet geselecteerde groepen uit andere Vault-programma’s te verbinden. Ze delen naam, ondersteunde beleidsinstellingen, doelen, gebruik en freeze-voorwaarden. Elk programma wijzigt en handhaaft alleen ondersteunde doeltypen; andere doelen blijven beschikbaar voor gekoppelde programma’s. **Ontkoppelen** verbreekt de koppeling maar behoudt de groep en instellingen. Is een lid offline, open Mac Vault en de gekoppelde browser om opnieuw te verbinden. Lokaal opgeslagen beleid kan offline actief blijven.

## Hulp

Klik op de kleine **i** naast een veld voor uitleg; klik erbuiten of druk op Escape om te sluiten. Lijsten staan in scrollbare vakken; zoeken filtert zichtbare items zonder ze te verwijderen. Het [Codehandboek](../code-manual/nl.md) voor aangepaste regels legt editor, activering, logboeken, bestandstoegang en API uit.

## Native toepassingen

Gebruik de + kiezer van een Apps-doel voor geïnstalleerde of actieve apps. Open de kiezer opnieuw om de lijst te vernieuwen nadat je een app uit een andere map hebt gestart. **Alle apps blokkeren behalve de apps in deze lijst** maakt de lijst een allowlist. Mac Vault kan gewone Apple-apps en volledige browsers blokkeren; Mac Vault zelf en apps met dezelfde bundle identifier blijven beschermd. Een geblokkeerde app krijgt een verzoek om te stoppen; **Ponownie proś zablokowaną aplikację o zamknięcie co (minuty)** bepaalt herhaling. Websiteomleidingen, paginapauzes en feed verbergen worden door de browserextensie afgehandeld, niet als native app-acties.

## Inhoud taggen

Elke Content taggen-groep tagt inhoud van de toegewezen platforms met een eigen tagboom en modelinstellingen. Elk platform hoort bij één groep; kies platforms bij het maken, later wijzigen kan niet. Planningen en filters van blocking groups bepalen tagging niet. Schakel tagging in Instellingen in en gebruik **Taggen pauzeren / Taggen hervatten** per groep. Het uitschakelen van feedopname onder **Activiteit → Registratie** stopt ook tagging van die feed.

### Tags en modelinstellingen

Maak tags, beschrijf hun betekenis en stel ouders in de boom in of verwijder ze. Sleep een tag om de tak te verplaatsen. Duidelijke beschrijvingen helpen het model vergelijkbare tags onderscheiden. Instellingen zijn per groep onafhankelijk. **Minimale tagzekerheid** stelt het vereiste bewijsniveau in van 1 tot 5; nieuwe groepen beginnen op 4 (sterke steun). Er is geen doel voor het aantal tags; een item kan geen tags krijgen. **Taginstructies** bewaart groepsvoorkeuren. Gewone wijzigingen worden automatisch opgeslagen; elke groep gebruikt één expliciet gekozen verbinding, model en reasoning effort.

### AI-verbindingen

Instellingen biedt ChatGPT subscription, OpenAI API, Gemini API en Grok API. De ChatGPT-subscriptie gebruikt Vault-aanmelding en een geschikt plan. API-sleutels vallen onder facturering en limieten van de gekozen provider. Kies de provider en voer de sleutel direct onder de gedeelde keuzelijst in. Wijzigingen worden automatisch opgeslagen; het veld leegmaken verwijdert de sleutel. **Modellijst ophalen** haalt modellen op, maar kiest er geen; selecteer daarna een model in de Content taggen- of custom-rule-groep.

**Redeneerniveau** bepaalt hoeveel het model nadenkt: Model default, Low, Medium of High waar ondersteund. Nieuwe keuzes beginnen op Medium; bestaande blijven opgeslagen. Meer inspanning kan tijd en tokens kosten. Web search is voor tagging altijd ingeschakeld; het model bepaalt wanneer het die gebruikt. Kies een model dat zoeken en gestructureerde tagging ondersteunt. Mislukte of niet-beschikbare verzoeken behouden geldige cache-resultaten; nieuwe items blijven onopgelost tot **Cloudclassificatie opnieuw proberen**. Vault wisselt niet automatisch van provider. Elke verbinding heeft een eigen retry-interval en pogingslimiet. Corrigeer tags in de browserextensie met **+ tag**; verwijder via de verwijderknop of selecteer een tag en druk eenmaal op Delete. **Geen tag** betekent klaar zonder tags; **Taggen** betekent dat het resultaat wacht. Je correctie is leidend voor dat item.

## Activiteit

Activiteit legt lokaal gebruik van ingeschakelde apps, websitebezoeken en ondersteunde **Bekeken inhoud** vast. Grafieken tonen vastgelegde gegevens; een leeg gebied bewijst niet dat de Mac inactief was. Kies een periode. **Tijdlijn** toont gebruik per tijdstip; **Totalen** telt duur op; **Tijdsinterval** bundelt gebruik in verticale blokken per interval. **Kleuren** is een klikbare legenda waarmee je een bron kiest om grafieken daarop te richten. Kies een dag om gebruik vanaf die dag te zien.

### Activiteit-groepen

Maak een groep om gekozen apps en websites samen in Usage te tonen. **Merge** gebruikt in heel Activiteit één naam en kleur voor leden. Een Activiteit-groep ordent vastgelegd gebruik en staat los van blocking- en tagging-groepen. Sla de editor expliciet op met **Save**.

### Registratie en bewaartermijn

Schakel onder **Registratie** opname per categorie of bron in of uit. **Bewaren** bepaalt de bewaartermijn; **Altijd** voorkomt automatische vervaldatum. Individuele keuzes kunnen de bredere instelling volgen. Opname uitschakelen stopt nieuwe opnamen; geschiedenis verwijderen wist vastgelegde items. Platformfeeds verzamelen inhoud die op ondersteunde pagina’s wordt getoond, ook als de pagina niet is geopend. Een feed met **Taggen ondersteund** kan Content taggen voeden zolang opname aanstaat. De bewaartermijn ervan staat los van app- en websitegebruik. Een tagging-groep pauzeren stopt opname niet vanzelf.

## Instellingen

Kies de interfacetaal in Instellingen. Veldverklaringen zijn beschikbaar via Info-knoppen in de gekozen taal.

## Opslaan en problemen oplossen

Gewone Vault- en Content taggen-wijzigingen worden automatisch opgeslagen; de Activiteit-groepeditor vereist **Save**. Toevoegen, verwijderen, verbinding testen en modellen ophalen zijn expliciete acties. Ontbreken tags, controleer browserverbinding, globale tagging-schakelaar, groepspauze, platformopname, gekozen verbinding/model en inloggegevens. Controleer bij mislukte AI-verzoeken ook providerlimieten en het groepslogboek. Kan een gekoppelde groep niet worden bewerkt, verbind programma’s opnieuw of hef freeze op zoals aangegeven.
