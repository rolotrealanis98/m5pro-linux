# hwmon: what to read after the boot

Patch: `patches/hwmon/0001-arm64-dts-apple-j716s-Enable-the-SMC-sensors.patch` (DT only, DTB
`build/hwmon.dtb`). Optional `0002` is Aurora's `b7891bd5f621` unchanged (a driver change, so a kernel
rebuild; not built here). With 0002 in the kernel the DT can keep `apple,soc-die-keys = "TCMb"` and
gets the `macsmc_soc_die` thermal zone; 0001 deletes that property because without 0002 it makes the probe
fail with `-EINVAL` ("Temperature discovery failed").

## What the DT asks for

| hwmon file | SMC key | Label | Unit |
|---|---|---|---|
| `fan1_input`, `fan1_min`, `fan1_max`, `fan1_target` | F0Ac, F0Mn, F0Mx, F0Tg | Fan 1 | rpm |
| `fan2_*` | F1Ac, F1Mn, F1Mx, F1Tg | Fan 2 | rpm |
| (mode key, no file) | F0md / F1md (ui8, flags 0xd0) | | |
| `power1_input` | PSTR | Total System Power | uW |
| `power2_input` | PDTR | AC Input Power | uW |
| `power3_input` | PMVR | 3.8 V Rail Power | uW |
| `power4_input` | PHPC | Heatpipe Power | uW |
| `in0_input` | VD0R | Charger Input Voltage | mV |
| `in1_input` | SBAV | Battery Voltage | mV |
| `curr1_input` | ID0R | AC Input Current | mA |
| `tempN_input` / `tempN_label` | every readable, non-function `flt ` key starting with T (268 on the J714s dump) | the key itself (`TB0T`, `TCMb`, ...) | m°C |

Channel numbers follow DT order and skip keys the SMC lacks, so read by label, not by number.
Keys whose meaning is known: TCMb SoC hotspot (47.8 °C idle, the die0 comment), TB0T battery, TCHP charge
regulator, TW0P Wi-Fi/BT module, TH0x NAND. The CPU/GPU cluster keys (Tp*, Te*, Tg*) are unverified.
`fan*_target` is 0444 (read-only) unless the kernel runs with `macsmc_hwmon.fan_control=1`.

## After the boot (read-only)

```sh
# 1. the driver probed, and what it skipped
dmesg | grep -iE 'macsmc[-_]hwmon|smc-hwmon'
#    pass: no "Could not parse sensors", no "Temperature discovery failed", no "No valid sensors".
#    "Fan F0Ac: no mode key F0md" or "no minimum key F0Mn" = that key is absent on the J716s:
#    the fan stays, only that attribute goes (patch 0047).

# 2. the device
H=$(grep -l '^macsmc_hwmon$' /sys/class/hwmon/hwmon*/name | xargs dirname); echo $H
ls $H

# 3. fans, power, voltage, current with labels
for f in $H/fan*_input $H/power*_input $H/in*_input $H/curr*_input; do
  b=${f%_input}; printf '%-8s %-24s %s\n' "$(basename $b)" "$(cat ${b}_label 2>/dev/null)" "$(cat $f)"
done
cat $H/fan1_min $H/fan1_max $H/fan1_target $H/fan2_min $H/fan2_max $H/fan2_target

# 4. temperatures: count, and the known keys
ls $H/temp*_input | wc -l
for k in TCMb TB0T TCHP TW0P TH0x; do
  l=$(grep -lx "$k" $H/temp*_label) && echo "$k $(cat ${l%_label}_input)"
done

# 5. the full dump (installed helper, read-only)
/usr/local/bin/m5-temps

# 6. fans follow load (the SMC's own policy): sample idle, then under load
for i in 1 2 3; do cat $H/fan1_input $H/fan2_input $H/power1_input; sleep 2; done
stress-ng --cpu 18 --timeout 60s &  sleep 50; cat $H/fan1_input $H/fan2_input $H/power1_input; wait
```

Expected (J714c on edimoldovan's tree, same SMC firmware family): fans 0 to about 2300-2500 rpm idle,
4500-4900 rpm after a minute on 18 cores; PSTR 50-90 W under that load. On the J714s dump F0Mn/F1Mn are
listed (flt, flags 0x84) but their values did not read: if `fan1_min` returns an error the fan still reports
`fan1_input`.

## F0md/F1md: what is known, and the read-only probe if needed

The J714s dump (T6050, `~/Work/omarchy-m5/docs/research/smc-keys-j714s.json`) has F0md/F1md as `ui8`,
flags 0xd0 (readable, writable, function key) and no F0Md/F1Md, and no `Ftst` unlock key. Aurora's J775D
(T6050) uses the same F0md/F1md. Nothing has to be read before this DT boots: a wrong key only drops
manual control (dmesg line above). If the J716s keys must be confirmed first, read them from the m1n1
proxy (no writes; the script lists every key and reads a fixed set):

```sh
# on the Studio, Mac in m1n1 proxy mode over the tether
cd ~/Work/omarchy-m5            # hv/ next to proxyclient/ in the tether bundle
python3 scripts/probes/smc-proxy-probe.py     # writes smc-keys.json next to the script
python3 - <<'PY'
import json; d = json.load(open("scripts/probes/smc-keys.json"))
k = {x["name"]: x for x in d["keys"]}
for n in "F0Ac F1Ac F0Mn F1Mn F0Mx F1Mx F0Tg F1Tg F0md F1md F0Md F1Md Ftst PSTR PDTR PMVR PHPC VD0R SBAV ID0R TCMb".split():
    print(n, (k[n]["type"], k[n]["size"], hex(k[n]["flags"])) if n in k else "ABSENT")
PY
```

There is no Linux-side read of an SMC key without a driver that names it; do not drive the SMC mailbox
from userspace next to the kernel driver.

## Fan floor (`contrib/pending/platform/userspace`, `m5-fan-floor.service`)

Still not needed by default, and it does not work as written on the Aurora kernel:

- The SMC runs both fans itself (stage 0 with no OS driver; J714c on Linux 0 -> 4532/4881 rpm under load).
  Run step 6 above; install the floor only if the fans stay flat while TCMb climbs past ~95 °C.
- Aurora's macsmc-hwmon reads the mode key before taking a fan manual. If F0md reads 3 ("system", the
  firmware's own policy) it needs an unlock key; the J714s SMC has no `Ftst`, so the write returns
  `-EOPNOTSUPP` and the script's `echo $rpm > fan1_target` fails every interval. Check first:
  `macsmc_hwmon.fan_control=1` on the command line, then `echo 3000 > $H/fan1_target; echo $?; cat $H/fan1_input;
  echo 0 > $H/fan1_target`.
- Its default labels (`P-cluster Tp00 (unverified)|M-cluster Tm00 (unverified)`) match nothing: discovered
  channels are labelled with the bare key. Set `M5_FAN_LABELS="TCMb"` (the one hotspot key known to track
  load) if it is ever enabled.
- `ConditionKernelCommandLine=macsmc_hwmon.fan_control=1` still gates it, and `fan_control` taints the kernel.
