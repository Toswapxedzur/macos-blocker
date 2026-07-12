# Projekt Mac Vault Xcode

`project.yml` to zatwierdzona specyfikacja XcodeGen dla systemów docelowych macOS i iOS, które korzystają ze wspólnego pakietu Swift.

## Wygeneruj projekt

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

Regeneruj po zmianie `project.yml`, celów, uprawnień lub członkostwa źródłowego. Nie używaj wygenerowanych plików projektu jako konfiguracji kanonicznej.

## Bieżące rodziny docelowe

- `AdamanciaVaultMac` to docelowa aplikacja dla systemu macOS obsługiwana przez `MacBlockerAppFeature`.
- `macosBlocker` to docelowa aplikacja iOS.
— Projekt na iOS obejmuje rozszerzenia dotyczące aktywności urządzenia, konfiguracji tarczy i działania tarczy.

Bieżące identyfikatory, cele wdrożenia, pola wersji i możliwości są zdefiniowane w `project.yml` i przywoływanych plikach uprawnień. Przed dystrybucją przejrzyj je w środowisku podpisywania.

## Podpisywanie i możliwości

Użyj identyfikatorów zespołu i paczki należących do konta dystrybucyjnego. Potwierdź możliwości wymagane przez budowany cel. Nigdy nie dodawaj do tego repozytorium sekretów podpisywania, profili udostępniania ani danych uwierzytelniających konta.

## Najpierw przetestuj

Uruchom testy pakietów współdzielonych przed utworzeniem archiwum:

```bash
cd ..
swift test
```
