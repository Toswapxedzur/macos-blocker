// Custom Web Blocker — curated raw-API examples.
//
// The custom-rule engine is intentionally low-level: rules are plain
// (event, helpers) => { ... } functions that register handlers and drive
// raw primitives. These examples cover the main capabilities; most users
// will generate rules with the "Generate AI prompt" button and an LLM.
//
// Key primitives used below:
//   event.on(type, id, (ev, h) => {})          register a handler
//   helpers.platform("youtube").hide(slot, pred)   hide feed cards
//   helpers.platform("youtube").allow(slot, pred)  rescue (whitelist) cards
//   helpers.platform("youtube").surface(name, "hide")  hide a whole region
//   ev.setResult(-1) (+ ev.preventDefault())   block the page (redirect)
//   helpers.getTimerHelper(), helpers.getPersistenceHelper()

(function () {
  CB_REGISTER_TEMPLATES([
    {
      id: "yt-hide-small-channels",
      title: "Hide YouTube videos from small channels",
      description:
        "Hide home/search/feed videos from channels under a subscriber threshold. Uses the enriched item.creator.subCount (null-safe; fails open until the channel resolves).",
      tags: ["youtube", "feed", "creator"],
      params: [
        { id: "minSubs", label: "Minimum subscribers", type: "number", span: 1, defaultValue: 100000 }
      ],
      buildCode(values) {
        const minSubs = Math.max(0, Math.round(Number(values.minSubs) || 0));
        return `(event, helpers) => {
  event.on("webChangedEvent", "yt-hide-small-channels", (ev, h) => {
    h.platform("youtube").hide("videos", (item) => {
      const c = item.creator;
      return c && typeof c.subCount === "number" && c.subCount < ${minSubs};
    });
  });
}`;
      }
    },
    {
      id: "yt-hide-by-tag",
      title: "Hide YouTube videos by creator tag",
      description:
        "Hide videos whose creator carries any of the given classification tags (e.g. gaming, news-politics). Tags come from item.creator.tags.",
      tags: ["youtube", "feed", "tags"],
      params: [
        { id: "tagsCsv", label: "Tags (comma separated)", type: "text", span: 2, defaultValue: "gaming,news-politics" }
      ],
      buildCode(values) {
        const tags = String(values.tagsCsv || "")
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean);
        return `(event, helpers) => {
  const blocked = ${JSON.stringify(tags)};
  event.on("webChangedEvent", "yt-hide-by-tag", (ev, h) => {
    h.platform("youtube").hide((item) => {
      const tags = (item.creator && item.creator.tags) || [];
      return tags.some((t) => blocked.includes(t));
    });
  });
}`;
      }
    },
    {
      id: "yt-allow-education",
      title: "Rescue (allow) educational creators",
      description:
        "A whitelist rescue: keep videos tagged 'education' even when a lower-priority block group would hide them. Place this group ABOVE the block group in the list.",
      tags: ["youtube", "allow", "rescue"],
      params: [
        { id: "tag", label: "Tag to always allow", type: "text", span: 1, defaultValue: "education" }
      ],
      buildCode(values) {
        const tag = String(values.tag || "education").trim();
        return `(event, helpers) => {
  event.on("webChangedEvent", "yt-allow-tag", (ev, h) => {
    h.platform("youtube").allow((item) => {
      const tags = (item.creator && item.creator.tags) || [];
      return tags.includes(${JSON.stringify(tag)});
    });
  });
}`;
      }
    },
    {
      id: "yt-hide-shorts",
      title: "Hide all YouTube Shorts",
      description:
        "Remove every Shorts card from feeds and hide the Shorts button in the sidebar.",
      tags: ["youtube", "shorts", "feed"],
      params: [],
      buildCode() {
        return `(event, helpers) => {
  event.on("webChangedEvent", "yt-hide-shorts", (ev, h) => {
    const yt = h.platform("youtube");
    yt.hide("shorts", () => true);
    yt.surface("shortButton", "hide");
  });
}`;
      }
    },
    {
      id: "block-shorts-page",
      title: "Block the Shorts player page (redirect)",
      description:
        "Bounce off any /shorts/ player URL. Native network blocking is gone — this redirects the page instead.",
      tags: ["youtube", "shorts", "redirect"],
      params: [],
      buildCode() {
        return `(event, helpers) => {
  const yt = helpers.platform("youtube");
  function maybeBlock(ev) {
    if (!yt.isShortUrl(ev.url)) return;
    ev.preventDefault();
    ev.setResult(-1);
  }
  event.on("openWebEvent", "shorts-page-block", maybeBlock);
  event.on("webChangedEvent", "shorts-page-block", maybeBlock);
}`;
      }
    },
    {
      id: "hide-home-feed",
      title: "Hide the YouTube home feed",
      description:
        "Hide the entire home page recommendation grid while leaving search and subscriptions usable.",
      tags: ["youtube", "home", "surface"],
      params: [],
      buildCode() {
        return `(event, helpers) => {
  event.on("webChangedEvent", "yt-hide-home", (ev, h) => {
    h.platform("youtube").surface("home", "hide");
  });
}`;
      }
    },
    {
      id: "watch-time-counter",
      title: "Count-up watch-time overlay",
      description:
        "Show a count-up stopwatch of time spent on YouTube watch pages. Informational only — it never blocks.",
      tags: ["timer", "youtube"],
      params: [],
      buildCode() {
        return `(event, helpers) => {
  const tm = helpers.getTimerHelper();
  tm.getOrCreateTimer({
    id: "yt-watch-time",
    displayName: "YouTube watch time",
    direction: "forward",
    currentMs: 0,
    scope: (url) => /youtube\\.com\\/watch/.test(url),
    domain: (url) => /youtube\\.com/.test(url)
  });
}`;
      }
    },
    {
      id: "daily-visit-counter",
      title: "Count daily visits with persistence",
      description:
        "Increment a per-day counter every time a tab opens on the given host, logging the running total. Shows raw persistence usage.",
      tags: ["persistence", "logging"],
      params: [
        { id: "host", label: "Host to count", type: "text", span: 2, defaultValue: "news.ycombinator.com" }
      ],
      buildCode(values) {
        const host = String(values.host || "").trim();
        return `(event, helpers) => {
  const host = ${JSON.stringify(host)};
  event.on("openWebEvent", "daily-visit-counter", (ev, h) => {
    if (!ev.hostname || ev.hostname.indexOf(host) === -1) return;
    const p = h.getPersistenceHelper();
    const day = new Date().toISOString().slice(0, 10);
    const key = "visits:" + day;
    const next = (Number(p.get(key, 0)) || 0) + 1;
    p.set(key, next);
    h.log(host + " visits today: " + next);
  });
}`;
      }
    }
  ]);
})();
