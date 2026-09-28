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
    '<div class="ranges" id="ranges">',
    '<button type="button" data-range="today" class="active">Today</button>',
    '<button type="button" data-range="7d">7 days</button>',
    '<button type="button" data-range="30d">30 days</button>',
    "</div>",
    "</div>",
    "</header>",
    '<main><div class="page" id="page"><p class="empty">Loading…</p></div></main>'
  ].join("");
  var RETENTIONS = [[7, "7 days"], [30, "30 days"], [90, "90 days"], [0, "Forever"]];
  var LISTS = [
    { id: "appUsage", key: "app-usage", title: "Apps", lens: "app" },
    { id: "webVisit", key: "web-visit", title: "Websites", lens: "web" },
    { id: "contentWatched", key: "content-watched", title: "Watched", lens: null }
  ];
  var current = "appUsage";
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
  function color(i) { return "c" + (((i % 12) + 12) % 12); }
  function textButton(label, onClick, cls) { var b = el("button", cls || null, label); b.type = "button"; b.addEventListener("click", onClick); return b; }

  function icon(key, label) {
    var box = el("span", "icon");
    if (icons[key]) { var img = el("img"); img.src = icons[key]; img.alt = ""; box.appendChild(img); }
    else box.textContent = ((label || key || "?").trim()[0] || "?").toUpperCase();
    return box;
  }

  function rows(bars) {
    var wrap = el("div");
    if (!bars.length) { wrap.appendChild(el("p", "empty", "Nothing in this range.")); return wrap; }
    bars.slice(0, 20).forEach(function (b) {
      var row = el("div", "row");
      row.title = (b.label || b.key) + " — " + fmt(b.seconds);
      row.appendChild(icon(b.key, b.label));
      var body = el("div", "row-body");
      body.appendChild(el("div", "row-name", b.label || b.key));
      var bar = el("div", "row-bar"), fill = el("span", color(b.colorIndex));
      fill.style.width = Math.max(1.5, b.fraction * 100) + "%";
      bar.appendChild(fill); body.appendChild(bar);
      row.appendChild(body);
      row.appendChild(el("div", "row-time", fmt(b.seconds)));
      wrap.appendChild(row);
    });
    return wrap;
  }

  function clock(ms) { return new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }); }
  function day(ms) { return new Date(ms).toLocaleDateString([], { month: "short", day: "numeric" }); }

  function strip(segments, startMs, endMs) {
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
      var seg = el("div", "seg " + color(s.colorIndex));
      seg.style.left = (s.startFraction * 100) + "%";
      seg.style.width = (s.widthFraction * 100) + "%";
      seg.title = (s.label || s.key) + " — " + new Date(s.startedAtMs).toLocaleString([], { weekday: "short", hour: "numeric", minute: "2-digit" }) + " · " + fmt(s.seconds);
      track.appendChild(seg);
    });
    wrap.appendChild(track);
    var axis = el("div", "axis");
    axis.appendChild(el("span", null, multiDay ? day(startMs) : clock(startMs)));
    axis.appendChild(el("span", null, multiDay ? day(endMs) : clock(endMs)));
    wrap.appendChild(axis);
    return wrap;
  }

  function settingsPanel(s) {
    var box = el("details", "vui-expand settings");
    box.appendChild(el("summary", null, "Recording"));
    LISTS.forEach(function (c) {
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

    var head = el("div", "lists");
    LISTS.forEach(function (c) {
      var b = textButton(c.title, function () { current = c.id; render(); }, c.id === current ? "active" : "");
      head.appendChild(b);
    });
    var def = LISTS.filter(function (c) { return c.id === current; })[0];
    var lens = def.lens ? snapshot[def.lens] : null;
    var bars = lens ? lens.bars : (snapshot.watched || []);
    var total = lens ? lens.totalSeconds : bars.reduce(function (a, b) { return a + b.seconds; }, 0);
    var totalEl = el("span", "total", "Total"); totalEl.appendChild(el("strong", null, fmt(total)));
    head.appendChild(totalEl);
    panel.appendChild(head);

    var cat = s[def.id] || { enabled: false };
    if (!cat.enabled) {
      var off = el("div", "off");
      off.appendChild(el("span", null, "Not recorded."));
      off.appendChild(textButton("Turn on", function () { send({ kind: "setSettings", category: def.key, enabled: true }); }));
      panel.appendChild(off);
    } else {
      if (lens && lens.timeline.length) panel.appendChild(strip(lens.timeline, snapshot.rangeStartMs, snapshot.rangeEndMs));
      panel.appendChild(rows(bars));
    }
    panel.appendChild(settingsPanel(s));
    page.appendChild(panel);
  }

  window.activityApply = function (data, iconMap) { snapshot = data; icons = iconMap || {}; render(); };

  scope.getElementById("ranges").addEventListener("click", function (e) {
    var b = e.target.closest("button[data-range]"); if (!b) return;
    [].forEach.call(this.querySelectorAll("button"), function (x) { x.classList.toggle("active", x === b); });
    send({ kind: "range", range: b.dataset.range });
  });

  window.VaultUI.observe(scope);
  send({ kind: "ready" });
})();
