import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "rolo.pointer"
  ipcTarget: "rolo.pointer"

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color bg: bar ? bar.background : Color.background
  readonly property color dim: Qt.darker(fg, 1.35)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string scriptPath: Qt.resolvedUrl("apply-pointer.py").toString().replace(/^file:\/\//, "")

  property string activeTab: "trackpad"
  property var cfg: ({
    profile: "custom",
    trackpad_scroll_factor: 1.0,
    trackpad_scroll_accel: 1.0,
    trackpad_tracking: 0.6875,
    trackpad_gain: 1.0,
    trackpad_natural_scroll: true,
    trackpad_tap_to_click: true,
    trackpad_disable_while_typing: true,
    trackpad_three_finger_drag: false,
    mouse_sensitivity: 0.0,
    mouse_tracking: 2.0,
    mouse_scroll_factor: 1.0,
    mouse_accel_profile: "adaptive",
    mouse_natural_scroll: false,
    cursor_size: 24
  })

  property bool writeQueued: false

  function readConfig() {
    if (!readProc.running) readProc.running = true
  }

  function applyConfig() {
    if (writeProc.running) {
      writeQueued = true
      return
    }
    writeQueued = false
    writeProc.command = ["python3", scriptPath, "--write", JSON.stringify(cfg)]
    writeProc.running = true
  }

  function scheduleApply() {
    applyDebounce.restart()
  }

  function updateField(key, value) {
    var next = Object.assign({}, cfg)
    next[key] = value
    cfg = next
  }

  function resetDefaults() {
    applyDebounce.stop()
    if (!resetProc.running) resetProc.running = true
  }

  // Profiles: "macos" (the owner's macOS settings through Apple's curves) and "custom" (hand-tuned).
  // Each keeps its own values; the sliders edit the active one.
  function setProfile(name) {
    if (name === cfg.profile) return
    applyDebounce.stop()
    profileProc.command = ["python3", scriptPath, "--profile", name]
    if (!profileProc.running) profileProc.running = true
  }
  readonly property bool macos: cfg.profile === "macos"
  readonly property bool mouseMacCurve: cfg.mouse_accel_profile === "macos"

  Component.onCompleted: readConfig()
  onOpenedChanged: if (opened) readConfig()

  Timer {
    id: applyDebounce
    interval: 70
    repeat: false
    onTriggered: root.applyConfig()
  }

  Process {
    id: readProc
    command: ["python3", root.scriptPath, "--read"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text.trim())
          if (parsed && typeof parsed === "object") root.cfg = parsed
        } catch (e) {}
      }
    }
  }

  Process {
    id: writeProc
    stdout: StdioCollector {
      onStreamFinished: {
        if (root.writeQueued) {
          root.writeQueued = false
          root.applyConfig()
        }
      }
    }
  }

  Process {
    id: profileProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text.trim())
          if (parsed && typeof parsed === "object") root.cfg = parsed
        } catch (e) {}
      }
    }
  }

  Process {
    id: resetProc
    command: ["python3", root.scriptPath, "--reset"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text.trim())
          if (parsed && typeof parsed === "object") root.cfg = parsed
        } catch (e) {}
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍽"
    tooltipText: "Pointer & Trackpad (" + (root.macos ? "macOS" : "Custom") + ")\nTrackpad scroll: " + Number(root.cfg.trackpad_scroll_factor).toFixed(2) + "× · Mouse scroll: " + Number(root.cfg.mouse_scroll_factor).toFixed(1) + "×"
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // Header + Trackpad / Mouse switcher
        Row {
          width: parent.width
          spacing: Style.space(10)

          Column {
            width: parent.width - tabGroup.implicitWidth - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "Pointer & Trackpad"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: (root.macos ? "macOS profile · " : "Custom profile · ") + (root.activeTab === "trackpad" ? "Apple MTP Trackpad" : "Mouse & Cursor")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          ButtonGroup {
            id: tabGroup
            anchors.verticalCenter: parent.verticalCenter
            foreground: root.fg
            background: root.bg
            fontFamily: root.fontFamily
            options: [
              { value: "trackpad", label: "Trackpad" },
              { value: "mouse", label: "Mouse" }
            ]
            value: root.activeTab
            onChanged: function(v) { root.activeTab = v }
          }
        }

        // Profile switcher
        Row {
          width: parent.width
          spacing: Style.space(10)

          Column {
            width: parent.width - profileGroup.implicitWidth - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "Profile"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.macos
                ? "macOS 27.3 values through Apple's own curves, sized for macOS's 2246-wide \"looks like\" (x0.77 at scale 2)"
                : "Your hand-tuned settings"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          ButtonGroup {
            id: profileGroup
            anchors.verticalCenter: parent.verticalCenter
            foreground: root.fg
            background: root.bg
            fontFamily: root.fontFamily
            options: [
              { value: "macos", label: "macOS" },
              { value: "custom", label: "Custom" }
            ]
            value: root.cfg.profile || "custom"
            onChanged: function(v) { root.setProfile(v) }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ======================================================== TRACKPAD TAB
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.activeTab === "trackpad"

          // Scroll Speed
          Column {
            width: parent.width
            spacing: Style.space(2)

            Row {
              width: parent.width
              Text {
                textFormat: Text.PlainText
                text: root.macos ? "Scroll speed (at rest)" : "Scroll speed"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                width: parent.width - tpScrollVal.implicitWidth
              }
              Text {
                id: tpScrollVal
                textFormat: Text.PlainText
                text: Number(root.cfg.trackpad_scroll_factor).toFixed(2) + "×"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: 0.1
              maximum: 3.0
              step: 0.05
              value: Number(root.cfg.trackpad_scroll_factor)
              onMoved: function(v) {
                root.updateField("trackpad_scroll_factor", Math.round(v * 100) / 100)
                root.scheduleApply()
              }
              onReleased: function(v) {
                applyDebounce.stop()
                root.updateField("trackpad_scroll_factor", Math.round(v * 100) / 100)
                root.applyConfig()
              }
            }
          }

          // Scroll Acceleration
          Column {
            width: parent.width
            spacing: Style.space(2)

            Row {
              width: parent.width
              Text {
                textFormat: Text.PlainText
                text: "Scroll flick acceleration"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                width: parent.width - tpScrollAccelVal.implicitWidth
              }
              Text {
                id: tpScrollAccelVal
                textFormat: Text.PlainText
                text: Math.round(Number(root.cfg.trackpad_scroll_accel) * 100) + "%"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: 0.0
              maximum: 1.0
              step: 0.05
              value: Number(root.cfg.trackpad_scroll_accel)
              onMoved: function(v) {
                root.updateField("trackpad_scroll_accel", Math.round(v * 100) / 100)
                root.scheduleApply()
              }
              onReleased: function(v) {
                applyDebounce.stop()
                root.updateField("trackpad_scroll_accel", Math.round(v * 100) / 100)
                root.applyConfig()
              }
            }
          }

          // Tracking Speed
          Column {
            width: parent.width
            spacing: Style.space(2)

            Row {
              width: parent.width
              Text {
                textFormat: Text.PlainText
                text: "Cursor speed (tracking)"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                width: parent.width - tpTrackVal.implicitWidth
              }
              Text {
                id: tpTrackVal
                textFormat: Text.PlainText
                text: Number(root.cfg.trackpad_tracking).toFixed(2)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: 0.0
              maximum: 3.0
              step: 0.05
              value: Number(root.cfg.trackpad_tracking)
              onMoved: function(v) {
                root.updateField("trackpad_tracking", Math.round(v * 100) / 100)
                root.scheduleApply()
              }
              onReleased: function(v) {
                applyDebounce.stop()
                root.updateField("trackpad_tracking", Math.round(v * 100) / 100)
                root.applyConfig()
              }
            }
          }

          // Pointer Gain
          Column {
            width: parent.width
            spacing: Style.space(2)

            Row {
              width: parent.width
              Text {
                textFormat: Text.PlainText
                text: root.macos ? "Pointer gain (on top of macOS)" : "Pointer gain multiplier"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                width: parent.width - tpGainVal.implicitWidth
              }
              Text {
                id: tpGainVal
                textFormat: Text.PlainText
                text: Number(root.cfg.trackpad_gain).toFixed(2) + "×"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: 0.4
              maximum: 2.0
              step: 0.05
              value: Number(root.cfg.trackpad_gain)
              onMoved: function(v) {
                root.updateField("trackpad_gain", Math.round(v * 100) / 100)
                root.scheduleApply()
              }
              onReleased: function(v) {
                applyDebounce.stop()
                root.updateField("trackpad_gain", Math.round(v * 100) / 100)
                root.applyConfig()
              }
            }
          }

          Toggle {
            width: parent.width
            label: "Natural scrolling"
            description: "Content moves with your fingers"
            checked: !!root.cfg.trackpad_natural_scroll
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: {
              root.updateField("trackpad_natural_scroll", !root.cfg.trackpad_natural_scroll)
              root.applyConfig()
            }
          }

          Toggle {
            width: parent.width
            label: "Tap to click"
            checked: !!root.cfg.trackpad_tap_to_click
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: {
              root.updateField("trackpad_tap_to_click", !root.cfg.trackpad_tap_to_click)
              root.applyConfig()
            }
          }

          Toggle {
            width: parent.width
            label: "Disable while typing"
            checked: !!root.cfg.trackpad_disable_while_typing
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: {
              root.updateField("trackpad_disable_while_typing", !root.cfg.trackpad_disable_while_typing)
              root.applyConfig()
            }
          }

          Toggle {
            width: parent.width
            label: "Three-finger drag"
            description: "Uses 3 fingers to drag (disables 3-finger swipes)"
            checked: !!root.cfg.trackpad_three_finger_drag
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: {
              root.updateField("trackpad_three_finger_drag", !root.cfg.trackpad_three_finger_drag)
              root.applyConfig()
            }
          }
        }

        // =========================================================== MOUSE TAB
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.activeTab === "mouse"

          // Mouse tracking speed (macOS curve)
          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.mouseMacCurve

            Row {
              width: parent.width
              Text {
                textFormat: Text.PlainText
                text: "Tracking speed (macOS)"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                width: parent.width - mTrackVal.implicitWidth
              }
              Text {
                id: mTrackVal
                textFormat: Text.PlainText
                text: Number(root.cfg.mouse_tracking).toFixed(2)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: 0.0
              maximum: 3.0
              step: 0.0625
              value: Number(root.cfg.mouse_tracking)
              onMoved: function(v) {
                root.updateField("mouse_tracking", Math.round(v * 10000) / 10000)
                root.scheduleApply()
              }
              onReleased: function(v) {
                applyDebounce.stop()
                root.updateField("mouse_tracking", Math.round(v * 10000) / 10000)
                root.applyConfig()
              }
            }
          }

          // Mouse Sensitivity
          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: !root.mouseMacCurve

            Row {
              width: parent.width
              Text {
                textFormat: Text.PlainText
                text: "Cursor speed (sensitivity)"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                width: parent.width - mSensVal.implicitWidth
              }
              Text {
                id: mSensVal
                textFormat: Text.PlainText
                text: (Number(root.cfg.mouse_sensitivity) > 0 ? "+" : "") + Number(root.cfg.mouse_sensitivity).toFixed(2)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: -1.0
              maximum: 1.0
              step: 0.05
              value: Number(root.cfg.mouse_sensitivity)
              onMoved: function(v) {
                root.updateField("mouse_sensitivity", Math.round(v * 100) / 100)
                root.scheduleApply()
              }
              onReleased: function(v) {
                applyDebounce.stop()
                root.updateField("mouse_sensitivity", Math.round(v * 100) / 100)
                root.applyConfig()
              }
            }
          }

          // Mouse Scroll Speed
          Column {
            width: parent.width
            spacing: Style.space(2)

            Row {
              width: parent.width
              Text {
                textFormat: Text.PlainText
                text: root.mouseMacCurve ? "Scroll wheel size (x macOS)" : "Scroll wheel speed"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                width: parent.width - mScrollVal.implicitWidth
              }
              Text {
                id: mScrollVal
                textFormat: Text.PlainText
                text: Number(root.cfg.mouse_scroll_factor).toFixed(1) + "×"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: 0.2
              maximum: 4.0
              step: 0.1
              value: Number(root.cfg.mouse_scroll_factor)
              onMoved: function(v) {
                root.updateField("mouse_scroll_factor", Math.round(v * 10) / 10)
                root.scheduleApply()
              }
              onReleased: function(v) {
                applyDebounce.stop()
                root.updateField("mouse_scroll_factor", Math.round(v * 10) / 10)
                root.applyConfig()
              }
            }
          }

          // Acceleration Profile
          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: "Acceleration"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              width: parent.width - accelGroup.implicitWidth - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
            }

            ButtonGroup {
              id: accelGroup
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.fg
              background: root.bg
              fontFamily: root.fontFamily
              options: [
                { value: "macos", label: "macOS" },
                { value: "adaptive", label: "Adaptive" },
                { value: "flat", label: "Flat" }
              ]
              value: root.cfg.mouse_accel_profile || "adaptive"
              onChanged: function(v) {
                root.updateField("mouse_accel_profile", v)
                root.applyConfig()
              }
            }
          }

          // Cursor Size
          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: "Cursor size"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              width: parent.width - cursorGroup.implicitWidth - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
            }

            ButtonGroup {
              id: cursorGroup
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.fg
              background: root.bg
              fontFamily: root.fontFamily
              options: ["18", "19", "24", "32", "40", "48"]
              value: String(root.cfg.cursor_size || 24)
              onChanged: function(v) {
                root.updateField("cursor_size", parseInt(v, 10) || 24)
                root.applyConfig()
              }
            }
          }

          Toggle {
            width: parent.width
            label: "Natural scrolling (mouse)"
            description: "Reverse mouse wheel scroll direction"
            checked: !!root.cfg.mouse_natural_scroll
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: {
              root.updateField("mouse_natural_scroll", !root.cfg.mouse_natural_scroll)
              root.applyConfig()
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // Footer: Reset button
        Row {
          width: parent.width
          layoutDirection: Qt.RightToLeft

          Button {
            text: root.macos ? "Reset to macOS values" : "Reset to defaults"
            foreground: root.fg
            background: root.bg
            fontFamily: root.fontFamily
            onClicked: root.resetDefaults()
          }
        }
      }
    }
  }
}
