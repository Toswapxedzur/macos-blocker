# Карта реализации Mac Vault

Эта карта получена из текущего исходного дерева. Это средство навигации, а не утверждение, что каждая функция браузера имеет собственный эквивалент.

| Концерн | Текущая реализация macOS |
| --- | --- |
| Модель группы и политики | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift` и `Schedule.swift` |
| Веб-редактор | `Sources/MacBlockerWebUI/` и `WebAssets/` внутри `WKWebView` |
| Настойчивость редактора | `BlockerWebStore.swift` и мост WebView |
| Собственный инвентарь приложений | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` и `MacAppInventoryJSON.swift` |
| План исполнения | `Sources/MacBlockerCore/EnforcementPlan.swift` и `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| Родные адаптеры управления | `Sources/MacBlockerMacControl/` и `Sources/MacBlockerScreenTime/` |
| Пользовательские правила | `CustomJavaScriptPolicyRuntime.swift` плюс ресурсы времени выполнения JavaScript |
| Мост-концентратор | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| Жизненный цикл приложения | `BlockerAppDelegate.swift`, `BlockerMainView.swift` и `MacBlockerPanelApp.swift` |

## Граница продукта

Редактор WebView использует групповую пользовательскую модель с расширением Vault, но хост решает, что может делать действие. Действия только в браузере не рассматриваются как встроенное принудительное исполнение. Собственное выполнение зависит от разрешения, цели и адаптера, доступных на Mac.

## Поддержание актуальности активов

Руководство по эксплуатации на английском языке: `WebAssets/manual/en.md`; переведенные руководства используют один и тот же каталог с кодом своей локали. Каталоги переводов остаются в `WebAssets/translation/`, а переведенные копии остальных поддерживаемых документов — в `i18n-docs/<locale>/`.

При изменении строки редактора сначала обновите его английский ключ, затем обновите каталоги языковых стандартов и запустите общий аудит перевода.
