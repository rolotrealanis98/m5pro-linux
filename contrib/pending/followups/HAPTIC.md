# MTP haptic (trackpad click feedback) on the J716s (finding 3)

Recommendation: turn it on (`CONFIG_HID_APPLE_MTP_HAPTIC=y` with `CONFIG_HID_MAGICMOUSE=y`), as one A/B boot.
It is a config-only change; the DT already has what the driver needs. `patches/0003-*.patch` is that change
to `arch/arm64/configs/j716s.config`. Do not expect a different click from it by itself (section 4).

## 1. Why the fragment has it off, and why that is no longer necessary

- `drivers/hid/Kconfig`: `HID_MAGICMOUSE` has `depends on HID_APPLE_MTP_HAPTIC || !HID_APPLE_MTP_HAPTIC`, the
  standard "optional tristate dependency". Haptic `=m` caps magicmouse at `=m`; haptic `=n` or `=y` allows `=y`.
- `arch/arm64/configs/asahi.config` line 82 sets `CONFIG_HID_APPLE_MTP_HAPTIC=m`. Our root has no modules, so
  `j716s.config` forced it to `n` (series 0058: "keeps the MTP haptic driver off so that HID_MAGICMOUSE ... can be
  built in"). betizzel hit the same cap and fixed it the other way: haptic `=y` (his
  `configs/aurora-j714s.config`, with the comment "Aurora caps HID_MAGICMOUSE at this dependency"; `docs/bringup.md`
  "both must resolve to y").
- Both `=y` is legal: the tristate dependency is satisfied by `y`.

## 2. What the driver is, and is it in our tree

- Present: `drivers/hid/hid-apple-mtp-haptic.c` (244 lines, Aurora's), `include/linux/soc/apple/actuator.h`,
  and the host-haptics code in `hid-magicmouse.c`, which is compiled only `#if IS_ENABLED(CONFIG_HID_APPLE_MTP_HAPTIC)`
  (lines 1504-1815 and 1982-2359; otherwise stubs that return the firmware's button state).
- What it does when built in:
  1. Binds to the HID device named "Apple MTP actuator" (`apple_taptic_is_actuator()`), which `dockchannel-hid.c:921`
     names from the DT/ADT interface `actuator`. At probe it sends feature report 0x21 to put the actuator back in
     device-controlled mode, so a mode left over from a previous boot cannot leave it silent, and on resume it
     re-checks the click strength.
  2. If the DT's `actuator` node has `apple,click-strength = <press release>`, writes those over the firmware's
     click waveforms 0x22 and 0x23 (the firmware starts with a weak placeholder).
  3. `hid-magicmouse` gets `apple_taptic_send()` / `apple_taptic_switch_modes()` instead of the -ENODEV stubs: it
     registers an `EV_FF`/`FF_HAPTIC` force-feedback device on the trackpad's input node (userspace can play haptic
     effects) and has optional host-driven click feedback. Defaults: `haptic_press=0`, so the firmware still
     does the click; the host path is opt-in module parameters (`haptic_press`, `haptic_*_strength`, thresholds).
- Today (haptic `=n`): `.config` has `# CONFIG_HID_APPLE_MTP_HAPTIC is not set`; the actuator HID device is created by
  `dockchannel-hid` (RESULTS R3-Q lists "stm, keyboard, actuator and tp-accel interfaces") and nothing binds to it
  except hid-generic (the two "device has no listeners" lines in the R3-Q log are probably those). Nobody touches
  the actuator, so whatever mode the MTP firmware boots in is what you get.

## 3. J714s DT versus ours

Nothing to add on the DT side.

| | J714s (betizzel `dt/t6050-j714s.dts`) | J716s (series `t6050-j716s.dts`) |
|---|---|---|
| `actuator {}` under `input@8000` | yes, empty | yes, empty (with the "[ADT] ... optional" comment) |
| `tp-accel {}` | yes, plus `tp_accel {}` and `mtp {}` as insurance for other firmware names | `tp-accel {}` only; the J716s [ADT] `mtp-transport` children are exactly multi-touch, keyboard, stm, actuator, tp-accel, so no insurance is needed |
| `apple,click-strength` | none | none |
| config | haptic `=y`, magicmouse `=y` | haptic `=n`, magicmouse `=y` |

So the only difference is the config line. The one DT property that matters, `apple,click-strength`, exists on
one machine in the tree (t8112-j413, `<0xc0 0x6e>`, tuned for that SPI actuator); no MTP machine sets it, and
there is no value measured for the J716s's actuator.

## 4. What to expect and what to check

- Risk: low. One new HID driver bound to one device that matches by name; the magicmouse haptic path is the one
  betizzel boot-tested on the J714s ("magicmouse initialized MTP haptics, the multi-touch interface became ready,
  a physical swipe/click produced ... a left-button press and release"). Not tested on the J716s: nobody has
  booted this combination here, and it adds code to the path of the working trackpad. Hence an A/B boot, with
  the current payload as the fallback.
- Check after the boot (dmesg): `initialised MTP haptics` from magicmouse; no `cannot return the actuator to
  device-controlled mode` warning from `hid-apple-mtp-haptic`; trackpad button and motion events as before
  (`evtest`/libinput); `evtest` on the trackpad node now also lists `EV_FF` with `FF_HAPTIC`.
- The click you feel: press the trackpad on the current boot first. If it clicks, the firmware is already playing its
  own waveform in device-controlled mode, and the driver's gain is the mode assertion, the resume check and the
  userspace effect API, not a new click. If it is faint, that is the firmware's placeholder strength: the fix is
  `apple,click-strength` in the `actuator` node, with values tuned by feel (J413's `<0xc0 0x6e>` is the only
  reference); that is a DT change after the A/B, not part of 0003. If it is silent, the actuator is probably not
  in device-controlled mode, and the driver's probe is what changes that.

## 5. The patch

`patches/0003-arm64-configs-j716s-Build-in-the-MTP-haptic-driver.patch`, on top of `dd6b39464ca9`
(`arch/arm64/configs/j716s.config` has no later change). It moves the comment to say why both are `y` and swaps
`CONFIG_HID_APPLE_MTP_HAPTIC=n` for `=y`. Checks are listed in `REPORT.md` (config resolution against the booted `.config`, two objects compiled, `git apply --check`).
