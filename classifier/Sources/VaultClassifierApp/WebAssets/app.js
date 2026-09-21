(() => {
  "use strict";

  const root = document.getElementById("app");
  const navigationWidthStorageKey = "vaultClassifier.navigationPanelWidth";
  const navigationWidthRange = { minimum: 236, maximum: 460, fallback: 300 };
  const strings = window.VaultClassifierStrings || {};
  const languageChoices = [
    ["en", "language.name.en"],
    ["ar", "language.name.ar"],
    ["bn", "language.name.bn"],
    ["de", "language.name.de"],
    ["es", "language.name.es"],
    ["fr", "language.name.fr"],
    ["hi", "language.name.hi"],
    ["id", "language.name.id"],
    ["it", "language.name.it"],
    ["ja", "language.name.ja"],
    ["ko", "language.name.ko"],
    ["nl", "language.name.nl"],
    ["pa", "language.name.pa"],
    ["pl", "language.name.pl"],
    ["pt", "language.name.pt"],
    ["ru", "language.name.ru"],
    ["th", "language.name.th"],
    ["tr", "language.name.tr"],
    ["vi", "language.name.vi"],
    ["zh", "language.name.zh"],
  ];
  let state = null;
  let renderedPresentationRevision = 0;
  let activeTagPanel = null;
  // Advanced local-model settings disclosure. Toggled without a re-render so
  // the CSS grid transition can play; re-renders rebuild from this flag.
  let advancedSettingsOpen = false;
  // Per-type local-model request overrides have their own disclosure state;
  // they must not expand/collapse the app-wide engine settings modal.
  let localModelAdvancedOpen = false;
  // Per-type research defaults have a separate disclosure for the same reason.
  let researchAdvancedOpen = false;
  let tagDrag = null;
  let suppressTagClick = false;
  let connectionSource = null;
  let selectedTagNode = null;
  const layoutTraceSignatures = new Map();
  const treeViewportPositions = new Map();
  const editorViewportPositions = new Map();
  const pendingTagRenames = new Map();
  const collapsedCollectionCreatorLists = new Set();
  const selectedCollectionCreatorByPlatform = new Map();
  // The snapshot carries only the creator-level primary list. A chosen
  // creator's full entries are fetched on demand and cached here (keyed
  // datasetID|platformID|creatorID); the pending set guards in-flight requests.
  const loadedCreatorEntries = new Map();
  const pendingCreatorEntryRequests = new Set();
  // Per-platform lookup (platformID -> Map(normalized tag name -> tree node))
  // used to color platform-supplied tags (YouTube hashtags, Reddit flair) with
  // the matching tag-tree tag's color. Rebuilt whenever the collection workspace
  // renders; the detail pane reads it during its targeted refreshes too.
  const suppliedTagNodeByPlatform = new Map();
  let pendingDeletion = null;
  // Non-null while the "create a group" dialog is open: { presetID, platformID }.
  // A group can only be created through this dialog, and only from a preset.
  let pendingCreateType = null;
  let utilityPanel = null;
  // Which classifier type is open in the left-panel list (client-only UI state).
  let selectedTypeID = null;
  // Which trash entry's recover/delete panel is expanded in the left panel.
  let selectedTrashID = null;
  // Set to the pre-create set of type ids when "New type" is clicked, so the
  // next snapshot can open the freshly created type.
  let pendingSelectNewType = null;
  let selectedLanguage = "en";
  let navigationPanelWidth = navigationWidthRange.fallback;
  let navigationResize = null;
  const collectionRowHeight = 48;
  const workspaceNames = new Set(["tagTree", "llmAssist", "browserBridge", "classificationData", "knowledge"]);
  const virtualLists = new Map();
  const virtualListScrollByKey = new Map();
  let virtualListSequence = 0;
  let virtualListResizeObserver = null;
  const keyedListRegistry = new Map();
  const keyedListRenderedRows = new Map();
  const liveHTMLRegistry = new Map();
  const liveHTMLRendered = new Map();
  // List search: raw query text per search group (persists across re-renders so a
  // background snapshot push never wipes what the user typed), debounce timers,
  // and a per-item normalized-haystack cache (WeakMap auto-clears when the
  // snapshot rebuilds the item objects).
  const listSearchQueryByGroup = new Map();
  const listSearchTimers = new Map();
  const searchHaystackCache = new WeakMap();
  // Minimum fraction of a query's trigrams that must appear in a candidate for
  // the typo-tolerant fallback to accept it. Raise toward 1 for stricter, lower
  // toward 0 for more forgiving.
  const trigramMatchThreshold = 0.5;
  let lastRenderedMarkup = null;

  try {
    const storedLanguage = window.localStorage.getItem("vaultClassifier.language");
    if (languageChoices.some(([identifier]) => identifier === storedLanguage)) selectedLanguage = storedLanguage;
  } catch (_) {}
  try {
    const storedWidth = Number(window.localStorage.getItem(navigationWidthStorageKey));
    if (Number.isFinite(storedWidth)) {
      navigationPanelWidth = Math.round(Math.min(navigationWidthRange.maximum, Math.max(navigationWidthRange.minimum, storedWidth)));
    }
  } catch (_) {}
  document.documentElement.lang = selectedLanguage;

  function applyNavigationPanelWidth() {
    root.style.setProperty("--navigation-panel-width", `${navigationPanelWidth}px`);
    root.querySelector("[data-navigation-resizer]")?.setAttribute("aria-valuenow", String(navigationPanelWidth));
  }

  const esc = (value) => String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");

  const normalizedTagColor = (value) => (
    typeof value === "string" && /^#[0-9a-f]{6}$/i.test(value)
      ? value.toUpperCase()
      : ""
  );

  // Fold a tag label to a match key: strip a leading hashtag and case/space so a
  // YouTube "#Minecraft" or a tree "minecraft" node compare equal.
  function normalizeTagName(value) {
    return (value == null ? "" : String(value)).trim().replace(/^#+/, "").toLowerCase();
  }

  function tagColorStyle(node) {
    const lightColor = normalizedTagColor(node?.lightColorHex);
    const darkColor = normalizedTagColor(node?.darkColorHex);
    return lightColor && darkColor
      ? `--tag-color-light:${lightColor};--tag-color-dark:${darkColor}`
      : "";
  }

  function tagPill(node, className = "") {
    if (!node) return "";
    const colorStyle = tagColorStyle(node);
    if (!colorStyle) return "";
    return `<span class="tag-pill${className ? ` ${esc(className)}` : ""}" style="${colorStyle}">${esc(node.name)}</span>`;
  }

  function tagPhrase(key, node) {
    const marker = "__VAULT_TAG__";
    const phrase = t(key, { tag: marker });
    const markerIndex = phrase.indexOf(marker);
    if (markerIndex < 0) return `${esc(phrase)} ${tagPill(node, "compact")}`;
    return `${esc(phrase.slice(0, markerIndex))}${tagPill(node, "compact")}${esc(phrase.slice(markerIndex + marker.length))}`;
  }

  function t(key, values = {}) {
    const template = strings[key];
    if (typeof template !== "string") return key;
    return template.replace(/\{([a-zA-Z0-9_]+)\}/g, (_, name) => String(values[name] ?? ""));
  }

  const tx = (key, values = {}) => esc(t(key, values));
  const percent = (value) => `${Math.round(Number(value || 0) * 100)}%`;
  const modelSizeGB = (bytes) => {
    const gigabytes = Math.max(0, Number(bytes) || 0) / 1_000_000_000;
    return gigabytes < 1 ? gigabytes.toFixed(2) : gigabytes.toFixed(1);
  };
  const selected = (value, expected) => value === expected ? " selected" : "";
  const checked = (value) => value ? " checked" : "";
  const disabled = (value) => value ? " disabled" : "";
  const enumText = (family, value) => Object.hasOwn(strings, `enum.${family}.${value}`)
    ? t(`enum.${family}.${value}`)
    : String(value ?? "").replaceAll(/([A-Z])/g, " $1").replaceAll(/[._-]/g, " ").replace(/^./, (letter) => letter.toUpperCase());

  document.title = t("app.title");

  function send(action, data = {}) {
    const handler = window.webkit?.messageHandlers?.vaultClassifier;
    if (handler) handler.postMessage({ action, data });
  }

  function collect(formID) {
    const form = root.querySelector(`[data-form-id="${formID}"]`);
    const values = {};
    if (!form) return values;
    form.querySelectorAll("[data-field]").forEach((control) => {
      if (control.type === "radio" && !control.checked) return;
      values[control.dataset.field] = control.type === "checkbox"
        ? control.checked
        : control.multiple
          ? Array.from(control.selectedOptions).map((option) => option.value)
          : control.value;
    });
    return values;
  }

  function providerConnectionPayload(values, formID) {
    const protocolConfiguration = {};
    Object.entries(values).forEach(([key, value]) => {
      if (key.startsWith("protocol.")) protocolConfiguration[key.slice("protocol.".length)] = value;
    });
    const payload = {
      credential: values.credential || "",
      customEndpoint: values.customEndpoint,
      testModelIdentifier: values.testModelIdentifier,
      protocolConfiguration,
    };
    return payload;
  }

  // Clears the per-render registries that shell() repopulates. Because the
  // sequences reset to 0, identical markup re-registers with identical ids —
  // which is what lets the render() fast path keep the existing DOM's observers
  // valid. Observers are disconnected only on a full rebuild (in render()).
  function resetDeferredRendering() {
    virtualLists.clear();
    keyedListRegistry.clear();
    liveHTMLRegistry.clear();
    virtualListSequence = 0;
  }

  // Windowed list: renders only the rows in (or near) the visible box, so DOM
  // and paint cost stay constant regardless of total row count. Rows must be a
  // single fixed height (rowHeight). A stable `key` preserves scroll position
  // across full re-renders.
  // Fold a raw string to a comparable form: strip diacritics and invisible
  // bidi/zero-width controls (creator names carry both), lowercase, and collapse
  // whitespace. CJK and digits pass through unchanged.
  function normalizeSearch(value) {
    return (value == null ? "" : String(value))
      .normalize("NFKD")
      .replace(/[̀-ͯ]/g, "")
      .replace(/[​-‏‪-‮⁦-⁩﻿]/g, "")
      .toLowerCase()
      .replace(/\s+/g, " ")
      .trim();
  }

  // Score one already-normalized haystack against a normalized, non-empty query.
  // Exact substring tiers (exact/prefix/word-prefix/contained) always outrank the
  // trigram-similarity fallback, so an exact match is never buried. The fallback
  // only fires for longer, typo'd queries with no substring hit; there is no
  // loose subsequence "scatter" matching. Returns -1 for no match.
  function searchScore(haystack, query) {
    const idx = haystack.indexOf(query);
    if (idx === 0) return haystack.length === query.length ? 1200 : 1000;
    if (idx > 0) return haystack[idx - 1] === " " ? 700 : 500 - Math.min(idx, 200);
    // Trigram fallback needs >= 2 shingles (query length >= 4) to offer real typo
    // tolerance. Its score stays strictly below the substring floor (300), so it
    // only ever appears beneath exact hits.
    if (query.length < 4) return -1;
    const coverage = trigramCoverage(haystack, query);
    if (coverage < trigramMatchThreshold) return -1;
    return Math.round(50 + coverage * 150);
  }

  // Fraction of the query's distinct overlapping 3-grams that occur as substrings
  // of the haystack. Trigram overlap requires real contiguous 3-char runs, so —
  // unlike subsequence matching — it never rewards arbitrarily scattered
  // characters, only genuine near-substring similarity (typos, transpositions).
  function trigramCoverage(haystack, query) {
    const grams = new Set();
    for (let i = 0; i + 3 <= query.length; i += 1) grams.add(query.slice(i, i + 3));
    if (grams.size < 2) return 0;
    let hit = 0;
    grams.forEach((gram) => { if (haystack.indexOf(gram) >= 0) hit += 1; });
    return hit / grams.size;
  }

  function searchHaystack(item, searchOf) {
    let hay = searchHaystackCache.get(item);
    if (hay === undefined) {
      hay = normalizeSearch(searchOf(item));
      if (item !== null && typeof item === "object") searchHaystackCache.set(item, hay);
    }
    return hay;
  }

  // Filter + rank items by relevance for a raw query. Empty query returns the
  // input untouched (stable original order). O(N·L) — fine for the few-thousand
  // rows these lists hold; no index needed below ~50k.
  function rankItems(items, searchOf, rawQuery) {
    const query = normalizeSearch(rawQuery);
    if (!query) return items;
    const scored = [];
    for (const item of items) {
      const score = searchScore(searchHaystack(item, searchOf), query);
      if (score >= 0) scored.push([score, item]);
    }
    scored.sort((lhs, rhs) => rhs[0] - lhs[0]);
    return scored.map(([, item]) => item);
  }

  function listSearchBox(group, placeholderKey) {
    const query = listSearchQueryByGroup.get(group) || "";
    return `<div class="list-search"><span class="list-search-icon" aria-hidden="true">⌕</span><input type="search" class="list-search-input" data-list-search="${esc(group)}" value="${esc(query)}" placeholder="${esc(tx(placeholderKey))}" aria-label="${esc(tx(placeholderKey))}" autocomplete="off" autocapitalize="off" spellcheck="false" enterkeyhint="search"><span class="list-search-count" data-list-search-count="${esc(group)}"></span></div>`;
  }

  function listSearchGroupContainers(group) {
    return [...root.querySelectorAll("[data-search-group]")].filter((container) => container.dataset.searchGroup === group);
  }

  function listSearchRegistry(container) {
    return container.dataset.virtualList
      ? virtualLists.get(container.dataset.virtualList)
      : keyedListRegistry.get(container.dataset.keyedList);
  }

  // Refreshes the "N / M" count shown in each of a group's search boxes from the
  // group's live registries.
  function refreshListSearchMeta(group) {
    let total = 0;
    let shown = 0;
    let hasRegistry = false;
    listSearchGroupContainers(group).forEach((container) => {
      const registry = listSearchRegistry(container);
      if (!registry) return;
      hasRegistry = true;
      total += registry.allItems.length;
      shown += registry.items.length;
    });
    const active = (listSearchQueryByGroup.get(group) || "").trim().length > 0;
    root.querySelectorAll("[data-list-search-count]").forEach((element) => {
      if (element.dataset.listSearchCount !== group) return;
      element.textContent = (active && hasRegistry) ? tx("bridge.searchCount", { shown, total }) : "";
    });
  }

  // Re-filters and repaints every list in a search group in place — no full
  // render() — so search-as-you-type keeps the input focused and stays cheap.
  function applyListSearch(group) {
    const raw = listSearchQueryByGroup.get(group) || "";
    listSearchGroupContainers(group).forEach((container) => {
      const registry = listSearchRegistry(container);
      if (!registry) return;
      registry.items = (registry.searchOf && raw.trim())
        ? rankItems(registry.allItems, registry.searchOf, raw)
        : registry.allItems;
      if (container.dataset.virtualList) {
        const sizer = container.querySelector(".virtual-list-sizer");
        if (sizer) sizer.style.height = `${registry.items.length * registry.rowHeight}px`;
        container.scrollTop = 0;
        paintVirtualList(container);
      } else if (container.dataset.keyedList) {
        reconcileKeyedList(container, registry);
      }
    });
    refreshListSearchMeta(group);
  }

  function scheduleListSearch(group) {
    clearTimeout(listSearchTimers.get(group));
    listSearchTimers.set(group, setTimeout(() => applyListSearch(group), 120));
  }

  function refreshAllListSearchMeta() {
    const groups = new Set();
    root.querySelectorAll("[data-list-search-count]").forEach((element) => groups.add(element.dataset.listSearchCount));
    groups.forEach(refreshListSearchMeta);
  }

  function virtualList(items, rowHeight, renderRow, { key = "", emptyMarkup = "", searchOf = null, searchGroup = "" } = {}) {
    // A keyed list always renders its container, even when empty, so a targeted
    // update can add rows to it later without a full re-render.
    if (!items.length && !key && !searchGroup) return emptyMarkup;
    const id = `virtual-list-${virtualListSequence += 1}`;
    // Apply any persisted search query up front so a full re-render (e.g. a
    // background snapshot push) reproduces the filtered view without a flash.
    const rawQuery = searchGroup ? (listSearchQueryByGroup.get(searchGroup) || "") : "";
    const filtered = (searchOf && rawQuery.trim()) ? rankItems(items, searchOf, rawQuery) : items;
    virtualLists.set(id, { items: filtered, allItems: items, rowHeight, renderRow, key, searchOf });
    const totalHeight = filtered.length * rowHeight;
    return `<div class="virtual-list" data-virtual-list="${id}"${key ? ` data-virtual-key="${esc(key)}"` : ""}${searchGroup ? ` data-search-group="${esc(searchGroup)}"` : ""}><div class="virtual-list-sizer" style="height:${totalHeight}px"><div class="virtual-list-window" data-virtual-window></div></div></div>`;
  }

  // Repaints every mounted virtual list from its (freshly rebuilt) registry
  // entry. Because resetDeferredRendering resets the id sequence, identical
  // markup re-registers with identical ids, so each container's id still maps to
  // its entry — letting the render() fast path refresh windowed rows in place.
  function repaintVirtualLists() {
    root.querySelectorAll("[data-virtual-list]").forEach((container) => {
      const state = virtualLists.get(container.dataset.virtualList);
      if (!state) return;
      const sizer = container.querySelector(".virtual-list-sizer");
      if (sizer) sizer.style.height = `${state.items.length * state.rowHeight}px`;
      paintVirtualList(container);
    });
  }

  function paintVirtualList(container) {
    const state = virtualLists.get(container.dataset.virtualList);
    const win = container.querySelector("[data-virtual-window]");
    if (!state || !win) return;
    const { items, rowHeight, renderRow, key } = state;
    const scrollTop = container.scrollTop;
    const clientHeight = container.clientHeight || rowHeight * 8;
    const buffer = 4;
    const start = Math.max(0, Math.floor(scrollTop / rowHeight) - buffer);
    const visibleCount = Math.ceil(clientHeight / rowHeight) + buffer * 2;
    const end = Math.min(items.length, start + visibleCount);
    win.style.transform = `translateY(${start * rowHeight}px)`;
    win.innerHTML = items.slice(start, end).map(renderRow).join("");
    if (key) virtualListScrollByKey.set(key, scrollTop);
  }

  function scheduleVirtualPaint(container) {
    if (container.dataset.vlScheduled === "true") return;
    container.dataset.vlScheduled = "true";
    window.requestAnimationFrame(() => {
      container.dataset.vlScheduled = "false";
      paintVirtualList(container);
    });
  }

  function setupVirtualLists() {
    const containers = root.querySelectorAll("[data-virtual-list]");
    if (!containers.length) return;
    if (!virtualListResizeObserver && "ResizeObserver" in window) {
      virtualListResizeObserver = new ResizeObserver((entries) => {
        entries.forEach((entry) => scheduleVirtualPaint(entry.target));
      });
    }
    containers.forEach((container) => {
      container.addEventListener("scroll", () => scheduleVirtualPaint(container), { passive: true });
      const key = container.dataset.virtualKey;
      if (key && virtualListScrollByKey.has(key)) container.scrollTop = virtualListScrollByKey.get(key);
      paintVirtualList(container);
      virtualListResizeObserver?.observe(container);
    });
  }

  function field(labelKey, hintKey, key, value, type = "text", extra = "") {
    return `<label class="field"><span class="field-label">${tx(labelKey)}${hintKey ? `<span class="field-hint"> · ${tx(hintKey)}</span>` : ""}</span><input type="${type}" data-field="${esc(key)}" value="${type === "password" ? "" : esc(value)}" ${extra}></label>`;
  }

  function textareaField(labelKey, hintKey, key, value, extra = "") {
    return `<label class="field wide"><span class="field-label">${tx(labelKey)}${hintKey ? `<span class="field-hint"> · ${tx(hintKey)}</span>` : ""}</span><textarea data-field="${esc(key)}" ${extra}>${esc(value)}</textarea></label>`;
  }

  function selectField(labelKey, hintKey, key, value, options) {
    return `<label class="field"><span class="field-label">${tx(labelKey)}${hintKey ? `<span class="field-hint"> · ${tx(hintKey)}</span>` : ""}</span><select class="select-control" data-field="${esc(key)}">${options.map(([id, labelKey]) => `<option value="${esc(id)}"${selected(value, id)}>${tx(labelKey)}</option>`).join("")}</select></label>`;
  }

  function valueSelectField(labelKey, hintKey, key, value, options, extra = "") {
    return `<label class="field"><span class="field-label">${tx(labelKey)}${hintKey ? `<span class="field-hint"> · ${tx(hintKey)}</span>` : ""}</span><select class="select-control" data-field="${esc(key)}" ${extra}>${options.map(([id, label]) => `<option value="${esc(id)}"${selected(value, id)}>${esc(label)}</option>`).join("")}</select></label>`;
  }

  function multiValueSelectField(labelKey, hintKey, key, values, options, extra = "") {
    const selectedValues = new Set(values || []);
    return `<label class="field"><span class="field-label">${tx(labelKey)}${hintKey ? `<span class="field-hint"> · ${tx(hintKey)}</span>` : ""}</span><select class="select-control multi-select-control" data-field="${esc(key)}" multiple ${extra}>${options.map(([id, label]) => `<option value="${esc(id)}"${selectedValues.has(id) ? " selected" : ""}>${esc(label)}</option>`).join("")}</select></label>`;
  }

  function groupedValueSelectField(labelKey, hintKey, key, value, groups, extra = "") {
    return `<label class="field"><span class="field-label">${tx(labelKey)}${hintKey ? `<span class="field-hint"> · ${tx(hintKey)}</span>` : ""}</span><select class="select-control" data-field="${esc(key)}" ${extra}><option value=""${selected(value, "")}>${tx("llm.chooseProviderType")}</option>${groups.map(([groupKey, options]) => `<optgroup label="${tx(groupKey)}">${options.map(([id, label]) => `<option value="${esc(id)}"${selected(value, id)}>${esc(label)}</option>`).join("")}</optgroup>`).join("")}</select></label>`;
  }

  function toggle(labelKey, key, value) {
    return `<label class="toggle-row"><input type="checkbox" data-field="${esc(key)}"${checked(value)}><span>${tx(labelKey)}</span></label>`;
  }

  function notice(text, tone = "navy") {
    return text ? `<div class="notice ${esc(tone)}">${esc(text)}</div>` : "";
  }

  // Compact "3h 12m" / "45s" for research cooldowns and ages.
  function formatDuration(totalSeconds) {
    const seconds = Math.max(0, Math.floor(Number(totalSeconds) || 0));
    if (seconds < 60) return `${seconds}s`;
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes}m`;
    const hours = Math.floor(minutes / 60);
    if (hours < 48) return `${hours}h ${minutes % 60}m`;
    return `${Math.floor(hours / 24)}d ${hours % 24}h`;
  }

  // Research lane status: live queue counters + the durable cooldown picture,
  // plus the user's escape hatch when a provider was down ("retry now").
  function researchStatusBlock(status) {
    if (!status || typeof status !== "object") return "";
    const lines = [tx("research.status.queue", {
      pending: status.pending ?? 0,
      inCooldown: status.inCooldown ?? 0,
      transient: status.transientInCooldown ?? 0,
      succeeded: status.succeeded ?? 0,
      failed: status.failed ?? 0,
      retries: status.retries ?? 0,
      skippedBudget: status.skippedBudget ?? 0
    })];
    if (status.inFlight) lines.push(tx("research.status.inFlight", { subject: status.inFlight }));
    const failure = status.lastFailure;
    if (failure && typeof failure === "object") {
      const kindKey = `research.failure.${failure.kind || "unknown"}`;
      const kind = tx(kindKey) === kindKey ? tx("research.failure.unknown") : tx(kindKey);
      const retryIn = Number(failure.retryInSeconds) || 0;
      lines.push(tx(retryIn > 0 ? "research.status.lastFailure" : "research.status.lastFailure.due", {
        kind,
        subject: failure.subject || "",
        ago: formatDuration(failure.agoSeconds),
        count: failure.failureCount ?? 1,
        retry: formatDuration(retryIn)
      }));
    } else {
      lines.push(tx("research.status.noFailures"));
    }
    const canRetry = (status.retryable ?? 0) > 0 || (status.inCooldown ?? 0) > 0;
    return `<div class="research-status notice navy" data-research-status><strong>${tx("research.status.heading")}</strong>${lines.map((line) => `<p class="small-copy">${esc(line)}</p>`).join("")}<div class="action-row"><button class="secondary" data-action="retryFailedResearch" title="${esc(tx("research.status.retryNowHint"))}"${canRetry ? "" : " disabled"}>${tx("research.status.retryNow")}</button></div></div>`;
  }

  function statusPill(title, tone = "navy") {
    return `<span class="status-pill ${esc(tone)}">${esc(title)}</span>`;
  }

  function header(titleKey, copyKey, badge, tone = "navy") {
    return `<div class="workspace-head"><div><h2>${tx(titleKey)}</h2><p class="section-copy">${tx(copyKey)}</p></div>${statusPill(badge, tone)}</div>`;
  }

  function collectionSourceTerms(sourceKind) {
    const kind = ["creator", "account", "subreddit", "server"].includes(sourceKind) ? sourceKind : "creator";
    return {
      singular: t(`bridge.sourceKind.${kind}`),
      plural: t(`bridge.sourceKind.${kind}Plural`)
    };
  }

  function collectionObservedAt(value) {
    const numeric = Number(value);
    return Number.isFinite(numeric)
      ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(numeric))
      : t("data.unknownDate");
  }

  const collectionAttributeLabel = (key) => ({
    subscriberCount: "Subscribers",
    viewCount: "Views",
    published: "Published",
    duration: "Duration",
    details: "Details",
    metadata: "Feed details",
    creatorURL: "Creator page",
    sourceKind: "Source type"
  })[key] || String(key)
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
    .replace(/[._-]+/g, " ")
    .replace(/^./, (letter) => letter.toUpperCase());

  function renderCollectionDetailEntry(entry) {
    const attributes = Object.entries(entry.attributes || {})
      .map(([key, value]) => {
        // The YouTube "details" attribute repeats the hashtags already shown as
        // tag pills; drop the trailing hashtag cluster so they render once.
        const cleaned = key === "details" ? String(value).replace(/(?:\s*#\S+)+\s*$/, "").trim() : String(value);
        return cleaned ? `${esc(collectionAttributeLabel(key))}: ${esc(cleaned)}` : "";
      })
      .filter(Boolean)
      .join(" · ");
    const colorByName = suppliedTagNodeByPlatform.get(entry.platformID);
    const tags = Array.isArray(entry.suppliedTags) && entry.suppliedTags.length
      ? `<span class="collection-entry-tags">${entry.suppliedTags.map((tag) => {
          const label = String(tag).replace(/^#+/, "").trim();
          if (!label) return "";
          // Color a platform tag with its matching tag-tree tag's color; leave
          // unmatched tags on the neutral pill style.
          const light = normalizedTagColor(colorByName?.get(normalizeTagName(tag))?.lightColorHex);
          const style = light ? ` style="background:${light};color:#000"` : "";
          return `<span${style}>${esc(label)}</span>`;
        }).filter(Boolean).join("")}</span>`
      : "";
    const summary = typeof entry.summary === "string" && entry.summary
      ? `<span class="collection-detail-evidence" dir="auto">${esc(entry.summary)}</span>`
      : "";
    const text = typeof entry.text === "string" && entry.text && entry.text !== entry.summary
      ? `<span class="collection-detail-evidence" dir="auto">${esc(entry.text)}</span>`
      : "";
    const canonicalURL = typeof entry.canonicalURL === "string" && entry.canonicalURL
      ? `<span class="collection-entry-url">${esc(entry.canonicalURL)}</span>`
      : "";
    const attributesMarkup = attributes ? `<span class="collection-entry-attributes">${attributes}</span>` : "";
    const entryMeta = `${esc(entry.surface || "feed")} · ${esc(entry.entryType)} · ${collectionObservedAt(entry.lastObservedAtMilliseconds)}`;
    const correctionMarkup = (entry.correctionForms || []).map((form) => {
      const formID = `correction-${entry.id}-${form.typeID}`;
      const options = (form.tagOptions || []).map((tag) => [tag.id, tag.name]);
      return `<div class="collection-correction-form" data-form-id="${esc(formID)}"><span class="collection-correction-type">${esc(form.typeName)} ${form.corrected ? statusPill(tx("data.corrected"), "cyan") : ""}</span><div class="collection-correction-fields">${
        multiValueSelectField("data.correctTags", "data.correctTagsHint", "correctTagIDs", form.correctTagIDs || [], options, 'size="3"')
      }${
        field("data.correctionNote", "data.correctionNoteHint", "note", form.note || "", "text", 'maxlength="500"')
      }</div><div class="action-row"><button class="secondary" data-action="submitCorrection" data-form="${esc(formID)}" data-type-id="${esc(form.typeID)}" data-platform-id="${esc(entry.platformID)}" data-entry-id="${esc(entry.entryID)}">${tx("data.saveCorrection")}</button></div></div>`;
    }).join("");
    const correctionEditor = correctionMarkup
      ? `<details class="collection-correction"><summary>${tx("data.correctClassification")}</summary><p class="small-copy">${tx("data.correctionCopy")}</p>${correctionMarkup}</details>`
      : "";
    // Tags render above the evidence text so the fixed-height card never clips
    // them (long evidence/attributes remain clamped below).
    return `<div class="collection-detail-entry" title="${esc(entry.title)}"><span class="collection-entry-title" dir="auto">${esc(entry.title)}</span><span class="collection-entry-meta">${entryMeta}</span>${tags}${summary}${text}${attributesMarkup}${canonicalURL}${correctionEditor}</div>`;
  }

  function creatorEntriesKey(datasetID, platformID, creatorID) {
    return `${datasetID}${platformID}${creatorID}`;
  }

  // Ask the native side for one creator's full entries. The detail body shows a
  // loading placeholder until receiveCreatorEntries answers on its own channel.
  function requestCreatorEntries(datasetID, platformID, creatorID) {
    if (!datasetID || !platformID || !creatorID) return;
    const key = creatorEntriesKey(datasetID, platformID, creatorID);
    if (loadedCreatorEntries.has(key) || pendingCreatorEntryRequests.has(key)) return;
    pendingCreatorEntryRequests.add(key);
    send("loadCreatorEntries", { datasetID, platformID, creatorID });
  }

  // Builds the detail-pane body for one creator from the on-demand cache. One
  // creator is a small slice of the dataset, so entries render plainly — which
  // lets receiveCreatorEntries swap this pane in place with no list setup.
  function collectionDetailBody(datasetID, platformID, creatorID, creatorName) {
    if (!creatorID) return "";
    const entries = loadedCreatorEntries.get(creatorEntriesKey(datasetID, platformID, creatorID));
    const head = `<div class="collection-detail-head"><span class="collection-detail-name" dir="auto">${esc(creatorName || creatorID)}</span><span class="collection-detail-count">${entries ? tx("data.entryCount", { count: entries.length }) : ""}</span></div>`;
    if (!entries) return `${head}<div class="collection-detail-loading empty">${tx("app.loading")}</div>`;
    const sorted = [...entries].sort((lhs, rhs) => (Number(rhs.lastObservedAtMilliseconds) || 0) - (Number(lhs.lastObservedAtMilliseconds) || 0));
    return `${head}<div class="collection-detail-list">${sorted.map(renderCollectionDetailEntry).join("")}</div>`;
  }

  function collectionDetailContainer(platformID) {
    return [...root.querySelectorAll("[data-collection-detail]")].find((element) => element.dataset.platformId === platformID) || null;
  }

  // Targeted swap of a single platform's detail pane — never a full render.
  function updateCollectionDetailPane(datasetID, platformID, creatorID, creatorName) {
    const container = collectionDetailContainer(platformID);
    if (!container) return;
    container.dataset.creatorId = creatorID || "";
    container.innerHTML = collectionDetailBody(datasetID, platformID, creatorID, creatorName);
  }

  function languageSelection() {
    return `<label class="header-language"><span class="visually-hidden">${tx("language.label")}</span><select class="select-control" data-language-selection aria-label="${tx("language.label")}">${languageChoices.map(([identifier, nameKey]) => `<option value="${esc(identifier)}"${selected(selectedLanguage, identifier)}>${tx(nameKey)}</option>`).join("")}</select></label>`;
  }

  function localModelOptions(availableNames, selectedName, emptyLabel) {
    const names = [...new Set((availableNames || []).filter((name) => typeof name === "string" && name))].sort();
    const options = [["", emptyLabel], ...names.map((name) => [name, name])];
    if (selectedName && !names.includes(selectedName)) {
      options.splice(1, 0, [selectedName, t("localModel.modelMissing", { file: selectedName })]);
    }
    return options;
  }

  function modelLibraryContent(entries) {
    const groups = [
      ["small", (entry) => Number(entry.downloadSizeBytes) < 1_500_000_000],
      ["medium", (entry) => Number(entry.downloadSizeBytes) >= 1_500_000_000 && Number(entry.downloadSizeBytes) < 3_000_000_000],
      ["large", (entry) => Number(entry.downloadSizeBytes) >= 3_000_000_000],
    ];
    const latencyBands = new Set(["green", "danger", "reject"]);
    const row = (entry) => {
      const stateKind = entry.state?.kind || "available";
      const fraction = Math.min(1, Math.max(0, Number(entry.state?.fraction) || 0));
      let controls = `<button class="primary" data-action="downloadModel" data-id="${esc(entry.id)}">${tx("modelLibrary.download")}</button>`;
      if (stateKind === "downloading") {
        controls = `<div class="model-download-state"><span class="model-download-label">${tx("modelLibrary.downloading", { progress: percent(fraction) })}</span><div class="model-download-progress" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${Math.round(fraction * 100)}"><span style="width:${Math.round(fraction * 100)}%"></span></div></div><button class="secondary" data-action="cancelModelDownload" data-id="${esc(entry.id)}">${tx("modelLibrary.cancel")}</button>`;
      } else if (stateKind === "downloaded") {
        controls = `${statusPill(t("modelLibrary.downloaded"), "cyan")}<button class="danger" data-action="deleteModelFile" data-file-name="${esc(entry.ggufFileName)}">${tx("modelLibrary.delete")}</button>`;
      }
      const latencyBand = latencyBands.has(entry.latencyBand) ? entry.latencyBand : "unmeasured";
      return `<article class="model-library-row"><div class="model-library-copy"><div class="model-library-title"><strong>${esc(entry.displayName)}</strong><span>${esc(entry.family)}</span>${entry.recommended ? `<span class="model-recommended-badge">${tx("modelLibrary.recommended")}</span>` : ""}</div><div class="model-library-meta"><span>${tx("modelLibrary.params", { params: Number(entry.paramsB).toLocaleString(undefined, { maximumFractionDigits: 2 }) })}</span><span>${tx("modelLibrary.size", { size: modelSizeGB(entry.downloadSizeBytes) })}</span><span>${tx("modelLibrary.minimumRAM", { ram: entry.minimumRAMGB })}</span>${statusPill(t(`modelLibrary.latency.${latencyBand}`), latencyBand === "unmeasured" ? "muted" : latencyBand)}</div></div><div class="model-library-controls">${controls}</div></article>`;
    };
    return groups.map(([group, includes]) => {
      const models = entries.filter(includes).sort((lhs, rhs) => Number(lhs.downloadSizeBytes) - Number(rhs.downloadSizeBytes));
      if (!models.length) return "";
      return `<section class="model-library-group"><h4>${tx(`modelLibrary.group.${group}`)}</h4><div class="model-library-rows">${models.map(row).join("")}</div></section>`;
    }).join("");
  }

  function utilityPanelContent() {
    if (!utilityPanel) return "";
    let content = "";
    if (utilityPanel === "settings") {
      const settings = state.settings;
      const llm = settings.localLLM || {};
      const research = settings.research || {};
      const assets = state.assets || {};
      const profiles = assets.providerProfiles || [];
      const protocols = assets.providerProtocols || {};
      const statusToneByState = { loaded: "cyan", loading: "navy", disabled: "navy", "no-model": "pink", failed: "red" };
      const modelOptions = localModelOptions(
        llm.availableModels,
        llm.modelFileName || "",
        t("localModel.modelAuto")
      );
      const thresholds = Array.isArray(llm.confidenceThresholds) && llm.confidenceThresholds.length === 4
        ? llm.confidenceThresholds
        : [0.2, 0.4, 0.6, 0.85];
      const advancedBody = `<div class="utility-settings-fields">${
        valueSelectField("localModel.contextTokens", "localModel.contextTokensHint", "contextTokens", String(llm.contextTokens ?? 4096), [["1024", "1,024"], ["2048", "2,048"], ["4096", "4,096"], ["8192", "8,192"], ["16384", "16,384"]])
      }${
        valueSelectField("localModel.batchTokens", "localModel.batchTokensHint", "batchTokens", String(llm.batchTokens ?? 512), [["128", "128"], ["256", "256"], ["512", "512"], ["1024", "1,024"], ["2048", "2,048"]])
      }${
        field("localModel.maxOutputTokens", "localModel.maxOutputTokensHint", "maximumOutputTokens", llm.maximumOutputTokens ?? 16)
      }${
        field("localModel.maxTags", "localModel.maxTagsHint", "maximumTags", llm.maximumTags ?? 1)
      }${
        field("localModel.minTags", "localModel.minTagsHint", "minimumTags", llm.minimumTags ?? 0)
      }${
        field("localModel.extraTagOdds", "localModel.extraTagOddsHint", "extraTagMinimumOdds", llm.extraTagMinimumOdds ?? 0.9, "number", 'min="0" max="0.999" step="0.01"')
      }${
        field("localModel.temperature", "localModel.temperatureHint", "temperature", llm.temperature ?? 0)
      }${
        field("localModel.maxResidentModels", "localModel.maxResidentModelsHint", "maxResidentModels", llm.maxResidentModels ?? 2, "number", 'min="1" max="4"')
      }</div><div class="utility-toggles">${
        toggle("localModel.gpuOffload", "gpuOffload", llm.gpuOffload !== false)
      }${
        toggle("localModel.allowDecline", "allowDecline", llm.allowDecline !== false)
      }</div><div class="field wide"><span class="field-label">${tx("localModel.confidence")}<span class="field-hint"> · ${tx("localModel.confidenceHint")}</span></span><div class="confidence-band-row">${
        [2, 3, 4, 5].map((level, index) => `<label class="confidence-band"><span class="confidence-band-label">≥ ${level}</span><input type="text" data-field="confidenceBand${level}" value="${esc(String(thresholds[index]))}"></label>`).join("")
      }</div></div>${
        textareaField("localModel.houseRules", "localModel.houseRulesHint", "houseRules", llm.houseRules || "", 'rows="4"')
      }`;
      const llmSection = `<section class="utility-settings-section utility-llm-section" data-form-id="utility-llm-form"><h3 class="utility-settings-section-title">${tx("localModel.title")} ${statusPill(tx(`localModel.status.${llm.engineStatus || "loading"}`), statusToneByState[llm.engineStatus] || "navy")}</h3><p class="section-copy">${tx("localModel.copy")}</p><div class="utility-toggles">${
        toggle("localModel.engineEnabled", "engineEnabled", llm.engineEnabled !== false)
      }</div><div class="utility-settings-fields">${
        valueSelectField("localModel.model", "localModel.modelHint", "modelFileName", llm.modelFileName || "", modelOptions)
      }</div><div class="utility-advanced${advancedSettingsOpen ? " open" : ""}" data-advanced-settings><button type="button" class="secondary advanced-toggle" data-action="toggleAdvancedSettings" aria-expanded="${advancedSettingsOpen}"><span>${tx("localModel.advanced")}</span><span class="advanced-chevron" aria-hidden="true">⌄</span></button><div class="advanced-settings-body"><div class="advanced-settings-inner">${advancedBody}</div></div></div><div class="action-row"><button class="primary" data-action="saveLocalLLMSettings" data-form="utility-llm-form">${tx("localModel.save")}</button></div></section>`;
      const modelLibrarySection = `<section class="utility-settings-section utility-model-library-section"><div><h3 class="utility-settings-section-title">${tx("modelLibrary.title")}</h3><p class="section-copy">${tx("modelLibrary.copy")}</p></div><p class="model-library-source-note">${tx("modelLibrary.sourceNote")}</p><div class="model-library-groups">${modelLibraryContent(llm.modelLibrary || [])}</div></section>`;
      const generationProfiles = profiles.filter((profile) => protocols[profile.type]?.supportsGenerateText === true);
      const isGroundingCapable = (profile) => protocols[profile.type]?.supportsGenerateText === true && protocols[profile.type]?.supportsNativeWebSearch === true;
      // Research is provider-grounding only, so only grounding-capable providers are offered.
      const llmProviderOptions = [["", tx("research.chooseProvider")]].concat(generationProfiles.filter(isGroundingCapable).map((profile) => [profile.id, profile.name]));
      const modelSuggestions = assets.providerModelCatalogs?.[research.llmProviderProfileID] || [];
      const researchSection = `<section class="utility-settings-section utility-research-section" data-form-id="utility-research-form"><h3 class="utility-settings-section-title">${tx("research.title")} ${statusPill(tx(research.enabled ? "research.status.on" : "research.status.off"), research.enabled ? "cyan" : "muted")}</h3><p class="section-copy">${tx("research.copy")}</p><div class="notice navy research-data-flow">${tx("research.disclosure")}</div><div class="utility-toggles">${
        toggle("research.consent", "enabled", research.enabled === true)
      }</div><div class="research-settings-groups"><section class="research-settings-group"><h4>${tx("research.group.providers")}</h4><div class="utility-settings-fields">${
        valueSelectField("research.llmProvider", "research.llmProviderHint", "llmProviderProfileID", research.llmProviderProfileID || "", llmProviderOptions)
      }${
        field("research.model", "research.modelHint", "llmModelIdentifier", research.llmModelIdentifier || "", "text", 'list="research-model-suggestions" maxlength="256"')
      }<datalist id="research-model-suggestions">${modelSuggestions.map((model) => `<option value="${esc(model)}"></option>`).join("")}</datalist></div></section><section class="research-settings-group"><h4>${tx("research.group.frequency")}</h4><div class="utility-settings-fields">${
        field("research.requestsPerMinute", "research.requestsPerMinuteHint", "requestsPerMinute", research.requestsPerMinute ?? 6, "number", 'min="1" max="120"')
      }${
        field("research.dailyTokenLimit", "research.dailyTokenLimitHint", "dailyTokenLimit", research.dailyTokenLimit ?? 10000, "number", 'min="1" max="10000000"')
      }${
        field("research.cooldownHours", "research.cooldownHoursHint", "cooldownHours", research.cooldownHours ?? 24, "number", 'min="1" max="720"')
      }</div></section><section class="research-settings-group"><h4>${tx("research.group.author")}</h4><div class="utility-settings-fields">${
        field("research.authorCount", "research.authorCountHint", "authorCount", research.authorCount ?? 5, "number", 'min="1" max="512"')
      }${
        field("research.authorLevel", "research.authorLevelHint", "authorLevel", research.authorLevel ?? 3.5, "number", 'min="1" max="5" step="0.5"')
      }${
        field("research.authorWindowDays", "research.authorWindowDaysHint", "authorWindowDays", research.authorWindowDays ?? 30, "number", 'min="1" max="3650"')
      }</div></section><section class="research-settings-group"><h4>${tx("research.group.knowledge")}</h4><div class="utility-settings-fields">${
        field("research.knowledgeTTLDays", "research.knowledgeTTLDaysHint", "knowledgeTTLDays", research.knowledgeTTLDays ?? 0, "number", 'min="0" max="3650"')
      }${
        field("research.maxKnowledgePerVideo", "research.maxKnowledgePerVideoHint", "maxKnowledgePerVideo", research.maxKnowledgePerVideo ?? 8, "number", 'min="1" max="32"')
      }</div></section></div><p class="small-copy">${tx("research.usageToday", { used: research.tokensUsedToday ?? 0 })}</p>${researchStatusBlock(research.status)}<div class="action-row"><button class="primary" data-action="saveResearchSettings" data-form="utility-research-form">${tx("research.save")}</button></div></section>`;
      const packageSection = `<section class="utility-settings-section utility-resource-section" data-form-id="utility-package-form"><h3 class="utility-settings-section-title">${tx("settings.packageUpdates")}</h3><div class="utility-settings-fields">${selectField("settings.packageUpdates", "settings.packageUpdatesCopy", "packageUpdateMode", settings.packageUpdateMode, [["automatic", "enum.update.automatic"], ["downloadThenAsk", "enum.update.downloadThenAsk"], ["manual", "enum.update.manual"]])}</div><div class="action-row"><button class="primary" data-action="savePackageSettings" data-form="utility-package-form">${tx("common.save")}</button></div></section>`;
      content = `<section class="utility-panel utility-settings-modal"><div class="utility-panel-head"><div><h2>${tx("utility.settings.title")}</h2><p class="section-copy">${tx("utility.settings.copy")}</p></div><button class="secondary utility-close" data-action="closeUtilityPanel">${tx("utility.close")}</button></div><div class="utility-settings-body">${llmSection}${modelLibrarySection}${researchSection}${packageSection}</div></section>`;
    }
    if (!content) return "";
    return `<div class="utility-popover-layer" role="presentation"><button class="utility-popover-dismiss" data-action="closeUtilityPanel" aria-label="${tx("utility.close")}"></button><div class="utility-popover" role="dialog" aria-modal="true" aria-label="${esc(tx("utility.settings.title"))}">${content}</div></div>`;
  }

  function navButton(workspace, symbol, titleKey, metaKey) {
    const active = state.workspace === workspace ? " active" : "";
    return `<button class="sidebar-row${active}" type="button" data-action="workspace" data-workspace="${esc(workspace)}"><span class="sidebar-symbol" aria-hidden="true">${symbol}</span><span class="sidebar-copy"><span class="sidebar-name">${tx(titleKey)}</span><span class="sidebar-meta">${tx(metaKey)}</span></span></button>`;
  }

  // Classifier types in list order (ascending `order`, id as a stable tiebreak).
  function orderedClassifierTypes() {
    return [...(state.assets?.classifierTypes || [])]
      .sort((lhs, rhs) => (lhs.order - rhs.order) || String(lhs.id).localeCompare(String(rhs.id)));
  }

  function classifierTypeRow(type) {
    const platform = (state.assets?.collectionPlatforms || []).find((definition) => definition.id === type.applicablePlatformID);
    const active = selectedTypeID === type.id ? " active" : "";
    const meta = platform ? platform.name : tx("bridge.noApplicablePlatform");
    return `<div class="classifier-type-row${active}" data-type-id="${esc(type.id)}">
      <button class="sidebar-row classifier-type-select${active}" type="button" data-action="selectType" data-type-id="${esc(type.id)}"><span class="sidebar-symbol" aria-hidden="true">◧</span><span class="sidebar-copy"><span class="sidebar-name">${esc(type.name)}</span><span class="sidebar-meta">${esc(meta)}</span></span></button>
    </div>`;
  }

  // A trashed entity in the left panel; clicking it expands a compact
  // recover / permanently-delete panel in place.
  function trashRow(entry) {
    const active = selectedTrashID === entry.id;
    return `<div class="sidebar-trash-item${active ? " active" : ""}">
      <button class="sidebar-row sidebar-trash-row${active ? " active" : ""}" type="button" data-action="selectTrash" data-id="${esc(entry.id)}"><span class="sidebar-symbol" aria-hidden="true">🗑</span><span class="sidebar-copy"><span class="sidebar-name" dir="auto">${esc(entry.name)}</span><span class="sidebar-meta">${tx("trash.deleted")}</span></span></button>
      ${active ? `<div class="sidebar-trash-actions"><button class="secondary" data-action="restoreTrashedEntry" data-id="${esc(entry.id)}">${tx("trash.restore")}</button><button class="danger" data-action="permanentlyDeleteTrashedEntry" data-id="${esc(entry.id)}">${tx("trash.permanentlyDelete")}</button></div>` : ""}
    </div>`;
  }

  // Left-panel body: the reorderable classifier-type list is primary; collection
  // sits below, and any trashed entities follow.
  function sidebarContent() {
    const types = orderedClassifierTypes();
    const typeRows = types.length
      ? types.map((type) => classifierTypeRow(type)).join("")
      : `<div class="empty compact-empty">${tx("navigation.noTypes")}</div>`;
    const trash = Array.isArray(state?.trash) ? state.trash : [];
    const trashSection = trash.length
      ? `<div class="sidebar-divider" role="separator"></div><div class="sidebar-group-title">${tx("trash.title")}</div><div class="sidebar-trash">${trash.map(trashRow).join("")}</div>`
      : "";
    return `
      <div class="sidebar-group-title">${tx("navigation.classifierTypes")}</div>
      <div class="classifier-type-nav" data-classifier-type-nav>${typeRows}</div>
      <button class="sidebar-add" type="button" data-action="newType"><span aria-hidden="true">＋</span> ${tx("navigation.newType")}</button>
      <div class="sidebar-divider" role="separator"></div>
      ${navButton("classificationData", "▤", "navigation.classificationData", "navigation.classificationDataMeta")}
      ${navButton("knowledge", "✦", "navigation.knowledge", "navigation.knowledgeMeta")}
      ${navButton("llmAssist", "◌", "navigation.apiKeys", "navigation.apiKeysMeta")}
      ${trashSection}`;
  }

  function shell(content) {
    return `<div class="popup">
      <header class="hero">
        <div class="hero-copy"><span class="hero-mark" aria-hidden="true">V</span><nav class="scene-tabs" aria-label="Scene"><button type="button" class="scene-tab" data-action="switchScene" data-scene="vault">Vault</button><button type="button" class="scene-tab is-active" data-action="switchScene" data-scene="classifier">Classifier</button><button type="button" class="scene-tab" data-action="switchScene" data-scene="activity">Activity</button></nav></div>
        <div class="hero-controls"><span class="settings-popover-anchor"><button class="header-tool" data-action="openUtilityPanel" data-utility-panel="settings" aria-haspopup="dialog" aria-expanded="${utilityPanel ? "true" : "false"}">${tx("utility.settings.button")}</button>${utilityPanelContent()}</span>${languageSelection()}<div class="hero-status"><span class="status-dot"></span>${tx(state.settings?.research?.enabled ? "hero.researchEnabled" : "hero.offline")}</div></div>
      </header>
      <div class="layout">
        <aside class="navigation-panel" aria-label="${tx("navigation.aria")}">
          <div class="panel-header"><div><h2>${tx("navigation.title")}</h2><p class="small-copy">${tx("navigation.subtitle")}</p></div></div>
          <div class="sidebar-list">${sidebarContent()}</div>
        </aside>
        <div class="layout-resizer" data-navigation-resizer role="separator" aria-orientation="vertical" aria-label="${tx("navigation.resize")}" aria-valuemin="${navigationWidthRange.minimum}" aria-valuemax="${navigationWidthRange.maximum}" aria-valuenow="${navigationPanelWidth}" tabindex="0"></div>
        <section class="editor-panel" data-editor-panel data-workspace="${esc(state.workspace)}">${content}</section>
      </div>
    </div>`;
  }

  function backupWorkspace() {
    const backup = state.backup;
    const stateLabel = t(backup.savedEnabled ? "common.on" : "common.off");
    return `<div class="workspace">${header("backup.title", "backup.copy", stateLabel, backup.savedEnabled ? "navy" : "muted")}
      <section class="section-card navy" data-form-id="backup-owner-form"><div class="section-header"><div><h3>${tx("backup.ownerGate")}</h3><p class="section-copy">${tx("backup.ownerCopy")}</p></div></div>${backup.unlocked ? `<div class="notice navy">${tx("backup.unlocked")}</div>` : `<div class="action-row"><div class="field">${field("backup.ownerCode", backup.hasOwnerCode ? "backup.existingCode" : "backup.newCode", "ownerCode", "", "password")}</div><button class="primary" data-action="${backup.hasOwnerCode ? "unlockBackup" : "setBackupOwnerCode"}" data-form="backup-owner-form">${tx(backup.hasOwnerCode ? "backup.unlock" : "backup.setCode")}</button></div>`}</section>
      <section class="section-card navy" data-form-id="backup-form"><div class="section-header"><div><h3>${tx("backup.folder")}</h3><p class="section-copy">${tx("backup.folderCopy")}</p></div></div><div class="form-stack">${field("backup.localFolder", "backup.pathHint", "directory", backup.directory)}${toggle("backup.auto", "enabled", backup.enabled)}<div class="action-row"><button class="primary" data-action="saveBackup" data-form="backup-form"${disabled(!backup.unlocked)}>${tx("backup.save")}</button><button class="secondary" data-action="backupNow"${disabled(!backup.unlocked || !backup.savedEnabled)}>${tx("backup.create")}</button></div></div></section>${notice(state.notices.backup, "navy")}${notice(state.issue, "red")}</div>`;
  }

  function integrationWorkspace() {
    const line = (labelKey, valueKey) => `<div class="status-line"><strong>${tx(labelKey)}</strong><span class="spacer"></span><span>${tx(valueKey)}</span></div>`;
    return `<div class="workspace">${header("integration.title", "integration.copy", t("integration.notInstalled"), "muted")}
      <section class="section-card cyan"><div class="form-stack">${line("integration.app", "integration.ready")}${line("integration.pairing", "integration.keychain")}${line("integration.host", "integration.notRegistered")}${line("integration.server", "integration.notRequired")}</div></section><div class="notice cyan">${tx("integration.notice")}</div></div>`;
  }

  function tagTreeWorkspace(scopeTreeID = null) {
    const assets = state.assets;
    const coordinate = (value, fallback) => {
      const number = Number(value);
      return Number.isFinite(number) && number >= 0 ? number : fallback;
    };
    const panel = (tree) => {
      const nodes = tree.nodes || [];
      const nodeByID = new Map(nodes.map((node) => [node.id, node]));
      const positions = new Map(nodes.map((node, index) => [node.id, {
        x: coordinate(node.positionX, 24 + (index % 4) * 154),
        y: coordinate(node.positionY, 24 + Math.floor(index / 4) * 48),
      }]));
      const depthFor = (node) => {
        let depth = 0;
        let current = node;
        const visited = new Set([node.id]);
        while (current.parentID && nodeByID.has(current.parentID) && !visited.has(current.parentID)) {
          current = nodeByID.get(current.parentID);
          visited.add(current.id);
          depth += 1;
        }
        return depth;
      };
      const panelState = activeTagPanel?.treeID === tree.id ? activeTagPanel : null;
      const nodeExtentX = Math.max(0, ...[...positions.values()].map((position) => position.x + 136));
      const nodeExtentY = Math.max(0, ...[...positions.values()].map((position) => position.y + 30));
      const panelExtentX = panelState ? panelState.x + 256 : 0;
      const panelExtentY = panelState ? panelState.y + 340 : 0;
      const mapWidth = Math.max(640, nodeExtentX + 28, panelExtentX + 20);
      const mapHeight = Math.max(320, nodeExtentY + 28, panelExtentY + 20);
      const selectedNodeID = selectedTagNode?.treeID === tree.id ? selectedTagNode.nodeID : "";
      const popoverNode = panelState?.nodeID ? nodeByID.get(panelState.nodeID) : null;
      const connectionState = connectionSource?.treeID === tree.id ? connectionSource : null;
      const popover = panelState ? (() => {
        const isTreeEdit = panelState.kind === "tree";
        const isTreeDelete = panelState.kind === "delete-tree";
        const isEdit = panelState.kind === "edit" && popoverNode;
        const nodeID = isEdit ? popoverNode.id : "";
        const titleKey = isTreeDelete ? "tree.confirmDelete" : isTreeEdit ? "tree.renameTree" : isEdit ? "tree.editNode" : "tree.createNode";
        const nameField = field(
          isTreeEdit ? "tree.treeName" : isEdit ? "tree.nodeName" : "tree.tagName",
          "",
          "name",
          isTreeEdit ? tree.name : isEdit ? popoverNode.name : "",
          "text",
          isEdit ? `data-live-tag-name data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}"` : ""
        );
        const descriptionField = !isTreeDelete && !isTreeEdit
          ? textareaField(
            "tree.tagDescription",
            "tree.tagDescriptionCopy",
            "description",
            isEdit ? popoverNode.description || "" : "",
            "maxlength=\"1024\""
          )
          : "";
        const actions = isTreeDelete
          ? `<button class="secondary" data-action="cancelTagPanel">${tx("tree.cancel")}</button><button class="danger" data-action="confirmDeleteTree" data-tree-id="${esc(tree.id)}">${tx("tree.confirmDeleteAction")}</button>`
          : isTreeEdit
            ? `<button class="primary" data-action="saveTreeName" data-form="tag-popover-form" data-tree-id="${esc(tree.id)}">${tx("tree.saveTreeName")}</button>`
            : isEdit
          ? `<button class="primary" data-action="saveTagName" data-form="tag-popover-form" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}">${tx("tree.saveNode")}</button><button class="secondary" data-action="beginConnection" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}">${tx("tree.connection")}</button><button class="secondary" data-action="disconnectTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}"${disabled(!popoverNode.parentID)}>${tx("tree.disconnection")}</button><button class="danger" data-action="deleteTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}">${tx("tree.deleteNode")}</button>`
          : `<button class="primary" data-action="addTag" data-form="tag-popover-form" data-tree-id="${esc(tree.id)}">${tx("tree.createNode")}</button>`;
        const content = isTreeDelete
          ? `<p class="small-copy">${tx("tree.confirmDeleteCopy")}</p><div class="action-row">${actions}</div>`
          : `${nameField}${descriptionField}${actions ? `<div class="action-row">${actions}</div>` : ""}`;
        return `<section class="tree-popover" style="left:${panelState.x}px;top:${panelState.y}px" data-tree-popover data-form-id="tag-popover-form"><div class="tree-popover-head"><span class="eyebrow">${tx(titleKey)}</span><button class="tree-popover-close" data-action="cancelTagPanel" title="${tx("tree.cancel")}" aria-label="${tx("tree.cancel")}">×</button></div><div class="tree-form">${content}</div></section>`;
      })() : "";
      const map = `<div class="tree-map" data-tree-map data-tree-id="${esc(tree.id)}"><div class="tree-map-title">${esc(tree.name)}</div>${connectionState ? `<div class="tree-connection-mode">${tx("tree.connectionHint")}</div>` : ""}<div class="tree-map-content" style="width:max(${mapWidth}px, calc(100% + 480px)); height:max(${mapHeight}px, calc(100% + 280px))"><svg class="tree-links" aria-hidden="true"></svg><div class="tree-node-layer">${nodes.map((node) => {
        const position = positions.get(node.id);
        const depth = depthFor(node);
        const tier = depth === 0 ? "primary" : depth === 1 ? "secondary" : depth === 2 ? "tertiary" : "quaternary";
        const colorStyle = tagColorStyle(node);
        return `<button class="tree-map-node ${tier}${panelState?.nodeID === node.id || selectedNodeID === node.id ? " active" : ""}${connectionState?.nodeID === node.id ? " connection-source" : ""}${node.retired ? " retired" : ""}" style="left:${position.x}px;top:${position.y}px;${colorStyle}" data-action="selectTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(node.id)}" data-parent-id="${esc(node.parentID || "")}" data-position-x="${position.x}" data-position-y="${position.y}" title="${tx("tree.contextHint")}"><span aria-hidden="true"></span><strong>${esc(node.name)}</strong></button>`;
      }).join("")}</div>${nodes.length ? "" : `<div class="tree-map-empty">${tx("tree.empty")}</div>`}${popover}</div></div>`;
      const treeActions = `<div class="tree-canvas-actions"><button class="secondary" data-action="renameTree" data-tree-id="${esc(tree.id)}">${tx("tree.rename")}</button><button class="danger" data-action="deleteTree" data-tree-id="${esc(tree.id)}">${tx("tree.delete")}</button><button class="secondary" data-action="rearrangeTree" data-tree-id="${esc(tree.id)}">${tx("tree.rearrange")}</button></div>`;
      return `<section class="tree-panel">${map}<div class="tree-canvas-hint"><span>${tx("tree.canvasHint")}</span>${treeActions}</div></section>`;
    };
    // Scoped to one type's tree: no shared-library header, create box, or trash.
    if (scopeTreeID) {
      const scopedTrees = assets.trees.filter((tree) => tree.id === scopeTreeID);
      return `<div class="workspace tree-workspace tree-workspace-scoped"><div class="tree-panels">${scopedTrees.map(panel).join("") || `<div class="empty">${tx("tree.empty")}</div>`}</div>${notice(state.issue, "red")}</div>`;
    }
    return `<div class="workspace tree-workspace">${header("tree.title", "tree.copy", t("tree.sharedLibrary"), "cyan")}
      <section class="tree-create" data-form-id="new-tree-form">${field("tree.treeName", "", "name", "")}<button class="primary" data-action="createTree" data-form="new-tree-form">${tx("tree.create")}</button><span class="small-copy">${tx("tree.multiplePanels")}</span></section><div class="tree-panels">${assets.trees.map(panel).join("")}</div>${notice(state.issue, "red")}</div>`;
  }

  function providerTypeLabelKey(type) {
    const keys = {
      openAI: "llm.provider.openAI",
      openAICompatible: "llm.provider.openAICompatible",
      deepSeek: "llm.provider.deepSeek",
      gemini: "llm.provider.gemini",
      anthropic: "llm.provider.anthropic",
      mistral: "llm.provider.mistral",
      cohere: "llm.provider.cohere",
      groq: "llm.provider.groq",
      openRouter: "llm.provider.openRouter",
      ollama: "llm.provider.ollama",
      youtubeData: "llm.provider.youtubeData",
      twitch: "llm.provider.twitch",
      reddit: "llm.provider.reddit",
      xPlatform: "llm.provider.xPlatform",
      tikTok: "llm.provider.tikTok",
      instagramGraph: "llm.provider.instagramGraph",
      facebookGraph: "llm.provider.facebookGraph",
      serper: "llm.provider.serper",
      youSearch: "llm.provider.youSearch",
      custom: "llm.provider.custom",
    };
    return keys[type] || "llm.provider.openAICompatible";
  }

  function protocolFieldLabelKey(fieldName) {
    const keys = {
      accountID: "llm.protocol.accountID",
      apiVersion: "llm.protocol.apiVersion",
      clientID: "llm.protocol.clientID",
      location: "llm.protocol.location",
      projectID: "llm.protocol.projectID",
      region: "llm.protocol.region",
      userAgent: "llm.protocol.userAgent",
      searchEngineID: "llm.protocol.searchEngineID",
      protocolFamily: "llm.protocol.protocolFamily",
    };
    return keys[fieldName] || "llm.protocol.protocolFamily";
  }

  function llmAssistWorkspace() {
    const profiles = state.assets.providerProfiles || [];
    const requestRecords = state.assets.providerRequestRecords || [];
    const protocols = state.assets.providerProtocols || {};
    const profileTypeGroups = [
      ["llm.providerGroup.models", ["openAI", "deepSeek", "gemini", "anthropic", "mistral", "cohere", "groq", "openRouter", "ollama"].map((type) => [type, t(providerTypeLabelKey(type))])],
      ["llm.providerGroup.platform", ["youtubeData", "twitch", "reddit", "xPlatform", "tikTok", "instagramGraph", "facebookGraph"].map((type) => [type, t(providerTypeLabelKey(type))])],
      ["llm.providerGroup.custom", ["openAICompatible", "custom"].map((type) => [type, t(providerTypeLabelKey(type))])],
    ];
    const panel = (profile) => {
      const formID = `provider-profile-${profile.id}`;
      const protocol = protocols[profile.type] || {};
      const supportsLLM = Boolean(protocol.supportsLLMConfiguration);
      const supportsPlatformData = Boolean(protocol.supportsPlatformData);
      // Serper / You.com fed the removed raw-search mode: kept readable, never testable or used.
      const retiredSearchProvider = Boolean(protocol.retiredSearchProvider);
      const profileRecords = requestRecords.filter((record) => record.profileID === profile.id);
      const latestResponseDiagnostic = profileRecords
        .filter((record) => typeof record.responseShape === "string" && record.responseShape.length > 0)
        .sort((left, right) => Number(right.createdAtMilliseconds) - Number(left.createdAtMilliseconds))[0];
      const tokenTotal = profileRecords.reduce(
        (total, record) => total + (Number(record.tokenCount) || 0),
        0
      );
      const credentialField = protocol.credentialRequired ? field("llm.apiKeyOrToken", "", "credential", profile.credential || "", "text", "data-provider-connection autocapitalize=\"off\" spellcheck=\"false\"") : "";
      const endpointField = protocol.allowsEndpointOverride ? field("llm.apiEndpoint", "", "customEndpoint", profile.customEndpoint || "", "text", "data-provider-connection") : "";
      const testModelField = supportsLLM && (protocol.allowsEndpointOverride || !profile.defaultModelIdentifier)
        ? field("llm.testModel", "", "testModelIdentifier", profile.testModelIdentifier || "", "text", `data-provider-connection placeholder=\"${esc(profile.defaultModelIdentifier || "model-name")}\"`)
        : "";
      const protocolFields = (protocol.configurationRequirements || []).map((requirement) => field(
        protocolFieldLabelKey(requirement.field),
        "",
        `protocol.${requirement.field}`,
        profile.protocolConfiguration?.[requirement.field] ?? requirement.defaultValue ?? "",
        "text",
        "data-provider-connection"
      )).join("");
      const connectionFields = [credentialField, endpointField, testModelField, protocolFields].filter(Boolean).join("");
      const testAvailable = (supportsLLM || supportsPlatformData) && !retiredSearchProvider;
      const testButton = testAvailable ? `<button class="gold-action" data-action="testProviderProfile" data-form="${esc(formID)}" data-profile-id="${esc(profile.id)}"${disabled(profile.testing)}>${tx(profile.testing ? "llm.testing" : "llm.test")}</button>` : "";
      const usage = supportsPlatformData || retiredSearchProvider
        ? `<p class="provider-token-usage"><span>${tx("llm.apiCalls")}</span><strong>${profileRecords.filter((record) => ["readPublicContent", "searchWeb", "search-creator-web"].includes(record.operation) && Number.isInteger(record.statusCode)).length}</strong></p>`
        : `<p class="provider-token-usage"><span>${tx("llm.tokenUsage")}</span><strong>${tx("llm.tokenTotal", { total: tokenTotal })}</strong></p>`;
      const responseDiagnostic = latestResponseDiagnostic
        ? `<p class="provider-response-shape"><span>${tx("llm.responseShape")}</span><strong>${esc(latestResponseDiagnostic.responseShape)}</strong></p>`
        : "";
      return `<section class="provider-panel" data-provider-panel data-provider-id="${esc(profile.id)}" data-form-id="${esc(formID)}"><div class="provider-panel-head"><h3>${esc(profile.name)}</h3><div class="provider-panel-actions">${testButton}<button class="danger" data-action="confirmDeleteProviderProfile" data-profile-id="${esc(profile.id)}">${tx("llm.deleteProfile")}</button></div></div>${retiredSearchProvider ? `<div class="notice navy">${tx("llm.retiredSearchProvider")}</div>` : ""}<div class="provider-panel-body">${connectionFields ? `<div class="provider-connection-fields">${connectionFields}</div>` : ""}<div class="provider-request-summary">${usage}${responseDiagnostic}</div></div>${profile.testSucceeded ? notice(t("llm.testSucceeded"), "green") : ""}</section>`;
    };
    return `<div class="workspace provider-workspace">${header("llm.title", "llm.copy", t("llm.keyLibrary"), "gold")}<div class="notice navy provider-local-only">${tx("llm.localOnlyDisclosure")}</div><section class="provider-create" data-form-id="new-provider-profile-form">${groupedValueSelectField("llm.providerType", "", "type", "", profileTypeGroups)}<button class="gold-action" data-action="createProviderProfile" data-form="new-provider-profile-form">${tx("llm.createKey")}</button><span class="small-copy">${tx("llm.createCopy")}</span></section><div class="provider-panels">${profiles.length ? profiles.map(panel).join("") : `<div class="empty">${tx("llm.empty")}</div>`}</div>${notice(state.issue, "red")}</div>`;
  }

  function browserBridgeWorkspace() {
    const assets = state.assets;
    const classifierTypes = assets.classifierTypes || [];
    const trees = assets.trees || [];
    const datasets = assets.datasets || [];
    const profiles = assets.providerProfiles || [];
    const platformDefinitions = new Map((assets.collectionPlatforms || []).map((platform) => [platform.id, platform]));
    const typeForm = (classifierType) => {
      const formID = `classifier-type-${classifierType.id}`;
      const applicablePlatformID = typeof classifierType.applicablePlatformID === "string" ? classifierType.applicablePlatformID : "";
      const applicableBinding = (assets.bindings || []).find((binding) => binding.id === applicablePlatformID);
      // A type owns its own tree; the binding only supplies the shared dataset.
      const selectedTree = trees.find((tree) => tree.id === classifierType.treeID);
      const selectedDataset = datasets.find((dataset) => dataset.id === applicableBinding?.datasetID);
      const applicablePlatform = platformDefinitions.get(applicablePlatformID);
      const supportsLocalModel = applicablePlatform?.supportsLocalModel === true;
      // A platform belongs to at most one classifier type: hide platforms another
      // type already claims (this type's own current platform stays selectable).
      const claimedElsewhere = new Set(classifierTypes
        .filter((other) => other.id !== classifierType.id && typeof other.applicablePlatformID === "string" && other.applicablePlatformID)
        .map((other) => other.applicablePlatformID));
      const applicablePlatformOptions = [["", t("bridge.noApplicablePlatform")], ...(assets.collectionPlatforms || []).filter((definition) => !claimedElsewhere.has(definition.id)).map((definition) => {
        const hasBinding = (assets.bindings || []).some((binding) => binding.id === definition.id);
        return [definition.id, `${definition.name} · ${definition.browser}${hasBinding ? "" : ` · ${t("bridge.platformDataAutoCreate")}`}${!definition.supportsLocalModel ? ` · ${t("bridge.collectionOnly")}` : ""}`];
      })];
      const platformAPIProfiles = applicablePlatform?.apiProviderType
        ? profiles.filter((profile) => profile.type === applicablePlatform.apiProviderType)
        : [];
      const boundPlatformAPIProfile = platformAPIProfiles.find((profile) => profile.hasCredential);
      const platformDataStatus = !applicablePlatform
        ? t("bridge.platformDataChoose")
        : !applicableBinding
          ? t("bridge.platformDataWillCreate", { platform: applicablePlatform.name })
        : !applicablePlatform.apiProviderType
          ? t("bridge.platformDataUnavailable", { platform: applicablePlatform.name })
          : boundPlatformAPIProfile
            ? t("bridge.platformDataBound", { profile: boundPlatformAPIProfile.name })
            : t("bridge.platformDataMissingKey", { platform: applicablePlatform.name });
      const typeStatus = applicablePlatformID ? t("bridge.configured") : t("bridge.needsSource");
      const localOverrides = classifierType.localModelOverrides || null;
      const localOverrideThresholds = Array.isArray(localOverrides?.confidenceThresholds) && localOverrides.confidenceThresholds.length === 4
        ? localOverrides.confidenceThresholds
        : [0.2, 0.4, 0.6, 0.85];
      const localModelFormID = `classifier-local-model-form-${classifierType.id}`;
      const typeModelOptions = localModelOptions(
        state.settings?.localLLM?.availableModels,
        classifierType.modelFileName || "",
        t("bridge.localModelInheritGlobal")
      );
      const localModelOverrideBody = `<div class="utility-toggles">${toggle("bridge.localModelAllowDecline", "allowDecline", localOverrides?.allowDecline ?? true)}${toggle("bridge.localModelOcrEvidence", "thumbnailOcrEvidence", localOverrides?.thumbnailOcrEvidence ?? true)}</div>${field("bridge.localModelMaxTags", "localModel.maxTagsHint", "maximumTags", localOverrides?.maximumTags ?? (state.settings?.localLLM?.maximumTags ?? 1))}${field("bridge.localModelMinTags", "localModel.minTagsHint", "minimumTags", localOverrides?.minimumTags ?? "")}<div class="field wide"><span class="field-label">${tx("localModel.confidence")}<span class="field-hint"> · ${tx("localModel.confidenceHint")}</span></span><div class="confidence-band-row">${[2, 3, 4, 5].map((level, index) => `<label class="confidence-band"><span class="confidence-band-label">≥ ${level}</span><input type="text" data-field="confidenceBand${level}" value="${esc(String(localOverrideThresholds[index]))}"></label>`).join("")}</div></div>${textareaField("bridge.localModelHouseRules", "bridge.localModelHouseRulesCopy", "houseRules", localOverrides?.houseRules ?? "", 'rows="4"')}`;
      const localModelOverrideSection = supportsLocalModel ? `<section class="classifier-type-section classifier-local-model-overrides" data-local-model-section><div class="section-header"><div><h3>${tx("bridge.localModelOverrides")}</h3><p class="section-copy">${tx("bridge.localModelOverridesCopy")}</p></div></div><div data-form-id="${esc(localModelFormID)}"><div class="utility-settings-fields">${valueSelectField("bridge.localModelFile", "bridge.localModelFileCopy", "modelFileName", classifierType.modelFileName || "", typeModelOptions)}</div><p class="small-copy resident-model-note">${tx("bridge.localModelResidentNote", { count: state.settings?.localLLM?.maxResidentModels ?? 2 })}</p>${toggle("bridge.localModelOverrideEnabled", "overrideEnabled", Boolean(localOverrides))}<div class="utility-advanced${localModelAdvancedOpen ? " open" : ""}" data-local-model-advanced><button type="button" class="secondary advanced-toggle" data-action="toggleLocalModelAdvanced" aria-expanded="${localModelAdvancedOpen}"><span>${tx("bridge.localModelOverrideControls")}</span><span class="advanced-chevron" aria-hidden="true">⌄</span></button><div class="advanced-settings-body"><div class="advanced-settings-inner">${localModelOverrideBody}</div></div></div><div class="action-row"><button type="button" class="primary" data-action="saveClassifierTypeLocalModel" data-form="${esc(localModelFormID)}" data-type-id="${esc(classifierType.id)}">${tx("common.save")}</button></div></div></section>` : "";
      const researchOverrides = classifierType.researchOverrides || null;
      const researchDefaults = researchOverrides || state.settings?.research || {};
      const researchFormID = `classifier-research-form-${classifierType.id}`;
      const generationProfiles = profiles.filter((profile) => assets.providerProtocols?.[profile.type]?.supportsGenerateText === true);
      const typeIsGroundingCapable = (profile) => assets.providerProtocols?.[profile.type]?.supportsGenerateText === true && assets.providerProtocols?.[profile.type]?.supportsNativeWebSearch === true;
      const typeLLMProviderOptions = [["", tx("research.chooseProvider")]].concat(generationProfiles.filter(typeIsGroundingCapable).map((profile) => [profile.id, profile.name]));
      const typeModelSuggestions = assets.providerModelCatalogs?.[researchDefaults.llmProviderProfileID] || [];
      const typeResearchModelListID = `research-model-suggestions-${classifierType.id}`;
      const researchOverrideBody = `<div class="utility-toggles">${toggle("bridge.researchEnabled", "enabled", researchDefaults.enabled === true)}</div><div class="research-settings-groups"><section class="research-settings-group"><h4>${tx("research.group.providers")}</h4><div class="utility-settings-fields">${
        valueSelectField("research.llmProvider", "research.llmProviderHint", "llmProviderProfileID", researchDefaults.llmProviderProfileID || "", typeLLMProviderOptions)
      }${
        field("research.model", "research.modelHint", "llmModelIdentifier", researchDefaults.llmModelIdentifier || "", "text", `list="${esc(typeResearchModelListID)}" maxlength="256"`)
      }<datalist id="${esc(typeResearchModelListID)}">${typeModelSuggestions.map((model) => `<option value="${esc(model)}"></option>`).join("")}</datalist></div></section><section class="research-settings-group"><h4>${tx("research.group.frequency")}</h4><div class="utility-settings-fields">${
        field("research.requestsPerMinute", "research.requestsPerMinuteHint", "requestsPerMinute", researchDefaults.requestsPerMinute ?? 6, "number", 'min="1" max="120"')
      }${
        field("research.dailyTokenLimit", "research.dailyTokenLimitHint", "dailyTokenLimit", researchDefaults.dailyTokenLimit ?? 10000, "number", 'min="1" max="10000000"')
      }${
        field("research.cooldownHours", "research.cooldownHoursHint", "cooldownHours", researchDefaults.cooldownHours ?? 24, "number", 'min="1" max="720"')
      }</div></section><section class="research-settings-group"><h4>${tx("research.group.author")}</h4><div class="utility-settings-fields">${
        field("research.authorCount", "research.authorCountHint", "authorCount", researchDefaults.authorCount ?? 5, "number", 'min="1" max="512"')
      }${
        field("research.authorLevel", "research.authorLevelHint", "authorLevel", researchDefaults.authorLevel ?? 3.5, "number", 'min="1" max="5" step="0.5"')
      }${
        field("research.authorWindowDays", "research.authorWindowDaysHint", "authorWindowDays", researchDefaults.authorWindowDays ?? 30, "number", 'min="1" max="3650"')
      }</div></section><section class="research-settings-group"><h4>${tx("research.group.knowledge")}</h4><div class="utility-settings-fields">${
        field("research.knowledgeTTLDays", "research.knowledgeTTLDaysHint", "knowledgeTTLDays", researchDefaults.knowledgeTTLDays ?? 0, "number", 'min="0" max="3650"')
      }${
        field("research.maxKnowledgePerVideo", "research.maxKnowledgePerVideoHint", "maxKnowledgePerVideo", researchDefaults.maxKnowledgePerVideo ?? 8, "number", 'min="1" max="32"')
      }</div></section></div>`;
      const researchOverrideSection = supportsLocalModel ? `<section class="classifier-type-section classifier-research-overrides"><div class="section-header"><div><h3>${tx("bridge.researchOverrides")}</h3><p class="section-copy">${tx("bridge.researchOverridesCopy")}</p></div></div><div data-form-id="${esc(researchFormID)}">${toggle("bridge.researchOverrideEnabled", "overrideEnabled", Boolean(researchOverrides))}<div class="utility-advanced${researchAdvancedOpen ? " open" : ""}" data-research-advanced><button type="button" class="secondary advanced-toggle" data-action="toggleResearchAdvanced" aria-expanded="${researchAdvancedOpen}"><span>${tx("bridge.researchOverrideControls")}</span><span class="advanced-chevron" aria-hidden="true">⌄</span></button><div class="advanced-settings-body"><div class="advanced-settings-inner">${researchOverrideBody}</div></div></div><p class="small-copy research-master-note">${tx("bridge.researchMasterGate")}</p><div class="action-row"><button type="button" class="primary" data-action="saveClassifierTypeResearch" data-form="${esc(researchFormID)}" data-type-id="${esc(classifierType.id)}">${tx("common.save")}</button></div></div></section>` : "";
      // Preset provenance: every type is created from a preset. Show which one,
      // and flag drift ("Modified from <preset>") once its overrides diverge from
      // what the preset writes — the detailed form below is the "Advanced" surface.
      const presetName = classifierType.presetNameKey ? t(classifierType.presetNameKey) : "";
      const presetBadge = presetName
        ? statusPill(
            t(classifierType.modifiedFromPreset ? "preset.modifiedFrom" : "preset.basedOn", { name: presetName }),
            classifierType.modifiedFromPreset ? "gold" : "muted"
          )
        : "";
      return `<section class="classifier-type-panel" data-form-id="${esc(formID)}" data-type-id="${esc(classifierType.id)}">
        <div class="classifier-type-head"><div><p class="section-copy">${tx("bridge.typeMatchCopy", { tree: selectedTree?.name || t("bridge.missingAsset"), data: selectedDataset?.name || t("bridge.missingAsset") })}</p></div><div class="classifier-type-head-pills">${presetBadge}${statusPill(typeStatus, applicablePlatformID ? "navy" : "muted")}</div></div>
        <div class="classifier-name-row">${field("bridge.typeName", "", "name", classifierType.name)}<button class="primary" data-action="configureClassifierType" data-form="${esc(formID)}" data-type-id="${esc(classifierType.id)}">${tx("bridge.saveType")}</button><button class="danger" data-action="confirmDeleteClassifierType" data-type-id="${esc(classifierType.id)}" data-name="${esc(classifierType.name)}">${tx("bridge.deleteType")}</button></div>
        <section class="classifier-type-section classifier-applicable-platform-section"><div class="section-header"><div><h3>${tx("bridge.applicablePlatform")}</h3><p class="section-copy">${tx("bridge.assetSelectionCopy")}</p></div></div><div class="classifier-applicable-platform-row">${valueSelectField("bridge.applicablePlatform", "bridge.applicablePlatformCopy", "applicablePlatformID", applicablePlatformID, applicablePlatformOptions)}<div class="classifier-platform-data-status"><span class="eyebrow">${tx("bridge.platformData")}</span><p class="small-copy">${esc(platformDataStatus)}</p></div></div>${applicablePlatform && !supportsLocalModel ? `<p class="small-copy" data-collection-only-platform-note>${tx("bridge.collectionOnlyCopy")}</p>` : ""}</section>
        ${localModelOverrideSection}
        ${researchOverrideSection}
      </section>`;
    };
    // A type now targets one platform at creation and owns a fresh tree. The
    // left panel selects which type is open; a selected type shows its config
    // and owned tree together.
    const selectedType = selectedTypeID ? classifierTypes.find((type) => type.id === selectedTypeID) : null;
    if (selectedType) {
      const platformDef = (assets.collectionPlatforms || []).find((definition) => definition.id === selectedType.applicablePlatformID);
      // Config and Tag tree are stacked in one continuous scroll.
      const section = (labelKey, inner) => `<section class="type-section"><h3 class="type-section-title">${tx(labelKey)}</h3>${inner}</section>`;
      return `<div class="workspace classifier-type-workspace">
        <div class="type-detail-head"><div><span class="eyebrow">${tx("bridge.typeLibrary")}</span><h2>${esc(selectedType.name)}</h2><p class="section-copy">${esc(platformDef ? platformDef.name : tx("bridge.noApplicablePlatform"))}</p></div></div>
        <div class="type-detail-body">
          ${section("bridge.tabConfig", typeForm(selectedType))}
          ${section("bridge.tabTree", tagTreeWorkspace(selectedType.treeID))}
        </div></div>`;
    }
    // Nothing selected: '+ New type' creates directly and the sidebar lists the
    // types, so this is just a prompt.
    return `<div class="workspace classifier-type-workspace">${header("bridge.title", "bridge.copy", t("bridge.typeLibrary"), "navy")}
      <div class="empty">${tx(classifierTypes.length ? "bridge.selectType" : "bridge.emptyTypes")}</div>${notice(state.issue, "red")}</div>`;
  }

  function knowledgeWorkspace() {
    const knowledge = state.assets?.knowledge || { creators: [], terms: [] };
    const creators = knowledge.creators || [];
    const terms = knowledge.terms || [];

    const entryCard = (entry, kind, index) => {
      const formID = `knowledge-edit-${kind}-${index}`;
      const sources = Array.isArray(entry.sourceURLs) ? entry.sourceURLs : [];
      const sourceLine = sources.length
        ? `<div class="knowledge-sources">${sources.map((url) => `<a href="${esc(url)}" target="_blank" rel="noreferrer noopener">${esc(url)}</a>`).join("")}</div>`
        : "";
      const badge = kind === "creator" ? statusPill(tx("knowledge.permanent"), "cyan") : "";
      return `<article class="knowledge-card" data-form-id="${formID}"><div class="knowledge-card-head"><span class="knowledge-subject" dir="auto">${esc(entry.subject)}</span>${badge}</div><label class="field wide"><span class="field-label">${tx("knowledge.description")}</span><textarea data-field="meaning" rows="3" maxlength="2000">${esc(entry.meaning || "")}</textarea></label>${sourceLine}<div class="action-row"><button class="primary" data-action="editKnowledgeEntry" data-form="${formID}" data-id="${esc(entry.id)}">${tx("common.save")}</button><button class="danger" data-action="deleteKnowledgeEntry" data-id="${esc(entry.id)}">${tx("knowledge.delete")}</button></div></article>`;
    };

    const group = (titleKey, hintKey, items, kind) => `<section class="knowledge-group"><div class="section-header"><div><h3>${tx(titleKey)} <span class="knowledge-count">${items.length}</span></h3><p class="section-copy">${tx(hintKey)}</p></div></div>${items.length ? `<div class="knowledge-list">${items.map((entry, index) => entryCard(entry, kind, index)).join("")}</div>` : `<div class="empty">${tx("knowledge.empty")}</div>`}</section>`;

    // Terms are only ever added here, by the user: name the term, and either
    // write what it means or leave that blank to have it looked up.
    const addTerm = `<section class="knowledge-group" data-form-id="knowledge-add-term"><div class="section-header"><div><h3>${tx("knowledge.addTerm")}</h3><p class="section-copy">${tx("knowledge.addTermHint")}</p></div></div><div class="form-stack">${field("knowledge.termSubject", "knowledge.termSubjectHint", "subject", "", "text", 'maxlength="120"')}<label class="field wide"><span class="field-label">${tx("knowledge.description")}</span><textarea data-field="meaning" rows="2" maxlength="2000" placeholder="${tx("knowledge.termMeaningPlaceholder")}"></textarea></label><div class="action-row"><button class="primary" data-action="addKnowledgeTerm" data-form="knowledge-add-term">${tx("knowledge.addTermButton")}</button></div></div></section>`;

    return `<div class="workspace knowledge-workspace">${header("knowledge.title", "knowledge.copy", tx("knowledge.badge"), "gold")}<div class="notice navy">${tx("knowledge.disclosure")}</div>${notice(state.notices?.knowledge, "navy")}${notice(state.issue, "red")}${addTerm}${group("knowledge.terms", "knowledge.termsHint", terms, "term")}${group("knowledge.creators", "knowledge.creatorsHint", creators, "creator")}</div>`;
  }

  function classificationDataWorkspace() {
    const assets = state.assets;
    const bindings = assets.bindings || [];
    const datasets = assets.datasets || [];
    const definitions = assets.collectionPlatforms || [];
    const datasetByID = new Map(datasets.map((dataset) => [dataset.id, dataset]));
    const treeByID = new Map((assets.trees || []).map((tree) => [tree.id, tree]));
    // Rebuild the platform -> (tag name -> tree node) color lookup for the detail
    // pane. Each binding owns one tree; a supplied tag is colored by the matching
    // tree tag, falling back to a neutral pill when the platform tag is not in
    // the taxonomy.
    suppliedTagNodeByPlatform.clear();
    bindings.forEach((binding) => {
      const tree = treeByID.get(binding.treeID);
      if (!tree) return;
      const nameToNode = new Map();
      (tree.nodes || []).forEach((node) => {
        if (node.retired) return;
        const key = normalizeTagName(node.name);
        if (key && !nameToNode.has(key)) nameToNode.set(key, node);
      });
      suppliedTagNodeByPlatform.set(binding.id, nameToNode);
    });
    const totalCollectedEntries = datasets.reduce((sum, dataset) => sum + (dataset.collectedCreators || []).reduce((inner, creator) => inner + (Number(creator.entryCount) || 0), 0), 0);
    const classifierTypes = assets.classifierTypes || [];
    const availablePlatforms = definitions.filter((definition) => !bindings.some((binding) => binding.id === definition.id));
    const bindingPanel = (binding) => {
      const definition = definitions.find((candidate) => candidate.id === binding.id);
      const sourceTerms = collectionSourceTerms(definition?.sourceKind);
      const dataset = datasetByID.get(binding.datasetID);
      const datasetID = binding.datasetID;
      // Only the creator-level primary list is in the snapshot; a chosen
      // creator's entries are fetched on demand (requestCreatorEntries).
      // Stable order: a creator keeps its slot by when it was first seen.
      const creatorRows = (dataset?.collectedCreators || [])
        .filter((creator) => creator.platformID === binding.id)
        .slice()
        .sort((lhs, rhs) => (Number(lhs.firstObservedAtMilliseconds) - Number(rhs.firstObservedAtMilliseconds)) || String(lhs.creatorID).localeCompare(String(rhs.creatorID)));
      const entryTotal = creatorRows.reduce((sum, creator) => sum + (Number(creator.entryCount) || 0), 0);
      // Keep the selected source stable across re-renders; fall back to the
      // first source so the detail pane is never empty when sources exist.
      let selectedCreatorID = selectedCollectionCreatorByPlatform.get(binding.id);
      if (!creatorRows.some((creator) => creator.creatorID === selectedCreatorID)) {
        selectedCreatorID = creatorRows[0]?.creatorID || "";
        if (selectedCreatorID) selectedCollectionCreatorByPlatform.set(binding.id, selectedCreatorID);
        else selectedCollectionCreatorByPlatform.delete(binding.id);
      }
      const creatorRow = (creator) => {
        const avatarURL = typeof creator.cachedSourceIconURL === "string" ? creator.cachedSourceIconURL : "";
        const avatar = avatarURL
          ? `<img class="collection-creator-avatar" src="${esc(avatarURL)}" alt="" aria-hidden="true" loading="lazy" decoding="async">`
          : `<span class="collection-creator-avatar collection-creator-avatar-empty" aria-hidden="true"></span>`;
        const selectedClass = creator.creatorID === selectedCreatorID ? " selected" : "";
        return `<button type="button" class="collection-creator-row${selectedClass}" data-action="selectCollectionCreator" data-dataset-id="${esc(datasetID)}" data-platform-id="${esc(binding.id)}" data-creator-id="${esc(creator.creatorID)}">${avatar}<span class="collection-creator-name" dir="auto">${esc(creator.creatorName || creator.creatorID)}</span><span class="collection-creator-count">${tx("data.entryCount", { count: Number(creator.entryCount) || 0 })}</span></button>`;
      };
      const creatorList = virtualList(creatorRows, collectionRowHeight, creatorRow, { key: `collection-master-${binding.id}`, searchGroup: `collection-master-${binding.id}`, searchOf: (creator) => `${creator.creatorName || ""} ${creator.creatorID || ""}` });
      const selectedCreator = creatorRows.find((creator) => creator.creatorID === selectedCreatorID) || null;
      const creatorListOpen = !collapsedCollectionCreatorLists.has(binding.id);
      // Lazy-load the chosen creator's entries only while the list is open; the
      // detail pane fills in via receiveCreatorEntries with no full re-render.
      if (creatorListOpen && selectedCreator) requestCreatorEntries(datasetID, binding.id, selectedCreator.creatorID);
      const detailMarkup = selectedCreator
        ? collectionDetailBody(datasetID, binding.id, selectedCreator.creatorID, selectedCreator.creatorName)
        : "";
      const detailPane = `<div class="collection-detail" data-collection-detail data-dataset-id="${esc(datasetID)}" data-platform-id="${esc(binding.id)}" data-creator-id="${esc(selectedCreator?.creatorID || "")}">${detailMarkup}</div>`;
      const formID = `collection-platform-${binding.id}`;
      const availability = definition?.collectorAvailable ? "data.collectorAvailable" : "data.collectorPlanned";
      const tree = treeByID.get(binding.treeID);
      const selectableTypes = classifierTypes.filter((classifierType) => {
        return classifierType.applicablePlatformID === binding.id
          && classifierType.treeID === binding.treeID
          && classifierType.datasetID === binding.datasetID
          && classifierType.treeRevision === tree?.revision
          && classifierType.datasetRevision === dataset?.revision;
      });
      const typeOptions = [["", t("data.noClassifierType")], ...selectableTypes.map((classifierType) => [classifierType.id, classifierType.name])];
      const typeStatus = binding.activeClassifierTypeID ? "data.classifierTypeActive" : "data.classifierTypeNone";
      const localOnlyNotice = binding.id === "discord" ? `<p class="small-copy collection-local-only">${tx("data.discordLocalOnly")}</p>` : "";
      return `<section class="collection-platform-panel" data-form-id="${esc(formID)}"><div class="collection-platform-head"><div><span class="eyebrow">${tx("data.platformPanel")}</span><h3>${esc(binding.name)}</h3><p class="section-copy">${esc(binding.browser)} · ${tx(availability)}</p></div><div class="collection-platform-actions">${statusPill(t(binding.collectionEnabled ? "data.collecting" : "data.collectionOff"), binding.collectionEnabled ? "cyan" : "muted")}<button class="danger" data-action="confirmDeleteCollectionPlatform" data-platform-id="${esc(binding.id)}" data-name="${esc(binding.name)}">${tx("data.deletePlatform")}</button></div></div><div class="collection-platform-controls">${toggle("data.collectToggle", "enabled", Boolean(binding.collectionEnabled))}<button class="primary" data-action="setCollectionEnabled" data-form="${esc(formID)}" data-platform-id="${esc(binding.id)}">${tx("data.applyCollection")}</button></div>${localOnlyNotice}<div class="collection-platform-controls">${valueSelectField("data.classifierType", "data.classifierTypeCopy", "classifierTypeID", binding.activeClassifierTypeID || "", typeOptions)}<button class="secondary" data-action="setActiveClassifierType" data-form="${esc(formID)}" data-platform-id="${esc(binding.id)}">${tx("data.applyClassifierType")}</button>${statusPill(t(typeStatus), binding.activeClassifierTypeID ? "navy" : "muted")}</div>${creatorRows.length ? `<details class="collection-creators" data-collection-creators-platform="${esc(binding.id)}"${creatorListOpen ? " open" : ""}><summary class="collection-creators-summary"><span>${tx("data.sourceCount", { count: creatorRows.length, sources: sourceTerms.plural })}</span><span>${tx("data.entryCount", { count: entryTotal })}</span></summary><div class="collection-master-detail"><div class="collection-master">${listSearchBox(`collection-master-${binding.id}`, "bridge.searchSources")}${creatorList}</div>${detailPane}</div></details>` : `<div class="empty collection-empty">${tx(binding.collectionEnabled ? "data.waitingForEntries" : "data.collectionDisabledCopy")}</div>`}</section>`;
    };
    return `<div class="workspace collection-workspace">${header("data.title", "data.copy", t("data.entries", { count: totalCollectedEntries }), "cyan")}
      <section class="collection-platform-create" data-form-id="collection-platform-create-form"><div><span class="eyebrow">${tx("data.addPlatform")}</span><p class="section-copy">${tx("data.addPlatformCopy")}</p></div>${availablePlatforms.length ? `${valueSelectField("data.platform", "", "platformID", availablePlatforms[0].id, availablePlatforms.map((platform) => [platform.id, platform.name]))}<button class="primary" data-action="addCollectionPlatform" data-form="collection-platform-create-form">${tx("data.addPlatformAction")}</button>` : `<span class="small-copy">${tx("data.allPlatformsAdded")}</span>`}</section>
      <div class="collection-platform-panels">${bindings.length ? bindings.map(bindingPanel).join("") : `<div class="empty">${tx("data.noPlatforms")}</div>`}</div>
      ${notice(state.issue, "red")}</div>`;
  }

  function workspace() {
    switch (state.workspace) {
      case "llmAssist": return llmAssistWorkspace();
      case "browserBridge": return browserBridgeWorkspace();
      case "classificationData": return classificationDataWorkspace();
      case "knowledge": return knowledgeWorkspace();
      default: return tagTreeWorkspace();
    }
  }

  function drawTreeConnections() {
    root.querySelectorAll("[data-tree-map]").forEach((map) => {
      const content = map.querySelector(".tree-map-content");
      const links = map.querySelector(".tree-links");
      if (!content || !links) return;

      const contentRect = content.getBoundingClientRect();
      const width = Math.ceil(content.offsetWidth);
      const height = Math.ceil(content.scrollHeight);
      links.setAttribute("viewBox", `0 0 ${width} ${height}`);
      links.setAttribute("width", width);
      links.setAttribute("height", height);

      const nodesByID = new Map([...content.querySelectorAll(".tree-map-node")].map((node) => [node.dataset.nodeId, node]));
      links.innerHTML = [...nodesByID.values()].map((node) => {
        const parent = node.dataset.parentId ? nodesByID.get(node.dataset.parentId) : null;
        if (!parent || parent === node) return "";
        const parentRect = parent.getBoundingClientRect();
        const nodeRect = node.getBoundingClientRect();
        const startX = Math.round(parentRect.left - contentRect.left + parentRect.width / 2);
        const startY = Math.round(parentRect.bottom - contentRect.top);
        const endX = Math.round(nodeRect.left - contentRect.left + nodeRect.width / 2);
        const endY = Math.round(nodeRect.top - contentRect.top);
        const bendY = Math.round((startY + endY) / 2);
        return `<path d="M ${startX} ${startY} V ${bendY} H ${endX} V ${endY}"/>`;
      }).join("");
    });
  }

  function traceTreeLayout() {
    root.querySelectorAll("[data-tree-map]").forEach((map) => {
      const content = map.querySelector(".tree-map-content");
      if (!content) return;
      const contentRect = content.getBoundingClientRect();
      const nodes = [...content.querySelectorAll(".tree-map-node")].slice(0, 12).map((node) => {
        const rect = node.getBoundingClientRect();
        return {
          id: node.dataset.nodeId,
          dataX: node.dataset.positionX,
          dataY: node.dataset.positionY,
          cssLeft: window.getComputedStyle(node).left,
          cssTop: window.getComputedStyle(node).top,
          renderX: Math.round(rect.left - contentRect.left + map.scrollLeft),
          renderY: Math.round(rect.top - contentRect.top + map.scrollTop),
        };
      });
      const popover = content.querySelector("[data-tree-popover]");
      const panel = popover ? {
        cssLeft: window.getComputedStyle(popover).left,
        cssTop: window.getComputedStyle(popover).top,
        renderX: Math.round(popover.getBoundingClientRect().left - contentRect.left + map.scrollLeft),
        renderY: Math.round(popover.getBoundingClientRect().top - contentRect.top + map.scrollTop),
      } : null;
      const detail = JSON.stringify({ scrollX: map.scrollLeft, scrollY: map.scrollTop, nodes, panel });
      const signature = `${map.dataset.treeId}:${detail}`;
      if (layoutTraceSignatures.get(map.dataset.treeId) === signature) return;
      layoutTraceSignatures.set(map.dataset.treeId, signature);
      send("layoutTrace", { phase: "render", treeID: map.dataset.treeId, detail });
    });
  }

  function traceTagDrag(phase, drag) {
    const node = drag.node;
    send("layoutTrace", {
      phase,
      treeID: drag.treeID,
      detail: JSON.stringify({
        id: drag.nodeID,
        dataX: node.dataset.positionX,
        dataY: node.dataset.positionY,
        cssLeft: window.getComputedStyle(node).left,
        cssTop: window.getComputedStyle(node).top,
      }),
    });
  }

  function tagRenameKey(treeID, nodeID) {
    return `${treeID}\u0000${nodeID}`;
  }

  function flushLiveTagRename(treeID, nodeID) {
    const key = tagRenameKey(treeID, nodeID);
    const name = pendingTagRenames.get(key);
    pendingTagRenames.delete(key);
    if (!name?.trim()) return;
    send("renameTag", { treeID, nodeID, name });
  }

  function flushTagNameInput(input) {
    if (!input) return;
    const { treeId: treeID, nodeId: nodeID } = input.dataset;
    if (!treeID || !nodeID) return;
    pendingTagRenames.set(tagRenameKey(treeID, nodeID), input.value);
    flushLiveTagRename(treeID, nodeID);
  }

  function updateRenderedTagName(treeID, nodeID, name) {
    root.querySelectorAll(".tree-map-node").forEach((node) => {
      if (node.dataset.treeId === treeID && node.dataset.nodeId === nodeID) {
        node.querySelector("strong").textContent = name;
      }
    });
  }

  function openTagEditor(treeID, nodeID) {
    const node = [...root.querySelectorAll(".tree-map-node")].find((candidate) => candidate.dataset.treeId === treeID && candidate.dataset.nodeId === nodeID);
    if (!node) return;
    selectedTagNode = { treeID, nodeID };
    const nodeX = Number(node.dataset.positionX) || 0;
    const nodeY = Number(node.dataset.positionY) || 0;
    activeTagPanel = { kind: "edit", treeID, nodeID, x: nodeX + node.offsetWidth + 12, y: nodeY };
    render();
  }

  function openTreePanel(treeID, kind) {
    const map = root.querySelector(`[data-tree-map][data-tree-id="${treeID}"]`);
    if (!map) return;
    selectedTagNode = null;
    connectionSource = null;
    activeTagPanel = {
      kind,
      treeID,
      x: map.scrollLeft + Math.max(16, Math.round((map.clientWidth - 256) / 2)),
      y: map.scrollTop + Math.max(56, Math.round((map.clientHeight - 174) / 2)),
    };
    render();
  }

  document.addEventListener("input", (event) => {
    const searchInput = event.target.closest("input[data-list-search]");
    if (searchInput) {
      const group = searchInput.dataset.listSearch;
      listSearchQueryByGroup.set(group, searchInput.value);
      scheduleListSearch(group);
      return;
    }
    const deletionInput = event.target.closest("[data-deletion-name-input]");
    if (deletionInput) {
      const confirmButton = root.querySelector('[data-action="confirmPendingDeletion"]');
      if (confirmButton) confirmButton.disabled = deletionInput.value.trim() !== (pendingDeletion?.name || "").trim();
      return;
    }
    const input = event.target.closest("input[data-live-tag-name]");
    if (!input) return;
    const { treeId: treeID, nodeId: nodeID } = input.dataset;
    if (!treeID || !nodeID) return;
    const key = tagRenameKey(treeID, nodeID);
    pendingTagRenames.set(key, input.value);
    updateRenderedTagName(treeID, nodeID, input.value);
  });

  function rememberTreeViewportPositions() {
    root.querySelectorAll("[data-tree-map]").forEach((map) => {
      treeViewportPositions.set(map.dataset.treeId, { x: map.scrollLeft, y: map.scrollTop });
    });
  }

  function restoreTreeViewportPositions() {
    root.querySelectorAll("[data-tree-map]").forEach((map) => {
      const position = treeViewportPositions.get(map.dataset.treeId);
      if (!position) return;
      map.scrollLeft = position.x;
      map.scrollTop = position.y;
    });
  }

  function rememberEditorViewportPosition() {
    const editor = root.querySelector("[data-editor-panel]");
    const workspace = editor?.dataset.workspace;
    if (!editor || !workspace) return;
    editorViewportPositions.set(workspace, { x: editor.scrollLeft, y: editor.scrollTop });
  }

  function restoreEditorViewportPosition() {
    const editor = root.querySelector("[data-editor-panel]");
    const workspace = editor?.dataset.workspace;
    const position = workspace ? editorViewportPositions.get(workspace) : null;
    if (!editor || !position) return;
    editor.scrollLeft = position.x;
    editor.scrollTop = position.y;
  }

  function applyApplicablePlatformCapabilities() {
    const definitions = new Map((state?.assets?.collectionPlatforms || []).map((platform) => [platform.id, platform]));
    root.querySelectorAll(".classifier-type-panel").forEach((panel) => {
      const sourceControl = panel.querySelector('[data-field="applicablePlatformID"]');
      if (!sourceControl) return;
      const platform = definitions.get(sourceControl.value);
      const supportsLocalModel = platform?.supportsLocalModel === true;
      const isCollectionOnlyPlatform = Boolean(platform && !supportsLocalModel);
      panel.querySelectorAll("[data-local-model-section]").forEach((section) => { section.hidden = !supportsLocalModel; });
      let note = panel.querySelector("[data-collection-only-platform-note]");
      if (!note) {
        note = document.createElement("p");
        note.className = "small-copy";
        note.dataset.collectionOnlyPlatformNote = "";
        note.textContent = t("bridge.collectionOnlyCopy");
        panel.querySelector(".classifier-applicable-platform-section")?.append(note);
      }
      if (note) note.hidden = !isCollectionOnlyPlatform;
    });
  }

  // A deleted entity leaves a small in-place tombstone (name + restore /
  // permanently-delete). It auto-purges 24h after deletion (native, on launch).
  function trashTombstone(entry) {
    return `<div class="trash-tombstone"><span class="trash-tombstone-name" dir="auto">${esc(entry.name)}</span><span class="trash-tombstone-meta">${tx("trash.deleted")}</span><span class="trash-tombstone-actions"><button class="secondary" data-action="restoreTrashedEntry" data-id="${esc(entry.id)}">${tx("trash.restore")}</button><button class="danger" data-action="permanentlyDeleteTrashedEntry" data-id="${esc(entry.id)}">${tx("trash.permanentlyDelete")}</button></span></div>`;
  }

  function trashOfKind(kind) {
    return (Array.isArray(state?.trash) ? state.trash : [])
      .filter((entry) => entry.kind === kind)
      .map(trashTombstone)
      .join("");
  }

  // Type-the-name delete confirmation for a "massive data" entity.
  function deletionModal() {
    if (!pendingDeletion) return "";
    return `<div class="utility-popover-layer" role="presentation"><button class="utility-popover-dismiss" data-action="cancelPendingDeletion" aria-label="${tx("common.cancel")}"></button><div class="deletion-dialog" role="dialog" aria-modal="true"><h3>${tx("trash.confirmTitle")}</h3><p class="section-copy">${tx("trash.confirmCopy", { name: pendingDeletion.name })}</p><label class="field"><span class="field-label">${tx("trash.typeNameLabel")}</span><input type="text" data-deletion-name-input autocomplete="off" spellcheck="false"></label><div class="action-row"><button class="secondary" data-action="cancelPendingDeletion">${tx("common.cancel")}</button><button class="danger" data-action="confirmPendingDeletion" disabled>${tx("trash.confirmDelete")}</button></div></div></div>`;
  }

  // Create-a-group dialog. A classifier group can only be created here, and only
  // from a preset — the preset seeds the model + research settings so nobody
  // hand-tunes them at creation. Platform and name are also chosen here.
  function createTypeModal() {
    if (!pendingCreateType) return "";
    const presets = state.assets?.presets || [];
    const platforms = state.assets?.collectionPlatforms || [];
    if (!presets.length || !platforms.length) return "";
    const selectedPresetID = pendingCreateType.presetID || state.assets?.defaultPresetID || presets[0].id;
    const selectedPlatformID = pendingCreateType.platformID || platforms[0].id;
    const presetCards = presets.map((preset) => {
      const active = preset.id === selectedPresetID;
      const badge = preset.isDefault ? `<span class="preset-card-badge">${tx("preset.default.badge")}</span>` : "";
      return `<button type="button" class="preset-card${active ? " active" : ""}" role="radio" aria-checked="${active}" data-action="selectCreatePreset" data-preset-id="${esc(preset.id)}"><span class="preset-card-head"><span class="preset-card-name">${tx(preset.nameKey)}</span>${badge}</span><span class="preset-card-desc">${tx(preset.descKey)}</span></button>`;
    }).join("");
    const platformOptions = platforms.map((platform) => `<option value="${esc(platform.id)}"${platform.id === selectedPlatformID ? " selected" : ""}>${esc(platform.name)} · ${esc(platform.browser)}</option>`).join("");
    return `<div class="utility-popover-layer" role="presentation"><button class="utility-popover-dismiss" data-action="cancelCreateType" aria-label="${tx("common.cancel")}"></button><div class="deletion-dialog create-type-dialog" role="dialog" aria-modal="true"><h3>${tx("createType.title")}</h3><p class="section-copy">${tx("createType.copy")}</p><div class="field"><span class="field-label">${tx("createType.presetLabel")}</span><div class="preset-card-grid" role="radiogroup" aria-label="${tx("createType.presetLabel")}">${presetCards}</div></div><label class="field"><span class="field-label">${tx("createType.platformLabel")}</span><select data-create-type-platform>${platformOptions}</select></label><label class="field"><span class="field-label">${tx("createType.nameLabel")}</span><input type="text" data-create-type-name autocomplete="off" spellcheck="false" value="${esc(pendingCreateType.name != null ? pendingCreateType.name : t("createType.defaultName"))}"></label><div class="action-row"><button class="secondary" data-action="cancelCreateType">${tx("common.cancel")}</button><button class="primary" data-action="confirmCreateType">${tx("createType.create")}</button></div></div></div>`;
  }

  // Keyed list: rendered as an empty container in the shell (so its row data is
  // excluded from the render signature) and populated/updated by
  // reconcileKeyedLists. On a state push that only changes row data, render()
  // updates just the changed rows in place and preserves the container's
  // scroll, instead of rebuilding the page.
  function keyedList(id, items, keyOf, renderRow, { emptyMarkup = "", listClass = "", searchOf = null, searchGroup = "" } = {}) {
    const rawQuery = searchGroup ? (listSearchQueryByGroup.get(searchGroup) || "") : "";
    const filtered = (searchOf && rawQuery.trim()) ? rankItems(items, searchOf, rawQuery) : items;
    keyedListRegistry.set(id, { items: filtered, allItems: items, keyOf, renderRow, emptyMarkup, searchOf });
    return `<div${listClass ? ` class="${esc(listClass)}"` : ""} data-keyed-list="${esc(id)}"${searchGroup ? ` data-search-group="${esc(searchGroup)}"` : ""}></div>`;
  }

  function reconcileKeyedLists() {
    root.querySelectorAll("[data-keyed-list]").forEach((container) => {
      const reg = keyedListRegistry.get(container.dataset.keyedList);
      if (reg) reconcileKeyedList(container, reg);
    });
  }

  function reconcileKeyedList(container, { items, keyOf, renderRow, emptyMarkup }) {
    const id = container.dataset.keyedList;
    let rendered = keyedListRenderedRows.get(id);
    if (!rendered) { rendered = new Map(); keyedListRenderedRows.set(id, rendered); }
    if (!items.length) {
      if (container.dataset.keyedEmpty !== "true") { container.innerHTML = emptyMarkup; container.dataset.keyedEmpty = "true"; }
      rendered.clear();
      return;
    }
    if (container.dataset.keyedEmpty === "true") { container.innerHTML = ""; delete container.dataset.keyedEmpty; }
    const existing = new Map();
    container.querySelectorAll(":scope > [data-key]").forEach((el) => existing.set(el.dataset.key, el));
    const desired = new Set();
    let prev = null;
    for (const item of items) {
      const key = String(keyOf(item));
      desired.add(key);
      const html = renderRow(item);
      let el = existing.get(key);
      if (el) {
        if (rendered.get(key) !== html) { el.innerHTML = html; rendered.set(key, html); }
      } else {
        el = document.createElement("div");
        el.className = "keyed-row";
        el.dataset.key = key;
        el.innerHTML = html;
        rendered.set(key, html);
        existing.set(key, el);
      }
      const anchor = prev ? prev.nextSibling : container.firstChild;
      if (el !== anchor) container.insertBefore(el, anchor);
      prev = el;
    }
    existing.forEach((el, key) => {
      if (!desired.has(key)) { el.remove(); rendered.delete(key); }
    });
  }

  // Live region: an empty container in the shell whose inner markup is updated
  // in place by reconcileLiveHTML — for small volatile bits (status counters)
  // that change alongside a keyed list.
  function liveHTML(id, html, { tag = "span", className = "" } = {}) {
    liveHTMLRegistry.set(id, html);
    return `<${tag}${className ? ` class="${esc(className)}"` : ""} data-live-html="${esc(id)}"></${tag}>`;
  }

  function reconcileLiveHTML() {
    root.querySelectorAll("[data-live-html]").forEach((el) => {
      const id = el.dataset.liveHtml;
      const html = liveHTMLRegistry.get(id);
      if (html == null) return;
      if (liveHTMLRendered.get(id) !== html) { el.innerHTML = html; liveHTMLRendered.set(id, html); }
    });
  }

  function render() {
    if (!state) {
      root.innerHTML = `<div class="popup"><div class="empty">${tx("app.loading")}</div></div>`;
      lastRenderedMarkup = null;
      return;
    }
    resetDeferredRendering();
    const markup = shell(workspace()) + deletionModal() + createTypeModal();
    // Fast path: the signature (everything except keyed-list rows, live
    // regions, and windowed virtual-list rows) is unchanged, so only
    // reconcilable data differs. Update those in place and keep scroll. Virtual
    // lists re-register with identical ids on identical markup, so their windows
    // can be repainted here rather than forcing a full rebuild. Any failure
    // falls back to a full rebuild, so the worst case is the previous behavior.
    if (markup === lastRenderedMarkup && root.firstChild) {
      try {
        reconcileLiveHTML();
        reconcileKeyedLists();
        repaintVirtualLists();
        refreshAllListSearchMeta();
        return;
      } catch (_) { /* fall through to full render */ }
    }
    renderFull(markup);
  }

  function renderFull(markup) {
    rememberTreeViewportPositions();
    rememberEditorViewportPosition();
    // A snapshot push can rebuild the DOM while the user is typing in a list
    // search (classification runs push often). Preserve which search box was
    // focused and the caret so search-as-you-type is not interrupted.
    const focusedSearch = document.activeElement?.closest?.("input[data-list-search]");
    const focusedSearchState = focusedSearch
      ? { group: focusedSearch.dataset.listSearch, start: focusedSearch.selectionStart, end: focusedSearch.selectionEnd }
      : null;
    virtualListResizeObserver?.disconnect();
    keyedListRenderedRows.clear();
    liveHTMLRendered.clear();
    root.innerHTML = markup;
    lastRenderedMarkup = markup;
    applyApplicablePlatformCapabilities();
    setupVirtualLists();
    bindTreeMapWheel();
    reconcileLiveHTML();
    reconcileKeyedLists();
    refreshAllListSearchMeta();
    if (focusedSearchState) {
      const restored = [...root.querySelectorAll("input[data-list-search]")]
        .find((input) => input.dataset.listSearch === focusedSearchState.group);
      if (restored) {
        restored.focus();
        try { restored.setSelectionRange(focusedSearchState.start, focusedSearchState.end); } catch (_) { /* non-text input */ }
      }
    }
    window.requestAnimationFrame(() => {
      applyNavigationPanelWidth();
      restoreEditorViewportPosition();
      restoreTreeViewportPositions();
      drawTreeConnections();
      traceTreeLayout();
    });
  }

  // Attach the non-passive tree-map wheel handler only to the tree canvases in
  // the freshly rendered DOM, leaving every other scroll container passive.
  function bindTreeMapWheel() {
    root.querySelectorAll("[data-tree-map]").forEach((map) => {
      map.addEventListener("wheel", handleTreeMapWheel, { passive: false });
    });
  }

  document.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-action]");
    if (!button) {
      const map = event.target.closest("[data-tree-map]");
      if (map && !event.target.closest(".tree-map-node, [data-tree-popover]")) {
        flushTagNameInput(map.querySelector("input[data-live-tag-name]"));
        activeTagPanel = null;
        connectionSource = null;
        selectedTagNode = null;
        render();
      }
      return;
    }
    if (button.disabled) return;
    const action = button.dataset.action;
    if (action === "switchScene") {
      // Header scene switch (Vault / Classifier / Activity). Classifier is the
      // active scene here; ask the native host to show another one.
      if (button.dataset.scene) send("switch-scene", { scene: button.dataset.scene });
      return;
    }
    if (action === "toggleAdvancedSettings") {
      // Class toggle only — a full render would replace the node and kill the
      // expand/collapse transition mid-flight.
      advancedSettingsOpen = !advancedSettingsOpen;
      const wrap = button.closest("[data-advanced-settings]");
      if (wrap) {
        wrap.classList.toggle("open", advancedSettingsOpen);
        button.setAttribute("aria-expanded", String(advancedSettingsOpen));
      }
      return;
    }
    if (action === "toggleLocalModelAdvanced") {
      localModelAdvancedOpen = !localModelAdvancedOpen;
      const wrap = button.closest("[data-local-model-advanced]");
      if (wrap) {
        wrap.classList.toggle("open", localModelAdvancedOpen);
        button.setAttribute("aria-expanded", String(localModelAdvancedOpen));
      }
      return;
    }
    if (action === "toggleResearchAdvanced") {
      researchAdvancedOpen = !researchAdvancedOpen;
      const wrap = button.closest("[data-research-advanced]");
      if (wrap) {
        wrap.classList.toggle("open", researchAdvancedOpen);
        button.setAttribute("aria-expanded", String(researchAdvancedOpen));
      }
      return;
    }
    if (action === "workspace") {
      const nextWorkspace = button.dataset.workspace;
      if (!state || !workspaceNames.has(nextWorkspace) || state.workspace === nextWorkspace) return;
      state.workspace = nextWorkspace;
      render();
      send("workspace", { workspace: nextWorkspace });
      return;
    }
    if (action === "selectType") {
      // A drag just ended: the trailing click must not also select.
      if (Date.now() < suppressTypeSelectUntil) return;
      const id = button.dataset.typeId;
      if (!id) return;
      selectedTypeID = id;
      if (state.workspace !== "browserBridge") { state.workspace = "browserBridge"; send("workspace", { workspace: "browserBridge" }); }
      render();
      return;
    }
    if (action === "selectTrash") {
      const id = button.dataset.id;
      selectedTrashID = selectedTrashID === id ? null : id;
      render();
      return;
    }
    if (action === "newType") {
      const platforms = state.assets?.collectionPlatforms || [];
      const presets = state.assets?.presets || [];
      if (!platforms.length || !presets.length) return;
      // Open the create-a-group dialog. A group can only be created from a preset,
      // so there is no direct-create path any more.
      pendingCreateType = {
        presetID: state.assets?.defaultPresetID || presets[0].id,
        platformID: platforms[0].id,
      };
      render();
      return;
    }
    if (action === "selectCreatePreset") {
      if (pendingCreateType) {
        // Preserve the platform/name the person may have already chosen.
        const nameInput = root.querySelector("[data-create-type-name]");
        const platformSelect = root.querySelector("[data-create-type-platform]");
        pendingCreateType = {
          presetID: button.dataset.presetId,
          platformID: platformSelect?.value || pendingCreateType.platformID,
          name: nameInput ? nameInput.value : pendingCreateType.name,
        };
        render();
      }
      return;
    }
    if (action === "cancelCreateType") {
      pendingCreateType = null;
      render();
      return;
    }
    if (action === "confirmCreateType") {
      if (!pendingCreateType) return;
      const nameInput = root.querySelector("[data-create-type-name]");
      const platformSelect = root.querySelector("[data-create-type-platform]");
      const name = ((nameInput?.value) || t("createType.defaultName")).trim() || t("createType.defaultName");
      const platformID = platformSelect?.value || pendingCreateType.platformID;
      const presetID = pendingCreateType.presetID;
      if (!platformID || !presetID) return;
      pendingSelectNewType = new Set((state.assets?.classifierTypes || []).map((type) => type.id));
      pendingCreateType = null;
      render();
      send("createClassifierType", { name, platformID, presetID });
      return;
    }
    if (action === "confirmDeleteClassifierType" || action === "confirmDeleteCollectionPlatform") {
      pendingDeletion = {
        action,
        name: button.dataset.name || "",
        payload: action === "confirmDeleteClassifierType"
          ? { typeID: button.dataset.typeId }
          : { platformID: button.dataset.platformId },
      };
      render();
      return;
    }
    if (action === "cancelPendingDeletion") {
      pendingDeletion = null;
      render();
      return;
    }
    if (action === "confirmPendingDeletion") {
      const input = root.querySelector("[data-deletion-name-input]");
      if (!pendingDeletion || (input?.value || "").trim() !== pendingDeletion.name.trim()) return;
      const pending = pendingDeletion;
      pendingDeletion = null;
      render();
      send(pending.action, pending.payload);
      return;
    }
    const data = button.dataset.form ? collect(button.dataset.form) : {};
    if (button.dataset.workspace) data.workspace = button.dataset.workspace;
    if (button.dataset.id) data.id = button.dataset.id;
    if (button.dataset.utilityPanel) data.utilityPanel = button.dataset.utilityPanel;
    if (button.dataset.profileId) data.profileID = button.dataset.profileId;
    if (button.dataset.treeId) data.treeID = button.dataset.treeId;
    if (button.dataset.nodeId) data.nodeID = button.dataset.nodeId;
    if (button.dataset.parentId) data.parentID = button.dataset.parentId;
    if (button.dataset.platformId) data.platformID = button.dataset.platformId;
    if (button.dataset.typeId) data.typeID = button.dataset.typeId;
    if (button.dataset.entryId) data.entryID = button.dataset.entryId;
    if (button.dataset.fileName) data.fileName = button.dataset.fileName;
    if (action === "submitCorrection") {
      loadedCreatorEntries.forEach((entries) => {
        const entry = entries.find((candidate) => candidate.platformID === data.platformID && candidate.entryID === data.entryID);
        const form = entry?.correctionForms?.find((candidate) => candidate.typeID === data.typeID);
        if (!form) return;
        form.correctTagIDs = Array.isArray(data.correctTagIDs) ? data.correctTagIDs : [];
        form.note = data.note || "";
        form.corrected = true;
      });
      send(action, data);
      return;
    }
    if (action === "testProviderProfile") Object.assign(data, providerConnectionPayload(data, button.dataset.form));
    if (action === "selectCollectionCreator") {
      const platformID = button.dataset.platformId;
      const creatorID = button.dataset.creatorId;
      const datasetID = button.dataset.datasetId;
      if (!platformID || !creatorID) return;
      selectedCollectionCreatorByPlatform.set(platformID, creatorID);
      // Targeted: move the selection highlight and swap only this platform's
      // detail pane. The master list and the rest of the page are untouched —
      // no full re-render. Entries load lazily if not already cached.
      const master = button.closest(".collection-master");
      master?.querySelectorAll(".collection-creator-row.selected").forEach((row) => row.classList.remove("selected"));
      button.classList.add("selected");
      const creatorName = button.querySelector(".collection-creator-name")?.textContent || creatorID;
      updateCollectionDetailPane(datasetID, platformID, creatorID, creatorName);
      requestCreatorEntries(datasetID, platformID, creatorID);
      return;
    }
    if (action === "cancelTagPanel") {
      flushTagNameInput(button.closest("[data-tree-popover]")?.querySelector("input[data-live-tag-name]"));
      activeTagPanel = null;
      render();
      return;
    }
    if (action === "saveTagName") {
      if (!data.name?.trim()) return;
      pendingTagRenames.delete(tagRenameKey(button.dataset.treeId, button.dataset.nodeId));
      activeTagPanel = null;
      render();
      send("updateTag", {
        treeID: button.dataset.treeId,
        nodeID: button.dataset.nodeId,
        name: data.name,
        description: data.description || "",
      });
      return;
    }
    if (action === "openUtilityPanel") {
      const nextPanel = data.utilityPanel === "settings" ? "settings" : null;
      utilityPanel = utilityPanel === nextPanel ? null : nextPanel;
      render();
      return;
    }
    if (action === "closeUtilityPanel") {
      utilityPanel = null;
      render();
      return;
    }
    if (action === "selectTag") {
      if (suppressTagClick) return;
      if (connectionSource) {
        if (button.dataset.treeId !== connectionSource.treeID || button.dataset.nodeId === connectionSource.nodeID) return;
        const source = connectionSource;
        flushLiveTagRename(source.treeID, source.nodeID);
        connectionSource = null;
        selectedTagNode = source;
        activeTagPanel = null;
        render();
        send("connectTag", { treeID: source.treeID, nodeID: source.nodeID, parentID: button.dataset.nodeId });
        return;
      }
      flushTagNameInput(root.querySelector("[data-tree-popover] input[data-live-tag-name]"));
      openTagEditor(button.dataset.treeId, button.dataset.nodeId);
      return;
    }
    if (action === "beginConnection") {
      flushLiveTagRename(button.dataset.treeId, button.dataset.nodeId);
      selectedTagNode = { treeID: button.dataset.treeId, nodeID: button.dataset.nodeId };
      connectionSource = { treeID: button.dataset.treeId, nodeID: button.dataset.nodeId };
      activeTagPanel = null;
      render();
      return;
    }
    if (action === "disconnectTag") {
      flushLiveTagRename(button.dataset.treeId, button.dataset.nodeId);
      connectionSource = null;
      selectedTagNode = { treeID: button.dataset.treeId, nodeID: button.dataset.nodeId };
      activeTagPanel = null;
      render();
      send("disconnectTag", { treeID: button.dataset.treeId, nodeID: button.dataset.nodeId });
      return;
    }
    if (action === "deleteTag") {
      flushLiveTagRename(button.dataset.treeId, button.dataset.nodeId);
      connectionSource = null;
      selectedTagNode = null;
      activeTagPanel = null;
      render();
      send("deleteTag", { treeID: button.dataset.treeId, nodeID: button.dataset.nodeId });
      return;
    }
    if (action === "renameTree") {
      openTreePanel(button.dataset.treeId, "tree");
      return;
    }
    if (action === "saveTreeName") {
      if (!data.name?.trim()) return;
      activeTagPanel = null;
      render();
      send("renameTree", { treeID: button.dataset.treeId, name: data.name });
      return;
    }
    if (action === "rearrangeTree") {
      selectedTagNode = null;
      connectionSource = null;
      activeTagPanel = null;
      render();
      send("rearrangeTree", { treeID: button.dataset.treeId });
      return;
    }
    if (action === "deleteTree") {
      openTreePanel(button.dataset.treeId, "delete-tree");
      return;
    }
    if (action === "confirmDeleteTree") {
      connectionSource = null;
      selectedTagNode = null;
      activeTagPanel = null;
      render();
      send("deleteTree", { treeID: button.dataset.treeId });
      return;
    }
    if (action === "deleteProviderProfile") {
      send("confirmDeleteProviderProfile", data);
      return;
    }
    if (action === "addTag") {
      if (!activeTagPanel || activeTagPanel.kind !== "create") return;
      data.parentID = activeTagPanel.parentID || "";
      data.positionX = activeTagPanel.x;
      data.positionY = activeTagPanel.y;
      activeTagPanel = null;
      render();
      send(action, data);
      return;
    }
    send(action, data);
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || !utilityPanel) return;
    utilityPanel = null;
    render();
  });

  document.addEventListener("toggle", (event) => {
    const details = event.target;
    if (!details?.matches?.("details")) return;
    if (details.matches("details[data-collection-creators-platform]")) {
      if (details.open) collapsedCollectionCreatorLists.delete(details.dataset.collectionCreatorsPlatform);
      else collapsedCollectionCreatorLists.add(details.dataset.collectionCreatorsPlatform);
    }
  }, true);

  document.addEventListener("change", (event) => {
    const languageControl = event.target.closest("[data-language-selection]");
    if (languageControl) {
      if (!languageChoices.some(([identifier]) => identifier === languageControl.value)) return;
      selectedLanguage = languageControl.value;
      document.documentElement.lang = selectedLanguage;
      try { window.localStorage.setItem("vaultClassifier.language", selectedLanguage); } catch (_) {}
      return;
    }
    const providerConnectionControl = event.target.closest("[data-provider-connection]");
    if (providerConnectionControl) {
      const panel = providerConnectionControl.closest("[data-provider-panel]");
      const formID = panel?.dataset.formId;
      const profileID = panel?.dataset.providerId;
      if (!formID || !profileID) return;
      const values = collect(formID);
      send("updateProviderConnection", { profileID, ...providerConnectionPayload(values, formID) });
      return;
    }
    if (event.target.closest('[data-field="applicablePlatformID"]')) {
      applyApplicablePlatformCapabilities();
      return;
    }
  });

  document.addEventListener("pointerdown", (event) => {
    const resizer = event.target.closest("[data-navigation-resizer]");
    if (!resizer || event.button !== 0) return;
    navigationResize = { pointerID: event.pointerId };
    resizer.setPointerCapture?.(event.pointerId);
    event.preventDefault();
  });

  document.addEventListener("pointermove", (event) => {
    if (!navigationResize || event.pointerId !== navigationResize.pointerID) return;
    const layout = root.querySelector(".layout");
    if (!layout) return;
    const bounds = layout.getBoundingClientRect();
    const width = Math.round(event.clientX - bounds.left);
    navigationPanelWidth = Math.min(navigationWidthRange.maximum, Math.max(navigationWidthRange.minimum, width));
    applyNavigationPanelWidth();
    event.preventDefault();
  });

  function finishNavigationResize(event) {
    if (!navigationResize || event.pointerId !== navigationResize.pointerID) return;
    navigationResize = null;
    try { window.localStorage.setItem(navigationWidthStorageKey, String(navigationPanelWidth)); } catch (_) {}
  }

  document.addEventListener("pointerup", finishNavigationResize);
  document.addEventListener("pointercancel", finishNavigationResize);

  // Drag-reorder the classifier-type list. Ported from the extension's group
  // reorder (customBlocker/popup.js): the whole row is the drag target (no
  // handle), a movement threshold keeps a short press a select, the dragged row
  // is clamped so it cannot leave the top of the list ("ceiling"), the others
  // glide aside, and on release the dragged row snaps to its slot.
  function typeNavElement() { return root.querySelector("[data-classifier-type-nav]"); }
  function getTypeDragCards() {
    const nav = typeNavElement();
    return nav ? Array.from(nav.querySelectorAll(".classifier-type-row[data-type-id]")) : [];
  }
  function getTypeCardGap() {
    const nav = typeNavElement();
    if (!nav) return 0;
    const computed = window.getComputedStyle(nav);
    const parsed = Number.parseFloat(computed.rowGap || computed.gap || "0");
    return Number.isFinite(parsed) ? parsed : 0;
  }
  function resetTypeDragLayout() {
    const nav = typeNavElement();
    if (nav) nav.classList.remove("is-reordering");
    for (const card of getTypeDragCards()) {
      card.classList.remove("dragging");
      card.style.removeProperty("transform");
      card.style.removeProperty("transition");
      card.style.removeProperty("z-index");
    }
  }
  function createTypeDragContext(typeID, pointerY) {
    const nav = typeNavElement();
    const cards = getTypeDragCards();
    const sourceIndex = cards.findIndex((card) => card.dataset.typeId === typeID);
    if (sourceIndex === -1 || !nav) return null;
    const draggedRect = cards[sourceIndex].getBoundingClientRect();
    const listRect = nav.getBoundingClientRect();
    const gap = getTypeCardGap();
    return {
      cards,
      sourceIndex,
      startY: pointerY,
      pointerOffsetY: pointerY - draggedRect.top,
      draggedHeight: draggedRect.height,
      minTop: listRect.top,
      shiftDistance: draggedRect.height + gap,
      rects: cards.map((card) => card.getBoundingClientRect())
    };
  }
  function getTypeDragInsertIndex(context, pointerY) {
    const draggedTop = pointerY - context.pointerOffsetY;
    const draggedCenterY = draggedTop + context.draggedHeight / 2;
    let insertIndex = 0;
    for (let i = 0; i < context.rects.length; i++) {
      if (i === context.sourceIndex) continue;
      const rect = context.rects[i];
      if (draggedCenterY > rect.top + rect.height / 2) insertIndex += 1;
    }
    return insertIndex;
  }
  let typeDragInsertIndex = -1;
  function applyTypeDragLayout(context, pointerY) {
    if (!context) return;
    const clampedPointerY = Math.max(pointerY, context.minTop + context.pointerOffsetY);
    const dragY = clampedPointerY - context.startY;
    const insertIndex = getTypeDragInsertIndex(context, clampedPointerY);
    typeDragInsertIndex = insertIndex;
    for (let i = 0; i < context.cards.length; i++) {
      const card = context.cards[i];
      let offsetY = 0;
      if (i === context.sourceIndex) { offsetY = dragY; card.style.zIndex = "20"; }
      else if (insertIndex > context.sourceIndex && i > context.sourceIndex && i <= insertIndex) offsetY = -context.shiftDistance;
      else if (insertIndex < context.sourceIndex && i >= insertIndex && i < context.sourceIndex) offsetY = context.shiftDistance;
      if (offsetY === 0) card.style.removeProperty("transform");
      else card.style.transform = `translateY(${offsetY}px)`;
    }
  }
  function getTypeDragSnapOffset(context, insertIndex) {
    if (!context || !Number.isInteger(insertIndex)) return 0;
    const normalized = Math.max(0, Math.min(insertIndex, context.rects.length - 1));
    const sourceRect = context.rects[context.sourceIndex];
    const targetRect = context.rects[normalized];
    if (!sourceRect || !targetRect) return 0;
    return targetRect.top - sourceRect.top;
  }
  function finishTypeDragRelease(context, insertIndex, callback) {
    if (!context) { callback(); return; }
    const draggedCard = context.cards[context.sourceIndex];
    if (!draggedCard) { callback(); return; }
    const snapOffset = getTypeDragSnapOffset(context, insertIndex);
    const done = () => {
      draggedCard.removeEventListener("transitionend", handleTransitionEnd);
      window.clearTimeout(fallbackTimeout);
      callback();
    };
    const handleTransitionEnd = (event) => {
      if (event.target === draggedCard && event.propertyName === "transform") done();
    };
    const fallbackTimeout = window.setTimeout(done, 220);
    draggedCard.addEventListener("transitionend", handleTransitionEnd);
    draggedCard.style.transition = "transform 180ms ease, box-shadow 120ms ease, opacity 120ms ease";
    window.requestAnimationFrame(() => {
      if (snapOffset === 0) draggedCard.style.removeProperty("transform");
      else draggedCard.style.transform = `translateY(${snapOffset}px)`;
    });
  }

  const TYPE_DRAG_THRESHOLD_PX = 5;
  let suppressTypeSelectUntil = 0;
  function startTypeReorder(event, typeID) {
    if (event.button !== 0) return;
    const startX = event.clientX;
    const startY = event.clientY;
    let dragActive = false;
    let dragContext = null;
    const beginDrag = () => {
      dragContext = createTypeDragContext(typeID, startY);
      if (!dragContext) return;
      dragActive = true;
      document.body.style.userSelect = "none";
      const nav = typeNavElement();
      if (nav) nav.classList.add("is-reordering");
      dragContext.cards[dragContext.sourceIndex].classList.add("dragging");
      applyTypeDragLayout(dragContext, startY);
    };
    const handleMove = (moveEvent) => {
      if (!dragActive) {
        const dx = moveEvent.clientX - startX;
        const dy = moveEvent.clientY - startY;
        if (dx * dx + dy * dy < TYPE_DRAG_THRESHOLD_PX * TYPE_DRAG_THRESHOLD_PX) return;
        beginDrag();
      }
      if (!dragActive) return;
      moveEvent.preventDefault();
      applyTypeDragLayout(dragContext, moveEvent.clientY);
    };
    const handleUp = () => {
      window.removeEventListener("mousemove", handleMove);
      window.removeEventListener("mouseup", handleUp);
      if (!dragActive) return;
      document.body.style.userSelect = "";
      // The row's select click fires right after mouseup; suppress it so a drag
      // never doubles as a selection.
      suppressTypeSelectUntil = Date.now() + 250;
      const insertIndex = typeDragInsertIndex;
      const sourceIndex = dragContext.sourceIndex;
      if (!Number.isInteger(insertIndex) || insertIndex === sourceIndex) {
        finishTypeDragRelease(dragContext, sourceIndex, () => resetTypeDragLayout());
        return;
      }
      const ids = dragContext.cards.map((card) => card.dataset.typeId);
      const [draggedID] = ids.splice(sourceIndex, 1);
      ids.splice(Math.max(0, Math.min(insertIndex, ids.length)), 0, draggedID);
      // Snap into place, then persist. The layout is left in the dropped order
      // and the next snapshot re-renders it cleanly (no flash).
      finishTypeDragRelease(dragContext, insertIndex, () => {
        send("reorderClassifierTypes", { orderedIDs: ids });
      });
    };
    window.addEventListener("mousemove", handleMove);
    window.addEventListener("mouseup", handleUp);
  }

  document.addEventListener("mousedown", (event) => {
    const row = event.target.closest?.(".classifier-type-row[data-type-id]");
    if (!row) return;
    startTypeReorder(event, row.dataset.typeId);
  });

  document.addEventListener("keydown", (event) => {
    const resizer = event.target.closest?.("[data-navigation-resizer]");
    if (!resizer) return;
    let nextWidth = navigationPanelWidth;
    if (event.key === "ArrowLeft") nextWidth -= 16;
    else if (event.key === "ArrowRight") nextWidth += 16;
    else if (event.key === "Home") nextWidth = navigationWidthRange.minimum;
    else if (event.key === "End") nextWidth = navigationWidthRange.maximum;
    else return;
    event.preventDefault();
    navigationPanelWidth = Math.min(navigationWidthRange.maximum, Math.max(navigationWidthRange.minimum, nextWidth));
    applyNavigationPanelWidth();
    try { window.localStorage.setItem(navigationWidthStorageKey, String(navigationPanelWidth)); } catch (_) {}
  });

  // Mirror the Tags canvas: keep a two-axis trackpad gesture inside the tree
  // viewport instead of letting the surrounding editor consume it. Bound per
  // tree map (see bindTreeMapWheel) rather than on document — a non-passive
  // wheel listener on document forces every scroll on the page onto the main
  // thread, so unrelated re-renders showed up as scroll stutter in long lists.
  function handleTreeMapWheel(event) {
    if (event.ctrlKey || event.metaKey) return;
    const map = event.currentTarget;
    const horizontal = event.shiftKey && event.deltaX === 0 ? event.deltaY : event.deltaX;
    const vertical = event.shiftKey && event.deltaX === 0 ? 0 : event.deltaY;
    const startX = map.scrollLeft;
    const startY = map.scrollTop;
    map.scrollLeft += horizontal;
    map.scrollTop += vertical;
    if (map.scrollLeft !== startX || map.scrollTop !== startY) event.preventDefault();
    event.stopPropagation();
  }

  document.addEventListener("contextmenu", (event) => {
    const map = event.target.closest("[data-tree-map]");
    if (!map || event.target.closest("[data-tree-popover]")) return;
    event.preventDefault();
    const content = map.querySelector(".tree-map-content");
    const contentRect = content.getBoundingClientRect();
    const node = event.target.closest(".tree-map-node");
    const nodeX = node ? Number(node.dataset.positionX) || 0 : Math.max(12, Math.round(event.clientX - contentRect.left + map.scrollLeft));
    const nodeY = node ? Number(node.dataset.positionY) || 0 : Math.max(12, Math.round(event.clientY - contentRect.top + map.scrollTop));
    connectionSource = null;
    if (node) {
      openTagEditor(map.dataset.treeId, node.dataset.nodeId);
    } else {
      selectedTagNode = null;
      activeTagPanel = { kind: "create", treeID: map.dataset.treeId, parentID: "", x: nodeX, y: nodeY };
      render();
    }
  });

  function beginTagDrag(event) {
    const node = event.target.closest(".tree-map-node");
    if (!node || event.button !== 0 || tagDrag) return;
    const map = node.closest("[data-tree-map]");
    const nodesByID = new Map([...map.querySelectorAll(".tree-map-node")].map((candidate) => [candidate.dataset.nodeId, candidate]));
    const childrenByParentID = new Map();
    nodesByID.forEach((candidate) => {
      const parentID = candidate.dataset.parentId;
      if (!parentID) return;
      const children = childrenByParentID.get(parentID) || [];
      children.push(candidate);
      childrenByParentID.set(parentID, children);
    });
    const branchNodes = [];
    const pendingIDs = [node.dataset.nodeId];
    const visitedIDs = new Set();
    while (pendingIDs.length) {
      const currentID = pendingIDs.pop();
      if (!currentID || visitedIDs.has(currentID)) continue;
      visitedIDs.add(currentID);
      const currentNode = nodesByID.get(currentID);
      if (!currentNode) continue;
      branchNodes.push({
        node: currentNode,
        startX: Number(currentNode.dataset.positionX) || 0,
        startY: Number(currentNode.dataset.positionY) || 0,
      });
      (childrenByParentID.get(currentID) || []).forEach((child) => pendingIDs.push(child.dataset.nodeId));
    }
    tagDrag = {
      pointerID: event.pointerId ?? null,
      treeID: node.dataset.treeId,
      nodeID: node.dataset.nodeId,
      node,
      nodes: branchNodes,
      startPointerX: event.clientX,
      startPointerY: event.clientY,
      startNodeX: Number(node.dataset.positionX) || 0,
      startNodeY: Number(node.dataset.positionY) || 0,
      moved: false,
    };
    if (event.pointerId != null) node.setPointerCapture?.(event.pointerId);
    traceTagDrag("drag-start", tagDrag);
  }

  function moveTagDrag(event) {
    if (!tagDrag || (event.pointerId != null && event.pointerId !== tagDrag.pointerID)) return;
    const rawDeltaX = Math.round(event.clientX - tagDrag.startPointerX);
    const rawDeltaY = Math.round(event.clientY - tagDrag.startPointerY);
    if (!tagDrag.moved && Math.max(Math.abs(rawDeltaX), Math.abs(rawDeltaY)) < 3) return;
    tagDrag.moved = true;
    activeTagPanel = null;
    root.querySelector("[data-tree-popover]")?.remove();
    const minStartX = Math.min(...tagDrag.nodes.map((entry) => entry.startX));
    const minStartY = Math.min(...tagDrag.nodes.map((entry) => entry.startY));
    const maxStartX = Math.max(...tagDrag.nodes.map((entry) => entry.startX));
    const maxStartY = Math.max(...tagDrag.nodes.map((entry) => entry.startY));
    const deltaX = Math.max(-minStartX, Math.min(20_000 - maxStartX, rawDeltaX));
    const deltaY = Math.max(-minStartY, Math.min(20_000 - maxStartY, rawDeltaY));
    tagDrag.nodes.forEach((entry) => {
      const positionX = entry.startX + deltaX;
      const positionY = entry.startY + deltaY;
      entry.node.dataset.positionX = String(positionX);
      entry.node.dataset.positionY = String(positionY);
      entry.node.style.left = `${positionX}px`;
      entry.node.style.top = `${positionY}px`;
    });
    window.requestAnimationFrame(drawTreeConnections);
    event.preventDefault();
  }

  function finishTagDrag(event) {
    if (!tagDrag || (event.pointerId != null && event.pointerId !== tagDrag.pointerID)) return;
    const drag = tagDrag;
    tagDrag = null;
    if (!drag.moved) return;
    traceTagDrag("drag-end", drag);
    suppressTagClick = true;
    window.setTimeout(() => { suppressTagClick = false; }, 0);
    send("moveTag", {
      treeID: drag.treeID,
      nodeID: drag.nodeID,
      positionX: Number(drag.node.dataset.positionX) || 0,
      positionY: Number(drag.node.dataset.positionY) || 0,
    });
  }

  document.addEventListener("pointerdown", beginTagDrag);
  document.addEventListener("mousedown", beginTagDrag);
  document.addEventListener("pointermove", moveTagDrag);
  document.addEventListener("mousemove", moveTagDrag);
  document.addEventListener("pointerup", finishTagDrag);
  document.addEventListener("pointercancel", finishTagDrag);
  document.addEventListener("mouseup", finishTagDrag);

  window.VaultClassifier = {
    receive(payload) {
      const revision = Number(payload?.presentationRevision);
      if (Number.isSafeInteger(revision) && revision > 0) {
        if (revision <= renderedPresentationRevision) return;
        renderedPresentationRevision = revision;
      }
      state = payload;
      // Drop a stale left-panel selection if that type no longer exists.
      const typeIDs = new Set((state.assets?.classifierTypes || []).map((type) => type.id));
      if (selectedTypeID && !typeIDs.has(selectedTypeID)) selectedTypeID = null;
      // Close the trash panel if that entry was restored or purged.
      if (selectedTrashID && !(Array.isArray(state.trash) ? state.trash : []).some((entry) => entry.id === selectedTrashID)) selectedTrashID = null;
      // Tag trees are rendered inside their owning type, not as a top-level page.
      if (state.workspace === "tagTree") state.workspace = "browserBridge";
      // Open a just-created type: the one id absent before "New type" was clicked.
      if (pendingSelectNewType) {
        const created = (state.assets?.classifierTypes || []).find((type) => !pendingSelectNewType.has(type.id));
        if (created) { selectedTypeID = created.id; state.workspace = "browserBridge"; }
        pendingSelectNewType = null;
      }
      render();
    },
    // Targeted channel for one chosen creator's entries (see the native
    // deliverCreatorEntries). Caches the result and patches only the open
    // detail pane if this creator is still selected — never a full render.
    receiveCreatorEntries(payload) {
      const datasetID = payload?.datasetID;
      const platformID = payload?.platformID;
      const creatorID = payload?.creatorID;
      if (!datasetID || !platformID || !creatorID) return;
      const entries = Array.isArray(payload.entries) ? payload.entries : [];
      pendingCreatorEntryRequests.delete(creatorEntriesKey(datasetID, platformID, creatorID));
      loadedCreatorEntries.set(creatorEntriesKey(datasetID, platformID, creatorID), entries);
      if (selectedCollectionCreatorByPlatform.get(platformID) === creatorID) {
        updateCollectionDetailPane(datasetID, platformID, creatorID, entries[0]?.creatorName || creatorID);
      }
    },
  };

  window.addEventListener("resize", () => window.requestAnimationFrame(drawTreeConnections));
  render();
  send("state", {});
})();
