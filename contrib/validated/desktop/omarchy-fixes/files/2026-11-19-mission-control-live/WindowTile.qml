import QtQuick
import Quickshell
import Quickshell.Wayland

// One window on the stage. At progress 0 it sits exactly where the real window
// is on the desktop; at 1 it is at its place in the spread.
Item {
  id: tile

  required property var mc
  required property string addr
  required property int ws
  required property real rx
  required property real ry
  required property real rw
  required property real rh
  required property string appId
  required property int stack
  required property bool focused

  readonly property var toplevel: mc.tops[addr] || null
  readonly property var target: mc.targets[addr] || ({ x: rx, y: ry, w: rw, h: rh })
  readonly property int wsIndex: mc.spaceIds.indexOf(ws)
  readonly property bool activePage: ws === mc.activeWs
  readonly property bool onScreen: wsIndex >= 0 && Math.abs(wsIndex - mc.page) < 1.02
  // The workspaces on either side keep their pictures ready for a swipe.
  readonly property bool near: wsIndex >= 0 && Math.abs(wsIndex - mc.page) < 1.6
  readonly property bool highlighted: mc.settled && !mc.dragTile && (mc.hoverAddr === addr || mc.selAddr === addr)
  readonly property bool dragging: mc.dragTile === tile
  readonly property string title: toplevel && toplevel.title ? String(toplevel.title) : ""
  property bool hasContent: false

  // Hyprland now and then refuses a frame and the recording ends with it. The
  // picture is then made afresh, the same way as on every opening, a few
  // times at most per opening.
  property bool recapturing: false
  property int recaptures: 0
  function captureStopped() {
    if (!mc.mapped || !near || recapturing) return
    console.info("capture stopped: " + appId + " on workspace " + ws + " (showing " + mc.activeWs + "), had a picture: " + hasContent + ", try " + recaptures)
    if (recaptures >= 4) return
    recaptures += 1
    recapturing = true
    recaptureTimer.restart()
  }
  Timer { id: recaptureTimer; interval: 80; onTriggered: tile.recapturing = false }
  Connections {
    target: tile.mc
    function onMappedChanged() { tile.recaptures = 0; tile.recapturing = false }
  }

  // The spread position. Animated when the spread changes under an open
  // overview (a window closed or moved away), never during open and close.
  property real tx: target.x
  property real ty: target.y
  property real tw: target.w
  property real th: target.h
  Behavior on tx { enabled: tile.mc.layoutAnimated; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
  Behavior on ty { enabled: tile.mc.layoutAnimated; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
  Behavior on tw { enabled: tile.mc.layoutAnimated; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
  Behavior on th { enabled: tile.mc.layoutAnimated; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

  // Dragging: the tile follows the pointer and shrinks as it nears the strip.
  property real dragX: 0
  property real dragY: 0
  property real grabX: 0
  property real grabY: 0
  property real dragScale: 1
  property bool dropped: false
  Behavior on dragX { enabled: !tile.dragging && !tile.dropped; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
  Behavior on dragY { enabled: !tile.dragging && !tile.dropped; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
  Behavior on dragScale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

  readonly property real p: mc.progress
  x: rx + (tx - rx) * p + (wsIndex - mc.page) * mc.pageStride + dragX
  y: ry + (ty - ry) * p + dragY
  width: rw + (tw - rw) * p
  height: rh + (th - rh) * p
  visible: onScreen
  z: dragging ? 100000 : (mc.raisedAddr === addr ? 50000 : (highlighted ? 40000 : 10000 + stack))
  opacity: dropped ? 0 : 1
  Behavior on opacity { NumberAnimation { duration: 140 } }
  // Dropped on another workspace: come back once it has moved there (or did not).
  onWsChanged: { dragX = 0; dragY = 0; dragScale = 1; dropped = false }
  Timer { interval: 900; running: tile.dropped; onTriggered: { tile.dragX = 0; tile.dragY = 0; tile.dragScale = 1; tile.dropped = false } }
  transform: Scale { origin.x: tile.grabX; origin.y: tile.grabY; xScale: tile.dragScale; yScale: tile.dragScale }

  // A soft edge instead of a blurred shadow: three faint rings.
  Repeater {
    model: 3
    Rectangle {
      required property int index
      anchors.fill: parent
      anchors.margins: -(index + 1) * 2
      radius: 6 + (index + 1) * 2
      color: "transparent"
      border.width: 2
      border.color: Qt.rgba(0, 0, 0, (0.22 - index * 0.07) * Math.min(1, tile.p * 1.5))
    }
  }

  // The desktop's own window border, fading away as the window leaves its place.
  Rectangle {
    anchors.fill: parent
    anchors.margins: -tile.mc.borderSize
    radius: tile.mc.rounding + tile.mc.borderSize
    color: "transparent"
    border.width: tile.mc.borderSize
    border.color: tile.focused ? tile.mc.activeBorder : tile.mc.inactiveBorder
    opacity: Math.max(0, 1 - tile.mc.shown * 2.5)
    visible: opacity > 0 && tile.mc.borderSize > 0
  }

  // The picture is laid out at the window's own size, one texel per pixel,
  // copied offscreen at that size, and scaled once on its way to the screen
  // by picture.frag. (Laying it out at the tile's size would resample it
  // twice, at a size that steps in whole pixels as the tile shrinks: text
  // blurs and jitters.) The offscreen copy is as large as the window, so it
  // only exists while the overview is in use.
  Loader {
    width: Math.max(1, tile.rw)
    height: Math.max(1, tile.rh)
    transform: Scale { xScale: tile.width / Math.max(1, tile.rw); yScale: tile.height / Math.max(1, tile.rh) }
    active: tile.mc.mapped && tile.near
    onActiveChanged: if (!active) tile.hasContent = false

    sourceComponent: Item {
      id: picture

      // What the shader reads: the window's picture, texel for pixel.
      Item {
        id: content
        anchors.fill: parent

        // Shown until the first frame arrives, and for windows that cannot be captured.
        Rectangle {
          anchors.fill: parent
          visible: !tile.hasContent
          color: tile.mc.cardColor
          Image {
            anchors.centerIn: parent
            width: Math.min(96, parent.width * 0.5, parent.height * 0.5)
            height: width
            sourceSize: Qt.size(144, 144)
            source: tile.mc.iconFor(tile.appId)
            asynchronous: true
          }
        }

        Loader {
          anchors.fill: parent
          active: tile.mc.captureOn && !tile.recapturing && !!tile.toplevel && !!tile.toplevel.wayland
          sourceComponent: ScreencopyView {
            captureSource: tile.toplevel ? tile.toplevel.wayland : null
            paintCursor: false
            live: true
            onHasContentChanged: {
              tile.hasContent = hasContent
              if (hasContent) tile.mc.tileReady(tile.addr)
            }
            onStopped: tile.captureStopped()
          }
        }
      }

      ShaderEffectSource {
        id: texels
        sourceItem: content
        hideSource: true
        live: true
        smooth: true
        textureSize: Qt.size(Math.ceil(picture.width * tile.mc.dpr), Math.ceil(picture.height * tile.mc.dpr))
      }

      // Bicubic scaling and the rounded corners (picture.frag).
      ShaderEffect {
        anchors.fill: parent
        fragmentShader: Qt.resolvedUrl("picture.frag.qsb")
        property var source: texels
        property real radius: tile.mc.rounding
        property real zoom: tile.width / Math.max(1, tile.rw) * tile.dragScale
        property real px: 1 / Math.max(0.01, zoom * tile.mc.dpr)
        property size itemSize: Qt.size(picture.width, picture.height)
        property size texSize: texels.textureSize
      }
    }
  }

  // Selection ring.
  Rectangle {
    anchors.fill: parent
    anchors.margins: -4
    radius: tile.mc.rounding + 4
    color: "transparent"
    border.width: 3
    border.color: tile.mc.accent
    opacity: tile.highlighted || tile.dragging ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 90 } }
  }

  MouseArea {
    id: area
    anchors.fill: parent
    enabled: tile.mc.interactive
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: tile.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
    property real pressX: 0
    property real pressY: 0
    property bool moved: false

    onEntered: tile.mc.hoverAddr = tile.addr
    onExited: if (tile.mc.hoverAddr === tile.addr) tile.mc.hoverAddr = ""

    onPressed: function(mouse) {
      var pt = mapToItem(tile.parent, mouse.x, mouse.y)
      pressX = pt.x
      pressY = pt.y
      moved = false
      tile.grabX = mouse.x
      tile.grabY = mouse.y
    }
    onPositionChanged: function(mouse) {
      if (!(pressedButtons & Qt.LeftButton)) return
      var pt = mapToItem(tile.parent, mouse.x, mouse.y)
      var dx = pt.x - pressX, dy = pt.y - pressY
      if (!moved && Math.abs(dx) + Math.abs(dy) < 8) return
      moved = true
      tile.mc.dragTile = tile
      tile.dragX = dx
      tile.dragY = dy
      tile.dragScale = tile.mc.dragScaleAt(pt.y, tile.width)
      tile.mc.dragMoved(pt.x, pt.y)
    }
    onReleased: function(mouse) {
      if (moved) {
        var pt = mapToItem(tile.parent, mouse.x, mouse.y)
        var taken = tile.mc.dropWindow(tile.addr, tile.ws, pt.x, pt.y)
        tile.mc.dragTile = null
        if (taken) {
          tile.dropped = true
        } else {
          tile.dragX = 0
          tile.dragY = 0
          tile.dragScale = 1
        }
        moved = false
      } else if (mouse.button === Qt.MiddleButton) {
        tile.mc.closeWindow(tile.addr)
      } else {
        tile.mc.activateWindow(tile.addr)
      }
    }
    onCanceled: {
      if (tile.mc.dragTile === tile) tile.mc.dragTile = null
      tile.dragX = 0
      tile.dragY = 0
      tile.dragScale = 1
      moved = false
    }
  }

  // Close button.
  Rectangle {
    width: 24
    height: 24
    radius: 12
    x: -10
    y: -10
    visible: opacity > 0
    opacity: tile.highlighted && tile.mc.hoverAddr === tile.addr ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 90 } }
    color: closeArea.containsMouse ? tile.mc.accent : tile.mc.fg
    border.width: 1
    border.color: Qt.rgba(0, 0, 0, 0.35)
    Text {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -1
      textFormat: Text.PlainText
      text: "×"
      color: tile.mc.bg
      font.pixelSize: 18
      font.bold: true
    }
    MouseArea {
      id: closeArea
      anchors.fill: parent
      anchors.margins: -4
      enabled: tile.mc.interactive
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: tile.mc.hoverAddr = tile.addr
      onClicked: tile.mc.closeWindow(tile.addr)
    }
  }

  // App icon and title under the highlighted window.
  Rectangle {
    id: pill
    anchors.horizontalCenter: parent.horizontalCenter
    y: parent.height + 10
    height: 30
    width: Math.min(pillRow.implicitWidth + 24, Math.max(tile.width, 220))
    radius: 15
    color: Qt.rgba(tile.mc.bg.r, tile.mc.bg.g, tile.mc.bg.b, 0.92)
    border.width: 1
    border.color: Qt.rgba(tile.mc.fg.r, tile.mc.fg.g, tile.mc.fg.b, 0.14)
    visible: opacity > 0
    opacity: tile.highlighted ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 90 } }

    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: 8
      Image {
        width: 18
        height: 18
        anchors.verticalCenter: parent.verticalCenter
        sourceSize: Qt.size(36, 36)
        source: tile.mc.iconFor(tile.appId)
        asynchronous: true
      }
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, pill.width - 24 - 26)
        text: tile.title !== "" ? tile.title : tile.appId
        color: tile.mc.fg
        elide: Text.ElideRight
        font.family: tile.mc.fontFamily
        font.pixelSize: 13
      }
    }
  }
}
