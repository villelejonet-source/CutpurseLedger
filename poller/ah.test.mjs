// node --test poller/ah.test.mjs
// Runs the whole feed (poller/ah.mjs) against a fake Blizzard API (fake-bnet.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { gzipSync, gunzipSync } from "node:zlib";

const HERE = dirname(fileURLToPath(import.meta.url));

// Run ah.mjs; `history` = { file: object } written gzipped into HISTORY_DIR first (null = no folder).
async function runFeed(spec, history = {}) {
  const dir = await mkdtemp(join(tmpdir(), "ah-"));
  const hist = join(dir, "history"), out = join(dir, "out");
  if (history) {
    await mkdir(hist);
    for (const [f, v] of Object.entries(history)) {
      await writeFile(join(hist, f), typeof v === "string" ? v : gzipSync(JSON.stringify(v)));
    }
  }
  const specFile = join(dir, "spec.json");
  await writeFile(specFile, JSON.stringify(spec));
  const r = spawnSync(process.execPath, ["--import", pathToFileURL(join(HERE, "fake-bnet.mjs")).href, join(HERE, "ah.mjs")], {
    env: { ...process.env, FAKE_BNET: specFile, BNET_CLIENT_ID: "x", BNET_CLIENT_SECRET: "y", HISTORY_DIR: hist, OUT_DIR: out },
    encoding: "utf8",
  });
  const read = async (f) => JSON.parse(gunzipSync(await readFile(join(out, "history", f))).toString());
  const lua = async () => readFile(join(out, "LootLedger_Prices", "Prices.lua"), "utf8");
  const log = async () => readFile(specFile + ".log", "utf8").catch(() => "");
  return { code: r.status, out: r.stdout + r.stderr, outHistory: () => readdir(join(out, "history")), read, lua, log };
}

const listing = (id, item, qty, price, tl = "LONG") => ({ id, item: { id: item }, quantity: qty, buyout: qty * price, time_left: tl });
const HOUSES = [{ id: 113, name: "Horde Thunderstrike" }, { id: 114, name: "Alliance Thunderstrike" }];

test("A1: a house that fails this run keeps its history and snapshot", async () => {
  const oldHist = { days: { "2026-11-01": {} }, months: {} };
  const oldSnap = { t: 1, l: [] };
  const r = await runFeed(
    { houses: HOUSES, data: { 113: { auctions: [listing(1, 2589, 20, 50)] }, 114: { status: 500 } } },
    { "114.json.gz": oldHist, "114.snap.json.gz": oldSnap },
  );
  assert.equal(r.code, 0, r.out);
  assert.deepEqual((await r.outHistory()).sort(), ["113.json.gz", "113.snap.json.gz", "114.json.gz", "114.snap.json.gz"]);
  assert.deepEqual(await r.read("114.json.gz"), oldHist);
  assert.deepEqual(await r.read("114.snap.json.gz"), oldSnap);
});

test("A2: a corrupt history file stops the run instead of starting that house over", async () => {
  const r = await runFeed(
    { houses: HOUSES.slice(0, 1), data: { 113: { auctions: [listing(1, 2589, 20, 50)] } } },
    { "113.json.gz": "not gzip" },
  );
  assert.notEqual(r.code, 0, r.out);
});
