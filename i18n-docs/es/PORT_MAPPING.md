# Mapa de implementación de Mac Vault

Este mapa se deriva del árbol fuente actual. Es una ayuda para la navegación, no una afirmación de que cada capacidad del navegador tenga un equivalente nativo.

| Preocupación | Implementación actual de macOS |
| --- | --- |
| Modelo de grupo y política | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift` y `Schedule.swift` |
| Editor web | `Sources/MacBlockerWebUI/` y `WebAssets/` dentro de un `WKWebView` |
| Persistencia del editor | `BlockerWebStore.swift` y el puente WebView |
| Inventario de aplicaciones nativas | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` y `MacAppInventoryJSON.swift` |
| Plan de aplicación | `Sources/MacBlockerCore/EnforcementPlan.swift` y `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| Adaptadores de control nativos | `Sources/MacBlockerMacControl/` y `Sources/MacBlockerScreenTime/` |
| Reglas personalizadas | `CustomJavaScriptPolicyRuntime.swift` más los recursos de tiempo de ejecución de JavaScript |
| Centro del puente | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| Ciclo de vida de la aplicación | `BlockerAppDelegate.swift`, `BlockerMainView.swift` y `MacBlockerPanelApp.swift` |

## Límite del producto

El editor WebView comparte un modelo de usuario orientado a grupos con la extensión Vault, pero el anfitrión decide qué puede hacer una acción. Las acciones exclusivas del navegador no se tratan silenciosamente como aplicación nativa. La ejecución nativa depende del permiso, el destino y el adaptador disponibles en Mac.

## Mantener los activos actualizados

El manual de instrucciones en inglés es `WebAssets/manual/en.md`; Los manuales traducidos comparten el mismo directorio con su código local. Los catálogos traducidos permanecen en `WebAssets/translation/`, mientras que las copias traducidas de los documentos mantenidos restantes están en `i18n-docs/<locale>/`.

Al cambiar una cadena de editor, actualice primero su clave en inglés, luego actualice los catálogos locales y ejecute la auditoría de traducción compartida.
