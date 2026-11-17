#!/usr/bin/env python3
"""Minimal Chrome DevTools client (stdlib only) for the GPU A/B: waits for bench.html to finish, reads its results,
then reads chrome://gpu (feature status, GL/Vulkan/Skia lines) and closes the browser. Prints one JSON object.
usage: cdp.py PORT TIMEOUT_S"""
import base64, http.client, json, os, socket, struct, sys, time
from urllib.parse import urlparse

PORT, TIMEOUT = int(sys.argv[1]), float(sys.argv[2])


def http_json(path, method="GET"):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    c.request(method, path)
    return json.loads(c.getresponse().read())


class WS:
    def __init__(self, url):
        u = urlparse(url)
        self.s = socket.create_connection((u.hostname, u.port), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET {u.path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\nUpgrade: websocket\r\n"
                        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.s.recv(4096)
        if b" 101 " not in buf.split(b"\r\n")[0]:
            raise RuntimeError(buf[:200])
        self.rest = buf.split(b"\r\n\r\n", 1)[1]
        self.id = 0

    def _read(self, n):
        while len(self.rest) < n:
            d = self.s.recv(65536)
            if not d:
                raise EOFError
            self.rest += d
        out, self.rest = self.rest[:n], self.rest[n:]
        return out

    def recv(self):
        msg = b""
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            msg += self._read(n)
            if b0 & 0x80:
                return json.loads(msg)

    def call(self, method, **params):
        self.id += 1
        data = json.dumps({"id": self.id, "method": method, "params": params}).encode()
        mask = os.urandom(4)
        hdr = bytes([0x81])
        n = len(data)
        hdr += bytes([0x80 | n]) if n < 126 else (bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", n))
        self.s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))
        while True:
            m = self.recv()
            if m.get("id") == self.id:
                return m.get("result", m)


def evaluate(ws, expr):
    r = ws.call("Runtime.evaluate", expression=expr, returnByValue=True, awaitPromise=True)
    return r.get("result", {}).get("value")


out = {}
t0 = time.time()
while True:
    try:
        ver = http_json("/json/version")
        break
    except Exception:
        if time.time() - t0 > 20:
            print(json.dumps({"error": "no devtools endpoint"}))
            sys.exit(1)
        time.sleep(0.5)
page = None
while page is None and time.time() - t0 < 30:
    page = next((t for t in http_json("/json/list") if t.get("type") == "page" and "bench.html" in t.get("url", "")), None)
    time.sleep(0.5)
ws = WS(page["webSocketDebuggerUrl"])
while time.time() - t0 < TIMEOUT:
    if evaluate(ws, "window.__done === true"):
        break
    time.sleep(1)
out["bench"] = evaluate(ws, "JSON.stringify(window.__results || {})")
out["bench"] = json.loads(out["bench"]) if out["bench"] else None
out["bench_done"] = bool(evaluate(ws, "window.__done === true"))

gpu = http_json("/json/new?chrome://gpu", method="PUT")
g = WS(gpu["webSocketDebuggerUrl"])
time.sleep(4)
txt = evaluate(g, "(() => { const v = document.querySelector('info-view'); const r = (v && v.shadowRoot) || document;"
                  " return [...r.querySelectorAll('li, tr')].map(e => e.textContent.replace(/\\s+/g, ' ').trim()).join('\\n'); })()") or ""
out["gpu_text_len"] = len(txt)
lines = [l.strip() for l in txt.replace("\t", " ").splitlines() if l.strip()]
keep = ("Canvas", "Compositing", "Direct Rendering Display Compositor", "Multiple Raster Threads", "OpenGL", "Rasterization",
        "Raw Draw", "Skia Graphite", "Video Decode", "Video Encode", "Vulkan", "WebGL", "WebGPU", "WebNN", "GL_RENDERER",
        "GL_VERSION", "Skia Backend", "ANGLE", "Display type", "GL implementation", "vaInitialize", "Hardware accelerated",
        "Software only", "Disabled", "Enabled")
out["gpu"] = [l[:240] for l in lines if l.startswith(keep)][:80]
out["gpu_full"] = txt
try:
    WS(ver["webSocketDebuggerUrl"]).call("Browser.close")
except Exception:
    pass
print(json.dumps(out))
