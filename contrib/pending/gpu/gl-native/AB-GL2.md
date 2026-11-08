# A/B plan for the gl2 tree (native Gallium GL, patches 0001-0008) on the MacBook

Tree: `/opt/mesa-aurora-gl2`, Mesa `d57b6f22c06` (branch `g17s-gallium-native-v2`: the 5-patch series plus `app-fixes/0006`-`0008`).
Side by side with `/opt/mesa-aurora-gl` (043a4c58080, 5 patches) and `/opt/mesa-aurora` (zink). The session stays on zink for the whole plan; nothing below edits `/etc/mesa-aurora/session.env`.

## 0. Install and headless check (root)

From the Studio (copies the tarball, checks SHA-256, unpacks to `/opt/mesa-aurora-gl2`, verifies files; no session change):

```
~/Work/agents/gpu-gl-native/scripts/install-gl2.sh root@100.99.249.67
```

Then on the MacBook as root, the existing headless suite against the new tree (12-scene smoke, probe, offscreen, gbm-scanout, gpubench). Expect no `STEP FAIL`:

```
scp ~/Work/agents/gpu-gl-native/scripts/gl-native-ab.sh root@100.99.249.67:/root/   # same script as before
NEW=/opt/mesa-aurora-gl2 bash /root/gl-native-ab.sh native 2>&1 | grep -E '^STEP|summary|native tree'
```

## 1. Per-process setup (user `rolo`, inside the Hyprland session or over ssh)

The session environment (`session.env`) exports `MESA_LOADER_DRIVER_OVERRIDE=zink` and `LD_LIBRARY_PATH=/opt/mesa-aurora/lib` to every client. The helper below sources `session-gl2.env` for one process only and unsets the zink override. Nothing global changes.

```
mkdir -p ~/ab-gl2 && cd ~/ab-gl2
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export WAYLAND_DISPLAY=$(ls $XDG_RUNTIME_DIR | grep -m1 '^wayland-[0-9]$')
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $XDG_RUNTIME_DIR/hypr | head -1)
T0=$(date '+%F %T'); echo "$T0" > t0.txt

# gl2 CMD...   traced run: refusal reasons on, shader cache off (every shader compiles, so every refusal is reported)
gl2() { ( set -a; . /usr/local/share/mesa-aurora/session-gl2.env; set +a
          unset MESA_LOADER_DRIVER_OVERRIDE LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER
          export MESA_DEBUG=1 ASAHI_MESA_DEBUG=faulttrace MESA_SHADER_CACHE_DISABLE=true
          exec "$@" ) ; }
# gl2q CMD...  clean run (scores): no trace; driver refusals are still printed, they are not gated
gl2q() { ( set -a; . /usr/local/share/mesa-aurora/session-gl2.env; set +a
           unset MESA_LOADER_DRIVER_OVERRIDE LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER
           exec "$@" ) ; }
# zink CMD...  baseline: the session's own environment
zinkq() { ( set -a; . /etc/mesa-aurora/session.env; set +a; exec "$@" ) ; }

# faulttrace also prints one M5_* line group per submit (M5_CLEAR, M5_TILE*, M5_RENDER, M5_EOT_PBE, M5_READBACK*).
# That is normal trace output, not a refusal. Drop it at the pipe so logs stay small; REJECT lines are kept.
quiet() { grep --line-buffered -vE '^M5_(CLEAR|TILE|TILE_RANGE|TILE_IOTO|RENDER|EOT_PBE|READBACK|READBACK_RAW|READBACK_DETILED|PROGRAM_DESC|TEXTURE|BLIT|LAYOUT_PASS)[ =]'; }
# one screenshot of the output, and of one window by title
shot()  { grim "$1.png"; }
wshot() { grim -g "$(hyprctl clients -j | jq -r --arg t "$2" '.[]|select(.title==$t)|"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"' | head -1)" "$1.png"; }
```

Preflight (must name the native driver, not zink, and Borealis from the gl2 tree):

```
gl2q eglinfo -B -p wayland 2>&1 | grep -E 'renderer|OpenGL (core )?profile version|OpenGL ES profile version'
gl2q eglinfo -B -p surfaceless 2>&1 | grep -E 'renderer'
gl2q vulkaninfo --summary 2>&1 | grep -E 'deviceName|driverName|driverInfo'
```

Pass: `renderer: Apple M5 Pro (G17S B1)` without `zink`, GL 4.6 core, `Mesa 26.3.0-devel (git-d57b6f22c0)`.

## 2. The set

Each run writes `<app>.log` (stdout+stderr, trace noise dropped) and a screenshot. Run them one at a time.

### 2.1 Alacritty (the black-window regression, patch 0006)

```
gl2 alacritty --title ab-gl2-alacritty -e sh -c '
  ls --color=always -la /opt /usr/lib | head -30
  echo "The quick brown fox jumps over the lazy dog 0123456789 {}[]<>()"
  printf "\e[4:3mundercurl\e[0m \e[4:4mdotted\e[0m \e[4:5mdashed\e[0m \e[7mreverse\e[0m \e[1;31mbold red\e[0m\n"
  sleep 30' 2>&1 | quiet > alacritty.log &
sleep 8; wshot alacritty ab-gl2-alacritty; wait
magick identify -format 'alacritty unique colours: %k\n' alacritty.png   # a black or flat window is 1-3
```

Look at `alacritty.png` (or the window): text, colours, undercurl/dotted/dashed lines visible.

### 2.2 foot (control: foot draws through `wl_shm`, not GL)

```
gl2q foot -T ab-gl2-foot sh -c 'ls --color=always -la /opt /usr/lib | head -30; sleep 25' > foot.log 2>&1 &
sleep 6; wshot foot ab-gl2-foot; echo "libEGL mapped in foot: $(grep -c libEGL /proc/$(pgrep -n -x foot)/maps)"; wait
```

Expected: 0 `libEGL` mappings, empty log, text visible. If foot ever maps libEGL, re-run it through `gl2` with the REFUSE grep below.

### 2.3 glmark2-es2-wayland, full default run (shader permutations, patch 0007)

Three runs. The traced run finds refusals (score thrown away: trace adds work per submit); the clean run gives the score; zink is the baseline. Each takes about 6 minutes. Leave the window alone while it runs.

```
gl2   timeout 1800 glmark2-es2-wayland 2>&1 | quiet > glmark2-traced.log
gl2q  timeout 1800 glmark2-es2-wayland 2>&1 | tee glmark2-gl2.log | grep -E 'GL_RENDERER|GL_VERSION|glmark2 Score'
zinkq timeout 1800 glmark2-es2-wayland 2>&1 | tee glmark2-zink.log | grep -E 'GL_RENDERER|GL_VERSION|glmark2 Score'
```

Every scene line must carry an `FPS:` value. A scene that printed nothing or an error line was not rendered:

```
grep -cE 'FPS: [0-9]+' glmark2-gl2.log glmark2-zink.log      # same count on both (zink is the reference)
grep -E '^\[.*(FPS|error|unsupported|failed)' glmark2-gl2.log | grep -vE 'FPS: [0-9]+' || echo "all scenes produced FPS"
```

### 2.4 vkcube (Borealis from the gl2 tree)

```
gl2q timeout 60 vkcube-wayland --c 900 > vkcube.log 2>&1 &
sleep 6; shot vkcube; wait
grep -E 'Selected GPU|deviceName|Apple' vkcube.log
```

(`vkcube-wayland` from vulkan-tools; if only `vkcube` exists it needs XWayland: add `--c 900` the same way.) Pass: GPU is the M5 Pro, window shows the rotating cube, exit 0 after the frame count.

### 2.5 GTK4 (GL renderer, GtkGLArea)

```
# GSK_RENDERER=ngl forces the GL renderer; GSK_DEBUG=renderer / GDK_DEBUG=opengl print which one and the GL strings
gl2 env GSK_RENDERER=ngl GSK_DEBUG=renderer GDK_DEBUG=opengl timeout 40 gtk4-widget-factory 2>&1 | quiet > gtk4-factory.log &
sleep 10; shot gtk4-factory; wait
gl2 env GSK_RENDERER=ngl GSK_DEBUG=renderer GDK_DEBUG=opengl timeout 40 gtk4-demo --run=glarea 2>&1 | quiet > gtk4-glarea.log &
sleep 10; shot gtk4-glarea; wait
grep -hiE 'renderer|GL_RENDERER|Apple M5' gtk4-factory.log gtk4-glarea.log | sort -u | head
```

If `--run=glarea` is not a demo name in this GTK build, pick a GL one from `gtk4-demo --list`. Pass: the log names the GL (ngl) renderer on `Apple M5 Pro`, not Cairo and not zink; widgets draw normally; the glarea scene renders.

## 3. What to grep

All of this runs after the set. Stage 1 is the pass/fail grep, stage 2 lists everything else for a human to read.

```
cd ~/ab-gl2
# 1. refusals: must print NOTHING (traced logs plus the clean glmark2 log)
REFUSE='M5_[A-Z_]*REJECT|could not build the native|dropping (a render|work)|cannot encode|will be skipped|exceeds the native|no proven native encoding|program is unusable|packer refused|DRM_IOCTL_ASAHI_SUBMIT.*failed|submit failed'
grep -nE "$REFUSE" alacritty.log foot.log glmark2-traced.log glmark2-gl2.log vkcube.log gtk4-factory.log gtk4-glarea.log

# 2. anything else the drivers or Mesa said (read it; one line is expected, see below)
grep -nHiE 'mesa: error|MESA: (error|warning)|GL_INVALID|VK_ERROR|asahi:|borealis|segfault|abort|Gdk-WARNING|Gdk-CRITICAL|Gsk-' \
  alacritty.log foot.log glmark2-traced.log glmark2-gl2.log vkcube.log gtk4-factory.log gtk4-glarea.log |
  grep -vE "GL_INVALID_ENUM in glGetString\(GL_EXTENSIONS\)|Experimental M5 HAL300 integration enabled"
```

Expected, not a failure: `Mesa: error: GL_INVALID_ENUM in glGetString(GL_EXTENSIONS)` from Alacritty (it probes the compatibility call on a core context on purpose and falls back to `glGetStringi`; same on zink) and the informational `Experimental M5 HAL300 integration enabled`.

Kernel and crash side, as root, window starting at `$(cat ~rolo/ab-gl2/t0.txt)`:

```
T0=$(cat /home/rolo/ab-gl2/t0.txt)
dmesg --since "$T0" 2>/dev/null | grep -iE 'aurora|asahi|agx|gpu|fault|timeout|hang|recover|submit failed|oops|BUG' || echo "(no GPU kernel lines)"
coredumpctl --since "$T0" --no-pager 2>&1 | tail -5
journalctl --since "$T0" --no-pager 2>&1 | grep -iE 'crash|segfault|coredump|gpu error' | head
```

(Omarchy's crash notifier fired with no coredumps in the earlier session; if it fires during this plan, `journalctl --user -b` around that time says what triggered it.)

## 4. Criterion to switch the session default back to native

Switch only if every line holds:

1. Stage-1 grep prints nothing for all seven logs, and the stage-2 grep leaves only the two expected lines.
2. No new GPU lines in `dmesg` (no `submit failed`, fault, timeout, hang, recover) and no coredump for any of the apps.
3. Alacritty renders text: the screenshot is legible text, not flat, and `unique colours` is well above 3 (a rendered terminal has dozens).
4. glmark2 on gl2 completes the full default run with an `FPS:` for every scene (same count as zink), prints a `glmark2 Score`, and `glmark2-gl2.log` has no `will be skipped` or `dropping work` lines, so every draw was counted. Record the score next to zink's (`glmark2-zink.log`) in the report; the old native number counted skipped draws, so a lower figure than before is expected. A score far below zink is a performance finding to file, not a refusal.
5. vkcube and both GTK4 runs draw and exit cleanly, with the log naming the M5 Pro and the GL (ngl) renderer; foot draws text.
6. The headless suite from step 0 is clean.

If met, switch (rollback in the second line), then re-run 2.1 and 2.3 once inside the new session:

```
cp -n /etc/mesa-aurora/session.env /etc/mesa-aurora/session.env.zink
cp /usr/local/share/mesa-aurora/session-gl2.env /etc/mesa-aurora/session.env && systemctl restart getty@tty2
# back: cp /etc/mesa-aurora/session.env.zink /etc/mesa-aurora/session.env && systemctl restart getty@tty2
```

If a refusal shows up, keep the session on zink, keep the traced log (the `M5_*REJECT` line names the condition), and replay the app's state on the `g17s-kernel` shim with the repro harness pattern in `APP-REGRESSIONS.md` section 5.

## 5. Offline results already in hand (Studio container, no GPU)

- `meson test --suite asahi`: 67/69 (the two G17P blit failures, `asahi-g17p-gallium-blit` and `-blit-encode`, fail at the base too). `agx_tests`: 520 passed, 1 skipped (`NativeFMA.ExactDyadicOracle`), 0 failed.
- `tests/alacritty-repro.c` (text, 5 variants, 4 rect programs) and `tests/glmark2-build-repro.c` (mediump/highp, build/texture) against `/opt/mesa-aurora-gl2` on the `g17s-kernel` shim with `ASAHI_MESA_DEBUG=faulttrace`: 10/10 and 4/4 submits, `M5 gate ... 0 refused`, no refusal messages. The same harnesses on `/opt/mesa-aurora-gl` still show `could not build the native fragment program`, `dropping a render`, and `refused persp_mul_agx3`.
- The shim reads pixels as zero, so none of this proves correct rendering. That is what sections 2-4 are for.
