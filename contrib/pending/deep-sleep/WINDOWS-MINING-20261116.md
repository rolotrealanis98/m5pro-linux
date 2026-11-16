# What the Windows-port repo gives Linux for display sleep, deep sleep, s2idle and hibernation (2026-11-16)

Static read only; the MacBook was not contacted. `W:` = `m5pro-windows` (main `7b74a358`), `L:` = `m5pro-linux`,
`DS:` = `/Volumes/m5pro/wt/deep-sleep` (`771acfd032cc`). The raw Linux DCP capture the Windows agent took on
2026-11-12 is `~/m5pro-archive-20261112/github/captures/display/dcpcap1/capture-final.dcpc`; parse it with
`python3 -I W:drivers/display-dcp/dcpcap/dcpcap_parse.py <file> --dump --type CMD` (or `--extract DIR`).

## 1. 27.3 DCP tags for the firmware 27 sleep

The Windows repo has **no macOS 27.3 sleep trace and no A500-class (AP-link release) tag**. It does give runtime
proof, on this J716s with DCP 27.3, of every table-backed method the sleep's display stage and power call use,
with the same argument bytes as the J714s sleep data. Combined with our own dispatch check
(`L:contrib/validated/aurora/prs/dcp-27.3/verify-kernel/`), those entries are facts, not candidates.

| 27.0 literal in `DS:drivers/gpu/drm/apple/dcp-v27-sleep.inc` / `iomfb.c` | 27.3 | Evidence | State |
|---|---|---|---|
| A484 set_power_state (in 0x10, out 0x8) | **A535** | same handler 27.2->27.3 (`tags-verify.txt:45,88`), sizes (`method-sizes.txt:40`); J716s: Linux sends `01 00..` on OOBCMD and gets `01 00 00 00 00 00 00 00` (capture #1624/#1627); the Windows client got "client open + power 0" (`W:captures/display/dcp-live/L2b-step2-20261111T090022Z/step2/launcher.txt:204`, `L3-hw-step2-20261112T012014Z/launcher.txt:212`) | known; only state 1, plain form, OOBCMD proven. State 0, the flags form (`01 00 00 01 01 00 00 00`) and the CMD context are unproven on 27.3 |
| A414 pipe_cfg_414 (8/8) | **A464** | `tags-verify.txt:34,77`, `method-sizes.txt:29`; J716s: in = 8 zero bytes (= J714s `sleep-display-stage-args` A414 part), reply `01 00..` (capture #1572/#1575) | known, runtime |
| A489 pipe_query_478 (0/4) | **A540** | `tags-verify.txt:35,78`, `method-sizes.txt:30`; sent 3x per Linux client open (#1576/#1588/#1596) | known, runtime |
| A487 pipe_set_476 (4/0) | **A538** | `tags-verify.txt:37,80`, `method-sizes.txt:32`; J716s: in = u32 1 (= J714s stage arg) (#1592) | known, runtime |
| A412 is_main_display (0/4) | **A462** | `tags-verify.txt:16,59`, `method-sizes.txt:11`; reply 1 (#1600/#1603) | known, runtime |
| A407 swap_submit (J714s) | A458 | 2362 swaps in the capture (`W:captures/display/linux-dcpcap/20261112T011544Z-dcpcap1/parse-summary.txt:13`) | known |
| A115 (UnifiedPipeline, in/out word) | A115 (likely) | in the 27.3 UP dispatch (fingerprint lists, `tags-verify.txt`); UP tags below A384 did not move 27.0->27.3; not one of the 41 verified methods; never sent on 27.3 | inferred |
| A442 (OOB, in 0x5c, out 0x1004) | A492? | 27.0 AP group is A400-A492, so A442 is a table entry: +50 in 27.2, below the 27.3 insert at A521. No evidence in either repo | inferred only |
| A500 sleep/wake form (in 4, AP-link release, compared in code) | **A550 or A551: missing** | nothing in the Windows repo. The 27.3 DCP syslog names the module, `ap_link.c:301` (Windows resident consoles). On 27.3, A500 is set_parameter_dcp (in 0x28, `method-sizes.txt:15`), so the 27.0 four-byte A500 lands on it short | missing |

Related methods, also handler-identical and usable for a DPMS power-down: A517 last_client_close (4/4,
`tags-verify.txt:84`), A508 enable_disable_video_power_savings (4/4, sent at every Linux open), A529
flush_supports_power (4/0, sent with 1 at boot). Callback D572 (powerUpDART) arrives 12 times in a normal 27.3
session (`parse-summary.txt:14`), so its ID is unchanged.

**To fill a 27.3 sleep table:** the display stage (A464, A540, A540, A538, A540, A462) and set_power_state (A535)
can go in now, behind the existing gate. Still needed: the A5x0 compare in the 27.3 `t605xdcp` dispatch (sithglan's
`movk wN,#0x4135,lsl #16` search), plus checks of A442 and A115. The switch emulator already ran on a 27.3 image
(`emu-rerun.txt:3-4`, "j716s-fw_Firmware_dcp", 2026-11-07), so that image existed on some host: find it there.
The emulator found 94 AP tags (A450-A543), and the 27.2 run had no A550 among its 93, so its sweep does not catch
in-code compares; it needs extending for this.

Context risk: on 27.3 only OOBCMD was used for set_power_state. The J714s macOS order sends A484 on CMD
(`DS:iomfb.c` `v27_sleep_power_oob` = 0), while H17P firmware never answers it on CMD (`iomfb_template.c:497-500`).
Try one context per boot, and log which one.

## 2. Power domains, PMGR, SMC

- **macOS's coprocessor sleep policy (ADT):** `iop-ans-nub` and `iop-gfx-nub` carry `shutdown-sleep`. `iop-aop-nub`,
  `iop-pmp0-nub` and `iop-smc-nub` carry `no-shutdown`. SMC and DCP nodes carry `cold-boot-after-hibernate`
  (`W:findings/platform/POWER-END-STATE-20261114.md:81`; `m5pro-linux-re` `captures/m5scan/04-gpu.txt:102,148`,
  `08-smc-battery.txt:300`, `02-dcp-display.txt:317`). So in sleep macOS stops ANS and the GPU coprocessor; it does
  not merely keep them alive.
- **ANS can be cold-restarted:** stage-1 m1n1 shuts ANS down before the next stage, and Linux restarts it on every
  boot with a fresh RTKit handshake and no PMGR reset. m1n1's `nvme_shutdown`, PMGR reset included, came back clean in
  0.59 s (`W:docs/HANDOFF-2026-11-09-LIVE.md:339-341,383-384`). An ANS shutdown in s2idle (macOS-style) therefore has a
  restart path that already runs on every boot. Contrast #1698's keep-live, which crashed.
- **Backlight-only off on 27.3** (what our soft DPMS does): five off/on cycles; the first swap completed 7-11 ms after
  the panel came back on (`W:findings/runs/20261115-w2a/README.md:6`). The DCP power-down boot (`AgxDcpOff=2`:
  A464 -> A462 -> A535{0} on OOBCMD, no flags, no A5x0) **never ran** (`README.md:3`).
- **System power under Windows:** PSTR median 9.85 / 11.1 / 12.8 W on an idle desktop (`W:findings/runs/20261115-power-w1/README.md`,
  `20261115-w1b/README.md`), no lower than Linux. While tethered, the debug cable powers the Mac and AC never reads
  offline (`W:findings/runs/20261115-pw1a/README.md`, criterion C).
- **DCP firmware syslog on 27.3** (Windows consoles): `FramebufferDCP.cpp:4846 clamshell value is 1` (the DCP tracks
  the lid), `init_power_lut: failed to read power-lut-data-x`, `set_PMU_service: failed to read PMU temperature
  property`, `set_run_mode_safe: deferring: 2 -> 4`. No power-off or sleep strings were seen.
- **SMC and PMGR:** nothing new. Every key the Windows SMCP reads (`PSTR`, `PDTR`, `PHPC`, `MSLD`, `bHLD`, `B0*`,
  `MBSE`, `NTAP`, PMU `0xf801`/`0xf80f`) is ported from our drivers. The hypervisor forces UART0 and ATC0 USB on and
  filters guest GPU PS writes to ACTIVE; it does no runtime gating.

## 3. Hibernation and Modern Standby

- Windows never hibernated or entered standby on hardware. W6 `pr2`: the FADT S0-idle flag was accepted (AoAc yes),
  but `powercfg /a` did not list S0 standby, the PEP stub never started, and no sleep was entered
  (`W:findings/runs/20261115-w6/README.md`). Nothing here transfers to Linux.
- Transferable:
  - PMU scratchpad marker `0x57` at `0xf803` survives a restart: Windows uses it to boot itself again. Whether it
    survives a power-off is untested (`W:findings/platform/POWER-W11-HIBERNATE-GUARD-20261115.md:162`, PR-4). Any Linux
    hibernate resume that has to pick its target after a power-off needs the same answer.
  - `cold-boot-after-hibernate` on the SMC and DCP matches the survey's verdict: every coprocessor needs a cold
    restore.
  - The W11 guard (`W:tooling/hibernate-guard/hibstate.py`) is the model for refusing writes to a hibernated volume.

## 4. Windows claims that contradict Linux

1. "No sleep model can put this SoC into macOS-class deep sleep ... implemented by nobody (Linux, Asahi, Aurora)"
   (`POWER-END-STATE-20261114.md:41-42,53-56,72`). Stale: #1963 J714s S2R merged 11-15; `j716s-s2r-data` carries it.
2. "Hibernate on Linux: not feasible" (`:73`). Superseded: the survey rates it feasible in principle, XL.
3. "No s2idle drain" and an L2 guess of 1.5-3 W (`:79,129`). We measured 4.3-4.4 W (with cables).
4. "Display-off through set_power_state (A535) is in reach (Linux port exists)" (`:118`). No T6050 fw27 DPMS
   power-down exists in Linux. The W2 note says so itself (`POWER-W2-DISPLAY-20261114.md:9`).
5. `power-audio-20261111/LINUX-MAP.md:98`: cpuidle "deep WFI, which writes `s3_5_c15_c5_0` bits 25:24" vs
   `POWER-END-STATE:78`: "`CYC_OVRD` UNDEF on T6050". The Windows notes disagree with each other; ours (WFI only)
   stands.
6. `W:drivers/display-dcp/dcp-20261111/LINUX-MAP.md:85` marks A535 "assumed". `UPSTREAM-SURVEY-20261116.md:59-73`
   calls A535/A540/A538/A464/A462 "untraced candidates". Both understate: the handlers are identical in the 27.3
   dispatch, and the J716s runs those exact tags with the sleep's arguments on every boot (section 1).
7. The W2 mapping "A473 = A535" (`POWER-W2-DISPLAY-20261114.md:34`) is desktop-26 -> 27.3. On 27.3, A473 is
   set_matrix. Do not reuse it.
