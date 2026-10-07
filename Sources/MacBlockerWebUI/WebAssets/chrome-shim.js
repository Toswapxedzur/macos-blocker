/* chrome.* shim for the macosBlocker native port.
 *
 * The customBlocker editor UI (popup.html / popup.js) was written for a
 * Chrome MV3 extension. Inside a WKWebView there is no `chrome` object, so
 * this shim provides the small surface the editor actually uses:
 *
 *   - chrome.storage.local.get / set / remove
 *   - chrome.storage.onChanged
 *   - chrome.runtime.getURL / sendMessage / onMessage / id / lastError
 *   - chrome.permissions.contains / request
 *   - chrome.i18n.getMessage (best effort; the editor mostly uses its own
 *     translation/*.json loader)
 *
 * Storage is mirrored to two places:
 *   1. localStorage, so the UI works even with no native host (plain Safari).
 *   2. the native host via window.webkit.messageHandlers.cbBridge, so the
 *      Swift policy core sees the same blockedGroups / settings / usage data.
 *
 * The native host can also push an initial store snapshot by calling
 *   window.__cbApplyNativeStore(jsonString)
 * before the editor reads storage.
 */
(function () {
  // Reconcile the retired scene-only language once. The app choice wins when
  // both exist; names, rules and Classifier data are never rewritten.
  try {
    const oldLanguage = localStorage.getItem("vaultClassifier.language");
    if (!localStorage.getItem("custom-blocker-language") && /^(en|ar|bn|de|es|fr|hi|id|it|ja|ko|nl|pa|pl|pt|ru|th|tr|vi|zh)$/.test(oldLanguage || "")) {
      localStorage.setItem("custom-blocker-language", oldLanguage);
    }
    localStorage.removeItem("vaultClassifier.language");
  } catch (_) {}
  window.__CB_DESKTOP_PROGRAM_ID = window.__CB_DESKTOP_PROGRAM_ID || "macapp";
  if (window.chrome && window.chrome.__cbShim) {
    return;
  }

  var STORE_KEY = "__cb_chrome_storage__";

  function nativeBridge() {
    try {
      if (
        window.webkit &&
        window.webkit.messageHandlers &&
        window.webkit.messageHandlers.cbBridge
      ) {
        return window.webkit.messageHandlers.cbBridge;
      }
    } catch (_) {}
    return null;
  }

  // The native host parks its store snapshot on `window` at document start
  // (see BlockerWebView): it is the truth and wins over the localStorage mirror,
  // which may be stale when a native writer changed the file while the editor
  // was closed.
  function loadStore() {
    try {
      if (typeof window.__cbNativeStoreSeed === "string") {
        var seeded = JSON.parse(window.__cbNativeStoreSeed) || {};
        try { window.localStorage.setItem(STORE_KEY, JSON.stringify(seeded)); } catch (_) {}
        return seeded;
      }
    } catch (_) {}
    try {
      return JSON.parse(window.localStorage.getItem(STORE_KEY) || "{}") || {};
    } catch (_) {
      return {};
    }
  }

  // Only the keys the editor set (or removed; null) go to Mac Vault, which
  // merges them into its file — like chrome.storage, a key another writer
  // changed meanwhile (the engine, a tool) is kept.
  // Per-group maps (WebStoreDocument.perGroupMapKeys): only the entries this
  // editor changed are sent — its copy of other groups' entries may be older
  // than the engine's, and Mac Vault merges them by group.
  var PER_GROUP_KEYS = ["usageTimersMs", "usageResetAtMs", "usageBucketsMs", "groupSnoozes", "groupSnoozeTotalsMs", "parentalPinAttempts"];
  function persist(keys, before) {
    try {
      window.localStorage.setItem(STORE_KEY, JSON.stringify(store));
    } catch (_) {}
    var bridge = nativeBridge();
    if (bridge) {
      var changes = {};
      keys.forEach(function (key) {
        var value = Object.prototype.hasOwnProperty.call(store, key) ? store[key] : null;
        if (value && typeof value === "object" && before && PER_GROUP_KEYS.indexOf(key) >= 0) {
          var old = before[key] && typeof before[key] === "object" ? before[key] : {};
          var changed = {};
          Object.keys(value).forEach(function (id) {
            if (JSON.stringify(value[id]) !== JSON.stringify(old[id])) changed[id] = value[id];
          });
          value = changed;
        }
        changes[key] = value;
      });
      try {
        bridge.postMessage({ kind: "persist-store", changes: changes });
      } catch (_) {}
    }
  }

  var store = loadStore();

  // Allow the native host to seed/replace the store. Also used at RUNTIME to
  // reconcile the open editor after a native writer (e.g. an MCP tool) mutated
  // web-store.json out-of-band: replace the store, mirror it into localStorage,
  // and fire chrome.storage change listeners for the keys that actually differ —
  // WITHOUT calling persist(), so there is no write-back echo to native (mirrors
  // the safe __cbApplyNativeRuleLog / __cbApplyNativeUsage pattern). Before the
  // editor registers its listeners this is just a seed (notifyChanges no-ops).
  window.__cbApplyNativeStore = function (json) {
    try {
      var incoming = typeof json === "string" ? JSON.parse(json) : json;
      if (!incoming || typeof incoming !== "object") return;
      var previous = store;
      store = incoming;
      delete store.ruleLog;
      pruneRuleLogs();
      try {
        window.localStorage.setItem(STORE_KEY, JSON.stringify(store));
      } catch (_) {}
      var changes = {};
      var keys = {};
      var k;
      for (k in (previous || {})) {
        if (Object.prototype.hasOwnProperty.call(previous, k)) keys[k] = true;
      }
      for (k in incoming) {
        if (Object.prototype.hasOwnProperty.call(incoming, k)) keys[k] = true;
      }
      for (k in keys) {
        var oldVal = previous ? previous[k] : undefined;
        var newVal = incoming[k];
        var differs;
        try {
          differs = JSON.stringify(oldVal) !== JSON.stringify(newVal);
        } catch (_) {
          differs = true;
        }
        if (differs) changes[k] = { oldValue: oldVal, newValue: newVal };
      }
      if (Object.keys(changes).length > 0) notifyChanges(changes);
    } catch (_) {}
  };

  // The native macOS host seeds the installed-application inventory here so the
  // editor's app picker can search/show real apps (name + bundle id + icon).
  // Each entry: { id: <bundleId>, name: <String>, icon: <data URL or "" > }.
  // On plain Safari (no native host) this stays an empty array and the picker
  // simply shows "no apps found".
  if (!Array.isArray(window.__cbAppInventory)) {
    window.__cbAppInventory = [];
  }
  window.__cbApplyAppInventory = function (json) {
    try {
      var incoming = typeof json === "string" ? JSON.parse(json) : json;
      if (Array.isArray(incoming)) {
        window.__cbAppInventory = incoming.filter(function (entry) {
          return entry && typeof entry.id === "string" && entry.id;
        });
        if (typeof window.__cbOnAppInventory === "function") {
          try { window.__cbOnAppInventory(); } catch (_) {}
        }
      }
    } catch (_) {}
  };

  // The native macOS host accrues "time spent" usage (while a blocked app is
  // frontmost — the analogue of the extension's per-page heartbeat) and pushes
  // it here every second so the editor's countdown ticks live, exactly like the
  // Chrome extension's popup. We merge the incoming usage keys and fire the
  // storage-change listeners (NOT persist) so the popup re-renders without
  // writing back to the native store.
  window.__cbApplyNativeUsage = function (json) {
    try {
      var incoming = typeof json === "string" ? JSON.parse(json) : json;
      if (!incoming || typeof incoming !== "object") return;
      var changes = {};
      ["usageTimersMs", "usageResetAtMs", "usageBucketsMs"].forEach(function (key) {
        if (incoming[key] && typeof incoming[key] === "object") {
          var oldValue = store[key];
          store[key] = incoming[key];
          changes[key] = { oldValue: oldValue, newValue: incoming[key] };
        }
      });
      if (Object.keys(changes).length === 0) return;
      try {
        window.localStorage.setItem(STORE_KEY, JSON.stringify(store));
      } catch (_) {}
      notifyChanges(changes);
    } catch (_) {}
  };

  // Only v.log output, keyed by immutable group ID. Config snapshots must
  // never overwrite this independent log store. The retired mixed buffer is ignored.
  var RULE_LOG_KEY = "__cb_rule_logs_by_group__";
  var ruleLogs = Object.create(null);
  var logFeedCounter = 0;
  var logFeedSession = Date.now() + "-" + Math.random().toString(36).slice(2);
  try {
    var savedLogs = JSON.parse(window.localStorage.getItem(RULE_LOG_KEY) || "{}");
    Object.keys(savedLogs || {}).forEach(function (groupId) {
      if (!Array.isArray(savedLogs[groupId])) return;
      ruleLogs[groupId] = savedLogs[groupId].filter(function (entry) {
        return entry && entry.source === "v.log" && entry.groupId === groupId;
      }).slice(-200);
    });
  } catch (_) {}
  delete store.ruleLog;

  function persistRuleLogs() {
    try { window.localStorage.setItem(RULE_LOG_KEY, JSON.stringify(ruleLogs)); } catch (_) {}
  }

  function pruneRuleLogs() {
    var ids = new Set((store.blockedGroups || []).map(function (group) { return group.id; }));
    Object.keys(ruleLogs).forEach(function (id) { if (!ids.has(id)) delete ruleLogs[id]; });
    persistRuleLogs();
  }

  function nativeLogToFeedEntry(e) {
    if (!e || e.source !== "v.log" || typeof e.groupId !== "string" || !e.groupId) return null;
    var ts = e.timestamp ? new Date(e.timestamp).getTime() : Date.now();
    if (!Number.isFinite(ts)) ts = Date.now();
    return {
      id: "native-" + logFeedSession + "-" + (++logFeedCounter),
      ts: ts, source: "v.log", level: "log", groupId: e.groupId,
      eventType: e.eventType || "", message: e.message || ""
    };
  }

  window.__cbApplyNativeRuleLog = function (json) {
    try {
      var entries = typeof json === "string" ? JSON.parse(json) : json;
      if (!Array.isArray(entries)) return;
      entries.forEach(function (nativeEntry) {
        var entry = nativeLogToFeedEntry(nativeEntry);
        if (!entry) return;
        var feed = ruleLogs[entry.groupId] || [];
        feed.push(entry);
        ruleLogs[entry.groupId] = feed.slice(-200);
        window.__cbDispatchRuntimeMessage({ type: "log-feed-entry", entry: entry });
      });
      pruneRuleLogs();
    } catch (_) {}
  };

  var changeListeners = [];

  function notifyChanges(changes) {
    for (var i = 0; i < changeListeners.length; i++) {
      try {
        changeListeners[i](changes, "local");
      } catch (_) {}
    }
  }

  function deepClone(value) {
    if (value === undefined) {
      return undefined;
    }
    try {
      return JSON.parse(JSON.stringify(value));
    } catch (_) {
      return value;
    }
  }

  function resolveQuery(query) {
    var out = {};
    if (query === null || query === undefined) {
      for (var k in store) {
        if (Object.prototype.hasOwnProperty.call(store, k)) {
          out[k] = deepClone(store[k]);
        }
      }
      return out;
    }
    if (typeof query === "string") {
      out[query] = deepClone(store[query]);
      return out;
    }
    if (Array.isArray(query)) {
      query.forEach(function (key) {
        out[key] = deepClone(store[key]);
      });
      return out;
    }
    if (typeof query === "object") {
      Object.keys(query).forEach(function (key) {
        out[key] = Object.prototype.hasOwnProperty.call(store, key)
          ? deepClone(store[key])
          : deepClone(query[key]);
      });
      return out;
    }
    return out;
  }

  function settleCallback(promiseResult, callback) {
    if (typeof callback === "function") {
      Promise.resolve(promiseResult).then(function (value) {
        callback(value);
      });
      return undefined;
    }
    return Promise.resolve(promiseResult);
  }

  var storageLocal = {
    get: function (query, callback) {
      return settleCallback(resolveQuery(query), callback);
    },
    set: function (items, callback) {
      var changes = {};
      var before = {};
      Object.keys(items || {}).forEach(function (key) {
        before[key] = store[key];
        changes[key] = {
          oldValue: deepClone(store[key]),
          newValue: deepClone(items[key])
        };
        store[key] = deepClone(items[key]);
      });
      persist(Object.keys(items || {}), before);
      notifyChanges(changes);
      return settleCallback(undefined, callback);
    },
    remove: function (keys, callback) {
      var list = Array.isArray(keys) ? keys : [keys];
      var changes = {};
      list.forEach(function (key) {
        changes[key] = { oldValue: deepClone(store[key]), newValue: undefined };
        delete store[key];
      });
      persist(list);
      notifyChanges(changes);
      return settleCallback(undefined, callback);
    }
  };

  // ----- runtime -----

  var messageListeners = [];

  // A request Mac Vault answers through window.__cbNativeReply(id, reply).
  var nativeReplies = {};
  var nativeReplySeq = 0;
  function nativeRequest(kind, message, fallback) {
    var bridge = nativeBridge();
    if (!bridge) return Promise.resolve(fallback);
    return new Promise(function (resolve) {
      var id = "r" + (++nativeReplySeq);
      nativeReplies[id] = resolve;
      setTimeout(function () {
        if (nativeReplies[id]) { delete nativeReplies[id]; resolve(fallback); }
      }, 5000);
      try {
        bridge.postMessage({ kind: kind, message: message, requestId: id });
      } catch (_) {
        delete nativeReplies[id];
        resolve(fallback);
      }
    });
  }
  window.__cbNativeReply = function (id, reply) {
    var resolve = nativeReplies[id];
    if (resolve) { delete nativeReplies[id]; resolve(reply); }
  };

  // cbasset Blob downloads are cancelled by WebKit; save the selected log natively.
  window.__cbSaveRuleLog = function (filename, text) {
    return nativeRequest("save-rule-log", { filename: filename, text: text }, { ok: false, error: "Log download unavailable." });
  };

  function bridgeOrResolve(kind, message, fallback) {
    var bridge = nativeBridge();
    if (bridge) {
      try {
        bridge.postMessage({ kind: kind, message: message });
      } catch (_) {}
    }
    return Promise.resolve(fallback);
  }

  function handleSendMessage(message) {
    var type = message && message.type;
    switch (type) {
      case "get-log-feed":
        pruneRuleLogs();
        return Promise.resolve({ ok: true, entries: (ruleLogs[message.groupId] || []).slice() });
      case "clear-log-feed":
        delete ruleLogs[message.groupId];
        persistRuleLogs();
        return nativeRequest("clear-rule-log", message, { ok: true });
      case "run-custom-group":
        // The rule loads in Mac Vault's own engine; its load result comes back.
        return nativeRequest("run-custom-group", message, { ok: false, error: "rules-not-running" });
      case "fire-snooze-press":
        return bridgeOrResolve("fire-snooze-press", message, { ok: true });
      case "vault-classifier-tag-names":
        return nativeRequest("vault-classifier-tag-names", message, { ok: false, names: [] });
      case "reset-group-runtime":
        return bridgeOrResolve("reset-group-runtime", message, { ok: true });
      case "clusters-status":
        return bridgeOrResolve("clusters-status", message, { ok: true });
      case "group-link":
      case "group-unlink":
        return bridgeOrResolve(message.type, message, { ok: true });
      default:
        return Promise.resolve({ ok: true });
    }
  }

  var runtime = {
    id: window.__CB_DESKTOP_PROGRAM_ID === "windowsapp" ? "windows-vault" : "mac-vault",
    lastError: null,
    getURL: function (path) {
      try {
        return new URL(String(path || ""), document.baseURI).href;
      } catch (_) {
        return String(path || "");
      }
    },
    getManifest: function () {
      return window.__CB_DESKTOP_MANIFEST || { version: "1.2.0", name: "macosBlocker" };
    },
    sendMessage: function (message, callback) {
      var result = handleSendMessage(message);
      if (typeof callback === "function") {
        result.then(callback);
        return undefined;
      }
      return result;
    },
    onMessage: {
      addListener: function (fn) {
        if (typeof fn === "function") messageListeners.push(fn);
      },
      removeListener: function (fn) {
        var i = messageListeners.indexOf(fn);
        if (i >= 0) messageListeners.splice(i, 1);
      },
      hasListener: function (fn) {
        return messageListeners.indexOf(fn) >= 0;
      }
    }
  };

  // Let the native host deliver a message into the page (e.g. log-feed push).
  window.__cbDispatchRuntimeMessage = function (message) {
    for (var i = 0; i < messageListeners.length; i++) {
      try {
        messageListeners[i](message, { id: runtime.id }, function () {});
      } catch (_) {}
    }
  };

  // ----- permissions (always granted on native; hides the site-access banner) -----

  var permissions = {
    contains: function (_query, callback) {
      return settleCallback(true, callback);
    },
    request: function (_query, callback) {
      return settleCallback(true, callback);
    }
  };

  // ----- i18n (best effort; editor primarily uses translation/*.json) -----

  var i18n = {
    getMessage: function (key) {
      return key;
    },
    getUILanguage: function () {
      try {
        return navigator.language || "en";
      } catch (_) {
        return "en";
      }
    }
  };

  window.chrome = window.chrome || {};
  window.chrome.__cbShim = true;
  window.chrome.storage = {
    local: storageLocal,
    onChanged: {
      addListener: function (fn) {
        if (typeof fn === "function") changeListeners.push(fn);
      },
      removeListener: function (fn) {
        var i = changeListeners.indexOf(fn);
        if (i >= 0) changeListeners.splice(i, 1);
      },
      hasListener: function (fn) {
        return changeListeners.indexOf(fn) >= 0;
      }
    }
  };
  window.chrome.runtime = runtime;
  window.chrome.permissions = permissions;
  window.chrome.i18n = i18n;

  // Pull the installed-application inventory (served dynamically by the native
  // scheme handler). It can be multi-megabyte with icons, so we fetch it rather
  // than have it injected. Resolves relative to the current page origin.
  try {
    if (typeof fetch === "function") {
      fetch("app-inventory.json", { cache: "no-store" })
        .then(function (response) {
          return response && response.ok ? response.json() : null;
        })
        .then(function (list) {
          if (Array.isArray(list) && typeof window.__cbApplyAppInventory === "function") {
            window.__cbApplyAppInventory(list);
          }
        })
        .catch(function () {});
    }
  } catch (_) {}
})();
