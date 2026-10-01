/* Aggregate exact Activity intervals for the ordered day chart. The raw
 * sessions remain unchanged and can still be shown with the Exact setting.
 * App time and its attributed website time are one clock, not two clocks.
 */
(function (root, factory) {
  var api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  root.ActivityTimeBins = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  var CHOICES = [5, 15, 30, 60];
  var DAY_SECONDS = 86400;

  function aggregate(apps, sites, minutes) {
    if (CHOICES.indexOf(minutes) < 0) throw new RangeError("unsupported block length");
    var count = 1440 / minutes;
    var blockSeconds = minutes * 60;
    var bins = new Map();

    function add(segments, isSite) {
      (segments || []).forEach(function (segment) {
        var from = Math.max(0, Math.min(1, Number(segment.from)));
        var to = Math.max(0, Math.min(1, Number(segment.to)));
        if (!Number.isFinite(from) || !Number.isFinite(to) || to <= from) return;
        var first = Math.floor(from * count);
        var last = Math.min(count - 1, Math.ceil(to * count) - 1);
        for (var index = first; index <= last; index++) {
          var a = Math.max(from, index / count);
          var b = Math.min(to, (index + 1) / count);
          if (b <= a) continue;
          var bin = bins.get(index);
          if (!bin) {
            bin = { index: index, from: index / count, to: (index + 1) / count, apps: new Map(), sites: new Map() };
            bins.set(index, bin);
          }
          var map = isSite ? bin.sites : bin.apps;
          var id = (isSite ? "web|" : "app|") + segment.key;
          var mapKey = isSite ? String(segment.browserKey) + "\u0000" + id : id;
          var part = map.get(mapKey);
          if (!part) {
            part = { id: id, key: segment.key, label: segment.label || segment.key,
              color: segment.color, kind: isSite ? "Website" : "App", browserId: isSite ? "app|" + segment.browserKey : null,
              seconds: 0 };
            map.set(mapKey, part);
          }
          part.seconds += (b - a) * DAY_SECONDS;
        }
      });
    }

    add(apps, false);
    add(sites, true);
    return Array.from(bins.values()).sort(function (a, b) { return a.index - b.index; }).map(function (bin) {
      // Sites replace their share of browser time. If overlapping site logs
      // exceed that browser's time in a block, scale only those site shares.
      var byBrowser = new Map();
      bin.sites.forEach(function (site) {
        var list = byBrowser.get(site.browserId) || [];
        list.push(site);
        byBrowser.set(site.browserId, list);
      });
      byBrowser.forEach(function (sitesForBrowser, browserId) {
        var browser = bin.apps.get(browserId);
        if (!browser) return;
        var siteSeconds = sitesForBrowser.reduce(function (sum, site) { return sum + site.seconds; }, 0);
        var attributed = Math.min(browser.seconds, siteSeconds);
        var ratio = siteSeconds > 0 ? attributed / siteSeconds : 0;
        sitesForBrowser.forEach(function (site) { site.seconds *= ratio; });
        browser.seconds -= attributed;
      });

      var byItem = new Map();
      function collect(part) {
        if (part.seconds <= 0) return;
        var item = byItem.get(part.id);
        if (!item) {
          item = { id: part.id, key: part.key, label: part.label, color: part.color,
            kind: part.kind, seconds: 0 };
          byItem.set(part.id, item);
        }
        item.seconds += part.seconds;
      }
      bin.apps.forEach(collect);
      bin.sites.forEach(collect);
      var items = Array.from(byItem.values());
      var used = items.reduce(function (sum, item) { return sum + item.seconds; }, 0);
      // A malformed overlap must never paint more than one clock per block.
      if (used > blockSeconds) {
        var scale = blockSeconds / used;
        items.forEach(function (item) { item.seconds *= scale; });
        used = blockSeconds;
      }
      items.sort(function (a, b) { return b.seconds - a.seconds || a.id.localeCompare(b.id); });
      return { from: bin.from, to: bin.to, items: items,
        usedSeconds: used, idleSeconds: Math.max(0, blockSeconds - used) };
    });
  }

  return Object.freeze({ choices: CHOICES, aggregate: aggregate });
});
