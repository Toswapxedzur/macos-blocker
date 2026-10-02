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
  // Every delete asks once more, as in the other sections (owner 2026-09-30):
  // the first click arms it ("Click again to delete" for 4 s, kept across the
  // page's re-renders), a second click does it. The key names the one item.
  let armedDelete = null;
  let armedDeleteTimer = null;
  const treeViewportPositions = new Map();
  const editorViewportPositions = new Map();
  const liveEdits = new Map();
  let replacingControls = false;
  let composingEdit = false;
  // Non-null while the "create a group" dialog is open: { platformIDs, name? }.
  // A group can only be created through this dialog.
  let pendingCreateType = null;
  let utilityPanel = null;
  let researchSetupRequested = false;
  let researchSetupFocusPending = false;
  let researchModelQuery = "";
  let researchModelQueryProvider = null;
  let releaseDialogFocus = null;
  let dialogFocusKind = null;
  // "More" / "Options" expands the user opened: the page re-renders on every update.
  const openExpands = new Set();
  // Which classifier type is open in the left-panel list (client-only UI state).
  let selectedTypeID = null;
  // Set to the pre-create set of type ids when "New type" is clicked, so the
  // next snapshot can open the freshly created type.
  let pendingSelectNewType = null;
  let selectedLanguage = "en";
  let navigationPanelWidth = navigationWidthRange.fallback;
  let navigationResize = null;
  const workspaceNames = new Set(["browserBridge", "knowledge"]);
  let lastRenderedMarkup = null;
  const listViewportPositions = new Map();

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

  // Persist through the same native actions as the explicit operations. A
  // draft stays until a snapshot acknowledges its latest values, so an older
  // response cannot replace text typed while a save was in flight.
  function liveEditKey(form) {
    return [form.dataset.formId, form.dataset.typeId, form.dataset.providerId,
      form.dataset.treeId, form.dataset.nodeId, form.dataset.id].join("|");
  }

  function queueLiveEdit(control, immediate = false) {
    if (replacingControls || !control.matches?.("[data-field]") || control.disabled) return false;
    const form = control.closest("[data-autosave-action]");
    if (!form) return false;
    // A setup choice is navigation, never a group mutation (including input/blur).
    if (control.matches("[data-group-research-choice]") && control.value === "on" && !researchAvailability().ready) {
      const draft = liveEdits.get(liveEditKey(form));
      const type = (state.assets?.classifierTypes || []).find((item) => item.id === form.dataset.typeId);
      control.value = draft?.values.researchMode ?? (type?.researchEnabled === true ? "on" : type?.researchEnabled === false ? "off" : "inherit");
      openResearchSetup();
      return true;
    }
    const key = liveEditKey(form);
    const previous = liveEdits.get(key);
    window.clearTimeout(previous?.timer);
    const values = collect(form.dataset.formId);
    if (form.dataset.autosaveAction === "configureClassifierType") {
      Object.keys(values).forEach((field) => { if (field !== "name") delete values[field]; });
    }
    if (previous && JSON.stringify(previous.values) === JSON.stringify(values)) {
      if (immediate) flushLiveEdit(previous);
      else if (!previous.sent) previous.timer = window.setTimeout(() => flushLiveEdit(previous), 300);
      return true;
    }
    const edit = { key, formID: form.dataset.formId, action: form.dataset.autosaveAction,
      values, identity: {} };
    for (const [attribute, field] of [["typeId", "typeID"], ["providerId", "profileID"],
      ["treeId", "treeID"], ["nodeId", "nodeID"], ["id", "id"]]) {
      if (form.dataset[attribute]) edit.identity[field] = form.dataset[attribute];
    }
    liveEdits.set(key, edit);
    if (immediate) flushLiveEdit(edit);
    else edit.timer = window.setTimeout(() => flushLiveEdit(edit), 300);
    return true;
  }

  function savedLiveEdit(edit) {
    const assets = state?.assets || {};
    const type = (assets.classifierTypes || []).find((item) => item.id === edit.identity.typeID);
    switch (edit.action) {
      case "configureClassifierType": return type && { name: type.name };
      case "saveClassifierTypeLocalModel": return type && {
        speedQuality: type.localModel?.speedQuality || "balanced",
        strictness: String(type.localModel?.strictness ?? 3),
        houseRules: type.localModel?.houseRules || "",
        minimumTagsOverride: type.localModel?.minimumTagsOverride == null ? "" : String(type.localModel.minimumTagsOverride),
        maximumTagsOverride: type.localModel?.maximumTagsOverride == null ? "" : String(type.localModel.maximumTagsOverride),
      };
      case "saveClassifierTypeResearch": return type && {
        researchMode: type.researchEnabled === true ? "on" : type.researchEnabled === false ? "off" : "inherit",
      };
      case "saveResearchSettings": return { ...state.settings?.research,
        llmProviderProfileID: state.settings?.research?.llmProviderProfileID || "",
        llmModelIdentifier: state.settings?.research?.llmModelIdentifier || "" };
      case "savePackageSettings": return state.settings;
      case "saveClassificationSettings": return state.settings;
      case "saveBackup": return state.backup;
      case "editKnowledgeEntry": return [...(assets.knowledge?.creators || []),
        ...(assets.knowledge?.terms || [])].find((item) => item.id === edit.identity.id);
      case "updateTag": return (assets.trees || []).find((tree) => tree.id === edit.identity.treeID)
        ?.nodes.find((node) => node.id === edit.identity.nodeID);
      case "updateProviderConnection": {
        const profile = (assets.providerProfiles || []).find((item) => item.id === edit.identity.profileID);
        if (!profile) return null;
        const values = { customEndpoint: profile.customEndpoint || "",
          testModelIdentifier: profile.testModelIdentifier || "",
          credential: profile.credential || "" };
        Object.entries(profile.protocolConfiguration || {}).forEach(([field, value]) => { values[`protocol.${field}`] = value; });
        return values;
      }
      default: return null;
    }
  }

  function liveEditMatches(edit, saved) {
    if (!saved) return false;
    const normalized = (field, value) => {
      if (typeof value === "boolean") return value;
      const text = String(value ?? "");
      return field === "name" || field === "customEndpoint" || field === "llmModelIdentifier"
        || field === "testModelIdentifier" || (field === "houseRules" && !text.trim()) ? text.trim() : text;
    };
    return Object.entries(edit.values).every(([field, value]) => normalized(field, value) === normalized(field, saved[field]));
  }

  function validateTagBounds(form, values = collect(form.dataset.formId)) {
    const minimumField = form.querySelector('[data-field="minimumTagsOverride"]');
    const maximumField = form.querySelector('[data-field="maximumTagsOverride"]');
    if (!minimumField || !maximumField) return true;
    minimumField.setCustomValidity(""); maximumField.setCustomValidity("");
    const strictness = Number(values.strictness || 3);
    const defaultMinimum = strictness === 5 ? 1 : 0, defaultMaximum = strictness === 1 ? 1 : 3;
    minimumField.placeholder = String(defaultMinimum); maximumField.placeholder = String(defaultMaximum);
    const defaultsNote = form.querySelector('[data-tag-bounds-defaults]');
    if (defaultsNote) defaultsNote.textContent = t("bridge.tagBounds.copy", { minimum: defaultMinimum, maximum: defaultMaximum });
    const minimum = values.minimumTagsOverride === "" ? (strictness === 5 ? 1 : 0) : Number(values.minimumTagsOverride);
    const maximum = values.maximumTagsOverride === "" ? (strictness === 1 ? 1 : 3) : Number(values.maximumTagsOverride);
    const valid = minimumField.checkValidity() && maximumField.checkValidity()
      && Number.isInteger(minimum) && Number.isInteger(maximum) && minimum <= maximum;
    const error = form.querySelector('[data-tag-bounds-error]');
    if (error) error.hidden = valid;
    minimumField.setAttribute("aria-invalid", String(!valid));
    maximumField.setAttribute("aria-invalid", String(!valid));
    return valid;
  }

  function flushLiveEdit(edit) {
    window.clearTimeout(edit.timer);
    edit.timer = null;
    if (edit.sent || composingEdit) return;
    if (edit.action === "saveClassifierTypeLocalModel") {
      const form = root.querySelector(`[data-form-id="${CSS.escape(edit.formID)}"]`);
      if (form && !validateTagBounds(form, edit.values)) return;
    }
    const saved = savedLiveEdit(edit);
    if (!saved || liveEditMatches(edit, saved)) { liveEdits.delete(edit.key); return; }
    edit.sent = true;
    const values = edit.action === "updateProviderConnection"
      ? providerConnectionPayload(edit.values, edit.formID) : edit.values;
    send(edit.action, { ...edit.identity, ...values });
  }

  function flushLiveEdits() {
    liveEdits.forEach(flushLiveEdit);
  }

  function reconcileLiveEdits() {
    liveEdits.forEach((edit, key) => {
      const saved = savedLiveEdit(edit);
      if (!saved || (edit.sent && !state.issue && liveEditMatches(edit, saved))) {
        window.clearTimeout(edit.timer);
        liveEdits.delete(key);
      }
    });
  }

  function captureLiveEditFocus() {
    const control = scope.activeElement;
    const form = control?.closest?.("[data-autosave-action]");
    return form && control.matches("[data-field]") ? { key: liveEditKey(form),
      field: control.dataset.field, value: control.value, start: control.selectionStart,
      end: control.selectionEnd, direction: control.selectionDirection } : null;
  }

  function restoreLiveEdits(focused) {
    root.querySelectorAll("[data-autosave-action]").forEach((form) => {
      const key = liveEditKey(form), edit = liveEdits.get(key);
      form.querySelectorAll("[data-field]").forEach((control) => {
        if (control.closest("[data-autosave-action]") !== form) return;
        const field = control.dataset.field;
        if (edit && Object.hasOwn(edit.values, field)) {
          if (control.type === "checkbox") control.checked = edit.values[field];
          else if (control.type === "radio") control.checked = control.value === edit.values[field];
          else control.value = edit.values[field];
        }
        if (focused?.key !== key || focused.field !== field) return;
        if (control.type === "radio" && control.value !== focused.value) return;
        if (control.type !== "radio" && control.type !== "checkbox") control.value = focused.value;
        control.focus({ preventScroll: true });
        if (focused.start != null) control.setSelectionRange(focused.start, focused.end, focused.direction);
      });
      if (form.dataset.autosaveAction === "saveClassifierTypeLocalModel") validateTagBounds(form);
    });
  }

  scope.addEventListener("focusout", (event) => {
    if (!replacingControls && !composingEdit) queueLiveEdit(event.target, true);
  });
  scope.addEventListener("compositionstart", (event) => {
    if (event.target.closest?.("[data-autosave-action]")) {
      flushLiveEdits();
      composingEdit = true;
    }
  });
  scope.addEventListener("compositionend", (event) => {
    composingEdit = false;
    queueLiveEdit(event.target);
    if (event.target.matches("[data-model-search]")) render();
  });
  window.addEventListener("pagehide", flushLiveEdits);

  // English field explanations are explicit; translations remain a release-time batch.
  const fieldInfo = Object.freeze({
    "bridge.typeName": "The name shown for this Classifier group.",
    "createType.nameLabel": "The name of the new Classifier group.",
    "createType.platformLabel": "Choose the platforms this group will classify. A platform can belong to only one Classifier group.",
    "bridge.applicablePlatform": "The platforms assigned when this Classifier group was created. Platform assignments are fixed for that group.",
    "bridge.researchMode": "Allow research for this group, turn it off, or follow the app-wide switch. Research also requires global consent and a configured provider.",
    "llm.providerType": "Choose the provider’s API type before adding its configuration. Adding a provider does not create an API key.",
    "llm.apiKeyOrToken": "Paste the credential issued by this provider. Vault uses it to authenticate requests to that provider.",
    "llm.apiEndpoint": "The provider’s API base address. Leave blank to use its default endpoint.",
    "llm.testModel": "The model identifier used by Test connection. This does not select the model used for web research.",
    "llm.protocol.accountID": "The account identifier required by this provider’s API.",
    "llm.protocol.apiVersion": "The API version sent to this provider. Use a version supported by its endpoint.",
    "llm.protocol.clientID": "The application or client identifier issued for this provider’s API.",
    "llm.protocol.location": "The service location used for this provider’s API requests.",
    "llm.protocol.projectID": "The cloud project identifier used for this provider’s API requests.",
    "llm.protocol.region": "The service region used for this provider’s API requests.",
    "llm.protocol.userAgent": "The client identification sent with this provider’s API requests.",
    "llm.protocol.searchEngineID": "The search engine identifier required by this saved provider configuration.",
    "llm.protocol.protocolFamily": "The API format this endpoint accepts. Choose the format supported by the provider.",
    "research.model": "The model used for web research. Fetch the selected provider’s model list, then choose a model.",
    "research.modelSearch": "Find a model by its identifier in the fetched list.",
    "classification.enabled": "Allow the Classifier to tag content. Individual Classifier groups can still be paused.",
    "research.consent": "Allow web research to send public source identifiers and requested terms to the selected provider. Turning this off disables research.",
    "backup.auto": "Create a local backup after configuration changes, using the configured backup folder.",
    "knowledge.platform": "The platform that owns this content source. This determines how its name or link is interpreted.",
    "knowledge.description": "Describe what this term or content source means so the Classifier can use that knowledge. Saved descriptions are editable.",
    "knowledge.search": "Find saved knowledge by name, identifier, or description.",
    "language.label": "Choose the app’s interface language. Stored groups, tags, and knowledge remain unchanged.",
    "tree.nodeName": "The name of this tag in the taxonomy and on tagged content.",
    "tree.tagName": "The name of the tag to add to this Classifier group’s taxonomy."
  });
  function infoAttrs(labelKey, hintKey = "") {
    const text = fieldInfo[labelKey] || strings[hintKey] || "";
    if (!text) return "";
    const target = labelKey === "bridge.typeName" ? ".classifier-name-row .field"
      : labelKey === "llm.providerType" ? ".provider-create .field" : "";
    return `data-info-label="${esc(strings[labelKey] || labelKey)}" data-info-key="${esc(labelKey)}" data-info-copy="${esc(text)}"${target ? ` data-info-target="${target}"` : ""}`;
  }

  function field(labelKey, hintKey, key, value, type = "text", extra = "") {
    return `<label class="field"><span class="field-label" ${infoAttrs(labelKey, hintKey)}>${tx(labelKey)}${hintKey ? `<span class="field-hint" data-info> · ${tx(hintKey)}</span>` : ""}</span><input type="${type}" data-field="${esc(key)}" value="${type === "password" ? "" : esc(value)}" ${extra}></label>`;
  }

  function textareaField(labelKey, hintKey, key, value, extra = "") {
    return `<label class="field wide"><span class="field-label" ${infoAttrs(labelKey, hintKey)}>${tx(labelKey)}${hintKey ? `<span class="field-hint" data-info> · ${tx(hintKey)}</span>` : ""}</span><textarea data-field="${esc(key)}" ${extra}>${esc(value)}</textarea></label>`;
  }

  function selectField(labelKey, hintKey, key, value, options) {
    return `<label class="field"><span class="field-label" ${infoAttrs(labelKey, hintKey)}>${tx(labelKey)}${hintKey ? `<span class="field-hint" data-info> · ${tx(hintKey)}</span>` : ""}</span><select class="select-control" data-field="${esc(key)}">${options.map(([id, labelKey]) => `<option value="${esc(id)}"${selected(value, id)}>${tx(labelKey)}</option>`).join("")}</select></label>`;
  }

  function valueSelectField(labelKey, hintKey, key, value, options, extra = "") {
    return `<label class="field"><span class="field-label" ${infoAttrs(labelKey, hintKey)}>${tx(labelKey)}${hintKey ? `<span class="field-hint" data-info> · ${tx(hintKey)}</span>` : ""}</span><select class="select-control" data-field="${esc(key)}" ${extra}>${options.map(([id, label]) => `<option value="${esc(id)}"${selected(value, id)}>${esc(label)}</option>`).join("")}</select></label>`;
  }

  function multiValueSelectField(labelKey, hintKey, key, values, options, extra = "") {
    const selectedValues = new Set(values || []);
    return `<label class="field"><span class="field-label" ${infoAttrs(labelKey, hintKey)}>${tx(labelKey)}${hintKey ? `<span class="field-hint" data-info> · ${tx(hintKey)}</span>` : ""}</span><select class="select-control multi-select-control" data-field="${esc(key)}" multiple ${extra}>${options.map(([id, label]) => `<option value="${esc(id)}"${selectedValues.has(id) ? " selected" : ""}>${esc(label)}</option>`).join("")}</select></label>`;
  }

  function groupedValueSelectField(labelKey, hintKey, key, value, groups, extra = "") {
    return `<label class="field"><span class="field-label" ${infoAttrs(labelKey, hintKey)}>${tx(labelKey)}${hintKey ? `<span class="field-hint" data-info> · ${tx(hintKey)}</span>` : ""}</span><select class="select-control" data-field="${esc(key)}" ${extra}><option value=""${selected(value, "")}>${tx("llm.chooseProviderType")}</option>${groups.map(([groupKey, options]) => `<optgroup label="${tx(groupKey)}">${options.map(([id, label]) => `<option value="${esc(id)}"${selected(value, id)}>${esc(label)}</option>`).join("")}</optgroup>`).join("")}</select></label>`;
  }

  function toggle(labelKey, key, value, extra = "") {
    return `<label class="toggle-row"><input type="checkbox" data-field="${esc(key)}"${checked(value)} ${extra}><span ${infoAttrs(labelKey)}>${tx(labelKey)}</span></label>`;
  }

  function notice(text, tone = "navy") {
    return text ? `<div class="notice ${esc(tone)}">${esc(text)}</div>` : "";
  }

  // Every elapsed or remaining duration uses HH:MM:SS.
  function formatDuration(totalSeconds) {
    const seconds = Math.max(0, Math.floor(Number(totalSeconds) || 0));
    return [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60]
      .map((part) => String(part).padStart(2, "0")).join(":");
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
    return `<div class="research-status notice navy" data-research-status><strong>${tx("research.status.heading")}</strong>${lines.map((line) => `<p class="small-copy">${esc(line)}</p>`).join("")}<div class="action-row"><button class="secondary" data-action="retryFailedResearch" data-hint="${esc(tx("research.status.retryNowHint"))}"${canRetry ? "" : " disabled"}>${tx("research.status.retryNow")}</button></div></div>`;
  }

  function statusPill(title, tone = "navy") {
    return `<span class="status-pill ${esc(tone)}">${esc(title)}</span>`;
  }

  function header(titleKey, copyKey, badge, tone = "navy") {
    return `<div class="workspace-head"><div><h2>${tx(titleKey)}</h2><p class="section-copy" data-info>${tx(copyKey)}</p></div>${statusPill(badge, tone)}</div>`;
  }


  function languageSelection() {
    return `<label class="header-language" ${infoAttrs("language.label")}><span class="visually-hidden">${tx("language.label")}</span><select class="select-control" data-language-selection aria-label="${tx("language.label")}">${languageChoices.map(([identifier, nameKey]) => `<option value="${esc(identifier)}"${selected(selectedLanguage, identifier)}>${tx(nameKey)}</option>`).join("")}</select></label>`;
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
  function speedQualityCards(llm, selectedTier, groupID) {
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
        controls = `${statusPill(t("modelLibrary.downloaded"), "cyan")}<button type="button" class="danger" data-action="deleteModelFile" data-file-name="${esc(entry.ggufFileName)}">${deleteLabel(`model:${entry.ggufFileName}`, tx("modelLibrary.delete"))}</button>`;
      }
      const meta = entry ? `<span class="dial-card-meta">${tx("localModel.tier.model", { model: entry.displayName, size: modelSizeGB(entry.downloadSizeBytes), ram: entry.minimumRAMGB })}</span>` : "";
      const ramShort = entry && systemRAMGB && Number(entry.minimumRAMGB) > systemRAMGB
        ? `<span class="dial-card-warning">${tx("localModel.tier.ramShort", { ram: entry.minimumRAMGB })}</span>` : "";
      const badge = entry?.recommended ? `<span class="dial-card-badge">${tx("localModel.tier.recommended")}</span>` : "";
      return `<label class="dial-card${active ? " active" : ""}"><input type="radio" name="speedQuality-${esc(groupID)}" data-field="speedQuality" value="${tier}"${active ? " checked" : ""}><span class="dial-card-head"><span class="dial-card-name">${tx(`localModel.tier.${tier}.name`)}</span>${badge}</span><span class="dial-card-desc" data-info>${tx(`localModel.tier.${tier}.desc`)}</span>${meta}${ramShort}<span class="dial-card-controls">${controls}</span></label>`;
    }).join("")}</div>`;
  }

  // Five positions from Strictest to Broadest, each with what it does.
  function strictnessOptions(selected, groupID) {
    return `<div class="strictness-options" role="radiogroup" aria-label="${esc(t("localModel.strictness"))}">${STRICTNESS_POSITIONS.map((position) => {
      const active = Number(selected) === position;
      return `<label class="strictness-option${active ? " active" : ""}"><input type="radio" name="strictness-${esc(groupID)}" data-field="strictness" value="${position}"${active ? " checked" : ""}><span class="strictness-option-name">${position} · ${tx(`localModel.strictness.${position}.name`)}</span><span class="strictness-option-desc" data-info>${tx(`localModel.strictness.${position}.desc`)}</span></label>`;
    }).join("")}</div>`;
  }

  // Read only acknowledged native state: a draft key/model is not ready yet.
  function researchAvailability() {
    const research = state.settings?.research || {};
    const profile = (state.assets?.providerProfiles || []).find((item) => item.id === research.llmProviderProfileID);
    const protocol = state.assets?.providerProtocols?.[profile?.type] || {};
    const providerReady = protocol.supportsGenerateText === true && protocol.supportsNativeWebSearch === true;
    const keyReady = providerReady && (!protocol.credentialRequired || Boolean(profile?.credential?.trim()));
    const modelReady = Boolean(research.llmModelIdentifier?.trim());
    const configured = providerReady && keyReady && modelReady;
    return { profile, providerReady, keyReady, modelReady, configured, ready: configured && research.enabled === true,
      actionKey: !configured ? "research.setup" : research.enabled ? "research.configure" : "research.enable" };
  }

  function openResearchSetup() {
    utilityPanel = "settings";
    researchSetupRequested = true;
    researchSetupFocusPending = true;
    render();
    window.requestAnimationFrame(placeResearchSetup);
  }

  function placeResearchSetup() {
    if (!researchSetupRequested || utilityPanel !== "settings") return;
    const availability = researchAvailability();
    const missing = [];
    if (!availability.providerReady) {
      missing.push(root.querySelector((state.assets?.providerProfiles || []).some((profile) => {
        const protocol = state.assets?.providerProtocols?.[profile.type];
        return protocol?.supportsGenerateText && protocol?.supportsNativeWebSearch;
      }) ? '[data-form-id="utility-research-form"] [data-field="llmProviderProfileID"]' : '[data-form-id="new-provider-profile-form"] [data-field="type"]'));
    } else if (!availability.keyReady) {
      missing.push(root.querySelector(`[data-form-id="${CSS.escape(`provider-profile-${availability.profile.id}`)}"] [data-field="credential"]`));
    }
    if (!availability.modelReady) missing.push(root.querySelector("[data-model-selector], [data-model-fetch]"));
    if (availability.configured && !availability.ready) missing.push(root.querySelector('[data-form-id="utility-research-form"] [data-field="enabled"]'));
    root.querySelectorAll(".research-setup-needed").forEach((field) => field.classList.remove("research-setup-needed"));
    missing.filter(Boolean).forEach((control) => control.closest(".field, label")?.classList.add("research-setup-needed"));
    if (!researchSetupFocusPending) return;
    researchSetupFocusPending = false;
    const target = missing.find(Boolean) || root.querySelector(".utility-research-section h3");
    if (target) {
      if (target.tagName === "H3") target.tabIndex = -1;
      const focusTarget = target.matches("select") ? target.nextElementSibling?.querySelector(".vui-select-button") || target : target;
      focusTarget.focus({ preventScroll: true });
      focusTarget.scrollIntoView({ block: "center" });
    }
  }

  function currentResearchValues() {
    const draft = [...liveEdits.values()].find((edit) => edit.formID === "utility-research-form");
    return { ...state.settings?.research, ...draft?.values };
  }

  function researchModelPicker() {
    const research = currentResearchValues();
    const providerID = research.llmProviderProfileID || "";
    const profile = (state.assets?.providerProfiles || []).find((item) => item.id === providerID);
    const protocol = state.assets?.providerProtocols?.[profile?.type] || {};
    const canFetch = protocol.supportsGenerateText && protocol.supportsNativeWebSearch
      && (!protocol.credentialRequired || Boolean(profile?.credential?.trim()));
    const catalogs = state.assets?.providerModelCatalogs || {};
    const fetched = Boolean(profile && Object.hasOwn(catalogs, providerID));
    const models = fetched ? catalogs[providerID] : [];
    const loading = (state.assets?.loadingProviderModelProfileIDs || []).includes(providerID);
    const error = state.assets?.providerModelCatalogErrors?.[providerID];
    const current = research.llmModelIdentifier || "";
    if (researchModelQueryProvider !== providerID) {
      researchModelQueryProvider = providerID;
      researchModelQuery = "";
    }
    const expandKey = `research-model:${providerID}`;
    const unavailable = fetched && current && !models.includes(current);
    const choices = models.map((model) => `<button type="button" class="vui-menu-item research-model-option${model === current ? " is-selected" : ""}" data-model-pick="${esc(model)}" aria-pressed="${model === current}">${esc(model)}</button>`).join("");
    const picker = fetched ? `<details class="research-model-picker" data-expand="${esc(expandKey)}"${openExpands.has(expandKey) ? " open" : ""}><summary class="vui-select-button" tabindex="0" data-model-selector aria-label="${tx("research.model")}: ${current ? esc(current) : tx("research.chooseModel")}"><span class="vui-select-label">${current ? esc(current) : tx("research.chooseModel")}</span></summary><div class="research-model-menu vui-menu"><div class="vui-info-field" data-info-label="Search models" ${infoAttrs("research.modelSearch")}><input type="search" data-model-search value="${esc(researchModelQuery)}" aria-label="${tx("research.modelSearch")}" placeholder="${tx("research.modelSearch")}" autocomplete="off" spellcheck="false"></div><div class="research-model-list vui-list-box" data-list-key="${esc(expandKey)}" tabindex="0" aria-label="${tx("research.model")}">${choices}</div><p class="small-copy" data-model-no-matches hidden>${tx("research.noMatchingModels")}</p>${models.length ? "" : `<p class="small-copy">${tx("research.noModels")}</p>`}</div></details>` : current ? `<p class="small-copy">${tx("research.savedModel", { model: current })}</p>` : "";
    return `<div class="field research-model-field"><span class="field-label" ${infoAttrs("research.model")}>${tx("research.model")}</span><input type="hidden" data-field="llmModelIdentifier" value="${esc(current)}">${picker}${unavailable ? `<p class="small-copy research-model-unavailable">${tx("research.modelUnavailable")}</p>` : ""}<div class="action-row"><button type="button" class="secondary" data-action="probeProviderModelCatalog" data-profile-id="${esc(providerID)}" data-model-fetch${disabled(!canFetch || loading)}>${tx(loading ? "research.fetchingModels" : error ? "research.retryModels" : fetched ? "research.refreshModels" : "research.fetchModels")}</button></div>${!canFetch ? `<p class="small-copy">${tx(profile ? "research.modelKeyRequired" : "research.modelProviderRequired")}</p>` : ""}${loading ? `<p class="small-copy" role="status">${tx("research.fetchingModels")}</p>` : ""}${error ? `<div role="alert">${notice(error, "red")}</div>` : ""}</div>`;
  }

  function filterResearchModels() {
    const query = researchModelQuery.trim().toLowerCase();
    const options = [...root.querySelectorAll("[data-model-pick]")];
    options.forEach((option) => { option.hidden = !option.dataset.modelPick.toLowerCase().includes(query); });
    const noMatches = root.querySelector("[data-model-no-matches]");
    if (noMatches) noMatches.hidden = !options.length || options.some((option) => !option.hidden);
    placeResearchModelMenu();
  }

  function closeResearchModelMenu(restoreFocus = false) {
    const picker = root.querySelector(".research-model-picker[open]");
    if (!picker) return false;
    picker.open = false;
    openExpands.delete(picker.dataset.expand);
    if (restoreFocus) picker.querySelector("summary")?.focus({ preventScroll: true });
    return true;
  }

  // Keep the menu inside the Settings dialog for its focus trap, but out of
  // layout flow. It uses the same white floating card as the shared selects.
  function placeResearchModelMenu() {
    const picker = root.querySelector(".research-model-picker[open]");
    if (!picker) return;
    placeClassifierMenu(picker.querySelector("summary"), picker.querySelector(".research-model-menu"));
  }

  function placeClassifierMenu(anchor, menu) {
    const box = anchor.getBoundingClientRect();
    const margin = 8, gap = 4;
    const width = Math.min(Math.max(160, box.width), window.innerWidth - margin * 2);
    menu.style.width = `${width}px`;
    menu.style.left = `${Math.max(margin, Math.min(box.left, window.innerWidth - width - margin))}px`;
    menu.style.maxHeight = `${Math.min(360, window.innerHeight - margin * 2)}px`;
    const desiredHeight = menu.offsetHeight;
    const below = window.innerHeight - box.bottom - gap - margin;
    const above = box.top - gap - margin;
    const opensAbove = below < desiredHeight && above > below;
    menu.style.maxHeight = `${Math.max(0, Math.min(360, opensAbove ? above : below))}px`;
    menu.style.top = `${Math.max(margin, Math.min(opensAbove ? box.top - gap - menu.offsetHeight : box.bottom + gap, window.innerHeight - menu.offsetHeight - margin))}px`;
    menu.style.visibility = "visible";
  }

  document.addEventListener("pointerdown", (event) => {
    const picker = root.querySelector(".research-model-picker[open]");
    if (picker && !event.composedPath().includes(picker)) closeResearchModelMenu();
    const suggestions = root.querySelector("[data-knowledge-suggestions]");
    const creator = root.querySelector("[data-knowledge-creator]");
    if (suggestions && !event.composedPath().includes(suggestions) && !event.composedPath().includes(creator)) closeKnowledgeSuggestions();
  }, true);
  scope.addEventListener("scroll", (event) => {
    if (!event.target.closest?.(".research-model-menu")) placeResearchModelMenu();
    placeKnowledgeSuggestions();
  }, true);
  window.addEventListener("resize", () => { placeResearchModelMenu(); placeKnowledgeSuggestions(); });

  function utilityPanelContent() {
    if (!utilityPanel) return "";
    let content = "";
    if (utilityPanel === "settings") {
      const settings = state.settings;
      const research = settings.research || {};
      const assets = state.assets || {};
      const profiles = assets.providerProfiles || [];
      const protocols = assets.providerProtocols || {};
      const generationProfiles = profiles.filter((profile) => protocols[profile.type]?.supportsGenerateText === true);
      const isGroundingCapable = (profile) => protocols[profile.type]?.supportsGenerateText === true && protocols[profile.type]?.supportsNativeWebSearch === true;
      // Research is provider-grounding only, so only grounding-capable providers are offered.
      const llmProviderOptions = [["", tx("research.chooseProvider")]].concat(generationProfiles.filter(isGroundingCapable).map((profile) => [profile.id, profile.name]));
      const classificationSection = `<section class="utility-settings-section" data-form-id="classification-settings-form" data-autosave-action="saveClassificationSettings"><h3 class="utility-settings-section-title">${tx("classification.title")}</h3><div class="utility-toggles">${toggle("classification.enabled", "classificationEnabled", settings.classificationEnabled !== false)}</div><p class="section-copy" data-info>${tx("classification.copy")}</p></section>`;
      const researchSection = `<section class="utility-settings-section utility-research-section" data-form-id="utility-research-form" data-autosave-action="saveResearchSettings"><h3 class="utility-settings-section-title">${tx("research.title")} ${statusPill(tx(research.enabled ? "research.status.on" : "research.status.off"), research.enabled ? "cyan" : "muted")}</h3><p class="section-copy" data-info>${tx("research.copy")}</p><div class="notice navy research-data-flow" data-info>${tx("research.disclosure")}</div><div class="utility-toggles">${
        toggle("research.consent", "enabled", research.enabled === true)
      }</div><div class="utility-settings-fields">${
        valueSelectField("research.llmProvider", "research.llmProviderHint", "llmProviderProfileID", research.llmProviderProfileID || "", llmProviderOptions)
      }${
        researchModelPicker()
      }</div><p class="small-copy" data-info="research.constantsNote" data-info-target=".utility-research-section h3">${tx("research.constantsNote")}</p><p class="small-copy">${tx("research.usageToday", { used: research.tokensUsedToday ?? 0, limit: research.dailyTokenLimit ?? 10000 })}</p>${researchStatusBlock(research.status)}</section>`;
      const packageSection = `<section class="utility-settings-section utility-resource-section" data-form-id="utility-package-form" data-autosave-action="savePackageSettings"><h3 class="utility-settings-section-title">${tx("settings.packageUpdates")}</h3><div class="utility-settings-fields">${selectField("settings.packageUpdates", "settings.packageUpdatesCopy", "packageUpdateMode", settings.packageUpdateMode, [["automatic", "enum.update.automatic"], ["downloadThenAsk", "enum.update.downloadThenAsk"], ["manual", "enum.update.manual"]])}</div></section>`;
      content = `<section class="utility-panel utility-settings-modal"><div class="utility-panel-head"><div><h2>${tx("utility.settings.title")}</h2><p class="section-copy" data-info>${tx("utility.settings.copy")}</p></div><button class="secondary utility-close" data-action="closeUtilityPanel">${tx("utility.close")}</button></div><div class="utility-settings-body">${notice(state.issue, "red")}${classificationSection}${apiKeySettings()}${researchSection}${packageSection}<section class="utility-settings-section"><h3 class="utility-settings-section-title">${tx("language.label")}</h3>${languageSelection()}</section></div></section>`;
    }
    if (!content) return "";
    return `<div class="utility-popover-layer" role="presentation"><button class="utility-popover-dismiss" data-action="closeUtilityPanel" aria-label="${tx("utility.close")}"></button><div class="utility-popover" data-list-key="settings" role="dialog" aria-modal="true" aria-label="${esc(tx("utility.settings.title"))}">${content}</div></div>`;
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
    const names = (type.applicablePlatformIDs || [])
      .map((id) => (state.assets?.collectionPlatforms || []).find((definition) => definition.id === id)?.name)
      .filter(Boolean);
    const active = selectedTypeID === type.id ? " active" : "";
    const meta = names.length ? names.join(", ") : tx("bridge.noApplicablePlatform");
    return `<div class="classifier-type-row${active}" data-type-id="${esc(type.id)}">
      <button class="sidebar-row classifier-type-select${active}" type="button" data-action="selectType" data-type-id="${esc(type.id)}"><span class="sidebar-symbol" aria-hidden="true">◧</span><span class="sidebar-copy"><span class="sidebar-name">${esc(type.name)}</span><span class="sidebar-meta">${esc(meta)}</span></span></button>
    </div>`;
  }

  // Groups and Knowledge are directly reachable.
  function sidebarContent() {
    const types = orderedClassifierTypes();
    const typeRows = types.length
      ? types.map((type) => classifierTypeRow(type)).join("")
      : `<div class="empty compact-empty">${tx("navigation.noTypes")}</div>`;
    return `
      <div class="sidebar-group-title">${tx("navigation.classifierTypes")}</div>
      <div class="classifier-type-nav vui-list-box" data-classifier-type-nav data-list-key="types" tabindex="0" aria-label="${tx("navigation.classifierTypes")}">${typeRows}</div>
      <button class="sidebar-add" type="button" data-action="newType"><span aria-hidden="true">＋</span> ${tx("navigation.newType")}</button>
      ${navButton("knowledge", "✦", "navigation.knowledge", "navigation.knowledgeMeta")}`;
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

  function initialShell() {
    // Native state arrives asynchronously. Keep navigation available from the
    // first paint rather than replacing the whole scene with a loading screen.
    return `<div class="popup"><header class="vui-topbar"><nav class="vui-tabs" aria-label="Scene"><button type="button" class="vui-tab" data-scene="vault">Vault</button><button type="button" class="vui-tab is-active" data-scene="classifier">Classifier</button><button type="button" class="vui-tab" data-scene="activity">Activity</button></nav></header><div class="layout" aria-busy="true"></div></div>`;
  }

  function syncDialogFocus(previousControl) {
    const kind = pendingCreateType ? "create" : utilityPanel;
    releaseDialogFocus?.(false);
    releaseDialogFocus = null;
    if (!kind) {
      if (dialogFocusKind) root.querySelector(dialogFocusKind === "create"
        ? '[data-action="newType"]' : '[data-action="openUtilityPanel"]')?.focus({ preventScroll: true });
      dialogFocusKind = null;
      return;
    }
    dialogFocusKind = kind;
    const card = root.querySelector(kind === "create" ? "[data-create-type-dialog]" : '.utility-popover[role="dialog"]');
    if (!card) return;
    const active = scope.activeElement;
    const initial = card.contains(active) ? active : previousControl
      ? Array.from(card.querySelectorAll("button, input, select, textarea")).find((control) =>
        control.dataset.action === previousControl.action && control.dataset.field === previousControl.field
        && control.hasAttribute("data-create-type-name") === previousControl.createName
        && (!previousControl.platform || control.value === previousControl.platform)) : null;
    releaseDialogFocus = window.VaultUI.focusDialog(card, {
      initialFocus: initial || card.querySelector(kind === "create" ? "[data-create-type-name]" : '[data-action="closeUtilityPanel"]'),
      returnFocus: () => root.querySelector(kind === "create" ? '[data-action="newType"]' : '[data-action="openUtilityPanel"]'),
      onEscape: dismissClassifierDialog
    });
    if (previousControl?.start != null && initial?.setSelectionRange) {
      initial.setSelectionRange(previousControl.start, previousControl.end);
    }
  }

  function backupWorkspace() {
    const backup = state.backup;
    const stateLabel = t(backup.savedEnabled ? "common.on" : "common.off");
    return `<div class="workspace">${header("backup.title", "backup.copy", stateLabel, backup.savedEnabled ? "navy" : "muted")}
      <section class="section-card navy" data-form-id="backup-owner-form"><div class="section-header"><div><h3>${tx("backup.ownerGate")}</h3><p class="section-copy" data-info>${tx("backup.ownerCopy")}</p></div></div>${backup.unlocked ? `<div class="notice navy">${tx("backup.unlocked")}</div>` : `<div class="action-row"><div class="field">${field("backup.ownerCode", backup.hasOwnerCode ? "backup.existingCode" : "backup.newCode", "ownerCode", "", "password")}</div><button class="primary" data-action="${backup.hasOwnerCode ? "unlockBackup" : "setBackupOwnerCode"}" data-form="backup-owner-form">${tx(backup.hasOwnerCode ? "backup.unlock" : "backup.setCode")}</button></div>`}</section>
      <section class="section-card navy" data-form-id="backup-form" data-autosave-action="saveBackup"><div class="section-header"><div><h3>${tx("backup.folder")}</h3><p class="section-copy" data-info>${tx("backup.folderCopy")}</p></div></div><div class="form-stack">${field("backup.localFolder", "backup.pathHint", "directory", backup.directory, "text", backup.unlocked ? "" : "disabled")}${toggle("backup.auto", "enabled", backup.enabled, backup.unlocked ? "" : "disabled")}<div class="action-row"><button class="secondary" data-action="backupNow"${disabled(!backup.unlocked || !backup.savedEnabled)}>${tx("backup.create")}</button></div></div></section>${notice(state.notices.backup, "navy")}${notice(state.issue, "red")}</div>`;
  }

  function integrationWorkspace() {
    const line = (labelKey, valueKey) => `<div class="status-line"><strong>${tx(labelKey)}</strong><span class="spacer"></span><span>${tx(valueKey)}</span></div>`;
    return `<div class="workspace">${header("integration.title", "integration.copy", t("integration.notInstalled"), "muted")}
      <section class="section-card cyan"><div class="form-stack">${line("integration.app", "integration.ready")}${line("integration.pairing", "integration.keychain")}${line("integration.host", "integration.notRegistered")}${line("integration.server", "integration.notRequired")}</div></section><div class="notice cyan" data-info="integration.notice">${tx("integration.notice")}</div></div>`;
  }

  // A classifier type's own tag tree (the tree belongs to its type: made and
  // deleted with it). The canvas is as tall as its tags (at most 520 px) and
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
          ? `<button class="secondary" data-action="beginConnection" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}">${tx("tree.connection")}</button><button class="secondary" data-action="disconnectTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}"${disabled(!popoverNode.parentID)}>${tx("tree.disconnection")}</button><button class="danger" data-action="deleteTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}">${deleteLabel(`tag:${nodeID}`, tx("tree.deleteNode"))}</button>`
          : `<button class="primary" data-action="addTag" data-form="tag-popover-form" data-tree-id="${esc(tree.id)}">${tx("tree.createNode")}</button>`;
        // Placed beside its anchor, inside the visible part (placeTreePopovers).
        return `<section class="tree-popover" data-anchor-x="${panelState.x}" data-anchor-y="${panelState.y}" data-anchor-w="${panelState.w || 0}" data-tree-popover data-form-id="tag-popover-form"${isEdit ? ` data-autosave-action="updateTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}"` : ""}><div class="tree-popover-head"><span class="eyebrow">${tx(isEdit ? "tree.editNode" : "tree.createNode")}</span><button class="tree-popover-close" data-action="cancelTagPanel" data-hint="${tx("tree.cancel")}" aria-label="${tx("tree.cancel")}">×</button></div><div class="tree-form">${nameField}${descriptionField}<div class="action-row">${actions}</div></div></section>`;
      })() : "";
      const map = `<div class="tree-map" data-tree-map data-tree-id="${esc(tree.id)}">${connectionState ? `<div class="tree-connection-mode">${tx("tree.connectionHint")}</div>` : ""}<div class="tree-map-content" style="width:max(${contentWidth}px, 100%);height:${contentHeight}px"><svg class="tree-links" aria-hidden="true"></svg><div class="tree-node-layer">${nodes.map((node) => {
        const position = positions.get(node.id);
        const colorStyle = tagColorStyle(node);
        return `<button class="tree-map-node${panelState?.nodeID === node.id || selectedNodeID === node.id ? " active" : ""}${connectionState?.nodeID === node.id ? " connection-source" : ""}${node.retired ? " retired" : ""}" style="left:${position.x}px;top:${position.y}px;${colorStyle}" data-action="selectTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(node.id)}" data-parent-id="${esc(node.parentID || "")}" data-position-x="${position.x}" data-position-y="${position.y}" data-hint="${tx("tree.contextHint")}"><span aria-hidden="true"></span><strong>${esc(node.name)}</strong></button>`;
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

  function apiKeySettings() {
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
      return `<section class="provider-panel" data-provider-panel data-provider-id="${esc(profile.id)}" data-form-id="${esc(formID)}" data-autosave-action="updateProviderConnection"><div class="provider-panel-head"><h3>${esc(profile.name)}</h3><div class="provider-panel-actions">${testButton}<button class="danger" data-action="confirmDeleteProviderProfile" data-profile-id="${esc(profile.id)}">${deleteLabel(`provider:${profile.id}`, tx("llm.deleteProfile"))}</button></div></div>${retiredSearchProvider ? `<div class="notice navy">${tx("llm.retiredSearchProvider")}</div>` : ""}<div class="provider-panel-body">${connectionFields ? `<div class="provider-connection-fields">${connectionFields}</div>` : ""}</div><footer class="provider-request-summary">${usage}${responseDiagnostic}</footer>${profile.testSucceeded ? notice(t("llm.testSucceeded"), "green") : ""}</section>`;
    };
    return `<section class="utility-settings-section utility-api-keys"><h3 class="utility-settings-section-title">${tx("navigation.apiKeys")}</h3><p class="section-copy" data-info>${tx("llm.copy")}</p><div class="notice navy provider-local-only" data-info>${tx("llm.localOnlyDisclosure")}</div><section class="provider-create" data-form-id="new-provider-profile-form">${groupedValueSelectField("llm.providerType", "", "type", "", profileTypeGroups)}<button class="gold-action" data-action="createProviderProfile" data-form="new-provider-profile-form">${tx("llm.createKey")}</button><span class="small-copy" data-info="llm.createCopy">${tx("llm.createCopy")}</span></section><div class="provider-panels vui-list-box" data-list-key="providers" tabindex="0" aria-label="${tx("llm.keyLibrary")}">${profiles.length ? profiles.map(panel).join("") : `<div class="empty">${tx("llm.empty")}</div>`}</div></section>`;
  }

  // The classifiable platforms as a checklist (owner 2026-09-30: a type may take
  // several; a platform belongs to at most one type. Creation is the only
  // time this choice can change; existing types show their fixed selection.
  function platformChoices(selectedIDs, typeID) {
    const selected = new Set(selectedIDs);
    const owners = new Map();
    for (const type of state.assets?.classifierTypes || []) {
      for (const id of type.applicablePlatformIDs || []) owners.set(id, type);
    }
    const platforms = (state.assets?.collectionPlatforms || []).filter((platform) => platform.supportsLocalModel === true);
    return `<div class="platform-choices">${platforms.map((platform) => {
      const owner = owners.get(platform.id);
      const taken = Boolean(owner && owner.id !== typeID);
      return `<label class="toggle-row platform-choice"><input type="checkbox" value="${esc(platform.id)}" data-platform-choice${selected.has(platform.id) ? " checked" : ""}${typeID || taken ? " disabled" : ""}><span>${esc(platform.name)}</span>${taken ? `<span class="field-hint">${tx("bridge.platformTakenBy", { name: owner.name })}</span>` : ""}</label>`;
    }).join("")}</div>`;
  }

  function checkedPlatforms(container) {
    return Array.from(container?.querySelectorAll("input[data-platform-choice]:checked") || []).map((input) => input.value);
  }

  function browserBridgeWorkspace() {
    const assets = state.assets;
    const classifierTypes = assets.classifierTypes || [];
    const profiles = assets.providerProfiles || [];
    const platformDefinitions = new Map((assets.collectionPlatforms || []).map((platform) => [platform.id, platform]));
    const typeForm = (classifierType) => {
      const formID = `classifier-type-${classifierType.id}`;
      const chosen = classifierType.applicablePlatformIDs || [];
      // Platform data (an API key some platforms use) and a recording that is
      // off, for the chosen platforms.
      const platformNotes = chosen.map((id) => platformDefinitions.get(id)).filter(Boolean).flatMap((platform) => {
        const notes = [];
        if (platform.apiProviderType) {
          const bound = profiles.find((profile) => profile.type === platform.apiProviderType && profile.hasCredential);
          notes.push(bound ? t("bridge.platformDataBound", { profile: bound.name }) : t("bridge.platformDataMissingKey", { platform: platform.name }));
        }
        const binding = (assets.bindings || []).find((candidate) => candidate.id === platform.id);
        if (binding && !binding.collectionEnabled) notes.push(`${platform.name}: ${t("bridge.recordingOff")}`);
        return notes;
      });
      const localModel = classifierType.localModel || { speedQuality: "balanced", strictness: 3, houseRules: "" };
      const localModelFormID = `classifier-local-model-form-${classifierType.id}`;
      const library = state.settings?.localModels || {};
      const selectedEntry = tierEntry(library, localModel.speedQuality);
      const modelReady = selectedEntry?.state?.kind === "downloaded";
      const engineStatus = modelReady ? (selectedEntry.engineStatus || "downloaded") : "no-model";
      const engineTone = { loaded: "cyan", downloaded: "cyan", loading: "navy", failed: "red", "no-model": "pink" }[engineStatus] || "navy";
      const engineLabel = engineStatus === "downloaded" ? "modelLibrary.downloaded" : `localModel.status.${engineStatus}`;
      const defaultMinimum = localModel.strictness === 5 ? 1 : 0;
      const defaultMaximum = localModel.strictness === 1 ? 1 : 3;
      const boundsSummary = localModel.minimumTagsOverride != null || localModel.maximumTagsOverride != null
        ? t("bridge.tagBounds.custom", { minimum: localModel.minimumTagsOverride ?? defaultMinimum, maximum: localModel.maximumTagsOverride ?? defaultMaximum })
        : t("bridge.tagBounds.default");
      const expandKey = `type-more:${classifierType.id}`;
      const localModelSection = `<section class="classifier-type-section classifier-local-model" data-local-model-section><div class="section-header"><div><h3>${tx("bridge.localModel")} ${statusPill(tx(engineLabel), engineTone)}</h3><p class="section-copy" data-info>${tx("bridge.localModelCopy")}</p></div></div><div class="field wide"><span class="field-label">${tx("localModel.speedQuality")}<span class="field-hint" data-info> · ${tx("localModel.speedQualityHint")}</span></span>${speedQualityCards(library, localModel.speedQuality, classifierType.id)}<p class="model-library-source-note" data-info>${tx("localModel.tier.sourceNote")}</p></div><div class="field wide"><span class="field-label">${tx("localModel.strictness")}<span class="field-hint" data-info> · ${tx("localModel.strictnessHint")}</span></span>${strictnessOptions(localModel.strictness, classifierType.id)}${localModel.minimumTagsOverride != null || localModel.maximumTagsOverride != null ? `<p class="small-copy" data-info="bridge.tagBounds.precedence">${tx("bridge.tagBounds.precedence")}</p>` : ""}</div><p class="small-copy resident-model-note" data-info data-info-target="[data-local-model-section] h3">${tx("bridge.localModelResidentNote")}</p>${textareaField("bridge.localModelHouseRules", "bridge.localModelHouseRulesCopy", "houseRules", localModel.houseRules, 'rows="4" maxlength="4000"')}</section>`;
      const tagBoundsSection = `<details class="vui-expand classifier-group-more" data-expand="${esc(expandKey)}"${openExpands.has(expandKey) ? " open" : ""}><summary><span>${tx("navigation.more")}</span><span class="small-copy classifier-override-summary">${esc(boundsSummary)}</span></summary><section class="classifier-type-section"><p class="section-copy" data-info data-tag-bounds-defaults>${tx("bridge.tagBounds.copy", { minimum: defaultMinimum, maximum: defaultMaximum })}</p><div class="utility-settings-fields">${field("bridge.tagBounds.minimum", "bridge.tagBounds.minimumHint", "minimumTagsOverride", localModel.minimumTagsOverride ?? "", "number", `min="0" max="3" step="1" placeholder="${defaultMinimum}"`)}${field("bridge.tagBounds.maximum", "bridge.tagBounds.maximumHint", "maximumTagsOverride", localModel.maximumTagsOverride ?? "", "number", `min="1" max="3" step="1" placeholder="${defaultMaximum}"`)}</div><p class="notice red" data-tag-bounds-error role="status" hidden>${tx("bridge.tagBounds.error")}</p></section></details>`;
      const researchFormID = `classifier-research-form-${classifierType.id}`;
      const researchMode = classifierType.researchEnabled === true ? "on" : classifierType.researchEnabled === false ? "off" : "inherit";
      const researchOverrideSection = `<section class="classifier-type-section classifier-research-overrides"><div class="section-header"><div><h3>${tx("bridge.researchOverrides")}</h3><p class="section-copy" data-info>${tx("bridge.researchOverridesCopy")}</p></div></div><div data-form-id="${esc(researchFormID)}" data-autosave-action="saveClassifierTypeResearch" data-type-id="${esc(classifierType.id)}"><div class="utility-settings-fields">${valueSelectField("bridge.researchMode", "", "researchMode", researchMode, [["inherit", t("bridge.researchMode.inherit")], ["on", t(researchAvailability().ready ? "bridge.researchMode.on" : researchAvailability().actionKey)], ["off", t("bridge.researchMode.off")]], "data-group-research-choice")}${researchMode === "on" && !researchAvailability().ready ? `<button class="secondary" data-action="openResearchSetup">${tx(researchAvailability().actionKey)}</button>` : ""}</div><p class="small-copy research-master-note" data-info>${tx("bridge.researchMasterGate")}</p></div></section>`;
      return `<section class="classifier-type-panel" data-form-id="${esc(formID)}" data-type-id="${esc(classifierType.id)}" data-autosave-action="configureClassifierType">
        <div class="classifier-name-row">${field("bridge.typeName", "", "name", classifierType.name, "text", 'maxlength="128"')}</div>
        <section class="classifier-type-section classifier-applicable-platform-section"><span class="field-label" ${infoAttrs("bridge.applicablePlatform")}>${tx("bridge.applicablePlatform")}</span>${platformChoices(chosen, classifierType.id)}<p class="small-copy" data-info="bridge.platformsFixed">${tx("bridge.platformsFixed")}</p>${platformNotes.map((note) => `<p class="small-copy">${esc(note)}</p>`).join("")}</section>
        <div class="action-row classifier-tagging-control"><button type="button" class="secondary" data-action="setClassifierTypePaused" data-type-id="${esc(classifierType.id)}" data-paused="${classifierType.isPaused !== true}">${tx(classifierType.isPaused === true ? "classification.resume" : "classification.pause")}</button>${statusPill(tx(classifierType.isPaused === true ? "classification.paused" : state.settings?.classificationEnabled === false ? "classification.disabled" : "classification.active"), classifierType.isPaused === true || state.settings?.classificationEnabled === false ? "muted" : "cyan")}</div>
        <p class="small-copy" data-info="bridge.autoSave">${tx("bridge.autoSave")}</p>
        <div data-form-id="${esc(localModelFormID)}" data-autosave-action="saveClassifierTypeLocalModel" data-type-id="${esc(classifierType.id)}">
          ${localModelSection}
          ${tagBoundsSection}
        </div>
        ${researchOverrideSection}
        <div class="action-row classifier-type-delete"><button class="danger" data-action="confirmDeleteClassifierType" data-type-id="${esc(classifierType.id)}">${deleteLabel(`type:${classifierType.id}`, tx("bridge.deleteType"))}</button></div>
      </section>`;
    };
    // A type targets one or more platforms and owns a fresh tree. The
    // left panel selects which type is open; a selected type shows its config
    // and owned tree together.
    const selectedType = selectedTypeID ? classifierTypes.find((type) => type.id === selectedTypeID) : null;
    if (selectedType) {
      // The type (its name is the editable title) and its tag tree, in one scroll.
      const section = (labelKey, inner) => `<section class="type-section"><h3 class="type-section-title">${tx(labelKey)}</h3>${inner}</section>`;
      return `<div class="workspace classifier-type-workspace">
        <div class="type-detail-body">
          ${notice(state.issue, "red")}
          <section class="type-section">${typeForm(selectedType)}</section>
          ${section("bridge.tabTree", tagTreeWorkspace(selectedType.treeID))}
        </div></div>`;
    }
    // Nothing selected: '+ New type' creates directly and the sidebar lists the
    // types, so this is just a prompt.
    return `<div class="workspace classifier-type-workspace">${header("bridge.title", "bridge.copy", t("bridge.typeLibrary"), "navy")}
      <div class="empty">${tx(classifierTypes.length ? "bridge.selectType" : "bridge.emptyTypes")}</div>${notice(state.issue, "red")}</div>`;
  }

  // Knowledge (owner 2026-09-30): terms are shared by every platform; known
  // creators are listed per platform, each with its name and picture. What
  // you write is marked "By you", lookups "Looked up". No source links.
  const KNOWLEDGE_PLATFORMS = [["youtube", "YouTube"], ["bilibili", "Bilibili"], ["reddit", "Reddit"], ["twitter", "X"]];
  let knowledgeQuery = "";
  let knowledgeAddPlatform = "youtube";
  let knowledgeCreatorDraft = "";
  let knowledgeSuggestionsOpen = false;

  function knowledgeWorkspace() {
    const availability = researchAvailability();
    const research = state.settings?.research || {};
    const connection = `<section class="knowledge-research-connection"><div><h3>${tx("knowledge.lookupProvider")}</h3><p class="small-copy">${availability.profile ? esc(availability.profile.name) : tx("research.noProvider")}${research.llmModelIdentifier ? ` · ${esc(research.llmModelIdentifier)}` : ""}</p>${statusPill(tx(availability.ready ? "research.status.on" : availability.configured ? "research.status.off" : "research.status.setup"), availability.ready ? "cyan" : "gold")}</div><button class="secondary" data-action="openResearchSetup">${tx(availability.actionKey)}</button></section>`;
    const knowledge = state.assets?.knowledge || { creators: [], terms: [] };
    const creators = knowledge.creators || [];
    const terms = knowledge.terms || [];

    const origin = (entry) => statusPill(tx(entry.writtenByUser ? "knowledge.byYou" : "knowledge.lookedUp"), entry.writtenByUser ? "gold" : "cyan");
    const entryCard = (entry, kind) => {
      const formID = `knowledge-edit-${entry.id}`;
      const name = kind === "creator" ? (entry.name || entry.subject) : entry.subject;
      const face = kind === "creator"
        ? (entry.icon ? `<img class="knowledge-face" src="${esc(entry.icon)}" alt="" aria-hidden="true" loading="lazy">` : `<span class="knowledge-face knowledge-face-empty" aria-hidden="true">${esc((name || "?").trim().charAt(0).toUpperCase())}</span>`)
        : "";
      const idLine = kind === "creator" ? `<span class="knowledge-id" dir="auto">${esc(entry.subject)}</span>` : "";
      const search = `${name} ${entry.subject} ${entry.meaning || ""}`.toLowerCase();
      return `<article class="knowledge-card" data-form-id="${esc(formID)}" data-knowledge-search="${esc(search)}" data-autosave-action="editKnowledgeEntry" data-id="${esc(entry.id)}"><div class="knowledge-card-head">${face}<span class="knowledge-name"><span class="knowledge-subject" dir="auto">${esc(name)}</span>${idLine}</span>${origin(entry)}</div><label class="field wide"><span class="field-label" ${infoAttrs("knowledge.description")}>${tx("knowledge.description")}</span><textarea data-field="meaning" rows="3" maxlength="2000">${esc(entry.meaning || "")}</textarea></label><div class="action-row"><button class="danger" data-action="deleteKnowledgeEntry" data-id="${esc(entry.id)}">${deleteLabel(`knowledge:${entry.id}`, tx("knowledge.delete"))}</button></div></article>`;
    };

    const group = (title, hint, items, kind) => `<section class="knowledge-group" data-knowledge-group><div class="section-header"><div><h3>${esc(title)} <span class="knowledge-count" data-knowledge-count>${items.length}</span></h3>${hint ? `<p class="section-copy" data-info>${esc(hint)}</p>` : ""}</div></div>${items.length ? `<div class="knowledge-list vui-list-box" data-list-key="knowledge:${kind}:${esc(title)}" tabindex="0" aria-label="${esc(title)}">${items.map((entry) => entryCard(entry, kind)).join("")}</div>` : `<div class="empty">${tx("knowledge.empty")}</div>`}</section>`;

    // Terms are only ever added here, by the user: name the term, and either
    // write what it means or leave that blank to have it looked up.
    const addTerm = `<section class="knowledge-group" data-form-id="knowledge-add-term"><div class="section-header"><div><h3>${tx("knowledge.addTerm")}</h3><p class="section-copy" data-info>${tx("knowledge.addTermHint")}</p></div></div><div class="form-stack">${field("knowledge.termSubject", "knowledge.termSubjectHint", "subject", "", "text", 'maxlength="120"')}<label class="field wide"><span class="field-label" ${infoAttrs("knowledge.description")}>${tx("knowledge.description")}</span><textarea data-field="meaning" rows="2" maxlength="2000" placeholder="${tx("knowledge.termMeaningPlaceholder")}"></textarea></label><div class="action-row"><button class="primary" data-action="addKnowledgeTerm" data-form="knowledge-add-term">${tx("knowledge.addTermButton")}</button></div></div></section>`;

    // A creator: pick the platform, then a link, @handle, r/name or the name of
    // one already seen (suggested as you type).
    const addCreator = `<section class="knowledge-group" data-form-id="knowledge-add-creator"><div class="section-header"><div><h3>${tx("knowledge.addCreator")}</h3><p class="section-copy" data-info>${tx("knowledge.addCreatorHint")}</p></div></div><div class="form-stack">${valueSelectField("knowledge.platform", "", "platformID", knowledgeAddPlatform, KNOWLEDGE_PLATFORMS, "data-knowledge-platform")}<label class="field"><span class="field-label">${tx("knowledge.creator")}<span class="field-hint" data-info> · ${tx("knowledge.creatorHint")}</span></span><input type="text" data-field="creator" data-knowledge-creator value="${esc(knowledgeCreatorDraft)}" maxlength="512" autocomplete="off" spellcheck="false"></label><div class="knowledge-suggestions vui-menu" data-knowledge-suggestions></div><label class="field wide"><span class="field-label" ${infoAttrs("knowledge.description")}>${tx("knowledge.description")}</span><textarea data-field="meaning" rows="2" maxlength="2000" placeholder="${tx("knowledge.creatorMeaningPlaceholder")}"></textarea></label><div class="action-row"><button class="primary" data-action="addKnowledgeCreator" data-form="knowledge-add-creator">${tx("knowledge.addCreatorButton")}</button></div></div></section>`;

    const searchBox = `<label class="field knowledge-search"><span class="field-label" ${infoAttrs("knowledge.search")}>${tx("knowledge.search")}</span><input type="search" data-knowledge-search-input value="${esc(knowledgeQuery)}" autocomplete="off" spellcheck="false"></label>`;
    const creatorGroups = KNOWLEDGE_PLATFORMS.map(([platformID, label]) =>
      group(t("knowledge.creatorsOn", { platform: label }), "", creators.filter((entry) => entry.platformID === platformID), "creator")).join("");

    return `<div class="workspace knowledge-workspace">${header("knowledge.title", "knowledge.copy", tx("knowledge.badge"), "gold")}<div class="notice navy" data-info="knowledge.disclosure">${tx("knowledge.disclosure")}</div>${connection}${notice(state.notices?.knowledge, "navy")}${notice(state.issue, "red")}${addTerm}${addCreator}${searchBox}${group(t("knowledge.terms"), t("knowledge.termsHint"), terms, "term")}<p class="small-copy" data-info="knowledge.creatorsHint">${tx("knowledge.creatorsHint")}</p>${creatorGroups}</div>`;
  }

  // Show only the cards matching the search (no re-render: nothing is lost
  // while typing) and keep each group's count honest.
  function applyKnowledgeSearch() {
    const query = knowledgeQuery.trim().toLowerCase();
    root.querySelectorAll("[data-knowledge-group]").forEach((groupElement) => {
      let shown = 0;
      groupElement.querySelectorAll("[data-knowledge-search]").forEach((card) => {
        const match = !query || card.dataset.knowledgeSearch.includes(query);
        card.hidden = !match;
        if (match) shown += 1;
      });
      const count = groupElement.querySelector("[data-knowledge-count]");
      if (count && groupElement.querySelector("[data-knowledge-search]")) count.textContent = String(shown);
    });
  }

  // "Add a creator" suggestions: creators already collected on the chosen
  // platform whose name contains what is typed.
  function showKnowledgeSuggestions(input) {
    const box = root.querySelector("[data-knowledge-suggestions]");
    if (!box) return;
    const query = input.value.trim().toLowerCase();
    knowledgeCreatorDraft = input.value;
    const known = (state.assets?.knowledge?.knownCreators || []).filter((creator) => creator.platformID === knowledgeAddPlatform);
    const rank = (name) => (name.startsWith(query) ? 0 : name.split(/\s+/).some((word) => word.startsWith(query)) ? 1 : 2);
    const matches = query.length < 2 ? [] : known
      .filter((creator) => creator.name.toLowerCase().includes(query))
      .sort((a, b) => rank(a.name.toLowerCase()) - rank(b.name.toLowerCase()))
      .slice(0, 6);
    box.innerHTML = matches.map((creator) => `<button type="button" class="vui-menu-item knowledge-suggestion" data-knowledge-pick="${esc(creator.name)}"><span dir="auto">${esc(creator.name)}</span><span class="knowledge-id">${esc(creator.id)}</span></button>`).join("");
    knowledgeSuggestionsOpen = matches.length > 0;
    if (knowledgeSuggestionsOpen) { window.VaultUI.close(); placeKnowledgeSuggestions(); }
  }

  function closeKnowledgeSuggestions(restoreFocus = false) {
    const box = root.querySelector("[data-knowledge-suggestions]");
    if (restoreFocus) root.querySelector("[data-knowledge-creator]")?.focus({ preventScroll: true });
    if (box) box.replaceChildren();
    knowledgeSuggestionsOpen = false;
  }

  function placeKnowledgeSuggestions() {
    const box = root.querySelector("[data-knowledge-suggestions]");
    const input = root.querySelector("[data-knowledge-creator]");
    if (box?.children.length && input) placeClassifierMenu(input, box);
  }

  scope.addEventListener("focusin", (event) => {
    if (event.target.matches?.("[data-knowledge-creator]") && !replacingControls) showKnowledgeSuggestions(event.target);
  });
  scope.addEventListener("focusout", () => window.requestAnimationFrame(() => {
    if (knowledgeSuggestionsOpen && !scope.activeElement?.matches?.("[data-knowledge-creator], [data-knowledge-pick]")) closeKnowledgeSuggestions();
  }));

  const DELETE_KEYS = {
    confirmDeleteProviderProfile: (data) => `provider:${data.profileId}`,
    deleteModelFile: (data) => `model:${data.fileName}`,
    deleteTag: (data) => `tag:${data.nodeId}`,
    confirmDeleteClassifierType: (data) => `type:${data.typeId}`,
    deleteKnowledgeEntry: (data) => `knowledge:${data.id}`
  };

  function deleteLabel(key, label) {
    return armedDelete === key ? tx("common.clickAgainToDelete") : label;
  }

  // → true when this click confirms (the button was armed); otherwise arms it.
  function confirmDelete(key) {
    clearTimeout(armedDeleteTimer);
    if (armedDelete === key) {
      armedDelete = null;
      return true;
    }
    armedDelete = key;
    armedDeleteTimer = setTimeout(() => { armedDelete = null; render(); }, 4000);
    render();
    return false;
  }

  function workspace() {
    switch (state.workspace) {
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

  function flushTagNameInput(input) {
    if (input) queueLiveEdit(input, true);
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
    if (!event.isComposing) queueLiveEdit(event.target);
    const knowledgeSearch = event.target.closest("input[data-knowledge-search-input]");
    if (knowledgeSearch) {
      knowledgeQuery = knowledgeSearch.value;
      applyKnowledgeSearch();
      return;
    }
    const creatorInput = event.target.closest("input[data-knowledge-creator]");
    if (creatorInput) {
      showKnowledgeSuggestions(creatorInput);
      return;
    }
    const modelSearch = event.target.closest("input[data-model-search]");
    if (modelSearch) {
      researchModelQuery = modelSearch.value;
      filterResearchModels();
      return;
    }
    const input = event.target.closest("input[data-live-tag-name]");
    if (!input) return;
    const { treeId: treeID, nodeId: nodeID } = input.dataset;
    if (!treeID || !nodeID) return;
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

  // Create-a-group dialog: platform and name. The new group follows the global
  // dials, house rules and research switch until given its own.
  function createTypeModal() {
    if (!pendingCreateType) return "";
    return `<div class="utility-popover-layer" role="presentation"><button class="utility-popover-dismiss" data-action="cancelCreateType" aria-label="${tx("common.cancel")}"></button><div class="deletion-dialog create-type-dialog" role="dialog" aria-modal="true" aria-label="${tx("createType.title")}" data-create-type-dialog><h3>${tx("createType.title")}</h3><p class="section-copy" data-info>${tx("createType.copy")}</p><div class="field"><span class="field-label" ${infoAttrs("createType.platformLabel")}>${tx("createType.platformLabel")}</span>${platformChoices(pendingCreateType.platformIDs || [], null)}${pendingCreateType.issue ? notice(t("createType.platformRequired"), "red") : ""}</div><label class="field"><span class="field-label" ${infoAttrs("createType.nameLabel")}>${tx("createType.nameLabel")}</span><input type="text" data-create-type-name autocomplete="off" spellcheck="false" value="${esc(pendingCreateType.name != null ? pendingCreateType.name : t("createType.defaultName"))}"></label><div class="action-row"><button class="secondary" data-action="cancelCreateType">${tx("common.cancel")}</button><button class="primary" data-action="confirmCreateType">${tx("createType.create")}</button></div></div></div>`;
  }


  function render() {
    if (!state) {
      root.innerHTML = initialShell();
      lastRenderedMarkup = null;
      return;
    }
    if (composingEdit) return;
    const markup = shell(workspace()) + createTypeModal();
    // Nothing changed on the page: keep the DOM (and its scroll) as it is.
    if (markup === lastRenderedMarkup && root.firstChild) return;
    renderFull(markup);
  }

  function renderFull(markup) {
    rememberTreeViewportPositions();
    rememberEditorViewportPosition();
    root.querySelectorAll("[data-list-key]").forEach((list) => {
      listViewportPositions.set(list.dataset.listKey, { x: list.scrollLeft, y: list.scrollTop });
    });
    const focused = captureLiveEditFocus();
    const creatorInput = scope.activeElement?.matches("[data-knowledge-creator]") ? scope.activeElement : null;
    const creatorSelection = creatorInput ? { start: creatorInput.selectionStart, end: creatorInput.selectionEnd } : null;
    const modelSearch = scope.activeElement?.matches("[data-model-search]") ? scope.activeElement : null;
    const searchSelection = modelSearch ? { start: modelSearch.selectionStart, end: modelSearch.selectionEnd } : null;
    const active = scope.activeElement;
    const dialogControl = active?.closest?.('[role="dialog"]') ? {
      action: active.dataset.action, field: active.dataset.field,
      createName: active.hasAttribute("data-create-type-name"),
      platform: active.hasAttribute("data-platform-choice") ? active.value : null,
      start: active.selectionStart, end: active.selectionEnd
    } : null;
    replacingControls = true;
    root.innerHTML = markup;
    restoreLiveEdits(focused);
    replacingControls = false;
    lastRenderedMarkup = markup;
    bindTreeMapWheel();
    applyKnowledgeSearch();
    if (knowledgeSuggestionsOpen) {
      const creator = root.querySelector("[data-knowledge-creator]");
      if (creator) showKnowledgeSuggestions(creator);
    }
    if (creatorSelection) {
      const creator = root.querySelector("[data-knowledge-creator]");
      creator?.focus({ preventScroll: true });
      creator?.setSelectionRange(creatorSelection.start, creatorSelection.end);
    }
    filterResearchModels();
    if (searchSelection) {
      const search = root.querySelector("[data-model-search]");
      if (search) { search.focus({ preventScroll: true }); search.setSelectionRange(searchSelection.start, searchSelection.end); }
    }
    syncDialogFocus(dialogControl);
    window.requestAnimationFrame(() => {
      applyNavigationPanelWidth();
      restoreEditorViewportPosition();
      restoreTreeViewportPositions();
      root.querySelectorAll("[data-list-key]").forEach((list) => {
        const position = listViewportPositions.get(list.dataset.listKey);
        if (position) { list.scrollLeft = position.x; list.scrollTop = position.y; }
      });
      drawTreeConnections();
      placeTreePopovers();
      placeResearchSetup();
      placeResearchModelMenu();
      placeKnowledgeSuggestions();
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
    const modelPick = event.target.closest("button[data-model-pick]");
    if (modelPick) {
      closeResearchModelMenu();
      const modelValue = root.querySelector('[data-form-id="utility-research-form"] [data-field="llmModelIdentifier"]');
      if (modelValue) { modelValue.value = modelPick.dataset.modelPick; queueLiveEdit(modelValue, true); }
      render();
      window.requestAnimationFrame(() => root.querySelector("[data-model-selector]")?.focus({ preventScroll: true }));
      return;
    }
    const pick = event.target.closest("button[data-knowledge-pick]");
    if (pick) {
      const creatorInput = root.querySelector("input[data-knowledge-creator]");
      knowledgeCreatorDraft = pick.dataset.knowledgePick;
      if (creatorInput) creatorInput.value = knowledgeCreatorDraft;
      closeKnowledgeSuggestions(true);
      return;
    }
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
    flushLiveEdits();
    const action = button.dataset.action;
    if (DELETE_KEYS[action] && !confirmDelete(DELETE_KEYS[action](button.dataset))) return;
    if (action === "setClassifierTypePaused") {
      send(action, { typeID: button.dataset.typeId, paused: button.dataset.paused === "true" });
      return;
    }
    if (action === "workspace") {
      const nextWorkspace = button.dataset.workspace;
      if (!state || !workspaceNames.has(nextWorkspace) || state.workspace === nextWorkspace) return;
      closeKnowledgeSuggestions();
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
    if (action === "newType") {
      // Open the create-a-group dialog (there is no direct-create path), with
      // the first classifiable platform no type holds yet ticked.
      const held = new Set((state.assets?.classifierTypes || []).flatMap((type) => type.applicablePlatformIDs || []));
      const free = (state.assets?.collectionPlatforms || []).find((platform) => platform.supportsLocalModel === true && !held.has(platform.id));
      pendingCreateType = { platformIDs: free ? [free.id] : [] };
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
      const name = ((nameInput?.value) || t("createType.defaultName")).trim() || t("createType.defaultName");
      const platformIDs = checkedPlatforms(root.querySelector("[data-create-type-dialog]"));
      if (!platformIDs.length) {
        pendingCreateType.name = name;
        pendingCreateType.issue = true;
        render();
        return;
      }
      pendingSelectNewType = new Set((state.assets?.classifierTypes || []).map((type) => type.id));
      pendingCreateType = null;
      render();
      send("createClassifierType", { name, platformIDs });
      return;
    }
    if (action === "confirmDeleteClassifierType") {
      render();
      send(action, { typeID: button.dataset.typeId });
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

    if (action === "openResearchSetup") { openResearchSetup(); return; }
    if (action === "openUtilityPanel") {
      closeKnowledgeSuggestions();
      researchSetupRequested = false;
      researchSetupFocusPending = false;
      const nextPanel = data.utilityPanel === "settings" ? "settings" : null;
      utilityPanel = utilityPanel === nextPanel ? null : nextPanel;
      render();
      return;
    }
    if (action === "closeUtilityPanel") {
      utilityPanel = null;
      researchSetupRequested = false;
      researchSetupFocusPending = false;
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
      // Confirmed above (click again); its child tags move up to its parent.
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
    if (action === "addKnowledgeCreator") {
      knowledgeCreatorDraft = "";
      closeKnowledgeSuggestions();
    }
    send(action, data);
  });

  function dismissClassifierDialog() {
    if (closeResearchModelMenu(true)) return;
    pendingCreateType = null;
    utilityPanel = null;
    researchSetupRequested = false;
    researchSetupFocusPending = false;
    render();
  }

  scope.addEventListener("keydown", (event) => {
    const menu = event.target.closest?.(".research-model-menu, [data-knowledge-suggestions]")
      || (event.target.matches?.("[data-knowledge-creator]") ? root.querySelector("[data-knowledge-suggestions]") : null);
    if (menu && ["ArrowDown", "ArrowUp"].includes(event.key) && !event.isComposing) {
      const options = [...menu.querySelectorAll("[data-model-pick], [data-knowledge-pick]")].filter((option) => !option.hidden);
      if (options.length) {
        const index = options.indexOf(scope.activeElement);
        const next = index < 0 ? (event.key === "ArrowDown" ? 0 : options.length - 1)
          : (index + (event.key === "ArrowDown" ? 1 : -1) + options.length) % options.length;
        event.preventDefault();
        options[next].focus({ preventScroll: true });
        options[next].scrollIntoView({ block: "nearest" });
      }
      return;
    }
    if (event.key === "Escape" && knowledgeSuggestionsOpen) {
      event.preventDefault();
      closeKnowledgeSuggestions(true);
      return;
    }
    if (event.key !== "Escape" || (!utilityPanel && !pendingCreateType)) return;
    event.preventDefault();
    dismissClassifierDialog();
  });

  scope.addEventListener("toggle", (event) => {
    if (!event.target.isConnected) return;
    const key = event.target.matches?.("details[data-expand]") ? event.target.dataset.expand : null;
    if (key) event.target.open ? openExpands.add(key) : openExpands.delete(key);
    if (event.target.matches?.(".research-model-picker") && event.target.open) {
      window.VaultUI.close();
      placeResearchModelMenu();
      // A snapshot restores the current focus; only a newly opened menu
      // moves focus from its selector into search.
      if (scope.activeElement === event.target.querySelector("summary")) {
        event.target.querySelector("[data-model-search]")?.focus({ preventScroll: true });
      }
    }
  }, true);

  scope.addEventListener("change", (event) => {
    if (event.target.matches('[data-form-id="utility-research-form"] [data-field="llmProviderProfileID"]')) {
      queueLiveEdit(event.target, true);
      render();
      return;
    }
    if (queueLiveEdit(event.target, true)) return;
    const knowledgePlatform = event.target.closest("[data-knowledge-platform]");
    if (knowledgePlatform) {
      knowledgeAddPlatform = knowledgePlatform.value;
      const creatorInput = root.querySelector("input[data-knowledge-creator]");
      if (creatorInput) showKnowledgeSuggestions(creatorInput);
      return;
    }
    const languageControl = event.target.closest("[data-language-selection]");
    if (languageControl) {
      if (!languageChoices.some(([identifier]) => identifier === languageControl.value)) return;
      selectedLanguage = languageControl.value;
      root.lang = selectedLanguage;
      try { window.localStorage.setItem("vaultClassifier.language", selectedLanguage); } catch (_) {}
      return;
    }
    // Preserve creation choices across page re-renders.
    const choice = event.target.closest("input[data-platform-choice]");
    if (choice) {
      const dialog = choice.closest("[data-create-type-dialog]");
      if (dialog && pendingCreateType) {
        pendingCreateType.platformIDs = checkedPlatforms(dialog);
        pendingCreateType.name = root.querySelector("[data-create-type-name]")?.value;
        const hadIssue = pendingCreateType.issue;
        pendingCreateType.issue = false;
        if (hadIssue) render();
      }
      return;
    }
  });

  scope.addEventListener("input", (event) => {
    if (pendingCreateType && event.target.matches("[data-create-type-name]")) {
      pendingCreateType.name = event.target.value;
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
      // Ignore a retired/unknown workspace safely; API keys now live in Settings.
      if (!workspaceNames.has(state.workspace)) state.workspace = "browserBridge";
      // Drop a stale left-panel selection if that type no longer exists.
      const typeIDs = new Set((state.assets?.classifierTypes || []).map((type) => type.id));
      if (selectedTypeID && !typeIDs.has(selectedTypeID)) selectedTypeID = null;
      // Open a just-created type: the one id absent before "New type" was clicked.
      if (pendingSelectNewType) {
        const created = (state.assets?.classifierTypes || []).find((type) => !pendingSelectNewType.has(type.id));
        if (created) { selectedTypeID = created.id; state.workspace = "browserBridge"; }
        pendingSelectNewType = null;
      }
      reconcileLiveEdits();
      render();
    },
  };

  window.addEventListener("resize", () => window.requestAnimationFrame(drawTreeConnections));
  window.VaultUI.observe(scope);
  window.VaultInfo.watch(scope, { enabled: () => selectedLanguage === "en" });
  render();
  send("state", {});
})();
