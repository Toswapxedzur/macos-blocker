# ਮੈਕ ਵਾਲਟ ਲਾਗੂ ਕਰਨ ਦਾ ਨਕਸ਼ਾ

ਇਹ ਨਕਸ਼ਾ ਮੌਜੂਦਾ ਸਰੋਤ ਰੁੱਖ ਤੋਂ ਲਿਆ ਗਿਆ ਹੈ। ਇਹ ਇੱਕ ਨੈਵੀਗੇਸ਼ਨ ਸਹਾਇਤਾ ਹੈ, ਇਹ ਦਾਅਵਾ ਨਹੀਂ ਹੈ ਕਿ ਹਰੇਕ ਬ੍ਰਾਊਜ਼ਰ ਸਮਰੱਥਾ ਦਾ ਮੂਲ ਬਰਾਬਰ ਹੈ।

| ਚਿੰਤਾ | ਮੌਜੂਦਾ macOS ਲਾਗੂਕਰਨ |
| --- | --- |
| ਸਮੂਹ ਅਤੇ ਨੀਤੀ ਮਾਡਲ | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift`, ਅਤੇ `Schedule.swift` |
| ਵੈੱਬ ਸੰਪਾਦਕ | `Sources/MacBlockerWebUI/` ਅਤੇ `WebAssets/` ਅੰਦਰ `WKWebView` |
| ਸੰਪਾਦਕ ਦ੍ਰਿੜਤਾ | `BlockerWebStore.swift` ਅਤੇ WebView ਬ੍ਰਿਜ |
| ਮੂਲ ਐਪ ਵਸਤੂ ਸੂਚੀ | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` ਅਤੇ `MacAppInventoryJSON.swift` |
| ਲਾਗੂ ਕਰਨ ਦੀ ਯੋਜਨਾ | `Sources/MacBlockerCore/EnforcementPlan.swift` ਅਤੇ `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| ਨੇਟਿਵ ਕੰਟਰੋਲ ਅਡਾਪਟਰ | `Sources/MacBlockerMacControl/` ਅਤੇ `Sources/MacBlockerScreenTime/` |
| ਕਸਟਮ ਨਿਯਮ | `CustomJavaScriptPolicyRuntime.swift` ਨਾਲ ਹੀ JavaScript ਰਨਟਾਈਮ ਸਰੋਤ |
| ਬ੍ਰਿਜ ਹੱਬ | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| ਐਪ ਲਾਈਫਸਾਈਕਲ | `BlockerAppDelegate.swift`, `BlockerMainView.swift`, ਅਤੇ `MacBlockerPanelApp.swift` |

## ਉਤਪਾਦ ਸੀਮਾ

WebView ਸੰਪਾਦਕ Vault ਐਕਸਟੈਂਸ਼ਨ ਦੇ ਨਾਲ ਇੱਕ ਸਮੂਹ-ਅਧਾਰਿਤ ਉਪਭੋਗਤਾ ਮਾਡਲ ਨੂੰ ਸਾਂਝਾ ਕਰਦਾ ਹੈ, ਪਰ ਹੋਸਟ ਇਹ ਫੈਸਲਾ ਕਰਦਾ ਹੈ ਕਿ ਕੋਈ ਕਾਰਵਾਈ ਕੀ ਕਰ ਸਕਦੀ ਹੈ। ਬ੍ਰਾਊਜ਼ਰ-ਸਿਰਫ਼ ਕਾਰਵਾਈਆਂ ਨੂੰ ਚੁੱਪਚਾਪ ਮੂਲ ਲਾਗੂਕਰਨ ਵਜੋਂ ਨਹੀਂ ਮੰਨਿਆ ਜਾਂਦਾ ਹੈ। ਨੇਟਿਵ ਐਗਜ਼ੀਕਿਊਸ਼ਨ ਮੈਕ 'ਤੇ ਉਪਲਬਧ ਇਜਾਜ਼ਤ, ਟੀਚੇ ਅਤੇ ਅਡਾਪਟਰ 'ਤੇ ਨਿਰਭਰ ਕਰਦਾ ਹੈ।

## ਸੰਪਤੀਆਂ ਨੂੰ ਮੌਜੂਦਾ ਰੱਖਣਾ

ਅੰਗਰੇਜ਼ੀ ਹਦਾਇਤਾਂ ਦਾ ਮੈਨੂਅਲ `WebAssets/manual/en.md` ਹੈ; ਅਨੁਵਾਦਿਤ ਮੈਨੂਅਲ ਆਪਣੇ ਲੋਕੇਲ ਕੋਡ ਨਾਲ ਇੱਕੋ ਡਾਇਰੈਕਟਰੀ ਨੂੰ ਸਾਂਝਾ ਕਰਦੇ ਹਨ। ਅਨੁਵਾਦ ਕੈਟਾਲਾਗ `WebAssets/translation/` ਵਿੱਚ ਰਹਿੰਦੇ ਹਨ, ਜਦੋਂ ਕਿ ਬਾਕੀ ਰੱਖੇ ਦਸਤਾਵੇਜ਼ਾਂ ਦੀਆਂ ਅਨੁਵਾਦਿਤ ਕਾਪੀਆਂ `i18n-docs/<locale>/` ਦੇ ਹੇਠਾਂ ਹਨ।

ਸੰਪਾਦਕ ਸਤਰ ਨੂੰ ਬਦਲਣ ਵੇਲੇ, ਪਹਿਲਾਂ ਇਸਦੀ ਅੰਗਰੇਜ਼ੀ ਕੁੰਜੀ ਨੂੰ ਅੱਪਡੇਟ ਕਰੋ, ਫਿਰ ਲੋਕੇਲ ਕੈਟਾਲਾਗ ਅੱਪਡੇਟ ਕਰੋ ਅਤੇ ਸਾਂਝਾ ਅਨੁਵਾਦ ਆਡਿਟ ਚਲਾਓ।
