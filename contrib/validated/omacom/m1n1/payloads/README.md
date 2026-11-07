# Boot-test payloads: omacom/m1n1 T6050 stacks on the J716s (2026-11-07)

Built by `python3 -I mk-omacom.py` (mk-daily.py as a module, `M1N1_SIZE = 0x410000`). None of these was deployed. The payload files contain the board's FTAB in the initramfs, so they are PRIVATE: mode 600, never committed. The recipes are next to them, and the hashes are in `SHA256SUMS`.

| Payload | m1n1 (build image, branch tip) | Kernel / DTB | chosen lines | Stage 1 watchdog | How to boot |
|---|---|---|---|---|---|
| `omacom-t6050-bringup-20261107-0ff98ed2` | c02, `omacom/t6050-bringup` | daily `a0f2f30c967b` / daily DTB | show-notch | **disarmed** by this loader (no `m1n1.wdt=keep` support) | **attended**, from a **full power-off** (no N1 code: a restart with the N1 in use hangs a loader without the warm-N1 entry once) |
| `omacom-t6050-n1-20261107-8d2a9d1d` | c07, `omacom/t6050-n1` | daily / daily DTB | + `chosen.asahi,t6050-n1=4` | **disarmed** | **attended**; a warm restart is fine (warm-N1 entry included) |
| `omacom-t6050-gpu-20261107-8fe1fce1` | c08, `omacom/t6050-gpu` | E2 `3671d907d570` / E2 DTB + `&gpu`, `&pmgr_gfx` okay | + n1=4 | **disarmed** | **attended** |
| `omacom-t6050-display-20261107-916071aa` | c12, `omacom/t6050-display` | daily / DCP-B0 DTB (display nodes, no bw-scratch) | + n1=4, `chosen.asahi,t6050-display=1` | **disarmed** | **attended** |
| `omacom-wdt-keep-20261107-2014252d` | c13, `omacom/wdt-keep` (full stack) | daily / daily DTB | + n1=4 | **kept armed**: honours the ` m1n1.wdt=keep` our A/B stage 1 appends | **unattended OK** (loop + A/B stage 1, as for the daily) |

All payloads: self-test on (`m5.selftest=1`: reverts to `boot.bin.prev` if there is no network 90 s after network-online), battery driver on.

The self-test only covers a boot that mounts the root. In the four "disarmed" payloads, a hang in m1n1 or in early boot parks the machine (in the proxy, or frozen). The stage 1 watchdog is off, and the PMU boot-error count does not cover a boot that stops in the proxy. Recovery is the #65 v2 one: macOS over Tailscale, mount the ESP, restore `boot.bin`.

Expected differences from the lineage loaders, all of which are this tree's behaviour rather than a payload problem:
- **USB-C**: omacom has no T6050 combo-PHY tunable producer (our 0021) and no T6050 PIPE park in m1n1 (the series kernel parks the PIPE itself). The daily DTB has no baked tunables. The USB gadget network may come up at USB 2.0 or not at all. The N1 payloads have Wi-Fi for the self-test. The bring-up payload has no N1, so it can self-revert for lack of network even if the loader worked. Judge it by the panel (18 CPUs, root mounted).
- **DAPF**: only the MTP DAPF is programmed (#26). The lineage programmed every DAPF with a window clamp, plus `dart-pmp0`.
- **Stage 2 size**: 0x410000, so the variables sit at 0x410000. `mk-daily.py --deploy-plan --payload` looks for the self-test flag at 0x400000 and would call these "daily". Write the plan by hand, or use mk-e2.py's `plan`.

What to look for on the panel or in the stage-2 log (`phram` mtd0):
- all: no `is not alive`; `SMP: installed RVBAR relay at 0x... -> 0x...` once; Linux with 18 CPUs.
- n1: `pcie-t6050: entry: linksts ...`, `gP13 reads ...`, `port 0 link Gen1 x1`, `n1: port 0 up: root port ...`.
- gpu: `FDT: GPU: T6050 GPU handed off: UAT, firmware and mailboxes from the ADT`, then the aurora DRM device in Linux.
- display: `DCP: T6050: handed off: framebuffer 0x...+0x..., firmware 27.3 beta, compat 27.3.0, nodes enabled`.
- wdt-keep: `Primary WDT left armed (m1n1.wdt=keep)`.
