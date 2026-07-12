# Informacje dotyczące funkcjonalności aplikacji komputerowej Vault

## Cel i granica

Jest to wiarygodne odniesienie do interfejsu aplikacji komputerowej Vault. Celowo oddzielono go od instrukcji rozszerzenia przeglądarki Vault.

Aplikacja komputerowa zarządza **aplikacjami natywnymi i oknami aplikacji**. Rozszerzenie przeglądarki zarządza stronami internetowymi, kartami przeglądarki i kanałami obsługiwanych platform internetowych. Mają te same pomysły — grupy, harmonogramy, liczniki czasu, zawieszanie, drzemki, reguły niestandardowe i opcjonalny most — ale nie mają tej samej powierzchni egzekwowania.

Ten dokument służy do konfigurowania, kontrolowania, odtwarzania lub utrzymywania zachowania aplikacji komputerowej. Kod jest kanoniczny, jeśli implementacja i niniejsza instrukcja różnią się.

## 1. Co aplikacja komputerowa może, a czego nie może kontrolować

Vault ocenia zasady skupienia dla wybranych aplikacji natywnych. Gdy dostępna jest natywna funkcja egzekwowania, może zastosować bieżący plan do pasujących celów aplikacji i zgłosić wynik osłony/stanu do interfejsu użytkownika hosta.

Może:

- tworzyć, włączać, wyłączać, zmieniać kolejność, importować, eksportować, zamrażać, odkładać i usuwać grupy;
- kieruj reklamy na aplikacje natywne wybrane za pomocą selektora aplikacji;
- zastosować natychmiastową blokadę, limit czasowy lub timer tylko naliczający;
- ograniczyć normalne grupy do dni powszednich i lokalnych okien czasowych;
- uruchamiaj niestandardowe reguły polityki JavaScript dla zdarzeń cyklu życia aplikacji;
- pokaż utworzone przez reguły natywne informacje o statusie/panelu za pośrednictwem hosta;
- zarządzaj opcjonalnym folderem lokalnym dla obsługiwanych żądań plików z regułami niestandardowymi;
- dołącz do kompatybilnych, wyraźnie połączonych grup za pośrednictwem lokalnego mostu Vault.

Nie może:

- działać jako rozszerzenie przeglądarki, sprawdzać DOM witryny internetowej lub manipulować kartami informacyjnymi przeglądarki;
- zagwarantować, że system operacyjny umożliwi kontrolowanie każdej aplikacji, procesu, okna lub usługi systemowej;
- zamień wybór aplikacji w zdalną administrację, nadzór urządzenia lub zaporę ogniową;
- sprawić, aby niestandardowe pomoce dostępne tylko w przeglądarce, takie jak DOM, nawigacja, przekierowanie lub kontrola kart, działały w natywnym środowisku wykonawczym;
- synchronizuj każdą grupę automatycznie tylko dlatego, że działa lokalny most.

## 2. Słownictwo

| Termin | Znaczenie |
| --- | --- |
| Grupa | Nazwany obiekt zasad fokusu. Nazwy grup muszą być unikalne w bieżącym punkcie końcowym Vault. |
| Cel | Natywna tożsamość aplikacji wybrana dla grupy. |
| Domyślna grupa aplikacji | Zwykła grupa, której celem są aplikacje natywne z selektora aplikacji. |
| Custom group | A group whose JavaScript rule reacts to application-policy events. |
| Dopasuj | Bieżąca aplikacja na pierwszym planie/działająca odpowiada włączonemu i aktywnemu celowi grupowemu lub warunkowi reguły niestandardowej. |
| Aktywny | Włączone, zgodnie z normalnym harmonogramem i nieaktywnie uśpione. |
| Plan wykonania | Wynikowa decyzja hosta natywnego o zezwoleniu/osłonie/statusie po ocenie odpowiednich grup. |
| Zamroź | Zabezpieczenie przed zwykłą modyfikacją grupy. |
| Odłóż | Tymczasowy wyjątek od normalnej polityki grupowej. |

## 3. Wybór tożsamości docelowej i aplikacji

Wybierz aplikacje za pomocą selektora **+** w domyślnej grupie aplikacji. Vault przechowuje znormalizowaną tożsamość oraz nazwę wyświetlaną.

| Gospodarz | Tożsamość docelowa używana do dopasowywania |
| --- | --- |
| macOS | Identyfikator pakietu aplikacji, jeśli jest dostępny. |
| Okna | Znormalizowana ścieżka pliku wykonywalnego lub nazwa procesu podana przez selektor aplikacji. |

Nazwa wyświetlana jest przeznaczona dla edytora. Znormalizowana wartość to tożsamość używana przez natywną warstwę wymuszania. Zmiana nazwy aplikacji w interfejsie użytkownika nie powoduje zmiany tożsamości. Cel może również zawierać znaczniki do użytku z regułami niestandardowymi.

Nie wpisuj adresu URL witryny w polu docelowym aplikacji i spodziewaj się egzekwowania zasad aplikacji natywnej. Użyj grupy witryn rozszerzenia do blokowania witryn.

## 4. Cykl życia i pierwszeństwo grupy

Nowa grupa jest domyślnie włączona. Lista grup obsługuje wybór, włączanie/wyłączanie, przeciąganie, dodawanie, czyszczenie, importowanie, eksportowanie i usuwanie. Wybrana grupa zostanie otwarta w edytorze.

Normalne zmiany w polach są zapisywane zgodnie z polityką automatycznego zapisywania edytora. Zamrożona grupa wyłącza zwykłe elementy sterujące edycją. Źródło niestandardowe jest inne: zapisanie tekstu nie powoduje jego uaktywnienia; **Uruchom** to operacja ładująca bieżące źródło do środowiska wykonawczego zasad.

Do tej samej aplikacji może pasować kilka grup. Vault ocenia zasady grupy w zapisanej kolejności i tworzy natywny plan egzekwowania. Zachowaj celowość nakładania się, szczególnie gdy grupy korzystają z różnych zasad czasowych lub reguły niestandardowe wydają decyzje dotyczące zezwolenia/zabezpieczenia. Zmień kolejność grup, aby zamierzone pierwszeństwo było jasne; nie polegaj na rozwiązywaniu konfliktów konfiguracyjnych w szczególnie przyjazny dla użytkownika sposób.

## 5. Normalne grupy aplikacji

### 5.1 Stan grupy

| Pole | Umowa funkcjonalna |
| --- | --- |
| Imię | Niepusty, przycięty, unikalny bez uwzględniania wielkości liter w tym punkcie końcowym. |
| Włączone | Grupy niepełnosprawne są zachowywane, ale nie biorą udziału w normalnym egzekwowaniu prawa. |
| Cele | Z selektora wybrano jedną lub więcej tożsamości aplikacji. |
| Zachowanie | Blokada natychmiastowa, blokada po zaliczeniu lub timer/odliczanie. |
| Harmonogram | Wybrane dni tygodnia i opcjonalne lokalne okna czasowe. |
| Zamroź | Brak, Zamrożone, Ściśle zamrożone lub Zamrożone rodzicielsko. |
| Odłóż | Zasady dotyczące tymczasowych wyjątków dla poszczególnych grup. |
| Komunikat awaryjny/stan | Wiadomość, którą może wyświetlić host natywny, gdy zastosuje odpowiedź tarczy/stanu. |

Pusta grupa domyślna nie ma wybranej aplikacji docelowej i dlatego nie pasuje do aplikacji jedynie na podstawie jej istnienia.

### 5.2 Zachowania blokujące

| Zachowanie | Wynik |
| --- | --- |
| Zablokuj natychmiast | Pasujący aktywny cel powoduje natychmiastową natywną decyzję o bloku/tarczy. |
| Blokuj po kilku minutach | Wykorzystanie wyrównawcze naliczane jest w ramach zasiłku grupowego. Po wyczerpaniu się limitu grupa wydaje natywną decyzję o blokowaniu/osłonie do czasu zresetowania okresu użytkowania lub innego stanu, który spowoduje, że grupa stanie się nieaktywna. |
| Timer (odliczanie, bez bloku) | Dopasowane użycie jest mierzone i może być wyświetlane, ale sam licznik czasu nigdy nie generuje blokady. |

Nowe grupy korzystają z 15-minutowego limitu i 24-godzinnego interwału resetowania, chyba że zostaną zmienione. Użycie ograniczone czasowo należy do grupy, więc wszystkie pasujące cele mają wspólne zasady grupy. Dokładna odpowiedź na blok jest implementowana przez hosta natywnego i jest ograniczona uprawnieniami systemu operacyjnego i obsługiwanym mechanizmem egzekwowania.

### 5.3 Harmonogramy

Harmonogramy obowiązują dla grup normalnych. Grupa niestandardowa podejmuje własne decyzje czasowe w JavaScript.

Wybierz dowolną kombinację dni od poniedziałku do niedzieli. Każde okno czasowe to jedna linia czasu lokalnego:

```text
0900-1200
1330-1730
```

Dokładny akceptowany format to HHMM-GGMM. Godziny muszą wynosić od 00 do 23, minuty od 00 do 59, a początek musi przypadać wcześniej niż koniec tego samego dnia. Okno zawiera jego początek i wyklucza koniec. Okna wychodzące poza północ nie są akceptowane. Puste okna oznaczają cały wybrany dzień.

Grupa normalna jest aktywna tylko wtedy, gdy:

1. jest włączony;
2. wybrany jest bieżący dzień tygodnia;
3. czas lokalny znajduje się w skonfigurowanym oknie lub grupa nie ma okien;
4. nie jest w stanie aktywnej drzemki.

### 5.4 Drzemka

Drzemka tymczasowo usuwa normalną grupę z aktywnego wymuszania. Jego fazy to:

| Faza | Wynik |
| --- | --- |
| Oczekuje | Żądanie istnieje, ale nie upłynęło opóźnienie aktywacji; grupa pozostaje aktywna. |
| Aktywny | Grupa jest tymczasowo nieaktywna przez czas drzemki. |
| Czas odnowienia | Drzemka dobiegła końca i grupa jest ponownie aktywna, ale nowa drzemka nie jest jeszcze dostępna. |

| Ustawienie | Zasada |
| --- | --- |
| Zezwalaj na drzemkę | Gdy jest wyłączona, grupy nie można normalnie uśpić. |
| Czas drzemki | Dodatnia liczba minut. Wartość domyślna dla nowej grupy to 30 minut. |
| Opóźnienie aktywacji | Zero lub więcej minut, zanim drzemka stanie się aktywna. |
| Czas odnowienia | Zerowanie do pięciu minut po zakończeniu aktywnej drzemki. |
| Potwierdzenia | Nieujemna liczba całkowita wymaganych interakcji potwierdzających. |

Aktywna drzemka jest tymczasowym wyjątkiem od zasad, a nie usunięciem lub odblokowaniem. Konfiguracja grupy pozostaje nienaruszona.

### 5.5 Zamrożenie

Zamrożenie to celowa bariera modyfikacji.

| Tryb | Umowa |
| --- | --- |
| Zamrożone | Zwykłe zmiany i zwykłe zmiany stanu pozostają zablokowane do czasu pomyślnego zakończenia procesu potwierdzania odblokowania produktu. |
| Ściśle mrożone | Grupy nie można odmrozić przed zakończeniem okresu ścisłego zamrożenia. Czas trwania jest dodatni i ograniczony do 72 godzin. |
| Rodzicielskie zamrożone | Do akcji blokowania/odblokowywania wymagane jest zarządzanie hasłami opiekuna. |

Wybór trybu w edytorze nie powoduje samodzielnego zamrożenia grupy; użyj akcji zamrożenia, aby ją zastosować. Grupa połączona mostkiem może również blokować skoordynowane kontrole zamrażania, gdy wymagany członek jest w trybie offline.

## 6. Natywne egzekwowanie i kontrola urządzeń

Edytor może dokładnie zapisać grupę, nawet jeśli system operacyjny nie umożliwił jej wymuszenia. Zawsze sprawdzaj **Ustawienia → Kontrola urządzeń** i stan natywny na żywo po zmianie uprawnień.

Host natywny decyduje, jakie działania są możliwe dla bieżącego systemu operacyjnego, aplikacji, okna i stanu uprawnień. Reguła może być poprawnie skonfigurowana, ale nie będzie miała widocznego efektu, gdy:

- Kontrola urządzeń nie została przyznana lub została cofnięta;
- grupa jest wyłączona, zaplanowana lub aktywnie odłożona;
- skupiony proces nie pasuje do wybranego znormalizowanego celu;
- system operacyjny odrzuca akcję dla tego celu;
- zależność mostu jest w trybie offline dla akcji wymagającej stanu skoordynowanego.

Nie traktuj udanego toastu zapisywania jako dowodu, że dostępne jest aktywne egzekwowanie. Przetestuj wybrany cel, gdy grupa jest aktywna i sprawdź stan hosta.

## 7. Grupy niestandardowe i natywne reguły polityki

Grupy niestandardowe działają w natywnym środowisku wykonawczym zasad JavaScript. Nie są to reguły niestandardowe przeglądarki. DOM przeglądarki, zakładka, nawigacja, przekierowanie adresu URL i kontrola kanału są celowo niedostępne.

### 7.1 Cykl życia źródła

Use a function expression:

```js
(events, helpers) => {
  events.on("focusEvent", "shield-focus", (event, h) => {
    if (event.target?.id) event.setResult(-1);
  });
}
```

Run loads the source and its event registrations. Running again unloads the old source and resets its rule-owned handlers, timers, panels, persistence, and dynamic app blocklist. A source that does not evaluate to a function cannot be loaded.

### 7.2 Wbudowane zdarzenia natywne

| Wydarzenie | Znaczenie |
| --- | --- |
| zaznaczWydarzenie | Okresowy tyk żywiciela. Opcja rejestracji interwałowej może ograniczyć szybkość obsługi. |
| licznik czasuKoniec | Odliczanie należące do reguły osiąga zero. |
| drzemkaNaciśnij | Użytkownik naciska przycisk Rozpocznij drzemkę dla grupy niestandardowej. |
| panelZdarzenie | Używana jest kontrolka panelu niestandardowego. |
| localFileEvent | Żądana akcja dotycząca folderu lokalnego została zakończona. |
| wydarzenie openApp | Zostanie otwarta śledzona aplikacja. |
| zamknij wydarzenie aplikacji | Śledzona aplikacja zostanie zamknięta. |
| focusWydarzenie | Aplikacja na pierwszym planie zmieni się w aplikację. |
| unfocusEvent | Aplikacja na pierwszym planie zmienia się z aplikacji. |
| minimalizujEvent / unminimizeEvent | Host zgłasza obsługiwane przejście minimalizujące okno. |
| switchAppEvent | Aplikacja na pierwszym planie zmienia się z jednej aplikacji na drugą. |
| aplikacjaChangedEvent | Ogólne wydarzenie dotyczące cyklu życia/zmiany aplikacji. |

Obiekt zdarzenia zawiera typ, identyfikator grupy/ID grupy, nazwę grupy, odpowiedniki adresu URL/nazwy hosta, czas, dane i cel. W przypadku aplikacji natywnej target udostępnia identyfikator, rodzaj, nazwę wyświetlaną, znormalizowaną wartość i znaczniki, gdy cel fokusowy pasuje do skonfigurowanego celu.

Dane zdarzeń cyklu życia aplikacji obejmują bieżący identyfikator/nazwę aplikacji, nazwę grupy, serializowaną migawkę uruchomionej aplikacji oraz wartości specyficzne dla zdarzenia, takie jak packageId, poprzedniAppId, currentAppId lub powód zmiany.

### 7.3 API zdarzeń i decyzje

Rejestr udostępnia funkcje włączania/rejestrowania, wyłączania/wyrejestrowywania, wyrejestrowywania wszystkich, liczników zarejestrowanych, getEvent i getEvents. Najpierw działa wyższy priorytet; równy priorytet zachowuje kolejność rejestracji. Rejestr ma limit liczby osób zajmujących się obsługą grupy.

Obiekt zdarzenia obsługuje:

| Metoda | Wynik |
| --- | --- |
| ustawWynik(-1) | Stwórz natywną decyzję o tarczy/bloku. Wynik w postaci ciągu staje się również blokiem natywnym, ponieważ reguły pulpitu nie mają celu przekierowania przeglądarki. |
| zezwolenie (powód) lub setResult (1) | Przygotuj decyzję zezwalającą na wydarzenie. |
| setShieldMessage(wiadomość) | Ustaw komunikat tarczy/stanu skierowany do człowieka dla bloku natywnego. |
| stopPropagation() | Zatrzymaj późniejsze procedury obsługi bieżącego zdarzenia. |
| zablokuj(appId), odblokuj(appId) | Dodaj/usuń dynamiczny blok aplikacji natywnej. |
| zamknij (identyfikator aplikacji), otwórz (identyfikator aplikacji) | Zażądaj obsługiwanej natywnej akcji zamykania/otwierania. |
| post(typ, dane) | Wyślij zagnieżdżone zdarzenie niestandardowe w natywnym środowisku wykonawczym. |

Środowisko wykonawcze aplikacji umożliwia korzystanie z liczników czasu, trwałości, paneli, dzienników, operacji na folderach lokalnych, pomocników okien aplikacji i narzędzi klasyfikatora adresów URL. Celowo traktuje pomocniki DOM, nawigację, przekierowania i karty przeglądarki jako niedostępne/obojętne.

### 7.4 Rodzimi pomocnicy

| Pomocnik | Zachowanie natywne |
| --- | --- |
| getLogHelper | Emituje decyzje dotyczące dziennika aplikacji/wyskakujących okienek/ekranu. |
| getTimerHelper | Tworzy liczniki czasu do przodu/do tyłu z granicami, krokami, predykatami zakresu/domeny, wstrzymaniem/wznowieniem, inspekcją stanu i przejściami timerEnded. Timery same w sobie nie chronią. |
| getPersistenceHelper | Stan JSON dla grupy: pobierz, ustaw, usuń, ma, klucze, wpisy, wyczyść, rozmiar. |
| getStorageHelper | Trwałość i symbole zastępcze żądań asynchronicznych hosta; nie zakładaj synchronicznej reakcji zewnętrznej. |
| getWindowHelper | Odczytuje bieżące/działające aplikacje i żąda zamknięcia/otwarcia/zablokowania/odblokowania akcji aplikacji. |
| getPanelHelper | Tworzy sprawdzone natywne migawki paneli, kontrolki, wbudowane procedury obsługi i reakcje na zdarzenia panelEvent. |
| getLocalFolderHelper | Kolejki umożliwiały względne operacje w plikach .txt, .csv i .json w ramach katalogu głównego przyznanego przez użytkownika. Zakończenie to localFileEvent. |
| getDomainHelper / getDomainUtility | Klasyfikatory adresów URL i platform dla reguł, które również uwzględniają wartości podobne do adresów URL. |
| getPlatformHelper / platforma | Klasyfikatory adresów URL pozostają dostępne; natywne wywołania sterujące kanałem RSS/DOM są obojętne, ponieważ host komputera stacjonarnego nie ma DOM witryny internetowej. |

Panele niestandardowe korzystają z tego samego deklaratywnego słownictwa sterującego, co środowisko wykonawcze przeglądarki: tekst, pole wyboru, zaznaczenie, wejście tekstowe, obszar tekstowy, przycisk, sekcja, licznik czasu, wejście liczbowe, zakres, przełącznik, radio, data, godzina, kolor, pin i oczyszczony kod HTML. Host natywny decyduje, jaka część panelu może być wyświetlana na bieżącej platformie.

## 8. Lokalny folder plików

Lokalny folder plików to opcjonalna granica przyznana przez użytkownika dla reguł niestandardowych. Reguły mogą żądać odczytów, zapisów, dołączeń, list, testów istnienia i operacji JSON w formacie tekstowym/CSV/JSON. Ścieżki zawsze odnoszą się do wybranego katalogu głównego. Ścieżki bezwzględne, segmenty przechodzenia, ukryte komponenty ścieżki, nieobsługiwane rozszerzenia i operacje poza katalogiem głównym są odrzucane.

Odwołaj folder, gdy reguła już go nie potrzebuje. Reguła musi obsługiwać niedostępne uprawnienia i nieudane wyniki zdarzenia localFileEvent; nie można zakładać, że wybrany folder pozostanie autoryzowany po ponownym uruchomieniu.

## 9. Mostek z aplikacją internetową

Mostek umożliwia opcjonalną lokalną synchronizację pomiędzy kompatybilnymi programami Vault. Natywna aplikacja komputerowa może hostować centrum lokalne; klienci łączą się pod obsługiwanym adresem lokalnym.

Stany połączenia to: Wyłączone, Łączenie, Rozłączone, Połączono/Uruchomione i Błąd. Podłączenie programu nie powoduje połączenia wszystkich grup. Użytkownik musi jawnie połączyć kwalifikujące się grupy pasujące.

Aby uzyskać link do grupy:

1. Uruchom natywny koncentrator w Ustawieniach.
2. Podłącz inny zgodny punkt końcowy Vault.
3. Utwórz pasujące, niezamrożone grupy o tej samej nazwie i typie.
4. W sekcji pomostu grupowego wybierz program i połącz grupę.

Połączona grupa tworzy klaster. Obsługiwane wspólne wartości zasad, użycie i stan drzemki mogą być synchronizowane, gdy członkowie są połączeni. Odłączenie wstrzymuje synchronizację i zachowuje grupy lokalne. Nie gwarantujemy przeniesienia elementów docelowych dostępnych tylko w przeglądarce, nieobsługiwanych działań niestandardowych i pól specyficznych dla platformy.

## 10. Importuj, eksportuj, resetuj i audytuj

Eksport zapisuje jedną zgodną reprezentację grupy. Import sprawdza/normalizuje zgodne dane grupy i nadal wymusza unikalność nazw lokalnych. Usuń grupę usuwa wybraną grupę i powiązany z nią stan. Wyczyść usuwa wszystkie grupy po potwierdzeniu. Przywrócenie ustawień domyślnych wpływa na globalne ustawienia edytora; wyeksportuj wszystko, co należy najpierw zachować.

Zanim zaczniesz polegać na regule dla komputerów stacjonarnych:

1. Sprawdź, czy kontrola urządzeń została przyznana.
2. Sprawdź znormalizowaną tożsamość wybranego celu.
3. Sprawdź stan włączenia, harmonogram, stan zamrożenia i fazę drzemki.
4. Przetestuj oddzielnie zachowanie natychmiastowe, czasowe i naliczanie.
5. W przypadku grupy niestandardowej uruchom dokładne źródło i przetestuj każde zarejestrowane zdarzenie aplikacji.
6. Sprawdź awarie folderów lokalnych oraz pomyślne operacje.
7. Sprawdź zachowanie mostu w trybie offline/połączonym, jeśli grupa jest połączona.

## 11. Uwagi dotyczące konkretnej platformy

Podstawowe koncepcje zasad są wspólne, ale natywne egzekwowanie zależy od hosta:

| macOS | Okna |
| --- | --- |
| Cele zwykle są rozpoznawane jako identyfikatory pakietów aplikacji. Kontrola urządzeń i egzekwowanie aktualnej bramy stanu uprawnień macOS. | Cele zwykle są rozpoznawane jako znormalizowana ścieżka pliku wykonywalnego lub nazwa procesu. Warstwa egzekwowania systemu Windows decyduje, którymi bieżącymi oknami/procesami można zarządzać. |

To odniesienie do komputerów stacjonarnych celowo nie opisuje list blokowania witryn, selektorów kanałów, klasyfikacji twórców YouTube, przekierowań przeglądarki ani działań na karcie przeglądarki. Należą one do podręcznika rozszerzenia Vault.
