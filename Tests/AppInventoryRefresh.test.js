const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const shim = fs.readFileSync(path.join(__dirname, '../Sources/MacBlockerWebUI/WebAssets/chrome-shim.js'), 'utf8');
const requests = [];
const listeners = {};
let mutation;
let hidden = true;
let searchEvents = 0;
const picker = { classList: { contains: name => name === 'hidden' && hidden } };
const search = { dispatchEvent: event => { assert.equal(event.type, 'input'); searchEvents++; } };
const document = {
  readyState: 'complete', baseURI: 'cbasset://app/popup.html',
  getElementById: id => id === 'appPickerModal' ? picker : id === 'appPickerSearch' ? search : null
};
const context = vm.createContext({
  console, URL, Date, Set, Map, Math, Promise,
  navigator: { language: 'en' }, document,
  Event: class { constructor(type) { this.type = type; } },
  MutationObserver: class { constructor(callback) { mutation = callback; } observe() {} },
  fetch: () => new Promise(resolve => requests.push(resolve)),
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  location: { href: document.baseURI, origin: 'cbasset://app' },
  addEventListener: (name, callback) => { listeners[name] = callback; }
});
context.window = context;
vm.runInContext(shim, context);

const reply = async (index, apps) => {
  requests[index]({ ok: true, json: async () => apps });
  for (let i = 0; i < 4; i++) await Promise.resolve();
};
(async () => {
  assert.equal(requests.length, 1, 'the initial inventory loads');
  hidden = false;
  mutation();
  assert.equal(requests.length, 2, 'opening the picker requests current running apps');
  await reply(0, [{ id: 'stale.app' }]);
  assert.equal(context.__cbAppInventory.length, 0, 'an older response cannot replace a new request');
  await reply(1, [{ id: 'running.app', name: 'Running' }]);
  assert.equal(context.__cbAppInventory[0].id, 'running.app');
  assert.equal(searchEvents, 1, 'the open picker repaints without losing its search');
  listeners.focus();
  assert.equal(requests.length, 3, 'returning to the picker refreshes a newly launched app');
  await reply(2, [{ id: 'running.app' }, { id: 'new.app' }]);
  assert.equal(context.__cbAppInventory[1].id, 'new.app');
  context.__cbRefreshAppInventory();
  assert.equal(requests.length, 4, 'a native app-launch notification refreshes an open picker');
  await reply(3, [{ id: 'running.app' }, { id: 'new.app' }, { id: 'background.app' }]);
  assert.equal(context.__cbAppInventory[2].id, 'background.app');
  hidden = true;
  listeners.focus();
  context.__cbRefreshAppInventory();
  assert.equal(requests.length, 4, 'a closed picker does not repeatedly fetch icons');
  console.log('PASS app inventory refreshes on open and focus; stale replies ignored');
})().catch(error => { console.error(error); process.exitCode = 1; });
