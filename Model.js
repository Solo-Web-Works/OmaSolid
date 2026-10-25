.pragma library

// Pure data helpers shared by Service.qml, BarWidget.qml, and Panel.qml.
// No Qt imports here — keep this file framework-free so it is trivially
// testable and safe to import from anywhere.

var apiBase = "/api/v1"

// Parse the JSON line printed by the Python helper. Helper output is exactly
// one JSON object terminated by a newline, so the first JSON.parse is enough.
// Returns {ok: bool, ...payload} and never throws.
function parseResult(raw) {
  var text = String(raw || "")
  if (!text) return { ok: false, error: "No response from SolidTime helper" }
  try {
    var parsed = JSON.parse(text)
  } catch (error) {
    return { ok: false, error: "Could not read the SolidTime response" }
  }
  if (!parsed || typeof parsed !== "object") {
    return { ok: false, error: "Unexpected SolidTime response" }
  }
  var ok = parsed._ok !== false
  var copy = {}
  for (var key in parsed) {
    if (parsed.hasOwnProperty(key) && key !== "_ok") copy[key] = parsed[key]
  }
  if (!ok && !copy.error) copy.error = "SolidTime request failed"
  copy.ok = ok
  return copy
}

// Normalize a user-entered instance URL: strip trailing slashes and ensure a
// scheme. Empty stays empty so the settings field can show its placeholder.
function normalizeInstance(value) {
  var url = String(value || "").trim()
  if (!url) return ""
  url = url.replace(/\/+$/, "")
  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(url)) url = "https://" + url
  return url
}

// Build an option list for SearchableDropdown from a projects array, filtered
// by an optional client id. Each option carries a description line so the
// picker can show the client name under the project title.
function projectOptions(projects, clientId) {
  var out = []
  var list = projects || []
  for (var i = 0; i < list.length; i++) {
    var p = list[i] || {}
    var cid = String(p.client_id || "")
    if (clientId !== undefined && clientId !== "" && cid !== String(clientId)) continue
    out.push({
      value: String(p.id || ""),
      label: String(p.name || "(unnamed)"),
      description: String(p.client_name || (cid ? "" : "No client"))
    })
  }
  return out
}

function clientOptions(clients) {
  var out = []
  var list = clients || []
  for (var i = 0; i < list.length; i++) {
    var c = list[i] || {}
    out.push({ value: String(c.id || ""), label: String(c.name || "(unnamed client)") })
  }
  return out
}

function taskOptions(projectId, tasks) {
  var out = []
  var list = tasks || []
  for (var i = 0; i < list.length; i++) {
    var t = list[i] || {}
    if (projectId && String(t.project_id) !== String(projectId)) continue
    out.push({
      value: String(t.id || ""),
      label: String(t.name || "(unnamed task)"),
      description: t.done ? "done" : ""
    })
  }
  return out
}

function orgOptions(orgs) {
  var out = []
  var list = orgs || []
  for (var i = 0; i < list.length; i++) {
    var o = list[i] || {}
    out.push({
      value: String(o.id || ""),
      label: String(o.name || "(unnamed org)"),
      description: o.is_personal ? "Personal" : (o.role || "")
    })
  }
  return out
}

// Find the member_id for a chosen organization id from a memberships list.
function memberIdForOrg(orgs, orgId) {
  var list = orgs || []
  for (var i = 0; i < list.length; i++) {
    if (String((list[i] || {}).id) === String(orgId)) return String(list[i].member_id || "")
  }
  return ""
}

// Format a running-elapsed duration for the bar from whole seconds.
function formatElapsed(seconds) {
  var value = Math.max(0, Math.floor(Number(seconds) || 0))
  var hours = Math.floor(value / 3600)
  var minutes = Math.floor((value % 3600) / 60)
  var secs = value % 60
  if (hours > 0) return hours + ":" + pad(minutes) + ":" + pad(secs)
  return minutes + ":" + pad(secs)
}

function pad(n) { return (n < 10 ? "0" : "") + n }

// Pick a Nerdfont glyph for the bar icon depending on state.
function barGlyph(active, error) {
  if (error) return "󰜺"
  if (active) return "󰔚"
  return "󰔛"
}
