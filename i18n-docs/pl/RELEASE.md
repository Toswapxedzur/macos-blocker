# Przewodnik po wydaniu Mac Vault

W tym przewodniku zastosowano sprawdzone skrypty kompilacji. Celowo nie zawiera osobistej tożsamości podpisującej, profilu notarialnego, hasła ani danych konta.

## Przed wydaniem

1. Uruchom `swift test` z katalogu głównego repozytorium.
2. Ustaw wersję wydania i numer kompilacji w kontrolowanej konfiguracji projektu/kompilacji.
3. Przejrzyj podręcznik w języku angielskim, zlokalizowane podręczniki i audyt tłumaczenia redaktora.
4. Przed opublikowaniem artefaktu sprawdź gałąź wydania, znacznik i zasady kamieni milowych.

## Rurociąg DMG witryny internetowej

Skrypty znajdują się w `scripts/release/`. Ich wartości domyślne można zastąpić zmiennymi środowiskowymi, w tym `APP_NAME`, `BUNDLE_ID`, `TEAM_ID`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `VERSION` i `BUILD_NUMBER`.

Uruchom cały potok tylko na skonfigurowanej maszynie podpisującej:

```bash
VERSION=<version> BUILD_NUMBER=<build> scripts/release/full_release_dmg.sh
```

Potok składa się z istniejących skryptów kompilacji, podpisywania, DMG, notarialnego i weryfikacyjnego. Traktuj jego dane wyjściowe jako kandydata do wydania, dopóki etap weryfikacji nie zakończy się pomyślnie.

## Cele dystrybucji Xcode

Wygeneruj projekt Xcode z `XcodeProject/project.yml`, skonfiguruj odpowiedni zespół podpisujący i możliwości w zatwierdzonym środowisku, a następnie zarchiwizuj odpowiedni cel. Nie zatwierdzaj wygenerowanych poświadczeń, plików informacyjnych ani profili notarialnych.

## Po wydaniu

1. Utwórz znacznik wersji niezmiennej i gałąź wydania stałego zgodnie z polityką zarządzania wersjami.
2. Opublikuj artefakt wersji i sumę kontrolną.
3. Zaktualizuj rejestr wydań publicznych dopiero po ustaleniu ostatecznego adresu URL artefaktu.
4. Przechowuj informacje o wydaniu w języku angielskim, chyba że dostarczono sprawdzoną zlokalizowaną informację o wydaniu.
