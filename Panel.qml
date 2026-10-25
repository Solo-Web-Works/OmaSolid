import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "bridge" as OmasolidBridge

Panel {
  id: root
  moduleName: "ksolomon.omasolid"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var omasolidService: null
  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // Draft selection for the "start a timer" form.
  property string draftClient: ""
  property string draftProject: ""
  property string draftTask: ""
  property string draftDescription: ""
  property bool creatingProject: false
  property string draftNewProjectName: ""

  // Draft settings for the "configure" form (kept locally until Save).
  property string draftInstance: ""
  property string draftToken: ""
  property string draftOrg: ""
  property bool testing: false
  property bool saved: false

  // ----- convenience accessors over the live service -----------------------
  readonly property var svc: root.omasolidService
  readonly property bool configured: svc ? svc.configured : false
  readonly property bool active: svc ? svc.active : false

  function open() { root.controller.show() }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function scrollPanel(delta) {
    panelFlick.contentY = Math.max(0, Math.min(
      panelFlick.contentY + delta,
      Math.max(0, panelFlick.contentHeight - panelFlick.height)))
  }

  // ----- settings helpers ---------------------------------------------------

  function loadSettingsDrafts() {
    if (!svc) return
    root.draftInstance = svc.config.instance || ""
    root.draftToken = svc.config.token || ""
    root.draftOrg = svc.config.organization_id || ""
    root.testing = false
    root.saved = false
  }

  function candidateConfig() {
    return {
      instance: Model.normalizeInstance(root.draftInstance),
      token: root.draftToken.trim(),
      organization_id: root.draftOrg,
      member_id: svc ? Model.memberIdForOrg(svc.organizations, root.draftOrg) : ""
    }
  }

  function runTest() {
    if (!svc) return
    root.testing = true
    svc.testConfig(root.candidateConfig(), function(ok) {
      root.testing = false
    })
  }

  function runSave() {
    if (!svc) return
    root.saved = true
    svc.saveConfig(root.candidateConfig())
  }

  // ----- start/stop helpers -------------------------------------------------

  function refreshSelections() {
    // Keep the draft project valid after a reload; drop project/client/task
    // references that no longer resolve.
    if (root.draftProject && !Model.projectOptions(svc.projects, root.draftClient).some(function(o) {
          return o.value === root.draftProject
        })) root.draftProject = ""
    if (root.draftTask && !Model.taskOptions(root.draftProject, svc.tasks).some(function(o) {
          return o.value === root.draftTask
        })) root.draftTask = ""
  }

  function canStart() {
    return !!root.draftProject && !svc.busy
  }

  function startTimer() {
    if (!root.canStart()) return
    svc.startEntry(root.draftProject, root.draftTask, root.draftDescription, function(ok) {
      if (ok) root.close()
    })
  }

  function stopTimer() {
    if (svc) svc.stopActive()
  }

  function canCreateProject() {
    return root.draftNewProjectName.trim() !== "" && svc && !svc.busy
  }

  function createNewProject() {
    if (!root.canCreateProject()) return
    svc.createProject(root.draftNewProjectName, root.draftClient, function(ok, result) {
      if (ok && result.project && result.project.id) {
        root.draftProject = result.project.id
        root.draftNewProjectName = ""
        root.creatingProject = false
      }
    })
  }

  onOpenedChanged: {
    if (opened) {
      root.loadSettingsDrafts()
      if (svc) {
        svc.clearError()
        if (svc.configured) {
          svc.loadProjects()
          svc.loadActive()
          svc.loadToday()
          Qt.callLater(root.refreshSelections)
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.scrollPanel(dy * Style.space(56))
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        WheelHandler {
          onWheel: function(event) {
            if (event.angleDelta.y === 0) return
            root.scrollPanel(event.angleDelta.y > 0 ? -Style.space(56) : Style.space(56))
            event.accepted = true
          }
        }

        Column {
          id: content
          width: panelFlick.width
          spacing: Style.space(12)

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(14)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󱂈"
              color: Color.accent
              font.family: root.contentFontFamily
              font.pixelSize: Style.space(40)
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "SolidTime"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                text: root.statusSubtitle()
                color: Util.alpha(root.contentForeground, 0.64)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                width: panel.fittedContentWidth(Style.space(300))
                elide: Text.ElideRight
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ------------------------------------------------------------------
          // Not configured: settings form.
          // ------------------------------------------------------------------
          Column {
            id: settingsSection
            width: parent.width
            spacing: Style.space(10)
            visible: !root.configured

            PanelSectionHeader {
              width: parent.width
              text: "CONNECT"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
            }

            Text {
              width: parent.width
              text: "Point this widget at your SolidTime instance and authenticate."
              color: Util.alpha(root.contentForeground, 0.64)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

              TextField {
                id: instanceField
                width: parent.width
                placeholderText: "https://solidtime.example.com"
                text: root.draftInstance
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                onTextChanged: root.draftInstance = text
              }

              TextField {
                id: tokenField
                width: parent.width
                password: true
                placeholderText: "API token"
                text: root.draftToken
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                onTextChanged: root.draftToken = text
              }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: (parent.width - Style.space(8)) / 2
                text: root.testing ? "Checking…" : "Validate & load"
                enabled: !root.testing && root.draftInstance.trim() !== "" && root.draftToken.trim() !== ""
                focusable: true
                bordered: true
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                iconText: root.testing ? "󰲄" : ""
                iconSpinning: root.testing
                onClicked: root.runTest()
              }

              Button {
                width: (parent.width - Style.space(8)) / 2
                text: "Open in browser"
                focusable: true
                bordered: true
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: Qt.openUrlExternally(Model.normalizeInstance(root.draftInstance))
              }
            }

            Text {
              visible: svc && svc.organizations.length > 0
              width: parent.width
              text: "Choose the organization to track time in"
              color: Util.alpha(root.contentForeground, 0.64)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            SearchableDropdown {
              visible: svc && svc.organizations.length > 0
              width: parent.width
              label: "Organization"
              value: root.draftOrg
              options: Model.orgOptions(svc.organizations)
              placeholderText: "Select organization…"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onChanged: root.draftOrg = value
            }

            Button {
              visible: svc && svc.organizations.length > 0
              width: parent.width
              text: "Save & connect"
              enabled: root.draftOrg !== "" && !svc.busy
              focusable: true
              bordered: true
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.runSave()
            }

            Text {
              visible: svc && svc.user && svc.user.name !== ""
              width: parent.width
              text: "Signed in as " + (svc.user.name || "") + (svc.user.email ? " (" + svc.user.email + ")" : "")
              color: Util.alpha(root.contentForeground, 0.64)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ------------------------------------------------------------------
          // Configured: tracking UI.
          // ------------------------------------------------------------------
          Column {
            id: trackingSection
            width: parent.width
            spacing: Style.space(10)
            visible: root.configured

            // --- active entry ---
            Column {
              width: parent.width
              spacing: Style.space(7)
              visible: root.active

              PanelSectionHeader {
                width: parent.width
                text: "RUNNING"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
              }

              Row {
                width: parent.width
                spacing: Style.space(10)

                Column {
                  width: parent.width - stopButton.width - Style.space(10)
                  spacing: Style.space(2)

                  Text {
                    text: svc && svc.activeEntry && svc.activeEntry.project_name
                      ? svc.activeEntry.project_name : "Active timer"
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Text {
                    text: (svc.activeEntry && svc.activeEntry.description
                      ? svc.activeEntry.description + " · " : "")
                      + (svc ? svc.elapsedLabel : "")
                    color: Util.alpha(root.contentForeground, 0.64)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                Button {
                  id: stopButton
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Stop"
                  enabled: !svc.busy
                  focusable: true
                  bordered: true
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.stopTimer()
                }
              }
            }

            // --- start a new timer ---
            Column {
              width: parent.width
              spacing: Style.space(7)
              visible: root.configured

              PanelSectionHeader {
                width: parent.width
                text: "NEW TIME ENTRY"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
              }

              Text {
                width: parent.width
                text: "Pick a client and project, optionally a task, add a note, then start."
                color: Util.alpha(root.contentForeground, 0.64)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              SearchableDropdown {
                id: clientDropdown
                width: parent.width
                label: "Client"
                value: root.draftClient
                options: Model.clientOptions(svc.clients)
                placeholderText: "All clients…"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: svc && !svc.loadingProjects
                onChanged: {
                  root.draftClient = value
                  root.draftProject = ""
                  root.draftTask = ""
                }
              }

              SearchableDropdown {
                id: projectDropdown
                width: parent.width
                label: "Project"
                value: root.draftProject
                options: Model.projectOptions(svc.projects, root.draftClient)
                placeholderText: "Select project…"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: svc && !svc.loadingProjects
                onChanged: {
                  root.draftProject = value
                  root.draftTask = ""
                }
              }

              Button {
                visible: !root.creatingProject
                width: parent.width
                text: "+ Create new project"
                focusable: true
                bordered: true
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: {
                  root.creatingProject = true
                  root.draftNewProjectName = ""
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.creatingProject

                PanelSectionHeader {
                  width: parent.width
                  text: "NEW PROJECT"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                }

                TextField {
                  id: newProjectNameField
                  width: parent.width
                  placeholderText: "Project name"
                  text: root.draftNewProjectName
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  onTextChanged: root.draftNewProjectName = text
                  onAccepted: if (root.canCreateProject()) root.createNewProject()
                }

                Text {
                  width: parent.width
                  text: root.draftClient ? "Will be added under selected client" : "No client selected (unassigned)"
                  color: Util.alpha(root.contentForeground, 0.64)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Button {
                    width: (parent.width - Style.space(8)) / 2
                    text: svc && svc.busy ? "Creating…" : "Create project"
                    enabled: root.canCreateProject()
                    focusable: true
                    bordered: true
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    iconText: svc && svc.busy ? "󰲄" : "󰐕"
                    iconSpinning: svc && svc.busy
                    onClicked: root.createNewProject()
                  }

                  Button {
                    width: (parent.width - Style.space(8)) / 2
                    text: "Cancel"
                    focusable: true
                    bordered: true
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: {
                      root.creatingProject = false
                      root.draftNewProjectName = ""
                    }
                  }
                }
              }

              SearchableDropdown {
                id: taskDropdown
                width: parent.width
                label: "Task (optional)"
                value: root.draftTask
                options: Model.taskOptions(root.draftProject, svc.tasks)
                placeholderText: "No task…"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: svc && !svc.loadingProjects
                onChanged: root.draftTask = value
              }

              TextField {
                id: descriptionField
                width: parent.width
                placeholderText: "What are you working on?"
                text: root.draftDescription
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                onTextChanged: root.draftDescription = text
                onAccepted: if (root.canStart()) root.startTimer()
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  width: (parent.width - Style.space(8)) / 2
                  text: "Start timer"
                  enabled: root.canStart()
                  focusable: true
                  bordered: true
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  iconText: svc && svc.busy ? "󰲄" : "󰔛"
                  iconSpinning: svc && svc.busy
                  onClicked: root.startTimer()
                }

                Button {
                  width: (parent.width - Style.space(8)) / 2
                  text: "Reconfigure"
                  focusable: true
                  bordered: true
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.configuredPanel()
                }
              }
            }

            // --- today's entries ---
            Column {
              width: parent.width
              spacing: Style.space(7)
              visible: root.configured

              PanelSeparator { width: parent.width }

              PanelSectionHeader {
                width: parent.width
                text: "TODAY"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
              }

              Row {
                width: parent.width
                spacing: Style.space(10)

                Text {
                  width: parent.width - refreshButton.width - Style.space(10)
                  text: svc && svc.todayEntries.length > 0
                    ? svc.todayEntries.length + " entries · " + root.todayTotalLabel()
                    : "No time entries yet today"
                  color: Util.alpha(root.contentForeground, 0.64)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  verticalAlignment: Text.AlignVCenter
                }

                Button {
                  id: refreshButton
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Refresh"
                  enabled: svc && !svc.loadingToday && !svc.busy
                  focusable: true
                  bordered: true
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: if (svc) svc.loadToday()
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: svc && svc.todayEntries.length > 0

                Repeater {
                  model: svc ? svc.todayEntries.slice(0, 8) : []

                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                      width: parent.width - durationText.width - Style.space(8)
                      text: (modelData.project_name ? modelData.project_name + " — " : "")
                        + (modelData.description && modelData.description !== "" ? modelData.description : "No description")
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                      verticalAlignment: Text.AlignVCenter
                    }

                    Text {
                      id: durationText
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.duration
                      color: Util.alpha(root.contentForeground, 0.7)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                }

                Text {
                  visible: svc && svc.todayEntries.length > 8
                  width: parent.width
                  text: "+" + (svc.todayEntries.length - 8) + " more…"
                  color: Util.alpha(root.contentForeground, 0.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // --- reconfigure form (inline) ---
            Column {
              id: reconfigureForm
              width: parent.width
              spacing: Style.space(10)
              visible: root.reconfiguring

              PanelSeparator { width: parent.width }

              PanelSectionHeader {
                width: parent.width
                text: "RECONFIGURE"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
              }

              TextField {
                width: parent.width
                placeholderText: "https://solidtime.example.com"
                text: root.draftInstance
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                onTextChanged: root.draftInstance = text
              }

              TextField {
                width: parent.width
                password: true
                placeholderText: "API token"
                text: root.draftToken
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                onTextChanged: root.draftToken = text
              }

              SearchableDropdown {
                width: parent.width
                label: "Organization"
                value: root.draftOrg
                options: Model.orgOptions(svc.organizations)
                placeholderText: "Select organization…"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onChanged: root.draftOrg = value
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  width: (parent.width - Style.space(8)) / 2
                  text: root.testing ? "Checking…" : "Validate"
                  enabled: !root.testing && root.draftInstance.trim() !== "" && root.draftToken.trim() !== ""
                  focusable: true
                  bordered: true
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.runTest()
                }

                Button {
                  width: (parent.width - Style.space(8)) / 2
                  text: "Save"
                  enabled: root.draftOrg !== "" && !svc.busy
                  focusable: true
                  bordered: true
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: {
                    root.runSave()
                    root.reconfiguring = false
                  }
                }
              }
            }
          }

          // ------------------------------------------------------------------
          // Footer: errors and status.
          // ------------------------------------------------------------------
          Text {
            visible: svc && svc.lastError !== ""
            width: parent.width
            text: svc ? svc.lastError : ""
            color: Color.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  property bool reconfiguring: false
  function configuredPanel() {
    root.reconfiguring = true
    root.loadSettingsDrafts()
  }

  function statusSubtitle() {
    if (!svc) return "Unavailable"
    if (svc.lastError) return "An error occurred — open to see details"
    if (!svc.configured) return "Not connected to a SolidTime instance"
    if (svc.active) return "Running on " + (svc.activeEntry && svc.activeEntry.project_name ? svc.activeEntry.project_name : "a project")
    return "Ready to track time"
  }

  function todayTotalLabel() {
    if (!svc) return "0:00"
    var seconds = 0
    var list = svc.todayEntries || []
    for (var i = 0; i < list.length; i++) seconds += Number(list[i].duration_seconds || 0)
    return Model.formatElapsed(seconds)
  }
}
