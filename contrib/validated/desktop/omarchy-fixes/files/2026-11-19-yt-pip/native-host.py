#!/usr/bin/env python3
"""Chrome native-messaging host for the yt-pip extension: get/set mini player settings."""
import json, os, struct, subprocess, sys

YT_PIP = os.path.expanduser("~/.local/bin/yt-pip")
KEYS = {"enabled", "auto", "autoClose", "mode", "workspace", "corner", "width", "opacity", "source"}


def read_msg():
    raw = sys.stdin.buffer.read(4)
    if len(raw) < 4:
        return None
    n = struct.unpack("=I", raw)[0]
    if n > 65536:
        return None
    return json.loads(sys.stdin.buffer.read(n))


def send(obj):
    data = json.dumps(obj).encode()
    sys.stdout.buffer.write(struct.pack("=I", len(data)) + data)
    sys.stdout.buffer.flush()


def snapshot():
    out = subprocess.run([YT_PIP, "status"], capture_output=True, text=True, timeout=5).stdout
    st = json.loads(out or "{}")
    return {"config": st.pop("config", {}), "state": st}


def main():
    msg = read_msg()
    if not isinstance(msg, dict):
        return
    try:
        if msg.get("cmd") == "set" and msg.get("key") in KEYS:
            v = msg.get("value")
            v = ("true" if v else "false") if isinstance(v, bool) else str(v)
            r = subprocess.run([YT_PIP, "set", msg["key"], v], capture_output=True, text=True, timeout=5)
            if r.returncode:
                return send({"error": r.stderr.strip() or "invalid setting"})
            if msg["key"] == "enabled" and v == "true":
                subprocess.Popen(["hyprctl", "eval", 'hl.dispatch(hl.dsp.exec_cmd("uwsm-app -- yt-pip daemon"))'],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        send(snapshot())
    except Exception as e:  # report, don't crash the extension's call
        send({"error": str(e)[:300]})


if __name__ == "__main__":
    main()
