// Adamancia Vault native desktop custom-rule examples.
//
// App identity means a macOS bundle identifier (for example
// com.apple.Safari) or the Windows identity shown by the app picker.

(function () {
  function appId(values) {
    return String(values.appId || "").trim();
  }

  CB_REGISTER_TEMPLATES([
    {
      id: "block-focused-app",
      title: "Always block an application",
      description: "Block an app whenever it is focused or observed by the one-second native tick.",
      tags: ["application", "block"],
      params: [
        { id: "appId", label: "Application identity", type: "text", span: 2, defaultValue: "com.example.App" }
      ],
      buildCode(values) {
        const id = appId(values);
        return `(event, helpers) => {
  const appId = ${JSON.stringify(id)};
  function blockWhenActive(ev) {
    if (ev.data.appId !== appId && ev.data.bundleId !== appId) return;
    ev.block(appId);
    ev.setShieldMessage("This application is blocked.");
    ev.setResult(-1);
  }
  event.on("focusEvent", "block-focused-app", blockWhenActive);
  event.on("tickEvent", "block-focused-app-tick", blockWhenActive, { intervalMs: 1000 });
}`;
      }
    },
    {
      id: "close-app-on-launch",
      title: "Close an application when it launches",
      description: "Close the selected app on its native launch event without adding a persistent block.",
      tags: ["application", "launch", "close"],
      params: [
        { id: "appId", label: "Application identity", type: "text", span: 2, defaultValue: "com.example.App" }
      ],
      buildCode(values) {
        const id = appId(values);
        return `(event, helpers) => {
  const appId = ${JSON.stringify(id)};
  event.on("openAppEvent", "close-app-on-launch", (ev) => {
    if (ev.data.bundleId === appId) ev.close(appId);
  });
}`;
      }
    },
    {
      id: "work-hours-app-block",
      title: "Block an app during selected hours",
      description: "Maintain a native app block during a daily time window, including windows that cross midnight.",
      tags: ["application", "schedule"],
      params: [
        { id: "appId", label: "Application identity", type: "text", span: 2, defaultValue: "com.example.App" },
        { id: "startHour", label: "Start hour (0–23)", type: "number", span: 1, defaultValue: 9 },
        { id: "endHour", label: "End hour (0–23)", type: "number", span: 1, defaultValue: 17 }
      ],
      buildCode(values) {
        const id = appId(values);
        const start = Math.max(0, Math.min(23, Math.floor(Number(values.startHour) || 0)));
        const end = Math.max(0, Math.min(23, Math.floor(Number(values.endHour) || 0)));
        return `(event, helpers) => {
  const appId = ${JSON.stringify(id)};
  const startHour = ${start};
  const endHour = ${end};
  event.on("tickEvent", "work-hours-app-block", (ev) => {
    const hour = ev.time.hour;
    const inside = startHour === endHour ||
      (startHour < endHour ? hour >= startHour && hour < endHour : hour >= startHour || hour < endHour);
    if (inside) {
      ev.block(appId);
      if (ev.data.appId === appId) ev.setResult(-1);
    } else {
      ev.unblock(appId);
    }
  }, { intervalMs: 1000 });
}`;
      }
    },
    {
      id: "daily-app-time-budget",
      title: "Give an app a daily time budget",
      description: "Count down only while the selected app is focused, reset each local day, then block it.",
      tags: ["application", "timer", "daily"],
      params: [
        { id: "appId", label: "Application identity", type: "text", span: 2, defaultValue: "com.example.App" },
        { id: "minutes", label: "Minutes per day", type: "number", span: 1, defaultValue: 30 }
      ],
      buildCode(values) {
        const id = appId(values);
        const minutes = Math.max(1, Math.round(Number(values.minutes) || 30));
        return `(event, helpers) => {
  const appId = ${JSON.stringify(id)};
  const budgetMs = ${minutes} * 60 * 1000;
  const timerId = "daily-app-budget";
  const tm = helpers.getTimerHelper();
  const persistence = helpers.getPersistenceHelper();
  tm.getOrCreateTimer({
    id: timerId,
    displayName: "Daily app budget",
    direction: "backward",
    currentMs: budgetMs,
    scope: appId
  });

  event.on("tickEvent", "daily-app-budget", (ev) => {
    const date = new Date(ev.time.now);
    const day = date.getFullYear() + "-" + (date.getMonth() + 1) + "-" + date.getDate();
    if (persistence.get("budget-day", "") !== day) {
      persistence.set("budget-day", day);
      tm.setCurrentMs(timerId, budgetMs);
    }
    if (tm.isExpired(timerId)) {
      ev.block(appId);
      if (ev.data.appId === appId) ev.setResult(-1);
    } else {
      ev.unblock(appId);
    }
  }, { intervalMs: 1000 });
}`;
      }
    },
    {
      id: "app-focus-counter",
      title: "Count application focuses",
      description: "Persist and log how many times the selected app receives focus.",
      tags: ["application", "persistence", "logging"],
      params: [
        { id: "appId", label: "Application identity", type: "text", span: 2, defaultValue: "com.example.App" }
      ],
      buildCode(values) {
        const id = appId(values);
        return `(event, helpers) => {
  const appId = ${JSON.stringify(id)};
  event.on("focusEvent", "app-focus-counter", (ev, h) => {
    if (ev.data.bundleId !== appId && ev.data.appId !== appId) return;
    const persistence = h.getPersistenceHelper();
    const count = Number(persistence.get("focus-count", 0)) + 1;
    persistence.set("focus-count", count);
    h.log(appId + " focus count: " + count);
  });
}`;
      }
    }
  ]);
})();
