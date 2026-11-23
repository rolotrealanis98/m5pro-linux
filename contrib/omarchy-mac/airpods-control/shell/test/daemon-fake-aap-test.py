#!/usr/bin/env python3
"""Exercise airpods-daemon against a fake AirPods (no Bluetooth needed): python3 -I daemon-fake-aap-test.py [PATH_TO_airpods-daemon]
Checks: state on connect, mode change confirmed, 'off' refused when disabled, conversation awareness, an event from the
AirPods (stem press) reaching a second client, no AirPods -> empty state, and that a non-AirPods device is never opened."""
import importlib.machinery, importlib.util, json, os, socket, sys, tempfile, threading, time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "files", "usr", "local", "bin", "airpods-daemon")
loader = importlib.machinery.SourceFileLoader("airpods_daemon", path)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("airpods_daemon", loader))
loader.exec_module(mod)
P, HDR = mod.P, mod.P.HDR

MAC = "AA:BB:CC:DD:EE:FF"
devices = [(MAC, "Rolo's AirPods Pro", "Rolo's AirPods Pro")]
opened = []
fake_end = {}


def batt(items):
    return HDR + bytes([0x04, 0x00, len(items)]) + b"".join(bytes([c, 1, lvl, st, 1]) for c, lvl, st in items)


def emit(sock, pkt):
    """A stream socketpair has no packet boundaries (the real L2CAP seqpacket has): space the packets out."""
    sock.sendall(pkt)
    time.sleep(0.08)


def fake_airpods(sock, off_allowed):
    emit(sock, batt([(4, 82, 2), (2, 80, 2), (8, 100, 1)]))
    emit(sock, HDR + bytes([0x06, 0x00, 0, 0]))
    emit(sock, HDR + bytes([0x09, 0x00, 0x0D, 2, 0, 0, 0]))
    emit(sock, HDR + bytes([0x09, 0x00, 0x34, 1 if off_allowed else 2, 0, 0, 0]))
    try:
        while True:
            d = sock.recv(64)
            if not d:
                return
            if len(d) >= 11 and d[:6] == HDR + bytes([0x09, 0x00]) and d[6] == 0x0D:
                emit(sock, HDR + bytes([0x09, 0x00, 0x0D, d[7], 0, 0, 0]))
    except OSError:
        return


def fake_connect(mac):
    opened.append(mac)
    a, b = socket.socketpair()
    fake_end[mac] = b
    threading.Thread(target=fake_airpods, args=(b, FLAGS["off_allowed"]), daemon=True).start()
    return a


FLAGS = {"off_allowed": True}
mod.list_connected = lambda: list(devices)
mod.connect_aap = fake_connect

tmp = tempfile.mkdtemp(prefix="airpods-daemon-test-", dir=os.environ.get("TMPDIR", None))
sockpath = os.path.join(tmp, "airpods-control.sock")
hub = mod.Hub(sockpath)
threading.Thread(target=hub.serve, daemon=True).start()
for _ in range(50):
    if os.path.exists(sockpath):
        break
    time.sleep(0.1)


class Client:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(sockpath)
        self.s.settimeout(0.2)
        self.buf = b""
        self.msgs = []

    def pump(self, secs):
        end = time.time() + secs
        while time.time() < end:
            try:
                d = self.s.recv(65536)
            except socket.timeout:
                continue
            self.buf += d
            while b"\n" in self.buf:
                l, self.buf = self.buf.split(b"\n", 1)
                self.msgs.append(json.loads(l))

    def wait(self, pred, secs=6):
        end = time.time() + secs
        while time.time() < end:
            for m in self.msgs:
                if pred(m):
                    return m
            self.pump(0.2)
        raise AssertionError("timeout waiting; last messages: %r" % self.msgs[-3:])

    def send(self, o):
        self.s.sendall((json.dumps(o) + "\n").encode())


def ok(cond, what):
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        sys.exit(1)


assert oct(os.stat(sockpath).st_mode & 0o777) == "0o600", "socket mode"
c1 = Client()
st = c1.wait(lambda m: m.get("event") == "state" and m["devices"].get(MAC, {}).get("mode") == "anc" and m["devices"][MAC]["battery"].get("case") and m["devices"][MAC]["off_allowed"] is not None)
d = st["devices"][MAC]
ok(d["aap"] and d["model"] == "pro" and d["modes"] == ["off", "transparency", "adaptive", "anc"], "state: pro model, four modes, AAP open")
ok(d["battery"]["left"]["level"] == 82 and d["battery"]["right"]["level"] == 80 and d["battery"]["case"]["status"] == "charging", "state: left, right, case battery")
ok(d["ear"] == ["in-ear", "in-ear"] and d["off_allowed"] is True, "state: ear detection and off_allowed")

c1.send({"cmd": "mode", "address": MAC, "value": "transparency", "id": 7})
r = c1.wait(lambda m: m.get("event") == "result" and m["id"] == 7)
ok(r["ok"], "mode transparency confirmed by the AirPods")
c1.wait(lambda m: m.get("event") == "state" and m["devices"][MAC]["mode"] == "transparency")
ok(True, "state pushed with the new mode")

c1.send({"cmd": "mode", "value": "adaptive", "id": 8})  # no address: single device
ok(c1.wait(lambda m: m.get("event") == "result" and m["id"] == 8)["ok"], "address may be left out with one AirPods")

c1.send({"cmd": "mode", "address": MAC, "value": "bogus", "id": 9})
r = c1.wait(lambda m: m.get("event") == "result" and m["id"] == 9)
ok(not r["ok"] and "not available" in r["error"], "unknown mode refused")

c1.send({"cmd": "ca", "address": MAC, "value": False, "id": 10})
ok(c1.wait(lambda m: m.get("event") == "result" and m["id"] == 10)["ok"], "conversation awareness accepted")
c1.wait(lambda m: m.get("event") == "state" and m["devices"][MAC]["conversation_awareness"] is False)
ok(True, "conversation awareness in state")

c2 = Client()
c2.wait(lambda m: m.get("event") == "state" and m["devices"][MAC]["mode"] == "adaptive")
ok(True, "second client gets the current state on connect")
emit(fake_end[MAC], HDR + bytes([0x09, 0x00, 0x0D, 2, 0, 0, 0]))  # stem press on the AirPods
c2.wait(lambda m: m.get("event") == "state" and m["devices"][MAC]["mode"] == "anc")
c1.wait(lambda m: m.get("event") == "state" and m["devices"][MAC]["mode"] == "anc")
ok(True, "a mode change made on the AirPods reaches every client")

emit(fake_end[MAC], HDR + bytes([0x09, 0x00, 0x34, 2, 0, 0, 0]))
c1.wait(lambda m: m.get("event") == "state" and m["devices"][MAC]["off_allowed"] is False)
c1.send({"cmd": "mode", "address": MAC, "value": "off", "id": 11})
r = c1.wait(lambda m: m.get("event") == "result" and m["id"] == 11)
ok(not r["ok"] and "disabled" in r["error"], "'off' refused with a clear message when the AirPods disabled it")

# the CLI goes through the daemon instead of opening a second AAP connection
import subprocess
MODE_BIN = os.path.join(os.path.dirname(os.path.realpath(path)), "airpods-mode")
env = dict(os.environ, XDG_RUNTIME_DIR=tmp)
def cli(*args):
    return subprocess.run([sys.executable, "-I", MODE_BIN, *args], capture_output=True, text=True, env=env, timeout=20)
r = cli("transparency")
ok(r.returncode == 0 and r.stdout.strip() == "transparency", "airpods-mode transparency via the daemon (rc %d: %s%s)" % (r.returncode, r.stdout.strip(), r.stderr.strip()))
r = cli("status")
ok(r.returncode == 0 and "mode: transparency" in r.stdout and "battery case: 100%" in r.stdout, "airpods-mode status via the daemon")
r = cli("status", "--waybar")
ok(r.returncode == 0 and json.loads(r.stdout)["class"] == "transparency", "airpods-mode status --waybar via the daemon")
r = cli("ca", "on")
ok(r.returncode == 0, "airpods-mode ca on via the daemon")

# disconnect the AirPods in BlueZ: device leaves the state
devices.clear()
hub.sync_devices()
c1.wait(lambda m: m.get("event") == "state" and m["devices"] == {})
ok(True, "AirPods gone -> empty state")

# list_connected filters on the name: a headset that is not AirPods is never returned, so never opened
class R:
    def __init__(self, a):
        self.stdout = {"devices": "Device 11:22:33:44:55:66 WH-1000XM5\nDevice AA:BB:CC:DD:EE:01 Anna's AirPods Max\nDevice AA:BB:CC:DD:EE:02 My buds\nDevice 11:22:33:44:55:77 MX Master\n",
                       "info": "Device AA:BB:CC:DD:EE:02 (public)\n\tName: Bob's AirPods Pro\n\tAlias: My buds\n"}[a[0][1]] if a[0][1] == "devices" or a[0][2] == "AA:BB:CC:DD:EE:02" else "Device x\n\tName: Something Else\n"
real_run = mod.subprocess.run
mod.subprocess.run = lambda *a, **k: R(a)
src = open(path).read()
ns = {}
exec(compile(src[src.index("def list_connected"):src.index("def model_of")], "x", "exec"), dict(mod.__dict__, subprocess=mod.subprocess), ns)
pods = ns["list_connected"]()
mod.subprocess.run = real_run
ok(pods == [("AA:BB:CC:DD:EE:01", "Anna's AirPods Max", "Anna's AirPods Max"), ("AA:BB:CC:DD:EE:02", "My buds", "Bob's AirPods Pro")], "only AirPods are picked, including a renamed pair (BlueZ Name)")
ok("11:22:33:44:55:66" not in opened, "a non-AirPods headset was never opened")
print("done")
hub.stop = True
