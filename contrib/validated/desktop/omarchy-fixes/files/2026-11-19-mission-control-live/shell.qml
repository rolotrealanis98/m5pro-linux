import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "Layout.js" as Layout

// Mission Control for Omarchy on Hyprland.
//
//   three fingers up / down   open / close, following the fingers
//   three fingers left/right  move between workspaces (Hyprland does the switch)
//   Ctrl + Up                 toggle (bound in ~/.config/hypr/bindings.lua)
//   click a window            go to it
//   drag a window             onto a workspace in the strip, or onto "+"
//   hover, then the x         close a window or a workspace
//   Esc, arrows, Enter, Tab, 1-9, Delete from the keyboard
//
// Runs as its own Quickshell instance (see mission-control.service) so it can
// render on the GPU while the Omarchy shell stays on the software renderer.
// The rounded window pictures are shader effects: it needs the GPU renderer.
ShellRoot {
  id: mc

  // ------------------------------------------------------------------ tuning
  // Finger travel, in libinput's unaccelerated units, for a full open or close
  // and for one workspace. Larger means a longer swipe.
  readonly property real swipeDistance: 250
  readonly property real pageDistance: 300
  // Spring rates (rad/s). Higher is snappier.
  readonly property real omega: 24
  readonly property real pageOmega: 21
  // Draw this many milliseconds ahead of the fingers, along their current
  // speed, to make up for the frame or two between a touch and the screen.
  readonly property real leadMs: 8
  // If the fingers moved before the first picture was ready, catch up over
  // this long instead of jumping.
  readonly property real catchMs: 45

  readonly property bool gpu: String(Quickshell.env("QT_QUICK_BACKEND") || "").indexOf("software") !== 0
  readonly property bool captureOn: String(Quickshell.env("MC_CAPTURE") || "1") !== "0"
  readonly property string home: Quickshell.env("HOME")
  readonly property int slots: 10   // Omarchy gives each monitor ten workspaces

  // ------------------------------------------------------------------- theme
  property color accent: "#ff9f0a"
  property color bg: "#1c1c1e"
  property color fg: "#f5f5f7"
  property color cardColor: "#2c2c2e"
  property string fontFamily: "monospace"
  property string wallpaperUrl: ""

  function parseTheme(text) {
    var want = { accent: "accent", background: "bg", foreground: "fg", lighter_background: "cardColor" }
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6,8})"/)
      if (m && want[m[1]]) mc[want[m[1]]] = m[2]
    }
  }

  FileView {
    path: mc.home + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: mc.parseTheme(text())
  }

  Process {
    running: true
    command: ["fc-match", "-f", "%{family[0]}", "monospace"]
    stdout: StdioCollector { onStreamFinished: if (text.trim() !== "") mc.fontFamily = text.trim() }
  }

  Process {
    id: wallpaperProc
    command: ["readlink", "-f", mc.home + "/.local/state/omarchy/current/background"]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = text.trim()
        var still = /\.(png|jpe?g|webp|avif|bmp|gif)$/i.test(path)
        mc.wallpaperUrl = path !== "" && still ? "file://" + path : ""
      }
    }
  }

  // Hyprland's window border and rounding, so a window looks the same at the
  // moment the overview takes over from the desktop.
  property int borderSize: 2
  property int rounding: 6
  property color activeBorder: accent
  property color inactiveBorder: "#aa595959"

  Process {
    id: decorProc
    command: ["sh", "-c", "for o in general:border_size decoration:rounding general:col.active_border general:col.inactive_border; do hyprctl -j getoption $o; echo; done"]
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var o = null
          try { o = JSON.parse(lines[i]) } catch (e) { continue }
          if (!o || !o.option) continue
          var hex = String(o.gradient || "").match(/^([0-9a-fA-F]{8})\b/)
          if (o.option === "general:border_size" && o["int"] >= 0) mc.borderSize = o["int"]
          else if (o.option === "decoration:rounding" && o["int"] >= 0) mc.rounding = o["int"]
          else if (o.option === "general:col.active_border" && hex) mc.activeBorder = "#" + hex[1]
          else if (o.option === "general:col.inactive_border" && hex) mc.inactiveBorder = "#" + hex[1]
        }
      }
    }
  }

  // ------------------------------------------------------------------- state
  property bool mapped: false        // the overview is in use (its surface is always there, empty)
  property bool revealed: false      // and its first frames are ready
  property bool pendingOpen: false
  property bool peeking: false       // shown for a screenshot: no input taken
  property real holdAt: -1           // testing: reveal frozen at this progress
  property bool warm: false          // mapped early because fingers rest on the pad

  property real progress: 0          // 0 the desktop, 1 the overview
  property real progressTarget: 0
  property real progressVel: 0
  property real page: 0              // position along the workspaces, in pages
  property real pageTarget: 0
  property real pageVel: 0
  property bool ticking: false
  property bool gesturing: false
  property var g: null               // the swipe in progress
  property double holdCloseUntil: 0

  readonly property real shown: Math.max(0, Math.min(1, progress))
  readonly property bool interactive: revealed && !peeking && !gesturing && progressTarget > 0.5
  readonly property bool settled: revealed && !gesturing && progressTarget === 1 && Math.abs(progress - 1) < 0.002
  readonly property bool layoutAnimated: settled

  property var monitor: null
  property var screen: null
  property int offX: 0
  property int offY: 0
  property real screenW: 1
  property real screenH: 1
  property real viewW: 1
  property real viewH: 1
  property int activeWs: -1

  ListModel { id: winModel }
  ListModel { id: spaceModel }
  property var spaceIds: []
  property var tops: ({})
  property var wsWins: ({})
  property var targets: ({})
  property var extraSpaces: []
  property string signature: ""

  property var ready: ({})
  property bool priming: false       // the one silent run after start that compiles the shaders
  property int readyWait: 0
  // When things happened in the current opening (Date.now()), for the log.
  property double touchAt: 0
  property double mapAt: 0
  property double latchAt: 0
  property double revealAt: 0
  property bool thumbsOn: false

  property string hoverAddr: ""
  property string selAddr: ""
  property string raisedAddr: ""
  property var dragTile: null
  property int dropTarget: 0         // workspace id under a dragged window, -1 for "+", 0 none

  // layout
  readonly property real thumbW: 172
  readonly property real thumbH: Math.round(thumbW * viewH / Math.max(1, viewW))
  readonly property real stripH: 18 + thumbH + 22 + 12
  readonly property real pageStride: viewW + 96
  readonly property var stageRect: ({ x: 72, y: stripH + 44, w: viewW - 144, h: viewH - stripH - 44 - 72 })

  // frame statistics of the last animation, for `status`
  property var stat: ({ frames: 0, sum: 0, max: 0 })
  property var lastStat: ({ frames: 0, avgMs: 0, maxMs: 0 })

  // ------------------------------------------------------------ open / close

  // Creating a GPU surface takes 100 to 250 ms here, a whole swipe. So the
  // overlay's surface is made once and stays mapped: empty, transparent and
  // click-through until the overview is used. It is parked on the focused
  // monitor ahead of time.
  function park() {
    if (mc.mapped) return false
    var mon = Hyprland.focusedMonitor
    if (!mon) return false
    var scr = null
    for (var i = 0; i < Quickshell.screens.length; i++)
      if (Quickshell.screens[i].name === mon.name) scr = Quickshell.screens[i]
    if (!scr) return false
    if (mc.monitor !== mon) mc.monitor = mon
    if (mc.screen !== scr) mc.screen = scr
    mc.readGeometry()
    return true
  }

  function readGeometry() {
    var mon = mc.monitor
    if (!mon || !mc.screen) return
    var mo = mon.lastIpcObject || ({})
    var res = mo.reserved || [0, 0, 0, 0]
    mc.offX = res[0]
    mc.offY = res[1]
    mc.screenW = mc.screen.width
    mc.screenH = mc.screen.height
    mc.viewW = Math.max(1, mc.screenW - res[0] - res[2])
    mc.viewH = Math.max(1, mc.screenH - res[1] - res[3])
  }

  Connections {
    target: Hyprland
    function onFocusedMonitorChanged() { mc.park() }
  }
  Connections {
    target: Quickshell
    function onScreensChanged() { mc.park() }
  }
  Timer { interval: 400; running: true; onTriggered: { Hyprland.refreshMonitors(); mc.park() } }
  Timer { interval: 1500; running: true; onTriggered: mc.park() }

  function prepare() {
    if (mc.mapped) return true
    if (!mc.park()) return false
    Hyprland.refreshMonitors()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()

    mc.ready = ({})
    mc.readyWait = 0
    mc.mapAt = Date.now()
    mc.visibleAt = 0
    mc.firstTileAt = 0
    mc.latchAt = 0
    mc.revealAt = 0
    mc.revealed = false
    mc.thumbsOn = false
    mc.pendingOpen = false
    mc.progress = 0
    mc.progressVel = 0
    mc.progressTarget = 0
    mc.pageVel = 0
    mc.hoverAddr = ""
    mc.selAddr = ""
    mc.raisedAddr = ""
    mc.dragTile = null
    mc.dropTarget = 0
    mc.holdCloseUntil = 0

    mc.mapped = true
    mc.rebuild()
    mc.page = Math.max(0, mc.spaceIds.indexOf(mc.activeWs))
    mc.pageTarget = mc.page
    wallpaperProc.running = true
    decorProc.running = true
    return true
  }

  function open() {
    if (mc.gesturing) return
    mc.stopPriming()
    mc.touchAt = 0
    if (!mc.prepare()) return
    mc.peeking = false
    if (mc.revealed) {
      mc.progressTarget = 1
      mc.animate()
    } else {
      mc.pendingOpen = true
    }
  }

  function close() {
    if (mc.gesturing || !mc.mapped) return
    mc.pendingOpen = false
    mc.progressTarget = 0
    if (!mc.revealed || mc.progress <= 0) mc.finishClose()
    else mc.animate()
  }

  function toggle() {
    if (mc.gesturing) return
    if (mc.mapped && (mc.progressTarget > 0.5 || mc.pendingOpen)) mc.close()
    else mc.open()
  }

  function finishClose() {
    // After a workspace change, wait out Hyprland's own switch animation
    // underneath: at progress 0 the overlay shows exactly what it will show.
    var wait = mc.holdCloseUntil - Date.now()
    if (wait > 0) {
      closeHold.interval = wait
      closeHold.restart()
      return
    }
    mc.mapped = false
    mc.revealed = false
    mc.thumbsOn = false
    mc.peeking = false
    mc.warm = false
    mc.pendingOpen = false
    mc.ticking = false
    mc.progress = 0
    mc.progressTarget = 0
    mc.progressVel = 0
    mc.dragTile = null
    mc.hoverAddr = ""
    mc.selAddr = ""
    mc.priming = false
    // The window and workspace items stay (building them costs about 15 ms
    // of an opening); only their pictures are dropped until the next use.
  }

  Timer { id: closeHold; onTriggered: if (mc.progressTarget === 0 && mc.progress <= 0) mc.finishClose() }
  Timer { id: warmTimer; interval: 320; onTriggered: { mc.warm = false; if (!mc.gesturing && !mc.pendingOpen && mc.progressTarget === 0 && mc.progress <= 0) mc.finishClose() } }
  // One silent run shortly after start: everything is drawn once, all but
  // transparent, so the first real opening does not pay for shader compiles.
  Timer {
    interval: 1200
    running: true
    onTriggered: {
      if (mc.mapped || !mc.prepare()) return
      mc.priming = true
      mc.peeking = true
      mc.holdAt = 1
      primeEnd.restart()
    }
  }
  Timer {
    id: primeEnd
    interval: 450
    onTriggered: {
      if (!mc.priming) return
      mc.progressTarget = 0
      mc.progress = 0
      mc.finishClose()
    }
  }
  function stopPriming() {
    if (!mc.priming) return
    mc.priming = false
    mc.peeking = false
    mc.progress = 0
    mc.progressTarget = 0
  }

  Timer { id: peekTimer; onTriggered: { mc.peeking = false; mc.progressTarget = 0; mc.holdCloseUntil = 0; mc.finishClose() } }
  Timer { id: thumbsTimer; interval: 30; onTriggered: mc.thumbsOn = true }

  property double visibleAt: 0
  property double firstTileAt: 0
  function tileReady(addr) {
    if (mc.firstTileAt === 0) mc.firstTileAt = Date.now()
    mc.ready[addr] = true
    if (!mc.revealed) Qt.callLater(mc.tryReveal)
  }

  // Draw nothing until the windows of the visible workspace have a frame, so
  // the overlay's first picture is the desktop it replaces.
  function tryReveal() {
    if (!mc.mapped || mc.revealed) return
    if (!panel.backingWindowVisible || panel.width < 2) return
    if (mc.visibleAt === 0) mc.visibleAt = Date.now()
    var waited = Date.now() - mc.mapAt
    mc.readyWait = waited
    var list = mc.wsWins[mc.activeWs] || []
    if (mc.captureOn && waited < 180) {
      for (var i = 0; i < list.length; i++) if (!mc.ready[list[i].addr]) return
    }
    mc.revealed = true
    mc.revealAt = Date.now()
    thumbsTimer.restart()
    if (mc.priming || mc.peeking)
      console.info("open: first window picture after " + (mc.firstTileAt > 0 ? mc.firstTileAt - mc.mapAt : -1)
        + " ms, all " + list.length + " after " + waited + " ms" + (mc.priming ? " (warm-up run)" : ""))
    if (mc.touchAt > 0 || mc.latchAt > 0)
      console.info("open: map to first picture " + waited + " ms"
        + (mc.touchAt > 0 ? ", fingers down to first picture " + (mc.revealAt - mc.touchAt) + " ms" : "")
        + (mc.latchAt > 0 ? ", swipe seen to first picture " + (mc.revealAt - mc.latchAt) + " ms, progress then " + (mc.g ? Math.round(mc.g.raw * 100) / 100 : 0) : ""))
    if (mc.holdAt >= 0) {
      mc.progress = mc.holdAt
      mc.progressTarget = mc.holdAt
      mc.holdAt = -1
    }
    if (mc.pendingOpen) {
      mc.pendingOpen = false
      mc.progressTarget = 1
      mc.animate()
    }
  }

  Timer {
    interval: 4
    repeat: true
    running: mc.mapped && !mc.revealed
    onTriggered: mc.tryReveal()
  }

  // ---------------------------------------------------------------- springs

  function animate() {
    mc.stat = ({ frames: 0, sum: 0, max: 0 })
    mc.ticking = true
  }

  FrameAnimation {
    running: mc.ticking && mc.mapped
    onTriggered: {
      var dt = Math.min(0.05, Math.max(0.0005, frameTime))
      mc.stat.frames += 1
      mc.stat.sum += frameTime
      if (frameTime > mc.stat.max) mc.stat.max = frameTime

      var busy = false
      var vertical = mc.gesturing && mc.g && mc.g.axis === "v"
      if (vertical) mc.applyVertical()
      var sideways = mc.gesturing && mc.g && mc.g.axis === "h"

      if (!vertical && (mc.progress !== mc.progressTarget || mc.progressVel !== 0)) {
        var r = Layout.spring(mc.progress, mc.progressVel, mc.progressTarget, mc.omega, dt)
        if (Math.abs(r[0] - mc.progressTarget) < 0.0008 && Math.abs(r[1]) < 0.03) {
          mc.progress = mc.progressTarget
          mc.progressVel = 0
        } else {
          mc.progress = r[0]
          mc.progressVel = r[1]
          busy = true
        }
      }
      if (!sideways && (mc.page !== mc.pageTarget || mc.pageVel !== 0)) {
        var q = Layout.spring(mc.page, mc.pageVel, mc.pageTarget, mc.pageOmega, dt)
        if (Math.abs(q[0] - mc.pageTarget) < 0.0008 && Math.abs(q[1]) < 0.03) {
          mc.page = mc.pageTarget
          mc.pageVel = 0
        } else {
          mc.page = q[0]
          mc.pageVel = q[1]
          busy = true
        }
      }
      if (busy || mc.gesturing) return

      mc.ticking = false
      if (mc.stat.frames > 3)
        mc.lastStat = ({ frames: mc.stat.frames, avgMs: Math.round(mc.stat.sum / mc.stat.frames * 10000) / 10, maxMs: Math.round(mc.stat.max * 10000) / 10 })
      if (mc.progressTarget === 0 && mc.progress <= 0) mc.finishClose()
    }
  }

  // --------------------------------------------------------------- gestures

  // The Pointer panel's "Three-finger drag" turns three-finger swipes into a
  // drag in Hyprland; the overview must not open under a drag.
  property bool threeFingerDrag: false
  FileView {
    path: mc.home + "/.config/hypr/pointer-tuning.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var on = false
      try {
        var d = JSON.parse(text())
        on = d.profiles[d.profile].trackpad_three_finger_drag === true
      } catch (e) {}
      mc.threeFingerDrag = on
    }
  }

  Process {
    id: gestureProc
    running: true
    command: [Qt.resolvedUrl("mc-gestures").toString().replace(/^file:\/\//, "")]
    stdout: SplitParser { onRead: function(line) { mc.onGesture(line) } }
    stderr: SplitParser { onRead: function(line) { console.info(line) } }
    onExited: gestureRestart.restart()
  }
  Timer { id: gestureRestart; interval: 3000; onTriggered: gestureProc.running = true }

  function onGesture(line) {
    if (mc.threeFingerDrag && !mc.gesturing) return
    var a = String(line).split(" ")
    var g = mc.g
    if (a[0] === "R") {
      if (g && g.src === "raw") mc.swipeUpdate(parseFloat(a[1]), parseFloat(a[2]), parseFloat(a[3]))
    } else if (a[0] === "U") {
      if (g && g.src === "li") mc.swipeUpdate(parseFloat(a[1]), parseFloat(a[2]), parseFloat(a[3]))
    } else if (a[0] === "T") {
      // Two fingers down is often the way to three: ask Hyprland for the
      // window boxes now, so they are current when the pictures are taken.
      if (parseInt(a[1]) >= 2 && !mc.mapped && !boxesAsked.running) {
        Hyprland.refreshToplevels()
        boxesAsked.restart()
      }
      // Three fingers just landed: get the window pictures ready before they move.
      if (parseInt(a[1]) === 3) {
        mc.touchAt = Date.now()
        if (!mc.mapped && mc.prepare()) mc.warm = true
        if (mc.warm) warmTimer.stop()
      } else if (mc.warm) {
        warmTimer.restart()
      }
    } else if (a[0] === "RB") {
      // The raw contacts see a swipe before libinput does. They lead unless
      // libinput is already driving one.
      if (!(g && g.src === "li" && (g.axis === "v" || g.axis === "h")))
        mc.g = { src: "raw", fingers: 3, axis: "", ax: 0, ay: 0, base: 0, raw: 0, hist: [], at: Date.now() }
    } else if (a[0] === "RE") {
      if (g && g.src === "raw") mc.swipeEnd(false)
    } else if (a[0] === "H") {
      if (parseInt(a[1]) === 3 && !mc.mapped && mc.prepare()) {
        mc.warm = true
        warmTimer.stop()
      }
    } else if (a[0] === "h") {
      if (mc.warm) warmTimer.restart()
    } else if (a[0] === "B") {
      // Up and down already follow the raw contacts; libinput keeps sideways.
      if (!(g && g.src === "raw" && g.axis === "v"))
        mc.g = { src: "li", fingers: parseInt(a[1]), axis: "", ax: 0, ay: 0, base: 0, raw: 0, hist: [], at: Date.now() }
    } else if (a[0] === "E") {
      if (g && g.src === "li") mc.swipeEnd(a[1] === "1")
    }
  }

  function swipeUpdate(dx, dy, t) {
    var g = mc.g
    if (!g || !isFinite(dx) || !isFinite(dy)) return
    g.ax += dx
    g.ay += dy

    if (g.axis === "") {
      // The raw source only speaks once the fingers agree; libinput needs a moment.
      if (g.src === "li" && Math.abs(g.ax) + Math.abs(g.ay) < 3) return
      if (Math.abs(g.ay) > Math.abs(g.ax)) {
        var up = g.ay < 0
        var showing = mc.mapped && (mc.progressTarget > 0.5 || mc.progress > 0.02 || mc.pendingOpen)
        // Down on the plain desktop, or four fingers, is not ours.
        if (mc.priming) { mc.stopPriming(); showing = false }
        if (g.fingers !== 3 || (!showing && !up) || !mc.prepare()) { g.axis = "x"; return }
        g.axis = "v"
        g.base = mc.progress
        mc.latchAt = Date.now()
        mc.warm = false
        warmTimer.stop()
        peekTimer.stop()
        mc.peeking = false
        mc.pendingOpen = false
        mc.progressVel = 0
        mc.gesturing = true
        mc.ticking = true
      } else {
        // Sideways only matters while the overview is up: Hyprland switches
        // the workspace underneath and the stage follows the fingers. That
        // one stays with libinput, which is what Hyprland itself listens to.
        if (g.src !== "li" || !(mc.mapped && mc.revealed && mc.progressTarget > 0.5)) { g.axis = "x"; return }
        g.axis = "h"
        g.base = mc.page
        mc.pageVel = 0
        mc.gesturing = true
      }
    }

    if (g.axis === "v") {
      g.raw = g.base - g.ay / mc.swipeDistance
    } else if (g.axis === "h") {
      g.raw = g.base - g.ax / mc.pageDistance
      var last = mc.spaceIds.length - 1
      var lo = Math.max(-0.3, Math.round(g.base) - 1)
      var hi = Math.min(last + 1, Math.round(g.base) + 1)
      mc.page = Math.max(lo, Math.min(hi, g.raw))
    } else {
      return
    }
    g.hist.push([t, g.raw])
    if (g.hist.length > 6) g.hist.shift()
    g.seen = Date.now()
    if (g.axis === "v") mc.applyVertical()
  }

  // Where to draw an up/down swipe right now.
  function applyVertical() {
    var g = mc.g
    if (!g || g.axis !== "v") return
    var now = Date.now()
    var p = g.raw
    // A little ahead of the fingers while they move, never once they stop.
    if (mc.leadMs > 0 && now - g.seen < 24 && g.hist.length >= 3) {
      var a = g.hist[g.hist.length - 3], b = g.hist[g.hist.length - 1]
      var dt = (b[0] - a[0]) / 1000
      if (dt > 0.004) p += Math.max(-0.06, Math.min(0.06, (b[1] - a[1]) / dt * mc.leadMs / 1000))
    }
    // The first picture arrived after the fingers had moved: close the gap fast.
    // A small gap is simply taken; a large one gets up to catchMs.
    var blend = 1
    if (mc.revealAt > g.at && mc.catchMs > 0) {
      if (g.catchFor === undefined) g.catchFor = Math.min(mc.catchMs, Math.abs(g.raw - g.base) * 400)
      if (g.catchFor > 1) blend = Math.min(1, (now - mc.revealAt) / g.catchFor)
    }
    mc.progress = Layout.rubber(g.base + (p - g.base) * blend)
  }

  function swipeVelocity(g) {
    if (g.hist.length < 2) return 0
    var a = g.hist[0], b = g.hist[g.hist.length - 1]
    var dt = (b[0] - a[0]) / 1000
    return dt > 0.004 ? (b[1] - a[1]) / dt : 0
  }

  function swipeEnd(cancelled) {
    var g = mc.g
    mc.g = null
    if (!g || (g.axis !== "v" && g.axis !== "h")) return
    var v = mc.swipeVelocity(g)
    // Fingers that stopped before lifting carry no speed.
    if (Date.now() - g.seen > 60) v = 0
    mc.gesturing = false

    if (g.axis === "v") {
      var projected = g.raw + v * 0.16
      mc.progressTarget = cancelled ? (g.base > 0.5 ? 1 : 0) : (projected > 0.5 ? 1 : 0)
      mc.progressVel = Math.max(-14, Math.min(14, v))
      if (mc.progress > 1) mc.progressVel = 0
    } else {
      // Guess where Hyprland lands, then take its word for it a moment later.
      var guess = Math.round(mc.page + v * 0.12)
      var from = Math.round(g.base)
      guess = Math.max(from - 1, Math.min(from + 1, guess))
      mc.pageTarget = Math.max(0, Math.min(mc.spaceIds.length - 1, guess))
      mc.pageVel = Math.max(-14, Math.min(14, v))
      pageSettle.restart()
    }
    mc.animate()
  }

  Timer { id: boxesAsked; interval: 400 }
  Timer { id: pageSettle; interval: 70; onTriggered: mc.followActive() }

  function followActive() {
    if (!mc.mapped || (mc.gesturing && mc.g && mc.g.axis === "h")) return
    var index = mc.spaceIds.indexOf(mc.activeWs)
    if (index < 0 || index === mc.pageTarget) return
    mc.pageTarget = index
    mc.animate()
  }

  // ------------------------------------------------------------------- data

  function blockOf(id) { return Math.floor((id - 1) / mc.slots) }
  function slotOf(id) { return (id - 1) % mc.slots + 1 }
  readonly property int ownBlock: activeWs > 0 ? blockOf(activeWs) : 0
  function labelFor(id) { return String(mc.blockOf(id) === mc.ownBlock ? mc.slotOf(id) : id) }

  function iconFor(appId) {
    var entry = appId ? DesktopEntries.heuristicLookup(appId) : null
    var name = entry && entry.icon ? entry.icon : appId
    return (name ? Quickshell.iconPath(name, true) : "") || Quickshell.iconPath("application-x-executable", true)
  }

  function rebuild() {
    var mon = mc.monitor
    if (!mon || !mc.mapped || !mc.screen) return
    mc.readGeometry()

    var active = mon.activeWorkspace ? mon.activeWorkspace.id : -1
    var list = Hyprland.toplevels.values
    var tops = ({}), byWs = ({}), recs = ({}), parts = []
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      var o = t.lastIpcObject
      if (!o || !o.workspace || !o.at || !o.size || !o.address) continue
      var wsId = o.workspace.id
      if (!(wsId > 0) || o.monitor !== mon.id) continue
      if (o.hidden === true || o.pinned === true || o.mapped === false) continue
      if (!(o.size[0] > 1 && o.size[1] > 1)) continue
      var rec = {
        addr: String(o.address),
        ws: wsId,
        rx: o.at[0] - mon.x - mc.offX,
        ry: o.at[1] - mon.y - mc.offY,
        rw: o.size[0],
        rh: o.size[1],
        appId: String(o["class"] || ""),
        stack: -(o.focusHistoryID | 0),
        focused: o.focusHistoryID === 0
      }
      tops[rec.addr] = t
      recs[rec.addr] = rec
      if (!byWs[wsId]) byWs[wsId] = []
      byWs[wsId].push(rec)
      parts.push([rec.addr, wsId, rec.rx, rec.ry, rec.rw, rec.rh, rec.stack, rec.focused].join(","))
    }

    var ids = []
    for (var key in byWs) ids.push(parseInt(key, 10))
    if (active > 0 && ids.indexOf(active) === -1) ids.push(active)
    for (var e = 0; e < mc.extraSpaces.length; e++)
      if (ids.indexOf(mc.extraSpaces[e]) === -1) ids.push(mc.extraSpaces[e])
    ids.sort(function(a, b) { return a - b })

    var signature = parts.sort().join("|") + "@" + active + "#" + ids.join(",") + "~" + mc.viewW + "x" + mc.viewH
    mc.tops = tops
    if (signature === mc.signature) return
    mc.signature = signature

    // Windows: keep the delegates of windows that stay, so their pictures stay.
    for (var w = winModel.count - 1; w >= 0; w--) {
      var row = winModel.get(w)
      var next = recs[row.addr]
      if (!next) { winModel.remove(w); continue }
      for (var role in next) if (row[role] !== next[role]) winModel.setProperty(w, role, next[role])
      delete recs[row.addr]
    }
    for (var addr in recs) winModel.append(recs[addr])

    // Workspaces, in order.
    var before = mc.spaceIds
    for (var s = spaceModel.count - 1; s >= 0; s--)
      if (ids.indexOf(spaceModel.get(s).wsId) === -1) spaceModel.remove(s)
    for (var n = 0; n < ids.length; n++)
      if (n >= spaceModel.count || spaceModel.get(n).wsId !== ids[n]) spaceModel.insert(n, { wsId: ids[n] })

    var screenBox = { w: mc.viewW, h: mc.viewH }
    var targets = ({})
    for (var d = 0; d < ids.length; d++) {
      var placed = Layout.natural(byWs[ids[d]] || [], screenBox, mc.stageRect, 14)
      for (var pa in placed) targets[pa] = placed[pa]
    }

    // Keep looking at the same workspace when the list around it changes.
    var index = ids.indexOf(active)
    var was = before.indexOf(active)
    var swiping = mc.gesturing && mc.g && mc.g.axis === "h"
    if (index >= 0 && was >= 0 && index !== was && mc.activeWs === active && !swiping) {
      mc.page += index - was
      mc.pageTarget = index
    }

    mc.wsWins = byWs
    mc.targets = targets
    mc.spaceIds = ids
    mc.activeWs = active
    if (mc.selAddr !== "" && !tops[mc.selAddr]) mc.selAddr = ""
    if (mc.hoverAddr !== "" && !tops[mc.hoverAddr]) mc.hoverAddr = ""
  }

  Timer { id: rebuildSoon; interval: 1; onTriggered: { mc.rebuild(); mc.followActive() } }
  Timer { id: rebuildLate; interval: 140; onTriggered: { mc.rebuild(); mc.followActive() } }
  Timer {
    id: refreshSoon
    interval: 15
    onTriggered: {
      Hyprland.refreshToplevels()
      Hyprland.refreshWorkspaces()
      rebuildSoon.restart()
      rebuildLate.restart()
    }
  }

  Connections {
    target: Hyprland
    enabled: mc.mapped
    function onRawEvent(event) {
      var n = event.name
      if (n === "openwindow" || n === "closewindow" || n === "movewindow" || n === "movewindowv2"
          || n === "changefloatingmode" || n === "fullscreen" || n === "workspace" || n === "workspacev2"
          || n === "createworkspace" || n === "destroyworkspace" || n === "focusedmon") refreshSoon.restart()
    }
  }
  Connections {
    target: Hyprland.toplevels
    enabled: mc.mapped
    function onValuesChanged() { rebuildSoon.restart() }
  }
  Connections {
    target: mc.monitor
    function onActiveWorkspaceChanged() { if (mc.mapped) rebuildSoon.restart() }
    function onLastIpcObjectChanged() { if (mc.mapped) rebuildSoon.restart(); else mc.readGeometry() }
  }
  // Window boxes arrive a moment after a refresh is asked for.
  Instantiator {
    model: Hyprland.toplevels
    delegate: Connections {
      required property var modelData
      target: modelData
      function onLastIpcObjectChanged() {
        if (!mc.mapped) return
        // Before the first picture, take the new boxes at once.
        if (!mc.revealed) mc.rebuild()
        else rebuildSoon.restart()
      }
    }
  }

  // ---------------------------------------------------------------- actions

  function hypr(expression) {
    Quickshell.execDetached(["hyprctl", "dispatch", expression])
  }
  function validAddr(addr) { return /^0x[0-9a-f]+$/i.test(String(addr || "")) }

  function focusWorkspace(id) {
    if (!(id > 0)) return
    var name = mc.monitor ? String(mc.monitor.name || "") : ""
    if (mc.blockOf(id) === mc.ownBlock && /^[A-Za-z0-9._:-]+$/.test(name))
      mc.hypr("o.workspaces.focus(" + mc.slotOf(id) + ", \"" + name + "\")")
    else
      mc.hypr("hl.dsp.focus({ workspace = \"" + Math.round(id) + "\" })")
  }

  function activateWindow(addr) {
    if (!mc.validAddr(addr)) return
    mc.raisedAddr = addr
    mc.hypr("hl.dsp.focus({ window = \"address:" + addr + "\" })")
    mc.close()
  }

  function closeWindow(addr) {
    if (!mc.validAddr(addr)) return
    mc.hypr("hl.dsp.window.close({ window = \"address:" + addr + "\" })")
    refreshSoon.restart()
  }

  function moveWindow(addr, id) {
    if (!mc.validAddr(addr) || !(id > 0)) return
    mc.hypr("hl.dsp.window.move({ workspace = \"" + Math.round(id) + "\", follow = false, window = \"address:" + addr + "\" })")
    refreshSoon.restart()
  }

  function goToSpace(id) {
    if (id !== mc.activeWs) {
      mc.focusWorkspace(id)
      mc.holdCloseUntil = Date.now() + 420
    }
    mc.close()
  }

  function newSpaceId() {
    var used = ({}), top = 0
    for (var i = 0; i < mc.spaceIds.length; i++) {
      if (mc.blockOf(mc.spaceIds[i]) !== mc.ownBlock) continue
      used[mc.slotOf(mc.spaceIds[i])] = true
      top = Math.max(top, mc.slotOf(mc.spaceIds[i]))
    }
    for (var s = top + 1; s <= mc.slots; s++) if (!used[s]) return mc.ownBlock * mc.slots + s
    for (var f = 1; f <= mc.slots; f++) if (!used[f]) return mc.ownBlock * mc.slots + f
    return 0
  }

  function addSpace() {
    var id = mc.newSpaceId()
    if (!(id > 0)) return 0
    mc.extraSpaces = mc.extraSpaces.concat([id])
    mc.rebuild()
    return id
  }

  // Like removing a Desktop on the Mac: its windows join the one beside it.
  function closeSpace(id) {
    var index = mc.spaceIds.indexOf(id)
    if (index < 0 || mc.spaceIds.length < 2) return
    var beside = index > 0 ? mc.spaceIds[index - 1] : mc.spaceIds[index + 1]
    var wins = mc.wsWins[id] || []
    for (var i = 0; i < wins.length; i++) mc.moveWindow(wins[i].addr, beside)
    mc.extraSpaces = mc.extraSpaces.filter(function(x) { return x !== id })
    if (id === mc.activeWs) mc.focusWorkspace(beside)
    mc.signature = ""
    refreshSoon.restart()
  }

  function dragScaleAt(y, width) {
    var t = Math.max(0, Math.min(1, (mc.stripH + 110 - y) / 130))
    var small = Math.min(1, mc.thumbW * 1.15 / Math.max(1, width))
    return 1 + (small - 1) * t
  }

  function dragMoved(x, y) {
    mc.dropTarget = panel.spaceAt(x, y)
  }

  function dropWindow(addr, fromWs, x, y) {
    var target = panel.spaceAt(x, y)
    mc.dropTarget = 0
    if (target === 0 || target === fromWs) return false
    if (target < 0) target = mc.addSpace()
    if (!(target > 0)) return false
    mc.moveWindow(addr, target)
    return true
  }

  function moveSelection(dx, dy) {
    var wins = mc.wsWins[mc.activeWs] || []
    if (wins.length === 0) return
    var cur = mc.targets[mc.selAddr] || mc.targets[mc.hoverAddr]
    if (!cur || !mc.tops[mc.selAddr !== "" ? mc.selAddr : mc.hoverAddr]) {
      mc.selAddr = wins[0].addr
      return
    }
    var cx = cur.x + cur.w / 2, cy = cur.y + cur.h / 2
    var best = "", bestScore = 1e12
    for (var i = 0; i < wins.length; i++) {
      var r = mc.targets[wins[i].addr]
      if (!r || wins[i].addr === mc.selAddr) continue
      var ox = r.x + r.w / 2 - cx, oy = r.y + r.h / 2 - cy
      var along = ox * dx + oy * dy
      if (along <= 4) continue
      var across = Math.abs(ox * dy) + Math.abs(oy * dx)
      var score = along + across * 2.5
      if (score < bestScore) { bestScore = score; best = wins[i].addr }
    }
    if (best !== "") mc.selAddr = best
  }

  function stepSpace(delta) {
    var index = mc.spaceIds.indexOf(mc.activeWs) + delta
    if (index >= 0 && index < mc.spaceIds.length) mc.focusWorkspace(mc.spaceIds[index])
  }

  // -------------------------------------------------------------- remote control

  IpcHandler {
    target: "mc"
    function toggle(): void { mc.toggle() }
    function open(): void { mc.open() }
    function close(): void { mc.close() }
    // Show the overview without taking the keyboard or the pointer, then close.
    function peek(ms: int): void {
      if (mc.mapped) return
      mc.open()
      mc.peeking = true
      peekTimer.interval = Math.max(100, ms)
      peekTimer.restart()
    }
    // Testing: freeze the overview at one point of its animation, taking no input.
    function hold(permille: int, ms: int): void {
      if (mc.mapped || !mc.prepare()) return
      mc.peeking = true
      mc.holdAt = Math.max(0, Math.min(1000, permille)) / 1000
      peekTimer.interval = Math.max(100, ms)
      peekTimer.restart()
    }
    // Testing: feed one line as if it came from the trackpad reader.
    function gesture(line: string): void { mc.onGesture(line) }
    // Testing: the actions behind the buttons and the drag.
    function act(name: string, a: string, b: string): string {
      if (name === "addSpace") return String(mc.addSpace())
      if (name === "closeSpace") { mc.closeSpace(parseInt(a)); return "ok" }
      if (name === "moveWindow") { mc.moveWindow(a, parseInt(b)); return "ok" }
      if (name === "closeWindow") { mc.closeWindow(a); return "ok" }
      if (name === "select") { mc.selAddr = a; return "ok" }
      if (name === "spaceAt") return String(panel.spaceAt(parseFloat(a), parseFloat(b)))
      return "unknown"
    }
    function status(): string {
      return JSON.stringify({
        gpu: mc.gpu, mapped: mc.mapped, revealed: mc.revealed, progress: mc.progress, page: mc.page,
        activeWs: mc.activeWs, spaces: mc.spaceIds, windows: winModel.count, readyWaitMs: mc.readyWait,
        captured: Object.keys(mc.ready).length, gestures: gestureProc.running, gesturing: mc.gesturing, target: mc.progressTarget, pageTarget: mc.pageTarget, interactive: mc.interactive, warm: mc.warm, lastAnimation: mc.lastStat
      })
    }
  }

  GlobalShortcut {
    appid: "mission-control"
    name: "toggle"
    description: "Toggle Mission Control"
    onPressed: mc.toggle()
  }

  // ------------------------------------------------------------------- view

  // The bar keeps its own strip of the screen, above the overlay. This sits
  // under it (and above the wallpaper), so the bar darkens together with the
  // workspace strip instead of staying a bright band across the top.
  PanelWindow {
    visible: !!mc.screen && mc.offY > 0
    screen: mc.screen
    anchors { top: true; left: true; right: true }
    implicitHeight: Math.max(1, mc.offY)
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.namespace: "mission-control-bar"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}

    // The strip is its band colour over the dimmed wallpaper; this is the
    // same two layers as one, over the plain wallpaper.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(mc.bg.r * 0.5, mc.bg.g * 0.5, mc.bg.b * 0.5, 0.9)
      visible: mc.mapped && mc.revealed
      opacity: Math.min(1, mc.shown * 1.8) * (mc.priming ? 0.004 : 1)
    }
  }

  PanelWindow {
    id: panel
    visible: !!mc.screen
    screen: mc.screen
    anchors { top: true; left: true; right: true; bottom: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Normal
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "mission-control"
    WlrLayershell.keyboardFocus: mc.interactive ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    mask: mc.interactive ? null : nothing

    Region { id: nothing }
    readonly property var core: mc

    // Which workspace of the strip is under a point: its id, -1 for "+", 0 for none.
    function spaceAt(x, y) {
      for (var i = 0; i < thumbs.count + 1; i++) {
        var item = i < thumbs.count ? thumbs.itemAt(i) : plus
        if (!item || !item.visible) continue
        var pt = item.mapFromItem(content, x, y)
        if (pt.x >= -10 && pt.x <= item.width + 10 && pt.y >= -18 && pt.y <= item.height + 14) return item.wsId
      }
      return 0
    }

    Item {
      id: content
      anchors.fill: parent
      visible: mc.mapped && mc.revealed
      opacity: mc.priming ? 0.004 : 1
      focus: true

      Keys.onPressed: function(event) {
        if (!mc.interactive) return
        var plain = !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
        var target = mc.selAddr !== "" ? mc.selAddr : mc.hoverAddr
        if (event.key === Qt.Key_Escape) mc.close()
        else if (event.key === Qt.Key_Left && plain) mc.moveSelection(-1, 0)
        else if (event.key === Qt.Key_Right && plain) mc.moveSelection(1, 0)
        else if (event.key === Qt.Key_Up && plain) mc.moveSelection(0, -1)
        else if (event.key === Qt.Key_Down && plain) mc.moveSelection(0, 1)
        else if (event.key === Qt.Key_Tab) mc.stepSpace(1)
        else if (event.key === Qt.Key_Backtab) mc.stepSpace(-1)
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          if (target !== "") mc.activateWindow(target)
          else mc.close()
        } else if ((event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) && target !== "") mc.closeWindow(target)
        else if (plain && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) mc.goToSpace(mc.ownBlock * mc.slots + (event.key - Qt.Key_0))
        else if (plain && event.key === Qt.Key_0) mc.goToSpace(mc.ownBlock * mc.slots + 10)
        else return
        event.accepted = true
      }

      // The desktop's own wallpaper, exactly where the desktop draws it.
      Rectangle { anchors.fill: parent; color: mc.bg }
      Image {
        x: -mc.offX
        y: -mc.offY
        width: mc.screenW
        height: mc.screenH
        source: mc.wallpaperUrl
        sourceSize: Qt.size(Math.ceil(mc.screenW * panel.devicePixelRatio), Math.ceil(mc.screenH * panel.devicePixelRatio))
        fillMode: Image.PreserveAspectCrop
        asynchronous: false
        cache: true
      }
      Rectangle { anchors.fill: parent; color: "black"; opacity: 0.46 * mc.shown }

      // A click on the empty desktop leaves.
      MouseArea {
        anchors.fill: parent
        enabled: mc.interactive
        onClicked: mc.close()
      }

      Item {
        id: stage
        anchors.fill: parent
        z: mc.dragTile ? 3 : 1
        Repeater {
          model: winModel
          delegate: WindowTile { mc: panel.core }
        }
      }

      Text {
        visible: mc.settled && (mc.wsWins[mc.activeWs] || []).length === 0
        x: (parent.width - width) / 2
        y: mc.stageRect.y + mc.stageRect.h / 2 - height / 2
        textFormat: Text.PlainText
        text: "No windows on this workspace"
        color: mc.fg
        opacity: 0.55
        font.family: mc.fontFamily
        font.pixelSize: 16
      }

      // Workspaces, sliding in from under the bar.
      Item {
        id: strip
        z: 2
        width: parent.width
        height: mc.stripH
        y: -mc.stripH * (1 - mc.shown)
        opacity: Math.min(1, mc.shown * 1.8)

        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(mc.bg.r * 0.55, mc.bg.g * 0.55, mc.bg.b * 0.55, 0.82)
        }
        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: 1
          color: Qt.rgba(mc.fg.r, mc.fg.g, mc.fg.b, 0.1)
        }
        MouseArea { anchors.fill: parent; enabled: mc.interactive }

        Row {
          id: stripRow
          anchors.horizontalCenter: parent.horizontalCenter
          y: 18
          spacing: 22
          Repeater {
            id: thumbs
            model: spaceModel
            delegate: SpaceThumb { mc: panel.core }
          }
          SpaceThumb {
            id: plus
            mc: panel.core
            wsId: -1
            visible: mc.newSpaceId() > 0
          }
        }
      }
    }
  }
}
