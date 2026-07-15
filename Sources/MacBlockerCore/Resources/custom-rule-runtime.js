/*
 * macosBlocker native-app custom-rule runtime.
 *
 * Runs inside JavaScriptCore (no DOM, no Web APIs, no chrome.*). It reimplements
 * the customBlocker custom-rule contract for the parts that make sense when the
 * blocker controls native applications:
 *
 *   - the full event registry (11 built-in types + typed registrars, priorities,
 *     intervalMs throttling, post(), unregister, counts)
 *   - the ev object (fields + preventDefault/stopPropagation/setResult/getResult/
 *     post, plus block/allow/setShieldMessage)
 *   - helpers: getLogHelper, getDomainHelper/getDomainUtility, getTimerHelper,
 *     getPersistenceHelper, getStorageHelper, getPanelHelper,
 *     getLocalFolderHelper, getPlatformHelper (URL classifiers)
 *
 * Browser events and browser-control helpers are intentionally unavailable.
 * Website, DOM, and tab control belong only to the browser extensions.
 *
 * dispatch() returns a JSON array of PolicyDecision objects for Swift.
 */
var MacBlockerRuntime = (function () {
  var MAX_POST_DEPTH = 16;
  var MAX_HANDLERS_PER_GROUP = 1000;
  var MAX_LOGS_PER_DISPATCH = 200;
  var MAX_INTENTS_PER_DISPATCH = 256;

  var handlersByGroup = {};      // groupId -> [entry]
  var persistenceByGroup = {};   // groupId -> { key: jsonString }
  var timersByGroup = {};        // groupId -> { timerId: timer }
  var panelsByGroup = {};        // groupId -> { panelId: panel }
  var panelDisplayedByGroup = {}; // groupId -> Set-like { panelId: true }
  var panelPredicatesByGroup = {}; // groupId -> { panelId: { scope?, domain? } }
  var panelInlineHandlersByGroup = {}; // groupId -> { panelId -> [ { controlId, eventName, handler } ] }
  var panelChangedByGroup = {};       // groupId -> boolean (shared across panelHelper instances)
  var panelCreationByGroup = {};      // groupId -> { panelId: sanitized config from last create() } for idempotent re-create
  var previouslyExpired = {};    // groupId -> { timerId: true } for timerEnded dedup
  var logSeenByGroup = {};       // groupId -> { key: true } for per-group log dedup
  var activeDecisionsByGroup = {}; // groupId -> current dispatch's decisions array
  var activeIntentsByGroup = {};   // groupId -> current dispatch's intents array

  var MAX_PANELS_PER_GROUP = 24;
  var MAX_PANEL_CONTROLS = 32;
  var MAX_PANEL_OPTIONS = 64;

  var TYPED = {
    TickEvent: "tickEvent",
    TimerEnded: "timerEnded",
    SnoozePress: "snoozePress",
    PanelEvent: "panelEvent",
    LocalFileEvent: "localFileEvent",
    // Native desktop app lifecycle events (notification/snapshot-driven)
    OpenAppEvent: "openAppEvent",
    CloseAppEvent: "closeAppEvent",
    FocusEvent: "focusEvent",
    UnfocusEvent: "unfocusEvent",
    MinimizeEvent: "minimizeEvent",
    UnminimizeEvent: "unminimizeEvent",
    SwitchAppEvent: "switchAppEvent",
    AppChangedEvent: "appChangedEvent"
  };
  var BROWSER_EVENT_TYPES = {
    openWebEvent: true,
    closeWebEvent: true,
    switchWebEvent: true,
    switchDomainEvent: true,
    webChangedEvent: true,
    pageHeartbeatEvent: true
  };

  // ----------------------------------------------------------------- utils

  function ensureGroup(groupId) {
    if (!handlersByGroup[groupId]) handlersByGroup[groupId] = [];
    return handlersByGroup[groupId];
  }

  function nowMs(ev) {
    var t = ev && ev.now ? Date.parse(ev.now) : Date.now();
    return isNaN(t) ? Date.now() : t;
  }

  function lower(value) {
    return String(value == null ? "" : value).toLowerCase();
  }

  // Manual URL parsing (JSC has no URL global).
  function parseUrl(u) {
    u = String(u == null ? "" : u);
    var out = { protocol: "", host: "", hostname: "", pathname: "", search: "", hash: "" };
    var rest = u;
    var hashIndex = rest.indexOf("#");
    if (hashIndex >= 0) { out.hash = rest.slice(hashIndex); rest = rest.slice(0, hashIndex); }
    var qIndex = rest.indexOf("?");
    if (qIndex >= 0) { out.search = rest.slice(qIndex); rest = rest.slice(0, qIndex); }
    var schemeMatch = rest.match(/^([a-zA-Z][a-zA-Z0-9+.-]*:)\/\//);
    if (schemeMatch) {
      out.protocol = schemeMatch[1];
      rest = rest.slice(schemeMatch[0].length);
      var slash = rest.indexOf("/");
      var authority = slash >= 0 ? rest.slice(0, slash) : rest;
      out.pathname = slash >= 0 ? rest.slice(slash) : "";
      out.host = authority;
      var afterAt = authority.indexOf("@") >= 0 ? authority.split("@").pop() : authority;
      out.hostname = lower(afterAt.split(":")[0]);
    } else {
      out.pathname = rest;
    }
    return out;
  }

  function hostnameOf(u) {
    var h = parseUrl(u).hostname;
    return h.indexOf("www.") === 0 ? h.slice(4) : h;
  }

  function pathnameOf(u) {
    return parseUrl(u).pathname || "/";
  }

  function queryGet(u, key) {
    var s = parseUrl(u).search;
    if (!s) return null;
    var pairs = s.replace(/^\?/, "").split("&");
    for (var i = 0; i < pairs.length; i++) {
      var kv = pairs[i].split("=");
      if (decodeURIComponent(kv[0]) === key) {
        return kv.length > 1 ? decodeURIComponent(kv[1]) : "";
      }
    }
    return null;
  }

  function hostMatches(host, suffixes) {
    host = lower(host);
    for (var i = 0; i < suffixes.length; i++) {
      var s = suffixes[i];
      if (host === s || host.slice(-(s.length + 1)) === "." + s) return true;
    }
    return false;
  }

  // ----------------------------------------------------------- registration

  function register(groupId, type, id, handler, options) {
    if (typeof type !== "string" || !type) return false;
    if (BROWSER_EVENT_TYPES[type]) return false;
    if (typeof id !== "string" || !id) return false;
    if (typeof handler !== "function") return false;
    var list = ensureGroup(groupId);
    var entry = {
      groupId: groupId,
      type: type,
      id: id,
      handler: handler,
      priority: Number(options && options.priority) || 0,
      intervalMs: Number(options && options.intervalMs) || 0,
      lastRun: 0,
      registeredAt: Date.now() + Math.random()
    };
    var existing = -1;
    for (var i = 0; i < list.length; i++) {
      if (list[i].type === type && list[i].id === id) { existing = i; break; }
    }
    if (existing >= 0) list[existing] = entry;
    else if (list.length >= MAX_HANDLERS_PER_GROUP) return false;
    else list.push(entry);
    list.sort(function (a, b) {
      return (b.priority - a.priority) || (a.registeredAt - b.registeredAt);
    });
    return true;
  }

  function unregister(groupId, type, id) {
    var list = handlersByGroup[groupId];
    if (!list) return false;
    for (var i = 0; i < list.length; i++) {
      if (list[i].type === type && list[i].id === id) { list.splice(i, 1); return true; }
    }
    return false;
  }

  function unregisterAll(groupId, type) {
    var list = handlersByGroup[groupId];
    if (!list) return 0;
    var before = list.length;
    handlersByGroup[groupId] = list.filter(function (e) { return e.type !== type; });
    return before - handlersByGroup[groupId].length;
  }

  function countRegistered(groupId, type) {
    var list = handlersByGroup[groupId] || [];
    var n = 0;
    for (var i = 0; i < list.length; i++) if (list[i].type === type) n++;
    return n;
  }

  function getEvents(groupId, type) {
    var list = handlersByGroup[groupId] || [];
    var out = {};
    for (var i = 0; i < list.length; i++) if (list[i].type === type) out[list[i].id] = list[i].handler;
    return out;
  }

  function eventRegistry(groupId) {
    var api = {
      // Raw primitives (mirror customBlocker event-sandbox): on/off/emit.
      on: function (type, id, handler, options) { return register(groupId, type, id, handler, options || {}); },
      off: function (type, id) { return unregister(groupId, type, id); },
      emit: function () { /* top-level emit is ignored; use ev.post inside handlers */ },
      register: function (type, id, handler, options) { return register(groupId, type, id, handler, options || {}); },
      unregister: function (type, id) { return unregister(groupId, type, id); },
      unregisterAll: function (type) { return unregisterAll(groupId, type); },
      countRegistered: function (type) { return countRegistered(groupId, type); },
      getEvent: function (type, id) { return getEvents(groupId, type)[id] || null; },
      getEvents: function (type) { return getEvents(groupId, type); },
      post: function () { /* top-level post is ignored; use ev.post inside handlers */ }
    };

    // iOS-specific event types fired by the Screen Time extensions, in
    // addition to the browser-era types above.
    var IOS_TYPED = {
      UsageThresholdReached: "usageThresholdReached",
      ScheduleChanged: "scheduleChanged",
      ShieldAction: "shieldAction"
    };
    var allTyped = {};
    Object.keys(TYPED).forEach(function (k) { allTyped[k] = TYPED[k]; });
    Object.keys(IOS_TYPED).forEach(function (k) { allTyped[k] = IOS_TYPED[k]; });

    Object.keys(allTyped).forEach(function (suffix) {
      var type = allTyped[suffix];
      api["register" + suffix] = function (id, handler, options) { return register(groupId, type, id, handler, options || {}); };
      api["get" + suffix] = function (id) { return getEvents(groupId, type)[id] || null; };
      api["get" + suffix + "s"] = function () { return getEvents(groupId, type); };
      api["count" + suffix + "Registered"] = function () { return countRegistered(groupId, type); };
      // "...Event" aliases used by some templates.
      api["register" + suffix + "Event"] = api["register" + suffix];
      api["get" + suffix + "Event"] = api["get" + suffix];
      api["get" + suffix + "Events"] = api["get" + suffix + "s"];
      api["count" + suffix + "EventRegistered"] = api["count" + suffix + "Registered"];
    });

    // Unknown registrar names return a harmless no-op rather than throwing.
    return new Proxy(api, {
      get: function (target, prop) {
        if (prop in target) return target[prop];
        if (typeof prop === "string" && prop.indexOf("register") === 0) {
          return function () { return false; };
        }
        return function () { return undefined; };
      }
    });
  }

  // ------------------------------------------------------------------ timers

  function timerStore(groupId) {
    if (!timersByGroup[groupId]) timersByGroup[groupId] = {};
    return timersByGroup[groupId];
  }

  function timerHelper(groupId) {
    var store = timerStore(groupId);
    function sanitizeOverlayStyle(style) {
      if (!style || typeof style !== "object") return null;
      var keys = ["color", "background", "fontSize", "fontWeight", "border", "borderRadius", "padding", "opacity", "icon"];
      var out = {};
      for (var i = 0; i < keys.length; i++) {
        var v = style[keys[i]];
        if (typeof v === "string" && v) out[keys[i]] = v.slice(0, 120);
        else if (keys[i] === "opacity" && isFinite(Number(v))) out[keys[i]] = String(Number(v));
      }
      var has = false; for (var k in out) { has = true; break; }
      return has ? out : null;
    }
    function clamp(t, ms) {
      var v = Math.max(0, Math.floor(Number(ms) || 0));
      if (isFinite(t.maxMs)) v = Math.min(t.maxMs, v);
      if (isFinite(t.minMs)) v = Math.max(t.minMs, v);
      return v;
    }
    function make(init) {
      var t = {
        id: String(init.id),
        displayName: String(init.displayName || init.id),
        direction: init.direction === "forward" ? "forward" : "backward",
        currentMs: Number(init.currentMs) || 0,
        isPaused: false,
        scope: init.scope || null,
        domain: init.domain || null,
        accrueWhen: init.accrueWhen || null
      };
      if (isFinite(Number(init.minMs)) && Number(init.minMs) > 0) t.minMs = Math.floor(Number(init.minMs));
      if (isFinite(Number(init.maxMs)) && Number(init.maxMs) > 0) t.maxMs = Math.floor(Number(init.maxMs));
      if (isFinite(Number(init.stepMs)) && Number(init.stepMs) > 0) t.stepMs = Math.floor(Number(init.stepMs));
      var os = sanitizeOverlayStyle(init.overlayStyle);
      if (os) t.overlayStyle = os;
      t.currentMs = clamp(t, t.currentMs);
      return t;
    }
    return {
      groupId: groupId,
      create: function (init) { var t = make(init || {}); store[t.id] = t; return t.id; },
      getOrCreateTimer: function (init) {
        init = init || {};
        if (store[init.id]) return store[init.id];
        var t = make(init); store[t.id] = t; return t;
      },
      delete: function (id) { delete store[id]; },
      pause: function (id) { if (store[id]) store[id].isPaused = true; },
      resume: function (id) { if (store[id]) store[id].isPaused = false; },
      setDirection: function (id, dir) { if (store[id]) store[id].direction = dir === "forward" ? "forward" : "backward"; },
      setCurrentMs: function (id, ms) { if (store[id]) store[id].currentMs = clamp(store[id], ms); },
      addMs: function (id, delta) { if (store[id]) store[id].currentMs = clamp(store[id], store[id].currentMs + (Number(delta) || 0)); },
      subMs: function (id, delta) { if (store[id]) store[id].currentMs = clamp(store[id], store[id].currentMs - (Number(delta) || 0)); },
      setBounds: function (id, minMs, maxMs) {
        var t = store[id]; if (!t) return;
        if (isFinite(Number(minMs)) && Number(minMs) > 0) t.minMs = Math.floor(Number(minMs)); else if (minMs === null) delete t.minMs;
        if (isFinite(Number(maxMs)) && Number(maxMs) > 0) t.maxMs = Math.floor(Number(maxMs)); else if (maxMs === null) delete t.maxMs;
        t.currentMs = clamp(t, t.currentMs);
      },
      setStep: function (id, stepMs) {
        var t = store[id]; if (!t) return;
        if (isFinite(Number(stepMs)) && Number(stepMs) > 0) t.stepMs = Math.floor(Number(stepMs)); else delete t.stepMs;
      },
      setOverlayStyle: function (id, style) {
        var t = store[id]; if (!t) return;
        var os = sanitizeOverlayStyle(style);
        if (os) t.overlayStyle = os; else delete t.overlayStyle;
      },
      setDisplayName: function (id, name) { if (store[id]) store[id].displayName = String(name); },
      getCurrentMs: function (id) { return store[id] ? store[id].currentMs : 0; },
      isExpired: function (id) {
        var t = store[id];
        if (!t) return false;
        return t.direction === "backward" ? t.currentMs <= 0 : false;
      },
      isPaused: function (id) { return store[id] ? store[id].isPaused : false; },
      getDirection: function (id) { return store[id] ? store[id].direction : null; },
      getDisplayName: function (id) { return store[id] ? store[id].displayName : null; },
      exists: function (id) { return !!store[id]; },
      getState: function (id) {
        var t = store[id];
        if (!t) return null;
        var s = { id: t.id, displayName: t.displayName, direction: t.direction, isPaused: t.isPaused, currentMs: t.currentMs, isExpired: t.direction === "backward" ? t.currentMs <= 0 : false };
        if (isFinite(t.minMs)) s.minMs = t.minMs;
        if (isFinite(t.maxMs)) s.maxMs = t.maxMs;
        if (isFinite(t.stepMs)) s.stepMs = t.stepMs;
        if (t.overlayStyle) s.overlayStyle = t.overlayStyle;
        return s;
      },
      list: function () { return Object.keys(store).map(function (k) { return store[k]; }); }
    };
  }

  // ------------------------------------------------------------- persistence

  function persistenceHelper(groupId) {
    if (!persistenceByGroup[groupId]) persistenceByGroup[groupId] = {};
    var bag = persistenceByGroup[groupId];
    var api = {
      get: function (key, dflt) { return key in bag ? JSON.parse(bag[key]) : (dflt === undefined ? null : dflt); },
      set: function (key, value) { bag[key] = JSON.stringify(value); },
      delete: function (key) { delete bag[key]; },
      has: function (key) { return key in bag; },
      keys: function () { return Object.keys(bag); },
      entries: function () { return Object.keys(bag).map(function (k) { return [k, JSON.parse(bag[k])]; }); },
      clear: function () { var keys = Object.keys(bag); for (var i = 0; i < keys.length; i++) delete bag[keys[i]]; },
      size: function () { return Object.keys(bag).length; }
    };
    return api;
  }

  function storageHelper(groupId) {
    var p = persistenceHelper(groupId);
    p.requestAsyncGet = function () { return "req-" + Date.now(); };
    p.requestAsyncSet = function () { return "req-" + Date.now(); };
    return p;
  }

  // ------------------------------------------------------------- local folder

  var localFolderRequestCounter = 0;
  var LOCAL_FOLDER_EXTENSIONS = { ".txt": true, ".csv": true, ".json": true };

  function localFolderExtensionOf(path) {
    var match = String(path || "").toLowerCase().match(/(\.[a-z0-9]+)$/);
    return match ? match[1] : "";
  }

  function safeLocalFolderPath(path, allowDirectory) {
    var raw = String(path == null ? "" : path)
      .trim()
      .replace(/\\/g, "/")
      .replace(/\/+/g, "/")
      .replace(/\/$/, "");
    if (!raw && allowDirectory) return "";
    if (!raw || raw.charAt(0) === "/" || /^[a-z]:\//i.test(raw) || /^[a-z][a-z0-9+.-]*:/i.test(raw)) return null;
    var parts = raw.split("/").filter(function (part) { return !!part; });
    if (parts.length === 0) return null;
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i];
      if (part === "." || part === ".." || part.charAt(0) === "." || !/^[A-Za-z0-9 _.,@()\-]+$/.test(part)) return null;
    }
    var normalized = parts.join("/");
    return allowDirectory || LOCAL_FOLDER_EXTENSIONS[localFolderExtensionOf(normalized)] ? normalized : null;
  }

  function localFolderHelper(groupId, pushIntent) {
    function request(action, path, extra) {
      var allowDirectory = action === "list";
      var sp = safeLocalFolderPath(path || "", allowDirectory);
      if (sp === null) return "";
      var reqId = "lf-" + groupId + "-" + (++localFolderRequestCounter);
      var intent = { kind: "localFile", action: action, path: sp, groupId: groupId, requestId: reqId };
      if (extra) { for (var k in extra) intent[k] = extra[k]; }
      pushIntent(intent);
      return reqId;
    }
    return {
      isAvailable: function () { return true; },
      requestRead: function (path) { return request("read", path); },
      requestWrite: function (path, text) { return typeof text === "string" ? request("write", path, { text: text }) : ""; },
      requestAppend: function (path, text) { return typeof text === "string" ? request("append", path, { text: text }) : ""; },
      requestList: function (dirPath) { return request("list", dirPath || ""); },
      requestExists: function (path) { return request("exists", path); },
      requestReadJson: function (path) {
        return localFolderExtensionOf(path) === ".json" ? request("readJson", path) : "";
      },
      requestWriteJson: function (path, value) {
        if (localFolderExtensionOf(path) !== ".json") return "";
        var text;
        try { text = JSON.stringify(value); } catch (e) { return ""; }
        return typeof text === "string" ? request("writeJson", path, { text: text }) : "";
      }
    };
  }

  // ---------------------------------------------------------------- domain

  var PLATFORM_HOSTS = {
    youtube: ["youtube.com", "youtu.be", "m.youtube.com"],
    tiktok: ["tiktok.com"],
    instagram: ["instagram.com"],
    facebook: ["facebook.com", "fb.com"],
    twitch: ["twitch.tv"],
    reddit: ["reddit.com"],
    discord: ["discord.com", "discordapp.com"]
  };

  function urlClassifiers(platform) {
    return {
      isPlatformUrl: function (u) { return hostMatches(hostnameOf(u), PLATFORM_HOSTS[platform] || []); },
      isShortUrl: function (u) {
        if (!hostMatches(hostnameOf(u), PLATFORM_HOSTS[platform] || [])) return false;
        var p = pathnameOf(u);
        if (platform === "youtube") return p.indexOf("/shorts/") === 0;
        if (platform === "instagram") return p.indexOf("/reels/") === 0 || p.indexOf("/reel/") === 0;
        if (platform === "tiktok") return /\/video\//.test(p) || p.indexOf("/foryou") === 0;
        return false;
      },
      isVideoUrl: function (u) {
        if (!hostMatches(hostnameOf(u), PLATFORM_HOSTS[platform] || [])) return false;
        var p = pathnameOf(u);
        if (platform === "youtube") return p.indexOf("/watch") === 0 || p.indexOf("/shorts/") === 0;
        return /\/video\//.test(p) || /\/watch/.test(p);
      },
      isPostUrl: function (u) {
        if (!hostMatches(hostnameOf(u), PLATFORM_HOSTS[platform] || [])) return false;
        var p = pathnameOf(u);
        return /\/p\//.test(p) || /\/post/.test(p) || /\/status\//.test(p);
      },
      isHomePage: function (u) {
        if (!hostMatches(hostnameOf(u), PLATFORM_HOSTS[platform] || [])) return false;
        var p = pathnameOf(u);
        return p === "/" || p === "";
      },
      extractAuthor: function (u) {
        if (!hostMatches(hostnameOf(u), PLATFORM_HOSTS[platform] || [])) return null;
        var p = pathnameOf(u);
        var at = p.match(/\/@([^\/?#]+)/);
        if (at) return at[1];
        var ch = p.match(/\/channel\/([^\/?#]+)/);
        if (ch) return ch[1];
        return null;
      },
      extractVideoId: function (u) {
        if (!hostMatches(hostnameOf(u), PLATFORM_HOSTS[platform] || [])) return null;
        if (platform === "youtube") {
          var v = queryGet(u, "v");
          if (v) return v;
          var s = pathnameOf(u).match(/\/shorts\/([^\/?#]+)/);
          if (s) return s[1];
          if (hostnameOf(u) === "youtu.be") return pathnameOf(u).replace(/^\//, "") || null;
        }
        return null;
      }
    };
  }

  function domainHelper() {
    var d = {
      hostnameOf: hostnameOf,
      pathnameOf: pathnameOf,
      queryGet: queryGet,
      queryHas: function (u, key, value) { var v = queryGet(u, key); return value === undefined ? v !== null : v === value; },
      matches: function (host, site) { return hostMatches(lower(host), [hostnameOf(site)]); },
      matchesAny: function (u, patterns) {
        var host = hostnameOf(u);
        var arr = Array.isArray(patterns) ? patterns : [patterns];
        for (var i = 0; i < arr.length; i++) {
          var pat = arr[i];
          if (pat instanceof RegExp) { if (pat.test(u)) return true; }
          else if (hostMatches(host, [hostnameOf(String(pat))])) return true;
        }
        return false;
      },
      pathStartsWith: function (u, prefix) { return pathnameOf(u).indexOf(prefix) === 0; },
      isEmptyStartPage: function (u) { var s = String(u || ""); return s === "" || s === "about:blank" || s === "chrome://newtab/"; },
      isSearchPage: function (u) { return /[?&]q=/.test(String(u)) || /\/search/.test(pathnameOf(u)); },
      isInfiniteFeedUrl: function (u) { return urlClassifiers("youtube").isShortUrl(u) || urlClassifiers("tiktok").isShortUrl(u) || urlClassifiers("instagram").isShortUrl(u); },
      sameSection: function (a, b) { return pathnameOf(a).split("/")[1] === pathnameOf(b).split("/")[1]; },
      getPlatform: function (u) {
        var host = hostnameOf(u);
        var names = Object.keys(PLATFORM_HOSTS);
        for (var i = 0; i < names.length; i++) if (hostMatches(host, PLATFORM_HOSTS[names[i]])) return names[i];
        return null;
      }
    };
    var HOST_CHECK_NAMES = {
      youtube: "isYouTubeHost",
      tiktok: "isTikTokHost",
      instagram: "isInstagramHost",
      facebook: "isFacebookHost",
      twitch: "isTwitchHost",
      reddit: "isRedditHost",
      discord: "isDiscordHost"
    };
    Object.keys(PLATFORM_HOSTS).forEach(function (name) {
      d[HOST_CHECK_NAMES[name]] = function (host) { return hostMatches(lower(host), PLATFORM_HOSTS[name]); };
    });
    ["youtube", "tiktok", "instagram", "facebook", "twitch"].forEach(function (name) {
      d[name] = function () { return urlClassifiers(name); };
    });
    return d;
  }

  // --------------------------------------------------------------- platform

  // Raw platform API. Feed-level DOM control (hide/allow/show/surface) has no
  // meaning on native (there is no page DOM), so these are inert no-ops that
  // log once as unsupported. URL classifiers remain functional. This mirrors
  // the customBlocker raw API surface: platform(name).hide(slot?,pred,opts)
  // etc. — there are no named convenience methods anymore.
  function platformApi(name, logUnsupported) {
    var api = urlClassifiers(name);
    function noop(method) {
      return function () { logUnsupported("platform." + name + "." + method); return undefined; };
    }
    api.hide = noop("hide");
    api.allow = noop("allow");
    api.show = noop("show");
    api.surface = noop("surface");
    api.timer = noop("timer");
    api.snapshot = function () { return null; };
    api.slots = function () { return []; };
    api.surfaces = function () { return []; };
    api.timerSlots = function () { return []; };
    return api;
  }

  function platformHelper(logUnsupported) {
    var helper = {};
    ["youtube", "tiktok", "instagram", "facebook", "twitch"].forEach(function (name) {
      helper[name] = function () { return platformApi(name, logUnsupported); };
    });
    return helper;
  }

  // Top-level helpers.platform(name?) accessor: with a name returns the raw
  // platform api directly; without one returns the {youtube(),tiktok(),...}
  // selector object.
  function platformAccessor(name, logUnsupported) {
    if (typeof name === "string" && name) return platformApi(name, logUnsupported);
    return platformHelper(logUnsupported);
  }

  // ------------------------------------------------- dynamic app blocklist (per-group)

  var dynamicAppBlocklistByGroup = {};  // groupId -> { bundleId -> true }

  function groupAppBlocklist(groupId) {
    if (!dynamicAppBlocklistByGroup[groupId]) dynamicAppBlocklistByGroup[groupId] = {};
    return dynamicAppBlocklistByGroup[groupId];
  }

  function windowHelper(rawEvent, pushIntent) {
    var blockedApps = groupAppBlocklist(rawEvent.groupID);
    var currentAppId = rawEvent.data && rawEvent.data.isBrowser === "true"
      ? ""
      : (rawEvent.data && rawEvent.data.appId || "");
    return {
      current: function () {
        return {
          id: currentAppId,
          name: rawEvent.data && rawEvent.data.appName || "",
          isBrowser: false
        };
      },
      all: function () {
        var list = rawEvent.data && rawEvent.data.allApps;
        if (typeof list === "string") {
          try { return JSON.parse(list); } catch (e) { return []; }
        }
        return [];
      },
      close: function (target) {
        pushIntent({ kind: "window", action: "close", target: String(target || "") });
      },
      block: function (bundleID) {
        var id = String(bundleID || "").trim();
        if (!id) return;
        blockedApps[id] = true;
        pushIntent({ kind: "window", action: "blockApp", target: id });
      },
      unblock: function (bundleID) {
        var id = String(bundleID || "").trim();
        delete blockedApps[id];
        pushIntent({ kind: "window", action: "unblockApp", target: id });
      },
      isBlocked: function (bundleID) {
        return Boolean(blockedApps[String(bundleID || "").trim()]);
      },
      getBlocked: function () {
        return Object.keys(blockedApps);
      }
    };
  }

  // ------------------------------------------------------------------ panels

  var PANEL_POSITIONS = { "top-left":1, "top-right":1, "bottom-left":1, "bottom-right":1, center:1 };
  var PANEL_ALIGNS = { left:1, center:1, right:1 };
  var PANEL_WIDTHS = { small:1, medium:1, large:1 };
  var PANEL_LAYOUTS = { vertical:1, compact:1, comfortable:1, spacious:1, inline:1, row:1, wrap:1, twoColumn:1, grid:1, split:1, form:1, toolbar:1, stack:1 };
  var PANEL_ROLES = { region:1, dialog:1, alert:1, status:1, form:1, group:1 };
  var PANEL_CONTROL_TYPES = { text:1, checkbox:1, select:1, textInput:1, textarea:1, button:1, section:1, timer:1, numberInput:1, range:1, toggle:1, radio:1, date:1, time:1, color:1, pin:1, html:1 };

  function sanitizePanelHtml(value) {
    var html = truncateText(value, 20000);
    if (!html) return "";
    html = html.replace(/<\s*script\b[\s\S]*?<\s*\/\s*script\s*>/gi, "");
    html = html.replace(/<\s*script\b[^>]*>/gi, "");
    html = html.replace(/\son[a-z]+\s*=\s*"[^"]*"/gi, "");
    html = html.replace(/\son[a-z]+\s*=\s*'[^']*'/gi, "");
    html = html.replace(/\son[a-z]+\s*=\s*[^\s>]+/gi, "");
    html = html.replace(/(href|src)\s*=\s*("|')\s*javascript:[^"']*\2/gi, "$1=$2#$2");
    return html;
  }
  var PANEL_CONTROL_ACTIONS = { submit:1, cancel:1, close:1 };

  function truncateText(value, max) {
    var text = String(value == null ? "" : value);
    return text.length > max ? text.slice(0, max) : text;
  }

  function normalizePanelControlType(type) {
    if (type === "input") return "textInput";
    if (type === "dropdown") return "select";
    if (type === "group") return "section";
    if (type === "number") return "numberInput";
    if (type === "slider") return "range";
    if (type === "switch") return "toggle";
    if (type === "raw" || type === "markup") return "html";
    return PANEL_CONTROL_TYPES[type] ? type : "text";
  }

  function sanitizePanelId(value, fallback) {
    return truncateText(value || fallback || "", 80)
      .trim()
      .replace(/\s+/g, "-")
      .replace(/[^A-Za-z0-9_-]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "");
  }

  function sanitizePanelColor(value) {
    var text = String(value == null ? "" : value).trim();
    if (!text || text.length > 64) return null;
    if (/^#[0-9a-f]{3,8}$/i.test(text)) return text;
    if (/^rgba?\([\d\s.,%+-]+\)$/i.test(text)) return text;
    if (/^hsla?\([\d\s.,%+-]+\)$/i.test(text)) return text;
    if (/^[a-z]{3,32}$/i.test(text)) return text;
    return null;
  }

  function sanitizePanelSize(value) {
    if (typeof value === "number" && isFinite(value)) {
      return Math.max(10, Math.min(32, Math.round(value))) + "px";
    }
    var text = String(value == null ? "" : value).trim();
    if (!text) return "";
    var match = text.match(/^(\d+(?:\.\d+)?)(px|rem|em)$/i);
    if (!match) return "";
    var n = Number(match[1]);
    if (!isFinite(n)) return "";
    if (match[2].toLowerCase() === "px") return Math.max(10, Math.min(32, Math.round(n))) + "px";
    return Math.max(0.65, Math.min(2, n)).toFixed(2).replace(/\.?0+$/, "") + match[2].toLowerCase();
  }

  function sanitizePanelWidth(value) {
    if (PANEL_WIDTHS[value]) return value;
    if (typeof value === "number" && isFinite(value)) {
      return Math.max(180, Math.min(520, Math.round(value))) + "px";
    }
    var text = String(value == null ? "" : value).trim();
    if (!text) return "";
    var match = text.match(/^(\d+(?:\.\d+)?)px$/i);
    if (!match) return "";
    var n = Number(match[1]);
    return isFinite(n) ? Math.max(180, Math.min(520, Math.round(n))) + "px" : "";
  }

  function sanitizePanelPriority(value) {
    var n = Number(value);
    return isFinite(n) ? Math.max(-1000, Math.min(1000, Math.round(n))) : 0;
  }

  function sanitizePanelTheme(theme) {
    if (!theme || typeof theme !== "object") return {};
    var out = {};
    var keys = ["background", "foreground", "accent", "border", "muted"];
    for (var i = 0; i < keys.length; i++) {
      var c = sanitizePanelColor(theme[keys[i]]);
      if (c) out[keys[i]] = c;
    }
    var fontSize = sanitizePanelSize(theme.fontSize || theme.textSize);
    var titleSize = sanitizePanelSize(theme.titleSize);
    if (fontSize) out.fontSize = fontSize;
    if (titleSize) out.titleSize = titleSize;
    return out;
  }

  function sanitizePanelNumber(value, min, max, fallback) {
    var n = Number(value);
    var lo = isFinite(Number(min)) ? Number(min) : -1000000;
    var hi = isFinite(Number(max)) ? Number(max) : 1000000;
    var boundLo = Math.min(lo, hi);
    var boundHi = Math.max(lo, hi);
    var base = isFinite(n) ? n : (fallback || 0);
    return Math.max(boundLo, Math.min(boundHi, base));
  }

  function sanitizePanelValue(type, value, control) {
    if (type === "checkbox" || type === "toggle") return value === true || value === "true";
    if (type === "numberInput" || type === "range") {
      return sanitizePanelNumber(value, control && control.min, control && control.max, 0);
    }
    if (type === "select" || type === "radio") return truncateText(value, 256);
    if (type === "textInput" || type === "textarea") return truncateText(value, 2000);
    if (type === "date") { var t = String(value == null ? "" : value).trim(); return /^\d{4}-\d{2}-\d{2}$/.test(t) ? t : ""; }
    if (type === "time") { var t2 = String(value == null ? "" : value).trim(); return /^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$/.test(t2) ? t2 : ""; }
    if (type === "color") { var t3 = String(value == null ? "" : value).trim(); return /^#[0-9a-f]{6}$/i.test(t3) ? t3 : "#000000"; }
    if (type === "pin") {
      var len = (control && control.length) ? Math.max(3, Math.min(12, Math.floor(Number(control.length)) || 6)) : 6;
      return String(value == null ? "" : value).replace(/\D/g, "").slice(0, len);
    }
    if (type === "section" || type === "timer") return "";
    return truncateText(value, 512);
  }

  function sanitizePanelOptions(rawOptions, selectedValue) {
    if (!Array.isArray(rawOptions)) return [];
    var out = [];
    for (var i = 0; i < rawOptions.length && out.length < MAX_PANEL_OPTIONS; i++) {
      var item = rawOptions[i];
      if (item && typeof item === "object") {
        var val = truncateText(item.value || item.label, 256);
        if (!val) continue;
        out.push({ value: val, label: truncateText(item.label || val, 256) });
      } else {
        var sv = truncateText(item, 256);
        if (sv) out.push({ value: sv, label: sv });
      }
    }
    if (out.length > 0) {
      var found = false;
      for (var j = 0; j < out.length; j++) { if (out[j].value === selectedValue) { found = true; break; } }
      if (!found) {
        out = [{ value: selectedValue, label: selectedValue }].concat(out).slice(0, MAX_PANEL_OPTIONS);
      }
    }
    return out;
  }

  function sanitizePanelControl(control, index, depth) {
    if (!control || typeof control !== "object") return null;
    depth = depth || 0;
    var type = normalizePanelControlType(control.type);
    var id = sanitizePanelId(control.id, "control-" + ((index || 0) + 1));
    if (!id) return null;
    var value = sanitizePanelValue(type, control.value, control);
    var out = { id: id, type: type, label: truncateText(control.label || "", 240), value: value, disabled: control.disabled === true, priority: sanitizePanelPriority(control.priority) };
    var layout = PANEL_LAYOUTS[control.layout] ? control.layout : "";
    var align = PANEL_ALIGNS[control.align] ? control.align : "";
    if (layout) out.layout = layout;
    if (align) out.align = align;
    if (control.autoFocus === true) out.autoFocus = true;
    if (type === "numberInput" || type === "range") {
      var cMin = Number(control.min), cMax = Number(control.max);
      if (isFinite(cMin)) out.min = Math.max(-1000000, Math.min(1000000, cMin));
      if (isFinite(cMax)) out.max = Math.max(-1000000, Math.min(1000000, cMax));
      var step = Number(control.step);
      if (isFinite(step) && step > 0) out.step = Math.min(1000000, step);
      out.value = sanitizePanelValue(type, value, out);
    }
    if (type === "text") out.text = truncateText(control.text || control.label || "", 1000);
    if (type === "html") out.html = sanitizePanelHtml(control.html || control.text || "");
    if (type === "section") {
      out.text = truncateText(control.text || control.description || "", 1000);
      out.role = PANEL_ROLES[control.role] ? control.role : "group";
      out.controls = [];
      var rawChildren = Array.isArray(control.controls) ? control.controls : [];
      if (depth < 3) {
        for (var ci = 0; ci < rawChildren.length && out.controls.length < MAX_PANEL_CONTROLS; ci++) {
          var child = sanitizePanelControl(rawChildren[ci], ci, depth + 1);
          if (child) out.controls.push(child);
        }
      }
    }
    if (type === "textInput" || type === "textarea") out.placeholder = truncateText(control.placeholder || "", 500);
    if (type === "pin") {
      out.length = Math.max(3, Math.min(12, Math.floor(Number(control.length)) || 6));
      out.masked = control.masked !== false;
      out.value = sanitizePanelValue(type, value, out);
      if (control.autoSubmit === true) out.autoSubmit = true;
    }
    if (type === "select" || type === "radio") out.options = sanitizePanelOptions(control.options, value);
    if (type === "timer") {
      var timerId = sanitizePanelId(control.timerId || (control.timer && control.timer.id));
      if (timerId) out.timerId = timerId;
      out.format = ["ms", "ss", "mm:ss", "hh:mm:ss"].indexOf(control.format) >= 0 ? control.format : "mm:ss";
      out.showExpired = control.showExpired !== false;
      out.value = "";
    }
    if (type === "button" && !out.label) out.label = truncateText(control.text || "Button", 120);
    if (type === "button" && PANEL_CONTROL_ACTIONS[control.action]) out.action = control.action;
    return out;
  }

  function sanitizePanelConfig(config) {
    if (!config || typeof config !== "object") return null;
    var id = sanitizePanelId(config.id);
    if (!id) return null;
    var controls = [];
    var rawControls = Array.isArray(config.controls) ? config.controls : [];
    for (var i = 0; i < rawControls.length && controls.length < MAX_PANEL_CONTROLS; i++) {
      var c = sanitizePanelControl(rawControls[i], i);
      if (c) controls.push(c);
    }
    return {
      id: id,
      title: truncateText(config.title || "", 240),
      description: truncateText(config.description || config.body || "", 1000),
      position: PANEL_POSITIONS[config.position] ? config.position : "bottom-right",
      align: PANEL_ALIGNS[config.align] ? config.align : "left",
      layout: PANEL_LAYOUTS[config.layout] ? config.layout : "vertical",
      priority: sanitizePanelPriority(config.priority),
      width: sanitizePanelWidth(config.width),
      textSize: sanitizePanelSize(config.textSize || config.fontSize),
      role: PANEL_ROLES[config.role] ? config.role : "region",
      autoFocus: config.autoFocus === true,
      theme: sanitizePanelTheme(config.theme || config.colors || {}),
      controls: controls,
      visible: config.visible !== false
    };
  }

  function clonePanelForSnapshot(panel) {
    try { return JSON.parse(JSON.stringify(panel)); } catch (e) { return null; }
  }

  function panelStateEquals(a, b) {
    try { return JSON.stringify(a) === JSON.stringify(b); } catch (e) { return false; }
  }

  function panelHelper(groupId, timersBucketFn) {
    if (!panelsByGroup[groupId]) panelsByGroup[groupId] = {};
    if (!panelDisplayedByGroup[groupId]) panelDisplayedByGroup[groupId] = {};
    if (!panelPredicatesByGroup[groupId]) panelPredicatesByGroup[groupId] = {};
    if (!panelInlineHandlersByGroup[groupId]) panelInlineHandlersByGroup[groupId] = {};
    if (!panelCreationByGroup[groupId]) panelCreationByGroup[groupId] = {};
    var bucket = panelsByGroup[groupId];
    var displayed = panelDisplayedByGroup[groupId];
    var predicates = panelPredicatesByGroup[groupId];
    var inlineHandlers = panelInlineHandlersByGroup[groupId];
    var creationConfigs = panelCreationByGroup[groupId];

    var INLINE_PROPS = { onEvent:1, onChange:1, onClick:1, onInput:1, onFocus:1, onBlur:1, onSubmit:1, onClose:1, onMount:1, onUnmount:1, onKey:1, onKeyDown:1 };
    function hasInlineProps(obj) {
      if (!obj || typeof obj !== "object") return false;
      for (var k in INLINE_PROPS) { if (typeof obj[k] === "function") return true; }
      if (Array.isArray(obj.controls)) {
        for (var i = 0; i < obj.controls.length; i++) {
          var c = obj.controls[i];
          if (c && typeof c === "object") {
            for (var k2 in INLINE_PROPS) { if (typeof c[k2] === "function") return true; }
          }
        }
      }
      return false;
    }

    function registerInlineHandlers(panelId, rawConfig) {
      if (!rawConfig || typeof rawConfig !== "object") return;
      var handlers = [];
      function addHandler(controlId, eventName, fn) {
        if (typeof fn === "function") handlers.push({ controlId: controlId, eventName: eventName, handler: fn });
      }
      function addAll(controlId, raw) {
        addHandler(controlId, "*", raw.onEvent);
        addHandler(controlId, "change", raw.onChange);
        addHandler(controlId, "click", raw.onClick);
        addHandler(controlId, "input", raw.onInput);
        addHandler(controlId, "focus", raw.onFocus);
        addHandler(controlId, "blur", raw.onBlur);
        addHandler(controlId, "submit", raw.onSubmit);
        addHandler(controlId, "close", raw.onClose);
        addHandler(controlId, "mount", raw.onMount);
        addHandler(controlId, "unmount", raw.onUnmount);
        addHandler(controlId, "key", raw.onKey || raw.onKeyDown);
      }
      addAll(null, rawConfig);
      var rawControls = rawConfig.controls;
      if (Array.isArray(rawControls)) {
        for (var i = 0; i < rawControls.length; i++) {
          var rc = rawControls[i];
          if (rc && typeof rc === "object" && rc.id) addAll(rc.id, rc);
          if (rc && rc.type === "section" && Array.isArray(rc.controls)) {
            for (var j = 0; j < rc.controls.length; j++) {
              var sc = rc.controls[j];
              if (sc && typeof sc === "object" && sc.id) addAll(sc.id, sc);
            }
          }
        }
      }
      if (handlers.length > 0) {
        inlineHandlers[panelId] = handlers;
      } else {
        delete inlineHandlers[panelId];
      }
    }

    function invokeInlineHandlers(panelId, controlId, eventName, data) {
      var list = inlineHandlers[panelId];
      if (!list) return;
      var actionName = data && data.value;
      var matchSet = {};
      matchSet[eventName] = true;
      matchSet["*"] = true;
      if (eventName === "click" && actionName && actionName !== "click") matchSet[actionName] = true;
      for (var i = 0; i < list.length; i++) {
        var h = list[i];
        if (!matchSet[h.eventName]) continue;
        if (h.controlId !== null && h.controlId !== controlId) continue;
        try { h.handler(data); } catch (e) {}
      }
    }

    function getPanel(id) {
      if (typeof id !== "string" || !id) return null;
      var p = bucket[id];
      return p && typeof p === "object" ? p : null;
    }

    function markChanged() { panelChangedByGroup[groupId] = true; }

    function safePredicate(pred, appId) {
      if (typeof pred !== "function") return false;
      try { return !!pred(appId || ""); } catch (e) { return false; }
    }

    function applyScopeAndDomain(id, scope, domain, appId) {
      if (typeof scope === "function") {
        if (!predicates[id]) predicates[id] = {};
        predicates[id].scope = scope;
      } else if (scope === null && predicates[id]) {
        delete predicates[id].scope;
      }
      if (typeof domain === "function") {
        if (!predicates[id]) predicates[id] = {};
        predicates[id].domain = domain;
      } else if (domain === null && predicates[id]) {
        delete predicates[id].domain;
      }
      var panel = getPanel(id);
      delete displayed[id];
      if (!panel || panel.visible === false) return;
      var slot = predicates[id] || {};
      var displayPredicate = typeof (typeof domain === "function" ? domain : slot.domain) === "function"
        ? (typeof domain === "function" ? domain : slot.domain)
        : (typeof scope === "function" ? scope : slot.scope);
      if (typeof displayPredicate !== "function" || safePredicate(displayPredicate, appId)) {
        displayed[id] = true;
      }
    }

    function findControl(panel, controlId) {
      if (!panel || typeof controlId !== "string" || !controlId) return null;
      var walk = function (controls) {
        for (var i = 0; i < (controls || []).length; i++) {
          if (controls[i].id === controlId) return controls[i];
          var child = walk(controls[i].controls);
          if (child) return child;
        }
        return null;
      };
      return walk(panel.controls);
    }

    function getValues(panel) {
      var out = {};
      var visit = function (controls) {
        for (var i = 0; i < (controls || []).length; i++) {
          var c = controls[i];
          if (c.type === "section") { visit(c.controls); continue; }
          if (c.type === "button" || c.type === "text" || c.type === "timer" || c.type === "html") continue;
          out[c.id] = c.value;
        }
      };
      visit(panel && panel.controls);
      return out;
    }

    function hydrateTimerControls(panel) {
      if (!panel || typeof panel !== "object") return panel;
      var timers = timersBucketFn();
      var visit = function (controls) {
        for (var i = 0; i < (controls || []).length; i++) {
          if (controls[i].type === "section") visit(controls[i].controls);
          else if (controls[i].type === "timer" && controls[i].timerId) {
            var t = timers[controls[i].timerId];
            if (t) {
              var ms = Math.max(0, Math.floor(Number(t.currentMs) || 0));
              controls[i].timer = {
                id: t.id, displayName: String(t.displayName || t.id),
                direction: t.direction === "forward" ? "forward" : "backward",
                isPaused: t.isPaused === true, currentMs: ms,
                isExpired: t.direction === "backward" ? ms <= 0 : false
              };
            }
          }
        }
      };
      visit(panel.controls);
      return panel;
    }

    function create(config) {
      if (Object.keys(bucket).length >= MAX_PANELS_PER_GROUP && !getPanel(config && config.id)) return null;
      var panel = sanitizePanelConfig(config);
      if (!panel) return null;
      var prev = getPanel(panel.id);
      // Idempotent re-create: if the panel already exists and the incoming
      // config is identical to the one it was last created from, treat this as
      // a no-op so repeated create() calls (e.g. from a tickEvent handler)
      // preserve the user's live input instead of resetting to source values.
      // Inline handlers and scope are still refreshed (closures change each
      // dispatch); only the panel's data/values are left untouched.
      if (prev && panelStateEquals(creationConfigs[panel.id], panel)) {
        applyScopeAndDomain(panel.id, config.scope, config.domain);
        registerInlineHandlers(panel.id, config);
        return panel.id;
      }
      bucket[panel.id] = panel;
      creationConfigs[panel.id] = clonePanelForSnapshot(panel);
      if (!panelStateEquals(prev, panel)) markChanged();
      applyScopeAndDomain(panel.id, config.scope, config.domain);
      registerInlineHandlers(panel.id, config);
      return panel.id;
    }

    return {
      groupId: groupId,
      create: create,
      getOrCreatePanel: function (config) {
        config = config || {};
        if (typeof config.id !== "string" || !config.id) return null;
        var id = sanitizePanelId(config.id);
        if (!id) return null;
        if (!getPanel(id)) return create(Object.assign({}, config, { id: id }));
        applyScopeAndDomain(id);
        return id;
      },
      update: function (id, patch) {
        var panel = getPanel(id);
        if (!panel || !patch || typeof patch !== "object") return false;
        var merged = {};
        for (var k in panel) merged[k] = panel[k];
        for (var k2 in patch) merged[k2] = patch[k2];
        merged.id = panel.id;
        var next = sanitizePanelConfig(merged);
        if (!next) return false;
        var changed = !panelStateEquals(panel, next);
        if (changed) { bucket[panel.id] = next; markChanged(); }
        if (patch.hasOwnProperty("scope") || patch.hasOwnProperty("domain")) {
          applyScopeAndDomain(panel.id, patch.scope, patch.domain);
        }
        if (patch.controls || hasInlineProps(patch)) {
          registerInlineHandlers(panel.id, patch);
        }
        return true;
      },
      "delete": function (id) {
        if (!getPanel(id)) return false;
        delete bucket[id]; delete predicates[id]; delete displayed[id]; delete inlineHandlers[id]; delete creationConfigs[id];
        markChanged();
        return true;
      },
      show: function (id) {
        var panel = getPanel(id);
        if (!panel || panel.visible === true) return !!panel;
        panel.visible = true;
        markChanged();
        applyScopeAndDomain(id);
        return true;
      },
      hide: function (id) {
        var panel = getPanel(id);
        if (!panel || panel.visible === false) return !!panel;
        panel.visible = false;
        markChanged();
        return true;
      },
      setValue: function (panelId, controlId, value) {
        var panel = getPanel(panelId);
        if (!panel || typeof controlId !== "string") return false;
        var control = findControl(panel, controlId);
        if (!control || control.type === "button" || control.type === "text" || control.type === "timer" || control.type === "html") return false;
        var next = sanitizePanelValue(control.type, value, control);
        if (JSON.stringify(control.value) === JSON.stringify(next)) return true;
        control.value = next;
        markChanged();
        return true;
      },
      updateControl: function (panelId, controlId, patch) {
        var panel = getPanel(panelId);
        var control = findControl(panel, controlId);
        if (!control || !patch || typeof patch !== "object") return false;
        var merged = {};
        for (var ck in control) merged[ck] = control[ck];
        for (var pk in patch) merged[pk] = patch[pk];
        merged.id = control.id;
        var next = sanitizePanelControl(merged, 0);
        if (!next) return false;
        if (panelStateEquals(control, next)) return true;
        for (var dk in control) delete control[dk];
        for (var nk in next) control[nk] = next[nk];
        markChanged();
        return true;
      },
      disable: function (pid, cid) { return this.updateControl(pid, cid, { disabled: true }); },
      enable: function (pid, cid) { return this.updateControl(pid, cid, { disabled: false }); },
      setOptions: function (pid, cid, opts) {
        var panel = getPanel(pid);
        var control = findControl(panel, cid);
        if (!control || (control.type !== "select" && control.type !== "radio")) return false;
        return this.updateControl(pid, cid, { options: opts });
      },
      setText: function (pid, cid, text) {
        var panel = getPanel(pid);
        var control = findControl(panel, cid);
        if (!control) return false;
        if (control.type === "button") return this.updateControl(pid, cid, { label: text });
        if (control.type === "text" || control.type === "section") return this.updateControl(pid, cid, { text: text });
        return this.updateControl(pid, cid, { label: text });
      },
      setTheme: function (pid, theme) {
        var panel = getPanel(pid);
        if (!panel) return false;
        var next = sanitizePanelTheme(theme);
        if (panelStateEquals(panel.theme, next)) return true;
        panel.theme = next;
        markChanged();
        return true;
      },
      setTitle: function (pid, title) {
        var panel = getPanel(pid);
        if (!panel) return false;
        var next = truncateText(title || "", 240);
        if (panel.title === next) return true;
        panel.title = next;
        markChanged();
        return true;
      },
      setDescription: function (pid, desc) {
        var panel = getPanel(pid);
        if (!panel) return false;
        var next = truncateText(desc || "", 1000);
        if (panel.description === next) return true;
        panel.description = next;
        markChanged();
        return true;
      },
      getValue: function (pid, cid) {
        var panel = getPanel(pid);
        var control = findControl(panel, cid);
        try { return control ? JSON.parse(JSON.stringify(control.value)) : undefined; } catch (e) { return undefined; }
      },
      getValues: function (pid) {
        try { return JSON.parse(JSON.stringify(getValues(getPanel(pid)))); } catch (e) { return {}; }
      },
      getState: function (id) {
        var panel = getPanel(id);
        return panel ? hydrateTimerControls(clonePanelForSnapshot(panel)) : null;
      },
      list: function () {
        return Object.keys(bucket).map(function (id) {
          return hydrateTimerControls(clonePanelForSnapshot(bucket[id]));
        }).filter(Boolean);
      },
      notice: function (config) {
        config = config || {};
        var controls = [];
        if (config.message || config.text) controls.push({ id: "message", type: "text", text: config.message || config.text });
        if (Array.isArray(config.controls)) controls = controls.concat(config.controls);
        var merged = { position: "bottom-right", layout: "compact", role: "status" };
        for (var k in config) merged[k] = config[k];
        merged.controls = controls;
        return create(merged);
      },
      confirm: function (config) {
        config = config || {};
        var confirmText = truncateText(config.confirmText || "Confirm", 120);
        var cancelText = truncateText(config.cancelText || "Cancel", 120);
        var controls = [];
        if (config.message || config.text) controls.push({ id: "message", type: "text", text: config.message || config.text });
        if (Array.isArray(config.controls)) controls = controls.concat(config.controls);
        controls.push({ id: config.confirmId || "confirm", type: "button", label: confirmText, action: "submit", priority: 1 });
        controls.push({ id: config.cancelId || "cancel", type: "button", label: cancelText, action: "cancel" });
        var merged = { position: "center", layout: "compact", role: "dialog" };
        for (var k in config) merged[k] = config[k];
        merged.controls = controls;
        return create(merged);
      },
      checklist: function (config) {
        config = config || {};
        var items = Array.isArray(config.items) ? config.items : [];
        var controls = items.map(function (item, i) {
          if (item && typeof item === "object") {
            return { type: "checkbox", id: item.id || ("item-" + (i + 1)), label: item.label || item.text || item.id, value: item.value === true || item.checked === true };
          }
          return { type: "checkbox", id: "item-" + (i + 1), label: item, value: false };
        });
        if (Array.isArray(config.controls)) controls = controls.concat(config.controls);
        var merged = { layout: "compact" };
        for (var k in config) merged[k] = config[k];
        merged.controls = controls;
        return create(merged);
      },
      form: function (config) {
        config = config || {};
        var fields = Array.isArray(config.fields) ? config.fields : [];
        var controls = fields.concat(Array.isArray(config.controls) ? config.controls : []);
        var merged = { layout: config.layout || "form", role: "form" };
        for (var k in config) merged[k] = config[k];
        merged.controls = controls;
        return create(merged);
      },
      __cb_applyPanelEvent: function (data) {
        if (!data || typeof data !== "object") return false;
        var panelId = typeof data.panelId === "string" ? data.panelId : "";
        var panel = getPanel(panelId);
        if (!panel) return false;
        var changed = false;
        if (data.eventName === "close" && panel.visible !== false) {
          panel.visible = false;
          changed = true;
        }
        var values = data.values && typeof data.values === "object" ? data.values : null;
        if (values) {
          var applyValues = function (controls) {
            for (var i = 0; i < (controls || []).length; i++) {
              var c = controls[i];
              if (c.type === "section") { applyValues(c.controls); continue; }
              if (c.type === "button" || c.type === "text" || c.type === "timer" || c.type === "html") continue;
              if (!values.hasOwnProperty(c.id)) continue;
              var nv = sanitizePanelValue(c.type, values[c.id], c);
              if (JSON.stringify(c.value) !== JSON.stringify(nv)) { c.value = nv; changed = true; }
            }
          };
          applyValues(panel.controls);
        } else if (typeof data.controlId === "string") {
          var control = findControl(panel, data.controlId);
          if (control && control.type !== "button" && control.type !== "text" && control.type !== "timer") {
            var nv2 = sanitizePanelValue(control.type, data.value, control);
            if (JSON.stringify(control.value) !== JSON.stringify(nv2)) { control.value = nv2; changed = true; }
          }
        }
        if (changed) markChanged();
        var eventName = data.eventName || "change";
        var controlId = data.controlId || null;
        invokeInlineHandlers(panelId, controlId, eventName, {
          panelId: panelId, controlId: controlId, eventName: eventName,
          value: data.value, values: data.values
        });
        return changed;
      },
      __cb_getDisplayedPanelSnapshots: function (appId) {
        var out = [];
        for (var id in bucket) {
          if (!displayed[id]) continue;
          var panel = getPanel(id);
          var snap = panel ? clonePanelForSnapshot(panel) : null;
          if (snap) {
            hydrateTimerControls(snap);
            snap.groupId = groupId;
            snap.values = getValues(panel);
            out.push(snap);
          }
        }
        out.sort(function (a, b) {
          var pa = Number(a.priority) || 0, pb = Number(b.priority) || 0;
          if (pb !== pa) return pb - pa;
          return String(a.id || "").localeCompare(String(b.id || ""));
        });
        return out;
      },
      __cb_refreshDisplayedPanels: function (appId) {
        for (var id in bucket) {
          var panel = getPanel(id);
          delete displayed[id];
          if (!panel || panel.visible === false) continue;
          var slot = predicates[id] || {};
          var pred = typeof slot.domain === "function" ? slot.domain : slot.scope;
          if (typeof pred !== "function" || safePredicate(pred, appId)) {
            displayed[id] = true;
          }
        }
      },
      __cb_hasChanged: function () { return !!panelChangedByGroup[groupId]; },
      __cb_resetChanged: function () { panelChangedByGroup[groupId] = false; }
    };
  }

  // ------------------------------------------------- unsupported (browser) helpers

  function unsupportedHelper(name, logUnsupported) {
    return new Proxy({}, {
      get: function () {
        return function () { logUnsupported(name); return undefined; };
      }
    });
  }

  // ------------------------------------------------------------------ dispatch

  function makeContext(rawEvent) {
    var decisions = [];
    var intents = [];
    var gid = rawEvent.groupID;
    activeDecisionsByGroup[gid] = decisions;
    activeIntentsByGroup[gid] = intents;
    if (!logSeenByGroup[gid]) logSeenByGroup[gid] = {};
    var logSeen = logSeenByGroup[gid];

    function pushDecision(action, reason, shieldMessage, overlay, metadata, targetIDs) {
      var sink = activeDecisionsByGroup[gid] || decisions;
      if (action === "log" && sink.filter(function (d) { return d.action === "log"; }).length >= MAX_LOGS_PER_DISPATCH) return;
      sink.push({
        action: action,
        groupID: gid,
        targetIDs: targetIDs || (rawEvent.target && rawEvent.target.id ? [rawEvent.target.id] : []),
        reason: String(reason || ""),
        shieldMessage: String(shieldMessage || ""),
        overlayStatus: overlay || null,
        metadata: metadata || {}
      });
    }

    function pushIntent(intent) {
      var sink = activeIntentsByGroup[gid] || intents;
      if (sink.length >= MAX_INTENTS_PER_DISPATCH) return;
      sink.push(intent);
    }

    function logUnsupported(name) {
      var key = "unsupported:" + name;
      if (logSeen[key]) return;
      logSeen[key] = true;
      pushDecision("log", "helpers." + name + " is not available in native apps (browser-only).", "", null, { level: "warn", surface: "popup" }, []);
    }

    function logDecision(level, surface, args) {
      var msg = Array.prototype.map.call(args, function (a) { return typeof a === "string" ? a : JSON.stringify(a); }).join(" ");
      pushDecision("log", msg, "", null, { level: level, surface: surface }, []);
    }

    function logHelper() {
      return {
        log: function () { logDecision("log", "all", arguments); },
        warn: function () { logDecision("warn", "all", arguments); },
        error: function () { logDecision("error", "all", arguments); },
        logScreen: function () { logDecision("log", "screen", arguments); },
        warnScreen: function () { logDecision("warn", "screen", arguments); },
        errorScreen: function () { logDecision("error", "screen", arguments); },
        logPopup: function () { logDecision("log", "popup", arguments); },
        warnPopup: function () { logDecision("warn", "popup", arguments); },
        errorPopup: function () { logDecision("error", "popup", arguments); }
      };
    }

    var groupId = rawEvent.groupID;
    var ms = nowMs(rawEvent);
    var date = new Date(ms);

    var win = windowHelper(rawEvent, pushIntent);

    var helpers = {
      now: rawEvent.now,
      currentUrl: rawEvent.url || "",
      groupId: groupId,
      log: function () { logDecision("log", "all", arguments); },
      warn: function () { logDecision("warn", "all", arguments); },
      error: function () { logDecision("error", "all", arguments); },
      logScreen: function () { logDecision("log", "screen", arguments); },
      warnScreen: function () { logDecision("warn", "screen", arguments); },
      errorScreen: function () { logDecision("error", "screen", arguments); },
      logPopup: function () { logDecision("log", "popup", arguments); },
      warnPopup: function () { logDecision("warn", "popup", arguments); },
      errorPopup: function () { logDecision("error", "popup", arguments); },
      getLogHelper: logHelper,
      getDomainHelper: domainHelper,
      getDomainUtility: domainHelper,
      getTimerHelper: function () { return timerHelper(groupId); },
      getPersistenceHelper: function () { return persistenceHelper(groupId); },
      getStorageHelper: function () { return storageHelper(groupId); },
      getWindowHelper: function () { return win; },
      getRedirectionHelper: function () { return unsupportedHelper("getRedirectionHelper", logUnsupported); },
      getPlatformHelper: function () { return platformHelper(logUnsupported); },
      platform: function (name) { return platformAccessor(name, logUnsupported); },
      getDOMHelper: function () { return unsupportedHelper("getDOMHelper", logUnsupported); },
      getNavigationHelper: function () { return unsupportedHelper("getNavigationHelper", logUnsupported); },
      getTabHelper: function () { return unsupportedHelper("getTabHelper", logUnsupported); },
      getPanelHelper: function () { return panelHelper(groupId, function () { return timersByGroup[groupId] || {}; }); },
      getLocalFolderHelper: function () { return localFolderHelper(groupId, pushIntent); },
      overlay: {
        show: function (status) {
          var safe = status || {};
          pushDecision("showStatus",
            String(safe.message || ""),
            "",
            {
              title: String(safe.title || "Blocker Status"),
              message: String(safe.message || ""),
              timerGroupID: String(safe.timerId || groupId),
              expiresAt: null
            },
            {},
            rawEvent.target && rawEvent.target.id ? [rawEvent.target.id] : []);
        }
      }
    };
    var BROWSER_ONLY_HELPERS = {
      getDOMHelper: true, getNavigationHelper: true, getRedirectionHelper: true, getTabHelper: true
    };
    // Unknown helper getters resolve to inert helpers instead of throwing.
    var helpersProxy = new Proxy(helpers, {
      get: function (target, prop) {
        if (prop in target) return target[prop];
        if (typeof prop === "string" && prop.indexOf("get") === 0 && prop.indexOf("Helper") > 0) {
          if (BROWSER_ONLY_HELPERS[prop]) {
            return function () { return unsupportedHelper(prop, logUnsupported); };
          }
          return function () { return unsupportedHelper(prop, function (name) {
            var key = "notfound:" + name;
            if (logSeen[key]) return;
            logSeen[key] = true;
            pushDecision("log", "helpers." + name + " does not exist.", "", null, { level: "warn", surface: "popup" }, []);
          }); };
        }
        return target[prop];
      }
    });

    return {
      decisions: decisions,
      intents: intents,
      helpers: helpersProxy,
      logUnsupported: logUnsupported,
      pushDecision: pushDecision,
      date: date
    };
  }

  function makeEvent(rawEvent, ctx, depth) {
    var date = ctx.date;
    var ev = {
      type: rawEvent.type,
      groupId: rawEvent.groupID,
      groupID: rawEvent.groupID,
      groupName: (rawEvent.data && rawEvent.data.groupName) || "",
      tabId: rawEvent.data && rawEvent.data.tabId ? rawEvent.data.tabId : null,
      pageId: rawEvent.data && rawEvent.data.pageId ? rawEvent.data.pageId : null,
      url: rawEvent.url || "",
      hostname: rawEvent.hostname || hostnameOf(rawEvent.url || ""),
      time: {
        now: rawEvent.now,
        month: date.getMonth() + 1,
        dayOfMonth: date.getDate(),
        dayName: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][date.getDay()],
        hour: date.getHours(),
        minute: date.getMinutes()
      },
      data: rawEvent.data || {},
      target: rawEvent.target || null,
      __result: 0,
      __shieldMessage: "",
      __reason: "",
      __stop: false
    };
    ev.stopPropagation = function () { ev.__stop = true; };
    ev.setResult = function (r) {
      // A string result used to mean "redirect"; redirection is gone, so any
      // truthy/negative result simply blocks.
      if (typeof r === "string") { ev.__result = -1; }
      else { ev.__result = Number(r) || 0; }
    };
    ev.getResult = function () { return ev.__result; };
    // Redirection removed (no URL target for app blocking); kept as no-ops.
    ev.setRedirectLink = function () {};
    ev.getRedirectLink = function () { return null; };
    // Resolve the focused app's identity from event context.
    var focusedAppId = rawEvent.data && rawEvent.data.isBrowser === "true"
      ? ""
      : (rawEvent.data && rawEvent.data.appId) || "";
    function pushIntent(intent) { ctx.intents.push(intent); }

    ev.close = function (id) {
      if (typeof id === "string" && id) {
        pushIntent({ kind: "window", action: "close", target: id });
      } else if (focusedAppId) {
        pushIntent({ kind: "window", action: "close", target: focusedAppId });
      }
    };

    ev.block = function (id) {
      var appId = typeof id === "string" && id ? id : focusedAppId;
      if (!appId) return;
      pushIntent({ kind: "window", action: "blockApp", target: appId });
    };

    ev.unblock = function (id) {
      var appId = typeof id === "string" && id ? id : focusedAppId;
      if (!appId) return;
      pushIntent({ kind: "window", action: "unblockApp", target: appId });
    };

    ev.open = function (id) {
      if (typeof id !== "string" || !id) return;
      pushIntent({ kind: "window", action: "openApp", target: id });
    };

    ev.allow = function (reason) { ev.__result = 1; ev.__reason = String(reason || ""); };
    ev.setShieldMessage = function (m) { ev.__shieldMessage = String(m || ""); };

    if (rawEvent.type === "panelEvent" && rawEvent.data && typeof rawEvent.data === "object") {
      ev.panelId = rawEvent.data.panelId || "";
      ev.controlId = rawEvent.data.controlId || "";
      ev.eventName = rawEvent.data.eventName || "";
      ev.value = rawEvent.data.value;
      var parsedValues = rawEvent.data.values;
      if (!parsedValues && typeof rawEvent.data.valuesJSON === "string") {
        try { parsedValues = JSON.parse(rawEvent.data.valuesJSON); } catch (e) { parsedValues = null; }
      }
      ev.values = parsedValues && typeof parsedValues === "object" ? parsedValues : {};
      ev.key = rawEvent.data.key || "";
      ev.code = rawEvent.data.code || "";
      ev.keyInfo = rawEvent.data.keyInfo && typeof rawEvent.data.keyInfo === "object" ? rawEvent.data.keyInfo : null;
    }
    if (rawEvent.type === "localFileEvent" && rawEvent.data && typeof rawEvent.data === "object") {
      var localData = rawEvent.data;
      ev.eventName = localData.eventName || "";
      ev.action = localData.action || ev.eventName || "";
      ev.path = localData.path || "";
      ev.directoryPath = localData.directoryPath || "";
      ev.requestId = localData.requestId || "";
      ev.ok = localData.ok === true || localData.ok === "true";
      ev.text = typeof localData.text === "string" ? localData.text : "";
      ev.value = localData.value;
      if (typeof localData.valueJSON === "string") {
        try { ev.value = JSON.parse(localData.valueJSON); } catch (e) { ev.value = undefined; }
      }
      var entries = localData.entries;
      if (typeof localData.entriesJSON === "string") {
        try { entries = JSON.parse(localData.entriesJSON); } catch (e2) { entries = []; }
      } else if (typeof entries === "string") {
        try { entries = JSON.parse(entries); } catch (e3) { entries = []; }
      }
      ev.entries = Array.isArray(entries) ? entries : [];
      ev.exists = localData.exists === true || localData.exists === "true";
      ev.bytes = isFinite(Number(localData.bytes)) ? Number(localData.bytes) : 0;
      ev.error = typeof localData.error === "string" ? localData.error : "";
    }
    ev.post = function (type, data, options) {
      if (depth >= MAX_POST_DEPTH) return;
      var sub = { type: String(type), groupID: rawEvent.groupID, target: rawEvent.target, now: rawEvent.now, url: rawEvent.url, hostname: rawEvent.hostname, data: data || {} };
      var subResult = runHandlers(sub, ctx, depth + 1);
      if (subResult === -1) ev.__result = -1;
    };
    return ev;
  }

  function runHandlers(rawEvent, ctx, depth) {
    if (rawEvent.type === "panelEvent" && rawEvent.groupID) {
      var panelBk = panelsByGroup[rawEvent.groupID];
      if (panelBk && Object.keys(panelBk).length > 0) {
        var ph = panelHelper(rawEvent.groupID, function () { return timersByGroup[rawEvent.groupID] || {}; });
        if (typeof ph.__cb_applyPanelEvent === "function") {
          var applyData = rawEvent.data || {};
          if (!applyData.values && typeof applyData.valuesJSON === "string") {
            try { applyData = JSON.parse(JSON.stringify(applyData)); applyData.values = JSON.parse(applyData.valuesJSON); } catch (e) {}
          }
          try { ph.__cb_applyPanelEvent(applyData); } catch (e) {}
        }
      }
    }
    var snapshot = (handlersByGroup[rawEvent.groupID] || []).slice();
    var ev = makeEvent(rawEvent, ctx, depth);
    var ms = nowMs(rawEvent);
    for (var i = 0; i < snapshot.length; i++) {
      var entry = snapshot[i];
      if (entry.type !== rawEvent.type) continue;
      if (entry.intervalMs > 0 && (ms - entry.lastRun) < entry.intervalMs) continue;
      entry.lastRun = ms;
      try {
        entry.handler(ev, ctx.helpers);
      } catch (e) {
        ctx.pushDecision("log", "Rule handler error: " + (e && e.message ? e.message : e), "", null, { level: "error", surface: "popup" }, []);
      }
      if (ev.__stop) break;
    }
    // Finalize this event's contribution.
    if (ev.__result === -1) {
      var reason = ev.__reason || "Blocked by custom rule.";
      var meta = {};
      ctx.pushDecision(
        "shield",
        reason,
        ev.__shieldMessage || reason,
        { title: "Blocked", message: reason, timerGroupID: rawEvent.groupID, expiresAt: null },
        meta
      );
    } else if (ev.__result === 1) {
      ctx.pushDecision("allow", ev.__reason || "", "", null, {});
    }
    return ev.__result;
  }

  return {
    load: function (groupId, source) {
      handlersByGroup[groupId] = [];
      var factory = Function('"use strict"; return (' + source + "\n);");
      var rule = factory();
      if (typeof rule !== "function") throw new Error("Custom rule must evaluate to a function.");
      var ctx = makeContext({ groupID: groupId, type: "_register", now: new Date().toISOString(), data: {} });
      rule(eventRegistry(groupId), ctx.helpers);
      return JSON.stringify({ handlers: countHandlers(groupId), decisions: ctx.decisions });
    },
    unload: function (groupId) {
      delete handlersByGroup[groupId];
      delete persistenceByGroup[groupId];
      delete timersByGroup[groupId];
      delete panelsByGroup[groupId];
      delete panelDisplayedByGroup[groupId];
      delete panelPredicatesByGroup[groupId];
      delete panelInlineHandlersByGroup[groupId];
      delete panelChangedByGroup[groupId];
      delete panelCreationByGroup[groupId];
      delete previouslyExpired[groupId];
      delete dynamicAppBlocklistByGroup[groupId];
      delete logSeenByGroup[groupId];
      delete activeDecisionsByGroup[groupId];
      delete activeIntentsByGroup[groupId];
    },
    dispatch: function (rawEvent) {
      var ctx = makeContext(rawEvent);
      var bucket = timersByGroup[rawEvent.groupID];
      // Snapshot which timers are already expired BEFORE auto-tick and
      // handlers, so timerEnded only fires for timers that transition
      // to expired during this dispatch (either via auto-tick or handler).
      var preExpired = {};
      if (bucket) {
        for (var k in bucket) {
          var bt = bucket[k];
          if (bt && bt.direction === "backward" && bt.currentMs <= 0) preExpired[k] = true;
        }
      }
      // Auto-tick backward timers by elapsed time on tickEvent.
      // Scoped timers only tick when the focused app matches the scope predicate.
      if (bucket && rawEvent.type === "tickEvent") {
        var elapsed = Number(rawEvent.data && rawEvent.data.intervalMs) || 0;
        var tickFocusedApp = (rawEvent.data && rawEvent.data.appId) || "";
        if (elapsed > 0) {
          for (var atid in bucket) {
            var at = bucket[atid];
            if (at && at.direction === "backward" && !at.isPaused && at.currentMs > 0) {
              var scopeMatch = true;
              if (at.scope != null) {
                if (typeof at.scope === "function") {
                  try { scopeMatch = !!at.scope(tickFocusedApp); } catch (e) { scopeMatch = false; }
                } else if (typeof at.scope === "string") {
                  scopeMatch = at.scope === tickFocusedApp;
                }
              }
              if (scopeMatch) {
                at.currentMs = Math.max(0, at.currentMs - elapsed);
              }
            }
          }
        }
      }
      runHandlers(rawEvent, ctx, 0);
      // Auto-fire timerEnded for backward timers that crossed zero during
      // this dispatch (not already expired before it started).
      bucket = timersByGroup[rawEvent.groupID];
      if (bucket && rawEvent.type !== "timerEnded") {
        var prev = previouslyExpired[rawEvent.groupID] || {};
        var nowExpired = {};
        for (var tid in bucket) {
          var t = bucket[tid];
          if (t && t.direction === "backward" && t.currentMs <= 0) {
            nowExpired[tid] = true;
            if (!prev[tid] && !preExpired[tid]) {
              var synthEvent = {
                type: "timerEnded",
                groupID: rawEvent.groupID,
                target: rawEvent.target,
                now: rawEvent.now,
                url: rawEvent.url,
                hostname: rawEvent.hostname,
                data: { timerId: tid, displayName: t.displayName, direction: t.direction, currentMs: t.currentMs }
              };
              runHandlers(synthEvent, ctx, 0);
            }
          }
        }
        previouslyExpired[rawEvent.groupID] = nowExpired;
      }
      // Collect visible timers filtered by scope vs. the focused app.
      var visibleTimers = [];
      if (bucket) {
        var focusedApp = (rawEvent.data && rawEvent.data.appId) || "";
        for (var vtid in bucket) {
          var vt = bucket[vtid];
          if (!vt) continue;
          var show = false;
          if (vt.scope == null) {
            show = true;
          } else if (typeof vt.scope === "function") {
            try { show = !!vt.scope(focusedApp); } catch (e) { show = false; }
          } else if (typeof vt.scope === "string") {
            show = vt.scope === focusedApp;
          }
          if (show) {
            visibleTimers.push({
              id: vt.id, groupId: rawEvent.groupID,
              displayName: vt.displayName, direction: vt.direction,
              currentMs: vt.currentMs, isPaused: vt.isPaused
            });
          }
        }
      }
      // Always report this group's CURRENT panel snapshots. The native
      // overlay is an authoritative mirror of JS panel state, so it can
      // remove panels that are gone (e.g. a disabled group reports none).
      // In-progress user input is preserved on the native side: the overlay
      // dedupes identical snapshots and the controls hold edits in local
      // view state, so re-emitting unchanged panels every tick is safe.
      var visiblePanels = [];
      var panelBucket = panelsByGroup[rawEvent.groupID];
      if (panelBucket && Object.keys(panelBucket).length > 0) {
        var ph = panelHelper(rawEvent.groupID, function () { return timersByGroup[rawEvent.groupID] || {}; });
        var focusApp = (rawEvent.data && rawEvent.data.appId) || "";
        ph.__cb_refreshDisplayedPanels(focusApp);
        visiblePanels = ph.__cb_getDisplayedPanelSnapshots(focusApp);
        ph.__cb_resetChanged();
      }
      return JSON.stringify({ decisions: ctx.decisions, intents: ctx.intents, timers: visibleTimers, panels: visiblePanels });
    },
    handlerCount: function (groupId) { return countHandlers(groupId); },
    getDynamicBlocklist: function (groupId) {
      if (groupId) return Object.keys(dynamicAppBlocklistByGroup[groupId] || {});
      var all = {};
      for (var gid in dynamicAppBlocklistByGroup) {
        var bl = dynamicAppBlocklistByGroup[gid];
        for (var p in bl) all[p] = true;
      }
      return Object.keys(all);
    }
  };

  function countHandlers(groupId) {
    return (handlersByGroup[groupId] || []).length;
  }
})();
