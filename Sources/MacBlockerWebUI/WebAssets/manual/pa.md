# Mac Vault ਵਰਤੋਂਕਾਰ ਮੈਨੂਅਲ

Mac Vault ਦੇ ਤਿੰਨ ਪੰਨੇ ਹਨ: **Vault** ਮੂਲ ਐਪਾਂ ਨੂੰ ਬਲੌਕ ਕਰਦਾ ਹੈ, **ਸਮੱਗਰੀ ਟੈਗਿੰਗ** ਸਹਾਇਕ ਬ੍ਰਾਊਜ਼ਰ ਸਮੱਗਰੀ ਨੂੰ ਟੈਗ ਕਰਦਾ ਹੈ ਅਤੇ **ਸਰਗਰਮੀ** ਦਰਜ ਕੀਤੀ ਵਰਤੋਂ ਦਿਖਾਉਂਦਾ ਹੈ। ਬ੍ਰਾਊਜ਼ਰ ਐਕਸਟੈਂਸ਼ਨ ਸਹਾਇਕ ਸਮੱਗਰੀ ਇਕੱਠੀ ਕਰਕੇ ਬ੍ਰਾਊਜ਼ਰ ਬਲੌਕਿੰਗ ਲਾਗੂ ਕਰਦੀ ਹੈ। ਇਸਨੂੰ ਵਰਤੇ ਜਾਂਦੇ ਬ੍ਰਾਊਜ਼ਰ ਵਿੱਚ ਸਥਾਪਤ ਅਤੇ ਕਨੈਕਟ ਕਰੋ।

## ਤੁਰੰਤ ਸ਼ੁਰੂਆਤ

1. **Vault** ਵਿੱਚ ਬਲਾਕ ਸਮੂਹ ਅਤੇ Apps target ਜੋੜੋ, ਫਿਰ + picker ਨਾਲ ਐਪ ਚੁਣੋ।
2. ਬਲੌਕਿੰਗ ਵਿਹਾਰ ਚੁਣ ਕੇ ਗਰੁੱਪ ਚਾਲੂ ਕਰੋ।
3. **ਸਮੱਗਰੀ ਟੈਗਿੰਗ** ਵਿੱਚ ਗਰੁੱਪ ਬਣਾਓ, ਪਲੇਟਫਾਰਮ ਚੁਣੋ ਅਤੇ ਵੇਰਵਿਆਂ ਵਾਲੇ ਟੈਗ ਜੋੜੋ।
4. ਸੈਟਿੰਗਾਂ → **AI ਕਨੈਕਸ਼ਨ** ਵਿੱਚ ChatGPT subscription, OpenAI API, Gemini API ਜਾਂ Grok API ਚੁਣੋ। ਖਾਤਾ ਕਨੈਕਟ ਕਰੋ ਜਾਂ key ਦਿਓ ਅਤੇ models ਲਿਆਓ; ਫਿਰ ਗਰੁੱਪ ਲਈ connection/model ਚੁਣੋ। Tagging ਚਾਲੂ ਕਰਕੇ ਗਰੁੱਪ ਮੁੜ ਚਲਾਓ।
5. ਕਨੈਕਟ ਕੀਤੇ ਬ੍ਰਾਊਜ਼ਰ ਵਿੱਚ ਸਹਾਇਕ ਸਮੱਗਰੀ ਖੋਲ੍ਹੋ। ਟੈਗਾਂ ਨਾਲ ਬਲੌਕਿੰਗ ਚਲਾਉਣੀ ਹੋਵੇ ਤਾਂ browser ਬਲਾਕ ਸਮੂਹ ਵਿੱਚ tag filter ਲਗਾਓ।

## ਬਲੌਕਿੰਗ ਗਰੁੱਪ

**ਬਲਾਕ ਸਮੂਹ** ਬਲੌਕਿੰਗ ਨੀਤੀ ਲਾਗੂ ਕਰਦਾ ਹੈ। **ਸਮੱਗਰੀ ਟੈਗਿੰਗ** ਸਮੱਗਰੀ ਨੂੰ ਟੈਗ ਕਰਦਾ ਹੈ; ਇਹ ਆਪਣੇ ਆਪ ਕੁਝ ਨਹੀਂ ਰੋਕਦਾ। ਗਰੁੱਪ ਜੋੜ ਕੇ ਨਾਮ ਦਿਓ, **ਲਾਗੂ ਹੁੰਦਾ ਹੈ** ਵਿੱਚ targets ਚੁਣੋ, ਬਲੌਕਿੰਗ ਦਾ ਸਮਾਂ ਅਤੇ schedule ਜਾਂ time allowance ਨਿਰਧਾਰਤ ਕਰਕੇ ਗਰੁੱਪ ਚਾਲੂ ਕਰੋ। ਆਮ ਸੋਧਾਂ ਆਪਣੇ ਆਪ ਸੰਭਲਦੀਆਂ ਹਨ। Error ਦਾ ਮਤਲਬ ਸੋਧ ਮਨਜ਼ੂਰ ਨਹੀਂ ਹੋਈ; field ਠੀਕ ਕਰਕੇ ਮੁੜ ਕੋਸ਼ਿਸ਼ ਕਰੋ। ਗਰੁੱਪ ਬੰਦ ਕਰਨ ਨਾਲ configuration ਬਚੀ ਰਹਿੰਦੀ ਹੈ; **ਗਰੁੱਪ ਮਿਟਾਓ** ਇਸਨੂੰ ਮਿਟਾਉਂਦਾ ਹੈ। ਗਰੁੱਪ ਖਿੱਚ ਕੇ ਕ੍ਰਮ ਬਦਲੋ। ਇੱਕ target ਉੱਤੇ ਕਈ ਗਰੁੱਪ ਲਾਗੂ ਹੋ ਸਕਦੇ ਹਨ; ਇੱਕ ਨੂੰ snooze ਕਰਨ ਨਾਲ ਦੂਜੇ ਦਾ ਬਲੌਕ ਨਹੀਂ ਹਟਦਾ। **ਨਿਰਯਾਤ** configuration ਕਾਪੀ ਕਰਦਾ ਹੈ; **ਆਯਾਤ ਕਰੋ** ਪੁਸ਼ਟੀ ਪਿੱਛੋਂ ਚੁਣੇ ਗਰੁੱਪ ਦੀ configuration ਬਦਲਦਾ ਹੈ।

### ਸਮਾਂ-ਹੱਦ ਅਤੇ ਸਮਾਂ-ਸਾਰਣੀ

**Block immediately** ਤਦ ਲਾਗੂ ਹੁੰਦਾ ਹੈ ਜਦੋਂ ਚਾਲੂ ਗਰੁੱਪ ਮਿਲੇ ਅਤੇ schedule ਸਰਗਰਮ ਹੋਵੇ। **Block when the time allowance is used** allowance ਮੁੱਕਣ ਤੱਕ ਵਰਤੋਂ ਦੀ ਇਜਾਜ਼ਤ ਦਿੰਦਾ ਹੈ। Allowance ਮਿੰਟਾਂ ਵਿੱਚ ਅਤੇ reset interval ਘੰਟਿਆਂ ਵਿੱਚ ਦਿਓ। Rolling limit ਪਿਛਲੀ window ਦੀ ਵਰਤੋਂ ਗਿਣਦਾ ਹੈ। Midnight reset ਸਥਾਨਕ ਅੱਧੀ ਰਾਤ ਨੂੰ ਨਵਾਂ period ਸ਼ੁਰੂ ਕਰਦਾ ਹੈ, rolling limit ਲਈ ਵੀ। ਸਰਗਰਮ weekdays ਅਤੇ ਚੋਣਵਾਂ local-time windows ਇੱਕ ਲਾਈਨ ਵਿੱਚ ਇੱਕ ਚੁਣੋ, ਜਿਵੇਂ **09:00-12:00**। ਖਾਲੀ window ਸੂਚੀ ਚੁਣੇ ਦਿਨਾਂ ਦੇ ਸਾਰੇ ਸਮੇਂ ਲਈ ਲਾਗੂ ਹੁੰਦੀ ਹੈ। Window ਉਸੇ ਦਿਨ ਸ਼ੁਰੂ ਤੋਂ ਬਾਅਦ ਮੁੱਕੇ; ਰਾਤ-ਪਾਰ schedule ਨੂੰ ਵੱਖਰੇ ਦਿਨਾਂ ਵਿੱਚ ਵੰਡੋ।

### ਵਿਰਾਮ

ਹਰ ਬਲਾਕ ਸਮੂਹ ਵਿੱਚ snooze ਲਗਾਓ। **Pause blocking** pause duration ਲਈ ਨੀਤੀ ਰੋਕਦਾ ਹੈ। **Add to the time allowance** ਸਮਾਂ-ਸੀਮਤ ਗਰੁੱਪ ਵਿੱਚ ਵਰਤਣਯੋਗ ਮਿੰਟ ਜੋੜਦਾ ਹੈ। ਸਿਰਫ਼ ਵਰਤੀ ਵਾਧੂ allowance snoozed time ਗਿਣੀ ਜਾਂਦੀ ਹੈ। ਨਾ ਵਰਤੀ ਵਾਧੂ allowance ਅਗਲੇ reset ਉੱਤੇ ਮੁੱਕਦੀ ਹੈ; rolling limit ਵਿੱਚ ਇੱਕ window ਬਾਅਦ ਜਾਂ ਚਾਲੂ ਹੋਣ ਉੱਤੇ midnight ਤੇ ਪਹਿਲਾਂ। **Activation delay** ਬਲੌਕ ਜਾਰੀ ਰੱਖਦਿਆਂ snooze ਪਿੱਛੇ ਕਰਦਾ ਹੈ। **Cooldown** snooze ਮੁੱਕਣ ਮਗਰੋਂ ਅਗਲੀ ਬੇਨਤੀ ਤੋਂ ਪਹਿਲਾਂ ਉਡੀਕ ਹੈ। **Required confirmations** ਪੁਸ਼ਟੀ ਕਦਮਾਂ ਦੀ ਗਿਣਤੀ ਹੈ। Frozen ਗਰੁੱਪ ਵਿੱਚ snooze ਤਾਂ ਹੀ ਮਿਲਦਾ ਹੈ ਜੇ freeze ਤੋਂ ਪਹਿਲਾਂ ਮਨਜ਼ੂਰ ਹੋਵੇ।

### Freeze ਅਤੇ PIN

**Freeze** ਆਮ ਸੋਧ ਰੋਕਦਾ ਹੈ। Unfreeze ਲਈ ਪੰਜ ਸਕਿੰਟ ਦੇ ਫ਼ਰਕ ਨਾਲ ਦਸ confirmations, ਨਿਰਧਾਰਤ wait ਅਤੇ ਛੇ ਅੰਕਾਂ ਦਾ PIN ਲੋੜੀਂਦਾ ਹੈ। **Wait before unfreezing** 0–72 ਘੰਟੇ ਲੈਂਦਾ ਹੈ; 0 ਦਾ ਮਤਲਬ ਉਡੀਕ ਨਹੀਂ। Frozen ਹੋਣ ਵੇਲੇ wait ਵਧਾਈ ਅਤੇ PIN ਜੋੜੀ ਜਾ ਸਕਦੀ ਹੈ, ਪਰ unfreeze ਤੱਕ ਸ਼ਰਤਾਂ ਕਮਜ਼ੋਰ ਨਹੀਂ ਕੀਤੀਆਂ ਜਾ ਸਕਦੀਆਂ। ਮਿਟਾਉਣ ਵੇਲੇ ਵੀ ਬਾਕੀ wait ਅਤੇ PIN ਲਾਗੂ ਹਨ।

### ਜੁੜੇ ਗਰੁੱਪ

**ਲਿੰਕ ਕਰੋ** ਨਾਲ ਹੋਰ Vault ਪ੍ਰੋਗਰਾਮਾਂ ਵਿੱਚ ਸਪਸ਼ਟ ਤੌਰ 'ਤੇ ਚੁਣੇ ਗਰੁੱਪ ਜੋੜੋ। ਉਹ ਨਾਮ, ਸਹਾਇਕ policy settings, targets, usage ਅਤੇ freeze conditions ਸਾਂਝੀਆਂ ਕਰਦੇ ਹਨ। ਹਰ ਪ੍ਰੋਗਰਾਮ ਸਿਰਫ਼ ਆਪਣੇ ਸਹਾਇਕ target types ਸੋਧਦਾ ਅਤੇ ਲਾਗੂ ਕਰਦਾ ਹੈ; ਹੋਰ targets ਜੁੜੇ ਪ੍ਰੋਗਰਾਮਾਂ ਲਈ ਉਪਲਬਧ ਰਹਿੰਦੇ ਹਨ। **ਅਨਲਿੰਕ ਕਰੋ** ਗਰੁੱਪ ਅਤੇ settings ਰੱਖਦਿਆਂ ਜੋੜ ਤੋੜਦਾ ਹੈ। ਕੋਈ ਮੈਂਬਰ offline ਹੋਵੇ ਤਾਂ Mac Vault ਅਤੇ ਜੁੜਿਆ ਬ੍ਰਾਊਜ਼ਰ ਖੋਲ੍ਹ ਕੇ ਮੁੜ ਕਨੈਕਟ ਕਰੋ। ਸਥਾਨਕ saved policy offline ਵੇਲੇ ਵੀ ਲਾਗੂ ਰਹਿ ਸਕਦੀ ਹੈ।

## ਮਦਦ

Field ਦੇ ਕੋਲ ਛੋਟਾ **i** ਦਬਾ ਕੇ ਵਿਆਖਿਆ ਵੇਖੋ; ਬਾਹਰ ਕਲਿੱਕ ਜਾਂ Escape ਦਬਾ ਕੇ ਬੰਦ ਕਰੋ। ਸੂਚੀਆਂ scrollable boxes ਵਿੱਚ ਰਹਿੰਦੀਆਂ ਹਨ; ਖੋਜ ਦਿੱਖ ਰਹੀਆਂ entries ਛਾਂਟਦੀ ਹੈ, ਮਿਟਾਉਂਦੀ ਨਹੀਂ। Custom rules ਲਈ [Code manual](../code-manual/pa.md) editor, activation, logs, file access ਅਤੇ API ਸਮਝਾਉਂਦਾ ਹੈ।

## ਮੂਲ ਐਪਾਂ

Apps target ਦੇ + picker ਵਿੱਚ installed ਜਾਂ ਚੱਲ ਰਹੀਆਂ ਐਪਾਂ ਚੁਣੋ; ਹੋਰ folder ਤੋਂ ਐਪ ਖੋਲ੍ਹਣ ਪਿੱਛੋਂ ਸੂਚੀ ਤਾਜ਼ਾ ਕਰਨ ਲਈ picker ਮੁੜ ਖੋਲ੍ਹੋ। **ਇੱਥੇ ਸੂਚੀਬੱਧ ਐਪਾਂ ਤੋਂ ਇਲਾਵਾ ਸਾਰੀਆਂ ਐਪਾਂ ਬਲੌਕ ਕਰੋ** ਸੂਚੀ ਨੂੰ allowlist ਬਣਾਉਂਦਾ ਹੈ। Mac Vault ਆਮ Apple apps ਅਤੇ ਪੂਰੇ browsers ਬਲੌਕ ਕਰ ਸਕਦਾ ਹੈ; Mac Vault ਅਤੇ ਇੱਕੋ bundle identifier ਵਾਲੀਆਂ ਐਪਾਂ ਸੁਰੱਖਿਅਤ ਹਨ। ਬਲੌਕ ਐਪ ਨੂੰ quit ਕਰਨ ਲਈ ਕਿਹਾ ਜਾਂਦਾ ਹੈ; **ਬਲੌਕ ਕੀਤੀ ਐਪ ਨੂੰ ਬੰਦ ਹੋਣ ਲਈ ਮੁੜ ਕਹੋ ਹਰ (ਮਿੰਟ)** ਦੁਬਾਰਾ ਬੇਨਤੀ ਦਾ ਸਮਾਂ ਤੈਅ ਕਰਦਾ ਹੈ। Website redirects, page pauses ਅਤੇ feed hiding ਬ੍ਰਾਊਜ਼ਰ ਐਕਸਟੈਂਸ਼ਨ ਲਾਗੂ ਕਰਦੀ ਹੈ, ਮੂਲ ਐਪ ਨਹੀਂ।

## ਸਮੱਗਰੀ ਟੈਗਿੰਗ

ਹਰ ਗਰੁੱਪ ਆਪਣੇ ਨਿਰਧਾਰਤ ਪਲੇਟਫਾਰਮਾਂ ਦੀ ਸਮੱਗਰੀ ਨੂੰ ਆਪਣੇ tag tree ਅਤੇ model settings ਨਾਲ ਟੈਗ ਕਰਦਾ ਹੈ। ਹਰ ਪਲੇਟਫਾਰਮ ਇੱਕ ਗਰੁੱਪ ਨਾਲ ਜੁੜਦਾ ਹੈ; ਬਣਾਉਂਦੇ ਵੇਲੇ ਚੁਣੋ, ਪਿੱਛੋਂ ਬਦਲ ਨਹੀਂ ਸਕਦੇ। Blocking schedule ਅਤੇ filters tagging ਨਹੀਂ ਚਲਾਉਂਦੇ। ਸੈਟਿੰਗਾਂ ਵਿੱਚ tagging ਚਾਲੂ ਕਰੋ ਅਤੇ ਹਰ ਗਰੁੱਪ ਦਾ **ਟੈਗਿੰਗ ਰੋਕੋ / ਟੈਗਿੰਗ ਮੁੜ ਸ਼ੁਰੂ ਕਰੋ** ਵੱਖਰੇ ਵਰਤੋ। **ਸਰਗਰਮੀ → ਰਿਕਾਰਡਿੰਗ** ਵਿੱਚ platform feed ਦੀ recording ਬੰਦ ਕਰਨ ਨਾਲ ਉਸਦੀ tagging ਵੀ ਰੁਕਦੀ ਹੈ।

### Tags ਅਤੇ model settings

Tags ਬਣਾਓ, ਮਤਲਬ ਲਿਖੋ ਅਤੇ tree ਵਿੱਚ parent ਜੋੜੋ ਜਾਂ ਹਟਾਓ। Tag ਖਿੱਚਣ ਨਾਲ branch ਹਿਲਦੀ ਹੈ। ਸਾਫ਼ ਵੇਰਵਾ ਮਿਲਦੇ-ਜੁਲਦੇ tags ਵੱਖ ਕਰਨ ਵਿੱਚ model ਦੀ ਮਦਦ ਕਰਦਾ ਹੈ। ਹਰ ਗਰੁੱਪ ਦੀਆਂ settings ਸੁਤੰਤਰ ਹਨ। **ਘੱਟੋ-ਘੱਟ tag confidence** ਹਰ predicted tag ਲਈ evidence grade 1–5 ਰੱਖਦਾ ਹੈ; ਨਵੇਂ ਗਰੁੱਪ 4 (ਮਜ਼ਬੂਤ ਸਬੂਤ) ਤੋਂ ਸ਼ੁਰੂ ਹੁੰਦੇ ਹਨ। Tag ਗਿਣਤੀ ਦਾ ਟੀਚਾ ਨਹੀਂ; item ਨੂੰ ਕੋਈ tag ਨਾ ਮਿਲ ਸਕਦਾ ਹੈ। **ਟੈਗਿੰਗ ਹਦਾਇਤਾਂ** ਗਰੁੱਪ ਦੀਆਂ ਪਸੰਦਾਂ ਰੱਖਦਾ ਹੈ। ਆਮ edits auto-save ਹੁੰਦੇ ਹਨ; ਹਰ ਗਰੁੱਪ ਸਪਸ਼ਟ ਤੌਰ 'ਤੇ ਚੁਣਿਆ connection, model ਅਤੇ reasoning effort ਵਰਤਦਾ ਹੈ।

### AI ਕਨੈਕਸ਼ਨ

ਸੈਟਿੰਗਾਂ ਵਿੱਚ ChatGPT subscription, OpenAI API, Gemini API ਅਤੇ Grok API ਹਨ। Subscription Vault sign-in ਅਤੇ ਯੋਗ plan ਵਰਤਦੀ ਹੈ। API key ਚੁਣੇ provider ਦੀ billing ਅਤੇ limits ਅਨੁਸਾਰ ਹੈ। Provider ਚੁਣ ਕੇ ਸਾਂਝੇ dropdown ਦੇ ਹੇਠਾਂ key ਦਿਓ; edits auto-save ਹੁੰਦੇ ਹਨ ਅਤੇ field ਖਾਲੀ ਕਰਨ ਨਾਲ key ਮਿਟਦੀ ਹੈ। **ਮਾਡਲ ਸੂਚੀ ਲਿਆਓ** models ਲਿਆਉਂਦਾ ਹੈ, ਚੋਣ ਨਹੀਂ ਕਰਦਾ; ਫਿਰ ਸਮੱਗਰੀ ਟੈਗਿੰਗ ਜਾਂ custom-rule group ਵਿੱਚ model ਚੁਣੋ।

**ਤਰਕ ਦੀ ਮਾਤਰਾ** model ਦੀ ਸੋਚ ਦੀ ਮਾਤਰਾ ਹੈ: Model default, Low, Medium ਜਾਂ High ਜਿੱਥੇ ਸਹਾਇਕ ਹੋਵੇ। ਨਵੀਂ ਚੋਣ Medium ਤੋਂ ਸ਼ੁਰੂ ਹੁੰਦੀ ਹੈ; ਪੁਰਾਣੀ ਜਿਉਂ ਦੀ ਤਿਉਂ ਰਹਿੰਦੀ ਹੈ। ਵੱਧ effort ਸਮਾਂ ਅਤੇ tokens ਵਧਾ ਸਕਦਾ ਹੈ। Tagging ਲਈ web search ਹਮੇਸ਼ਾ ਚਾਲੂ ਹੈ; model ਵਰਤਣ ਦਾ ਸਮਾਂ ਤੈਅ ਕਰਦਾ ਹੈ। Search ਅਤੇ structured tagging ਸਹਾਇਕ model ਚੁਣੋ। ਅਸਫਲ/ਅਣਉਪਲਬਧ request valid cached results ਰੱਖਦੀ ਹੈ; ਨਵੇਂ items **ਕਲਾਊਡ ਵਰਗੀਕਰਨ ਮੁੜ ਅਜ਼ਮਾਓ** ਤੱਕ unresolved ਰਹਿੰਦੇ ਹਨ। Vault provider ਨਹੀਂ ਬਦਲਦਾ; ਹਰ connection ਦਾ retry interval ਅਤੇ attempt limit ਵੱਖਰਾ ਹੈ। Extension ਵਿੱਚ **+ tag** ਨਾਲ ਜੋੜੋ; remove control ਜਾਂ tag ਚੁਣ ਕੇ Delete ਇੱਕ ਵਾਰ ਦਬਾ ਕੇ ਹਟਾਓ। **ਟੈਗ ਰਹਿਤ** ਦਾ ਮਤਲਬ ਮੁਕੰਮਲ ਪਰ tag ਨਹੀਂ; **ਟੈਗ ਕੀਤਾ ਜਾ ਰਿਹਾ ਹੈ** ਮਤਲਬ ਨਤੀਜਾ ਉਡੀਕ ਰਿਹਾ ਹੈ। ਤੁਹਾਡੀ correction ਉਸ item ਲਈ authoritative ਹੈ।

## ਸਰਗਰਮੀ

ਸਰਗਰਮੀ enabled app use, website visits ਅਤੇ ਸਹਾਇਕ **ਵੇਖੀ ਸਮੱਗਰੀ** ਸਥਾਨਕ ਤੌਰ 'ਤੇ ਦਰਜ ਕਰਦੀ ਹੈ। Charts ਦਰਜ ਕੀਤੇ data ਦਿਖਾਉਂਦੇ ਹਨ; ਖਾਲੀ ਥਾਂ Mac idle ਹੋਣ ਦਾ ਸਬੂਤ ਨਹੀਂ। Date range ਚੁਣੋ। **ਟਾਈਮਲਾਈਨ** ਦਿਨ ਦੇ ਸਮੇਂ ਅਨੁਸਾਰ ਵਰਤੋਂ ਦਿਖਾਉਂਦਾ ਹੈ; **ਕੁੱਲ** duration ਜੋੜਦਾ ਹੈ; **ਸਮਾਂ ਅੰਤਰਾਲ** ਹਰ interval ਦੀ ਵਰਤੋਂ vertical blocks ਵਿੱਚ ਜੋੜਦਾ ਹੈ। **ਰੰਗ** clickable legend ਹੈ; source ਚੁਣ ਕੇ chart ਨੂੰ ਉਸ ਉੱਤੇ ਕੇਂਦਰਿਤ ਕਰੋ। ਦਿਨ ਚੁਣ ਕੇ ਉਸ ਦਿਨ ਤੋਂ ਵਰਤੋਂ ਵੇਖੋ।

### ਸਰਗਰਮੀ groups

Usage ਵਿੱਚ ਚੁਣੀਆਂ apps ਅਤੇ websites ਇਕੱਠੇ ਦਿਖਾਉਣ ਲਈ group ਬਣਾਓ। **Merge** ਸਰਗਰਮੀ ਭਰ ਮੈਂਬਰਾਂ ਲਈ ਇੱਕ ਨਾਮ ਅਤੇ ਰੰਗ ਵਰਤਦਾ ਹੈ। ਸਰਗਰਮੀ group ਦਰਜ ਵਰਤੋਂ ਵਿਵਸਥਿਤ ਕਰਦਾ ਹੈ; blocking ਜਾਂ tagging group ਤੋਂ ਵੱਖਰਾ ਹੈ। Editor ਨੂੰ ਸਪਸ਼ਟ ਤੌਰ 'ਤੇ **Save** ਕਰੋ।

### ਰਿਕਾਰਡਿੰਗ ਅਤੇ retention

**ਰਿਕਾਰਡਿੰਗ** ਵਿੱਚ ਹਰ category ਜਾਂ source ਲਈ recording ਚਾਲੂ/ਬੰਦ ਕਰੋ। **ਰੱਖੋ** history ਰੱਖਣ ਦਾ ਸਮਾਂ ਹੈ; **ਹਮੇਸ਼ਾ** ਆਪਣੇ ਆਪ ਮਿਆਦ ਨਹੀਂ ਮੁਕਾਉਂਦਾ। Individual selections ਵੱਡੀ setting ਮੰਨ ਸਕਦੀਆਂ ਹਨ। ਰਿਕਾਰਡਿੰਗ ਬੰਦ ਕਰਨ ਨਾਲ ਨਵੀਂ recording ਰੁਕਦੀ ਹੈ; history ਮਿਟਾਉਣ ਨਾਲ ਦਰਜ entries ਮਿਟਦੀਆਂ ਹਨ। Platform feeds supported pages ਉੱਤੇ ਦਿਖੀ ਸਮੱਗਰੀ ਇਕੱਠੀ ਕਰਦੀਆਂ ਹਨ, ਭਾਵੇਂ ਖੋਲ੍ਹੀ ਨਾ ਹੋਵੇ। **ਟੈਗਿੰਗ ਸਮਰਥਿਤ** feed recording ਚਾਲੂ ਹੋਣ 'ਤੇ ਸਮੱਗਰੀ ਟੈਗਿੰਗ ਨੂੰ ਸਮੱਗਰੀ ਦੇ ਸਕਦੀ ਹੈ। ਇਸਦੀ retention app ਅਤੇ website usage ਤੋਂ ਵੱਖਰੀ ਹੈ। Tagging group pause ਕਰਨ ਨਾਲ recording ਆਪਣੇ ਆਪ ਬੰਦ ਨਹੀਂ ਹੁੰਦੀ।

## ਸੈਟਿੰਗਾਂ

ਸੈਟਿੰਗਾਂ ਵਿੱਚ interface language ਚੁਣੋ। Field explanations ਚੁਣੀ ਭਾਸ਼ਾ ਦੇ Info buttons ਰਾਹੀਂ ਮਿਲਦੀਆਂ ਹਨ।

## ਸੰਭਾਲਣਾ ਅਤੇ ਸਮੱਸਿਆ ਹੱਲ

ਆਮ Vault ਅਤੇ ਸਮੱਗਰੀ ਟੈਗਿੰਗ edits auto-save ਹੁੰਦੇ ਹਨ; ਸਰਗਰਮੀ group editor ਲਈ **Save** ਲੋੜੀਂਦਾ ਹੈ। Add, delete, connection test ਅਤੇ model-list fetch ਸਪਸ਼ਟ actions ਹਨ। Tags ਗਾਇਬ ਹੋਣ ਤਾਂ browser connection, global tagging switch, group pause, platform recording, ਚੁਣਿਆ connection/model ਅਤੇ credentials ਵੇਖੋ। AI request fail ਹੋਵੇ ਤਾਂ provider usage limits ਅਤੇ group Log ਵੀ ਵੇਖੋ। Linked group edit ਨਾ ਹੋਵੇ ਤਾਂ programs ਮੁੜ ਕਨੈਕਟ ਕਰੋ ਜਾਂ ਦੱਸੇ ਅਨੁਸਾਰ unfreeze ਕਰੋ।
