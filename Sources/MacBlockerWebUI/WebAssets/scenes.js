/* Mac Vault: one web view, one document, three scenes (owner 2026-09-28).
 * The Vault scene is this page itself — the editor synced from the extension
 * (popup.html). The Classifier and Activity scenes live beside it, each in its
 * own shadow root, so their stylesheets and the editor's never meet. Every
 * scene's header carries the same Vault / Classifier / Activity tabs; they
 * switch here, inside the page. The native side only hears which scene shows
 * (the Classifier pauses its snapshots while hidden, Activity refreshes).
 * Mac-only (not synced); sync-webui.sh adds its script tag to popup.html.
 */
(function () {
  "use strict";

  // Each scene: its stylesheets, its scripts (in order) and its mount markup.
  const SCENES = {
    classifier: {
      styles: ["classifier/app.css"],
      scripts: ["classifier/strings.js", "classifier/notice-language.js", "classifier/app.js"],
      markup: '<main id="app" aria-live="polite"></main>'
    },
    activity: {
      styles: ["activity.css"],
      scripts: ["activity-time-bins.js", "activity.js"],
      markup: '<div id="activity"></div>'
    }
  };

  const scopes = {};
  for (const [name, scene] of Object.entries(SCENES)) {
    const host = document.createElement("div");
    host.className = "vault-scene";
    host.dataset.scene = name;
    const scope = host.attachShadow({ mode: "open" });
    scope.innerHTML = ["vault-ui.css", "vault-info.css", ...scene.styles]
      .map((href) => `<link rel="stylesheet" href="${href}">`)
      .join("") + scene.markup;
    document.body.appendChild(host);
    scopes[name] = scope;
  }

  // All pages edit the same app Settings. Content tagging belongs with app
  // behavior; AI connections have their own column because custom rules also
  // use them. Both keep the shared dialog and focus lifecycle.
  const settingsModal = document.getElementById("settingsModal");
  const updatesSection = document.createElement("section");
  updatesSection.className = "settings-group native-updates";
  updatesSection.innerHTML = '<span class="label">Updates</span>'
    + '<label class="checkbox-row compact" for="vaultAutoUpdates">'
    + '<input id="vaultAutoUpdates" type="checkbox"><span>Auto install updates</span></label>'
    + '<div class="field-actions"><button id="vaultCheckUpdates" type="button" class="secondary">Check for updates</button></div>';
  settingsModal.querySelector(".settings-col").appendChild(updatesSection);
  const autoUpdates = updatesSection.querySelector("#vaultAutoUpdates");
  const checkUpdates = updatesSection.querySelector("#vaultCheckUpdates");
  async function refreshUpdates() {
    const result = await window.__cbUpdaterRequest("status");
    autoUpdates.checked = result.autoInstall === true;
    autoUpdates.disabled = result.available !== true;
    checkUpdates.disabled = result.available !== true || result.checking === true;
  }
  autoUpdates.addEventListener("change", async () => {
    autoUpdates.disabled = true;
    await window.__cbUpdaterRequest("set", autoUpdates.checked);
    refreshUpdates();
  });
  checkUpdates.addEventListener("click", async () => {
    checkUpdates.disabled = true;
    await window.__cbUpdaterRequest("check");
    refreshUpdates();
  });
  function settingsMount(parent, id) {
    const host = document.createElement("div");
    host.className = "native-settings-host";
    host.dataset.scene = "classifier";
    parent.appendChild(host);
    const scope = host.attachShadow({ mode: "open" });
    scope.innerHTML = ["vault-ui.css", "vault-info.css", "classifier/app.css"]
      .map(href => `<link rel="stylesheet" href="${href}">`).join("")
      + `<div id="${id}" class="utility-settings-body"></div>`;
    return { scope, root: scope.getElementById(id) };
  }
  const tagging = settingsMount(settingsModal.querySelector(".settings-col"), "native-tagging-settings");
  const connectionsColumn = document.createElement("section");
  connectionsColumn.className = "settings-col ai-connections-col";
  settingsModal.querySelector(".settings-cols").appendChild(connectionsColumn);
  const connections = settingsMount(connectionsColumn, "native-settings");
  let settingsVisible = false;
  function notifyScene(scene) {
    try { window.webkit.messageHandlers.cbBridge.postMessage({ kind: "scene-shown", scene }); } catch (_) {}
  }
  function settingsChanged() {
    const visible = !settingsModal.classList.contains("hidden");
    if (visible === settingsVisible) return;
    settingsVisible = visible;
    if (visible) refreshUpdates();
    notifyScene(visible ? "settings" : document.body.dataset.scene || "vault");
    window.dispatchEvent(new CustomEvent("vault-settings-changed", { detail: { open: visible } }));
  }
  new MutationObserver(settingsChanged).observe(settingsModal, { attributes: true, attributeFilter: ["class"] });
  window.VaultSettings = Object.freeze({
    scope: connections.scope, root: connections.root,
    taggingScope: tagging.scope, taggingRoot: tagging.root,
    isOpen: () => !settingsModal.classList.contains("hidden"),
    open() { openSettings(); settingsChanged(); },
    close() { closeSettings(); settingsChanged(); }
  });
  window.VaultUI.observe(connections.scope);
  window.VaultUI.observe(tagging.scope);

  // A scene's script finds its shadow root here.
  window.VaultScenes = Object.freeze({ scope: (name) => scopes[name] || null });

  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = src;
      script.onload = resolve;
      script.onerror = () => reject(new Error("could not load " + src));
      document.body.appendChild(script);
    });
  }

  (async () => {
    for (const scene of Object.values(SCENES)) {
      for (const src of scene.scripts) await loadScript(src);
    }
  })().catch((error) => console.error("[scenes]", error));

  function show(name) {
    if (name !== "vault" && !scopes[name]) return;
    document.body.dataset.scene = name;
    try {
      window.webkit.messageHandlers.cbBridge.postMessage({ kind: "scene-shown", scene: name });
    } catch (_) {}
  }

  // A tab in any scene's header (the click leaves its shadow root, so read the
  // original target from the event path).
  document.addEventListener("click", (event) => {
    const tab = event.composedPath().find((node) =>
      node instanceof Element && node.classList.contains("vui-tab") && node.dataset.scene);
    if (!tab) return;
    event.preventDefault();
    show(tab.dataset.scene);
  });

  document.body.dataset.scene = "vault";
})();
