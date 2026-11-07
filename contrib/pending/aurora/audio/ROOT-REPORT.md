# ROOT-REPORT: J716 audio userspace on the Aurora/ALARM root (2026-11-06, ~01:36-01:41 MBP time)

## Result
Everything the Arch Linux ARM repos can provide is installed and our J716 files are in place. **speakersafetyd, asahi-audio
and alsa-ucm-conf-asahi are not in the ALARM repos**, so the speaker-protection daemon is NOT installed and the
stage B (speaker) boot is **not cleared**: ROOT-SETUP.md section 5 gate 1 (`pacman -Q speakersafetyd`) fails.
This is still the safe state: without the daemon the kernel keeps the speaker volume locked (silence is the failure mode),
and the protective graph cannot link because its target node (RawSpeakers) only exists with asahi-audio.

## In place
| Item | Where | Check |
|---|---|---|
| pipewire 1.6.10, wireplumber 0.5.18, pipewire-alsa, pipewire-pulse, alsa-ucm-conf 1.2.16.1 | already installed | `pacman -Q` |
| rtkit 0.14-2, alsa-utils 1.2.16-1, lsp-plugins-lv2 1.2.37-1, sox 14.8.0.1-1 (+libao libid3tag libmad opusfile twolame wavpack) | [extra], new today | no existing package upgraded; `pacman -Qu` = 0, no -Sy |
| speakersafetyd profile | /usr/share/speakersafetyd/apple/j716.conf | sha256 = Studio copy |
| udev rule | /usr/lib/udev/rules.d/96-speakersafetyd-j716.rules | `udevadm verify` ok, `udevadm control --reload` ran; 1 non-comment AppleJ716 line (plain `grep -c` gives 2 because a comment names AppleJ716) |
| speaker graph / mic graph | /usr/share/asahi-audio/j716/{graph,mic}.json | valid JSON; both build in a test filter-chain (LSP compressor_stereo / limiter_mono load) |
| WirePlumber fragments | /usr/share/wireplumber/wireplumber.conf.d/99-asahi-j716{,-mic}.conf | `pw-config` merges them cleanly |
| macaudio UCM | /usr/share/alsa/ucm2/conf.d/macaudio/MacBook Pro J716.conf | in place, but see missing #3 |
| user audio services | pipewire.socket, pipewire-pulse.socket, wireplumber enabled globally and in ~rolo/.config/systemd/user (were already) | rolo session test: all active, `pw-dump` rc 0, `wireplumber --version` 0.5.18 |
| staged sources | /root/j716-audio (incl. audio-root-setup.sh and its log) | |

## Missing, and what is needed (build on the Studio, ship as aarch64 packages, install with `pacman -U`)
1. **speakersafetyd** (AsahiLinux/speakersafetyd): binary + shipped `speakersafetyd.service` (keep `-m 7`) + `95-speakersafetyd.rules`.
   Hard prerequisite for stage B. After install: `systemctl is-enabled speakersafetyd` (static/enabled), `speakersafetyd --help`.
   Our j716.conf and 96 rule are already where it looks.
2. **asahi-audio** (+ its deps **bankstown-lv2**, **triforce-lv2**): its `99-asahi.conf` is what (a) turns on
   `node.software-dsp` in the WirePlumber main profile (WP 0.5.18 does not load node/software-dsp.lua by default, so today
   our two J716 fragments parse but are inert: no speaker graph and no mic graph) and (b) renames hw:AppleJ716,1 to
   `alsa_output.platform-sound.RawSpeakers`, the target of graph.json. Our graphs themselves only need lsp-plugins-lv2 (installed).
3. **alsa-ucm-conf-asahi** with the `macaudio/laptops/HiFi.conf` and `aop_audio/3chan/HiFi.conf` trees (the latter only in
   builds carrying alsa-ucm-conf-asahi#10). Until then the installed macaudio UCM includes a missing file, so alsa-lib fails
   the UCM open and PipeWire's ACP falls back to plain ALSA (same as no UCM file). The AOP UCM file was **skipped** per
   ROOT-SETUP section 3 (it is staged in /root/j716-audio); install it with the line in audio-root-setup.sh once the tree exists.
Not done on purpose: adding `[asahi-alarm]` (ROOT-SETUP 2.2 points at GitHub releases) and the ROOT-SETUP 2.4 source-build fallback, both outside today's scope.

## Side effects / state
- rtkit system user (uid 965) created by sysusers; pacman armed ConditionNeedsUpdate (normal; next boot runs the update units).
- user@1001 started for ~2 min to test the rolo session, then stopped; rolo has no processes now, same as before.
- Not touched: amps/mixer, /boot, kernel, network files, tailscale, sshd, logind/sleep, m5-selftest, ~rolo/.config/hypr. No reboot, no -Syu.
- Baseline note: Hyprland was **not running** when I started (it launches only on a rolo tty2 login) and is still not running; nothing to break there.
- Final: 0 failed units; sshd, tailscaled, systemd-networkd, rtkit-daemon active; enu1u2u2 <lan-ip> and tailscale0 <tailscale-ip> unchanged.

## Reproduce
`~/Work/agents/audio-aurora/audio-root-setup.sh` (copy of /root/j716-audio/audio-root-setup.sh). From the Studio:
```
scp -i ~/.ssh/mbp -r ~/Work/agents/audio-aurora/userspace root@<tailscale-ip>:/root/j716-audio
scp -i ~/.ssh/mbp ~/Work/agents/audio-aurora/audio-root-setup.sh root@<tailscale-ip>:/root/j716-audio/
ssh -i ~/.ssh/mbp root@<tailscale-ip> 'bash /root/j716-audio/audio-root-setup.sh'
```
Idempotent; when the three packages exist in a reachable repo or are installed with `pacman -U`, rerunning it picks them up
and installs the AOP UCM file automatically. Verification commands used beyond the script: `pacman -S --needed --print ...`
(dry run), sha256 comparison of /root/j716-audio, `udevadm verify`, `pw-config -n wireplumber.conf paths|merge` with
PIPEWIRE_CONFIG_DIR=/usr/share/wireplumber, `systemctl start user@1001` + `systemctl --user start pipewire pipewire-pulse wireplumber`
+ `pw-dump` / `wpctl status` / `pactl info` as rolo, a throwaway `pipewire -c` filter-chain load of each graph, `systemctl stop user@1001`.
