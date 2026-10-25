import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "bridge" as OmasolidBridge

Item {
  id: root

  property var shell: null
  property var config: ({ instance: "", token: "", organization_id: "", member_id: "" })
  readonly property bool configured: !!(config && config.instance && config.token
    && config.organization_id && config.member_id)

  // Live data for the panel.
  property var organizations: []      // [{id, name, is_personal, role, member_id}]
  property var user: ({})
  property var clients: []            // [{id, name}]
  property var projects: []            // [{id, name, color, client_id, client_name, is_billable}]
  property var tasks: []               // [{id, name, project_id, done}]
  property var todayEntries: []        // [{id, description, project_id, project_name, ...}]
  property var activeEntry: null      // entry object or null
  readonly property bool active: !!(activeEntry && activeEntry.running)

  // Elapsed seconds on the running timer, ticked by liveTimer when active.
  property int elapsedSeconds: 0
  readonly property string elapsedLabel: Model.formatElapsed(root.elapsedSeconds)

  // Status flags surfaced to the bar/panel.
  property bool busy: false            // a user-triggered helper call is in flight
  property bool loadingProjects: false
  property bool loadingToday: false
  property string lastError: ""

  // Serialized helper queue. A single Process can only run one command at a
  // time, and refreshAll()/the poll timer fire several calls, so jobs queue up
  // and run one after another. `busy` only reflects *foreground* (user)
  // actions so background polling doesn't flicker the buttons.
  property var _queue: []
  property bool _helperRunning: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/solidtime.json"
  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("solidtime.py"))
    return decodeURIComponent(url.indexOf("file://") === 0 ? url.substring(7) : url)
  }

  function resolveShellService() {
    // Nothing to resolve yet; placeholder mirrors the sandman convention so
    // future cross-plugin lookups keep working.
  }

  function runHelper(args, onResult, foreground) {
    var job = { args: args, onResult: onResult, foreground: !!foreground }
    root._queue.push(job)
    root.pumpQueue()
  }

  // Run a call the user initiated. Sets the busy flag so the panel buttons
  // show a spinner and block re-entry.
  function runForeground(args, onResult) {
    root.busy = true
    runHelper(args, onResult, true)
  }

  // Run a background call (polls, refreshes) that must not block the UI.
  function runBackground(args, onResult) {
    runHelper(args, onResult, false)
  }

  function pumpQueue() {
    if (root._helperRunning) return
    var job = root._queue.shift()
    if (!job) return
    root._helperRunning = true
    helperProcess.callback = job
    helperProcess.command = ["python3", root.helperPath].concat(job.args)
    helperProcess.running = true
  }

  function finishHelperJob(result) {
    root._helperRunning = false
    if (result && !result.ok && root.busy) root.lastError = result.error || "SolidTime request failed"
    var job = helperProcess.callback
    helperProcess.callback = null
    if (job) {
      if (job.foreground) root.busy = false
      if (job.onResult) job.onResult(result)
    }
    root.pumpQueue()
  }

  // --- API: settings / config ---------------------------------------------- #

  function loadConfig() {
    runBackground(["init"], function(result) {
      if (result.ok) root.config = {
        instance: result.instance || "",
        token: result.token || "",
        organization_id: result.organization_id || "",
        member_id: result.member_id || ""
      }
      else root.lastError = result.error
    })
  }

  // Validate credentials against the instance and surface the org list. The
  // QML settings form passes the candidate config so we never persist a token
  // that cannot authenticate. On success the caller chooses an org and calls
  // saveConfig.
  function testConfig(candidate, done) {
    runForeground(["test-config", JSON.stringify(candidate)], function(result) {
      if (!result.ok) { root.lastError = result.error; if (done) done(false, result); return }
      root.user = result.user || {}
      root.organizations = result.organizations || []
      if (done) done(true, result)
    })
  }

  function saveConfig(candidate, done) {
    runForeground(["save-config", JSON.stringify(candidate)], function(result) {
      if (!result.ok) { root.lastError = result.error; if (done) done(false, result); return }
      root.config = {
        instance: result.instance || candidate.instance || "",
        token: result.token || candidate.token || "",
        organization_id: result.organization_id || candidate.organization_id || "",
        member_id: result.member_id || candidate.member_id || ""
      }
      if (done) done(true, result)
      if (root.configured) root.refreshAll()
    })
  }

  // --- API: data ----------------------------------------------------------- #

  function loadProjects() {
    if (!root.configured) return
    root.loadingProjects = true
    root.lastError = ""
    runBackground(["projects"], function(result) {
      root.loadingProjects = false
      if (!result.ok) { root.lastError = result.error; return }
      root.clients = result.clients || []
      root.projects = result.projects || []
      root.tasks = result.tasks || []
    })
  }

  function loadActive() {
    if (!root.configured) { root.activeEntry = null; root.elapsedSeconds = 0; return }
    runBackground(["active"], function(result) {
      if (!result.ok) { root.activeEntry = null; root.elapsedSeconds = 0; return }
      root.activeEntry = result.entry || null
      root.syncElapsed()
    })
  }

  function loadToday() {
    if (!root.configured) { root.todayEntries = []; return }
    root.loadingToday = true
    runBackground(["today"], function(result) {
      root.loadingToday = false
      if (!result.ok) { root.lastError = result.error; return }
      root.todayEntries = result.entries || []
    })
  }

  // --- API: actions -------------------------------------------------------- #

  function startEntry(projectId, taskId, description, done) {
    runForeground(["start", JSON.stringify({
      project_id: projectId, task_id: taskId || "", description: description || ""
    })], function(result) {
      if (!result.ok) { root.lastError = result.error; if (done) done(false, result); return }
      root.activeEntry = result.entry || null
      root.syncElapsed()
      root.loadToday()
      if (done) done(true, result)
    })
  }

  function stopActive(done) {
    runForeground(["stop"], function(result) {
      if (!result.ok) { root.lastError = result.error; if (done) done(false, result); return }
      root.activeEntry = null
      root.elapsedSeconds = 0
      root.loadToday()
      if (done) done(true, result)
    })
  }

  // --- refresh ------------------------------------------------------------- #

  function refreshAll() {
    root.loadActive()
    root.loadProjects()
    root.loadToday()
  }

  // Keep the elapsed counter in sync after the active entry changes.
  function syncElapsed() {
    if (root.active && root.activeEntry && root.activeEntry.start) {
      root.elapsedSeconds = Number(root.activeEntry.duration_seconds || 0)
    } else {
      root.elapsedSeconds = 0
    }
  }

  function clearError() { root.lastError = "" }

  Component.onCompleted: {
    OmasolidBridge.Bridge.service = root
    root.loadConfig()
    // The Timer object is not yet part of the scene when onCompleted first
    // runs, so schedule the start through callLater.
    Qt.callLater(function() {
      refreshTimer.start()
    })
  }
  Component.onDestruction: if (OmasolidBridge.Bridge.service === root) OmasolidBridge.Bridge.service = null

  onConfiguredChanged: if (root.configured) root.refreshAll()

  // Background poll: refresh the active timer + today's entries every minute
  // so the bar stays accurate even while the panel is closed.
  Timer {
    id: refreshTimer
    interval: 60000
    repeat: true
    onTriggered: {
      if (root.configured) {
        root.loadActive()
        root.loadToday()
      }
    }
  }

  // Tick the live elapsed-seconds counter every second while a timer runs.
  Timer {
    id: liveTimer
    interval: 1000
    repeat: true
    running: root.active
    onTriggered: root.elapsedSeconds = root.elapsedSeconds + 1
  }

  Process {
    id: helperProcess
    property var callback: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.parseResult(String(text))
        root.finishHelperJob(result)
      }
    }
    onExited: function(exitCode) {
      // If the helper exits without the stdout collector ever reporting its
      // finished stream (missing interpreter, hard crash), release any pending
      // callback with a generic error so the UI unblocks and calls can retry.
      if (exitCode !== 0 && helperProcess.callback) {
        root.finishHelperJob({ ok: false, error: "SolidTime helper exited with code " + exitCode })
      }
    }
  }
}
