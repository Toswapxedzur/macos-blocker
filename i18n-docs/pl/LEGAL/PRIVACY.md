# Polityka prywatności skarbca Adamancia

Ostatnia aktualizacja: 7 lipca 2026 r

Adamancia Vault to aplikacja skupiająca i blokująca. Ta zasada opisuje wersję aplikacji na macOS.

## Podsumowanie

Program Adamancia Vault zaprojektowano tak, aby domyślnie zachowywał reguły blokowania i stan użytkowania lokalnie na komputerze Mac. Aplikacja nie sprzedaje danych osobowych, nie wyświetla reklam i nie udostępnia danych osobowych brokerom danych.

## Dane przechowywane lokalnie

Aplikacja może przechowywać następujące dane lokalne na komputerze Mac:

- Blokowanie grup, harmonogramów, timerów, stanu wstrzymania/drzemki i ustawień aplikacji.
- Lokalna pamięć edytora internetowego odzwierciedlana z dołączonego interfejsu internetowego.
- Stan lokalnego mostu/łącza po podłączeniu aplikacji macOS do rozszerzeń przeglądarki.
- Pliki zasad egzekwowania aplikacji używane przez silnik blokujący macOS.
- Dane kontenera grupy aplikacji, gdy kompilacja lub rozszerzenie App Store korzysta z grupy aplikacji.

Znane ścieżki lokalne są udokumentowane w `RELEASE.md` i w skrypcie deinstalatora.

## Korzystanie z sieci

Aplikacja może otworzyć odbiornik sieci lokalnej dla swojego mostka z aplikacją internetową, dzięki czemu rozszerzenia przeglądarki będą mogły łączyć się z aplikacją na komputerze Mac. Aplikacja może również wysyłać żądania sieciowe, jeśli dołączona funkcja musi komunikować się z usługami Adamancia, na przykład opcjonalne konto lub funkcje związane z synchronizacją.

## Analityka i reklamy

Aplikacja dla systemu macOS nie zawiera pakietów SDK do reklam innych firm. Nie powinna wysyłać statystyk, chyba że funkcja wyraźnie mówi, że korzysta z usługi online.

## Opcjonalne konta i synchronizacja

Jeśli w danej wersji włączone są funkcje konta lub synchronizacji, funkcje te mogą wysyłać minimalne dane potrzebne do zapewnienia tej funkcji, takie jak tożsamość konta i ładunki synchronizacji. Pobieranie plików i blokowanie lokalne nie mogą wymagać posiadania konta.

## Uprawnienia

W zależności od kanału i włączonych funkcji Adamancia Vault może poprosić system macOS o uprawnienia, takie jak dostępność, dostęp do sieci, rejestracja elementu logowania lub dostęp do grupy aplikacji. Te uprawnienia służą do zapewniania funkcji blokowania, uruchamiania aplikacji, łączenia i utrzymywania.

## Odinstalowywanie

DMG obejmuje `uninstall.command`. Prosi o potwierdzenie, zamyka aplikację, jeśli jest uruchomiona, wyrejestrowuje element logowania aplikacji, jeśli to możliwe, usuwa `/Applications/AdamanciaVault.app` i opcjonalnie usuwa tylko znane pliki utworzone przez tę aplikację.

## Kontakt

W przypadku pytań dotyczących prywatności otwórz problem w publicznym repozytorium GitHub lub skorzystaj z kanału kontaktowego opublikowanego w witrynie Adamancia Vault.
