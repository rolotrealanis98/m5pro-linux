# Touch ID in Omarchy (J716s)

Touch ID on the MacBook Pro J716s (M5 Pro) running Omarchy 4.5: the boot bring-up, a guard that keeps
the right libfprint, a Touch ID panel inside Omarchy's own shell, and fingerprint unlock for sudo, the
lock screen, polkit prompts and 1Password. Installed on the J716s 2026-11-17.

## What is here

| Path | Installs to | What it does |
| --- | --- | --- |
| `system/` | `/etc/modprobe.d/apple-sep.conf`, `/etc/systemd/system/m5pro-touchid.service`, `fprintd.service.d/60-m5pro-touchid.conf`, `/usr/local/lib/m5pro/touchid-up`, `touchid-sensor-present`, `/usr/share/omarchy-platform/fingerprint-readers` | Loads `apple_sep` at boot (the SEP node stays disabled until the driver enables it, so nothing autoloads it), waits for the key store, restores the enrolled fingers before fprintd starts. The platform file makes `omarchy-hw-fingerprint` see Touch ID. |
| `libfprint-aurora/` | package `libfprint-git 2:1.94.100.aurora.a227a35` | libfprint 1.94.100 + aurora-sep-userspace patches 0001-0011 (sep-bio v4/v5). Same files as the earlier `libfprint-aurora` package, renamed (see below). |
| `guard/` | `/etc/pacman.d/hooks/50-m5pro-touchid-guard.hook`, `/usr/local/lib/m5pro/touchid-pacman-guard`, `IgnorePkg = libfprint-git` in `/etc/pacman.conf` | Refuses any transaction that installs, upgrades or downgrades `libfprint`/`libfprint-git`/`libfprint-aurora`, or removes `libfprint-git`/`fprintd`. |
| `polkit/40-m5pro-admin-self.rules` | `/etc/polkit-1/rules.d/` | Admin prompts ask the wheel member at the keyboard instead of the first wheel member (`alarm`). |
| `bin/m5pro-touchid` | `/usr/local/bin/` | Backend for the panel: fprintd over D-Bus, JSON lines out. `status`, `enroll`, `verify`, `delete`, `label`. |
| `plugin/m5pro.touchid/` | `~/.config/omarchy/plugins/m5pro.touchid/` (enabled) | The Touch ID panel, an overlay plugin in Omarchy's Quickshell shell built from its own UI kit. |
| `menu/menu-touchid-rows.jsonc` | merged into `~/.config/omarchy/extensions/omarchy-menu.jsonc` | Setup > Security > Fingerprint becomes **Touch ID** and opens the panel; Remove > Security > Fingerprint is hidden. |
| `rearm/install-rearm.sh` | opt-in | aurora-sep-userspace `touchid-rearm`: a password ends a Touch ID lockout. Not installed. |
| `install.sh` | | Idempotent installer for all of the above (`--with-rearm`, `--uninstall`, `--user`). |

## Design

**Why the library is called libfprint-git.** Omarchy's fingerprint setup
(`omarchy-setup-security-fingerprint`, behind Setup > Security > Fingerprint and the first-run
invitation) runs `pacman -S --needed --noconfirm --ask 4 libfprint-git fprintd usbutils` whenever
`omarchy-pkg-missing libfprint-git fprintd usbutils` says one is missing. Omarchy's `libfprint-git`
(`1:1.94.100.r10…`) has an aurora driver that speaks only sep-bio v4, and the J716s kernel speaks v5, so
the swap stops Touch ID. It happened on 2026-11-17 at 11:12; the enrolment that followed failed with
"No devices available" before reaching the enclave. Our build now carries Omarchy's name with `epoch=2`,
and `usbutils` is installed, so the check passes and the package step is skipped. `epoch=2` keeps a
`-Syu` from treating Omarchy's build as newer; `IgnorePkg` keeps `-Syu` from even asking; the pacman
hook refuses everything else, including `omarchy-remove-security-fingerprint`, whose
`omarchy-pkg-drop fprintd libfprint libfprint-git` would remove both. To change the package on purpose:
`sudo touch /run/m5pro-touchid-allow-libfprint` (gone at the next boot).

Omarchy's own setup, if run anyway, now skips packages, then `fprintd-enroll`s the right index finger.
That finger is enrolled, so fprintd's duplicate check ends it with `enroll-duplicate` and nothing is written.

**Why a shell plugin.** Omarchy has no fingerprint manager, only the terminal setup script. Its shell
loads user plugins from `~/.config/omarchy/plugins/` with the same manifest contract as its own
(`omarchy plugin validate`), and its menu takes user rows that override a default row by id. The panel
is an `overlay` plugin (like Omarchy's reminders flow) built from `qs.Ui` (`OverlayWindow`,
`BorderSurface`, `Button`, `TextField`, `ConfirmDialog`) and the theme's colors, so it follows the
Omarchy theme. It is summoned with `omarchy-shell shell summon m5pro.touchid` (also
`omarchy menu summon touchid`).

**Panel flows.**
- *List*: enrolled fingers, "N of 3" (the enclave holds three prints per user, `SEP_USER_CAPACITY`),
  Test / Rename / Delete per finger, Add. Keyboard: arrows or hjkl, Enter, Esc.
- *Add*: pick a finger not yet enrolled. The helper first asks polkit for fprintd's enroll permission
  (`auth_self_keep`) with `pkcheck --process <its pid>`, *before* claiming the reader, so Omarchy's
  polkit dialog can take a touch of an enrolled finger (once fprintd holds the reader for the
  enrolment, pam_fprintd could not use it and the dialog would fall back to the password). Then it
  claims the reader and enrols, on a D-Bus connection opened after the dialog: fprintd broadcasts
  its Verify/EnrollStatus signals, and on the shared connection the dialog's own `verify-match`
  was queued and then ended the enrolment 13 ms after it started (first owner test, 11:27). The
  helper also ignores any signal that is not its own kind or arrives before its Start returned.
  Its diagnostics go to the shell's journal (`journalctl --user _COMM=quickshell | grep m5pro-touchid`).
  Touch ID's first `enroll-stage-passed` is fprintd's duplicate check and
  is not counted. A ring fills per accepted touch (paced for ~14), retries say why
  (not centered, too fast, lift). At the end the finger can be named.
- *Test*: `VerifyStart(<finger>)`. Aurora's patch 0011 reports a touch of a different enrolled finger
  as a plain no match, so the copy says "That wasn't your …, or it didn't read". Every miss counts
  toward the enclave's lockout (five in a row), so the panel stops offering tests after two misses
  in a row.
- *Rename*: a label in `~/.config/m5pro-touchid/labels.json`. fprintd and the enclave know a print
  only by its finger slot; the label is shown only in the panel.
- *Delete*: always confirmed in a dialog first (it writes the Secure Enclave), with a stronger message
  for the last fingerprint; then polkit, claim, `DeleteEnrolledFinger`.
- While polkit's dialog is up, the panel drops its exclusive keyboard focus so the dialog gets the keys.

**Polkit and 1Password.** Omarchy's shell is the polkit agent (`omarchy.polkit`, Quickshell
`PolkitAgent`). It reads `/etc/pam.d/polkit-1`, and when `pam_fprintd` is in it, it shows a fingerprint
glyph instead of a password field until PAM asks for a password (lid closed, timeout, or no match).
1Password's "Unlock using system authentication" is polkit action `com.1password.1Password.unlock`
(`auth_self`); `op` uses `com.1password.1Password.authorizeCLI` and the SSH agent
`…authorizeSshAgent`. All three go through that dialog, so with pam_fprintd in polkit-1 they take a
touch. Installed: `1password 8.12.44` (aarch64, Arch package), `1password-cli 2.42.0`, native messaging
hosts for Chrome and Chromium. In 1Password's settings, system-authentication unlock, browser
integration, CLI integration and the SSH agent are already on.

Admin prompts (`auth_admin`: mounting a disk, `pkexec`) offered the identity `alarm` (the image's
first wheel member) and failed for the owner's finger and password. `40-m5pro-admin-self.rules` makes
polkit name the asking wheel member.

**touchid-rearm (evaluated, not installed).** apple_sep locks Touch ID after five failed matches in a
row and keeps the lock across restarts (`/var/lib/aurora-sep-touchid-lockout.bin`). Only
`SEP_BIO_REARM` with a password that PAM just accepted ends it, and nothing calls that until
`touchid-rearm` is installed: today a lockout cannot be undone. Recommendation: install it, owner
present, with `rearm/install-rearm.sh` (backs up all Linux SEP state first, adds one `-auth optional`
line to `system-auth`, leaves `aurora-touchid-boot.service` disabled so Touch ID keeps working from the
first login). Its first re-arm makes the driver create its Linux FV KEK/VEK pair in the host-state
store, an enclave write that has not been exercised on this machine yet, which is why it is opt-in.
Omarchy's lock-screen password stack (`omarchy-lock-password`) does not include `system-auth`, so
after it is installed a lockout is cleared by a sudo or polkit password, not by the lock screen.
The driver's other macOS rules (48 h without an unlock, 156 h without a password) live in the
user-bag policy, which does not gate matching on this kernel today.

## Install / undo

```sh
# on the MacBook, as root, from a copy of this folder
bash install.sh                 # everything except rearm
bash install.sh --with-rearm    # also touchid-rearm (read rearm/install-rearm.sh first)
bash install.sh --uninstall     # panel, menu rows, guard, IgnorePkg line, polkit rule
```

The library needs a built package in `/home/<user>/build/libfprint-aurora/` (`makepkg -f` in
`libfprint-aurora/`; on the J716s it was repackaged from the existing build with
`makepkg -R -p PKGBUILD-libfprint-git`). Every file the installer replaces is copied to
`/root/<name>.before-touchid-omarchy-<stamp>` first.

Undo by hand, on the J716s as installed on 2026-11-17:
- panel and menu: `bash install.sh --uninstall`, or restore
  `/root/omarchy-menu.jsonc.before-touchid-omarchy-20261117-112256` and
  `rm -r ~/.config/omarchy/plugins/m5pro.touchid /usr/local/bin/m5pro-touchid`
- guard: `rm /etc/pacman.d/hooks/50-m5pro-touchid-guard.hook /usr/local/lib/m5pro/touchid-pacman-guard`,
  restore `/root/pacman.conf.before-touchid-guard`
- polkit rule: `rm /etc/polkit-1/rules.d/40-m5pro-admin-self.rules`
- back to the old package name: `touch /run/m5pro-touchid-allow-libfprint; pacman -U --ask 4
  /home/rolo/build/libfprint-aurora/libfprint-aurora-1.94.100-1-aarch64.pkg.tar.xz` (same files)

## Owner test steps (at the machine; pam_fprintd skips the reader over SSH)

Touch ID is the power button, top right of the keyboard: rest the finger on it, don't press.

1. **Panel.** Super+Alt+Space (Omarchy menu) > Setup > Security > **Touch ID**. Expect "1 of 3
   fingerprints" and Right index finger. Test it: touch, expect "Matched".
2. **Add.** Add a fingerprint > pick e.g. Left index finger. Omarchy's polkit dialog appears with the
   fingerprint glyph: touch with the right index finger (or wait and type the password). Then touch
   repeatedly, moving the finger a little, until "Fingerprint added" (roughly 10-15 touches). Type a
   name or press Enter. Test the new finger.
   If the polkit dialog shows a password field straight away instead of the glyph, the pre-claim
   authorization did not carry over: report it (the rest still works with the password).
3. **Rename.** Rename on a finger, type a name, Enter. The list shows the name with the finger below.
4. **Delete.** Delete on the new finger > the dialog warns > Delete > confirm with Touch ID. The list
   drops to 1 of 3. (Do not delete the right index finger unless you mean to.)
5. **Omarchy's own entry is safe.** Only if curious: in a terminal,
   `sudo pacman -S libfprint-git` must fail with "m5pro-touchid-guard: refusing this transaction".
6. **1Password.** Lock 1Password (Ctrl+Shift+L in the app, or from the tray). Click the unlock
   prompt: Omarchy's dialog shows the fingerprint glyph; touch. 1Password unlocks.
   Right after 1Password starts (and after a restart) it asks for the account password once by
   design; system unlock works from the next lock. In the browser (Chrome/Chromium) the extension
   unlocks with the app. `op vault ls` in a terminal shows the same dialog; touch.
   If 1Password offers only the password: Settings > Security > "Unlock using system authentication
   service" must be on (it is on today).
7. **Admin prompt.** Plug in a USB stick or run `pkexec true`: the dialog must accept your own
   finger/password (it used to ask for `alarm`).

## Risks

- Five failed matches in a row (any mix of lock screen, sudo, polkit, the panel's Test) lock Touch ID
  until `touchid-rearm` is installed and a password is typed. pam_fprintd tries up to three times per
  prompt, so two wrong-finger prompts in a row are enough.
- The pre-claim polkit authorization relies on polkit keying `auth_self_keep` to the helper process.
  If it does not carry over, Add and Delete ask for the password in the dialog instead of a touch.
- If Omarchy ships a `libfprint-git` with `epoch>=2`, `IgnorePkg` and the hook still hold it; a
  `-Syu` then lists it as ignored.
- `install.sh` must not guess the user from `/home`: the image's leftover `alarm` account sorts first
  (it now uses the seat0 session's user).
