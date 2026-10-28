import { test } from "node:test";
import { strict as assert } from "node:assert";
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import { spawn, spawnSync } from "node:child_process";

const panel = readFileSync(new URL("../Panel.qml", import.meta.url), "utf8");
const labels = [
  "text: root.statusSubtitle()",
  'text: "Signed in as "',
  "text: svc && svc.activeEntry && svc.activeEntry.project_name",
  "text: (svc.activeEntry && svc.activeEntry.description",
  "text: (modelData.project_name",
  'text: svc ? svc.lastError : ""',
];

function labelBlock(marker) {
  const position = panel.indexOf(marker);
  assert.notEqual(position, -1, marker);
  return panel.slice(panel.lastIndexOf("Text {", position), panel.indexOf("}", position) + 1);
}

test("API-controlled panel labels explicitly render plain text", () => {
  for (const marker of labels) {
    assert.match(labelBlock(marker), /textFormat:\s*Text\.PlainText\b/, marker);
  }
});

test("host-managed tooltip does not interpolate API text", () => {
  const bar = readFileSync(new URL("../BarWidget.qml", import.meta.url), "utf8");
  const tooltip = bar.slice(bar.indexOf("tooltipText: {"), bar.indexOf("onPressed:"));
  const returns = [...tooltip.matchAll(/return ([^\n]+)/g)].map(match => match[1]);
  assert.equal(returns.length, 4);
  for (const value of returns) assert.match(value, /^"[^"\n]*"$/);
});

const qml = process.env.QML_BIN || "qml6";
const hasQt = !spawnSync(qml, ["--version"], {
  env: { ...process.env, QT_QPA_PLATFORM: "offscreen" },
}).error;

test("Qt renders injected image markup without requests; AutoText control requests it", {
  skip: !hasQt && "Qt runtime unavailable; set QML_BIN to enable rendering test",
  timeout: 15000,
}, async () => {
  const requests = [];
  const server = createServer((req, res) => {
    requests.push(req.url);
    res.writeHead(200, { "Content-Type": "image/svg+xml" });
    res.end('<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>');
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const dir = mkdtempSync(join(tmpdir(), "omasolid-render-"));
  async function render(formats) {
    const items = formats.map((format, i) => `Text {
      textFormat: ${format}
      text: ${JSON.stringify(`<img src="http://127.0.0.1:${server.address().port}/${i}"/>`)}
    }`).join("\n");
    const file = join(dir, "render.qml");
    writeFileSync(file, `import QtQuick
Window {
  visible: true; width: 400; height: 300
  Column { ${items} }
  Timer { interval: 1200; running: true; onTriggered: Qt.quit() }
}`);
    await new Promise((resolve, reject) => {
      const child = spawn(qml, [file], {
        env: { ...process.env, QT_QPA_PLATFORM: "offscreen", QT_QUICK_BACKEND: "software" },
        timeout: 5000,
      });
      let output = "";
      child.stderr.on("data", chunk => { output += chunk; });
      child.on("error", reject);
      child.on("close", code => code === 0 ? resolve() : reject(new Error(output || `Qt exited ${code}`)));
    });
  }
  try {
    await render(["Text.AutoText"]);
    assert.ok(requests.length > 0, "positive control must load the image");
    requests.length = 0;
    await render(labels.map(marker => labelBlock(marker).match(/textFormat:\s*(Text\.\w+)/)[1]));
    assert.deepEqual(requests, [], "plain-text labels must not load images");
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    rmSync(dir, { recursive: true, force: true });
  }
});
