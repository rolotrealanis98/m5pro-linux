# SPDX-License-Identifier: MIT
# run_guest.py -m module: install the hv27-trace groups *late*, from inside the SPTM AMCC hook read callback.
# SPTM reads the CTRR/AMCC registers late in its own init; handle_exception runs pt_update() right after the hook
# returns, so the tracers take effect once the guest's first stage is past the phase where traced device accesses
# made it panic (2026-11-08, see TRACE-UNDER-SPTM.md D.2). Same env as hv27-trace.py: HV27_TRACE, HV27_TRACE_MODE.
import builtins, os
from m1n1.utils import irange
from m1n1.hv import TraceMode
_h27_done = False
_h27_orig_read = hv.sptm_amcc.read
def _h27_amcc_read(addr, width=None, **kw):
    global _h27_done
    if not _h27_done:
        _h27_done = True
        print(f"hv27-trace-late: SPTM read AMCC {addr:#x}; installing groups {os.environ.get('HV27_TRACE','')}")
        builtins.exec(open(os.path.join(os.path.dirname(__file__) if '__file__' in globals() else os.path.expanduser('~/Work/agents/hv27/hv'), 'hv27-trace.py')).read(), globals())
    return _h27_orig_read(addr, width, **kw) if width is not None else _h27_orig_read(addr)
for _a in hv.sptm_amcc.registers:
    hv.add_tracer(irange(_a, 4), "SPTM AMCC", TraceMode.HOOK, read=_h27_amcc_read, write=hv.sptm_amcc.write)
print(f"hv27-trace-late: armed on {len(hv.sptm_amcc.registers)} AMCC registers")
