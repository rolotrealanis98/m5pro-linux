# Mesa: use alarm-aurora's `mesa-aurora`, no package of our own

Decision, 2026-11-15: no `mesa-m5pro`. alarm-aurora's `mesa-aurora` at the current pin already contains the M5 Pro
default admission, so the simplest thing that gets it is to install that package.

## Pin

| What | Value |
|---|---|
| Recipe | aurora-silicon/alarm-aurora `packages/mesa-aurora/PKGBUILD`, main `27109d226aa5ec80734f30e5d9e754e433e08f40` (PR #319, 2026-11-15) |
| Mesa | aurora-silicon/mesa `d4ad4a4dce6d1d23ecd897d6d73fadf9ab618614` (2026-11-15, "st/mesa: reject links mixing GLSL and SPIR-V shaders in either order"); `pkgver` `26.3.0_devel.202611150611.d4ad4a4dce6`, `epoch=1` |
| Packages | `mesa-aurora` (GL, Zink), `vulkan-aurora` (Honeykrisp), `opencl-rusticl-aurora`, `vulkan-lavapipe-aurora`; `provides=mesa`, `conflicts=mesa` |

## The admission fix is in it

Branch `fix/m5-pro-default-admission-20261114` (`7e428d50810c`) carries `67ac6c3e115c` ("asahi: admit the exact M5 Pro
contract without an environment override") and `9a71d48fc32e` ("asahi: select implemented GPU features without
environment opt-ins"). Both landed as `a967585acaf1` ("asahi: enable implemented GPU features without feature opt-ins
(#348)", squash, 2026-11-14 22:03 UTC). GitHub's compare API says `a967585a` is an ancestor of `d4ad4a4d` (`d4ad4a4d` is 9 commits
ahead, 0 behind), and `src/asahi/lib/agx_chip.c` at `d4ad4a4d` contains the added `agx_params_m5_supported()` clause:

```
/* T6050 M5 Pro (J714s/J716s): G17S, one die, two clusters. */
(chip == AGX_CHIP_G17S && params->chip_id == 0x6050 && params->num_clusters_total == 2) ||
```

`67ac6c3e` and `9a71d48f` themselves are not ancestors of `d4ad4a4d` (they are on the topic branch; main has the squash).
Use `d4ad4a4d` or later; do not pin the two topic commits.

## Using it

- The recipe needs `llvm`, `clang`, `rust`, `libclc`, `spirv-llvm-translator`, `spirv-tools` and builds Mesa twice; it is
  an aarch64 build. It is the [aurora] repo's package, so the simplest is to add that repo; building it ourselves is the
  PKGBUILD copied unchanged.
- The kernel must match: the recipe says "Matched to the DRM UAPI in aurora-silicon/linux integration/aurora". The
  packaged `linux-m5pro` (asahi-wip-7.2) has no GPU driver (GAPS.md item 13); `j716s-next`, which is rebased on
  `integration/aurora`, is the kernel this Mesa matches.
- Not built, not run: nothing here has touched the MacBook, and the M5 Pro contract is "admitted", which the source
  itself says "is not a declaration of a complete or conformant device path".
