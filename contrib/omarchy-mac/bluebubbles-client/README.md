# BlueBubbles client (Messages) for the J716s

An optimized build of the upstream BlueBubbles desktop client (iMessage through a BlueBubbles server on another Mac) for Omarchy on the 16" M5 Pro. Phase 1 (2026-11-27): reproducible build and install, measurements, glitch survey, plans. Local work only: no forks, pushes or issues on BlueBubbles repos.

Contents: `build.sh`, `install.sh`, `files/bluebubbles` (the wrapper), `patches/` (series exported from branch `m5pro/client`), `tools/` (measurement and launch helpers), `results/` (raw measurements), `GLITCHES.md`, `SLIM-PROFILE.md`, `REWRITE.md`, `api-inventory.md`, `settings-inventory.md`.

## Where things live
- Source: `/Volumes/m5pro/bluebubbles/bluebubbles-app`, clone of `BlueBubblesApp/bluebubbles-app` at tag `v2.1.6+desktop.96` (`f931e26a1`). Local branch `m5pro/client`, author `Rolando Trevino <122947376+rolotrealanis98@users.noreply.github.com>`. One commit so far (the series in `patches/`).
- Build outputs: `/Volumes/m5pro/bluebubbles/out/` (tarballs, sha256, logs), one file per commit (`...-<label>-<commit>.tar.gz`), never replaced. The phase 1 names without a commit (`...-m5pro-client.tar.gz`, `...-diag-base.tar.gz`) are the first builds of this phase and of phase 1 (the phase 1 client tarball was overwritten once by mistake before this rule).
- On the Mac: `~/.local/opt/bluebubbles-m5pro/` (ours), `~/.local/opt/bluebubbles/` (upstream, untouched), wrapper `~/.local/bin/bluebubbles`, launcher `~/.local/share/applications/bluebubbles.desktop` (unchanged: "Messages", icon `messages-imessage`). Bench helpers: `~/.local/share/bluebubbles-bench/`.

## Build
Studio (macOS) runs an Ubuntu 24.04 arm64 container (`bb-build`, 10 CPUs, 16 GB, the same distro as upstream's `ubuntu-24.04-arm` CI job) with the same package list as `desktop-builds.yml`, plus `build-essential` and a headless JDK (the runners ship both; `libdartjni.so` is only built with a JDK). Flutter 3.47.8 (the pin in `.github/workflows/*.yml` and `linux/build.sh`) cloned from git into the container, then upstream's own `linux/build.sh` with `FLUTTER_CMD=flutter`: `pub get --enforce-lockfile`, `flutter build linux --release`, tarball. Source is copied in with `git archive`, so the checkout stays clean and the host mount is not walked (vnode pressure). Serialized with `lockf /Volumes/m5pro/bench/.build-lock`.

```
contrib/omarchy-mac/bluebubbles-client/build.sh 'v2.1.6+desktop.96'   # the untouched upstream tag
contrib/omarchy-mac/bluebubbles-client/build.sh                       # branch m5pro/client
```
Why the container and not the Mac: same toolchain as upstream, no Flutter SDK, JDK or dev headers installed on the Mac, builds do not compete with kernel tests there, and the bundle built on Ubuntu 24.04 loads on the Mac (it runs there). Time: rebuilds take 1 min 50 s (container, SDK and pub cache warm); the first run adds the apt install, the Flutter clone and the engine download (a few minutes). The `.env` is empty (it carries the upstream Klipy GIF key): `install.sh` reuses the installed upstream copy.

Reproduction check: the rebuilt tag has the same 83-file list as the upstream tarball (installed copy), identical `libflutter_linux_gtk.so` and `version.json` (2.1.6.0, build 96); `bluebubbles`, `libapp.so` and `libdartjni.so` differ (embedded paths and timestamps, not byte-reproducible). Measured behaviour is the same (table below).

The slim profile is compiled in with `--dart-define=BB_SLIM=true`: `build.sh` turns it on for the branch and off for a pure upstream tag and for `diag-base` (override with `BB_SLIM=0|1`). `BB_ANALYZE`-style checks are run by hand in the container: `flutter analyze --no-pub` and `flutter test` in a copy of the tree.

## Install and switch
```
contrib/omarchy-mac/bluebubbles-client/install.sh /Volumes/m5pro/bluebubbles/out/bluebubbles-linux-aarch64-m5pro-client.tar.gz [tag]
```
Refuses while BlueBubbles runs (the app data dir `~/.local/share/app.bluebubbles.BlueBubbles` is shared; never run two). Moves an existing `bluebubbles-m5pro` to `bluebubbles-m5pro.pre-<tag>-<date>`, extracts the new one, backs the old wrapper up once as `~/.local/bin/bluebubbles.pre-m5pro-client-20261127`, writes the new wrapper. Environment switches of the wrapper: `BLUEBUBBLES_UPSTREAM=1` (original install), `BLUEBUBBLES_SOFTWARE_GL=1` (llvmpipe), `BLUEBUBBLES_IMPELLER=1` (our build only).

Backups on the Mac as left by phase 1: `~/.local/bin/bluebubbles.pre-m5pro-client-20261127` (the original wrapper), `~/.local/opt/bluebubbles-m5pro.pre-client1-20261127` (the first, JDK-less reproduction build).

## Roll back
```
mv ~/.local/bin/bluebubbles.pre-m5pro-client-20261127 ~/.local/bin/bluebubbles   # original wrapper: runs ~/.local/opt/bluebubbles
rm -rf ~/.local/opt/bluebubbles-m5pro ~/.local/opt/bluebubbles-m5pro.pre-*       # optional; the upstream install is never modified
```
Or just `BLUEBUBBLES_UPSTREAM=1 bluebubbles`. Close the app first (`hyprctl dispatch "hl.dsp.window.close({ window = \"class:bluebubbles\" })"` hides it to the tray; the process stays: quit it from the tray or `pkill -TERM -x bluebubbles`).

## Patch series (`patches/`) and upstream target
Branch `m5pro/client` on the tag `v2.1.6+desktop.96`; `patches/` is `git format-patch` of it (apply with `git am`). `patches/baseline/` is the diagnostics-only commit (upstream plus `BB_DIAG` marks, no behaviour change) that builds the "base" comparison binary: `git checkout -b diag-base v2.1.6+desktop.96 && git am patches/baseline/*.patch`.

| Patch | Change | Upstream target |
|---|---|---|
| 0001 | `BLUEBUBBLES_IMPELLER=1` opts into Impeller; Skia stays default (Impeller measured worse here) | optional, harmless |
| 0002 | settings: UI scale, font scale, system font, follow Omarchy theme, reopen last chat; titlebar hidden by default | ours (defaults); the settings keys could go upstream |
| 0003 | linux runner: pass GTK `text-scaling-factor` and `font-name` to Dart, push changes; window title `BlueBubbles` | upstream-able |
| 0004 | UI follows the desktop text size: whole-UI scale plus Desktop Settings controls | ours (Omarchy-specific default), the mechanism is upstream-able |
| 0005 | desktop interface font; Noto Color Emoji fallback on Linux | upstream-able (fixes tofu and flat hearts for every Linux user; see upstream `joel/test/fontconfig`) |
| 0006 | start on the chat list, setting to reopen the last chat | upstream-able as a setting |
| 0007 | image cache cap; `BB_DIAG` startup and frame diagnostics | upstream-able |
| 0008 | follow the active Omarchy theme (`colors.toml`), live | ours (Omarchy) |
| 0009 | slim profile `BB_SLIM`: hide about 45 tiles and 7 entries, Messages-like seeded defaults | ours |

Upstream is already working near this: remote branches `joel/perf/chat-layers` (2026-11-19, chat list layers), `joel/test/fontconfig` (2026-11-18), `joel/fix/main-thread-blocking` and `joel/fix/desktop-responsiveness` exist in the clone; rebase onto the next tag and drop what lands there. The slim profile and Omarchy theme stay ours.


## Scaling: root cause and fix
Phase 1 (measured on the device): the buffer scale is right (`set_buffer_scale(2)`, 2200x1518 buffers, sharp text), `GDK_SCALE` is ignored on Wayland, and the app disagreed with Omarchy only in size.
Root cause found in phase 2: Omarchy has one text-size knob, `omarchy-display-text-size`, which sets the shell base size (10 px now), the GTK `text-scaling-factor` (0.8182) and the terminal font together; GTK apps follow (Liberation Sans 11 pt x 0.8182 = 9 pt = 12 px). The Flutter engine reads the same GSettings key (`g_settings_get_double`; engine text scale 0.8182 observed) and applies it to text only, while the app is laid out for a phone (body 14 px, bubbles 15 px, titles 22 px) at a fixed size. Text shrank, widgets did not, and nothing in the app could change either. Upstream has no scale option.
Fix (patches 0002 to 0005): the runner reads `text-scaling-factor` and `font-name` and passes them to Dart, live; `DesktopScaleWrapper` lays the whole UI out at window/scale and scales it back (`FittedBox`, correct hit testing), replacing the engine's text-only factor by a font-size multiplier; automatic scale = desktop text px / 14 = 0.857 now, so body text is 12 px like GTK apps and bubbles 12.9 px; the app font is the desktop's interface font. Desktop Settings gets Match Desktop Text Size (auto, follows `omarchy-display-text-size` live), Interface Scale (0.6 to 1.6), Font Size (80 to 150 percent), Use Desktop Font. `BB_UI_SCALE` and `BB_FONT_SCALE` override them for measuring. Unit tests cover the math (`test/desktop_follow_test.dart`, 7 tests, passing in the container).
Observed on the device in one run before it was withdrawn (side by side with a plain GTK3 window in the same session; screenshot `dev1-ref-compare.png` in the shots folder): app diagnostics `ui=0.857 gtkTextPx=12.00 bodyPx=12.00`, `refreshRate=120 dpr=2 engineTextScale=0.8182`; the app's list text and the GTK label are the same size by eye. Still to confirm with numbers on the device: the comparison against the Omarchy shell bar text and a Qt app, and fractional Hyprland scales (not solved: GLITCHES.md 9).


## Baseline (task: performance) and where the cost is
Mac, Aurora GPU (Mesa tip-hwrq6, `/etc/mesa-aurora/session.env`: GL on the native Gallium driver `libgallium-26.3.0-devel` through `libEGL_aurora`), Skia, window 1100x759 on its own workspace, chat list scrolled with a virtual wheel at 60 notches/s for 10 s (no chat opened by the harness, nothing clicked). Tool: `tools/bb-measure.py` (`/proc` sampling; frame pacing from `WAYLAND_DEBUG` commit intervals in separate runs because tracing costs CPU). Raw files in `results/`. The Mac had just rebooted, so absolute RSS is on a fresh database; compare rows, not absolutes. One run per cell; idle CPU varied 1.1-3.3 percent between upstream runs.

| Metric | Upstream | m5pro (Skia, default) | m5pro, Impeller |
|---|---|---|---|
| Cold start: window mapped | 0.23-0.25 s | 0.24-0.25 s | 0.24-0.34 s |
| CPU settled (under 5 percent for 3 s) | 4.2 s | 4.2 s | 4.2-4.3 s |
| RSS after start | 507-536 MB | 518-537 MB | 903-914 MB |
| Idle 60 s: CPU | 1.1-3.3 % | 1.2 % | 3.4 % |
| Idle 60 s: wakeups per second | 32-35 | 26 | 41 |
| Idle RSS range | 474-717 MB | 566-770 MB | 1085-1303 MB |
| Scroll 10 s: CPU | 53 % (58 % traced) | 47 % (44 % traced) | 69 % (68 % traced) |
| Scroll RSS after | 890-911 MB | 902-1002 MB | 1433-1439 MB |
| Commit rate while scrolling | 59.8 fps | 59.9 fps | 59.8 fps |
| Commit interval p50 / p95 / p99 / max | 17.0 / 22.1 / 23.7 / 25.0 ms | 16.7 / 19.7 / 21.2 / 25.6 ms | 16.7 / 18.1 / 19.0 / 27.7 ms |

Cold start to first frame is bounded by the window mapping at about 0.25 s; the app is idle (CPU settled) after about 4.2 s, of which the native splash covers the Dart init. Conversation scrolling was not measured: opening a chat marks it read on the server, which the brief forbids. (One chat reopens by itself at start: GLITCHES.md 14.) Flutter's own timeline needs a `--profile` build and a debug connection: phase 2.

Findings:
- GPU path is the real GPU (Aurora Mesa), not llvmpipe.
- Impeller is worse here (more CPU, about 400-500 MB more RSS): keep Skia.
- Biggest costs, in order: (1) memory growth when scrolling (image decode and cache; 520 to 900-1000 MB), (2) a 60 fps commit cap on a 120 Hz panel with a clean 16.7 ms cadence, (3) 45-55 percent of a core while scrolling a text list, (4) non-zero idle (1-3 percent CPU, 26-35 wakeups per second) with the window visible.
- Quick wins inside Flutter: cap `imageCache` and decode sizes; stop the idle ticker (find it with a profile build); find where vsync is taken; do not enable Impeller. Not yet looked at, from the code: ObjectBox queries on the UI isolate (the app already uses a global isolate), link-preview fetches (client-side), socket polling (ping timers), avatar decoding for the contact list.

## Phase 2: what changed (offline build; device numbers pending)
| Item | Change | State |
|---|---|---|
| Scaling and font | see "Scaling" | seen working on the device once (compare screenshot, diagnostics); numbers pending |
| Emoji | Noto Color Emoji fallback in the theme and the explicit emoji styles (0005) | seen on the device once: color emoji in names and previews where phase 1 showed tofu |
| Window buttons and tiling | titlebar defaults to hidden (0002): no Flutter-drawn buttons over the header; tiling was not the app: Omarchy has per-workspace floating/tiling modes (`workspace-modes.lua`); on workspace 9 the window tiled | seen once |
| Memory while scrolling | decoded-image cache 100 MB/1000 to 48 MB/300 (0007), `BB_IMAGE_CACHE_MB` | one run: RSS after a 10 s list scroll 869 MB (phase 1: 890-1002 MB), scroll CPU 32 % (phase 1: 47-58 %); needs the repeated A/B run |
| 60 fps | not a cap: the engine reports `refreshRate=120`, and the GTK frame clock is not used (the engine does not import it). A steady 16.7 ms interval means frames take over 8.3 ms and land on every second vblank. `BB_DIAG` now prints build and raster times per 5 s, which says which thread to fix | diagnosed, not fixed; needs the device run |
| Idle CPU and wakeups | `BB_DIAG` counts frames per 5 s; an idle app that still draws has something animating | measurement ready; no fix without it |
| Startup | `BB_DIAG` marks: dart main, core services, database, themes and contacts, services registered, first frame, splash closed (first usable frame), UI ready. One run: dart main 0.17-0.42 s, first frame 1.38-1.62 s, splash closed 1.41-1.66 s | needs base vs client; no deferral was changed blind |
| Slim profile | `BB_SLIM` (0009), Omarchy theme (0008), start on the chat list (0006) | built, unit-tested where pure; screens not yet looked at on the device |

Open risk to check first on the device: in the one-run check before it was withdrawn, "CPU settled" took 8-12 s against 4.2 s for the phase 1 builds. Phase 1 numbers came right after a reboot with a different database state, so it may be sync work, but the "base" build (upstream plus diagnostics only) in the device run answers it directly.

## Device run (one command, later)
The device is not used by the build. When the owner allows it, on the Studio:
```
cd /Users/rolo/Documents/GitHub/m5pro/m5pro-linux/contrib/omarchy-mac/bluebubbles-client
./build.sh && ./build.sh diag-base     # ours (slim, the default branch) and upstream plus diagnostics only
./tools/device-run.sh --runs 3         # add --conversation FX,FY to scroll one chat with no unread messages
```
`device-run.sh` closes a running BlueBubbles, installs the two builds as side copies (`~/.local/opt/bluebubbles-m5pro-bench-*`, the default install and the wrapper are untouched), measures upstream, base and client (N full runs plus one Wayland-traced run each: cold start marks, idle CPU/wakeups/frames, RSS, list scroll CPU/RSS/frame build+raster times/commit intervals, optional conversation scroll), takes the GTK size comparison screenshot, starts the app again, and writes `results/<stamp>/summary.md` (medians) plus screenshots in `/Volumes/m5pro/bench/bluebubbles/shots/`. It never types, reacts, sends or marks anything; nothing is deleted. To make the new build the default afterwards: `./install.sh "$(ls -t /Volumes/m5pro/bluebubbles/out/bluebubbles-linux-aarch64-m5pro-client-*.tar.gz | head -1)"`.

## Offline checks done
`flutter analyze` (no errors), `flutter test` (7 tests: scale math, colors.toml parser, palette application), release builds of `m5pro/client` (slim) and `diag-base`, run in the `bb-build` container. The Python harness (`tools/bb-measure.py`, `bb-summary.py`) was syntax-checked, and the frame-commit parser and summary table were exercised on recorded and synthetic data.

## Glitches
See `GLITCHES.md`: 15 entries with reproduction, fix and effort, plus what was checked and what was not covered.

## Plans
- `SLIM-PROFILE.md`: which options to hide or default differently, as a build-time (`BB_SLIM`) and config-time preset; proposal for approval, nothing implemented.
- `REWRITE.md`: decision memo on a Rust client with the API inventory (`api-inventory.md`); recommendation: stay on Flutter now, decide again after phase 2.

## How it would ship in omarchy-mac-pkgs and Aurora (plan)
Read-only look at `omacom/omarchy-mac-pkgs` and `omacom/omarchy-pkgs` (no PRs, issues or comments anywhere): `omarchy-mac-pkgs` holds one directory per Mac-only package (`omarchy-mac`, `omarchy-mac-boot`) with an `install DESTDIR`, `test/all`, README, LICENSE and a version, tests that stage into a temp root; recipes (PKGBUILDs, aarch64, pinned to an exact commit with sha256) live in `omacom/omarchy-pkgs/pkgbuilds/<name>/` and are published to pkgs.omarchy.org on `edge` first; `release/owners.json` needs a line for a new `pkgname`; a PR touching only `pkgbuilds/` merges and publishes itself when green (open as draft to keep control). CONTRIBUTING says a Mac-only package comes after an issue, and a change that is not Apple-specific belongs upstream in omacom/omarchy.

Shape:
1. Not Apple-specific, so the app itself is not an `omarchy-mac` change. Proposed package `omarchy-bluebubbles` (optional, not in the default list): `pkgbuilds/omarchy-bluebubbles/PKGBUILD`, `arch=('aarch64' 'x86_64')`, `source=("bluebubbles-app::git+https://github.com/BlueBubblesApp/bluebubbles-app.git#tag=v2.1.6+desktop.96" "m5pro.patch series...")` with `sha256sums`, `makedepends` as in upstream CI (clang cmake ninja pkg-config gtk3 webkit2gtk-4.1 mpv libayatana-appindicator libnotify json-glib, plus a Flutter SDK pinned to 3.47.8 fetched in `prepare()` from the flutter git tag, no keyserver or network at build beyond that, as the omarchy-pkgs rules require), `build()` = the same `flutter build linux --release` with `BB_SLIM` on, `package()` installing to `/usr/lib/bluebubbles`, a `/usr/bin/bluebubbles` wrapper, a `.desktop` named Messages and the icon. The Flutter download in `prepare()` is the sticking point for the package builders (network, size); the alternative is to ship the tarball built by CI as a `-bin` package like `amp-desktop-bin` in `pkgbuilds/`.
2. Optional install entry: Omarchy has app install hooks and its own install menu in omacom/omarchy; the entry is an `omarchy-install-*` style command that runs `pacman -S omarchy-bluebubbles` and applies the config below, proposed upstream in omacom/omarchy (we do not touch it here).
3. Theme hook: a script in `~/.config/omarchy/hooks/theme-set.d/` that writes the Omarchy palette to `~/.config/bluebubbles/omarchy-colors.json` and signals the app (SLIM-PROFILE.md C1); shipped by the package under `/usr/share/omarchy-platform/` or installed per user by the setup hook.
4. Mac-specific bits (the J716s tuning, Aurora Mesa environment, the 120 Hz and scale notes) belong in `omarchy-mac` only if they are Apple-specific; for Aurora (aurora-silicon) the package list or recipe lives with their repos: same recipe, no Apple strings (their AGENTS.md rules: no Apple strings, no model gates, limits from the machine).
5. Tests per the package contract: a `test/all` that stages `install DESTDIR` into a temp root and checks the wrapper, desktop file and hook; the patch series applies cleanly to the pinned tag (CI-enforceable).
6. Attribution: human sign-off only; no AI attribution in anything sent to omacom or aurora-silicon.
Order of work: finish phase 2 patches, make the slim profile switch, then open an issue (owner's call) before any PR.

## Open questions for the owner
1. Is the automatic scale right (body text equal to GTK UI text, 12 px)? Chat text is then 12.9 px; the Interface Scale and Font Size controls change it.
2. Are the Private API sending defaults (typing indicators, auto mark-read, edit on Up) wanted? They are not seeded: they act on the server and contacts, so they stay off until you turn them on.
3. When may the device run happen (command above), and which chat with no unread messages may it open for the conversation-scroll number?
4. Rust decision: after that run, with the base-versus-client numbers.
