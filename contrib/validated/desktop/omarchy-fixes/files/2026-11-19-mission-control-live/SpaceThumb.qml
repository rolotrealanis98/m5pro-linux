import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets

// One workspace in the strip: a small copy of the desktop, with its windows.
Item {
  id: thumb

  required property var mc
  required property int wsId          // -1 is the "new workspace" tile
  readonly property bool isNew: wsId < 0
  readonly property bool current: wsId === mc.activeWs
  readonly property bool dropHover: mc.dragTile && mc.dropTarget === wsId
  readonly property var wins: isNew ? [] : (mc.wsWins[wsId] || [])
  readonly property real k: mc.thumbW / Math.max(1, mc.viewW)
  property bool hovered: area.containsMouse || closeArea.containsMouse

  width: mc.thumbW
  height: mc.thumbH + 22

  Item {
    id: body
    width: thumb.mc.thumbW
    height: thumb.mc.thumbH
    scale: thumb.dropHover ? 1.1 : (thumb.hovered && !thumb.mc.dragTile ? 1.05 : 1)
    Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

    ClippingRectangle {
      anchors.fill: parent
      radius: 8
      color: thumb.isNew ? Qt.rgba(thumb.mc.fg.r, thumb.mc.fg.g, thumb.mc.fg.b, thumb.dropHover || thumb.hovered ? 0.16 : 0.07) : thumb.mc.cardColor

      Image {
        visible: !thumb.isNew
        x: -thumb.mc.offX * thumb.k
        y: -thumb.mc.offY * thumb.k
        width: thumb.mc.screenW * thumb.k
        height: thumb.mc.screenH * thumb.k
        source: thumb.mc.wallpaperUrl
        sourceSize: Qt.size(480, 320)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
      }

      Repeater {
        model: thumb.wins
        delegate: Item {
          id: mini
          required property var modelData
          readonly property var toplevel: thumb.mc.tops[modelData.addr] || null
          x: modelData.rx * thumb.k
          y: modelData.ry * thumb.k
          width: Math.max(2, modelData.rw * thumb.k)
          height: Math.max(2, modelData.rh * thumb.k)

          Rectangle {
            anchors.fill: parent
            visible: !(shot.item && shot.item.hasContent)
            color: thumb.mc.cardColor
            border.width: 1
            border.color: Qt.rgba(thumb.mc.fg.r, thumb.mc.fg.g, thumb.mc.fg.b, 0.18)
          }
          Loader {
            id: shot
            anchors.fill: parent
            active: thumb.mc.captureOn && thumb.mc.thumbsOn && !!mini.toplevel && !!mini.toplevel.wayland
            sourceComponent: ScreencopyView {
              captureSource: mini.toplevel ? mini.toplevel.wayland : null
              paintCursor: false
              live: false
              layer.enabled: true
              layer.smooth: true
              layer.mipmap: true
              Component.onCompleted: captureFrame()
            }
          }
          // The visible workspace keeps changing; the others are parked.
          Timer {
            interval: 1200
            repeat: true
            running: thumb.current && thumb.mc.settled && !!shot.item
            onTriggered: shot.item.captureFrame()
          }
        }
      }

      Text {
        visible: thumb.isNew
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: "+"
        color: thumb.mc.fg
        opacity: 0.75
        font.family: thumb.mc.fontFamily
        font.pixelSize: 34
      }
    }

    Rectangle {
      anchors.fill: parent
      anchors.margins: -3
      radius: 11
      color: "transparent"
      border.width: thumb.dropHover ? 3 : 2
      border.color: thumb.mc.accent
      opacity: thumb.dropHover || (thumb.current && !thumb.isNew) ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 110 } }
    }

    MouseArea {
      id: area
      anchors.fill: parent
      enabled: thumb.mc.interactive
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: thumb.isNew ? thumb.mc.addSpace() : thumb.mc.goToSpace(thumb.wsId)
    }

    // Close the workspace: its windows move to the one beside it.
    Rectangle {
      width: 22
      height: 22
      radius: 11
      x: -8
      y: -8
      visible: opacity > 0
      opacity: !thumb.isNew && thumb.hovered && !thumb.mc.dragTile && thumb.mc.spaceIds.length > 1 ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 90 } }
      color: closeArea.containsMouse ? thumb.mc.accent : thumb.mc.fg
      border.width: 1
      border.color: Qt.rgba(0, 0, 0, 0.35)
      Text {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -1
        textFormat: Text.PlainText
        text: "×"
        color: thumb.mc.bg
        font.pixelSize: 16
        font.bold: true
      }
      MouseArea {
        id: closeArea
        anchors.fill: parent
        anchors.margins: -4
        enabled: thumb.mc.interactive
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: thumb.mc.closeSpace(thumb.wsId)
      }
    }
  }

  Text {
    y: thumb.mc.thumbH + 7
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    textFormat: Text.PlainText
    text: thumb.isNew ? "" : thumb.mc.labelFor(thumb.wsId)
    color: thumb.current ? thumb.mc.accent : thumb.mc.fg
    opacity: thumb.current || thumb.hovered ? 1 : 0.6
    font.family: thumb.mc.fontFamily
    font.pixelSize: 12
    font.bold: thumb.current
  }
}
