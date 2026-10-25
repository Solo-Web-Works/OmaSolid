pragma Singleton
import QtQuick

// Replacement bars (e.g. ruixen.bar) get a widget facade whose serviceFor()
// always returns null, so Service.qml publishes itself here for BarWidget.qml
// and Panel.qml to fall back on.
QtObject {
  property var service: null
}
