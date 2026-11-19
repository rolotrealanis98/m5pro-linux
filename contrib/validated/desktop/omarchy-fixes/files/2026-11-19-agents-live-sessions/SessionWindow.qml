import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A larger pop-out for one live agent session: its terminal screen (Herdr) or
// its recent conversation (a local Claude Code window), with a reply field and
// the keys a permission prompt asks for. Opens from the My Agents panel.
OverlayWindow {
  id: win

  property var session: null
  property string scriptPath: ""
  property string fontFamily: Style.font.family
  property color foreground: Commons.Color.foreground

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property bool isHerdr: !!session && session.kind === "herdr"
  readonly property bool isLocal: !!session && session.kind === "local"
  readonly property bool waiting: liveState === "waiting"

  property string mode: ""          // "screen" | "chat"
  property string screenText: ""
  property var messages: []
  property string liveState: session ? session.state : ""
  property string waitingFor: session ? session.waitingFor : ""
  property string error: ""
  property bool revealed: false

  WlrLayershell.namespace: "rolo-agent-session"

  function openSession(s) {
    session = s
    mode = ""
    screenText = ""
    messages = []
    error = ""
    liveState = s.state
    waitingFor = s.waitingFor || ""
    reply.text = ""
    shown = true
    refresh()
  }

  function dismiss() {
    revealed = false
    closeTimer.restart()
  }

  function refresh() {
    if (!session || readProc.running) return
    readProc.command = ["python3", scriptPath, "read", session.kind, session.id]
    readProc.running = true
  }

  function run(args) {
    Quickshell.execDetached(["python3", scriptPath].concat(args))
  }

  // A local window can only be typed into once it has the keyboard, so the
  // pop-out gets out of the way first and the helper focuses the terminal.
  function sendText() {
    var text = reply.text.trim()
    if (!session || text === "") return
    reply.text = ""
    if (isLocal) {
      dismiss()
      run(["send", session.kind, session.id, text])
    } else {
      run(["send", session.kind, session.id, text])
      followUp.restart()
    }
  }

  function pressKey(key) {
    if (!session) return
    if (isLocal) {
      dismiss()
      run(["keys", session.kind, session.id, key])
    } else {
      run(["keys", session.kind, session.id, key])
      followUp.restart()
    }
  }

  function goToTerminal() {
    if (!session) return
    dismiss()
    if (session.interactive) run(["focus", session.kind, session.id])
    else Quickshell.execDetached(["omarchy-launch-or-focus-tui", "--app-id=cds", "cds"])
  }

  onShownChanged: if (shown) Qt.callLater(function() { win.revealed = true; reply.forceActiveFocus() })

  Timer { id: closeTimer; interval: Style.duration(130); onTriggered: win.shown = false }
  Timer { id: followUp; interval: 600; onTriggered: win.refresh() }
  Timer {
    interval: win.isHerdr ? 1500 : (win.isLocal ? 2500 : 8000)
    running: win.shown && !!win.session
    repeat: true
    onTriggered: win.refresh()
  }

  Process {
    id: readProc
    stdout: StdioCollector {
      onStreamFinished: {
        var data
        try { data = JSON.parse(text) } catch (e) { return }
        if (data.error) { win.error = String(data.error); return }
        win.error = ""
        var stick = body.atYEnd || win.mode === ""
        win.mode = data.mode || ""
        if (data.mode === "screen") win.screenText = String(data.text || "")
        else {
          win.messages = Array.isArray(data.messages) ? data.messages : []
          if (data.state) win.liveState = data.state
          win.waitingFor = data.waitingFor || ""
        }
        if (stick) Qt.callLater(function() { body.contentY = Math.max(0, body.contentHeight - body.height) })
      }
    }
  }

  // ------------------------------------------------------------- scrim
  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.55)
    opacity: win.revealed ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(win.revealed ? 180 : 120); easing.type: Easing.OutCubic } }
    MouseArea { anchors.fill: parent; onClicked: win.dismiss() }
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: true
    Keys.onEscapePressed: win.dismiss()

    // ------------------------------------------------------------- card
    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(64), Style.space(980))
      height: Math.min(parent.height - Style.space(96), Style.space(760))
      radius: Style.cornerRadius
      color: Commons.Color.popups.background
      borderSpec: Border.localOrSurfaceSpec("popups", "border", Commons.Color.popups.border, Commons.Color.popups.border, Math.max(1, Style.space(2)))

      opacity: win.revealed ? 1 : 0
      scale: win.revealed ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: Style.duration(win.revealed ? 180 : 120); easing.type: Easing.OutCubic } }
      Behavior on scale {
        NumberAnimation { duration: Style.duration(win.revealed ? 180 : 120); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
      }

      MouseArea { anchors.fill: parent; onClicked: reply.forceActiveFocus() }

      // ---------------------------------------------------------- header
      Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(20)
        height: Math.max(headerText.implicitHeight, headerButtons.implicitHeight)

        Rectangle {
          id: stateDot
          width: Style.space(10); height: width; radius: width / 2
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.topMargin: Math.max(0, (headerTitle.implicitHeight - height) / 2)
          color: win.waiting ? Commons.Color.accent : win.foreground
          opacity: win.waiting ? 1 : 0.6
        }

        Column {
          id: headerText
          anchors.left: stateDot.right
          anchors.leftMargin: Style.space(12)
          anchors.right: headerButtons.left
          anchors.rightMargin: Style.space(12)
          spacing: Style.space(2)

          Text {
            id: headerTitle
            width: parent.width
            textFormat: Text.PlainText
            text: win.session ? win.session.title : ""
            color: win.foreground
            font.family: win.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: !win.session ? "" : [
              win.waiting ? (win.waitingFor || "Needs you") : (win.liveState === "working" ? "Working" : "Idle"),
              win.session.provider,
              win.session.machine === "here" ? "this machine" + (win.session.workspace ? " · workspace " + win.session.workspace : "") : win.session.machine,
              win.session.where
            ].filter(function(s) { return !!s }).join("  ·  ")
            color: win.waiting ? Commons.Color.accent : win.dim
            font.family: win.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: win.waiting
            elide: Text.ElideRight
          }
        }

        Row {
          id: headerButtons
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Button {
            text: win.session && !win.session.interactive ? "Open in cds" : "Go to terminal"
            iconText: "󰆍"
            foreground: win.foreground
            fontFamily: win.fontFamily
            tooltipText: !win.session ? "" : (!win.session.interactive ? "Open the cds dashboard" : (win.isLocal ? "Switch to its window" : "Attach to it in a terminal"))
            onClicked: win.goToTerminal()
          }
          PanelActionButton {
            iconText: "󰅖"
            foreground: win.dim
            fontFamily: win.fontFamily
            tooltipText: "Close (Esc)"
            onClicked: win.dismiss()
          }
        }
      }

      PanelSeparator {
        id: topRule
        anchors.top: header.bottom
        anchors.topMargin: Style.space(14)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(20)
        anchors.rightMargin: Style.space(20)
        foreground: win.foreground
      }

      // ------------------------------------------------------------ body
      Flickable {
        id: body
        anchors.top: topRule.bottom
        anchors.bottom: footer.visible ? footer.top : readOnlyNote.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(20)
        clip: true
        contentWidth: width
        contentHeight: bodyColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: bodyColumn
          width: body.width - Style.space(12)
          spacing: Style.space(12)

          Text {
            visible: win.mode === "" || win.error !== ""
            width: parent.width
            topPadding: Style.space(24)
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: win.error !== "" ? win.error : "Loading…"
            color: win.dim
            font.family: win.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          // Herdr: the live terminal screen, as text.
          Text {
            visible: win.mode === "screen" && win.error === ""
            width: parent.width
            textFormat: Text.PlainText
            text: win.screenText
            color: win.foreground
            font.family: win.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WrapAnywhere
          }

          // Local: the conversation.
          Repeater {
            model: win.mode === "chat" && win.error === "" ? win.messages : []

            Item {
              id: msg
              required property var modelData
              readonly property string role: modelData.role
              width: bodyColumn.width
              implicitHeight: role === "user" ? userBubble.height : (role === "assistant" ? assistantText.implicitHeight : toolRow.implicitHeight)

              BorderSurface {
                id: userBubble
                visible: msg.role === "user"
                anchors.right: parent.right
                width: Math.min(parent.width * 0.8, userText.implicitWidth + Style.space(24))
                height: userText.implicitHeight + Style.space(16)
                radius: Style.cornerRadius
                color: Style.selectedFillFor(win.foreground, Commons.Color.accent)
                borderSpec: Border.none()

                Text {
                  id: userText
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  textFormat: Text.PlainText
                  text: msg.role === "user" ? msg.modelData.text : ""
                  color: win.foreground
                  font.family: win.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                }
              }

              Text {
                id: assistantText
                visible: msg.role === "assistant"
                width: parent.width * 0.92
                textFormat: Text.PlainText
                text: msg.role === "assistant" ? msg.modelData.text : ""
                color: win.foreground
                font.family: win.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
                lineHeight: 1.15
              }

              Row {
                id: toolRow
                visible: msg.role === "tool" || msg.role === "tools"
                width: parent.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: msg.modelData.pending ? "󰔟" : "󰒓"
                  color: msg.modelData.pending ? Commons.Color.accent : win.dim
                  font.family: win.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  width: parent.width - Style.space(24)
                  textFormat: Text.PlainText
                  text: (msg.modelData.pending ? "Waiting to run: " : (msg.modelData.count > 1 ? msg.modelData.count + " tool calls · last: " : ""))
                    + msg.modelData.text
                  color: msg.modelData.pending ? Commons.Color.accent : win.dim
                  font.family: win.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: !!msg.modelData.pending
                  elide: Text.ElideRight
                }
              }
            }
          }
        }
      }

      // Desktop and profile sessions can be read from here but only answered in their own app.
      Text {
        id: readOnlyNote
        visible: !!win.session && !win.session.interactive
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(20)
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: !win.session ? "" : "Read only. This is a " + (win.session.name === "Desktop" ? "Claude Desktop" : win.session.name)
          + " session on " + (win.session.machine === "here" ? "this machine" : win.session.machine) + "; answer it there."
        color: win.dim
        font.family: win.fontFamily
        font.pixelSize: Style.font.caption
      }

      // ---------------------------------------------------------- footer
      Column {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(20)
        spacing: Style.space(10)
        visible: !!win.session && win.session.interactive

        PanelSeparator { width: parent.width; foreground: win.foreground }

        // The keys a Claude Code prompt asks for. A local session says when it's
        // asking; a Herdr screen can't, so there they're always offered.
        Row {
          spacing: Style.space(6)
          visible: win.waiting || win.isHerdr

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Answer"
            color: win.dim
            font.family: win.fontFamily
            font.pixelSize: Style.font.caption
            rightPadding: Style.space(4)
          }

          Repeater {
            model: [
              { key: "1", label: "1  Yes" },
              { key: "2", label: "2  Always" },
              { key: "3", label: "3  No" },
              { key: "esc", label: "Esc" },
              { key: "enter", label: "↵" }
            ]
            Button {
              required property var modelData
              text: modelData.label
              foreground: win.foreground
              fontFamily: win.fontFamily
              fontSize: Style.font.caption
              bordered: true
              onClicked: win.pressKey(modelData.key)
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: reply
            width: parent.width - sendButton.width - parent.spacing
            foreground: win.foreground
            font.family: win.fontFamily
            placeholderText: win.isLocal ? "Reply… (Enter sends it to the terminal and switches to it)" : "Reply… (Enter sends)"
            onAccepted: win.sendText()
            Keys.onEscapePressed: win.dismiss()
          }

          Button {
            id: sendButton
            anchors.verticalCenter: reply.verticalCenter
            text: "Send"
            iconText: "󰒊"
            foreground: win.foreground
            fontFamily: win.fontFamily
            enabled: reply.text.trim() !== ""
            opacity: enabled ? 1 : 0.5
            onClicked: win.sendText()
          }
        }
      }
    }
  }
}
