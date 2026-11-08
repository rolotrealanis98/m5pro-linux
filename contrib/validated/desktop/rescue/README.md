# Desktop rescue card (J716s, Omarchy)

When Hyprland crashes, shows its safe-mode message, or the screen stays black:

1. Press **Ctrl+Alt+F3** to get a text console; log in as `rolo`.
2. Run `sudo m5pro-rescue`. It prints the diagnosis (Hyprland alive? GPU recoveries this boot and which app
   caused them? does a forced redraw reach the panel?), saves the evidence under `/root/wedge-<time>/`, restarts the
   desktop session, and checks again.
3. If it says "recovered", press **Ctrl+Alt+F2** to go back to the desktop.
4. If it says the panel is wedged (only on the DCP daily: a page flip stuck on a GPU fence), answer `y` to reboot;
   it syncs, waits 30 s so the restart is not counted as a failed boot, and reboots on the same slot.

`sudo m5pro-rescue status` only diagnoses; `sudo m5pro-rescue session` only restarts the session;
`sudo m5pro-rescue reboot` saves evidence and reboots with the settle.

Why this happens today: a GPU fault from any client (Chrome, Claude Desktop, quickshell) makes the aurora recovery
declare the compositor's context lost; zink then crashes. On the DCP daily the display pipeline can stay stuck on
the dead fence. The kernel and Mesa fixes are tracked in m4-m5-linux issue #36; until they land, the boot slot runs
the simpledrm daily (no wedge possible) and Chromium/Electron apps run without GPU acceleration.
