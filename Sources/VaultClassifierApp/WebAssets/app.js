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
  let renderedPayloadSignature = "";
  let activeTagPanel = null;
  let tagDrag = null;
  let suppressTagClick = false;
  let connectionSource = null;
  let selectedTagNode = null;
  const layoutTraceSignatures = new Map();
  const treeViewportPositions = new Map();
  const editorViewportPositions = new Map();
  const pendingTagRenames = new Map();
  const selectedCreatorTagByType = new Map();
  const selectedLLMProfileByType = new Map();
  let utilityPanel = null;
  let selectedLanguage = "en";
  let navigationPanelWidth = navigationWidthRange.fallback;
  let navigationResize = null;
  const incrementalPageSize = 40;
  const workspaceNames = new Set(["tagTree", "localModel", "llmAssist", "browserBridge", "classificationData"]);
  const incrementalLists = new Map();
  const deferredCreatorEntries = new Map();
  let incrementalListSequence = 0;
  let deferredCreatorEntrySequence = 0;
  let incrementalListObserver = null;

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

  function t(key, values = {}) {
    const template = strings[key];
    if (typeof template !== "string") return key;
    return template.replace(/\{([a-zA-Z0-9_]+)\}/g, (_, name) => String(values[name] ?? ""));
  }

  const tx = (key, values = {}) => esc(t(key, values));
  const percent = (value) => `${Math.round(Number(value || 0) * 100)}%`;
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

  function resetDeferredRendering() {
    incrementalListObserver?.disconnect();
    incrementalLists.clear();
    deferredCreatorEntries.clear();
    incrementalListSequence = 0;
    deferredCreatorEntrySequence = 0;
  }

  function incrementalList(items, renderItem, emptyMarkup = "") {
    if (!items.length) return emptyMarkup;
    const id = `incremental-list-${incrementalListSequence += 1}`;
    const nextIndex = Math.min(incrementalPageSize, items.length);
    incrementalLists.set(id, { items, renderItem, nextIndex });
    const initialRows = items.slice(0, nextIndex).map(renderItem).join("");
    const sentinel = nextIndex < items.length
      ? `<span class="incremental-list-sentinel" data-incremental-list="${id}" aria-hidden="true"></span>`
      : "";
    return `${initialRows}${sentinel}`;
  }

  function appendIncrementalRows(sentinel) {
    const id = sentinel?.dataset.incrementalList;
    const list = id ? incrementalLists.get(id) : null;
    if (!list || !sentinel.isConnected) return;
    incrementalListObserver?.unobserve(sentinel);
    const endIndex = Math.min(list.nextIndex + incrementalPageSize, list.items.length);
    const rows = list.items.slice(list.nextIndex, endIndex).map(list.renderItem).join("");
    if (rows) sentinel.insertAdjacentHTML("beforebegin", rows);
    list.nextIndex = endIndex;
    if (endIndex >= list.items.length) {
      incrementalLists.delete(id);
      sentinel.remove();
      return;
    }
    window.requestAnimationFrame(() => {
      if (sentinel.isConnected) incrementalListObserver?.observe(sentinel);
    });
  }

  function observeIncrementalLists() {
    const sentinels = root.querySelectorAll("[data-incremental-list]");
    if (!sentinels.length) return;
    if (!("IntersectionObserver" in window)) {
      sentinels.forEach((sentinel) => {
        while (sentinel.isConnected && incrementalLists.has(sentinel.dataset.incrementalList)) {
          appendIncrementalRows(sentinel);
        }
      });
      return;
    }
    incrementalListObserver ||= new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) appendIncrementalRows(entry.target);
      });
    }, { rootMargin: "160px 0px" });
    sentinels.forEach((sentinel) => incrementalListObserver.observe(sentinel));
  }

  function field(labelKey, hintKey, key, value, type = "text", extra = "") {
    return `<label class="field"><span class="field-label">${tx(labelKey)}${hintKey ? ` · ${tx(hintKey)}` : ""}</span><input type="${type}" data-field="${esc(key)}" value="${type === "password" ? "" : esc(value)}" ${extra}></label>`;
  }

  function textareaField(labelKey, hintKey, key, value, extra = "") {
    return `<label class="field wide"><span class="field-label">${tx(labelKey)}${hintKey ? ` · ${tx(hintKey)}` : ""}</span><textarea data-field="${esc(key)}" ${extra}>${esc(value)}</textarea></label>`;
  }

  function selectField(labelKey, hintKey, key, value, options) {
    return `<label class="field"><span class="field-label">${tx(labelKey)}${hintKey ? ` · ${tx(hintKey)}` : ""}</span><select class="select-control" data-field="${esc(key)}">${options.map(([id, labelKey]) => `<option value="${esc(id)}"${selected(value, id)}>${tx(labelKey)}</option>`).join("")}</select></label>`;
  }

  function valueSelectField(labelKey, hintKey, key, value, options, extra = "") {
    return `<label class="field"><span class="field-label">${tx(labelKey)}${hintKey ? ` · ${tx(hintKey)}` : ""}</span><select class="select-control" data-field="${esc(key)}" ${extra}>${options.map(([id, label]) => `<option value="${esc(id)}"${selected(value, id)}>${esc(label)}</option>`).join("")}</select></label>`;
  }

  function multiValueSelectField(labelKey, hintKey, key, values, options, extra = "") {
    const selectedValues = new Set(values || []);
    return `<label class="field"><span class="field-label">${tx(labelKey)}${hintKey ? ` · ${tx(hintKey)}` : ""}</span><select class="select-control multi-select-control" data-field="${esc(key)}" multiple ${extra}>${options.map(([id, label]) => `<option value="${esc(id)}"${selectedValues.has(id) ? " selected" : ""}>${esc(label)}</option>`).join("")}</select></label>`;
  }

  function groupedValueSelectField(labelKey, hintKey, key, value, groups, extra = "") {
    return `<label class="field"><span class="field-label">${tx(labelKey)}${hintKey ? ` · ${tx(hintKey)}` : ""}</span><select class="select-control" data-field="${esc(key)}" ${extra}>${groups.map(([groupKey, options]) => `<optgroup label="${tx(groupKey)}">${options.map(([id, label]) => `<option value="${esc(id)}"${selected(value, id)}>${esc(label)}</option>`).join("")}</optgroup>`).join("")}</select></label>`;
  }

  function toggle(labelKey, key, value) {
    return `<label class="toggle-row"><input type="checkbox" data-field="${esc(key)}"${checked(value)}><span>${tx(labelKey)}</span></label>`;
  }

  function metric(titleKey, value, tone = "navy") {
    return `<div class="metric ${esc(tone)}"><div class="metric-title">${tx(titleKey)}</div><div class="metric-value">${esc(value)}</div></div>`;
  }

  function notice(text, tone = "navy") {
    return text ? `<div class="notice ${esc(tone)}">${esc(text)}</div>` : "";
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

  function languageSelection() {
    return `<label class="header-language"><span class="visually-hidden">${tx("language.label")}</span><select class="select-control" data-language-selection aria-label="${tx("language.label")}">${languageChoices.map(([identifier, nameKey]) => `<option value="${esc(identifier)}"${selected(selectedLanguage, identifier)}>${tx(nameKey)}</option>`).join("")}</select></label>`;
  }

  function utilityPanelContent() {
    if (!utilityPanel) return "";
    let content = "";
    if (utilityPanel === "settings") {
      const settings = state.activity.settings;
      content = `<section class="utility-panel utility-settings-modal" data-form-id="utility-settings-form"><div class="utility-panel-head"><div><h2>${tx("utility.settings.title")}</h2><p class="section-copy">${tx("utility.settings.copy")}</p></div><button class="secondary utility-close" data-action="closeUtilityPanel">${tx("utility.close")}</button></div><div class="utility-settings-body">${browserBridgeSettingsCard()}<section class="utility-settings-section utility-resource-section"><h3 class="utility-settings-section-title">${tx("activity.resources")}</h3><div class="utility-settings-fields">${selectField("activity.profile", "activity.profileHint", "profile", settings.profile, [["light", "enum.profile.light"], ["balanced", "enum.profile.balanced"], ["aggressive", "enum.profile.aggressive"]])}${field("activity.cacheCapacity", "activity.uniqueEntries", "cacheCapacity", settings.cacheCapacity)}${selectField("activity.packageUpdates", "activity.preference", "packageUpdateMode", settings.packageUpdateMode, [["automatic", "enum.update.automatic"], ["downloadThenAsk", "enum.update.downloadThenAsk"], ["manual", "enum.update.manual"]])}</div><div class="utility-toggles">${toggle("activity.idleWork", "allowIdleWork", settings.allowIdleWork)}${toggle("activity.backgroundSync", "allowBackgroundSync", settings.allowBackgroundSync)}</div></section></div><div class="utility-modal-actions"><button class="primary" data-action="saveResourceSettings" data-form="utility-settings-form">${tx("activity.save")}</button></div></section>`;
    }
    if (!content) return "";
    return `<div class="utility-popover-layer" role="presentation"><button class="utility-popover-dismiss" data-action="closeUtilityPanel" aria-label="${tx("utility.close")}"></button><div class="utility-popover" role="dialog" aria-modal="true" aria-label="${esc(tx("utility.settings.title"))}">${content}</div></div>`;
  }

  function browserBridgeSettingsCard() {
    const hub = state.bridge || {};
    const knownStates = new Set(["off", "connecting", "hosting", "joined-macapp", "joined-classifier", "disconnected", "error"]);
    const bridgeState = knownStates.has(hub.state) ? hub.state : "off";
    const online = bridgeState === "hosting" || bridgeState.startsWith("joined-");
    const active = bridgeState !== "off" && bridgeState !== "error";
    const stateKey = `bridge.status.${bridgeState}`;
    const peers = Array.isArray(hub.peers) ? hub.peers : [];
    const peerLabels = peers.filter((peer) => peer && peer.program).map((peer) => esc(peer.program)).join(", ") || tx("bridge.noPeers");
    const action = active
      ? `<button class="secondary danger" data-action="disconnectSharedHub">${tx("bridge.disconnect")}</button>`
      : `<button class="secondary" data-action="connectSharedHub">${tx("bridge.connect")}</button>`;
    return `<section class="utility-bridge-card"><div class="utility-bridge-card-head"><h2>${tx("bridge.settingsTitle")}</h2><p class="section-copy">${tx("bridge.settingsCopy")}</p></div><div class="bridge-local-status"><span class="status-dot ${bridgeState}${online ? " connected" : ""}"></span><strong>${tx(stateKey)}</strong></div><p class="bridge-address"><strong>${tx("bridge.hubAddress")}:</strong> <code>${esc(hub.address || "ws://127.0.0.1:8787")}</code></p><p class="small-copy">${tx("bridge.hostCopy")}</p><p class="bridge-peer-copy">${tx("bridge.peers")}: ${peerLabels}</p><div class="bridge-settings-actions">${action}</div>${hub.error ? notice(hub.error, "red") : ""}</section>`;
  }

  function navButton(workspace, symbol, titleKey, metaKey) {
    const active = state.workspace === workspace ? " active" : "";
    return `<button class="sidebar-row${active}" type="button" data-action="workspace" data-workspace="${esc(workspace)}"><span class="sidebar-symbol" aria-hidden="true">${symbol}</span><span class="sidebar-copy"><span class="sidebar-name">${tx(titleKey)}</span><span class="sidebar-meta">${tx(metaKey)}</span></span></button>`;
  }

  function shell(content) {
    return `<div class="popup">
      <header class="hero">
        <div class="hero-copy"><span class="hero-mark" aria-hidden="true">V</span><div><h1>${tx("app.title")}</h1></div></div>
        <div class="hero-controls"><span class="settings-popover-anchor"><button class="header-tool" data-action="openUtilityPanel" data-utility-panel="settings" aria-haspopup="dialog" aria-expanded="${utilityPanel ? "true" : "false"}">${tx("utility.settings.button")}</button>${utilityPanelContent()}</span>${languageSelection()}<div class="hero-status"><span class="status-dot"></span>${tx("hero.offline")}</div></div>
      </header>
      <div class="layout">
        <aside class="navigation-panel" aria-label="${tx("navigation.aria")}">
          <div class="panel-header"><div><h2>${tx("navigation.title")}</h2><p class="small-copy">${tx("navigation.subtitle")}</p></div></div>
          <div class="sidebar-list">
            ${navButton("tagTree", "⌘", "navigation.tagTree", "navigation.tagTreeMeta")}
            ${navButton("localModel", "◉", "navigation.localModel", "navigation.localModelMeta")}
            ${navButton("llmAssist", "◌", "navigation.llmAssist", "navigation.llmAssistMeta")}
            ${navButton("browserBridge", "⇄", "navigation.browserBridge", "navigation.browserBridgeMeta")}
            ${navButton("classificationData", "▤", "navigation.classificationData", "navigation.classificationDataMeta")}
          </div>
        </aside>
        <div class="layout-resizer" data-navigation-resizer role="separator" aria-orientation="vertical" aria-label="${tx("navigation.resize")}" aria-valuemin="${navigationWidthRange.minimum}" aria-valuemax="${navigationWidthRange.maximum}" aria-valuenow="${navigationPanelWidth}" tabindex="0"></div>
        <section class="editor-panel" data-editor-panel data-workspace="${esc(state.workspace)}">${content}</section>
      </div>
    </div>`;
  }

  function inspectWorkspace() {
    const inspect = state.inspect;
    const platformOptions = (state.assets.bindings || []).map((binding) => [binding.id, binding.name]);
    const result = inspect.result;
    let renderedResult = "";
    if (result) {
      const action = result.strongestAction;
      const symbol = action === "allow" ? "✓" : action === "dim" ? "◒" : "!";
      const scores = result.scores.length
        ? `<div class="score-list">${result.scores.map((score) => `<div class="score"><span class="score-name">${esc(score.tag.replace("content.", ""))}</span><span class="bar"><span style="width:${Math.max(0, Math.min(100, Number(score.score) * 100))}%"></span></span><span class="score-value">${percent(score.score)}</span></div>`).join("")}</div>`
        : `<p class="small-copy">${tx("inspect.noLeaf")}</p>`;
      const decisions = result.decisions.length
        ? `<div class="list">${result.decisions.map((decision) => `<div class="list-row"><span class="list-symbol">•</span><span class="list-copy"><span class="list-title">${esc(decision.policyID)} · ${esc(enumText("action", decision.action))}</span><span class="list-meta">${esc(decision.explanation)}</span></span></div>`).join("")}</div>`
        : `<p class="small-copy">${tx("inspect.noPolicy")}</p>`;
      const correction = action === "allow"
        ? `<button class="secondary" data-action="markCorrection" data-correction="falseAllow">${tx("inspect.markFalseAllow")}</button>`
        : `<button class="gold-action" data-action="markCorrection" data-correction="falseDim">${tx("inspect.markFalseDim")}</button><button class="danger" data-action="markCorrection" data-correction="falseBlock">${tx("inspect.markFalseBlock")}</button>`;
      renderedResult = `<section class="result-card ${esc(action)}"><div class="result-head"><span class="result-symbol">${symbol}</span><div><span class="eyebrow">${tx("inspect.policyDecision")}</span><div class="result-action">${esc(enumText("action", action))}</div></div><span class="spacer"></span><span class="small-copy">${tx("inspect.threshold", { value: percent(result.threshold) })}</span></div><div><span class="field-label">${tx("inspect.predictedLeaves")} · ${tx("inspect.ancestorsComputed")}</span><div class="chips">${result.leafTags.length ? result.leafTags.map((tag) => `<span class="chip">${esc(tag.replace("content.", "").replaceAll(".", " · "))}</span>`).join("") : `<span class="small-copy">${tx("inspect.noLeaf")}</span>`}</div></div><div><span class="field-label">${tx("inspect.localScores")} · ${tx("inspect.sourcePrior")}</span>${scores}</div><div><span class="field-label">${tx("inspect.policyMatches")}</span>${decisions}</div>${result.ancestorTags.length ? `<p class="small-copy">${tx("inspect.computedPath", { path: result.ancestorTags.join(" › ") })}</p>` : ""}<div class="action-row">${correction}</div></section>`;
    }
    return `<div class="workspace">${header("inspect.title", "inspect.copy", t(inspect.surface === "feed" ? "inspect.feedDecision" : "inspect.pageDecision"), "cyan")}
      <section class="section-card cyan" data-form-id="inspect-form"><div class="form-stack">
        ${field("inspect.entryTitle", "inspect.required", "title", inspect.title)}
        <div class="form-row">${field("inspect.sourceID", "inspect.optional", "sourceID", inspect.sourceID)}${platformOptions.length ? valueSelectField("inspect.platform", "inspect.platformCopy", "platformID", inspect.platformID, platformOptions) : ""}</div>
        <div class="field"><span class="field-label">${tx("inspect.surface")} · ${tx("inspect.surfaceHint")}</span><div class="choice-row"><label><input type="radio" name="surface" data-field="surface" value="feed"${checked(inspect.surface === "feed")}><span>${tx("enum.surface.feed")}</span></label><label><input type="radio" name="surface" data-field="surface" value="page"${checked(inspect.surface === "page")}><span>${tx("enum.surface.page")}</span></label></div></div>
        <div class="action-row"><button class="primary" data-action="classify" data-form="inspect-form"${disabled(!platformOptions.length)}>${tx("inspect.classify")}</button>${inspect.llmAvailable ? `<button class="gold-action" data-action="classifyWithLLM" data-form="inspect-form"${disabled(inspect.llmRunning)}>${tx(inspect.llmRunning ? "inspect.llmClassifying" : "inspect.classifyWithLLM")}</button>` : ""}<span class="small-copy">${tx(inspect.llmAvailable ? "inspect.llmExplicitOnly" : "inspect.localOnly")}</span></div>
      </div></section>${renderedResult || `<div class="empty">${tx("inspect.noResult")}</div>`}${notice(state.issue, "red")}</div>`;
  }

  function policyWorkspace() {
    const policies = state.policies;
    const editor = policies.editor;
    return `<div class="workspace">${header("policies.title", "policies.copy", t("policies.savedCount", { count: policies.items.length }), "navy")}
      <section class="section-card navy"><div class="section-header"><div><h3>${tx("policies.saved")}</h3><p class="section-copy">${tx("policies.savedCopy")}</p></div><button class="secondary" data-action="newPolicy">${tx("policies.new")}</button></div>
      ${policies.items.length ? `<div class="list">${policies.items.map((policy) => `<button class="list-row" data-action="selectPolicy" data-id="${esc(policy.id)}"><span class="list-symbol">⌗</span><span class="list-copy"><span class="list-title">${esc(policy.name || policy.id)}</span><span class="list-meta">${esc(policy.id)} · ${tx("enum.surface.feed").toLowerCase()} ${esc(enumText("action", policy.feedAction))}</span></span></button>`).join("")}</div>` : `<div class="empty">${tx("policies.empty")}</div>`}</section>
      <section class="section-card navy" data-form-id="policy-form"><div class="section-header"><div><h3>${tx(editor.id ? "policies.edit" : "policies.create")}</h3><p class="section-copy">${tx("policies.editorCopy")}</p></div></div><div class="form-stack">
      <div class="form-row">${field("policies.id", "policies.idHint", "id", editor.id)}${field("policies.displayName", "policies.localOnly", "name", editor.name)}</div>
      ${field("policies.includeAny", "policies.exactIDs", "includeAny", editor.includeAny)}
      ${field("policies.exclude", "inspect.optional", "exclude", editor.exclude)}
      <div class="form-row">${selectField("policies.feedAction", "policies.feedHint", "feedAction", editor.feedAction, [["allow", "enum.action.allow"], ["dim", "enum.action.dim"], ["block", "enum.action.block"]])}${selectField("policies.pageAction", "policies.pageHint", "pageAction", editor.pageAction, [["allow", "enum.action.allow"], ["block", "enum.action.block"]])}</div>
      <div class="action-row"><button class="primary" data-action="savePolicy" data-form="policy-form">${tx("policies.save")}</button><button class="danger" data-action="deletePolicy"${disabled(!editor.id)}>${tx("common.delete")}</button></div>
      </div></section>${notice(state.issue, "red")}</div>`;
  }

  function activityWorkspace() {
    const activity = state.activity;
    const settings = activity.settings;
    return `<div class="workspace">${header("activity.title", "activity.copy", t("activity.localOnly"), "cyan")}
      <div class="metric-row">${metric("activity.cache", `${activity.cacheCount} / ${activity.cacheCapacity}`, "cyan")}${metric("activity.ledger", activity.ledgerCount, "cyan")}${metric("activity.corrections", activity.correctionCount, "cyan")}</div>
      <section class="section-card cyan" data-form-id="resource-form"><div class="section-header"><div><h3>${tx("activity.resources")}</h3><p class="section-copy">${tx("activity.resourcesCopy")}</p></div></div><div class="form-stack">
      <div class="form-row">${selectField("activity.profile", "activity.profileHint", "profile", settings.profile, [["light", "enum.profile.light"], ["balanced", "enum.profile.balanced"], ["aggressive", "enum.profile.aggressive"]])}${field("activity.cacheCapacity", "activity.uniqueEntries", "cacheCapacity", settings.cacheCapacity)}${selectField("activity.packageUpdates", "activity.preference", "packageUpdateMode", settings.packageUpdateMode, [["automatic", "enum.update.automatic"], ["downloadThenAsk", "enum.update.downloadThenAsk"], ["manual", "enum.update.manual"]])}</div>
      ${toggle("activity.idleWork", "allowIdleWork", settings.allowIdleWork)}${toggle("activity.backgroundSync", "allowBackgroundSync", settings.allowBackgroundSync)}
      <div class="action-row"><button class="primary" data-action="saveResourceSettings" data-form="resource-form">${tx("activity.save")}</button></div>
      </div></section>
      <section class="section-card cyan"><div class="section-header"><div><h3>${tx("activity.recent")}</h3><p class="section-copy">${tx("activity.newest")}</p></div><button class="secondary" data-action="state">${tx("common.refresh")}</button></div>${activity.ledger.length ? `<div class="list">${activity.ledger.map((entry) => `<div class="list-row"><span class="list-symbol">${entry.hasCorrection ? "!" : "✓"}</span><span class="list-copy"><span class="list-title">${esc(entry.cacheKey)}</span><span class="list-meta">${esc(entry.modelVersion)}</span></span>${entry.hasCorrection ? `<button class="secondary" data-action="clearCorrection" data-id="${esc(entry.id)}">${tx("common.clear")}</button>` : ""}</div>`).join("")}</div>` : `<div class="empty">${tx("activity.empty")}</div>`}</section>${notice(state.issue, "red")}</div>`;
  }

  function trainingWorkspace() {
    const training = state.training;
    const run = training.lastRun;
    return `<div class="workspace">${header("training.title", "training.copy", t(training.labelCount ? "training.localOnly" : "training.noLabels"), "pink")}
      <div class="metric-row">${metric("training.labels", `${training.labelCount} / ${training.capacity}`, "pink")}${metric("training.features", training.featureCount, "pink")}${metric("training.lastRebuild", run ? t("training.labelCount", { count: run.exampleCount }) : t("training.notYet"), "pink")}</div>
      <section class="section-card pink" data-form-id="training-form"><div class="section-header"><div><h3>${tx("training.currentLabel")}</h3><p class="section-copy">${tx("training.currentLabelCopy")}</p></div></div><div class="form-stack">${field("training.positive", "training.commaSeparated", "positiveTags", training.positiveTags)}${field("training.negative", "training.optionalCommaSeparated", "negativeTags", training.negativeTags)}<div class="action-row"><button class="pink-action" data-action="storeTraining" data-form="training-form">${tx("training.store")}</button><span class="small-copy">${tx("training.replace")}</span></div></div></section>
      <section class="section-card pink" data-form-id="retrain-form"><div class="section-header"><div><h3>${tx("training.rebuild")}</h3><p class="section-copy">${tx("training.rebuildCopy")}</p></div></div><div class="form-row">${field("training.passes", "training.passesHint", "epochs", training.epochs)}<div class="field"><span class="field-label">${tx("training.localAction")}</span><button class="pink-action" data-action="retrain" data-form="retrain-form"${disabled(!training.labelCount)}>${tx("training.retrain")}</button></div></div></section>
      ${run ? notice(t("training.lastRun", { labels: run.exampleCount, updates: run.labelUpdateCount, epochs: run.epochs, taxonomy: run.taxonomyVersion }), "pink") : ""}${notice(state.notices.training, "pink")}${notice(state.issue, "red")}</div>`;
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

  function tagTreeWorkspace() {
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
        return `<button class="tree-map-node ${tier}${panelState?.nodeID === node.id || selectedNodeID === node.id ? " active" : ""}${connectionState?.nodeID === node.id ? " connection-source" : ""}${node.retired ? " retired" : ""}" style="left:${position.x}px;top:${position.y}px" data-action="selectTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(node.id)}" data-parent-id="${esc(node.parentID || "")}" data-position-x="${position.x}" data-position-y="${position.y}" title="${tx("tree.contextHint")}"><span aria-hidden="true"></span><strong>${esc(node.name)}</strong></button>`;
      }).join("")}</div>${nodes.length ? "" : `<div class="tree-map-empty">${tx("tree.empty")}</div>`}${popover}</div></div>`;
      const treeActions = `<div class="tree-canvas-actions"><button class="secondary" data-action="renameTree" data-tree-id="${esc(tree.id)}">${tx("tree.rename")}</button><button class="danger" data-action="deleteTree" data-tree-id="${esc(tree.id)}">${tx("tree.delete")}</button><button class="secondary" data-action="rearrangeTree" data-tree-id="${esc(tree.id)}">${tx("tree.rearrange")}</button></div>`;
      return `<section class="tree-panel">${map}<div class="tree-canvas-hint"><span>${tx("tree.canvasHint")}</span>${treeActions}</div></section>`;
    };
    return `<div class="workspace tree-workspace">${header("tree.title", "tree.copy", t("tree.sharedLibrary"), "cyan")}
      <section class="tree-create" data-form-id="new-tree-form">${field("tree.treeName", "", "name", "")}<button class="primary" data-action="createTree" data-form="new-tree-form">${tx("tree.create")}</button><span class="small-copy">${tx("tree.multiplePanels")}</span></section><div class="tree-panels">${assets.trees.map(panel).join("")}</div>${notice(state.issue, "red")}</div>`;
  }

  function baseEmbeddingLabelKey(identifier) {
    const keys = {
      "all-MiniLM-L6-v2": "model.base.allMiniLML6V2",
      "all-mpnet-base-v2": "model.base.allMPNetBaseV2",
      "multilingual-e5-small": "model.base.multilingualE5Small",
      "multilingual-e5-base": "model.base.multilingualE5Base",
      "multilingual-e5-large": "model.base.multilingualE5Large",
      "bge-m3": "model.base.bgeM3",
    };
    return keys[identifier] || "model.base.none";
  }

  function localModelWorkspace() {
    const assets = state.assets;
    const models = assets.models || [];
    const localModelBindings = (assets.bindings || []).filter((binding) => binding.supportsLocalModel);
    const panel = (model) => {
      const formID = `local-model-${model.id}`;
      const tree = assets.trees.find((candidate) => candidate.id === model.treeID);
      const platformIDs = model.platformIDs?.length
        ? model.platformIDs
        : [model.platformID || assets.bindings.find((binding) => binding.datasetID === model.datasetID)?.id].filter(Boolean);
      const dataset = assets.datasets.find((candidate) => candidate.id === model.datasetID);
      const treeOptions = assets.trees.map((candidate) => [candidate.id, `${candidate.name} · r${candidate.revision}`]);
      const platformOptions = localModelBindings.map((binding) => [binding.id, `${binding.name} · ${binding.browser}`]);
      const baseOptions = [["", t("model.base.none")], ...(assets.baseEmbeddings || []).map((identifier) => [identifier, t(baseEmbeddingLabelKey(identifier))])];
      const tagCount = tree?.nodes.filter((node) => !node.retired).length || 0;
      const sourcePlatforms = new Set(platformIDs);
      const recordCount = (dataset?.creatorClassifications || []).filter((classification) => sourcePlatforms.has(classification.platformID) && classification.review === "approved" && (classification.origin === "manual" || classification.origin === "llmAssist") && classification.treeID === model.treeID && classification.treeRevision === model.treeRevision).reduce((count, classification) => count + (dataset?.collectedEntries || []).filter((entry) => entry.platformID === classification.platformID && entry.creatorID === classification.creatorID).length, 0);
      const training = model.training;
      const trainingStatus = training
        ? `<div class="model-run pink">${tx("model.trainedRun", { records: training.examples, updates: training.updates, epochs: training.epochs })}</div>`
        : `<div class="model-run muted">${tx("model.untrained")}</div>`;
      return `<section class="model-panel" data-model-panel data-model-id="${esc(model.id)}" data-form-id="${esc(formID)}">
        <div class="model-panel-head">
          <div><span class="eyebrow">${tx("model.panel")}</span><h3>${esc(model.name)}</h3><p class="section-copy">${tx("model.boundRevisions", { tree: model.treeRevision, data: model.datasetRevision })}</p></div>
          <div class="model-panel-status">${statusPill(t(model.ready ? "model.ready" : "model.needsTraining"), model.ready ? "pink" : "gold")}${statusPill(t("model.version", { value: model.version }), "navy")}</div>
        </div>
        <div class="model-name-row">${field("model.modelName", "", "name", model.name)}<div class="model-name-actions"><button class="secondary" data-action="renameLocalModel" data-form="${esc(formID)}" data-model-id="${esc(model.id)}">${tx("model.rename")}</button><button class="danger" data-action="deleteLocalModel" data-model-id="${esc(model.id)}">${tx("model.delete")}</button></div></div>
        <div class="model-setup"><div class="section-header"><div><h3>${tx("model.setup")}</h3><p class="section-copy">${tx("model.setupCopy")}</p></div></div><div class="form-row model-setup-fields">${valueSelectField("model.targetTree", "", "treeID", model.treeID, treeOptions, "data-local-model-setup")}${multiValueSelectField("model.classificationPlatforms", "model.classificationPlatformsCopy", "platformIDs", platformIDs, platformOptions, "data-local-model-setup")}${valueSelectField("model.baseLanguageModel", "model.baseCopy", "baseEmbeddingID", model.baseEmbeddingID || "", baseOptions, "data-local-model-setup")}</div></div>
        <div class="model-training-row"><div><span class="eyebrow">${tx("model.localTraining")}</span><p class="section-copy">${tx("model.trainingScope", { records: recordCount, tags: tagCount })}</p></div><button class="pink-action" data-action="trainLocalModel" data-form="${esc(formID)}" data-model-id="${esc(model.id)}"${disabled(!treeOptions.length || !platformOptions.length)}>${tx("model.train")}</button></div>
        ${trainingStatus}
      </section>`;
    };
    return `<div class="workspace model-workspace">${header("model.title", "model.copy", t("model.sharedLibrary"), "pink")}
      <section class="model-create" data-form-id="new-local-model-form">${field("model.modelName", "", "name", "")}<button class="pink-action" data-action="createLocalModel" data-form="new-local-model-form"${disabled(!assets.trees.length || !localModelBindings.length)}>${tx("model.create")}</button><span class="small-copy">${tx("model.multiplePanels")}</span></section>
      <div class="model-panels">${models.length ? models.map(panel).join("") : `<div class="empty">${tx("model.empty")}</div>`}</div>${notice(state.issue, "red")}</div>`;
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
      ["llm.providerGroup.search", ["serper", "youSearch"].map((type) => [type, t(providerTypeLabelKey(type))])],
      ["llm.providerGroup.custom", ["openAICompatible", "custom"].map((type) => [type, t(providerTypeLabelKey(type))])],
    ];
    const panel = (profile) => {
      const formID = `provider-profile-${profile.id}`;
      const protocol = protocols[profile.type] || {};
      const supportsLLM = Boolean(protocol.supportsLLMConfiguration);
      const supportsPlatformData = Boolean(protocol.supportsPlatformData);
      const supportsRawWebSearch = Boolean(protocol.supportsRawWebSearch);
      const profileRecords = requestRecords.filter((record) => record.profileID === profile.id);
      const latestResponseDiagnostic = profileRecords
        .filter((record) => typeof record.responseShape === "string" && record.responseShape.length > 0)
        .sort((left, right) => Number(right.createdAtMilliseconds) - Number(left.createdAtMilliseconds))[0];
      const tokenTotals = profileRecords.filter((record) => record.outcome === "succeeded").reduce((total, record) => ({
        input: total.input + (Number(record.inputTokens) || 0),
        output: total.output + (Number(record.outputTokens) || 0),
      }), { input: 0, output: 0 });
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
      const testAvailable = supportsLLM || supportsPlatformData || supportsRawWebSearch;
      const testButton = testAvailable ? `<button class="gold-action" data-action="testProviderProfile" data-form="${esc(formID)}" data-profile-id="${esc(profile.id)}"${disabled(profile.testing)}>${tx(profile.testing ? "llm.testing" : "llm.test")}</button>` : "";
      const usage = supportsPlatformData || supportsRawWebSearch
        ? `<p class="provider-token-usage"><span>${tx("llm.apiCalls")}</span><strong>${profileRecords.filter((record) => ["readPublicContent", "searchWeb", "search-creator-web"].includes(record.operation) && Number.isInteger(record.statusCode)).length}</strong></p>`
        : `<p class="provider-token-usage"><span>${tx("llm.tokenUsage")}</span><strong>${tx("llm.tokenTotals", { input: tokenTotals.input, output: tokenTotals.output })}</strong></p>`;
      const responseDiagnostic = latestResponseDiagnostic
        ? `<p class="provider-response-shape"><span>${tx("llm.responseShape")}</span><strong>${esc(latestResponseDiagnostic.responseShape)}</strong></p>`
        : "";
      return `<section class="provider-panel" data-provider-panel data-provider-id="${esc(profile.id)}" data-form-id="${esc(formID)}"><div class="provider-panel-head"><h3>${esc(profile.name)}</h3><div class="provider-panel-actions">${testButton}<button class="danger" data-action="confirmDeleteProviderProfile" data-profile-id="${esc(profile.id)}">${tx("llm.deleteProfile")}</button></div></div><div class="provider-panel-body">${connectionFields ? `<div class="provider-connection-fields">${connectionFields}</div>` : ""}<div class="provider-request-summary">${usage}${responseDiagnostic}</div></div>${profile.testSucceeded ? notice(t("llm.testSucceeded"), "green") : ""}</section>`;
    };
    return `<div class="workspace provider-workspace">${header("llm.title", "llm.copy", t("llm.keyLibrary"), "gold")}<section class="provider-create" data-form-id="new-provider-profile-form">${groupedValueSelectField("llm.providerType", "", "type", "gemini", profileTypeGroups)}<button class="gold-action" data-action="createProviderProfile" data-form="new-provider-profile-form">${tx("llm.createKey")}</button><span class="small-copy">${tx("llm.createCopy")}</span></section><div class="provider-panels">${profiles.length ? profiles.map(panel).join("") : `<div class="empty">${tx("llm.empty")}</div>`}</div>${notice(state.issue, "red")}</div>`;
  }

  function browserBridgeWorkspace() {
    const assets = state.assets;
    const classifierTypes = assets.classifierTypes || [];
    const trees = assets.trees || [];
    const datasets = assets.datasets || [];
    const models = assets.models || [];
    const profiles = assets.providerProfiles || [];
    const platformDefinitions = new Map((assets.collectionPlatforms || []).map((platform) => [platform.id, platform]));
    const protocols = assets.providerProtocols || {};
    const llmProfiles = profiles.filter((profile) => protocols[profile.type]?.supportsLLMConfiguration);
    const rawWebSearchProfiles = profiles.filter((profile) => protocols[profile.type]?.supportsRawWebSearch);
    const sourceOptions = [
      ["human", t("bridge.source.human")],
      ["llmAssist", t("bridge.source.llmAssist")],
      ["localModel", t("bridge.source.localModel")],
    ];
    const typeForm = (classifierType) => {
      const formID = `classifier-type-${classifierType.id}`;
      const applicablePlatformID = typeof classifierType.applicablePlatformID === "string" ? classifierType.applicablePlatformID : "";
      const applicableBinding = (assets.bindings || []).find((binding) => binding.id === applicablePlatformID);
      const selectedTree = trees.find((tree) => tree.id === applicableBinding?.treeID);
      const selectedDataset = datasets.find((dataset) => dataset.id === applicableBinding?.datasetID);
      const applicablePlatform = platformDefinitions.get(applicablePlatformID);
      const sourceTerms = collectionSourceTerms(applicablePlatform?.sourceKind);
      const dataSourcePlatforms = new Set(applicablePlatformID ? [applicablePlatformID] : []);
      const supportsLocalModel = applicablePlatform?.supportsLocalModel === true;
      const supportsLLMAssist = applicablePlatform?.supportsLLMAssist === true;
      const applicablePlatformOptions = [["", t("bridge.noApplicablePlatform")], ...(assets.collectionPlatforms || []).map((definition) => {
        const hasBinding = (assets.bindings || []).some((binding) => binding.id === definition.id);
        return [definition.id, `${definition.name} · ${definition.browser}${hasBinding ? "" : ` · ${t("bridge.platformDataAutoCreate")}`}${!definition.supportsLocalModel ? ` · ${t("bridge.manualOnly")}` : ""}`];
      })];
      const platformAPIProfiles = applicablePlatform?.apiProviderType
        ? profiles.filter((profile) => profile.type === applicablePlatform.apiProviderType)
        : [];
      const boundPlatformAPIProfile = platformAPIProfiles.find((profile) => profile.hasCredential);
      const platformEvidenceReady = Boolean(applicablePlatform && (!applicablePlatform.apiProviderType || boundPlatformAPIProfile));
      const platformDataStatus = !applicablePlatform
        ? t("bridge.platformDataChoose")
        : !applicableBinding
          ? t("bridge.platformDataWillCreate", { platform: applicablePlatform.name })
        : !applicablePlatform.apiProviderType
          ? t("bridge.platformDataUnavailable", { platform: applicablePlatform.name })
          : boundPlatformAPIProfile
            ? t("bridge.platformDataBound", { profile: boundPlatformAPIProfile.name })
            : t("bridge.platformDataMissingKey", { platform: applicablePlatform.name });
      const compatibleModels = supportsLocalModel ? models.filter((model) => model.ready &&
        model.treeID === selectedTree?.id &&
        model.treeRevision === selectedTree?.revision &&
        model.datasetID === selectedDataset?.id &&
        model.datasetRevision === selectedDataset?.revision &&
        new Set(model.platformIDs || [model.platformID].filter(Boolean)).size === dataSourcePlatforms.size &&
        (model.platformIDs || [model.platformID].filter(Boolean)).every((platformID) => dataSourcePlatforms.has(platformID))) : [];
      const modelOptions = [["", t("bridge.noLocalModel")], ...compatibleModels.map((model) => [model.id, `${model.name} · v${model.version}`])];
      const llmAssist = classifierType.llmAssistConfiguration || null;
      const savedLLMProfileID = classifierType.selectedLLMProviderProfileID || llmAssist?.providerProfileID || "";
      const selectedLLMProfileID = selectedLLMProfileByType.get(classifierType.id) || savedLLMProfileID;
      const selectedLLMProfile = llmProfiles.find((profile) => profile.id === selectedLLMProfileID) || null;
      const llmProviderOptions = [["", t("bridge.noLLMModel")], ...llmProfiles.map((profile) => [profile.id, `${profile.name} · ${tx(providerTypeLabelKey(profile.type))}`])];
      const llmModelIdentifier = llmAssist?.providerProfileID === selectedLLMProfileID
        ? llmAssist.modelIdentifier
        : "";
      const modelCatalogs = assets.providerModelCatalogs || {};
      const modelCatalogErrors = assets.providerModelCatalogErrors || {};
      const loadingModelCatalogs = new Set(assets.loadingProviderModelProfileIDs || []);
      const fetchedModels = selectedLLMProfile ? (modelCatalogs[selectedLLMProfile.id] || []) : [];
      // The fetched list is deliberately session-only, but the classifier
      // type's chosen model is durable. Keep that saved value visible before a
      // Probe (or after a failed Probe) so a relaunch cannot make the form
      // look as though its LLM settings were lost.
      const visibleModels = llmModelIdentifier && !fetchedModels.includes(llmModelIdentifier)
        ? [llmModelIdentifier, ...fetchedModels]
        : fetchedModels;
      const currentModel = llmModelIdentifier;
      const classifierSupportsNativeWebSearch = protocols[selectedLLMProfile?.type]?.supportsNativeWebSearch === true;
      const savedWebSearchProfileID = typeof llmAssist?.webSearchProviderProfileID === "string"
        ? llmAssist.webSearchProviderProfileID
        : "";
      const configuredWebSearchProfile = rawWebSearchProfiles.find((profile) => profile.id === savedWebSearchProfileID) || null;
      const webSearchProviderOptions = [
        ["", t("bridge.llmChooseSearchProvider")],
        ...rawWebSearchProfiles.map((profile) => [profile.id, `${profile.name} · ${tx(providerTypeLabelKey(profile.type))}`]),
      ];
      const priority = classifierType.decisionPriority || ["human", "llmAssist", "localModel"];
      const typeStatus = applicablePlatformID ? t("bridge.configured") : t("bridge.needsSource");
      const leafTagOptions = (selectedTree?.nodes || [])
        .filter((node) => !node.retired && !(selectedTree?.nodes || []).some((candidate) => candidate.parentID === node.id))
        .sort((lhs, rhs) => lhs.name.localeCompare(rhs.name))
        .map((node) => [node.id, `${node.name} · ${node.id}`]);
      const currentDecisionByCreator = new Map((selectedDataset?.creatorClassifications || [])
        .filter((classification) => classification.classifierTypeID === classifierType.id && classification.origin === "manual")
        .map((classification) => [`${classification.platformID}|${classification.creatorID}`, classification]));
      const creatorCandidates = new Map();
      (selectedDataset?.collectedEntries || []).forEach((entry) => {
        if (!dataSourcePlatforms.has(entry.platformID) || !entry.creatorID || !entry.creatorName) return;
        const key = `${entry.platformID}|${entry.creatorID}`;
        const current = creatorCandidates.get(key);
        if (!current || Number(entry.lastObservedAtMilliseconds) > Number(current.lastObservedAtMilliseconds)) creatorCandidates.set(key, entry);
      });
      const sortedCreatorCandidates = [...creatorCandidates.entries()]
        .sort(([, lhs], [, rhs]) => lhs.creatorName.localeCompare(rhs.creatorName));
      let selectedCreatorTagID = selectedCreatorTagByType.get(classifierType.id);
      if (!leafTagOptions.some(([tagID]) => tagID === selectedCreatorTagID)) {
        selectedCreatorTagID = leafTagOptions[0]?.[0] || "";
        if (selectedCreatorTagID) selectedCreatorTagByType.set(classifierType.id, selectedCreatorTagID);
        else selectedCreatorTagByType.delete(classifierType.id);
      }
      const selectedCreatorTagName = leafTagOptions.find(([tagID]) => tagID === selectedCreatorTagID)?.[1]?.split(" · ")[0] || "";
      const creatorRecords = sortedCreatorCandidates
        .map(([key, entry]) => {
          const classification = currentDecisionByCreator.get(key);
          return {
            key,
            platformName: platformDefinitions.get(entry.platformID)?.name || entry.platformID,
            name: entry.creatorName,
            subscriberCount: entry.attributes?.subscriberCount || "",
            avatarURL: typeof entry.cachedCreatorAvatarURL === "string" ? entry.cachedCreatorAvatarURL : "",
            tagIDs: classification?.tags || [],
            negativeTagIDs: classification?.negativeTags || [],
          };
        })
        .sort((lhs, rhs) => lhs.name.localeCompare(rhs.name));
      const nativeProviderWebSearchReady = Boolean(
        llmAssist?.providerProfileID === selectedLLMProfileID &&
        llmAssist?.webSearchEnabled &&
        classifierSupportsNativeWebSearch
      );
      const rawProviderWebSearchReady = Boolean(
        llmAssist?.providerProfileID === selectedLLMProfileID &&
        llmAssist?.webSearchEnabled &&
        configuredWebSearchProfile &&
        configuredWebSearchProfile.hasCredential &&
        protocols[configuredWebSearchProfile.type]?.supportsRawWebSearch
      );
      const providerWebSearchReady = nativeProviderWebSearchReady || rawProviderWebSearchReady;
      const providerEvidenceReady = platformEvidenceReady ||
        Boolean(llmAssist?.webSearchEnabled && providerWebSearchReady);
      const creatorLLMReady = Boolean(selectedLLMProfile &&
        (!protocols[selectedLLMProfile.type]?.credentialRequired || selectedLLMProfile.hasCredential) &&
        (!["openAICompatible", "custom"].includes(selectedLLMProfile.type) || Boolean(selectedLLMProfile.customEndpoint)) &&
        providerEvidenceReady &&
        (!(llmAssist?.webSearchEnabled ?? false) || providerWebSearchReady)
      );
      const llmRunning = Boolean(state.inspect?.llmRunning);
      const creatorLLMClassification = selectedLLMProfile && !llmAssist?.isActive && llmAssist?.providerProfileID === selectedLLMProfileID
          ? (() => {
            const creatorOptions = sortedCreatorCandidates.map(([key, entry]) => {
              const platformName = platformDefinitions.get(entry.platformID)?.name || entry.platformID;
              const existing = currentDecisionByCreator.get(key);
              return [key, `${platformName} · ${entry.creatorName}${existing ? ` · ${t("bridge.sourceClassified")}` : ""}`];
            });
            return `<div class="creator-llm-row">${valueSelectField("bridge.source", "bridge.sourceCopy", "creatorKey", creatorOptions[0]?.[0] || "", creatorOptions)}<span class="small-copy">${esc(selectedLLMProfile.name)} · ${esc(llmAssist.modelIdentifier)}</span><button class="gold-action" data-action="classifyCreatorWithLLM" data-form="${esc(formID)}" data-type-id="${esc(classifierType.id)}"${disabled(!creatorOptions.length || !creatorLLMReady || llmRunning)}>${tx(llmRunning ? "bridge.sourceLLMClassifying" : "bridge.classifySourceWithLLM", { source: sourceTerms.singular })}</button><button class="secondary" data-action="classifyCreatorBatchWithLLM" data-type-id="${esc(classifierType.id)}"${disabled(!creatorOptions.length || !creatorLLMReady || llmRunning)}>${tx("bridge.classifyCreatorBatch", { count: llmAssist.batchSize })}</button></div><p class="small-copy">${tx("bridge.sourceLLMExplicitOnly", { source: sourceTerms.singular })}</p>`;
          })()
          : "";
      const creatorClassification = creatorRecords.length && leafTagOptions.length
        ? (() => {
          const columnData = [
            ["needsDecision", "bridge.creatorTagNeedDecision", creatorRecords.filter((creator) => !creator.tagIDs.includes(selectedCreatorTagID) && !creator.negativeTagIDs.includes(selectedCreatorTagID))],
            ["tagged", "bridge.creatorTagTagged", creatorRecords.filter((creator) => creator.tagIDs.includes(selectedCreatorTagID))],
            ["notTagged", "bridge.creatorTagNotTagged", creatorRecords.filter((creator) => creator.negativeTagIDs.includes(selectedCreatorTagID))],
          ];
          const creatorCardAction = (creator, labelKey, nextTagIDs, nextNegativeTagIDs, style) => `<button class="${style} creator-tag-card-action" data-action="recordCreatorClassification" data-type-id="${esc(classifierType.id)}" data-creator-key="${esc(creator.key)}" data-tag-ids="${esc(JSON.stringify(nextTagIDs))}" data-negative-tag-ids="${esc(JSON.stringify(nextNegativeTagIDs))}">${esc(t(labelKey, { tag: selectedCreatorTagName }))}</button>`;
          const creatorCard = (creator, decision) => {
            const positiveWithoutActive = creator.tagIDs.filter((tagID) => tagID !== selectedCreatorTagID);
            const negativeWithoutActive = creator.negativeTagIDs.filter((tagID) => tagID !== selectedCreatorTagID);
            const tagDecision = creatorCardAction(
              creator,
              "bridge.creatorTagTag",
              [...new Set([...positiveWithoutActive, selectedCreatorTagID])].sort(),
              negativeWithoutActive,
              "primary"
            );
            const notTagDecision = creatorCardAction(
              creator,
              "bridge.creatorTagMarkNot",
              positiveWithoutActive,
              [...new Set([...negativeWithoutActive, selectedCreatorTagID])].sort(),
              "secondary"
            );
            const clearDecision = creatorCardAction(
              creator,
              "bridge.creatorTagClear",
              positiveWithoutActive,
              negativeWithoutActive,
              "secondary"
            );
            const actions = decision === "needsDecision"
              ? `${tagDecision}${notTagDecision}`
              : decision === "tagged"
                ? `${notTagDecision}${clearDecision}`
                : `${tagDecision}${clearDecision}`;
            const avatar = creator.avatarURL
              ? `<img class="creator-tag-card-avatar" src="${esc(creator.avatarURL)}" alt="" aria-hidden="true" loading="lazy" decoding="async">`
              : `<span class="creator-tag-card-avatar creator-tag-card-avatar-fallback" aria-hidden="true">${esc(creator.name.slice(0, 1).toUpperCase())}</span>`;
            return `<article class="creator-tag-card"><div class="creator-tag-card-profile">${avatar}<div><strong dir="auto">${esc(creator.name)}</strong><span>${esc(creator.platformName)}${creator.subscriberCount ? ` · ${tx("bridge.creatorSubscribers", { count: creator.subscriberCount })}` : ""}</span></div></div><div class="creator-tag-card-actions">${actions}</div></article>`;
          };
          const columns = columnData.map(([kind, titleKey, creators]) => `<section class="creator-tag-column"><div class="creator-tag-column-head"><h4>${tx(titleKey, { tag: selectedCreatorTagName })}</h4><span>${creators.length}</span></div><div class="creator-tag-column-list">${incrementalList(creators, (creator) => creatorCard(creator, kind), `<p class="creator-tag-empty">${esc(t("bridge.sourceTagEmpty", { sources: sourceTerms.plural }))}</p>`)}</div></section>`).join("");
          return `<div class="creator-tag-browser"><nav class="creator-tag-navigation" aria-label="${tx("bridge.creatorTagNavigation")}" role="tablist">${leafTagOptions.map(([tagID, label]) => `<button class="creator-tag-tab${selectedCreatorTagID === tagID ? " active" : ""}" type="button" data-action="selectCreatorTag" data-type-id="${esc(classifierType.id)}" data-tag-id="${esc(tagID)}" role="tab" aria-selected="${selectedCreatorTagID === tagID}">${esc(label.split(" · ")[0])}</button>`).join("")}</nav><div class="creator-tag-columns">${columns}</div></div>`;
        })()
        : `<div class="empty compact-empty">${!creatorRecords.length ? esc(t("bridge.noSources", { sources: sourceTerms.plural })) : tx("bridge.noCreatorTags")}</div>`;
      const tagNameByID = new Map((selectedTree?.nodes || []).map((node) => [node.id, node.name]));
      const decisionsByCreator = new Map();
      (selectedDataset?.creatorClassifications || []).forEach((record) => {
        if (record.classifierTypeID !== classifierType.id) return;
        const key = `${record.platformID}|${record.creatorID}`;
        const decisions = decisionsByCreator.get(key) || [];
        decisions.push(record);
        decisionsByCreator.set(key, decisions);
      });
      const creatorDecisionRows = sortedCreatorCandidates;
      const creatorDecisionRow = ([key, entry]) => {
        const decisions = decisionsByCreator.get(key) || [];
        const human = decisions.find((record) => record.origin === "manual");
        const llm = decisions.find((record) => record.origin === "llmAssist");
        const labelText = (record) => {
          if (!record) return tx("bridge.noDecision");
          const tags = [
            ...record.tags.map((tagID) => tagNameByID.get(tagID) || tagID),
            ...record.negativeTags.map((tagID) => `${tx("bridge.notTag")} ${tagNameByID.get(tagID) || tagID}`),
          ];
          return tags.join(", ") || tx("bridge.noTags");
        };
        const avatarURL = typeof entry.cachedCreatorAvatarURL === "string" ? entry.cachedCreatorAvatarURL : "";
        const avatar = avatarURL ? `<img class="creator-tag-card-avatar" src="${esc(avatarURL)}" alt="" aria-hidden="true" loading="lazy" decoding="async">` : `<span class="creator-tag-card-avatar creator-tag-card-avatar-fallback" aria-hidden="true">${esc(entry.creatorName.slice(0, 1).toUpperCase())}</span>`;
        return `<article class="creator-tag-card"><div class="creator-tag-card-profile">${avatar}<div><strong dir="auto">${esc(entry.creatorName)}</strong><span>${esc(platformDefinitions.get(entry.platformID)?.name || entry.platformID)}</span></div></div><div class="creator-tag-card-actions"><span class="small-copy">${tx("bridge.humanTags")}: ${esc(labelText(human))}</span><span class="small-copy">${tx("bridge.llmTags")}: ${esc(labelText(llm))}</span></div></article>`;
      };
      const creatorDecisionList = `<section class="classifier-type-section creator-classification-section"><div class="section-header"><div><h3>${tx("bridge.sourceDecisionList", { source: sourceTerms.singular })}</h3><p class="section-copy">${tx("bridge.sourceDecisionListCopy", { sources: sourceTerms.plural })}</p></div></div><div class="creator-tag-column-list">${incrementalList(creatorDecisionRows, creatorDecisionRow, `<div class="empty compact-empty">${esc(t("bridge.noSources", { sources: sourceTerms.plural }))}</div>`)}</div></section>`;
      const llmModelControl = !selectedLLMProfile
        ? `<p class="small-copy">${tx("bridge.llmChooseProviderFirst")}</p>`
        : `<div class="field"><span class="field-label">${tx("bridge.llmModel")} · ${tx("bridge.llmModelCopy")}</span><select class="select-control" data-field="llmModelIdentifier"><option value="">${tx("bridge.llmChooseModel")}</option>${visibleModels.map((model) => `<option value="${esc(model)}"${selected(currentModel, model)}>${esc(model)}</option>`).join("")}</select><span class="action-row"><button type="button" class="secondary" data-action="probeProviderModelCatalog" data-profile-id="${esc(selectedLLMProfile.id)}"${disabled(loadingModelCatalogs.has(selectedLLMProfile.id))}>${tx(loadingModelCatalogs.has(selectedLLMProfile.id) ? "bridge.llmProbingModels" : "bridge.llmProbeModels")}</button><span class="small-copy">${esc(loadingModelCatalogs.has(selectedLLMProfile.id) ? tx("bridge.llmProbingModels") : modelCatalogErrors[selectedLLMProfile.id] || tx("bridge.llmProbeModelsCopy"))}</span></span></div>`;
      const llmActivation = llmAssist
        ? `<div class="action-row"><span class="small-copy">${tx(llmAssist.isActive ? (llmRunning ? "bridge.llmActivationRunning" : "bridge.llmActive") : "bridge.llmInactive")}</span><button class="${llmAssist.isActive ? "secondary" : "gold-action"}" data-action="setLLMAssistActive" data-type-id="${esc(classifierType.id)}" data-is-active="${llmAssist.isActive ? "false" : "true"}"${disabled(!llmAssist.isActive && (!creatorLLMReady || llmRunning))}>${tx(llmAssist.isActive ? "bridge.llmDeactivate" : "bridge.llmActivate")}</button></div>`
        : `<span class="small-copy">${tx("bridge.llmModelRequired")}</span>`;
      const llmLastOutcome = llmAssist?.lastClassificationOutcome;
      const llmClassificationStatus = llmAssist
        ? `<div class="llm-classification-status"><div><span class="eyebrow">${tx("bridge.llmClassificationStatus")}</span><p class="small-copy">${tx(llmAssist.isActive ? (llmRunning ? "bridge.llmActivationRunning" : "bridge.llmActive") : "bridge.llmInactive")}</p></div><div class="llm-classification-metrics"><span>${tx("bridge.llmQueuedCreators", { count: llmAssist.queuedCreatorCount || 0 })}</span><span>${tx("bridge.llmCompletedToday", { count: llmAssist.completedToday || 0 })}</span>${llmLastOutcome ? `<span>${tx("bridge.llmLastResult", { result: tx(llmLastOutcome === "succeeded" ? "bridge.llmOutcomeSucceeded" : "bridge.llmOutcomeFailed") })}</span>` : ""}</div></div>`
        : "";
      const webSearchControls = `${toggle("bridge.llmWebSearch", "llmWebSearchEnabled", llmAssist?.webSearchEnabled ?? false)}<p class="small-copy">${tx(classifierSupportsNativeWebSearch ? "bridge.llmNativeWebSearchCopy" : "bridge.llmRawWebSearchCopy")}</p>${(llmAssist?.webSearchEnabled ?? false) && !classifierSupportsNativeWebSearch ? valueSelectField("bridge.llmWebSearchProvider", "bridge.llmWebSearchProviderCopy", "llmWebSearchProviderProfileID", savedWebSearchProfileID, webSearchProviderOptions) : ""}`;
      const llmSettings = selectedLLMProfile ? `${llmClassificationStatus}<div class="classifier-llm-config">${valueSelectField("bridge.llmProvider", "bridge.llmProviderCopy", "llmProviderProfileID", selectedLLMProfileID, llmProviderOptions)}${llmModelControl}${field("bridge.llmDailyOutputBudget", "bridge.llmDailyOutputBudgetCopy", "llmDailyOutputTokenLimit", llmAssist?.dailyOutputTokenLimit || 10000, "text", "inputmode=\"numeric\"")}${llmAssist ? `<p class="small-copy">${tx("bridge.llmDailyOutputUsage", { used: llmAssist.dailyOutputTokensUsed || 0, limit: llmAssist.dailyOutputTokenLimit || 10000 })}</p>` : ""}${field("bridge.llmMaximumTokens", "bridge.llmMaximumTokensCopy", "llmMaximumOutputTokensPerRequest", llmAssist?.maximumOutputTokensPerRequest || 4096, "text", "inputmode=\"numeric\"")}${textareaField("bridge.llmExtraDirection", "bridge.llmExtraDirectionCopy", "llmExtraDirection", llmAssist?.extraDirection || "", "maxlength=\"4096\"")}${field("bridge.llmClassificationPace", "bridge.llmClassificationPaceCopy", "llmClassificationRequestsPerMinute", llmAssist?.classificationRequestsPerMinute || 6, "text", "inputmode=\"numeric\"")}${field("bridge.llmBatchSize", "bridge.llmBatchSizeCopy", "llmBatchSize", llmAssist?.batchSize || 5, "text", "inputmode=\"numeric\"")}${field("bridge.llmMaximumTagCount", "bridge.llmMaximumTagCountCopy", "llmMaximumTagCount", llmAssist?.maximumTagCount || 8, "text", "inputmode=\"numeric\"")}${toggle("bridge.llmLeafOnly", "llmRestrictToLeafTags", llmAssist?.restrictToLeafTags ?? true)}<p class="small-copy">${tx("bridge.llmLeafOnlyCopy")}</p>${webSearchControls}</div>` : `<div class="classifier-llm-config">${valueSelectField("bridge.llmProvider", "bridge.llmProviderCopy", "llmProviderProfileID", selectedLLMProfileID, llmProviderOptions)}</div>`;
      return `<section class="classifier-type-panel" data-form-id="${esc(formID)}" data-type-id="${esc(classifierType.id)}">
        <div class="classifier-type-head"><div><span class="eyebrow">${tx("bridge.typePanel")}</span><h3>${esc(classifierType.name)}</h3><p class="section-copy">${tx("bridge.typeMatchCopy", { tree: selectedTree?.name || t("bridge.missingAsset"), data: selectedDataset?.name || t("bridge.missingAsset") })}</p></div>${statusPill(typeStatus, applicablePlatformID ? "navy" : "muted")}</div>
        <div class="classifier-name-row">${field("bridge.typeName", "", "name", classifierType.name)}<button class="primary" data-action="configureClassifierType" data-form="${esc(formID)}" data-type-id="${esc(classifierType.id)}">${tx("bridge.saveType")}</button><button class="danger" data-action="confirmDeleteClassifierType" data-type-id="${esc(classifierType.id)}">${tx("bridge.deleteType")}</button></div>
        <section class="classifier-type-section classifier-applicable-platform-section"><div class="section-header"><div><h3>${tx("bridge.applicablePlatform")}</h3><p class="section-copy">${tx("bridge.assetSelectionCopy")}</p></div></div><div class="classifier-applicable-platform-row">${valueSelectField("bridge.applicablePlatform", "bridge.applicablePlatformCopy", "applicablePlatformID", applicablePlatformID, applicablePlatformOptions)}<div class="classifier-platform-data-status"><span class="eyebrow">${tx("bridge.platformData")}</span><p class="small-copy">${esc(platformDataStatus)}</p></div></div>${applicablePlatform && !supportsLocalModel && !supportsLLMAssist ? `<p class="small-copy" data-manual-only-platform-note>${tx("bridge.manualOnlyCopy")}</p>` : ""}</section>
        <section class="classifier-type-section classifier-local-model-section" data-local-model-section${supportsLocalModel ? "" : " hidden"}><div class="section-header"><div><h3>${tx("bridge.localModel")}</h3><p class="section-copy">${tx("bridge.localModelCopy")}</p></div></div><div class="classifier-local-model-field">${valueSelectField("bridge.localModel", "", "localModelID", classifierType.localModelID || "", modelOptions)}</div></section>
        <section class="classifier-type-section creator-classification-section"><div class="section-header"><div><h3>${tx("bridge.manualSource", { source: sourceTerms.singular })}</h3><p class="section-copy">${tx("bridge.manualSourceCopy", { source: sourceTerms.singular })}</p></div><div class="action-row"><span class="small-copy">${tx("bridge.sourceCount", { count: creatorRecords.length, sources: sourceTerms.plural })}</span></div></div>${creatorClassification}</section>
        <section class="classifier-type-section classifier-llm-section" data-llm-assist-section${supportsLLMAssist ? "" : " hidden"}><div class="section-header"><div><h3>${tx("bridge.llmAssist")}</h3><p class="section-copy">${tx("bridge.llmAssistCopy")}</p></div>${llmActivation}</div>${llmProfiles.length ? `${llmSettings}${creatorLLMClassification}` : `<div class="empty compact-empty">${tx("bridge.noLLMProfiles")}</div>`}</section>
        <section class="classifier-type-section classifier-decision-policy-section" data-decision-policy-section${supportsLocalModel || supportsLLMAssist ? "" : " hidden"}><div class="section-header"><div><h3>${tx("bridge.decisionPolicy")}</h3><p class="section-copy">${tx("bridge.decisionPolicyCopy")}</p></div></div><div class="classifier-priority-grid">${valueSelectField("bridge.priorityFirst", "", "priorityFirst", priority[0], sourceOptions)}${valueSelectField("bridge.prioritySecond", "", "prioritySecond", priority[1], sourceOptions)}${valueSelectField("bridge.priorityThird", "", "priorityThird", priority[2], sourceOptions)}</div></section>
        ${creatorDecisionList}
      </section>`;
    };
    return `<div class="workspace classifier-type-workspace">${header("bridge.title", "bridge.copy", t("bridge.typeLibrary"), "navy")}
      <section class="classifier-type-create" data-form-id="classifier-type-create-form">${field("bridge.newTypeName", "bridge.newTypeNameCopy", "name", "")}<button class="primary" data-action="createClassifierType" data-form="classifier-type-create-form">${tx("bridge.createType")}</button></section>
      <div class="classifier-type-panels">${classifierTypes.length ? classifierTypes.map(typeForm).join("") : `<div class="empty">${tx("bridge.emptyTypes")}</div>`}</div>${notice(state.issue, "red")}</div>`;
  }

  function classificationDataWorkspace() {
    const assets = state.assets;
    const bindings = assets.bindings || [];
    const datasets = assets.datasets || [];
    const definitions = assets.collectionPlatforms || [];
    const datasetByID = new Map(datasets.map((dataset) => [dataset.id, dataset]));
    const treeByID = new Map((assets.trees || []).map((tree) => [tree.id, tree]));
    const allCollected = datasets.flatMap((dataset) => dataset.collectedEntries || []);
    const classifierTypes = assets.classifierTypes || [];
    const models = assets.models || [];
    const availablePlatforms = definitions.filter((definition) => !bindings.some((binding) => binding.id === definition.id));
    const observedAt = (value) => {
      const numeric = Number(value);
      return Number.isFinite(numeric) ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(numeric)) : t("data.unknownDate");
    };
    const diagnostics = Array.isArray(state.collectionDiagnostics) ? state.collectionDiagnostics : [];
    const diagnosticsPanel = `<section class="collection-diagnostics"><div class="collection-diagnostics-head"><div><span class="eyebrow">${tx("data.diagnostics")}</span><p class="section-copy">${tx("data.diagnosticsCopy")}</p></div><button class="secondary" data-action="clearCollectionDiagnostics">${tx("data.clearDiagnostics")}</button></div>${diagnostics.length ? `<div class="collection-diagnostic-list">${diagnostics.map((entry) => {
      const checkpoint = [entry.platformID, entry.event, entry.detail, entry.outcome].filter(Boolean).join(" · ");
      return `<div class="collection-diagnostic-row"><span>${esc(checkpoint)}</span><time>${esc(observedAt(entry.recordedAtMilliseconds))}</time></div>`;
    }).join("")}</div>` : `<div class="empty collection-diagnostics-empty">${tx("data.noDiagnostics")}</div>`}</section>`;
    const collectionAttributeLabel = (key) => ({
      subscriberCount: "Subscribers",
      viewCount: "Views",
      published: "Published",
      duration: "Duration",
      details: "Details",
      metadata: "Feed details",
      creatorURL: "Creator page",
      sourceKind: "Source type"
    })[key] || String(key).replaceAll(/([A-Z])/g, " $1").replaceAll(/[._-]/g, " ").replace(/^./, (letter) => letter.toUpperCase());
    const bindingPanel = (binding) => {
      const definition = definitions.find((candidate) => candidate.id === binding.id);
      const sourceTerms = collectionSourceTerms(definition?.sourceKind);
      const dataset = datasetByID.get(binding.datasetID);
      const entries = (dataset?.collectedEntries || []).filter((entry) => entry.platformID === binding.id);
      const creators = new Map();
      entries.forEach((entry) => {
        const creatorID = entry.creatorID || "unknown";
        const group = creators.get(creatorID) || { id: creatorID, name: entry.creatorName || creatorID, entries: [], latestObservedAtMilliseconds: 0 };
        group.entries.push(entry);
        group.latestObservedAtMilliseconds = Math.max(group.latestObservedAtMilliseconds, Number(entry.lastObservedAtMilliseconds) || 0);
        creators.set(creatorID, group);
      });
      const creatorRows = [...creators.values()]
        .sort((lhs, rhs) => rhs.latestObservedAtMilliseconds - lhs.latestObservedAtMilliseconds);
      const creatorRow = (creator) => {
        const creatorEntries = [...creator.entries].sort((lhs, rhs) => (Number(rhs.lastObservedAtMilliseconds) || 0) - (Number(lhs.lastObservedAtMilliseconds) || 0));
        const avatarURL = creatorEntries.find((entry) => typeof entry.cachedCreatorAvatarURL === "string")?.cachedCreatorAvatarURL || "";
        const avatar = avatarURL ? `<img class="collection-creator-avatar" src="${esc(avatarURL)}" alt="" aria-hidden="true" loading="lazy" decoding="async">` : "";
        const entryListID = `deferred-creator-entries-${deferredCreatorEntrySequence += 1}`;
        deferredCreatorEntries.set(entryListID, {
          entries: creatorEntries,
          renderEntry: (entry) => {
            const attributes = Object.entries(entry.attributes || {})
              .filter(([key]) => key !== "creatorAvatarURL")
              .slice(0, 5)
              .map(([key, value]) => `${esc(collectionAttributeLabel(key))}: ${esc(value)}`)
              .join(" · ");
            return `<div class="collection-entry"><span class="collection-entry-title" dir="auto">${esc(entry.title)}</span><span class="collection-entry-meta">${esc(entry.entryType)} · ${observedAt(entry.lastObservedAtMilliseconds)}${attributes ? ` · ${attributes}` : ""}</span></div>`;
          },
        });
        return `<details class="collection-creator" data-deferred-creator-entries="${entryListID}"><summary>${avatar}<span class="collection-creator-name" dir="auto">${esc(creator.name)}</span><span class="collection-creator-count">${tx("data.entryCount", { count: creatorEntries.length })}</span></summary><div class="collection-entry-list"></div></details>`;
      };
      const creatorList = incrementalList(creatorRows, creatorRow);
      const formID = `collection-platform-${binding.id}`;
      const availability = definition?.collectorAvailable ? "data.collectorAvailable" : "data.collectorPlanned";
      const tree = treeByID.get(binding.treeID);
      const selectableTypes = classifierTypes.filter((classifierType) => {
        if (classifierType.applicablePlatformID !== binding.id || classifierType.treeID !== binding.treeID || classifierType.datasetID !== binding.datasetID || classifierType.treeRevision !== tree?.revision || classifierType.datasetRevision !== dataset?.revision) return false;
        if (!definition?.supportsLocalModel && classifierType.localModelID) return false;
        if (!definition?.supportsLLMAssist && classifierType.llmAssistConfiguration) return false;
        return !classifierType.localModelID || models.some((model) => model.id === classifierType.localModelID && model.ready && model.training);
      });
      const typeOptions = [["", t("data.noClassifierType")], ...selectableTypes.map((classifierType) => [classifierType.id, classifierType.name])];
      const typeStatus = binding.activeClassifierTypeID ? "data.classifierTypeActive" : "data.classifierTypeNone";
      const localOnlyNotice = binding.id === "discord" ? `<p class="small-copy collection-local-only">${tx("data.discordLocalOnly")}</p>` : "";
      return `<section class="collection-platform-panel" data-form-id="${esc(formID)}"><div class="collection-platform-head"><div><span class="eyebrow">${tx("data.platformPanel")}</span><h3>${esc(binding.name)}</h3><p class="section-copy">${esc(binding.browser)} · ${tx(availability)}</p></div><div class="collection-platform-actions">${statusPill(t(binding.collectionEnabled ? "data.collecting" : "data.collectionOff"), binding.collectionEnabled ? "cyan" : "muted")}<button class="danger" data-action="confirmDeleteCollectionPlatform" data-platform-id="${esc(binding.id)}">${tx("data.deletePlatform")}</button></div></div><div class="collection-platform-controls">${toggle("data.collectToggle", "enabled", Boolean(binding.collectionEnabled))}<button class="primary" data-action="setCollectionEnabled" data-form="${esc(formID)}" data-platform-id="${esc(binding.id)}">${tx("data.applyCollection")}</button><span class="small-copy">${tx("data.sourceCount", { count: creators.size, sources: sourceTerms.plural })} · ${tx("data.entryCount", { count: entries.length })}</span></div>${localOnlyNotice}<div class="collection-platform-controls">${valueSelectField("data.classifierType", "data.classifierTypeCopy", "classifierTypeID", binding.activeClassifierTypeID || "", typeOptions)}<button class="secondary" data-action="setActiveClassifierType" data-form="${esc(formID)}" data-platform-id="${esc(binding.id)}">${tx("data.applyClassifierType")}</button>${statusPill(t(typeStatus), binding.activeClassifierTypeID ? "navy" : "muted")}</div>${entries.length ? `<div class="collection-creators">${creatorList}</div>` : `<div class="empty collection-empty">${tx(binding.collectionEnabled ? "data.waitingForEntries" : "data.collectionDisabledCopy")}</div>`}</section>`;
    };
    return `<div class="workspace collection-workspace">${header("data.title", "data.copy", t("data.entries", { count: allCollected.length }), "cyan")}
      <section class="collection-platform-create" data-form-id="collection-platform-create-form"><div><span class="eyebrow">${tx("data.addPlatform")}</span><p class="section-copy">${tx("data.addPlatformCopy")}</p></div>${availablePlatforms.length ? `${valueSelectField("data.platform", "", "platformID", availablePlatforms[0].id, availablePlatforms.map((platform) => [platform.id, platform.name]))}<button class="primary" data-action="addCollectionPlatform" data-form="collection-platform-create-form">${tx("data.addPlatformAction")}</button>` : `<span class="small-copy">${tx("data.allPlatformsAdded")}</span>`}</section>
      ${diagnosticsPanel}
      <div class="collection-platform-panels">${bindings.length ? bindings.map(bindingPanel).join("") : `<div class="empty">${tx("data.noPlatforms")}</div>`}</div>
      ${notice(state.issue, "red")}</div>`;
  }

  function workspace() {
    switch (state.workspace) {
      case "localModel": return localModelWorkspace();
      case "llmAssist": return llmAssistWorkspace();
      case "browserBridge": return browserBridgeWorkspace();
      case "classificationData": return classificationDataWorkspace();
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
      const supportsLLMAssist = platform?.supportsLLMAssist === true;
      const isManualOnlyPlatform = Boolean(platform && !supportsLocalModel && !supportsLLMAssist);
      panel.querySelectorAll("[data-local-model-section]").forEach((section) => { section.hidden = !supportsLocalModel; });
      panel.querySelectorAll("[data-llm-assist-section]").forEach((section) => { section.hidden = !supportsLLMAssist; });
      panel.querySelectorAll("[data-decision-policy-section]").forEach((section) => { section.hidden = !supportsLocalModel && !supportsLLMAssist; });
      let note = panel.querySelector("[data-manual-only-platform-note]");
      if (!note) {
        note = document.createElement("p");
        note.className = "small-copy";
        note.dataset.manualOnlyPlatformNote = "";
        note.textContent = t("bridge.manualOnlyCopy");
        panel.querySelector(".classifier-applicable-platform-section")?.append(note);
      }
      if (note) note.hidden = !isManualOnlyPlatform;
      panel.querySelectorAll('[data-field="localModelID"], [data-field="creatorLocalModel"], [data-field="entryLocalModel"]').forEach((control) => {
        control.disabled = !supportsLocalModel;
        if (!supportsLocalModel && control.type === "checkbox") control.checked = false;
        if (!supportsLocalModel && control.dataset.field === "localModelID") control.value = "";
      });
      panel.querySelectorAll('[data-field^="llm"], [data-field="creatorLLM"], [data-field="entryLLM"]').forEach((control) => {
        control.disabled = !supportsLLMAssist;
        if (!supportsLLMAssist && control.type === "checkbox") control.checked = false;
        if (!supportsLLMAssist && control.type !== "checkbox") control.value = "";
      });
    });
  }

  function render() {
    rememberTreeViewportPositions();
    rememberEditorViewportPosition();
    resetDeferredRendering();
    root.innerHTML = state ? shell(workspace()) : `<div class="popup"><div class="empty">${tx("app.loading")}</div></div>`;
    applyApplicablePlatformCapabilities();
    observeIncrementalLists();
    window.requestAnimationFrame(() => {
      applyNavigationPanelWidth();
      restoreEditorViewportPosition();
      restoreTreeViewportPositions();
      drawTreeConnections();
      traceTreeLayout();
    });
  }

  function saveLLMClassifierTypeFields(panel) {
    const formID = panel?.dataset.formId;
    const typeID = panel?.dataset.typeId;
    if (!formID || !typeID) return;
    const data = collect(formID);
    // A provider alone is intentionally not a valid LLM attachment. Once the
    // user selects its fetched model, persist the complete type form on each
    // subsequent LLM-field change instead of leaving a session-only draft.
    if (!data.llmProviderProfileID || !data.llmModelIdentifier) return;
    data.typeID = typeID;
    send("configureClassifierType", data);
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
    if (action === "workspace") {
      const nextWorkspace = button.dataset.workspace;
      if (!state || !workspaceNames.has(nextWorkspace) || state.workspace === nextWorkspace) return;
      state.workspace = nextWorkspace;
      render();
      send("workspace", { workspace: nextWorkspace });
      return;
    }
    const data = button.dataset.form ? collect(button.dataset.form) : {};
    if (button.dataset.workspace) data.workspace = button.dataset.workspace;
    if (button.dataset.id) data.id = button.dataset.id;
    if (button.dataset.correction) data.correction = button.dataset.correction;
    if (button.dataset.utilityPanel) data.utilityPanel = button.dataset.utilityPanel;
    if (button.dataset.policyId) data.policyID = button.dataset.policyId;
    if (button.dataset.modelId) data.modelID = button.dataset.modelId;
    if (button.dataset.profileId) data.profileID = button.dataset.profileId;
    if (button.dataset.treeId) data.treeID = button.dataset.treeId;
    if (button.dataset.nodeId) data.nodeID = button.dataset.nodeId;
    if (button.dataset.parentId) data.parentID = button.dataset.parentId;
    if (button.dataset.platformId) data.platformID = button.dataset.platformId;
    if (button.dataset.typeId) data.typeID = button.dataset.typeId;
    if (button.dataset.isActive) data.isActive = button.dataset.isActive === "true";
    if (button.dataset.creatorKey) data.creatorKey = button.dataset.creatorKey;
    if (button.dataset.tagIds) {
      try {
        const tagIDs = JSON.parse(button.dataset.tagIds);
        if (!Array.isArray(tagIDs) || !tagIDs.every((tagID) => typeof tagID === "string")) return;
        data.tagIDs = tagIDs;
      } catch (_) {
        return;
      }
    }
    if (button.dataset.negativeTagIds) {
      try {
        const negativeTagIDs = JSON.parse(button.dataset.negativeTagIds);
        if (!Array.isArray(negativeTagIDs) || !negativeTagIDs.every((tagID) => typeof tagID === "string")) return;
        data.negativeTagIDs = negativeTagIDs;
      } catch (_) {
        return;
      }
    }
    if (action === "testProviderProfile") Object.assign(data, providerConnectionPayload(data, button.dataset.form));
    if (action === "selectCreatorTag") {
      const typeID = button.dataset.typeId;
      const tagID = button.dataset.tagId;
      if (!typeID || !tagID) return;
      selectedCreatorTagByType.set(typeID, tagID);
      render();
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
    if (action === "deleteLocalModel") {
      send("confirmDeleteLocalModel", data);
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
    const details = event.target.closest?.("details[data-deferred-creator-entries]");
    if (!details?.open || details.dataset.entriesLoaded === "true") return;
    const deferred = deferredCreatorEntries.get(details.dataset.deferredCreatorEntries);
    const list = details.querySelector(".collection-entry-list");
    if (!deferred || !list) return;
    list.innerHTML = deferred.entries.map(deferred.renderEntry).join("");
    details.dataset.entriesLoaded = "true";
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
    const llmProviderControl = event.target.closest('[data-field="llmProviderProfileID"]');
    if (llmProviderControl) {
      const panel = llmProviderControl.closest(".classifier-type-panel");
      const typeID = panel?.querySelector("[data-type-id]")?.dataset.typeId;
      if (typeID) selectedLLMProfileByType.set(typeID, llmProviderControl.value);
      if (typeID && llmProviderControl.value) send("selectLLMProvider", { typeID, profileID: llmProviderControl.value });
      render();
      return;
    }
    const llmField = event.target.closest('[data-field^="llm"]');
    if (llmField) {
      saveLLMClassifierTypeFields(llmField.closest(".classifier-type-panel"));
      return;
    }
    const control = event.target.closest("[data-local-model-setup]");
    if (!control) return;
    const panel = control.closest("[data-model-panel]");
    const formID = panel?.dataset.formId;
    const modelID = panel?.dataset.modelId;
    if (!formID || !modelID) return;
    const data = collect(formID);
    send("configureLocalModel", { modelID, treeID: data.treeID, platformIDs: data.platformIDs || [], baseEmbeddingID: data.baseEmbeddingID });
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

  // Mirror the Tags canvas: keep a two-axis trackpad gesture inside the
  // tree viewport instead of letting the surrounding editor consume it.
  document.addEventListener("wheel", (event) => {
    const map = event.target.closest("[data-tree-map]");
    if (!map || event.ctrlKey || event.metaKey) return;
    const horizontal = event.shiftKey && event.deltaX === 0 ? event.deltaY : event.deltaX;
    const vertical = event.shiftKey && event.deltaX === 0 ? 0 : event.deltaY;
    const startX = map.scrollLeft;
    const startY = map.scrollTop;
    map.scrollLeft += horizontal;
    map.scrollTop += vertical;
    if (map.scrollLeft !== startX || map.scrollTop !== startY) event.preventDefault();
    event.stopPropagation();
  }, { passive: false });

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
      const signature = JSON.stringify(payload);
      if (signature === renderedPayloadSignature) return;
      renderedPayloadSignature = signature;
      state = payload;
      render();
    },
  };

  window.addEventListener("resize", () => window.requestAnimationFrame(drawTreeConnections));
  render();
  send("state", {});
})();
