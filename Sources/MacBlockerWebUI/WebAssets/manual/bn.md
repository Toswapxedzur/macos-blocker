# Mac Vault ব্যবহারকারী নির্দেশিকা

Mac Vault-এর তিনটি পৃষ্ঠা: **Vault** নেটিভ অ্যাপ ব্লক করে, **Content tagging** সমর্থিত ব্রাউজার কনটেন্টে ট্যাগ দেয় এবং **Activity** রেকর্ড করা ব্যবহার দেখায়। ব্রাউজার এক্সটেনশন সমর্থিত কনটেন্ট সংগ্রহ করে এবং ব্রাউজার ব্লকিং প্রয়োগ করে। ব্যবহৃত ব্রাউজারে এটি ইনস্টল ও সংযোগ করুন।

## দ্রুত শুরু

1. **Vault**-এ blocking group ও Apps target যোগ করে + picker থেকে অ্যাপ বেছে নিন।
2. ব্লকিং আচরণ বেছে নিয়ে গ্রুপ চালু করুন।
3. **Content tagging**-এ গ্রুপ তৈরি করুন, platform বেছে নিন এবং বর্ণনাসহ tag যোগ করুন।
4. Settings → **AI connections**-এ ChatGPT subscription, OpenAI API, Gemini API বা Grok API বেছে নিন। অ্যাকাউন্ট সংযোগ করুন বা key দিন, model list আনুন, তারপর গ্রুপে connection/model বেছে নিন। Tagging চালু করে গ্রুপ resume করুন।
5. সংযুক্ত ব্রাউজারে সমর্থিত কনটেন্ট খুলুন। ট্যাগ দিয়ে ব্লকিং নিয়ন্ত্রণ চাইলে browser blocking group-এ tag filter দিন।

## Blocking groups

একটি blocking group ব্লকিং নীতি প্রয়োগ করে; Content tagging group কনটেন্টে ট্যাগ দেয়, নিজে ব্লক করে না। 1) গ্রুপ যোগ করে নাম দিন। 2) **Applies to**-তে target বেছে নিন। 3) কখন ব্লক হবে ঠিক করে schedule বা time allowance সেট করুন। 4) গ্রুপ চালু করুন; target-গুলো নীতি ভাগ করে। সাধারণ সম্পাদনা auto-save হয়। error মানে পরিবর্তন গৃহীত হয়নি। Disable করলে configuration থাকে; **Delete group** মুছে দেয়। Drag করে সাজান। একাধিক গ্রুপ একই target-এ লাগতে পারে; একটিকে snooze করলে অন্যটির block ওঠে না। **Export** কপি করে; **Import** নিশ্চিত করে নির্বাচিত group প্রতিস্থাপন করে।

### Time allowance and schedule

**Block immediately** সক্রিয় গ্রুপ ও schedule মিললে block করে। **Block when the time allowance is used** allowance শেষ হওয়া পর্যন্ত ব্যবহার দেয়। মিনিটে allowance, ঘণ্টায় reset interval দিন। Rolling limit আগের window-এর ব্যবহার গোনে। Midnight reset স্থানীয় মধ্যরাতে নতুন period শুরু করে, rolling limit হলেও। সক্রিয় weekday ও ঐচ্ছিক local-time window প্রতি লাইনে দিন, যেমন **09:00-12:00**। ফাঁকা window তালিকা নির্বাচিত দিনজুড়ে প্রযোজ্য। Window একই দিনে শুরু থেকে পরে শেষ হতে হবে; রাত পার হলে আলাদা দিনে ভাগ করুন।

### Snooze

প্রতি blocking group-এ snooze সেট করুন। **Pause blocking** pause duration-এ নীতি স্থগিত করে। **Add to the time allowance** time-limited group-এ ব্যবহারযোগ্য মিনিট যোগ করে। কেবল ব্যবহৃত অতিরিক্ত allowance snoozed time হিসেবে গোনে। অব্যবহৃত অংশ পরের reset-এ শেষ হয়; rolling limit-এ এক window পরে, অথবা চালু থাকলে midnight-এ আরও আগে। **Activation delay** block চালু রেখেই snooze পিছিয়ে দেয়। **Cooldown** snooze শেষে পরের অনুরোধের অপেক্ষা। **Required confirmations** confirmation ধাপের সংখ্যা। Frozen group-এ snooze কেবল freeze-এর আগে অনুমোদিত হলে পাওয়া যায়।

### Freeze and PIN

**Freeze** সাধারণ edit আটকায়। Unfreeze-এ ৫ সেকেন্ড ব্যবধানে দশটি confirmation, সেট করা wait এবং ছয় অঙ্কের PIN লাগে। **Wait before unfreezing** ০–৭২ ঘণ্টা; ০ মানে wait নেই। Frozen অবস্থায় wait বাড়ানো ও PIN যোগ করা যায়, কিন্তু unfreeze না করা পর্যন্ত শর্ত শিথিল করা যায় না। Delete-ও বাকি wait ও PIN মানে।

### Linked groups

**Link** দিয়ে অন্য Vault program-এর স্পষ্টভাবে নির্বাচিত group যুক্ত করুন। নাম, সমর্থিত policy setting, target, usage ও freeze condition ভাগ হয়। প্রতিটি program নিজের সমর্থিত target type edit ও enforce করে; অন্য target linked program-এ থাকে। **Unlink** group ও settings রেখে আলাদা করে। linked member offline হলে Mac Vault ও browser খুলে reconnect করুন। local saved policy offline অবস্থায়ও চলতে পারে.

**Blocking group** একটি ব্লকিং নীতি প্রয়োগ করে। **Content tagging group** কনটেন্টে tag দেয়, নিজে থেকে ব্লক করে না। গ্রুপের নাম দিন, **Applies to**-তে target বেছে নিন, কখন ব্লক হবে নির্ধারণ করে schedule বা time allowance দিন এবং গ্রুপ চালু করুন। সাধারণ সম্পাদনা স্বয়ংক্রিয়ভাবে সেভ হয়। ত্রুটি মানে পরিবর্তন গৃহীত হয়নি; ক্ষেত্র ঠিক করে আবার চেষ্টা করুন। গ্রুপ বন্ধ করলে কনফিগারেশন থাকে, **Delete group** মুছে দেয়। একাধিক গ্রুপ একই target-এ প্রযোজ্য হতে পারে; একটিকে snooze করলে অন্যটির ব্লক ওঠে না। **Export** কনফিগারেশন কপি করে; **Import** নিশ্চিতকরণের পর নির্বাচিত গ্রুপ প্রতিস্থাপন করে।

**Block immediately** সক্রিয় গ্রুপ ও সময়সূচি মিলে গেলে ব্লক করে। **Block when the time allowance is used** allowance শেষ না হওয়া পর্যন্ত ব্যবহার করতে দেয়. Allowance-ஐ মিনিটে, reset interval-ஐ ঘণ্টায় নির্ধারণ করুন. Rolling limit আগের window-এর பயன்பாட்டைக் கணக்கிடும். সক্রিয় weekday এবং ঐচ্ছিক local-time window প্রতি লাইনে দিন, যেমন **09:00-12:00**; ফাঁকা তালিকা নির্বাচিত দিনগুলো জুড়ে প্রযোজ্য। রাত পার হওয়া সময়সূচি আলাদা দিনে ভাগ করুন।

প্রতি গ্রুপে snooze নির্ধারণ করুন। **Pause blocking** নির্দিষ্ট সময় নীতিটি থামায়; **Add to the time allowance** সীমিত গ্রুপে ব্যবহারযোগ্য মিনিট যোগ করে। ব্যবহৃত অতিরিক্ত allowance-ই snoozed time; অব্যবহৃত অংশ পরের reset-এ মুছে যায়। **Activation delay**, **Cooldown**, **Required confirmations** যথাক্রমে শুরু বিলম্ব, পরবর্তী অনুরোধের অপেক্ষা ও নিশ্চিতকরণের সংখ্যা নির্ধারণ করে। **Freeze** সাধারণ সম্পাদনা আটকায়। Unfreeze করতে ৫ সেকেন্ড ব্যবধানে ১০টি confirmation, নির্ধারিত অপেক্ষা এবং ছয় অঙ্কের PIN লাগে। অপেক্ষা ০–৭২ ঘণ্টা; ০ মানে অপেক্ষা নেই। Frozen অবস্থায় শর্ত কঠোর করা যায়, দুর্বল করা যায় না; মুছতেও অপেক্ষা ও PIN মানতে হয়।

**Link** অন্য Vault প্রোগ্রামের বেছে নেওয়া গ্রুপ যুক্ত করে; নাম, সমর্থিত নীতি, লক্ষ্য, ব্যবহার ও freeze শর্ত ভাগ হয়। প্রতিটি প্রোগ্রাম নিজের সমর্থিত target সম্পাদনা ও প্রয়োগ করে। **Unlink** গ্রুপ ও সেটিংস রেখে সংযোগ সরায়। অফলাইন সদস্য থাকলে Mac Vault ও সংযুক্ত ব্রাউজার খুলে পুনঃসংযোগ করুন।

## Getting help

Field-এর পাশে **i** চাপলে ব্যাখ্যা; বাইরে click বা Escape চাপলে বন্ধ হয়। তালিকা scrollable box-এ থাকে; search দৃশ্যমান item ছাঁকে, মুছে না। কাস্টম নিয়মের [Code manual](../code-manual/bn.md)-এ editor, activation, logs, file access ও API ব্যাখ্যা করা আছে।

## Native apps

ক্ষেত্রের পাশে **i** চাপলে ব্যাখ্যা দেখা যায়; বাইরে ক্লিক বা Escape চাপলে বন্ধ হয়। তালিকা scroll box-এ থাকে, search দৃশ্যমান তালিকা ছাঁকে—মুছে না। কাস্টম নিয়মের [Code manual](../code-manual/bn.md)-এ editor, activation, logs, file access ও API আছে। Apps target-এর + picker-এ ইনস্টল বা চলমান অ্যাপ বেছে নিন; অন্য ফোল্ডার থেকে অ্যাপ চালালে picker আবার খুলে তালিকা refresh করুন। **Block every app except these** allowlist করে। Mac Vault সাধারণ Apple app ও পুরো browser ব্লক করতে পারে; Mac Vault নিজে ও একই bundle ID-র অ্যাপ সুরক্ষিত। ব্লকড অ্যাপকে quit করতে বলা হয়; retry ব্যবধান নির্ধারণ করে **Ask a blocked app to quit again every (minutes)**। সাইট redirect, page pause, feed hiding এক্সটেনশন সামলায়।

## Content tagging

Content tagging group নির্ধারিত platform-এর content-এ নিজস্ব tag tree ও model settings দিয়ে tag দেয়। প্রতিটি platform একটি group-এর; তৈরি করার সময় বেছে নিন, পরে বদলানো যায় না। Blocking schedule/filter tagging নিয়ন্ত্রণ করে না। Settings-এ tagging চালু করুন; প্রতিটি group-এর **Pause tagging / Resume tagging** আলাদা। **Activity → Recording**-এ platform feed recording বন্ধ করলে tagging-ও থামে।

### Tags and model settings

Tag তৈরি, অর্থ বর্ণনা, parent যোগ/সরানো tree-তে করুন; drag করলে branch চলে। পরিষ্কার description অনুরূপ tag পৃথক করতে model-কে সাহায্য করে। প্রতিটি group-এর setting আলাদা। **Minimum confidence** প্রতিটি predicted tag-এর evidence grade ১–৫; নতুন group ৪ (strong support) থেকে শুরু। নির্দিষ্ট tag count নেই; item-এ tag নাও থাকতে পারে। **Tagging instructions** group-এর পছন্দ ধরে রাখে। সাধারণ edit auto-save হয়; group স্পষ্টভাবে নির্বাচিত connection, model ও reasoning effort ব্যবহার করে।

### AI connections

প্রতি platform একটি tagging group-এর। তৈরির সময় platform বেছে নিন; পরে বদলানো যায় না। Blocking schedule/filter tagging নিয়ন্ত্রণ করে না। Settings-এ tagging চালু করুন; প্রতিটি গ্রুপ আলাদাভাবে **Pause tagging / Resume tagging** করুন। **Activity → Recording**-এ feed recording বন্ধ করলে tagging-ও থামে। Tag tree-তে tag, বর্ণনা, parent যোগ/বদল করুন; drag করে branch সরান। **Minimum confidence** ১–৫ evidence grade; নতুন গ্রুপ ৪-এ শুরু হয় এবং tag সংখ্যা বাধ্যতামূলক নয়। **Tagging instructions** গ্রুপের পছন্দ সংরক্ষণ করে। প্রতিটি গ্রুপে নির্দিষ্ট connection, model ও reasoning effort থাকে।

**AI connections**-এ ChatGPT subscription, OpenAI API, Gemini API, Grok API আছে। Subscription Vault-এর sign-in/যোগ্য plan ব্যবহার করে; API key নির্বাচিত provider-এর billing ও limits মেনে চলে। Provider বেছে dropdown-এর নিচে key দিন; পরিবর্তন auto-save হয়, খালি করলে মুছে যায়। **Fetch model list**-এর পর গ্রুপে model বেছে নিন; fetch নিজে model নির্বাচন করে না। **Reasoning effort** default/Low/Medium/High; নতুন পছন্দ Medium, আগের পছন্দ সংরক্ষিত। বেশি effort সময় ও token বাড়াতে পারে। Web search tagging-এ সর্বদা সক্রিয়; model ঠিক করে কখন ব্যবহার করবে। ব্যর্থ অনুরোধে বৈধ cached result থাকে; নতুন item unresolved থাকে যতক্ষণ না **Retry cloud classification** বেছে নেন। Provider স্বয়ংক্রিয়ভাবে বদলায় না। Browser extension-এ **+ tag** দিয়ে যোগ করুন; remove control বা tag নির্বাচন করে Delete একবার দিয়ে সরান। **Untagged** সম্পন্ন কিন্তু tag নেই; **Tagging** ফল pending। আপনার সংশোধন ওই item-এর জন্য কার্যকর থাকে।

## Activity

Activity চালু app use, website visit ও সমর্থিত **Content viewed** স্থানীয়ভাবে record করে। Chart record-করা data দেখায়; ফাঁকা অংশ Mac idle ছিল প্রমাণ করে না। Date range বেছে নিন। **Timeline** দিনের সময় অনুযায়ী, **Totals** duration যোগ করে, **Time interval** interval-এ ব্যবহার vertical block-এ দেখায়। **Colors** clickable legend; source বেছে chart ফোকাস করুন। দিন বেছে সেই দিন থেকে ব্যবহার দেখুন।

### Activity groups

Usage-এ নির্বাচিত app ও website একসঙ্গে দেখাতে group তৈরি করুন। **Merge** সদস্যদের জন্য Activity জুড়ে একই নাম ও রঙ ব্যবহার করে। Activity group রেকর্ড করা ব্যবহার সাজায়; blocking বা tagging group থেকে আলাদা। Editor-এ **Save** চাপুন।

### Recording and retention

**Recording**-এ category বা individual source-এ recording চালু/বন্ধ করুন। **Keep** history কতদিন থাকবে; **Forever** স্বয়ংক্রিয় মেয়াদ শেষ করে না। Individual choice বৃহত্তর setting অনুসরণ করতে পারে। Recording বন্ধ করলে নতুন record থামে; history delete করলে record entry মুছে যায়। Platform feed supported page-এ প্রদর্শিত content সংগ্রহ করে, পৃষ্ঠা খোলা না হলেও। **Tagging supported** feed recording চালু থাকলে Content tagging-এ তথ্য দিতে পারে। এর retention app ও website usage থেকে আলাদা। Tagging group pause করলেই recording বন্ধ হয় না।

## Settings

Settings-এ interface language বেছে নিন। Field ব্যাখ্যা নির্বাচিত ভাষার Info button-এ পাওয়া যায়।

## Saving and troubleshooting

Activity স্থানীয়ভাবে app use, website visit ও সমর্থিত **Content viewed** রেকর্ড করে; ফাঁকা chart মানে Mac নিষ্ক্রিয় ছিল এমন নয়। তারিখ বেছে নিন: **Timeline** দিনের সময় দেখায়, **Totals** সময় যোগ করে, **Time interval** interval-এ ব্যবহার একত্র করে। **Colors** legend-এ source বেছে chart ফোকাস করুন। Activity group Usage-এ app/site একত্র করে; **Merge** সদস্যদের এক নাম/রঙ দেয়। এটি blocking/tagging group থেকে আলাদা; editor-এ **Save** চাপুন। **Recording**-এ category/source অনুযায়ী রেকর্ডিং চালু-বন্ধ করুন। **Keep** retention, **Forever** মেয়াদহীন রাখে; recording বন্ধ করলে নতুন তথ্য থামে, history delete করলে পুরনো entry মুছে যায়। Platform feed সমর্থিত পৃষ্ঠায় প্রদর্শিত কনটেন্ট সংগ্রহ করে; **Tagging supported** feed recording চললে tagging দিতে পারে।

Settings-এ interface language বেছে নিন; Info button-এ ব্যাখ্যা মেলে। Vault ও tagging edit auto-save হয়; Activity group-এ **Save** লাগে। Add, delete, connection test ও model fetch আলাদা action। Tag না এলে browser connection, global tagging, pause, platform recording, connection/model ও credentials দেখুন। AI request ব্যর্থ হলে provider limits ও group Log-ও দেখুন। Linked group সম্পাদনা না হলে reconnect বা নির্দেশমতো unfreeze করুন।
