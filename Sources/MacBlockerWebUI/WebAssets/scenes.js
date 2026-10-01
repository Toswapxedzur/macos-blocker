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
      scripts: ["classifier/strings.js", "classifier/app.js"],
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
    scope.innerHTML = ["vault-ui.css", ...scene.styles]
      .map((href) => `<link rel="stylesheet" href="${href}">`)
      .join("") + scene.markup;
    document.body.appendChild(host);
    scopes[name] = scope;
  }

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
