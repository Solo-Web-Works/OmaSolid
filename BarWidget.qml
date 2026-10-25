import QtQuick
import Quickshell
import qs.Ui
import "Model.js" as Model
import "bridge" as OmasolidBridge

BarWidget {
  id: root
  moduleName: "ksolomon.omasolid"

  // Replacement bars cannot resolve services through bar.shell; see bridge/Bridge.qml.
  // If no service instance exists yet, spin one up locally so the widget
  // is fully self-contained and never depends on shell service loading.
  readonly property var omasolidService: {
    var viaHost = bar && bar.shell && typeof bar.shell.serviceFor === "function"
      ? bar.shell.serviceFor("ksolomon.omasolid") : null
    return viaHost || OmasolidBridge.Bridge.service || localService
  }
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { panelLoader.item ? panelLoader.item.toggle() : undefined }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.omasolidService = root.omasolidService
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onOmasolidServiceChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Last-resort local service instance. Ensures the panel works even when
  // the shell's service loader hasn't been asked to start this plugin's
  // Service.qml (e.g. a plugin that is "enabled" but whose service entry
  // point was not requested by the bar).
  Loader {
    id: serviceLoader
    active: true
    source: Qt.resolvedUrl("Service.qml")
    visible: false
  }
  readonly property var localService: serviceLoader.item

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // While a timer runs, show the live elapsed clock; otherwise the static
    // time-tracker glyph. The elapsed value updates every second so the bar
    // visibly counts up.
    text: {
      var svc = root.omasolidService
      if (svc && svc.lastError) return Model.barGlyph(false, true)
      if (svc && svc.active && svc.elapsedSeconds > 0)
        return svc.elapsedLabel
      if (svc && svc.active) return Model.barGlyph(true, false)
      return Model.barGlyph(false, false)
    }
    tooltipText: {
      var svc = root.omasolidService
      if (svc && svc.lastError) return "SolidTime: " + svc.lastError
      if (svc && svc.active) {
        var name = svc.activeEntry && svc.activeEntry.project_name ? svc.activeEntry.project_name : "timer"
        return "SolidTime running on " + name + " — " + svc.elapsedLabel
      }
      if (svc && svc.configured) return "SolidTime: no timer running"
      return "SolidTime not configured"
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) {
        // Right-click: quickly stop the running timer without opening the panel.
        if (root.omasolidService && root.omasolidService.active) root.omasolidService.stopActive()
      }
    }
  }
}
