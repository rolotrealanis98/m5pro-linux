#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only: per-cluster ACC CLUSTER_PSTATE (cpm-impl-reg + 0x20020) and the PMGR CPU_START
block on the T6050, from the m1n1 proxy. XNU's AppleT6050PMGR::configCPUComplexPowerState
clears bit 23 (m1n1: CLUSTER_PSTATE_M2_APSC_DIS) of this register to enable a complex;
m1n1's cpufreq has no T6050 table so it never touches it. Arm the watchdog first:
    wdt-arm.py 60 && cluster-pstate-probe.py && wdt-arm.py --off
"""
from m1n1.setup import *

adt = u.adt
print(f"m1n1 base {u.base:#x}")
cpus = [c for c in adt["/cpus"] if c.name.startswith("cpu") and c.name != "cpus"]
c1 = next(c for c in cpus if c.name == "cpu1")
rv = p.read64(c1.cpu_impl_reg[0])
print(f"cpu1 RVBAR {rv:#x} -> {'stage-1 (RVBAR == this image)' if rv & 0xffffffffff000 == u.base else 'CHAINLOADED image'}")

clusters = {}
for c in cpus:
    cpm = getattr(c, "cpm_impl_reg", None); acc = getattr(c, "acc_impl_reg", None)
    print(f"{c.name:6} id {c.cpu_id:#5x} cluster {c.cluster_id} core {c.cluster_core_id} type {c.cluster_type} "
          f"impl {c.cpu_impl_reg[0]:#x} cpm {cpm[0] if cpm else None} acc {acc[0] if acc else None}")
    if cpm: clusters.setdefault(c.cluster_id, (cpm[0] & ~0xffffff) + 0xe00000)  # DVFS block, like m1n1 cpufreq cluster->base
print()
for cid, base in sorted(clusters.items()):
    ps = p.read64(base + 0x20020)
    st = p.read64(base + 0x20050)
    print(f"cluster {cid} ACC {base:#x}: PSTATE {ps:#018x}  busy={ps>>31&1} set={ps>>25&1} "
          f"APSC_DIS(b23)={ps>>23&1} b22={ps>>22&1} b20={ps>>20&1} apsc_busy(b7)={ps>>7&1} "
          f"des1={ps&0x1f} des2={ps>>12&0xf}   STATUS {st:#018x}")
sb = adt["/arm-io/pmgr"].get_reg(0)[0] + 0x88000
print("\nPMGR CPU_START:", " ".join(f"+{o:#x}={p.read32(sb+o):#x}" for o in range(0, 0x1c, 4)))
