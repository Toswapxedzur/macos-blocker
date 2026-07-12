# แผนที่การใช้งาน Mac Vault

แผนที่นี้ได้มาจากแผนผังต้นทางปัจจุบัน มันเป็นเครื่องช่วยนำทาง ไม่ใช่การอ้างว่าความสามารถของเบราว์เซอร์ทุกอย่างเทียบเท่ากัน

| ความกังวล | การใช้งาน macOS ปัจจุบัน |
| --- | --- |
| รูปแบบกลุ่มและนโยบาย | `Sources/MacBlockerCore/BlockGroup.swift`, `PolicyEvaluator.swift`, `UsageState.swift` และ `Schedule.swift` |
| บรรณาธิการเว็บ | `Sources/MacBlockerWebUI/` และ `WebAssets/` ภายใน `WKWebView` |
| ความเพียรของบรรณาธิการ | `BlockerWebStore.swift` และสะพาน WebView |
| พื้นที่โฆษณาเนทีฟแอป | `Sources/MacBlockerMacControl/MacApplicationInventory.swift` และ `MacAppInventoryJSON.swift` |
| แผนการบังคับใช้ | `Sources/MacBlockerCore/EnforcementPlan.swift` และ `Sources/MacBlockerAppFeature/MacEnforcementBridge.swift` |
| อะแดปเตอร์ควบคุมดั้งเดิม | `Sources/MacBlockerMacControl/` และ `Sources/MacBlockerScreenTime/` |
| กฎที่กำหนดเอง | `CustomJavaScriptPolicyRuntime.swift` รวมถึงทรัพยากรรันไทม์ JavaScript |
| สะพานฮับ | `Sources/MacBlockerAppFeature/ConnectionHub.swift` |
| วงจรชีวิตของแอป | `BlockerAppDelegate.swift`, `BlockerMainView.swift` และ `MacBlockerPanelApp.swift` |

##ขอบเขตสินค้า

เครื่องมือแก้ไข WebView แชร์โมเดลผู้ใช้แบบกลุ่มกับส่วนขยาย Vault แต่โฮสต์จะเป็นผู้ตัดสินใจว่าจะดำเนินการใดได้บ้าง การดำเนินการเฉพาะเบราว์เซอร์จะไม่ถือเป็นการบังคับใช้แบบเนทิฟ การดำเนินการแบบเนทีฟขึ้นอยู่กับสิทธิ์ เป้าหมาย และอะแดปเตอร์ที่มีอยู่บน Mac

## รักษาทรัพย์สินให้เป็นปัจจุบัน

คู่มือการใช้งานภาษาอังกฤษคือ `WebAssets/manual/en.md`; คู่มือที่แปลจะใช้ไดเร็กทอรีเดียวกันกับรหัสสถานที่ แค็ตตาล็อกการแปลยังคงอยู่ใน `WebAssets/translation/` ในขณะที่สำเนาที่แปลแล้วของเอกสารที่ได้รับการดูแลที่เหลืออยู่จะอยู่ภายใต้ `i18n-docs/<locale>/`

เมื่อเปลี่ยนสตริงตัวแก้ไข ให้อัปเดตคีย์ภาษาอังกฤษก่อน จากนั้นอัปเดตแค็ตตาล็อกสถานที่และเรียกใช้การตรวจสอบการแปลที่ใช้ร่วมกัน
