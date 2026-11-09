# SPDX-License-Identifier: MIT
# run_guest.py -m module: log the IOMFB (DCP, endpoint 0x37) RPC traffic of the macOS 27.3 guest on the J716s (T6050).
#
# What it does (see DCP-TRACE-MODULE.md next to this file):
#   * traces only the DCP ASC mailbox page (reg0 + 0x8000, 0x4000) and the first 0x4000 of the dart-dcp registers
#     (writes only: TLB_OP, TCR, TTBR). It does NOT trap the DCP shared memory.
#   * two modes (HV27_DCP_TRACE_MODE):
#       async (default): WORDS ONLY. The event handler never issues a proxy request (m1n1 treats any request that
#           arrives while the guest runs as a user interrupt, and the resulting exception desyncs the UART channel:
#           see DCP-TRACE-MODULE.md "Why no readmem in ASYNC"). Each mailbox word is decoded from its own bits
#           (type, ctx, channel, shmem offset, length, ack) and logged as JSONL kind "word".
#       sync: the guest is stopped at every hooked mailbox access, so the handler may use the proxy. On each
#           endpoint-0x37 word it reads the RPC header out of the shared memory (DVA -> PA through the dart-dcp page
#           tables, walked by hand from the ADT l1-tt-<sid> seed plus the traced TTBR/TCR writes) and logs direction,
#           context, 4-char tag, in/out lengths and the payloads. Unknown tags are kept.
#   * every line on the client stdout starts with "DCPRPC:" and is plain printable ASCII (hex only, no raw payload
#     bytes; anything else is escaped), so the run log stays grep-safe. A compact JSONL with the payloads goes to
#     ~/Work/agents/hv27/captures/dcp-rpc-<stamp>.jsonl
#   * install is late by default (from the SPTM AMCC hook callback, like hv27-trace-late.py), because tracers installed
#     before SPTM's init panic the guest on this machine. It chains onto an AMCC hook that hv27-trace-late.py already
#     armed, so pass THIS module AFTER hv27-trace-late.py when both are used.
#
# Environment (all optional):
#   HV27_DCP_INSTALL=late|now        late (default): arm on the SPTM AMCC read; now: register tracers at load
#   HV27_DCP_TRACE_MODE=async|sync   mailbox tracer mode (default async = words only, no proxy requests from the
#                                    handler; sync = payloads, exact shmem contents, guest is stalled per access)
#   HV27_DCP_DART_TRACE=1            async only: still trace the DART TTBR/TCR/TLB_OP writes (log only; the DART is
#                                    otherwise only traced in sync mode, where it is needed for the walk)
#   HV27_DCP_CONSOLE_ALL=1           async: print every word line (default: first HV27_DCP_FULL_N per (dir,ctx,kind,len)
#                                    then every 50th; the JSONL always has all of them)
#   HV27_DCP_NAME=dcp                ADT name below /arm-io of the DCP ASC (dart is dart-<name>); default dcp
#   HV27_DCP_SID=23                  DART stream used for IOMFB (default: the ADT 'sid', then 'exclave-sid')
#   HV27_DCP_SHMEM_DVA=0x...         shared-memory DVA if SET_SHMEM was missed (module installed after it)
#   HV27_DCP_SHMEM_PA=0x...          bypass the DART walk: treat the shared memory as contiguous at this PA
#   HV27_DCP_FULL_N=6                full hexdump for the first N records of each (dir, ctx, tag); then one brief line
#   HV27_DCP_DUMP=64                 bytes of in/out data shown in the hexdump (default 64)
#   HV27_DCP_JSONL=path              JSONL path (default captures/dcp-rpc-<stamp>.jsonl; "" or "off" disables)
#   HV27_DCP_JSONL_BYTES=4096        bytes of each in/out blob stored in the JSONL (0 = whole payload)
#   HV27_DCP_ALLEP=1                 also log every message of every other endpoint (default: only ep0 mgmt, counted)
#   HV27_DCP_DART_LIVE=1             also read TCR/TTBR of the DART over MMIO at install (default: ADT seed only; a
#                                    read of a power-gated DART could hang the bus)
import atexit, json, os, re, struct, sys, time, traceback
from m1n1.utils import irange
from m1n1.hv import TraceMode

_DCPRPC_STAMP = time.strftime("%Y%m%d-%H%M%S")
_DCPRPC_CAPDIR = os.path.expanduser("~/Work/agents/hv27/captures")
_DCPRPC_BAD = re.compile(r"[^\x20-\x7e]")


def _dcprpc_safe(s):
    """Printable ASCII only: everything else is escaped, so a log of this module can never turn binary."""
    def esc(m):
        o = ord(m.group(0))
        return "\\x%02x" % o if o < 256 else "\\u%04x" % o
    return _DCPRPC_BAD.sub(esc, str(s))


def _p(s=""):
    try:
        for ln in str(s).split("\n"):
            print(_dcprpc_safe(ln))
    except Exception:
        pass


def _dcprpc_env_int(name, default):
    v = os.environ.get(name, "")
    if not v.strip():
        return default
    try:
        return int(v, 0)
    except ValueError:
        _p(f"DCPRPC: bad {name}={v!r}, using {default}")
        return default


def _dcprpc_hexdump(data, limit, indent="DCPRPC:     "):
    """Hex only (no ASCII column, no raw bytes)."""
    out = []
    data = bytes(data[:limit])
    for i in range(0, len(data), 16):
        out.append(f"{indent}{i:04x}: " + " ".join(f"{b:02x}" for b in data[i:i + 16]))
    return out


class _NoRead(Exception):
    """A proxy read was refused because it is not safe here (async context / no stopped guest)."""


class _DcpRpcTrace:
    EP = 0x37
    MGMT = {1: "HELLO", 2: "HELLO_ACK", 5: "STARTEP", 6: "SET_IOP_PWR", 7: "IOP_PWR_ACK", 8: "EPMAP",
            0xb: "SET_AP_PWR", 0xf: "NMI"}
    CTXN = {0: "CB", 2: "CMD", 3: "ASYNC", 4: "OOBCB", 6: "OOBCMD", 7: "OOBASYNC"}
    # shared-memory channel buffers (m1n1 hv/trace_dcp.py, fw/dcp/dcpep.py); each is 0x8000 long
    CHBUF = {"CMD": 0x0, "OOBCMD": 0x8000, "ASYNC": 0x40000, "OOBASYNC": 0x48000, "CB": 0x60000, "OOBCB": 0x68000}
    CHSIZE = 0x8000
    # channel carrying an AP->DCP call / a DCP->AP ack, indexed by CTX
    AP_CALL_CH = {0: "CMD", 2: "CMD", 4: "OOBCMD", 6: "OOBCMD"}
    # channel carrying a DCP->AP callback / an AP->DCP ack of it, indexed by CTX
    DCP_CB_CH = {0: "CB", 3: "ASYNC", 4: "OOBCB", 6: "OOBCB", 7: "OOBASYNC"}
    PAGE = 0x4000

    def __init__(self):
        self.installed = False
        self.t0 = time.monotonic()
        self.seq = 0
        self.msg_in = None          # pending INBOX0 value (AP->DCP)
        self.msg_out = None         # pending OUTBOX0 value (DCP->AP)
        self.shmem_dva = None
        self.shmem_pa = None        # HV27_DCP_SHMEM_PA bypass
        self.sync = False           # set by install(): payload reads only in SYNC mode
        self.payload_dead = False   # latched after a proxy error: words only from then on
        self.pending = {}           # channel -> [call state]   (sync, payload path)
        self.wpending = {}          # channel -> [word call state] (words-only path)
        self.seen = {}              # (dir, ctx, tag, kind) -> count
        self.wseen = {}             # (dir, ctxn, kind, len) -> count (console throttle)
        self.tagcount = {}
        self.wordcount = {}
        self.nmsg = {"ep0": 0, "ep37": 0, "other": 0, "odd": 0}
        self.errors = 0
        self.untrans = 0
        self.page_cache = {}
        self.ttbr = {}
        self.tcr = {}
        self.sids = []
        self.dart_base = None
        self.mbox_base = None
        self.four = True
        self.full_n = _dcprpc_env_int("HV27_DCP_FULL_N", 6)
        self.dump = _dcprpc_env_int("HV27_DCP_DUMP", 64)
        self.jbytes = _dcprpc_env_int("HV27_DCP_JSONL_BYTES", 4096)
        self.allep = os.environ.get("HV27_DCP_ALLEP") == "1"
        self.console_all = os.environ.get("HV27_DCP_CONSOLE_ALL") == "1"
        self.jf = None
        self.walk_err = ""
        self._open_jsonl()
        atexit.register(self._summary)

    # ------------------------------------------------------------------ output
    def _open_jsonl(self):
        path = os.environ.get("HV27_DCP_JSONL", os.path.join(_DCPRPC_CAPDIR, f"dcp-rpc-{_DCPRPC_STAMP}.jsonl"))
        if path.strip() in ("", "off"):
            _p("DCPRPC: jsonl disabled")
            return
        try:
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            self.jf = open(path, "a", buffering=1)
            _p(f"DCPRPC: jsonl -> {path}")
        except Exception as e:
            self.jf = None
            _p(f"DCPRPC: cannot open jsonl {path}: {e}")

    def _t(self):
        return time.monotonic() - self.t0

    def _j(self, rec):
        if self.jf is None:
            return
        try:
            self.jf.write(json.dumps(rec, separators=(",", ":")) + "\n")
        except Exception as e:
            _p(f"DCPRPC: jsonl write failed: {e}")
            self.jf = None

    def _blob(self, data):
        if data is None:
            return None
        if self.jbytes and len(data) > self.jbytes:
            data = data[:self.jbytes]
        return bytes(data).hex()

    def _summary(self):
        try:
            _p(f"DCPRPC: summary msgs={self.nmsg} untranslated={self.untrans} errors={self.errors} "
               f"mode={'SYNC' if self.sync else 'ASYNC'} payload_dead={self.payload_dead}")
            top = sorted(self.tagcount.items(), key=lambda kv: -kv[1])
            for (d, ctx, tag, in_len, out_len), n in top[:60]:
                _p(f"DCPRPC: summary {d} ctx={ctx} tag={tag} in={in_len} out={out_len} count={n}")
            wtop = sorted(self.wordcount.items(), key=lambda kv: -kv[1])
            for (d, ctx, kind, ln), n in wtop[:60]:
                _p(f"DCPRPC: summary words {d} ctx={ctx} {kind} len={ln:#x} count={n}")
            self._j({"summary": True, "msgs": self.nmsg, "untranslated": self.untrans, "errors": self.errors,
                     "tags": [[list(k), n] for k, n in top], "words": [[list(k), n] for k, n in wtop]})
            if self.jf:
                self.jf.close()
                self.jf = None
        except Exception:
            pass

    # ------------------------------------------------------------------ install
    def install(self):
        if self.installed:
            return
        self.installed = True
        try:
            sys.stdout.reconfigure(line_buffering=True)   # keep the piped run log current
        except Exception:
            pass
        name = os.environ.get("HV27_DCP_NAME", "dcp")
        asc_path = f"/arm-io/{name}"
        dart_path = f"/arm-io/dart-{name}"
        try:
            hv.adt[asc_path]
        except Exception:
            alt = "dcp0" if name == "dcp" else "dcp"
            try:
                hv.adt[f"/arm-io/{alt}"]
                asc_path, dart_path = f"/arm-io/{alt}", f"/arm-io/dart-{alt}"
                _p(f"DCPRPC: {name} not in ADT, using {alt}")
            except Exception:
                _p(f"DCPRPC: no DCP node ({asc_path}) in the ADT, nothing installed")
                return

        want = os.environ.get("HV27_DCP_TRACE_MODE", "async").strip().lower()
        if want not in ("async", "sync"):
            _p(f"DCPRPC: bad HV27_DCP_TRACE_MODE={want!r}, using async")
        mode = TraceMode.SYNC if want == "sync" else TraceMode.ASYNC
        self.sync = mode == TraceMode.SYNC
        base, _ = hv.adt[asc_path].get_reg(0)
        self.mbox_base = base + 0x8000
        hv.add_tracer(irange(self.mbox_base, 0x4000), "DCPRPC.mbox", mode, read=self._mbox, write=self._mbox)
        _p(f"DCPRPC: {asc_path} mailbox {self.mbox_base:#x}+0x4000 ({mode.name})")
        if self.sync:
            _p("DCPRPC: SYNC: guest is stopped at each mailbox access, payload reads through the proxy enabled")
        else:
            _p("DCPRPC: ASYNC: words only, the event handler issues no proxy requests (use HV27_DCP_TRACE_MODE=sync for payloads)")

        try:
            self._install_dart(dart_path)
        except Exception as e:
            _p(f"DCPRPC: DART setup failed ({e!r}); DVA translation will fail")
            _p(traceback.format_exc())

        sp = os.environ.get("HV27_DCP_SHMEM_PA", "").strip()
        if sp:
            self.shmem_pa = int(sp, 0)
        sd = os.environ.get("HV27_DCP_SHMEM_DVA", "").strip()
        if sd:
            self.shmem_dva = int(sd, 0)
            _p(f"DCPRPC: shmem dva forced to {self.shmem_dva:#x}")
        _p(f"DCPRPC: installed, mailbox mode {mode.name}, DART sids {self.sids}")

    def _prop(self, node, key):
        try:
            return node._properties.get(key)
        except Exception:
            return getattr(node, key.replace("-", "_"), None)

    def _install_dart(self, dart_path):
        node = hv.adt[dart_path]
        self.dart_base, _ = node.get_reg(0)
        sid = self._prop(node, "sid")
        xsid = self._prop(node, "exclave-sid")
        forced = os.environ.get("HV27_DCP_SID", "").strip()
        if forced:
            self.sids = [int(forced, 0)]
        else:
            self.sids = [s for s in (sid, xsid) if s is not None]
        vm_base = self._prop(node, "vm-base") or 0
        vm_size = self._prop(node, "vm-size") or 0
        self.four = (vm_base + vm_size) > (1 << 36)
        for s in self.sids:
            tt = self._prop(node, f"l1-tt-{s}")
            if tt:
                pa = int(tt[0])
                valid = int(tt[1]) & 1 if len(tt) > 1 else 1
                self.ttbr[s] = (((pa >> 14) << 2) | valid)
            self.tcr[s] = (1 | (8 if self.four else 0))      # translate enable (+ FOUR_LEVELS when vm range > 2^36)
        if os.environ.get("HV27_DCP_DART_LIVE") == "1":
            for s in self.sids:
                try:
                    self.tcr[s] = hv.p.read32(self.dart_base + 0x1000 + 4 * s)
                    self.ttbr[s] = hv.p.read32(self.dart_base + 0x1400 + 4 * s)
                except Exception as e:
                    _p(f"DCPRPC: live DART read failed: {e!r}")
        # The DART is only needed for the payload walk (SYNC); in ASYNC leave the page alone unless asked.
        if self.sync or os.environ.get("HV27_DCP_DART_TRACE") == "1":
            hv.add_tracer(irange(self.dart_base, 0x4000), "DCPRPC.dart", TraceMode.ASYNC, write=self._dart_w)
        else:
            _p("DCPRPC: DART not traced in ASYNC mode (HV27_DCP_DART_TRACE=1 to log its TTBR/TCR writes)")
        for s in self.sids:
            _p(f"DCPRPC: dart {self.dart_base:#x} sid {s}: TTBR {self.ttbr.get(s, 0):#x} TCR {self.tcr.get(s, 0):#x} "
               f"({'4' if self.four else '3'}-level, vm-base {vm_base:#x} size {vm_size:#x})")

    # ------------------------------------------------------------------ DART
    def _dart_w(self, evt, **kw):
        # local state only, no proxy requests (runs as an ASYNC event handler)
        try:
            off = evt.addr - self.dart_base
            width = evt.flags.WIDTH
            if width < 2:
                return
            val = evt.data
            for lane in range(1 << (width - 2)):
                lo = off + 4 * lane
                v = (val >> (32 * lane)) & 0xffffffff
                self._dart_reg(lo, v)
        except Exception:
            self._err("dart write")

    def _dart_reg(self, off, v):
        if off == 0x80:                          # TLB_OP
            op, stream = (v >> 8) & 7, v & 0xff
            if op == 0 or stream in self.sids:
                self.page_cache.clear()
            return
        for s in self.sids:
            if off == 0x1400 + 4 * s:
                self.ttbr[s] = v
                self.page_cache.clear()
                _p(f"DCPRPC: dart TTBR[{s}] = {v:#x}")
            elif off == 0x1000 + 4 * s:
                self.tcr[s] = v
                self.page_cache.clear()
                _p(f"DCPRPC: dart TCR[{s}] = {v:#x}")

    # ------------------------------------------------------------------ guarded proxy reads
    def _can_read(self):
        """True only where a proxy request is safe: SYNC mode, guest stopped in the hv exception context."""
        if not self.sync or self.payload_dead:
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
            self.payload_dead = True      # the channel may be desynced: never talk to the proxy from here again
            _p("DCPRPC: proxy read failed; payload reads disabled, words only from now on")
            raise

    def _rd64(self, pa):
        return struct.unpack("<Q", self._readmem(pa, 8))[0]

    @staticmethod
    def _pte_pa(pte):
        return ((pte >> 10) & 0xfffffff) << 14

    def _walk(self, sid, page):
        """DVA page -> PA, or None (self.walk_err says why)."""
        tcr = self.tcr.get(sid)
        ttbr = self.ttbr.get(sid)
        if tcr is not None and (tcr & 2) and not (tcr & 1):   # BYPASS_DART without translate
            return page
        if ttbr is None or not (ttbr & 1):
            self.walk_err = f"sid {sid}: no valid TTBR ({ttbr})"
            return None
        four = bool(tcr & 8) if tcr is not None else self.four
        tbl = ((ttbr >> 2) & 0xfffffff) << 14
        if four:
            levels = [(page >> 36) & 0x7ff, (page >> 25) & 0x7ff, (page >> 14) & 0x7ff]
        else:
            pm = page & 0xfffffffff
            levels = [(pm >> 25) & 0x7ff, (pm >> 14) & 0x7ff]
        for i, idx in enumerate(levels):
            pte = self._rd64(tbl + 8 * idx)
            if not pte & 1:
                self.walk_err = f"sid {sid} {'4' if four else '3'}-level: invalid PTE {pte:#x} at level {i} idx {idx:#x} (table {tbl:#x})"
                return None
            tbl = self._pte_pa(pte)
        return tbl

    def _page_pa(self, page):
        pa = self.page_cache.get(page)
        if pa is not None:
            return pa
        for sid in self.sids:
            pa = self._walk(sid, page)
            if pa is not None:
                self.page_cache[page] = pa
                return pa
        return None

    def read_dva(self, dva, size):
        if size <= 0:
            return b""
        if self.shmem_pa is not None and self.shmem_dva is not None and self.shmem_dva <= dva:
            return self._readmem(self.shmem_pa + dva - self.shmem_dva, size)
        out = b""
        done = 0
        while done < size:
            va = dva + done
            page = va & ~(self.PAGE - 1)
            po = va & (self.PAGE - 1)
            n = min(size - done, self.PAGE - po)
            pa = self._page_pa(page)
            if pa is None:
                self.untrans += 1
                if self.untrans <= 40 or self.untrans % 500 == 0:
                    _p(f"DCPRPC: untranslated dva {va:#x} (+{size:#x}): {self.walk_err}")
                return None
            out += self._readmem(pa + po, n)
            done += n
        return out

    # ------------------------------------------------------------------ mailbox
    def _err(self, what):
        self.errors += 1
        if self.errors <= 20:
            _p(f"DCPRPC: handler error in {what} (#{self.errors}):")
            _p(traceback.format_exc())

    def _mbox(self, evt, **kw):
        try:
            off = evt.addr - self.mbox_base
            if off not in (0x800, 0x808, 0x830, 0x838):
                return
            if evt.flags.WIDTH != 3:
                self.nmsg["odd"] += 1
                return
            w = bool(evt.flags.WRITE)
            d = evt.data
            if off == 0x800 and w:
                self.msg_in = d
            elif off == 0x808 and w:
                if self.msg_in is not None:
                    self._msg("AP>DCP", self.msg_in, d)
                self.msg_in = None
            elif off == 0x830 and not w:
                self.msg_out = d
            elif off == 0x838 and not w:
                if self.msg_out is not None:
                    self._msg("DCP>AP", self.msg_out, d)
                self.msg_out = None
        except Exception:
            self._err("mailbox")

    def _word(self, seq, dirn, m0, m1, wt, **extra):
        rec = {"seq": seq, "t": round(self._t(), 4), "dir": dirn, "kind": "word", "ep": m1 & 0xff, "wt": wt,
               "msg0": f"{m0:#018x}", "msg1": f"{m1:#x}"}
        rec.update(extra)
        self._j(rec)
        return rec

    def _msg(self, dirn, m0, m1):
        ep = m1 & 0xff
        if ep == 0:
            self.nmsg["ep0"] += 1
            t = (m0 >> 52) & 0xff
            tn = self.MGMT.get(t, f"type{t:#x}")
            extra = f" ep={(m0 >> 32) & 0xff:#x}" if t == 5 else ""
            self.seq += 1
            _p(f"DCPRPC: mgmt {dirn} {tn}{extra} msg0={m0:#018x}")
            kw = {"mgmt": tn}
            if t == 5:
                kw["start_ep"] = (m0 >> 32) & 0xff
            self._word(self.seq, dirn, m0, m1, "mgmt", **kw)
            return
        if ep != self.EP:
            self.nmsg["other"] += 1
            if self.allep:
                _p(f"DCPRPC: ep{ep:#04x} {dirn} msg0={m0:#018x}")
                self.seq += 1
                self._word(self.seq, dirn, m0, m1, "other")
            return
        self.nmsg["ep37"] += 1
        if self.nmsg["ep37"] % 2000 == 0:
            _p(f"DCPRPC: stats msgs={self.nmsg} untranslated={self.untrans} errors={self.errors}")
        self.seq += 1
        seq = self.seq
        typ = m0 & 0xf
        if typ == 0:
            self.shmem_dva = m0 >> 16
            self.page_cache.clear()
            _p(f"DCPRPC: #{seq} t={self._t():.3f} {dirn} SET_SHMEM dva={self.shmem_dva:#x} flag={(m0 >> 4) & 0xf:#x} msg0={m0:#018x}")
            if self.sync:
                self._j({"seq": seq, "t": round(self._t(), 4), "dir": dirn, "kind": "set_shmem", "dva": self.shmem_dva,
                         "msg0": f"{m0:#018x}"})
            else:
                self._word(seq, dirn, m0, m1, "set_shmem", dva=self.shmem_dva, flag=(m0 >> 4) & 0xf)
        elif typ == 1:
            _p(f"DCPRPC: #{seq} t={self._t():.3f} {dirn} INIT_COMPLETE msg0={m0:#018x}")
            if self.sync:
                self._j({"seq": seq, "t": round(self._t(), 4), "dir": dirn, "kind": "init_complete", "msg0": f"{m0:#018x}"})
            else:
                self._word(seq, dirn, m0, m1, "init_complete")
        elif typ == 2:
            self._rpc(seq, dirn, m0, m1)
        else:
            _p(f"DCPRPC: #{seq} t={self._t():.3f} {dirn} type{typ} msg0={m0:#018x}")
            if self.sync:
                self._j({"seq": seq, "t": round(self._t(), 4), "dir": dirn, "kind": "raw", "msg0": f"{m0:#018x}"})
            else:
                self._word(seq, dirn, m0, m1, "raw", type=typ)

    def _rpc(self, seq, dirn, m0, m1):
        length = (m0 >> 32) & 0xffffffff
        off = (m0 >> 16) & 0xffff
        ctx = (m0 >> 8) & 0xf
        ack = (m0 >> 6) & 1
        ctxn = self.CTXN.get(ctx, f"ctx{ctx}")
        tx = dirn == "AP>DCP"
        if ack:
            chname = (self.DCP_CB_CH if tx else self.AP_CALL_CH).get(ctx)
        else:
            chname = (self.AP_CALL_CH if tx else self.DCP_CB_CH).get(ctx)
        head = f"DCPRPC: #{seq} t={self._t():.3f} {dirn} {'ACK ' if ack else 'CALL'} ctx={ctxn}"
        rec = {"seq": seq, "t": round(self._t(), 4), "dir": dirn, "kind": "ack" if ack else "call", "ctx": ctx,
               "ctxn": ctxn, "ch": chname, "off": off, "len": length, "msg0": f"{m0:#018x}"}
        why = None
        if not self.sync:
            why = "async"
        elif self.payload_dead:
            why = "payload reads disabled after a proxy error"
        elif chname is None:
            why = "unknown ctx"
        elif self.shmem_dva is None:
            why = "no shmem dva yet"
        elif not self._can_read():
            why = "no stopped-guest context"
        if why is None:
            try:
                if ack:
                    self._ack(seq, head, rec, chname, off)
                else:
                    self._call(seq, head, rec, chname, off, length)
                return
            except Exception:
                self._err("payload read")
                why = "payload read failed"
                rec = {"seq": seq, "t": round(self._t(), 4), "dir": dirn, "kind": "ack" if ack else "call",
                       "ctx": ctx, "ctxn": ctxn, "ch": chname, "off": off, "len": length, "msg0": f"{m0:#018x}"}
        self._word_rpc(head, rec, m1, why, ack, chname, ctxn, off, length)

    def _word_rpc(self, head, rec, m1, why, ack, chname, ctxn, off, length):
        """Words only: everything comes from the mailbox word itself, no proxy request."""
        rec["kind"] = "word"
        rec["wt"] = "ack" if ack else "call"
        rec["ep"] = m1 & 0xff
        rec["msg1"] = f"{m1:#x}"
        rec["why"] = why
        extra = ""
        if ack:
            lst = self.wpending.get(chname) or []
            st = None
            for i in range(len(lst) - 1, -1, -1):
                if lst[i]["off"] == off:
                    st = lst.pop(i)
                    break
            if st is None and lst:
                st = lst.pop()
            if st is not None:
                rec["call_seq"] = st["seq"]
                rec["call_len"] = st["len"]
                rec["call_off"] = st["off"]
                extra = f" call=#{st['seq']} call_len={st['len']:#x}"
            else:
                extra = " (no matching call seen)"
        else:
            if length >= 12:
                rec["body_len"] = length - 12          # in_len + out_len; the split needs the header (SYNC)
            if chname is not None:
                lst = self.wpending.setdefault(chname, [])
                lst.append({"seq": rec["seq"], "off": off, "len": length})
                if len(lst) > 64:
                    del lst[0]
        self._j(rec)
        key = (rec["dir"], ctxn, rec["wt"], length)
        n = self.wordcount.get(key, 0) + 1
        self.wordcount[key] = n
        if self.console_all or n <= self.full_n or n % 50 == 0:
            _p(f"{head} ch={chname} off={off:#x} len={length:#x}{extra} msg0={rec['msg0']} [{why}] n={n}")

    def _tagstr(self, raw4):
        t = raw4[::-1]
        return "".join(chr(b) if 32 <= b < 127 else "." for b in t), t.hex()

    def _call(self, seq, head, rec, chname, off, length):
        base = self.CHBUF[chname] + off
        n = min(max(length, 12), self.CHSIZE - off) if off < self.CHSIZE else 12
        data = self.read_dva(self.shmem_dva + base, n)
        if data is None or len(data) < 12:
            _p(f"{head} ch={chname} off={off:#x} len={length:#x} DATA UNAVAILABLE")
            rec["untranslated"] = True
            self._j(rec)
            return
        tag, tag_hex = self._tagstr(data[:4])
        in_len, out_len = struct.unpack("<II", data[4:12])
        lenok = (12 + in_len + out_len == length)
        in_data = data[12:12 + in_len]
        st = {"seq": seq, "off": off, "tag": tag, "in_len": in_len, "out_len": out_len, "base": base + 12 + in_len,
              "ctxn": rec["ctxn"], "dir": rec["dir"]}
        lst = self.pending.setdefault(chname, [])
        lst.append(st)
        if len(lst) > 64:
            del lst[0]
        key = (rec["dir"], rec["ctxn"], tag, in_len, out_len)
        self.tagcount[key] = self.tagcount.get(key, 0) + 1
        rec.update({"tag": tag, "tag_hex": tag_hex, "in_len": in_len, "out_len": out_len, "lenok": lenok,
                    "in": self._blob(in_data)})
        self._j(rec)
        self._show(head, f"ch={chname} off={off:#x} len={length:#x} tag={tag} in={in_len} out={out_len}"
                   + ("" if lenok else " LEN-MISMATCH(stale or layout differs)"), "in", in_data,
                   (rec["dir"], rec["ctxn"], tag, "call"))

    def _ack(self, seq, head, rec, chname, off):
        lst = self.pending.get(chname) or []
        st = None
        for i in range(len(lst) - 1, -1, -1):
            if lst[i]["off"] == off:
                st = lst.pop(i)
                break
        if st is None and lst:
            st = lst.pop()
        if st is None:
            _p(f"{head} ch={chname} off={off:#x} ACK WITHOUT CALL (module installed late or event lost)")
            self._j(rec)
            return
        out_len = st["out_len"]
        out = self.read_dva(self.shmem_dva + st["base"], min(out_len, self.CHSIZE)) if out_len else b""
        rec.update({"tag": st["tag"], "call_seq": st["seq"], "out_len": out_len, "in_len": st["in_len"],
                    "out": self._blob(out)})
        self._j(rec)
        self._show(head, f"ch={chname} off={off:#x} tag={st['tag']} call=#{st['seq']} out={out_len}"
                   + ("" if out is not None else " DATA UNAVAILABLE"), "out", out,
                   (rec["dir"], rec["ctxn"], st["tag"], "ack"))

    def _show(self, head, body, label, data, key):
        n = self.seen.get(key, 0) + 1
        self.seen[key] = n
        data = data or b""
        if n <= self.full_n:
            _p(f"{head} {body}")
            if data:
                _p(f"DCPRPC:   {label} ({len(data)} bytes, first {min(len(data), self.dump)}):")
                for ln in _dcprpc_hexdump(data, self.dump):
                    _p(ln)
        else:
            _p(f"{head} {body} {label}[:16]={bytes(data[:16]).hex()}" + (" ..." if len(data) > 16 else ""))


def _dcprpc_arm_late(inst):
    """Same wrapper as hv27-trace-late.py: re-register every SPTM AMCC register as a HOOK whose read installs us
    on the first access and then forwards to the registered read with the same (addr, width=None, **kw) signature."""
    sp = getattr(hv, "sptm_amcc", None)
    if sp is None:
        _p("DCPRPC: no SPTM AMCC emulation in this run; installing now")
        inst.install()
        return
    done = [False]

    def mk(pread, pwrite):
        def rd(addr, width=None, **kw):
            if not done[0]:
                done[0] = True
                _p(f"DCPRPC: SPTM read AMCC {addr:#x}; installing the DCP tracers")
                try:
                    inst.install()
                except Exception:
                    _p("DCPRPC: install failed:")
                    _p(traceback.format_exc())
            return pread(addr, width, **kw) if width is not None else pread(addr)
        rd._dcprpc = True
        return rd, pwrite

    n = chained = 0
    for a in list(sp.registers):
        pread, pwrite = sp.read, sp.write          # trace-late: hv.sptm_amcc.read / .write
        try:
            prev = hv.mmio_maps[(a, "SPTM AMCC")]  # (mode, ident, read, write, kwargs) as stored by add_tracer
        except Exception:
            prev = None
        if isinstance(prev, (tuple, list)) and len(prev) >= 4 and callable(prev[2]) and callable(prev[3]):
            if getattr(prev[2], "_dcprpc", False):
                continue                           # already armed by this module
            if prev[2] != sp.read or prev[3] != sp.write:
                pread, pwrite = prev[2], prev[3]   # another module's wrapper (hv27-trace-late.py): chain onto it
                chained += 1
        rd, wr = mk(pread, pwrite)
        hv.add_tracer(irange(a, 4), "SPTM AMCC", TraceMode.HOOK, read=rd, write=wr)
        n += 1
    _p(f"DCPRPC: armed on {n} AMCC registers (late install, {chained} chained onto another module's hook)")


_dcprpc = _DcpRpcTrace()
if os.environ.get("HV27_DCP_INSTALL", "late") == "now":
    _dcprpc.install()
else:
    _dcprpc_arm_late(_dcprpc)
