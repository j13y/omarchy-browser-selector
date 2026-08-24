import QtQuick
import qs.Commons
import qs.Ui

// Bar icon + host for the settings panel, same Loader pattern as the
// built-in Clock/Weather widgets: this file owns the bar button, Panel.qml
// owns the popup content.
BarWidget {
  id: root
  moduleName: "j13y.browser-selector"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
  }

  onBarChanged: injectPanel()

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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-fa-globe (U+F0AC). Picked over a plain unicode arrow because it
    // reads instantly as "browser/web" — rendered and visually checked in
    // JetBrainsMono Nerd Font (the shell's default) before committing to it.
    text: ""
    horizontalMargin: 8.75
    onPressed: function(b) { root.togglePanel() }
  }
}
