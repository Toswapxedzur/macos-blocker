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
  const settingsScope = window.VaultSettings.scope;
  const settingsRoot = window.VaultSettings.root;
  const taggingScope = window.VaultSettings.taggingScope || settingsScope;
  const taggingRoot = window.VaultSettings.taggingRoot || settingsRoot;
  const uiScopes = [...new Set([scope, settingsScope, taggingScope])];
  const uiRoots = [...new Set([root, settingsRoot, taggingRoot])];
  const uiQuery = selector => uiRoots.map(node => node.querySelector(selector)).find(Boolean) || null;
  const uiQueryAll = selector => uiRoots.flatMap(node => [...node.querySelectorAll(selector)]);
  const activeControl = () => uiScopes.map(node => node.activeElement).find(Boolean) || null;
  function listen(type, listener, options) { for (const node of uiScopes) node.addEventListener(type, listener, options); }
  const captureSearch = () => uiScopes.map(node => [node, window.VaultUI.captureSearch(node)]);
  function restoreSearch(saved) { for (const [node, focus] of saved) window.VaultUI.restoreSearch(node, focus); }
  let state = null;
  let renderedPresentationRevision = 0;
  let activeTagPanel = null;
  let connectionTab = "chatGPT";
  const KEY_CONNECTIONS = ["openAI", "gemini", "xAI"];
  function selectedTaggingModel(type) {
    if (type.classificationProvider === "apiKey") return type.apiKey?.model ? `api:${type.apiKey.profileID}:${type.apiKey.model}` : "";
    return type.chatGPT?.model ? `${type.chatGPT?.accountID === state.assets?.chatGPT?.accountID ? "chatgpt" : "unavailable"}:${type.chatGPT.model}` : "";
  }
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

  let releaseDialogFocus = null;
  let dialogFocusKind = null;
  // "More" / "Options" expands the user opened: the page re-renders on every update.
  const openExpands = new Set();
  // Which classifier type is open in the left-panel list (client-only UI state).
  let selectedTypeID = null;
  // Set to the pre-create set of type ids when "New type" is clicked, so the
  // next snapshot can open the freshly created type.
  let pendingSelectNewType = null;
  let selectedLanguage = document.documentElement.lang || "en";
  let languageMessages = {};
  let languageRevision = 0;
  let navigationPanelWidth = navigationWidthRange.fallback;
  let navigationResize = null;
  const workspaceNames = new Set(["browserBridge"]);
  let lastRenderedMarkup = null;
  const listViewportPositions = new Map();

  try {
    const storedWidth = Number(window.localStorage.getItem(navigationWidthStorageKey));
    if (Number.isFinite(storedWidth)) {
      navigationPanelWidth = Math.round(Math.min(navigationWidthRange.maximum, Math.max(navigationWidthRange.minimum, storedWidth)));
    }
  } catch (_) {}
  root.lang = selectedLanguage;
  root.dir = selectedLanguage === "ar" ? "rtl" : "ltr";

  function applyNavigationPanelWidth() {
    root.style.setProperty("--navigation-panel-width", `${navigationPanelWidth}px`);
    uiQuery("[data-navigation-resizer]")?.setAttribute("aria-valuenow", String(navigationPanelWidth));
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
    const template = languageMessages["classifier." + key] ?? strings[key];
    if (typeof template !== "string") return key;
    return template.replace(/\{([a-zA-Z0-9_]+)\}/g, (_, name) => String(values[name] ?? ""));
  }

  async function loadSelectedLanguage() {
    const revision = ++languageRevision;
    const language = selectedLanguage = document.documentElement.lang || "en";
    let messages = {};
    try {
      if (window.VaultLoadMessages) messages = await window.VaultLoadMessages(language);
      else {
        const response = await fetch(`translation/${language}.json`);
        if (response.ok) messages = await response.json();
      }
    } catch (_) {}
    if (revision !== languageRevision) return;
    languageMessages = messages;
    for (const node of uiRoots) { node.lang = language; node.dir = language === "ar" ? "rtl" : "ltr"; }
    render();
    for (const node of uiScopes) window.VaultInfo.refresh(node);
  }

  window.VaultClassifierTranslate = (key, values = {}) => {
    const template = languageMessages[key];
    return template ? template.replace(/\{([a-zA-Z0-9_]+)\}/g, (_, name) => String(values[name] ?? "")) : key;
  };
  const tx = (key, values = {}) => esc(t(key, values));
  const sx = (key, fallback) => esc(languageMessages[key] ?? fallback);
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
    const form = uiQuery(`[data-form-id="${formID}"]`);
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

    const key = liveEditKey(form);
    const previous = liveEdits.get(key);
    window.clearTimeout(previous?.timer);
    if (form.dataset.autosaveAction === "saveClassificationProvider" && control.dataset.field === "providerModel") {
      const effort = form.querySelector('[data-field="reasoningEffort"]');
      const options = reasoningChoices(control.value);
      const previousEffort = effort.value;
      effort.innerHTML = options.map(([value,label]) => `<option value="${esc(value)}">${esc(label)}</option>`).join("");
      effort.value = options.some(([value]) => value === previousEffort) ? previousEffort : "default";
    }
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
    for (const [attribute, field] of [["typeId", "typeID"], ["providerId", "profileID"], ["connectionType", "type"],
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
      case "saveClassifierTypeTagging": return type && {
        strictness: String(type.tagging?.strictness ?? 3),
        houseRules: type.tagging?.houseRules || "",
        minimumTagsOverride: type.tagging?.minimumTagsOverride == null ? "" : String(type.tagging.minimumTagsOverride),
        maximumTagsOverride: type.tagging?.maximumTagsOverride == null ? "" : String(type.tagging.maximumTagsOverride),
      };
      case "saveClassificationProvider": return type && { providerModel: selectedTaggingModel(type), reasoningEffort: (type.classificationProvider === "apiKey" ? type.apiKey : type.chatGPT)?.reasoningEffort || (type.classificationProvider === "apiKey" ? "default" : "low") };
      case "saveChatGPTUsageLimit": return { dailyRequestLimit: state.assets?.chatGPT?.dailyRequestLimit == null ? "" : String(state.assets.chatGPT.dailyRequestLimit) };

      case "saveClassificationSettings": return state.settings;
      case "saveBackup": return state.backup;

      case "updateTag": return (assets.trees || []).find((tree) => tree.id === edit.identity.treeID)
        ?.nodes.find((node) => node.id === edit.identity.nodeID);
      case "saveTaggingConnection": {
        const profiles = (assets.providerProfiles || []).filter(item => item.type === edit.identity.type);
        return profiles.length <= 1 ? { credential: profiles[0]?.credential || "" } : null;
      }
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
    if (edit.action === "saveClassifierTypeTagging") {
      const form = uiQuery(`[data-form-id="${CSS.escape(edit.formID)}"]`);
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
    const control = activeControl();
    const form = control?.closest?.("[data-autosave-action]");
    return form && control.matches("[data-field]") ? { key: liveEditKey(form),
      field: control.dataset.field, value: control.value, start: control.selectionStart,
      end: control.selectionEnd, direction: control.selectionDirection } : null;
  }

  function restoreLiveEdits(focused) {
    uiQueryAll("[data-autosave-action]").forEach((form) => {
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
      if (form.dataset.autosaveAction === "saveClassifierTypeTagging") validateTagBounds(form);
    });
  }

  listen("focusout", (event) => {
    if (!replacingControls && !composingEdit) queueLiveEdit(event.target, true);
  });
  listen("compositionstart", (event) => {
    if (event.target.closest?.("[data-autosave-action]")) {
      flushLiveEdits();
      composingEdit = true;
    }
  });
  listen("compositionend", (event) => {
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

    "llm.providerType": "Choose the provider’s API type before adding its configuration. Adding a provider does not create an API key.",
    "llm.apiKeyOrToken": "Paste the credential issued by this provider. Vault uses it to authenticate requests to that provider.",
    "llm.apiEndpoint": "The provider’s API base address. Leave blank to use its default endpoint.",
    "llm.testModel": "The model identifier used by Test connection. Each group selects its tagging model.",
    "llm.protocol.accountID": "The account identifier required by this provider’s API.",
    "llm.protocol.apiVersion": "The API version sent to this provider. Use a version supported by its endpoint.",
    "llm.protocol.clientID": "The application or client identifier issued for this provider’s API.",
    "llm.protocol.location": "The service location used for this provider’s API requests.",
    "llm.protocol.projectID": "The cloud project identifier used for this provider’s API requests.",
    "llm.protocol.region": "The service region used for this provider’s API requests.",
    "llm.protocol.userAgent": "The client identification sent with this provider’s API requests.",
    "llm.protocol.searchEngineID": "The search engine identifier required by this saved provider configuration.",
    "llm.protocol.protocolFamily": "The API format this endpoint accepts. Choose the format supported by the provider.",

    "classification.enabled": "Allow the Classifier to tag content. Individual Classifier groups can still be paused.",

    "backup.auto": "Create a local backup after configuration changes, using the configured backup folder.",

    "tree.nodeName": "The name of this tag in the taxonomy and on tagged content.",
    "tree.tagName": "The name of the tag to add to this Classifier group’s taxonomy."
  });
  function infoAttrs(labelKey, hintKey = "") {
    let text = languageMessages["classifierInfo." + labelKey] || fieldInfo[labelKey] || (hintKey ? t(hintKey) : "");
    if (labelKey === "llm.apiKeyOrToken") text += ` ${t("connections.apiBilling")} ${t("llm.localOnlyDisclosure")}`;
    if (!text) return "";
    const target = labelKey === "bridge.typeName" ? ".classifier-name-row .field"
      : "";
    return `data-info-label="${esc(t(labelKey))}" data-info-key="${esc(labelKey)}" data-info-copy="${esc(text)}"${target ? ` data-info-target="${target}"` : ""}`;
  }

  function field(labelKey, hintKey, key, value, type = "text", extra = "") {
    return `<label class="field"><span class="field-label" ${infoAttrs(labelKey, hintKey)}>${tx(labelKey)}${hintKey ? `<span class="field-hint" data-info> · ${tx(hintKey)}</span>` : ""}</span><input type="${type}" data-field="${esc(key)}" value="${type === "password" && key !== "credential" ? "" : esc(value)}" ${extra}></label>`;
  }

  function textareaField(labelKey, hintKey, key, value, extra = "") {
    return `<label class="field wide"><span class="field-label" ${infoAttrs(labelKey, hintKey)}>${tx(labelKey)}${hintKey ? `<span class="field-hint" data-info> · ${tx(hintKey)}</span>` : ""}</span><textarea data-field="${esc(key)}" ${extra}>${esc(value)}</textarea></label>`;
  }

  function selectField(labelKey, hintKey, key, value, options) {
    return `<label class="field"><span class="field-label" ${infoAttrs(labelKey, hintKey)}>${tx(labelKey)}${hintKey ? `<span class="field-hint" data-info> · ${tx(hintKey)}</span>` : ""}</span><select class="select-control" data-field="${esc(key)}">${options.map(([id, labelKey]) => `<option value="${esc(id)}"${selected(value, id)}>${tx(labelKey)}</option>`).join("")}</select></label>`;
  }

  let deferredChoices = new Map();
  function mountChoices() {
    uiQueryAll("[data-choice-key]").forEach(select => { const choice = deferredChoices.get(select.dataset.choiceKey); if (choice) window.VaultUI.setSelectOptions(select, choice.options, choice.value); });
  }
  function valueSelectField(labelKey, hintKey, key, value, options, extra = "") {
    let choiceKey = "", visible = options;
    if (options.length > 200) { choiceKey = "choice-" + deferredChoices.size; deferredChoices.set(choiceKey, {options, value}); visible = options.filter(([id]) => String(id) === String(value)); if (!visible.length) visible = options.slice(0,1); }
    return `<label class="field"><span class="field-label" ${infoAttrs(labelKey, hintKey)}>${tx(labelKey)}${hintKey ? `<span class="field-hint" data-info> · ${tx(hintKey)}</span>` : ""}</span><select class="select-control" data-field="${esc(key)}" ${choiceKey ? `data-choice-key="${choiceKey}"` : ""} ${extra}>${visible.map(([id, label]) => `<option value="${esc(id)}"${selected(value, id)}>${esc(label)}</option>`).join("")}</select></label>`;
  }

  function multiValueSelectField(labelKey, hintKey, key, values, options, extra = "") {
    const selectedValues = new Set(values || []);
    return `<label class="field"><span class="field-label" ${infoAttrs(labelKey, hintKey)}>${tx(labelKey)}${hintKey ? `<span class="field-hint" data-info> · ${tx(hintKey)}</span>` : ""}</span><select class="select-control multi-select-control" data-field="${esc(key)}" multiple ${extra}>${options.map(([id, label]) => `<option value="${esc(id)}"${selectedValues.has(id) ? " selected" : ""}>${esc(label)}</option>`).join("")}</select></label>`;
  }

  function toggle(labelKey, key, value, extra = "") {
    return `<label class="toggle-row"><input type="checkbox" data-field="${esc(key)}"${checked(value)} ${extra}><span ${infoAttrs(labelKey)}>${tx(labelKey)}</span></label>`;
  }

  function notice(text, tone = "navy") {
    return text ? `<div class="notice ${esc(tone)}">${esc(window.VaultNoticeLanguage ? window.VaultNoticeLanguage(text, t) : text)}</div>` : "";
  }

  // Every elapsed or remaining duration uses HH:MM:SS.
  function formatDuration(totalSeconds) {
    const seconds = Math.max(0, Math.floor(Number(totalSeconds) || 0));
    return [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60]
      .map((part) => String(part).padStart(2, "0")).join(":");
  }

  // Research lane status: live queue counters + the durable cooldown picture,
  // plus the user's escape hatch when a provider was down ("retry now").

  function statusPill(title, tone = "navy") {
    return `<span class="status-pill ${esc(tone)}">${esc(title)}</span>`;
  }

  function header(titleKey, copyKey, badge, tone = "navy") {
    return `<div class="workspace-head"><div><h2>${tx(titleKey)}</h2><p class="section-copy" data-info>${tx(copyKey)}</p></div>${statusPill(badge, tone)}</div>`;
  }

  const STRICTNESS_POSITIONS = [1, 2, 3, 4, 5];

  // Five positions from Strictest to Broadest, each with what it does.
  function strictnessOptions(selected, groupID) {
    return `<div class="strictness-options" role="radiogroup" aria-label="${esc(t("localModel.strictness"))}">${STRICTNESS_POSITIONS.map((position) => {
      const active = Number(selected) === position;
      return `<label class="strictness-option${active ? " active" : ""}"><input type="radio" name="strictness-${esc(groupID)}" data-field="strictness" value="${position}"${active ? " checked" : ""}><span class="strictness-option-name">${position} · ${tx(`localModel.strictness.${position}.name`)}</span><span class="strictness-option-desc" data-info>${tx(`localModel.strictness.${position}.desc`)}</span></label>`;
    }).join("")}</div>`;
  }

  // Read only acknowledged native state: a draft key/model is not ready yet.

  // Keep the menu inside the Settings dialog for its focus trap, but out of
  // layout flow. It uses the same white floating card as the shared selects.

  function placeClassifierMenu(anchor, menu) {
    window.VaultUI.showMenuLayer(menu);
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

  document.addEventListener("scroll", () => {   }, true);
  window.addEventListener("resize", () => {   });

  function chatGPTAccountSection() {
    const account = state.assets?.chatGPT || {};
    const busy = account.signingIn === true;
    return `<section class="utility-settings-section" data-chatgpt-account><p class="small-copy">${account.connected ? esc(account.email || t("cloud.connected")) : tx("cloud.disconnected")}</p><p class="small-copy" data-info>${tx("cloud.disclosure")}</p><div class="action-row">${busy ? `<span role="status">${tx("cloud.signingIn")}</span><button type="button" class="secondary" data-action="cancelChatGPTSignIn">${tx("cloud.cancel")}</button>` : `<button type="button" class="secondary" data-action="connectChatGPT">${tx("cloud.connect")}</button>`}${account.connected ? `<button type="button" class="secondary" data-action="refreshChatGPTModels">${tx("cloud.refreshModels")}</button><button type="button" class="secondary" data-action="disconnectChatGPT">${tx("cloud.disconnect")}</button>` : ""}</div>${account.connected && !account.planUsageEnabled ? `<p role="alert">${tx("cloud.planRequired")}</p>` : ""}${notice(account.issue, "red")}<div data-form-id="chatgpt-limit-form" data-autosave-action="saveChatGPTUsageLimit">${field("cloud.dailyLimit", "cloud.dailyLimitHint", "dailyRequestLimit", account.dailyRequestLimit ?? "", "number", 'min="1" max="100000" step="1"')}</div><p class="small-copy">${tx("cloud.requestsToday", {count: account.requestsToday || 0})}</p>${account.connected ? `<button type="button" class="${account.needsRetry ? "primary" : "secondary"}" data-action="openChatGPTUsage">${tx("cloud.manageUsage")}</button>` : ""}${account.needsRetry || account.failedItems ? `<button type="button" class="secondary" data-action="retryChatGPTClassifications">${tx("cloud.retry")}</button>` : ""}</section>`;
  }

  function reasoningChoices(model) {
    const levels = state.assets?.classificationModelCapabilities?.[model]?.reasoningEfforts || ["default", "low", "medium", "high"];
    return levels.map(value => [value, t(`cloud.reasoning.${value}`)]);
  }
  function cloudProviderSection(type) {
    const account = state.assets?.chatGPT || {};
    const selected = selectedTaggingModel(type);
    const choices = [["", t("cloud.chooseModel")]];
    if (account.planUsageEnabled) (account.models || []).forEach(model => {
      if (state.assets?.classificationModelCapabilities?.[`chatgpt:${model.id}`]?.searchCompatible !== false) choices.push([`chatgpt:${model.id}`, `${t("connections.subscription")} · ${model.name}`]);
    });
    for (const profile of state.assets?.providerProfiles || []) {
      if (!KEY_CONNECTIONS.includes(profile.type) || !profile.hasCredential) continue;
      for (const model of state.assets?.providerModelCatalogs?.[profile.id] || []) {
        const id = model.id || model.identifier || model;
        if (state.assets?.classificationModelCapabilities?.[`api:${profile.id}:${id}`]?.searchCompatible !== false) choices.push([`api:${profile.id}:${id}`, `${profile.name} · ${id}`]);
      }
    }
    const configuration = type.classificationProvider === "apiKey" ? type.apiKey : type.chatGPT;
    if (!choices.some(([value]) => value === selected)) choices.push([selected, `${configuration?.model || ""} · ${t("cloud.unavailable")}`]);
    const configured = Boolean(configuration?.model);
    const effort = configuration?.reasoningEffort || (type.classificationProvider === "apiKey" ? "default" : "low");
    const efforts = reasoningChoices(selected);
    if (!efforts.some(([value]) => value === effort)) efforts.push([effort, `${t(`cloud.reasoning.${effort}`)} · ${t("cloud.unavailable")}`]);
    const retry = account.needsRetry || account.failedItems || state.assets?.apiKeyClassification?.failedProfileIDs?.length;
    return `<section class="classifier-type-section" data-form-id="cloud-provider-${esc(type.id)}" data-autosave-action="saveClassificationProvider" data-type-id="${esc(type.id)}">${valueSelectField("cloud.provider", "", "providerModel", selected, choices)}${valueSelectField("cloud.reasoning", "cloud.reasoningHint", "reasoningEffort", effort, efforts)}<div class="action-row"><button type="button" class="secondary" data-action="openConnections">${tx("connections.manage")}</button>${retry ? `<button type="button" class="secondary" data-action="retryChatGPTClassifications">${tx("cloud.retry")}</button>` : ""}</div>${configured ? `<p class="small-copy">${tx(type.classificationProvider === "apiKey" ? "connections.apiBilling" : "cloud.usingPlan")}</p><p class="small-copy" data-search-always>${tx("cloud.searchAlways")}</p>` : ""}</section>`;
  }

  function connectionsSection() {
    const options = [["chatGPT","connections.subscription"],["openAI","connections.openAI"],["gemini","connections.gemini"],["xAI","connections.grok"]];
    return `<div data-tagging-connections>${selectField("connections.title", "", "connectionType", connectionTab, options)}${connectionTab === "chatGPT" ? chatGPTAccountSection() : apiKeySettings(connectionTab)}</div>`;
  }

  function nativeTaggingContent() {
    if (utilityPanel !== "settings" || !state) return "";
    const settings = state.settings;
    return `<section class="utility-settings-section" data-form-id="classification-settings-form" data-autosave-action="saveClassificationSettings"><h3 class="utility-settings-section-title">${tx("classification.title")}</h3><div class="utility-toggles">${toggle("classification.enabled", "classificationEnabled", settings.classificationEnabled !== false)}</div><p class="section-copy" data-info>${tx("classification.copy")}</p></section>`;
  }

  function nativeConnectionsContent() {
    if (utilityPanel !== "settings" || !state) return "";
    return `${notice(state.issue, "red")}${connectionsSection()}`;
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
      `;
  }

  function shell(content) {
    return `<div class="popup">
      <header class="vui-topbar">
        <nav class="vui-tabs" aria-label="${sx("activity.scene", "Scene")}"><button type="button" class="vui-tab" data-scene="vault">${sx("scene.vault", "Vault")}</button><button type="button" class="vui-tab is-active" data-scene="classifier">${sx("scene.classifier", "Classifier")}</button><button type="button" class="vui-tab" data-scene="activity">${sx("scene.activity", "Activity")}</button></nav>
        <div class="vui-topbar-links"><button type="button" class="secondary" data-action="openManual">${sx("manual.title", "User manual")}</button><span class="settings-popover-anchor"><button type="button" class="secondary" data-action="openUtilityPanel" data-utility-panel="settings" aria-haspopup="dialog" aria-expanded="${utilityPanel ? "true" : "false"}">${tx("utility.settings.button")}</button></span></div>
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
    return `<div class="popup"><header class="vui-topbar"><nav class="vui-tabs" aria-label="${sx("activity.scene", "Scene")}"><button type="button" class="vui-tab" data-scene="vault">${sx("scene.vault", "Vault")}</button><button type="button" class="vui-tab is-active" data-scene="classifier">${sx("scene.classifier", "Classifier")}</button><button type="button" class="vui-tab" data-scene="activity">${sx("scene.activity", "Activity")}</button></nav></header><div class="layout" aria-busy="true"></div></div>`;
  }

  function syncDialogFocus(previousControl) {
    const kind = state?.assets?.chatGPT?.needsWelcome ? "welcome" : pendingCreateType ? "create" : null;
    releaseDialogFocus?.(false);
    releaseDialogFocus = null;
    if (!kind) {
      if (dialogFocusKind) uiQuery(dialogFocusKind === "create"
        ? '[data-action="newType"]' : '[data-action="openUtilityPanel"]')?.focus({ preventScroll: true });
      dialogFocusKind = null;
      return;
    }
    dialogFocusKind = kind;
    const card = uiQuery(kind === "welcome" ? "[data-chatgpt-welcome]" : kind === "create" ? "[data-create-type-dialog]" : '.utility-popover[role="dialog"]');
    if (!card) return;
    const active = activeControl();
    const initial = card.contains(active) ? active : previousControl
      ? Array.from(card.querySelectorAll("button, input, select, textarea")).find((control) =>
        control.dataset.action === previousControl.action && control.dataset.field === previousControl.field
        && control.hasAttribute("data-create-type-name") === previousControl.createName
        && (!previousControl.platform || control.value === previousControl.platform)) : null;
    releaseDialogFocus = window.VaultUI.focusDialog(card, {
      initialFocus: initial || card.querySelector(kind === "welcome" ? '[data-action="acknowledgeChatGPTPlan"]' : kind === "create" ? "[data-create-type-name]" : '[data-action="closeUtilityPanel"]'),
      returnFocus: () => uiQuery(kind === "create" ? '[data-action="newType"]' : '[data-action="openUtilityPanel"]'),
      onEscape: kind === "welcome" ? () => send("acknowledgeChatGPTPlan") : dismissClassifierDialog
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
  const graphModels = new Map();
  function mountLargeGraphs() {
    for (const map of uiQueryAll("[data-tree-map]")) {
      const model = graphModels.get(map.dataset.treeId);
      if (!model || model.nodes.length <= 200) continue;
      window.VaultUI.bindFind(map, { items: model.nodes, id: node => node.id,
        text: node => node.name + " " + (node.description || ""),
        matches(ids) { model.matches = ids; paintLargeGraph(map); },
        locate(node) {
          const point = model.positions.get(node.id);
          map.scrollLeft = Math.max(0, point.x - (map.clientWidth - 126) / 2);
          map.scrollTop = Math.max(0, point.y - (map.clientHeight - 22) / 2);
          paintLargeGraph(map);
        } });
      if (!map.__graphScrollBound) {
        map.__graphScrollBound = true;
        let scheduled = false;
        map.addEventListener("scroll", () => {
          if (scheduled) return; scheduled = true;
          requestAnimationFrame(() => { scheduled = false; paintLargeGraph(map); });
        }, { passive: true });
      }
      paintLargeGraph(map);
    }
  }
  function paintLargeGraph(map) {
    if (tagDrag?.treeID === map.dataset.treeId) return;
    const model = graphModels.get(map.dataset.treeId), layer = map.querySelector(".tree-node-layer");
    if (!model || !layer) return;
    const left = Math.max(0, map.scrollLeft - 180), top = Math.max(0, map.scrollTop - 100);
    const right = map.scrollLeft + (map.clientWidth || 900) + 180, bottom = map.scrollTop + (map.clientHeight || 350) + 100;
    const visible = new Set();
    for (let x = Math.floor(left / 256); x <= Math.floor(right / 256); x++) for (let y = Math.floor(top / 256); y <= Math.floor(bottom / 256); y++) {
      for (const node of model.cells.get(x + ":" + y) || []) {
        const point = model.positions.get(node.id);
        if (point.x + 126 >= left && point.x <= right && point.y + 22 >= top && point.y <= bottom) visible.add(node.id);
      }
    }
    const active = activeControl()?.closest?.(".tree-map-node");
    if (active?.dataset.treeId === map.dataset.treeId) visible.add(active.dataset.nodeId);
    const existing = new Map([...layer.children].map(row => [row.dataset.nodeId, row]));
    for (const [id, row] of existing) if (!visible.has(id)) row.remove();
    for (const id of visible) {
      let row = existing.get(id);
      const markup = model.markup(model.nodeByID.get(id));
      if (!row || row.__graphMarkup !== markup) {
        const template = document.createElement("template"); template.innerHTML = markup;
        const next = template.content.firstElementChild; next.__graphMarkup = markup;
        const focused = row === activeControl();
        if (row) row.replaceWith(next); else layer.append(next);
        row = next; if (focused) row.focus({ preventScroll: true });
      }
      row.classList.toggle("vui-search-match", model.matches.has(id));
    }
    drawTreeConnections();
  }

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
      const contentWidth = [...positions.values()].reduce((max, position) => Math.max(max, position.x + 126), 0) + 28;
      const contentHeight = Math.max(240, [...positions.values()].reduce((max, position) => Math.max(max, position.y + 22), 0) + 28,
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
          isEdit ? popoverNode.name : panelState.draft?.name || "",
          "text",
          isEdit ? `data-live-tag-name data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}"` : ""
        );
        const descriptionField = textareaField(
          "tree.tagDescription",
          "tree.tagDescriptionCopy",
          "description",
          isEdit ? popoverNode.description || "" : panelState.draft?.description || "",
          "maxlength=\"1024\""
        );
        const actions = isEdit
          ? `<button class="secondary" data-action="beginConnection" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}">${tx("tree.connection")}</button><button class="secondary" data-action="disconnectTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}"${disabled(!popoverNode.parentID)}>${tx("tree.disconnection")}</button><button class="danger" data-action="deleteTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(nodeID)}">${deleteLabel(`tag:${nodeID}`, tx("tree.deleteNode"))}</button>`
          : `<button class="primary" data-action="addTag" data-form="tag-popover-form" data-tree-id="${esc(tree.id)}">${tx("tree.createNode")}</button>`;
        // Placed beside its anchor, inside the visible part (placeTreePopovers).
        return `<section class="tree-popover" data-anchor-x="${panelState.x}" data-anchor-y="${panelState.y}" data-anchor-w="${panelState.w || 0}" data-tree-popover data-form-id="tag-popover-form" data-tree-id="${esc(tree.id)}"${isEdit ? ` data-autosave-action="updateTag" data-node-id="${esc(nodeID)}"` : ""}><div class="tree-popover-head"><span class="eyebrow">${tx(isEdit ? "tree.editNode" : "tree.createNode")}</span><button class="tree-popover-close" data-action="cancelTagPanel" data-hint="${tx("tree.cancel")}" aria-label="${tx("tree.cancel")}">×</button></div><div class="tree-form">${nameField}${descriptionField}<div class="action-row">${actions}</div></div></section>`;
      })() : "";
      const nodeMarkup = node => {
        const position = positions.get(node.id);
        const colorStyle = tagColorStyle(node);
        return `<button class="tree-map-node${panelState?.nodeID === node.id || selectedNodeID === node.id ? " active" : ""}${connectionState?.nodeID === node.id ? " connection-source" : ""}${node.retired ? " retired" : ""}" style="left:${position.x}px;top:${position.y}px;${colorStyle}" data-vui-search-text="${esc(node.name + " " + (node.description || ""))}" data-action="selectTag" data-tree-id="${esc(tree.id)}" data-node-id="${esc(node.id)}" data-parent-id="${esc(node.parentID || "")}" data-position-x="${position.x}" data-position-y="${position.y}" data-hint="${tx("tree.contextHint")}"><span aria-hidden="true"></span><strong>${esc(node.name)}</strong></button>`;
      };
      const cells = new Map();
      if (nodes.length > 200) for (const node of nodes) {
        const point = positions.get(node.id), key = Math.floor(point.x / 256) + ":" + Math.floor(point.y / 256);
        if (!cells.has(key)) cells.set(key, []); cells.get(key).push(node);
      }
      const edges = [], edgeCells = new Map();
      if (nodes.length > 200) for (const node of nodes) {
        const start = positions.get(node.parentID), end = positions.get(node.id);
        if (!start || node.parentID === node.id) continue;
        const sx = start.x + 63, sy = start.y + 22, ex = end.x + 63, ey = end.y, bend = Math.round((sy + ey) / 2);
        const index = edges.length; edges.push(`M ${sx} ${sy} V ${bend} H ${ex} V ${ey}`);
        // Index the three segments, including links whose endpoints are both off screen.
        for (const [x1,y1,x2,y2] of [[sx,sy,sx,bend],[sx,bend,ex,bend],[ex,bend,ex,ey]]) {
          for (let x = Math.floor(Math.min(x1,x2)/256); x <= Math.floor(Math.max(x1,x2)/256); x++) for (let y = Math.floor(Math.min(y1,y2)/256); y <= Math.floor(Math.max(y1,y2)/256); y++) {
            const key = x + ":" + y; if (!edgeCells.has(key)) edgeCells.set(key, new Set()); edgeCells.get(key).add(index);
          }
        }
      }
      graphModels.set(tree.id, { nodes, nodeByID, positions, cells, edges, edgeCells, markup: nodeMarkup, matches: graphModels.get(tree.id)?.matches || new Set() });
      const map = `<div class="tree-map" data-vui-search="tree:${esc(tree.id)}" data-vui-search-label="Find tag" data-vui-search-mode="find" data-vui-search-items=".tree-map-node" data-tree-map data-tree-id="${esc(tree.id)}">${connectionState ? `<div class="tree-connection-mode">${tx("tree.connectionHint")}</div>` : ""}<div class="tree-map-content" style="width:max(${contentWidth}px, 100%);height:${contentHeight}px"><svg class="tree-links" aria-hidden="true"></svg><div class="tree-node-layer">${nodes.length > 200 ? "" : nodes.map(nodeMarkup).join("")}</div>${nodes.length ? "" : `<div class="tree-map-empty">${tx("tree.empty")}</div>`}${popover}</div></div>`;
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
    uiQueryAll("[data-tree-map]").forEach((map) => {
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

  let pendingLists = [];
  function listPlaceholder(key, items, render, text, pageSize = 12) {
    pendingLists.push({ key, items, render, text, pageSize });
    return "";
  }
  function mountLists() {
    for (const options of pendingLists) {
      const list = [...uiQueryAll("[data-vui-search]")].find(list => list.dataset.vuiSearch === options.key);
      if (!list) continue;
      let focused = null;
      window.VaultUI.renderList(list, { ...options, scope, beforePaint() { focused = captureLiveEditFocus(); }, afterPaint() {
        restoreLiveEdits(focused);
        window.VaultUI.enhance(list);
      } });
    }
  }

  function apiKeySettings(connectionType) {
    const profiles = (state.assets.providerProfiles || []).filter(profile => profile.type === connectionType);
    const profile = profiles.length === 1 ? profiles[0] : null;
    const conflict = profiles.length > 1;
    const id = profile?.id || "";
    const error = conflict ? t("connections.duplicateKeys") : state.assets.providerModelCatalogErrors?.[id];
    const loading = (state.assets.loadingProviderModelProfileIDs || []).includes(id);
    const count = (state.assets.providerModelCatalogs?.[id] || []).length;
    return `<section class="tagging-key-fields" data-tagging-key-fields data-form-id="tagging-key-${esc(connectionType)}" data-autosave-action="saveTaggingConnection" data-connection-type="${esc(connectionType)}">${field("llm.apiKeyOrToken", "", "credential", profile?.credential || "", "password", `autocapitalize="off" spellcheck="false"${disabled(conflict)}`)}<div class="action-row"><button type="button" class="secondary" data-action="probeProviderModelCatalog" data-profile-id="${esc(id)}"${disabled(!profile?.hasCredential || loading || conflict)}>${tx(loading ? "research.fetchingModels" : error ? "research.retryModels" : count ? "research.refreshModels" : "research.fetchModels")}</button>${count ? `<span class="small-copy">${tx("connections.modelCount", {count})}</span>` : ""}</div>${notice(error,"red")}</section>`;
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
      const tagging = classifierType.tagging || { strictness: 3, houseRules: "" };
      const taggingFormID = `classifier-tagging-form-${classifierType.id}`;
      const defaultMinimum = tagging.strictness === 5 ? 1 : 0;
      const defaultMaximum = tagging.strictness === 1 ? 1 : 3;
      const boundsSummary = tagging.minimumTagsOverride != null || tagging.maximumTagsOverride != null
        ? t("bridge.tagBounds.custom", { minimum: tagging.minimumTagsOverride ?? defaultMinimum, maximum: tagging.maximumTagsOverride ?? defaultMaximum })
        : t("bridge.tagBounds.default");
      const expandKey = `type-more:${classifierType.id}`;
      const taggingSection = `<section class="classifier-type-section classifier-tagging" data-tagging-section><div class="section-header"><div><h3>${tx("cloud.tagging")}</h3></div></div><div class="field wide"><span class="field-label">${tx("localModel.strictness")}<span class="field-hint" data-info> · ${tx("localModel.strictnessHint")}</span></span>${strictnessOptions(tagging.strictness, classifierType.id)}${tagging.minimumTagsOverride != null || tagging.maximumTagsOverride != null ? `<p class="small-copy" data-info="bridge.tagBounds.precedence">${tx("bridge.tagBounds.precedence")}</p>` : ""}</div>${textareaField("bridge.localModelHouseRules", "bridge.localModelHouseRulesCopy", "houseRules", tagging.houseRules, 'rows="4" maxlength="4000"')}</section>`;
      const tagBoundsSection = `<details class="vui-expand classifier-group-more" data-expand="${esc(expandKey)}"${openExpands.has(expandKey) ? " open" : ""}><summary><span>${tx("navigation.more")}</span><span class="small-copy classifier-override-summary">${esc(boundsSummary)}</span></summary><section class="classifier-type-section"><p class="section-copy" data-info data-tag-bounds-defaults>${tx("bridge.tagBounds.copy", { minimum: defaultMinimum, maximum: defaultMaximum })}</p><div class="utility-settings-fields">${field("bridge.tagBounds.minimum", "bridge.tagBounds.minimumHint", "minimumTagsOverride", tagging.minimumTagsOverride ?? "", "number", `min="0" max="3" step="1" placeholder="${defaultMinimum}"`)}${field("bridge.tagBounds.maximum", "bridge.tagBounds.maximumHint", "maximumTagsOverride", tagging.maximumTagsOverride ?? "", "number", `min="1" max="3" step="1" placeholder="${defaultMaximum}"`)}</div><p class="notice red" data-tag-bounds-error role="status" hidden>${tx("bridge.tagBounds.error")}</p></section></details>`;

      return `<section class="classifier-type-panel" data-form-id="${esc(formID)}" data-type-id="${esc(classifierType.id)}" data-autosave-action="configureClassifierType">
        <div class="classifier-name-row">${field("bridge.typeName", "", "name", classifierType.name, "text", 'maxlength="128"')}</div>
        <section class="classifier-type-section classifier-applicable-platform-section"><span class="field-label" ${infoAttrs("bridge.applicablePlatform")}>${tx("bridge.applicablePlatform")}</span>${platformChoices(chosen, classifierType.id)}<p class="small-copy" data-info="bridge.platformsFixed">${tx("bridge.platformsFixed")}</p>${platformNotes.map((note) => `<p class="small-copy">${esc(note)}</p>`).join("")}</section>
        <div class="action-row classifier-tagging-control"><button type="button" class="secondary" data-action="setClassifierTypePaused" data-type-id="${esc(classifierType.id)}" data-paused="${classifierType.isPaused !== true}">${tx(classifierType.isPaused === true ? "classification.resume" : "classification.pause")}</button>${statusPill(tx(classifierType.isPaused === true ? "classification.paused" : state.settings?.classificationEnabled === false ? "classification.disabled" : "classification.active"), classifierType.isPaused === true || state.settings?.classificationEnabled === false ? "muted" : "cyan")}</div>
        <p class="small-copy" data-info="bridge.autoSave">${tx("bridge.autoSave")}</p>
        ${cloudProviderSection(classifierType)}
        <div data-form-id="${esc(taggingFormID)}" data-autosave-action="saveClassifierTypeTagging" data-type-id="${esc(classifierType.id)}">
          ${taggingSection}
          ${tagBoundsSection}
        </div>

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


  // Each platform and Terms share the standard per-list search. Keep names,
  // identifiers and the currently edited description searchable without a render.

  // "Add a creator" suggestions: creators already collected on the chosen
  // platform whose name contains what is typed.

  const DELETE_KEYS = {
    confirmDeleteProviderProfile: (data) => `provider:${data.profileId}`,
    deleteTag: (data) => `tag:${data.nodeId}`,
    confirmDeleteClassifierType: (data) => `type:${data.typeId}`,

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

      default: return browserBridgeWorkspace();
    }
  }

  function drawTreeConnections() {
    uiQueryAll("[data-tree-map]").forEach((map) => {
      const content = map.querySelector(".tree-map-content");
      const links = map.querySelector(".tree-links");
      if (!content || !links) return;

      const contentRect = content.getBoundingClientRect();
      const width = Math.ceil(content.offsetWidth);
      const height = Math.ceil(content.scrollHeight);
      links.setAttribute("viewBox", `0 0 ${width} ${height}`);
      links.setAttribute("width", width);
      links.setAttribute("height", height);

      const model = graphModels.get(map.dataset.treeId);
      if (model?.nodes.length > 200 && tagDrag?.treeID !== map.dataset.treeId) {
        const visibleEdges = new Set();
        for (let x = Math.floor(map.scrollLeft / 256); x <= Math.floor((map.scrollLeft + map.clientWidth) / 256); x++) for (let y = Math.floor(map.scrollTop / 256); y <= Math.floor((map.scrollTop + map.clientHeight) / 256); y++) for (const edge of model.edgeCells.get(x + ":" + y) || []) visibleEdges.add(edge);
        links.innerHTML = `<path d="${[...visibleEdges].map(index => model.edges[index]).join(" ")}"/>`;
        return;
      }
      const nodesByID = new Map([...content.querySelectorAll(".tree-map-node")].map((node) => [node.dataset.nodeId, node]));
      links.innerHTML = [...nodesByID.values()].map((node) => {
        const parent = node.dataset.parentId ? nodesByID.get(node.dataset.parentId) : null;
        const model = graphModels.get(map.dataset.treeId);
        if (!parent && model?.nodes.length > 200 && model.positions.has(node.dataset.parentId)) {
          const start = model.positions.get(node.dataset.parentId), end = model.positions.get(node.dataset.nodeId);
          const bend = Math.round((start.y + 22 + end.y) / 2);
          return `<path d="M ${start.x + 63} ${start.y + 22} V ${bend} H ${end.x + 63} V ${end.y}"/>`;
        }
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
    uiQueryAll(".tree-map-node").forEach((node) => {
      if (node.dataset.treeId === treeID && node.dataset.nodeId === nodeID) {
        node.querySelector("strong").textContent = name;
      }
    });
  }

  function openTagEditor(treeID, nodeID) {
    const node = [...uiQueryAll(".tree-map-node")].find((candidate) => candidate.dataset.treeId === treeID && candidate.dataset.nodeId === nodeID);
    if (!node) return;
    selectedTagNode = { treeID, nodeID };
    const nodeX = Number(node.dataset.positionX) || 0;
    const nodeY = Number(node.dataset.positionY) || 0;
    activeTagPanel = { kind: "edit", treeID, nodeID, x: nodeX, y: nodeY, w: node.offsetWidth };
    render();
  }

  listen("input", (event) => {
    if (!event.isComposing) queueLiveEdit(event.target);
    const input = event.target.closest("input[data-live-tag-name]");
    if (!input) return;
    const { treeId: treeID, nodeId: nodeID } = input.dataset;
    if (treeID && nodeID) updateRenderedTagName(treeID, nodeID, input.value);
  });

  function rememberTreeViewportPositions() {
    uiQueryAll("[data-tree-map]").forEach((map) => {
      treeViewportPositions.set(map.dataset.treeId, { x: map.scrollLeft, y: map.scrollTop });
    });
  }

  function restoreTreeViewportPositions() {
    uiQueryAll("[data-tree-map]").forEach((map) => {
      const position = treeViewportPositions.get(map.dataset.treeId);
      if (!position) return;
      map.scrollLeft = position.x;
      map.scrollTop = position.y;
    });
  }

  function rememberEditorViewportPosition() {
    const editor = uiQuery("[data-editor-panel]");
    const workspace = editor?.dataset.workspace;
    if (!editor || !workspace) return;
    editorViewportPositions.set(workspace, { x: editor.scrollLeft, y: editor.scrollTop });
  }

  function restoreEditorViewportPosition() {
    const editor = uiQuery("[data-editor-panel]");
    const workspace = editor?.dataset.workspace;
    const position = workspace ? editorViewportPositions.get(workspace) : null;
    if (!editor || !position) return;
    editor.scrollLeft = position.x;
    editor.scrollTop = position.y;
  }

  // Create-a-group dialog: platform and name. The new group follows the global
  // dials and house rules until given its own.
  function createTypeModal() {
    if (!pendingCreateType) return "";
    return `<div class="utility-popover-layer" role="presentation"><button class="utility-popover-dismiss" data-action="cancelCreateType" aria-label="${tx("common.cancel")}"></button><div class="deletion-dialog create-type-dialog" role="dialog" aria-modal="true" aria-label="${tx("createType.title")}" data-create-type-dialog><h3>${tx("createType.title")}</h3><p class="section-copy" data-info>${tx("createType.copy")}</p><div class="field"><span class="field-label" ${infoAttrs("createType.platformLabel")}>${tx("createType.platformLabel")}</span>${platformChoices(pendingCreateType.platformIDs || [], null)}${pendingCreateType.issue ? notice(t("createType.platformRequired"), "red") : ""}</div><label class="field"><span class="field-label" ${infoAttrs("createType.nameLabel")}>${tx("createType.nameLabel")}</span><input type="text" data-create-type-name autocomplete="off" spellcheck="false" value="${esc(pendingCreateType.name != null ? pendingCreateType.name : t("createType.defaultName"))}"></label><div class="action-row"><button class="secondary" data-action="cancelCreateType">${tx("common.cancel")}</button><button class="primary" data-action="confirmCreateType">${tx("createType.create")}</button></div></div></div>`;
  }

  function chatGPTWelcome() {
    if (!state?.assets?.chatGPT?.needsWelcome) return "";
    return `<div class="utility-popover-layer" role="presentation"><div class="deletion-dialog" role="dialog" aria-modal="true" aria-label="${tx("cloud.welcomeTitle")}" data-chatgpt-welcome><h3>${tx("cloud.welcomeTitle")}</h3><p>${tx("cloud.welcomeCopy")}</p><div class="action-row"><button type="button" class="primary" data-action="acknowledgeChatGPTPlan">${tx("cloud.gotIt")}</button></div></div></div>`;
  }

  function render() {
    if (!state) {
      root.innerHTML = initialShell();
      lastRenderedMarkup = null;
      return;
    }
    if (composingEdit) return;
    if (state?.assets?.chatGPT?.needsWelcome && window.VaultSettings?.isOpen()) { window.VaultSettings.close(); return; }
    // A new tag is an explicit action, so its fields are not autosave edits.
    // Keep that pending draft when downloads or other snapshots redraw the UI.
    const tagForm = uiQuery("[data-tree-popover]");
    if (activeTagPanel?.kind === "create" && tagForm?.dataset.treeId === activeTagPanel.treeID) {
      activeTagPanel.draft = collect("tag-popover-form");
    }
    pendingLists = []; deferredChoices = new Map();
    const markup = shell(workspace()) + createTypeModal() + chatGPTWelcome();
    const settingsMarkup = nativeConnectionsContent();
    const taggingMarkup = nativeTaggingContent();
    // Nothing changed on the page: keep the DOM (and its scroll) as it is.
    if (markup === lastRenderedMarkup && settingsMarkup === settingsRoot.__markup && taggingMarkup === taggingRoot.__markup && root.firstChild) {
      const searchFocus = captureSearch(), focused = captureLiveEditFocus();
      replacingControls = true;
      mountChoices(); mountLists(); mountLargeGraphs();
      restoreLiveEdits(focused);
      replacingControls = false;
      restoreSearch(searchFocus);
      return;
    }
    renderFull(markup, settingsMarkup, taggingMarkup);
  }

  function renderFull(markup, settingsMarkup, taggingMarkup) {
    rememberTreeViewportPositions();
    rememberEditorViewportPosition();
    uiQueryAll("[data-list-key]").forEach((list) => {
      listViewportPositions.set(list.dataset.listKey, { x: list.scrollLeft, y: list.scrollTop });
    });
    const listSearchFocus = captureSearch();
    const focused = captureLiveEditFocus();

    const active = activeControl();
    const pendingTagFocus = activeTagPanel?.kind === "create" && active?.closest?.("[data-tree-popover]") && active.matches("[data-field]")
      ? { field: active.dataset.field, start: active.selectionStart, end: active.selectionEnd, direction: active.selectionDirection } : null;
    const toolbarAction = active?.closest?.('.vui-topbar-links') ? active.dataset.action : null;
    const dialogControl = active?.closest?.('[role="dialog"]') ? {
      action: active.dataset.action, field: active.dataset.field,
      createName: active.hasAttribute("data-create-type-name"),
      platform: active.hasAttribute("data-platform-choice") ? active.value : null,
      start: active.selectionStart, end: active.selectionEnd
    } : null;
    replacingControls = true;
    root.innerHTML = markup;
    settingsRoot.innerHTML = settingsMarkup;
    settingsRoot.__markup = settingsMarkup;
    taggingRoot.innerHTML = taggingMarkup;
    taggingRoot.__markup = taggingMarkup;
    mountChoices(); mountLists();
    restoreLiveEdits(focused);
    if (pendingTagFocus) {
      const control = uiQuery(`[data-tree-popover] [data-field="${CSS.escape(pendingTagFocus.field)}"]`);
      control?.focus({ preventScroll: true });
      if (control && pendingTagFocus.start != null) control.setSelectionRange(pendingTagFocus.start, pendingTagFocus.end, pendingTagFocus.direction);
    }
    replacingControls = false;
    lastRenderedMarkup = markup;
    bindTreeMapWheel();
    mountLargeGraphs();

    syncDialogFocus(dialogControl);
    if (toolbarAction) uiQuery(`.vui-topbar-links [data-action="${toolbarAction}"]`)?.focus({ preventScroll: true });
    restoreSearch(listSearchFocus);
    window.requestAnimationFrame(() => {
      applyNavigationPanelWidth();
      restoreEditorViewportPosition();
      restoreTreeViewportPositions();
      uiQueryAll("[data-list-key]").forEach((list) => {
        const position = listViewportPositions.get(list.dataset.listKey);
        if (position) { list.scrollLeft = position.x; list.scrollTop = position.y; }
      });
      for (const map of uiQueryAll("[data-tree-map]")) if ((graphModels.get(map.dataset.treeId)?.nodes.length || 0) > 200) paintLargeGraph(map);
      drawTreeConnections();
      placeTreePopovers();

    });
  }

  // Attach the non-passive tree-map wheel handler only to the tree canvases in
  // the freshly rendered DOM, leaving every other scroll container passive.
  function bindTreeMapWheel() {
    uiQueryAll("[data-tree-map]").forEach((map) => {
      map.addEventListener("wheel", handleTreeMapWheel, { passive: false });
    });
  }

  listen("click", (event) => {
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
    flushLiveEdits();
    const action = button.dataset.action;

    if (DELETE_KEYS[action] && !confirmDelete(DELETE_KEYS[action](button.dataset))) return;
    if (action === "setClassifierTypePaused") {
      send(action, { typeID: button.dataset.typeId, paused: button.dataset.paused === "true" });
      return;
    }
    if (action === "openConnections") {
      connectionTab = "chatGPT";
      if (selectedTypeID) {
        const type = (state.assets?.classifierTypes || []).find(item => item.id === selectedTypeID);
        if (type?.classificationProvider === "apiKey") connectionTab = (state.assets.providerProfiles || []).find(profile=>profile.id===type.apiKey?.profileID)?.type || "openAI";
      }
      utilityPanel = "settings"; window.VaultSettings.open(); render(); return;
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
      const nameInput = uiQuery("[data-create-type-name]");
      const name = ((nameInput?.value) || t("createType.defaultName")).trim() || t("createType.defaultName");
      const platformIDs = checkedPlatforms(uiQuery("[data-create-type-dialog]"));
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
    if (button.dataset.kind) data.kind = button.dataset.kind;
    if (action === "testProviderProfile") Object.assign(data, providerConnectionPayload(data, button.dataset.form));
    if (action === "cancelTagPanel") {
      flushTagNameInput(button.closest("[data-tree-popover]")?.querySelector("input[data-live-tag-name]"));
      activeTagPanel = null;
      render();
      return;
    }

    if (action === "openManual") { window.VaultManual?.open("user", "Classifier"); return; }
    if (action === "openUtilityPanel") {

      window.VaultSettings.open();
      return;
    }
    if (action === "closeUtilityPanel") {
      window.VaultSettings.close();
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
      flushTagNameInput(uiQuery("[data-tree-popover] input[data-live-tag-name]"));
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

    send(action, data);
  });

  function dismissClassifierDialog() {

    pendingCreateType = null;
    utilityPanel = null;

    render();
  }

  listen("keydown", (event) => {

    if (event.key !== "Escape" || !pendingCreateType) return;
    event.preventDefault();
    dismissClassifierDialog();
  });

  listen("toggle", (event) => {
    if (!event.target.isConnected) return;
    const key = event.target.matches?.("details[data-expand]") ? event.target.dataset.expand : null;
    if (key) event.target.open ? openExpands.add(key) : openExpands.delete(key);

  }, true);

  listen("change", (event) => {
    if (event.target.matches('[data-field="connectionType"]')) {
      const next = event.target.value;
      if (!["chatGPT", ...KEY_CONNECTIONS].includes(next)) return;
      flushLiveEdits();
      connectionTab = next;
      render();
      uiQuery('[data-field="connectionType"] + .vui-select .vui-select-button')?.focus({ preventScroll: true });
      return;
    }

    if (queueLiveEdit(event.target, true)) return;

    // Preserve creation choices across page re-renders.
    const choice = event.target.closest("input[data-platform-choice]");
    if (choice) {
      const dialog = choice.closest("[data-create-type-dialog]");
      if (dialog && pendingCreateType) {
        pendingCreateType.platformIDs = checkedPlatforms(dialog);
        pendingCreateType.name = uiQuery("[data-create-type-name]")?.value;
        const hadIssue = pendingCreateType.issue;
        pendingCreateType.issue = false;
        if (hadIssue) render();
      }
      return;
    }
  });

  listen("input", (event) => {
    if (pendingCreateType && event.target.matches("[data-create-type-name]")) {
      pendingCreateType.name = event.target.value;
    }
  });

  listen("pointerdown", (event) => {
    const resizer = event.target.closest("[data-navigation-resizer]");
    if (!resizer || event.button !== 0) return;
    navigationResize = { pointerID: event.pointerId };
    resizer.setPointerCapture?.(event.pointerId);
    event.preventDefault();
  });

  listen("pointermove", (event) => {
    if (!navigationResize || event.pointerId !== navigationResize.pointerID) return;
    const layout = uiQuery(".layout");
    if (!layout) return;
    const bounds = layout.getBoundingClientRect();
    const width = Math.round(root.dir === "rtl" ? bounds.right - event.clientX : event.clientX - bounds.left);
    navigationPanelWidth = Math.min(navigationWidthRange.maximum, Math.max(navigationWidthRange.minimum, width));
    applyNavigationPanelWidth();
    event.preventDefault();
  });

  function finishNavigationResize(event) {
    if (!navigationResize || event.pointerId !== navigationResize.pointerID) return;
    navigationResize = null;
    try { window.localStorage.setItem(navigationWidthStorageKey, String(navigationPanelWidth)); } catch (_) {}
  }

  listen("pointerup", finishNavigationResize);
  listen("pointercancel", finishNavigationResize);

  // Drag-reorder the classifier-type list. Ported from the extension's group
  // reorder (customBlocker/popup.js): the whole row is the drag target (no
  // handle), a movement threshold keeps a short press a select, the dragged row
  // is clamped so it cannot leave the top of the list ("ceiling"), the others
  // glide aside, and on release the dragged row snaps to its slot.
  function typeNavElement() { return uiQuery("[data-classifier-type-nav]"); }
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

  listen("mousedown", (event) => {
    const row = event.target.closest?.(".classifier-type-row[data-type-id]");
    if (!row) return;
    startTypeReorder(event, row.dataset.typeId);
  });

  listen("keydown", (event) => {
    const resizer = event.target.closest?.("[data-navigation-resizer]");
    if (!resizer) return;
    let nextWidth = navigationPanelWidth;
    if (event.key === "ArrowLeft") nextWidth += root.dir === "rtl" ? 16 : -16;
    else if (event.key === "ArrowRight") nextWidth += root.dir === "rtl" ? -16 : 16;
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

  listen("contextmenu", (event) => {
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
  listen("pointerdown", beginTreePan);
  listen("pointermove", moveTreePan);
  listen("pointerup", finishTreePan);
  listen("pointercancel", finishTreePan);

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
    const model = graphModels.get(map.dataset.treeId);
    if (model?.nodes.length > 200) {
      childrenByParentID.clear();
      for (const candidate of model.nodes) {
        if (!candidate.parentID) continue;
        if (!childrenByParentID.has(candidate.parentID)) childrenByParentID.set(candidate.parentID, []);
        childrenByParentID.get(candidate.parentID).push({ dataset: { nodeId: candidate.id } });
      }
    }
    const branchNodes = [];
    const pendingIDs = [node.dataset.nodeId];
    const visitedIDs = new Set();
    while (pendingIDs.length) {
      const currentID = pendingIDs.pop();
      if (!currentID || visitedIDs.has(currentID)) continue;
      visitedIDs.add(currentID);
      const currentNode = nodesByID.get(currentID);
      const position = model?.positions.get(currentID);
      if (!currentNode && !position) continue;
      branchNodes.push({
        node: currentNode,
        startX: currentNode ? Number(currentNode.dataset.positionX) || 0 : position.x,
        startY: currentNode ? Number(currentNode.dataset.positionY) || 0 : position.y,
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
    uiQuery("[data-tree-popover]")?.remove();
    const minStartX = tagDrag.nodes.reduce((value, entry) => Math.min(value, entry.startX), Infinity);
    const minStartY = tagDrag.nodes.reduce((value, entry) => Math.min(value, entry.startY), Infinity);
    const maxStartX = tagDrag.nodes.reduce((value, entry) => Math.max(value, entry.startX), -Infinity);
    const maxStartY = tagDrag.nodes.reduce((value, entry) => Math.max(value, entry.startY), -Infinity);
    const deltaX = Math.max(-minStartX, Math.min(20_000 - maxStartX, rawDeltaX));
    const deltaY = Math.max(-minStartY, Math.min(20_000 - maxStartY, rawDeltaY));
    tagDrag.nodes.forEach((entry) => {
      const positionX = entry.startX + deltaX;
      const positionY = entry.startY + deltaY;
      if (!entry.node) return;
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

  listen("pointerdown", beginTagDrag);
  listen("mousedown", beginTagDrag);
  listen("pointermove", moveTagDrag);
  listen("mousemove", moveTagDrag);
  listen("pointerup", finishTagDrag);
  listen("pointercancel", finishTagDrag);
  listen("mouseup", finishTagDrag);

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
  for (const infoScope of uiScopes) window.VaultInfo.watch(infoScope, { enabled: () => true, translate: (key, values = {}) => {
    const template = languageMessages[key];
    if (!template) return null;
    return template.replace(/\{([a-zA-Z0-9_]+)\}/g, (_, name) => String(values[name] ?? ""));
  } });
  window.addEventListener("vault-language-changed", () => { void loadSelectedLanguage(); });
  window.addEventListener("vault-settings-changed", event => {
    utilityPanel = event.detail.open ? "settings" : null;
    if (!event.detail.open) {

      flushLiveEdits();
    }
    render();
    if (event.detail.open) send("state", {});
  });
  render();
  void loadSelectedLanguage();
  send("state", {});
})();
