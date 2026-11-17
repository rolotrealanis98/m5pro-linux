import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Confirm dialog for "Reboot to Windows". Summoned from the Omarchy menu
// (System > Reboot to Windows). Confirming runs exactly:
//   pkexec /usr/local/sbin/m5w-windows
// which the polkit action org.m5w.windows allows for the active local session.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property var windowsCommand: ["pkexec", "/usr/local/sbin/m5w-windows"]

  function open(payloadJson) {
    confirm.selectedIndex = 0   // Cancel is preselected
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "m5w.reboot-windows")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function confirmed() {
    // Run the command BEFORE dismissing: hide() unloads this plugin, and anything after it never ran
    // (2026-11-15: the first real click did nothing; journal had no pkexec line).
    Quickshell.execDetached(root.windowsCommand)
    root.dismiss()
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "m5w-reboot-windows"

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (confirm.handleKey(event)) event.accepted = true
      }
    }

    ConfirmDialog {
      id: confirm
      anchors.fill: parent
      opened: root.opened
      message: "Restart into Windows now? Windows starts once; after you shut it down or restart, the next boot is Linux again."
      confirmText: "Restart"
      onCanceled: root.dismiss()
      onConfirmed: root.confirmed()
    }
  }
}
