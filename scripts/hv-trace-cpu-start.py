# run_guest.py -m script: log how macOS + SPTM release a T6050 secondary core.
#   tools/run_guest.py --sptm-mode emulation -p sptm.macho -t txm.macho \
#       -m hv-trace-cpu-start.py -l guest.log kernelcache.macho "-v debug=0x14e"
# Runs inside run_guest's namespace (hv, irange). The PMGR page is shared with
# every other power domain macOS polls, so only the CPU_START block is traced
# for reads; everything else is write-only to keep the log readable.
from m1n1.utils import irange

pmgr = hv.adt["/arm-io/pmgr"].get_reg(0)[0]
hv.trace_range(irange(pmgr + 0x88000, 0x100), name="cpu_start")
hv.trace_range(irange(pmgr, 0xa8), read=False, name="cpu_ps")

for cpu in hv.adt["cpus"]:
    impl = cpu.cpu_impl_reg[0]
    hv.trace_range(irange(impl, 0x1000), read=False, name=f"{cpu.name}.impl")

print(f"hv-trace-cpu-start: pmgr {pmgr:#x}, {len(list(hv.adt['cpus']))} cpu impl pages traced")
