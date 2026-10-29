# Mac Vault उपयोगकर्ता पुस्तिका

Mac Vault में तीन पृष्ठ हैं: **Vault** नेटिव ऐप्स को ब्लॉक करता है, **Content tagging** समर्थित ब्राउज़र सामग्री को टैग करता है और **Activity** रिकॉर्ड किया गया उपयोग दिखाता है। ब्राउज़र एक्सटेंशन समर्थित सामग्री एकत्र करके ब्राउज़र ब्लॉकिंग लागू करता है। इसे अपने ब्राउज़र में इंस्टॉल और कनेक्ट करें।

## तुरंत शुरू करें

1. **Vault** में blocking group और Apps target जोड़ें, फिर + picker से ऐप चुनें।
2. ब्लॉकिंग व्यवहार चुनकर group सक्षम करें।
3. **Content tagging** में group बनाएं, उसके platforms चुनें और विवरण सहित tags जोड़ें।
4. Settings → **AI connections** में ChatGPT subscription, OpenAI API, Gemini API या Grok API चुनें। खाते से जुड़ें या key डालकर model list लाएं, फिर group में connection/model चुनें। Tagging चालू करें और group resume करें।
5. कनेक्टेड ब्राउज़र में समर्थित सामग्री खोलें। Tags से block नियंत्रित करना हो तो browser blocking group में tag filter सेट करें।

## Blocking groups

**Blocking group** ब्लॉकिंग नीति लागू करता है। **Content tagging group** सामग्री को tags देता है; वह स्वयं कुछ ब्लॉक नहीं करता। Group जोड़कर नाम दें, **Applies to** में targets चुनें, ब्लॉकिंग का समय और schedule या time allowance तय करें, फिर enable करें। सामान्य बदलाव अपने-आप सेव होते हैं। Error का अर्थ है बदलाव स्वीकार नहीं हुआ; field ठीक कर पुनः प्रयास करें। Group disable करने से configuration रहते हुए नीति रुकती है; **Delete group** इसे मिटाता है। क्रम बदलने के लिए groups खींचें। एक target पर कई groups लागू हो सकते हैं; एक को snooze करने से दूसरे का block नहीं हटता। **Export** configuration कॉपी करता है; **Import** पुष्टि के बाद चुने group को बदलता है।

### Time allowance and schedule

**Block immediately** तब लागू होता है जब enabled group मेल खाता हो और schedule सक्रिय हो। **Block when the time allowance is used** allowance समाप्त होने तक उपयोग की अनुमति देता है। Allowance मिनट में और reset interval घंटे में तय करें। Rolling limit पिछली window का उपयोग गिनता है। Midnight reset स्थानीय मध्यरात्रि में नया period शुरू करता है, rolling limit पर भी। सक्रिय weekdays और वैकल्पिक local-time windows हर पंक्ति में चुनें, जैसे **09:00-12:00**। खाली window सूची चुने दिनों भर लागू होती है। Window उसी दिन शुरू होने के बाद समाप्त हो; रात-पार schedule को अलग दिनों में बांटें।

### Snooze

हर blocking group में snooze सेट करें। **Pause blocking** pause duration तक नीति रोकता है। **Add to the time allowance** समय-सीमित group में उपयोग योग्य मिनट जोड़ता है। केवल उपयोग किया गया अतिरिक्त allowance snoozed time गिना जाता है। बचा हुआ extra allowance अगले reset पर समाप्त होता है; rolling limit में एक window बाद, या सक्षम होने पर midnight पर पहले। **Activation delay** block जारी रखते हुए snooze टालता है। **Cooldown** snooze खत्म होने के बाद अगले अनुरोध का इंतज़ार है। **Required confirmations** पुष्टि चरण तय करता है। Frozen group पर snooze तभी उपलब्ध है जब freeze से पहले अनुमति दी गई हो।

### Freeze and PIN

**Freeze** सामान्य edits रोकता है। Unfreeze के लिए पांच सेकंड के अंतर से दस confirmations, निर्धारित wait और छह अंकों का PIN चाहिए। **Wait before unfreezing** 0–72 घंटे स्वीकार करता है; 0 का अर्थ कोई प्रतीक्षा नहीं। Frozen रहते wait बढ़ाया और PIN जोड़ा जा सकता है, पर unfreeze से पहले शर्तें कमजोर नहीं की जा सकतीं। Delete करते समय भी शेष wait और PIN लागू हैं।

### Linked groups

**Link** से दूसरे Vault programs के स्पष्ट रूप से चुने groups जोड़ें। वे नाम, समर्थित policy settings, targets, usage और freeze conditions साझा करते हैं। हर program वही target types बदलता और लागू करता है जिन्हें वह support करता है; अन्य target entries linked programs में उपलब्ध रहती हैं। **Unlink** group और settings रखकर अलग करता है। Offline member होने पर Mac Vault और linked browser खोलकर reconnect करें। Member offline होने पर भी स्थानीय saved policy लागू रह सकती है।

## सहायता लें

Field के पास छोटा **i** दबाकर explanation देखें; बाहर क्लिक करें या Escape दबाकर बंद करें। Lists scrollable boxes में हैं; search दिखाई देने वाली सूची छांटता है, entries नहीं मिटाता। Custom rules के लिए [Code manual](../code-manual/hi.md) में editor, activation, logs, file access और API है।

## Native apps

Apps target के + picker से installed या चल रहे apps चुनें। दूसरे folder से app चलाने के बाद सूची refresh करने को picker फिर खोलें। **Block every app except these** सूची को allowlist बनाता है। Mac Vault सामान्य Apple apps और पूरे browsers को block कर सकता है; Mac Vault और समान bundle identifier वाला app सुरक्षित रहते हैं। Blocked app को quit करने को कहा जाता है; **Ask a blocked app to quit again every (minutes)** retry तय करता है। Website redirect, page pause और feed hiding browser extension लागू करता है, native app action नहीं।

## Content tagging

Group अपनी platforms की सामग्री को अपने tag tree और model settings से tag करता है। हर platform एक group में होता है; creation के समय चुनें, बाद में बदल नहीं सकते। Blocking schedules/filters tagging नियंत्रित नहीं करते। Settings में tagging enable करें और हर group का **Pause tagging / Resume tagging** अलग करें। **Activity → Recording** में platform feed recording बंद करने से tagging भी बंद होता है।

### Tags and model settings

Tags बनाएं, अर्थ बताएं, tree में parent जोड़ें या हटाएं; drag करने से branch जाती है। स्पष्ट विवरण model को मिलते-जुलते tags अलग करने में मदद करता है। हर group की settings स्वतंत्र हैं। **Minimum confidence** हर अनुमानित tag के evidence grade को 1–5 रखता है; नए groups 4 (strong support) से शुरू होते हैं। कोई लक्ष्य tag count नहीं; item को कोई tag न मिले यह संभव है। **Tagging instructions** group की प्राथमिकताएं रखता है। सामान्य edits auto-save होते हैं। हर group एक स्पष्ट रूप से चुना connection, model और reasoning effort उपयोग करता है।

### AI connections

Settings में ChatGPT subscription, OpenAI API, Gemini API और Grok API हैं। ChatGPT subscription Vault के sign-in और पात्र plan का उपयोग करता है। API keys चुने provider की billing और limits के अधीन हैं। Provider चुनकर साझा dropdown के ठीक नीचे key डालें। Key edit auto-save होती है; field खाली करने से key हटती है। **Fetch model list** चुनें, फिर Content tagging या custom-rule group में model चुनें; models fetch करने से model चुना नहीं जाता।

**Reasoning effort** model की सोच की मात्रा है: जहां उपलब्ध हो Model default, Low, Medium या High। नई selections Medium से शुरू होती हैं; पुरानी saved रहती हैं। अधिक effort में समय और tokens बढ़ सकते हैं। Tagging के लिए web search हमेशा enabled है; model तय करता है कब खोजे। Search और structured tagging समर्थित model चुनें। विफल/अनुपलब्ध requests में valid cached results रखे जाते हैं; नए items तब तक unresolved रहते हैं जब तक **Retry cloud classification** न चुनें। Vault provider अपने-आप नहीं बदलता; हर connection का retry interval और attempt limit अलग है। Browser extension में **+ tag** दबाकर खोजें और tag जोड़ें। हटाने वाले control या चुने tag पर Delete एक बार दबाकर हटाएं। **Untagged** का अर्थ tagging पूरी, कोई tag नहीं; **Tagging** का अर्थ परिणाम लंबित है। आपकी correction उस item के लिए authoritative रहती है।

## Activity

Activity enabled app use, website visits और समर्थित **Content viewed** स्थानीय रूप से रिकॉर्ड करता है। Charts recorded data दिखाते हैं; खाली जगह Mac के idle होने का प्रमाण नहीं। Date range चुनें। **Timeline** दिन के समय के अनुसार उपयोग दिखाता है; **Totals** duration जोड़ता है; **Time interval** प्रत्येक interval में उपयोग को vertical blocks में जोड़ता है। **Colors** clickable legend है; source चुनकर chart focus करें। दिन चुनकर उस दिन से आगे का उपयोग देखें।

### Activity groups

Usage में चुने apps और websites साथ दिखाने के लिए group बनाएं। **Merge** Activity भर उसके सदस्यों के लिए एक नाम और रंग रखता है। Activity group recorded use व्यवस्थित करता है; blocking और tagging groups से अलग है। Editor को स्पष्ट रूप से **Save** करें।

### Recording and retention

**Recording** में हर category या individual source का recording चालू/बंद करें। **Keep** history retention अवधि तय करता है; **Forever** auto-expiry रोकता है। Individual selections बड़ी setting का पालन कर सकती हैं। Recording बंद करने से नई recording रुकती है; history delete करने से recorded entries हटती हैं। Platform feeds supported pages पर दिखी सामग्री एकत्र करते हैं, चाहे page खोला हो या नहीं। **Tagging supported** feed recording चालू होने पर Content tagging को सामग्री दे सकता है। इसका retention app और website usage से अलग है। Tagging group pause करने से recording अपने-आप बंद नहीं होती।

## Settings

Settings में interface language चुनें। चुनी भाषा में field explanations छोटे Info buttons पर मिलती हैं।

## Saving and troubleshooting

सामान्य Vault और Content tagging edits auto-save होते हैं। Activity group editor में **Save** दबाना होता है। Add, delete, connection tests और model-list fetch स्पष्ट actions हैं। Tags न दिखें तो browser connection, global tagging switch, group pause, platform recording, चुना connection/model और credentials जांचें। AI requests विफल हों तो connection/model, credentials, provider usage limits और group Log देखें। Linked group edit न हो तो programs reconnect करें या बताए अनुसार unfreeze करें।
