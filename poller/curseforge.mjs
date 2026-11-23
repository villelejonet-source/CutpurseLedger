// Upload a zip to a CurseForge project, tagged with the WoW: Forever game version.
//
//   node poller/curseforge.mjs --project 1825560 --file dist/x.zip --name "Prices 2026-11-23 06:40 UTC" \
//        [--changelog "text"] [--requires cutpurse-ledger-prices-eu] [--type release|beta|alpha]
//   node poller/curseforge.mjs --versions      (list the WoW game versions CurseForge knows, for debugging)
//
// Env: CF_API_KEY (CurseForge author API token)
//      CF_GAME_VERSION (default: the newest version in CurseForge's "Forever" version group)

import { readFile } from "node:fs/promises";
import { basename } from "node:path";

const API = "https://wow.curseforge.com/api";
const { CF_API_KEY, CF_GAME_VERSION } = process.env;
if (!CF_API_KEY) throw new Error("Set CF_API_KEY");

function args() {
  const out = {};
  const a = process.argv.slice(2);
  for (let i = 0; i < a.length; i++) {
    if (!a[i].startsWith("--")) continue;
    const key = a[i].slice(2);
    out[key] = a[i + 1] && !a[i + 1].startsWith("--") ? a[++i] : true;
  }
  return out;
}

async function get(path) {
  const res = await fetch(API + path, { headers: { "X-Api-Token": CF_API_KEY } });
  if (!res.ok) throw new Error(`${res.status} from ${path}: ${(await res.text()).slice(0, 300)}`);
  return res.json();
}

// The game version id(s) to tag the file with: WoW: Forever.
async function foreverVersion() {
  const [types, versions] = await Promise.all([get("/game/version-types"), get("/game/versions")]);
  const forever = types.filter((t) => /forever/i.test(`${t.name} ${t.slug}`)).map((t) => t.id);
  let pool = versions.filter((v) => forever.includes(v.gameVersionTypeID));
  if (CF_GAME_VERSION) {
    const wanted = versions.filter((v) => v.name === CF_GAME_VERSION && (!forever.length || forever.includes(v.gameVersionTypeID)));
    if (wanted.length) pool = wanted;
  }
  if (!pool.length) {
    throw new Error(`No WoW: Forever game version found on CurseForge (version types: ${types.map((t) => t.name).join(", ")})`);
  }
  // Newest first by numeric version name ("1.60.1")
  const num = (s) => s.name.split(".").map((x) => Number(x) || 0);
  pool.sort((a, b) => {
    const x = num(a), y = num(b);
    for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] ?? 0) !== (y[i] ?? 0)) return (y[i] ?? 0) - (x[i] ?? 0);
    return b.id - a.id;
  });
  return pool[0];
}

async function upload({ project, file, name, changelog, requires, type }, version, withRelations = true) {
  const metadata = {
    changelog: changelog || name,
    changelogType: "markdown",
    displayName: name,
    gameVersions: [version.id],
    releaseType: type || "release",
  };
  if (requires && withRelations) {
    metadata.relations = { projects: [{ slug: requires, type: "requiredDependency" }] };
  }
  const form = new FormData();
  form.append("metadata", JSON.stringify(metadata));
  form.append("file", new Blob([await readFile(file)]), basename(file));
  const res = await fetch(`${API}/projects/${project}/upload-file`, {
    method: "POST",
    headers: { "X-Api-Token": CF_API_KEY },
    body: form,
  });
  const text = await res.text();
  return { ok: res.ok, status: res.status, text };
}

const a = args();
if (a.versions) {
  const [types, versions] = await Promise.all([get("/game/version-types"), get("/game/versions")]);
  for (const t of types) {
    const vs = versions.filter((v) => v.gameVersionTypeID === t.id).map((v) => `${v.name}(${v.id})`);
    console.log(`${t.id} ${t.name} [${t.slug}]: ${vs.slice(-6).join(", ")}`);
  }
  process.exit(0);
}
for (const k of ["project", "file", "name"]) if (!a[k]) throw new Error(`--${k} is required`);

const version = await foreverVersion();
console.log(`Game version: ${version.name} (id ${version.id})`);
let r = await upload(a, version);
if (!r.ok && a.requires && /relation|slug|project/i.test(r.text)) {
  // A wrong dependency slug shouldn't block the upload: retry without it and say so.
  console.log(`Upload with dependency "${a.requires}" failed (${r.status}): ${r.text.slice(0, 300)}`);
  console.log("Retrying without the dependency. Set it by hand on CurseForge, or fix the slug.");
  r = await upload(a, version, false);
}
if (!r.ok) throw new Error(`Upload failed (${r.status}): ${r.text.slice(0, 500)}`);
console.log(`Uploaded ${basename(a.file)} to project ${a.project}: ${r.text}`);
