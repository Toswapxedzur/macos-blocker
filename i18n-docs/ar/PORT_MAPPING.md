# خريطة تنفيذ Mac Vault

هذه الخريطة مشتقة من شجرة المصدر الحالية. إنها أداة مساعدة للملاحة، وليست ادعاءً بأن كل قدرة متصفح لها مكافئ أصلي.

| قلق | تنفيذ macOS الحالي |
| --- | --- |
| نموذج المجموعة والسياسة | `Sources/MacBlockerCore/BlockGroup.swift`، `PolicyEvaluator.swift`، `UsageState.swift`، و`Schedule.swift` |
| محرر الويب | `Sources/MacBlockerWebUI/` و`WebAssets/` داخل `WKWebView` |
| ثبات المحرر | `BlockerWebStore.swift` وجسر WebView |
| مخزون التطبيق الأصلي | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` و `MacAppInventoryJSON.swift` |
| خطة التنفيذ | `Sources/MacBlockerCore/EnforcementPlan.swift` و `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| محولات التحكم الأصلية | `Sources/MacBlockerMacControl/` و `Sources/MacBlockerScreenTime/` |
| القواعد المخصصة | `CustomJavaScriptPolicyRuntime.swift` بالإضافة إلى موارد وقت تشغيل JavaScript |
| محور الجسر | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| دورة حياة التطبيق | `BlockerAppDelegate.swift`، `BlockerMainView.swift`، و`MacBlockerPanelApp.swift` |

## حدود المنتج

يشارك محرر WebView نموذج مستخدم موجهًا للمجموعة مع ملحق Vault، لكن المضيف هو الذي يقرر ما يمكن أن يفعله الإجراء. لا يتم التعامل مع الإجراءات التي يتم تنفيذها في المتصفح فقط بصمت على أنها إجراءات تنفيذ أصلية. يعتمد التنفيذ الأصلي على الإذن والهدف والمحول المتوفر على جهاز Mac.

## الحفاظ على الأصول الحالية

دليل التعليمات باللغة الإنجليزية هو `WebAssets/manual/en.md`؛ تشترك الأدلة المترجمة في نفس الدليل مع رمزها المحلي. تظل كتالوجات الترجمة في `WebAssets/translation/`، بينما توجد النسخ المترجمة من المستندات المتبقية تحت `i18n-docs/<locale>/`.

عند تغيير سلسلة محرر، قم بتحديث مفتاحها الإنجليزي أولاً، ثم قم بتحديث كتالوجات اللغة وقم بتشغيل تدقيق الترجمة المشتركة.
