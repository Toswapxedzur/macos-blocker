(() => {
  "use strict";

  // Mac Vault's Classifier scene: this page lives in a shadow root beside the
  // Vault editor in the one document (see Mac Vault's scenes.js), so it looks
  // up and listens inside that root, never on the document.
  const scope = window.VaultScenes.scope("classifier");
  const root = scope.getElementById("app");
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
  // Per-type local-model request overrides have their own disclosure state;
  // they must not expand/collapse the app-wide engine settings modal.
  // Per-type research defaults have a separate disclosure for the same reason.
  let tagDrag = null;
  let suppressTagClick = false;
  let connectionSource = null;
  let selectedTagNode = null;
  const treeViewportPositions = new Map();
  const editorViewportPositions = new Map();
  const pendingTagRenames = new Map();
  let pendingDeletion = null;
  // Non-null while the "create a group" dialog is open: { platformID, name? }.
  // A group can only be created through this dialog.
  let pendingCreateType = null;
  let utilityPanel = null;
  // "More" / "Options" expands the user opened: the page re-renders on every update.
  const openExpands = new Set();
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
  const workspaceNames = new Set(["llmAssist", "browserBridge", "knowledge"]);
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
  root.lang = selectedLanguage;

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


  function languageSelection() {
    return `<label class="header-language"><span class="visually-hidden">${tx("language.label")}</span><select class="select-control" data-language-selection aria-label="${tx("language.label")}">${languageChoices.map(([identifier, nameKey]) => `<option value="${esc(identifier)}"${selected(selectedLanguage, identifier)}>${tx(nameKey)}</option>`).join("")}</select></label>`;
  }

  // The two dials of the local model (2026-09-23): Speed ↔ Quality picks a
  // model tier, Strict ↔ Broad picks a tag-count position. Everything else
  // is a constant on the Swift side.
  const SPEED_TIERS = ["fast", "balanced", "best"];
  const STRICTNESS_POSITIONS = [1, 2, 3, 4, 5];

  function tierEntry(llm, tier) {
    return (llm?.modelLibrary || []).find((entry) => entry.tier === tier) || null;
  }

  // One card per tier, carrying that tier's download state and controls.
  function speedQualityCards(llm, selectedTier) {
    const systemRAMGB = Number(llm.systemRAMGB) || 0;
    return `<div class="dial-card-grid" role="radiogroup" aria-label="${esc(t("localModel.speedQuality"))}">${SPEED_TIERS.map((tier) => {
      const entry = tierEntry(llm, tier);
      const active = tier === selectedTier;
      const stateKind = entry?.state?.kind || "available";
      const fraction = Math.min(1, Math.max(0, Number(entry?.state?.fraction) || 0));
      let controls = entry ? `<button type="button" class="primary" data-action="downloadModel" data-id="${esc(entry.id)}">${tx("modelLibrary.download")}</button>` : "";
      if (entry && stateKind === "downloading") {
        controls = `<div class="model-download-state"><span class="model-download-label">${tx("modelLibrary.downloading", { progress: percent(fraction) })}</span><div class="model-download-progress" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${Math.round(fraction * 100)}"><span style="width:${Math.round(fraction * 100)}%"></span></div></div><button type="button" class="secondary" data-action="cancelModelDownload" data-id="${esc(entry.id)}">${tx("modelLibrary.cancel")}</button>`;
      } else if (entry && stateKind === "downloaded") {
        controls = `${statusPill(t("modelLibrary.downloaded"), "cyan")}<button type="button" class="danger" data-action="deleteModelFile" data-file-name="${esc(entry.ggufFileName)}">${tx("modelLibrary.delete")}</button>`;
      }
      const meta = entry ? `<span class="dial-card-meta">${tx("localModel.tier.model", { model: entry.displayName, size: modelSizeGB(entry.downloadSizeBytes), ram: entry.minimumRAMGB })}</span>` : "";
      const ramShort = entry && systemRAMGB && Number(entry.minimumRAMGB) > systemRAMGB
        ? `<span class="dial-card-warning">${tx("localModel.tier.ramShort", { ram: entry.minimumRAMGB })}</span>` : "";
      const badge = entry?.recommended ? `<span class="dial-card-badge">${tx("localModel.tier.recommended")}</span>` : "";
      return `<label class="dial-card${active ? " active" : ""}"><input type="radio" name="speedQuality" data-field="speedQuality" value="${tier}"${active ? " checked" : ""}><span class="dial-card-head"><span class="dial-card-name">${tx(`localModel.tier.${tier}.name`)}</span>${badge}</span><span class="dial-card-desc">${tx(`localModel.tier.${tier}.desc`)}</span>${meta}${ramShort}<span class="dial-card-controls">${controls}</span></label>`;
    }).join("")}</div>`;
  }

  // Five positions from Strictest to Broadest, each with what it does.
  function strictnessOptions(selected) {
    return `<div class="strictness-options" role="radiogroup" aria-label="${esc(t("localModel.strictness"))}">${STRICTNESS_POSITIONS.map((position) => {
      const active = Number(selected) === position;
      return `<label class="strictness-option${active ? " active" : ""}"><input type="radio" name="strictness" data-field="strictness" value="${position}"${active ? " checked" : ""}><span class="strictness-option-name">${position} · ${tx(`localModel.strictness.${position}.name`)}</span><span class="strictness-option-desc">${tx(`localModel.strictness.${position}.desc`)}</span></label>`;
    }).join("")}</div>`;
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
      const llmSection = `<section class="utility-settings-section utility-llm-section" data-form-id="utility-llm-form"><h3 class="utility-settings-section-title">${tx("localModel.title")} ${statusPill(tx(`localModel.status.${llm.engineStatus || "loading"}`), statusToneByState[llm.engineStatus] || "navy")}</h3><p class="section-copy">${tx("localModel.copy")}</p><div class="field wide"><span class="field-label">${tx("localModel.speedQuality")}<span class="field-hint"> · ${tx("localModel.speedQualityHint")}</span></span>${
        speedQualityCards(llm, llm.speedQuality || "balanced")
      }<p class="model-library-source-note">${tx("localModel.tier.sourceNote")}</p></div><div class="field wide"><span class="field-label">${tx("localModel.strictness")}<span class="field-hint"> · ${tx("localModel.strictnessHint")}</span></span>${
        strictnessOptions(llm.strictness ?? 3)
      }</div>${
        textareaField("localModel.houseRules", "localModel.houseRulesHint", "houseRules", llm.houseRules || "", 'rows="4"')
      }<div class="action-row"><button class="primary" data-action="saveLocalLLMSettings" data-form="utility-llm-form">${tx("localModel.save")}</button></div></section>`;
      const generationProfiles = profiles.filter((profile) => protocols[profile.type]?.supportsGenerateText === true);
      const isGroundingCapable = (profile) => protocols[profile.type]?.supportsGenerateText === true && protocols[profile.type]?.supportsNativeWebSearch === true;
      // Research is provider-grounding only, so only grounding-capable providers are offered.
      const llmProviderOptions = [["", tx("research.chooseProvider")]].concat(generationProfiles.filter(isGroundingCapable).map((profile) => [profile.id, profile.name]));
      const modelSuggestions = assets.providerModelCatalogs?.[research.llmProviderProfileID] || [];
      const researchSection = `<section class="utility-settings-section utility-research-section" data-form-id="utility-research-form"><h3 class="utility-settings-section-title">${tx("research.title")} ${statusPill(tx(research.enabled ? "research.status.on" : "research.status.off"), research.enabled ? "cyan" : "muted")}</h3><p class="section-copy">${tx("research.copy")}</p><div class="notice navy research-data-flow">${tx("research.disclosure")}</div><div class="utility-toggles">${
        toggle("research.consent", "enabled", research.enabled === true)
      }</div><div class="utility-settings-fields">${
        valueSelectField("research.llmProvider", "research.llmProviderHint", "llmProviderProfileID", research.llmProviderProfileID || "", llmProviderOptions)
      }${
        field("research.model", "research.modelHint", "llmModelIdentifier", research.llmModelIdentifier || "", "text", 'list="research-model-suggestions" maxlength="256"')
      }<datalist id="research-model-suggestions">${modelSuggestions.map((model) => `<option value="${esc(model)}"></option>`).join("")}</datalist></div><p class="small-copy">${tx("research.constantsNote")}</p><p class="small-copy">${tx("research.usageToday", { used: research.tokensUsedToday ?? 0, limit: research.dailyTokenLimit ?? 10000 })}</p>${researchStatusBlock(research.status)}<div class="action-row"><button class="primary" data-action="saveResearchSettings" data-form="utility-research-form">${tx("research.save")}</button></div></section>`;
      const packageSection = `<section class="utility-settings-section utility-resource-section" data-form-id="utility-package-form"><h3 class="utility-settings-section-title">${tx("settings.packageUpdates")}</h3><div class="utility-settings-fields">${selectField("settings.packageUpdates", "settings.packageUpdatesCopy", "packageUpdateMode", settings.packageUpdateMode, [["automatic", "enum.update.automatic"], ["downloadThenAsk", "enum.update.downloadThenAsk"], ["manual", "enum.update.manual"]])}</div><div class="action-row"><button class="primary" data-action="savePackageSettings" data-form="utility-package-form">${tx("common.save")}</button></div></section>`;
      content = `<section class="utility-panel utility-settings-modal"><div class="utility-panel-head"><div><h2>${tx("utility.settings.title")}</h2><p class="section-copy">${tx("utility.settings.copy")}</p></div><button class="secondary utility-close" data-action="closeUtilityPanel">${tx("utility.close")}</button></div><div class="utility-settings-body">${llmSection}${researchSection}${packageSection}<section class="utility-settings-section"><h3 class="utility-settings-section-title">${tx("language.label")}</h3>${languageSelection()}</section></div></section>`;
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
      <details class="vui-expand sidebar-more" data-expand="sidebar"${openExpands.has("sidebar") || ["knowledge", "llmAssist", "trash"].includes(state.workspace) ? " open" : ""}>
        <summary>${tx("navigation.more")}</summary>
        ${navButton("knowledge", "✦", "navigation.knowledge", "navigation.knowledgeMeta")}
        ${navButton("llmAssist", "◌", "navigation.apiKeys", "navigation.apiKeysMeta")}
        ${trashSection}
      </details>`;
  }

  function shell(content) {
    return `<div class="popup">
      <header class="vui-topbar">
        <nav class="vui-tabs" aria-label="Scene"><button type="button" class="vui-tab" data-scene="vault">Vault</button><button type="button" class="vui-tab is-active" data-scene="classifier">Classifier</button><button type="button" class="vui-tab" data-scene="activity">Activity</button></nav>
        <div class="vui-topbar-links"><span class="settings-popover-anchor"><button type="button" class="secondary" data-action="openUtilityPanel" data-utility-panel="settings" aria-haspopup="dialog" aria-expanded="${utilityPanel ? "true" : "false"}">${tx("utility.settings.button")}</button>${utilityPanelContent()}</span></div>
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

  // A classifier type's own tag tree (the tree belongs to its type: made and
  // trashed with it). The canvas is as tall as its tags (at most 520 px) and
  // shows no scroll bars (owner 2026-09-30): drag empty space or use the
  // trackpad to pan a tree wider than the panel.
  function tagTreeWorkspace(treeID) {
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
      const panelState = activeTagPanel?.treeID === tree.id ? activeTagPanel : null;
      const contentWidth = Math.max(0, ...[...positions.values()].map((position) => position.x + 126)) + 28;
      const contentHeight = Math.max(240, Math.max(0, ...[...positions.values()].map((position) => position.y + 22)) + 28,
        panelState ? 380 : 0);  // room for the popover, placed in view below
      const selectedNodeID = selectedTagNode?.treeID === tree.id ? selectedTagNode.nodeID : "";
      const popoverNode = panelState?.nodeID ? nodeByID.get(panelState.nodeID) : null;
      const connectionState = connectionSource?.treeID === tree.id ? connectionSource : null;
      const popover = panelState ? (() => {
        const isEdit = panelState.kind === "edit" && popoverNode;
        const nodeID = isEdit ? popoverNode.id : "";
        const nameField = field(
          isEdit ? "tree.nodeName" : "tree.tagName",
          "",
          "name",
          isEdit ? popoverNode.name : "",
          "text",
          isEdit ? `data-live-tag-name data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}"` : ""
        );
        const descriptionField = textareaField(
          "tree.tagDescription",
          "tree.tagDescriptionCopy",
          "description",
          isEdit ? popoverNode.description || "" : "",
          "maxlength=\"1024\""
        );
        const actions = isEdit
          ? `<button class="primary" data-action="saveTagName" data-form="tag-popover-form" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}">${tx("tree.saveNode")}</button><button class="secondary" data-action="beginConnection" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}">${tx("tree.connection")}</button><button class="secondary" data-action="disconnectTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}"${disabled(!popoverNode.parentID)}>${tx("tree.disconnection")}</button><button class="danger" data-action="deleteTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}">${tx("tree.deleteNode")}</button>`
          : `<button class="primary" data-action="addTag" data-form="tag-popover-form" data-tree-id="${esc(tree.id)}">${tx("tree.createNode")}</button>`;
        // Placed beside its anchor, inside the visible part (placeTreePopovers).
        return `<section class="tree-popover" data-anchor-x="${panelState.x}" data-anchor-y="${panelState.y}" data-anchor-w="${panelState.w || 0}" data-tree-popover data-form-id="tag-popover-form"><div class="tree-popover-head"><span class="eyebrow">${tx(isEdit ? "tree.editNode" : "tree.createNode")}</span><button class="tree-popover-close" data-action="cancelTagPanel" title="${tx("tree.cancel")}" aria-label="${tx("tree.cancel")}">×</button></div><div class="tree-form">${nameField}${descriptionField}<div class="action-row">${actions}</div></div></section>`;
      })() : "";
      const map = `<div class="tree-map" data-tree-map data-tree-id="${esc(tree.id)}">${connectionState ? `<div class="tree-connection-mode">${tx("tree.connectionHint")}</div>` : ""}<div class="tree-map-content" style="width:max(${contentWidth}px, 100%);height:${contentHeight}px"><svg class="tree-links" aria-hidden="true"></svg><div class="tree-node-layer">${nodes.map((node) => {
        const position = positions.get(node.id);
        const colorStyle = tagColorStyle(node);
        return `<button class="tree-map-node${panelState?.nodeID === node.id || selectedNodeID === node.id ? " active" : ""}${connectionState?.nodeID === node.id ? " connection-source" : ""}${node.retired ? " retired" : ""}" style="left:${position.x}px;top:${position.y}px;${colorStyle}" data-action="selectTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(node.id)}" data-parent-id="${esc(node.parentID || "")}" data-position-x="${position.x}" data-position-y="${position.y}" title="${tx("tree.contextHint")}"><span aria-hidden="true"></span><strong>${esc(node.name)}</strong></button>`;
      }).join("")}</div>${nodes.length ? "" : `<div class="tree-map-empty">${tx("tree.empty")}</div>`}${popover}</div></div>`;
      const treeActions = `<div class="tree-canvas-actions"><button class="secondary" data-action="rearrangeTree" data-tree-id="${esc(tree.id)}">${tx("tree.rearrange")}</button></div>`;
      return `<section class="tree-panel">${map}<div class="tree-canvas-hint"><span>${tx("tree.canvasHint")}</span>${treeActions}</div></section>`;
    };
    const tree = state.assets.trees.find((candidate) => candidate.id === treeID);
    return `<div class="workspace tree-workspace tree-workspace-scoped">${tree ? panel(tree) : `<div class="empty">${tx("tree.empty")}</div>`}${notice(state.issue, "red")}</div>`;
  }

  // A tag's popover sits beside its anchor, flipped left when the visible
  // part of the canvas has no room on the right, and moved up so all of it
  // shows.
  function placeTreePopovers() {
    root.querySelectorAll("[data-tree-map]").forEach((map) => {
      const popover = map.querySelector("[data-tree-popover]");
      if (!popover) return;
      const x = Number(popover.dataset.anchorX) || 0;
      const width = popover.offsetWidth;
      const viewLeft = map.scrollLeft;
      const viewRight = map.scrollLeft + map.clientWidth;
      let left = x + (Number(popover.dataset.anchorW) || 0) + 12;
      if (left + width > viewRight - 8) left = x - width - 12;
      left = Math.max(viewLeft + 8, Math.min(left, viewRight - width - 8));
      popover.style.left = `${Math.round(left)}px`;
      const viewTop = map.scrollTop;
      const viewBottom = map.scrollTop + map.clientHeight;
      const top = Math.max(viewTop + 8, Math.min(Number(popover.dataset.anchorY) || 0, viewBottom - popover.offsetHeight - 8));
      popover.style.top = `${Math.round(top)}px`;
    });
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
      ["llm.providerGroup.platform", ["youtubeData", "twitch", "reddit", "xPlatform", "instagramGraph", "facebookGraph"].map((type) => [type, t(providerTypeLabelKey(type))])],
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
    const profiles = assets.providerProfiles || [];
    const platformDefinitions = new Map((assets.collectionPlatforms || []).map((platform) => [platform.id, platform]));
    const typeForm = (classifierType) => {
      const formID = `classifier-type-${classifierType.id}`;
      const applicablePlatformID = typeof classifierType.applicablePlatformID === "string" ? classifierType.applicablePlatformID : "";
      const applicableBinding = (assets.bindings || []).find((binding) => binding.id === applicablePlatformID);
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
      const localOverrides = classifierType.localModelOverrides || null;
      const localModelFormID = `classifier-local-model-form-${classifierType.id}`;
      const globalLLM = state.settings?.localLLM || {};
      const tierName = (tier) => t(`localModel.tier.${tier}.name`);
      const typeSpeedOptions = [["", t("localModel.speedQuality.followGlobal", { name: tierName(globalLLM.speedQuality || "balanced") })]].concat(SPEED_TIERS.map((tier) => {
        const downloaded = tierEntry(globalLLM, tier)?.state?.kind === "downloaded";
        return [tier, downloaded ? tierName(tier) : t("localModel.tier.notDownloaded", { name: tierName(tier) })];
      }));
      const positionName = (position) => `${position} · ${t(`localModel.strictness.${position}.name`)}`;
      const typeStrictnessOptions = [["", t("localModel.strictness.followGlobal", { name: positionName(globalLLM.strictness ?? 3) })]]
        .concat(STRICTNESS_POSITIONS.map((position) => [String(position), positionName(position)]));
      // The platform's collection lives with its type (the History page is
      // gone, owner 2026-09-30): collect on/off and delete what was collected.
      const collectionFormID = `type-collection-${classifierType.id}`;
      const collectedCount = applicableBinding
        ? Number((assets.datasets || []).find((dataset) => dataset.id === applicableBinding.datasetID)?.entryCounts?.[applicableBinding.id]) || 0
        : 0;
      const collectionSection = applicableBinding ? `<section class="classifier-type-section classifier-collection-section" data-form-id="${esc(collectionFormID)}"><div class="section-header"><div><h3>${tx("bridge.collection")}</h3><p class="section-copy">${tx("bridge.collectionCount", { count: collectedCount })}</p></div></div>${toggle("bridge.collectToggle", "enabled", Boolean(applicableBinding.collectionEnabled))}<div class="action-row"><button class="primary" data-action="setCollectionEnabled" data-form="${esc(collectionFormID)}" data-platform-id="${esc(applicableBinding.id)}">${tx("common.save")}</button><button class="danger" data-action="clearCollectedData" data-platform-id="${esc(applicableBinding.id)}" data-name="${esc(applicableBinding.name)}"${disabled(!collectedCount)}>${tx("bridge.deleteCollected")}</button></div></section>` : "";
      const localModelOverrideSection = supportsLocalModel ? `<section class="classifier-type-section classifier-local-model-overrides" data-local-model-section><div class="section-header"><div><h3>${tx("bridge.localModelOverrides")}</h3><p class="section-copy">${tx("bridge.localModelOverridesCopy")}</p></div></div><div data-form-id="${esc(localModelFormID)}"><div class="utility-settings-fields">${valueSelectField("localModel.speedQuality", "localModel.speedQualityHint", "speedQuality", localOverrides?.speedQuality || "", typeSpeedOptions)}${valueSelectField("localModel.strictness", "localModel.strictnessHint", "strictness", localOverrides?.strictness != null ? String(localOverrides.strictness) : "", typeStrictnessOptions)}</div><p class="small-copy resident-model-note">${tx("bridge.localModelResidentNote")}</p>${textareaField("bridge.localModelHouseRules", "bridge.localModelHouseRulesCopy", "houseRules", localOverrides?.houseRules ?? "", 'rows="4"')}<div class="action-row"><button type="button" class="primary" data-action="saveClassifierTypeLocalModel" data-form="${esc(localModelFormID)}" data-type-id="${esc(classifierType.id)}">${tx("common.save")}</button></div></div></section>` : "";
      const researchFormID = `classifier-research-form-${classifierType.id}`;
      const researchMode = classifierType.researchEnabled === true ? "on" : classifierType.researchEnabled === false ? "off" : "inherit";
      const researchOverrideSection = supportsLocalModel ? `<section class="classifier-type-section classifier-research-overrides"><div class="section-header"><div><h3>${tx("bridge.researchOverrides")}</h3><p class="section-copy">${tx("bridge.researchOverridesCopy")}</p></div></div><div data-form-id="${esc(researchFormID)}"><div class="utility-settings-fields">${valueSelectField("bridge.researchMode", "", "researchMode", researchMode, [["inherit", t("bridge.researchMode.inherit")], ["on", t("bridge.researchMode.on")], ["off", t("bridge.researchMode.off")]])}</div><p class="small-copy research-master-note">${tx("bridge.researchMasterGate")}</p><div class="action-row"><button type="button" class="primary" data-action="saveClassifierTypeResearch" data-form="${esc(researchFormID)}" data-type-id="${esc(classifierType.id)}">${tx("common.save")}</button></div></div></section>` : "";
      return `<section class="classifier-type-panel" data-form-id="${esc(formID)}" data-type-id="${esc(classifierType.id)}">
        <div class="classifier-name-row">${field("bridge.typeName", "", "name", classifierType.name)}</div>
        <section class="classifier-type-section classifier-applicable-platform-section"><div class="classifier-applicable-platform-row">${valueSelectField("bridge.applicablePlatform", "", "applicablePlatformID", applicablePlatformID, applicablePlatformOptions)}<p class="small-copy classifier-platform-data-status">${esc(platformDataStatus)}</p></div>${applicablePlatform && !supportsLocalModel ? `<p class="small-copy" data-collection-only-platform-note>${tx("bridge.collectionOnlyCopy")}</p>` : ""}</section>
        <div class="action-row"><button class="primary" data-action="configureClassifierType" data-form="${esc(formID)}" data-type-id="${esc(classifierType.id)}">${tx("common.save")}</button></div>
        <details class="vui-expand classifier-type-more" data-expand="type-options-${esc(classifierType.id)}"${openExpands.has(`type-options-${classifierType.id}`) ? " open" : ""}><summary>${tx("navigation.options")}</summary>
        ${localModelOverrideSection}
        ${researchOverrideSection}
        ${collectionSection}
          <div class="action-row"><button class="danger" data-action="confirmDeleteClassifierType" data-type-id="${esc(classifierType.id)}" data-name="${esc(classifierType.name)}">${tx("bridge.deleteType")}</button></div>
        </details>
      </section>`;
    };
    // A type now targets one platform at creation and owns a fresh tree. The
    // left panel selects which type is open; a selected type shows its config
    // and owned tree together.
    const selectedType = selectedTypeID ? classifierTypes.find((type) => type.id === selectedTypeID) : null;
    if (selectedType) {
      // The type (its name is the editable title) and its tag tree, in one scroll.
      const section = (labelKey, inner) => `<section class="type-section"><h3 class="type-section-title">${tx(labelKey)}</h3>${inner}</section>`;
      return `<div class="workspace classifier-type-workspace">
        <div class="type-detail-body">
          <section class="type-section">${typeForm(selectedType)}</section>
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

  function workspace() {
    switch (state.workspace) {
      case "llmAssist": return llmAssistWorkspace();
      case "browserBridge": return browserBridgeWorkspace();
      case "knowledge": return knowledgeWorkspace();
      default: return browserBridgeWorkspace();
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
    activeTagPanel = { kind: "edit", treeID, nodeID, x: nodeX, y: nodeY, w: node.offsetWidth };
    render();
  }

  scope.addEventListener("input", (event) => {
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

  // Create-a-group dialog: platform and name. The new group follows the global
  // dials, house rules and research switch until given its own.
  function createTypeModal() {
    if (!pendingCreateType) return "";
    const platforms = state.assets?.collectionPlatforms || [];
    if (!platforms.length) return "";
    const selectedPlatformID = pendingCreateType.platformID || platforms[0].id;
    const platformOptions = platforms.map((platform) => `<option value="${esc(platform.id)}"${platform.id === selectedPlatformID ? " selected" : ""}>${esc(platform.name)} · ${esc(platform.browser)}</option>`).join("");
    return `<div class="utility-popover-layer" role="presentation"><button class="utility-popover-dismiss" data-action="cancelCreateType" aria-label="${tx("common.cancel")}"></button><div class="deletion-dialog create-type-dialog" role="dialog" aria-modal="true"><h3>${tx("createType.title")}</h3><p class="section-copy">${tx("createType.copy")}</p><label class="field"><span class="field-label">${tx("createType.platformLabel")}</span><select data-create-type-platform>${platformOptions}</select></label><label class="field"><span class="field-label">${tx("createType.nameLabel")}</span><input type="text" data-create-type-name autocomplete="off" spellcheck="false" value="${esc(pendingCreateType.name != null ? pendingCreateType.name : t("createType.defaultName"))}"></label><div class="action-row"><button class="secondary" data-action="cancelCreateType">${tx("common.cancel")}</button><button class="primary" data-action="confirmCreateType">${tx("createType.create")}</button></div></div></div>`;
  }

  function render() {
    if (!state) {
      root.innerHTML = `<div class="popup"><div class="empty">${tx("app.loading")}</div></div>`;
      lastRenderedMarkup = null;
      return;
    }
    const markup = shell(workspace()) + deletionModal() + createTypeModal();
    // Nothing changed on the page: keep the DOM (and its scroll) as it is.
    if (markup === lastRenderedMarkup && root.firstChild) return;
    renderFull(markup);
  }

  function renderFull(markup) {
    rememberTreeViewportPositions();
    rememberEditorViewportPosition();
    root.innerHTML = markup;
    lastRenderedMarkup = markup;
    applyApplicablePlatformCapabilities();
    bindTreeMapWheel();
    window.requestAnimationFrame(() => {
      applyNavigationPanelWidth();
      restoreEditorViewportPosition();
      restoreTreeViewportPositions();
      drawTreeConnections();
      placeTreePopovers();
    });
  }

  // Attach the non-passive tree-map wheel handler only to the tree canvases in
  // the freshly rendered DOM, leaving every other scroll container passive.
  function bindTreeMapWheel() {
    root.querySelectorAll("[data-tree-map]").forEach((map) => {
      map.addEventListener("wheel", handleTreeMapWheel, { passive: false });
    });
  }

  scope.addEventListener("click", (event) => {
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
      if (!platforms.length) return;
      // Open the create-a-group dialog; there is no direct-create path.
      pendingCreateType = { platformID: platforms[0].id };
      render();
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
      if (!platformID) return;
      pendingSelectNewType = new Set((state.assets?.classifierTypes || []).map((type) => type.id));
      pendingCreateType = null;
      render();
      send("createClassifierType", { name, platformID });
      return;
    }
    if (action === "confirmDeleteClassifierType" || action === "clearCollectedData") {
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
    if (action === "testProviderProfile") Object.assign(data, providerConnectionPayload(data, button.dataset.form));
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
    if (action === "rearrangeTree") {
      selectedTagNode = null;
      connectionSource = null;
      activeTagPanel = null;
      render();
      send("rearrangeTree", { treeID: button.dataset.treeId });
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

  scope.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || !utilityPanel) return;
    utilityPanel = null;
    render();
  });

  scope.addEventListener("toggle", (event) => {
    const key = event.target.matches?.("details[data-expand]") ? event.target.dataset.expand : null;
    if (key) event.target.open ? openExpands.add(key) : openExpands.delete(key);
  }, true);

  scope.addEventListener("change", (event) => {
    const languageControl = event.target.closest("[data-language-selection]");
    if (languageControl) {
      if (!languageChoices.some(([identifier]) => identifier === languageControl.value)) return;
      selectedLanguage = languageControl.value;
      root.lang = selectedLanguage;
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

  scope.addEventListener("pointerdown", (event) => {
    const resizer = event.target.closest("[data-navigation-resizer]");
    if (!resizer || event.button !== 0) return;
    navigationResize = { pointerID: event.pointerId };
    resizer.setPointerCapture?.(event.pointerId);
    event.preventDefault();
  });

  scope.addEventListener("pointermove", (event) => {
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

  scope.addEventListener("pointerup", finishNavigationResize);
  scope.addEventListener("pointercancel", finishNavigationResize);

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

  scope.addEventListener("mousedown", (event) => {
    const row = event.target.closest?.(".classifier-type-row[data-type-id]");
    if (!row) return;
    startTypeReorder(event, row.dataset.typeId);
  });

  scope.addEventListener("keydown", (event) => {
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

  scope.addEventListener("contextmenu", (event) => {
    const map = event.target.closest("[data-tree-map]");
    if (!map || event.target.closest("[data-tree-popover]")) return;
    event.preventDefault();
    const content = map.querySelector(".tree-map-content");
    const contentRect = content.getBoundingClientRect();
    const node = event.target.closest(".tree-map-node");
    // The content's rect already moves with the canvas's scroll.
    const nodeX = node ? Number(node.dataset.positionX) || 0 : Math.max(12, Math.round(event.clientX - contentRect.left));
    const nodeY = node ? Number(node.dataset.positionY) || 0 : Math.max(12, Math.round(event.clientY - contentRect.top));
    connectionSource = null;
    if (node) {
      openTagEditor(map.dataset.treeId, node.dataset.nodeId);
    } else {
      selectedTagNode = null;
      activeTagPanel = { kind: "create", treeID: map.dataset.treeId, parentID: "", x: nodeX, y: nodeY };
      render();
    }
  });

  // With no scroll bars, dragging the canvas's empty space pans it.
  let treePan = null;
  function beginTreePan(event) {
    const map = event.target.closest("[data-tree-map]");
    if (!map || event.button !== 0 || treePan || event.target.closest(".tree-map-node, [data-tree-popover]")) return;
    treePan = { map, x: event.clientX, y: event.clientY, left: map.scrollLeft, top: map.scrollTop };
    map.classList.add("panning");
  }
  function moveTreePan(event) {
    if (!treePan) return;
    treePan.map.scrollLeft = treePan.left - (event.clientX - treePan.x);
    treePan.map.scrollTop = treePan.top - (event.clientY - treePan.y);
    event.preventDefault();
  }
  function finishTreePan() {
    if (!treePan) return;
    treePan.map.classList.remove("panning");
    treePan = null;
  }
  scope.addEventListener("pointerdown", beginTreePan);
  scope.addEventListener("pointermove", moveTreePan);
  scope.addEventListener("pointerup", finishTreePan);
  scope.addEventListener("pointercancel", finishTreePan);

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
    suppressTagClick = true;
    window.setTimeout(() => { suppressTagClick = false; }, 0);
    send("moveTag", {
      treeID: drag.treeID,
      nodeID: drag.nodeID,
      positionX: Number(drag.node.dataset.positionX) || 0,
      positionY: Number(drag.node.dataset.positionY) || 0,
    });
  }

  scope.addEventListener("pointerdown", beginTagDrag);
  scope.addEventListener("mousedown", beginTagDrag);
  scope.addEventListener("pointermove", moveTagDrag);
  scope.addEventListener("mousemove", moveTagDrag);
  scope.addEventListener("pointerup", finishTagDrag);
  scope.addEventListener("pointercancel", finishTagDrag);
  scope.addEventListener("mouseup", finishTagDrag);

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
      // Open a just-created type: the one id absent before "New type" was clicked.
      if (pendingSelectNewType) {
        const created = (state.assets?.classifierTypes || []).find((type) => !pendingSelectNewType.has(type.id));
        if (created) { selectedTypeID = created.id; state.workspace = "browserBridge"; }
        pendingSelectNewType = null;
      }
      render();
    },
  };

  window.addEventListener("resize", () => window.requestAnimationFrame(drawTreeConnections));
  window.VaultUI.observe(scope);
  render();
  send("state", {});
})();
