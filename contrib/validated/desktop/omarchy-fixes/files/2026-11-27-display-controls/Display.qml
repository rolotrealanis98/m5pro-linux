import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "stock" as Stock
import "DisplayModel.js" as X

// Omarchy's own Display panel, loaded from the package (so it follows every
// Omarchy update), with more display controls added to it: the XDR brightness
// range and auto brightness under the brightness slider, a fine scale slider
// under the scale presets, and refresh rate, variable refresh, HDR and night
// light sections below. Nothing of the stock panel is copied: "stock" is a
// symlink to /usr/share/omarchy/shell/plugins/panels/monitor (it has to be a
// symlink, see rolo.power). The additions are parented into the stock panel's
// content when the panel loads it. If a later Omarchy changes that layout they
// go to the end of the panel, or are left out with one warning, and the stock
// panel works as shipped.
//
// Every change goes through ./display-ctl, which applies it with hyprctl and
// remembers it; this file asks it to put the remembered choices back when the
// shell starts and after each Hyprland config reload.
//
// One stock function is replaced, setScale(), so the stock scale presets take
// the same path as the fine slider: applied at once, kept across reloads, no
// config file rewritten.
Stock.Panel {
  id: root

  readonly property string xCtl: {
    var p = String(Qt.resolvedUrl("display-ctl")).replace(/^file:\/\//, "")
    return p.charAt(0) === "/" ? p : Quickshell.env("HOME") + "/.config/omarchy/plugins/rolo.display/display-ctl"
  }

  property var xs: X.parseState("")
  readonly property var xMon: X.focused(xs)
  readonly property bool xInternal: !!xMon && xMon.builtin

  // Commands waiting for display-ctl, one argv each; they run one at a time.
  property var xQueue: []
  property bool xStateAgain: false
  property string xError: ""

  // What was just chosen, shown until display-ctl reports the real state.
  property var xOpt: ({})
  property int xScalePending: -1

  // A change that could leave the screen unusable waits for "Keep".
  property var xConfirm: null
  property int xConfirmLeft: 0

  property var xPopup: null
  property var xHolder: null
  property var xItems: []
  property string xAnchors: ""
  property bool xDry: false
  property string xLastCall: ""

  readonly property var xStops: X.scaleStops()
  readonly property int xScaleK: xScalePending >= 0 ? xScalePending : (xMon ? X.scale120(xMon.scale) : 240)
  readonly property string xModeId: xMon ? X.currentMode(xMon) : ""
  readonly property string xHdr: xVal("hdr", xMon ? X.hdrMode(xMon, xs.autoHdr) : "off")
  readonly property int xXdrMax: xVal("xdr", xs.xdr.max > 0 ? xs.xdr.max : xs.xdr.sdr)

  readonly property var xXdrOptions: {
    var stops = X.xdrStops(xs.xdr.sdr, xs.xdr.peak)
    var out = []
    for (var i = 0; i < stops.length; i++) out.push({ value: String(stops[i]), label: Commons.I18n.formatNumber(stops[i]) })
    return out
  }
  readonly property var xResolutions: {
    var list = xMon ? X.resolutions(xMon) : []
    var out = []
    for (var i = 0; i < list.length; i++)
      out.push({ value: list[i].value, label: strings.t("mode.resolution").arg(list[i].width).arg(list[i].height) })
    return out
  }
  readonly property var xRates: {
    var list = xMon ? X.rates(xMon, xMon.width, xMon.height) : []
    var out = []
    for (var i = 0; i < list.length; i++)
      out.push({ value: list[i].id, label: strings.t("mode.hz").arg(Commons.I18n.formatNumber(list[i].rate, X.rateDecimals(list[i].rate))) })
    return out
  }
  readonly property var xVrrOptions: [
    { value: "0", label: strings.t("vrr.off") },
    { value: "1", label: strings.t("vrr.on") },
    { value: "2", label: strings.t("vrr.fullscreen") }
  ]
  readonly property var xHdrOptions: [
    { value: "off", label: strings.t("hdr.off") },
    { value: "auto", label: strings.t("hdr.auto") },
    { value: "on", label: strings.t("hdr.on") }
  ]

  function xVal(key, real) {
    var v = xOpt[key]
    return v === undefined ? real : v
  }

  function xSetOpt(key, value) {
    var o = {}
    for (var k in xOpt) o[k] = xOpt[k]
    o[key] = value
    xOpt = o
  }

  function xRun(args) {
    if (xDry) { xLastCall = args.join(" "); return }
    var q = xQueue.slice()
    q.push(args)
    xQueue = q
    xPump()
  }

  function xPump() {
    if (xActProc.running || xQueue.length === 0) return
    var q = xQueue.slice()
    var args = q.shift()
    xQueue = q
    xActProc.command = [xCtl].concat(args)
    xActProc.running = true
  }

  function xRefresh() {
    if (xStateProc.running) { xStateAgain = true; return }
    xStateProc.running = true
  }

  // Replaces the stock setScale(): the scale presets and the fine slider share one path.
  function setScale(scale) {
    var k = Math.round(Number(scale) * 120)
    if (isFinite(k) && k > 0) xSetScale(k)
  }

  function xSetScale(k) {
    if (!xMon) return
    xScalePending = k
    xRun(["scale", String(k / 120), xMon.name])
  }

  function xSetXdr(nits) {
    if (!xs.xdr.supported || nits === xXdrMax) return
    xSetOpt("xdr", nits)
    xRun(["xdr", nits <= xs.xdr.sdr ? "off" : String(nits)])
  }

  function xSetMode(id) {
    if (!xMon || xConfirm || !id || id === xModeId) return
    xRun(["mode", id, xMon.name, "--try"])
    xAsk("mode", ["mode", id, xMon.name], ["mode", xModeId !== "" ? xModeId : "preferred", xMon.name, "--try"])
  }

  function xSetResolution(resolution) {
    if (!xMon || resolution === xMon.width + "x" + xMon.height) return
    xSetMode(X.modeFor(xMon, resolution))
  }

  function xSetVrr(value) {
    if (String(xVal("vrr", xs.vrr)) === value) return
    xSetOpt("vrr", Number(value))
    xRun(["vrr", value])
  }

  function xSetHdr(mode) {
    if (!xMon || xConfirm || mode === xHdr) return
    var before = xHdr
    xSetOpt("hdr", mode)
    if (mode === "on") {
      xRun(["hdr", "on", xMon.name, "--try"])
      xAsk("hdr", ["hdr", "on", xMon.name], ["hdr", before, xMon.name, "--try"])
    } else {
      xRun(["hdr", mode, xMon.name])
    }
  }

  function xAsk(what, keep, revert) {
    xConfirm = { what: what, keep: keep, revert: revert }
    xConfirmLeft = 12
    xConfirmTick.restart()
  }

  function xSettle(keep) {
    var c = xConfirm
    if (!c) return
    xConfirm = null
    xConfirmTick.stop()
    if (!keep) xOpt = ({})
    xRun(keep ? c.keep : c.revert)
  }

  function xFindPopup() {
    var list = root.data
    for (var i = 0; i < list.length; i++) {
      var o = list[i]
      if (o && o.loadedContent !== undefined && o.content !== undefined) return o
    }
    return null
  }

  function xFind(item, test, depth) {
    if (!item || depth < 0) return null
    var kids = item.children
    if (!kids) return null
    for (var i = 0; i < kids.length; i++) if (kids[i] && test(kids[i])) return kids[i]
    for (var j = 0; j < kids.length; j++) {
      var found = xFind(kids[j], test, depth - 1)
      if (found) return found
    }
    return null
  }

  function xIsColumn(item) {
    return item.spacing !== undefined && item.padding !== undefined && item.columns === undefined
  }

  // The stock content is a key catcher holding a scroll area with one Column of
  // sections. The brightness section is the one with the 1-100 slider, the
  // scale section the one with the grid of presets.
  function xInject() {
    var holder = xPopup ? xPopup.loadedContent : null
    if (!holder) { xHolder = null; xItems = []; return }
    if (holder === xHolder && xItems.length > 0) return
    var main = xFind(holder, function(c) { return root.xIsColumn(c) && c.children.length >= 4 }, 6)
    if (!main) {
      console.warn("rolo.display: the stock Display panel layout changed; the extra controls were not added")
      return
    }
    var bright = null
    var scale = null
    var kids = main.children
    for (var i = 0; i < kids.length; i++) {
      var c = kids[i]
      if (!c || !xIsColumn(c)) continue
      if (!bright && xFind(c, function(s) { return s.liveValue !== undefined && s.minimum === 1 && s.maximum === 100 }, 3)) bright = c
      else if (!scale && xFind(c, function(g) { return g.columns !== undefined && g.columnSpacing !== undefined }, 0)) scale = c
    }
    // The stock column ends in a small spacer; ours follow it, so it would double the gap before them.
    var last = kids.length > 0 ? kids[kids.length - 1] : null
    if (last && !xIsColumn(last) && last.children.length === 0 && last.height > 0 && last.height <= Style.space(8)) last.visible = false
    var items = []
    items.push(xBrightnessExtras.createObject(bright || main))
    items.push(xScaleExtras.createObject(scale || main))
    items.push(xSections.createObject(main))
    xHolder = holder
    xItems = items
    xAnchors = (bright ? "brightness" : "end") + "," + (scale ? "scale" : "end")
  }

  Component.onCompleted: {
    xPopup = xFindPopup()
    if (!xPopup) console.warn("rolo.display: the stock Display panel has no popup to extend")
    // Room for the added sections before the panel starts to scroll.
    if (xPopup && typeof xPopup.fittedContentHeight === "function" && xPopup.loadedContentHeight !== undefined)
      xPopup.contentHeight = Qt.binding(function() {
        return root.xPopup.fittedContentHeight(root.xPopup.loadedContentHeight, Style.space(900))
      })
    xInject()
    xRefresh()
    xReapplySoon.restart()
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Connections {
    target: root.xPopup
    ignoreUnknownSignals: true
    function onLoadedContentChanged() { root.xInject() }
  }

  // A config reload puts the config's own values back, and a monitor that is
  // plugged in comes up with its rule from the config.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (name === "configreloaded" || name === "monitoraddedv2") xReapplySoon.restart()
    }
  }

  ShellIpc {
    target: "rolo.display"

    function state(): string { return JSON.stringify(root.xs) }
    function refresh(): void { root.xRefresh() }
    function reapply(): void { xReapplySoon.restart() }

    // Checks, without changing anything, that the additions are in place and
    // that the stock scale presets reach this file's setScale().
    function selftest(): string {
      var section = root.focusSection
      var index = root.selectedIndex
      root.xDry = true
      root.xLastCall = ""
      root.focusSection = "scale"
      root.selectedIndex = 0
      root.activateCursor()
      var call = root.xLastCall
      root.xDry = false
      root.xScalePending = -1
      root.focusSection = section
      root.selectedIndex = index
      return JSON.stringify({
        ctl: root.xCtl, popup: !!root.xPopup, contentLoaded: !!root.xHolder, added: root.xItems.length,
        anchors: root.xAnchors, presetCall: call, monitor: root.xMon ? root.xMon.name : ""
      })
    }
  }

  Process {
    id: xStateProc
    command: [root.xCtl, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.xs = X.parseState(text)
        if (!xActProc.running && root.xQueue.length === 0) {
          if (!root.xConfirm) root.xOpt = ({})
          if (!xScaleCommit.running) root.xScalePending = -1
        }
      }
    }
    onExited: {
      if (root.xStateAgain) {
        root.xStateAgain = false
        root.xRefresh()
      }
    }
  }

  Process {
    id: xActProc
    stderr: StdioCollector { id: xActErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.xError = exitCode === 0 ? "" : String(xActErr.text || "").replace(/^display-ctl: /, "").trim().slice(0, 160)
      root.xRefresh()
      root.refresh()
      root.xPump()
    }
  }

  Process {
    id: xReapplyProc
    command: [root.xCtl, "reapply"]
    onExited: {
      root.xRefresh()
      root.refresh()
    }
  }

  Timer { id: xReapplySoon; interval: 400; onTriggered: if (!xReapplyProc.running) xReapplyProc.running = true }

  Timer { interval: 5000; running: root.opened; repeat: true; triggeredOnStart: true; onTriggered: root.xRefresh() }

  Timer { interval: 8000; running: root.xError !== ""; onTriggered: root.xError = "" }

  Timer {
    id: xConfirmTick
    interval: 1000
    repeat: true
    onTriggered: {
      root.xConfirmLeft -= 1
      if (root.xConfirmLeft <= 0) root.xSettle(false)
    }
  }

  // A drag over several stops becomes one change of scale.
  Timer { id: xScaleCommit; interval: 350; onTriggered: if (root.xScalePending >= 0) root.xSetScale(root.xScalePending) }

  component XHeader: Item {
    id: header
    property string text: ""
    property string value: ""

    width: parent ? parent.width : 0
    implicitHeight: Math.max(headerTitle.implicitHeight, headerValue.implicitHeight)

    PanelSectionHeader {
      id: headerTitle
      text: header.text
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: headerValue
      textFormat: Text.PlainText
      text: header.value
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component XCaption: Text {
    textFormat: Text.PlainText
    width: parent ? parent.width : 0
    wrapMode: Text.WordWrap
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  // A row of equal buttons, one of them current.
  component XPills: Grid {
    id: pills
    property var options: []
    property string value: ""
    property int maxColumns: 6
    signal picked(string value)

    width: parent ? parent.width : 0
    columns: Math.max(1, Math.min(options.length, maxColumns))
    spacing: Style.spacing.xs
    opacity: enabled ? 1.0 : 0.5

    readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

    Repeater {
      model: pills.options

      Button {
        required property var modelData

        width: pills.cellWidth
        text: String(modelData.label)
        fontSize: Style.font.caption
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        horizontalPadding: Style.spacing.sm
        verticalPadding: Style.spacing.controlPaddingY
        bordered: true
        active: String(modelData.value) === pills.value
        onClicked: pills.picked(String(modelData.value))
      }
    }
  }

  component XSwitch: Item {
    id: row
    property string label: ""
    property string caption: ""
    property bool checked: false
    signal toggled()

    width: parent ? parent.width : 0
    implicitHeight: Math.max(rowTexts.implicitHeight, rowKnob.implicitHeight)

    Column {
      id: rowTexts
      anchors.left: parent.left
      anchors.right: rowKnob.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: row.label
        width: parent.width
        elide: Text.ElideRight
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
      }

      XCaption {
        visible: row.caption !== ""
        text: row.caption
      }
    }

    ToggleSwitch {
      id: rowKnob
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: row.checked
      foreground: root.bar.foreground
      onToggled: row.toggled()
    }
  }

  component XConfirmRow: Column {
    property string what: ""

    visible: !!root.xConfirm && root.xConfirm.what === what
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    XCaption {
      opacity: 1.0
      text: strings.t("confirm.text").arg(Commons.I18n.formatNumber(root.xConfirmLeft))
    }

    XPills {
      options: [{ value: "keep", label: strings.t("confirm.keep") }, { value: "back", label: strings.t("confirm.revert") }]
      value: "keep"
      onPicked: function(v) { root.xSettle(v === "keep") }
    }
  }

  // Under the stock brightness slider: the XDR range and auto brightness of the built-in panel.
  Component {
    id: xBrightnessExtras

    Column {
      width: parent ? parent.width : 0
      spacing: Style.space(10)
      topPadding: Style.space(6)
      visible: root.xInternal && (root.xs.xdr.supported || root.xs.autoBrightness.supported)

      Column {
        visible: root.xs.xdr.supported
        width: parent.width
        spacing: Style.space(8)

        XHeader {
          text: strings.t("xdr.title")
          value: strings.t("xdr.now").arg(Commons.I18n.formatNumber(X.nitsNow(root.brightnessPercent, root.xs.xdr.range)))
        }

        XPills {
          options: root.xXdrOptions
          value: String(root.xXdrMax)
          onPicked: function(v) { root.xSetXdr(Number(v)) }
        }

        XCaption {
          text: root.xXdrMax > root.xs.xdr.sdr
            ? strings.t("xdr.on").arg(Commons.I18n.formatNumber(root.xXdrMax))
            : strings.t("xdr.off").arg(Commons.I18n.formatNumber(root.xs.xdr.sdr))
        }
      }

      XSwitch {
        visible: root.xs.autoBrightness.supported
        label: strings.t("auto.title")
        caption: strings.t("auto.caption")
        checked: root.xVal("auto", root.xs.autoBrightness.on)
        onToggled: {
          var next = !checked
          root.xSetOpt("auto", next)
          root.xRun(["auto-brightness", next ? "on" : "off"])
        }
      }
    }
  }

  // Under the stock scale presets: the sizes in between.
  Component {
    id: xScaleExtras

    Column {
      id: fine
      width: parent ? parent.width : 0
      spacing: Style.space(6)
      visible: !!root.xMon

      readonly property int liveK: fineSlider.dragging ? root.xStops[Math.round(fineSlider.liveValue)] : root.xScaleK
      readonly property var looks: root.xMon ? X.looksLike(liveK, root.xMon.width, root.xMon.height) : ({ width: 0, height: 0 })

      XHeader {
        text: strings.t("scale.fine")
        value: strings.t("scale.value")
          .arg(Commons.I18n.formatNumber(fine.liveK / 120, X.scaleDecimals(fine.liveK)))
          .arg(fine.looks.width).arg(fine.looks.height)
      }

      Item {
        width: parent.width
        implicitHeight: fineSlider.implicitHeight

        PanelSlider {
          id: fineSlider
          bar: root.bar
          anchors.fill: parent
          anchors.leftMargin: Style.space(6)
          anchors.rightMargin: Style.space(6)
          minimum: 0
          maximum: root.xStops.length - 1
          step: 1
          integer: true
          tickCount: root.xStops.length
          value: X.nearestStop(root.xScaleK)
          onReleased: function(v) {
            var k = root.xStops[Math.round(v)]
            if (k === root.xScaleK) return
            root.xScalePending = k
            xScaleCommit.restart()
          }
        }

        // No wheel on this slider: scrolling the panel past it must not rescale the screen.
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.NoButton
          onWheel: function(wheel) { wheel.accepted = true }
        }
      }

      XCaption {
        visible: !!root.xMon && !X.isClean(fine.liveK, root.xMon.width, root.xMon.height)
        text: strings.t("scale.soft")
      }
    }
  }

  // After the stock sections.
  Component {
    id: xSections

    Column {
      width: parent ? parent.width : 0
      spacing: parent && parent.spacing !== undefined ? parent.spacing : Style.space(14)

      PanelSeparator {
        visible: modeBox.visible
        foreground: root.bar.foreground
      }

      Column {
        id: modeBox
        visible: !!root.xMon && root.xRates.length > 0
        width: parent.width
        spacing: Style.space(10)

        XHeader {
          text: strings.t("mode.title")
          value: root.xMon ? strings.t("mode.resolution").arg(root.xMon.width).arg(root.xMon.height) : ""
        }

        XPills {
          visible: root.xResolutions.length > 1
          maxColumns: 3
          enabled: !root.xConfirm
          options: root.xResolutions
          value: root.xMon ? root.xMon.width + "x" + root.xMon.height : ""
          onPicked: function(v) { root.xSetResolution(v) }
        }

        XPills {
          maxColumns: 5
          enabled: !root.xConfirm
          options: root.xRates
          value: root.xModeId
          onPicked: function(v) { root.xSetMode(v) }
        }

        XConfirmRow { what: "mode" }
      }

      PanelSeparator {
        visible: vrrBox.visible
        foreground: root.bar.foreground
      }

      Column {
        id: vrrBox
        visible: !!root.xMon && root.xMon.vrrCapable && root.xs.vrr >= 0
        width: parent.width
        spacing: Style.space(10)

        XHeader { text: strings.t("vrr.title") }

        XPills {
          options: root.xVrrOptions
          value: String(root.xVal("vrr", root.xs.vrr))
          onPicked: function(v) { root.xSetVrr(v) }
        }

        XCaption { text: strings.t("vrr.caption." + Math.max(0, Math.min(3, root.xVal("vrr", root.xs.vrr)))) }
      }

      PanelSeparator {
        visible: hdrBox.visible
        foreground: root.bar.foreground
      }

      Column {
        id: hdrBox
        visible: !!root.xMon && root.xMon.hdrCapable
        width: parent.width
        spacing: Style.space(10)

        XHeader { text: strings.t("hdr.title") }

        XPills {
          enabled: !root.xConfirm
          options: root.xHdrOptions
          value: root.xHdr
          onPicked: function(v) { root.xSetHdr(v) }
        }

        XCaption { text: strings.t("hdr.caption." + root.xHdr) }

        XConfirmRow { what: "hdr" }
      }

      PanelSeparator {
        visible: nightBox.visible
        foreground: root.bar.foreground
      }

      XSwitch {
        id: nightBox
        visible: root.xs.nightlight.supported
        label: strings.t("night.title")
        caption: strings.t("night.caption")
        checked: root.xVal("night", root.xs.nightlight.on)
        onToggled: {
          var next = !checked
          root.xSetOpt("night", next)
          root.xRun(["nightlight", next ? "on" : "off"])
        }
      }

      XCaption {
        visible: root.xError !== ""
        text: strings.t("error.text").arg(root.xError)
      }

      Button {
        visible: root.xs.overrides
        width: parent.width
        text: strings.t("reset.button")
        fontSize: Style.font.bodySmall
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        bordered: true
        onClicked: root.xRun(["reset"])
      }

      Item {
        width: parent.width
        height: Style.space(4)
      }
    }
  }
}
