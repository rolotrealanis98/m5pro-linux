# mesa-aurora-side-by-side: Aurora Mesa next to the session Mesa, A/B by environment only

Built 2026-11-17 for `gpu-mesa-aurora-1` (report: `/Volumes/m5pro/bench/requests/gpu-mesa-aurora-1.md`).
The MacBook's session already runs Aurora Mesa from `/opt/mesa-aurora` (`/etc/mesa-aurora/session.env`); this item adds a second
tree, `/opt/mesa-aurora-20261117` (aurora-silicon/mesa `aurora-wip` `db928e79933d`), and changes nothing else: no session env,
no pacman, no `/usr`.

| File | Does |
|---|---|
| `../../distro/pkg/mesa-aurora/build-container.sh` | Studio: builds the tree in an Arch Linux ARM container, stages it, same recipe as the alarm-aurora PKGBUILD |
| `install-tree.sh` | Puts the tarball under `/opt/mesa-aurora-<date>` (refuses to overwrite) |
| `ab-env.sh` | `. ab-env.sh PREFIX zink\|native`: environment for ONE process (LD_LIBRARY_PATH, EGL/GLX vendor, VK_DRIVER_FILES, loader override) |
| `run-ab.sh` | vulkaninfo, eglinfo, vkcube, glmark2 subset, gpubench-vk tests; stops at the first GPU kernel fault line |
| `app-check.sh` | Alacritty, glmark2, foot, kitty from `APP-REGRESSIONS.md`; captures only the test window |

On the MacBook the scripts live in `/home/rolo/gpu-ab/` (owner rolo), results in `/home/rolo/gpu-ab/results/`.
Run as the desktop user: `runuser -u rolo -- bash -c 'cd /home/rolo/gpu-ab; ./run-ab.sh LABEL /opt/mesa-aurora-20261117 native'`.

Undo: `rm -rf /opt/mesa-aurora-20261117 /home/rolo/gpu-ab`.
