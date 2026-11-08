# Hyprland 0.57.1 with the direct-scanout failed-candidate latch (hyprland-m5pro)

The M5 Pro MacBook runs Arch Linux ARM's `extra/hyprland 0.57.1-1` (tag v0.57.1, acc1aa0) with
aquamarine 0.16.0 on the apple-drm DCP display without modifiers (`AQ_NO_MODIFIERS=1`, the DCP scans
out linear only). With `render:direct_scanout = 1`, a fullscreen client whose buffer is tiled (glmark2
on zink, vkcube, mpv) is a scanout candidate Hyprland re-tests on every client frame: each test
reconfigures the output swapchain to the client's format (3 new 31 MB dumb buffers), fails, and the
composed frame reconfigures it back (3 more) and modesets. The replaced buffers were never released:
48 GB in 7 s, OOM-killed session (2026-11-08). Analysis and upstream draft:
`contrib/pending/gpu/userspace/HYPRLAND-DIRECT-SCANOUT-LEAK-REPORT.md`.

Files here:

- `0001-direct-scanout-latch-failed-candidate.patch`: against v0.57.1 (applies to the release tarball
  with `patch -Np1 --fuzz=0`, also after Omarchy's three carried patches). Hyprland only; aquamarine is
  unchanged.
- `pkg/PKGBUILD`: `hyprland-m5pro 0.57.1-1`, Arch's `extra/hyprland 0.57.1-1` recipe (the one ALARM
  ships; Omarchy's `pkgbuilds/hyprland 0.57.1-2` is the same recipe plus three unrelated patches) with
  only our patch added. `provides=(hyprland=0.57.1 wayland-compositor)`, `conflicts=(hyprland)`.
  `pkg/0001-...patch` is a symlink to the patch above; copy the whole `hyprland/` directory.
- Built package, build logs and sha256 (private, not in the repo): `~/Work/agents/hyprland-fix/` on
  the Studio, built in an `menci/archlinuxarm:base-devel` container with Apple `container`
  (`makepkg -sL` as an unprivileged user; `pacman -Syu` inside the container only).

## What the patch changes (src/output/Monitor.cpp, Monitor.hpp)

1. Latch (`DS_BLOCK_FAILED`, which existed but was never set): when the scanout test of a candidate
   fails, `CMonitor` remembers the window and the format and modifier of the buffer it offered.
   `isDSBlocked()` reports `DS_BLOCK_FAILED` for that window while it keeps offering buffers with that
   format and modifier, so the frame is composited instead of re-tested. `recheckSolitary()` drops the
   latch as soon as the solitary candidate is another window or none (new fullscreen client, the same
   one after leaving fullscreen, a notification or workspace animation in between): the next candidate
   gets one fresh test. A later buffer with another format or modifier from the same window is tested
   too. `hyprctl monitors` shows `directScanoutBlockedBy: activation failed` while the latch holds.
2. No swapchain reconfigure in the test: `attemptDirectScanout()` leaves `m_drmFormat` and the output
   format alone until the test passes and tests with `m_output->test()` instead of `m_state.test()`
   (which first reconfigured the swapchain to the client's format). aquamarine tests a buffer whose
   format differs from the output's as a modeset, the same way it did when the format was set first,
   so the test's outcome does not change. On success the client's format is adopted right before the
   commit, as before. The cursor-update path (same buffer already on the plane) tests with
   `m_output->test()` too; the swapchain update there was a no-op.
3. No modeset for an unchanged format: the rollback after a failed test only calls `setFormat()` if
   the output state's format differs from the one being restored. aquamarine marks a `setFormat()`
   as a change even when the value is the same and modesets on the next commit for it.

Behaviour when the test passes is unchanged, except that the swapchain is no longer switched to the
client's format at scanout entry (it is switched lazily by the next `CMonitorState::commit()` during
the scanout, if any, exactly the code path that ran before; it is already in the output's format when
the scanout ends, which also removes the blank first frame after a scanout today). On a successful
test with a differing format, aquamarine logs one `drm: Formats mismatch in commit ... Modesetting to
...` WARNING line (it did the modeset test before as well, without the line); it does not appear in
the failing case, which is rejected earlier (`CDRMBufferUnimportable`), nor on the real commit.

Risk: a scanout test that failed for a transient reason stays blocked until the candidate changes
(any solitary gap clears it). The latch is per window, format and modifier; another window, or a
buffer the backend may import (LINEAR), is still tried.

## Install on the MacBook (as root, from a shell in the session or over ssh)

Copy the package and keep the stock one in the pacman cache for the rollback:

```sh
ls /var/cache/pacman/pkg/hyprland-0.57.1-1-aarch64.pkg.tar.xz || pacman -Sw --noconfirm hyprland   # stock copy for rollback
sha256sum hyprland-m5pro-0.57.1-1-aarch64.pkg.tar.xz           # compare with ~/Work/agents/hyprland-fix/SHA256SUMS
pacman -U hyprland-m5pro-0.57.1-1-aarch64.pkg.tar.xz           # "hyprland and hyprland-m5pro are in conflict. Remove hyprland? [y/N]" -> y
pacman -Q hyprland-m5pro hyprpm xdg-desktop-portal-hyprland     # hyprpm and the portal stay (provides=hyprland=0.57.1)
```

`pacman -U` downloads nothing, so the download sandbox does not matter (if `pacman -Sw` fails with the
Landlock error on a kernel without `CONFIG_SECURITY_LANDLOCK`, fetch the `pacman -Sp` URL as the
`alpm` user into `/var/cache/pacman/pkg/` as `omarchy/REPORT.md` describes, or set `DisableSandbox`
in `pacman.conf` for that one command). Omarchy's `00-omarchy-update-guard.hook` only stops a plain
`pacman -Syu`, and the m5pro boot guard does not list hyprland. The running compositor keeps the old binary mapped: finish with a session restart
(`m5pro-desktop`-style logout, or `systemctl restart getty@tty2` from ssh, which kills the session
on tty2 and autologin starts a new one).

Keep `omarchy update` / `pacman -Syu` from putting the stock package back. Nothing replaces a package
no repository carries, and `omarchy`'s `hyprland` dependency is satisfied by `provides`, but a script
that installs `hyprland` by name would pull the stock build and conflict. Add it to the existing
`IgnorePkg` line in `/etc/pacman.conf` (the `# m5pro-boot-guard` one), or its own line:

```
IgnorePkg = hyprland
```

pacman then asks before installing `hyprland` even as a dependency instead of doing it silently.

When upstream fixes land (a Hyprland release whose `attemptDirectScanout()` no longer retries a
failed candidate, or `omarchy-pkgs` carries the fix): drop `hyprland` from `IgnorePkg`, then
`pacman -S hyprland` (removes `hyprland-m5pro` on the conflict prompt). Do not bump `hyprland-m5pro` to
a new upstream version without re-reading `src/output/Monitor.cpp`: the patch is against 0.57.1 and
`--fuzz=0` is on purpose.

## Verify (storm reproduction, direct scanout ON)

The GPU session launcher (`hypr-gpu-session`) sets `M5PRO_DCP_DIRECT_SCANOUT=0` whenever it exports
`AQ_NO_MODIFIERS=1`, and `m5pro-dcp.lua` turns `render:direct_scanout` off from that. For the test,
turn direct scanout on at runtime in the live session and run the client that caused the storm.
Before the patch this allocated ~185 MB of dumb buffers per client frame; keep the run short and
watch the log live the first time:

```sh
# as the session user (or root with HYPRLAND_INSTANCE_SIGNATURE and WAYLAND_DISPLAY from the session)
hyprctl version                       # branch m5pro-ds-latch, commit message "hyprland-m5pro 0.57.1-1: ..."
hyprctl keyword cursor:inactive_timeout 1 ; hyprctl keyword render:direct_scanout 1
HLOG=$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/hyprland.log
tr -d '\000' < "$HLOG" | grep -c 'Reconfigured a swapchain'       # baseline count
( tr -d '\000' < "$HLOG" | grep -c 'Modesetting' )                 # baseline count
glmark2-es2-wayland --fullscreen -b build:duration=8 &            # hands off keyboard and trackpad while it runs
sleep 12
tr -d '\000' < "$HLOG" | grep -E 'Reconfigured a swapchain|Modesetting|scanout test failed|Buffer failed to import' | tail -20
hyprctl keyword render:direct_scanout 0                           # back to the launcher's setting
```

Expected with the patch: at most one `attemptDirectScanout: scanout test failed for ... blocking it`
DEBUG line per fullscreen enter (one `Buffer failed to import to KMS` ERR group per client buffer the
first time each is tested, 4 for glmark2), **no** `Swapchain: Reconfigured a swapchain` and **no**
`drm: Modesetting eDP-2` during the run, the client composited at the panel rate, `hyprctl monitors`
showing `directScanoutBlockedBy: activation failed` while glmark2 is fullscreen, and
`ls /proc/$(pidof Hyprland)/fd | wc -l` flat. Before the patch: one AR24 and one XR24 reconfigure and
one modeset per client frame, fds climbing by 6 per frame.

`hypr-dcp-verify` (`contrib/pending/gpu/userspace/mesa-aurora/session-dcp/`) already counts the
reconfigures over its fullscreen glmark2 run and fails above 4 (`glmark2: swapchain reconfigured N
times`); it reports the profile check as FAIL while `render:direct_scanout` differs from what the
launcher set, which is expected during this test. Once the patch is verified, the launcher can set
`M5PRO_DCP_DIRECT_SCANOUT=1` with `AQ_NO_MODIFIERS=1` again (nothing is gained: a tiled buffer still
cannot be scanned out, it is just no longer retried), or stay at 0.

Plugins: the plugin API hash includes `GIT_COMMIT_HASH`. The release tarball ships `src/version.h.in`
pre-filled (hash acc1aa0, branch "v0.57.1"), so extra/, [omarchy] and this package carry the same
hash; the PKGBUILD only rewrites the branch and commit-message labels `hyprctl version` prints. A
plugin built against the stock 0.57.1 (e.g. `omarchy-hyprland-titlebars`, not installed on the
MacBook) keeps loading.

## Rollback

```sh
pacman -U /var/cache/pacman/pkg/hyprland-0.57.1-1-aarch64.pkg.tar.xz   # conflict prompt removes hyprland-m5pro
sed -i 's/^IgnorePkg = hyprland$//' /etc/pacman.conf                    # or edit the line by hand
```

then restart the session. If the cache copy is missing: `pacman -S hyprland` (same version from
`extra/`; `[omarchy]` is listed last, so ALARM's build wins).

## Rebuild on the MacBook (if the Studio package is not at hand)

Omarchy's base system has `base-devel` (makepkg, gcc 16, cmake, meson, ninja); the makedepends
(`glaze hyprland-protocols hyprwayland-scanner xorgproto`) come from `extra/` (`pacman -S --needed`,
or the `pacman -Sp` + curl-as-alpm workaround from `omarchy/REPORT.md` while Landlock is off).
Never as root:

```sh
cp -a contrib/validated/desktop/hyprland /tmp/hyprland-m5pro && cd /tmp/hyprland-m5pro/pkg
cp -L ../0001-direct-scanout-latch-failed-candidate.patch .        # replace the symlink if cp -a kept it
PKGDEST=$PWD/out LOGDEST=$PWD/out makepkg -sL                       # ~10 min on the 18 cores, ~56 MB source download
```
