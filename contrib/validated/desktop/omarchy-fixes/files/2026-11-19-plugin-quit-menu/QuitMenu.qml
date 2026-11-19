import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Right-click menu for a rolo.* bar widget: the widget's quick actions, then Quit.
// Quit stops (and disables) the plugin's own user services, then disables the plugin so it
// leaves the bar; Omarchy menu → Plugins brings it back. Same file in every rolo.* bar plugin.
Item {
  id: root

  property Item anchorItem: null
  property QtObject bar: null
  property string pluginId: ""
  property string pluginName: ""
  property var services: []   // systemd --user units: disable --now on Quit
  property var actions: []    // [{ label, icon, enabled, run }]
  property bool opened: false
  property bool popoutSwitchClosing: false
  property int cursorIndex: -1

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var rows: (actions || []).filter(function(a) { return !!a })
    .concat([{ label: "Quit " + pluginName, icon: "󰈆", quit: true }])

  visible: false
  width: 0
  height: 0

  function open() { cursorIndex = -1; opened = true }
  function close() { opened = false }
  function closeForPopoutSwitch() { close() }
  function toggle() { opened ? close() : open() }

  function quote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

  function quit() {
    var cmd = ""
    for (var i = 0; i < services.length; i++) cmd += "systemctl --user disable --now " + quote(services[i]) + "; "
    cmd += "omarchy plugin disable " + quote(pluginId)
    Quickshell.execDetached(["sh", "-c", cmd])
  }

  function trigger(i) {
    var r = rows[i]
    if (!r || r.enabled === false) return
    close()
    if (r.quit) quit()
    else if (typeof r.run === "function") r.run()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(230))
    contentHeight: panel.fittedContentHeight(menuColumn.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) {
        if (dy === 0 || root.rows.length === 0) return
        var n = root.rows.length
        root.cursorIndex = root.cursorIndex < 0 ? (dy > 0 ? 0 : n - 1) : (root.cursorIndex + dy + n) % n
      }
      onActivateRequested: if (root.cursorIndex >= 0) root.trigger(root.cursorIndex)
      onReturnRequested: if (root.cursorIndex >= 0) root.trigger(root.cursorIndex)

      Column {
        id: menuColumn
        width: parent.width

        Repeater {
          model: root.rows

          delegate: Rectangle {
            id: row
            required property var modelData
            required property int index
            readonly property bool usable: modelData.enabled !== false
            readonly property bool hot: usable && (rowMouse.containsMouse || root.cursorIndex === index)

            width: menuColumn.width
            height: Style.spacing.popupRowHeight
            radius: Style.cornerRadius
            color: hot ? Style.hoverFill : "transparent"
            opacity: usable ? 1 : 0.45

            Rectangle {
              visible: !!row.modelData.quit && root.rows.length > 1
              anchors.top: parent.top
              width: parent.width
              height: 1
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
            }

            Text {
              id: rowIcon
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(18)
              textFormat: Text.PlainText
              text: row.modelData.icon || ""
              color: row.modelData.quit ? Commons.Color.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              anchors.left: rowIcon.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.controlPaddingX
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: row.modelData.label || ""
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: row.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.trigger(row.index)
            }
          }
        }
      }
    }
  }
}
