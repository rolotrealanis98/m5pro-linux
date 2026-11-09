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

## 2026-11-08 night, second study and the tools it produced

- `TRACE-UNDER-SPTM-2.md`: no silent path exists in the hypervisor for a traced access (every early return prints
  or opens the shell), the guest runs in EL1&0 under the one stage-2 table, ASYNC events are pushed per event; so
  zero events means no access in the window. Live installs after SMP bring-up land after the drivers' init bursts
  and a static console makes no DCP traffic. Tracing from guest start is the way (`hv27-trace-late.py`, installed
  from the SPTM AMCC-read callback, mailbox pages only via `HV27_TRACE_MBOX_ONLY=1`), with a tripwire
  (`p.hv_map(page, 0, 0x4000, 0)`) as the decisive check.
- The single-core traced guest panicked on `msr S3_7_C15_C11_3` (AppleT6050CLPC): an unlisted sibling of a
  virtualised register family. Client-side fix: the text patcher rewrites that MSR to NOP and the MRS to
  `mov Xd, xzr` (sprr.py); `pt_update` now brackets its TLB invalidate with `dsb ishst` / `dsb ish; isb`.
- `shot.sh`: screenshot of the guest's panel through the proxy (boot-args framebuffer, 31 MB, ~20 s) as PNG, half
  size plus a full-size crop of the last text rows. Replaces photos of the panel; it is how the panic was read.
