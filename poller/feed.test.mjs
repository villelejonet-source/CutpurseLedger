// node --test poller/feed.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { carryOverHistory } from "./feed.mjs";

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
