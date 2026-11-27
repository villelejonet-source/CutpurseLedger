// Day keys around the clock changes (a 23- or 25-hour day). Runs in a European
// time zone whatever the machine's own is.
process.env.TZ = "Europe/Stockholm";
import { test } from "node:test";
import assert from "node:assert/strict";
import { luaVM } from "./harness.mjs";

const at = (iso) => Math.floor(Date.parse(iso) / 1000);

test("the night after the spring clock change: yesterday is the 29th, not the 28th", () => {
  // 30 March 2026 00:30 CEST; 29 March had only 23 hours
  const { get } = luaVM({ before: `NOW = ${at("2026-03-29T22:30:00Z")}` });
  assert.equal(get("ns.DayKey()"), "2026-03-30");
  assert.equal(get("ns.DayKey(1)"), "2026-03-29");
  assert.equal(get("ns.DayKey(2)"), "2026-03-28");
  assert.equal(get(`date("%Y-%m-%d %H:%M", ns.DayStart(1))`), "2026-03-29 00:00");
});

test("the night after the autumn change (a 25-hour day) is right too", () => {
  // 26 October 2026 00:30 CET; 25 October had 25 hours
  const { get } = luaVM({ before: `NOW = ${at("2026-10-25T23:30:00Z")}` });
  assert.equal(get("ns.DayKey(1)"), "2026-10-25");
  assert.equal(get(`date("%Y-%m-%d %H:%M", ns.DayStart(1))`), "2026-10-25 00:00");
});
