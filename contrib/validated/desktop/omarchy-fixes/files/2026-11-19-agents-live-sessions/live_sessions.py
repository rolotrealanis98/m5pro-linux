#!/usr/bin/env python3
"""Live coding-agent sessions for the My Agents panel.

  live_sessions.py list                     JSON: every busy/waiting session it can reach
  live_sessions.py read  <kind> <id>        JSON: the session's screen (Herdr) or recent conversation (local)
  live_sessions.py send  <kind> <id> <text> type a reply into the session and press Enter
  live_sessions.py keys  <kind> <id> <key>  press one key: enter, esc, up, down, 1..9, y, n
  live_sessions.py focus <kind> <id>        bring the session's terminal to the front

kind "local": a Claude Code CLI in a terminal window on this machine (id = its pid).
kind "herdr": a Herdr terminal here or on another machine (id = its hc address, like studio/t85).
kind "other": anything else cds lists (Claude Desktop, profiles); only cds can open those.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
REGISTRY = HOME + "/.claude/sessions/*.json"
PROJECTS = HOME + "/.claude/projects"
APPS = {"claude-code": "claude", "claude": "claude", "codex": "codex", "copilot": "copilot",
        "antigravity": "antigravity", "agy": "antigravity"}
STATE = {"working": "working", "busy": "working", "blocked": "waiting", "waiting": "waiting", "asking": "waiting"}
ADDRESS = re.compile(r"^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$")
KEYS = {"enter": "Return", "esc": "Escape", "up": "Up", "down": "Down", "tab": "Tab"}


def run(argv, timeout=10, stdin=None):
    try:
        done = subprocess.run(argv, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout if done.returncode == 0 else None


def clean(text, limit=200):
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", str(text or "")).strip()
    return text[:limit]


def age(ms):
    if not ms:
        return ""
    seconds = max(0, time.time() - ms / 1000)
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if seconds >= size:
            return "%d%s" % (seconds // size, unit)
    return "now"


def parents():
    table = run(["ps", "-axo", "pid=,ppid=,comm="], timeout=5) or ""
    out = {}
    for line in table.splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2:
            out[int(parts[0])] = (int(parts[1]), parts[2] if len(parts) > 2 else "")
    return out


def windows():
    raw = run(["hyprctl", "clients", "-j"], timeout=5)
    try:
        return {c["pid"]: c for c in json.loads(raw or "[]")}
    except ValueError:
        return {}


def window_of(pid, tree, clients):
    """The Hyprland window whose process is an ancestor of pid, and whether a Herdr client sits in between."""
    herdr = False
    for _ in range(12):
        if pid in clients:
            return clients[pid], herdr
        entry = tree.get(pid)
        if not entry:
            return None, herdr
        if entry[1] in ("herdr", "hc"):
            herdr = True
        pid = entry[0]
    return None, herdr


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def local_sessions():
    tree, clients, out = parents(), windows(), []
    for path in glob.glob(REGISTRY):
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or data.get("kind") != "interactive" or not alive(data.get("pid")):
            continue
        state = STATE.get(str(data.get("status", "")).lower())
        if not state:
            continue
        win, in_herdr = window_of(int(data["pid"]), tree, clients)
        if in_herdr:
            continue  # the Herdr listing has it, with a readable screen
        cwd = data.get("cwd") or ""
        out.append({
            "kind": "local", "id": str(data["pid"]), "machine": "here", "provider": "claude",
            "title": re.sub(r"^[^\w]+", "", clean(win.get("title") if win else "", 80)) or clean(data.get("name"), 80) or "Claude Code",
            "name": clean(data.get("name"), 40), "state": state, "waitingFor": clean(data.get("waitingFor"), 80),
            "age": age(data.get("statusUpdatedAt") or data.get("updatedAt")), "where": os.path.basename(cwd.rstrip("/")) or "~",
            "window": win.get("address") if win else "", "workspace": (win.get("workspace") or {}).get("name", "") if win else "",
            "sessionId": clean(data.get("sessionId"), 64), "interactive": True,
        })
    return out


def herdr_sessions():
    if not shutil.which("hc"):
        return []
    try:
        payload = json.loads(run(["hc", "ls", "--json"], timeout=8) or "{}")
    except ValueError:
        return []
    terminals = payload if isinstance(payload, list) else payload.get("terminals", [])
    out = []
    for t in terminals:
        address = t.get("address", "")
        if t.get("state") != "live" or t.get("agent") not in APPS or not ADDRESS.match(address):
            continue
        state = STATE.get(str(t.get("status", "")).lower())
        if not state:
            continue
        detail = {}
        try:
            detail = json.loads(run(["hc", "get", address, "--json"], timeout=5) or "{}")
            detail = detail.get("terminal", detail)
        except ValueError:
            pass
        title = clean(detail.get("name"), 80) or clean(detail.get("title"), 80) or t["agent"]
        records = detail.get("records") or {}
        for rec in records.values():
            if isinstance(rec, dict) and rec.get("title"):
                title = clean(rec["title"], 80)
        cwd = t.get("cwd") or ""
        out.append({
            "kind": "herdr", "id": address, "machine": address.split("/", 1)[0] if "/" in address else "here",
            "provider": APPS[t["agent"]], "title": title, "name": clean(t.get("where"), 40), "state": state,
            "waitingFor": clean(((detail.get("status") or {}) if isinstance(detail.get("status"), dict) else {}).get("msg"), 80),
            "age": age(detail.get("status_ms")), "where": os.path.basename(cwd.rstrip("/")) or "~",
            "window": "", "workspace": "", "sessionId": "", "interactive": True,
            "terminalTitle": clean(detail.get("title"), 80),
        })
    return out


LIST_RE = re.compile(r"^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.*?)\s+\[([^\]]*)\]\s*$")


def other_sessions():
    """Busy or waiting sessions cds sees that aren't a local CLI or a Herdr terminal (Desktop, profiles)."""
    if not shutil.which("cds"):
        return []
    out = []
    for line in (run(["cds", "--list"], timeout=40) or "").splitlines():
        m = LIST_RE.match(line)
        if not m or m.group(2) in ("CLI", "Herdr"):
            continue
        state = STATE.get(m.group(4).lower())
        if not state:
            continue
        out.append({
            "kind": "other", "id": json.dumps({"machine": m.group(1), "source": m.group(2), "title": m.group(6)}),
            "machine": clean(m.group(1), 24), "provider": clean(m.group(3), 24),
            "title": clean(m.group(6), 80), "name": clean(m.group(2), 24), "state": state, "waitingFor": "",
            "age": clean(m.group(5), 12), "where": clean(m.group(7), 40), "window": "", "workspace": "",
            "sessionId": "", "interactive": False,
        })
    return out


def cmd_list():
    herdr = herdr_sessions()
    seen = {(s["machine"], s["terminalTitle"]) for s in herdr if s.get("terminalTitle")}
    others = [s for s in other_sessions() if (s["machine"], s["title"]) not in seen]
    sessions = local_sessions() + herdr + others
    sessions.sort(key=lambda s: (s["state"] != "waiting", s["machine"] != "here", not s["interactive"]))
    print(json.dumps({"sessions": sessions[:60]}))


# ------------------------------------------------------------------ read

def text_of(content):
    if isinstance(content, str):
        return content
    parts = []
    for block in content or []:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text", ""))
    return "\n".join(parts)


def tool_line(block):
    name = block.get("name", "tool")
    args = block.get("input") or {}
    detail = args.get("command") or args.get("file_path") or args.get("pattern") or args.get("description") or args.get("prompt") or ""
    return "%s  %s" % (name, clean(str(detail).replace("\n", " "), 160))


def transcript(session_id):
    if not re.match(r"^[0-9a-f-]{36}$", session_id or ""):
        return None
    found = glob.glob(PROJECTS + "/*/" + session_id + ".jsonl")
    return found[0] if found else None


def conversation(path, limit=40):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        f.seek(max(0, size - (1 << 21)))
        lines = f.read().split(b"\n")
    if size > (1 << 21):
        lines = lines[1:]
    messages, pending = [], {}
    for raw in lines:
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        if entry.get("type") not in ("user", "assistant") or entry.get("isMeta") or entry.get("isSidechain"):
            continue
        content = (entry.get("message") or {}).get("content")
        if entry["type"] == "user":
            if isinstance(content, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        pending.pop(b.get("tool_use_id"), None)
                continue
            text = text_of(content).strip()
            command = re.search(r"<command-name>(.*?)</command-name>", text, re.S)
            if command:
                args = re.search(r"<command-args>(.*?)</command-args>", text, re.S)
                text = (command.group(1).strip() + " " + (args.group(1).strip() if args else "")).strip()
            if text and not text.startswith("<") and not text.startswith("Caveat:"):
                messages.append({"role": "user", "text": clean(text, 4000)})
        else:
            text = text_of(content).strip()
            if text:
                messages.append({"role": "assistant", "text": clean(text, 6000)})
            for b in content if isinstance(content, list) else []:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    messages.append({"role": "tool", "text": tool_line(b)})
                    pending[b.get("id")] = len(messages) - 1
    for index in pending.values():
        messages[index]["pending"] = True
    # A run of tool calls reads as one line: how many, and the last one.
    folded = []
    for m in messages:
        if m["role"] == "tool" and not m.get("pending") and folded and folded[-1]["role"] == "tools":
            folded[-1]["count"] += 1
            folded[-1]["text"] = m["text"]
        elif m["role"] == "tool" and not m.get("pending"):
            folded.append({"role": "tools", "count": 1, "text": m["text"]})
        else:
            folded.append(m)
    return folded[-limit:]


CDS_SNIPPET = r'''
import json as _j, sys as _s
_want = _j.loads(_s.argv[1])
_best = None
for _r in collect(False):
    if _r["source"] == _want["source"] and tidy(_r["title"])[:60] == _want["title"]:
        if _best is None or _r["activity"] > _best["activity"]:
            _best = _r
_j.dump({"found": bool(_best), "status": (_best or {}).get("status", ""), "messages": read_preview(_best) if _best else None}, _s.stdout)
'''


def cds_source():
    path = shutil.which("cds")
    if not path:
        return None
    with open(os.path.realpath(path)) as f:
        source = f.read()
    source = re.sub(r"(?ms)^# <local-scenes>$.*?^# </local-scenes>$\n?", "", source)
    return source.replace('if __name__ == "__main__":\n    main()', CDS_SNIPPET)


def read_other(ident):
    """A Desktop or profile session's recent conversation, through cds's own reader, on whichever machine has it."""
    try:
        want = json.loads(ident)
    except ValueError:
        return {"error": "Unknown session."}
    source = cds_source()
    if not source:
        return {"error": "cds isn't installed."}
    if want.get("machine") == "here":
        raw = run(["python3", "-", ident], timeout=30, stdin=source)
    else:
        raw = run(["hc", "exec", "--on", want.get("machine", ""), "--timeout", "25", "-i", "python3", "-", ident], timeout=35, stdin=source)
    try:
        data = json.loads(raw or "")
    except ValueError:
        return {"error": "Couldn't reach %s." % want.get("machine")}
    if not data.get("found"):
        return {"error": "That session isn't listed any more."}
    messages = []
    for m in data.get("messages") or []:
        text = str(m.get("text") or "").strip()
        if text.startswith("<"):
            inner = re.findall(r"<message[^>]*>(.*?)</message>", text, re.S)
            if not inner:
                continue  # task notifications and other injected context
            text = inner[-1].strip()
        messages.append({"role": m.get("role", "assistant"), "text": clean(text, 6000)})
    return {"mode": "chat", "messages": messages, "state": STATE.get(str(data.get("status", "")).lower(), "idle"), "waitingFor": ""}


def cmd_read(kind, ident):
    if kind == "other":
        print(json.dumps(read_other(ident)))
        return
    if kind == "herdr" and ADDRESS.match(ident):
        screen = run(["hc", "read", ident], timeout=10)
        if screen is None:
            print(json.dumps({"error": "Couldn't read %s." % ident}))
            return
        lines = [re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", l) for l in screen.splitlines()[-400:]]
        print(json.dumps({"mode": "screen", "text": "\n".join(lines)}))
        return
    if kind == "local":
        for path in glob.glob(REGISTRY):
            try:
                with open(path) as f:
                    data = json.load(f)
            except (OSError, ValueError):
                continue
            if str(data.get("pid")) == ident:
                found = transcript(data.get("sessionId"))
                print(json.dumps({"mode": "chat", "messages": conversation(found) if found else [],
                                  "state": STATE.get(str(data.get("status", "")).lower(), "idle"),
                                  "waitingFor": clean(data.get("waitingFor"), 120)}))
                return
    print(json.dumps({"error": "That session has ended."}))


# --------------------------------------------------------- send and focus

def local_window(ident):
    if not ident.isdigit() or not alive(ident):
        return None
    win, _ = window_of(int(ident), parents(), windows())
    return win


def focus_window(address):
    if not re.match(r"^0x[0-9a-f]+$", address or ""):
        return False
    ok = run(["hyprctl", "dispatch", 'hl.dsp.focus({ window = "address:%s" })' % address], timeout=5)
    if ok is None or "error" in ok.lower():
        run(["hyprctl", "dispatch", "focuswindow", "address:" + address], timeout=5)
    return True


def type_into(ident, text=None, key=None):
    win = local_window(ident)
    if not win or not shutil.which("wtype"):
        return False
    focus_window(win["address"])
    time.sleep(0.4)  # let the shell's popup let go of the keyboard and the window take focus
    if text is not None:
        subprocess.run(["wtype", "--", text], timeout=10)
        time.sleep(0.05)
        subprocess.run(["wtype", "-k", "Return"], timeout=5)
    elif key:
        if key in KEYS:
            subprocess.run(["wtype", "-k", KEYS[key]], timeout=5)
        else:
            subprocess.run(["wtype", "--", key], timeout=5)
    return True


def cmd_send(kind, ident, text):
    text = text.replace("\r", "").strip()
    if not text:
        return 1
    if kind == "herdr" and ADDRESS.match(ident):
        return 0 if run(["hc", "send", ident, text], timeout=15) is not None else 1
    if kind == "local":
        return 0 if type_into(ident, text=text) else 1
    return 1


def cmd_keys(kind, ident, key):
    if not re.match(r"^(enter|esc|up|down|tab|[0-9yn])$", key):
        return 1
    if kind == "herdr" and ADDRESS.match(ident):
        return 0 if run(["hc", "keys", ident, key], timeout=10) is not None else 1
    if kind == "local":
        return 0 if type_into(ident, key=key) else 1
    return 1


def cmd_focus(kind, ident):
    if kind == "other":
        try:
            source = json.loads(ident).get("source")
        except ValueError:
            return 1
        if source != "Desktop":
            return 1
        # Claude Desktop's window, wherever it is; started (still without GPU, see chromium-flags) if it isn't running.
        subprocess.Popen(["omarchy-launch-or-focus", "com.anthropic.Claude", "uwsm-app -- claude-desktop --disable-gpu"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return 0
    if kind == "local":
        win = local_window(ident)
        return 0 if win and focus_window(win["address"]) else 1
    if kind == "herdr" and ADDRESS.match(ident):
        # Attach in a terminal of its own; a second press focuses that window.
        app_id = "herdr-" + re.sub(r"[^A-Za-z0-9]", "-", ident)
        subprocess.Popen(["omarchy-launch-or-focus-tui", "--app-id=" + app_id, "hc", "attach", ident],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return 0
    return 1


def main(argv):
    if not argv or argv[0] == "list":
        cmd_list()
        return 0
    if len(argv) >= 3 and argv[0] == "read":
        cmd_read(argv[1], argv[2])
        return 0
    if len(argv) >= 4 and argv[0] == "send":
        return cmd_send(argv[1], argv[2], argv[3])
    if len(argv) >= 4 and argv[0] == "keys":
        return cmd_keys(argv[1], argv[2], argv[3])
    if len(argv) >= 3 and argv[0] == "focus":
        return cmd_focus(argv[1], argv[2])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
