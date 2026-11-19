# Right-click menu with Quit on every rolo.* bar plugin (2026-11-19)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/53     Kernel: 7.3.0-gc1e08542a544

## What broke
Rolando wanted to quit his bar plugins from the bar itself. Right-click on KM Link toggled control, on My Agents it launched an agent, on cds it opened the Dashboard, and on Pointer it did nothing. Quitting KM Link meant stopping `kmlink-controller.service` and running `omarchy plugin disable` by hand.

## Cause
Missing feature: none of the widgets had a context menu, and Omarchy has no generic "quit plugin" action for bar widgets.

## Fix
1. New `QuitMenu.qml` (same file in rolo.kmlink, rolo.agents, rolo.cds and rolo.pointer): a small `KeyboardPanel` menu anchored on the bar icon. It lists the widget's quick actions, then a red **Quit <name>**, and works with the keyboard (arrows, Enter, Esc). Quit runs `systemctl --user disable --now <unit>` for each of the plugin's services, then `omarchy plugin disable <id>`. Omarchy menu → Plugins brings the plugin back.
2. Right-click on each widget now opens that menu, and left-click closes it before toggling the main panel. The old right-click action is the menu's first item:
   - **KM Link:** Take control of the Mac / Give control back (disabled when not connected), KM Link settings. Quit also disables `kmlink-controller.service`. The widget runs `systemctl --user enable --now kmlink-controller.service` when it loads, so re-enabling the plugin brings the service back.
   - **My Agents:** Launch an agent, Refresh now (middle-click still refreshes).
   - **cds:** Open Dashboard, Colony or Vault.
   - **Pointer:** Switch to the macOS or Custom profile.
3. rolo.tray already used right-click for its manage popup, so a **Quit My System tray** button went at the bottom of that popup instead.

User-level QML only: no package, no service file, no system change.

## Files changed
- `~/.config/omarchy/plugins/rolo.{kmlink,agents,cds,pointer}/QuitMenu.qml` (new): copy in [files/2026-11-19-plugin-quit-menu/QuitMenu.qml](files/2026-11-19-plugin-quit-menu/QuitMenu.qml)
- `~/.config/omarchy/plugins/rolo.{kmlink,agents,cds,pointer}/Panel.qml` and `rolo.tray/Tray.qml` (backups `*.pre-quit`):

```diff
### rolo.agents.diff
--- rolo.agents/Panel.qml.pre-quit	2026-11-19 06:30:41.155475877 -0600
+++ rolo.agents/Panel.qml	2026-11-19 06:47:32.616594545 -0600
@@ -54,36 +54,41 @@
   }
   readonly property int cdsWorking: liveSessions.length - cdsWaiting
 
-  function parseCdsList(raw) {
-    var lines = String(raw || "").split("\n")
+  // live_sessions.py merges local Claude Code windows, Herdr terminals (any
+  // machine) and whatever else cds lists; only the first two can be answered here.
+  function parseSessions(raw) {
+    var data
+    try { data = JSON.parse(String(raw || "")) } catch (e) { return }
+    var list = Array.isArray(data.sessions) ? data.sessions : []
     var out = []
-    for (var i = 0; i < Math.min(lines.length, 400); i++) {
-      var line = lines[i]
-      if (!line || line.indexOf("# ") === 0) continue
-      // %-9s %-8s %-8s %-6s %-5s %s  [%s]
-      var m = line.match(/^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.*?)\s+\[([^\]]*)\]\s*$/)
-      if (!m) continue
-      var state = m[4].toLowerCase()
-      var waiting = state === "wait" || state === "waiting"
-      var working = state === "busy" || state === "work" || state === "working" || state === "run"
-      if (!waiting && !working) continue
+    for (var i = 0; i < list.length && out.length < 50; i++) {
+      var s = list[i]
+      if (!s || (s.state !== "working" && s.state !== "waiting")) continue
       out.push({
-        machine: safeText(m[1], 24),
-        source: safeText(m[2], 24),
-        provider: safeText(m[3], 24),
-        state: state,
-        waiting: waiting,
-        age: safeText(m[5], 12),
-        title: safeText(m[6], 80),
-        where: safeText(m[7], 40)
+        kind: safeText(s.kind, 8), id: String(s.id || "").slice(0, 400),
+        machine: safeText(s.machine, 24), provider: safeText(s.provider, 24),
+        title: safeText(s.title, 80), where: safeText(s.where, 40),
+        state: s.state, waiting: s.state === "waiting", waitingFor: safeText(s.waitingFor, 80),
+        age: safeText(s.age, 12), workspace: safeText(s.workspace, 12),
+        interactive: s.interactive === true,
+        name: safeText(s.name, 40)
       })
-      if (out.length >= 50) break
     }
-    // Waiting for you first, then the rest in cds's order (most recent first).
-    out.sort(function(a, b) { return (b.waiting ? 1 : 0) - (a.waiting ? 1 : 0) })
     liveSessions = out
   }
 
+  function openSession(s) {
+    // Claude Desktop sessions are answered in Claude Desktop: go to its window.
+    if (s.kind === "other" && s.name === "Desktop") { focusSession(s); return }
+    root.close()
+    sessionWindow.openSession(s)
+  }
+
+  function focusSession(s) {
+    Quickshell.execDetached(["python3", root.scriptDir + "/live_sessions.py", "focus", s.kind, s.id])
+    root.close()
+  }
+
   function refreshSessions() {
     if (cdsListProc.running) return
     cdsListProc.collected = ""
@@ -97,7 +102,7 @@
 
   Process {
     id: cdsListProc
-    command: ["cds", "--list"]
+    command: ["python3", root.scriptDir + "/live_sessions.py", "list"]
     property string collected: ""
     stdout: SplitParser {
       splitMarker: ""
@@ -105,7 +110,7 @@
     }
     onExited: exitCode => {
       root.cdsAvailable = exitCode === 0
-      if (exitCode === 0) root.parseCdsList(cdsListProc.collected)
+      if (exitCode === 0) root.parseSessions(cdsListProc.collected)
     }
   }
 
@@ -1101,6 +1106,21 @@
     function hide(): void { root.close() }
     function toggle(): void { root.toggle() }
     function refresh(): string { root.refreshNow(); return "ok" }
+    // Opens the session that has waited longest for you (or the first live one) in the pop-out.
+    function openWaiting(): string {
+      var list = root.liveSessions
+      var pick = list.filter(function(s) { return s.waiting })[0] || list.filter(function(s) { return s.interactive })[0]
+      if (!pick) return "none"
+      root.openSession(pick)
+      return pick.title
+    }
+  }
+
+  SessionWindow {
+    id: sessionWindow
+    scriptPath: root.scriptDir + "/live_sessions.py"
+    fontFamily: root.fontFamily
+    foreground: root.foreground
   }
 
   BarIconButton {
@@ -1112,12 +1132,24 @@
     active: root.alarming || root.liveSessions.length > 0
     labelText: root.cdsWaiting > 0 ? String(root.cdsWaiting) : ""
     onPressed: function(buttonCode) {
-      if (buttonCode === Qt.RightButton) root.launchAgent()
+      if (buttonCode === Qt.RightButton) { root.close(); quitMenu.toggle() }
       else if (buttonCode === Qt.MiddleButton) root.refreshNow()
-      else root.toggle()
+      else { quitMenu.close(); root.toggle() }
     }
   }
 
+  QuitMenu {
+    id: quitMenu
+    anchorItem: button
+    bar: root.bar
+    pluginId: "rolo.agents"
+    pluginName: "My Agents"
+    actions: [
+      { label: "Launch an agent", icon: "󱚣", run: function() { root.launchAgent() } },
+      { label: "Refresh now", icon: "󰑓", run: function() { root.refreshNow() } }
+    ]
+  }
+
   KeyboardPanel {
     id: panel
     anchorItem: button
@@ -1283,6 +1315,8 @@
                 width: liveSection.width
                 implicitHeight: sessionText.implicitHeight + Style.space(8)
 
+                HoverHandler { id: rowHover }
+
                 Rectangle {
                   anchors.fill: parent
                   anchors.leftMargin: -Style.space(6)
@@ -1314,7 +1348,7 @@
                   id: sessionText
                   anchors.left: stateDot.right
                   anchors.leftMargin: Style.space(10)
-                  anchors.right: sessionAge.left
+                  anchors.right: sessionGo.visible ? sessionGo.left : sessionAge.left
                   anchors.rightMargin: Style.space(8)
                   anchors.verticalCenter: parent.verticalCenter
                   spacing: Style.space(1)
@@ -1333,7 +1367,9 @@
                     width: parent.width
                     textFormat: Text.PlainText
                     text: [sessionRow.modelData.provider,
-                           sessionRow.modelData.machine === "here" ? pluginStrings.t("live.here") : sessionRow.modelData.machine,
+                           sessionRow.modelData.machine === "here"
+                             ? (sessionRow.modelData.workspace ? pluginStrings.t("live.workspace").arg(sessionRow.modelData.workspace) : pluginStrings.t("live.here"))
+                             : sessionRow.modelData.machine,
                            sessionRow.modelData.where].filter(function(s) { return s !== "" }).join(" · ")
                     color: root.dim
                     font.family: root.fontFamily
@@ -1342,6 +1378,20 @@
                   }
                 }
 
+                PanelActionButton {
+                  id: sessionGo
+                  anchors.right: sessionAge.left
+                  anchors.rightMargin: Style.space(6)
+                  anchors.verticalCenter: parent.verticalCenter
+                  visible: sessionRow.modelData.interactive && rowHover.hovered
+                  iconText: "󰆍"
+                  foreground: root.dim
+                  fontFamily: root.fontFamily
+                  tooltipText: pluginStrings.t("live.goToTerminal")
+                  onClicked: root.focusSession(sessionRow.modelData)
+                  z: 2
+                }
+
                 Text {
                   id: sessionAge
                   anchors.right: parent.right
@@ -1359,7 +1409,7 @@
                   anchors.fill: parent
                   hoverEnabled: true
                   cursorShape: Qt.PointingHandCursor
-                  onClicked: root.openCds()
+                  onClicked: root.openSession(sessionRow.modelData)
                 }
               }
             }
### rolo.cds.diff
--- rolo.cds/Panel.qml.pre-quit	2026-11-17 06:58:12.242747565 -0600
+++ rolo.cds/Panel.qml	2026-11-19 06:35:19.569203598 -0600
@@ -211,11 +211,24 @@
       ? strings.t("tooltip.none")
       : strings.t("tooltip.summary").arg(root.summaryText)
     onPressed: function(b) {
-      if (b === Qt.RightButton) root.launchDashboard()
-      else root.toggle()
+      if (b === Qt.RightButton) { root.close(); quitMenu.toggle() }
+      else { quitMenu.close(); root.toggle() }
     }
   }
 
+  QuitMenu {
+    id: quitMenu
+    anchorItem: button
+    bar: root.bar
+    pluginId: "rolo.cds"
+    pluginName: "cds"
+    actions: [
+      { label: "Open Dashboard", icon: "󰆍", run: function() { root.launchDashboard() } },
+      { label: "Open Colony", icon: "󰡨", run: function() { root.launchColony() } },
+      { label: "Open Vault", icon: "󰌾", run: function() { root.launchVault() } }
+    ]
+  }
+
   // ------------------------------------------------------------ panel
   KeyboardPanel {
     id: panel
### rolo.kmlink.diff
--- rolo.kmlink/Panel.qml.pre-quit	2026-11-10 04:07:47.939908670 -0600
+++ rolo.kmlink/Panel.qml	2026-11-19 06:35:19.405205221 -0600
@@ -84,11 +84,29 @@
     dimmed: !root.reachable
     tooltipText: root.peerName + ": " + root.statusLine + (root.status.detail ? "\n" + root.status.detail : "")
     onPressed: function(b) {
-      if (b === Qt.RightButton) root.toggleControl()
-      else root.toggle()
+      if (b === Qt.RightButton) { root.close(); quitMenu.toggle() }
+      else { quitMenu.close(); root.toggle() }
     }
   }
 
+  // Plugin enabled means the controller runs: Quit disables both, and turning the plugin back
+  // on (Omarchy menu → Plugins) brings the service back with it.
+  Component.onCompleted: Quickshell.execDetached(["systemctl", "--user", "enable", "--now", "kmlink-controller.service"])
+
+  QuitMenu {
+    id: quitMenu
+    anchorItem: button
+    bar: root.bar
+    pluginId: "rolo.kmlink"
+    pluginName: "KM Link"
+    services: ["kmlink-controller.service"]
+    actions: [
+      { label: root.linkState === "remote" ? "Give control back" : "Take control of the Mac", icon: "󰌢",
+        enabled: root.controlling, run: function() { root.toggleControl() } },
+      { label: "KM Link settings", icon: "󰒓", run: function() { root.run("omarchy-launch-or-focus kmlink") } }
+    ]
+  }
+
   // ------------------------------------------------------------ panel
   KeyboardPanel {
     id: panel
### rolo.pointer.diff
--- rolo.pointer/Panel.qml.pre-quit	2026-11-19 06:29:22.975664598 -0600
+++ rolo.pointer/Panel.qml	2026-11-19 06:35:19.641202885 -0600
@@ -435,10 +435,23 @@
       + "\nTrackpad scroll " + Number(root.cfg.trackpad_scroll_factor).toFixed(2) + "× · Mouse scroll " + Number(root.cfg.mouse_scroll_factor).toFixed(1) + "×"
       + (root.g502Ready ? "\n" + (root.g502.name || "G502 X") + " · " + root.g502BatteryText + (root.g502.charging ? " charging" : "") + (root.g502.dpi ? " · " + root.g502.dpi + " DPI" : "") : "")
     onPressed: function(b) {
-      if (b === Qt.LeftButton) root.toggle()
+      if (b === Qt.RightButton) { root.close(); quitMenu.toggle() }
+      else { quitMenu.close(); root.toggle() }
     }
   }
 
+  QuitMenu {
+    id: quitMenu
+    anchorItem: button
+    bar: root.bar
+    pluginId: "rolo.pointer"
+    pluginName: "Pointer"
+    actions: [
+      { label: root.macos ? "Switch to Custom profile" : "Switch to macOS profile", icon: "󰒓",
+        run: function() { root.setProfile(root.macos ? "custom" : "macos") } }
+    ]
+  }
+
   // --------------------------------------------------------------------- panel
   KeyboardPanel {
     id: panel
### rolo.tray.diff
--- rolo.tray/Tray.qml.pre-quit	2026-11-17 04:35:03.111136370 -0600
+++ rolo.tray/Tray.qml	2026-11-19 06:35:36.337036975 -0600
@@ -564,6 +564,21 @@
           }
         }
       }
+
+      PanelSeparator { width: parent.width; foreground: root.foreground }
+
+      // Quit: disable this plugin so it leaves the bar (Omarchy menu → Plugins brings it back).
+      Button {
+        text: "Quit My System tray"
+        iconText: "󰈆"
+        foreground: root.foreground
+        fontFamily: root.fontFamily
+        fontSize: Style.font.bodySmall
+        onClicked: {
+          root.managePopupOpen = false
+          Quickshell.execDetached(["omarchy", "plugin", "disable", "rolo.tray"])
+        }
+      }
     }
   }
```

## Verified
- omarchy-shell hot-reloaded all five plugins, and the live shell's log has no QML warnings for any of them.
- Not yet clicked through: the menus' look and the Quit path (service stop + plugin disable) haven't been exercised, and Rolando hasn't confirmed them.

## Rollback
```bash
cd ~/.config/omarchy/plugins
for p in rolo.kmlink/Panel.qml rolo.agents/Panel.qml rolo.cds/Panel.qml rolo.pointer/Panel.qml rolo.tray/Tray.qml; do cp -a $p.pre-quit $p; done
rm rolo.{kmlink,agents,cds,pointer}/QuitMenu.qml
omarchy plugin enable rolo.kmlink && systemctl --user enable --now kmlink-controller.service   # if KM Link was quit
```
