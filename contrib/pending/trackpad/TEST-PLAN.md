# Test plan: J716s trackpad (host-driven AFE reset)

Do not start while another agent owns reboots. Everything below runs from the Mac Studio.

    B="~/Work/m1n1/.venv/bin/python ~/Work/eem-vm/eem-vm.py --keep"
    P=~/Work/agents/trackpad/payload-trackpad.bin
    # sha256 fcc402401b33325cac937037deb050660756a4d615182470b7dde3afad001a0d

## 0. Before deploying (current boot)

    $B 'uname -r; sha256sum /boot/m1n1/boot.bin /boot/m1n1/boot.bin.prev; df -h /boot | tail -1'

Record the running boot.bin hash (at 23:11 M5 time it was a2407e83..., the payload with
kernel 7.2.2-01023-g666335fea5e3-dirty). Note that `boot.bin.prev` currently holds the
other agent's rollback image; step 1 replaces it with today's boot.bin, which is the
known-good one. Keep a second copy if that older image still matters
(`cp /boot/m1n1/boot.bin.prev /boot/m1n1/boot.bin.prev2`).

## 1. Deploy (write a temp file, verify, then rename; never leave a half-written boot.bin)

    $B 'cp /boot/m1n1/boot.bin /boot/m1n1/boot.bin.prev && sync && sha256sum /boot/m1n1/boot.bin.prev'
    $B --put $P /boot/m1n1/boot.bin.new 'sync; sha256sum /boot/m1n1/boot.bin.new'
    # continue only if the hash is fcc40240...
    $B 'mv /boot/m1n1/boot.bin.new /boot/m1n1/boot.bin && sync && sha256sum /boot/m1n1/boot.bin'
    $B 'systemctl reboot'

Wait ~60-90 s, then `$B 'uptime'` until it answers (retry; the bridge returns 2 while the M5
is down).

## 2. Checks after each boot

a) Right kernel, nothing else broke:

    $B 'uname -r; nproc; cat /proc/cmdline'

Expect `7.2.2-gf31c51d6187d-dirty` and 18 CPUs. If SSH never comes back or the keyboard is
dead, go to Rollback: this is the first boot of this LLVM-built kernel, so a failure here is
probably not the trackpad patch.

b) The second SMC GPIO bank probed and gp1c exists:

    $B 'dmesg | grep -E "macsmc-(low-)?gpio|Failed to locate of_node"'
    $B 'grep -A40 "macsmc-pmu-low-gpio" /sys/kernel/debug/gpio | head -45'

Expect two `First GPIO key:` lines, one `gP01 (0x67503031)` and one `gp01 (0x67703031)`, and
no `Failed to locate of_node`. After the trackpad has been opened, the low chip lists line
28 as `afe-reset` output. If `macsmc-low-gpio` failed to probe, the driver says
`AFE reset line unavailable` and behaves as before (keyboard must still work).

c) Trackpad bring-up:

    $B 'dmesg | grep -E "dockchannel-hid|294600000.mtp" | grep -iE "multi-touch|AFE|HINT|Touch|TPM|GPIO|bootload" | grep -v PANICLOG'

Pass, in this order:

    dockchannel-hid ...: Starting interface multi-touch
    dockchannel-hid ...: multi-touch: host-driven AFE reset, power method 2
    dockchannel-hid ...: Sending firmware for multi-touch
    dockchannel-hid ...: Resetting multi-touch
    dockchannel-hid ...: multi-touch: AFE reset asserted
    dockchannel-hid ...: multi-touch: AFE reset released
    RTKit: syslog message: bootloader.c:537: (*)New AFE[0] cbor image received
    dockchannel-hid ...: Interface multi-touch is now ready
    RTKit: syslog message: touch_iface.c:512: Touch MT ready

Fail signatures: `Failed to attach to AFE`, `No HINT_L`, `AFE[0] bootload failed`,
`iface multi-touch start timed out`, `AFE reset line unavailable`, `failed to assert|release
AFE reset`, `GPIO set failed gp1c`. If the interface was never opened yet (no `Starting
interface multi-touch`), step d opens it.

d) Input device and events:

    $B 'cat /proc/bus/input/devices | grep -A5 "Apple MTP multi-touch"'
    $B 'N=$(grep -A5 "Apple MTP multi-touch" /proc/bus/input/devices | sed -n "s/.*Handlers=.*\(event[0-9]*\).*/\1/p"); echo $N; timeout 5 cat /dev/input/$N | wc -c'

Run the second command twice: once with nobody touching the trackpad (expect 0 or close
to it) and once while someone swipes on it (expect thousands of bytes; one input_event is
24 bytes). `libinput` and `evtest` are not installed on the Arch root.

## 3. Repeat: three boots

The unpatched driver already passes on some boots (it passed on the 23:08 boot today), so
one pass proves nothing. Do three consecutive reboots (`$B 'systemctl reboot'`) and run
section 2 each time. If possible make one of them a cold boot (shut down, power on) and
one a reboot right after a passing boot (the case that failed before). Record per boot:
c) pass/fail and the RTKit syslog lines; d) byte counts.

Decision:
- 3/3 pass: done; keep payload-trackpad.bin.
- 0/3, each with `AFE reset asserted`/`released` logged and `No HINT_L`: the polarity is
  probably inverted. Deploy the fallback the same way and repeat section 2 and 3:
  `P=~/Work/agents/trackpad/payload-trackpad-active-high.bin`
  (sha256 59b5d00e8dc5bbf612bc069b45622b7a61b11ad898135f6861ec31d4bc87a260; only the DTB flag
  differs). Do not overwrite boot.bin.prev a second time: skip the first `cp` of step 1.
- Mixed results with the reset logged: polarity is likely right but something else is
  intermittent; send back the full `dmesg` of a passing and a failing boot.
- `AFE reset line unavailable`: send back the b) output.

## 4. Rollback

From a running Linux:

    $B 'cp /boot/m1n1/boot.bin.prev /boot/m1n1/boot.bin && sync && sha256sum /boot/m1n1/boot.bin && systemctl reboot'

If Linux does not come up (no SSH): hold power until off, press once (stage-1 m1n1 runs
again and chainloads the ESP boot.bin, so this alone does not roll back). Then either boot
Linux tethered with `host/macos/m5.sh boot-linux` and do the `cp` above, or use the ESP
install path in m5pro-linux `docs/boot-and-recovery.md` (mk-esp-install.sh +
`rdinit=/esp-install.sh`) with the previous payload. To get back to macOS: hold power,
boot picker, Macintosh HD.
