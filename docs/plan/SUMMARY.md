# Summary: the top five changes, in order

Planning agent, 2026-11-05. Everything here is UNTESTED. Details: `FRICTION.md`, `ROADMAP.md`.

1. **Install the A/B stage-1 (m1n1 patch 0016) in Sunday's one ceremony.**
   - Stage-1 reads iBoot's own PMU boot-error count. Non-zero means the last boot did not end in a
     clean Linux restart (hang, panic, watchdog reset, forced power-off). Then stage-1 boots
     `m1n1/boot.bin.prev` and clears the count.
   - Stage-1 also arms the SoC watchdog for 150 s at the hand-over. A kernel that hangs before Linux
     takes the watchdog over (like the 7.8 s macsmc-power hang) resets on its own.
   - The root demotes a failed trial payload (`m5-boot-slot`).
   - Compile-checked only. The raw image is 0x420000, the same as today; the installed object is
     0x430000.
   - Removes from Rolando's list:
     - booting macOS, mounting the ESP and copying `boot.bin.prev` back (1);
     - the "needs to be reinstalled" recovery after failed boots (3), even for payloads without 0017;
     - power-cycling most hung kernels (4, 8).

2. **Kernel config: hangs become panics, panics become resets (`m5-debug.config`).**
   - Soft- and buddy hard-lockup panics, hung-task detection, `panic_on_oops`, `PANIC_TIMEOUT=10`.
   - The watchdog stays running until systemd takes it.
   - Today a panic waits forever (`PANIC_TIMEOUT=0`) and no lockup detector is built in.
   - Removes: "photograph the panel, then hold power" for every crash (2, 4).

3. **netconsole over the EEM link (debug initramfs + listener in the Studio guest).**
   - Kernel lines stream to `~/Work/m5-logs/netconsole.log` from the initramfs onward, and keep
     streaming after `switch_root`.
   - A probe-bisect hook (`m5.insmod=macsmc_power`) loads a suspect driver only after netconsole is up.
   - Removes: Rolando as the only reader of kernel text (2). The macsmc-power hang becomes
     agent-bisectable (8).

4. **`m5-deploy.sh`: one command per kernel test.**
   - Hash-checked upload, rotation of the previous payload, a `TRIAL` marker, a clean reboot, a wait
     for SSH, then checks of kernel release, boot slot and 18 CPUs.
   - On failure: `macvdmtool reboot`, the stage-1 fallback from (1), evidence collection (pstore,
     journal, netconsole) and demotion of the bad payload.
   - Removes: agents stalling until Rolando is back after a bad deploy. He is called only on exit 3,
     with exact steps.

5. **pstore/ramoops in iBoot's `/pram` panic region, then a USB Ethernet path (Stage C).**
   - XNU's source shows `/pram` is the panic buffer that iBoot carries across a reset. A 3-boot
     retention probe on Sunday decides whether Linux can keep the previous boot's console there.
   - USB host Ethernet on the left-front port gives SSH straight from macOS (no QEMU guest) and
     internet for pacman. The same port later takes the Wi-Fi/BT dongle.
   - Removes: the last invisible failures (2, 8) and the QEMU-only network (5).

Cheap extras: a webcam on the panel with Vision OCR (for iBoot and m1n1 screens); an armed-only
Studio hang watchdog; `asahi-bless`/`bless` for the startup disk (6); fixed cabling done once (7).
Serial is last: `macvdmtool serial` answers BUSY and `debug-enabled` is 0.

Roadmap after that:
- R2 (unattended): macsmc-power bisect, cpufreq, thermal and fans, keyboard backlight.
- R3: USB host and Ethernet (needs a dongle, a hub and a power meter).
- R4: Wi-Fi dongle, DCP read-only steps, audio stage A.
- R5+: aurora DCP and Thunderbolt imports.
- R6+: CONFIG_RUST in the Fedora container, then audio stage B.
- GPU, camera, built-in mics and ALS wait on the external triggers in ROADMAP section 4.
