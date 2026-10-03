# Mac Vault ব্যবহারকারী নির্দেশিকা

Mac Vault-এ তিনটি পৃষ্ঠা আছে: native app ব্লক করতে **Vault**, সমর্থিত browser content-এ tag দিতে **শ্রেণিবিন্যাস**, এবং রেকর্ড করা ব্যবহার দেখাতে **কার্যকলাপ**। Browser extension সমর্থিত content সংগ্রহ ও browser blocking প্রয়োগ করে। ব্যবহৃত browser-এ এটি install ও connect করুন।

## দ্রুত শুরু

1. **Vault**-এ blocking group যোগ করে Apps target দিন, তারপর + picker দিয়ে app নির্বাচন করুন।
2. Group-এর blocking behavior বেছে চালু করুন।
3. **শ্রেণিবিন্যাস**-এ group তৈরি করে platform বেছে tag ও description যোগ করুন।
4. local model tier বেছে প্রয়োজন হলে download করুন। শ্রেণিবিন্যাস settings-এ tagging চালু করে group resume করুন।
5. connected browser-এ supported content খুলুন। Tag দিয়ে blocking নিয়ন্ত্রণ করতে চাইলে browser blocking group-এ tag filter configure করুন।

## ব্লকিং গ্রুপ

**ব্লকিং গ্রুপ** একটি ব্লকিং নীতি প্রয়োগ করে। **শ্রেণিবিন্যাস গ্রুপ** কনটেন্টে ট্যাগ দেয়; এটি নিজে কিছু ব্লক করে না।

1. একটি ব্লকিং গ্রুপ যোগ করে নাম দিন।
2. **প্রযোজ্য**-এর অধীনে লক্ষ্য বেছে নিন।
3. কখন ব্লকিং প্রযোজ্য হবে বেছে নিয়ে সময়সূচি বা সময়সীমা সেট করুন।
4. গ্রুপ চালু করুন। এর লক্ষ্যগুলো একই নীতি মেনে চলে।

সাধারণ সম্পাদনা স্বয়ংক্রিয়ভাবে সংরক্ষিত হয়। ত্রুটি মানে পরিবর্তন গৃহীত হয়নি; ক্ষেত্রটি ঠিক করে আবার চেষ্টা করুন। সেটিং রেখে নীতি বন্ধ করতে গ্রুপ নিষ্ক্রিয় করুন। **গ্রুপ মুছুন** এটি সরায়। গ্রুপগুলো টেনে সাজান। একাধিক গ্রুপ একই লক্ষ্যে প্রযোজ্য হতে পারে; একটির বিরতি অন্যটির ব্লক সরায় না।

**রপ্তানি** গ্রুপের কনফিগারেশন কপি করে। **আমদানি** নিশ্চিত করার পর নির্বাচিত গ্রুপের কনফিগারেশন প্রতিস্থাপন করে।

### সময়সীমা ও সময়সূচি

**তাৎক্ষণিকভাবে ব্লক করুন** সক্রিয় গ্রুপের লক্ষ্য মিলে গেলে এবং সময়সূচি চললে প্রয়োগ হয়। **সময়সীমা শেষ হলে ব্লক করুন** নির্ধারিত সময় শেষ হওয়া পর্যন্ত মিলে যাওয়া ব্যবহার অনুমোদন করে।

সময়সীমা মিনিটে এবং রিসেট ব্যবধান ঘণ্টায় নির্ধারণ করুন। চলমান সীমা আগের সময়-উইন্ডোর ব্যবহার গণনা করে। মধ্যরাতে রিসেট স্থানীয় মধ্যরাতে নতুন সময়কাল শুরু করে, চলমান সীমার ক্ষেত্রেও।

সক্রিয় সপ্তাহের দিন এবং ঐচ্ছিক স্থানীয় সময়ের উইন্ডো বেছে নিন—প্রতি লাইনে একটি, যেমন **09:00-12:00**। উইন্ডোর তালিকা ফাঁকা হলে নির্বাচিত দিনগুলো জুড়ে প্রযোজ্য হয়। একই দিনে উইন্ডোর শেষ সময় শুরুর পরে হতে হবে; রাত পেরোনো সময়সূচি আলাদা দিনে ভাগ করুন।

### সাময়িক বিরতি

প্রতিটি ব্লকিং গ্রুপে বিরতি কনফিগার করুন। **ব্লকিং বিরতি দিন** নির্দিষ্ট সময়ের জন্য ওই গ্রুপের নীতি স্থগিত করে। **সময়সীমায় যোগ করুন** সময়সীমাযুক্ত গ্রুপে ব্যবহারযোগ্য মিনিট যোগ করে। ব্যবহৃত অতিরিক্ত সময়ই কেবল বিরতির সময় হিসেবে গণ্য হয়। অব্যবহৃত অতিরিক্ত সময় পরবর্তী রিসেটে শেষ হয়; চলমান সীমার ক্ষেত্রে একটি উইন্ডোর পরে, অথবা সক্রিয় থাকলে মধ্যরাতে তারও আগে।

**সক্রিয়করণ বিলম্ব** ব্লকিং চলার সময় বিরতি শুরু পিছিয়ে দেয়। **কুলডাউন** বিরতি শেষ হওয়ার পর আরেকটি অনুরোধের আগের অপেক্ষা। **প্রয়োজনীয় নিশ্চিতকরণ** নিশ্চিতকরণ ধাপের সংখ্যা নির্ধারণ করে। ফ্রিজ করা গ্রুপে বিরতি কেবল ফ্রিজের আগে অনুমোদিত থাকলেই পাওয়া যায়।

### সম্পাদনা লক ও PIN

**ফ্রিজ** সাধারণ সম্পাদনা বন্ধ করে। আনফ্রিজ করতে দশটি নিশ্চিতকরণ লাগে, প্রতিটির মাঝে পাঁচ সেকেন্ড, এবং সেট করা অপেক্ষা ও ছয় অঙ্কের PIN। **আনফ্রিজের আগে অপেক্ষা** 0–72 ঘণ্টা গ্রহণ করে; 0 মানে অতিরিক্ত অপেক্ষা নেই।

ফ্রিজ থাকা অবস্থায় অপেক্ষার সময় বাড়ানো এবং PIN না থাকলে যোগ করা যায়। গ্রুপ আনফ্রিজ না করা পর্যন্ত এসব শর্ত শিথিল করা যায় না। মুছতেও অবশিষ্ট অপেক্ষা ও PIN প্রযোজ্য।

### সংযুক্ত গ্রুপ

অন্যান্য Vault প্রোগ্রামে স্পষ্টভাবে নির্বাচিত গ্রুপগুলো যুক্ত করতে **সংযুক্ত করুন** ব্যবহার করুন। সংযুক্ত গ্রুপ নাম, সমর্থিত নীতি-সেটিং, লক্ষ্য, ব্যবহার এবং ফ্রিজ-শর্ত ভাগ করে। প্রতিটি প্রোগ্রাম সমর্থিত লক্ষ্য সম্পাদনা ও কার্যকর করে; অন্য লক্ষ্যগুলো সংযুক্ত প্রোগ্রামের জন্য থাকে। সংযোগ বিচ্ছিন্ন করলে প্রতিটি গ্রুপ ও সেটিং অক্ষত থাকে।

Connected member offline হলে editing অনুপলব্ধ হতে পারে। পুনঃসংযোগে Mac Vault ও linked browser খুলুন। Member offline থাকলেও locally saved policy প্রযোজ্য থাকতে পারে।

## সহায়তা নিন

ক্ষেত্রের পাশে ছোট **i**-তে ক্লিক করে ব্যাখ্যা দেখুন। বন্ধ করতে বাইরে ক্লিক করুন বা Escape চাপুন। তালিকা স্ক্রলযোগ্য বাক্সে থাকে; আরও আইটেম দেখতে বাক্সটি স্ক্রল করুন। অনুসন্ধান আইটেম না মুছে দৃশ্যমান তালিকা ফিল্টার করে।

কাস্টম নিয়মের নিজস্ব [কোড নির্দেশিকা](../code-manual/bn.md) আছে। এতে সম্পাদক, সক্রিয়করণ, লগ, ফাইল অ্যাক্সেস এবং সমর্থিত API ব্যাখ্যা করা হয়েছে।

## Native app

Installed app বাছতে Apps target-এর + picker ব্যবহার করুন। **এইগুলো ছাড়া সব app ব্লক করুন** তালিকাকে allowlist করে। System app, browser এবং Vault নিজে native app blocking থেকে বাদ।

Blocked app-কে quit করার অনুরোধ করা হয়। **প্রতি (মিনিট) পরে blocked app-কে আবার quit বলতে হবে** retry নিয়ন্ত্রণ করে। Website redirect, page pause ও feed hiding browser extension প্রয়োগ করে; এগুলো native app action নয়।

## শ্রেণিবিন্যাস

শ্রেণিবিন্যাস group নিজস্ব tag tree ও model settings দিয়ে নির্ধারিত platform-এর content tag করে। প্রতিটি platform একটি group-এর অন্তর্ভুক্ত। Group তৈরির সময় platform বেছে নিন; পরে বদলানো যায় না। Blocking group-এর schedule ও filter tagging নিয়ন্ত্রণ করে না।

শ্রেণিবিন্যাস settings-এ tagging চালু করুন। প্রতিটি group-এর **Tagging বিরতি দিন / Tagging আবার শুরু করুন** আলাদাভাবে ব্যবহার করুন। **কার্যকলাপ → Recording**-এ platform feed recording বন্ধ করলেও tagging থামে।

### Tag ও model settings

Tag তৈরি করে অর্থ লিখুন, tag tree-তে parent নির্ধারণ বা সরান। Tag টেনে branch সরান। পরিষ্কার description model-কে কাছাকাছি tag আলাদা করতে সাহায্য করে। প্রতিটি group-এর setting আলাদা।

- **গতি ↔ গুণমান** local model tier বেছে নেয়। বড় model বেশি memory ব্যবহার করে; গতি ও ফল Mac ও কাজের ওপর নির্ভর করে। Group-গুলোর মধ্যে download ভাগাভাগি হয়।
- **কঠোর ↔ বিস্তৃত** confidence requirement ও default tag count নির্ধারণ করে।
- More-এর **সর্বনিম্ন tag / সর্বোচ্চ tag** default count বদলায়। অতিরিক্ত tag-এর confidence **কঠোর ↔ বিস্তৃত** নিয়ন্ত্রণ করে। Default চাইলে ক্ষেত্র ফাঁকা রাখুন।
- **Tagging instruction** এই group-এর ঐচ্ছিক নির্দেশ যোগ করে।

সাধারণ শ্রেণিবিন্যাস সম্পাদনা স্বয়ংক্রিয়ভাবে সংরক্ষিত হয়। Content tag করার আগে নির্বাচিত tier download করতে হবে। একই tier-ব্যবহারকারী group একই loaded model ভাগ করে; একসঙ্গে সর্বোচ্চ দুই tier loaded থাকতে পারে।

Browser extension-এ content item-এর tag সংশোধন করুন। **+ tag** ক্লিক করে শ্রেণিবিন্যাসের বিদ্যমান tag খুঁজে যোগ করার জন্য বেছে নিন। Tag-এর remove control ব্যবহার করুন বা সেটি নির্বাচন করে একবার Delete চাপুন। **ট্যাগবিহীন** মানে tagging শেষ, tag নেই; **ট্যাগ হচ্ছে** মানে ফল অপেক্ষমাণ। সংশোধন ভবিষ্যৎ tagging-এ সহায়তা করে।

## জ্ঞান ও web research

জ্ঞান Mac-এ local tagging model-এর জন্য সংক্ষিপ্ত description সংরক্ষণ করে। **Content source**-এ creator, account, channel ও community থাকে। Source description তাদের content-এর সঙ্গে ব্যবহৃত হয়। শিরোনামে term থাকলে **পরিচিত term** প্রযোজ্য।

একটি source বা term এবং description যোগ করুন; অথবা research চালু থাকলে research চাইতে description ফাঁকা রাখুন। Creator suggestion শ্রেণিবিন্যাসের সংগৃহীত source খুঁজতে সাহায্য করে। ছয় বা বেশি entry-র list-এ ঠিক ওপরেই search থাকে: Terms ও প্রতিটি platform-এর Content source-এর নাম, ID বা description-এর জন্য আলাদা search। Description edit করলে ভবিষ্যৎ tagging বদলায়; source knowledge delete করলেও পরে research তা আবার তৈরি করতে পারে।

### Research provider সেটআপ

1. **শ্রেণিবিন্যাস settings → API key ও provider** খুলুন।
2. Provider type ও **Add provider** বেছে নিন। এতে configuration তৈরি হয়, API key ইস্যু হয় না।
3. Provider থেকে credential নিয়ে লিখুন। সামঞ্জস্যপূর্ণ custom endpoint হলে endpoint ও protocol field-ও configure করুন।
4. **Web research**-এ built-in web search-সহ provider বেছে নিন। Model list fetch করে research model নির্বাচন করুন। Model chooser-এর search দিয়ে তালিকা ছোট করুন; refresh করলে আবার fetch হবে।
5. Consent notice পড়ে consent চালু করুন। প্রতিটি group-এ **On**, **Off**, অথবা **শ্রেণিবিন্যাস settings অনুসরণ করুন** বেছে নিন।

Configuration না থাকলে **Web research সেটআপ…** settings-এ নিয়ে যায়। Group research consent এড়াতে পারে না। **Test connection** test request সফল হয়েছে নিশ্চিত করে; সব model research সমর্থন করে তা নয়। Provider-এর test model নির্বাচিত research model থেকে আলাদা।

Key Mac-এ app-এর support folder-এ থাকে, system Keychain-এ নয়। এগুলো configured provider-এ request authenticate করে; Vault নিজ server-এ upload করে না। Research sanitized public subject নির্বাচিত provider-এ পাঠায়, ব্যক্তিগত content body বা summary নয়। ঠিক কোন field পাঠানো হয় জানতে consent notice পড়ুন। Provider usage-এ connection test ও model-list request-ও আছে।

Research status-এ queued request, retry cooldown, failure ও আজকের token usage দেখায়। **এখন ব্যর্থ subject আবার চেষ্টা করুন** যোগ্য failure retry করে; দৈনিক limit বা consent এড়ায় না।

## কার্যকলাপ

কার্যকলাপ চালু app use, website visit ও supported **দেখা content** স্থানীয়ভাবে রেকর্ড করে। Chart রেকর্ড করা তথ্য দেখায়; ফাঁকা অংশ Mac নিষ্ক্রিয় ছিল তা প্রমাণ করে না।

Date range বেছে নিন। **Timeline** ব্যবহারের দিনের সময় দেখায়; **Totals** duration যোগ করে। **Time interval** প্রতি interval-এর ব্যবহার vertical block-এ একত্র করে। **Colors** clickable legend: source বেছে chart-এ সেটিতে focus করুন। কোনো দিন বেছে সেই দিন থেকে ব্যবহার দেখুন।

### কার্যকলাপ group

Usage-এ নির্বাচিত app ও website একসঙ্গে দেখাতে group তৈরি করুন। **Merge** কার্যকলাপ জুড়ে সদস্যদের একই নাম ও রঙ দেয়। কার্যকলাপ group রেকর্ড করা use সাজায়; blocking বা শ্রেণিবিন্যাস group থেকে আলাদা। কার্যকলাপ group editor-এ **Save** দিয়ে স্পষ্টভাবে সংরক্ষণ করুন।

### Recording ও retention

**Recording**-এ প্রতিটি category বা source-এর recording চালু/বন্ধ করুন। **Keep** কতদিন history থাকবে তা ঠিক করে; **Forever** স্বয়ংক্রিয় মেয়াদ ছাড়া রাখে। আলাদা পছন্দ বৃহত্তর setting অনুসরণ করতে পারে। Recording বন্ধ করলে নতুন রেকর্ড থামে; history মুছলে রেকর্ড করা entry মুছে যায়।

Platform feed supported page-এ দেখানো content সংগ্রহ করে, খোলা না হলেও। **Tagging supported** feed recording চালু থাকলে শ্রেণিবিন্যাসে তথ্য দিতে পারে। এর retention app ও website use থেকে আলাদাভাবে সংগৃহীত content নিয়ন্ত্রণ করে। শ্রেণিবিন্যাস group pause করলে recording নিজে বন্ধ হয় না।

## সেটিংস

Settings-এ interface language বেছে নিন। নির্বাচিত interface language-এ ছোট Info বোতামে field explanation পাওয়া যায়।

## সংরক্ষণ ও সমস্যা সমাধান

সাধারণ Vault ও শ্রেণিবিন্যাস সম্পাদনা স্বয়ংক্রিয়ভাবে সংরক্ষিত হয়। কার্যকলাপ group সম্পাদনায় **Save** লাগে। Add, delete, model download, connection test এবং model list fetch স্পষ্ট action হিসেবেই থাকে।

Tag না থাকলে browser connection, global tagging switch, group pause, platform recording ও model download পরীক্ষা করুন। Research না চললে consent, group নির্বাচন, provider credential, research model ও research status দেখুন। Linked group edit করা না গেলে program reconnect করুন বা নির্দেশমতো unfreeze করুন।
