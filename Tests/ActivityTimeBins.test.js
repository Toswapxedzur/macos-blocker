const assert = require("node:assert/strict");
const { aggregate } = require("../Sources/MacBlockerWebUI/WebAssets/activity-time-bins.js");

const fraction = (minutes) => minutes / 1440;
const segment = (key, from, to, color, browserKey) => ({
  key, label: key, from: fraction(from), to: fraction(to), color, browserKey
});
const close = (actual, expected) => assert.ok(Math.abs(actual - expected) < 0.001, `${actual} != ${expected}`);

// One clock: a website replaces browser time, and the rest stays browser time.
let bins = aggregate(
  [segment("browser", 0, 20, "blue"), segment("editor", 20, 35, "orange")],
  [segment("example.com", 5, 13, "green", "browser")], 30);
assert.equal(bins.length, 2);
close(bins[0].usedSeconds, 1800);
close(bins[0].idleSeconds, 0);
close(bins[0].items.find((x) => x.id === "app|browser").seconds, 12 * 60);
close(bins[0].items.find((x) => x.id === "web|example.com").seconds, 8 * 60);
close(bins[0].items.find((x) => x.id === "app|editor").seconds, 10 * 60);
close(bins[1].items[0].seconds, 5 * 60);
close(bins[1].idleSeconds, 25 * 60);

// A session crossing a boundary contributes to both blocks, without rounding
// its start/end or changing its permanent colour.
bins = aggregate([segment("editor", 29, 31, "orange")], [], 30);
close(bins[0].items[0].seconds, 60);
close(bins[1].items[0].seconds, 60);
assert.equal(bins[0].items[0].color, "orange");
assert.equal(bins[1].items[0].color, "orange");

// Focusing a website need not include its browser as a separate item.
bins = aggregate([], [segment("example.com", 0, 10, "green", "browser")], 30);
close(bins[0].usedSeconds, 600);
close(bins[0].idleSeconds, 1200);

// Overlapping site reports cannot double-count the browser or exceed a block.
bins = aggregate([segment("browser", 0, 10, "blue")], [
  segment("one.com", 0, 10, "green", "browser"),
  segment("two.com", 0, 10, "red", "browser")
], 30);
close(bins[0].usedSeconds, 600);
close(bins[0].items.find((x) => x.id === "web|one.com").seconds, 300);
close(bins[0].items.find((x) => x.id === "web|two.com").seconds, 300);

assert.deepEqual(aggregate([], [], 5), []);
assert.throws(() => aggregate([], [], 7), RangeError);
console.log("Activity time bins: PASS");
