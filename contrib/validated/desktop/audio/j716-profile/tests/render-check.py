#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Render J716 speaker graphs offline and check them, without a sound.

Each graph runs as a filter-chain client of a private PipeWire daemon that
loads no ALSA plugin, no device monitor and no session manager, in its own
runtime directory: nothing in it can reach the speakers or the user's audio
session. Generated signals play through the graph at the given sink volume;
its six outputs are recorded and measured.

Checks per graph:
  - it builds (every LV2 plugin and FIR loads);
  - channel map: left-only pink noise lands on AUX0/AUX2/AUX4 (LW1 LW2 LT)
    and right-only on AUX1/AUX3/AUX5 (RW1 RW2 RT), the other side 40 dB down;
  - crossover: a 200 Hz tone is 20 dB louder on the woofers than the
    tweeters, a 5 kHz tone 10 dB louder on the tweeters (the J316 FIRs
    overlap: about 16 dB at 5 kHz by design);
  - no output sample at or over full scale (the amps take integers).
It prints every output's RMS and peak, so two graphs can be level-matched.
A graph given with --ref (the bring-up graph: its woofers have no low-pass)
is measured and checked for clipping and channel map, not for crossover.

Run (as any user, on the machine with PipeWire and the LV2 plugins):
  python3 render-check.py [--volume 1.0] [--ref bringup.json] graph.json ...
"""
import array, json, math, os, random, re, shutil, struct, subprocess, sys, tempfile, time

RATE = 48000
failures = []


def wav_write(path, frames):
    data = array.array("f", [s for fr in frames for s in fr]).tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt "
                + struct.pack("<IHHIIHH", 16, 3, 2, RATE, RATE * 8, 8, 32)
                + b"data" + struct.pack("<I", len(data)) + data)


def wav_read(path):
    b = open(path, "rb").read()
    i, ch, data = 12, 1, b""
    while i + 8 <= len(b):
        cid, n = b[i:i + 4], struct.unpack("<I", b[i + 4:i + 8])[0]
        if cid == b"fmt ":
            ch = struct.unpack("<H", b[i + 10:i + 12])[0]
        if cid == b"data":
            data = b[i + 8:] if n in (0, 0xFFFFFFFF) or i + 8 + n > len(b) else b[i + 8:i + 8 + n]
            break
        i += 8 + n + (n & 1)
    a = array.array("f")
    a.frombytes(data[:len(data) // (4 * ch) * 4 * ch])
    return [a[c::ch] for c in range(ch)]


def pink(n, rng):
    b = [0.0] * 7
    out = []
    for _ in range(n):
        w = rng.gauss(0, 1)
        b[0] = 0.99886 * b[0] + w * 0.0555179
        b[1] = 0.99332 * b[1] + w * 0.0750759
        b[2] = 0.96900 * b[2] + w * 0.1538520
        b[3] = 0.86650 * b[3] + w * 0.3104856
        b[4] = 0.55000 * b[4] + w * 0.5329522
        b[5] = -0.7616 * b[5] - w * 0.0168980
        out.append(sum(b) + b[6] + w * 0.5362)
        b[6] = w * 0.115926
    return out


def at_rms(x, db):
    g = 10 ** (db / 20) / math.sqrt(sum(v * v for v in x) / len(x))
    return [max(-1.0, min(1.0, v * g)) for v in x]


def fade(x, n=int(0.02 * RATE)):
    for k in range(n):
        x[k] *= k / n
        x[-1 - k] *= k / n
    return x


def signals(d):
    rng = random.Random(7)
    n = 4 * RATE
    lead = [(0.0, 0.0)] * (RATE // 4)
    p = fade(at_rms(pink(n, rng), -18))
    sine = lambda f, db: fade([10 ** (db / 20) * math.sin(2 * math.pi * f * t / RATE) for t in range(n)])
    k = math.log(300 / 30)
    sweep = fade([0.708 * math.sin(2 * math.pi * 30 * 4 / k * (math.exp(t / RATE / 4 * k) - 1)) for t in range(n)])
    pl, pr = fade(at_rms(pink(n, rng), -12)), fade(at_rms(pink(n, rng), -12))
    sig = {
        "pinkL": [(v, 0.0) for v in p],
        "pinkR": [(0.0, v) for v in p],
        "tone200": [(v, v) for v in sine(200, -12)],
        "tone5k": [(v, v) for v in sine(5000, -12)],
        "pink12": list(zip(pl, pr)),
        "sweep": [(v, v) for v in sweep],
    }
    for name, fr in sig.items():
        wav_write(os.path.join(d, name + ".wav"), lead + fr)
    return list(sig)


def spa(v):
    """SPA JSON (key = value, no commas), the form PipeWire's config parser expects."""
    if isinstance(v, dict):
        return "{ " + " ".join("%s = %s" % (json.dumps(k), spa(x)) for k, x in v.items()) + " }"
    if isinstance(v, list):
        return "[ " + " ".join(spa(x) for x in v) + " ]"
    return json.dumps(v)


def spa_load(path):
    txt = "\n".join(l for l in open(path).read().split("\n") if not l.lstrip().startswith("#"))
    return json.loads(re.sub(r",(\s*[\]}])", r"\1", txt))


class Offline:
    def __init__(self, graph_path, top):
        self.d = tempfile.mkdtemp(prefix="g.", dir=top)
        g = spa_load(graph_path)
        self.n = int(g["playback.props"]["audio.channels"])
        libs = {"audio.convert.*": "audioconvert/libspa-audioconvert", "support.*": "support/libspa-support"}
        daemon = {
            "context.properties": {"core.daemon": True, "core.name": "pw-j716-check", "support.dbus": False,
                                   "default.clock.rate": RATE, "default.clock.allowed-rates": [RATE],
                                   "default.clock.quantum": 1024, "default.clock.min-quantum": 1024,
                                   "default.clock.max-quantum": 1024, "mem.allow-mlock": False},
            "context.spa-libs": libs,
            "context.modules": [{"name": "libpipewire-module-" + m} for m in
                                ("protocol-native", "client-node", "adapter", "link-factory",
                                 "spa-node-factory", "access", "metadata")],
            "context.objects": [{"factory": "spa-node-factory",
                                 "args": {"factory.name": "support.node.driver", "node.name": "Dummy-Driver",
                                          "node.group": "pipewire.dummy", "priority.driver": 20000}}],
        }
        args = {
            "node.description": "j716 render check", "media.name": "j716 render check",
            "remote.name": "pw-j716-check", "filter.graph": g["filter.graph"],
            "capture.props": {"node.name": "chk.in", "media.class": "Audio/Sink", "node.autoconnect": False,
                              "audio.channels": 2, "audio.position": ["FL", "FR"]},
            "playback.props": {"node.name": "chk.out", "node.autoconnect": False,
                               "audio.channels": self.n, "audio.position": ["AUX%d" % i for i in range(self.n)]},
        }
        client = {
            "context.properties": {"support.dbus": False, "remote.name": "pw-j716-check"},
            "context.spa-libs": libs,
            "context.modules": [{"name": "libpipewire-module-" + m} for m in ("protocol-native", "client-node", "adapter")]
                               + [{"name": "libpipewire-module-filter-chain", "args": args}],
        }
        for name, c in (("daemon.conf", daemon), ("filter.conf", client)):
            with open(os.path.join(self.d, name), "w") as f:
                f.write("\n".join("%s = %s" % (k, spa(v)) for k, v in c.items()) + "\n")
        self.env = dict(os.environ, XDG_RUNTIME_DIR=self.d, PIPEWIRE_RUNTIME_DIR=self.d, PIPEWIRE_REMOTE="pw-j716-check")
        self.env.pop("PIPEWIRE_CORE", None)
        self.log = open(os.path.join(self.d, "log"), "w")
        self.procs = [self.spawn(["pipewire", "-c", os.path.join(self.d, "daemon.conf")])]
        self.wait(lambda: os.path.exists(os.path.join(self.d, "pw-j716-check")), "daemon")
        self.procs.append(self.spawn(["pipewire", "-c", os.path.join(self.d, "filter.conf")]))
        self.wait(lambda: self.node("chk.in") and self.node("chk.out"), "filter nodes (graph failed to build?)")
        self.portcfg("chk.in", "Input", ["FL", "FR"])
        self.portcfg("chk.out", "Output", ["AUX%d" % i for i in range(self.n)])

    def spawn(self, cmd):
        return subprocess.Popen(cmd, env=self.env, stdout=self.log, stderr=self.log)

    def run(self, *cmd):
        return subprocess.run(cmd, env=self.env, capture_output=True, text=True, timeout=10).stdout

    def wait(self, cond, what, t=15.0):
        end = time.time() + t
        while time.time() < end:
            if cond():
                return
            time.sleep(0.05)
        raise RuntimeError("timed out waiting for " + what + "; log: " + open(os.path.join(self.d, "log")).read()[-2000:])

    def node(self, name):
        cur = None
        for line in self.run("pw-cli", "ls", "Node").split("\n"):
            m = re.match(r"\s*id (\d+),", line)
            if m:
                cur = m.group(1)
            if re.match(r'\s*node\.name = "%s"$' % re.escape(name), line):
                return cur
        return None

    def portcfg(self, name, direction, pos):
        fmt = {"mediaType": "audio", "mediaSubtype": "raw", "format": "F32P", "rate": RATE,
               "channels": len(pos), "position": pos}
        self.run("pw-cli", "s", self.node(name), "PortConfig",
                 json.dumps({"direction": direction, "mode": "dsp", "monitor": False, "format": fmt}))

    def volume(self, v):
        self.run("pw-cli", "s", self.node("chk.in"), "Props", json.dumps({"channelVolumes": [v, v]}))
        time.sleep(0.3)

    def ports(self, flag, node):
        def key(p):
            m = re.search(r"(\d+)$", p)
            return (re.sub(r"\d+$", "", p), int(m.group(1)) if m else -1)
        return sorted((p for p in self.run("pw-link", flag).split("\n") if p.startswith(node + ":")), key=key)

    def render(self, src, dst):
        aux = ",".join("AUX%d" % i for i in range(self.n))
        rec = self.spawn(["pw-record", "-P", "{ node.autoconnect = false node.name = chk.rec }",
                          "--rate", str(RATE), "--channels", str(self.n), "--channel-map", aux, "--format", "f32", dst])
        self.wait(lambda: self.node("chk.rec"), "recorder")
        self.portcfg("chk.rec", "Input", aux.split(","))
        play = self.spawn(["pw-play", "-P", "{ node.autoconnect = false node.name = chk.play }", src])
        self.wait(lambda: self.node("chk.play"), "player")
        self.portcfg("chk.play", "Output", ["FL", "FR"])
        self.wait(lambda: len(self.ports("-o", "chk.play")) == 2 and len(self.ports("-i", "chk.rec")) == self.n, "ports")
        for a, b in zip(self.ports("-o", "chk.out"), self.ports("-i", "chk.rec")):
            self.run("pw-link", a, b)
        for a, b in zip(self.ports("-o", "chk.play"), self.ports("-i", "chk.in")):
            self.run("pw-link", a, b)
        play.wait(timeout=60)
        time.sleep(0.6)
        rec.terminate()
        rec.wait(timeout=10)

    def close(self):
        for p in reversed(self.procs):
            p.terminate()
            p.wait(timeout=10)
        self.log.close()


def db(x):
    return 20 * math.log10(max(x, 1e-9))


def measure(path):
    out = []
    for x in wav_read(path):
        rms = math.sqrt(sum(v * v for v in x) / max(len(x), 1))
        pk = max((abs(v) for v in x), default=0.0)
        out.append((db(rms), db(pk), sum(1 for v in x if abs(v) >= 1.0)))
    return out


NAMES = ["LW1", "RW1", "LW2", "RW2", "LT", "RT"]


def label(path):
    return "/".join(os.path.abspath(path).split("/")[-2:])


def check_graph(path, vol, top, sigs, ref=False):
    name = label(path)
    off = Offline(path, top)
    res = {}
    try:
        off.volume(vol)
        for s in sigs:
            dst = os.path.join(off.d, s + ".out.wav")
            off.render(os.path.join(top, s + ".wav"), dst)
            res[s] = measure(dst)
    finally:
        off.close()
    print("== %s (sink volume %.2f linear)" % (name, vol))
    print("   %-8s " % "" + " ".join("%14s" % n for n in NAMES) + "   rms/peak dBFS, clipped")
    for s, m in res.items():
        print("   %-8s " % s + " ".join("%6.1f/%5.1f%s" % (r, p, "!" if c else " ") for r, p, c in m))
        clipped = sum(c for _, _, c in m)
        if clipped:
            failures.append("%s %s: %d clipped samples" % (name, s, clipped))
    r = lambda s, i: res[s][i][0]
    for s, own, other in (("pinkL", (0, 2, 4), (1, 3, 5)), ("pinkR", (1, 3, 5), (0, 2, 4))):
        for a, b in zip(own, other):
            if not (r(s, a) > -70 and r(s, a) - r(s, b) > 40):
                failures.append("%s %s: %s %.1f dB against %s %.1f dB" % (name, s, NAMES[a], r(s, a), NAMES[b], r(s, b)))
    w200 = max(r("tone200", i) for i in range(4)); t200 = max(r("tone200", i) for i in (4, 5))
    w5k = max(r("tone5k", i) for i in range(4)); t5k = max(r("tone5k", i) for i in (4, 5))
    print("   crossover: 200 Hz woofers-tweeters %+.1f dB, 5 kHz tweeters-woofers %+.1f dB" % (w200 - t200, t5k - w5k))
    if ref:
        return res
    if w200 - t200 < 20:
        failures.append("%s: 200 Hz only %.1f dB louder on the woofers" % (name, w200 - t200))
    if t5k - w5k < 10:
        failures.append("%s: 5 kHz only %.1f dB louder on the tweeters" % (name, t5k - w5k))
    return res


def main():
    argv = sys.argv[1:]
    vol, refs = 1.0, []
    if "--volume" in argv:
        i = argv.index("--volume")
        vol = float(argv[i + 1])
        del argv[i:i + 2]
    while "--ref" in argv:
        i = argv.index("--ref")
        refs.append(argv[i + 1])
        del argv[i:i + 2]
    argv = refs + argv
    for t in ("pipewire", "pw-cli", "pw-link", "pw-play", "pw-record"):
        if shutil.which(t) is None:
            print("needs " + t)
            return 77
    top = tempfile.mkdtemp(prefix="j716-render-check.")
    try:
        sigs = signals(top)
        results = {g: check_graph(g, vol, top, sigs, g in refs) for g in argv}
        if len(results) > 1:
            base = argv[0]
            for g in argv[1:]:
                d = [results[g]["pink12"][i][0] - results[base]["pink12"][i][0] for i in range(6)]
                print("pink -12 dBFS, %s minus %s per output: %s dB" % (
                    label(g), label(base), " ".join("%s %+.1f" % (NAMES[i], d[i]) for i in range(6))))
    finally:
        shutil.rmtree(top, ignore_errors=True)
    for f in failures:
        print("FAIL: " + f)
    print("ok" if not failures else "%d failures" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
