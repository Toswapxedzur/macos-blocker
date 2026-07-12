# ম্যাক ভল্ট বাস্তবায়ন মানচিত্র

এই মানচিত্রটি বর্তমান উৎস গাছ থেকে নেওয়া হয়েছে। এটি একটি নেভিগেশন সহায়তা, এমন দাবি নয় যে প্রতিটি ব্রাউজার ক্ষমতার একটি নেটিভ সমতুল্য রয়েছে৷

| উদ্বেগ | বর্তমান macOS বাস্তবায়ন |
| --- | --- |
| গ্রুপ এবং নীতি মডেল | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift`, এবং `Schedule.swift` |
| ওয়েব সম্পাদক | `Sources/MacBlockerWebUI/` এবং `WebAssets/` ভিতরে একটি `WKWebView` |
| সম্পাদকের অধ্যবসায় | `BlockerWebStore.swift` এবং ওয়েবভিউ ব্রিজ |
| নেটিভ অ্যাপ ইনভেন্টরি | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` এবং `MacAppInventoryJSON.swift` |
| প্রয়োগ পরিকল্পনা | `Sources/MacBlockerCore/EnforcementPlan.swift` এবং `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| নেটিভ কন্ট্রোল অ্যাডাপ্টার | `Sources/MacBlockerMacControl/` এবং `Sources/MacBlockerScreenTime/` |
| কাস্টম নিয়ম | `CustomJavaScriptPolicyRuntime.swift` প্লাস জাভাস্ক্রিপ্ট রানটাইম সম্পদ |
| ব্রিজ হাব | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| অ্যাপ জীবনচক্র | `BlockerAppDelegate.swift`, `BlockerMainView.swift`, এবং `MacBlockerPanelApp.swift` |

## পণ্যের সীমানা

WebView এডিটর ভল্ট এক্সটেনশনের সাথে একটি গ্রুপ-ভিত্তিক ব্যবহারকারী মডেল শেয়ার করে, কিন্তু হোস্ট সিদ্ধান্ত নেয় একটি অ্যাকশন কী করতে পারে। শুধুমাত্র ব্রাউজার ক্রিয়াগুলিকে নীরবে দেশীয় প্রয়োগ হিসাবে গণ্য করা হয় না। নেটিভ এক্সিকিউশন ম্যাকে উপলব্ধ অনুমতি, লক্ষ্য এবং অ্যাডাপ্টারের উপর নির্ভর করে।

## সম্পদ বর্তমান রাখা

ইংরেজি নির্দেশনা ম্যানুয়াল হল `WebAssets/manual/en.md`; অনুবাদকৃত ম্যানুয়াল তাদের লোকেল কোডের সাথে একই ডিরেক্টরি শেয়ার করে। অনুবাদের ক্যাটালগগুলি `WebAssets/translation/`-এ থাকে, যখন অবশিষ্ট রক্ষণাবেক্ষণ করা নথিগুলির অনুবাদিত অনুলিপিগুলি `i18n-docs/<locale>/`-এর অধীনে থাকে।

একটি সম্পাদক স্ট্রিং পরিবর্তন করার সময়, প্রথমে এটির ইংরেজি কী আপডেট করুন, তারপর লোকেল ক্যাটালগ আপডেট করুন এবং শেয়ার্ড ট্রান্সলেশন অডিট চালান।
