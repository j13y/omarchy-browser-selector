import QtQuick
import Quickshell
import Quickshell.Io

// First-run setup, run once whenever this plugin loads (shell startup, or
// `omarchy plugin enable`): registers bin/browser-selector-dispatch as the
// default handler for http/https links. The actual routing logic lives
// entirely in that shell script and keeps working independent of whether
// the shell is even running — this just makes sure it's installed.
//
// Re-running install is safe: it only (re)writes its own .desktop file and
// the http/https mime association. It never touches the user's rules file
// once created (see bin/lib.sh ensure_config).
QtObject {
  id: root

  // Third-party plugins always live at ~/.config/omarchy/plugins/<id>/ —
  // must match manifest.json's "id".
  readonly property string pluginId: "j13y.browser-selector"
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + pluginId

  property Process installProcess: Process {
    command: [root.pluginDir + "/bin/browser-selector-install"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.length > 0)
          console.warn("browser-selector: install script reported:", text)
      }
    }
  }

  Component.onCompleted: installProcess.running = true
}
