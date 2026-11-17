import base64, json, os, socket, sys, time, urllib.request
# cdpshot.py PORT OUT.png [N] : Page.captureScreenshot of the first page target, N shots 1 s apart (stdlib websocket)
port, out = int(sys.argv[1]), sys.argv[2]; n = int(sys.argv[3]) if len(sys.argv) > 3 else 1
tg = None
for _ in range(40):
    try:
        tg = [t for t in json.load(urllib.request.urlopen("http://127.0.0.1:%d/json" % port)) if t.get("type") == "page"]
        if tg: break
    except Exception: pass
    time.sleep(0.25)
url = tg[0]["webSocketDebuggerUrl"]; path = url.split(str(port), 1)[1]
s = socket.create_connection(("127.0.0.1", port))
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (path, port, key)).encode())
buf = b""
while b"\r\n\r\n" not in buf: buf += s.recv(4096)
buf = buf.split(b"\r\n\r\n", 1)[1]
def send(obj):
    p = json.dumps(obj).encode(); m = os.urandom(4); h = bytearray([0x81])
    if len(p) < 126: h.append(0x80 | len(p))
    elif len(p) < 65536: h.append(0x80 | 126); h += len(p).to_bytes(2, "big")
    else: h.append(0x80 | 127); h += len(p).to_bytes(8, "big")
    s.sendall(bytes(h) + m + bytes(b ^ m[i % 4] for i, b in enumerate(p)))
def need(k):
    global buf
    while len(buf) < k:
        d = s.recv(1 << 20)
        if not d: raise EOFError
        buf += d
def recv():
    global buf
    msg = b""
    while True:
        need(2); b0, b1 = buf[0], buf[1]; ln = b1 & 0x7f; o = 2
        if ln == 126: need(4); ln = int.from_bytes(buf[2:4], "big"); o = 4
        elif ln == 127: need(10); ln = int.from_bytes(buf[2:10], "big"); o = 10
        need(o + ln); msg += buf[o:o + ln]; buf = buf[o + ln:]
        if b0 & 0x80: return json.loads(msg)
i = 0
for k in range(n):
    i += 1; send({"id": i, "method": "Page.captureScreenshot", "params": {"format": "png"}})
    while True:
        r = recv()
        if r.get("id") == i: break
    if "result" in r:
        open(out.replace(".png", "-%d.png" % k), "wb").write(base64.b64decode(r["result"]["data"]))
    else:
        print("error", r); break
    time.sleep(1)
print("ok", n)
