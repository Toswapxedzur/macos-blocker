# Mapa de implementação do Mac Vault

Este mapa é derivado da árvore de origem atual. É um auxílio à navegação, não uma afirmação de que cada capacidade do navegador tenha um equivalente nativo.

| Preocupação | Implementação atual do macOS |
| --- | --- |
| Modelo de grupo e política | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift` e `Schedule.swift` |
| Editor da Web | `Sources/MacBlockerWebUI/` e `WebAssets/` dentro de um `WKWebView` |
| Persistência do editor | `BlockerWebStore.swift` e a ponte WebView |
| Inventário de aplicativos nativos | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` e `MacAppInventoryJSON.swift` |
| Plano de execução | `Sources/MacBlockerCore/EnforcementPlan.swift` e `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| Adaptadores de controle nativos | `Sources/MacBlockerMacControl/` e `Sources/MacBlockerScreenTime/` |
| Regras personalizadas | `CustomJavaScriptPolicyRuntime.swift` mais os recursos de tempo de execução JavaScript |
| Centro de ponte | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| Ciclo de vida do aplicativo | `BlockerAppDelegate.swift`, `BlockerMainView.swift` e `MacBlockerPanelApp.swift` |

## Limite do produto

O editor WebView compartilha um modelo de usuário orientado a grupo com a extensão Vault, mas o host decide o que uma ação pode fazer. As ações exclusivas do navegador não são tratadas silenciosamente como imposição nativa. A execução nativa depende da permissão, do destino e do adaptador disponível no Mac.

## Manter os ativos atualizados

O manual de instruções em inglês é `WebAssets/manual/en.md`; manuais traduzidos compartilham o mesmo diretório com seu código de localidade. Os catálogos de tradução permanecem em `WebAssets/translation/`, enquanto as cópias traduzidas dos demais documentos mantidos estão em `i18n-docs/<locale>/`.

Ao alterar uma string do editor, atualize primeiro sua chave em inglês, depois atualize os catálogos de localidade e execute a auditoria de tradução compartilhada.
