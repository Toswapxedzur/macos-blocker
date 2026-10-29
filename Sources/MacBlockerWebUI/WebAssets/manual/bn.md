# Mac Vault ব্যবহারকারী নির্দেশিকা

Mac Vault-এর তিনটি পৃষ্ঠা: **Vault** নেটিভ অ্যাপ ব্লক করে, **কনটেন্ট ট্যাগিং** সমর্থিত ব্রাউজার কনটেন্টে ট্যাগ দেয় এবং **কার্যকলাপ** রেকর্ড করা ব্যবহার দেখায়। ব্রাউজার এক্সটেনশন সমর্থিত কনটেন্ট সংগ্রহ করে এবং ব্রাউজার ব্লকিং প্রয়োগ করে। ব্যবহৃত ব্রাউজারে এটি ইনস্টল ও সংযোগ করুন।

## দ্রুত শুরু

1. **Vault**-এ ব্লকিং গ্রুপ ও Apps target যোগ করে + picker থেকে অ্যাপ বেছে নিন।
2. ব্লকিং আচরণ বেছে নিয়ে গ্রুপ চালু করুন।
3. **কনটেন্ট ট্যাগিং**-এ গ্রুপ তৈরি করুন, platform বেছে নিন এবং বর্ণনাসহ tag যোগ করুন।
4. সেটিংস → **AI সংযোগ**-এ ChatGPT subscription, OpenAI API, Gemini API বা Grok API বেছে নিন। অ্যাকাউন্ট সংযোগ করুন বা key দিন, model list আনুন, তারপর গ্রুপে connection/model বেছে নিন। Tagging চালু করে গ্রুপ resume করুন।
5. সংযুক্ত ব্রাউজারে সমর্থিত কনটেন্ট খুলুন। ট্যাগ দিয়ে ব্লকিং নিয়ন্ত্রণ চাইলে browser ব্লকিং গ্রুপ-এ tag filter দিন।

## ব্লকিং গ্রুপ

একটি ব্লকিং গ্রুপ ব্লকিং নীতি প্রয়োগ করে; কনটেন্ট ট্যাগিং কনটেন্টে ট্যাগ দেয়, নিজে ব্লক করে না। 1) গ্রুপ যোগ করে নাম দিন। 2) **প্রযোজ্য**-তে target বেছে নিন। 3) কখন ব্লক হবে ঠিক করে schedule বা time allowance সেট করুন। 4) গ্রুপ চালু করুন; target-গুলো নীতি ভাগ করে। সাধারণ সম্পাদনা auto-save হয়। error মানে পরিবর্তন গৃহীত হয়নি। Disable করলে configuration থাকে; **গ্রুপ মুছুন** মুছে দেয়। Drag করে সাজান। একাধিক গ্রুপ একই target-এ লাগতে পারে; একটিকে snooze করলে অন্যটির block ওঠে না। **রপ্তানি** কপি করে; **আমদানি** নিশ্চিত করে নির্বাচিত group প্রতিস্থাপন করে।

### সময়সীমা ও সময়সূচি

**Block immediately** সক্রিয় গ্রুপ ও schedule মিললে block করে। **Block when the time allowance is used** allowance শেষ হওয়া পর্যন্ত ব্যবহার দেয়। মিনিটে allowance, ঘণ্টায় reset interval দিন। Rolling limit আগের window-এর ব্যবহার গোনে। Midnight reset স্থানীয় মধ্যরাতে নতুন period শুরু করে, rolling limit হলেও। সক্রিয় weekday ও ঐচ্ছিক local-time window প্রতি লাইনে দিন, যেমন **09:00-12:00**। ফাঁকা window তালিকা নির্বাচিত দিনজুড়ে প্রযোজ্য। Window একই দিনে শুরু থেকে পরে শেষ হতে হবে; রাত পার হলে আলাদা দিনে ভাগ করুন।

### স্নুজ

প্রতি ব্লকিং গ্রুপ-এ snooze সেট করুন। **Pause blocking** pause duration-এ নীতি স্থগিত করে। **Add to the time allowance** time-limited group-এ ব্যবহারযোগ্য মিনিট যোগ করে। কেবল ব্যবহৃত অতিরিক্ত allowance snoozed time হিসেবে গোনে। অব্যবহৃত অংশ পরের reset-এ শেষ হয়; rolling limit-এ এক window পরে, অথবা চালু থাকলে midnight-এ আরও আগে। **Activation delay** block চালু রেখেই snooze পিছিয়ে দেয়। **Cooldown** snooze শেষে পরের অনুরোধের অপেক্ষা। **Required confirmations** confirmation ধাপের সংখ্যা। Frozen group-এ snooze কেবল freeze-এর আগে অনুমোদিত হলে পাওয়া যায়।

### ফ্রিজ ও PIN

**Freeze** সাধারণ edit আটকায়। Unfreeze-এ ৫ সেকেন্ড ব্যবধানে দশটি confirmation, সেট করা wait এবং ছয় অঙ্কের PIN লাগে। **Wait before unfreezing** ০–৭২ ঘণ্টা; ০ মানে wait নেই। Frozen অবস্থায় wait বাড়ানো ও PIN যোগ করা যায়, কিন্তু unfreeze না করা পর্যন্ত শর্ত শিথিল করা যায় না। Delete-ও বাকি wait ও PIN মানে।

### লিঙ্ক করা গ্রুপ

**লিঙ্ক** দিয়ে অন্য Vault program-এর স্পষ্টভাবে নির্বাচিত group যুক্ত করুন। নাম, সমর্থিত policy setting, target, usage ও freeze condition ভাগ হয়। প্রতিটি program নিজের সমর্থিত target type edit ও enforce করে; অন্য target linked program-এ থাকে। **আনলিঙ্ক** group ও settings রেখে আলাদা করে। linked member offline হলে Mac Vault ও browser খুলে reconnect করুন। local saved policy offline অবস্থায়ও চলতে পারে.
## সহায়তা

Field-এর পাশে **i** চাপলে ব্যাখ্যা; বাইরে click বা Escape চাপলে বন্ধ হয়। তালিকা scrollable box-এ থাকে; search দৃশ্যমান item ছাঁকে, মুছে না। কাস্টম নিয়মের [Code manual](../code-manual/bn.md)-এ editor, activation, logs, file access ও API ব্যাখ্যা করা আছে।

## নেটিভ অ্যাপ

Apps target-এর + picker-এ ইনস্টল করা বা বর্তমানে চলমান app বেছে নিন। অন্য folder থেকে app চালু করলে তালিকা refresh করতে picker আবার খুলুন। **এখানে তালিকাভুক্ত অ্যাপ ছাড়া সব অ্যাপ ব্লক করুন** তালিকাকে allowlist করে। Mac Vault সাধারণ Apple app এবং সম্পূর্ণ browser block করতে পারে; Mac Vault নিজে এবং একই bundle identifier-সহ app সুরক্ষিত থাকে। ব্লক করা app-কে স্বাভাবিকভাবে quit করতে বলা হয়; **حোল্ড করা অ্যাপকে আবার বন্ধ হতে বলুন প্রতি (মিনিটে)** পুনরায় অনুরোধের ব্যবধান নির্ধারণ করে। Website redirect, page pause এবং feed লুকানো browser extension প্রয়োগ করে; এগুলো native app-এর কাজ নয়।

## কনটেন্ট ট্যাগিং

কনটেন্ট ট্যাগিং নির্ধারিত platform-এর content-এ নিজস্ব tag tree ও model settings দিয়ে tag দেয়। প্রতিটি platform একটি group-এর; তৈরি করার সময় বেছে নিন, পরে বদলানো যায় না। Blocking schedule/filter tagging নিয়ন্ত্রণ করে না। সেটিংস-এ tagging চালু করুন; প্রতিটি group-এর **ট্যাগ দেওয়া বিরতি দিন / ট্যাগ দেওয়া আবার শুরু করুন** আলাদা। **কার্যকলাপ → রেকর্ডিং**-এ platform feed recording বন্ধ করলে tagging-ও থামে।

### ট্যাগ ও মডেল সেটিং

Tag তৈরি, অর্থ বর্ণনা, parent যোগ/সরানো tree-তে করুন; drag করলে branch চলে। পরিষ্কার description অনুরূপ tag পৃথক করতে model-কে সাহায্য করে। প্রতিটি group-এর setting আলাদা। **tag-এর ন্যূনতম confidence** প্রতিটি predicted tag-এর evidence grade ১–৫; নতুন group ৪ (strong support) থেকে শুরু। নির্দিষ্ট tag count নেই; item-এ tag নাও থাকতে পারে। **ট্যাগিং নির্দেশনা** group-এর পছন্দ ধরে রাখে। সাধারণ edit auto-save হয়; group স্পষ্টভাবে নির্বাচিত connection, model ও reasoning effort ব্যবহার করে।

### AI সংযোগ

**AI সংযোগ**-এ ChatGPT subscription, OpenAI API, Gemini API, Grok API আছে। Subscription Vault-এর sign-in/যোগ্য plan ব্যবহার করে; API key নির্বাচিত provider-এর billing ও limits মেনে চলে। Provider বেছে dropdown-এর নিচে key দিন; পরিবর্তন auto-save হয়, খালি করলে মুছে যায়। **মডেলের তালিকা আনুন**-এর পর গ্রুপে model বেছে নিন; fetch নিজে model নির্বাচন করে না। **যুক্তির মাত্রা** default/Low/Medium/High; নতুন পছন্দ Medium, আগের পছন্দ সংরক্ষিত। বেশি effort সময় ও token বাড়াতে পারে। Web search tagging-এ সর্বদা সক্রিয়; model ঠিক করে কখন ব্যবহার করবে। ব্যর্থ অনুরোধে বৈধ cached result থাকে; নতুন item unresolved থাকে যতক্ষণ না **cloud classification আবার চেষ্টা করুন** বেছে নেন। Provider স্বয়ংক্রিয়ভাবে বদলায় না। প্রতিটি connection-এর নিজস্ব retry interval এবং attempt limit আছে। Browser extension-এ **+ tag** দিয়ে যোগ করুন; remove control বা tag নির্বাচন করে Delete একবার দিয়ে সরান। **ট্যাগবিহীন** সম্পন্ন কিন্তু tag নেই; **ট্যাগ করা হচ্ছে** ফল pending। আপনার সংশোধন ওই item-এর জন্য কার্যকর থাকে।

## কার্যকলাপ

কার্যকলাপ সক্রিয় app ব্যবহার, website visit এবং সমর্থিত **দেখা কনটেন্ট** স্থানীয়ভাবে রেকর্ড করে। Chart রেকর্ড করা data দেখায়; ফাঁকা অংশ Mac idle ছিল প্রমাণ করে না। Date range বেছে নিন। **টাইমলাইন** দিনের সময় অনুযায়ী ব্যবহার দেখায়; **মোট** duration যোগ করে; **সময়ের ব্যবধান** প্রতিটি interval-এর ব্যবহার vertical block-এ একত্র করে। **রং** clickable legend; source বেছে chart-কে সেটিতে ফোকাস করুন। দিন বেছে সেই দিন থেকে ব্যবহার দেখুন।

### কার্যকলাপ groups

Usage-এ নির্বাচিত app ও website একসঙ্গে দেখাতে group তৈরি করুন। **Merge** কার্যকলাপ জুড়ে সদস্যদের এক নাম ও রঙ দেয়। কার্যকলাপ group রেকর্ড করা ব্যবহার সাজায়; ব্লকিং গ্রুপ ও কনটেন্ট ট্যাগিং থেকে আলাদা। Editor-এ **Save** চাপুন।

### রেকর্ডিং ও সংরক্ষণকাল

**রেকর্ডিং**-এ category বা individual source-এর recording চালু/বন্ধ করুন। **রাখুন** history কতদিন থাকবে তা নির্ধারণ করে; **চিরকাল**-এ স্বয়ংক্রিয় মেয়াদ নেই। Individual পছন্দ বৃহত্তর setting অনুসরণ করতে পারে। রেকর্ডিং বন্ধ করলে নতুন record থামে; history delete করলে রেকর্ডকৃত entry মুছে যায়। Platform feed supported page-এ প্রদর্শিত content সংগ্রহ করে, page খোলা না হলেও। **ট্যাগিং সমর্থিত** feed recording চালু থাকলে কনটেন্ট ট্যাগিং-এ তথ্য দিতে পারে। এর retention app ও website ব্যবহারের থেকে আলাদা। Tagging group pause করলেই recording বন্ধ হয় না।

## সেটিংস

সেটিংস-এ interface language বেছে নিন। নির্বাচিত ভাষায় field explanation ছোট Info button-এ পাওয়া যায়।

## সংরক্ষণ ও সমস্যা সমাধান

সাধারণ Vault ও কনটেন্ট ট্যাগিং edit auto-save হয়। কার্যকলাপ group editor-এ **Save** লাগে। Add, delete, connection test ও model-list fetch স্পষ্ট action। Tag না এলে browser connection, global tagging switch, group pause, platform recording, নির্বাচিত connection/model ও credentials দেখুন। AI request ব্যর্থ হলে connection/model, credentials, provider usage limit ও group Log পরীক্ষা করুন। Linked group edit করা না গেলে program reconnect করুন বা নির্দেশমতো unfreeze করুন।
