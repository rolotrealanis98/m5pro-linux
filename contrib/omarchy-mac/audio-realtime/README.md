# audio-realtime

Scope: generic (any Omarchy/Arch install where PipeWire starts before rtkit). Status: installed 2026-11-17.

Found on the J716s: PipeWire's audio thread (`data-loop.0`) ran SCHED_OTHER at nice 0. rtkit only ever granted Hyprland;
PipeWire's module-rt (rt.prio 88, nice -11) asked before rtkit was ready at boot and never retried, and the session had
RLIMIT_RTPRIO 0. Desktop load (an Omarchy shell restart, a plugin reload) then made PipeWire resync the speaker sense
capture (`spa.alsa: hw:AppleJ716,DEV=2c: follower delay ... resync`), heard as a speaker glitch.

- `25-m5pro-audio-rt.conf` -> `/etc/security/limits.d/`: lets the `audio` group use RT priority up to 95, nice -19 and
  4 GiB memlock, so module-rt sets realtime itself (pam_limits via system-auth; effective from the next login).
- Live fix used once (until the next login): `chrt -f -p 88 <pipewire data-loop.0>`, `chrt -f -p 83 <wireplumber
  data-loop.0>`, `renice -n -11 <pipewire>`.
- Check: `ps -L -o tid,cls,rtprio,ni,comm -p $(pgrep -x pipewire)` shows `FF 88 data-loop.0`.

Undo: `rm /etc/security/limits.d/25-m5pro-audio-rt.conf` (next login). Upstream: Omarchy (ship realtime-privileges-style
limits on aarch64; Arch's `realtime-privileges` package is not in the aarch64 repos).
