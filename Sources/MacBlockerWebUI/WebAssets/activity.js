/* Mac Vault's Activity scene (see ACTIVITY-LOG.md). A renderer only: Mac
 * Vault computes everything (ActivityDashboard) and pushes it with
 * window.activityApply(snapshot, icons). It lives in a shadow root beside the
 * Vault editor in the one document (scenes.js).
 */
"use strict";
(function () {
  // The scene's shadow root (Mac Vault's scenes.js): the page is built and
  // listened to inside it.
  var scope = window.VaultScenes.scope("activity");
  scope.getElementById("activity").innerHTML = [
    '<header class="vui-topbar">',
    '<nav class="vui-tabs" aria-label="Scene">',
    '<button type="button" class="vui-tab" data-scene="vault">Vault</button>',
    '<button type="button" class="vui-tab" data-scene="classifier">Classifier</button>',
    '<button type="button" class="vui-tab is-active" data-scene="activity">Activity</button>',
    "</nav>",
    '<div class="vui-topbar-links">',
    '<div class="vui-tabs" id="ranges">',
    '<button type="button" data-range="today" class="vui-tab is-active">Today</button>',
    '<button type="button" data-range="7d" class="vui-tab">7 days</button>',
    '<button type="button" data-range="30d" class="vui-tab">30 days</button>',
    "</div>",
    "</div>",
    "</header>",
    '<main><div class="page" id="page"><p class="empty">Loading…</p></div></main>'
  ].join("");
  var RETENTIONS = [[7, "7 days"], [30, "30 days"], [90, "90 days"], [0, "Forever"]];
  // What is recorded (each kind has its own switch under Recording).
  var KINDS = [
    { id: "appUsage", key: "app-usage", title: "Apps" },
    { id: "webVisit", key: "web-visit", title: "Websites" },
    { id: "contentWatched", key: "content-watched", title: "Watched" }
  ];
  // What is shown: apps and websites together in one ranked list, or the
  // videos watched.
  var VIEWS = [{ id: "usage", title: "Usage" }, { id: "watched", title: "Watched" }];
  var current = "usage";
  var snapshot = null;
  var icons = {};

  function send(msg) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.activity) {
        window.webkit.messageHandlers.activity.postMessage(msg);
      } else if (window.chrome && window.chrome.webview) {
        window.chrome.webview.postMessage(msg);
      }
    } catch (_) {}
  }

  function fmt(seconds) {
    var s = Math.round(seconds);
    if (s < 60) return s + "s";
    var m = Math.round(s / 60);
    if (m < 60) return m + "m";
    return Math.floor(m / 60) + "h " + (m % 60) + "m";
  }
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  // Every item on the page has its own colour index (Mac Vault numbers apps,
  // then sites, then watched videos). The first twelve are the base palette;
  // past it, golden-angle hues keep every further colour different.
  var PALETTE = ["#5b7fc7", "#e8914a", "#5fa86a", "#d9656a", "#6fb3ae", "#d9b945",
    "#a27bb0", "#e99aa6", "#9a7a64", "#8ccf7f", "#86b8c7", "#c97aa0"];
  function colorOf(i) {
    if (i >= 0 && i < PALETTE.length) return PALETTE[i];
    var n = i - PALETTE.length;
    return "hsl(" + ((n * 137.508 + 20) % 360).toFixed(1) + ", " + (n % 3 === 1 ? 45 : 58) + "%, " + (n % 2 ? 62 : 50) + "%)";
  }
  function paint(node, i) { node.style.background = colorOf(i); return node; }
  function textButton(label, onClick, cls) { var b = el("button", cls || null, label); b.type = "button"; b.addEventListener("click", onClick); return b; }

  function icon(key, label) {
    var box = el("span", "icon");
    if (icons[key]) { var img = el("img"); img.src = icons[key]; img.alt = ""; box.appendChild(img); }
    else box.textContent = ((label || key || "?").trim()[0] || "?").toUpperCase();
    return box;
  }

  // `seconds` null = a row shown by name only (a browser in Usage).
  function row(item, seconds, fraction, kind) {
    var line = el("div", "row");
    line.title = item.label || item.key;
    if (seconds !== null) line.title += " — " + fmt(seconds);
    line.appendChild(icon(item.key, item.label));
    var body = el("div", "row-body");
    var name = el("div", "row-name");
    name.appendChild(el("span", "row-label", item.label || item.key));
    if (kind) name.appendChild(el("span", "row-kind", kind));
    body.appendChild(name);
    if (seconds !== null) {
      var bar = el("div", "row-bar"), fill = paint(el("span"), item.colorIndex);
      fill.style.width = Math.max(1.5, fraction * 100) + "%";
      bar.appendChild(fill); body.appendChild(bar);
    }
    line.appendChild(body);
    line.appendChild(el("div", "row-time", seconds === null ? "" : fmt(seconds)));
    return line;
  }

  function rows(bars) {
    var wrap = el("div");
    if (!bars.length) { wrap.appendChild(el("p", "empty", "Nothing in this range.")); return wrap; }
    bars.slice(0, 20).forEach(function (b) { wrap.appendChild(row(b, b.seconds, b.fraction)); });
    return wrap;
  }

  // Apps and websites in one ranked list, each marked. A browser whose sites
  // are recorded is listed by name only (owner 2026-09-28: its time would
  // dominate — its sites have their own rows); it is ranked, and counted in
  // the total, by its time not spent on a recorded site. A browser without
  // recorded sites (no Vault extension) keeps its time.
  function usageItems(apps, sites, attribution, spanSeconds) {
    var items = [];
    apps.forEach(function (b) {
      var seconds = b.seconds;
      var inSites = attribution.byBrowser[b.key];
      if (inSites) {
        var siteSeconds = Object.keys(inSites).reduce(function (sum, key) { return sum + inSites[key] * spanSeconds; }, 0);
        seconds = Math.max(0, b.seconds - siteSeconds);
      }
      if (seconds >= 1) items.push({ item: b, seconds: seconds, kind: "App", nameOnly: !!inSites });
    });
    sites.forEach(function (b) { items.push({ item: b, seconds: b.seconds, kind: "Website" }); });
    return items.sort(function (x, y) { return y.seconds - x.seconds; });
  }

  function usageRows(items) {
    var wrap = el("div");
    if (!items.length) { wrap.appendChild(el("p", "empty", "Nothing in this range.")); return wrap; }
    var shown = items.filter(function (entry) { return !entry.nameOnly; });
    var top = Math.max(shown.length ? shown[0].seconds : 1, 1);
    items.slice(0, 20).forEach(function (entry) {
      wrap.appendChild(row(entry.item, entry.nameOnly ? null : entry.seconds, entry.seconds / top, entry.kind));
    });
    return wrap;
  }

  // The sites visited while a browser was in front: each site segment clipped
  // to each browser segment (fractions of the range). `pieces` feed the strip,
  // `byBrowser` the browsers' own time in the list.
  function attributeSites(apps, sites) {
    var pieces = [], byBrowser = {};
    apps.forEach(function (s) {
      if (!BROWSERS[s.key]) return;
      var from = s.startFraction, to = s.startFraction + s.widthFraction;
      sites.forEach(function (w) {
        var a = Math.max(from, w.startFraction), b = Math.min(to, w.startFraction + w.widthFraction);
        if (b <= a) return;
        pieces.push({ from: a, to: b, site: w, browser: s });
        var perSite = byBrowser[s.key] || (byBrowser[s.key] = {});
        perSite[w.key] = (perSite[w.key] || 0) + (b - a);
      });
    });
    return { pieces: pieces, byBrowser: byBrowser };
  }

  function clock(ms) { return new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }); }
  function day(ms) { return new Date(ms).toLocaleDateString([], { month: "short", day: "numeric" }); }

  // Browsers (by bundle id): in the Apps strip their time is split — the sites
  // visited on top, a thin band in the browser's own colour below.
  var BROWSERS = {
    "com.google.Chrome": 1, "com.google.Chrome.beta": 1, "com.google.Chrome.canary": 1,
    "com.google.Chrome.for.Testing": 1, "org.chromium.Chromium": 1, "com.microsoft.edgemac": 1,
    "com.brave.Browser": 1, "company.thebrowser.Browser": 1, "com.vivaldi.Vivaldi": 1,
    "com.operasoftware.Opera": 1, "com.apple.Safari": 1, "org.mozilla.firefox": 1
  };

  function segmentTitle(s) {
    return (s.label || s.key) + " — " + new Date(s.startedAtMs).toLocaleString([], { weekday: "short", hour: "numeric", minute: "2-digit" }) + " · " + fmt(s.seconds);
  }

  function place(node, from, to) {
    node.style.left = (from * 100) + "%";
    node.style.width = ((to - from) * 100) + "%";
  }

  // `pieces` (attributeSites) draw the sites inside the browser segments of
  // `segments`; omit them for a strip of one kind.
  function strip(segments, startMs, endMs, pieces) {
    var wrap = el("div");
    var track = el("div", "strip");
    var span = endMs - startMs;
    var multiDay = span > 36 * 3600 * 1000;
    if (span > 0 && multiDay) {
      var d = new Date(startMs); d.setHours(24, 0, 0, 0);
      for (; d.getTime() < endMs; d.setDate(d.getDate() + 1)) {
        var line = el("div", "day"); line.style.left = ((d.getTime() - startMs) / span * 100) + "%"; track.appendChild(line);
      }
    }
    segments.forEach(function (s) {
      var seg = paint(el("div", "seg"), s.colorIndex);
      place(seg, s.startFraction, s.startFraction + s.widthFraction);
      seg.title = segmentTitle(s);
      track.appendChild(seg);
    });
    // Sites on top of their browser's time; the browser's colour stays below.
    (pieces || []).forEach(function (piece) {
      var w = piece.site;
      var site = paint(el("div", "seg site"), w.colorIndex);
      place(site, piece.from, piece.to);
      site.title = segmentTitle(w) + " (" + (piece.browser.label || piece.browser.key) + ")";
      track.appendChild(site);
    });
    wrap.appendChild(track);
    var axis = el("div", "axis");
    axis.appendChild(el("span", null, multiDay ? day(startMs) : clock(startMs)));
    axis.appendChild(el("span", null, multiDay ? day(endMs) : clock(endMs)));
    wrap.appendChild(axis);
    return wrap;
  }

  function notRecorded(categories) {
    var off = el("div", "off");
    off.appendChild(el("span", null, "Not recorded."));
    off.appendChild(textButton("Turn on", function () {
      categories.forEach(function (category) { send({ kind: "setSettings", category: category, enabled: true }); });
    }));
    return off;
  }

  function settingsPanel(s) {
    var box = el("details", "vui-expand settings");
    box.appendChild(el("summary", null, "Recording"));
    KINDS.forEach(function (c) {
      var cat = s[c.id] || { enabled: false, retentionDays: 30 };
      var row = el("div", "settings-row");
      row.appendChild(el("span", "name", c.title));
      var rec = el("label"); var sw = el("input"); sw.type = "checkbox"; sw.checked = !!cat.enabled;
      sw.addEventListener("change", function () { send({ kind: "setSettings", category: c.key, enabled: sw.checked }); });
      rec.appendChild(sw); rec.appendChild(document.createTextNode("Record")); row.appendChild(rec);
      var keep = el("label"); keep.appendChild(document.createTextNode("Keep"));
      var sel = el("select");
      RETENTIONS.forEach(function (r) { var o = el("option", null, r[1]); o.value = String(r[0]); o.selected = r[0] === cat.retentionDays; sel.appendChild(o); });
      sel.addEventListener("change", function () { send({ kind: "setSettings", category: c.key, retentionDays: parseInt(sel.value, 10) }); });
      keep.appendChild(sel); row.appendChild(keep);
      // No native dialog: the first click asks, a second one within 4 s deletes.
      var armed = null;
      var del = textButton("Delete history", function () {
        if (armed) { clearTimeout(armed); armed = null; del.textContent = "Delete history"; send({ kind: "delete", scope: "category", category: c.key }); return; }
        del.textContent = "Click again to delete";
        armed = setTimeout(function () { armed = null; del.textContent = "Delete history"; }, 4000);
      }, "danger");
      row.appendChild(del);
      box.appendChild(row);
    });
    return box;
  }

  function render() {
    var page = scope.getElementById("page");
    page.textContent = "";
    if (!snapshot) { page.appendChild(el("p", "empty", "Loading…")); return; }
    var s = snapshot.settings || {};
    var panel = el("div", "panel");

    var head = el("div", "lists vui-tabs");
    VIEWS.forEach(function (view) {
      head.appendChild(textButton(view.title, function () { current = view.id; render(); },
        view.id === current ? "vui-tab is-active" : "vui-tab"));
    });
    var totalEl = el("span", "total", "Total");
    head.appendChild(totalEl);
    panel.appendChild(head);

    if (current === "watched") {
      var watched = snapshot.watched || [];
      totalEl.appendChild(el("strong", null, fmt(watched.reduce(function (a, b) { return a + b.seconds; }, 0))));
      if (!(s.contentWatched && s.contentWatched.enabled)) panel.appendChild(notRecorded(["content-watched"]));
      else panel.appendChild(rows(watched));
    } else {
      var apps = snapshot.app || { totalSeconds: 0, bars: [], timeline: [] };
      var web = snapshot.web || { totalSeconds: 0, bars: [], timeline: [] };
      var attribution = attributeSites(apps.timeline, web.timeline);
      var spanSeconds = (snapshot.rangeEndMs - snapshot.rangeStartMs) / 1000;
      var items = usageItems(apps.bars, web.bars, attribution, spanSeconds);
      totalEl.appendChild(el("strong", null, fmt(items.reduce(function (sum, entry) { return sum + entry.seconds; }, 0))));
      var appsOn = s.appUsage && s.appUsage.enabled, webOn = s.webVisit && s.webVisit.enabled;
      if (!appsOn && !webOn) {
        panel.appendChild(notRecorded(["app-usage", "web-visit"]));
      } else {
        if (apps.timeline.length) panel.appendChild(strip(apps.timeline, snapshot.rangeStartMs, snapshot.rangeEndMs, attribution.pieces));
        panel.appendChild(usageRows(items));
      }
    }
    panel.appendChild(settingsPanel(s));
    page.appendChild(panel);
  }

  window.activityApply = function (data, iconMap) { snapshot = data; icons = iconMap || {}; render(); };

  scope.getElementById("ranges").addEventListener("click", function (e) {
    var b = e.target.closest("button[data-range]"); if (!b) return;
    [].forEach.call(this.querySelectorAll("button"), function (x) { x.classList.toggle("is-active", x === b); });
    send({ kind: "range", range: b.dataset.range });
  });

  window.VaultUI.observe(scope);
  send({ kind: "ready" });
})();
