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
    '<div class="vui-topbar-links"><button type="button" class="secondary" id="activityManualButton">User manual</button></div>',
    "</header>",
    '<main><div class="page" id="page"><p class="empty">Loading…</p></div></main>'
  ].join("");
  scope.getElementById("activityManualButton").addEventListener("click", function () { window.VaultManual.open("user", "Activity"); });
  var RETENTIONS = [[7, "7 days"], [30, "30 days"], [90, "90 days"], [180, "180 days"], [365, "365 days"], [0, "Forever"]];
  // What is recorded (each kind has its own switch under Recording).
  var KINDS = [
    { id: "appUsage", key: "app-usage", title: "Apps" },
    { id: "webVisit", key: "web-visit", title: "Websites" },
    { id: "contentWatched", key: "content-watched", title: "Content" }
  ];
  var snapshot = null;       // the Usage range's snapshot (and groups, settings)
  var contentSnap = null;    // the Content range's snapshot
  var usageItemsShown = [];  // the Usage rows (merge groups folded in)
  var usageItemsRaw = [];    // the same before folding (a group's members)
  // Groups (owner 2026-09-29): member id -> its merge group, for this render.
  var mergeOf = {};
  var editing = null;        // { id, name, merge, members, message, conflicts }
  var knownItems = null;     // what a group can hold (Mac Vault's list)
  var groupSearch = "";
  var armedDeletes = new Map();

  // Confirmation belongs to the entity, so rebuilding the page does not
  // discard a first click. Expiry updates whichever button is now on screen.
  function deleteButton(label, key, action) {
    var armed = armedDeletes.get(key);
    var button = textButton(armed && armed.until > Date.now() ? CLICK_AGAIN : label, function () {
      var current = armedDeletes.get(key);
      if (current && current.until > Date.now()) {
        clearTimeout(current.timer);
        armedDeletes.delete(key);
        action();
        return;
      }
      if (current) clearTimeout(current.timer);
      var next = { until: Date.now() + 4000 };
      next.timer = setTimeout(function () {
        if (armedDeletes.get(key) !== next) return;
        armedDeletes.delete(key);
        scope.querySelectorAll("[data-confirm-key]").forEach(function (node) {
          if (node.dataset.confirmKey === key) node.textContent = label;
        });
      }, 4000);
      armedDeletes.set(key, next);
      button.textContent = CLICK_AGAIN;
    }, "danger");
    button.dataset.confirmKey = key;
    return button;
  }
  var icons = {};
  // Watched (owner 2026-09-29): videos, authors and tags; per watched key
  // { creator, creatorIcon, tags: [{ id, name, color }] } (Mac Vault records
  // the author when the video is watched; the tags are the classifier's).
  var watchedFacts = {};
  var knownIcons = {};       // the editor's items' icons (Mac Vault sends them with the list)

  function send(msg) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.activity) {
        window.webkit.messageHandlers.activity.postMessage(msg);
      } else if (window.chrome && window.chrome.webview) {
        window.chrome.webview.postMessage(msg);
      }
    } catch (_) {}
  }

  var CLICK_AGAIN = "Click again to delete";

  // Durations read as the Vault editor's (owner 2026-09-30): 01:20:00.
  function fmt(seconds) {
    var s = Math.max(0, Math.round(seconds));
    return [Math.floor(s / 3600), Math.floor((s % 3600) / 60), s % 60]
      .map(function (n) { return String(n).padStart(2, "0"); }).join(":");
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
  function searchable(node, key, label, items) {
    node.dataset.vuiSearch = key;
    node.dataset.vuiSearchLabel = label;
    node.dataset.vuiSearchItems = items;
    return node;
  }

  function textButton(label, onClick, cls) { var b = el("button", cls || null, label); b.type = "button"; b.addEventListener("click", onClick); return b; }

  function iconURI(key) { return icons[key] || knownIcons[key] || null; }
  function initial(text) { return ((text || "?").trim()[0] || "?").toUpperCase(); }

  function icon(key, label) {
    if (key && key.indexOf("group|") === 0) {
      var g = groupsList().filter(function (x) { return "group|" + x.id === key; })[0];
      if (g) return groupIcon(g);
    }
    var box = el("span", "icon");
    if (iconURI(key)) { var img = el("img"); img.src = iconURI(key); img.alt = ""; box.appendChild(img); }
    else box.textContent = initial(label || key);
    return box;
  }

  // A group's icon is made of slices of its members' icons (owner
  // 2026-09-29): 1 whole, 2 halves, 3 wedges from the centre, 4 quarters;
  // more than 4 = three members and "+N". Each slice shows the middle of its
  // member's icon (a real corner of an icon is mostly empty).
  var SLICES = {
    1: [["0 0, 100% 0, 100% 100%, 0 100%", 50, 50]],
    2: [["0 0, 50% 0, 50% 100%, 0 100%", 25, 50], ["50% 0, 100% 0, 100% 100%, 50% 100%", 75, 50]],
    3: [["50% 50%, 50% 0, 0 0, 0 78.9%", 24, 34], ["50% 50%, 50% 0, 100% 0, 100% 78.9%", 76, 34],
        ["50% 50%, 100% 78.9%, 100% 100%, 0 100%, 0 78.9%", 50, 80]],
    4: [["0 0, 50% 0, 50% 50%, 0 50%", 25, 25], ["50% 0, 100% 0, 100% 50%, 50% 50%", 75, 25],
        ["0 50%, 50% 50%, 50% 100%, 0 100%", 25, 75], ["50% 50%, 100% 50%, 100% 100%, 50% 100%", 75, 75]]
  };
  function groupIcon(g, big) {
    var box = el("span", big ? "icon group-icon big" : "icon group-icon");
    var members = g.members || [];
    if (!members.length) { box.textContent = initial(g.name); return box; }
    var shown = members.length > 4 ? members.slice(0, 3) : members;
    var slices = SLICES[Math.min(members.length, 4)];
    shown.forEach(function (id, i) {
      var slice = el("span", "slice");
      slice.style.clipPath = "polygon(" + slices[i][0] + ")";
      var key = id.slice(4);
      if (iconURI(key)) {
        var face = el("img", "face");
        face.src = iconURI(key);
        face.alt = "";
        face.style.left = (slices[i][1] - 50) + "%";
        face.style.top = (slices[i][2] - 50) + "%";
        slice.appendChild(face);
      } else {
        // no icon: its letter, at the slice's middle
        slice.classList.add("lettered");
        var letter = el("span", "letter", initial(memberLabel(id)));
        letter.style.left = slices[i][1] + "%";
        letter.style.top = slices[i][2] + "%";
        if (members.length === 1) letter.style.fontSize = "14px";
        slice.appendChild(letter);
      }
      box.appendChild(slice);
    });
    if (members.length > 4) {
      var more = el("span", "slice more");
      more.style.clipPath = "polygon(" + slices[3][0] + ")";
      var label = el("span", "letter", "+" + (members.length - 3));
      label.style.left = "75%"; label.style.top = "75%";
      more.appendChild(label);
      box.appendChild(more);
    }
    return box;
  }

  // `seconds` null = a row shown by name only (a browser in Usage).
  function row(item, seconds, fraction, kind, onPick) {
    var line = el("div", onPick ? "row pickable" : "row");
    if (onPick) line.addEventListener("click", onPick);
    line.dataset.hint = (item.label || item.key) + (seconds !== null ? " — " + fmt(seconds) : "");
    var mark = icon(item.key, item.label);
    if (item.color && !iconURI(item.key)) { mark.style.background = item.color; mark.style.color = "#ffffff"; }
    line.appendChild(mark);
    var body = el("div", "row-body");
    var name = el("div", "row-name");
    name.appendChild(el("span", "row-label", item.label || item.key));
    if (kind) name.appendChild(el("span", "row-kind", kind));
    body.appendChild(name);
    if (seconds !== null) {
      var bar = el("div", "row-bar"), fill = item.color ? el("span") : paint(el("span"), item.colorIndex);
      if (item.color) fill.style.background = item.color;
      fill.style.width = Math.max(1.5, fraction * 100) + "%";
      bar.appendChild(fill); body.appendChild(bar);
    }
    line.appendChild(body);
    line.appendChild(el("div", "row-time", seconds === null ? "" : fmt(seconds)));
    return line;
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

  // The sites visited while a browser was in front: each site segment clipped
  // to each browser segment (fractions of the range). `pieces` feed the strip,
  // `byBrowser` the browsers' own time in the list.
  function attributeSites(apps, sites) {
    var pieces = [], byBrowser = {};
    // Sites by start; each browser block looks only at the sites that can
    // overlap it (every pair was ~6 M checks for 90 days).
    var sorted = sites.slice().sort(function (a, b) { return a.startFraction - b.startFraction; });
    var starts = sorted.map(function (w) { return w.startFraction; });
    var longest = sorted.reduce(function (m, w) { return Math.max(m, w.widthFraction); }, 0);
    apps.forEach(function (s) {
      if (!BROWSERS[s.key]) return;
      var from = s.startFraction, to = s.startFraction + s.widthFraction;
      // first site that could still be running at `from`
      var lo = 0, hi = starts.length, bound = from - longest;
      while (lo < hi) { var mid = (lo + hi) >> 1; if (starts[mid] < bound) lo = mid + 1; else hi = mid; }
      for (var i = lo; i < sorted.length && sorted[i].startFraction < to; i++) {
        var w = sorted[i];
        var a = Math.max(from, w.startFraction), b = Math.min(to, w.startFraction + w.widthFraction);
        if (b <= a) continue;
        pieces.push({ from: a, to: b, site: w, browser: s });
        var perSite = byBrowser[s.key] || (byBrowser[s.key] = {});
        perSite[w.key] = (perSite[w.key] || 0) + (b - a);
      }
    });
    return { pieces: pieces, byBrowser: byBrowser };
  }

  // One formatter each: building one per call cost ~0.2 ms, thousands of
  // times per render.
  var CLOCK = new Intl.DateTimeFormat([], { hour: "numeric", minute: "2-digit" });
  var DAY = new Intl.DateTimeFormat([], { month: "short", day: "numeric" });
  function clock(ms) { return CLOCK.format(ms); }
  function day(ms) { return DAY.format(ms); }

  // Browsers (by bundle id): in the Apps strip their time is split — the sites
  // visited on top, a thin band in the browser's own colour below.
  var BROWSERS = {
    "com.google.Chrome": 1, "com.google.Chrome.beta": 1, "com.google.Chrome.canary": 1,
    "com.google.Chrome.for.Testing": 1, "org.chromium.Chromium": 1, "com.microsoft.edgemac": 1,
    "com.brave.Browser": 1, "company.thebrowser.Browser": 1, "com.vivaldi.Vivaldi": 1,
    "com.operasoftware.Opera": 1, "com.apple.Safari": 1, "org.mozilla.firefox": 1
  };

  // ── Hover card (owner 2026-09-29: hover any bar or pie for details) ──
  // Our own card, not the system tooltip. A chart part registers what it
  // shows: { title, color, key, lines: [text], list: [[label, time]] }.
  var hoverInfo = new WeakMap();
  var hot = null;
  // `info` may be a function: it is built on first hover (a strip holds
  // thousands of blocks, most never hovered).
  function hoverable(node, info) { hoverInfo.set(node, info); return node; }
  function share(part, whole, of) {
    var p = part / whole * 100;
    return (p > 0 && p < 1 ? "<1%" : Math.round(p) + "%") + " of " + of;
  }
  function timeSpan(fromMs, toMs, withDay) {
    var text = clock(fromMs) + " – " + clock(toMs);
    return withDay ? day(fromMs) + ", " + text : text;
  }

  function hideHover() {
    var card = scope.getElementById("hovercard");
    if (card) card.hidden = true;
    if (hot) { hot.classList.remove("is-hot"); hot = null; }
  }

  function showHover(node, info, x, y) {
    var card = scope.getElementById("hovercard");
    if (!card) {
      card = el("div", "hovercard");
      card.id = "hovercard";
      scope.getElementById("activity").appendChild(card);
    }
    if (hot !== node) {
      if (hot) hot.classList.remove("is-hot");
      hot = node;
      node.classList.add("is-hot");
      card.textContent = "";
      var head = el("div", "hover-head");
      if (info.key) head.appendChild(icon(info.key, info.title));
      else if (info.color) { var dot = el("span", "dot"); dot.style.background = info.color; head.appendChild(dot); }
      head.appendChild(el("span", "hover-title", info.title));
      card.appendChild(head);
      (info.lines || []).forEach(function (line) { if (line) card.appendChild(el("div", "hover-line", line)); });
      if (info.list && info.list.length) {
        var list = el("div", "hover-list");
        info.list.forEach(function (pair) {
          var item = el("div", "hover-item");
          item.appendChild(el("span", "hover-item-label", pair[0]));
          item.appendChild(el("span", "hover-item-time", pair[1]));
          list.appendChild(item);
        });
        card.appendChild(list);
      }
    }
    card.hidden = false;
    var w = card.offsetWidth, h = card.offsetHeight;
    var left = x + 14, top = y + 14;
    if (left + w > window.innerWidth - 8) left = Math.max(8, x - w - 14);
    if (top + h > window.innerHeight - 8) top = Math.max(8, y - h - 14);
    card.style.left = left + "px";
    card.style.top = top + "px";
  }

  scope.addEventListener("mousemove", function (event) {
    var path = event.composedPath();
    for (var i = 0; i < path.length; i++) {
      var info = hoverInfo.get(path[i]);
      if (typeof info === "function") { info = info(); hoverInfo.set(path[i], info); }
      if (info) { showHover(path[i], info, event.clientX, event.clientY); return; }
    }
    hideHover();
  });
  scope.addEventListener("mouseout", function (event) { if (!event.relatedTarget) hideHover(); });
  scope.addEventListener("scroll", hideHover, true);

  // A strip segment: an app's or site's stretch of time.
  function segmentInfo(s, kind, fromMs, toMs, multiDay, browser) {
    return {
      title: s.label || s.key,
      key: s.key,
      lines: [kind + (browser ? " · in " + (browser.label || browser.key) : ""),
        timeSpan(fromMs, toMs, multiDay) + " · " + fmt((toMs - fromMs) / 1000)]
    };
  }

  // A Usage entry (an app, a site, a merge group, a browser's leftover).
  function entryInfo(entry, lines) {
    var kind = entry.kind === "Group"
      ? "Merge group · " + entry.group.members.length + (entry.group.members.length === 1 ? " member" : " members")
      : entry.nameOnly ? "App · browser, time outside recorded sites"
      : entry.videos ? entry.kind + " · " + entry.videos.length + (entry.videos.length === 1 ? " item" : " items") : entry.kind;
    if (entry.item.color) return { title: entry.item.label, color: entry.item.color, lines: [kind].concat(lines) };
    return { title: entry.item.label || entry.item.key, key: entry.item.key, lines: [kind].concat(lines) };
  }

  function place(node, from, to) {
    node.style.left = (from * 100) + "%";
    node.style.width = ((to - from) * 100) + "%";
  }

  function notRecorded(categories) {
    var off = el("div", "off");
    off.appendChild(el("span", null, "Not recorded."));
    off.appendChild(textButton("Turn on", function () {
      categories.forEach(function (category) { send({ kind: "setSettings", category: category, enabled: true }); });
    }));
    return off;
  }

  function infoField(anchor, key, label, text) {
    anchor.dataset.infoKey = key;
    anchor.dataset.infoLabel = label;
    anchor.dataset.infoCopy = text;
    return anchor;
  }
  function infoControl(control, key, label, text) {
    var row = infoField(el("div", "vui-info-field"), key, label, text);
    row.appendChild(control);
    return row;
  }

  function keepSelect(value, follow, onChange) {
    var sel = el("select");
    var choices = (follow ? [[-1, "Same as all (" + follow + ")"]] : []).concat(RETENTIONS);
    choices.forEach(function (r) { var o = el("option", null, r[1]); o.value = String(r[0]); o.selected = r[0] === value; sel.appendChild(o); });
    sel.addEventListener("change", function () { onChange(parseInt(sel.value, 10)); });
    return sel;
  }

  var recordingOpen = false; // the Recording expand stays open across updates
  var platformFeeds = {};    // what each platform records for the classifier

  function settingsPanel(s) {
    var box = el("details", "vui-expand settings");
    box.open = recordingOpen;
    box.addEventListener("toggle", function () { recordingOpen = box.open; });
    box.appendChild(el("summary", null, "Recording"));
    // The global Keep (owner 2026-09-29); each kind follows it unless set.
    var global = typeof s.retentionDays === "number" ? s.retentionDays : 180;
    var globalName = (RETENTIONS.filter(function (r) { return r[0] === global; })[0] || [0, global + " days"])[1];
    var all = el("div", "settings-row");
    all.appendChild(el("span", "name", "All history"));
    var allKeep = el("label"); allKeep.appendChild(document.createTextNode("Keep"));
    allKeep.appendChild(keepSelect(global, null, function (days) { send({ kind: "setSettings", retentionDays: days }); }));
    infoField(allKeep, "retention:all", "Keep all history", "How long recorded history is retained. Categories and platform feeds follow this value unless they have their own setting. Older records are deleted automatically.");
    all.appendChild(allKeep);
    box.appendChild(all);
    KINDS.forEach(function (c) {
      var cat = s[c.id] || { enabled: false, retentionDays: null };
      var row = el("div", "settings-row");
      row.appendChild(el("span", "name", c.title));
      var rec = el("label"); var sw = el("input"); sw.type = "checkbox"; sw.checked = !!cat.enabled;
      sw.addEventListener("change", function () { send({ kind: "setSettings", category: c.key, enabled: sw.checked }); });
      infoField(rec, "record:" + c.key, "Record " + c.title, "Record new " + c.title.toLowerCase() + " history. Turning recording off leaves saved history in place.");
      rec.appendChild(sw); rec.appendChild(document.createTextNode("Record")); row.appendChild(rec);
      var keep = el("label"); keep.appendChild(document.createTextNode("Keep"));
      var own = typeof cat.retentionDays === "number" ? cat.retentionDays : -1;
      keep.appendChild(keepSelect(own, globalName.toLowerCase(), function (days) {
        send({ kind: "setSettings", category: c.key, retentionDays: days });
      }));
      infoField(keep, "keep:" + c.key, "Keep " + c.title, "How long this category’s history is retained. Choose Same as all to follow the shared retention setting; older records are deleted automatically.");
      row.appendChild(keep);
      // Every delete asks once more (VaultUI.confirmClick, as in every section).
      var del = deleteButton("Delete history", "history:" + c.key, function () {
        send({ kind: "delete", scope: "category", category: c.key });
      });
      row.appendChild(del);
      box.appendChild(row);
    });
    box.appendChild(feedsGroup(globalName));
    return box;
  }

  // Platform feeds (owner 2026-09-30): what the classifier records from each
  // platform's pages — everything shown, opened or not — to tag it. Only the
  // platforms that classify need it; each keeps "Keep all history" unless set.
  function feedsGroup(globalName) {
    var group = el("div", "feeds");
    group.appendChild(el("div", "feeds-title", "Platform feeds"));
    group.appendChild(el("p", "feeds-hint", "Record content shown on platform pages, whether opened or not. Local tagging is supported on the indicated platforms and requires feed recording to be on."));
    (platformFeeds.platforms || []).forEach(function (p) {
      var row = el("div", "settings-row");
      var name = el("span", "name");
      name.appendChild(el("span", null, p.name));
      name.appendChild(el("span", "feeds-meta", (p.classifies ? "Tagging supported" : "Tagging not supported") + " · " + p.entries + (p.entries === 1 ? " entry" : " entries")));
      row.appendChild(name);
      var rec = el("label"); var sw = el("input"); sw.type = "checkbox"; sw.checked = !!p.record;
      sw.addEventListener("change", function () { send({ kind: "collection-record", platformID: p.id, record: sw.checked }); });
      infoField(rec, "feed-record:" + p.id, "Record " + p.name, "Record content seen on this platform for the Classifier. Content is tagged only while its platform feed is recorded.");
      rec.appendChild(sw); rec.appendChild(document.createTextNode("Record")); row.appendChild(rec);
      var keep = el("label"); keep.appendChild(document.createTextNode("Keep"));
      keep.appendChild(keepSelect(typeof p.keepDays === "number" ? p.keepDays : -1, globalName.toLowerCase(), function (days) {
        send({ kind: "collection-keep", platformID: p.id, days: days });
      }));
      infoField(keep, "feed-keep:" + p.id, "Keep " + p.name, "How long this platform’s feed entries are retained. Choose Same as all to follow the shared retention setting; older entries are deleted automatically.");
      row.appendChild(keep);
      var del = deleteButton("Delete collected data", "feed:" + p.id, function () {
        send({ kind: "collection-clear", platformID: p.id });
      });
      del.disabled = !p.entries;
      row.appendChild(del);
      group.appendChild(row);
    });
    return group;
  }

  var NAVY = [30, 58, 138];
  function navy(alpha) { return "rgba(" + NAVY.join(",") + "," + alpha + ")"; }
  var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  var MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

  function svg(tag, attrs) {
    var node = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (var name in attrs) node.setAttribute(name, attrs[name]);
    return node;
  }

  // GitHub-style: one column per week (Monday on top), one square per day,
  // darker = more time.
  function dayMap(h, name, section) {
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
      hoverable(square, {
        title: DAY_NAMES[date.getDay()] + " " + MONTHS[date.getMonth()] + " " + date.getDate() + ", " + date.getFullYear(),
        color: level === 0 ? "#e8ecf2" : navy([0, 0.3, 0.5, 0.72, 1][level]),
        lines: [name + ": " + (seconds > 0 ? fmt(seconds) : "not used"),
          seconds > 0 ? share(seconds, max, "the busiest day") : null]
      });
      square.style.cursor = "pointer";
      square.addEventListener("click", function () { setRange(section, "since:" + dayStart(h.dayStartsMs[i])); });
      chart.appendChild(square);
    });
    var scroller = el("div", "map-scroll");
    scroller.appendChild(chart);
    wrap.appendChild(scroller);
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
  function pie(items, title, searchKey) {
    var wrap = el("div", "chart");
    wrap.appendChild(el("div", "chart-title", title || "Share"));
    var total = items.reduce(function (sum, entry) { return sum + entry.seconds; }, 0);
    if (!total) { wrap.appendChild(el("p", "empty", "Nothing in this range.")); return wrap; }
    var split = splitSlices(items, total);
    var slices = split.named.map(function (entry) {
      var label = entry.item.label || entry.item.key;
      return { label: label, entry: entry, seconds: entry.seconds, color: entry.item.color || colorOf(entry.item.colorIndex) };
    });
    if (split.otherSeconds > 0) {
      slices.push({
        label: "Other · " + split.other.length + (split.other.length === 1 ? " item" : " items"),
        other: split.other,
        seconds: split.otherSeconds,
        color: "#cbd5e1"
      });
    }
    function sliceInfo(slice) {
      var line = fmt(slice.seconds) + " · " + share(slice.seconds, total, "the total (" + fmt(total) + ")");
      if (slice.entry) return entryInfo(slice.entry, [line]);
      var list = slice.other.slice(0, 12).map(function (entry) {
        return [entry.item.label || entry.item.key, entry.nameOnly ? "outside sites" : fmt(entry.seconds)];
      });
      if (slice.other.length > 12) list.push(["and " + (slice.other.length - 12) + " more", ""]);
      var why = [];
      if (slice.other.some(function (entry) { return !entry.nameOnly; })) why.push("items under 2% each");
      if (slice.other.some(function (entry) { return entry.nameOnly; })) why.push("browsers' time outside recorded sites");
      return { title: slice.label, color: slice.color, lines: [line, why.join(", and ")], list: list };
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
      hoverable(shape, sliceInfo(slice));
      chart.appendChild(shape);
      angle = next;
    });
    var body = el("div", "pie-body");
    body.appendChild(chart);
    var legend = el("div", "pie-legend");
    searchable(legend, searchKey, "Search chart items", ".legend-item");
    slices.forEach(function (slice) {
      var item = el("div", "legend-item");
      item.dataset.vuiSearchText = slice.label;
      hoverable(item, sliceInfo(slice));
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

  // Group editor helpers.

  // An app's or website's name: from this range's rows, the editor's list,
  // or else its bundle id's last part / its domain.
  function memberLabel(id) {
    var entry = usageItemsRaw.filter(function (x) { return entryID(x) === id; })[0];
    if (entry) return entry.item.label || entry.item.key;
    var known = (knownItems || []).filter(function (item) { return item.id === id; })[0];
    if (known) return known.label;
    return id.indexOf("app|") === 0 ? id.slice(4).split(".").pop() : id.slice(4);
  }

  function saveGroup(group, move, request) {
    send({ kind: "group-save", group: { id: group.id || "", name: group.name, merge: !!group.merge, members: group.members }, move: !!move, request: request });
  }

  window.activityKnownItems = function (list, iconMap) {
    knownItems = list || [];
    knownIcons = iconMap || {};
    if (editing) refreshGroups();
  };

  // Mac Vault's answer to a save: saved (the snapshot follows), or refused —
  // a merge group's member already in another merge group can be moved.
  window.activityGroupSaved = function (answer) {
    var target = editing;
    if (answer.ok) { editing = null; return; }
    if (!target) return;
    target.message = answer.message || "Not saved.";
    target.conflicts = answer.conflicts || null;
    refreshGroups();
  };

  function openEditor(group) {
    editing = group
      ? { id: group.id, name: group.name, merge: group.merge, members: group.members.slice() }
      : { id: "", name: "", merge: false, members: [] };
    groupSearch = "";
    send({ kind: "known-items" });
    refreshGroups();
    var panel = scope.getElementById("groups");
    if (panel) panel.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }

  // The Groups panel (owner 2026-09-30): always shown, the page's top, one
  // fixed height; the groups side by side as cards (scrolling sideways), or
  // the editor in columns.
  function groupsPanel() {
    var box = el("section", "panel groups" + (editing ? " is-editing" : ""));
    box.id = "groups";
    box.dataset.editingId = editing ? editing.id : "";
    var head = el("div", "column-head");
    head.appendChild(el("h2", null, "Groups"));
    if (!editing) head.appendChild(textButton("New group", function () { openEditor(null); }, "head-button"));
    box.appendChild(head);
    if (editing) { box.appendChild(groupForm()); return box; }
    var list = groupsList().map(function (g) {
      var seconds = usageItemsRaw.reduce(function (sum, entry) {
        return g.members.indexOf(entryID(entry)) >= 0 ? sum + entry.seconds : sum;
      }, 0);
      return { g: g, seconds: seconds };
    }).sort(function (x, y) { return y.seconds - x.seconds; });   // merge or not, by time (owner 2026-09-30)
    if (!list.length) {
      box.appendChild(el("p", "empty", "No groups yet. A group shows its apps and websites together in Usage; a merge group also stands in for them everywhere."));
      return box;
    }
    var cards = el("div", "group-cards");
    searchable(cards, "activity-groups", "Search groups", ".group-card");
    var top = Math.max.apply(null, list.map(function (x) { return x.seconds; }).concat([1]));
    list.forEach(function (x) {
      var g = x.g;
      var card = el("div", usageFocus === "group|" + g.id ? "group-card is-focus" : "group-card");
      card.dataset.vuiSearchText = g.name;
      card.addEventListener("click", function () { pick("group|" + g.id); });
      var name = el("div", "group-card-top");
      name.appendChild(groupIcon(g));
      var label = el("div", "group-card-name");
      label.appendChild(el("span", "row-label", g.name));
      label.appendChild(el("span", "row-kind", g.merge ? "Merge" : "View"));
      name.appendChild(label);
      card.appendChild(name);
      var bar = el("div", "row-bar"), fill = paint(el("span"), g.colorIndex);
      fill.style.width = Math.max(1.5, x.seconds / top * 100) + "%";
      bar.appendChild(fill);
      card.appendChild(bar);
      var foot = el("div", "group-card-foot");
      foot.appendChild(el("span", null, g.members.length + (g.members.length === 1 ? " member" : " members") + " · " + fmt(x.seconds)));
      var edit = textButton("Edit", function (event) { event.stopPropagation(); openEditor(g); }, "secondary");
      foot.appendChild(edit);
      card.appendChild(foot);
      cards.appendChild(card);
    });
    box.appendChild(cards);
    return box;
  }

  // Redraw only the Groups panel (the editor's own changes).
  function refreshGroups() {
    var old = scope.getElementById("groups");
    if (old) {
      var searchFocus = window.VaultUI.captureSearch(scope);
      var focus = captureGroupFocus(old);
      var positions = captureGroupScrolls(old), next = groupsPanel();
      old.replaceWith(next);
      restoreGroupScrolls(next, positions);
      restoreGroupFocus(next, focus);
      window.VaultUI.restoreSearch(scope, searchFocus);
    }
  }

  function captureGroupFocus(panel) {
    var active = scope.activeElement;
    if (!panel || !panel.contains(active) || !active.dataset.groupField) return null;
    return { editingId: panel.dataset.editingId, field: active.dataset.groupField,
      start: active.selectionStart, end: active.selectionEnd, direction: active.selectionDirection };
  }

  function restoreGroupFocus(panel, focus) {
    if (!panel || !focus || panel.dataset.editingId !== focus.editingId) return;
    var input = panel.querySelector('[data-group-field="' + focus.field + '"]');
    if (!input) return;
    input.focus({ preventScroll: true });
    if (focus.start !== null) input.setSelectionRange(focus.start, focus.end, focus.direction);
  }

  function captureGroupScrolls(panel) {
    if (!panel) return null;
    var positions = { editingId: panel.dataset.editingId, lists: {} };
    ["group-cards", "group-selected-members", "group-members"].forEach(function (name) {
      var list = panel.querySelector("." + name);
      if (list) positions.lists[name] = [list.scrollLeft, list.scrollTop];
    });
    return positions;
  }

  function restoreGroupScrolls(panel, positions) {
    if (!panel || !positions || panel.dataset.editingId !== positions.editingId) return;
    Object.keys(positions.lists).forEach(function (name) {
      var list = panel.querySelector("." + name), position = positions.lists[name];
      if (list) { list.scrollLeft = position[0]; list.scrollTop = position[1]; }
    });
  }

  function groupForm() {
    var form = el("div", "group-form");
    var first = el("div", "group-col group-details"), second = el("div", "group-col"), third = el("div", "group-col group-add");
    form.appendChild(first); form.appendChild(second); form.appendChild(third);
    var top = el("div", "group-top");
    top.appendChild(groupIcon(editing, true));
    var name = el("input");
    name.type = "text";
    name.dataset.groupField = "name";
    name.placeholder = "Group name";
    name.value = editing.name;
    name.addEventListener("input", function () { editing.name = name.value; });
    top.appendChild(infoControl(name, "activity-group-name", "Group name", "The name shown for this Activity group. The change is saved when you click Save."));
    first.appendChild(top);
    var mergeRow = el("label", "group-merge");
    var merge = el("input");
    merge.type = "checkbox";
    merge.checked = editing.merge;
    merge.addEventListener("change", function () { editing.merge = merge.checked; });
    mergeRow.appendChild(merge);
    mergeRow.appendChild(document.createTextNode("Merge — show as one, in one color, everywhere"));
    infoField(mergeRow, "activity-group-merge", "Merge group", "Show the group’s members as one item with one shared color throughout Activity. A view group keeps each member separate. Saved when you click Save.");
    first.appendChild(mergeRow);

    var chips = el("div", "chips vui-list-box group-selected-members");
    searchable(chips, "activity-members:" + (editing.id || "new"), "Search selected members", ".chip");
    chips.tabIndex = 0;
    chips.setAttribute("aria-label", "Members");
    if (!editing.members.length) chips.appendChild(el("span", "vui-muted", "No members yet."));
    editing.members.forEach(function (id) {
      var chip = el("span", "chip");
      chip.dataset.vuiSearchText = memberLabel(id) + " " + id;
      chip.appendChild(icon(id.slice(4), memberLabel(id)));
      chip.appendChild(el("span", "chip-label", memberLabel(id)));
      chip.appendChild(el("span", "row-kind", id.indexOf("web|") === 0 ? "Website" : "App"));
      chip.appendChild(textButton("×", function () {
        editing.members = editing.members.filter(function (m) { return m !== id; });
        refreshGroups();
      }, "chip-remove"));
      chips.appendChild(chip);
    });
    second.appendChild(infoField(el("div", "chart-subtitle", "Members"), "activity-group-members", "Members", "The apps and websites included in this Activity group. Add from the search results or remove with the cross, then click Save."));
    second.appendChild(chips);

    var search = el("input");
    search.type = "search";
    search.dataset.groupField = "search";
    search.placeholder = "Add an app or website";
    search.value = groupSearch;
    third.appendChild(infoControl(search, "activity-member-search", "Find members", "Find an app or website to add to this Activity group."));
    var found = el("div", "group-members");
    function fill() {
      found.textContent = "";
      if (!knownItems) { found.appendChild(el("p", "empty", "Loading…")); return; }
      var q = groupSearch.trim().toLowerCase();
      var matches = knownItems.filter(function (item) {
        return editing.members.indexOf(item.id) < 0 && (!q || (item.label + " " + item.id).toLowerCase().indexOf(q) >= 0);
      }).slice(0, 60);
      if (!matches.length) found.appendChild(el("p", "empty", q ? "Nothing matches." : "Everything is in."));
      matches.forEach(function (item) {
        var line = el("button", "member-row");
        line.type = "button";
        line.appendChild(icon(item.id.slice(4), item.label));
        line.appendChild(el("span", "name", item.label));
        line.appendChild(el("span", "row-kind", item.id.indexOf("web|") === 0 ? "Website" : "App"));
        if (item.seconds) line.appendChild(el("span", "group-count", fmt(item.seconds)));
        line.addEventListener("click", function () {
          editing.members.push(item.id);
          refreshGroups();
          var again = scope.querySelector("#groups input[type=search]");
          if (again) again.focus();
        });
        found.appendChild(line);
      });
    }
    search.addEventListener("input", function () { groupSearch = search.value; fill(); });
    fill();
    third.appendChild(found);

    if (editing.message) {
      var note = el("div", "group-note", editing.message + ".");
      if (editing.conflicts) {
        note.appendChild(textButton("Move them here", function () { saveGroup(editing, true, "editor"); }, "secondary"));
      }
      first.appendChild(note);
    }
    var actions = el("div", "group-actions");
    actions.appendChild(textButton("Save", function () { editing.message = null; saveGroup(editing, false, "editor"); }));
    actions.appendChild(textButton("Cancel", function () { editing = null; refreshGroups(); }, "secondary"));
    if (editing.id) {
      var id = editing.id;
      var del = deleteButton("Delete group", "group:" + id, function () {
        editing = null;
        send({ kind: "group-delete", id: id });
      });
      actions.appendChild(del);
    }
    first.appendChild(actions);
    return form;
  }

  // ══ The page (owner 2026-09-30): Groups on top, then two stacked sections,
  // Usage and Content, each with its own range (Today / A week / A month /
  // since a custom date, picked in our date picker or on a year map) and its
  // own focus; Recording last, collapsed. Panels keep a fixed size and scroll
  // inside. "Empty" is every hour not used (all 24 h of a day). ══

  var UNTAGGED = { id: "", name: "Untagged", color: "#94a3b8" };
  var EMPTY_COLOR = "#e2e8f0";
  var OTHER_PAGES = { id: "other-pages", name: "Other pages", color: "#cbd5e1" };
  var PLATFORM_NAMES = { youtube: "YouTube", bilibili: "Bilibili", twitch: "Twitch", reddit: "Reddit",
    twitter: "X", instagram: "Instagram", facebook: "Facebook", discord: "Discord" };
  // The sites of the platforms content is recorded on (their pages that are
  // no one piece of content are "Other pages").
  var PLATFORM_SITES = [["youtube.com", "youtube"], ["bilibili.com", "bilibili"], ["twitch.tv", "twitch"], ["reddit.com", "reddit"],
    ["x.com", "twitter"], ["twitter.com", "twitter"], ["instagram.com", "instagram"], ["facebook.com", "facebook"], ["discord.com", "discord"]];
  // One colour per weekday (the authors' per-day segments).
  var WEEKDAY_COLORS = ["#d9656a", "#5b7fc7", "#e8914a", "#5fa86a", "#9b6fb0", "#6fb3ae", "#c79a3f"];
  var DAY_MS = 86400000;

  var ranges = { usage: "today", content: "today" };   // today | 7d | 30d | since:<ms>
  var USAGE_BLOCK_KEY = "adamancia.activity.usage-block-minutes";
  function savedBlockMinutes() {
    try {
      var stored = window.localStorage.getItem(USAGE_BLOCK_KEY);
      if (stored !== null) {
        var minutes = Number(stored);
        if (minutes === 0 || window.ActivityTimeBins.choices.indexOf(minutes) >= 0) return minutes;
      }
    } catch (_) {}
    return 30;
  }
  var usageBlockMinutes = savedBlockMinutes(); // 0 = exact sessions
  var usageFocus = "all";       // all | app|<key> | web|<key> | group|<id>
  var contentFocus = "all";     // all | tag|<id>
  var usageHistory = null;      // { map, days } for usageFocus over the range
  var contentYear = null;       // the content year map for contentFocus
  var tagNodes = [];            // the classifier's tags: { id, name, color, parentID }

  function dayStart(ms) { var d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime(); }
  function rangeDayStarts(snap) {
    var out = [];
    if (!snap) return out;
    var d = new Date(dayStart(snap.rangeStartMs));
    for (; d.getTime() <= snap.rangeEndMs; d.setDate(d.getDate() + 1)) out.push(d.getTime());
    return out;
  }
  function dayName(ms) {
    var d = new Date(ms);
    return dayStart(ms) === dayStart(Date.now()) ? "Today" : DAY_NAMES[d.getDay()] + " " + MONTHS[d.getMonth()] + " " + d.getDate();
  }

  // ── Usage ──

  function focusName(id) {
    if (id === "all") return "All usage";
    if (id.indexOf("group|") === 0) {
      var g = groupsList().filter(function (x) { return "group|" + x.id === id; })[0];
      return g ? g.name : "Group";
    }
    return memberLabel(id);
  }
  function pick(id) { setUsageFocus(id); }

  // The ids the usage focus covers (null = everything).
  function usageFocusSet() {
    if (usageFocus === "all") return null;
    if (usageFocus.indexOf("group|") === 0) {
      var g = groupsList().filter(function (x) { return "group|" + x.id === usageFocus; })[0];
      return new Set(g ? g.members : []);
    }
    return new Set([usageFocus]);
  }

  // The range's apps and sites (merge groups folded in unless one is focused).
  function usageData() {
    var apps = snapshot.app || { totalSeconds: 0, bars: [], timeline: [] };
    var web = snapshot.web || { totalSeconds: 0, bars: [], timeline: [] };
    var attribution = attributeSites(apps.timeline, web.timeline);
    var spanSeconds = (snapshot.rangeEndMs - snapshot.rangeStartMs) / 1000;
    usageItemsRaw = usageItems(apps.bars, web.bars, attribution, spanSeconds);
    var set = usageFocusSet();
    var items = set ? usageItemsRaw.filter(function (entry) { return set.has(entryID(entry)); }) : mergeItems(usageItemsRaw);
    usageItemsShown = items;
    var segments = apps.timeline.filter(function (s) { return !set || set.has("app|" + s.key); });
    var pieces = attribution.pieces.filter(function (p) { return !set || set.has("web|" + p.site.key) || set.has("app|" + p.browser.key); });
    // Time used: the apps in front (a browser's sites are inside its time).
    var used = set
      ? segments.reduce(function (sum, s) { return sum + s.seconds; }, 0)
        + pieces.filter(function (p) { return !set.has("app|" + p.browser.key); })
          .reduce(function (sum, p) { return sum + (p.to - p.from) * spanSeconds; }, 0)
      : apps.timeline.reduce(function (sum, s) { return sum + s.seconds; }, 0);
    return { items: items, segments: segments, pieces: pieces, used: used, empty: Math.max(0, spanSeconds - used) };
  }

  // A time strip over the whole range, one fixed width per day, scrolling
  // sideways when the range is long.
  function stripFrame(height, snap) {
    var days = rangeDayStarts(snap).length;
    var perDay = days <= 1 ? 0 : days <= 2 ? 720 : days <= 7 ? 360 : days <= 31 ? 200 : 110;
    var scroller = el("div", "strip-scroll");
    var track = el("div", "strip");
    track.style.height = height + "px";
    if (perDay) track.style.width = (days * perDay) + "px";
    var axis = el("div", "axis strip-axis");
    if (perDay) axis.style.width = (days * perDay) + "px";
    var span = snap.rangeEndMs - snap.rangeStartMs;
    if (days > 1) {
      rangeDayStarts(snap).forEach(function (start, i) {
        if (i > 0) { var line = el("div", "day"); line.style.left = ((start - snap.rangeStartMs) / span * 100) + "%"; track.appendChild(line); }
        var label = el("span", "strip-day", dayName(start));
        label.style.left = (Math.max(0, start - snap.rangeStartMs) / span * 100) + "%";
        axis.appendChild(label);
      });
    } else {
      axis.appendChild(el("span", null, clock(snap.rangeStartMs)));
      axis.appendChild(el("span", null, clock(snap.rangeEndMs)));
    }
    scroller.appendChild(track);
    scroller.appendChild(axis);
    return { node: scroller, track: track, span: span, multiDay: days > 1 };
  }

  function usageStrip(data) {
    var f = stripFrame(44, snapshot);
    data.segments.forEach(function (s) {
      var seg = paint(el("div", "seg"), colorIndexFor("app", s.key, s.colorIndex));
      place(seg, s.startFraction, s.startFraction + s.widthFraction);
      hoverable(seg, function () { return segmentInfo(s, BROWSERS[s.key] ? "App · browser" : "App", s.startedAtMs, s.startedAtMs + s.seconds * 1000, f.multiDay); });
      f.track.appendChild(seg);
    });
    data.pieces.forEach(function (piece) {
      var w = piece.site;
      var site = paint(el("div", "seg site"), colorIndexFor("web", w.key, w.colorIndex));
      place(site, piece.from, piece.to);
      hoverable(site, function () { return segmentInfo(w, "Website", snapshot.rangeStartMs + piece.from * f.span, snapshot.rangeStartMs + piece.to * f.span, f.multiDay, piece.browser); });
      f.track.appendChild(site);
    });
    return f.node;
  }

  // The colour map: every app and site in view with its colour and time,
  // and Empty. Clicking one focuses it.
  function colourMap(entries, empty, onPick, emptyLabel) {
    var box = el("div", "colour-map");
    searchable(box, emptyLabel === "Empty" ? "activity-usage-items" : "activity-content-tags", emptyLabel === "Empty" ? "Search apps and websites" : "Search tags", ".colour-row");
    entries.forEach(function (entry) {
      var line = el("button", "colour-row");
      line.dataset.vuiSearchText = (entry.item.label || "") + " " + (entry.item.key || "");
      line.type = "button";
      var swatch = el("span", "swatch");
      swatch.style.background = entry.item.color || colorOf(entry.item.colorIndex);
      line.appendChild(swatch);
      if (entry.item.key) line.appendChild(icon(entry.item.key, entry.item.label));
      line.appendChild(el("span", "colour-name", entry.item.label || entry.item.key));
      if (entry.kind && entry.kind !== "Tag") line.appendChild(el("span", "row-kind", entry.kind));
      line.appendChild(el("span", "colour-time", entry.nameOnly ? "" : fmt(entry.seconds)));
      hoverable(line, entryInfo(entry, [fmt(entry.seconds)]));
      if (onPick) line.addEventListener("click", function () { onPick(entry); });
      box.appendChild(line);
    });
    if (empty) {
      var row = el("div", "colour-row is-empty");
      var sw = el("span", "swatch"); sw.style.background = empty.color; row.appendChild(sw);
      row.appendChild(el("span", "colour-name", emptyLabel));
      row.appendChild(el("span", "colour-time", fmt(empty.seconds)));
      box.appendChild(row);
    }
    if (!entries.length && !empty) box.appendChild(el("p", "empty", "Nothing in this range."));
    return box;
  }

  // Per-day totals: stacked, largest first; `rest` tops each bar (Empty up to
  // the day's 24 h, or Other pages). Scrolls sideways when there are many days.
  // The two day graphs share one layout so their days line up (owner
  // 2026-09-30: the ordered graph above, the unordered totals below).
  function dayLayout(days, availableWidth) {
    // Use actual pixels in both axes. Scaling an 820 px SVG to fill a wide
    // window enlarged its height, labels and bars along with its width.
    var left = 44;
    var barGap = Math.max(days <= 7 ? 72 : 40,
      (Math.max(820, availableWidth) - left) / Math.max(1, days));
    return { days: days, barGap: barGap, width: left + days * barGap,
      left: left, barWidth: Math.min(days <= 7 ? 54 : 32, barGap * 0.6) };
  }
  function dayLabelText(start, days) {
    var date = new Date(start);
    return days > 14 ? String(date.getDate()) : dayName(start).replace(/^\w+ /, days > 7 ? "" : "$&");
  }

  // Unordered: each day's items stacked, largest first, `rest` on top.
  function dayTotalsChart(perDay, rest, fixedDayScale, layout) {
    var days = perDay.length;
    var width = layout.width, height = 210, left = layout.left, top = 8, bottom = 24, barGap = layout.barGap;
    var plot = height - top - bottom, base = height - bottom;
    var totals = perDay.map(function (d) { return d.items.reduce(function (s, e) { return s + e.seconds; }, 0) + (d.rest || 0); });
    var topSeconds = fixedDayScale ? 86400 : Math.max(3600, Math.max.apply(null, totals.concat([0])));
    var step = topSeconds > 12 * 3600 ? 6 * 3600 : topSeconds > 6 * 3600 ? 2 * 3600 : 3600;
    // Few days fill the width; many scroll sideways at a fixed spacing.
    var chart = svg("svg", { viewBox: "0 0 " + width + " " + height, width: width, height: height, class: "days" });
    for (var t = 0; t <= topSeconds + 1; t += step) {
      var y = base - (t / topSeconds) * plot;
      chart.appendChild(svg("line", { x1: left, x2: width, y1: y, y2: y, stroke: "#eef1f6", "stroke-width": 1 }));
      var label = svg("text", { x: 0, y: y + 3, class: "axis-label" });
      label.textContent = t === 0 ? "0" : (t / 3600) + "h";
      chart.appendChild(label);
    }
    var barWidth = layout.barWidth;
    perDay.forEach(function (d, i) {
      var x = left + i * barGap + (barGap - barWidth) / 2, yy = base;
      var dayTotal = totals[i];
      d.items.forEach(function (entry) {
        var h = entry.seconds / topSeconds * plot;
        yy -= h;
        var color = entry.item.color || colorOf(entry.item.colorIndex);
        var rect = svg("rect", { x: x, y: yy, width: barWidth, height: Math.max(0.6, h), fill: color });
        hoverable(rect, function () {
          var info = entryInfo(entry, [dayName(d.start), fmt(entry.seconds) + " · " + share(entry.seconds, dayTotal, "the day")]);
          info.color = color;
          return info;
        });
        chart.appendChild(rect);
      });
      if (d.rest > 0) {
        var h = d.rest / topSeconds * plot;
        yy -= h;
        var restRect = svg("rect", { x: x, y: yy, width: barWidth, height: h, fill: rest.color });
        hoverable(restRect, function () { return { title: rest.name, color: rest.color, lines: [dayName(d.start), fmt(d.rest)] }; });
        chart.appendChild(restRect);
      }
      var dl = svg("text", { x: x + barWidth / 2, y: height - 8, "text-anchor": "middle", class: "axis-label" });
      dl.textContent = dayLabelText(d.start, days);
      chart.appendChild(dl);
    });
    return chart;
  }

  // Ordered: each day on a 24-hour scale, 00:00 at the bottom — every block
  // at its time, the gaps empty. `narrow` blocks (sites inside a browser)
  // leave the browser's colour showing beside them.
  function dayOrderChart(perDay, layout, grouped, isUsage) {
    var days = perDay.length;
    var width = layout.width, height = isUsage ? 320 : 210, left = layout.left, top = 8, bottom = 24, barGap = layout.barGap;
    var plot = height - top - bottom, base = height - bottom, barWidth = layout.barWidth;
    var chart = svg("svg", { viewBox: "0 0 " + width + " " + height, width: width, height: height, class: "days" });
    [0, 6, 12, 18, 24].forEach(function (h) {
      var y = base - (h / 24) * plot;
      chart.appendChild(svg("line", { x1: left, x2: width, y1: y, y2: y, stroke: "#eef1f6", "stroke-width": 1 }));
      var label = svg("text", { x: 0, y: y + 3, class: "axis-label" });
      label.textContent = h + ":00";
      chart.appendChild(label);
    });
    perDay.forEach(function (d, i) {
      var x = left + i * barGap + (barGap - barWidth) / 2;
      chart.appendChild(svg("rect", { x: x, y: top, width: barWidth, height: plot, rx: 4, fill: "#f1f4f8" }));
      if (grouped) {
        (d.bins || []).forEach(function (bin) {
          var blockSeconds = usageBlockMinutes * 60;
          // Adjacent time slots meet exactly; a fixed gap would split even
          // uninterrupted usage into separate-looking strips.
          var y = base - bin.to * plot, h = (bin.to - bin.from) * plot;
          var info = function () {
            var shown = bin.items.slice(0, 7).map(function (item) { return [item.label, fmt(item.seconds)]; });
            if (bin.items.length > 7) shown.push(["More items", String(bin.items.length - 7) + " · choose Exact to inspect"]);
            return { title: hourMinute(bin.from) + " – " + hourMinute(bin.to),
              lines: [dayName(d.start), fmt(bin.usedSeconds) + " used · " + fmt(bin.idleSeconds) + " not recorded"], list: shown };
          };
          var background = svg("rect", { x: x, y: y, width: barWidth, height: h, fill: "#e5eaf1" });
          hoverable(background, info);
          chart.appendChild(background);
          // Keep the two largest identities; the remaining time is one
          // neutral aggregate so a busy block never becomes hairlines again.
          var prominent = bin.items.slice(0, 2), others = bin.items.slice(2);
          var pieces = prominent.map(function (item) { return { seconds: item.seconds, color: item.color }; });
          if (others.length) pieces.push({ seconds: others.reduce(function (sum, item) { return sum + item.seconds; }, 0), color: "#aeb9c8" });
          // Each interval retains the full day-column width. Stack its time
          // shares upward from the interval's start, leaving idle time above.
          var cursor = y + h;
          pieces.forEach(function (piece) {
            var pieceHeight = h * piece.seconds / blockSeconds;
            if (pieceHeight <= 0) return;
            cursor -= pieceHeight;
            var rect = svg("rect", { x: x, y: cursor, width: barWidth, height: pieceHeight, fill: piece.color });
            hoverable(rect, info);
            chart.appendChild(rect);
          });
        });
      } else {
        d.blocks.forEach(function (b) {
          var rect = svg("rect", { x: x, y: base - b.to * plot, width: barWidth * (b.narrow ? 0.85 : 1), height: Math.max(0.6, (b.to - b.from) * plot), fill: b.color });
          hoverable(rect, b.info);
          chart.appendChild(rect);
        });
      }
      var dl = svg("text", { x: x + barWidth / 2, y: height - 8, "text-anchor": "middle", class: "axis-label" });
      dl.textContent = dayLabelText(d.start, days);
      chart.appendChild(dl);
    });
    return chart;
  }

  // "Day by day": the ordered graph over the totals, scrolling together.
  var activeDayCharts = [];
  var chartResizePending = false;
  window.addEventListener("resize", function () {
    if (chartResizePending) return;
    chartResizePending = true;
    window.requestAnimationFrame(function () {
      chartResizePending = false;
      activeDayCharts = activeDayCharts.filter(function (entry) { return entry.node.isConnected; });
      activeDayCharts.forEach(function (entry) { entry.draw(); });
    });
  });
  function dayCharts(ordered, totals, rest, fixedDayScale, isUsage) {
    var box = el("div", "chart");
    box.appendChild(el("div", "chart-title", "Day by day"));
    var scroller = el("div", "totals-scroll");
    var toolbar = el("div", "day-chart-toolbar");
    toolbar.appendChild(el("div", "chart-subtitle", "Timeline"));
    if (isUsage) {
      var control = el("label", "block-length-control");
      control.appendChild(infoField(el("span", null, "Time interval"), "activity-time-interval", "Time interval", "Group timeline usage into vertical time intervals to reduce thin segments. Exact shows the original intervals. This changes the chart, not recorded usage."));
      var select = el("select");
      select.setAttribute("aria-label", "Activity time interval");
      [[0, "Exact"], [5, "5 min"], [15, "15 min"], [30, "30 min"], [60, "1 hour"]].forEach(function (choice) {
        var option = el("option", null, choice[1]);
        option.value = String(choice[0]);
        option.selected = choice[0] === usageBlockMinutes;
        select.appendChild(option);
      });
      select.addEventListener("change", function () {
        usageBlockMinutes = Number(select.value);
        try { window.localStorage.setItem(USAGE_BLOCK_KEY, String(usageBlockMinutes)); } catch (_) {}
        var target = scope.getElementById("usage-totals");
        if (!target) return;
        var old = target.querySelector(".totals-scroll"), oldLeft = old ? old.scrollLeft : 0;
        target.textContent = "";
        target.appendChild(usageTotals());
        window.requestAnimationFrame(function () {
          var next = target.querySelector(".totals-scroll");
          if (next) next.scrollLeft = oldLeft;
        });
      });
      control.appendChild(select);
      toolbar.appendChild(control);
    }
    scroller.appendChild(toolbar);
    var orderedSlot = el("div");
    scroller.appendChild(orderedSlot);
    scroller.appendChild(el("div", "chart-subtitle", "Totals"));
    var totalsSlot = el("div");
    scroller.appendChild(totalsSlot);
    box.appendChild(scroller);
    var drawnWidth = 0;
    function draw() {
      var layout = dayLayout(totals.length, scroller.clientWidth || 820);
      if (layout.width === drawnWidth && orderedSlot.firstChild) return;
      drawnWidth = layout.width;
      orderedSlot.textContent = "";
      orderedSlot.appendChild(dayOrderChart(ordered, layout, isUsage && usageBlockMinutes > 0, isUsage));
      totalsSlot.textContent = "";
      totalsSlot.appendChild(dayTotalsChart(totals, rest, fixedDayScale, layout));
    }
    draw();
    activeDayCharts.push({ node: box, draw: draw });
    window.requestAnimationFrame(function () {
      activeDayCharts = activeDayCharts.filter(function (entry) { return entry.node.isConnected; });
      if (box.isConnected) draw();
    });
    return box;
  }

  function hourMinute(fraction) {
    var minutes = Math.round(fraction * 1440);
    return Math.floor(minutes / 60) + ":" + String(minutes % 60).padStart(2, "0");
  }

  function usageTotals() {
    if (!usageHistory) {
      var loading = el("div", "chart");
      loading.appendChild(el("div", "chart-title", "Day by day"));
      loading.appendChild(el("p", "empty", "Loading…"));
      return loading;
    }
    var set = usageFocusSet();
    var now = Date.now();
    var ordered = [], totals = [];
    usageHistory.days.forEach(function (day) {
      var attribution = attributeSites(day.app, day.web);
      var raw = usageItems(barsOf(day.app), barsOf(day.web), attribution, 86400);
      var items = (set ? raw.filter(function (entry) { return set.has(entryID(entry)); }) : mergeItems(raw))
        .filter(function (entry) { return !entry.nameOnly && entry.seconds >= 1; })
        .sort(function (a, b) { return b.seconds - a.seconds; });
      var used = items.reduce(function (sum, e) { return sum + e.seconds; }, 0);
      var elapsed = Math.min(86400, Math.max(0, (now - day.dayStartMs) / 1000));
      totals.push({ start: day.dayStartMs, items: items, rest: Math.max(0, elapsed - used) });
      var blocks = [], binApps = [], binSites = [];
      day.app.forEach(function (seg) {
        if (set && !set.has("app|" + seg.key)) return;
        var color = colorOf(colorIndexFor("app", seg.key, seg.colorIndex));
        binApps.push({ key: seg.key, label: seg.label || seg.key, from: seg.startFraction, to: seg.startFraction + seg.widthFraction, color: color });
        blocks.push({ from: seg.startFraction, to: seg.startFraction + seg.widthFraction, color: color,
          info: function () { return { title: seg.label || seg.key, key: seg.key, lines: [(BROWSERS[seg.key] ? "App · browser" : "App") + " · " + dayName(day.dayStartMs),
            hourMinute(seg.startFraction) + " – " + hourMinute(seg.startFraction + seg.widthFraction) + " · " + fmt(seg.widthFraction * 86400)] }; } });
      });
      attribution.pieces.forEach(function (piece) {
        if (set && !set.has("web|" + piece.site.key) && !set.has("app|" + piece.browser.key)) return;
        var color = colorOf(colorIndexFor("web", piece.site.key, piece.site.colorIndex));
        binSites.push({ key: piece.site.key, label: piece.site.label || piece.site.key, browserKey: piece.browser.key,
          from: piece.from, to: piece.to, color: color });
        blocks.push({ from: piece.from, to: piece.to, narrow: true, color: color,
          info: function () { return { title: piece.site.label || piece.site.key, key: piece.site.key, lines: ["Website · in " + (piece.browser.label || piece.browser.key) + " · " + dayName(day.dayStartMs),
            hourMinute(piece.from) + " – " + hourMinute(piece.to) + " · " + fmt((piece.to - piece.from) * 86400)] }; } });
      });
      ordered.push({ start: day.dayStartMs, blocks: blocks,
        bins: usageBlockMinutes ? window.ActivityTimeBins.aggregate(binApps, binSites, usageBlockMinutes) : [] });
    });
    return dayCharts(ordered, totals, { name: "No recorded usage", color: EMPTY_COLOR }, true, true);
  }

  // A day's segments as bars (seconds per key).
  function barsOf(segments) {
    var by = {};
    segments.forEach(function (seg) {
      var bar = by[seg.key] || (by[seg.key] = { key: seg.key, label: seg.label, colorIndex: seg.colorIndex, seconds: 0 });
      bar.seconds += seg.widthFraction * 86400;
    });
    return Object.keys(by).map(function (k) { return by[k]; }).sort(function (x, y) { return y.seconds - x.seconds; });
  }

  function usageFocusSelect() {
    var select = el("select");
    var choices = [["all", "All usage"]];
    groupsList().forEach(function (g) { choices.push(["group|" + g.id, g.name + " · " + (g.merge ? "Merge group" : "View group")]); });
    usageItemsRaw.forEach(function (entry) { choices.push([entryID(entry), (entry.item.label || entry.item.key) + " · " + entry.kind]); });
    if (!choices.some(function (c) { return c[0] === usageFocus; })) choices.push([usageFocus, focusName(usageFocus)]);
    choices.forEach(function (c) { var o = el("option", null, c[1]); o.value = c[0]; o.selected = c[0] === usageFocus; select.appendChild(o); });
    select.addEventListener("change", function () { setUsageFocus(select.value); });
    return infoControl(select, "activity-usage-filter", "Usage filter", "Show all usage, one app or website, or an Activity group. Filtering does not change recorded history.");
  }

  function setUsageFocus(id) {
    usageFocus = id;
    usageHistory = null;
    renderSection("usage");
    if (!editing) refreshGroups();
    requestUsageHistory();
  }

  function usageSection(s) {
    var section = el("section", "panel act-section");
    var head = el("div", "section-head");
    head.appendChild(el("h2", null, "Usage"));
    head.appendChild(usageFocusSelect());
    head.appendChild(rangeTabs("usage"));
    var appsOn = s.appUsage && s.appUsage.enabled, webOn = s.webVisit && s.webVisit.enabled;
    if (!appsOn && !webOn) {
      section.appendChild(head);
      section.appendChild(notRecorded(["app-usage", "web-visit"]));
      return section;
    }
    var data = usageData();
    var summary = el("span", "section-summary");
    summary.appendChild(el("strong", null, fmt(data.used)));
    summary.appendChild(document.createTextNode(" used · " + fmt(data.empty) + " not recorded"));
    head.appendChild(summary);
    section.appendChild(head);
    section.appendChild(usageStrip(data));
    var grid = el("div", "act-grid");
    var mapPanel = el("div", "act-cell");
    mapPanel.appendChild(el("div", "chart-title", "Colors"));
    mapPanel.appendChild(colourMap(data.items, { seconds: data.empty, color: EMPTY_COLOR }, function (entry) {
      setUsageFocus(entryID(entry));
    }, "No recorded usage"));
    grid.appendChild(mapPanel);
    var pieCell = el("div", "act-cell");
    pieCell.appendChild(pie(data.items.filter(function (e) { return !e.nameOnly; }), "Share", "activity-usage-share"));
    grid.appendChild(pieCell);
    var year = el("div", "act-cell");
    year.id = "usage-year";
    fillYear(year, usageHistory && usageHistory.map, focusName(usageFocus), "usage");
    grid.appendChild(year);
    section.appendChild(grid);
    var totals = el("div", "act-wide");
    totals.id = "usage-totals";
    totals.appendChild(usageTotals());
    section.appendChild(totals);
    return section;
  }

  function fillYear(box, history, name, section) {
    box.textContent = "";
    if (!history) { box.appendChild(el("div", "chart-title", "Last 365 days")); box.appendChild(el("p", "empty", "Loading…")); return; }
    box.appendChild(dayMap(history, name, section));
    box.appendChild(el("p", "chart-note", "Choose a day to view activity from then until now."));
    [].forEach.call(box.querySelectorAll(".map-scroll"), scrollToNewest);
  }

  // ── Content ──

  function tagByID() {
    var map = {};
    tagNodes.forEach(function (n) { map[n.id] = n; });
    return map;
  }
  // A tag and every tag under it.
  function tagFamily(id) {
    var out = new Set([id]), grew = true;
    while (grew) {
      grew = false;
      tagNodes.forEach(function (n) { if (n.parentID && out.has(n.parentID) && !out.has(n.id)) { out.add(n.id); grew = true; } });
    }
    return out;
  }
  function contentFocusSet() { return contentFocus === "all" ? null : tagFamily(contentFocus.slice(4)); }
  function tagsOf(key) { return ((watchedFacts[key] || {}).tags || []).filter(function (t) { return t && t.id; }); }

  // The content in the range: pieces (with their tags) and the platforms'
  // other pages (their time not on any one piece).
  function contentData() {
    var set = contentFocusSet();
    var pieces = (contentSnap.watchedTimeline || []).map(function (s) {
      var tags = tagsOf(s.key);
      var shown = set ? tags.filter(function (t) { return set.has(t.id); }) : tags;
      return { seg: s, startMs: s.startedAtMs, endMs: s.startedAtMs + s.seconds * 1000, tags: shown.length ? shown : [UNTAGGED] };
    }).filter(function (p) { return !set || p.tags[0] !== UNTAGGED; });
    var other = [];
    if (!set) {
      var sites = (contentSnap.web && contentSnap.web.timeline || []).filter(function (w) {
        return PLATFORM_SITES.some(function (p) { return w.key === p[0] || w.key.endsWith("." + p[0]); });
      });
      sites.forEach(function (w) {
        var start = w.startedAtMs, end = w.startedAtMs + w.seconds * 1000;
        var cuts = pieces.filter(function (p) { return p.endMs > start && p.startMs < end; })
          .sort(function (a, b) { return a.startMs - b.startMs; });
        var cursor = start;
        cuts.forEach(function (p) {
          if (p.startMs > cursor) other.push({ startMs: cursor, endMs: Math.min(p.startMs, end), site: w });
          cursor = Math.max(cursor, p.endMs);
        });
        if (cursor < end) other.push({ startMs: cursor, endMs: end, site: w });
      });
    }
    // Tag totals: a piece with several tags gives each an equal share.
    var byTag = {};
    pieces.forEach(function (p) {
      var sec = (p.endMs - p.startMs) / 1000 / p.tags.length;
      p.tags.forEach(function (t) {
        var e = byTag[t.id] || (byTag[t.id] = { item: { key: "", label: t.name, color: t.color || "#94a3b8", tagID: t.id }, seconds: 0, kind: "Tag" });
        e.seconds += sec;
      });
    });
    var tagEntries = Object.keys(byTag).map(function (k) { return byTag[k]; }).sort(function (a, b) { return b.seconds - a.seconds; });
    var watched = pieces.reduce(function (sum, p) { return sum + (p.endMs - p.startMs) / 1000; }, 0);
    var otherSeconds = other.reduce(function (sum, o) { return sum + (o.endMs - o.startMs) / 1000; }, 0);
    return { pieces: pieces, other: other, tags: tagEntries, watched: watched, otherSeconds: otherSeconds };
  }

  function contentStrip(data) {
    var f = stripFrame(30, contentSnap);
    var fraction = function (ms) { return (ms - contentSnap.rangeStartMs) / f.span; };
    data.other.forEach(function (o) {
      var seg = el("div", "seg");
      seg.style.background = OTHER_PAGES.color;
      place(seg, fraction(o.startMs), fraction(o.endMs));
      hoverable(seg, function () { return { title: "Other pages", color: OTHER_PAGES.color, lines: [o.site.label || o.site.key, timeSpan(o.startMs, o.endMs, f.multiDay) + " · " + fmt((o.endMs - o.startMs) / 1000)] }; });
      f.track.appendChild(seg);
    });
    data.pieces.forEach(function (p) {
      var seg = el("div", "seg");
      seg.style.background = p.tags[0].color || "#94a3b8";
      place(seg, fraction(p.startMs), fraction(p.endMs));
      var fact = watchedFacts[p.seg.key] || {};
      hoverable(seg, function () { return { title: p.seg.label || p.seg.key, key: p.seg.key, lines: [
        (PLATFORM_NAMES[String(p.seg.key).split(":")[0]] || "") + (fact.creator ? " · " + fact.creator : ""),
        p.tags.map(function (t) { return t.name; }).join(", "),
        timeSpan(p.startMs, p.endMs, f.multiDay) + " · " + fmt((p.endMs - p.startMs) / 1000)] }; });
      f.track.appendChild(seg);
    });
    return f.node;
  }

  // Seconds of [startMs, endMs) falling on each range day.
  function splitByDay(startMs, endMs, starts, add) {
    starts.forEach(function (s, i) {
      var a = Math.max(startMs, s), b = Math.min(endMs, s + DAY_MS);
      if (b > a) add(i, (b - a) / 1000);
    });
  }

  function contentTotals(data) {
    var starts = rangeDayStarts(contentSnap);
    var perDay = starts.map(function (st) { return { start: st, byTag: {}, rest: 0 }; });
    var ordered = starts.map(function (st) { return { start: st, blocks: [] }; });
    var addBlock = function (startMs, endMs, color, info, narrow) {
      starts.forEach(function (st, i) {
        var a = Math.max(startMs, st), b = Math.min(endMs, st + DAY_MS);
        if (b > a) ordered[i].blocks.push({ from: (a - st) / DAY_MS, to: (b - st) / DAY_MS, color: color, info: info, narrow: narrow });
      });
    };
    data.other.forEach(function (o) {
      splitByDay(o.startMs, o.endMs, starts, function (i, sec) { perDay[i].rest += sec; });
      addBlock(o.startMs, o.endMs, OTHER_PAGES.color, function () { return { title: "Other pages", color: OTHER_PAGES.color, lines: [o.site.label || o.site.key, clock(o.startMs) + " – " + clock(o.endMs) + " · " + fmt((o.endMs - o.startMs) / 1000)] }; });
    });
    data.pieces.forEach(function (p) {
      splitByDay(p.startMs, p.endMs, starts, function (i, sec) {
        p.tags.forEach(function (t) {
          var e = perDay[i].byTag[t.id] || (perDay[i].byTag[t.id] = { item: { key: "", label: t.name, color: t.color || "#94a3b8" }, seconds: 0, kind: "Tag" });
          e.seconds += sec / p.tags.length;
        });
      });
      addBlock(p.startMs, p.endMs, p.tags[0].color || "#94a3b8", function () { return { title: p.seg.label || p.seg.key, key: p.seg.key, lines: [
        p.tags.map(function (t) { return t.name; }).join(", "),
        clock(p.startMs) + " – " + clock(p.endMs) + " · " + fmt((p.endMs - p.startMs) / 1000)] }; });
    });
    var totals = perDay.map(function (d) {
      return { start: d.start, rest: d.rest, items: Object.keys(d.byTag).map(function (k) { return d.byTag[k]; }).sort(function (a, b) { return b.seconds - a.seconds; }) };
    });
    return dayCharts(ordered, totals, OTHER_PAGES, false);
  }

  // Authors: total time, the bar split per day (one colour per weekday).
  function authorsList(data) {
    var box = el("div", "act-cell act-list");
    box.appendChild(el("div", "chart-title", "Content sources"));
    var legend = el("div", "chart-legend");
    ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].forEach(function (name, i) {
      var item = el("span", "legend-item"); var dot = el("span", "dot"); dot.style.background = WEEKDAY_COLORS[(i + 1) % 7];
      item.appendChild(dot); item.appendChild(el("span", null, name)); legend.appendChild(item);
    });
    box.appendChild(legend);
    var starts = rangeDayStarts(contentSnap);
    var by = {};
    data.pieces.forEach(function (p) {
      var fact = watchedFacts[p.seg.key] || {};
      var name = fact.creator || "Unknown source";
      var a = by[name] || (by[name] = { name: name, key: fact.creator ? "author|" + fact.creator : "", seconds: 0, days: starts.map(function () { return 0; }), items: 0 });
      a.items += 1;
      splitByDay(p.startMs, p.endMs, starts, function (i, sec) { a.days[i] += sec; a.seconds += sec; });
    });
    var authors = Object.keys(by).map(function (k) { return by[k]; }).sort(function (a, b) { return b.seconds - a.seconds; });
    var top = Math.max(1, authors.length ? authors[0].seconds : 1);
    var list = el("div", "scroll-list");
    searchable(list, "activity-authors", "Search content sources", ".author-row");
    authors.forEach(function (a) {
      var line = el("div", "author-row");
      line.dataset.vuiSearchText = a.name + " " + a.key;
      line.appendChild(icon(a.key, a.name));
      var body = el("div", "row-body");
      var name = el("div", "row-name");
      name.appendChild(el("span", "row-label", a.name));
      name.appendChild(el("span", "row-count", a.items + (a.items === 1 ? " item" : " items")));
      body.appendChild(name);
      var bar = el("div", "day-bar");
      bar.style.width = Math.max(2, a.seconds / top * 100) + "%";
      a.days.forEach(function (sec, i) {
        if (sec <= 0) return;
        var part = el("span");
        part.style.flex = String(sec);
        part.style.background = WEEKDAY_COLORS[new Date(starts[i]).getDay()];
        hoverable(part, { title: a.name, color: part.style.background, lines: [dayName(starts[i]), fmt(sec)] });
        bar.appendChild(part);
      });
      body.appendChild(bar);
      line.appendChild(body);
      line.appendChild(el("div", "row-time", fmt(a.seconds)));
      list.appendChild(line);
    });
    if (!authors.length) list.appendChild(el("p", "empty", "Nothing in this range."));
    box.appendChild(list);
    return box;
  }

  // Everything watched, newest first, with its platform, author and tags.
  function rawList(data) {
    var box = el("div", "act-cell act-list");
    box.appendChild(el("div", "chart-title", "Content viewed"));
    var list = el("div", "scroll-list");
    searchable(list, "activity-watched", "Search viewed content", ".raw-row");
    data.pieces.slice().sort(function (a, b) { return b.startMs - a.startMs; }).forEach(function (p) {
      var fact = watchedFacts[p.seg.key] || {};
      var line = el("div", "raw-row");
      line.dataset.vuiSearchText = (p.seg.label || "") + " " + p.seg.key + " " + (fact.creator || "") + " " + p.tags.map(function (tag) { return tag.name; }).join(" ");
      line.appendChild(icon(p.seg.key, p.seg.label));
      var body = el("div", "row-body");
      body.appendChild(el("div", "raw-title", p.seg.label || p.seg.key));
      var meta = el("div", "raw-meta");
      meta.appendChild(el("span", "row-kind", PLATFORM_NAMES[String(p.seg.key).split(":")[0]] || "Content"));
      meta.appendChild(el("span", null, fact.creator || "Unknown source"));
      meta.appendChild(el("span", "vui-muted", dayName(p.startMs) + " " + clock(p.startMs)));
      p.tags.forEach(function (t) {
        var chip = el("span", "tag-chip", t.name);
        chip.style.background = t.color || "#94a3b8";
        meta.appendChild(chip);
      });
      body.appendChild(meta);
      line.appendChild(body);
      line.appendChild(el("div", "row-time", fmt((p.endMs - p.startMs) / 1000)));
      list.appendChild(line);
    });
    if (!data.pieces.length) list.appendChild(el("p", "empty", "Nothing in this range."));
    box.appendChild(list);
    return box;
  }

  function contentFocusSelect() {
    var select = el("select");
    var choices = [["all", "All content"]];
    var depthOf = function (n) { var d = 0, seen = {}, cur = n, byID = tagByID(); while (cur && cur.parentID && byID[cur.parentID] && !seen[cur.id]) { seen[cur.id] = 1; cur = byID[cur.parentID]; d += 1; } return d; };
    // Tree order: each tag followed by the tags under it.
    var children = {};
    tagNodes.forEach(function (n) { (children[n.parentID || ""] = children[n.parentID || ""] || []).push(n); });
    (function walk(parent) {
      (children[parent] || []).forEach(function (n) {
        choices.push(["tag|" + n.id, new Array(depthOf(n) + 1).join("   ") + n.name]);
        walk(n.id);
      });
    })("");
    choices.forEach(function (c) { var o = el("option", null, c[1]); o.value = c[0]; o.selected = c[0] === contentFocus; select.appendChild(o); });
    select.addEventListener("change", function () { setContentFocus(select.value); });
    return infoControl(select, "activity-content-filter", "Content filter", "Show all viewed content or content with the selected tag. Filtering does not change recorded history.");
  }

  function setContentFocus(id) {
    contentFocus = id;
    contentYear = null;
    renderSection("content");
    requestContentHistory();
  }

  function contentSection(s) {
    var section = el("section", "panel act-section");
    var head = el("div", "section-head");
    head.appendChild(el("h2", null, "Content"));
    head.appendChild(contentFocusSelect());
    head.appendChild(rangeTabs("content"));
    if (!(s.contentWatched && s.contentWatched.enabled)) {
      section.appendChild(head);
      section.appendChild(notRecorded(["content-watched"]));
      return section;
    }
    var data = contentData();
    var summary = el("span", "section-summary");
    summary.appendChild(el("strong", null, fmt(data.watched)));
    summary.appendChild(document.createTextNode(" on content" + (contentFocus === "all" ? " · " + fmt(data.otherSeconds) + " other pages" : "")));
    head.appendChild(summary);
    section.appendChild(head);
    section.appendChild(contentStrip(data));
    var grid = el("div", "act-grid");
    var mapCell = el("div", "act-cell");
    mapCell.appendChild(el("div", "chart-title", "Tags"));
    mapCell.appendChild(colourMap(data.tags, contentFocus === "all" ? { seconds: data.otherSeconds, color: OTHER_PAGES.color } : null, function (entry) {
      if (entry.item.tagID) setContentFocus("tag|" + entry.item.tagID);
    }, "Other pages"));
    grid.appendChild(mapCell);
    var pieCell = el("div", "act-cell");
    pieCell.appendChild(pie(data.tags, "Share", "activity-content-share"));
    grid.appendChild(pieCell);
    var year = el("div", "act-cell");
    year.id = "content-year";
    fillYear(year, contentYear, contentFocus === "all" ? "All content" : (tagByID()[contentFocus.slice(4)] || { name: "Tag" }).name, "content");
    grid.appendChild(year);
    section.appendChild(grid);
    var totals = el("div", "act-wide");
    totals.appendChild(contentTotals(data));
    section.appendChild(totals);
    var lists = el("div", "act-grid two");
    lists.appendChild(authorsList(data));
    lists.appendChild(rawList(data));
    section.appendChild(lists);
    return section;
  }

  // ── The page ──

  function render() {
    var page = scope.getElementById("page");
    var searchFocus = window.VaultUI.captureSearch(scope);
    var groupFocus = captureGroupFocus(scope.getElementById("groups"));
    var groupScrolls = captureGroupScrolls(scope.getElementById("groups"));
    // Panels that scroll keep their place across updates.
    var scrolls = {};
    [].forEach.call(page.querySelectorAll(".scroll-list, .colour-map, .strip-scroll, .totals-scroll, .map-scroll"), function (node, i) { scrolls[i] = [node.scrollLeft, node.scrollTop]; });
    page.textContent = "";
    if (!snapshot) { page.appendChild(el("p", "empty", "Loading…")); return; }
    refreshMergeMap();
    var s = snapshot.settings || {};
    var usage = usageSection(s); usage.id = "usage-section";
    page.appendChild(groupsPanel());
    restoreGroupScrolls(scope.getElementById("groups"), groupScrolls);
    page.appendChild(usage);
    var content = contentSection(s); content.id = "content-section"; page.appendChild(content);
    // Recording: always last, one collapsed line (owner 2026-09-30).
    var recording = el("div", "panel settings-panel");
    recording.appendChild(settingsPanel(s));
    page.appendChild(recording);
    [].forEach.call(page.querySelectorAll(".scroll-list, .colour-map, .strip-scroll, .totals-scroll, .map-scroll"), function (node, i) {
      var section = node.closest("#content-section") ? "content" : "usage";
      if (scrolls[i] && !freshScroll[section]) { node.scrollLeft = scrolls[i][0]; node.scrollTop = scrolls[i][1]; }
      else scrollToNewest(node);
    });
    freshScroll = { usage: false, content: false };
    restoreGroupFocus(scope.getElementById("groups"), groupFocus);
    window.VaultUI.restoreSearch(scope, searchFocus);
  }

  // The range's days, as Mac Vault answers them (at most a year).
  function historyDays() { return Math.max(1, Math.min(365, rangeDayStarts(snapshot).length)); }

  // A new range (or first view) opens the time charts at the newest day.
  var freshScroll = { usage: true, content: true };
  function scrollToNewest(node) {
    if (node.matches(".strip-scroll, .totals-scroll, .map-scroll")) node.scrollLeft = node.scrollWidth;
  }

  // A focus change redraws only its own section (the other keeps its place).
  function renderSection(name) {
    var old = scope.getElementById(name + "-section");
    if (!old || !snapshot) { render(); return; }
    var s = snapshot.settings || {};
    var fresh = name === "usage" ? usageSection(s) : contentSection(s);
    fresh.id = name + "-section";
    var searchFocus = window.VaultUI.captureSearch(scope);
    old.replaceWith(fresh);
    window.VaultUI.restoreSearch(scope, searchFocus);
    [].forEach.call(fresh.querySelectorAll(".strip-scroll, .totals-scroll, .map-scroll"), scrollToNewest);
  }

  function requestUsageHistory() {
    send({ kind: "history", section: "usage", pick: usageFocus, barDays: historyDays() });
  }
  function contentPick() {
    var set = contentFocusSet();
    return set ? "tag|" + Array.from(set).join(",") : "all";
  }
  function requestContentHistory() {
    send({ kind: "history", section: "content", pick: contentPick() });
  }

  window.activityHistory = function (request, data) {
    if (request.section === "content") {
      if (request.pick !== contentPick()) return;
      contentYear = data;
      var box = scope.getElementById("content-year");
      if (box) fillYear(box, contentYear, contentFocus === "all" ? "All content" : (tagByID()[contentFocus.slice(4)] || { name: "Tag" }).name, "content");
      return;
    }
    if (request.pick !== usageFocus || request.barDays !== historyDays()) return;
    usageHistory = data;
    var year = scope.getElementById("usage-year");
    if (year) fillYear(year, usageHistory.map, focusName(usageFocus), "usage");
    var totals = scope.getElementById("usage-totals");
    if (totals) { totals.textContent = ""; totals.appendChild(usageTotals()); [].forEach.call(totals.querySelectorAll(".totals-scroll"), scrollToNewest); }
  };

  // A section's range (owner 2026-09-30): Today / A week / A month (rolling)
  // or Custom date — from a day picked in the date picker (or on a year map)
  // up to now.
  var RANGES = [["today", "Today"], ["7d", "A week"], ["30d", "A month"]];
  function setRange(section, value) {
    closePicker();
    ranges[section] = value;
    freshScroll[section] = true;
    if (section === "usage") usageHistory = null;
    send({ kind: "range", section: section, range: value });
  }
  function rangeTabs(section) {
    var tabs = el("div", "vui-tabs range-tabs");
    infoField(tabs, "activity-range:" + section, "Date range", "Choose a rolling date range or a custom starting day. Custom date shows history from that day until now.");
    var current = ranges[section];
    RANGES.forEach(function (r) {
      var b = textButton(r[1], function () { setRange(section, r[0]); }, "vui-tab");
      b.classList.toggle("is-active", current === r[0]);
      tabs.appendChild(b);
    });
    var since = current.indexOf("since:") === 0 ? +current.slice(6) : null;
    var custom = textButton(since ? "Since " + shortDate(since) : "Custom date", function () { openPicker(custom, section); }, "vui-tab");
    custom.classList.toggle("is-active", !!since);
    tabs.appendChild(custom);
    return tabs;
  }
  function shortDate(ms) {
    var d = new Date(ms);
    return MONTHS[d.getMonth()] + " " + d.getDate() + (d.getFullYear() !== new Date().getFullYear() ? ", " + d.getFullYear() : "");
  }

  // ── The date picker: a month of days (Monday first); any past day. ──
  var picker = null;           // { node, section, month (ms of its 1st) }
  function openPicker(anchor, section) {
    if (picker && picker.section === section) { closePicker(); return; }
    closePicker();
    var current = ranges[section].indexOf("since:") === 0 ? +ranges[section].slice(6) : Date.now();
    var first = new Date(current); first.setDate(1); first.setHours(0, 0, 0, 0);
    picker = { node: el("div", "date-picker"), section: section, month: first.getTime(), anchor: anchor };
    scope.getElementById("activity").appendChild(picker.node);
    drawPicker();
  }
  function closePicker() {
    if (picker) { picker.node.remove(); picker = null; }
  }
  function shiftMonth(by) {
    var d = new Date(picker.month); d.setMonth(d.getMonth() + by);
    var now = new Date(); now.setDate(1); now.setHours(0, 0, 0, 0);
    picker.month = Math.min(d.getTime(), now.getTime());
    drawPicker();
  }
  function drawPicker() {
    var box = picker.node, month = new Date(picker.month), today = dayStart(Date.now());
    var chosen = ranges[picker.section].indexOf("since:") === 0 ? +ranges[picker.section].slice(6) : null;
    box.textContent = "";
    var head = el("div", "picker-head");
    head.appendChild(textButton("«", function () { shiftMonth(-12); }, "picker-nav"));
    head.appendChild(textButton("‹", function () { shiftMonth(-1); }, "picker-nav"));
    head.appendChild(el("span", "picker-title", MONTH_NAMES[month.getMonth()] + " " + month.getFullYear()));
    var thisMonth = new Date(); thisMonth.setDate(1); thisMonth.setHours(0, 0, 0, 0);
    var atNow = picker.month >= thisMonth.getTime();
    var next = textButton("›", function () { shiftMonth(1); }, "picker-nav"); next.disabled = atNow;
    var nextYear = textButton("»", function () { shiftMonth(12); }, "picker-nav"); nextYear.disabled = atNow;
    head.appendChild(next); head.appendChild(nextYear);
    box.appendChild(head);
    var grid = el("div", "picker-grid");
    ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"].forEach(function (d) { grid.appendChild(el("span", "picker-weekday", d)); });
    var lead = (month.getDay() + 6) % 7;
    for (var i = 0; i < lead; i++) grid.appendChild(el("span"));
    var d = new Date(month);
    for (; d.getMonth() === month.getMonth(); d.setDate(d.getDate() + 1)) {
      (function (ms) {
        var b = textButton(String(new Date(ms).getDate()), function () { setRange(picker.section, "since:" + ms); }, "picker-day");
        if (ms > today) b.disabled = true;
        if (ms === today) b.classList.add("is-today");
        if (ms === chosen) b.classList.add("is-chosen");
        grid.appendChild(b);
      })(d.getTime());
    }
    box.appendChild(grid);
    box.appendChild(el("div", "picker-note", "From the selected day until now."));
    var r = picker.anchor.getBoundingClientRect();
    box.style.top = (r.bottom + 6) + "px";
    box.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 268)) + "px";
  }
  scope.addEventListener("mousedown", function (e) {
    if (!picker) return;
    var path = e.composedPath();
    if (path.indexOf(picker.node) < 0 && path.indexOf(picker.anchor) < 0) closePicker();
  });
  scope.addEventListener("keydown", function (e) { if (e.key === "Escape") closePicker(); });
  scope.getElementById("page").parentNode.addEventListener("scroll", closePicker);

  window.activityApply = function (data, iconMap, facts, feeds, tags, content) {
    closePicker();
    snapshot = data;
    contentSnap = content || data;
    platformFeeds = feeds || {};
    tagNodes = tags || [];
    icons = iconMap || {};
    watchedFacts = facts || {};
    // A watched piece, and its author's row, show the author's icon.
    Object.keys(watchedFacts).forEach(function (key) {
      var fact = watchedFacts[key];
      if (!fact.creatorIcon) return;
      icons[key] = fact.creatorIcon;
      if (fact.creator) icons["author|" + fact.creator] = fact.creatorIcon;
    });
    render();
    requestUsageHistory();
    requestContentHistory();
  };

  window.VaultUI.observe(scope);
  window.VaultInfo.watch(scope, { selector: ".feeds-hint,.chart-note,.picker-note" });
  send({ kind: "ready" });
})();
