# hv27-dcp-trace.py: IOMFB (DCP) RPC logger for the macOS 27.3 guest

Module: `~/Work/agents/hv27/hv/hv27-dcp-trace.py` (run_guest `-m`). Written on the Studio; compiles and is exercised against a
mock hv (synthetic ADT, DART tables and shared memory, real `DictRangeMap`/`TraceMode`). Revision 2 (2026-11-09) after two
hardware results: a standalone first-instruction fault (R1) and a UART desync in ASYNC mode (R2).

## Modes (the important part)

| `HV27_DCP_TRACE_MODE` | mailbox tracer | what the handler does | proxy requests from the handler |
|---|---|---|---|
| `async` (default) | `TraceMode.ASYNC` | decodes each mailbox word from its own bits, logs it (`kind:"word"`) | **never** |
| `sync` | `TraceMode.SYNC` | same, plus reads the RPC header/payload out of the DCP shared memory (DART walk) | yes, only with the guest stopped (`hv.ctx` set) |

### Why no readmem in ASYNC

Evidence is the crash log `captures/trace-cpus1-dcprpc-20261109-0229-async-crash.log` (line ~1881 onward) and
`proxy.py`/`hv/__init__.py`:

- An ASYNC mmiotrace event reaches the client from `proxy.reply()` (the `REQ_EVENT` branch) while the guest keeps running;
  `hv.ctx` is `None`. m1n1 itself says so in `shellwrap`: "Running in asynchronous context. Target operations are not
  available."
- Any request the client sends while the guest runs makes m1n1 stop the guest with a user interrupt (`TTY> HV: User interrupt`
  in the log) and answer with a `REQ_BOOT` reply. Inside our `readmem`'s `reply()` loop that reply goes to `handle_boot` ->
  `handle_exception` -> `_load_context` -> a nested `readmem` while the first request's reply is still on the wire. The two
  replies interleave and the client reads garbage (`UartChecksumError: Reply data sentinel error ... got 0x0`), then
  `unkhandler` dumps the raw UART bytes as `TTY> ...`. That one line is what turned the log binary, not the module's output.
- So a readmem from an ASYNC event callback is not legal, whether or not another event happens to be in flight: the request
  itself provokes the exception that desyncs the channel. (The same applies to an ASYNC handler that runs nested inside
  another request's reply wait: a second request there steals the first request's reply.)
- m1n1's own `m1n1/trace/asc.py` (`DEFAULT_MODE = TraceMode.SYNC`, reads DVAs with `hv.iface.readmem`) and
  `proxyclient/hv/trace_dcp.py` only read from SYNC/HOOK callbacks, where `handle_vm_hook_mapped` runs inside
  `handle_exception` with the guest stopped and `ctx` loaded. This module now follows the same rule.

Guards in the module: every proxy read goes through `_readmem`, which refuses (`_NoRead`) unless the mode is SYNC and
`hv.ctx is not None`; any proxy exception latches `payload_dead` (words only from then on, one console line) so a desynced
channel is never poked again. Every handler (`_mbox`, `_dart_w`, the AMCC wrapper's install) is wrapped and counts errors
instead of raising.

## How it works

- **Late install.** `HV27_DCP_INSTALL=late` (default) re-registers every SPTM AMCC register as a HOOK with the same wrapper
  shape as `hv27-trace-late.py`: `rd(addr, width=None, **kw)` installs on the first access, then returns
  `read(addr, width)` of the previously registered hook (`pread(addr)` when `width is None`); the write is forwarded
  unchanged. Standalone, the previous hook is the one `load_macos_sptm` registered, i.e. exactly `hv.sptm_amcc.read/.write`
  (the module detects that and uses them directly, as trace-late does). If another module's wrapper is already there
  (`hv27-trace-late.py` armed first) it is chained, so both fire; pass this module AFTER `hv27-trace-late.py`.
  Registers already armed by this module are skipped. The arm line prints `armed on N AMCC registers (late install, K
  chained ...)`. `HV27_DCP_INSTALL=now` registers at load (not recommended: tracers before SPTM init panic the guest).
- **What is trapped.** `/arm-io/dcp` reg0+0x8000 (0x4000, read+write) in the chosen mode; `/arm-io/dart-dcp` reg0+0..0x4000
  (writes only, ASYNC) **only in SYNC mode** (the walk needs TTBR/TCR/TLB_OP), or in ASYNC with `HV27_DCP_DART_TRACE=1` (log
  only). The DCP shared memory is not trapped. No ASCTracer/DCPTracer classes, nothing from `m1n1/fw/dcp`.
- **Mailbox decode.** INBOX0 0x800 / INBOX1 0x808 writes form an AP>DCP word (sent when 0x808 is written); OUTBOX0 0x830 /
  OUTBOX1 0x838 reads form a DCP>AP word (popped on the 0x838 read). Endpoint = msg1[7:0]. ep0 mgmt words are printed and
  logged (STARTEP, HELLO, ...), other endpoints are counted (`HV27_DCP_ALLEP=1` logs them). ep 0x37 words use the m1n1
  `dcpep.py` layout: TYPE 3:0 (0 SET_SHMEM dva=63:16, 1 INIT_COMPLETE, 2 MSG), MSG: LEN 63:32, OFF 31:16, CTX 11:8 (0 CB,
  2 CMD, 3 ASYNC, 4 OOBCB, 6 OOBCMD, 7 OOBASYNC), ACK bit 6.
- **ASYNC (words only).** Each ep0x37 word becomes one JSONL record, `kind:"word"`, with `wt` (`set_shmem`, `init_complete`,
  `call`, `ack`, `raw`, `mgmt`, `other`), `dir`, `ctx/ctxn`, `ch` (channel the word refers to), `off`, `len` (call: LEN of the
  whole entry = 12-byte header + in + out; `body_len = len-12`), `msg0`, `msg1`, `why:"async"`. An ack word is matched to
  the latest unacked call on the same channel/OFF (`call_seq`, `call_len`, `call_off`), so offline you can pair them. The tag
  and the in/out split live in the shared memory and are not available in this mode.
- **SYNC (payloads).** Shared-memory buffers: CMD 0x0, OOBCMD 0x8000, ASYNC 0x40000, OOBASYNC 0x48000, CB 0x60000, OOBCB
  0x68000. Each entry at buf+OFF is `reversed 4-char tag, in_len (u32), out_len (u32), in data, out data`. A call (either
  direction) is read at the call word; the ack word reads the out data from the remembered call. Records keep the old kinds
  (`set_shmem|init_complete|call|ack|raw`) with `tag, tag_hex, in_len, out_len, lenok, in, out, call_seq`. If a payload
  cannot be read (no shmem DVA yet, no stopped guest, proxy error) that word is logged as `kind:"word"` with `why`.
- **DVA to PA (SYNC).** `SET_SHMEM dva` is the full `msg0>>16` (0x10000044000 in the 0105 capture). The DART is walked by hand
  (t8110, 16K pages, 11-bit levels at shifts 36/25/14, PTE valid = bit 0, next/PA = bits 37:10 << 14). TTBR/TCR come from
  the ADT (`l1-tt-23`, `l1-tt-24`; 4-level because vm-base+vm-size = 4 TiB > 2^36) and are updated from traced TTBR/TCR
  writes; translations are cached and dropped on traced TLB_OP / TTBR / TCR writes. SID 23 is tried first, then 24.
  No MMIO read of the DART unless `HV27_DCP_DART_LIVE=1`.
- **Console is grep-safe.** Every module line is printable ASCII (`_p()` escapes anything else as `\xNN`), payloads are shown
  as hex only (no ASCII column), the tag is shown as ASCII-with-dots plus `tag_hex` in the JSONL. Console in ASYNC is
  throttled: the first `HV27_DCP_FULL_N` (6) lines per (dir, ctx, wt, len), then every 50th (`HV27_DCP_CONSOLE_ALL=1`
  prints all); the JSONL always has every word.

## Run it

Line to add to `~/Work/agents/hv27/run-hv27.sh` right after the `TR=(); ...` line (125):

```bash
    [ -n "${HV27_DCP_TRACE:-}" ] && TR+=(-m "$H/hv/hv27-dcp-trace.py")
```

Words only (default), standalone or together with the PrintTracer groups (this module appended after trace-late):

```bash
HV27_DCP_TRACE=1 ~/Work/agents/hv27/run-hv27.sh guest nodisk
HV27_TRACE=dcp HV27_TRACE_MBOX_ONLY=1 HV27_TRACE_LATE=1 HV27_DCP_TRACE=1 ~/Work/agents/hv27/run-hv27.sh guest nodisk
```

Payloads (guest stalled per mailbox access, slower; do not run PrintTracer ASYNC over the same page with it unless you want both):

```bash
HV27_DCP_TRACE=1 HV27_DCP_TRACE_MODE=sync ~/Work/agents/hv27/run-hv27.sh guest nodisk
```

Output: client stdout (`runs/<ts>-guest-nodisk/hv.log`), grep `DCPRPC:` (safe with plain `grep`); JSONL
`captures/dcp-rpc-<stamp>.jsonl`. Tunables are listed at the top of the module.

## What to look for

- ASYNC: the call/ack structure and sizes: `jq -r 'select(.kind=="word" and .wt=="call")|[.dir,.ctxn,.off,.len]|@tsv'
  | sort | uniq -c`. Distinct `len` values per (dir, ctx) are the distinct methods' sizes; pair with a SYNC run for the tags.
- SYNC: method tags `jq -r 'select(.kind=="call")|[.dir,.ctxn,.tag,.in_len,.out_len]|@tsv' | sort | uniq -c`.
  `AP>DCP ctx=CMD` tags are the AP-to-DCP methods, `DCP>AP ctx=CB/ASYNC` callbacks/notifications. HDR / colour work: AP>DCP
  calls with a large in-payload, full payload from the JSONL.
- `lenok=false` / `LEN-MISMATCH`: layout differs for 27.3 or the buffer was reused (not expected in SYNC, the guest is
  stopped). A tag that prints as `....`: wrong buffer offsets or a failed translation (see `untranslated` lines).
- `ACK WITHOUT CALL` / `no matching call seen`: the call word was before install or its event was lost.

## Limits and unverified assumptions

- ASYNC carries no tags/payloads by design. SYNC is untested on hardware for the DCP mailbox (SYNC stalls the guest per
  access; SEP/DCP firmware handshake timeouts are possible, try it with `cpus=1` first).
- Not verified on hardware: that the 27.3 DART still uses the t8110 PTE layout and 4-level walk, the shared-memory channel
  offsets and the `tag/in_len/out_len` header, the OOB ctx mapping.
- Only ep 0x37 is decoded. AFK endpoints (0x20-0x2d, 0x31) are counted, not parsed.
- Reads/writes narrower than 8 bytes at the four message offsets are ignored (counted as `odd`).
- The DART TTBR seed is the iBoot table from the ADT; a TTBR change before install is missed in SYNC
  (`HV27_DCP_DART_LIVE=1` or `HV27_DCP_SHMEM_PA` recover it).

## R1 (standalone first-instruction fault): finding

The standalone fault is not caused by this module's arming code (details in the 2026-11-09 report): the stage-2 map at
`hv_start` is identical to the working chained run, the hook never ran before the fault (no `DCPRPC: SPTM read AMCC` line),
and the identical fault (IABORT at 0x200, x0=0x20003, right after `hv_amcc:` and before any `hv_sprr:` line) occurs in runs
with no `-m` module at all (`runs/20261108-160901-guest-nodisk`) and with the eager trace (`runs/20261108-164955-...`):
3 of the 25 guest runs that reached "Jumping to entrypoint". It is an SPTM early BRK (TRACE-UNDER-SPTM.md B.1); the
`handle_brk` guard in `hv/__init__.py` now stops in the shell at the real PC instead of reflecting it to vector 0x200.
