# Skarbiec Maca

Mac Vault jest natywnym członkiem rodziny produktów Vault w systemie macOS. Łączy w sobie silnik reguł Swift, edytor WebView, natywny spis aplikacji i adaptery egzekwowania, obsługę niestandardowych reguł oraz lokalny hub aplikacji internetowych.

Obowiązujący kodeks jest źródłem prawdy. Odniesienie do aplikacji w języku angielskim to [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md).

## Co zostało zaimplementowane

- Grupy domyślne dla wybranych aplikacji macOS i grupy niestandardowe dla zaawansowanych reguł zasad.
- Tryby blokowania natychmiastowego, zasiłku i odliczania.
- Harmonogramy, tryby zamrażania, przepływy drzemki, import/eksport i trwały stan grupy.
— Spis aplikacji, stan uprawnień do kontroli urządzeń, natywne adaptery wymuszające i pływająca powierzchnia stanu.
- Kontrolowane środowisko wykonawcze zasad JavaScript z rejestrowaniem i sprawdzaniem składni.
- Koncentrator mostowy WebSocket z pętlą zwrotną dla jawnie połączonych kompatybilnych grup.
- Edytor WebView z tym samym modelem grupy podstawowej, co rodzina produktów Vault.

## Rozwój

Uruchom testy pakietu Swift:

```bash
swift test
```

Pakiet obejmuje podstawowe testy zasad, harmonogramu, reguł niestandardowych, pomostu, importu i kontroli systemu macOS.

## Projekt Xcode

Opcjonalny projekt Xcode jest generowany z [XcodeProject/project.yml](XcodeProject/project.yml):

```bash
cd XcodeProject
./generate.sh
```

Przeczytaj [XcodeProject/README.md](XcodeProject/README.md) przed skonfigurowaniem celów podpisywania lub dystrybucji.

## Polityka dotycząca dokumentacji

Dokumenty angielskie pozostają kanoniczne. Interfejs edytora zawiera kompletne katalogi regionalne, przetłumaczone podręczniki znajdują się obok `WebAssets/manual/en.md`, a przetłumaczone kopie pozostałych utrzymywanych dokumentów znajdują się pod `i18n-docs/<locale>/`.

Warunki prawne i informacje o ochronie prywatności pozostają odrębnymi dokumentami prawnymi; niniejszy plik README ich nie zastępuje.
