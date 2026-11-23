// node --test poller/workflow.test.mjs
// Checks on .github/workflows/prices.yml: step order, and the shell of some steps
// run in bash against a local git repository and stubbed `gh` / `sleep`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync, execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readdirSync, readFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const YML = readFileSync(join(HERE, "..", ".github", "workflows", "prices.yml"), "utf8").replace(/\r/g, "");

// The steps of the one job: [{ name, if, run, raw }] in order.
function steps() {
  const out = [];
  const lines = YML.split("\n");
  let cur = null;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^      - (name: (.*)|uses: .*)$/);
    if (m) { cur = { name: m[2] ?? m[1], raw: [] }; out.push(cur); continue; }
    if (!cur) continue;
    cur.raw.push(lines[i]);
    const kv = lines[i].match(/^        (if|continue-on-error|run): (.*)$/);
    if (kv) cur[kv[1]] = kv[2];
    if (/^        run: \|$/.test(lines[i])) {
      const body = [];
      while (i + 1 < lines.length && (lines[i + 1] === "" || lines[i + 1].startsWith("          "))) body.push(lines[++i].slice(10));
      cur.run = body.join("\n");
    }
  }
  return out;
}
const step = (name) => steps().find((s) => s.name === name);
const names = () => steps().map((s) => s.name);

// Run a step's script like GitHub does (bash -eo pipefail), in `cwd`, with extra env.
function runStep(name, cwd, env = {}) {
  const r = spawnSync("bash", ["--noprofile", "--norc", "-eo", "pipefail", "-c", step(name).run], {
    cwd, env: { ...process.env, ...env }, encoding: "utf8",
  });
  return { code: r.status, out: r.stdout + r.stderr };
}
const tmp = () => mkdtempSync(join(tmpdir(), "wf-"));
const git = (cwd, ...args) => execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@t", ...args], { cwd, stdio: "pipe" });

function bareRepo({ withHistory }) {
  const dir = tmp(), bare = join(dir, "repo.git"), work = join(dir, "work");
  git(dir, "init", "--quiet", "--bare", bare);
  mkdirSync(work);
  git(work, "init", "--quiet", "--initial-branch", withHistory ? "history" : "main");
  writeFileSync(join(work, "113.json.gz"), "x");
  git(work, "add", "-A");
  git(work, "commit", "--quiet", "-m", "c");
  git(work, "push", "--quiet", bare, "HEAD");
  return bare;
}

test("A2: no history branch yet -> start with an empty history", () => {
  const cwd = tmp();
  const r = runStep("Get previous history", cwd, { REPO_URL: bareRepo({ withHistory: false }) });
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(readdirSync(join(cwd, "history")), []);
});

test("A2: an existing history branch is cloned", () => {
  const cwd = tmp();
  const r = runStep("Get previous history", cwd, { REPO_URL: bareRepo({ withHistory: true }) });
  assert.equal(r.code, 0, r.out);
  assert.ok(existsSync(join(cwd, "history", "113.json.gz")));
});

test("A2: a repository that can't be read fails the step instead of starting empty", () => {
  const cwd = tmp();
  const r = runStep("Get previous history", cwd, { REPO_URL: join(cwd, "does-not-exist.git") });
  assert.notEqual(r.code, 0, r.out);
  assert.ok(!existsSync(join(cwd, "history")));
});
