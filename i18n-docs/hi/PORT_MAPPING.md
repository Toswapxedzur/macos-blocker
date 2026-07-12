# मैक वॉल्ट कार्यान्वयन मानचित्र

यह मानचित्र वर्तमान स्रोत वृक्ष से लिया गया है। यह एक नेविगेशन सहायता है, यह दावा नहीं है कि प्रत्येक ब्राउज़र क्षमता का एक मूल समकक्ष होता है।

| चिंता | वर्तमान macOS कार्यान्वयन |
| --- | --- |
| समूह और नीति मॉडल | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift`, और `Schedule.swift` |
| वेब संपादक | `Sources/MacBlockerWebUI/` और `WebAssets/` एक `WKWebView` के अंदर |
| संपादक दृढ़ता | `BlockerWebStore.swift` और वेबव्यू ब्रिज |
| नेटिव ऐप इन्वेंट्री | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` और `MacAppInventoryJSON.swift` |
| प्रवर्तन योजना | `Sources/MacBlockerCore/EnforcementPlan.swift` और `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| मूल नियंत्रण एडेप्टर | `Sources/MacBlockerMacControl/` और `Sources/MacBlockerScreenTime/` |
| कस्टम नियम | `CustomJavaScriptPolicyRuntime.swift` प्लस जावास्क्रिप्ट रनटाइम संसाधन |
| ब्रिज हब | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| ऐप जीवनचक्र | `BlockerAppDelegate.swift`, `BlockerMainView.swift`, और `MacBlockerPanelApp.swift` |

## उत्पाद सीमा

वेबव्यू संपादक वॉल्ट एक्सटेंशन के साथ एक समूह-उन्मुख उपयोगकर्ता मॉडल साझा करता है, लेकिन होस्ट यह तय करता है कि कोई कार्रवाई क्या कर सकती है। केवल ब्राउज़र वाली कार्रवाइयों को चुपचाप मूल प्रवर्तन के रूप में नहीं माना जाता है। मूल निष्पादन मैक पर उपलब्ध अनुमति, लक्ष्य और एडाप्टर पर निर्भर करता है।

## संपत्ति को चालू रखना

अंग्रेजी निर्देश पुस्तिका `WebAssets/manual/en.md` है; अनुवादित मैनुअल अपने स्थानीय कोड के साथ समान निर्देशिका साझा करते हैं। अनुवाद कैटलॉग `WebAssets/translation/` में रहते हैं, जबकि शेष बनाए गए दस्तावेज़ों की अनुवादित प्रतियां `i18n-docs/<locale>/` के अंतर्गत हैं।

किसी संपादक स्ट्रिंग को बदलते समय, पहले उसकी अंग्रेजी कुंजी को अपडेट करें, फिर स्थानीय कैटलॉग को अपडेट करें और साझा अनुवाद ऑडिट चलाएं।
