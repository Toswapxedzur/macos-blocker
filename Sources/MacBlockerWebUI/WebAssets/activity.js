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
  var RETENTIONS = [[7, "7 days"], [30, "30 days"], [90, "90 days"], [180, "180 days"], [0, "Forever"]];
  // What is recorded (each kind has its own switch under Recording).
  var KINDS = [
    { id: "appUsage", key: "app-usage", title: "Apps" },
    { id: "webVisit", key: "web-visit", title: "Websites" },
    { id: "contentWatched", key: "content-watched", title: "Watched" }
  ];
  var snapshot = null;
  // Details follows one pick: "all", an app ("app|<bundle id>"), a website
  // ("web|<domain>") or a group ("group|<id>"). Mac Vault answers with its
  // history (window.activityHistory).
  var picked = "all";
  var barDays = 3;
  var itemHistory = null;
  var usageItemsShown = [];  // the Usage rows (merge groups folded in)
  var usageItemsRaw = [];    // the same before folding (a group's members)
  // Groups (owner 2026-09-29): member id -> its merge group, for this render.
  var mergeOf = {};
  var groupsOpen = false;    // the Groups expand
  var editing = null;        // { id, name, merge, members, message, conflicts }
  var knownItems = null;     // what a group can hold (Mac Vault's list)
  var groupSearch = "";
  var groupMenu = null;
  var expandedGroups = {};   // merge group id -> its Usage row shows its members      // the Usage row's Add to group menu: { id, x, y, message, conflicts, group }
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
  function row(item, seconds, fraction, kind, onPick) {
    var line = el("div", onPick ? "row pickable" : "row");
    if (onPick) line.addEventListener("click", onPick);
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

  // ── Groups ──────────────────────────────────────────────────────────────

  function groupsList() { return (snapshot && snapshot.groups) || []; }

  function refreshMergeMap() {
    mergeOf = {};
    groupsList().forEach(function (g) {
      if (g.merge) g.members.forEach(function (m) { if (!mergeOf[m]) mergeOf[m] = g; });
    });
  }

  // A merge group's members take its colour everywhere (one colour).
  function colorIndexFor(lens, key, own) {
    var g = mergeOf[lens + "|" + key];
    return g ? g.colorIndex : own;
  }

  function entryID(entry) {
    if (entry.kind === "Group") return entry.item.key;
    return (entry.kind === "Website" ? "web|" : "app|") + entry.item.key;
  }

  // A merge group stands in for its members: one "Group" row with their time.
  function mergeItems(items) {
    var out = [], byGroup = {};
    items.forEach(function (entry) {
      var g = mergeOf[entryID(entry)];
      if (!g) { out.push(entry); return; }
      var merged = byGroup[g.id];
      if (!merged) {
        merged = byGroup[g.id] = { item: { key: "group|" + g.id, label: g.name, colorIndex: g.colorIndex }, seconds: 0, kind: "Group", group: g };
        out.push(merged);
      }
      merged.seconds += entry.seconds;
    });
    return out.sort(function (x, y) { return y.seconds - x.seconds; });
  }

  function usageRows(items) {
    var wrap = el("div");
    if (!items.length) { wrap.appendChild(el("p", "empty", "Nothing in this range.")); return wrap; }
    var shown = items.filter(function (entry) { return !entry.nameOnly; });
    var top = Math.max(shown.length ? shown[0].seconds : 1, 1);
    items.slice(0, 20).forEach(function (entry) {
      var line = row(entry.item, entry.nameOnly ? null : entry.seconds, entry.seconds / top, entry.kind,
        function () { pick(entryID(entry)); });
      if (entry.kind === "Group") {
        // Expand a merge group's row to its members' own times (owner 2026-09-29).
        var open = !!expandedGroups[entry.group.id];
        var toggle = el("button", open ? "row-expand is-open" : "row-expand", "›");
        toggle.type = "button";
        toggle.title = open ? "Hide members" : "Show members";
        toggle.addEventListener("click", function (event) {
          event.stopPropagation();
          expandedGroups[entry.group.id] = !open;
          render();
        });
        line.querySelector(".row-name").insertBefore(toggle, line.querySelector(".row-label"));
        wrap.appendChild(line);
        if (open) {
          usageItemsRaw.filter(function (member) { return entry.group.members.indexOf(entryID(member)) >= 0; })
            .forEach(function (member) {
              var memberLine = row(member.item, member.nameOnly ? null : member.seconds, member.seconds / top, member.kind,
                function () { pick(entryID(member)); });
              memberLine.classList.add("member");
              wrap.appendChild(memberLine);
            });
        }
        return;
      }
      if (entry.kind !== "Group") {
        var add = el("button", "row-add secondary", "+ Group");
        add.type = "button";
        add.title = "Add to group";
        add.addEventListener("click", function (event) {
          event.stopPropagation();
          var box = line.getBoundingClientRect();
          groupMenu = { id: entryID(entry), label: entry.item.label || entry.item.key, x: box.right, y: box.top + 30 };
          renderGroupMenu();
        });
        line.appendChild(add);
      }
      wrap.appendChild(line);
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
      var seg = paint(el("div", "seg"), colorIndexFor("app", s.key, s.colorIndex));
      place(seg, s.startFraction, s.startFraction + s.widthFraction);
      seg.title = segmentTitle(s);
      track.appendChild(seg);
    });
    // Sites on top of their browser's time; the browser's colour stays below.
    (pieces || []).forEach(function (piece) {
      var w = piece.site;
      var site = paint(el("div", "seg site"), colorIndexFor("web", w.key, w.colorIndex));
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

  // ── Details: the picked item's 180-day map, hour-by-hour bars, and the pie ──

  function pick(id) {
    picked = id;
    itemHistory = null;
    requestHistory();
    renderDetails();
  }

  function requestHistory() {
    send({ kind: "history", pick: picked, barDays: barDays });
  }

  window.activityHistory = function (request, data) {
    if (request.pick !== picked || request.barDays !== barDays) return;
    itemHistory = data;
    renderDetails();
  };

  var NAVY = [30, 58, 138];
  function navy(alpha) { return "rgba(" + NAVY.join(",") + "," + alpha + ")"; }
  var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

  function svg(tag, attrs) {
    var node = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (var name in attrs) node.setAttribute(name, attrs[name]);
    return node;
  }

  // GitHub-style: one column per week (Monday on top), one square per day,
  // darker = more time.
  function dayMap(h) {
    var wrap = el("div", "chart");
    wrap.appendChild(el("div", "chart-title", "Last " + h.daySeconds.length + " days"));
    var max = Math.max.apply(null, h.daySeconds.concat([1]));
    var cell = 13, gap = 3, top = 16, left = 28;
    var firstDay = new Date(h.dayStartsMs[0]);
    var lead = (firstDay.getDay() + 6) % 7; // Monday = 0
    var weeks = Math.ceil((lead + h.daySeconds.length) / 7);
    var width = left + weeks * (cell + gap), height = top + 7 * (cell + gap);
    var chart = svg("svg", { viewBox: "0 0 " + width + " " + height, width: width, height: height, class: "map" });
    ["Mon", "Wed", "Fri"].forEach(function (name, i) {
      var label = svg("text", { x: 0, y: top + (i * 2) * (cell + gap) + cell - 2, class: "axis-label" });
      label.textContent = name;
      chart.appendChild(label);
    });
    var lastMonth = -1;
    h.daySeconds.forEach(function (seconds, i) {
      var slot = lead + i, week = Math.floor(slot / 7), weekday = slot % 7;
      var date = new Date(h.dayStartsMs[i]);
      if (weekday === 0 || i === 0) {
        if (date.getMonth() !== lastMonth && week * (cell + gap) + left < width - 20) {
          var month = svg("text", { x: left + week * (cell + gap), y: 10, class: "axis-label" });
          month.textContent = MONTHS[date.getMonth()];
          chart.appendChild(month);
          lastMonth = date.getMonth();
        }
      }
      var level = seconds <= 0 ? 0 : Math.min(4, Math.ceil((seconds / max) * 4));
      var square = svg("rect", {
        x: left + week * (cell + gap), y: top + weekday * (cell + gap), width: cell, height: cell, rx: 3,
        fill: level === 0 ? "#e8ecf2" : navy([0, 0.3, 0.5, 0.72, 1][level])
      });
      var title = svg("title", {});
      title.textContent = DAY_NAMES[date.getDay()] + " " + MONTHS[date.getMonth()] + " " + date.getDate() + " · " + (seconds > 0 ? fmt(seconds) : "none");
      square.appendChild(title);
      chart.appendChild(square);
    });
    var scroller = el("div", "map-scroll");
    scroller.appendChild(chart);
    wrap.appendChild(scroller);
    return wrap;
  }

  // One day's rows, like the Usage list: apps, sites, a browser's leftover.
  function dayTotals(day, attribution) {
    var DAY = 86400;
    function bars(segments) {
      var by = {};
      segments.forEach(function (seg) {
        var bar = by[seg.key] || (by[seg.key] = { key: seg.key, label: seg.label, colorIndex: seg.colorIndex, seconds: 0 });
        bar.seconds += seg.widthFraction * DAY;
      });
      return Object.keys(by).map(function (k) { return by[k]; }).sort(function (x, y) { return y.seconds - x.seconds; });
    }
    return mergeItems(usageItems(bars(day.app), bars(day.web), attribution, DAY));
  }

  function dayLabel(day, index, count) {
    var date = new Date(day.dayStartMs);
    return index === count - 1 ? "Today" : DAY_NAMES[date.getDay()] + " " + date.getDate();
  }

  // One graph frame: horizontal grid lines with labels, one column per day.
  function dayFrame(days, ticks) {
    var width = 860, height = 240, left = 44, top = 8, bottom = 26;
    var frame = {
      width: width, left: left, top: top, plot: height - top - bottom, base: height - bottom,
      group: (width - left) / days.length,
      chart: svg("svg", { viewBox: "0 0 " + width + " " + height, width: "100%", class: "days" })
    };
    frame.barWidth = Math.min(46, frame.group * 0.5);
    ticks.forEach(function (tick) {
      var y = frame.base - tick.at * frame.plot;
      frame.chart.appendChild(svg("line", { x1: left, x2: width, y1: y, y2: y, stroke: "#eef1f6", "stroke-width": 1 }));
      var label = svg("text", { x: 0, y: y + 3, class: "axis-label" });
      label.textContent = tick.text;
      frame.chart.appendChild(label);
    });
    days.forEach(function (day, d) {
      var label = svg("text", { x: left + frame.group * d + frame.group / 2, y: height - 8, "text-anchor": "middle", class: "axis-label" });
      label.textContent = dayLabel(day, d, days.length);
      frame.chart.appendChild(label);
    });
    frame.block = function (x, y, w, h, colorIndex, text) {
      var rect = svg("rect", { x: x, y: y, width: w, height: Math.max(0.8, h), fill: colorOf(colorIndex) });
      var title = svg("title", {});
      title.textContent = text;
      rect.appendChild(title);
      frame.chart.appendChild(rect);
    };
    frame.barX = function (d) { return left + frame.group * d + (frame.group - frame.barWidth) / 2; };
    return frame;
  }

  function timeOfDay(fraction) {
    var minutes = Math.round(fraction * 1440);
    return Math.floor(minutes / 60) + ":" + String(minutes % 60).padStart(2, "0");
  }

  // In order: each day on a 24-hour scale, 00:00 at the bottom — every app
  // and site at its time, empty where nothing was used; a browser's time
  // shows its sites with the browser's colour as a thin band.
  function inOrderGraph(days) {
    var wrap = el("div", "chart");
    wrap.appendChild(el("div", "chart-title", "In order"));
    var f = dayFrame(days, [0, 6, 12, 18, 24].map(function (h) { return { at: h / 24, text: h + ":00" }; }));
    days.forEach(function (day, d) {
      var x = f.barX(d);
      f.chart.appendChild(svg("rect", { x: x, y: f.top, width: f.barWidth, height: f.plot, rx: 4, fill: "#f1f4f8" }));
      day.app.forEach(function (seg) {
        f.block(x, f.base - (seg.startFraction + seg.widthFraction) * f.plot, f.barWidth, seg.widthFraction * f.plot, colorIndexFor("app", seg.key, seg.colorIndex),
          (seg.label || seg.key) + " · " + timeOfDay(seg.startFraction) + "–" + timeOfDay(seg.startFraction + seg.widthFraction));
      });
      attributeSites(day.app, day.web).pieces.forEach(function (piece) {
        f.block(x, f.base - piece.to * f.plot, f.barWidth * 0.85, (piece.to - piece.from) * f.plot, colorIndexFor("web", piece.site.key, piece.site.colorIndex),
          (piece.site.label || piece.site.key) + " · " + timeOfDay(piece.from) + "–" + timeOfDay(piece.to) + " (" + (piece.browser.label || piece.browser.key) + ")");
      });
    });
    wrap.appendChild(f.chart);
    return wrap;
  }

  // Totals: each day's apps and sites stacked largest first from the bottom;
  // the busiest day shown reaches the top.
  function totalsGraph(days) {
    var wrap = el("div", "chart");
    wrap.appendChild(el("div", "chart-title", "Totals"));
    var perDay = days.map(function (day) { return dayTotals(day, attributeSites(day.app, day.web)); });
    var busiest = Math.max.apply(null, perDay.map(function (items) {
      return items.reduce(function (sum, entry) { return sum + entry.seconds; }, 0);
    }).concat([3600]));
    var stepHours = busiest > 12 * 3600 ? 4 : busiest > 6 * 3600 ? 2 : 1;
    var top = Math.ceil(busiest / (stepHours * 3600)) * stepHours * 3600;
    var ticks = [];
    for (var t = 0; t <= top; t += stepHours * 3600) ticks.push({ at: t / top, text: t === 0 ? "0" : (t / 3600) + "h" });
    var f = dayFrame(days, ticks);
    perDay.forEach(function (items, d) {
      var x = f.barX(d), y = f.base;
      items.forEach(function (entry) {
        var h = (entry.seconds / top) * f.plot;
        y -= h;
        f.block(x, y, f.barWidth, h, entry.item.colorIndex, (entry.item.label || entry.item.key) + " · " + fmt(entry.seconds));
      });
    });
    wrap.appendChild(f.chart);
    return wrap;
  }

  // The last 1-7 days of all usage, in two graphs under one picker.
  function daySection(days) {
    var wrap = el("div", "day-section");
    var head = el("div", "chart-head");
    head.appendChild(el("h2", null, "Day by day"));
    var select = el("select");
    [1, 2, 3, 4, 5, 6, 7].forEach(function (n) {
      var option = el("option", null, n === 1 ? "Today" : "Last " + n + " days");
      option.value = String(n);
      option.selected = n === barDays;
      select.appendChild(option);
    });
    select.addEventListener("change", function () {
      barDays = parseInt(select.value, 10);
      itemHistory = null;
      requestHistory();
      renderDetails();
    });
    head.appendChild(select);
    wrap.appendChild(head);
    wrap.appendChild(inOrderGraph(days));
    wrap.appendChild(totalsGraph(days));
    wrap.appendChild(el("div", "chart-legend", "Hover a block for its name and time."));
    return wrap;
  }

  // What gets its own slice (owner 2026-09-29). Other holds the items under
  // 2% of the total and a browser's leftover time (its time outside recorded
  // sites — the list shows no number for it, so neither does the pie). At
  // most 12 named slices; while there is room, Other's largest items get
  // their own slice so Other stays the smallest. `items` is sorted largest first.
  var OTHER_SHARE = 0.02, MAX_NAMED = 12;
  function splitSlices(items, total) {
    var named = [], other = [];
    items.forEach(function (entry) {
      if (!entry.nameOnly && entry.seconds / total >= OTHER_SHARE && named.length < MAX_NAMED) named.push(entry);
      else other.push(entry);
    });
    var otherSeconds = other.reduce(function (sum, entry) { return sum + entry.seconds; }, 0);
    while (named.length < MAX_NAMED && otherSeconds > 0) {
      var smallest = named.length ? named[named.length - 1].seconds : 0;
      if (otherSeconds < smallest) break;
      var index = other.findIndex(function (entry) { return !entry.nameOnly; });
      if (index < 0) break;
      var promoted = other.splice(index, 1)[0];
      named.push(promoted);
      otherSeconds -= promoted.seconds;
    }
    return { named: named, other: other, otherSeconds: otherSeconds };
  }

  // Share of the chosen range (Today / 7 / 30 days): the Usage rows.
  function pie(items) {
    var wrap = el("div", "chart");
    wrap.appendChild(el("div", "chart-title", "Share"));
    var total = items.reduce(function (sum, entry) { return sum + entry.seconds; }, 0);
    if (!total) { wrap.appendChild(el("p", "empty", "Nothing in this range.")); return wrap; }
    var split = splitSlices(items, total);
    var slices = split.named.map(function (entry) {
      var label = entry.item.label || entry.item.key;
      return { label: label, title: label, seconds: entry.seconds, color: colorOf(entry.item.colorIndex) };
    });
    if (split.otherSeconds > 0) {
      var names = split.other.slice(0, 15).map(function (entry) { return entry.item.label || entry.item.key; });
      if (split.other.length > 15) names.push("…");
      slices.push({
        label: "Other · " + split.other.length + (split.other.length === 1 ? " item" : " items"),
        title: "Other: " + names.join(", "),
        seconds: split.otherSeconds,
        color: "#cbd5e1"
      });
    }
    var size = 140, r = 64, c = size / 2;
    var chart = svg("svg", { viewBox: "0 0 " + size + " " + size, width: size, height: size, class: "pie" });
    var angle = -Math.PI / 2;
    slices.forEach(function (slice) {
      var part = slice.seconds / total, next = angle + part * Math.PI * 2;
      var shape;
      if (part >= 0.9999) {
        shape = svg("circle", { cx: c, cy: c, r: r, fill: slice.color });
      } else {
        var large = part > 0.5 ? 1 : 0;
        shape = svg("path", {
          d: "M" + c + "," + c + " L" + (c + r * Math.cos(angle)) + "," + (c + r * Math.sin(angle)) +
             " A" + r + "," + r + " 0 " + large + " 1 " + (c + r * Math.cos(next)) + "," + (c + r * Math.sin(next)) + " Z",
          fill: slice.color, stroke: "#ffffff", "stroke-width": 1
        });
      }
      var title = svg("title", {});
      title.textContent = slice.title + " · " + fmt(slice.seconds) + " · " + Math.round(part * 100) + "%";
      shape.appendChild(title);
      chart.appendChild(shape);
      angle = next;
    });
    var body = el("div", "pie-body");
    body.appendChild(chart);
    var legend = el("div", "pie-legend");
    slices.forEach(function (slice) {
      var item = el("div", "legend-item");
      item.title = slice.title;
      var dot = el("span", "dot");
      dot.style.background = slice.color;
      item.appendChild(dot);
      item.appendChild(el("span", "legend-label", slice.label));
      item.appendChild(el("span", "legend-note", Math.round((slice.seconds / total) * 100) + "%"));
      legend.appendChild(item);
    });
    body.appendChild(legend);
    wrap.appendChild(body);
    return wrap;
  }

  // ── Groups editor (under the Usage list, like Recording) ──

  function memberLabel(id) {
    var known = (knownItems || []).filter(function (item) { return item.id === id; })[0];
    return known ? known.label : id.slice(4);
  }

  function saveGroup(group, move, request) {
    send({ kind: "group-save", group: { id: group.id || "", name: group.name, merge: !!group.merge, members: group.members }, move: !!move, request: request });
  }

  window.activityKnownItems = function (list) {
    knownItems = list || [];
    if (editing) render();
  };

  // Mac Vault's answer to a save: saved (the snapshot follows), or refused —
  // a merge group's member already in another merge group can be moved.
  window.activityGroupSaved = function (answer) {
    var target = answer.request === "menu" ? groupMenu : editing;
    if (answer.ok) {
      if (answer.request === "menu") groupMenu = null; else editing = null;
      renderGroupMenu();
      return;
    }
    if (!target) return;
    target.message = answer.message || "Not saved.";
    target.conflicts = answer.conflicts || null;
    if (answer.request === "menu") renderGroupMenu(); else render();
  };

  function openEditor(group) {
    editing = group
      ? { id: group.id, name: group.name, merge: group.merge, members: group.members.slice() }
      : { id: "", name: "", merge: false, members: [] };
    groupsOpen = true;
    groupSearch = "";
    if (!knownItems) send({ kind: "known-items" });
    render();
  }

  function groupsPanel() {
    var box = el("details", "vui-expand groups");
    box.open = groupsOpen;
    box.addEventListener("toggle", function () {
      groupsOpen = box.open;
      if (box.open && !knownItems) send({ kind: "known-items" });
    });
    box.appendChild(el("summary", null, "Groups"));
    if (editing) { box.appendChild(groupForm()); return box; }
    var list = el("div", "group-list");
    groupsList().forEach(function (g) {
      var line = el("div", "group-row");
      var dot = paint(el("span", "dot"), g.colorIndex);
      line.appendChild(dot);
      line.appendChild(el("span", "name", g.name));
      line.appendChild(el("span", "row-kind", g.merge ? "Merge" : "View"));
      line.appendChild(el("span", "group-count", g.members.length + (g.members.length === 1 ? " member" : " members")));
      line.appendChild(textButton("Edit", function () { openEditor(g); }, "secondary"));
      var armed = null;
      var del = textButton("Delete", function () {
        if (armed) { clearTimeout(armed); send({ kind: "group-delete", id: g.id }); return; }
        del.textContent = "Click again to delete";
        armed = setTimeout(function () { armed = null; del.textContent = "Delete"; }, 4000);
      }, "danger");
      line.appendChild(del);
      list.appendChild(line);
    });
    if (!groupsList().length) list.appendChild(el("p", "empty", "No groups yet. A group shows its apps and websites together in Details; a merge group also stands in for them everywhere."));
    box.appendChild(list);
    box.appendChild(textButton("New group", function () { openEditor(null); }));
    return box;
  }

  function groupForm() {
    var form = el("div", "group-form");
    var name = el("input");
    name.type = "text";
    name.placeholder = "Group name";
    name.value = editing.name;
    name.addEventListener("input", function () { editing.name = name.value; });
    form.appendChild(name);
    var mergeRow = el("label", "group-merge");
    var merge = el("input");
    merge.type = "checkbox";
    merge.checked = editing.merge;
    merge.addEventListener("change", function () { editing.merge = merge.checked; });
    mergeRow.appendChild(merge);
    mergeRow.appendChild(document.createTextNode("Merge — show its members as one, in one colour, everywhere"));
    form.appendChild(mergeRow);
    var search = el("input");
    search.type = "search";
    search.placeholder = "Search apps and websites";
    search.value = groupSearch;
    form.appendChild(search);
    var list = el("div", "group-members");
    var entries = (knownItems || []).slice();
    editing.members.forEach(function (id) {
      if (!entries.some(function (item) { return item.id === id; })) entries.unshift({ id: id, label: id.slice(4), seconds: 0 });
    });
    if (!knownItems) list.appendChild(el("p", "empty", "Loading…"));
    entries.forEach(function (item) {
      var line = el("label", "member-row");
      line.dataset.search = (item.label + " " + item.id).toLowerCase();
      var box = el("input");
      box.type = "checkbox";
      box.checked = editing.members.indexOf(item.id) >= 0;
      box.addEventListener("change", function () {
        if (box.checked) { if (editing.members.indexOf(item.id) < 0) editing.members.push(item.id); }
        else editing.members = editing.members.filter(function (m) { return m !== item.id; });
      });
      line.appendChild(box);
      line.appendChild(icon(item.id.slice(4), item.label));
      line.appendChild(el("span", "name", item.label));
      line.appendChild(el("span", "row-kind", item.id.indexOf("web|") === 0 ? "Website" : "App"));
      if (item.seconds) line.appendChild(el("span", "group-count", fmt(item.seconds)));
      list.appendChild(line);
    });
    function filter() {
      var q = groupSearch.trim().toLowerCase();
      [].forEach.call(list.querySelectorAll(".member-row"), function (line) { line.hidden = !!q && line.dataset.search.indexOf(q) < 0; });
    }
    search.addEventListener("input", function () { groupSearch = search.value; filter(); });
    filter();
    form.appendChild(list);
    if (editing.message) {
      var note = el("div", "group-note", editing.message + ".");
      if (editing.conflicts) {
        note.appendChild(textButton("Move them here", function () { saveGroup(editing, true, "editor"); }, "secondary"));
      }
      form.appendChild(note);
    }
    var actions = el("div", "group-actions");
    actions.appendChild(textButton("Save", function () { editing.message = null; saveGroup(editing, false, "editor"); }));
    actions.appendChild(textButton("Cancel", function () { editing = null; render(); }, "secondary"));
    form.appendChild(actions);
    return form;
  }

  // The Usage row's "+ Group": tick the groups this app or site is in.
  function renderGroupMenu() {
    var old = scope.getElementById("group-menu");
    if (old) old.remove();
    if (!groupMenu) return;
    var menu = el("div", "group-menu");
    menu.id = "group-menu";
    menu.style.left = Math.max(8, groupMenu.x - 240) + "px";
    menu.style.top = groupMenu.y + "px";
    menu.addEventListener("click", function (event) { event.stopPropagation(); });
    menu.appendChild(el("div", "group-menu-title", groupMenu.label));
    groupsList().forEach(function (g) {
      var inIt = g.members.indexOf(groupMenu.id) >= 0;
      var item = textButton((inIt ? "✓ " : "") + g.name + (g.merge ? " · Merge" : ""), function () {
        var members = inIt ? g.members.filter(function (m) { return m !== groupMenu.id; }) : g.members.concat([groupMenu.id]);
        groupMenu.group = { id: g.id, name: g.name, merge: g.merge, members: members };
        groupMenu.message = null;
        saveGroup(groupMenu.group, false, "menu");
      }, "group-menu-item");
      menu.appendChild(item);
    });
    menu.appendChild(textButton("New group with this…", function () {
      var id = groupMenu.id;
      groupMenu = null;
      renderGroupMenu();
      openEditor({ id: "", name: "", merge: false, members: [id] });
    }, "group-menu-item"));
    if (groupMenu.message) {
      var note = el("div", "group-note", groupMenu.message + ".");
      if (groupMenu.conflicts && groupMenu.group) {
        note.appendChild(textButton("Move it", function () { saveGroup(groupMenu.group, true, "menu"); }, "secondary"));
      }
      menu.appendChild(note);
    }
    scope.getElementById("activity").appendChild(menu);
  }

  scope.addEventListener("click", function () {
    if (groupMenu) { groupMenu = null; renderGroupMenu(); }
  });

  // A picked group's pie shows its members; otherwise the Usage rows.
  function pieItems() {
    if (picked.indexOf("group|") !== 0) return usageItemsShown;
    var g = groupsList().filter(function (x) { return "group|" + x.id === picked; })[0];
    if (!g) return usageItemsShown;
    return usageItemsRaw.filter(function (entry) { return g.members.indexOf(entryID(entry)) >= 0; });
  }

  function renderDetails() {
    var box = scope.getElementById("details");
    if (!box) return;
    box.textContent = "";
    var head = el("div", "details-head");
    head.appendChild(el("h2", null, "Details"));
    var select = el("select");
    var choices = [{ value: "all", label: "All usage" }];
    groupsList().forEach(function (g) {
      choices.push({ value: "group|" + g.id, label: g.name + " · " + (g.merge ? "Merge group" : "View group") });
    });
    usageItemsShown.forEach(function (entry) {
      if (entry.kind !== "Group") choices.push({ value: entryID(entry), label: (entry.item.label || entry.item.key) + " · " + entry.kind });
    });
    var chosen = picked;
    if (!choices.some(function (c) { return c.value === chosen; })) {
      if (chosen.indexOf("group|") === 0) { chosen = picked = "all"; } // a deleted group
      else choices.push({ value: chosen, label: chosen.slice(4) });
    }
    choices.forEach(function (choice) {
      var option = el("option", null, choice.label);
      option.value = choice.value;
      option.selected = choice.value === chosen;
      select.appendChild(option);
    });
    select.addEventListener("change", function () { pick(select.value); });
    head.appendChild(select);
    box.appendChild(head);
    if (!itemHistory) { box.appendChild(el("p", "empty", "Loading…")); return; }
    var upper = el("div", "details-row");
    upper.appendChild(dayMap(itemHistory.map));
    upper.appendChild(pie(pieItems()));
    box.appendChild(upper);
    box.appendChild(daySection(itemHistory.days));
  }

  // One column's head: its title and its total.
  function columnHead(title, seconds) {
    var head = el("div", "column-head");
    head.appendChild(el("h2", null, title));
    var total = el("span", "total");
    total.appendChild(el("strong", null, fmt(seconds)));
    head.appendChild(total);
    return head;
  }

  // Usage and Watched side by side (owner 2026-09-29: "enough space for all of
  // them"), the day strip above both.
  function render() {
    var page = scope.getElementById("page");
    page.textContent = "";
    if (!snapshot) { page.appendChild(el("p", "empty", "Loading…")); return; }
    refreshMergeMap();
    var s = snapshot.settings || {};
    var panel = el("div", "panel");

    var apps = snapshot.app || { totalSeconds: 0, bars: [], timeline: [] };
    var web = snapshot.web || { totalSeconds: 0, bars: [], timeline: [] };
    var attribution = attributeSites(apps.timeline, web.timeline);
    var spanSeconds = (snapshot.rangeEndMs - snapshot.rangeStartMs) / 1000;
    usageItemsRaw = usageItems(apps.bars, web.bars, attribution, spanSeconds);
    var items = mergeItems(usageItemsRaw);
    usageItemsShown = items;
    var appsOn = s.appUsage && s.appUsage.enabled, webOn = s.webVisit && s.webVisit.enabled;
    if ((appsOn || webOn) && apps.timeline.length) {
      panel.appendChild(strip(apps.timeline, snapshot.rangeStartMs, snapshot.rangeEndMs, attribution.pieces));
    }

    var columns = el("div", "columns");
    var usage = el("section", "column");
    usage.appendChild(columnHead("Usage", items.reduce(function (sum, entry) { return sum + entry.seconds; }, 0)));
    usage.appendChild(appsOn || webOn ? usageRows(items) : notRecorded(["app-usage", "web-visit"]));
    columns.appendChild(usage);

    var watched = snapshot.watched || [];
    var watchedColumn = el("section", "column");
    watchedColumn.appendChild(columnHead("Watched", watched.reduce(function (a, b) { return a + b.seconds; }, 0)));
    watchedColumn.appendChild(s.contentWatched && s.contentWatched.enabled ? rows(watched) : notRecorded(["content-watched"]));
    columns.appendChild(watchedColumn);
    panel.appendChild(columns);

    panel.appendChild(settingsPanel(s));
    panel.appendChild(groupsPanel());
    page.appendChild(panel);
    var details = el("div", "panel details");
    details.id = "details";
    page.appendChild(details);
    renderDetails();
  }

  window.activityApply = function (data, iconMap) {
    snapshot = data;
    icons = iconMap || {};
    render();
    requestHistory();
  };

  scope.getElementById("ranges").addEventListener("click", function (e) {
    var b = e.target.closest("button[data-range]"); if (!b) return;
    [].forEach.call(this.querySelectorAll("button"), function (x) { x.classList.toggle("is-active", x === b); });
    send({ kind: "range", range: b.dataset.range });
  });

  window.VaultUI.observe(scope);
  send({ kind: "ready" });
})();
