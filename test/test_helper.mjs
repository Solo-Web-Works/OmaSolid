import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { strict as assert } from "node:assert";

const here = dirname(fileURLToPath(import.meta.url));
const helper = join(here, "..", "solidtime.py");

// Run the helper against an isolated config file so tests never touch the
// user's real ~/.config/omarchy/solidtime.json.
const tmp = mkdtempSync(join(tmpdir(), "omasolid-"));
const configPath = join(tmp, "solidtime.json");

// spawnSync (not execFileSync) so a non-zero exit code is returned rather than
// thrown — most helper failures exit 1 with a JSON error on stdout.
function run(args) {
  const out = spawnSync("python3", [helper, ...args], {
    encoding: "utf8",
    env: { ...process.env, OMASOLID_CONFIG_PATH: configPath },
  });
  const line = (out.stdout || "").split("\n").filter(Boolean).pop() || "{}";
  return JSON.parse(line);
}

test.after(() => rmSync(tmp, { recursive: true, force: true }));

test("init reports unconfigured with empty defaults", () => {
  const r = run(["init"]);
  assert.equal(r._ok, true);
  assert.equal(r.configured, false);
  assert.equal(r.instance, "");
});

test("start without config returns a structured error, not a crash", () => {
  const r = run(["start", JSON.stringify({ project_id: "p" })]);
  assert.equal(r._ok, false);
  assert.ok(typeof r.error === "string" && r.error.length > 0);
});

test("stop without config returns a structured error", () => {
  const r = run(["stop"]);
  assert.equal(r._ok, false);
  assert.ok(r.error);
});

test("save-config persists and re-reads", () => {
  const candidate = { instance: "https://example.com", token: "tok", organization_id: "", member_id: "" };
  const saved = run(["save-config", JSON.stringify(candidate)]);
  assert.equal(saved._ok, true);
  assert.equal(saved.instance, "https://example.com");
  const re = run(["init"]);
  assert.equal(re.instance, "https://example.com");
  assert.equal(re.configured, false); // no org/member yet
});

test("test-config with unreachable instance returns a structured error", () => {
  const candidate = { instance: "https://localhost:9", token: "tok", organization_id: "", member_id: "" };
  const r = run(["test-config", JSON.stringify(candidate)]);
  assert.equal(r._ok, false);
  assert.ok(r.error);
});

test("malformed payload produces a structured error", () => {
  const r = run(["save-config", "not-json"]);
  assert.equal(r._ok, false);
  assert.ok(r.error);
});

test("create-project without config returns a structured error", () => {
  const r = run(["create-project", JSON.stringify({ name: "New Project" })]);
  assert.equal(r._ok, false);
  assert.ok(r.error);
});
