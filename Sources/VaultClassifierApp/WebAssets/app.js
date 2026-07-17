(() => {
  "use strict";

  const root = document.getElementById("app");
  const strings = window.VaultClassifierStrings || {};
  let state = null;

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
            ${navButton("inspect", "✦", "navigation.inspect", "navigation.inspectMeta", "cyan")}
            ${navButton("policies", "⌗", "navigation.policies", "navigation.policiesMeta", "navy")}
            ${navButton("activity", "◷", "navigation.activity", "navigation.activityMeta", "cyan")}
            ${navButton("training", "◉", "navigation.training", "navigation.trainingMeta", "pink")}
          </div></section>
          <section class="sidebar-section"><span class="eyebrow">${tx("navigation.control")}</span><div class="sidebar-list">
            ${navButton("backup", "□", "navigation.backup", "navigation.backupMeta", "navy")}
            ${navButton("audit", "◌", "navigation.audit", "navigation.auditMeta", "gold")}
            ${navButton("integration", "⇄", "navigation.integration", "navigation.integrationMeta", "cyan")}
          </div></section>
          <div class="sidebar-status"><strong>${tx("navigation.seedVerified")}</strong><br><span class="small-copy">${tx("navigation.seedCopy")}</span></div>
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

  function workspace() {
    switch (state.workspace) {
      case "policies": return policyWorkspace();
      case "activity": return activityWorkspace();
      case "training": return trainingWorkspace();
      case "backup": return backupWorkspace();
      case "audit": return auditWorkspace();
      case "integration": return integrationWorkspace();
      default: return inspectWorkspace();
    }
  }

  function render() {
    root.innerHTML = state ? shell(workspace()) : `<div class="popup"><div class="empty">${tx("app.loading")}</div></div>`;
  }

  document.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-action]");
    if (!button || button.disabled) return;
    const action = button.dataset.action;
    const data = button.dataset.form ? collect(button.dataset.form) : {};
    if (button.dataset.workspace) data.workspace = button.dataset.workspace;
    if (button.dataset.id) data.id = button.dataset.id;
    if (button.dataset.correction) data.correction = button.dataset.correction;
    if (button.dataset.policyId) data.policyID = button.dataset.policyId;
    send(action, data);
  });

  window.VaultClassifier = {
    receive(payload) {
      state = payload;
      render();
    },
  };

  render();
  send("state", {});
  window.setInterval(() => {
    const active = document.activeElement;
    if (!active || !["INPUT", "TEXTAREA", "SELECT"].includes(active.tagName)) send("state", {});
  }, 3000);
})();
