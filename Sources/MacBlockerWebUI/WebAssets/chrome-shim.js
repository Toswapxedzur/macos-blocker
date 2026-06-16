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

  function loadStore() {
    try {
      return JSON.parse(window.localStorage.getItem(STORE_KEY) || "{}") || {};
    } catch (_) {
      return {};
    }
  }

  function persist() {
    try {
      window.localStorage.setItem(STORE_KEY, JSON.stringify(store));
    } catch (_) {}
    var bridge = nativeBridge();
    if (bridge) {
      try {
        bridge.postMessage({ kind: "persist-store", store: store });
      } catch (_) {}
    }
  }

  var store = loadStore();

  // Allow the native host to seed/replace the store before first read.
  window.__cbApplyNativeStore = function (json) {
    try {
      var incoming = typeof json === "string" ? JSON.parse(json) : json;
      if (incoming && typeof incoming === "object") {
        store = incoming;
        try {
          window.localStorage.setItem(STORE_KEY, JSON.stringify(store));
        } catch (_) {}
      }
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
      ["usageTimersMs", "usageResetAtMs"].forEach(function (key) {
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

  // Native rule-log push. Each entry: { timestamp, level, group, message }.
  // Stored under the "ruleLog" key in the shim store so the popup Log panel
  // can read it like any other chrome.storage.local value.
  // Also dispatches each entry as a "log-feed-entry" runtime message so the
  // popup's live Log panel updates immediately.
  var logFeedCounter = 0;

  function nativeLogToFeedEntry(e) {
    var ts = e.timestamp ? new Date(e.timestamp).getTime() : Date.now();
    if (!Number.isFinite(ts)) ts = Date.now();
    return {
      id: "native-" + ts + "-" + (++logFeedCounter),
      ts: ts,
      level: e.level || "log",
      eventType: e.group || "",
      groupName: e.group || "",
      message: e.message || ""
    };
  }

  // System overlay panel events pushed from the native host (e.g. parental PIN
  // entry). The web editor registers handlers via window.__cbSystemPanelHandlers
  // (see openOverlayPanel in popup.js).
  window.__cbSystemPanelHandlers = window.__cbSystemPanelHandlers || [];
  window.__cbSystemPanelEvent = function (json) {
    try {
      var events = typeof json === "string" ? JSON.parse(json) : json;
      if (!Array.isArray(events)) events = [events];
      var handlers = window.__cbSystemPanelHandlers.slice();
      for (var i = 0; i < events.length; i++) {
        for (var j = 0; j < handlers.length; j++) {
          try { handlers[j](events[i]); } catch (_) {}
        }
      }
    } catch (_) {}
  };

  window.__cbApplyNativeRuleLog = function (json) {
    try {
      var entries = typeof json === "string" ? JSON.parse(json) : json;
      if (!Array.isArray(entries) || entries.length === 0) return;
      var existing = Array.isArray(store.ruleLog) ? store.ruleLog : [];
      var merged = existing.concat(entries);
      if (merged.length > 200) merged = merged.slice(merged.length - 200);
      var oldValue = store.ruleLog;
      store.ruleLog = merged;
      try {
        window.localStorage.setItem(STORE_KEY, JSON.stringify(store));
      } catch (_) {}
      notifyChanges({ ruleLog: { oldValue: oldValue, newValue: merged } });

      for (var i = 0; i < entries.length; i++) {
        try {
          window.__cbDispatchRuntimeMessage({
            type: "log-feed-entry",
            entry: nativeLogToFeedEntry(entries[i])
          });
        } catch (_) {}
      }
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
      Object.keys(items || {}).forEach(function (key) {
        changes[key] = {
          oldValue: deepClone(store[key]),
          newValue: deepClone(items[key])
        };
        store[key] = deepClone(items[key]);
      });
      persist();
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
      persist();
      notifyChanges(changes);
      return settleCallback(undefined, callback);
    }
  };

  // ----- custom-rule syntax check (runs in-page, like the sandbox) -----

  function noop() {}

  function stubHelpers() {
    return new Proxy(
      {},
      {
        get: function () {
          return function () {
            return new Proxy({}, { get: function () { return noop; } });
          };
        }
      }
    );
  }

  function countingRegistry(onRegister) {
    var api = {
      register: function () {
        onRegister();
        return true;
      },
      unregister: function () { return true; },
      unregisterAll: function () { return 0; },
      getEvent: function () { return null; },
      getEvents: function () { return {}; },
      countRegistered: function () { return 0; },
      post: noop
    };
    var MAX_HANDLERS = 1000;
    var registered = 0;
    var typed = [
      "TickEvent", "TimerEnded", "SnoozePress",
      "PanelEvent", "LocalFileEvent",
      "OpenAppEvent", "CloseAppEvent", "FocusEvent", "UnfocusEvent",
      "MinimizeEvent", "UnminimizeEvent", "SwitchAppEvent", "AppChangedEvent",
      "UsageThresholdReached", "ScheduleChanged", "ShieldAction"
    ];
    function cappedRegister() {
      if (registered < MAX_HANDLERS) { registered++; onRegister(); return true; }
      return false;
    }
    typed.forEach(function (name) {
      api["register" + name] = cappedRegister;
      api["register" + name + "Event"] = cappedRegister;
      api["get" + name] = function () { return null; };
      api["get" + name + "s"] = function () { return {}; };
      api["get" + name + "Event"] = function () { return null; };
      api["get" + name + "Events"] = function () { return {}; };
      api["count" + name + "Registered"] = function () { return 0; };
      api["count" + name + "EventRegistered"] = function () { return 0; };
    });
    return new Proxy(api, {
      get: function (target, prop) {
        if (prop in target) return target[prop];
        if (typeof prop === "string" && prop.indexOf("register") === 0) {
          return cappedRegister;
        }
        return noop;
      }
    });
  }

  function checkSyntax(source) {
    try {
      var count = 0;
      var factory = new Function('"use strict"; return (' + String(source || "") + "\n);");
      var rule = factory();
      if (typeof rule !== "function") {
        return { ok: true, result: { ok: false, error: "Rule must evaluate to a function." } };
      }
      try {
        rule(countingRegistry(function () { count += 1; }), stubHelpers());
      } catch (runErr) {
        // Registration body referenced a helper at top level; syntax is
        // still valid, so report ok with however many handlers registered.
        return { ok: true, result: { ok: true, handlers: count } };
      }
      return { ok: true, result: { ok: true, handlers: count } };
    } catch (parseErr) {
      return {
        ok: true,
        result: { ok: false, error: String((parseErr && parseErr.message) || parseErr) }
      };
    }
  }

  // ----- runtime -----

  var messageListeners = [];

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
        var feed = Array.isArray(store.ruleLog) ? store.ruleLog : [];
        var mapped = feed.map(function (e, i) { return nativeLogToFeedEntry(e); });
        return Promise.resolve({ ok: true, entries: mapped });
      case "clear-log-feed":
        store.ruleLog = [];
        try { window.localStorage.setItem(STORE_KEY, JSON.stringify(store)); } catch (_) {}
        return Promise.resolve({ ok: true });
      case "check-custom-group-syntax":
        return Promise.resolve(checkSyntax(message && message.source));
      case "run-custom-group":
        var runResult = checkSyntax(message && message.source);
        var bridge = nativeBridge();
        if (bridge) {
          try { bridge.postMessage({ kind: "run-custom-group", message: message }); } catch (_) {}
        }
        return Promise.resolve({
          ok: true,
          loadResult: runResult && runResult.result ? runResult.result : { ok: true, handlers: 0 }
        });
      case "fire-snooze-press":
        return bridgeOrResolve("fire-snooze-press", message, { ok: true });
      case "custom-panel-event":
        return bridgeOrResolve("custom-panel-event", message, { ok: true });
      case "show-system-panel":
        return bridgeOrResolve("show-system-panel", message, { ok: true });
      case "dismiss-system-panel":
        return bridgeOrResolve("dismiss-system-panel", message, { ok: true });
      case "request-app-blocking-permission":
        return bridgeOrResolve("request-app-blocking-permission", message, { ok: true });
      case "open-permission-settings":
        return bridgeOrResolve("open-permission-settings", message, { ok: true });
      case "refresh-blocking-rules":
        return bridgeOrResolve("refresh-blocking-rules", message, { ok: true });
      case "unload-custom-group":
        return bridgeOrResolve("unload-custom-group", message, { ok: true });
      case "connection-server-start":
        return bridgeOrResolve("connection-server-start", message, { ok: true });
      case "connection-server-stop":
        return bridgeOrResolve("connection-server-stop", message, { ok: true });
      case "connection-connect":
        return bridgeOrResolve("connection-connect", message, { ok: true });
      case "connection-disconnect":
        return bridgeOrResolve("connection-disconnect", message, { ok: true });
      case "connection-status":
        return bridgeOrResolve("connection-status", message, { ok: true });
      case "group-connect":
        return bridgeOrResolve("group-connect", message, { ok: true });
      case "group-disconnect":
        return bridgeOrResolve("group-disconnect", message, { ok: true });
      case "group-sync":
        return bridgeOrResolve("group-sync", message, { ok: true });
      case "groups-announce":
        return bridgeOrResolve("groups-announce", message, { ok: true });
      case "clusters-status":
        return bridgeOrResolve("clusters-status", message, { ok: true });
      default:
        return Promise.resolve({ ok: true });
    }
  }

  var runtime = {
    id: "ios-blocker",
    lastError: null,
    getURL: function (path) {
      try {
        return new URL(String(path || ""), document.baseURI).href;
      } catch (_) {
        return String(path || "");
      }
    },
    getManifest: function () {
      return { version: "1.2.0", name: "macosBlocker" };
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
