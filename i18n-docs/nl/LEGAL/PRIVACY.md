# Adamancia Vault-privacybeleid

Laatst bijgewerkt: 7 juli 2026

Adamancia Vault is een focus- en blokkeerapp. Dit beleid beschrijft de release van de macOS-app.

## Samenvatting

Adamancia Vault is ontworpen om blokkeerregels en gebruiksstatus standaard lokaal op uw Mac te houden. De app verkoopt geen persoonlijke gegevens, geeft geen advertenties weer en deelt geen persoonlijke gegevens met datamakelaars.

## Gegevens lokaal opgeslagen

De app kan de volgende lokale gegevens op uw Mac opslaan:

- Blokkeren van groepen, schema's, timers, bevriezings-/sluimerstatus en app-instellingen.
- Lokale webeditoropslag gespiegeld vanuit de gebundelde webinterface.
- Lokale bridge-/linkstatus wanneer u de macOS-app verbindt met browserextensies.
- App-handhavingsbeleidsbestanden die worden gebruikt door de macOS-blokkeerengine.
- App Group-containergegevens wanneer een App Store-build of extensie-build een App Group gebruikt.

Bekende lokale paden zijn gedocumenteerd in `RELEASE.md` en in het verwijderprogrammascript.

## Netwerkgebruik

De app kan een lokale netwerklistener openen voor de web-app-bridge, zodat browserextensies verbinding kunnen maken met de Mac-app. De app kan ook netwerkverzoeken doen als een gebundelde functie moet communiceren met Adamancia-services, bijvoorbeeld optionele account- of synchronisatiegerelateerde functies.

## Analytics en advertenties

De macOS-app bevat geen advertentie-SDK's van derden. Er mogen geen analyses worden verzonden, tenzij een functie expliciet aangeeft dat er gebruik wordt gemaakt van een online service.

## Optionele accounts en synchronisatie

Als account- of synchronisatiefuncties zijn ingeschakeld in een release, verzenden deze functies mogelijk de minimale gegevens die nodig zijn om die functie te bieden, zoals accountidentiteit en synchronisatiepayloads. Voor downloads en lokale blokkering is geen account vereist.

## Machtigingen

Afhankelijk van het kanaal en de ingeschakelde functies kan Adamancia Vault macOS vragen om machtigingen zoals toegankelijkheid, netwerktoegang, registratie van inlogitems of toegang tot app-groepen. Deze machtigingen worden gebruikt om functies voor blokkeren, het starten van apps, overbruggen en persistentie te bieden.

## Verwijderen

De DMG bevat `uninstall.command`. Het vraagt ​​om bevestiging, sluit de app af als deze actief is, maakt de registratie van het inlogitem van de app ongedaan indien mogelijk, verwijdert `/Applications/AdamanciaVault.app` en verwijdert optioneel alleen bekende bestanden die door deze app zijn gemaakt.

## Contactpersoon

Voor privacyvragen opent u een issue in de openbare GitHub-repository of gebruikt u het contactkanaal dat is gepubliceerd op de Adamancia Vault-website.
