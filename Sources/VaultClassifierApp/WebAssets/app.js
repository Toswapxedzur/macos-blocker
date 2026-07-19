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
  const pendingTagRenameTimers = new Map();
  const pendingTagRenames = new Map();
  let utilityPanel = null;
  let selectedLanguage = "en";
  let navigationPanelWidth = navigationWidthRange.fallback;
  let navigationResize = null;

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

  function field(labelKey, hintKey, key, value, type = "text", extra = "") {
    return `<label class="field"><span class="field-label">${tx(labelKey)}${hintKey ? ` · ${tx(hintKey)}` : ""}</span><input type="${type}" data-field="${esc(key)}" value="${type === "password" ? "" : esc(value)}" ${extra}></label>`;
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

  function languageSelection() {
    return `<label class="header-language"><span class="visually-hidden">${tx("language.label")}</span><select class="select-control" data-language-selection aria-label="${tx("language.label")}">${languageChoices.map(([identifier, nameKey]) => `<option value="${esc(identifier)}"${selected(selectedLanguage, identifier)}>${tx(nameKey)}</option>`).join("")}</select></label>`;
  }

  function utilityPanelContent() {
    if (!utilityPanel) return "";
    let content = "";
    if (utilityPanel === "settings") {
      const settings = state.activity.settings;
      content = `<section class="utility-panel utility-settings-modal" data-form-id="utility-settings-form"><div class="utility-panel-head"><div><h2>${tx("utility.settings.title")}</h2><p class="section-copy">${tx("utility.settings.copy")}</p></div><button class="secondary utility-close" data-action="closeUtilityPanel">${tx("utility.close")}</button></div><div class="utility-settings-body"><section class="utility-settings-section"><h3 class="utility-settings-section-title">${tx("activity.resources")}</h3><div class="utility-settings-fields">${selectField("activity.profile", "activity.profileHint", "profile", settings.profile, [["light", "enum.profile.light"], ["balanced", "enum.profile.balanced"], ["aggressive", "enum.profile.aggressive"]])}${field("activity.cacheCapacity", "activity.uniqueEntries", "cacheCapacity", settings.cacheCapacity)}${selectField("activity.packageUpdates", "activity.preference", "packageUpdateMode", settings.packageUpdateMode, [["automatic", "enum.update.automatic"], ["downloadThenAsk", "enum.update.downloadThenAsk"], ["manual", "enum.update.manual"]])}</div><div class="utility-toggles">${toggle("activity.idleWork", "allowIdleWork", settings.allowIdleWork)}${toggle("activity.backgroundSync", "allowBackgroundSync", settings.allowBackgroundSync)}${toggle("activity.auditDispatch", "allowLocalLLMAudit", settings.allowLocalLLMAudit)}</div></section><section class="utility-setting-card"><div><h3>${tx("bridge.settingsTitle")}</h3><p class="section-copy">${tx("bridge.settingsCopy")}</p></div><button class="secondary" data-action="openUtilityPanel" data-utility-panel="browserBridge">${tx("bridge.openSettings")}</button></section></div><div class="utility-modal-actions"><button class="primary" data-action="saveResourceSettings" data-form="utility-settings-form">${tx("activity.save")}</button></div></section>`;
    }
    if (utilityPanel === "browserBridge") {
      content = browserBridgeSettingsPopover();
    }
    if (!content) return "";
    const title = utilityPanel === "browserBridge" ? tx("bridge.settingsTitle") : tx("utility.settings.title");
    return `<div class="utility-popover-layer" role="presentation"><button class="utility-popover-dismiss" data-action="closeUtilityPanel" aria-label="${tx("utility.close")}"></button><div class="utility-popover" role="dialog" aria-modal="true" aria-label="${esc(title)}">${content}</div></div>`;
  }

  function browserBridgeSettingsPopover() {
    const hub = state.bridge || {};
    const connected = hub.state === "connected";
    const stateKey = `bridge.status.${hub.state || "off"}`;
    const peers = Array.isArray(hub.peers) ? hub.peers : [];
    const peerLabels = peers.filter((peer) => peer && peer.program).map((peer) => esc(peer.program)).join(", ") || tx("bridge.noPeers");
    return `<section class="utility-panel utility-bridge-modal"><div class="utility-panel-head"><div><h2>${tx("bridge.settingsTitle")}</h2><p class="section-copy">${tx("bridge.settingsCopy")}</p></div><div class="action-row"><button class="secondary" data-action="openUtilityPanel" data-utility-panel="settings">${tx("bridge.backToSettings")}</button><button class="secondary utility-close" data-action="closeUtilityPanel">${tx("utility.close")}</button></div></div><div class="bridge-local-status"><span class="status-dot ${connected ? "connected" : ""}"></span><strong>${tx(stateKey)}</strong></div><p class="bridge-address"><strong>${tx("bridge.hubAddress")}:</strong> <code>${esc(hub.address || "ws://127.0.0.1:8787")}</code></p><label class="toggle-row bridge-server-toggle"><input type="checkbox" data-bridge-server-toggle${connected ? " checked" : ""}><span>${tx("bridge.connect")}</span></label><p class="small-copy">${tx("bridge.hostCopy")}</p><p class="bridge-peer-copy">${tx("bridge.peers")}: ${peerLabels}</p>${hub.error ? notice(hub.error, "red") : ""}</section>`;
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
      ${toggle("activity.idleWork", "allowIdleWork", settings.allowIdleWork)}${toggle("activity.backgroundSync", "allowBackgroundSync", settings.allowBackgroundSync)}${toggle("activity.auditDispatch", "allowLocalLLMAudit", settings.allowLocalLLMAudit)}
      <div class="action-row"><button class="primary" data-action="saveResourceSettings" data-form="resource-form">${tx("activity.save")}</button></div>
      </div></section>
      <section class="section-card cyan"><div class="section-header"><div><h3>${tx("activity.recent")}</h3><p class="section-copy">${tx("activity.newest")}</p></div><button class="secondary" data-action="state">${tx("common.refresh")}</button></div>${activity.ledger.length ? `<div class="list">${activity.ledger.map((entry) => `<div class="list-row"><span class="list-symbol">${entry.hasCorrection ? "!" : "✓"}</span><span class="list-copy"><span class="list-title">${esc(entry.cacheKey)}</span><span class="list-meta">${esc(enumText("grade", entry.grade))} · ${esc(entry.modelVersion)}</span></span>${entry.hasCorrection ? `<button class="secondary" data-action="clearCorrection" data-id="${esc(entry.id)}">${tx("common.clear")}</button>` : ""}</div>`).join("")}</div>` : `<div class="empty">${tx("activity.empty")}</div>`}</section>${notice(state.issue, "red")}</div>`;
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

  function auditWorkspace() {
    const audit = state.audit;
    const statusKey = !audit.enabled ? "common.off" : !audit.dispatchAllowed ? "audit.resourceHold" : !audit.hasStoredKey ? "audit.keyNeeded" : "audit.ready";
    const tone = statusKey === "audit.ready" ? "gold" : "muted";
    const canQueue = audit.enabled && audit.dispatchAllowed;
    return `<div class="workspace">${header("audit.title", "audit.copy", t(statusKey), tone)}
      <section class="section-card gold" data-form-id="audit-form"><div class="section-header"><div><h3>${tx("audit.settings")}</h3><p class="section-copy">${tx("audit.settingsCopy")}</p></div></div><div class="form-stack">
      ${toggle("audit.enable", "enabled", audit.enabled)}
      <div class="form-row">${field("audit.provider", "audit.fixedAdapter", "providerLabel", t("audit.gemini"), "text", "readonly")}${selectField("audit.reasoning", "audit.perRequest", "effort", audit.effort, [["minimal", "enum.effort.minimal"], ["low", "enum.effort.low"], ["medium", "enum.effort.medium"], ["high", "enum.effort.high"]])}</div>
      ${field("audit.model", "audit.modelHint", "modelIdentifier", audit.modelIdentifier)}
      ${selectField("audit.selection", "audit.selectionHint", "selectionMode", audit.selectionMode, [["targetedFalseAllow", "enum.selection.targetedFalseAllow"], ["targetedWithRandomSample", "enum.selection.targetedWithRandomSample"], ["userMarkedOnly", "enum.selection.userMarkedOnly"]])}
      <div class="form-row">${field("audit.outputCap", "audit.outputHint", "outputCap", audit.outputCap)}${field("audit.requestCap", "audit.reservation", "requestCap", audit.requestCap)}${field("audit.weekly", "audit.accounting", "weeklyCap", audit.weeklyCap)}${field("audit.monthly", "audit.accounting", "monthlyCap", audit.monthlyCap)}</div>
      ${toggle("audit.polish", "localLearning", audit.localLearning)}
      <div class="action-row"><button class="gold-action" data-action="saveAudit" data-form="audit-form">${tx("audit.save")}</button></div>
      </div></section>
      ${!audit.dispatchAllowed ? notice(t("audit.dispatchHeld"), "gold") : ""}
      <section class="section-card gold"><div class="section-header"><div><h3>${tx("audit.key")}</h3><p class="section-copy">${tx("audit.keyCopy")}</p></div></div><div class="action-row"><button class="secondary" data-action="presentGeminiCredentialEntry">${tx(audit.hasStoredKey ? "audit.replace" : "audit.store")}</button>${audit.hasStoredKey ? `<button class="danger" data-action="removeGeminiKey">${tx("audit.remove")}</button>` : ""}</div></section>
      <div class="action-row"><button class="secondary" data-action="queueSuggestedAudits"${disabled(!canQueue)}>${tx("audit.queueRisk")}</button><button class="secondary" data-action="queueCurrentAudit"${disabled(!audit.enabled)}>${tx("audit.queueCurrent")}</button><button class="secondary" data-action="copyDiagnostics">${tx("audit.copyDiagnostics")}</button></div>
      <div class="metric-row">${metric("audit.queued", audit.candidateCount, "gold")}${metric("audit.settled", audit.settledCount, "gold")}${metric("audit.inFlight", audit.inFlightCount, "gold")}${metric("audit.uncertain", audit.uncertainCount, "gold")}${metric("audit.weeklyTokens", audit.weeklyTokens, "gold")}${metric("audit.monthlyTokens", audit.monthlyTokens, "gold")}</div>
      <section class="section-card gold"><div class="section-header"><div><h3>${tx("audit.queue")}</h3><p class="section-copy">${tx("audit.queueCopy")}</p></div></div>${audit.candidates.length ? `<div class="list">${audit.candidates.map((candidate) => `<div class="list-row"><span class="list-symbol">?</span><span class="list-copy"><span class="list-title">${esc(enumText("intent", candidate.intent))}</span><span class="list-meta">${tx("audit.risk", { value: percent(candidate.priority) })} · ${esc(candidate.modelVersion)}</span></span>${statusPill(t(candidate.eligible ? "audit.eligible" : "audit.held"), candidate.eligible ? "gold" : "red")}<button class="gold-action" data-action="runAudit" data-id="${esc(candidate.id)}"${disabled(!candidate.eligible || !audit.enabled || !audit.dispatchAllowed || !audit.hasStoredKey || candidate.running)}>${tx(candidate.running ? "audit.running" : "audit.run")}</button></div>`).join("")}</div>` : `<div class="empty">${tx("audit.emptyQueue")}</div>`}</section>
      <section class="section-card gold"><div class="section-header"><div><h3>${tx("audit.results")}</h3><p class="section-copy">${tx("audit.resultsCopy")}</p></div></div>${audit.results.length ? `<div class="list">${audit.results.map((result) => `<div class="list-row"><span class="list-symbol">${result.finding === "potentialFalseAllow" ? "!" : "✓"}</span><span class="list-copy"><span class="list-title">${esc(enumText("finding", result.finding))}</span><span class="list-meta">${esc(result.leafTags.join(", ") || t("audit.noLeaf"))} · ${tx("audit.tokens", { count: result.tokens })}</span>${result.canApply ? `<span class="list-meta">${tx("audit.confirm")} ${result.policyIDs.map((policyID) => `<button class="secondary" data-action="confirmAudit" data-id="${esc(result.id)}" data-policy-id="${esc(policyID)}">${tx("audit.polishPolicy", { policy: policyID })}</button>`).join(" ")}</span>` : ""}</span></div>`).join("")}</div>` : `<div class="empty">${tx("audit.emptyResults")}</div>`}</section>
      ${notice(state.notices.auditDiagnostic, "gold")}${notice(state.issue, "red")}</div>`;
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
      const panelExtentY = panelState ? panelState.y + 214 : 0;
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
        const actions = isTreeDelete
          ? `<button class="secondary" data-action="cancelTagPanel">${tx("tree.cancel")}</button><button class="danger" data-action="confirmDeleteTree" data-tree-id="${esc(tree.id)}">${tx("tree.confirmDeleteAction")}</button>`
          : isTreeEdit
            ? `<button class="primary" data-action="saveTreeName" data-form="tag-popover-form" data-tree-id="${esc(tree.id)}">${tx("tree.saveTreeName")}</button>`
            : isEdit
          ? `<button class="secondary" data-action="beginConnection" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}">${tx("tree.connection")}</button><button class="secondary" data-action="disconnectTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}"${disabled(!popoverNode.parentID)}>${tx("tree.disconnection")}</button><button class="danger" data-action="deleteTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}">${tx("tree.deleteNode")}</button>`
          : `<button class="primary" data-action="addTag" data-form="tag-popover-form" data-tree-id="${esc(tree.id)}">${tx("tree.createNode")}</button>`;
        const content = isTreeDelete
          ? `<p class="small-copy">${tx("tree.confirmDeleteCopy")}</p><div class="action-row">${actions}</div>`
          : `${nameField}${actions ? `<div class="action-row">${actions}</div>` : ""}`;
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
    const panel = (model) => {
      const formID = `local-model-${model.id}`;
      const tree = assets.trees.find((candidate) => candidate.id === model.treeID);
      const platformIDs = model.platformIDs?.length
        ? model.platformIDs
        : [model.platformID || assets.bindings.find((binding) => binding.datasetID === model.datasetID)?.id].filter(Boolean);
      const dataset = assets.datasets.find((candidate) => candidate.id === model.datasetID);
      const treeOptions = assets.trees.map((candidate) => [candidate.id, `${candidate.name} · r${candidate.revision}`]);
      const platformOptions = assets.bindings.map((binding) => [binding.id, `${binding.name} · ${binding.browser}`]);
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
      <section class="model-create" data-form-id="new-local-model-form">${field("model.modelName", "", "name", "")}<button class="pink-action" data-action="createLocalModel" data-form="new-local-model-form"${disabled(!assets.trees.length || !assets.bindings.length)}>${tx("model.create")}</button><span class="small-copy">${tx("model.multiplePanels")}</span></section>
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
      linkedIn: "llm.provider.linkedIn",
      pinterest: "llm.provider.pinterest",
      bluesky: "llm.provider.bluesky",
      mastodon: "llm.provider.mastodon",
      vimeo: "llm.provider.vimeo",
      dailyMotion: "llm.provider.dailyMotion",
      spotify: "llm.provider.spotify",
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

  function credentialFieldLabelKey(fieldName) {
    const keys = {
      apiKey: "llm.credential.apiKey",
      bearerToken: "llm.credential.bearerToken",
      clientSecret: "llm.credential.clientSecret",
      accessKeyID: "llm.credential.accessKeyID",
      secretAccessKey: "llm.credential.secretAccessKey",
      sessionToken: "llm.credential.sessionToken",
    };
    return keys[fieldName] || "llm.apiKey";
  }

  function tokenCost(value) {
    return value === null || value === undefined || !Number.isFinite(Number(value))
      ? t("llm.costUnavailable")
      : t("llm.cost", { value: Number(value).toFixed(6) });
  }

  function protocolConfigurationField(requirement, profile) {
    const value = profile.protocolConfiguration?.[requirement.field] ?? requirement.defaultValue ?? "";
    const hint = requirement.requiredForDispatch ? "llm.protocol.required" : "";
    return field(protocolFieldLabelKey(requirement.field), hint, `protocol.${requirement.field}`, value);
  }

  function llmAssistWorkspace() {
    const profiles = state.assets.providerProfiles || [];
    const requestRecords = state.assets.providerRequestRecords || [];
    const profileTypeGroups = [
      ["llm.providerGroup.models", ["openAI", "deepSeek", "gemini", "anthropic", "mistral", "cohere", "groq", "openRouter", "ollama"].map((type) => [type, t(providerTypeLabelKey(type))])],
      ["llm.providerGroup.platform", ["youtubeData", "twitch", "reddit", "xPlatform", "tikTok", "instagramGraph", "facebookGraph", "linkedIn", "pinterest", "bluesky", "mastodon", "vimeo", "dailyMotion", "spotify"].map((type) => [type, t(providerTypeLabelKey(type))])],
      ["llm.providerGroup.custom", ["openAICompatible", "custom"].map((type) => [type, t(providerTypeLabelKey(type))])],
    ];
    const panel = (profile) => {
      const formID = `provider-profile-${profile.id}`;
      const protocol = state.assets.providerProtocols?.[profile.type] || {};
      const supportsLLM = Boolean(protocol.supportsLLMConfiguration);
      const hasSessionCredential = Boolean(profile.hasSessionCredential);
      const profileRecords = requestRecords.filter((record) => record.profileID === profile.id);
      const tokenTotals = profileRecords.filter((record) => record.outcome === "succeeded").reduce((total, record) => ({
        input: total.input + (Number(record.inputTokens) || 0),
        output: total.output + (Number(record.outputTokens) || 0),
        cost: total.cost + (Number(record.estimatedCostUSD) || 0),
        priced: total.priced || record.estimatedCostUSD !== null,
      }), { input: 0, output: 0, cost: 0, priced: false });
      const credentialStatus = !protocol.credentialRequired ? "llm.noCredentialStatus" : (profile.hasStoredCredential ? "llm.credentialStored" : (hasSessionCredential ? "llm.sessionCredential" : "llm.credentialNeeded"));
      const protocolFields = (protocol.configurationRequirements || []).map((requirement) => protocolConfigurationField(requirement, profile)).join("");
      const requiresCompatibleEndpoint = ["openAICompatible", "custom"].includes(profile.type);
      const endpointField = protocol.allowsEndpointOverride ? field("llm.apiEndpoint", requiresCompatibleEndpoint ? "llm.compatibleEndpointCopy" : "llm.apiEndpointCopy", "customEndpoint", profile.customEndpoint || "") : "";
      const pricing = supportsLLM ? `<section class="provider-pricing"><div class="section-header"><div><h3>${tx("llm.tokenCost")}</h3><p class="section-copy">${tx("llm.tokenCostCopy")}</p></div></div><div class="provider-pricing-fields">${field("llm.inputCost", "", "inputCostUSDPerMillion", profile.inputCostUSDPerMillion ?? "", "text", "inputmode=\"decimal\"")}${field("llm.outputCost", "", "outputCostUSDPerMillion", profile.outputCostUSDPerMillion ?? "", "text", "inputmode=\"decimal\"")}</div>${toggle("llm.fullRecords", "storesFullRequestRecords", Boolean(profile.storesFullRequestRecords))}<p class="small-copy">${tx("llm.fullRecordsCopy")}</p></section>` : "";
      const setup = supportsLLM
        ? `<div class="provider-setup"><div class="section-header"><div><h3>${tx("llm.modelSetup")}</h3><p class="section-copy">${tx("llm.modelSetupCopy")}</p></div></div><div class="provider-setup-fields">${field("llm.modelIdentifier", "", "modelIdentifier", profile.modelIdentifier)}${field("llm.batchSize", "", "batchSize", profile.batchSize, "text", "inputmode=\"numeric\"")}${field("llm.maximumTokens", "", "maximumTokens", profile.maximumTokens, "text", "inputmode=\"numeric\"")}</div>${endpointField}</div>${pricing}`
        : `<div class="provider-setup"><div class="section-header"><div><span class="eyebrow">${tx("llm.externalTool")}</span><h3>${tx("llm.platformDataSetup")}</h3><p class="section-copy">${tx("llm.dataAPIOnlyCopy")}</p></div></div>${endpointField}</div>`;
      const credentialFormID = `${formID}-credential`;
      const credentialFields = (protocol.credentialFields || []).map((fieldName) => field(credentialFieldLabelKey(fieldName), "", `credential.${fieldName}`, "", "password", "autocomplete=\"off\" autocapitalize=\"off\" spellcheck=\"false\"")).join("");
      const credentials = protocol.credentialRequired ? `<div class="provider-credential-entry" data-form-id="${esc(credentialFormID)}">${credentialFields}<p class="small-copy">${tx("llm.keychainCopy")}</p><div class="provider-credential-row">${toggle("llm.storeInKeychain", "storeInKeychain", false)}<button class="secondary" data-action="saveProviderCredential" data-form="${esc(credentialFormID)}" data-profile-id="${esc(profile.id)}">${tx("llm.saveCredential")}</button>${(profile.hasStoredCredential || hasSessionCredential) ? `<button class="danger" data-action="removeProviderCredential" data-profile-id="${esc(profile.id)}">${tx("llm.removeKey")}</button>` : ""}</div></div>` : `<p class="small-copy">${tx("llm.noCredential")}</p>`;
      const endpointReady = !requiresCompatibleEndpoint || Boolean(profile.customEndpoint);
      const testAvailable = supportsLLM && endpointReady && (!protocol.credentialRequired || profile.hasStoredCredential || hasSessionCredential);
      const history = supportsLLM ? `<section class="provider-history"><div class="section-header"><div><h3>${tx("llm.requestHistory")}</h3><p class="section-copy">${tx("llm.requestHistoryCopy")}</p></div><span class="small-copy">${tx("llm.tokenTotals", { input: tokenTotals.input, output: tokenTotals.output, cost: tokenTotals.priced ? tokenCost(tokenTotals.cost) : t("llm.costUnavailable") })}</span></div>${profileRecords.length ? `<div class="list">${profileRecords.slice(0, 8).map((record) => `<div class="list-row"><span class="list-symbol">${record.outcome === "succeeded" ? "✓" : "!"}</span><span class="list-copy"><span class="list-title">${esc(record.model)} · ${esc(record.outcome)}</span><span class="list-meta">${esc(record.method)} · ${esc(record.endpoint)} · ${record.statusCode ?? "—"} · ${record.durationMilliseconds}ms · ${tx("llm.tokens", { input: record.inputTokens ?? "—", output: record.outputTokens ?? "—" })} · ${tokenCost(record.estimatedCostUSD)}</span>${record.requestContent || record.responseContent ? `<span class="request-record-content"><strong>${tx("llm.request")}</strong> ${esc(record.requestContent || "")}<strong>${tx("llm.response")}</strong> ${esc(record.responseContent || "")}</span>` : ""}</span></div>`).join("")}</div>` : `<p class="small-copy">${tx("llm.noRequests")}</p>`}</section>` : "";
      const testButton = supportsLLM ? `<button class="gold-action" data-action="testProviderProfile" data-profile-id="${esc(profile.id)}"${disabled(!testAvailable || profile.testing)}>${tx(profile.testing ? "llm.testing" : "llm.test")}</button>` : "";
      return `<section class="provider-panel" data-provider-panel data-provider-id="${esc(profile.id)}" data-form-id="${esc(formID)}"><div class="provider-panel-head"><div><span class="eyebrow">${tx(supportsLLM ? "llm.providerPanel" : "llm.externalTool")}</span><h3>${esc(profile.name)}</h3><p class="section-copy">${tx(providerTypeLabelKey(profile.type))}</p></div><div class="provider-panel-status">${statusPill(t(credentialStatus), profile.hasStoredCredential ? "gold" : "muted")}</div></div><div class="provider-name-row">${field("llm.profileName", "", "name", profile.name)}<button class="secondary" data-action="configureProviderProfile" data-form="${esc(formID)}" data-profile-id="${esc(profile.id)}">${tx("llm.saveProfile")}</button>${testButton}<button class="danger" data-action="deleteProviderProfile" data-profile-id="${esc(profile.id)}">${tx("llm.deleteProfile")}</button></div><section class="provider-credential"><div class="section-header"><div><h3>${tx("llm.apiKey")}</h3></div>${credentials}</section>${protocolFields ? `<section class="provider-setup"><div class="section-header"><div><h3>${tx("llm.protocolSetup")}</h3><p class="section-copy">${tx("llm.protocolSetupCopy")}</p></div></div><div class="provider-setup-fields">${protocolFields}</div></section>` : ""}${setup}${history}</section>`;
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
    const sourceOptions = [
      ["human", t("bridge.source.human")],
      ["llmAssist", t("bridge.source.llmAssist")],
      ["localModel", t("bridge.source.localModel")],
    ];
    const typeForm = (classifierType) => {
      const formID = `classifier-type-${classifierType.id}`;
      const selectedTree = trees.find((tree) => tree.id === classifierType.treeID);
      const selectedDataset = datasets.find((dataset) => dataset.id === classifierType.datasetID);
      const sourceBindings = (assets.bindings || []).filter((binding) =>
        binding.treeID === classifierType.treeID && binding.datasetID === classifierType.datasetID
      );
      const dataSourcePlatformIDs = classifierType.dataSourcePlatformIDs?.length
        ? classifierType.dataSourcePlatformIDs
        : sourceBindings.map((binding) => binding.id);
      const dataSourcePlatforms = new Set(dataSourcePlatformIDs);
      const dataSourceOptions = sourceBindings.map((binding) => [binding.id, `${binding.name} · ${binding.browser}`]);
      const compatibleModels = models.filter((model) => model.ready &&
        model.treeID === classifierType.treeID &&
        model.treeRevision === selectedTree?.revision &&
        model.datasetID === classifierType.datasetID &&
        model.datasetRevision === selectedDataset?.revision &&
        new Set(model.platformIDs || [model.platformID].filter(Boolean)).size === dataSourcePlatforms.size &&
        (model.platformIDs || [model.platformID].filter(Boolean)).every((platformID) => dataSourcePlatforms.has(platformID)));
      const treeOptions = trees.map((tree) => [tree.id, `${tree.name} · r${tree.revision}`]);
      const datasetOptions = datasets.map((dataset) => [dataset.id, `${dataset.name} · r${dataset.revision}`]);
      const modelOptions = [["", t("bridge.noLocalModel")], ...compatibleModels.map((model) => [model.id, `${model.name} · v${model.version}`])];
      const selectedLLMIDs = new Set(classifierType.llmProfileIDs || []);
      const creatorSources = new Set(classifierType.creatorDecisionSources || []);
      const entrySources = new Set(classifierType.entryDecisionSources || []);
      const priority = classifierType.decisionPriority || ["human", "llmAssist", "localModel"];
      const localAvailable = Boolean(classifierType.localModelID) && compatibleModels.some((model) => model.id === classifierType.localModelID);
      const llmAvailable = selectedLLMIDs.size > 0;
      const sourceToggle = (fieldName, source, enabled, available) => `<label class="classifier-source-toggle"><input type="checkbox" data-field="${esc(fieldName)}"${checked(enabled)}${disabled(!available)}><span>${tx(`bridge.source.${source}`)}</span>${!available ? `<small>${tx(`bridge.sourceUnavailable.${source}`)}</small>` : ""}</label>`;
      const typeStatus = `${creatorSources.size || entrySources.size ? t("bridge.configured") : t("bridge.needsSource")}`;
      const leafTagOptions = (selectedTree?.nodes || [])
        .filter((node) => !node.retired && !(selectedTree?.nodes || []).some((candidate) => candidate.parentID === node.id))
        .sort((lhs, rhs) => lhs.name.localeCompare(rhs.name))
        .map((node) => [node.id, `${node.name} · ${node.id}`]);
      const currentDecisionByCreator = new Map((selectedDataset?.creatorClassifications || [])
        .filter((classification) => classification.classifierTypeID === classifierType.id)
        .map((classification) => [`${classification.platformID}|${classification.creatorID}`, classification]));
      const creatorCandidates = new Map();
      (selectedDataset?.collectedEntries || []).forEach((entry) => {
        if (!dataSourcePlatforms.has(entry.platformID) || !entry.creatorID || !entry.creatorName) return;
        const key = `${entry.platformID}|${entry.creatorID}`;
        const current = creatorCandidates.get(key);
        if (!current || Number(entry.lastObservedAtMilliseconds) > Number(current.lastObservedAtMilliseconds)) creatorCandidates.set(key, entry);
      });
      const creatorOptions = [...creatorCandidates.entries()]
        .sort(([, lhs], [, rhs]) => lhs.creatorName.localeCompare(rhs.creatorName))
        .map(([key, entry]) => {
          const platformName = platformDefinitions.get(entry.platformID)?.name || entry.platformID;
          const existing = currentDecisionByCreator.get(key);
          return [key, `${platformName} · ${entry.creatorName}${existing ? ` · ${t("bridge.creatorClassified")}` : ""}`];
        });
      const canClassifyCreator = creatorSources.has("human") && creatorOptions.length && leafTagOptions.length;
      const creatorLLMProfiles = llmProfiles.filter((profile) => selectedLLMIDs.has(profile.id));
      const creatorLLMReady = creatorLLMProfiles.some((profile) =>
        (profile.hasStoredCredential || profile.hasSessionCredential) &&
        (!["openAICompatible", "custom"].includes(profile.type) || Boolean(profile.customEndpoint))
      );
      const llmRunning = Boolean(state.inspect?.llmRunning);
      const creatorLLMClassification = creatorSources.has("llmAssist")
        ? creatorLLMProfiles.length
          ? `<div class="creator-llm-row">${valueSelectField("bridge.creatorLLMProfile", "bridge.creatorLLMProfileCopy", "creatorLLMProfileID", creatorLLMProfiles[0].id, creatorLLMProfiles.map((profile) => [profile.id, `${profile.name} · ${profile.modelIdentifier}`]))}<button class="gold-action" data-action="classifyCreatorWithLLM" data-form="${esc(formID)}" data-type-id="${esc(classifierType.id)}"${disabled(!creatorOptions.length || !creatorLLMReady || llmRunning)}>${tx(llmRunning ? "bridge.creatorLLMClassifying" : "bridge.classifyCreatorWithLLM")}</button></div><p class="small-copy">${tx("bridge.creatorLLMExplicitOnly")}</p>`
          : `<p class="small-copy">${tx("bridge.creatorLLMRequired")}</p>`
        : "";
      const creatorClassification = creatorOptions.length && leafTagOptions.length
        ? `<div class="creator-classification-fields">${valueSelectField("bridge.creator", "bridge.creatorCopy", "creatorKey", creatorOptions[0][0], creatorOptions)}${multiValueSelectField("bridge.creatorTags", "bridge.creatorTagsCopy", "tagIDs", [], leafTagOptions)}</div><div class="action-row"><button class="primary" data-action="recordCreatorClassification" data-form="${esc(formID)}" data-type-id="${esc(classifierType.id)}"${disabled(!canClassifyCreator)}>${tx("bridge.classifyCreator")}</button>${!creatorSources.has("human") ? `<span class="small-copy">${tx("bridge.creatorHumanRequired")}</span>` : ""}</div>${creatorLLMClassification}`
        : `<div class="empty compact-empty">${tx(!creatorOptions.length ? "bridge.noCreators" : "bridge.noCreatorTags")}</div>`;
      return `<section class="classifier-type-panel" data-form-id="${esc(formID)}"><div class="classifier-type-head"><div><span class="eyebrow">${tx("bridge.typePanel")}</span><h3>${esc(classifierType.name)}</h3><p class="section-copy">${tx("bridge.typeMatchCopy", { tree: selectedTree?.name || t("bridge.missingAsset"), data: selectedDataset?.name || t("bridge.missingAsset") })}</p></div>${statusPill(typeStatus, creatorSources.size || entrySources.size ? "navy" : "muted")}</div><div class="classifier-name-row">${field("bridge.typeName", "", "name", classifierType.name)}<button class="primary" data-action="configureClassifierType" data-form="${esc(formID)}" data-type-id="${esc(classifierType.id)}">${tx("bridge.saveType")}</button><button class="danger" data-action="confirmDeleteClassifierType" data-type-id="${esc(classifierType.id)}">${tx("bridge.deleteType")}</button></div><section class="classifier-type-section"><div class="section-header"><div><h3>${tx("bridge.assetSelection")}</h3><p class="section-copy">${tx("bridge.assetSelectionCopy")}</p></div></div><div class="classifier-asset-grid">${valueSelectField("bridge.tagTree", "", "treeID", classifierType.treeID, treeOptions)}${valueSelectField("bridge.classificationData", "", "datasetID", classifierType.datasetID, datasetOptions)}${valueSelectField("bridge.localModel", "bridge.localModelCopy", "localModelID", classifierType.localModelID || "", modelOptions)}</div><div class="classifier-data-source-field">${multiValueSelectField("bridge.dataSources", "bridge.dataSourcesCopy", "dataSourcePlatformIDs", dataSourcePlatformIDs, dataSourceOptions)}</div></section><section class="classifier-type-section creator-classification-section"><div class="section-header"><div><h3>${tx("bridge.manualCreator")}</h3><p class="section-copy">${tx("bridge.manualCreatorCopy")}</p></div><span class="small-copy">${tx("bridge.creatorCount", { count: creatorOptions.length })}</span></div>${creatorClassification}</section><section class="classifier-type-section classifier-llm-section"><div class="section-header"><div><h3>${tx("bridge.llmAssist")}</h3><p class="section-copy">${tx("bridge.llmAssistCopy")}</p></div><span class="small-copy">${tx("bridge.llmExplicitOnly")}</span></div>${llmProfiles.length ? `<div class="classifier-profile-list">${llmProfiles.map((profile) => `<label class="classifier-profile-choice"><input type="checkbox" data-field="llmProfile.${esc(profile.id)}"${checked(selectedLLMIDs.has(profile.id))}><span>${esc(profile.name)}</span><small>${esc(profile.modelIdentifier)}</small></label>`).join("")}</div>` : `<div class="empty compact-empty">${tx("bridge.noLLMProfiles")}</div>`}</section><section class="classifier-type-section"><div class="section-header"><div><h3>${tx("bridge.decisionPolicy")}</h3><p class="section-copy">${tx("bridge.decisionPolicyCopy")}</p></div></div><div class="classifier-priority-grid">${valueSelectField("bridge.priorityFirst", "", "priorityFirst", priority[0], sourceOptions)}${valueSelectField("bridge.prioritySecond", "", "prioritySecond", priority[1], sourceOptions)}${valueSelectField("bridge.priorityThird", "", "priorityThird", priority[2], sourceOptions)}</div><div class="classifier-decision-grid"><section><span class="eyebrow">${tx("bridge.creatorDecision")}</span><p class="small-copy">${tx("bridge.creatorDecisionCopy")}</p><div class="classifier-source-list">${sourceToggle("creatorHuman", "human", creatorSources.has("human"), true)}${sourceToggle("creatorLLM", "llmAssist", creatorSources.has("llmAssist"), llmAvailable)}${sourceToggle("creatorLocalModel", "localModel", creatorSources.has("localModel"), localAvailable)}</div></section><section><span class="eyebrow">${tx("bridge.entryDecision")}</span><p class="small-copy">${tx("bridge.entryDecisionCopy")}</p><div class="classifier-source-list">${sourceToggle("entryHuman", "human", entrySources.has("human"), true)}${sourceToggle("entryLLM", "llmAssist", entrySources.has("llmAssist"), llmAvailable)}${sourceToggle("entryLocalModel", "localModel", entrySources.has("localModel"), localAvailable)}</div></section></div></section></section>`;
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
    const bindingPanel = (binding) => {
      const definition = definitions.find((candidate) => candidate.id === binding.id);
      const dataset = datasetByID.get(binding.datasetID);
      const entries = (dataset?.collectedEntries || []).filter((entry) => entry.platformID === binding.id);
      const creators = new Map();
      entries.forEach((entry) => {
        const creatorID = entry.creatorID || "unknown";
        const group = creators.get(creatorID) || { id: creatorID, name: entry.creatorName || creatorID, entries: [] };
        group.entries.push(entry);
        creators.set(creatorID, group);
      });
      const creatorRows = [...creators.values()]
        .sort((lhs, rhs) => Math.max(...rhs.entries.map((entry) => Number(entry.lastObservedAtMilliseconds) || 0)) - Math.max(...lhs.entries.map((entry) => Number(entry.lastObservedAtMilliseconds) || 0)))
        .map((creator) => {
          const creatorEntries = creator.entries.sort((lhs, rhs) => (Number(rhs.lastObservedAtMilliseconds) || 0) - (Number(lhs.lastObservedAtMilliseconds) || 0));
          return `<details class="collection-creator"><summary><span class="collection-creator-name">${esc(creator.name)}</span><span class="collection-creator-count">${tx("data.entryCount", { count: creatorEntries.length })}</span></summary><div class="collection-entry-list">${creatorEntries.map((entry) => {
            const attributes = Object.entries(entry.attributes || {}).slice(0, 5).map(([key, value]) => `${esc(key)}: ${esc(value)}`).join(" · ");
            return `<div class="collection-entry"><span class="collection-entry-title">${esc(entry.title)}</span><span class="collection-entry-meta">${esc(entry.entryType)} · ${observedAt(entry.lastObservedAtMilliseconds)}${attributes ? ` · ${attributes}` : ""}</span></div>`;
          }).join("")}</div></details>`;
        }).join("");
      const formID = `collection-platform-${binding.id}`;
      const availability = definition?.collectorAvailable ? "data.collectorAvailable" : "data.collectorPlanned";
      const tree = treeByID.get(binding.treeID);
      const selectableTypes = classifierTypes.filter((classifierType) => {
        if (classifierType.treeID !== binding.treeID || classifierType.datasetID !== binding.datasetID || classifierType.treeRevision !== tree?.revision || classifierType.datasetRevision !== dataset?.revision) return false;
        if (!(classifierType.entryDecisionSources || []).includes("localModel")) return true;
        return models.some((model) => model.id === classifierType.localModelID && model.ready && model.training);
      });
      const typeOptions = [["", t("data.noClassifierType")], ...selectableTypes.map((classifierType) => [classifierType.id, classifierType.name])];
      const typeStatus = binding.activeClassifierTypeID ? "data.classifierTypeActive" : "data.classifierTypeNone";
      return `<section class="collection-platform-panel" data-form-id="${esc(formID)}"><div class="collection-platform-head"><div><span class="eyebrow">${tx("data.platformPanel")}</span><h3>${esc(binding.name)}</h3><p class="section-copy">${esc(binding.browser)} · ${tx(availability)}</p></div><div class="collection-platform-actions">${statusPill(t(binding.collectionEnabled ? "data.collecting" : "data.collectionOff"), binding.collectionEnabled ? "cyan" : "muted")}<button class="danger" data-action="confirmDeleteCollectionPlatform" data-platform-id="${esc(binding.id)}">${tx("data.deletePlatform")}</button></div></div><div class="collection-platform-controls">${toggle("data.collectToggle", "enabled", Boolean(binding.collectionEnabled))}<button class="primary" data-action="setCollectionEnabled" data-form="${esc(formID)}" data-platform-id="${esc(binding.id)}">${tx("data.applyCollection")}</button><span class="small-copy">${tx("data.creatorCount", { count: creators.size })} · ${tx("data.entryCount", { count: entries.length })}</span></div><div class="collection-platform-controls">${valueSelectField("data.classifierType", "data.classifierTypeCopy", "classifierTypeID", binding.activeClassifierTypeID || "", typeOptions)}<button class="secondary" data-action="setActiveClassifierType" data-form="${esc(formID)}" data-platform-id="${esc(binding.id)}">${tx("data.applyClassifierType")}</button>${statusPill(t(typeStatus), binding.activeClassifierTypeID ? "navy" : "muted")}</div>${entries.length ? `<div class="collection-creators">${creatorRows}</div>` : `<div class="empty collection-empty">${tx(binding.collectionEnabled ? "data.waitingForEntries" : "data.collectionDisabledCopy")}</div>`}</section>`;
    };
    return `<div class="workspace collection-workspace">${header("data.title", "data.copy", t("data.entries", { count: allCollected.length }), "cyan")}
      <section class="collection-platform-create" data-form-id="collection-platform-create-form"><div><span class="eyebrow">${tx("data.addPlatform")}</span><p class="section-copy">${tx("data.addPlatformCopy")}</p></div>${availablePlatforms.length ? `${valueSelectField("data.platform", "", "platformID", availablePlatforms[0].id, availablePlatforms.map((platform) => [platform.id, platform.name]))}<button class="primary" data-action="addCollectionPlatform" data-form="collection-platform-create-form">${tx("data.addPlatformAction")}</button>` : `<span class="small-copy">${tx("data.allPlatformsAdded")}</span>`}</section>
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
    const timer = pendingTagRenameTimers.get(key);
    if (timer) window.clearTimeout(timer);
    pendingTagRenameTimers.delete(key);
    const name = pendingTagRenames.get(key);
    pendingTagRenames.delete(key);
    if (!name?.trim()) return;
    send("renameTag", { treeID, nodeID, name });
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
    const timer = pendingTagRenameTimers.get(key);
    if (timer) window.clearTimeout(timer);
    pendingTagRenameTimers.set(key, window.setTimeout(() => flushLiveTagRename(treeID, nodeID), 250));
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

  function render() {
    rememberTreeViewportPositions();
    rememberEditorViewportPosition();
    root.innerHTML = state ? shell(workspace()) : `<div class="popup"><div class="empty">${tx("app.loading")}</div></div>`;
    window.requestAnimationFrame(() => {
      applyNavigationPanelWidth();
      restoreEditorViewportPosition();
      restoreTreeViewportPositions();
      drawTreeConnections();
      traceTreeLayout();
    });
  }

  document.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-action]");
    if (!button) {
      const map = event.target.closest("[data-tree-map]");
      if (map && !event.target.closest(".tree-map-node, [data-tree-popover]")) {
        activeTagPanel = null;
        connectionSource = null;
        selectedTagNode = null;
        render();
      }
      return;
    }
    if (button.disabled) return;
    const action = button.dataset.action;
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
    if (action === "configureProviderProfile") {
      const protocolConfiguration = {};
      Object.keys(data).filter((key) => key.startsWith("protocol.")).forEach((key) => {
        protocolConfiguration[key.slice("protocol.".length)] = data[key];
        delete data[key];
      });
      data.protocolConfiguration = protocolConfiguration;
    }
    if (action === "saveProviderCredential") {
      const credentials = {};
      Object.keys(data).filter((key) => key.startsWith("credential.")).forEach((key) => {
        credentials[key.slice("credential.".length)] = data[key];
        delete data[key];
      });
      data.credentials = credentials;
    }
    if (action === "configureClassifierType") {
      data.llmProfileIDs = Object.keys(data)
        .filter((key) => key.startsWith("llmProfile.") && data[key] === true)
        .map((key) => key.slice("llmProfile.".length));
      Object.keys(data).filter((key) => key.startsWith("llmProfile.")).forEach((key) => delete data[key]);
    }
    if (action === "cancelTagPanel") {
      activeTagPanel = null;
      render();
      return;
    }
    if (action === "openUtilityPanel") {
      const nextPanel = ["settings", "browserBridge"].includes(data.utilityPanel) ? data.utilityPanel : null;
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

  document.addEventListener("change", (event) => {
    const bridgeServerToggle = event.target.closest("[data-bridge-server-toggle]");
    if (bridgeServerToggle) {
      send(bridgeServerToggle.checked ? "connectSharedHub" : "disconnectSharedHub");
      return;
    }
    const languageControl = event.target.closest("[data-language-selection]");
    if (languageControl) {
      if (!languageChoices.some(([identifier]) => identifier === languageControl.value)) return;
      selectedLanguage = languageControl.value;
      document.documentElement.lang = selectedLanguage;
      try { window.localStorage.setItem("vaultClassifier.language", selectedLanguage); } catch (_) {}
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
