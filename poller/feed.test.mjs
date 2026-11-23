// node --test poller/feed.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gzipSync } from "node:zlib";
import { carryOverHistory, readGzJson, fetchRetry, diffPlausible, snapshotTime, luaEscape } from "./feed.mjs";

const tmp = () => mkdtemp(join(tmpdir(), "feed-"));

test("A1: history of houses not processed this run is carried over", async () => {
  const prev = await tmp(), out = await tmp();
  await writeFile(join(prev, "113.json.gz"), "h113");
  await writeFile(join(prev, "113.snap.json.gz"), "s113");
  await writeFile(join(prev, "114.json.gz"), "h114");
  await mkdir(join(prev, ".git")); // the cloned branch's git folder is not history
  assert.equal(await carryOverHistory(prev, out), 3);
  assert.deepEqual((await readdir(out)).sort(), ["113.json.gz", "113.snap.json.gz", "114.json.gz"]);
  assert.equal(await readFile(join(out, "113.snap.json.gz"), "utf8"), "s113");
});

test("A1: no previous history folder means nothing to carry over", async () => {
  const out = await tmp();
  assert.equal(await carryOverHistory(join(out, "missing"), out), 0);
});

test("A2: a missing file is null, a corrupt one throws", async () => {
  const dir = await tmp();
  assert.equal(await readGzJson(join(dir, "113.json.gz")), null);
  await writeFile(join(dir, "113.json.gz"), "not gzip");
  await assert.rejects(readGzJson(join(dir, "113.json.gz")));
  await writeFile(join(dir, "114.json.gz"), gzipSync(JSON.stringify({ days: {} })));
  assert.deepEqual(await readGzJson(join(dir, "114.json.gz")), { days: {} });
});

test("A7: fetchRetry retries thrown errors and bad statuses, gives up on 404", async () => {
  const real = globalThis.fetch;
  try {
    const seen = [];
    let n = 0;
    globalThis.fetch = async (url, init) => {
      seen.push(init.signal instanceof AbortSignal);
      if (n++ === 0) throw new TypeError("fetch failed");
      if (n === 2) return new Response("", { status: 503 });
      return new Response('{"ok":1}');
    };
    assert.deepEqual(await fetchRetry("http://x", {}, { delayMs: 1, read: (r) => r.json() }), { ok: 1 });
    assert.deepEqual(seen, [true, true, true]);
    n = 0;
    globalThis.fetch = async () => { n++; return new Response("", { status: 404 }); };
    await assert.rejects(fetchRetry("http://x", {}, { delayMs: 1 }), /404/);
    assert.equal(n, 1);
  } finally {
    globalThis.fetch = real;
  }
});

test("A7: snapshot plausibility, time and Lua escaping", () => {
  const snap = (n) => ({ l: Array.from({ length: n }, () => []) });
  assert.equal(diffPlausible(null, snap(1)), true);
  assert.equal(diffPlausible(snap(10), snap(5)), true);
  assert.equal(diffPlausible(snap(10), snap(4)), false);
  assert.equal(snapshotTime("Mon, 23 Nov 2026 10:00:00 GMT", "Mon, 23 Nov 2026 11:00:00 GMT"), Date.parse("2026-11-23T11:00:00Z"));
  assert.equal(snapshotTime(null, "Mon, 23 Nov 2026 11:00:00 GMT"), Date.parse("2026-11-23T11:00:00Z"));
  assert.equal(luaEscape('a"b\\c'), 'a\\"b\\\\c');
  assert.equal(luaEscape("a\nb"), "a\\nb");
});
