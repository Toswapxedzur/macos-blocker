/*
 * Mac Vault's custom-rule engine: rule-core.js's engine (the rule contract,
 * shared with the browser) with Mac Vault's own actions. It controls apps
 * only — never websites (the scope line).
 *
 * Runs inside JavaScriptCore after rule-core.js. The Swift host
 * (RuleRuntime.swift) calls, with JSON in and JSON out:
 *   MacBlockerRuntime.load(groupId, source, stateJSON)
 *     → { ok, handlers, types, error, logs, quarantine }
 *   MacBlockerRuntime.unload(groupId)
 *   MacBlockerRuntime.suppress(groupId, on)      // a disabled group's rule hears nothing
 *   MacBlockerRuntime.dispatch(descriptorJSON)   // { type, now, data, targetGroupId? }
 *     → { actions, logs, panels: { groupId: [panel] }, states: { groupId: stateJSON }, quarantine }
 * Log values arrive as one message string; a state and a file payload as JSON
 * text (Swift keeps them as they are).
 */
var MacBlockerRuntime = (function () {
  "use strict";

  function app(id) {
    return typeof id === "string" && id ? id.slice(0, 255) : null;
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

  return {
    load(groupId, source, stateJSON) {
      let state = {};
      try { state = JSON.parse(stateJSON || "{}"); } catch (_) {}
      const result = engine.load(String(groupId), source, state);
      return JSON.stringify({ ...result, logs: logs(result.logs) });
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
      return JSON.stringify({ actions, logs: logs(result.logs), panels: result.panels, states, quarantine: result.quarantine });
    }
  };
})();
