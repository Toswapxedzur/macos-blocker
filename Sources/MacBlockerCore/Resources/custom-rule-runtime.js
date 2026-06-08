/*
 * macosBlocker custom-rule runtime (iOS-portable subset).
 *
 * Runs inside JavaScriptCore (no DOM, no Web APIs, no chrome.*). It reimplements
 * the customBlocker custom-rule contract for the parts that make sense when the
 * blocker controls native apps via Screen Time:
 *
 *   - the full event registry (11 built-in types + typed registrars, priorities,
 *     intervalMs throttling, post(), unregister, counts)
 *   - the ev object (fields + preventDefault/stopPropagation/setResult/getResult/
 *     post, plus block/allow/setShieldMessage)
 *   - helpers: getLogHelper, getDomainHelper/getDomainUtility, getTimerHelper,
 *     getPersistenceHelper, getStorageHelper,
 *     getPlatformHelper (URL classifiers)
 *
 * Browser-only helpers (getDOMHelper, getNavigationHelper, getTabHelper,
 * getLocalFolderHelper, getPanelHelper) are present but inert: every call is a
 * no-op that emits ONE log decision noting it is unsupported on iOS, so existing
 * rules/templates load and run instead of throwing.
 *
 * dispatch() returns a JSON array of PolicyDecision objects for Swift.
 */
var MacBlockerRuntime = (function () {
  var MAX_POST_DEPTH = 16;

  var handlersByGroup = {};      // groupId -> [entry]
  var persistenceByGroup = {};   // groupId -> { key: jsonString }
  var timersByGroup = {};        // groupId -> { timerId: timer }
  var previouslyExpired = {};    // groupId -> { timerId: true } for timerEnded dedup

  var TYPED = {
    TickEvent: "tickEvent",
    OpenWebEvent: "openWebEvent",
    CloseWebEvent: "closeWebEvent",
    SwitchWebEvent: "switchWebEvent",
    SwitchDomainEvent: "switchDomainEvent",
    WebChangedEvent: "webChangedEvent",
    TimerEnded: "timerEnded",
    SnoozePress: "snoozePress",
    PanelEvent: "panelEvent",
    LocalFileEvent: "localFileEvent",
    PageHeartbeatEvent: "pageHeartbeatEvent",
    // macOS app lifecycle events (notification-driven)
    OpenAppEvent: "openAppEvent",
    CloseAppEvent: "closeAppEvent",
    FocusEvent: "focusEvent",
    UnfocusEvent: "unfocusEvent",
    MinimizeEvent: "minimizeEvent",
    UnminimizeEvent: "unminimizeEvent",
    SwitchAppEvent: "switchAppEvent",
    AppChangedEvent: "appChangedEvent"
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
    function make(init) {
      return {
        id: String(init.id),
        displayName: String(init.displayName || init.id),
        direction: init.direction === "forward" ? "forward" : "backward",
        currentMs: Number(init.currentMs) || 0,
        isPaused: false,
        scope: init.scope || null,
        domain: init.domain || null
      };
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
      setCurrentMs: function (id, ms) { if (store[id]) store[id].currentMs = Number(ms) || 0; },
      addMs: function (id, delta) { if (store[id]) store[id].currentMs += Number(delta) || 0; },
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
        return { id: t.id, displayName: t.displayName, direction: t.direction, isPaused: t.isPaused, currentMs: t.currentMs, isExpired: t.direction === "backward" ? t.currentMs <= 0 : false };
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
      clear: function () { persistenceByGroup[groupId] = {}; },
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
        var p = pathnameOf(u);
        if (platform === "youtube") return p.indexOf("/shorts/") === 0;
        if (platform === "instagram") return p.indexOf("/reels/") === 0 || p.indexOf("/reel/") === 0;
        if (platform === "tiktok") return /\/video\//.test(p) || p.indexOf("/foryou") === 0;
        return false;
      },
      isVideoUrl: function (u) {
        var p = pathnameOf(u);
        if (platform === "youtube") return p.indexOf("/watch") === 0 || p.indexOf("/shorts/") === 0;
        return /\/video\//.test(p) || /\/watch/.test(p);
      },
      isPostUrl: function (u) {
        var p = pathnameOf(u);
        return /\/p\//.test(p) || /\/post/.test(p) || /\/status\//.test(p);
      },
      isHomePage: function (u) {
        var p = pathnameOf(u);
        return p === "/" || p === "";
      },
      extractAuthor: function (u) {
        var p = pathnameOf(u);
        var at = p.match(/\/@([^\/?#]+)/);
        if (at) return at[1];
        var ch = p.match(/\/channel\/([^\/?#]+)/);
        if (ch) return ch[1];
        return null;
      },
      extractVideoId: function (u) {
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

  var PLATFORM_DOM_METHODS = [
    "hideShorts", "showShorts", "hideVideos", "showVideos", "hidePosts", "showPosts",
    "hideReels", "showReels", "hideShortButton", "showShortButton", "hideHomePage",
    "showHomePage", "hideComments", "showComments", "filterComments", "hideLive",
    "showLive", "filterLive", "hideClips", "showClips", "hideStreams", "showStreams",
    "isCurrentChannelSubscribed", "isChannelSubscribed", "isCurrentChannelVerified",
    "isLiveNow", "isItemLive", "isAlgorithmicRecommendation", "isSponsored",
    "setShortsTimer", "setVideosTimer", "setPostsTimer", "setReelsTimer",
    "setClipsTimer", "setStreamsTimer"
  ];

  function platformApi(name, logUnsupported) {
    var api = urlClassifiers(name);
    PLATFORM_DOM_METHODS.forEach(function (m) {
      api[m] = function () { logUnsupported("platform." + name + "." + m); return undefined; };
    });
    return api;
  }

  function platformHelper(logUnsupported) {
    var helper = { listMethods: function () { return PLATFORM_DOM_METHODS.slice(); }, hasMethod: function (_p, m) { return PLATFORM_DOM_METHODS.indexOf(m) >= 0; } };
    ["youtube", "tiktok", "instagram", "facebook", "twitch"].forEach(function (name) {
      helper[name] = function () { return platformApi(name, logUnsupported); };
    });
    return helper;
  }

  // ------------------------------------------------- tab helper

  function tabHelper(rawEvent, pushIntent) {
    return {
      getAllTabs: function () {
        if (typeof __nativeGetAllTabs === "function") {
          try {
            var json = __nativeGetAllTabs();
            return typeof json === "string" ? JSON.parse(json) : json;
          } catch (e) { return []; }
        }
        return [];
      },
      closeTab: function (tab) {
        if (!tab) return;
        pushIntent({
          kind: "window", action: "closeTab",
          browserBundleID: tab.browserBundleID || "",
          windowIndex: Number(tab.windowIndex) || 0,
          tabIndex: Number(tab.tabIndex) || 0
        });
      },
      closeTabsByPattern: function (pattern) {
        var p = String(pattern || "").trim().toLowerCase();
        if (!p) return;
        pushIntent({ kind: "window", action: "closeTabsByPattern", pattern: p });
      },
      currentTab: function () {
        return {
          url: rawEvent.url || "",
          title: rawEvent.data && rawEvent.data.tabTitle || "",
          browserBundleID: rawEvent.data && rawEvent.data.appId || "",
          windowIndex: 1,
          tabIndex: 1
        };
      }
    };
  }

  // ------------------------------------------------- dynamic site blocklist

  var dynamicBlocklist = {};  // pattern -> true

  function windowHelper(rawEvent, pushIntent, logDecisionFn) {
    return {
      current: function () {
        return {
          id: rawEvent.data && rawEvent.data.appId || rawEvent.hostname || "",
          name: rawEvent.data && rawEvent.data.appName || "",
          url: rawEvent.url || "",
          hostname: rawEvent.hostname || hostnameOf(rawEvent.url || ""),
          title: rawEvent.data && rawEvent.data.tabTitle || "",
          isBrowser: rawEvent.data && rawEvent.data.isBrowser === "true"
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
      closeTab: function (tab) {
        if (tab && tab.browserBundleID && tab.windowIndex && tab.tabIndex) {
          pushIntent({ kind: "window", action: "closeTab",
            browserBundleID: tab.browserBundleID,
            windowIndex: Number(tab.windowIndex), tabIndex: Number(tab.tabIndex) });
        } else {
          pushIntent({ kind: "window", action: "closeTab" });
        }
      },
      block: function (pattern) {
        var p = String(pattern || "").trim().toLowerCase();
        if (!p) return;
        dynamicBlocklist[p] = true;
        pushIntent({ kind: "window", action: "blockSite", pattern: p });
      },
      unblock: function (pattern) {
        var p = String(pattern || "").trim().toLowerCase();
        delete dynamicBlocklist[p];
        pushIntent({ kind: "window", action: "unblockSite", pattern: p });
      },
      isBlocked: function (pattern) {
        var p = String(pattern || "").trim().toLowerCase();
        if (!p) return false;
        if (dynamicBlocklist[p]) return true;
        for (var key in dynamicBlocklist) {
          if (p === key) return true;
          var suffix = "." + key;
          if (p.length > key.length && p.indexOf(suffix) === p.length - suffix.length) return true;
        }
        return false;
      },
      getBlocked: function () {
        return Object.keys(dynamicBlocklist);
      }
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
    var unsupportedSeen = {};

    function pushDecision(action, reason, shieldMessage, overlay, metadata, targetIDs) {
      decisions.push({
        action: action,
        groupID: rawEvent.groupID,
        targetIDs: targetIDs || (rawEvent.target && rawEvent.target.id ? [rawEvent.target.id] : []),
        reason: String(reason || ""),
        shieldMessage: String(shieldMessage || ""),
        overlayStatus: overlay || null,
        metadata: metadata || {}
      });
    }

    function pushIntent(intent) {
      intents.push(intent);
    }

    function logUnsupported(name) {
      if (unsupportedSeen[name]) return;
      unsupportedSeen[name] = true;
      pushDecision("log", "helpers." + name + " is not available on iOS (browser-only).", "", null, { level: "warn", surface: "popup" }, []);
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

    var win = windowHelper(rawEvent, pushIntent, logDecision);

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
      getDOMHelper: function () { return unsupportedHelper("getDOMHelper", logUnsupported); },
      getNavigationHelper: function () { return unsupportedHelper("getNavigationHelper", logUnsupported); },
      getTabHelper: function () { return tabHelper(rawEvent, pushIntent); },
      getLocalFolderHelper: function () { return unsupportedHelper("getLocalFolderHelper", logUnsupported); }
    };
    // Unknown helper getters resolve to inert helpers instead of throwing.
    var helpersProxy = new Proxy(helpers, {
      get: function (target, prop) {
        if (prop in target) return target[prop];
        if (typeof prop === "string" && prop.indexOf("get") === 0 && prop.indexOf("Helper") > 0) {
          return function () { return unsupportedHelper(prop, logUnsupported); };
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
    ev.preventDefault = function () { ev.__prevented = true; };
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
    var focusedAppId = (rawEvent.data && rawEvent.data.appId) || "";
    var focusedIsBrowser = (rawEvent.data && rawEvent.data.isBrowser) === "true";
    var focusedHostname = ev.hostname || "";

    function pushIntent(intent) { ctx.intents.push(intent); }

    ev.close = function (id) {
      if (typeof id === "string" && id) {
        pushIntent({ kind: "window", action: "close", target: id });
        pushIntent({ kind: "window", action: "closeTabsByPattern", pattern: id });
      } else {
        if (focusedIsBrowser) {
          pushIntent({ kind: "window", action: "closeTab" });
        } else if (focusedAppId) {
          pushIntent({ kind: "window", action: "close", target: focusedAppId });
        }
      }
    };

    ev.block = function (id) {
      var pattern = typeof id === "string" && id ? id : (focusedIsBrowser ? focusedHostname : focusedAppId);
      if (!pattern) return;
      pushIntent({ kind: "window", action: "blockSite", pattern: pattern });
      pushIntent({ kind: "window", action: "blockApp", target: pattern });
    };

    ev.unblock = function (id) {
      var pattern = typeof id === "string" && id ? id : (focusedIsBrowser ? focusedHostname : focusedAppId);
      if (!pattern) return;
      pushIntent({ kind: "window", action: "unblockSite", pattern: pattern });
      pushIntent({ kind: "window", action: "unblockApp", target: pattern });
    };

    ev.open = function (id) {
      if (typeof id !== "string" || !id) return;
      pushIntent({ kind: "window", action: "openApp", target: id });
    };

    ev.allow = function (reason) { ev.__result = 1; ev.__reason = String(reason || ""); };
    ev.setShieldMessage = function (m) { ev.__shieldMessage = String(m || ""); };
    ev.post = function (type, data, options) {
      if (depth >= MAX_POST_DEPTH) return;
      var sub = { type: String(type), groupID: rawEvent.groupID, target: rawEvent.target, now: rawEvent.now, url: rawEvent.url, hostname: rawEvent.hostname, data: data || {} };
      var subResult = runHandlers(sub, ctx, depth + 1);
      if (subResult === -1) ev.__result = -1;
    };
    return ev;
  }

  function runHandlers(rawEvent, ctx, depth) {
    var list = handlersByGroup[rawEvent.groupID] || [];
    var ev = makeEvent(rawEvent, ctx, depth);
    var ms = nowMs(rawEvent);
    for (var i = 0; i < list.length; i++) {
      var entry = list[i];
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
      delete previouslyExpired[groupId];
    },
    dispatch: function (rawEvent) {
      var ctx = makeContext(rawEvent);
      runHandlers(rawEvent, ctx, 0);
      // Auto-fire timerEnded for backward timers that just crossed zero.
      var bucket = timersByGroup[rawEvent.groupID];
      if (bucket && rawEvent.type !== "timerEnded") {
        var prev = previouslyExpired[rawEvent.groupID] || {};
        var nowExpired = {};
        for (var tid in bucket) {
          var t = bucket[tid];
          if (t && t.direction === "backward" && t.currentMs <= 0) {
            nowExpired[tid] = true;
            if (!prev[tid]) {
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
      return JSON.stringify({ decisions: ctx.decisions, intents: ctx.intents });
    },
    handlerCount: function (groupId) { return countHandlers(groupId); },
    getDynamicBlocklist: function () { return Object.keys(dynamicBlocklist); }
  };

  function countHandlers(groupId) {
    return (handlersByGroup[groupId] || []).length;
  }
})();
