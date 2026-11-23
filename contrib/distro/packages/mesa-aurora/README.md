# mesa-aurora with G17: nothing to carry (checked 2026-11-23)

The gap-map row says "mesa-aurora has no G17". That is no longer true; there is no PKGBUILD in this folder on purpose.

| Fact | Evidence (read-only `gh`) |
|---|---|
| aurora-silicon/mesa #194 "asahi: native Gallium GL on the M5 Pro and M5 Max (G17S, G17C)" is **merged** | merged 2026-11-10 13:20 UTC, merge commit `10161a78e60e` |
| omarchy-pkgs `mesa-aurora` pins omacom/mesa `e705eca833f3` (pkgver `1:26.3.0_devel.20261122.232644.e705eca833f`) = aurora-wip `1fdf5396758f` + #415/#416 | `pkgbuilds/mesa-aurora/PKGBUILD`, tag aurora-7.3.0-1 |
| `10161a78e60e` is an ancestor of that pin | compare API: ahead 856, behind 0 |
| The M5 Pro default admission (`#348`, `a967585acaf1`: "asahi: enable implemented GPU features without feature opt-ins") is an ancestor too | ahead 518, behind 0 |
| `src/asahi/lib/agx_chip.c` at the pin has the admission clause | `(chip == AGX_CHIP_G17S && params->chip_id == 0x6050 && params->num_clusters_total == 2)` and the G17C one |
| The pin also adds `llvmpipe` and tags Honeykrisp ("aurora" DRM driver name accepted next to "asahi") | PKGBUILD comments |

So a stranger on the J716s needs the **stock omarchy-pkgs `mesa-aurora` + `vulkan-aurora` at or above `1:26.3.0_devel.20261120.232519.fb3b11e121c`**, which is
exactly what omarchy-pkgs' `linux-aurora` already `conflicts` below. `linux-aurora-j716s` repeats that conflict.

What is *not* proven by this: the Mac's measured Mesa is the Studio-built `/opt/mesa-aurora-20261117` (aurora-wip `db928e79933d`, G17S, native GL about 1.8x
glmark2 vs zink, no GPU faults; `contrib/distro/pkg/mesa-aurora/README.md`, `gpu-mesa-aurora-1.md`). The packaged `e705eca833f3` has not been installed and run
on the J716s. First hardware step when someone builds it: install side by side like `/opt/mesa-aurora-20261117` (aarch64 build, ~1 h on the Studio's container,
`contrib/distro/pkg/mesa-aurora/build-container.sh`), run `glmark2`, `vulkaninfo`, watch for GPU faults, then swap.

`contrib/distro/pkg/mesa-aurora/PKGBUILD` (a copy of alarm-aurora's recipe at `db928e79933d`) is the older local pin; it can be deleted once the packaged
Mesa has run on the Mac.

## Waits for

- Nothing upstream. Waits for one hardware run of the packaged Mesa on the J716s, and for the gap-map text to be corrected.
- The kernel it pairs with: omarchy-pkgs `linux-aurora` 7.3.0 has the "aurora" GPU driver, but no J716s GPU bring-up (that is our branch, `linux-aurora-j716s`).
