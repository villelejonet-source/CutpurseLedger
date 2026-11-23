// File handling for the price feed (poller/ah.mjs), kept apart so it can be tested
// without credentials or network.

import { copyFile, readdir, readFile } from "node:fs/promises";
import { gunzipSync } from "node:zlib";
import { join } from "node:path";

// Copy every history file of the previous run into this run's output, so a house
// that is skipped this hour (fetch error, empty) keeps its history: the workflow
// replaces the whole history branch with the output folder.
// Returns the number of files copied. A missing source folder means no history yet.
export async function carryOverHistory(from, to) {
  let entries;
  try {
    entries = await readdir(from, { withFileTypes: true });
  } catch (e) {
    if (e.code === "ENOENT") return 0;
    throw e;
  }
  let n = 0;
  for (const e of entries) {
    if (!e.isFile()) continue; // e.g. the .git folder of the cloned branch
    await copyFile(join(from, e.name), join(to, e.name));
    n++;
  }
  return n;
}

// A gzipped JSON file, or null if it doesn't exist. Any other error (unreadable,
// corrupt) is thrown: treating it as "no history" would overwrite real history.
export async function readGzJson(file) {
  let buf;
  try {
    buf = await readFile(file);
  } catch (e) {
    if (e.code === "ENOENT") return null;
    throw e;
  }
  return JSON.parse(gunzipSync(buf).toString());
}
