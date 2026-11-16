# J716s stage 2: m1n1 fork -> aura (branch `j716s`)

Written 2026-11-15. Source tree: `/Volumes/m5pro/aura`, branch `j716s` on aura `main` 52af355c (#214). Nothing pushed.

## What "today's stage 2" is

`~/Documents/m5pro-next-park/ingredients/m1n1-hostwait-0x430000.bin` (sha256 `9db33e69ffc2ee9e6b05b5432d68ec4f4a7d5088fb28127c631943f5031e9c0b`,
bytes [0, 0x430000) of the installed daily `629fc84c`) is the "hostwait daily" loader:

- m1n1 `v2.0.0-133-g88002ed4` (the string in the image) = `rolotrealanis98/m1n1` branch `hv27-t6050` @ `63e6053c`
  (branch `win-el2` of the fork; its 152 commits over aura main are upstream m1n1 plus the J716s stack below)
  + one commit `88002ed4` "hostwait daily: USB proxy window before the payload; P_CHAINLOAD_IMAGE"
  (`m5pro-windows/tooling/hostwait/m1n1-patches/0001-*.patch`; the commit itself is only in the Windows agent's scratch, not on the fork).
- Built `CHAINLOADING=0` (plain stage 2), Fedora 43 container, clang/lld 21, rustc 1.99.1 (`m5pro-windows/tooling/hostwait/build-daily.sh`),
  rebuilt byte-identical in the Windows agent's check (`INSTALL.md`: loader `9db33e69` + tail = daily `629fc84c`).
- Not the omacom PR stack (#30, #33-#37, aurora-silicon/m1n1#65): those branches are the same changes rebased on `integration/aurora`
  (`fork/omacom-t6050-*`, `fork/omacom-wdt-keep`), used here as the reference for each port. The daily itself carries older forms of them
  (the 0001-0021 series of `m5pro-linux/patches/m1n1/`) plus the Windows project's HV work.
- `chosen.m5pro,boot-slot` and `chosen.m5pro,pmu-scrpad` are set by **stage 1** (`patches/m1n1-stage1/0016`: it picks the slot from iBoot's PMU
  boot-error count and appends them as `chosen.*` variables to the next stage); stage 2 only copies `chosen.*` into `/chosen`, which aura does
  generically. Nothing to port. Stage 1 also arms the 150 s watchdog and appends ` m1n1.wdt=keep` to the stage-2 boot arguments.

## Port table

Legend: **aura** = aura already does it (no change); **ported** = commit on `j716s`; **dropped** = not carried, with the reason.

| # | Behaviour of today's stage 2 | Source (fork) | Result | Where / why |
|---|---|---|---|---|
| 1 | Stage-2 plain build, payload appended after the image (variables, `Image.gz`, DTB, cpio), entry at base+0x800, vars after the payload from stage 1 | m1n1 core | **aura** | plain `make` build; `payload.c` keeps the legacy `m1n1_` record prefix; chainload entry offset `0x800` is the same ABI |
| 2 | Watchdog stays armed into Linux on `m1n1.wdt=keep` (stage 1 arms 150 s; systemd/apple_wdt feeds it) | `64c8ce21` (#36), `2800f8bb` | **ported** `dc70e00e` | aura disabled it unconditionally; token kept in its m1n1 spelling because stage 1 is not replaced |
| 3 | Dead-man feeding: proxy requests and HV tick reset the count; a silent host lets it bite | `479b13ef` | **ported** `dc70e00e` | `wdt_kick()` in `proxy_process()` and `hv_tick()`; `P_WDT_DISABLE` still disarms |
| 4 | RVBAR relay: secondaries locked to stage 1's base are forwarded to the relocated stage 2 (18 CPUs) | `6a0102a3` / `0015` / `ff75a40d` (#33) | **ported** `d3b75564` | aura's relay is a branch and only for aura vectors it can reach; T6050 now uses aura's absolute veneer, admitted by `smp_old_vector_owned()`; page reserved for the OS |
| 5 | CTRR avoidance and relocation above the window (#4, #13) | `2800f8bb`, `d72aad82` | **dropped** | stage 1 only (`chainload_image()` of the stage that loads `boot.bin`); a plain stage 2 reaches `chainload_image()` only through `P_CHAINLOAD_IMAGE` (row 8), where aura's own placement logic applies |
| 6 | `MAX_CPUS` 32 -> 24 and raw-image size cliff | `a08771d6`, #14 | **dropped** | the cliff was stage 1's 0x430000 slot. Aura's `MAX_CPUS` is 32 (J716s has 18 CPUs); this image is smaller than the old loader (sizes below). PR #262 (64) not needed |
| 7 | 4 s USB proxy window before the payload; `P_EXIT` boots the payload; no host: boots as before | `88002ed4` | **ported** `7219e44c` | `HOSTWAIT_MS` in `config.h` (plain builds only, 0 disables), uses aura's `uartproxy_wait_stage1()`; on T6050 schedules aura's explicit USB2 gadget (see risks) |
| 8 | `P_CHAINLOAD_IMAGE` (0x1500) for the Windows test loop | `88002ed4` | **ported** `7219e44c` | op + `proxyclient/aura` method; calls aura's `chainload_image()`. `hostwait.py`'s identity check compares memory with the old daily bytes and needs the new image hash |
| 9 | Skip the USB-PD HPM probe on T6050 (#5) | `08746507` | **aura** | aura's T6050 `usb_init()` returns before the HPM loop (`usb_cdc_deferred_usb2()`); its gadget is a separate explicit USB2 path (`usb_t6050_init`) |
| 10 | HPM power-up with bounded SPMI/HPM commands, PIPE park on the dummy producer, ATC combo-PHY tunables from the ADT | `14b2b97b`, `8b7ddcac`, `b42d74ff` | **aura (different)** | aura: `usb_t6050_init` (USB2 + dummy PIPE), `kboot_atc.c` T6050 tunables, `tps6598x_route_ap_usb2`. State left for Linux's tether can differ (see risks) |
| 11 | PMP DART (`dart-pmp0`) DAPF | `09792c61` | **aura** | #193 (`c0842f7f`) |
| 12 | DAPF: skip `dart-aop` on T6050 (async SError slice 6) | `3aeaf10e` | **ported** `9880be01` | aura programs every DAPF in the ADT, and the J716s ADT has `dart-aop` |
| 13 | DAPF: clamp slices to the register window | `3aeaf10e` | **ported** `8609ceb6` | aura walks the whole property |
| 14 | Bring-up diagnostics (`KBOOT_PHASE`, yellow band), `P_KBOOT_GET_DT` | `3aeaf10e` | **dropped** | debugging aids of the bring-up |
| 15 | `chosen.asahi,show-notch=1` keeps the notch rows | `974c9248` | **aura** | `kboot.c` handles `asahi,show-notch` |
| 16 | N1: fill the hand-off in the DT (tunables, `apple,link-trained-by-bootloader`, port status), wifi0/bluetooth0 MACs; the daily does **not** train (kernel trains, loader leaves it down) | `b80f4d3a`, `12aad6db`, #34 | **aura (different)** | aura trains port 0 itself (`pcie_t6050.c`, SMC N1 reset) and writes the hand-off (`pcie_t6050_handoff_fdt`); aliases handled by `kboot.c`. j716s-next supports both (adopts a trained link or trains it). First-boot risk |
| 17 | N1 training behind `chosen.m5pro,n1`, SMC release, warm port | `2fb19ab7`, `956532c6`, `f994235a`, `dcbf875e` (#34, aurora-silicon/m1n1#65) | **aura** | `pcie_t6050.c` 88a69d85, `49be7071`; no switch |
| 18 | GPU hand-off for the G17S: four PMGR states, one `gfx` domain, mailboxes, UAT/fw regions, gated by `chosen.m5pro,gpu=1` | `1ad9d57e`, `2bebfe77` (#37) | **aura + ported** `240f075f` | aura's G17S hand-off enables the DT's pmgr node, `power-controller@0/@100/@110`, both mailboxes and `gpu` (the J716s DT also has `@108` cs); it admits only digests it knows: 27.0 and 27.2 (K116s). Added the 27.3 (26C5035r) G17S row from Linux's `hw/t6050.rs`. Not gated any more: `chosen.m5pro,gpu=1` becomes a harmless `/chosen` property |
| 19 | Display hand-off for the firmware-27 DCP driver (`chosen.m5,t6050-display=1`): reserve /vram, firmware version, compat, enable dcp/mailbox/DARTs/display | `5d26f9a9`, `f45e22a8`, `64bc83a7` (#35) | **aura + ported** `c263647f` | aura pins one DCP image per OS firmware (27.0, 27.2): added 27.3 beta (J716s DCP image `58CB3FFC-...`, from the 27.3 ioreg capture of this machine) with `apple,firmware-compat` 27.3.0; accepts the DT's own clocks/bw-scratch when equal to the ADT (the J716s DT has them, aura refused such a tree). Not gated any more. Phandles for dcp/disp: not needed, aura addresses nodes by path |
| 20 | 27.3 firmware strings (V27_3B) and DCP method matrix | `47850903`, 1946694593 | **aura** | `firmware.c` V27_3B, 71fb1a45, 4dd0f87f |
| 21 | Reserve every running coprocessor's `__OS_LOG` segment (dcp, dcpext0-3, aop, mtp, auss-cpu0) | `088b8c4c` (#35) | **ported** `6b91eb0d` | aura reserves only dcp/dcpext logs |
| 22 | Keep off the SEP mailbox; seed RNG from `/chosen/random-seed` | `72ed8f9c` | **aura** | `sep_warm_active`; `dt_set_sep()` is no longer fatal without a `sep` alias (the J716s DT has none) |
| 23 | AVE encoder firmware hand-over | `51148ed5` | **aura** | #171 |
| 24 | AMCC IRQ-hook skip (#8), guest timers via IMASK, AVNCR_EL2 via GL2, SPRR pool/MTE/RAM top, HV CPU_START hook (`proxyclient/hv`) | `06a770c0`, `7f2feca4`, `96393289`, `0009`-`0011`, `63e6053c` | **dropped** | hypervisor-only, never run on the Linux boot path; aura's HV is the SPTM-virt line (#257). #224 (draft) is the same CPU_START fix if the HV is wanted on T6050 |
| 25 | `wcslen` for LLVM loop idioms | `327b54b5` | **dropped** | aura links with clang 21 without it |
| 26 | Clear iBoot's failed-boot count in stage 2 | new in aura (#173) | **aura (new)** | harmless behind our stage 1, which reads and clears the count first; only differs if stage 1 is configured `chainload.pmu-clear=0` |
| 27 | Kernel suspend-to-RAM: T6050 SIO tables, sleep wake sources | new in aura (#214) | **aura (new)** | `3b3e814c`, `76f6d953` |
| 28 | Unmap ADT TZ carve-outs, NVRAM under qspi, SIQ_CFG_EL1=0, NVMe CC/CSTS from ans reg[9] | new in aura (#173) | **aura (new)** | |


## Build

Branch `j716s` at `8609ceb6`, 8 commits on aura `main` 52af355c (`git log origin/main..j716s` in `/Volumes/m5pro/aura`; nothing pushed, no PR, no comment).
Built by `build-stage2.sh j716s final-hostwait` (this folder): Fedora 43 container (Apple `container`), clang/lld 21.1.8, rustc/cargo 1.99.1
(`aarch64-unknown-none-softfloat`), GNU make 4.4.1, `make USE_CLANG=1` = plain stage 2 (no `CHAINLOADING`, no `ESP_STAGE2`, `RELEASE` unset so the
text log stays on the panel like the old build; tree passed as `git archive`, version tag `1.0.0b13-g8609ceb6`).

| File | sha256 | What |
|---|---|---|
| `aura-j716s.bin` | `f15498851abb17427ef9496ffd5a745352e47f8637e289ace757895f65693edf` | stage 2, 4 s USB window (`HOSTWAIT_MS=4000`) |
| `aura-j716s-nohostwait.bin` | `a1a68eeed24cb517f08148d7c3bf9ff79982d66b96faeea1559b7e5623447cdc` | the same with `EXTRA_CFLAGS=-DHOSTWAIT_MS=0` (no USB bring-up before the payload); version tag `...-nohostwait` |
| `aura-j716s.elf` | `6cb4ce87...` | linked ELF of the first, for symbols |

Both are **3 866 624 bytes = 0x3b0000** (old loader: 0x430000 = 4 390 912). Layout: `.init` 0x1ef28, `.text` to 0xa0000, `.rodata`+`.rela` to 0xe0000, `.data`
to 0x120000, stack to 0x3b0000 = `_payload_start`. `_file_vital_end` 0xfb770 against the limit 0x120000 (aura main without my commits: 0xfb638). Build
warnings: the 9 existing Rust dead-code warnings, none new. The strings `hostwait:`, `m1n1.wdt=keep`, `58CB3FFC-...` and `26C5035` are in the image;
the no-hostwait image has no `hostwait:` string. Build logs and symbol tables: `final-hostwait/`, `final-nohostwait/`, `baseline-main/` (aura main, same size).

## Tests

`run-tests.sh j716s tests-clang` / `TEST_CC=gcc ... tests-gcc`: aura's CI "test" workflow in the same container (pytest over `tests/python` and the two
T8122 tests, `run-pmp-boot-data.sh`, `run-t8122-gpu26-identity.sh`), arm64 native, so the native `start.S` tests run too.

| Run | Result |
|---|---|
| aura `main` 52af355c, clang | 2 failed, 738 passed, 27 skipped, 27 errors |
| `j716s` 8609ceb6, clang | 2 failed, 740 passed, 27 skipped, 27 errors (+2 passed: the new wdt-keep and T6050 veneer tests) |
| `j716s` 8609ceb6, gcc | 1 failed, 769 passed, 26 skipped, no errors |
| `run-pmp-boot-data.sh`, `run-t8122-gpu26-identity.sh` | pass |

The same 2 failures and 27 errors are on `main` itself with this container's clang 21 (`test_legacy_table_lifetime` x2; `test_display_dart_view`:
`-Werror,-Wunused-function` on `dart_gen3_tlbi_broadcast`), and clang 21 builds them nowhere else. The gcc failure is `test_xnuboot_layout`, which
calls `$CC --target=aarch64-linux-gnu` (a clang option). The tests the changes touch were adapted: the two `test_j713_*dapf*` harnesses and the SMP RVBAR
harnesses define `T6050`, the display host stand-in gets `V27_3B`. No host test models the T6050 display or GPU hand-off (they are not unit-testable without an ADT
of the J716s; there is none in the repos, only the ioreg text of the 27.3 capture).

## Packing it (`mk-next-test.py` / `mk-daily.py`)

Checked with a dry run (`pack-check.py`, a copy of `mk-next-test.py`'s logic with the aura image; nothing under the park folder or the repos
was written): `mk-daily.py` packs the aura image with the same ingredients as the j716s-next test file and its own layout check passes
(`pack-check/j716s-aura-check-*.recipe.txt`; the 41 MB test file itself was deleted, it is rebuilt in seconds).

- **Format is the same.** `image | chosen.bootargs=...\n | chosen.asahi,show-notch=1\n ... | Image.gz | dtb | initramfs`, directly after the
  image; `_payload_start == _end == file size`, the image ends in the 8-byte `STACKBOT` marker, as m1n1's did. Aura's `payload.c` reads
  gzip kernel, FDT, gzip cpio and `chosen.*` lines (limits unchanged: name 64, value 1024, 16 `chosen.` variables). Variables that stage 1
  appends after the initramfs (`chosen.m5pro,boot-slot`, `chosen.m5pro,pmu-scrpad`) are read the same way.
- **Load address:** none in the packer. Stage 1 copies `boot.bin` into RAM and enters it at `base + 0x800`; aura's `_start` is there
  (`b .Lstart_entry`, first instruction `0x1400000a`), the `AURALOAD` header at `+0x808` has `run_base = 0` (no self-move on a plain stage 2).
- **Size:** the loader slot is the image's own size, **0x3b0000** (3 866 624 bytes), not 0x430000. There is no 0x430000 limit on a
  stage 2 (that was stage 1's slot); the only limit is aura's `_file_limit` 0x120000 for code and data before the pixel data:
  `_file_vital_end` 0xfb770 in this build, 149 KB of room.
- **Packer change needed (not made):**
  - `mk-next-test.py`: `M1N1 = R/"m1n1-hostwait-0x430000.bin"; M1N1.write_bytes(daily[:0x430000])` and `mk.M1N1_SIZE = 0x430000` become
    `img = pathlib.Path(os.environ["NEXT_M1N1"]).read_bytes(); M1N1 = that path; mk.M1N1_SIZE = len(img)`. Everything else stays (the
    `daily-hostwait.bin` is still read to check the initramfs).
  - `mk-daily.py`: `check_inputs` demands exactly `M1N1_SIZE` bytes (default 0x400000). Make it `len == the image's own size`, and check that
    the image ends in `b"STACKBOT"` and its size is a multiple of 0x10000, then pin the aura image in `INGREDIENTS["m1n1"]`
    (`aura-j716s`, sha256 of `aura-j716s.bin`).
  - `NOTCH` variables `chosen.m5pro,gpu=1` and `chosen.m5,t6050-display=1` can go: aura has no such gates (they stay harmless `/chosen`
    properties if left).
  - `hostwait.py` (Windows loop): its identity check compares the loaded loader with the old daily's bytes and needs the new hash.

## First-boot risks (nothing here was run on the machine)

1. **USB window.** On T6050 aura has no automatic USB proxy; its USB2 gadget is an explicit transition (HPM0 routed to the controller)
   that enumerated on a J714s and never on a J714c. The 4 s window schedules it. If it hangs on the J716s, the stage 2 stops there and
   stage 1's 150 s watchdog sends the machine to `boot.bin.prev` (the old daily). **Boot `aura-j716s-nohostwait.bin` first** (`HOSTWAIT_MS=0`: no
   USB bring-up at all before the payload), then the hostwait image.
2. **N1.** The daily's loader does not train the N1; aura trains port 0 itself (and refuses the whole hand-off if the shared GP state or
   the storage check stops: "refusing T6050 handoff"). j716s-next adopts a trained link or trains one itself, but aura's sequence has not
   run on a J716s (only the m1n1 one did, #34).
3. **Display and GPU are all-or-nothing and silent in the loader log.** Aura refuses the display hand-off if any DT value differs from the
   ADT (dcp regs, clocks, bw-scratch, PMC window): read `/chosen/asahi,t6050-dcp-handoff` (`published`/`refused`) and the log line
   "internal display handoff refused". The GPU stays disabled on any mismatch ("T6050 G17S handoff refused at check N").
4. **Things aura does that the old stage 2 did not:** train the N1, program `dart-ave0`'s DAPF, hand the ISP/camera over (the DT now
   has the `isp` alias), clear iBoot's failed-boot count, hand over the encoder/ANE firmware. All fail-soft except the N1 and DAPF.
5. **RVBAR veneer.** Needs `smp_old_vector_owned()` to find the vector tags and a `STACKBOT` within 16 MiB after stage 1's base. If it
   refuses, only CPU 0 starts ("SMP: RVBAR ... refusing start").
6. **Tether.** The state of the ATC0 PHY/controller that Linux's device-mode tether inherits comes from aura's USB2 path now (or from nothing
   with `HOSTWAIT_MS=0`); it was already not a working link on the daily.
7. **Windows test loop.** `P_CHAINLOAD_IMAGE` runs aura's `chainload_image()`, whose placement logic differs from m1n1's; untested with a
   resident image.

## j716s-fix1 (2026-11-15, after the first hardware boot)

First boot of `aura-j716s-nohostwait.bin` (j716s-next2 kernel): `pcie-t6050: STOP: ANS is not running (before)`, `kboot: refusing T6050
handoff ...`, `No valid payload found`, then the proxy for 11+ minutes with no watchdog reset. Branch `j716s-fix1` @ `436287b0` (3 commits on
`j716s` 8609ceb6, nothing pushed):

| Commit | Bug | Cause | Change |
|---|---|---|---|
| `349f78f4` | watchdog never fired | Stage 1 (m1n1) keeps boot_args in a naturally aligned union: it reads/writes the command line at **+0x70** and appends ` m1n1.wdt=keep` there. Aura reads it at iBoot's real **+0x6c** (aura `e287bbf2`). iBoot's line is empty on the J716s, so +0x6c is a terminator and the token is a separate string 4 bytes in: `boot_options_init()` never saw it, `wdt_disable()` disarmed stage 1's 150 s watchdog. (The old m1n1 stage 2 has stage 1's layout, so it always matched.) Nothing else disarms it: `wdt_kick()` only on proxy requests/HV ticks, `wdt_host_attached()` only for aura stage 1's own watchdog, CDC is T8140-only, `P_WDT_DISABLE` only on request | if iBoot's line ends within 4 bytes, also scan the string at +4 for this one token; kboot logs `watchdog left armed for the OS (m1n1.wdt=keep)` into `aura_stage2.log`. Host test `test_wdt_keep_from_an_m1n1_stage1` (m1n1's struct + stage 1's append, iBoot lines of 0/2/4/20 chars, all revisions); fails on `j716s` |
| `575c58a5` | proxy forever | `run_actions()` ends in an unbounded `uartproxy_run()` | plain stage 2 with the token: 30 s (`STAGE2_FALLBACK_WINDOW_MS`) for a host via `uartproxy_wait_stage1()`, else `flush_and_reboot()` (WDT reset, iBoot's boot stage left set, so stage 1 counts a failure and boots the fallback). Independent of the watchdog |
| `436287b0` | kboot refusal | m1n1 stage 1's `chainload_load()` reads boot.bin via NVMe then `nvme_shutdown()`: RTKit sleep + `pmgr_reset("ANS"/"ANS2")`. The plain stage 2 never restarts ANS (no `nvme.sart=` from an m1n1 stage 1, so #213 does not apply). The storage checks need a running ANS; aura refused the whole hand-off | on a board whose ADT has no required GP port (J716s: port 0 only): a stop before any write -> `PCIE_T6050_LEFT`, nothing written to apcie0/PHY/PMGR/SMC, the tree describes the N1 port for Linux's cold train exactly as the m1n1 stage 2's `kboot_n1.c` (port + DART `okay` when `pwren-gpios` + `apple,manual-availability`, port link tunables, host `apple,tunable-{axi2af,cio3pllcore(+0x2200),pcieclkgen,phy,phy-ip-pll,phy-ip-auspma}` 4-cell); APCIe deep-sleep tables not published then (their 3-cell `apple,tunable-axi2af/-phy*` would clobber the train's lists, so deep sleep stays refused on this path). A stop after a write -> `PCIE_T6050_PARTIAL`: down ports disabled, boot goes on. Boards with a required port (J775D) keep the refusal |

NVMe safety: in the left case aura writes nothing; storage reaches Linux as stage 1 left it (stopped), as behind the old stage 2, and
nvme-apple cold-starts ANS; the shared GP init then happens in the kernel's train (the daily's path). The live-ANS check still guards
every case where aura writes. Not chosen: adopting ANS as #159 (needs a running session; m1n1's stage 1 resets it, and `nvme_init()`
refuses an off ANS without `nvme.sart=`), or training with no storage reference.

Build (`build-stage2.sh j716s-fix1 ...`, same container/toolchain): `aura-j716s-fix1b.bin` `741e9004b4bcdb610f2e2184d9d43f2fe1ed70b2a19bbdc9d789e9330b7cd835`,
`aura-j716s-fix1b-nohostwait.bin` `8d71c06acb7689332d95a2b52a2b986358c63ed51cd5a1bd9a8ce6c3741dfe93` (0x3b0000 each, `_file_vital_end`
0xfb7b0, only the 9 old Rust warnings). (`aura-j716s-fix1*.bin` without the `b` are the same code at the pre-squash id `bac23a06`.)
Tests (`run-tests.sh j716s-fix1 fix1b-tests-clang`): 2 failed, 741 passed, 27 skipped, 27 errors = the `main` baseline (+1 new test);
`test_smp_handoff_gate.py` needed a `PCIE_T6050_LEFT` stub. No host test models the T6050 left-for-OS DT path.
Test request: `/Volumes/m5pro/bench/requests/boot-aura-1.md` (file `next2-aura-fix1b-nohw-20261115-7a95410a.bin`). Built, not booted.

### boot-aura-1 result and the debug build (2026-11-15)

boot-aura-1 (`next2-aura-fix1b-nohw-...-7a95410a.bin`): logo only, no text; reset ~150 s after stage 1 armed the watchdog, fallback
`fallback-after-failure`, pmu `300130`, no journal. Reading: the token fix works (unattended fallback). A clean logo is what aura's
hand-off leaves (`fb_shutdown(restore_logo=false)` clears the text), so aura most likely vectored and the kernel died before fbcon and
before apple_wdt (else the core would ping, or a panic would restart in 10 s with `300100`). `300130` = boot_error_stage 0x30 (after
iBoot's hand-over, no clean restart). Next: `e94051a8` adds `HANDOFF_DEBUG` (debug builds only): a host that had the hostwait window
gets the proxy again for 60 s after kboot, before anything is shut down, and the log stays on the panel at the hand-off. Image
`aura-j716s-fix2-dbg.bin` `acac4771...`; host script `m5pro-linux-re/tooling/pr-verify/aura-handoff-capture.py` dumps the console ring,
the phram log and the hand-off FDT for a diff against the old loader's `/sys/firmware/fdt`. Request `boot-aura-2.md`. Built, not booted.

### boot-aura-2 result and fix3 (2026-11-15)

boot-aura-2 (`fix2-dbg`, host window + hold): Linux up in 61 s on the primary slot, display 120 Hz + VRR, GPU, N1 (trained by Linux),
NVMe, watchdog fed; capture in `/Volumes/m5pro/bench/boot-aura/run2/`. Two problems, both fixed on `j716s-fix1`:
- **One CPU** (`d1c5ac92`): the locked RVBAR 0x10004160000 is stage 1's base (m1n1, 0x430000 up to the DCP log carve-outs at
  0x10004590000); d3b75564's retired-*aura*-image test refused it. Now forwarded on T6050 like the m1n1 stage 2 did (RAM, below this
  image and the inherited top, EL2, once); the log prints the slot words it saw. Test extended.
- **Non-debug hang** (`16ab9c11`): of the boot-aura-1 vs boot-aura-2 differences only the USB side reaches hardware the kernel then
  drives. Without the host window aura never touched the T6050 USB2 controller (usb_init() defers on T6050), so Linux inherited it,
  its PHY and the PIPE mux as iBoot leaves them; the m1n1 stage 2 always ran usb_init() before the hand-off (PIPE parked at 0x42, the
  only value the kernel's combo PHY accepts at its first reset), and boot-aura-2 had aura's USB2 transition (PIPE=42). On one CPU a
  stalled MMIO access stops everything, watchdog feeding included. fb_shutdown() only clears aura's own console text and frees its
  back buffer (no hardware); the hold is only a delay. Fix: a no-window plain stage 2 runs the same USB2 transition (bounded 5 s, no
  host wait), and plain stage 2s keep the log on the panel at the hand-off. Not proven on hardware which of the two mattered.
Images (`j716s-fix1` @ `16ab9c11`): `aura-j716s-fix3.bin` (window) `26fa411e...`, `aura-j716s-fix3-nohostwait.bin` `2342da0f...`; tests 2 failed /
741 passed / 27 errors (= baseline). Request `boot-aura-3.md` (file `next2-aura-fix3-nohw-20261115-c7e2e338.bin`). Built, not booted.
