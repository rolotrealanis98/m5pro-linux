# SPDX-License-Identifier: MIT
# run_guest.py -m module: capture the GPU InitData that macOS 27.3 (26C5035r) hands the G17S GPU firmware on the
# J716s (T6050), for aurora-silicon/linux#1173. Pass it AFTER hv27-trace-late.py (same chaining rule as
# hv27-dcp-trace.py).
#
# What it does
#   * traces the mailbox page (reg0 + 0x8000, 0x4000) of each GPU ASC (/arm-io/gfx-asc, /arm-io/gfx1-asc), installed
#     late: at SPTM's first AMCC read (the from-start recipe of 2026-11-09; tracers armed before SPTM init panic the
#     first stage). Nothing else is trapped: the GPU, the UAT tables and the InitData memory are left alone.
#   * decodes every RTKit word (A2I +0x800/+0x808, I2A +0x830/+0x838): ep0 management, firmware endpoint 0x20
#     (type = msg0 >> 48: 0x81 INITDATA from the host, 0x09 its acknowledgement, 0x42 events), doorbell ep 0x21.
#     Every word goes to gpu-mbox.jsonl.
#   * when the host writes the INITDATA word (SYNC mode: the guest is stopped at that store, BEFORE the word reaches
#     the firmware), it reads the root the word points at and the objects the root reaches, by walking the GPU's UAT
#     page tables (TTBAT = ADT sgx gpu-region-base, context 0) in guest memory, and writes each object raw plus an
#     index. The firmware has not seen the graph yet, so the dump is exactly what macOS built. A second snapshot
#     is taken at the firmware's acknowledgement (tag "ack") unless HV27_GPU_ACKDUMP=0.
#   * raw dumps are the primary artifact; the console carries only a short decode of the words PR #1173 needs.
#     initdata-compare.py (tools/) turns a dump into the redacted public summary.
#
# Rules learned on this machine (TRACE-UNDER-SPTM*.md, DCP-TRACE-MODULE.md): proxy reads only from a SYNC/HOOK
# callback with the guest stopped (hv.ctx set), never from an ASYNC event; a proxy error latches "reads off" so a
# desynced channel is never poked again; every handler is wrapped; console lines are printable ASCII; single-core
# guest (cpus=1) for traced runs (a traced access on a secondary core deadlocked the multi-core guest).
#
# Environment (all optional)
#   HV27_GPU_OUT=dir          output directory (default <this dir>/../runs/gpu-<stamp>)
#   HV27_GPU_MODE=sync|async  mailbox tracer mode (default sync; async = words only, no dump)
#   HV27_GPU_ASCS=gfx-asc,gfx1-asc   ADT names below /arm-io
#   HV27_GPU_INSTALL=late|now late (default): arm on SPTM's first AMCC read
#   HV27_GPU_ACKDUMP=1        second snapshot at the INITDATA acknowledgement (default 1)
#   HV27_GPU_CRAWL=1          also dump every object the main configs' channel table points at (first 0x4000 each)
#   HV27_GPU_TTB1=0x...       force the L1 table of context 0's high half (if the TTBAT entry is not usable)
#   HV27_GPU_TTB0=0x...       same for the low half
#   HV27_GPU_CONSOLE_ALL=1    print every mailbox word (default: ep0 and ep 0x20 non-event words, the rest counted)
#
# Shell helpers (after Ctrl-C in the hypervisor shell, guest stopped):
#   gpu_status()                    counters, roots seen, dumps written
#   gpu_redump(asc=None, tag="manual")   read the last root of an ASC (or every ASC) again
#   gpu_walk(va)                    translate a GPU VA (context 0) and print the PA
#   gpu_dump_root(va[, asc])        dump the graph below a root VA found some other way
#   gpu_shot([name])                panel screenshot (PNG, private) to see where the guest is
import atexit, hashlib, json, os, re, struct, sys, time, traceback
from m1n1.utils import irange
from m1n1.hv import TraceMode

_GI_STAMP = time.strftime("%Y%m%d-%H%M%S")
_GI_BAD = re.compile(r"[^\x20-\x7e]")
_GI_HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()


def _gi_p(s=""):
    try:
        for ln in str(s).split("\n"):
            print("GPUINIT: " + _GI_BAD.sub(lambda m: "\\x%02x" % (ord(m.group(0)) & 0xff), ln))
    except Exception:
        pass


def _gi_env_int(name, default):
    v = os.environ.get(name, "").strip()
    if not v:
        return default
    try:
        return int(v, 0)
    except ValueError:
        _gi_p(f"bad {name}={v!r}, using {default}")
        return default


class _NoRead(Exception):
    pass


# ---------------------------------------------------------------------------------------------- graph layout
# M5 root (PR #1173 g17/fw/m5/initdata.rs: ROOT_*), main config (MAIN_*), and the sizes of the 27.2+ allocation size
# table (ABI_ALLOCATION_SIZES_26B123_M5). Dump sizes are the 27.2+ size plus slack, so a 27.0-sized object is covered
# too and the start of the next object (if macOS packs like the driver) is visible.
ROOT_READ = 0x100
ROOT_FIELDS = {"version": 0x00, "region_a": 0x08, "main_config": 0x18, "region_c": 0x20, "status_a": 0xa8,
               "status_b": 0xb0, "extra0": 0xb8, "extra1": 0xc0}
MAIN_SIZE = 0x600
MAIN_CHANNELS = (0x20, 17, 0x20)          # offset, entries, stride; 3 state pointers + ring pointer each
MAIN_BUNDLE_VIEWS = 0x254                 # 5 pointers (primary)
MAIN_REGION_VIEWS = 0x2d0                 # 5 words (primary)
MAIN_POLICY_PTR = 0x481                   # secondary main config, unaligned u64 (COMMON26_MAIN_SECONDARY_POLICY_PTR)
OBJ_READ = {                              # name -> bytes to read
    "root": ROOT_READ, "main_config": MAIN_SIZE + 0x40, "region_a": 0x4000, "region_c": 0x2000,
    "status_a": 0x100, "status_b": 0xef40, "status_config": 0x840, "secondary_extra_1": 0x100,
    "hw_data": 0x2c00, "policy": 0x12800, "view0": 0xc80, "view1": 0x1080, "view2": 0xe40, "view3": 0x80,
    "view4": 0x800,
}
INITDATA_ADDR_MASK = (1 << 44) - 1
INITDATA_ADDR_PREFIX = 0xffff_f000_0000_0000


def _va_of_msg(m0):
    va = m0 & INITDATA_ADDR_MASK
    if va & (1 << 43):
        va |= INITDATA_ADDR_PREFIX
    return va


def _looks_va(v):
    """A GPU VA of the kernel context: high half (top 20 bits set) or the low window used for aliases."""
    if v >> 44 == 0xfffff:
        return True
    return 0x10_0000_0000 <= v < (1 << 42)


class _GpuInit:
    MGMT = {1: "HELLO", 2: "HELLO_ACK", 5: "STARTEP", 6: "SET_IOP_PWR", 7: "IOP_PWR_ACK", 8: "EPMAP",
            0xb: "SET_AP_PWR", 0xf: "NMI"}
    EP_FW, EP_DOORBELL = 0x20, 0x21
    FWTYPES = {0x81: "INITDATA", 0x09: "INITDATA_ACK", 0x42: "EVENTS", 0x84: "CONTROL_NOTIFY", 0x89: "POWER_ON_DONE"}
    PAGE = 0x4000

    def __init__(self):
        self.t0 = time.monotonic()
        self.installed = False
        self.sync = True
        self.reads_dead = False
        self.out = os.path.abspath(os.path.expanduser(
            os.environ.get("HV27_GPU_OUT", os.path.join(_GI_HERE, "..", "runs", f"gpu-{_GI_STAMP}"))))
        self.ascs = {}               # mbox base -> {"name", "path", "in", "out"}
        self.roots = {}              # asc name -> last root VA
        self.dumps = []
        self.counts = {}
        self.errors = 0
        self.seq = 0
        self.console_all = os.environ.get("HV27_GPU_CONSOLE_ALL") == "1"
        self.ackdump = os.environ.get("HV27_GPU_ACKDUMP", "1") == "1"
        self.crawl = os.environ.get("HV27_GPU_CRAWL") == "1"
        self.ttbat = None
        self.forced_ttb = {1: _gi_env_int("HV27_GPU_TTB1", None), 0: _gi_env_int("HV27_GPU_TTB0", None)}
        self.shared_region = None
        self.tlb = {}
        self.uat_note = ""
        self.jf = None
        self.uat_saved = False
        try:
            os.makedirs(self.out, exist_ok=True)
            self.jf = open(os.path.join(self.out, "gpu-mbox.jsonl"), "a", buffering=1)
        except Exception as e:
            _gi_p(f"cannot open output {self.out}: {e}")
        _gi_p(f"output -> {self.out}")
        atexit.register(self.summary)

    # ------------------------------------------------------------------ output helpers
    def _t(self):
        return round(time.monotonic() - self.t0, 4)

    def _j(self, rec):
        if self.jf:
            try:
                self.jf.write(json.dumps(rec, separators=(",", ":")) + "\n")
            except Exception:
                self.jf = None

    def _err(self, what):
        self.errors += 1
        if self.errors <= 20:
            _gi_p(f"handler error in {what} (#{self.errors}):")
            _gi_p(traceback.format_exc())

    def summary(self):
        try:
            _gi_p(f"summary words={self.counts} errors={self.errors} reads_dead={self.reads_dead} "
                  f"roots={ {k: hex(v) for k, v in self.roots.items()} } dumps={len(self.dumps)}")
            for d in self.dumps:
                _gi_p(f"summary dump {d}")
            self._j({"summary": True, "counts": {str(k): v for k, v in self.counts.items()},
                     "errors": self.errors, "dumps": self.dumps})
        except Exception:
            pass

    # ------------------------------------------------------------------ install
    def _prop(self, node, key):
        for k in (key.replace("-", "_"), key):
            try:
                v = getattr(node, k)
                if v is not None:
                    return v
            except Exception:
                pass
        try:
            return node._properties.get(key)
        except Exception:
            return None

    def install(self):
        if self.installed:
            return
        self.installed = True
        try:
            sys.stdout.reconfigure(line_buffering=True)
        except Exception:
            pass
        want = os.environ.get("HV27_GPU_MODE", "sync").strip().lower()
        mode = TraceMode.ASYNC if want == "async" else TraceMode.SYNC
        self.sync = mode == TraceMode.SYNC
        sgx = hv.adt["/arm-io/sgx"]
        self.ttbat = self._prop(sgx, "gpu-region-base")
        self.shared_region = self._prop(sgx, "gfx-shared-region-base")
        self.handoff = self._prop(sgx, "gfx-handoff-base")
        _gi_p(f"sgx: TTBAT (gpu-region-base) {self.ttbat:#x}, gfx-shared-region {self.shared_region:#x}, "
              f"gfx-handoff {self.handoff:#x}" if self.ttbat and self.shared_region and self.handoff
              else f"sgx: region properties missing ({self.ttbat}, {self.shared_region}, {self.handoff})")
        for name in [n.strip() for n in os.environ.get("HV27_GPU_ASCS", "gfx-asc,gfx1-asc").split(",") if n.strip()]:
            path = f"/arm-io/{name}"
            try:
                node = hv.adt[path]
            except Exception:
                _gi_p(f"{path} not in the ADT, skipped")
                continue
            base, _ = node.get_reg(0)
            mbox = base + 0x8000
            role = self._prop(node, "role")
            self.ascs[mbox] = {"name": name, "path": path, "role": str(role), "in": None, "out": None}
            hv.add_tracer(irange(mbox, 0x4000), f"GPUINIT.{name}", mode, read=self._mbox, write=self._mbox)
            _gi_p(f"{path} (role {role}) mailbox {mbox:#x}+0x4000 {mode.name}")
        _gi_p("SYNC: InitData is read at the INITDATA store, guest stopped" if self.sync
              else "ASYNC: words only, no InitData dump (HV27_GPU_MODE=sync for the dump)")
        self._j({"t": self._t(), "kind": "install", "mode": mode.name,
                 "ascs": [{"name": a["name"], "role": a["role"]} for a in self.ascs.values()]})

    # ------------------------------------------------------------------ guarded reads, UAT walk
    def _can_read(self):
        if not self.sync or self.reads_dead:
            return False
        try:
            return getattr(hv, "ctx", None) is not None
        except Exception:
            return False

    def _readmem(self, pa, n):
        if not self._can_read():
            raise _NoRead("proxy read refused (not SYNC with a stopped guest)")
        try:
            return hv.iface.readmem(pa, n)
        except Exception:
            self.reads_dead = True
            _gi_p("proxy read failed; reads disabled for the rest of the run")
            raise

    def _rd64(self, pa):
        return struct.unpack("<Q", self._readmem(pa, 8))[0]

    def _l1_base(self, hi):
        forced = self.forced_ttb.get(hi)
        if forced is not None:
            return forced, "forced"
        ttbr = self._rd64(self.ttbat + 8 * hi)                    # context 0: TTBR0 at +0, TTBR1 at +8
        if ttbr & 1:
            return (ttbr & 0x0000_ffff_ffff_fffe), f"TTBAT[0].{hi} {ttbr:#x}"
        if hi == 1 and self.shared_region:
            return self.shared_region, f"TTBAT[0].1 invalid ({ttbr:#x}); gfx-shared-region as the L1 table"
        return None, f"TTBAT[0].{hi} invalid ({ttbr:#x})"

    def walk(self, va):
        """Context-0 GPU VA -> PA (None if unmapped). UAT: TTBR pair by VA bit 42, L1 41:36 (64), L2 35:25, L3 24:14."""
        page = va & ~(self.PAGE - 1)
        if page in self.tlb:
            return self.tlb[page] | (va & (self.PAGE - 1))
        hi = (va >> 42) & 1
        tbl, why = self._l1_base(hi)
        if tbl is None:
            self.uat_note = why
            return None
        for shift, bits, last in ((36, 6, False), (25, 11, False), (14, 11, True)):
            idx = (va >> shift) & ((1 << bits) - 1)
            pte = self._rd64(tbl + 8 * idx)
            if not pte & 1:
                self.uat_note = f"invalid PTE {pte:#x} at shift {shift} idx {idx:#x} (table {tbl:#x}; L1 from {why})"
                return None
            out = pte & 0x0000_ffff_ffff_c000
            if last or not pte & 2:                                 # page, or a block at L1/L2
                span = 1 << shift
                pa = (out & ~(span - 1)) | (va & (span - 1))
                self.tlb[page] = pa & ~(self.PAGE - 1)
                return pa
            tbl = out
        return None

    def read_va(self, va, n):
        """Returns (bytes, runs, missing): unmapped pages read as zeros and are listed in missing."""
        data, runs, missing = bytearray(), [], []
        done = 0
        while done < n:
            cur = va + done
            k = min(n - done, self.PAGE - (cur & (self.PAGE - 1)))
            pa = self.walk(cur)
            if pa is None:
                data += b"\0" * k
                missing.append([cur, k, self.uat_note])
            else:
                data += self._readmem(pa, k)
                if runs and runs[-1][1] + runs[-1][2] == pa and runs[-1][0] + runs[-1][2] == cur:
                    runs[-1][2] += k
                else:
                    runs.append([cur, pa, k])
            done += k
        return bytes(data), runs, missing

    # ------------------------------------------------------------------ dump
    def _save_uat(self):
        if self.uat_saved:
            return
        self.uat_saved = True
        d = os.path.join(self.out, "uat")
        os.makedirs(d, exist_ok=True)
        for name, base, size in (("ttbat", self.ttbat, 0x4000), ("handoff", self.handoff, 0x4000)):
            try:
                if base:
                    open(os.path.join(d, f"{name}.bin"), "wb").write(self._readmem(base, size))
            except _NoRead:
                raise
            except Exception:
                self._err(f"uat save {name}")

    def capture(self, asc, root_va, tag):
        n = len([x for x in self.dumps if f"-{asc}-" in x]) + 1
        d = os.path.join(self.out, f"initdata-{asc}-{tag}-{n}")
        os.makedirs(d, exist_ok=True)
        t0 = time.monotonic()
        idx = {"asc": asc, "tag": tag, "t": self._t(), "root_va": root_va, "objects": {}, "pointers": {},
               "notes": []}
        bufs = {}

        def grab(name, va, size=None):
            if not va or not _looks_va(va):
                idx["objects"][name] = {"va": va, "skipped": "not a GPU VA"}
                return None
            size = size or OBJ_READ.get(name, 0x4000)
            data, runs, missing = self.read_va(va, size)
            open(os.path.join(d, f"{name}.bin"), "wb").write(data)
            idx["objects"][name] = {"va": va, "size": size, "runs": runs, "missing": missing,
                                    "sha256": hashlib.sha256(data).hexdigest()}
            bufs[name] = data
            return data

        u64 = lambda b, o: struct.unpack_from("<Q", b, o)[0]
        u32 = lambda b, o: struct.unpack_from("<I", b, o)[0]
        try:
            self._save_uat()
            root = grab("root", root_va)
            if root is None or idx["objects"]["root"]["missing"]:
                _gi_p(f"{asc}: root {root_va:#x} not translatable: {self.uat_note}")
                idx["notes"].append(f"root not translatable: {self.uat_note}")
                return
            role = u32(root, 0x28)
            idx["role"] = role
            for k, o in ROOT_FIELDS.items():
                idx["pointers"][f"root+{o:#x}"] = u64(root, o)
            ptr = {k: u64(root, o) for k, o in ROOT_FIELDS.items()}
            main = grab("main_config", ptr["main_config"])
            grab("region_a", ptr["region_a"])
            grab("region_c", ptr["region_c"])
            grab("status_a", ptr["status_a"])
            # role-agnostic: whatever the root carries is read (primary: status B; secondary: status config, extra 1)
            if ptr["status_b"]:
                grab("status_b", ptr["status_b"])
            if ptr["extra0"]:
                grab("status_config", ptr["extra0"])
            if ptr["extra1"]:
                grab("secondary_extra_1", ptr["extra1"])
            if main is not None:
                for o in range(0, MAIN_SIZE, 8):
                    v = u64(main, o)
                    if _looks_va(v):
                        idx["pointers"][f"main+{o:#x}"] = v
                grab("hw_data", u64(main, 0x00))
                for i in range(5):                                  # primary: bundle views
                    v = u64(main, MAIN_BUNDLE_VIEWS + 8 * i)
                    if _looks_va(v):
                        grab(f"view{i}", v)
                pol = struct.unpack_from("<Q", main, MAIN_POLICY_PTR)[0]   # secondary: policy (unaligned)
                idx["pointers"][f"main+{MAIN_POLICY_PTR:#x}"] = pol
                if _looks_va(pol):
                    grab("policy", pol)
                if self.crawl:
                    off, cnt, stride = MAIN_CHANNELS
                    for e in range(cnt):
                        for w in range(4):
                            v = u64(main, off + e * stride + 8 * w)
                            if _looks_va(v):
                                grab(f"chan{e:02d}_{'ring' if w == 3 else 'state%d' % w}", v, 0x4000)
            self._decode(asc, tag, role, bufs, idx)
        except _NoRead as e:
            idx["notes"].append(str(e))
            _gi_p(f"{asc}: dump stopped: {e}")
        except Exception:
            self._err(f"capture {asc}")
            idx["notes"].append("exception, see console")
        finally:
            idx["seconds"] = round(time.monotonic() - t0, 3)
            try:
                json.dump(idx, open(os.path.join(d, "index.json"), "w"), indent=1, default=str)
            except Exception:
                self._err("index write")
            self.dumps.append(d)
            _gi_p(f"{asc}: {tag} dump -> {d} ({len(bufs)} objects, {idx['seconds']} s)")
            self._j({"t": self._t(), "kind": "dump", "asc": asc, "tag": tag, "dir": d,
                     "objects": sorted(bufs), "seconds": idx["seconds"]})

    def _decode(self, asc, tag, role, b, idx):
        """Console only: the handful of words the PR names (offsets per PR #1173; values never pointers)."""
        u32 = lambda n, o: struct.unpack_from("<I", b[n], o)[0] if n in b and o + 4 <= len(b[n]) else None
        u64 = lambda n, o: struct.unpack_from("<Q", b[n], o)[0] if n in b and o + 8 <= len(b[n]) else None
        lines = [f"{asc} {tag}: role {role} version word {u64('root', 0):#018x} "
                 f"(PR 27.2+: 0x0c8e4339872804c0; 27.0: 0x0c8e0339872804c0)"]
        if "hw_data" in b:
            lines.append(f"  hw_data[0x2720]={u32('hw_data', 0x2720)} (PR: 5000)  [0x271c]={u32('hw_data', 0x271c):#x} "
                         f"(0x96 below the band)  [0xfb0]={u32('hw_data', 0xfb0):#x} (chip)")
            for base in (0x273c, 0x2740):
                ent = [(u32('hw_data', base + 0x20 * i + 0x10), u32('hw_data', base + 0x20 * i + 0x14),
                        u32('hw_data', base + 0x20 * i + 0x18)) for i in range(4)]
                lines.append(f"  completion table at {base:#x}: {ent} (PR 26C5035r: 0x2740, 0x800/0x40/i)")
            for o in (0x27d4, 0x27d8, 0x27dc, 0x27e0):
                v = u64('hw_data', o)
                lines.append(f"  hw_data u64[{o:#x}] {'pointer' if v and _looks_va(v) else hex(v or 0)}")
        if "policy" in b:
            lines.append(f"  policy[0x492c]={u32('policy', 0x492c)} (PR 5000) [0x4a14]={u32('policy', 0x4a14)} (PR 1600)")
            for o in (0x8254, 0x8284, 0x11a1c, 0x11a4c):
                v = struct.unpack_from("<Q", b["policy"], o)[0]
                lines.append(f"  policy u64[{o:#x}] {'pointer' if _looks_va(v) else hex(v)}")
        if "status_config" in b:
            lines.append("  status_config inserted " + " ".join(
                f"[{o:#x}]={u32('status_config', o)}" for o in (0x5dc, 0x60c, 0x640, 0x670))
                + " (PR 0/5000/0/0)")
            v = u64('status_config', 0x788)
            lines.append(f"  status_config link word [0x784]={u32('status_config', 0x784):#x} ptr[0x788] "
                         f"{'pointer' if v and _looks_va(v) else hex(v or 0)}")
        for ln in lines:
            _gi_p(ln)

    # ------------------------------------------------------------------ mailbox
    def _mbox(self, evt, **kw):
        try:
            base = evt.addr & ~0x3fff
            a = self.ascs.get(base)
            if a is None:
                return
            off = evt.addr - base
            if off not in (0x800, 0x808, 0x830, 0x838):
                return
            if evt.flags.WIDTH != 3:
                self.counts["odd"] = self.counts.get("odd", 0) + 1
                return
            w = bool(evt.flags.WRITE)
            if off == 0x800 and w:
                a["in"] = evt.data
            elif off == 0x808 and w:
                if a["in"] is not None:
                    self._msg(a, "AP>GPU", a["in"], evt.data)
                a["in"] = None
            elif off == 0x830 and not w:
                a["out"] = evt.data
            elif off == 0x838 and not w:
                if a["out"] is not None:
                    self._msg(a, "GPU>AP", a["out"], evt.data)
                a["out"] = None
        except Exception:
            self._err("mailbox")

    def _msg(self, a, dirn, m0, m1):
        ep = m1 & 0xff
        self.seq += 1
        rec = {"seq": self.seq, "t": self._t(), "asc": a["name"], "dir": dirn, "ep": ep,
               "msg0": f"{m0:#018x}", "msg1": f"{m1:#x}"}
        show = self.console_all
        if ep == 0:
            t = (m0 >> 52) & 0xff
            rec["mgmt"] = self.MGMT.get(t, f"type{t:#x}")
            if t == 5:
                rec["start_ep"] = (m0 >> 32) & 0xff
            key = "ep0"
            show = True
        elif ep == self.EP_FW:
            t = (m0 >> 48) & 0xffff
            rec["fw"] = self.FWTYPES.get(t, f"type{t:#x}")
            key = f"ep20.{rec['fw']}"
            show = show or t != 0x42
        elif ep == self.EP_DOORBELL:
            key = "ep21"
        else:
            key = f"ep{ep:#x}"
        self.counts[key] = self.counts.get(key, 0) + 1
        self._j(rec)
        if show or self.counts[key] <= 3:
            extra = "".join(f" {k}={rec[k]}" for k in ("mgmt", "start_ep", "fw") if k in rec)
            _gi_p(f"#{self.seq} t={rec['t']:.3f} {a['name']} {dirn} ep{ep:#04x}{extra} msg0={m0:#018x}")
        if ep == self.EP_FW and dirn == "AP>GPU" and (m0 >> 48) & 0xffff == 0x81:
            va = _va_of_msg(m0)
            self.roots[a["name"]] = va
            _gi_p(f"{a['name']}: INITDATA root {va:#x}")
            if self._can_read():
                self.capture(a["name"], va, "send")
            else:
                _gi_p(f"{a['name']}: no stopped-guest context (mode {'SYNC' if self.sync else 'ASYNC'}); "
                      "Ctrl-C and gpu_redump() to read it now")
        elif ep == self.EP_FW and dirn == "GPU>AP" and (m0 >> 48) & 0xffff == 0x09:
            _gi_p(f"{a['name']}: INITDATA acknowledged by the firmware")
            va = self.roots.get(a["name"])
            if self.ackdump and va and self._can_read():
                self.capture(a["name"], va, "ack")


def _gi_arm_late(inst):
    """hv27-dcp-trace.py's wrapper: re-register each SPTM AMCC register as a HOOK that installs on the first read and
    forwards to the hook registered before it (hv27-trace-late.py's, chained), signature (addr, width=None, **kw)."""
    sp = getattr(hv, "sptm_amcc", None)
    if sp is None:
        _gi_p("no SPTM AMCC emulation in this run; installing now")
        inst.install()
        return
    done = [False]

    def mk(pread, pwrite):
        def rd(addr, width=None, **kw):
            if not done[0]:
                done[0] = True
                _gi_p(f"SPTM read AMCC {addr:#x}; installing the GPU mailbox tracers")
                try:
                    inst.install()
                except Exception:
                    _gi_p("install failed:")
                    _gi_p(traceback.format_exc())
            return pread(addr, width, **kw) if width is not None else pread(addr)
        rd._gpuinit = True
        return rd, pwrite

    n = chained = 0
    for a in list(sp.registers):
        pread, pwrite = sp.read, sp.write
        try:
            prev = hv.mmio_maps[(a, "SPTM AMCC")]
        except Exception:
            prev = None
        if isinstance(prev, (tuple, list)) and len(prev) >= 4 and callable(prev[2]) and callable(prev[3]):
            if getattr(prev[2], "_gpuinit", False):
                continue
            if prev[2] != sp.read or prev[3] != sp.write:
                pread, pwrite = prev[2], prev[3]
                chained += 1
        rd, wr = mk(pread, pwrite)
        hv.add_tracer(irange(a, 4), "SPTM AMCC", TraceMode.HOOK, read=rd, write=wr)
        n += 1
    _gi_p(f"armed on {n} AMCC registers (late install, {chained} chained onto another module's hook)")


_gpuinit = _GpuInit()


def gpu_status():
    g = _gpuinit
    _gi_p(f"installed={g.installed} sync={g.sync} words={g.counts} errors={g.errors} reads_dead={g.reads_dead}")
    for k, v in g.roots.items():
        _gi_p(f"root {k} {v:#x}")
    for d in g.dumps:
        _gi_p(f"dump {d}")


def gpu_redump(asc=None, tag="manual"):
    g = _gpuinit
    for name, va in list(g.roots.items()):
        if asc is None or asc == name:
            g.capture(name, va, tag)


def gpu_dump_root(va, asc="manual", tag="manual"):
    """Dump the graph below an arbitrary root VA (if macOS hands the root over some other way than ep 0x20 type 0x81)."""
    _gpuinit.roots[asc] = va
    _gpuinit.capture(asc, va, tag)


def gpu_walk(va):
    pa = _gpuinit.walk(va)
    _gi_p(f"{va:#x} -> {pa:#x}" if pa is not None else f"{va:#x} -> unmapped ({_gpuinit.uat_note})")
    return pa


def gpu_shot(name=None):
    """Panel screenshot from the paused hypervisor (boot-args framebuffer, ~31 MB over the proxy, ~20 s) as a
    half-size PNG under <out>/shots/. Private: a panic screen carries UUIDs."""
    import zlib
    ba = hv.u.ba
    base, w, h, stride, depth = ba.video.base, ba.video.width, ba.video.height, ba.video.stride, ba.video.depth & 0xff
    raw = hv.iface.readmem(base, stride * h)
    d = os.path.join(_gpuinit.out, "shots")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, f"{name or time.strftime('panel-%H%M%S')}.png")

    def px(v):
        return ((v >> 22) & 0xff, (v >> 12) & 0xff, (v >> 2) & 0xff) if depth == 30 else ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
    rows = []
    for y in range(0, h - 1, 2):
        line = raw[y * stride:y * stride + w * 4]
        rows.append(b"\0" + b"".join(bytes(px(struct.unpack_from("<I", line, 8 * x)[0])) for x in range(w // 2)))

    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w // 2, len(rows), 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(b"".join(rows), 6)) + chunk(b"IEND", b""))
    _gi_p(f"screenshot -> {path}")
    return path


if os.environ.get("HV27_GPU_INSTALL", "late") == "now":
    _gpuinit.install()
else:
    _gi_arm_late(_gpuinit)
