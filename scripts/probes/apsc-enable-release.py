#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Clear CLUSTER_PSTATE_M2_APSC_DIS (bit 23 of cpm-impl-reg + 0x20020) on the given clusters,
the way AppleT6050PMGR::configCPUComplexPowerState(complex, true) does, and show the result.
Run smp-reset-crumb.py afterwards to see whether a released core now executes its RVBAR.
    apsc-enable-release.py [cluster ...]     # default: 0
"""
import sys, time
from m1n1.setup import *

want = [int(a) for a in sys.argv[1:]] or [0]
adt = u.adt
clusters = {}
for c in adt["/cpus"]:
    if c.name.startswith("cpu") and c.name != "cpus" and getattr(c, "cpm_impl_reg", None):
        clusters.setdefault(c.cluster_id, (c.cpm_impl_reg[0] & ~0xffffff) + 0xe00000)
for cid in want:
    base = clusters[cid]; reg = base + 0x20020
    v = p.read64(reg)
    print(f"cluster {cid} PSTATE before {v:#018x} (APSC_DIS={v>>23&1})")
    if v & (1 << 23):
        p.write64(reg, v & ~(1 << 23))
        for _ in range(100):
            if not (p.read64(reg) & (1 << 7)): break
            time.sleep(0.001)
    v = p.read64(reg)
    print(f"cluster {cid} PSTATE after  {v:#018x} (APSC_DIS={v>>23&1} apsc_busy={v>>7&1})")
