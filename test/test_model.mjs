// Unit tests for Model.js using node:test.
//
// Model.js is a QML ".pragma library" file: its top-level `function`
// declarations become members of the module when QML does
// `import "Model.js" as Model`. There is no exported `Model` object in plain
// JavaScript, so to exercise it in Node we wrap the source in a Function body
// and hand back the functions we want to test.
import { test } from "node:test";
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*/m, "");

const Model = new Function(
  src + `
; return {
  parseResult,
  normalizeInstance,
  projectOptions,
  clientOptions,
  taskOptions,
  orgOptions,
  memberIdForOrg,
  formatElapsed,
  barGlyph
};`
)();

test("normalizeInstance strips trailing slashes and adds a scheme", () => {
  assert.equal(Model.normalizeInstance("https://solidtime.example.com/"), "https://solidtime.example.com");
  assert.equal(Model.normalizeInstance("solidtime.example.com/"), "https://solidtime.example.com");
  assert.equal(Model.normalizeInstance(""), "");
});

test("formatElapsed formats seconds as H:MM:SS or M:SS", () => {
  assert.equal(Model.formatElapsed(0), "0:00");
  assert.equal(Model.formatElapsed(65), "1:05");
  assert.equal(Model.formatElapsed(3661), "1:01:01");
});

test("parseResult returns ok:false on bad input", () => {
  assert.equal(Model.parseResult("").ok, false);
  assert.equal(Model.parseResult("not json").ok, false);
});

test("parseResult strips _ok and reports success", () => {
  const r = Model.parseResult(JSON.stringify({ _ok: true, configured: true }));
  assert.equal(r.ok, true);
  assert.equal(r.configured, true);
  assert.equal("_ok" in r, false);
});

test("parseResult surfaces errors from the helper", () => {
  const r = Model.parseResult(JSON.stringify({ _ok: false, error: "boom" }));
  assert.equal(r.ok, false);
  assert.equal(r.error, "boom");
});

test("projectOptions filters by client", () => {
  const projects = [
    { id: "p1", name: "Alpha", client_id: "c1", client_name: "Acme" },
    { id: "p2", name: "Beta", client_id: "c2", client_name: "Globex" },
    { id: "p3", name: "Gamma", client_id: "", client_name: "No client" }
  ];
  const forC1 = Model.projectOptions(projects, "c1");
  assert.equal(forC1.length, 1);
  assert.equal(forC1[0].value, "p1");
  assert.equal(Model.projectOptions(projects).length, 3);
});

test("memberIdForOrg resolves the membership id", () => {
  const orgs = [{ id: "o1", member_id: "m1" }, { id: "o2", member_id: "m2" }];
  assert.equal(Model.memberIdForOrg(orgs, "o2"), "m2");
  assert.equal(Model.memberIdForOrg(orgs, "missing"), "");
});

test("taskOptions filters by project and is empty for an unknown project", () => {
  const tasks = [
    { id: "t1", name: "Design", project_id: "p1" },
    { id: "t2", name: "Build", project_id: "p2" }
  ];
  assert.equal(Model.taskOptions("p1", tasks).length, 1);
  assert.equal(Model.taskOptions("nope", tasks).length, 0);
});

test("barGlyph reflects state", () => {
  assert.ok(Model.barGlyph(true, false));
  assert.ok(Model.barGlyph(false, false));
  assert.notEqual(Model.barGlyph(false, true), Model.barGlyph(false, false));
});
