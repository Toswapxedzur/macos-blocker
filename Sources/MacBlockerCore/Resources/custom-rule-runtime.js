/*
 * Mac Vault's custom-rule engine: rule-core.js's engine (the rule contract,
 * shared with the browser) with Mac Vault's own actions. It controls apps
 * only — never websites (the scope line).
 *
 * Runs inside JavaScriptCore after rule-core.js. The Swift host
 * (RuleRuntime.swift) calls, with JSON in and JSON out:
 *   MacBlockerRuntime.load(groupId, source, stateJSON)
 *     → { ok, handlers, types, error, logs, states: { groupId: stateJSON }, quarantine }
 *   MacBlockerRuntime.unload(groupId)
 *   MacBlockerRuntime.suppress(groupId, on)      // a disabled group's rule hears nothing
 *   MacBlockerRuntime.dispatch(descriptorJSON)   // { type, now, data, targetGroupId? }
 *     → { actions, logs, panels: { groupId: [panel] }, states: { groupId: stateJSON }, quarantine }
 * Log values arrive as one message string; a state and a file payload as JSON
 * text (Swift keeps them as they are).
 */
var MacBlockerRuntime = (function () {
  "use strict";

  // Capture the host platform before evaluating user code. Windows identities
  // can be long executable paths; truncating one could target another app.
  const appIDLimit = globalThis.CBNativeRulePlatform === "windows" ? 32767 : 255;

  function app(id) {
    return typeof id === "string" && id && id.length <= appIDLimit ? id : null;
  }

  function macActions(act) {
    return {
      block(appId, on) {
        if (app(appId)) act("block", { appId: app(appId), on: on !== false });
      },
      quit(appId) {
        if (app(appId)) act("quit", { appId: app(appId) });
      },
      open(appId) {
        if (app(appId)) act("open", { appId: app(appId) });
      }
    };
  }

  const engine = RuleCore.createEngine(macActions);

  function message(args) {
    return (args || []).map((value) => (typeof value === "string" ? value : JSON.stringify(value))).join(" ");
  }

  function logs(list) {
    return (list || []).map((entry) => ({ groupId: entry.groupId, level: entry.level, message: message(entry.args) }));
  }

  // Keep the native writer outside user code's global namespace.
  const nativeCommit = globalThis.__vaultBeforeRuleCommit;
  delete globalThis.__vaultBeforeRuleCommit;
  let registering = false;
  const captureRecovery = globalThis.__vaultCaptureRuleLoadRecovery;
  delete globalThis.__vaultCaptureRuleLoadRecovery;
  if (typeof captureRecovery === "function") captureRecovery(() => { registering = false; });

  function stateStrings(states) {
    const out = {};
    for (const [groupId, state] of Object.entries(states || {})) out[groupId] = JSON.stringify(state);
    return out;
  }

  return {
    load(groupId, source, stateJSON) {
      if (registering) return JSON.stringify({ ok: false, handlers: 0, types: [], error: "A rule load is already in progress.", logs: [], states: {} });
      registering = true;
      try {
        let state = {};
        try { state = JSON.parse(stateJSON || "{}"); } catch (_) {}
        const beforeCommit = typeof nativeCommit === "function" ? (states) => {
          const error = nativeCommit(JSON.stringify(stateStrings(states)));
          if (error) throw new Error(error);
        } : undefined;
        const result = engine.load(String(groupId), source, state, beforeCommit);
        return JSON.stringify({ ...result, states: stateStrings(result.states), logs: logs(result.logs) });
      } finally { registering = false; }
    },
    unload(groupId) {
      engine.unload(String(groupId));
    },
    suppress(groupId, on) {
      engine.suppress(String(groupId), on === true);
    },
    dispatch(descriptorJSON) {
      const result = engine.dispatch(JSON.parse(descriptorJSON));
      const states = {};
      for (const [groupId, state] of Object.entries(result.states)) states[groupId] = JSON.stringify(state);
      const actions = result.actions.map((action) => (action.kind === "file"
        ? { ...action, payload: action.payload === null ? null : typeof action.payload === "string" ? action.payload : JSON.stringify(action.payload) }
        : action));
      return JSON.stringify({ actions, logs: logs(result.logs), diagnostics: logs(result.diagnostics), panels: result.panels, states, quarantine: result.quarantine });
    }
  };
})();
