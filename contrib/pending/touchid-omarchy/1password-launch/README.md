# 1Password: Touch ID from a fresh start (m5pro-1p-touchid)

1Password on Linux asks for the account password after every start (app launch, login, reboot);
only after that does its own "Unlock using system authentication" (Touch ID through polkit) work,
until it quits. This item closes that gap on the J716s: the account password is sealed by the
Secure Enclave, and after a Touch ID match it is typed into 1Password's own lock screen.

## How it works

- **Setup** (`m5pro-1p-touchid setup`, in a terminal at the machine; menu Setup > Security >
  1Password Touch ID > Set up): reads the password twice from the terminal without echo (bullets
  only), into a byte buffer that is zeroed after use, and pipes it to `pkexec m5pro-1p-seal seal`.
  The Omarchy polkit dialog ("Save your 1Password password for Touch ID unlock") asks for Touch ID
  or the login password.
- **Sealing** (`m5pro-1p-seal`, root, C): aurora-sep-userspace's LUKS/SSH sealing
  (`luks/sep-seal.c`, vendored unchanged): a fresh 32-byte AES key from the kernel `trusted` key
  type with the `applesep` source, used by keyring serial through AF_ALG AES-256-CCM, so the AES
  key never reaches userspace. The password is padded to 256 bytes; the additional data is
  `m5pro-1p-touchid:1:<uid>:<random id>`, so a LUKS or SSH record of the same SEP cannot stand in.
  The seal is proved by reopening it with a key loaded afresh from the blob, the same path a boot
  takes. The record is `/var/lib/m5pro-1p-touchid/<uid>.record`, root 0600. Unsealing is limited to
  four per minute per user.
- **Unlock** (`m5pro-1p-touchid unlock`, the watcher, or menu > Unlock 1Password now):
  1. 1Password's state comes from its own log (`~/.config/1Password/logs/1Password_rCURRENT.log`,
     `Lock state changed` and `Sys auth status` since the process started). Unlocked: nothing to do.
     `Sys auth status Ready`: 1Password's own Touch ID unlock is armed, so this tool only shows the
     window and lets 1Password ask.
  2. Shows 1Password's window (a second launch hands over to the running app) and waits for it.
  3. `pkexec m5pro-1p-seal unseal`: polkit action `org.m5pro.1p-touchid.unlock` ("Unlock
     1Password"), `auth_self` every time, so Omarchy's dialog takes Touch ID (pam_fprintd in
     `/etc/pam.d/polkit-1`) or the login password. The password comes back on a pipe.
  4. Checks again: same 1Password process, still locked, its window present; focuses it and checks
     that the active window is that address and belongs to `/opt/1Password/1password`. Ctrl+A,
     types the password with `wtype -` (stdin, not argv), checks focus again, presses Enter.
     If any check fails nothing (more) is typed and a notification says why.
  5. Waits for `Lock state changed: Unlocked` in 1Password's log; otherwise notifies ("if you
     changed your account password, run Setup again"). After this unlock, 1Password logs
     `Sys auth status Ready` at its next lock and handles Touch ID itself until it quits.
- **Watcher** (`m5pro-1p-touchid-watch.service`, user unit, `graphical-session.target`): unlocks
  when a new 1Password main process appears (login autostart, relaunch) and when a 1Password window
  opens while it is locked and its own Touch ID is not armed. After an attempt, or a dismissed
  dialog, it stays quiet for two minutes. Turn either trigger off in
  `~/.config/m5pro-1p-touchid/config`: `at_launch = no`, `on_window = no`.

## What it protects, and what it does not

- The saved password opens only on this Mac, with this Linux install's SEP identity and key store
  (the same binding as aurora-sep-userspace's LUKS and SSH sealing). A copied disk or backup holds
  nothing usable.
- Touch ID is enforced by polkit + PAM in software, not by an enclave access policy: **root on this
  Mac can unseal the password without a finger**, and so can anyone who can become root without a
  touch (a NOPASSWD sudo rule or cached sudo ticket). 1Password's own design never stores the
  account password; this is weaker, and the owner accepted that trade-off (2026-11-17).
- Typing goes to whatever window has the keyboard at that instant. The tool checks the window
  right before typing and before Enter, but a window that grabs focus in the few milliseconds
  between could receive the text. It never types without the 1Password window being in front.
- The password never goes into argv, the environment, files or logs; it travels by pipes and the
  tool's buffers are zeroed (copies inside pipes and wtype's memory are not under its control).
- Each Touch ID dialog is fprintd's ordinary verify and counts toward the enclave's five-miss
  lockout like any other.

## Install, test, undo

```sh
bash install.sh                # root, on the MacBook; then the owner runs Setup at the machine
bash install.sh --uninstall    # destroys every saved record, removes the tool, unit, policy, menu rows
```

Owner steps:
1. Setup: Omarchy menu > Setup > Security > 1Password Touch ID > **Set up**. In the terminal, type
   the 1Password account password twice (bullets only). Confirm in the dialog with Touch ID.
   "Saved." closes it.
2. Fresh start: 1Password tray icon > **Quit 1Password** (or `pkill -x 1password`), then open
   1Password from the launcher. Its window appears, then the dialog "Unlock 1Password": touch.
   The password is typed and 1Password opens.
3. After that, lock 1Password (Ctrl+Shift+L): its own Touch ID prompt handles it (no typing).
4. On demand: menu > Setup > Security > 1Password Touch ID > **Unlock 1Password now**.
5. Status: same submenu > Status. Remove: same submenu > **Remove the saved password** (dialog),
   or `install.sh --uninstall`.
6. After a reboot the saved password must still open: restart the Mac once and repeat step 2.
   If it fails with "refused: sealed on another Mac or Linux install", the SEP identity or key
   store changed; run Setup again.

Changed the 1Password account password? Run Setup again (the old record is replaced).
