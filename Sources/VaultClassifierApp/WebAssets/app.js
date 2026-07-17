(() => {
  "use strict";

  const root = document.getElementById("app");
  const strings = window.VaultClassifierStrings || {};
  let state = null;
  let renderedPayloadSignature = "";
  let activeTagPanel = null;
  let tagDrag = null;
  let suppressTagClick = false;
  const layoutTraceSignatures = new Map();
  const treeViewportPositions = new Map();

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
      values[control.dataset.field] = control.type === "checkbox" ? control.checked : control.value;
    });
    return values;
  }

  function field(labelKey, hintKey, key, value, type = "text", extra = "") {
    return `<label class="field"><span class="field-label">${tx(labelKey)}${hintKey ? ` · ${tx(hintKey)}` : ""}</span><input type="${type}" data-field="${esc(key)}" value="${type === "password" ? "" : esc(value)}" ${extra}></label>`;
  }

  function selectField(labelKey, hintKey, key, value, options) {
    return `<label class="field"><span class="field-label">${tx(labelKey)}${hintKey ? ` · ${tx(hintKey)}` : ""}</span><select class="select-control" data-field="${esc(key)}">${options.map(([id, labelKey]) => `<option value="${esc(id)}"${selected(value, id)}>${tx(labelKey)}</option>`).join("")}</select></label>`;
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

  function navButton(workspace, symbol, titleKey, metaKey, tone) {
    const active = state.workspace === workspace ? " active" : "";
    return `<button class="sidebar-row accent-${esc(tone)}${active}" type="button" data-action="workspace" data-workspace="${esc(workspace)}"><span class="sidebar-symbol" aria-hidden="true">${symbol}</span><span class="sidebar-copy"><span class="sidebar-name">${tx(titleKey)}</span><span class="sidebar-meta">${tx(metaKey)}</span></span></button>`;
  }

  function shell(content) {
    return `<div class="popup">
      <header class="hero">
        <div class="hero-copy"><span class="hero-mark" aria-hidden="true">V</span><div><h1>${tx("app.title")}</h1><p class="subtitle">${tx("hero.subtitle")}</p></div></div>
        <div class="hero-status"><span class="status-dot"></span>${tx("hero.offline")}</div>
      </header>
      <div class="layout">
        <aside class="navigation-panel" aria-label="${tx("navigation.aria")}">
          <div class="panel-header"><div><h2>${tx("navigation.title")}</h2><p class="small-copy">${tx("navigation.subtitle")}</p></div></div>
          <section class="sidebar-section"><span class="eyebrow">${tx("navigation.work")}</span><div class="sidebar-list">
            ${navButton("tagTree", "⌘", "navigation.tagTree", "navigation.tagTreeMeta", "cyan")}
            ${navButton("localModel", "◉", "navigation.localModel", "navigation.localModelMeta", "pink")}
            ${navButton("llmAssist", "◌", "navigation.llmAssist", "navigation.llmAssistMeta", "gold")}
            ${navButton("browserBridge", "⇄", "navigation.browserBridge", "navigation.browserBridgeMeta", "navy")}
            ${navButton("classificationData", "▤", "navigation.classificationData", "navigation.classificationDataMeta", "cyan")}
          </div></section>
          <div class="sidebar-status"><strong>${tx("navigation.localProfile")}</strong><br><span class="small-copy">${tx("navigation.assetCopy")}</span></div>
        </aside>
        <section class="editor-panel">${content}</section>
      </div>
    </div>`;
  }

  function inspectWorkspace() {
    const inspect = state.inspect;
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
        <div class="form-row">${field("inspect.sourceID", "inspect.optional", "sourceID", inspect.sourceID)}<div class="field"><span class="field-label">${tx("inspect.surface")} · ${tx("inspect.surfaceHint")}</span><div class="choice-row"><label><input type="radio" name="surface" data-field="surface" value="feed"${checked(inspect.surface === "feed")}><span>${tx("enum.surface.feed")}</span></label><label><input type="radio" name="surface" data-field="surface" value="page"${checked(inspect.surface === "page")}><span>${tx("enum.surface.page")}</span></label></div></div></div>
        <div class="action-row"><button class="primary" data-action="classify" data-form="inspect-form">${tx("inspect.classify")}</button><span class="small-copy">${tx("inspect.localOnly")}</span></div>
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
      <section class="section-card gold" data-form-id="key-form"><div class="section-header"><div><h3>${tx("audit.key")}</h3><p class="section-copy">${tx("audit.keyCopy")}</p></div></div><div class="action-row"><div class="field">${field("audit.keychain", audit.hasStoredKey ? "audit.replaceHint" : "audit.keyHint", "apiKey", "", "password")}</div><button class="secondary" data-action="storeGeminiKey" data-form="key-form">${tx(audit.hasStoredKey ? "audit.replace" : "audit.store")}</button>${audit.hasStoredKey ? `<button class="danger" data-action="removeGeminiKey">${tx("audit.remove")}</button>` : ""}</div></section>
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
      const selectedNode = panelState?.nodeID ? nodeByID.get(panelState.nodeID) : null;
      const parentChoices = (node, selectedParentID) => `<option value="">${tx("tree.rootLevel")}</option>${nodes.filter((candidate) => candidate.id !== node?.id).map((candidate) => `<option value="${esc(candidate.id)}"${selected(selectedParentID || "", candidate.id)}>${esc(candidate.name)}</option>`).join("")}`;
      const popover = panelState ? (() => {
        const isEdit = panelState.kind === "edit" && selectedNode;
        const parentID = isEdit ? selectedNode.parentID : panelState.parentID;
        const nodeID = isEdit ? selectedNode.id : "";
        const titleKey = isEdit ? "tree.editNode" : "tree.createNode";
        const action = isEdit ? "updateTag" : "addTag";
        return `<section class="tree-popover" style="left:${panelState.x}px;top:${panelState.y}px" data-tree-popover data-form-id="tag-popover-form"><div class="tree-popover-head"><span class="eyebrow">${tx(titleKey)}</span><button class="tree-popover-close" data-action="cancelTagPanel" title="${tx("tree.cancel")}" aria-label="${tx("tree.cancel")}">×</button></div><div class="tree-form">${field(isEdit ? "tree.nodeName" : "tree.tagName", "", "name", isEdit ? selectedNode.name : "")}<label class="field"><span class="field-label">${tx("tree.parent")}</span><select class="select-control" data-field="parentID">${parentChoices(isEdit ? selectedNode : null, parentID)}</select></label><div class="action-row"><button class="primary" data-action="${action}" data-form="tag-popover-form" data-tree-id="${esc(tree.id)}"${nodeID ? ` data-node-id="${esc(nodeID)}"` : ""}>${tx(isEdit ? "tree.saveNode" : "tree.createNode")}</button>${isEdit ? `<button class="secondary" data-action="toggleTagRetirement" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}">${tx(selectedNode.retired ? "tree.restore" : "tree.retire")}</button>` : ""}</div></div></section>`;
      })() : "";
      const map = `<div class="tree-map" data-tree-map data-tree-id="${esc(tree.id)}"><div class="tree-map-content" style="width:max(${mapWidth}px, calc(100% + 480px)); height:max(${mapHeight}px, calc(100% + 280px))"><svg class="tree-links" aria-hidden="true"></svg><div class="tree-map-title">${esc(tree.name)}</div><div class="tree-node-layer">${nodes.map((node) => {
        const position = positions.get(node.id);
        const depth = depthFor(node);
        const tier = depth === 0 ? "primary" : depth === 1 ? "secondary" : depth === 2 ? "tertiary" : "quaternary";
        return `<button class="tree-map-node ${tier}${panelState?.nodeID === node.id ? " active" : ""}${node.retired ? " retired" : ""}" style="left:${position.x}px;top:${position.y}px" data-action="selectTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(node.id)}" data-parent-id="${esc(node.parentID || "")}" data-position-x="${position.x}" data-position-y="${position.y}" title="${tx("tree.contextHint")}"><span aria-hidden="true"></span><strong>${esc(node.name)}</strong></button>`;
      }).join("")}</div>${nodes.length ? "" : `<div class="tree-map-empty">${tx("tree.empty")}</div>`}${popover}</div></div>`;
      return `<section class="tree-panel">${map}<p class="tree-canvas-hint">${tx("tree.canvasHint")}</p></section>`;
    };
    return `<div class="workspace tree-workspace">${header("tree.title", "tree.copy", t("tree.sharedLibrary"), "cyan")}
      <section class="tree-create" data-form-id="new-tree-form">${field("tree.treeName", "", "name", "")}<button class="primary" data-action="createTree" data-form="new-tree-form">${tx("tree.create")}</button><span class="small-copy">${tx("tree.multiplePanels")}</span></section><div class="tree-panels">${assets.trees.map(panel).join("")}</div>${notice(state.issue, "red")}</div>`;
  }

  function localModelWorkspace() {
    const assets = state.assets;
    const model = assets.models[0];
    const training = state.training;
    const backup = state.backup;
    return `<div class="workspace">${header("model.title", "model.copy", t(model?.ready ? "model.ready" : "model.needsTraining"), "pink")}
      <div class="metric-row">${metric("model.models", assets.models.length, "pink")}${metric("model.labels", training.labelCount, "pink")}${metric("model.versions", model?.version || 0, "pink")}</div>
      <section class="section-card pink"><div class="section-header"><div><h3>${tx("model.active")}</h3><p class="section-copy">${tx("model.activeCopy")}</p></div></div><div class="status-line"><strong>${esc(model?.name || t("model.none"))}</strong><span class="spacer"></span><span>${tx("model.boundRevisions", { tree: model?.treeRevision || 0, data: model?.datasetRevision || 0 })}</span></div></section>
      <section class="section-card pink" data-form-id="retrain-form"><div class="section-header"><div><h3>${tx("model.localTraining")}</h3><p class="section-copy">${tx("model.trainingCopy")}</p></div></div><div class="form-row">${field("model.passes", "", "epochs", training.epochs)}<div class="field"><span class="field-label">${tx("model.explicitAction")}</span><button class="pink-action" data-action="retrain" data-form="retrain-form"${disabled(!training.labelCount)}>${tx("model.train")}</button></div></div></section>
      <section class="section-card navy" data-form-id="backup-owner-form"><div class="section-header"><div><h3>${tx("model.backup")}</h3><p class="section-copy">${tx("model.backupCopy")}</p></div></div>${backup.unlocked ? `<div class="notice navy">${tx("backup.unlocked")}</div>` : `<div class="action-row"><div class="field">${field("backup.ownerCode", backup.hasOwnerCode ? "backup.existingCode" : "backup.newCode", "ownerCode", "", "password")}</div><button class="primary" data-action="${backup.hasOwnerCode ? "unlockBackup" : "setBackupOwnerCode"}" data-form="backup-owner-form">${tx(backup.hasOwnerCode ? "backup.unlock" : "backup.setCode")}</button></div>`}</section>
      <section class="section-card navy" data-form-id="backup-form"><div class="form-stack">${field("backup.localFolder", "backup.pathHint", "directory", backup.directory)}${toggle("backup.auto", "enabled", backup.enabled)}<div class="action-row"><button class="primary" data-action="saveBackup" data-form="backup-form"${disabled(!backup.unlocked)}>${tx("backup.save")}</button><button class="secondary" data-action="backupNow"${disabled(!backup.unlocked || !backup.savedEnabled)}>${tx("backup.create")}</button><span class="small-copy">${tx("model.backupStatus", { count: 4 })}</span></div></div></section>${notice(state.notices.backup, "navy")}${notice(state.notices.training, "pink")}${notice(state.issue, "red")}</div>`;
  }

  function llmAssistWorkspace() {
    const entries = state.assets.tokenUsage || [];
    const ledger = `<section class="section-card gold"><div class="section-header"><div><h3>${tx("llm.usage")}</h3><p class="section-copy">${tx("llm.usageCopy")}</p></div></div>${entries.length ? `<div class="list">${entries.map((entry) => `<div class="list-row"><span class="list-symbol">◌</span><span class="list-copy"><span class="list-title">${esc(entry.provider)} · ${esc(entry.model)}</span><span class="list-meta">${tx("llm.tokenLine", { input: entry.input, output: entry.output, other: entry.other })} · ${tx(`llm.status.${entry.status}`)}</span></span></div>`).join("")}</div>` : `<div class="empty">${tx("llm.noUsage")}</div>`}</section>`;
    const audit = auditWorkspace().replace(tx("audit.title"), tx("llm.title")).replace(tx("audit.copy"), tx("llm.copy"));
    return audit.replace(/<\/div>$/, `${ledger}</div>`);
  }

  function browserBridgeWorkspace() {
    const binding = state.assets.bindings[0];
    return `<div class="workspace">${header("bridge.title", "bridge.copy", t("bridge.macOnly"), "navy")}
      <section class="section-card navy"><div class="section-header"><div><h3>${tx("bridge.platform")}</h3><p class="section-copy">${tx("bridge.platformCopy")}</p></div></div><div class="status-line"><strong>${esc(binding?.name || t("bridge.none"))}</strong><span class="spacer"></span><span>${esc(binding?.browser || "")}</span></div><div class="status-line"><strong>${tx("bridge.assetBinding")}</strong><span class="spacer"></span><span>${tx("bridge.oneTreeDataset")}</span></div></section>
      <section class="section-card navy"><div class="section-header"><div><h3>${tx("bridge.policy")}</h3><p class="section-copy">${tx("bridge.policyCopy")}</p></div><button class="secondary" data-action="workspace" data-workspace="browserBridge">${tx("bridge.configure")}</button></div>${state.policies.items.length ? `<div class="list">${state.policies.items.map((policy) => `<div class="list-row"><span class="list-symbol">⌗</span><span class="list-copy"><span class="list-title">${esc(policy.name || policy.id)}</span><span class="list-meta">${esc(policy.id)}</span></span></div>`).join("")}</div>` : `<div class="empty">${tx("bridge.noPolicy")}</div>`}</section>${notice(state.issue, "red")}</div>`;
  }

  function classificationDataWorkspace() {
    const dataset = state.assets.datasets[0];
    const records = dataset?.records || [];
    const tree = state.assets.trees[0];
    return `<div class="workspace">${header("data.title", "data.copy", t("data.records", { count: records.length }), "cyan")}
      <section class="section-card cyan" data-form-id="manual-record-form"><div class="section-header"><div><h3>${tx("data.manual")}</h3><p class="section-copy">${tx("data.manualCopy")}</p></div></div><div class="form-stack">${field("data.entryTitle", "", "title", "")}${field("data.tagIDs", "data.tagIDsHint", "tags", tree?.nodes.filter((node) => !node.retired).map((node) => node.id).join(", ") || "")}<div class="action-row"><button class="primary" data-action="recordManualClassification" data-form="manual-record-form">${tx("data.record")}</button></div></div></section>
      <section class="section-card cyan"><div class="section-header"><div><h3>${tx("data.ledger")}</h3><p class="section-copy">${tx("data.ledgerCopy")}</p></div></div>${records.length ? `<div class="list">${records.map((record) => `<div class="list-row"><span class="list-symbol">${record.origin === "manual" ? "✓" : "◌"}</span><span class="list-copy"><span class="list-title">${esc(record.title)}</span><span class="list-meta">${esc(record.tags.join(", "))} · ${tx(`data.origin.${record.origin}`)} · ${tx(`data.review.${record.review}`)}</span></span></div>`).join("")}</div>` : `<div class="empty">${tx("data.empty")}</div>`}</section>${notice(state.issue, "red")}</div>`;
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

  function render() {
    rememberTreeViewportPositions();
    root.innerHTML = state ? shell(workspace()) : `<div class="popup"><div class="empty">${tx("app.loading")}</div></div>`;
    window.requestAnimationFrame(() => {
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
    if (button.dataset.policyId) data.policyID = button.dataset.policyId;
    if (button.dataset.treeId) data.treeID = button.dataset.treeId;
    if (button.dataset.nodeId) data.nodeID = button.dataset.nodeId;
    if (button.dataset.parentId) data.parentID = button.dataset.parentId;
    if (action === "cancelTagPanel") {
      activeTagPanel = null;
      render();
      return;
    }
    if (action === "selectTag") {
      if (suppressTagClick) return;
      const nodeX = Number(button.dataset.positionX) || 0;
      const nodeY = Number(button.dataset.positionY) || 0;
      activeTagPanel = { kind: "edit", treeID: button.dataset.treeId, nodeID: button.dataset.nodeId, x: nodeX + button.offsetWidth + 12, y: nodeY };
      render();
      return;
    }
    if (action === "addTag") {
      if (!activeTagPanel || activeTagPanel.kind !== "create") return;
      data.positionX = activeTagPanel.x;
      data.positionY = activeTagPanel.y;
      activeTagPanel = null;
      render();
      send(action, data);
      return;
    }
    if (action === "updateTag" || action === "toggleTagRetirement") {
      activeTagPanel = null;
      render();
    }
    send(action, data);
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
    activeTagPanel = {
      kind: "create",
      treeID: map.dataset.treeId,
      parentID: node?.dataset.nodeId || "",
      x: node ? nodeX + node.offsetWidth + 12 : nodeX,
      y: nodeY,
    };
    render();
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
