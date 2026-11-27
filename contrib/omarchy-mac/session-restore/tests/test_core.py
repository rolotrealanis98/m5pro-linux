"""Offline tests for the session-restore core (no compositor, no GTK). Run: python3 -m unittest discover -s tests -v"""
import json
import os
import sys
import tempfile
import time
import unittest

TMP = tempfile.mkdtemp(prefix="m5pro-session-test-")
os.environ.update({
    "M5PRO_SESSION_STATE": os.path.join(TMP, "state"),
    "M5PRO_SESSION_CONFIG": os.path.join(TMP, "cfg", "config.json"),
    "M5PRO_SESSION_HYPR_AUTOSTART": os.path.join(TMP, "autostart.lua"),
    "M5PRO_SESSION_AUTOSTART_USER": os.path.join(TMP, "user-autostart"),
    "M5PRO_SESSION_AUTOSTART_SYSTEM": os.path.join(TMP, "sys-autostart"),
    "XDG_CURRENT_DESKTOP": "Hyprland",
})
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "home/.local/lib/m5pro-session"))
import m5pro_session as m  # noqa: E402


def win(cls, ws=1, kind="app", **kw):
    w = {"address": "0x%x" % (abs(hash((cls, ws, str(kw)))) % 10**8), "class": cls, "initialClass": cls, "title": cls,
         "workspace": {"id": ws, "name": str(ws)}, "floating": False, "at": [0, 0], "size": [100, 100], "fullscreen": 0,
         "pid": 100 + ws, "kind": kind}
    w.update(kw)
    return w


def snap(*ws):
    return {"windows": list(ws), "taken_at": time.time()}


class Helpers(unittest.TestCase):
    def test_exec_argv_drops_field_codes(self):
        self.assertEqual(m.exec_argv('env FOO=1 "/opt/My App/app" --url=%u %U --pct=100%%'),
                         ["env", "FOO=1", "/opt/My App/app", "--pct=100%"])

    def test_lua_quote(self):
        self.assertEqual(m.lua_q('a"b\\c\n'), '"a\\"b\\\\c\\n"')

    def test_ws_ref(self):
        self.assertEqual(m.ws_ref({"id": 5, "name": "5"}), "5")
        self.assertEqual(m.ws_ref({"id": -1337, "name": "web"}), "name:web")
        self.assertEqual(m.ws_ref({"id": -99, "name": "special:scratchpad"}), "special:scratchpad")


class Agents(unittest.TestCase):
    def test_agent_kind(self):
        self.assertEqual(m.agent_kind(["/home/x/.local/share/mise/installs/claude/latest/claude"]), "claude")
        self.assertEqual(m.agent_kind(["codex", "resume", "abc"]), "codex")
        self.assertIsNone(m.agent_kind(["codex", "app-server", "--listen", "unix://"]))
        self.assertEqual(m.agent_kind(["node", "/x/bin/opencode", "-s", "ses"]), "opencode")
        self.assertEqual(m.agent_kind(["agy", "--conversation", "u"]), "agy")
        self.assertIsNone(m.agent_kind(["bash", "-lc", "claude"]) and None)

    def test_flags_carried(self):
        self.assertEqual(m.carried_flags("claude", ["claude", "--permission-mode", "auto", "--chrome", "prompt text"]),
                         ["--permission-mode", "auto", "--chrome"])
        self.assertEqual(m.carried_flags("codex", ["codex", "--model=gpt", "--full-auto"]), ["--model", "gpt", "--full-auto"])

    def test_resume_commands(self):
        sid = "11111111-2222-4333-8444-555555555555"
        self.assertEqual(m.resume_argv({"kind": "claude", "session_id": sid, "flags": ["--chrome"]}), ["claude", "--chrome", "--resume", sid])
        self.assertEqual(m.resume_argv({"kind": "codex", "session_id": sid}), ["codex", "resume", sid])
        self.assertEqual(m.resume_argv({"kind": "opencode", "session_id": sid}), ["opencode", "--session", sid])
        self.assertEqual(m.resume_argv({"kind": "agy", "session_id": sid}), ["agy", "--conversation", sid])
        self.assertEqual(m.resume_argv({"kind": "gemini", "session_id": "latest"}), ["gemini", "--resume", "latest"])
        self.assertEqual(m.resume_argv({"kind": "claude", "session_id": None}), ["claude", "--continue"])
        self.assertEqual(m.resume_argv({"kind": "claude", "session_id": None, "fresh": True}), ["claude"])

    def test_terminal_argv(self):
        self.assertEqual(m.terminal_argv("alacritty", "/tmp", "claude --resume x"),
                         ["alacritty", "--working-directory", "/tmp", "-e", "bash", "-lc", "claude --resume x; exec bash"])
        self.assertEqual(m.terminal_argv("alacritty", "/tmp"), ["alacritty", "--working-directory", "/tmp"])
        self.assertEqual(m.terminal_argv("alacritty", "/nonexistent-dir", cls="org.omarchy.agent")[:3], ["alacritty", "--class", "org.omarchy.agent"])

    def test_claude_session_file(self):
        d = tempfile.mkdtemp(dir=TMP)
        os.makedirs(os.path.join(d, "sessions"))
        with open(os.path.join(d, "sessions", "4242.json"), "w") as f:
            json.dump({"pid": 4242, "sessionId": "sid-1", "cwd": "/work"}, f)
        m.AGENT_DB["claude_dir"] = d
        self.assertEqual(m.claude_session(4242, ["claude"]), ("sid-1", "/work", True))
        self.assertEqual(m.claude_session(1, ["claude", "--resume", "11111111-2222-4333-8444-555555555555"])[0],
                         "11111111-2222-4333-8444-555555555555")


class Guard(unittest.TestCase):
    def test_empty_never_saved(self):
        self.assertFalse(m.accept_snapshot(snap(), snap(win("a")))[0])

    def test_restoring_and_pending_block(self):
        s = snap(win("a"), win("b"))
        self.assertFalse(m.accept_snapshot(s, s, restoring=True)[0])
        self.assertFalse(m.accept_snapshot(s, s, restore_pending=True)[0])

    def test_shrink_right_after_login_or_on_final(self):
        prev = snap(*[win("c%d" % i) for i in range(8)])
        new = snap(win("c0"))
        self.assertFalse(m.accept_snapshot(new, prev, since_login_s=30)[0])
        self.assertFalse(m.accept_snapshot(new, prev, final=True)[0])
        self.assertTrue(m.accept_snapshot(new, prev, since_login_s=3600)[0])      # closed on purpose, long after login
        self.assertTrue(m.accept_snapshot(snap(*[win("c%d" % i) for i in range(7)]), prev, final=True)[0])

    def test_rotation_keeps_last_n(self):
        for i in range(8):
            s = snap(win("a"), win("b%d" % i))
            s["taken_at"] = 1_700_000_000 + i * 100
            m.save_snapshot(s, keep=3)
        self.assertEqual(len(m.history_files()), 3)
        self.assertEqual(len(m.latest_snapshot()["windows"]), 2)

    def test_unchanged_layout_does_not_add_history(self):
        d = tempfile.mkdtemp(dir=TMP)
        m.STATE_DIR = d
        s = snap(win("a"))
        s["taken_at"] = 1_700_000_000
        m.save_snapshot(s)
        s2 = json.loads(json.dumps(s))
        s2["taken_at"] += 60
        s2["windows"][0]["title"] = "other title"
        m.save_snapshot(s2)
        self.assertEqual(len(m.history_files()), 1)
        self.assertEqual(m.latest_snapshot()["taken_at"], s2["taken_at"])


class Plan(unittest.TestCase):
    cfg = {"excluded": []}

    def test_terminals_agents_and_skips(self):
        t1 = win("Alacritty", 2, "terminal", terminal="alacritty", cwd="/a", agent={"kind": "claude", "session_id": "s1", "exact": True})
        t2 = win("Alacritty", 2, "terminal", terminal="alacritty", cwd="/b")
        t3 = win("Alacritty", 3, "terminal", terminal="alacritty", cwd="/c", agent={"kind": "codex", "session_id": "s2", "exact": True})
        live = snap(win("Alacritty", 4, "terminal", terminal="alacritty", cwd="/a", agent={"kind": "claude", "session_id": "s1"}))
        g = m.build_plan(snap(t1, t2, t3), live, self.cfg, [])
        status = [(x["windows"][0].get("cwd"), x["status"]) for x in g]
        self.assertEqual(status, [("/a", "skip"), ("/b", "launch"), ("/c", "launch")])
        self.assertEqual(m.plan_summary(g)["agents"], 1)

    def test_exclusions(self):
        a = win("firefox", 1, cmd=["firefox"], cmd_source="desktop", desktop="firefox")
        t = win("Alacritty", 1, "terminal", terminal="alacritty", cwd="/a", agent={"kind": "claude", "session_id": "s1"})
        g = m.build_plan(snap(a, t), snap(), {"excluded": ["firefox", "agent:claude"]}, [])
        self.assertEqual([x["status"] for x in g], ["skip", "skip"])

    def test_login_item_and_running_apps_not_launched_twice(self):
        a = win("com.onepassword.OnePassword", 1, cmd=["/opt/1Password/1password"], desktop="1password")
        b = win("slack", 2, cmd=["slack"], desktop="slack")
        c = win("mpv", 3, cmd=["mpv"], desktop="mpv")
        matchers = [{"desktop_id": "", "wmclass": "com.onepassword.onepassword", "exe": ""}]
        live = snap(win("slack", 1, cmd=["slack"]))
        g = {x["classes"][0]: x["status"] for x in m.build_plan(snap(a, b, c), live, self.cfg, matchers)}
        self.assertEqual(g, {"com.onepassword.OnePassword": "login-item", "slack": "running", "mpv": "launch"})

    def test_multi_window_app_is_one_launch(self):
        w1 = win("chrome", 1, cmd=["chrome"], pid=9, at=[0, 0])
        w2 = win("chrome", 2, cmd=["chrome"], pid=9, at=[0, 0])
        g = m.build_plan(snap(w1, w2), snap(), self.cfg, [])
        self.assertEqual(len(g), 1)
        self.assertEqual(len(g[0]["windows"]), 2)

    def test_group_command(self):
        t = win("org.omarchy.agent", 4, "terminal", terminal="alacritty", cwd="/", term_class="org.omarchy.agent",
                agent={"kind": "claude", "session_id": "s1", "flags": ["--permission-mode", "auto"], "cwd": "/"})
        g = m.build_plan(snap(t), snap(), self.cfg, [])[0]
        self.assertIn("--class org.omarchy.agent", m.group_command(g))
        self.assertIn("'claude --permission-mode auto --resume s1; exec bash'", m.group_command(g))


class VmWindows(unittest.TestCase):
    """Windows hosted by the muvm/Steam VM are never saved and never replayed (a relaunched VM holds /boot open)."""
    steam = dict(cmd=["m5pro-steam"], desktop="steam")

    def test_argv_and_class_detection(self):
        self.assertTrue(m.is_vm_argv(["/opt/muvm-gpu-20261125/bin/muvm", "--", "steam"]))
        self.assertTrue(m.is_vm_argv(["bash", "-lc", "m5pro-steam -silent"]))
        self.assertTrue(m.is_vm_argv(["/usr/local/bin/m5pro-muvm-gpu", "x"]))
        self.assertFalse(m.is_vm_argv(["firefox", "https://store.steampowered.com"]))
        for cls in ("steam", "Steam", "steamwebhelper", "steam_app_1245620", "muvm"):
            self.assertTrue(m.is_vm_window({"class": cls}), cls)
        self.assertFalse(m.is_vm_window({"class": "firefox", "cmd": ["firefox"]}))

    def test_process_ancestry(self):
        table = {10: {"ppid": 1, "comm": "muvm", "cmd": ["/usr/bin/muvm", "--", "steam"], "tty": 0},
                 11: {"ppid": 10, "comm": "weird", "cmd": ["weird"], "tty": 0},
                 20: {"ppid": 1, "comm": "firefox", "cmd": ["firefox"], "tty": 0}}
        self.assertTrue(m.is_vm_window({"class": "weird", "pid": 11}, table))
        self.assertFalse(m.is_vm_window({"class": "firefox", "pid": 20}, table))

    def test_capture_skips_vm_windows(self):
        table = {7: {"ppid": 1, "comm": "muvm", "cmd": ["muvm", "--", "steam"], "tty": 0},
                 8: {"ppid": 1, "comm": "mpv", "cmd": ["mpv"], "tty": 0}}
        def client(addr, cls, pid):
            return {"address": addr, "class": cls, "initialClass": cls, "title": cls, "mapped": True, "pid": pid, "workspace": {"id": 1, "name": "1"},
                    "monitor": 0, "floating": False, "at": [0, 0], "size": [10, 10], "fullscreen": 0}
        s = m.collect_snapshot(table=table, clients=[client("0x1", "steam", 7), client("0x2", "gameapp", 7), client("0x3", "mpv", 8)],
                               monitors=[{"id": 0, "name": "eDP-1"}], index=type("I", (), {"lookup": lambda *a, **k: None})())
        self.assertEqual([w["class"] for w in s["windows"]], ["mpv"])

    def test_replay_of_saved_state_skips_vm_windows(self):
        steam = win("steam", 3, cmd=["m5pro-steam"], desktop="steam", pid=50)
        web = win("steamwebhelper", 3, cmd=["steamwebhelper"], pid=51)
        via_cmd = win("odd", 3, cmd=["/opt/muvm-gpu-20261125/bin/muvm", "--", "x"], pid=52)
        term = win("Alacritty", 3, "terminal", terminal="alacritty", cwd="/", run=["m5pro-steam"])
        keep = win("mpv", 3, cmd=["mpv"], pid=53)
        g = m.build_plan(snap(steam, web, via_cmd, term, keep), snap(), {"excluded": []}, [])
        self.assertEqual([(x["classes"][0], x["status"]) for x in g], [("mpv", "launch")])


class LoginItems(unittest.TestCase):
    def setUp(self):
        for d in ("user-autostart", "sys-autostart"):
            os.makedirs(os.path.join(TMP, d), exist_ok=True)
            for f in os.listdir(os.path.join(TMP, d)):
                os.unlink(os.path.join(TMP, d, f))
        with open(os.path.join(TMP, "sys-autostart", "tray.desktop"), "w") as f:
            f.write("[Desktop Entry]\nType=Application\nName=Tray\nExec=tray --x\n")
        with open(os.path.join(TMP, "sys-autostart", "gnome-only.desktop"), "w") as f:
            f.write("[Desktop Entry]\nType=Application\nName=G\nExec=g\nOnlyShowIn=GNOME;\n")
        with open(os.path.join(TMP, "user-autostart", "mine.desktop"), "w") as f:
            f.write("[Desktop Entry]\nType=Application\nName=Mine\nExec=mine\nX-GNOME-Autostart-enabled=true\n")

    def items(self):
        return {i["id"]: i for i in m.list_autostart_items(m.DesktopIndex(dirs=[]))}

    def test_system_entry_overridden_never_edited(self):
        it = self.items()["tray.desktop"]
        self.assertTrue(it["enabled"])
        sys_file = os.path.join(TMP, "sys-autostart", "tray.desktop")
        before = open(sys_file).read()
        m.set_item_enabled(it, False)
        self.assertEqual(open(sys_file).read(), before)
        self.assertFalse(self.items()["tray.desktop"]["enabled"])
        m.set_item_enabled(self.items()["tray.desktop"], True)
        self.assertTrue(self.items()["tray.desktop"]["enabled"])
        self.assertFalse(os.path.exists(os.path.join(TMP, "user-autostart", "tray.desktop")))

    def test_user_entry_flag_roundtrip_keeps_content(self):
        p = os.path.join(TMP, "user-autostart", "mine.desktop")
        m.set_item_enabled(self.items()["mine.desktop"], False)
        txt = open(p).read()
        self.assertIn("Hidden=true", txt)
        self.assertIn("Exec=mine", txt)
        m.set_item_enabled(self.items()["mine.desktop"], True)
        self.assertNotIn("Hidden", open(p).read())

    def test_other_desktop_entries_are_not_applicable(self):
        it = self.items()["gnome-only.desktop"]
        self.assertFalse(it["enabled"])
        self.assertFalse(it["toggleable"])

    def test_add_app(self):
        name = m.add_login_app({"id": "foo", "name": "Foo", "exec": "foo --bar %U", "icon": "foo", "wmclass": "Foo"})
        txt = open(os.path.join(TMP, "user-autostart", name)).read()
        self.assertIn("Exec=foo --bar", txt)
        it = self.items()["foo.desktop"]
        self.assertTrue(it["added_here"])
        m.remove_login_app(it)
        self.assertNotIn("foo.desktop", self.items())

    def test_hypr_autostart_toggle_and_lock(self):
        p = m.HYPR_AUTOSTART
        with open(p, "w") as f:
            f.write('-- c\no.launch_on_start("my-service --flag")\n  o.launch_on_start("m5pro-lock-at-login")  -- lock\n-- o.launch_on_start("old")\n')
        items = {i["id"]: i for i in m.list_hypr_items(m.DesktopIndex(dirs=[]))}
        self.assertEqual(sorted(items), ["m5pro-lock-at-login", "my-service --flag"])
        self.assertTrue(items["m5pro-lock-at-login"]["locked"])
        with self.assertRaises(PermissionError):
            m.set_item_enabled(items["m5pro-lock-at-login"], False)
        m.set_item_enabled(items["my-service --flag"], False)
        self.assertIn("-- m5pro-disabled: o.launch_on_start", open(p).read())
        self.assertFalse({i["id"]: i for i in m.list_hypr_items()}["my-service --flag"]["enabled"])
        m.set_item_enabled({i["id"]: i for i in m.list_hypr_items()}["my-service --flag"], True)
        self.assertEqual(open(p).read().split("\n")[1], 'o.launch_on_start("my-service --flag")')
        self.assertIn('o.launch_on_start("m5pro-lock-at-login")  -- lock', open(p).read())


class Launcher(unittest.TestCase):
    def test_wrapper_script_loses_to_the_real_launcher(self):
        wrap = os.path.join(TMP, "claude-work")
        with open(wrap, "w") as f:
            f.write('#!/bin/bash\nexec /usr/bin/claude-desktop --disable-gpu --user-data-dir="$HOME/.config/Claude-Work" "$@"\n')
        stock = {"exec": "claude-desktop --disable-gpu %U"}
        work = {"exec": wrap + " %U"}
        personal = ["claude-desktop", "--ozone-platform=wayland", "--disable-gpu"]
        profile = ["claude-desktop", "--disable-gpu", "--user-data-dir=/home/x/.config/Claude-Work"]
        self.assertGreater(m.score_launcher(stock, personal), m.score_launcher(work, personal))
        self.assertGreater(m.score_launcher(work, profile), m.score_launcher(stock, profile))


if __name__ == "__main__":
    unittest.main()
