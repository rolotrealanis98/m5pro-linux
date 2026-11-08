# hv tools (read-only probes over the m1n1 USB proxy)

Run from the proxyclient directory of the m1n1 tree that built the running stage-2, with `M1N1DEVICE` set:
`PYTHONPATH=. python ../../path/to/<probe>.py`. Every system-register read goes through m1n1's exception guard,
so an undefined register raises `ProxyError` in the client and m1n1 keeps running.

| tool | what | J716s result 2026-11-08 |
|---|---|---|
| `gic-probe.py` | ID registers (PFR0/PFR1/MMFR0/MMFR1), HCR_EL2, the AIC node | PFR0.GIC = 0, EL2 present, VH=1, AIC3 at 0x280400000 |
| `ich-probe.py` | the GICv3 virtual CPU interface registers `ICH_*_EL2`, `ICC_SRE_EL2/EL1`, and the physical `ICC_*_EL1` from EL2 | `ICH_VTR_EL2` = 0x90580007 (8 LRs, 5 prio bits, no GICv4), `ICC_SRE_EL2` = 0xf; physical ICC_* undefined |
| `icv-probe.py` | from EL1 (`el1_call`): are `ICC_*_EL1` accesses routed to the virtual interface when `ICH_HCR_EL2.En` = 1 | yes: PMR 0xf8, IAR1 0x3ff, BPR1 3, RPR 0xff. The optional ack test (`ICV_ACK_TEST=1`) delivers a real virtual IRQ to EL1 and wedges the proxy (no handler there): only inside a guest |

Record: `contrib/validated/integration/RESULTS.md` (2026-11-08 19:37 entry). Consumer: the Windows track
(`m5pro-windows`, OPEN-QUESTIONS Q1).
