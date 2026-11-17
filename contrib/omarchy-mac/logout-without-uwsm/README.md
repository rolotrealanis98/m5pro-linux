# logout-without-uwsm

Scope: j716s (any Mac whose Omarchy desktop is started from a tty autologin instead of uwsm). Status: installed 2026-11-17.

Omarchy's System > Log out runs `uwsm stop`, which does nothing here because the desktop is started by tty2 autologin
(`~/.local/bin/hypr-session`), not by uwsm. `uwsm` in this folder wraps the real one: on `stop` with no uwsm compositor it
ends the user's seat0 session (`loginctl terminate-session`), so autologin starts a fresh desktop. All other calls pass through.

Install: `install -m755 uwsm /usr/local/bin/uwsm`. Undo: `rm /usr/local/bin/uwsm`.
Dry run: `M5PRO_UWSM_DRYRUN=1 /usr/local/bin/uwsm stop` prints the session it would end.
Upstream: Omarchy (omarchy-system logout could fall back to `loginctl terminate-session` when uwsm isn't managing the session).
