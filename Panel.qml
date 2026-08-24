import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Small popup: pause/resume smart routing, see the current fallback browser
// and rule count, and jump to the rules file. All state lives in the JSON
// config the dispatch script also reads — this panel just shells out to the
// same CLI helpers a human would use (see bin/browser-selector-status,
// -toggle, -edit) rather than parsing/writing the file itself.
Panel {
  id: root
  moduleName: "j13y.browser-selector"
  ipcTarget: "j13y.browser-selector"
  manageIpc: false

  property var anchorItem: null

  readonly property string pluginId: "j13y.browser-selector"
  readonly property string binDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + pluginId + "/bin"

  property bool routingEnabled: true
  property string defaultBrowser: ""
  property int rulesCount: 0
  property int urlRulesCount: 0
  property string configPath: ""
  property bool busy: false

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
  }

  function toggleRouting() {
    if (busy || toggleProcess.running) return
    busy = true
    toggleProcess.running = true
  }

  function editConfig() {
    Quickshell.execDetached([root.binDir + "/browser-selector-edit"])
  }

  function open() {
    refresh()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) close(); else open()
  }

  Process {
    id: statusProcess
    command: [root.binDir + "/browser-selector-status"]
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.routingEnabled = data.enabled !== false
          root.defaultBrowser = String(data.default || "")
          root.rulesCount = Number(data.rulesCount || 0)
          root.urlRulesCount = Number(data.urlRulesCount || 0)
          root.configPath = String(data.configPath || "")
        } catch (e) {
          console.warn("browser-selector: could not parse status:", e)
        }
      }
    }
  }

  Process {
    id: toggleProcess
    command: [root.binDir + "/browser-selector-toggle"]
    stdout: StdioCollector {
      id: toggleOut
      waitForEnd: true
      onStreamFinished: {
        root.routingEnabled = text.trim() === "true"
        root.busy = false
      }
    }
  }

  onOpenedChanged: if (opened) refresh()

  KeyboardPanel {
    id: keyboardPanel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: keyboardPanel.fittedContentWidth(Style.space(300))
    contentHeight: keyboardPanel.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      width: parent.width
      spacing: Style.space(12)

      PanelSectionHeader {
        text: "Browser Selector"
        foreground: root.contentForeground
      }

      Row {
        width: parent.width
        spacing: Style.space(10)

        Text {
          width: parent.width - toggleSwitch.width - Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: "Smart routing"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
        }

        ToggleSwitch {
          id: toggleSwitch
          anchors.verticalCenter: parent.verticalCenter
          checked: root.routingEnabled
          busy: root.busy
          foreground: root.contentForeground
          onToggled: root.toggleRouting()
        }
      }

      Text {
        width: parent.width
        wrapMode: Text.Wrap
        color: Qt.darker(root.contentForeground, 1.4)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        text: {
          if (!root.routingEnabled) return "Paused — everything opens in " + root.defaultBrowser
          if (root.rulesCount === 0 && root.urlRulesCount === 0)
            return "No rules yet — everything opens in " + root.defaultBrowser
          var parts = []
          if (root.rulesCount > 0) parts.push(root.rulesCount + " app rule(s)")
          if (root.urlRulesCount > 0) parts.push(root.urlRulesCount + " url rule(s)")
          return parts.join(", ") + " — else opens in " + root.defaultBrowser
        }
      }

      PanelSeparator { foreground: root.contentForeground }

      Button {
        text: "Edit rules"
        foreground: root.contentForeground
        bordered: true
        onClicked: root.editConfig()
      }
    }
  }
}
