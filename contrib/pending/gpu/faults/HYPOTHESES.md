# Why ordinary GPU clients fault the M5 Pro (G17S), and what to toggle

2026-11-08. Studio-only analysis from source and firmware disassembly. Nothing here was run on the MacBook.
The recovery side (isolation, fence signalling, bounded apple-drm wait) is in `../recovery/`.

Trees:
- kernel `j716s-daily-dcp` @ `bd53915f2ef1`, plus this directory's two patches (branch `j716s-daily-dcp-faults`);
- Mesa `agx3c` @ `a8e86a80cdc` (the `/opt/mesa-aurora` build);
- G17S firmware `a010` carved from 27.2 (26B123) and 27.3 (26C5035r):
  `~/Work/agents/gpu-port/e-runtime/work/fw/{2,3}-armfw.dis`.

## What a recovery looks like today

Every recovery logs the same lines:
- `fault registers [0,0,0,0,0,0]`;
- `reason None`;
- a varying slot mask (0x0, 0x1, 0x25, 0x40, 0x41);
- `N commands were in flight`.

Two runs mark the edges:
- A 24-minute soak with only Hyprland and glmark2 had none.
- On the simpledrm daily, with no DCP, there were two recoveries in 8 minutes (slot mask 0x1). Both failed `quickshell`, a mostly idle Qt Quick bar on zink, at `runtime.rs:1422`, the compute quarantine.

So the fault class does not need the DCP. It needs no heavy load and no more than one busy slot. Its common factor is a second client that submits now and then.

## Patches

| Patch | Effect |
|---|---|
| `0001-drm-asahi-g17-Name-the-cause-and-the-clients-of-ever.patch` | Reads the firmware's recovery record in the M5 status B and logs it. The reason is at +0x4aac, slots walked at +0x4aa0, the slot record word at +0x4aa8 and the detail at +0x4ab0. Also names the client (comm[tgid]) and the retained command count of every queue in the recovery table, and of the blamed queue. Blame is unchanged unless `aurora.m5_recovery_reason_blame=1`. |
| `0002-drm-asahi-g17-Add-M5-GPU-fault-experiment-parameters.patch` | Adds the boot parameters `m5_pause_timeout_us`, `m5_idle_standby_us` and `m5_idle_hold`, all off by default. |

Both patches:
- compile with the daily `.config` (clang 21.1.8, rustc 1.99.1, `make W=1 drivers/gpu/drm/asahi/`);
- add no new warnings (the same 19 pre-existing ones);
- apply cleanly on top of the recovery branch (`j716s-daily-dcp-recovery` @ `ed7e1d0c42b0`).

The record and the three parameters are only read at recovery time or at probe. `CONFIG_KUNIT` is off, so the
new KUnit case in `attribution.rs` was not compiled.

New log lines per recovery:

```
G17: recovery cause gen N: DSF pause timeout: the GPU did not pause scheduling in time (firmware reason 5, macOS restart reason Some(7)); firmware blames queue Some(Q); slots walked S, slot word 0x.., detail 0x..
G17: recovery gen N queue Q blamed guilty: 3 retained commands, client quickshell[933]
```

`cause ...: none recorded (the firmware cleared its record)` means the firmware took its host-request path. That path zeroes the whole record, and it fits the `slot_mask 0x0` recoveries.

### What the firmware record holds (verified in the 27.3 primary image, same code in 27.2)

- **Where it is written.** The recovery routine stores the record at TEXT 0x7808..0x784c, before it announces the restart.
- **Reasons**, written to view 3 +0x48 and copied to status B +0x4aac:
  - 3: a GPU page fault (TEXT 0x7320). The latched fault status goes to view 3 +0x40, then to +0x4ab0.
  - 5: an unacknowledged scheduling pause (TEXT 0xb620, "Unexpected scheduling pause timeout after %uus").
  - 6: forced idle after a sleep request (TEXT 0x29eec).
  - 0, 1, 2 and 4 have no name. The macOS kext maps them to restart reasons 2, 2, 4 and 6.
- **The blamed queue in the restart event** is the faulting command's queue index, read through the per-type table. It is -1 when no slot was selected.
- **+0x4aa8 is not that stamp.** It is word +0x44 of the record behind slot register 0xc0f8. `RUNTIME-DIFF-27.2.md` §2 calls it "stamp word"; that is imprecise.
- **Host-request path.** If view 3 +0x4 is set, the routine memsets 0x4298..0x4ac0, so the reason, the slot mask and the table all read 0.

## Hypotheses, ranked

### H1. DSF (scheduling) pause timeout, reason 5. The firmware gets 150 us to pause the hardware.

Evidence:
- **The firmware's pause routine** (27.2 TEXT 0x23180):
  - sets MMIO +0x211c8 bit 0;
  - reads HW data +0x271c as a bound in us, where u32::MAX means no bound;
  - polls MMIO +0x211d0 for the acknowledge at 24 ticks per us;
  - on expiry, the caller (0xb578) writes reason 5 and halts.
- **The driver writes 150 there.** That is the inherited `COMMON26_HW_FIXED_WORD` (0x2714 = 0x96, from the J813/G17P template), moved to 0x271c by the M5 HW data insert. Patch 0002 asserts this at compile time. Checked 2026-11-08 against the macOS AGXG17X kext (27.0, 27.2, 27.3): macOS also writes 0x96 = 150 us at +0x271c, as a constant in the HW-data setup function (straight-line code, no variant branch, no other store to 0x271c). So the Linux value is not a mismatch with macOS; the `m5_pause_timeout_us=2000` experiment tests a bound 13x looser than what macOS ships. Offsets live in the private 27.x derived notes, not here.
- **Who pauses scheduling.** Callers of 0xb578, by mask bit:
  - 0x4: `AGFASchedulerProcessPowerKick`, power-state changes;
  - 0x8: the sleep / forced-idle path;
  - 0x80: parameter-buffer state rebind;
  - 0x100: the KSM kick path and the debug dump;
  - 0x400: the KSM completion handler. It is the one that logs "CDM context store took too long", the compute context store;
  - 0x1000: recovery;
  - 0x2, 0x10, 0x20, 0x800 and 0x4000: others.

  So pauses come from power transitions, from compute context switches and from buffer-manager rebinds. They do not come from load as such.
- **Why it fits.** A pause has to drain whatever the busy slot runs within 150 us. One busy slot (mask 0x1) is enough, and a client waking the GPU from idle starts a power kick. That matches a mostly idle quickshell, and two clients being worse than one.

Toggle, no rebuild:
- `aurora.m5_pause_timeout_us=2000`, then `=20000`.
- Last resort: `=4294967295`. The firmware then waits forever, and the driver's own 10 s timeouts take over.
- Confirmation: patch 0001 logs `firmware reason 5`.

### H2. GPU idle power-off and wake racing a submission (power kick)

Evidence:
- On M5 the driver takes **no** host idle hold (`g17/mod.rs` `idle_hold` returns early). The "GPU idle power-off delay: 2 ms" log line is only the DT value echoed back; M5 ignores it.
- The firmware keeps its own policy: Region C idle standby 1500 us (+0x7c8). After a submission it powers the cores on through `ProcessPowerKick`, which pauses scheduling (mask 0x4). That pause is H1's trigger.
- A client that submits every few hundred ms (a bar animating, a cursor, a blinking caret) wakes the GPU each time. A continuous load like glmark2 keeps it awake, which explains the clean 24-minute soak.

Toggles:
- **Runtime, needs patch 0002.**
  1. Boot with `aurora.m5_idle_hold=1`.
  2. Run `echo 1000 > $(find /sys/devices -name idle_off_delay_ms | head -1)` to hold the cores powered for 1 s after the last work.
  3. `echo 2` turns the hold off again, with no reboot.
  - Risk: the code notes that on the M5 Ultra (J775D) a host hold makes the core-power witness read unpowered. J716s has not been tested. If submissions stall, set the delay back to 2.
- **Boot only:** `aurora.m5_idle_standby_us=20000` (or 100000). The idle GPU waits longer before standby, so it makes fewer power kicks.

### H3. Compute work from zink transfers (context store and preemption)

Evidence:
- quickshell's failure site is the **compute** quarantine (`runtime.rs:1422`).
- On M5, Borealis encodes buffer copies, fills, raw tiled image copies, buffer-to-image uploads and mip blits as CDM compute commands (`hk_cmd_meta.c:2641-2670`, `:2898-2937`, `:4050-4075`). Glyph-atlas and texture uploads from Qt or Chromium are compute jobs.
- Compute work carries preemption buffers (`g17/fw/compute.rs` `PREEMPT_STATE`). The completion handler's pause (mask 0x400) sits beside "CDM context store took too long".

Toggles, no rebuild:
- `QT_QUICK_BACKEND=software` for quickshell removes the trigger. It is already the stopgap.
- Chromium `--disable-gpu-rasterization` keeps GPU compositing but drops Skia's uploads.
- `ASAHI_MESA_DEBUG=sync` for one client serializes it, since each submit waits for the last.

### H4. Priority asymmetry between clients

Evidence:
- zink creates its single VkQueue with priority 0.0 (`zink_screen.c:2929`). Borealis turns that into `DRM_ASAHI_PRIORITY_LOW` on M5 (`hk_queue.c:1790-1793`).
- So Hyprland, Chromium and quickshell all run LOW, while native GL (`agx_pipe.c:2048-2091`) runs MEDIUM.
- Mixed priorities make the firmware preempt LOW work for MEDIUM work, which means more context stores and pauses. This fits the native-GL test window's recoveries, but not the simpledrm quickshell ones, where every client was zink.

Toggle: none without a rebuild. The cheapest test is to run without native-GL clients. The real test would be a zink one-liner that passes 1.0 instead of `dummy`, or a kernel parameter that flattens queue priority to MEDIUM. Neither is written yet.

### H5. Multi-slot concurrency and stamp handling

Evidence:
- Slot masks 0x25 and 0x41 mean several busy slots, but 0x1 and 0x40 mean one. So concurrency is not required.
- `stampless lifetime total 0` rules out the stampless compute fallback.
- The firmware chooses slots. The driver has no slot pinning, and adding it would mean changing firmware scheduling state, which is not a parameter.

Toggle: the Mesa environment knobs below reduce per-client overlap. A rarely submitting queue's stamp path shows up in patch 0001's per-queue lines: a blamed queue with `no retained commands` would point here.

### H6. DCP sharing power or fabric with the GPU (demoted)

Evidence:
- simpledrm also faults, so the DCP is not required.
- The DCP still adds load: 120 Hz VRR swaps, and memory-bandwidth requests through the PMC bandwidth scratch (`apple,bw-scratch`). Each request can change the memory fabric's performance state, which stalls memory clients. A stall during a pause makes H1 more likely.

Toggles, no rebuild:
- `hyprctl keyword monitor eDP-1,3456x2234@60,0x0,1` (use the real output name);
- `misc:vrr = 0`.

Compare the fault rate on the two dailies under the same load.

## Mesa knobs to reduce concurrency (no rebuild)

| Variable | Effect |
|---|---|
| `ASAHI_MESA_DEBUG=sync` | Each submit waits for completion. This is the strongest knob. |
| `HK_PERFTEST=nobatch` | One control stream per ioctl. |
| `ZINK_DEBUG=noreorder` | One fewer command buffer per batch. |
| `GALLIUM_THREAD=0` | No threaded context. |
| `ASAHI_MESA_DEBUG=1queue` | One kernel queue per native-GL device. |
