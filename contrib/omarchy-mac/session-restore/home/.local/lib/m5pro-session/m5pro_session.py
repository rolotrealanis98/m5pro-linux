"""m5pro-session core: window snapshots, agent session detection, restore engine, login items.

Used by m5pro-session-save, m5pro-session-restore and m5pro-session-app. Standard library only
(the GUI adds GTK4/libadwaita). Everything here is plain functions so it can be unit tested without
a compositor: the tests in ../../../../tests feed it fake /proc data, fake desktop files and fake clients.
"""
import collections
import fnmatch
import json
import os
import re
import select
import shlex
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time

HOME = os.path.expanduser("~")
STATE_DIR = os.environ.get("M5PRO_SESSION_STATE") or os.path.join(HOME, ".local/state/m5pro-session")
CONFIG_PATH = os.environ.get("M5PRO_SESSION_CONFIG") or os.path.join(HOME, ".config/m5pro-session/config.json")
HYPR_AUTOSTART = os.environ.get("M5PRO_SESSION_HYPR_AUTOSTART") or os.path.join(HOME, ".config/hypr/autostart.lua")
AUTOSTART_USER = os.environ.get("M5PRO_SESSION_AUTOSTART_USER") or os.path.join(HOME, ".config/autostart")
AUTOSTART_SYSTEM = (os.environ.get("M5PRO_SESSION_AUTOSTART_SYSTEM") or "/etc/xdg/autostart").split(":")
UNIT_USER_DIR = os.path.join(HOME, ".config/systemd/user")
UNIT_MEMORY = os.path.join(os.path.dirname(CONFIG_PATH), "login-units.json")

DEFAULT_CONFIG = {
    "auto_restore": True,        # the restorer runs at login
    "excluded": [],              # window classes (lower case) that are never restored
    "keep": 5,                   # snapshots kept in STATE_DIR
}
# Windows that are never saved or restored (our own app, portal helpers, bars).
IGNORE_CLASSES = {
    "org.m5pro.sessionrestore", "quickshell", "xdg-desktop-portal-gtk", "hyprland-share-picker",
    "org.freedesktop.impl.portal.desktop.hyprland", "polkit-gnome-authentication-agent-1", "mission-control",
}
# Windows hosted by a muvm microVM (Steam and its games via m5pro-steam / m5pro-muvm-gpu) are never saved or restored: a relaunched VM
# holds /boot open and blocks test boots. Matched on the window class, the launch command, and the process ancestry.
VM_CLASS_RE = re.compile(r"^(steam|steamwebhelper|steam_app_\d+|steam_proton|muvm)$")
VM_EXES = {"muvm", "krun", "m5pro-muvm-gpu", "m5pro-steam", "steam", "steamwebhelper", "steamrtarm64", "steam.sh"}
VM_PATH_PARTS = ("/bin/muvm", "m5pro-muvm-gpu", "m5pro-steam")
# Terminals we know how to start with a working directory and a command.
TERMINALS = {"alacritty": "alacritty", "kitty": "kitty", "foot": "foot", "footclient": "foot"}
SHELLS = {"bash", "zsh", "fish", "sh", "dash", "nu", "xonsh", "ksh"}
UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
LOCKED_COMMANDS = {
    "m5pro-lock-at-login": "Part of the Touch ID and lock-screen security: the lock screen is the only gate at boot, so this cannot be turned off here.",
}
LOCKED_UNITS = {
    "m5pro-session-save.service": "Managed by this app (Restore page).",
    "m5pro-session-restore.service": "Managed by this app: use the automatic-restore switch on the Restore page.",
}


# ----------------------------------------------------------------------------- small helpers

def is_vm_argv(argv):
    """True when a command line runs muvm, Steam or one of our wrappers for them (any argv element, so `bash -lc 'm5pro-steam'` counts)."""
    for a in argv or []:
        if not isinstance(a, str):
            continue
        if os.path.basename(a) in VM_EXES or any(part in a for part in VM_PATH_PARTS):
            return True
        if " " in a and any(os.path.basename(t) in VM_EXES for t in a.split()):
            return True
    return False


def is_vm_window(w, table=None):
    """A window (live client or saved entry) that a muvm VM hosts. table (proc_table) adds the process-ancestry check."""
    for k in ("class", "initialClass"):
        if VM_CLASS_RE.match((w.get(k) or "").lower()):
            return True
    if (w.get("desktop") or "").lower() in ("steam", "steam.desktop"):
        return True
    if is_vm_argv(w.get("cmd")) or is_vm_argv(w.get("run")):
        return True
    if table is not None:
        pid, hops = w.get("pid") or 0, 0
        while pid and pid in table and hops < 12:
            if is_vm_argv(table[pid]["cmd"]) or table[pid]["comm"] in VM_EXES:
                return True
            pid, hops = table[pid].get("ppid") or 0, hops + 1
    return False

def atomic_write(path, data, mode=0o600):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def load_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    cfg.update(load_json(CONFIG_PATH, {}) or {})
    cfg["excluded"] = sorted({str(x).lower() for x in cfg.get("excluded", [])})
    return cfg


def save_config(cfg):
    atomic_write(CONFIG_PATH, json.dumps(cfg, indent=2, sort_keys=True) + "\n", 0o644)


def boot_id():
    try:
        with open("/proc/sys/kernel/random/boot_id") as f:
            return f.read().strip()
    except OSError:
        return ""


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def lua_q(s):
    """Quote a string as a Lua string literal."""
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch in '\\"':
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\n")
        elif o < 32 or o == 127:
            out.append("\\%03d" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


# ----------------------------------------------------------------------------- Hyprland

def hypr_env():
    env = dict(os.environ)
    rt = env.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
    env["XDG_RUNTIME_DIR"] = rt
    sig = env.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    base = os.path.join(rt, "hypr")
    if not sig or not os.path.exists(os.path.join(base, sig, ".socket.sock")):
        best = None
        try:
            for d in os.listdir(base):
                p = os.path.join(base, d, ".socket.sock")
                if os.path.exists(p) and (best is None or os.stat(p).st_mtime > best[0]):
                    best = (os.stat(p).st_mtime, d)
        except OSError:
            pass
        if best:
            env["HYPRLAND_INSTANCE_SIGNATURE"] = best[1]
    return env


def hyprctl_json(*args):
    r = subprocess.run(["hyprctl", "-j", *args], env=hypr_env(), capture_output=True, text=True, timeout=8)
    if r.returncode != 0:
        raise RuntimeError("hyprctl %s failed: %s" % (" ".join(args), r.stderr.strip()))
    return json.loads(r.stdout)


def hypr_dispatch(lua):
    """Run one Lua dispatcher, e.g. hl.dsp.window.close({...}). Hyprland 0.57 takes Lua here, not 'exec ...' strings."""
    r = subprocess.run(["hyprctl", "dispatch", lua], env=hypr_env(), capture_output=True, text=True, timeout=8)
    out = (r.stdout + r.stderr).strip()
    return out.splitlines()[0].strip() == "ok" if out else r.returncode == 0, out


def ws_ref(ws):
    """Workspace reference for Lua dispatchers from a {'id','name'} record."""
    name = str(ws.get("name", ""))
    if name.startswith("special:"):
        return name
    if name == str(ws.get("id")) or not name:
        return str(ws.get("id"))
    return "name:" + name


def move_window(addr, ws):
    return hypr_dispatch("hl.dsp.window.move({ workspace = %s, follow = false, window = %s })"
                         % (lua_q(ws_ref(ws)), lua_q("address:" + addr)))


def exec_on_workspace(cmd, ws):
    """Start a command; its first window opens silently on the workspace."""
    return hypr_dispatch("hl.dsp.exec_cmd(%s, { workspace = %s })" % (lua_q(cmd), lua_q(ws_ref(ws) + " silent")))


class EventStream:
    """Hyprland's event socket (socket2): wakes the restorer when a window opens."""

    def __init__(self):
        self.sock = None
        env = hypr_env()
        path = os.path.join(env["XDG_RUNTIME_DIR"], "hypr", env.get("HYPRLAND_INSTANCE_SIGNATURE", ""), ".socket2.sock")
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(path)
            s.setblocking(False)
            self.sock = s
        except OSError:
            self.sock = None
        self.buf = b""

    def wait(self, timeout):
        """Return a list of (event, data) seen within timeout seconds (may be empty)."""
        if not self.sock:
            time.sleep(timeout)
            return []
        try:
            r, _, _ = select.select([self.sock], [], [], timeout)
            if not r:
                return []
            chunk = self.sock.recv(65536)
        except OSError:
            return []
        if not chunk:
            self.sock = None
            return []
        self.buf += chunk
        lines = self.buf.split(b"\n")
        self.buf = lines.pop()
        evs = []
        for ln in lines:
            name, _, data = ln.decode("utf8", "replace").partition(">>")
            evs.append((name, data))
        return evs

    def close(self):
        if self.sock:
            self.sock.close()


# ----------------------------------------------------------------------------- /proc

def proc_table():
    """pid -> {ppid, comm, cmd, tty}. One pass over /proc."""
    table = {}
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % d, "rb") as f:
                s = f.read().decode("utf8", "replace")
            rp = s.rindex(")")
            comm = s[s.index("(") + 1:rp]
            rest = s[rp + 2:].split()
            with open("/proc/%s/cmdline" % d, "rb") as f:
                cmd = [x.decode("utf8", "replace") for x in f.read().split(b"\0") if x]
            if len(cmd) == 1 and " " in cmd[0] and cmd[0].startswith("/"):
                cmd = cmd[0].split(" ")          # electron/chrome rewrite their title into argv[0]
            table[int(d)] = {"ppid": int(rest[1]), "comm": comm, "cmd": cmd, "tty": int(rest[4])}
        except (OSError, ValueError, IndexError):
            continue
    return table


def descendants(table, pid):
    """pid's descendants, breadth first (nearest first)."""
    kids = collections.defaultdict(list)
    for p, info in table.items():
        kids[info["ppid"]].append(p)
    out, queue = [], collections.deque(sorted(kids.get(pid, [])))
    while queue:
        p = queue.popleft()
        out.append(p)
        queue.extend(sorted(kids.get(p, [])))
    return out


def pid_cwd(pid):
    try:
        return os.readlink("/proc/%d/cwd" % pid)
    except OSError:
        return None


# ----------------------------------------------------------------------------- desktop files

def parse_desktop(path):
    """Parse the [Desktop Entry] group into a dict (plain keys only, no localized ones)."""
    d = {}
    try:
        with open(path, encoding="utf8", errors="replace") as f:
            in_main = False
            for line in f:
                line = line.rstrip("\n")
                if line.startswith("["):
                    in_main = line.strip() == "[Desktop Entry]"
                    continue
                if not in_main or not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                k = k.strip()
                if "[" in k:
                    continue
                d.setdefault(k, v.strip())
    except OSError:
        return None
    return d


def exec_argv(exec_line):
    """Desktop Exec= to an argv: field codes dropped, quoting honoured."""
    try:
        toks = shlex.split(exec_line)
    except ValueError:
        toks = exec_line.split()
    out = []
    for t in toks:
        t = t.replace("%%", "\0")
        stripped = re.sub(r"%[fFuUdDnNickvm]", "", t)
        if stripped != t and (not stripped or stripped.endswith("=")):
            continue                              # a bare %u, or --url=%u with nothing to put there
        out.append(stripped.replace("\0", "%"))
    return out


def app_dirs():
    dirs = [os.path.join(HOME, ".local/share/applications")]
    for d in (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":"):
        if d:
            dirs.append(os.path.join(d, "applications"))
    return dirs


class DesktopIndex:
    """Installed applications: lookup by window class, Exec parsing. Cached on directory mtimes."""

    def __init__(self, dirs=None):
        self.dirs = dirs or app_dirs()
        self.sig = None
        self.apps = []

    def refresh(self):
        sig = []
        for d in self.dirs:
            try:
                sig.append((d, os.stat(d).st_mtime_ns))
            except OSError:
                sig.append((d, 0))
        if sig == self.sig:
            return
        self.sig = sig
        seen, apps = set(), []
        for d in self.dirs:
            try:
                names = sorted(os.listdir(d))
            except OSError:
                continue
            for n in names:
                if not n.endswith(".desktop") or n in seen:
                    continue
                seen.add(n)
                e = parse_desktop(os.path.join(d, n))
                if not e or e.get("Type", "Application") != "Application" or not e.get("Exec"):
                    continue
                apps.append({
                    "id": n[:-8], "file": os.path.join(d, n), "name": e.get("Name", n[:-8]),
                    "exec": e["Exec"], "wmclass": e.get("StartupWMClass", ""), "icon": e.get("Icon", ""),
                    "terminal": e.get("Terminal", "false").lower() == "true",
                    "nodisplay": e.get("NoDisplay", "false").lower() == "true" or e.get("Hidden", "false").lower() == "true",
                })
        self.apps = apps

    def candidates(self, *classes):
        self.refresh()
        want = [c.lower() for c in classes if c]
        out = []
        for tier in ("wmclass", "id"):            # StartupWMClass is the exact link; else the desktop id
            for c in want:
                for a in self.apps:
                    if a[tier].lower() == c and a not in out:
                        out.append(a)
            if out:
                break
        return out

    def lookup(self, *classes, proc_cmd=None):
        """The desktop entry for a window class. Several entries can claim one class (a work profile wrapper next to
        the stock launcher): the running process's command line decides which one it really is."""
        cands = self.candidates(*classes)
        if len(cands) > 1 and proc_cmd:
            cands.sort(key=lambda a: -score_launcher(a, proc_cmd))
        return cands[0] if cands else None


def flag_names(argv):
    return {t.split("=", 1)[0] for t in argv if t.startswith("--")}


def score_launcher(app, proc_cmd):
    argv = exec_argv(app["exec"])
    flags = flag_names(argv)
    exe = os.path.basename(proc_cmd[0]) if proc_cmd else ""
    match = bool(argv) and os.path.basename(argv[0]) == exe
    if argv and not match:                         # a wrapper script that execs the real binary
        try:
            if os.path.getsize(argv[0]) < 8192:
                with open(argv[0], errors="replace") as f:
                    text = f.read()
                if exe and exe in text:
                    match = True
                    flags |= {m for m in re.findall(r"--[a-z][a-z0-9-]*", text)}
        except OSError:
            pass
    pflags = flag_names(proc_cmd)
    score = 2 * match + len(flags & pflags) - len(flags - pflags)
    if {"--user-data-dir", "--profile-directory"} & (pflags - flags):
        score -= 2
    return score


# ----------------------------------------------------------------------------- agents

AGENT_NAMES = {
    "claude": "claude", "codex": "codex", "opencode": "opencode", "agy": "agy", "antigravity": "agy", "gemini": "gemini",
}
# Flags worth carrying over to the resumed session: flag -> number of values.
CARRY_FLAGS = {
    "claude": {"--dangerously-skip-permissions": 0, "--permission-mode": 1, "--model": 1, "--effort": 1, "--chrome": 0},
    "codex": {"--dangerously-bypass-approvals-and-sandbox": 0, "--full-auto": 0, "--search": 0, "-m": 1, "--model": 1,
              "-s": 1, "--sandbox": 1, "-a": 1, "--ask-for-approval": 1},
    "opencode": {"--auto": 0},
    "agy": {"--dangerously-skip-permissions": 0, "--model": 1, "--effort": 1, "--mode": 1},
    "gemini": {"--yolo": 0, "-y": 0, "-m": 1, "--model": 1},
}
AGENT_DB = {
    "codex_logs": os.path.join(HOME, ".codex/logs_2.sqlite"),
    "codex_state": os.path.join(HOME, ".codex/state_5.sqlite"),
    "opencode": os.path.join(HOME, ".local/share/opencode/opencode.db"),
    "agy_dir": os.path.join(HOME, ".gemini/antigravity-cli"),
    "claude_dir": os.path.join(HOME, ".claude"),
}


def agent_kind(cmd):
    """Which agent CLI a command line is, or None. Interpreter wrappers (node/bun/python) are looked through."""
    if not cmd:
        return None
    exe = os.path.basename(cmd[0])
    if exe in ("node", "bun", "deno", "python", "python3", "sh", "bash") and len(cmd) > 1:
        exe = os.path.basename(cmd[1])
    exe = re.sub(r"\.(js|mjs|cjs|py)$", "", exe).lstrip(".")
    kind = AGENT_NAMES.get(exe)
    if kind == "codex" and any(x in cmd for x in ("app-server", "exec-server", "mcp-server")):
        return None              # codex's own helper processes, not the TUI
    return kind


def carried_flags(kind, cmd):
    table, out, i = CARRY_FLAGS.get(kind, {}), [], 1
    while i < len(cmd):
        a = cmd[i]
        name, eq, val = a.partition("=")
        if name in table:
            if table[name] == 0:
                out.append(name)
            elif eq:
                out += [name, val]
            elif i + 1 < len(cmd):
                out += [name, cmd[i + 1]]
                i += 1
        i += 1
    return out


def _sqlite_ro(path):
    con = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=2)
    con.row_factory = sqlite3.Row
    return con


def claude_session(pid, cmd):
    d = load_json(os.path.join(AGENT_DB["claude_dir"], "sessions", "%d.json" % pid))
    if d and d.get("sessionId") and int(d.get("pid", pid)) == pid:
        return d["sessionId"], d.get("cwd"), True
    for i, a in enumerate(cmd):
        if a in ("--resume", "-r") and i + 1 < len(cmd) and UUID_RE.fullmatch(cmd[i + 1]):
            return cmd[i + 1], None, True
        if a.startswith("--resume=") and UUID_RE.fullmatch(a.split("=", 1)[1]):
            return a.split("=", 1)[1], None, True
    return None, None, False


def claude_transcript_exists(session_id):
    base = os.path.join(AGENT_DB["claude_dir"], "projects")
    try:
        for p in os.listdir(base):
            if os.path.exists(os.path.join(base, p, session_id + ".jsonl")):
                return True
    except OSError:
        pass
    return False


def codex_session(pid, cmd, family, cwd):
    """family: the agent's pid plus its descendants (codex logs under its app-server child)."""
    try:
        con = _sqlite_ro(AGENT_DB["codex_logs"])
        like = " or ".join("process_uuid like 'pid:%d:%%'" % p for p in family)
        row = con.execute("select thread_id from logs where thread_id is not null and (%s) order by id desc limit 1" % like).fetchone()
        con.close()
        if row and row[0]:
            return row[0], True
    except sqlite3.Error:
        pass
    for i, a in enumerate(cmd):
        if a in ("resume", "fork") and i + 1 < len(cmd) and UUID_RE.fullmatch(cmd[i + 1]):
            return cmd[i + 1], True
    try:
        con = _sqlite_ro(AGENT_DB["codex_state"])
        row = con.execute("select id from threads where cwd=? and archived=0 order by updated_at desc limit 1", (cwd,)).fetchone()
        con.close()
        if row:
            return row[0], False
    except sqlite3.Error:
        pass
    return None, False


def agy_session(family, cmd, cwd):
    base = AGENT_DB["agy_dir"]
    for p in family:                      # the running CLI holds presence/<id>.lock and conversations/<id>.db open
        try:
            for fd in os.listdir("/proc/%d/fd" % p):
                try:
                    t = os.readlink("/proc/%d/fd/%s" % (p, fd))
                except OSError:
                    continue
                m = re.match(re.escape(base) + r"/(presence|conversations)/(%s)\.(lock|db)$" % UUID_RE.pattern, t)
                if m:
                    return m.group(2), True
        except OSError:
            continue
    for i, a in enumerate(cmd):
        if a == "--conversation" and i + 1 < len(cmd):
            return cmd[i + 1], True
        if a.startswith("--conversation="):
            return a.split("=", 1)[1], True
    last = None
    try:
        with open(os.path.join(base, "history.jsonl")) as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("workspace") == cwd and e.get("conversationId"):
                    last = e["conversationId"]
    except OSError:
        pass
    return last, False


def opencode_session(cmd, cwd):
    for i, a in enumerate(cmd):
        if a in ("-s", "--session") and i + 1 < len(cmd):
            return cmd[i + 1], True
        if a.startswith("--session="):
            return a.split("=", 1)[1], True
    try:
        con = _sqlite_ro(AGENT_DB["opencode"])
        row = con.execute("select id from session_v2 where directory=? and time_archived is null and parent_id is null "
                          "order by time_updated desc limit 1", (cwd,)).fetchone()
        con.close()
        if row:
            return row[0], False
    except sqlite3.Error:
        pass
    return None, False


def detect_agent(table, pid):
    """The agent CLI nearest to pid in its process tree, with its session id. None if there is none."""
    cands = [p for p in [pid] + descendants(table, pid) if p in table and agent_kind(table[p]["cmd"])]
    cands = [p for p in cands if not (agent_kind(table[table[p]["ppid"]]["cmd"]) if table[p]["ppid"] in table else None)]
    if not cands:
        return None
    ap = cands[0]
    cmd = table[ap]["cmd"]
    kind = agent_kind(cmd)
    cwd = pid_cwd(ap) or pid_cwd(pid) or HOME
    family = [ap] + descendants(table, ap)
    sid, exact, fresh = None, False, False
    if kind == "claude":
        sid, c, exact = claude_session(ap, cmd)
        cwd = c or cwd
        if sid and not claude_transcript_exists(sid):
            fresh, sid, exact = True, None, False   # an empty session has nothing to resume: start fresh in the same folder
    elif kind == "codex":
        sid, exact = codex_session(ap, cmd, family, cwd)
    elif kind == "agy":
        sid, exact = agy_session(family, cmd, cwd)
    elif kind == "opencode":
        sid, exact = opencode_session(cmd, cwd)
    elif kind == "gemini":
        sid, exact = "latest", False
    return {"kind": kind, "session_id": sid, "exact": bool(exact and sid), "fresh": fresh, "cwd": cwd,
            "flags": carried_flags(kind, cmd), "pid": ap}


def resume_argv(agent):
    """The command that reopens an agent session (argv), as run inside the restored terminal."""
    kind, sid, flags = agent["kind"], agent.get("session_id"), agent.get("flags", [])
    if agent.get("fresh"):
        return [kind, *flags]
    if kind == "claude":
        return ["claude", *flags, *(["--resume", sid] if sid else ["--continue"])]
    if kind == "codex":
        return ["codex", *flags, *(["resume", sid] if sid else ["resume", "--last"])]
    if kind == "opencode":
        return ["opencode", *flags, *(["--session", sid] if sid else ["--continue"])]
    if kind == "agy":
        return ["agy", *flags, *(["--conversation", sid] if sid else ["--continue"])]
    if kind == "gemini":
        return ["gemini", *flags, "--resume", "latest"]
    return [kind]


def terminal_argv(term, cwd, inner=None, cls=None):
    """Start a terminal in cwd; inner (a shell command line) runs in a login bash that stays open afterwards."""
    cwd = cwd if cwd and os.path.isdir(cwd) else HOME
    tail = ["bash", "-lc", "%s; exec bash" % inner] if inner else []
    if term == "kitty":
        return ["kitty", *(["--class", cls] if cls else []), "--directory", cwd, *tail]
    if term == "foot":
        return ["foot", *(["--app-id", cls] if cls else []), "--working-directory", cwd, *tail]
    return ["alacritty", *(["--class", cls] if cls else []), "--working-directory", cwd, *(["-e", *tail] if tail else [])]


# ----------------------------------------------------------------------------- snapshot

def terminal_of(cls):
    return TERMINALS.get((cls or "").lower())


def terminal_exe(table, pid):
    """The terminal program behind a window's process (alacritty, kitty, foot), whatever class it was started with."""
    info = table.get(pid)
    if not info:
        return None
    exe = os.path.basename(info["cmd"][0]) if info["cmd"] else info["comm"]
    return TERMINALS.get(exe.lower())


def terminal_default_class(term):
    return {"alacritty": "Alacritty", "kitty": "kitty", "foot": "foot"}.get(term, "")


def alacritty_command(cmd):
    """Tokens after -e / --command of an alacritty command line (what the window was asked to run), or []."""
    for i, a in enumerate(cmd):
        if a in ("-e", "--command"):
            return cmd[i + 1:]
    return []


def collect_snapshot(table=None, clients=None, monitors=None, index=None):
    clients = clients if clients is not None else hyprctl_json("clients")
    monitors = monitors if monitors is not None else hyprctl_json("monitors")
    table = table if table is not None else proc_table()
    index = index or DesktopIndex()
    mon_name = {m["id"]: m["name"] for m in monitors}
    by_pid = collections.Counter(c.get("pid") for c in clients if c.get("mapped"))
    windows = []
    for c in clients:
        cls = c.get("class") or c.get("initialClass") or ""
        if not c.get("mapped") or not cls or cls.lower() in IGNORE_CLASSES:
            continue
        pid = c.get("pid") or 0
        if is_vm_window({"class": cls, "initialClass": c.get("initialClass"), "pid": pid}, table):
            continue
        w = {
            "address": c["address"], "class": c.get("class", ""), "initialClass": c.get("initialClass", ""),
            "title": c.get("title", ""), "initialTitle": c.get("initialTitle", ""),
            "workspace": {"id": c["workspace"]["id"], "name": c["workspace"]["name"]},
            "monitor": mon_name.get(c.get("monitor"), ""), "floating": bool(c.get("floating")),
            "at": c.get("at", [0, 0]), "size": c.get("size", [0, 0]), "fullscreen": int(c.get("fullscreen", 0) or 0),
            "pid": pid, "xwayland": bool(c.get("xwayland")), "pinned": bool(c.get("pinned")),
        }
        term = terminal_exe(table, pid) or terminal_of(cls)
        if term and pid in table:
            w["kind"] = "terminal"
            w["terminal"] = term
            if cls != terminal_default_class(term):
                w["term_class"] = cls                 # e.g. org.omarchy.agent: keep it so Omarchy's window rules still match
            fam = descendants(table, pid)
            shells = [p for p in fam if table[p]["comm"] in SHELLS or os.path.basename((table[p]["cmd"] or [""])[0]).lstrip("-") in SHELLS]
            sh = shells[0] if shells else None
            w["cwd"] = (pid_cwd(sh) if sh else None) or pid_cwd(pid) or HOME
            w["shared_process"] = by_pid[pid] > 1
            ag = None if by_pid[pid] > 1 else detect_agent(table, pid)
            if ag:
                ag.pop("pid", None)
                w["agent"] = ag
            elif term == "alacritty":
                run = alacritty_command(table[pid]["cmd"])
                if run and os.path.basename(run[0]) not in SHELLS:
                    w["run"] = run                    # a TUI the terminal was started for (not a shell wrapper)
        else:
            w["kind"] = "app"
            app = index.lookup(cls, c.get("initialClass"), proc_cmd=table.get(pid, {}).get("cmd"))
            if app and not app["terminal"]:
                w["cmd"], w["cmd_source"], w["desktop"], w["app_name"] = exec_argv(app["exec"]), "desktop", app["id"], app["name"]
                w["icon"] = app["icon"]
            elif pid in table and table[pid]["cmd"]:
                w["cmd"], w["cmd_source"] = table[pid]["cmd"], "proc"
                w["cwd"] = pid_cwd(pid) or HOME
                if app:
                    w["app_name"] = app["name"]
            w.setdefault("app_name", cls)
        windows.append(w)
    return {"version": 1, "taken_at": time.time(), "boot_id": boot_id(), "monitors": sorted(mon_name.values()), "windows": windows}


def snapshot_signature(snap):
    """What matters for restoring (not titles or timestamps): used to decide whether to keep a new history file."""
    return sorted(json.dumps([w["class"], w["workspace"]["name"], w["floating"], w.get("cwd"),
                              (w.get("agent") or {}).get("kind"), (w.get("agent") or {}).get("session_id"),
                              w["at"] if w["floating"] else None, w["size"] if w["floating"] else None])
                  for w in snap["windows"])


def accept_snapshot(new, prev, *, restoring=False, restore_pending=False, since_login_s=1e9, final=False):
    """Decide whether a fresh snapshot may replace the good one. Returns (ok, reason)."""
    n = len(new["windows"])
    if n == 0:
        return False, "no windows"
    if restoring:
        return False, "a restore is running"
    if restore_pending:
        return False, "the login restore has not run yet"
    pn = len(prev["windows"]) if prev else 0
    if pn >= 3 and (final or since_login_s < 600) and n < 0.6 * pn:
        return False, "far fewer windows than the last good snapshot (%d vs %d): session starting or ending" % (n, pn)
    return True, "ok"


def history_files():
    try:
        names = sorted(n for n in os.listdir(STATE_DIR) if n.startswith("snapshot-") and n.endswith(".json"))
    except OSError:
        return []
    return [os.path.join(STATE_DIR, n) for n in names]


def latest_snapshot():
    return load_json(os.path.join(STATE_DIR, "latest.json"))


def restore_status():
    return load_json(os.path.join(STATE_DIR, "restore.json"), {}) or {}


def restore_running():
    st = restore_status()
    return st.get("status") == "running" and pid_alive(st.get("pid"))


def write_restore_status(**kw):
    st = restore_status()
    st.update(kw)
    atomic_write(os.path.join(STATE_DIR, "restore.json"), json.dumps(st, indent=1) + "\n")


def save_snapshot(snap, keep=5):
    """Write snapshot as latest.json (always) and as a history file (when it differs from the last one)."""
    os.makedirs(STATE_DIR, exist_ok=True)
    os.chmod(STATE_DIR, 0o700)
    atomic_write(os.path.join(STATE_DIR, "latest.json"), json.dumps(snap, indent=1) + "\n")
    hist = history_files()
    last = load_json(hist[-1]) if hist else None
    if not last or snapshot_signature(last) != snapshot_signature(snap):
        name = "snapshot-%s.json" % time.strftime("%Y%m%d-%H%M%S", time.localtime(snap["taken_at"]))
        atomic_write(os.path.join(STATE_DIR, name), json.dumps(snap, indent=1) + "\n")
    for old in history_files()[:-max(1, int(keep))]:
        try:
            os.unlink(old)
        except OSError:
            pass


def save_once(final=False, force=False, started=None, log=lambda m: None):
    """One guarded save. Returns (saved, reason)."""
    cfg = load_config()
    try:
        snap = collect_snapshot()
    except Exception as e:           # compositor gone or not up yet: keep what we have
        return False, "no compositor: %s" % e
    prev = latest_snapshot()
    st = restore_status()
    since_login = (time.time() - started) if started else 1e9      # one-shot saves (Save now, shutdown) know no warm-up
    done_at = st.get("finished") if st.get("boot_id") == boot_id() else None
    if done_at and time.time() - done_at < 600:
        since_login = min(since_login, time.time() - done_at)
    pending = bool(started and cfg["auto_restore"] and prev and st.get("boot_id") != boot_id() and since_login < 900)
    ok, why = (True, "forced") if force else accept_snapshot(
        snap, prev, restoring=restore_running(), restore_pending=pending, since_login_s=since_login, final=final)
    if ok:
        save_snapshot(snap, cfg["keep"])
    return ok, why


def run_saver(interval=60, log=print):
    started = time.time()
    last_reason = None
    while True:
        ok, why = save_once(started=started)
        if why != last_reason:
            log("saved" if ok else "skipped: %s" % why)
            last_reason = why
        time.sleep(interval)


# ----------------------------------------------------------------------------- login items

def desktops():
    return [d for d in (os.environ.get("XDG_CURRENT_DESKTOP") or "Hyprland").split(":") if d]


def autostart_enabled(e):
    if e.get("Hidden", "false").lower() == "true":
        return False
    if e.get("X-GNOME-Autostart-enabled", "true").lower() == "false":
        return False
    return True


def autostart_applicable(e):
    only = [x for x in e.get("OnlyShowIn", "").split(";") if x]
    notin = [x for x in e.get("NotShowIn", "").split(";") if x]
    cur = desktops()
    if only and not any(c in only for c in cur):
        return False
    if any(c in notin for c in cur):
        return False
    return True


def is_background_entry(e):
    if e.get("NoDisplay", "false").lower() == "true":
        return True
    return any(k in e for k in ("X-GNOME-Autostart-Phase", "X-GNOME-HiddenUnderSystemd", "X-KDE-autostart-phase"))


def parse_hypr_autostart(path=None):
    """o.launch_on_start("cmd") lines: [{line_no, command, enabled, raw}] (a line disabled by this app starts with '-- m5pro-disabled: ')."""
    items = []
    try:
        with open(path or HYPR_AUTOSTART) as f:
            lines = f.read().split("\n")
    except OSError:
        return items
    pat = re.compile(r'^(?P<pre>\s*(?:--\s*m5pro-disabled:\s*)?)o\.launch_on_start\(\s*(?P<q>["\'])(?P<cmd>(?:\\.|(?!(?P=q)).)*)(?P=q)\s*\)\s*(?:--.*)?$')
    for i, ln in enumerate(lines):
        m = pat.match(ln)
        if not m:
            continue
        pre = m.group("pre")
        if pre.strip() and "m5pro-disabled" not in pre:
            continue
        items.append({"line_no": i, "command": m.group("cmd").replace('\\"', '"').replace("\\'", "'"),
                      "enabled": "m5pro-disabled" not in pre})
    return items


def set_hypr_autostart(command, enabled, path=None):
    path = path or HYPR_AUTOSTART
    with open(path) as f:
        text = f.read()
    lines = text.split("\n")
    for it in parse_hypr_autostart(path):
        if it["command"] != command:
            continue
        ln = lines[it["line_no"]]
        if enabled and not it["enabled"]:
            lines[it["line_no"]] = re.sub(r"^(\s*)--\s*m5pro-disabled:\s*", r"\1", ln)
        elif not enabled and it["enabled"]:
            lines[it["line_no"]] = re.sub(r"^(\s*)", r"\1-- m5pro-disabled: ", ln, count=1)
        else:
            return
        atomic_write(path, "\n".join(lines), os.stat(path).st_mode & 0o777)
        return
    raise KeyError(command)


def read_unit_memory():
    return load_json(UNIT_MEMORY, {}) or {}


def _systemctl(*args):
    return subprocess.run(["systemctl", "--user", *args], capture_output=True, text=True, timeout=20)


STOCK_WANTS = ("omarchy-", "bt-agent", "pipewire", "wireplumber", "gcr-", "dbus", "xdg-", "gvfs", "at-spi")


def candidate_units():
    """Names of the owner's own user units (not stock systemd/Omarchy ones)."""
    names = set()
    try:
        for n in os.listdir(UNIT_USER_DIR):
            if n.endswith((".service", ".timer")) and not n.startswith(STOCK_WANTS):
                names.add(n)
            elif n.endswith(".wants") and os.path.isdir(os.path.join(UNIT_USER_DIR, n)):
                for u in os.listdir(os.path.join(UNIT_USER_DIR, n)):
                    if u.endswith((".service", ".timer")) and not u.startswith(STOCK_WANTS):
                        names.add(u)
    except OSError:
        pass
    for d in ("/usr/lib/systemd/user", "/etc/systemd/user"):
        try:
            for n in os.listdir(d):
                if n.endswith((".service", ".timer")) and (fnmatch.fnmatch(n, "m5pro-*") or fnmatch.fnmatch(n, "aurora-*")) and "@" not in n:
                    names.add(n)
        except OSError:
            pass
    names |= set(read_unit_memory())          # units this app turned off keep their row
    return sorted(names)


def list_unit_items():
    names = candidate_units()
    if not names:
        return []
    r = _systemctl("show", "-p", "Id,Description,UnitFileState,ActiveState,FragmentPath,LoadState", *names)
    blocks = [b for b in r.stdout.strip().split("\n\n")]
    mem = read_unit_memory()
    items, new_mem = [], dict(mem)
    for name, block in zip(names, blocks):
        kv = dict(l.partition("=")[::2] for l in block.splitlines() if "=" in l)
        if kv.get("LoadState") == "not-found" and name not in mem:
            continue
        state = kv.get("UnitFileState", "")
        frag = kv.get("FragmentPath") or mem.get(name, "")
        if kv.get("FragmentPath"):
            new_mem[name] = kv["FragmentPath"]
        can_toggle = state not in ("static", "generated", "transient", "masked", "masked-runtime", "indirect") or kv.get("LoadState") == "not-found"
        items.append({
            "kind": "unit", "id": name, "name": name[:-8] if name.endswith(".service") else name,
            "comment": kv.get("Description", ""), "category": "Background",
            "enabled": state in ("enabled", "enabled-runtime", "linked", "linked-runtime", "alias"),
            "running": kv.get("ActiveState") == "active", "locked": name in LOCKED_UNITS,
            "lock_note": LOCKED_UNITS.get(name, ""), "toggleable": can_toggle and name not in LOCKED_UNITS,
            "source": frag, "state": state or "not enabled",
        })
    if new_mem != mem:
        try:
            atomic_write(UNIT_MEMORY, json.dumps(new_mem, indent=1) + "\n", 0o644)
        except OSError:
            pass
    return items


def list_autostart_items(index=None):
    index = index or DesktopIndex()
    files = collections.OrderedDict()
    for d in AUTOSTART_SYSTEM:
        try:
            for n in sorted(os.listdir(d)):
                if n.endswith(".desktop"):
                    files.setdefault(n, {})["system"] = os.path.join(d, n)
        except OSError:
            pass
    try:
        for n in sorted(os.listdir(AUTOSTART_USER)):
            if n.endswith(".desktop"):
                files.setdefault(n, {})["user"] = os.path.join(AUTOSTART_USER, n)
    except OSError:
        pass
    items = []
    for n, src in files.items():
        sysd = parse_desktop(src["system"]) if "system" in src else None
        usr = parse_desktop(src["user"]) if "user" in src else None
        e = dict(sysd or {})
        e.update({k: v for k, v in (usr or {}).items()})
        if not e.get("Exec"):
            continue
        name = e.get("Name") or (sysd or {}).get("Name") or n[:-8]
        applicable = autostart_applicable(e)
        items.append({
            "kind": "autostart", "id": n, "name": name, "comment": e.get("Comment", ""),
            "category": "Background" if is_background_entry(e) else "App",
            "enabled": autostart_enabled(e) and applicable, "applicable": applicable,
            "running": False, "locked": False, "lock_note": "",
            "toggleable": applicable, "icon": e.get("Icon", ""), "exec": e.get("Exec", ""),
            "wmclass": e.get("StartupWMClass", ""), "desktop_id": n[:-8],
            "system": "system" in src, "user": "user" in src, "added_here": (usr or {}).get("X-M5PRO-Added", "") == "true",
            "source": src.get("user") or src["system"],
            "state": "" if applicable else "never starts on this desktop",
        })
    return items


def list_hypr_items(index=None):
    index = index or DesktopIndex()
    items = []
    for it in parse_hypr_autostart():
        cmd = it["command"]
        first = os.path.basename(shlex.split(cmd)[0]) if cmd.strip() else cmd
        app = None
        index.refresh()
        for a in index.apps:
            ea = exec_argv(a["exec"])
            if ea and os.path.basename(ea[0]) == first:
                app = a
                break
        locked = first in LOCKED_COMMANDS
        items.append({
            "kind": "hypr", "id": cmd, "name": first, "comment": cmd if cmd != first else "Started from ~/.config/hypr/autostart.lua",
            "category": "App" if app else "Background", "enabled": it["enabled"] or locked, "running": False,
            "locked": locked, "lock_note": LOCKED_COMMANDS.get(first, ""), "toggleable": not locked,
            "icon": (app or {}).get("icon", ""), "exec": cmd, "wmclass": (app or {}).get("wmclass", ""),
            "desktop_id": (app or {}).get("id", ""), "source": HYPR_AUTOSTART, "state": "Hyprland autostart",
        })
    return items


def list_login_items():
    index = DesktopIndex()
    items = list_hypr_items(index) + list_autostart_items(index) + list_unit_items()
    return items


def _write_desktop(path, entries):
    body = "[Desktop Entry]\n" + "".join("%s=%s\n" % kv for kv in entries)
    atomic_write(path, body, 0o644)


def set_desktop_flag(path, key, value):
    """Set (or, with value None, remove) a key in the [Desktop Entry] group of an existing file; the rest stays as it was."""
    with open(path, encoding="utf8", errors="replace") as f:
        lines = f.read().split("\n")
    start = next((i for i, ln in enumerate(lines) if ln.strip() == "[Desktop Entry]"), None)
    if start is None:
        raise ValueError("no [Desktop Entry] group in %s" % path)
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("[")), len(lines))
    body = [ln for ln in lines[start + 1:end] if ln.partition("=")[0].strip() != key]
    while body and not body[-1].strip():
        body.pop()
    if value is not None:
        body.append("%s=%s" % (key, value))
    trailing = lines[end:] if end < len(lines) else [""]
    if end < len(lines):
        body.append("")
    atomic_write(path, "\n".join(lines[:start + 1] + body + trailing), 0o644)


def set_autostart_enabled(item, on):
    """Per-user switch for an XDG autostart entry. System files are never edited: a Hidden=true copy overrides them."""
    name = item["id"]
    upath = os.path.join(AUTOSTART_USER, name)
    if not on:
        if os.path.exists(upath):
            set_desktop_flag(upath, "Hidden", "true")
            set_desktop_flag(upath, "X-GNOME-Autostart-enabled", None)
        else:
            os.makedirs(AUTOSTART_USER, exist_ok=True)
            _write_desktop(upath, [("Type", "Application"), ("Name", item["name"]), ("Hidden", "true"), ("X-M5PRO-Override", "true")])
        return
    if not os.path.exists(upath):
        return
    d = parse_desktop(upath) or {}
    if d.get("X-M5PRO-Override") == "true" and not d.get("Exec"):
        os.unlink(upath)                       # pure override: removing it re-enables the system entry
        return
    set_desktop_flag(upath, "Hidden", None)
    if d.get("X-GNOME-Autostart-enabled", "").lower() == "false":
        set_desktop_flag(upath, "X-GNOME-Autostart-enabled", "true")


def set_unit_enabled(item, on):
    name = item["id"]
    if on:
        target = name
        if item.get("source") and os.path.isabs(item["source"]) and not os.path.exists(os.path.join(UNIT_USER_DIR, name)):
            target = item["source"]            # a unit that was only linked from elsewhere: enable by path
        r = _systemctl("enable", target)
    else:
        r = _systemctl("disable", name)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip() or "systemctl failed")


def set_item_enabled(item, on):
    if item.get("locked"):
        raise PermissionError(item.get("lock_note") or "locked")
    if item["kind"] == "autostart":
        set_autostart_enabled(item, on)
    elif item["kind"] == "hypr":
        set_hypr_autostart(item["id"], on)
    elif item["kind"] == "unit":
        set_unit_enabled(item, on)


def add_login_app(app):
    """Make an installed application open at login: a user autostart entry (app: dict from DesktopIndex)."""
    os.makedirs(AUTOSTART_USER, exist_ok=True)
    name = app["id"] + ".desktop"
    path = os.path.join(AUTOSTART_USER, name)
    for d in AUTOSTART_SYSTEM:
        if os.path.exists(os.path.join(d, name)):
            if os.path.exists(path):
                os.unlink(path)
            return name
    entries = [("Type", "Application"), ("Name", app["name"]), ("Exec", " ".join(shlex.quote(a) for a in exec_argv(app["exec"]))),
               ("X-GNOME-Autostart-enabled", "true"), ("X-M5PRO-Added", "true")]
    if app.get("icon"):
        entries.append(("Icon", app["icon"]))
    if app.get("wmclass"):
        entries.append(("StartupWMClass", app["wmclass"]))
    _write_desktop(path, entries)
    return name


def remove_login_app(item):
    if item["kind"] == "autostart" and item.get("added_here"):
        os.unlink(os.path.join(AUTOSTART_USER, item["id"]))


def login_matchers():
    """What the enabled login items start, so the restorer does not launch the same apps twice."""
    out = []
    for it in list_hypr_items() + list_autostart_items():
        if not it["enabled"] or it["category"] == "Background" and it["kind"] == "autostart" and not it.get("wmclass"):
            continue
        exe = ""
        try:
            argv = exec_argv(it["exec"]) if it["kind"] == "autostart" else shlex.split(it["exec"])
            exe = os.path.basename(argv[0]) if argv else ""
        except ValueError:
            pass
        out.append({"desktop_id": it.get("desktop_id", ""), "wmclass": (it.get("wmclass") or "").lower(), "exe": exe})
    return out


# ----------------------------------------------------------------------------- restore plan

def group_matches_login_item(group, matchers):
    cls = {c.lower() for c in group["classes"]}
    exe = os.path.basename(group["cmd"][0]) if group.get("cmd") else ""
    for m in matchers:
        if m["desktop_id"] and m["desktop_id"] == group.get("desktop"):
            return True
        if m["wmclass"] and m["wmclass"] in cls:
            return True
        if m["desktop_id"] and m["desktop_id"].lower() in cls:
            return True
        if m["exe"] and exe and m["exe"] == exe:
            return True
    return False


def window_order_key(w):
    ws = w["workspace"]
    return (ws["id"] if isinstance(ws["id"], int) else 0, w["at"][0], w["at"][1])


def exclude_key(w):
    """What the per-app exclude switch is keyed on: the window class for apps, the agent for agent terminals."""
    if w.get("kind") == "terminal":
        ag = w.get("agent")
        return "agent:%s" % ag["kind"] if ag else "terminal:shell"
    return w["class"].lower()


def terminal_key(w):
    ag = w.get("agent")
    if ag and ag.get("session_id"):
        return ("agent", ag["kind"], ag["session_id"])
    return ("shell", w.get("cwd") or HOME) if not ag else ("agent", ag["kind"], None, w.get("cwd"))


def build_plan(snap, live, cfg, matchers, adopt=False):
    """Pure: what to launch and what to skip. live is a snapshot of the current windows."""
    excluded = {c.lower() for c in cfg.get("excluded", [])}
    live_classes = collections.Counter(w["class"].lower() for w in live["windows"] if w["kind"] == "app")
    live_term = collections.Counter(terminal_key(w) for w in live["windows"] if w["kind"] == "terminal")
    groups, by_key = [], {}
    for w in sorted(snap["windows"], key=window_order_key):
        cls = w["class"].lower()
        if cls in IGNORE_CLASSES:
            continue
        if is_vm_window(w):          # also drops VM windows from state saved before this rule existed
            continue
        if exclude_key(w) in excluded or (w["kind"] == "app" and (w.get("initialClass") or "").lower() in excluded):
            groups.append({"status": "skip", "reason": "excluded", "windows": [w], "classes": [w["class"]], "kind": w["kind"]})
            continue
        if w["kind"] == "terminal":
            k = terminal_key(w)
            g = {"kind": "terminal", "windows": [w], "classes": [w["class"]], "status": "launch", "reason": ""}
            if live_term[k] > 0:
                live_term[k] -= 1
                g["status"], g["reason"] = "skip", "already open"
            groups.append(g)
            continue
        if not w.get("cmd"):
            groups.append({"status": "skip", "reason": "no launch command known", "windows": [w], "classes": [w["class"]], "kind": "app"})
            continue
        key = (w["pid"], tuple(w["cmd"]))
        g = by_key.get(key)
        if g:
            g["windows"].append(w)
            g["classes"] = sorted(set(g["classes"]) | {w["class"]})
            continue
        g = {"kind": "app", "windows": [w], "classes": [w["class"]], "cmd": w["cmd"], "cmd_source": w.get("cmd_source"),
             "desktop": w.get("desktop"), "cwd": w.get("cwd"), "status": "launch", "reason": ""}
        by_key[key] = g
        groups.append(g)
    for g in groups:
        if g["status"] != "launch" or g["kind"] != "app":
            continue
        if group_matches_login_item(g, matchers):
            g["status"], g["reason"] = "login-item", "a login item starts it"
        elif any(live_classes[c.lower()] > 0 for c in g["classes"]):
            g["status"], g["reason"] = "running", "already running"
            g["adopt"] = adopt
    # one launch per (command) when several saved processes share a single-instance command is left to the app itself
    groups.sort(key=lambda g: window_order_key(g["windows"][0]))
    return groups


def plan_summary(groups):
    c = collections.Counter()
    for g in groups:
        c[g["status"]] += 1
        c["windows"] += len(g["windows"])
        if g["kind"] == "terminal":
            c["terminals"] += 1
            ag = g["windows"][0].get("agent")
            if ag and g["status"] == "launch":
                c["agents"] += 1
                if ag.get("exact"):
                    c["agents_exact"] += 1
    return dict(c)


def group_command(g):
    """The command line string that opens a group, and the workspace it opens on."""
    w = g["windows"][0]
    if g["kind"] == "terminal":
        ag = w.get("agent")
        inner = shlex.join(resume_argv(ag)) if ag else (shlex.join(w["run"]) if w.get("run") else None)
        cwd = (ag or {}).get("cwd") or w.get("cwd")
        return shlex.join(terminal_argv(w.get("terminal") or "alacritty", cwd, inner, w.get("term_class")))
    cmd = shlex.join(g["cmd"])
    if g.get("cmd_source") == "proc" and g.get("cwd") and os.path.isdir(g["cwd"]):
        return "cd %s && exec %s" % (shlex.quote(g["cwd"]), cmd)
    return cmd


class Restorer:
    def __init__(self, snap, cfg, matchers, dry_run=False, adopt=False, log=print):
        self.snap, self.cfg, self.matchers = snap, cfg, matchers
        self.dry, self.adopt, self.log = dry_run, adopt, log
        self.assigned = set()          # saved window addresses already matched
        self.seen = set()              # live window addresses ignored or handled
        self.stats = collections.Counter()
        self.eligible = []             # saved windows new live windows may be matched to
        self.events = None

    # -- live state
    def live(self):
        return collect_snapshot()

    def clients(self):
        return [c for c in hyprctl_json("clients") if c.get("mapped") and c.get("class")]

    def pump(self, done, timeout):
        """Wait for new windows (openwindow events, polled as a safety net) and place them until done() or timeout."""
        end = time.time() + timeout
        while True:
            self.scan()
            if done():
                return True
            if time.time() >= end:
                return False
            self.events.wait(0.5)

    def scan(self):
        for c in self.clients():
            if c["address"] in self.seen:
                continue
            self.seen.add(c["address"])
            self.place_new(c)

    def match(self, c):
        cls = {c.get("class", "").lower(), c.get("initialClass", "").lower()}
        cands = [w for w in self.eligible if w["address"] not in self.assigned and
                 ({w["class"].lower(), (w.get("initialClass") or "").lower()} & cls - {""})]
        if not cands:
            return None
        title = c.get("title", "").lower()
        for w in cands:
            if w["title"].lower() == title:
                return w
        for w in cands:
            if title and (w["title"].lower() in title or title in w["title"].lower()):
                return w
        return cands[0]

    def place_new(self, c):
        saved = self.match(c)
        if not saved:
            return
        self.assigned.add(saved["address"])
        self.place(c, saved)

    def place(self, c, saved):
        ws = saved["workspace"]
        if (c["workspace"]["name"] != ws["name"]):
            ok, out = move_window(c["address"], ws)
            if not ok:
                self.log("  move failed: %s" % out)
        if saved["floating"] != bool(c.get("floating")):
            hypr_dispatch("hl.dsp.window.float({ action = %s, window = %s })" % (lua_q("on" if saved["floating"] else "off"), lua_q("address:" + c["address"])))
        if saved["floating"]:
            hypr_dispatch("hl.dsp.window.resize({ x = %d, y = %d, window = %s })" % (saved["size"][0], saved["size"][1], lua_q("address:" + c["address"])))
            hypr_dispatch("hl.dsp.window.move({ x = %d, y = %d, window = %s })" % (saved["at"][0], saved["at"][1], lua_q("address:" + c["address"])))
        if saved.get("fullscreen"):
            mode = "fullscreen" if saved["fullscreen"] == 2 else "maximized"
            hypr_dispatch("hl.dsp.window.fullscreen({ mode = %s, action = %s, window = %s })" % (lua_q(mode), lua_q("set"), lua_q("address:" + c["address"])))
        self.stats["placed"] += 1

    # -- run
    def run(self, groups):
        todo = [g for g in groups if g["status"] == "launch"]
        waiting = [g for g in groups if g["status"] == "login-item" or (g["status"] == "running" and g.get("adopt"))]
        if self.dry:
            return
        self.events = EventStream()
        try:
            self.eligible = [w for g in waiting for w in g["windows"]]
            live = self.clients()
            self.seen = {c["address"] for c in live}
            if self.adopt:           # at login, windows a login item already opened are put on their saved workspaces
                self.seen = {c["address"] for c in live if not self.match(c)}
            for g in todo:
                self.launch(g)
            want = [w for g in groups if g["status"] == "launch" or g in waiting for w in g["windows"]]
            # at login, slow-starting login-item apps (Electron) get up to 150 s to show their window
            self.pump(lambda: all(w["address"] in self.assigned for w in want), 150 if self.adopt else 15)
        finally:
            self.events.close()

    def launch(self, g):
        cmd = group_command(g)
        ws = g["windows"][0]["workspace"]
        mine = list(g["windows"])
        self.eligible += mine
        self.log("launch %s on workspace %s" % (g["classes"][0], ws["name"]))
        ok, out = exec_on_workspace(cmd, ws)
        if not ok:
            self.log("  exec failed: %s" % out)
            self.stats["failed"] += 1
            return
        self.stats["launched"] += 1
        first = 25 if g["kind"] == "app" else 20
        self.pump(lambda: any(w["address"] in self.assigned for w in mine), first)
        if g["kind"] == "app" and len(mine) > 1:        # multi-window apps (Chrome) open their own windows
            idle_end = time.time() + 10
            n = lambda: sum(1 for w in mine if w["address"] in self.assigned)
            last = n()
            while time.time() < idle_end and n() < len(mine):
                self.pump(lambda: n() > last, 1.5)
                if n() > last:
                    last = n()
                    idle_end = time.time() + 10
        if g["kind"] == "terminal":                       # a terminal's window is matched only while it is starting
            self.eligible = [w for w in self.eligible if w not in mine]
        self.stats["missing"] += sum(1 for w in mine if w["address"] not in self.assigned)


def wait_for_shell(timeout=90, log=print):
    """Wait for the compositor to answer and for the Omarchy shell (quickshell) to be up, then let it settle."""
    end = time.time() + timeout
    uid = os.getuid()
    while time.time() < end:
        try:
            hyprctl_json("monitors")
            r = subprocess.run(["pgrep", "-u", str(uid), "-f", "quickshell.*omarchy/shell"], capture_output=True)
            if r.returncode == 0:
                time.sleep(3)
                return True
        except Exception:
            pass
        time.sleep(1)
    log("shell did not show up in %ds; continuing" % timeout)
    return False


def describe_group(g):
    w = g["windows"][0]
    ws = w["workspace"]["name"]
    if g["kind"] == "terminal":
        ag = w.get("agent")
        what = "%s %s" % (ag["kind"], "session %s" % (ag["session_id"][:8] if ag.get("session_id") else "(latest in folder)")) if ag else "shell"
        return "ws %-3s terminal %-9s %s" % (ws, w.get("terminal") or w["class"], what)
    extra = " +%d window(s)" % (len(g["windows"]) - 1) if len(g["windows"]) > 1 else ""
    return "ws %-3s app      %-9s%s" % (ws, g["classes"][0][:30], extra)
