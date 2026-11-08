import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Mission Control: the focused monitor's workspaces as a strip along the top,
// and live thumbnails of the previewed workspace's windows below it.
//
//   click a window      focus it (switching workspace if needed)
//   click a workspace   go to it
//   "+"                 go to the first free workspace
//   Esc / click outside close
//   arrows / Enter      move between windows / focus the highlighted one
//   Tab / Shift+Tab     preview the next / previous workspace
//   1-9, 0              go to that workspace
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "rolo.mission-control"
  // Omarchy gives every monitor a block of ten workspaces: 1-10, 11-20, ...
  readonly property int slots: 10

  property bool opened: false

  // Live window thumbnails use Wayland screencopy: the compositor renders every
  // window into a buffer that this shell imports on the GPU. That path is not
  // validated on the J716s yet (the Aurora driver faults on GPU work it does
  // not expect, and a fault takes Hyprland down with every open app), so it is
  // off. Tiles show the app icon and title instead. Flip to true only with the
  // machine's owner at the keyboard.
  property bool liveThumbnails: false

  // Same surface tokens as the menu, so themes that restyle it restyle this.
  readonly property color background: Commons.Color.menu.background
  readonly property color foreground: Commons.Color.menu.text
  readonly property color accent: Commons.Color.menu.selectedText
  readonly property color hoverFill: Commons.Color.menu.selectedBackground
  readonly property color scrim: Qt.rgba(Commons.Color.menu.scrim.r, Commons.Color.menu.scrim.g,
                                         Commons.Color.menu.scrim.b, Math.max(Commons.Color.menu.scrim.a, 0.93))
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int cornerRadius: Math.max(Style.cornerRadius, Style.space(4))

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ------------------------------------------------------------------ state

  readonly property var monitor: panel.targetMonitor
  readonly property string monitorName: monitor ? String(monitor.name || "") : ""

  property var workspaceIds: []      // workspaces shown in the strip, ascending
  property var windowsByWs: ({})     // workspace id -> window records
  property int selectedWorkspace: -1 // the workspace whose windows fill the stage
  property var windows: []           // records of selectedWorkspace, reading order
  property int selectedWindow: -1    // keyboard / hover cursor into `windows`
  property bool cursorActive: false
  property bool initialized: false
  property string lastSignature: ""

  function blockOf(id) { return Math.floor((id - 1) / root.slots) }
  function slotOf(id) { return (id - 1) % root.slots + 1 }

  function activeId() {
    var m = root.monitor
    return m && m.activeWorkspace ? m.activeWorkspace.id : -1
  }

  readonly property int ownBlock: {
    var active = root.activeId()
    return active > 0 ? root.blockOf(active) : 0
  }

  // The number the bar shows: 1-10 inside the monitor's own block, else the id.
  function labelFor(id) {
    return String(root.blockOf(id) === root.ownBlock ? root.slotOf(id) : id)
  }

  function freeSlot() {
    for (var s = 1; s <= root.slots; s++) {
      if (root.workspaceIds.indexOf(root.ownBlock * root.slots + s) === -1) return s
    }
    return 0
  }

  // ---------------------------------------------------------- open / close

  function open(payloadJson) {
    root.initialized = false
    root.lastSignature = ""
    root.selectedWindow = -1
    root.cursorActive = false
    Hyprland.refreshMonitors()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    // Drop every record so the live captures stop with the overlay.
    root.windows = []
    root.windowsByWs = ({})
    root.workspaceIds = []
    root.selectedWorkspace = -1
    root.selectedWindow = -1
    root.cursorActive = false
    root.initialized = false
    root.lastSignature = ""
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ------------------------------------------------------------------ data

  function rebuild() {
    var mon = root.monitor
    if (!mon) return

    var tops = Hyprland.toplevels.values
    var byWs = ({})
    for (var i = 0; i < tops.length; i++) {
      var t = tops[i]
      var ws = t.workspace
      if (!ws || ws.id <= 0) continue                         // special workspaces
      if (t.monitor && t.monitor.name !== mon.name) continue  // another monitor

      var o = t.lastIpcObject || {}
      var at = o.at || [0, 0]
      var size = o.size || [0, 0]
      var w = size[0]
      var h = size[1]
      // Geometry arrives a moment after the window does.
      if (!(w > 0 && h > 0)) { w = Math.round(panel.width * 0.5); h = Math.round(panel.height * 0.6) }

      var rec = {
        address: String(t.address || ""),
        appId: String(o["class"] || (t.wayland ? t.wayland.appId : "") || ""),
        top: t,
        x: at[0] - mon.x,
        y: at[1] - mon.y,
        w: w,
        h: h
      }
      if (!byWs[ws.id]) byWs[ws.id] = []
      byWs[ws.id].push(rec)
    }

    var active = root.activeId()
    var ids = []
    for (var key in byWs) {
      ids.push(parseInt(key, 10))
      byWs[key].sort(function(a, b) {
        var dy = Math.round(a.y / 40) - Math.round(b.y / 40)
        return dy !== 0 ? dy : a.x - b.x
      })
    }
    if (active > 0 && ids.indexOf(active) === -1) ids.push(active)
    ids.sort(function(a, b) { return a - b })

    // Titles change constantly and are bound live, so they stay out of the
    // signature; a thumbnail is rebuilt only when a window or its box changes.
    var parts = []
    for (var n = 0; n < ids.length; n++) {
      var list = byWs[ids[n]] || []
      var row = [ids[n]]
      for (var j = 0; j < list.length; j++) row.push(list[j].address, list[j].x, list[j].y, list[j].w, list[j].h)
      parts.push(row.join(","))
    }
    var signature = parts.join("|") + "@" + active
    if (root.initialized && signature === root.lastSignature) return
    root.lastSignature = signature

    root.windowsByWs = byWs
    root.workspaceIds = ids

    if (!root.initialized) {
      root.initialized = true
      root.selectedWorkspace = active
    } else if (ids.indexOf(root.selectedWorkspace) === -1) {
      root.selectedWorkspace = active
    }
    root.windows = byWs[root.selectedWorkspace] || []

    if (root.selectedWindow >= root.windows.length) root.selectedWindow = root.windows.length - 1
    if (root.windows.length === 0) root.cursorActive = false
  }

  function previewWorkspace(id) {
    if (id === root.selectedWorkspace) return
    root.selectedWorkspace = id
    root.windows = root.windowsByWs[id] || []
    root.selectedWindow = -1
    root.cursorActive = false
  }

  function stepWorkspace(delta) {
    var ids = root.workspaceIds
    if (ids.length === 0) return
    var index = ids.indexOf(root.selectedWorkspace)
    if (index === -1) index = 0
    root.previewWorkspace(ids[(index + delta + ids.length) % ids.length])
  }

  // ---------------------------------------------------------------- actions

  function hyprDispatch(expression) {
    Quickshell.execDetached(["hyprctl", "dispatch", expression])
  }

  function goToWorkspace(id) {
    if (id <= 0) return
    // Names come from Hyprland, but they end up in a Lua expression.
    var safeMonitor = /^[A-Za-z0-9._:-]+$/.test(root.monitorName)
    if (root.blockOf(id) === root.ownBlock && safeMonitor)
      root.hyprDispatch("o.workspaces.focus(" + root.slotOf(id) + ", \"" + root.monitorName + "\")")
    else
      root.hyprDispatch("hl.dsp.focus({ workspace = \"" + id + "\" })")
    root.dismiss()
  }

  function goToSlot(slot) {
    if (slot > 0) root.goToWorkspace(root.ownBlock * root.slots + slot)
  }

  function focusWindow(address) {
    // By address, because a class is not an identity.
    if (!/^0x[0-9a-f]+$/i.test(String(address || ""))) return
    root.hyprDispatch("hl.dsp.focus({window = hl.get_window(\"address:" + address + "\")})")
    root.dismiss()
  }

  function activateCursor() {
    if (root.cursorActive && root.selectedWindow >= 0 && root.selectedWindow < root.windows.length)
      root.focusWindow(root.windows[root.selectedWindow].address)
    else
      root.goToWorkspace(root.selectedWorkspace)
  }

  function moveCursor(delta) {
    var n = root.windows.length
    if (n === 0) return
    if (!root.cursorActive || root.selectedWindow < 0) {
      root.cursorActive = true
      root.selectedWindow = delta < 0 ? n - 1 : 0
    } else {
      root.selectedWindow = (root.selectedWindow + delta + n) % n
    }
  }

  function moveCursorRow(delta) {
    var n = root.windows.length
    if (n === 0) return
    if (!root.cursorActive || root.selectedWindow < 0) {
      root.moveCursor(delta)
      return
    }
    var next = root.selectedWindow + delta * root.layout.cols
    if (next >= 0 && next < n) root.selectedWindow = next
  }

  function iconFor(appId) {
    var entry = appId ? DesktopEntries.heuristicLookup(appId) : null
    var name = entry && entry.icon ? entry.icon : appId
    return (name ? Quickshell.iconPath(name, true) : "") || Quickshell.iconPath("application-x-executable", true)
  }

  // ----------------------------------------------------------------- layout

  readonly property int edge: Style.space(48)
  readonly property int gap: Style.space(20)
  readonly property int labelHeight: Style.space(26)
  readonly property real aspect: panel.height > 0 ? panel.width / panel.height : 1.6
  readonly property int stripCount: root.workspaceIds.length + (root.freeSlot() > 0 ? 1 : 0)
  readonly property real cardWidth: Math.min(Style.space(220),
    (panel.width - root.edge * 2 - root.gap * Math.max(0, root.stripCount - 1)) / Math.max(1, root.stripCount))
  readonly property real cardHeight: root.cardWidth / root.aspect
  readonly property real stripHeight: root.cardHeight + root.labelHeight

  // Pick the column count that leaves the windows biggest, then centre every
  // row (the last one included) and shrink each window to fit its cell.
  function computeLayout(wins, areaW, areaH) {
    var n = wins.length
    var result = { rects: [], cols: 1 }
    if (n === 0 || areaW <= 0 || areaH <= 0) return result

    var gutter = Style.space(28)
    var caption = Style.space(34)
    var best = -1

    for (var cols = 1; cols <= n; cols++) {
      var rows = Math.ceil(n / cols)
      var cw = (areaW - gutter * (cols - 1)) / cols
      var ch = (areaH - gutter * (rows - 1)) / rows - caption
      if (cw <= 0 || ch <= 0) continue

      var rects = []
      var score = 0
      for (var i = 0; i < n; i++) {
        var scale = Math.min(1, cw / wins[i].w, ch / wins[i].h)
        var tw = Math.floor(wins[i].w * scale)
        var th = Math.floor(wins[i].h * scale)
        var r = Math.floor(i / cols)
        var inRow = r < rows - 1 ? cols : n - cols * (rows - 1)
        var offset = (cols - inRow) * (cw + gutter) / 2
        var cellX = offset + (i % cols) * (cw + gutter)
        var cellY = r * (ch + caption + gutter)
        rects.push({ x: Math.round(cellX + (cw - tw) / 2), y: Math.round(cellY + (ch - th) / 2), w: tw, h: th })
        score += tw * th
      }
      if (score > best) { best = score; result = { rects: rects, cols: cols } }
    }
    return result
  }

  readonly property var layout: root.computeLayout(root.windows, stage.width, stage.height)

  Timer {
    interval: 250
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: root.rebuild()
  }

  // Ctrl+Left / Ctrl+Right change workspace under the overlay; follow them.
  Connections {
    target: root.monitor
    function onActiveWorkspaceChanged() {
      if (root.opened && root.initialized) root.rebuild()
      if (root.opened && root.initialized) root.previewWorkspace(root.activeId())
    }
  }

  // ------------------------------------------------------------------- view

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "omarchy-mission-control"

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        var plain = !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
        var reading = Util.readingKey(event)
        if (event.key === Qt.Key_Escape) {
          root.dismiss()
        } else if (reading === Qt.Key_Left && plain) {
          root.moveCursor(-1)
        } else if (reading === Qt.Key_Right && plain) {
          root.moveCursor(1)
        } else if (event.key === Qt.Key_Up && plain) {
          root.moveCursorRow(-1)
        } else if (event.key === Qt.Key_Down && plain) {
          root.moveCursorRow(1)
        } else if (event.key === Qt.Key_Tab) {
          root.stepWorkspace(1)
        } else if (event.key === Qt.Key_Backtab) {
          root.stepWorkspace(-1)
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activateCursor()
        } else if (plain && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
          root.goToSlot(event.key - Qt.Key_0)
        } else if (plain && event.key === Qt.Key_0) {
          root.goToSlot(10)
        } else {
          return
        }
        event.accepted = true
      }
    }

    // ---- workspace strip -------------------------------------------------
    Row {
      id: strip
      anchors.horizontalCenter: parent.horizontalCenter
      y: root.edge
      spacing: root.gap

      Repeater {
        model: root.workspaceIds

        delegate: Column {
          id: workspaceItem
          required property int modelData
          readonly property int wsId: modelData
          readonly property bool previewed: root.selectedWorkspace === wsId
          readonly property bool current: root.activeId() === wsId
          readonly property var wins: root.windowsByWs[wsId] || []
          readonly property real shrink: root.cardWidth / Math.max(1, panel.width)
          spacing: Style.space(6)

          Rectangle {
            id: card
            width: root.cardWidth
            height: root.cardHeight
            radius: root.cornerRadius
            color: root.background
            clip: true
            border.width: workspaceItem.previewed ? 2 : 1
            border.color: workspaceItem.previewed ? root.accent
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)

            // Each window where it sits on the screen, scaled down.
            Repeater {
              model: workspaceItem.wins
              delegate: Item {
                id: mini
                required property var modelData
                x: modelData.x * workspaceItem.shrink
                y: modelData.y * workspaceItem.shrink
                width: Math.max(2, modelData.w * workspaceItem.shrink)
                height: Math.max(2, modelData.h * workspaceItem.shrink)

                Rectangle {
                  anchors.fill: parent
                  radius: 2
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
                }
                Loader {
                  anchors.fill: parent
                  active: root.liveThumbnails
                  sourceComponent: ScreencopyView {
                    captureSource: mini.modelData.top ? mini.modelData.top.wayland : null
                    live: false
                    Component.onCompleted: captureFrame()
                  }
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.previewWorkspace(workspaceItem.wsId)
              onClicked: root.goToWorkspace(workspaceItem.wsId)
            }
          }

          Text {
            textFormat: Text.PlainText
            width: root.cardWidth
            height: root.labelHeight - Style.space(6)
            horizontalAlignment: Text.AlignHCenter
            text: root.labelFor(workspaceItem.wsId)
            color: workspaceItem.previewed ? root.accent : root.foreground
            opacity: workspaceItem.current || workspaceItem.previewed ? 1 : 0.65
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: workspaceItem.current
          }
        }
      }

      // "+": the first workspace in the block that is not listed.
      Column {
        visible: root.freeSlot() > 0
        spacing: Style.space(6)

        Rectangle {
          width: root.cardWidth
          height: root.cardHeight
          radius: root.cornerRadius
          color: addArea.containsMouse ? root.hoverFill : "transparent"
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: "+"
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }

          MouseArea {
            id: addArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.goToSlot(root.freeSlot())
          }
        }

        Text {
          textFormat: Text.PlainText
          width: root.cardWidth
          height: root.labelHeight - Style.space(6)
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          text: strings.t("mission.newWorkspace")
          color: root.foreground
          opacity: 0.65
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }
      }
    }

    // ---- stage: live window thumbnails -------------------------------------
    Item {
      id: stage
      x: root.edge
      y: root.edge + root.stripHeight + Style.space(36)
      width: panel.width - root.edge * 2
      height: panel.height - y - root.edge

      Repeater {
        model: root.windows

        delegate: Item {
          id: tile
          required property int index
          required property var modelData

          readonly property var box: root.layout.rects[index] || ({ x: 0, y: 0, w: 0, h: 0 })
          readonly property bool highlighted: root.cursorActive && root.selectedWindow === index
          readonly property string title: modelData.top && modelData.top.title ? String(modelData.top.title) : ""

          x: box.x
          y: box.y
          width: box.w
          height: box.h

          Rectangle {
            anchors.fill: parent
            radius: root.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
          }

          Loader {
            id: captureLoader
            anchors.fill: parent
            active: root.liveThumbnails
            sourceComponent: ScreencopyView {
              captureSource: tile.modelData.top ? tile.modelData.top.wayland : null
              live: true
            }
          }

          // Until the first frame arrives, if live thumbnails are off, or if
          // the source cannot be captured.
          Image {
            anchors.centerIn: parent
            visible: !(captureLoader.item && captureLoader.item.hasContent)
            width: Math.min(Style.space(64), parent.width, parent.height)
            height: width
            sourceSize: Qt.size(width, height)
            source: root.iconFor(tile.modelData.appId)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
          }

          Rectangle {
            anchors.fill: parent
            anchors.margins: -Style.space(3)
            radius: root.cornerRadius + Style.space(3)
            color: "transparent"
            border.width: tile.highlighted ? Style.space(3) : 0
            border.color: root.accent
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: { root.cursorActive = true; root.selectedWindow = tile.index }
            onClicked: root.focusWindow(tile.modelData.address)
          }

          // App icon and title, centred under the thumbnail.
          Row {
            anchors.top: parent.bottom
            anchors.topMargin: Style.space(8)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(8)

            Image {
              width: Style.space(20)
              height: width
              sourceSize: Qt.size(width, height)
              source: root.iconFor(tile.modelData.appId)
              fillMode: Image.PreserveAspectFit
              asynchronous: true
            }

            Text {
              textFormat: Text.PlainText
              width: Math.min(implicitWidth, Math.max(tile.width, Style.space(160)) - Style.space(28))
              anchors.verticalCenter: parent.verticalCenter
              text: tile.title !== "" ? tile.title : strings.t("mission.untitled")
              color: tile.highlighted ? root.accent : root.foreground
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }
          }
        }
      }

      Text {
        visible: root.opened && root.initialized && root.windows.length === 0
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: strings.t("mission.empty")
        color: root.foreground
        opacity: 0.7
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
      }
    }
  }
}
