# Podręcznik użytkownika Mac Vault

Mac Vault ma trzy strony: **Vault** blokuje natywne aplikacje, **Tagowanie treści** oznacza obsługiwane treści przeglądarki, a **Aktywność** pokazuje zarejestrowane użycie. Rozszerzenie przeglądarki zbiera obsługiwane treści i egzekwuje blokady w przeglądarce. Zainstaluj je i połącz w używanej przeglądarce.

## Szybki start

1. W **Vault** dodaj grupa bloków i cel Apps, a następnie wybierz aplikacje przyciskiem +.
2. Wybierz sposób blokowania i włącz grupę.
3. W **Tagowanie treści** utwórz grupę, wybierz jej platformy i dodaj tagi z opisami.
4. W Ustawienia → **Połączenia AI** wybierz ChatGPT subscription, OpenAI API, Gemini API lub Grok API. Połącz konto albo wpisz klucz i pobierz modele, a następnie wybierz połączenie/model w grupie. Włącz tagowanie i wznów grupę.
5. Otwórz obsługiwane treści w połączonej przeglądarce. Ustaw filtr tagów w browser grupa bloków, jeśli tagi mają sterować blokowaniem.

## Grupy blokowania

**Grupa bloków** stosuje politykę blokowania. **Tagowanie treści** przypisuje tagi i samodzielnie niczego nie blokuje. Dodaj i nazwij grupę, wybierz cele w **Dotyczy**, określ warunki blokowania i harmonogram lub limit czasu, a następnie włącz grupę. Zwykłe zmiany zapisują się automatycznie. Błąd oznacza, że zmiana nie została przyjęta; popraw pole i spróbuj ponownie. Wyłączenie grupy zatrzymuje politykę, zachowując konfigurację; **Usun grupe** usuwa grupę. Przeciągaj grupy, by zmienić kolejność. Kilka grup może dotyczyć tego samego celu; snooze jednej nie znosi blokady innej. **Eksportuj** kopiuje konfigurację; **Importuj** po potwierdzeniu zastępuje konfigurację wybranej grupy.

### Limit czasu i harmonogram

**Block immediately** blokuje, gdy aktywna grupa pasuje, a harmonogram obowiązuje. **Block when the time allowance is used** pozwala korzystać do wyczerpania limitu. Ustaw limit w minutach, a reset w godzinach. Limit kroczący liczy użycie z poprzedniego okna. Reset o północy rozpoczyna nowy okres według czasu lokalnego, również dla limitu kroczącego. Wybierz aktywne dni tygodnia i opcjonalne lokalne przedziały czasu, po jednym w wierszu, np. **09:00-12:00**. Pusta lista oznacza cały wybrany dzień. Przedział musi kończyć się później tego samego dnia; nocny harmonogram podziel na dni.

### Pauza

Skonfiguruj snooze w każdej grupa bloków. **Pause blocking** zawiesza politykę na czas pauzy. **Add to the time allowance** dodaje używalne minuty do grupy z limitem czasu. Jako czas snooze liczy się tylko wykorzystany dodatek. Niewykorzystany wygasa przy następnym resecie; dla limitu kroczącego po jednym oknie lub wcześniej o północy, jeśli włączono reset. **Activation delay** opóźnia snooze, gdy blokowanie nadal trwa. **Cooldown** to oczekiwanie po snooze przed kolejnym żądaniem. **Required confirmations** ustala liczbę potwierdzeń. Snooze w zamrożonej grupie jest dostępne tylko wtedy, gdy zezwolono na nie przed zamrożeniem.

### Freeze i PIN

**Freeze** blokuje zwykłe edycje. Odmrożenie wymaga dziesięciu potwierdzeń co pięć sekund, skonfigurowanego oczekiwania i sześciocyfrowego PIN-u. **Wait before unfreezing** przyjmuje 0–72 godziny; 0 oznacza brak oczekiwania. Podczas zamrożenia można wydłużyć oczekiwanie i dodać brakujący PIN, ale warunków nie można złagodzić przed odmrożeniem. Usunięcie także respektuje pozostały czas i PIN.

### Połączone grupy

**Połącz** łączy jawnie wybrane grupy z innych programów Vault. Wspólne są nazwa, obsługiwane ustawienia polityki, cele, użycie i warunki freeze. Każdy program edytuje i egzekwuje obsługiwane typy celów; pozostałe cele pozostają dostępne połączonym programom. **Rozłącz** rozłącza, zachowując grupy i ustawienia. Jeśli członek jest offline, otwórz Mac Vault i połączoną przeglądarkę, aby się połączyć. Lokalna zapisana polityka może działać offline.

## Pomoc

Kliknij małe **i** przy polu, aby zobaczyć objaśnienie; kliknij poza nim lub naciśnij Escape, aby zamknąć. Listy mieszczą się w przewijanych polach; wyszukiwanie filtruje widok bez usuwania wpisów. [Podręcznik kodu](../code-manual/pl.md) opisuje edytor reguł niestandardowych, aktywację, logi, dostęp do plików i API.

## Aplikacje natywne

Użyj selektora + celu Apps, by wybrać zainstalowane lub uruchomione aplikacje. Otwórz selektor ponownie, aby odświeżyć listę po uruchomieniu aplikacji z innego folderu. **Blokuj wszystkie aplikacje poza wymienionymi tutaj** zmienia listę w allowlist. Mac Vault może blokować zwykłe aplikacje Apple i całe przeglądarki; Mac Vault oraz aplikacje z tym samym bundle identifier są chronione. Zablokowana aplikacja otrzymuje prośbę o zamknięcie; **Ponownie proś zablokowaną aplikację o zamknięcie co (minuty)** określa ponowienia. Przekierowania stron, pauzy i ukrywanie feedów egzekwuje rozszerzenie przeglądarki, nie aplikacja natywna.

## Oznaczanie treści

Grupa taguje treści z przypisanych platform przy użyciu własnego drzewa tagów i ustawień modelu. Każda platforma należy do jednej grupy; wybierz je przy tworzeniu, później nie można ich zmienić. Harmonogramy i filtry blokowania nie sterują tagowaniem. Włącz tagowanie w Ustawienia; używaj **Wstrzymaj tagowanie / Wznów tagowanie** osobno dla każdej grupy. Wyłączenie nagrywania feedu w **Aktywność → Nagrywanie** także zatrzymuje jego tagowanie.

### Tagi i ustawienia modelu

Twórz tagi, opisuj ich znaczenie i ustawiaj lub usuwaj rodziców w drzewie. Przeciąganie przenosi gałąź. Jasne opisy pomagają modelowi rozróżniać podobne tagi. Ustawienia grup są niezależne. **Minimalna pewność tagu** określa wymagany poziom dowodów 1–5; nowe grupy zaczynają od 4 (silne wsparcie). Nie ma docelowej liczby tagów; element może nie otrzymać żadnego. **Instrukcje tagowania** zapisuje preferencje grupy. Zwykłe zmiany zapisują się automatycznie; każda grupa używa jawnie wybranego połączenia, modelu i reasoning effort.

### Połączenia AI

Ustawienia zawiera ChatGPT subscription, OpenAI API, Gemini API i Grok API. Subskrypcja korzysta z logowania Vault i kwalifikującego się planu. Klucze API podlegają rozliczeniom i limitom wybranego dostawcy. Wybierz dostawcę i wpisz klucz pod wspólną listą; zmiany zapisują się automatycznie, wyczyszczenie pola usuwa klucz. **Pobierz listę modeli** pobiera modele, ale nie wybiera żadnego; wybierz go w grupie tagowania lub custom-rule.

**Poziom rozumowania** określa poziom rozumowania modelu: Model default, Low, Medium lub High, jeśli obsługiwane. Nowe wybory zaczynają od Medium; istniejące pozostają zapisane. Wyższy poziom może zużyć więcej czasu i tokenów. Web search jest zawsze włączone dla tagowania; model decyduje, kiedy go użyć. Wybierz model obsługujący wyszukiwanie i ustrukturyzowane tagowanie. Nieudane lub niedostępne żądania zachowują prawidłowe wyniki cache; nowe elementy pozostają nierozstrzygnięte do **Ponów klasyfikację w chmurze**. Vault nie przełącza dostawcy automatycznie; każde połączenie ma własny odstęp i limit prób. W rozszerzeniu popraw tagi przez **+ tag**, wyszukanie i wybór; usuń przyciskiem usuwania lub wybierz tag i naciśnij Delete raz. **Bez tagu** oznacza zakończenie bez tagów; **Tagowanie** oznacza oczekujący wynik. Twoja korekta jest wiążąca dla elementu.

## Aktywność

Aktywność lokalnie zapisuje użycie włączonych aplikacji, odwiedziny witryn i obsługiwane **Wyświetlone treści**. Wykresy pokazują zapisane dane; pusty obszar nie dowodzi bezczynności Maca. Wybierz zakres dat. **Oś czasu** pokazuje godziny, **Sumy** sumuje czas, **Przedział czasu** łączy użycie z przedziałów w pionowe bloki. **Kolory** to klikalna legenda; wybierz źródło, by skupić wykresy. Wybierz dzień, aby zobaczyć użycie od niego.

### Grupy Aktywność

Utwórz grupę, by pokazać wybrane aplikacje i witryny razem w Usage. **Merge** stosuje jedną nazwę i kolor dla członków w całym Aktywność. Grupa porządkuje zapisane użycie i jest odrębna od grup blokowania i tagowania. Zapisz edytor jawnie przyciskiem **Save**.

### Nagrywanie i przechowywanie

W **Nagrywanie** włączaj lub wyłączaj nagrywanie kategorii albo źródeł. **Zachowaj** określa czas przechowywania historii; **Zawsze** nie wygasa automatycznie. Ustawienia pojedyncze mogą dziedziczyć szersze. Wyłączenie nagrywania zatrzymuje nowe dane; usunięcie historii usuwa zapisane wpisy. Feedy platform zbierają treści wyświetlone na obsługiwanych stronach, otwartych lub nie. Feed **Tagowanie obsługiwane** może zasilać Tagowanie treści, gdy nagrywanie jest włączone. Jego retencja jest niezależna od użycia aplikacji i stron. Wstrzymanie grupy tagowania samo nie wyłącza nagrywania.

## Ustawienia

W Ustawienia wybierz język interfejsu. Objaśnienia pól są dostępne przez przyciski Info w tym języku.

## Zapisywanie i rozwiązywanie problemów

Zwykłe zmiany Vault i Tagowanie treści zapisują się automatycznie; edytor Aktywność wymaga **Save**. Dodawanie, usuwanie, test połączenia i pobranie modeli to jawne działania. Jeśli brakuje tagów, sprawdź połączenie przeglądarki, globalny przełącznik tagowania, pauzę grupy, nagrywanie platformy, wybrane połączenie/model i dane uwierzytelniające. Przy błędach AI sprawdź też limity dostawcy i Log grupy. Jeśli nie można edytować połączonej grupy, połącz ponownie programy lub odmroź ją zgodnie z komunikatem.
