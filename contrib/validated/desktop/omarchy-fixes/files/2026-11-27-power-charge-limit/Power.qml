import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "stock" as Stock
import "ChargeLimit.js" as Limit

// Omarchy's own Power panel, loaded from the package (so it follows every
// Omarchy update), with one section added at the bottom: the battery charge
// limit. Nothing of the stock panel is copied here: "stock" is a symlink to
// /usr/share/omarchy/shell/plugins/panels/power. It has to be a symlink:
// importing that directory by its own path fails in this shell with
// "InfoLabel is not a type" once the stock panel has been loaded. The section is parented
// into the stock panel's content column when the panel loads it; if a future
// Omarchy changes that layout, the section is left out and the stock panel
// works as shipped.
//
// The limit is written by /usr/local/bin/m5pro-charge-limit (m5pro-linux
// desktop-defaults), which needs root: sudo without a password when a sudoers
// rule allows it, otherwise the desktop's polkit prompt through pkexec.
Stock.Panel {
  id: root

  readonly property string limitHelper: "/usr/local/bin/m5pro-charge-limit"
  property var limitInfo: ({})
  readonly property var limitState: Limit.state(limitInfo)
  // The value under the knob while it is dragged or waiting to be written; -1 otherwise.
  property int limitPending: -1
  property bool limitFailed: false
  property bool limitSettling: false
  readonly property bool limitBusy: limitSetProc.running
  readonly property int limitShown: limitPending >= 0 ? limitPending : limitState.persistent
  property var limitPopup: null
  property var limitItem: null

  readonly property string limitValueText: limitShown >= Limit.MAX
    ? strings.t("limit.off")
    : strings.t("limit.percent").arg(Commons.I18n.formatNumber(limitShown))

  readonly property string limitCaption: {
    if (limitBusy) return strings.t("limit.applying")
    if (limitFailed) return strings.t("limit.failed")
    if (limitPending >= 0) {
      return limitPending >= Limit.MAX ? strings.t("limit.none")
        : strings.t("limit.stop").arg(Commons.I18n.formatNumber(limitPending))
    }
    if (limitState.fullOnce) return strings.t("limit.fullOnce").arg(Commons.I18n.formatNumber(limitState.saved))
    if (limitState.end >= Limit.MAX) return strings.t("limit.none")
    if (limitState.start > 0 && limitState.start < limitState.end)
      return strings.t("limit.range").arg(Commons.I18n.formatNumber(limitState.end)).arg(Commons.I18n.formatNumber(limitState.start))
    return strings.t("limit.stop").arg(Commons.I18n.formatNumber(limitState.end))
  }

  function limitRefresh() {
    if (!limitReadProc.running) limitReadProc.running = true
  }

  function limitRead(raw) {
    var info = Limit.parse(raw)
    if (info.end !== undefined) limitInfo = info
    if (limitSettling) {
      limitSettling = false
      if (!limitCommit.running) limitPending = -1
    }
  }

  function limitRun(value) {
    var arg = Limit.argument(value)
    if (arg === "" || limitSetProc.running) return
    limitFailed = false
    // sudo -n works when a sudoers rule lets this one command through without
    // a password; without one it says so and the polkit prompt takes over.
    limitSetProc.command = ["sh", "-c",
      'out=$(LC_ALL=C sudo -n "$0" "$1" 2>&1); rc=$?; '
      + 'case $out in *"password is required"*|*"terminal is required"*) exec pkexec "$0" "$1" ;; esac; '
      + 'exit $rc',
      limitHelper, arg]
    limitSetProc.running = true
  }

  function limitCommitPending() {
    if (limitPending < 0) return
    if (limitSetProc.running) { limitCommit.restart(); return }
    var s = limitState
    if (!s.fullOnce && limitPending === s.end && limitPending === s.saved) { limitPending = -1; return }
    limitRun(limitPending)
  }

  function limitToggleFullOnce() {
    limitCommit.stop()
    limitPending = -1
    if (limitState.fullOnce) limitRun(limitState.saved)
    else limitRun("full")
  }

  function limitFindPopup() {
    var list = root.data
    for (var i = 0; i < list.length; i++) {
      var o = list[i]
      if (o && o.loadedContent !== undefined && o.content !== undefined) return o
    }
    return null
  }

  // The stock content is a key catcher holding one Column of sections.
  function limitInject() {
    var holder = limitPopup ? limitPopup.loadedContent : null
    if (!holder) { limitItem = null; return }
    if (limitItem && limitItem.parent && limitItem.parent.parent === holder) return
    var kids = holder.children
    for (var i = 0; i < kids.length; i++) {
      var c = kids[i]
      if (c && c.spacing !== undefined && c.padding !== undefined && c.children.length > 1) {
        limitItem = limitSection.createObject(c)
        return
      }
    }
    console.warn("rolo.power: the stock Power panel layout changed; charge limit section not added")
  }

  Component.onCompleted: {
    limitPopup = limitFindPopup()
    if (!limitPopup) console.warn("rolo.power: the stock Power panel has no popup to extend")
    limitInject()
    limitRefresh()
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Connections {
    target: root.limitPopup
    ignoreUnknownSignals: true
    function onLoadedContentChanged() { root.limitInject() }
  }

  Process {
    id: limitReadProc
    command: ["sh", "-c",
      'b=/sys/class/power_supply/macsmc-battery; [ -r "$b/charge_control_end_threshold" ] || exit 0; '
      + 'printf "end\\t%s\\n" "$(cat "$b/charge_control_end_threshold")"; '
      + 'printf "start\\t%s\\n" "$(cat "$b/charge_control_start_threshold" 2>/dev/null)"; '
      + 'printf "saved\\t%s\\n" "$(sed -n "s/^CHARGE_CONTROL_END_THRESHOLD=\\([0-9]*\\)$/\\1/p" /etc/udev/macsmc-battery.conf 2>/dev/null | tail -1)"']
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.limitRead(text) }
  }

  Process {
    id: limitSetProc
    onExited: function(exitCode) {
      root.limitFailed = exitCode !== 0
      root.limitSettling = true
      root.limitRefresh()
    }
  }

  // A drag, a wheel run or a few clicks become one write (and one prompt).
  Timer { id: limitCommit; interval: 700; onTriggered: root.limitCommitPending() }

  Timer { interval: 5000; running: root.opened; repeat: true; triggeredOnStart: true; onTriggered: root.limitRefresh() }

  Timer { interval: 6000; running: root.limitFailed; onTriggered: root.limitFailed = false }

  Component {
    id: limitSection

    Column {
      width: parent ? parent.width : 0
      spacing: parent && parent.spacing !== undefined ? parent.spacing : Style.space(14)
      visible: root.limitState.supported

      PanelSeparator {
        foreground: root.bar.foreground
      }

      Column {
        width: parent.width
        spacing: Style.space(8)

        Item {
          width: parent.width
          implicitHeight: Math.max(limitTitle.implicitHeight, limitValue.implicitHeight)

          PanelSectionHeader {
            id: limitTitle
            text: strings.t("limit.title")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: limitValue
            textFormat: Text.PlainText
            text: root.limitValueText
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSlider {
          bar: root.bar
          width: parent.width
          minimum: Limit.MIN
          maximum: Limit.MAX
          step: 5
          integer: true
          tickCount: 11
          value: root.limitShown
          enabled: !root.limitBusy
          opacity: root.limitBusy ? 0.5 : 1.0

          onMoved: function(v) {
            limitCommit.stop()
            root.limitFailed = false
            root.limitPending = Limit.clamp(v)
          }
          onReleased: function(v) {
            root.limitPending = Limit.clamp(v)
            limitCommit.restart()
          }
        }

        Text {
          textFormat: Text.PlainText
          text: root.limitCaption
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.bar.foreground
          opacity: 0.6
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          visible: root.limitState.persistent < Limit.MAX
          width: parent.width
          iconText: "󰁹"
          iconSize: Style.font.title
          text: root.limitState.fullOnce
            ? strings.t("limit.fullOnceCancel").arg(Commons.I18n.formatNumber(root.limitState.saved))
            : strings.t("limit.fullOnceButton")
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          bordered: true
          active: root.limitState.fullOnce
          enabled: !root.limitBusy
          opacity: root.limitBusy ? 0.5 : 1.0
          onClicked: root.limitToggleFullOnce()
        }
      }
    }
  }
}
