# GPU fault stress reproducer (MacBook, J716s)

Status: plan only. Nothing here has been run. See `HYPOTHESES.md` for what each toggle tests.

Goal: measure recoveries per 10 minutes for each configuration, under a fixed mixed load, and with patch 0001
learn what each recovery's reason and client were.

## 0. Prerequisites

- **Kernel.** For reasons and toggles: a daily rebuilt with `0001` and `0002` from this directory, on top of the
  recovery patches in `../recovery/`. Without them, only the rate and the `reported at ... client X` lines can be
  compared.
- **Session.** Run inside the normal Hyprland session, from a terminal on that seat (the clients need
  `WAYLAND_DISPLAY`). The session already exports the `/opt/mesa-aurora` environment
  (`userspace/mesa-aurora/session/session.env`), so zink is the GL driver and Borealis is the Vulkan driver.
- **Keep the compositor up during the test.** Leave quickshell on `QT_QUICK_BACKEND=software` (the current stopgap)
  for every run except H3's, which turns it back on as a trigger.
- **Which loads exist:**

  ```sh
  for t in vkcube glmark2-wayland kitty qml qml6 /usr/lib/qt6/bin/qml; do
    printf '%-24s %s\n' "$t" "$(command -v $t || echo missing)"
  done
  pacman -Q vulkan-tools glmark2 qt6-declarative kitty 2>/dev/null
  ```

  Install whatever is missing: `sudo pacman -S --needed vulkan-tools glmark2 qt6-declarative`. `qt6-declarative`
  provides the `qml` runner at `/usr/lib/qt6/bin/qml`. Its examples are not packaged, so the QML below stands in.

## 1. Load scripts

Save as `~/gpu-stress/` (all plain files; nothing needs root except reading the kernel log).

`~/gpu-stress/anim.qml`: a Qt Quick client that animates continuously, plus one that idles and wakes like a bar.

```qml
import QtQuick
Window {
    width: 640; height: 360; visible: true; title: "qq-stress"
    Rectangle {
        id: r; width: 120; height: 120; radius: 20; color: "tomato"
        NumberAnimation on x { from: 0; to: 520; duration: 1500; loops: Animation.Infinite }
        RotationAnimation on rotation { from: 0; to: 360; duration: 3000; loops: Animation.Infinite }
    }
    Text { anchors.bottom: parent.bottom; font.pixelSize: 28; text: Date.now() }
}
```

`~/gpu-stress/bar.qml`: mostly idle, it redraws one small item every 700 ms (the quickshell pattern).

```qml
import QtQuick
Window {
    width: 600; height: 32; visible: true; title: "qq-bar"
    property int n: 0
    Timer { interval: 700; running: true; repeat: true; onTriggered: n++ }
    Text { anchors.centerIn: parent; font.pixelSize: 18; text: "tick " + n }
}
```

`~/gpu-stress/watch.sh`: counts recoveries and keeps every GPU line of the run.

```sh
#!/bin/sh
# usage: watch.sh <label> <seconds>
L=$1; T=${2:-600}; D=~/gpu-stress/runs/$(date +%H%M%S)-$L; mkdir -p "$D"
uname -r > "$D/kernel"; cat /proc/cmdline > "$D/cmdline"
f=$(find /sys/devices -name idle_off_delay_ms 2>/dev/null | head -1); [ -n "$f" ] && cat "$f" > "$D/idle_off_delay_ms"
sudo dmesg -w > "$D/dmesg" 2>&1 &
W=$!
sleep "$T"
kill $W
grep -c "G17: recovery snapshot" "$D/dmesg" > "$D/recoveries"
grep -E "G17: recovery (snapshot|cause)|G17: recovery gen [0-9]+ queue|commands were in flight|GPU work of a client failed|firmware blamed|GPU MMU fault|event service failed" \
  "$D/dmesg" > "$D/summary"
echo "$L: $(cat "$D/recoveries") recoveries in $T s -> $D"
grep -o "firmware reason [0-9]*" "$D/summary" | sort | uniq -c
grep -o "client [^ ]*\[" "$D/summary" | sort | uniq -c
```

`~/gpu-stress/load.sh`: the fixed mixed load. N vkcube, glmark2, two Qt Quick windows, kitty and one Chromium tab.

```sh
#!/bin/sh
# usage: load.sh <N vkcube> <seconds>
N=${1:-3}; T=${2:-600}; P=
for i in $(seq "$N"); do vkcube --wsi wayland >/dev/null 2>&1 & P="$P $!"; done
glmark2-wayland --run-forever --off-screen=0 >/dev/null 2>&1 & P="$P $!"
QML=$(command -v qml || echo /usr/lib/qt6/bin/qml)
"$QML" ~/gpu-stress/anim.qml >/dev/null 2>&1 & P="$P $!"
"$QML" ~/gpu-stress/bar.qml  >/dev/null 2>&1 & P="$P $!"
kitty -e sh -c 'while :; do ls -lR /usr/share >/dev/null; seq 1 2000; done' >/dev/null 2>&1 & P="$P $!"
chromium --new-window https://webglsamples.org/aquarium/aquarium.html >/dev/null 2>&1 & P="$P $!"
sleep "$T"; kill $P 2>/dev/null
```

Notes:
- If `vkcube --wsi wayland` is not accepted, drop the flag.
- If glmark2 rejects `--run-forever`, use `glmark2-wayland -b build:duration=600`.
- Without a network, replace the WebGL page with `chrome://gpu`. Its idle compositing alone is a GPU client.

One run is:

```sh
chmod +x ~/gpu-stress/*.sh
~/gpu-stress/watch.sh <label> 600 &
~/gpu-stress/load.sh 3 600
wait
```

Leave the machine untouched for the 10 minutes, on AC power with the lid open. Close the Chromium window and the
load windows between runs. If the compositor dies, note the time and reboot, and count the run as "lost device at
T".

## 2. Configurations

Boot parameters go on the kernel command line of the boot entry (the driver is built in, so the prefix is
`aurora.`). Check `/proc/cmdline` after boot; `watch.sh` saves it.

| # | Kernel | Display | Boot parameters | Runtime | Tests |
|---|---|---|---|---|---|
| A | DCP daily + 0001/0002 | DCP 120 Hz VRR | none | none | baseline rate, and the **named reasons** |
| B | same | same | `aurora.m5_pause_timeout_us=2000` | none | H1 |
| C | same | same | `aurora.m5_idle_hold=1` | `echo 1000 >` idle_off_delay_ms | H2, runtime |
| D | same | same | `aurora.m5_idle_standby_us=20000` | none | H2, boot |
| E | simpledrm daily (same patches) | simpledrm | none | none | H6: DCP vs no DCP |
| F | DCP daily | DCP at 60 Hz, `misc:vrr = 0` | none | `hyprctl keyword monitor <out>,3456x2234@60,0x0,1` | H6 |
| G | as A | as A | none | quickshell back on GPU (unset `QT_QUICK_BACKEND`), and `load.sh 0` (no vkcube) | H3: an almost idle zink client |
| H | as A | as A | none | `ASAHI_MESA_DEBUG=sync` exported before `load.sh` | H5: per-client serialization |

Notes:
- **Run C can share A's boot.** Booted with `aurora.m5_idle_hold=1`, the hold stays off while `idle_off_delay_ms` is
  2. Run A first, then `echo 1000`, then run C. With the hold off, the parameter changes nothing, so A and C in
  one boot are a fair pair.
- **Turning C off:** if the GPU stops completing work (vkcube freezes), `echo 2` releases the hold. That J716s case
  is untested (see H2).
- **Without the patches:** A and E still give a rate on today's two dailies (`7.3.0-gbd53915f2ef1` and
  `36845aa5f650`). They give no reasons.
- **Repetition:** do each configuration twice, on different boots where the row needs a boot. A recovery rate of a
  few per 10 minutes needs two runs before a difference means anything.

## 3. The first two runs

1. **A: DCP daily with 0001 + 0002, defaults, the full load, 10 min.**
   - This turns "reason None" into a firmware reason and names the clients.
   - Expected: `firmware reason 5` (DSF pause timeout) on most recoveries, with a mostly idle zink client among the
     named queues.
   - Whatever the reason, it picks the next run:
     - 5: run B;
     - 0/2/4 with no page fault: run C;
     - 3: an MMU fault the registers missed, so collect `detail`;
     - "none recorded": the host-request path, so report it.
2. **B: same kernel, `aurora.m5_pause_timeout_us=2000`, same load, 10 min.**
   - If the recoveries stop or drop sharply, the 150 us bound is the cause. The next questions are which value
     macOS uses (compare against a macOS M5 HW data dump) and whether 2000 costs anything (a pause that long stalls
     scheduling).
   - If reason 5 persists at 2000, try 20000 once. Then move to C/D: the pause itself never completes, so the
     trigger (power kick vs compute context store) is what has to change.

Report for each run: the label, `recoveries`, the reason histogram, the client histogram, and whether the
compositor survived.
