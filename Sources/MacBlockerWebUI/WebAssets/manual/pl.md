# Podręcznik użytkownika Mac Vault

Mac Vault ma trzy strony: **Vault** blokuje aplikacje natywne, **Classifier** taguje obsługiwane treści przeglądarkowe, a **Activity** pokazuje zarejestrowane użycie. Rozszerzenie przeglądarki zbiera obsługiwane treści i stosuje blokowanie w przeglądarce. Zainstaluj je i połącz w używanej przeglądarce.

## Szybki start

1. W **Vault** dodaj grupę blokowania i cel Apps, a potem wybierz aplikacje za pomocą selektora +.
2. Wybierz zachowanie blokowania grupy i ją włącz.
3. W **Classifier** utwórz grupę, wybierz platformy i dodaj tagi z opisami.
4. Wybierz lokalny poziom modelu i w razie potrzeby go pobierz. Włącz tagowanie w ustawieniach Classifier i wznów grupę.
5. Otwórz obsługiwane treści w połączonej przeglądarce. Skonfiguruj filtr tagów w przeglądarkowej grupie blokowania, jeśli tagi mają sterować blokowaniem.

## Grupy blokowania

**Grupa blokowania** stosuje zasady blokowania. **Grupa Classifier** przypisuje tagi do treści; sama niczego nie blokuje.

1. Dodaj grupę blokowania i nadaj jej nazwę.
2. Wybierz cele w sekcji **Dotyczy**.
3. Wybierz, kiedy blokowanie ma obowiązywać, a następnie ustaw harmonogram lub dozwolony czas.
4. Włącz grupę. Jej cele współdzielą zasady grupy.

Zwykłe zmiany są zapisywane automatycznie. Błąd oznacza, że zmiana nie została zaakceptowana; popraw pole i spróbuj ponownie. Wyłącz grupę, aby wstrzymać jej zasady, zachowując konfigurację. **Usuń grupę** usuwa ją. Przeciągaj grupy, aby zmienić ich kolejność. Do celu może pasować kilka grup; odroczenie jednej nie znosi blokady innej.

**Eksportuj** kopiuje konfigurację grupy. **Importuj** zastępuje konfigurację wybranej grupy po potwierdzeniu.

### Dozwolony czas i harmonogram

**Blokuj natychmiast** obowiązuje, gdy włączona grupa pasuje i jej harmonogram jest aktywny. **Blokuj po wykorzystaniu dozwolonego czasu** zezwala na pasujące użycie, dopóki limit czasu się nie wyczerpie.

Ustaw dozwolony czas w minutach, a interwał resetowania w godzinach. Limit kroczący zlicza użycie w poprzedzającym go oknie. Reset o północy rozpoczyna nowy okres o lokalnej północy, również dla limitu kroczącego.

Wybierz aktywne dni tygodnia i opcjonalne lokalne przedziały czasu, po jednym w wierszu, np. **09:00-12:00**. Pusta lista przedziałów oznacza cały wybrany dzień. Przedział musi kończyć się później niż zaczyna tego samego dnia; harmonogram nocny rozdziel na osobne dni.

### Odroczenie

Skonfiguruj odroczenie w każdej grupie blokowania. **Wstrzymaj blokowanie** zawiesza zasady grupy na określony czas. **Dodaj do dozwolonego czasu** dodaje dostępne minuty do grupy z limitem czasu. Jako czas odroczenia liczy się tylko wykorzystany dodatkowy limit. Niewykorzystany dodatkowy czas wygasa przy następnym resecie; dla limitu kroczącego po jednym oknie albo wcześniej o północy, jeśli ta opcja jest włączona.

**Opóźnienie aktywacji** odracza odroczenie, gdy blokowanie nadal działa. **Przerwa** to czas oczekiwania od zakończenia odroczenia do następnej prośby. **Wymagane potwierdzenia** ustawia liczbę etapów potwierdzania. Odroczenie jest dostępne dla zamrożonej grupy tylko wtedy, gdy zezwolono na nie przed zamrożeniem.

### Zamrażanie i PIN

**Zamroź** uniemożliwia zwykłe zmiany. Odmrożenie wymaga dziesięciu potwierdzeń w odstępach pięciu sekund oraz skonfigurowanego czasu oczekiwania i sześciocyfrowego PIN-u. **Czekaj przed odmrożeniem** przyjmuje 0–72 godziny; 0 nie dodaje oczekiwania.

Podczas zamrożenia można wydłużyć czas oczekiwania i dodać PIN, jeśli go nie ma. Tych warunków nie można złagodzić przed odmrożeniem grupy. Usunięcie również wymaga odczekania pozostałego czasu i podania PIN-u.

### Połączone grupy

Użyj **Połącz**, aby połączyć jawnie wybrane grupy w innych programach Vault. Połączone grupy współdzielą nazwę, obsługiwane ustawienia zasad, cele, użycie i warunki zamrożenia. Każdy program edytuje i egzekwuje obsługiwane przez siebie typy celów; pozostałe wpisy celów są dostępne dla połączonych programów. Rozłączenie zachowuje każdą grupę i jej ustawienia.

Jeśli połączony członek jest offline, edycja może być niedostępna. Otwórz Mac Vault i połączoną przeglądarkę, aby połączyć się ponownie. Zapisane lokalnie zasady mogą nadal obowiązywać, gdy członek jest offline.

## Uzyskiwanie pomocy

Kliknij małe **i** obok pola, aby zobaczyć wyjaśnienie. Kliknij poza nim lub naciśnij Escape, aby zamknąć. Listy znajdują się w przewijanych polach; przewiń pole, aby zobaczyć więcej pozycji. Wyszukiwanie filtruje widoczną listę bez usuwania pozycji.

Reguły niestandardowe mają osobny [Podręcznik kodu](../code-manual/pl.md). Wyjaśnia on edytor, aktywację, dzienniki, dostęp do plików i obsługiwane API.

## Aplikacje natywne

Użyj selektora + celu Apps, aby wybrać zainstalowane aplikacje. **Blokuj wszystkie aplikacje poza tymi** zmienia listę w allowlistę. Aplikacje systemowe, przeglądarki i sam Vault są wyłączone z natywnego blokowania aplikacji.

Zablokowana aplikacja otrzymuje prośbę o zamknięcie. **Ponownie proś zablokowaną aplikację o zamknięcie co (minuty)** steruje ponawianiem. Przekierowania witryn, pauzy stron i ukrywanie feedów są egzekwowane przez rozszerzenie przeglądarki; nie stają się akcjami aplikacji natywnej.

## Classifier

Grupa Classifier taguje treści z przypisanych platform, korzystając z własnego drzewa tagów i ustawień modelu. Każda platforma należy do jednej grupy. Wybierz platformy podczas tworzenia grupy; później nie można ich zmienić. Harmonogramy i filtry grup blokowania nie sterują tagowaniem.

Włącz tagowanie w ustawieniach Classifier. Używaj osobno **Wstrzymaj tagowanie / Wznów tagowanie** dla każdej grupy. Wyłączenie rejestrowania feedu platformy w **Activity → Rejestrowanie** również zatrzymuje tagowanie tego feedu.

### Tagi i ustawienia modelu

Utwórz tagi, opisz ich znaczenie, ustaw lub usuń tagi nadrzędne w drzewie. Przeciągnij tag, aby przenieść jego gałąź. Jasne opisy pomagają modelowi rozróżniać podobne tagi. Ustawienia każdej grupy są niezależne.

- **Szybkość ↔ Jakość** wybiera lokalny poziom modelu. Większe modele zużywają więcej pamięci; szybkość i wyniki zależą od Mac i obciążenia. Pobrane modele są współdzielone między grupami.
- **Ścisłe ↔ Szerokie** ustawia wymagany poziom pewności i domyślną liczbę tagów.
- **Minimalna liczba tagów / Maksymalna liczba tagów** w Więcej zastępuje te liczby. Ścisłe ↔ Szerokie nadal steruje pewnością dodatkowych tagów. Zostaw pole puste, aby użyć wartości domyślnej.
- **Instrukcje tagowania** dodają opcjonalne wskazówki dla tej grupy.

Zwykłe zmiany Classifier zapisują się automatycznie. Wybrany poziom musi zostać pobrany przed tagowaniem treści. Grupy używające tego samego poziomu współdzielą załadowany model; jednocześnie załadowane mogą być najwyżej dwa poziomy.

Popraw tagi elementu treści w rozszerzeniu przeglądarki. Kliknij **+ tag**, wyszukaj istniejące tagi Classifier i wybierz jeden do dodania. Użyj przycisku usuwania tagu albo zaznacz go i raz naciśnij Delete. **Bez tagu** oznacza zakończone tagowanie bez tagów; **Tagowanie** oznacza wynik oczekujący. Poprawki usprawniają przyszłe tagowanie.

## Knowledge i badania w sieci

Knowledge przechowuje krótkie opisy na tym Mac dla lokalnego modelu tagowania. **Źródła treści** obejmują twórców, konta, kanały i społeczności. Opisy źródła towarzyszą jego treściom. **Znane terminy** mają zastosowanie, gdy termin występuje w tytule.

Dodaj źródło lub termin z opisem albo pozostaw opis pusty, aby zażądać badań po ich włączeniu. Sugestie twórców pomagają znaleźć źródło zebrane przez Classifier. Listy zawierające co najmniej sześć pozycji mają wyszukiwanie bezpośrednio nad nimi: Terms i Content sources każdej platformy mają osobne wyszukiwanie po nazwie, identyfikatorze lub opisie. Zmiana opisu wpływa na przyszłe tagowanie; usunięcie wiedzy o źródle nie uniemożliwia późniejszego odtworzenia jej przez badania.

### Konfigurowanie dostawcy badań

1. Otwórz **Ustawienia Classifier → API keys & providers**.
2. Wybierz typ dostawcy i **Dodaj dostawcę**. Tworzy to konfigurację; nie wydaje API key.
3. Uzyskaj dane logowania od dostawcy i wpisz je. Dla zgodnego niestandardowego endpointu skonfiguruj też pola endpoint i protocol.
4. W **Badaniach internetowych** wybierz dostawcę z wbudowanym web search. Pobierz listę modeli i wybierz model badawczy. Użyj wyszukiwania w selektorze modelu, aby zawęzić listę; odśwież ją, by pobrać ponownie.
5. Przeczytaj informację o zgodzie i ją włącz. W każdej grupie wybierz **Włącz**, **Wyłącz** lub **Zgodnie z ustawieniami Classifier**.

**Skonfiguruj badania internetowe…** otwiera ustawienia, gdy brakuje konfiguracji. Grupa nie może ominąć zgody na badania. **Testuj połączenie** potwierdza powodzenie żądania testowego, nie obsługę badań przez każdy model. Model testowy dostawcy różni się od wybranego modelu badawczego.

Keys są przechowywane w folderze support aplikacji na tym Mac, a nie w system Keychain. Uwierzytelniają żądania do skonfigurowanego dostawcy; Vault nie wysyła ich na własny serwer. Badania wysyłają oczyszczone publiczne tematy do wybranego dostawcy, nie treść prywatnych materiałów ani streszczenia. Przeczytaj informację o zgodzie, aby poznać dokładne wysyłane fields. Użycie dostawcy obejmuje testy połączenia i żądania listy modeli, nie tylko badania.

Status badań pokazuje żądania w kolejce, przerwy przed ponowieniem, błędy i dzienne użycie tokenów. **Ponów teraz nieudane tematy** ponawia kwalifikujące się błędy; nie omija dziennego limitu ani zgody.

## Activity

Activity lokalnie rejestruje użycie włączonych aplikacji, odwiedziny witryn i obsługiwane **Wyświetlone treści**. Wykresy odzwierciedlają zarejestrowane dane; pusty obszar nie dowodzi, że Mac był bezczynny.

Wybierz zakres dat. **Oś czasu** pokazuje użycie o danej porze dnia; **Sumy** sumują czas. **Przedział czasu** grupuje użycie w każdym przedziale w pionowe bloki. **Kolory** to klikalna legenda: wybierz źródło, aby skupić na nim wykresy. Wybierz dzień, aby zobaczyć użycie od tego dnia.

### Grupy Activity

Utwórz grupę, aby razem wyświetlić wybrane aplikacje i witryny w Usage. **Scal** używa jednej nazwy i koloru dla elementów w całym Activity. Grupa Activity porządkuje zarejestrowane użycie; jest odrębna od grupy blokowania lub Classifier. Zapisz edytor grupy Activity jawnie przyciskiem **Zapisz**.

### Rejestrowanie i przechowywanie

W sekcji **Rejestrowanie** włącz lub wyłącz rejestrowanie każdej kategorii lub źródła. **Przechowuj** określa, jak długo zachowywana jest historia; **Bezterminowo** zachowuje ją bez automatycznego wygaśnięcia. Ustawienia indywidualne mogą stosować szersze ustawienie. Wyłączenie rejestrowania zatrzymuje nowe wpisy; usunięcie historii usuwa zapisane pozycje.

Feedy platform zbierają treści pokazywane na obsługiwanych stronach platform, otwartych lub nie. Feed z etykietą **Obsługa tagowania** może dostarczać dane Classifier, gdy rejestrowanie jest włączone. Jego przechowywanie kontroluje zebrane treści niezależnie od użycia aplikacji i witryn. Wstrzymana grupa Classifier sama nie wyłącza rejestrowania.

## Ustawienia Classifier

**Aktualizacje pakietów tagów** określają, kiedy zweryfikowane aktualizacje pakietu tagów wchodzą w życie: **Automatycznie**, **Zapytaj najpierw** lub **Ręcznie**. To osobne od pobierania lokalnego modelu wybranego w grupie. Pliki modelu są pobierane z Hugging Face po wybraniu **Pobierz**; podczas pobierania używaj statusu/postępu grupy i przycisku **Anuluj**.

Wybierz język interfejsu w Settings. Objaśnienia pól są dostępne po kliknięciu małych przycisków Info w wybranym języku interfejsu.

## Zapisywanie i rozwiązywanie problemów

Zwykłe zmiany Vault i Classifier zapisują się automatycznie. Edycja grupy Activity wymaga użycia **Zapisz**. Dodawanie, usuwanie, pobieranie modelu, testowanie połączenia i pobieranie listy modeli są jawnymi czynnościami.

Jeśli brakuje tagów, sprawdź połączenie przeglądarki, globalny przełącznik tagowania, stan wstrzymania grupy, rejestrowanie platformy i pobranie modelu. Jeśli badania nie działają, sprawdź zgodę, wybór grupy, dane dostawcy, model badawczy i status badań. Jeśli nie można edytować połączonej grupy, połącz ponownie programy lub odmroź grupę zgodnie z komunikatem.
