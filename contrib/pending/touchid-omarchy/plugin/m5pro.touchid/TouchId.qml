import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Touch ID settings, summoned from Setup > Security > Touch ID
// (omarchy-shell shell summon m5pro.touchid). Lists the enrolled fingerprints
// and adds, tests, names and deletes them through /usr/local/bin/m5pro-touchid,
// which speaks to fprintd. Adding and deleting ask who you are first in
// Omarchy's own polkit dialog (a touch of an enrolled finger, or the password).
// Deleting writes the Secure Enclave, so it is always confirmed here first.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property string helper: "/usr/local/bin/m5pro-touchid"
  readonly property string fpGlyph: "󰈷"
  // A rough count of touches an enrolment takes; only the ring's pace.
  readonly property int expectedTouches: 14
  // Five failed matches in a row lock Touch ID. Tests stop well before that.
  readonly property int maxMisses: 2

  // list | pick | enroll | verify | rename | confirmDelete | deleting
  property string mode: "list"
  property var status: ({ reader: false, fingers: [], capacity: 3, fingerNames: [], reason: "", rearm: false })
  property bool loading: false
  property int cursor: 0
  property int column: 0
  property string notice: ""

  property string activeFinger: ""
  property string activeName: ""
  property string headline: ""
  property string detail: ""
  property int steps: 0
  property bool finished: false
  property bool success: false
  property bool authWaiting: false
  property bool touchFlash: false
  property int missesInARow: 0

  readonly property var fingers: status && status.fingers ? status.fingers : []
  readonly property int capacity: status && status.capacity ? status.capacity : 3
  readonly property bool full: fingers.length >= capacity
  readonly property var listRows: {
    var rows = []
    for (var i = 0; i < fingers.length; i++) rows.push({ kind: "finger", finger: fingers[i] })
    if (status && status.reader) rows.push({ kind: "add" })
    return rows
  }
  readonly property var freeFingers: {
    var taken = {}
    for (var i = 0; i < fingers.length; i++) taken[fingers[i].id] = true
    var all = status && status.fingerNames ? status.fingerNames : []
    var out = []
    for (var j = 0; j < all.length; j++) if (!taken[all[j].id]) out.push(all[j])
    return out
  }
  readonly property real ringProgress: success ? 1 : Math.min(0.94, steps / expectedTouches)

  function displayName(f) { return f.label && f.label.length ? f.label : f.name }
  function buttonsFor(row) {
    if (!row) return []
    if (row.kind === "add") return [root.full ? "Touch ID holds " + root.capacity + " fingerprints" : "Add a fingerprint"]
    return ["Test", "Rename", "Delete"]
  }

  // ---------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    mode = "list"
    cursor = 0
    column = 0
    notice = ""
    missesInARow = 0
    opened = true
    refresh()
    Qt.callLater(refocus)
  }

  function close() { opened = false }

  function dismiss() {
    if (opProc.running) opProc.running = false
    opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "m5pro.touchid")
  }

  function toggle() { if (opened) dismiss(); else open("{}") }

  function refocus() {
    if (mode === "rename" || (mode === "enroll" && success)) labelField.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
  }

  function refresh() {
    if (statusProc.running) return
    loading = true
    statusProc.running = true
  }

  function back() {
    if (opProc.running) opProc.running = false
    authWaiting = false
    mode = "list"
    if (cursor >= listRows.length) cursor = Math.max(0, listRows.length - 1)
    column = 0
    refresh()
    Qt.callLater(refocus)
  }

  // ---------------------------------------------------------------- helper runs

  function run(args) {
    if (opProc.running) return false
    opProc.command = [root.helper].concat(args)
    opProc.running = true
    return true
  }

  function resetOp(finger, name) {
    activeFinger = finger
    activeName = name
    steps = 0
    finished = false
    success = false
    authWaiting = false
    headline = ""
    detail = ""
  }

  function startEnroll(entry) {
    resetOp(entry.id, entry.name)
    mode = "enroll"
    headline = "Confirm it's you"
    detail = "Touch ID or your password, in the dialog."
    labelField.text = ""
    run(["enroll", entry.id])
    Qt.callLater(refocus)
  }

  function startVerify(f) {
    if (missesInARow >= maxMisses) {
      notice = "Tests are paused: two misses in a row. Unlock with Touch ID somewhere else first (sudo, lock screen)."
      return
    }
    resetOp(f.id, displayName(f))
    mode = "verify"
    headline = "Touch ID with your " + f.name.toLowerCase()
    detail = "Rest the finger on the Touch ID button, top right of the keyboard. Don't press it."
    run(["verify", f.id])
    Qt.callLater(refocus)
  }

  function startRename(f) {
    resetOp(f.id, f.name)
    labelField.text = f.label || ""
    mode = "rename"
    Qt.callLater(refocus)
  }

  function saveLabel() {
    var text = labelField.text.trim()
    if (opProc.running) return
    if (mode === "enroll" && !text.length) { back(); return }
    mode = "list"
    run(["label", activeFinger, text])
  }

  function askDelete(f) {
    resetOp(f.id, displayName(f))
    confirm.selectedIndex = 0
    mode = "confirmDelete"
  }

  function doDelete() {
    mode = "deleting"
    headline = "Confirm it's you"
    detail = "Touch ID or your password, in the dialog."
    run(["delete", activeFinger])
  }

  function parse(line) {
    try { return JSON.parse(line) } catch (e) { return null }
  }

  function onStatusLine(line) {
    var msg = parse(line)
    if (msg && msg.event === "status") {
      status = msg
      if (cursor >= listRows.length) cursor = Math.max(0, listRows.length - 1)
    }
  }

  function flash() {
    touchFlash = true
    flashTimer.restart()
  }

  function enrollText(result) {
    switch (result) {
    case "duplicate-check-passed": return ["Touch ID with your " + activeName.toLowerCase(), "Rest it on the Touch ID button, lift, and rest it again. Don't press."]
    case "enroll-stage-passed": return [steps === 1 ? "Good. Lift and touch again" : "Keep going", "Move the finger a little each time, then the edges of it."]
    case "enroll-retry-scan": return ["That one didn't read", "Lift your finger and touch again."]
    case "enroll-finger-not-centered": return ["Not centered", "Cover the whole button with the pad of your finger."]
    case "enroll-remove-and-retry": return ["Lift your finger", "Then rest it on the button again."]
    case "enroll-too-fast": return ["A little slower", "Hold each touch for a moment."]
    case "enroll-swipe-too-short": return ["That one didn't read", "Touch again."]
    case "enroll-completed": return ["Fingerprint added", "Name it if you like, then press Enter."]
    case "enroll-duplicate": return ["Already enrolled", "That finger is already one of your fingerprints."]
    case "enroll-data-full": return ["No room left", "Touch ID holds " + capacity + " fingerprints. Delete one first."]
    case "enroll-disconnected": return ["The reader went away", "Open the lid and try again."]
    default: return ["Enrolment stopped", "Nothing was saved. Try again and keep going until it says added."]
    }
  }

  function verifyText(result) {
    switch (result) {
    case "verify-match": return ["Matched", activeName + " works."]
    case "verify-no-match": return ["No match", "That wasn't your " + activeName.toLowerCase() + ", or it didn't read."]
    case "verify-retry-scan": return ["That one didn't read", "Touch again."]
    case "verify-finger-not-centered": return ["Not centered", "Cover the whole button and touch again."]
    case "verify-remove-and-retry": return ["Lift your finger", "Then touch again."]
    case "verify-too-fast": return ["A little slower", "Touch again."]
    case "verify-disconnected": return ["The reader went away", "Open the lid and try again."]
    default: return ["Touch ID didn't check it", "It may be locked after failed tries: unlock once with your password (sudo or the lock screen), then try again."]
    }
  }

  function finishText(result, error) {
    switch (result) {
    case "denied": return ["Not confirmed", "Nothing was changed."]
    case "busy": return ["The reader is busy", "A lock screen, sudo or 1Password prompt is using it. Finish that, then try again."]
    case "lid-closed": return ["The lid is closed", "Open it to use Touch ID."]
    case "no-reader": return ["No Touch ID reader", "fprintd found no reader. If this persists, restart the Mac."]
    case "timeout": return mode === "enroll" ? ["Timed out", "Nothing was saved. Try again."] : ["No touch", "Try again when you're ready."]
    case "cancelled": return ["Cancelled", "Nothing was changed."]
    case "full": return ["No room left", "Touch ID holds " + capacity + " fingerprints. Delete one first."]
    case "already-enrolled": return ["Already enrolled", "Pick another finger."]
    default: return ["Something went wrong", error || result || ""]
    }
  }

  function onOpLine(line) {
    var msg = parse(line)
    if (!msg) return
    var t
    if (msg.event === "auth") {
      authWaiting = true
    } else if (msg.event === "authorized") {
      authWaiting = false
      if (msg.ok && mode === "enroll") {
        headline = "Getting Touch ID ready"
        detail = ""
      } else if (msg.ok && mode === "deleting") {
        headline = "Deleting " + activeName
        detail = "Touch ID is forgetting this fingerprint."
      }
      Qt.callLater(refocus)
    } else if (msg.event === "started") {
      if (mode === "enroll") {
        // Touch ID's first stage is fprintd's duplicate check; the copy for it
        // already asks for the first touch.
        t = enrollText("duplicate-check-passed")
        headline = t[0]; detail = t[1]
      }
    } else if (msg.event === "status") {
      if (mode === "enroll") {
        steps = msg.step || steps
        if (msg.result === "enroll-stage-passed") flash()
        if (msg.result === "enroll-completed") success = true
        t = enrollText(msg.result)
      } else {
        t = verifyText(msg.result)
        if (msg.done) {
          success = msg.result === "verify-match"
          missesInARow = success ? 0 : (msg.result === "verify-no-match" ? missesInARow + 1 : missesInARow)
        } else {
          flash()
        }
      }
      headline = t[0]; detail = t[1]
      if (msg.done) finished = true
      if (success && mode === "enroll") Qt.callLater(refocus)
    } else if (msg.event === "finished") {
      authWaiting = false
      if (msg.result === "labelled") {
        notice = msg.label ? "Named it “" + msg.label + "”." : "Name cleared."
        refresh()
        return
      }
      if (msg.result === "deleted") {
        notice = activeName + " deleted."
        back()
        return
      }
      if (mode === "verify" && msg.result === "verify-no-match" && missesInARow >= maxMisses)
        detail += " Tests pause now, so a run of misses can't lock Touch ID."
      if (!finished || ["denied", "busy", "timeout", "cancelled", "lid-closed", "no-reader", "error",
                        "claim-failed", "start-failed", "delete-failed", "full", "already-enrolled"].indexOf(msg.result) >= 0) {
        if (msg.result && msg.result.indexOf("enroll-") !== 0 && msg.result.indexOf("verify-") !== 0) {
          t = finishText(msg.result, msg.error)
          headline = t[0]; detail = t[1]
        }
        finished = true
      }
      if (mode === "deleting" && !msg.ok) mode = "result"
      refresh()
    }
  }

  function onOpExited(code) {
    authWaiting = false
    if (!finished && (mode === "enroll" || mode === "verify" || mode === "deleting")) {
      finished = true
      if (!headline.length || headline === "Confirm it's you") {
        headline = "Stopped"
        detail = "Nothing was changed."
      }
    }
  }

  // ---------------------------------------------------------------- keys

  function activate() {
    if (mode === "list") {
      var row = listRows[cursor]
      if (!row) return
      if (row.kind === "add") {
        if (!full) { mode = "pick"; cursor = 0 }
        return
      }
      if (column === 0) startVerify(row.finger)
      else if (column === 1) startRename(row.finger)
      else askDelete(row.finger)
    } else if (mode === "pick") {
      var entry = freeFingers[cursor]
      if (entry) startEnroll(entry)
    } else if (finished || mode === "result") {
      if (mode === "verify" && !success && missesInARow < maxMisses) {
        startVerify({ id: activeFinger, name: nameOf(activeFinger), label: "" })
      } else {
        back()
      }
    }
  }

  function nameOf(id) {
    var all = status && status.fingerNames ? status.fingerNames : []
    for (var i = 0; i < all.length; i++) if (all[i].id === id) return all[i].name
    return id
  }

  function handleKey(event) {
    if (mode === "confirmDelete") return confirm.handleKey(event)
    var count = mode === "pick" ? freeFingers.length : listRows.length
    switch (event.key) {
    case Qt.Key_Escape:
      if (mode === "list") dismiss()
      else if (mode === "pick") { mode = "list"; cursor = listRows.length - 1 }
      else back()
      return true
    case Qt.Key_Up:
    case Qt.Key_K:
      if (mode === "list" || mode === "pick") { cursor = Math.max(0, cursor - 1); column = 0 }
      return true
    case Qt.Key_Down:
    case Qt.Key_J:
      if (mode === "list" || mode === "pick") { cursor = Math.min(count - 1, cursor + 1); column = 0 }
      return true
    case Qt.Key_Left:
    case Qt.Key_H:
      if (mode === "list") column = Math.max(0, column - 1)
      return true
    case Qt.Key_Right:
    case Qt.Key_L:
    case Qt.Key_Tab:
      if (mode === "list") column = Math.min(buttonsFor(listRows[cursor]).length - 1, column + 1)
      return true
    case Qt.Key_Return:
    case Qt.Key_Enter:
    case Qt.Key_Space:
      activate()
      return true
    }
    return false
  }

  // ---------------------------------------------------------------- processes

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: SplitParser { onRead: function(line) { root.onStatusLine(line) } }
    onExited: root.loading = false
  }

  Process {
    id: opProc
    stdout: SplitParser { onRead: function(line) { root.onOpLine(line) } }
    onExited: function(exitCode, exitStatus) { root.onOpExited(exitCode) }
  }

  Timer { id: flashTimer; interval: 260; onTriggered: root.touchFlash = false }
  Timer { id: noticeTimer; interval: 6000; running: root.notice.length > 0; onTriggered: root.notice = "" }

  // ---------------------------------------------------------------- window

  OverlayWindow {
    id: panel
    shown: root.opened
    // While polkit's dialog asks who you are, it needs the keyboard.
    shownKeyboardFocus: root.authWaiting ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "m5pro-touchid"

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Commons.Color.background, 0.7)
      MouseArea { anchors.fill: parent; onClicked: root.mode === "list" ? root.dismiss() : root.refocus() }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { if (root.handleKey(event)) event.accepted = true }
    }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(32), Style.space(480))
      height: card.contentTopInset + card.contentBottomInset + body.implicitHeight
      anchors.centerIn: parent
      color: Commons.Color.background
      borderSpec: Border.flat(Commons.Color.accent, Style.normalBorderWidth)
      padding: Style.spacing.panelPadding
      radius: Style.cornerRadius
      visible: root.mode !== "confirmDelete"

      MouseArea { anchors.fill: parent; onClicked: root.refocus() }

      Column {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: Style.spacing.panelGap

        // Header
        Row {
          spacing: Style.space(12)
          Text {
            text: root.fpGlyph
            color: Commons.Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }
          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              textFormat: Text.PlainText
              text: root.mode === "pick" ? "Add a fingerprint" : "Touch ID"
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: {
                if (root.mode === "pick") return "Which finger?"
                if (!root.status.reader) {
                  if (root.loading) return "Checking the reader…"
                  if (root.status.reason === "lid-closed") return "Open the lid to use Touch ID"
                  return "Touch ID isn't available right now"
                }
                return root.fingers.length + " of " + root.capacity + " fingerprints"
              }
              color: Commons.Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        // List of fingerprints
        Column {
          visible: root.mode === "list"
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.listRows
            delegate: BorderSurface {
              id: rowItem
              required property var modelData
              required property int index
              readonly property bool current: root.cursor === index
              width: parent ? parent.width : 0
              height: Style.space(44)
              color: current ? Util.alpha(Commons.Color.foreground, 0.06) : "transparent"
              borderSpec: Border.flat(current ? Util.alpha(Commons.Color.accent, 0.6) : "transparent", Style.normalBorderWidth)
              radius: Style.cornerRadius

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: { root.cursor = rowItem.index }
                onClicked: { root.cursor = rowItem.index; root.column = 0; if (rowItem.modelData.kind === "add") root.activate() }
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - actions.width - Style.space(24)
                elide: Text.ElideRight
                textFormat: Text.PlainText
                visible: rowItem.modelData.kind === "finger"
                text: rowItem.modelData.kind === "finger" ? root.displayName(rowItem.modelData.finger) : ""
                color: Commons.Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.title
              }
              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(2)
                textFormat: Text.PlainText
                visible: rowItem.modelData.kind === "finger" && !!rowItem.modelData.finger.label
                text: visible ? rowItem.modelData.finger.name : ""
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Row {
                id: actions
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)
                Repeater {
                  model: root.buttonsFor(rowItem.modelData)
                  delegate: Button {
                    required property string modelData
                    required property int index
                    text: modelData
                    bordered: true
                    hasCursor: rowItem.current && root.column === index
                    foreground: (rowItem.modelData.kind === "finger" && index === 2) ? Commons.Color.urgent
                      : (rowItem.modelData.kind === "add" && root.full ? Commons.Color.muted : Commons.Color.foreground)
                    onClicked: { root.cursor = rowItem.index; root.column = index; root.activate() }
                  }
                }
              }
            }
          }

          Text {
            visible: root.status.reader && root.fingers.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "No fingerprints yet. Add one to unlock sudo, the lock screen and 1Password with a touch."
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            visible: !root.status.reader && !root.loading
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.status.reason === "lid-closed" ? "The reader is under the lid."
              : "fprintd can't reach Touch ID (" + (root.status.error || root.status.reason || "unknown") + "). Restarting the Mac brings the Secure Enclave driver up again."
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        // Finger picker
        Column {
          visible: root.mode === "pick"
          width: parent.width
          spacing: Style.space(2)
          Repeater {
            model: root.mode === "pick" ? root.freeFingers : []
            delegate: BorderSurface {
              id: pickItem
              required property var modelData
              required property int index
              readonly property bool current: root.cursor === index
              width: parent ? parent.width : 0
              height: Style.space(30)
              color: current ? Util.alpha(Commons.Color.foreground, 0.08) : "transparent"
              borderSpec: Border.flat(current ? Commons.Color.accent : "transparent", Style.normalBorderWidth)
              radius: Style.cornerRadius
              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: pickItem.modelData.name
                color: pickItem.current ? Commons.Color.accent : Commons.Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.title
              }
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.cursor = pickItem.index
                onClicked: { root.cursor = pickItem.index; root.activate() }
              }
            }
          }
        }

        // Enrol / test / delete progress
        Item {
          visible: root.mode === "enroll" || root.mode === "verify" || root.mode === "deleting" || root.mode === "result"
          width: parent.width
          height: Style.space(150)

          Canvas {
            id: ring
            width: Style.space(120)
            height: width
            anchors.centerIn: parent
            visible: root.mode === "enroll"
            property real progress: root.ringProgress
            property color track: Util.alpha(Commons.Color.foreground, 0.12)
            property color fill: Commons.Color.accent
            onProgressChanged: requestPaint()
            onFillChanged: requestPaint()
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var r = width / 2 - Style.space(4)
              ctx.lineWidth = Style.space(4)
              ctx.strokeStyle = track
              ctx.beginPath(); ctx.arc(width / 2, height / 2, r, 0, 2 * Math.PI); ctx.stroke()
              if (progress > 0) {
                ctx.strokeStyle = fill
                ctx.beginPath()
                ctx.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * progress)
                ctx.stroke()
              }
            }
            Behavior on progress { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          }

          Text {
            anchors.centerIn: parent
            text: root.finished && !root.success ? "" : (root.finished && root.success && root.mode !== "enroll" ? "" : root.fpGlyph)
            color: root.finished ? (root.success ? Commons.Color.accent : Commons.Color.urgent)
              : (root.touchFlash ? Commons.Color.accent : Util.alpha(Commons.Color.foreground, 0.75))
            font.family: Style.font.family
            font.pixelSize: Style.space(64)
            scale: root.touchFlash ? 1.08 : 1
            Behavior on scale { NumberAnimation { duration: 120 } }
            SequentialAnimation on opacity {
              running: !root.finished && !root.authWaiting && root.opened
              loops: Animation.Infinite
              NumberAnimation { from: 1; to: 0.55; duration: 900; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1; duration: 900; easing.type: Easing.InOutSine }
              onRunningChanged: if (!running) parent.opacity = 1
            }
          }
        }

        Column {
          visible: root.mode === "enroll" || root.mode === "verify" || root.mode === "deleting" || root.mode === "result"
          width: parent.width
          spacing: Style.space(4)
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: root.headline
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
            wrapMode: Text.WordWrap
          }
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: root.detail
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: root.mode === "enroll" && root.steps > 0 && !root.finished
            textFormat: Text.PlainText
            text: root.steps + (root.steps === 1 ? " touch" : " touches")
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // Name field: rename, and right after an enrolment
        Column {
          visible: root.mode === "rename" || (root.mode === "enroll" && root.success)
          width: parent.width
          spacing: Style.space(6)
          Text {
            textFormat: Text.PlainText
            text: root.mode === "rename" ? "Name for " + root.activeName.toLowerCase() : "Name (optional)"
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          TextField {
            id: labelField
            width: parent.width
            maximumLength: 40
            placeholderText: root.activeName
            Keys.onReturnPressed: root.saveLabel()
            Keys.onEnterPressed: root.saveLabel()
            Keys.onEscapePressed: root.back()
          }
          Text {
            textFormat: Text.PlainText
            text: "Enter to save · Esc to " + (root.mode === "rename" ? "cancel" : "skip") + ". Only this panel shows the name."
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // Footer
        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          visible: text.length > 0
          text: {
            if (root.notice.length) return root.notice
            if (root.mode === "list") return "↑↓ choose · ←→ action · Enter · Esc close"
            if (root.mode === "pick") return "Enter to start · Esc back"
            if (root.mode === "rename" || (root.mode === "enroll" && root.success)) return ""
            if (root.finished) return root.mode === "verify" && !root.success && root.missesInARow < root.maxMisses
              ? "Enter to try again · Esc back" : "Enter or Esc to go back"
            if (root.authWaiting) return ""
            return "Esc to cancel"
          }
          color: root.notice.length ? Commons.Color.accent : Commons.Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    ConfirmDialog {
      id: confirm
      anchors.fill: parent
      opened: root.mode === "confirmDelete"
      message: root.fingers.length <= 1
        ? "Delete " + root.activeName + "? It is your last fingerprint: sudo, the lock screen and 1Password then ask for your password. Touch ID forgets it in the Secure Enclave."
        : "Delete " + root.activeName + "? Touch ID forgets this fingerprint in the Secure Enclave. You can add it again later."
      confirmText: "Delete"
      onCanceled: root.back()
      onConfirmed: root.doDelete()
    }
  }
}
