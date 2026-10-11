// Actual native shim, canonical scope helper, popup persistence function and
// storage-change listener. The inert page adapters below do not emulate Swift.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const { webcrypto } = require('node:crypto');
const assets = path.join(__dirname, '../Sources/MacBlockerWebUI/WebAssets');
const source = name => fs.readFileSync(path.join(assets, name), 'utf8');
const popup = source('popup.js');
const persistenceStart = popup.indexOf('let editorPersistTail = Promise.resolve();');
const persistenceEnd = popup.indexOf('// A snooze entry', persistenceStart);
const listenerStart = popup.indexOf('chrome.storage.onChanged.addListener((changes, areaName) => {');
const listenerEnd = popup.indexOf('\nwindow.addEventListener("keydown"', listenerStart);
assert(persistenceStart >= 0 && persistenceEnd > persistenceStart && listenerStart >= 0 && listenerEnd > listenerStart);
let checks = 0;
const check = (condition, message) => { assert(condition, message); checks++; };
const plain = value => JSON.parse(JSON.stringify(value));
function page({ bridge = true, oldMirror } = {}) {
  const messages = [], timers = [], storage = new Map();
  const initial = oldMirror || {
    blockedGroups: [{ id: 'a', name: 'UI20', allowedMinutes: 20, scopes: [{ id: 'apps-1', entryID: 'apps', surface: 'apps', action: 'block', apps: [{ id: 'old.app' }], appsExcept: false }] }],
    globalSettings: { sentinel: 'keep' }, usageTimersMs: { a: 714 }, groupSnoozes: { a: { startsAtMs: 3 } }
  };
  storage.set('__cb_chrome_storage__', JSON.stringify(initial));
  const context = vm.createContext({ console, URL, Date, Set, Map, Math, Promise, Uint32Array,
    crypto: webcrypto, navigator: { language: 'en' },
    setTimeout: callback => { timers.push(callback); return timers.length; }, clearTimeout() {},
    localStorage: { getItem: key => storage.get(key) || null, setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) },
    location: { href: 'cbasset://app/popup.html', origin: 'cbasset://app' }, addEventListener() {} });
  context.window = context;
  if (bridge) context.webkit = { messageHandlers: { cbBridge: { postMessage: message => messages.push(plain(message)) } } };
  for (const file of ['platform-profiles.js', 'group-actions.js', 'group-scopes.js', 'chrome-shim.js']) vm.runInContext(source(file), context, { filename: file });
  context.IS_NATIVE_DESKTOP = true; context.LOCAL_OWNER = 'desktop'; context.BLOCKED_GROUPS_KEY = 'blockedGroups';
  context.state = { groups: plain(initial.blockedGroups) };
  context.popupDefinitionReadRevision = 0;
  // DOM-independent adapters: stored-form input is already canonical; the actual
  // producer, helper, onChanged listener and native reply path run unchanged.
  context.toStoredGroup = group => plain(group);
  context.setStatus = () => {};
  context.syncExternalState = changes => { if (changes.blockedGroups) context.state.groups = plain(changes.blockedGroups.newValue); };
  context.refreshPopupDefinitionStorage = async () => { context.state.groups = plain((await context.chrome.storage.local.get('blockedGroups')).blockedGroups); };
  vm.runInContext(popup.slice(persistenceStart, persistenceEnd) + popup.slice(listenerStart, listenerEnd), context, { filename: 'popup-native-producer.js' });
  return { context, messages, timers, initial, read: async () => plain(await context.chrome.storage.local.get(null)) };
}
(async () => {
  const p = page(), c = p.context;
  const before = plain(c.state.groups[0]); c.state.groups[0].scopes[0].apps = [{ id: 'edited.app' }];
  c.__before = before;
  let completed = false;
  const task = vm.runInContext('persistGroups(["a"], { before: [__before] })', c).then(async reply => {
    completed = true;
    check((await p.read()).blockedGroups[0].allowedMinutes === 24, 'authoritative groups mirrored before success resolves');
    return reply;
  });
  check(p.messages.length === 1 && p.messages[0].kind === 'editor-definition-edit', 'actual popup uses acknowledged native edit route');
  check(!completed, 'request awaits real native response');
  const message = p.messages[0];
  check(Object.keys(message.message.changes[0].fields.set).length === 0, 'Apps-only producer sends no stale scalar');
  check(message.message.changes[0].lines.length === 1, 'producer sends exact Apps entry intent');
  const authoritative = [{ ...before, name: 'Shared24', allowedMinutes: 24, scopes: [{ ...before.scopes[0], apps: [{ id: 'edited.app' }] }] }];
  c.__cbNativeReply(message.requestId, { ok: true, groups: authoritative });
  check((await task).ok === true, 'successful native acknowledgement returned');
  const saved = await p.read();
  check(saved.blockedGroups[0].name === 'Shared24' && c.state.groups[0].name === 'Shared24', 'actual onChanged and popup final refresh adopt authoritative groups');
  for (const key of ['globalSettings', 'usageTimersMs', 'groupSnoozes']) check(JSON.stringify(saved[key]) === JSON.stringify(p.initial[key]), `${key} preserved by groups-only mirror`);
  check(!p.messages.some(m => m.kind === 'persist-store'), 'native reply/onChanged/actual popup emit no full-snapshot echo');
  const refusal = c.chrome.runtime.sendMessage({ type: 'editor-definition-edit', changes: [] });
  c.__cbNativeReply(p.messages.at(-1).requestId, { ok: false, error: 'disk-full' });
  check((await refusal).error === 'disk-full', 'explicit backend error retained');
  check(JSON.stringify(await p.read()) === JSON.stringify(saved), 'refused reply has no mirror mutation');
  const invalid = c.chrome.runtime.sendMessage({ type: 'editor-definition-edit', changes: [] });
  c.__cbNativeReply(p.messages.at(-1).requestId, { ok: true });
  check((await invalid).error === 'invalid-editor-response', 'malformed success is refused');
  check(JSON.stringify(await p.read()) === JSON.stringify(saved), 'malformed success leaves mirror unchanged');

  const old = page(); const obsolete = old.context.chrome.runtime.sendMessage({ type: 'editor-definition-edit', changes: [] });
  const oldId = old.messages[0].requestId;
  const fresh = page(); let freshCompleted = false;
  const freshTask = fresh.context.chrome.runtime.sendMessage({ type: 'editor-definition-edit', changes: [] }).then(reply => { freshCompleted = true; return reply; });
  const freshId = fresh.messages[0].requestId;
  check(oldId !== freshId, 'per-document nonce separates first request across reload');
  fresh.context.__cbNativeReply(oldId, { ok: true, groups: authoritative });
  await Promise.resolve(); await Promise.resolve();
  check(!freshCompleted, 'obsolete reply cannot settle new document request');
  check((await fresh.read()).blockedGroups[0].name === 'UI20', 'obsolete response does not replace fresh mirror');
  fresh.context.__cbNativeReply(freshId, { ok: true, groups: authoritative });
  check((await freshTask).ok && freshCompleted, 'current document reply settles normally');
  old.timers.forEach(fn => fn()); await obsolete;

  const timed = page(); const timeout = timed.context.chrome.runtime.sendMessage({ type: 'editor-definition-edit', changes: [] });
  const timedId = timed.messages[0].requestId; timed.timers.forEach(fn => fn());
  check((await timeout).error === 'native-editor-response-unavailable', 'timeout reports response uncertainty, not refused or absent commit');
  timed.context.__cbNativeReply(timedId, { ok: true, groups: authoritative });
  check((await timed.read()).blockedGroups[0].name === 'UI20', 'late reply after timeout has no unsolicited mirror effect');
  check(timed.messages.length === 1, 'transport uncertainty does not retry a potentially committed edit');
  const unavailable = page({ bridge: false });
  check((await unavailable.context.chrome.runtime.sendMessage({ type: 'editor-definition-edit', changes: [] })).error === 'native-editor-response-unavailable', 'absent transport does not return false success');
  console.log(`PASS ${checks} native editor shim/popup transport assertions (Swift backend acceptance separate)`);
})().catch(error => { console.error(error); process.exitCode = 1; });
