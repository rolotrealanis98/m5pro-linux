# crashlog: readable kernel failures on the J716s (2026-11-07)

Agent report, saved by the coordinator (the agent could not write this file). Nothing was run on the MacBook,
pushed or posted. No IP, MAC or secret is in any file.

Notes first:
- `/Volumes/linux-cs` hit 100% full during the build (another agent was building in `wt-daily-next-out`).
  The agent copied `Image.gz`, `vmlinux`, `System.map`, `.config` into `build/` and deleted its clone out dir
  `wt-crashlog-out`; free space is back to 3.9 GiB. `wt-betizzel-out` (the daily's) was not touched.
- netconsole will NOT deliver panic text over the r8152 adapter: the driver queues frames and sends them from a
  tasklet, which never runs after `panic()`. Lines before the panic get out; pstore carries the panic itself.
  An AX88179 adapter (driver already built in) sends directly and would get panic lines out until its queue fills.
- Whether iBoot keeps the RAM region across a warm reset has not been measured: test step 1 measures it.
  If it does not, the fallback is ramoops in iBoot's `/pram` region, which needs an m1n1 change.

## What was built (all under `~/Work/agents/crashlog/`)

- **Patches** (worktree `/Volumes/linux-cs/wt-crashlog`, branch `j716s-crashlog`, from series tip `c2e1be601fb4`).
  Sparse worktree (DT, configs, dt-bindings); `git sparse-checkout disable` gives the full tree.
  Author/Signed-off-by Rolando Trevino, no AI trailers, checkpatch `--strict` clean.
  - `patches/0001-arm64-dts-apple-j716s-Reserve-a-ramoops-region.patch` (`28a0b33a19d8`)
  - `patches/0002-arm64-configs-j716s-Build-in-ramoops-and-netconsole.patch` (`ef66e11a6739`)
- **DTB:** `build/t6050-j716s-ramoops.dtb`, sha256 `69487dce6415…08927`. Built by `build/mk-dtb.sh` (replays kbuild's
  command with the kernel's dtc); the same command on the unmodified tree reproduces the daily's `594f2a9f…` byte for
  byte, so the only change is the new node.
- **Kernel:** `7.3.0-crashlog-gf080637018df`, `build/Image.gz` sha256 `81fa8006627…e6801a2`; `vmlinux`, `System.map`
  next to it. Built from `wt-betizzel` (`f080637018df`), whose non-DT code equals the series tip. `LOCALVERSION=-crashlog`
  keeps the release string distinct (stale modules will not load). Nearly a full rebuild because `NETPOLL` changes
  `struct net_device`. `ramoops_init`, `ramoops_probe`, `pstore_register_console`, `write_pmsg`, `init_netconsole` are in
  `System.map`.
- **Config:** the old `j716s.config` reproduces the daily `.config` symbol for symbol. Changes: `PSTORE_RAM` m→y,
  `PSTORE_CONSOLE=y`, `PSTORE_PMSG=y`, `NETCONSOLE=y`, `NETCONSOLE_DYNAMIC=y`, `PANIC_TIMEOUT` 0→10; pulled in `NETPOLL`,
  `NET_POLL_CONTROLLER`, `PRINTK_EXECUTION_CTX`, `REED_SOLOMON` m→y. Diff in `build/config.diff`.
- **Root-side files** (`rootfs/`, shellcheck and `sh -n` clean; collector logic tested with stubs on the Studio):
  - `m5-pstore-collect` + `m5-pstore-collect.service` (sysinit, `DefaultDependencies=no`, before `systemd-pstore.service`):
    copies `/sys/fs/pstore/*` to `/boot/r1-logs/pstore-<seq>-<date>-<bootid>/` with `INFO.txt` (release, boot slot,
    pmu-scrpad, cmdline) and the previous boot's journal tail; clears the store; writes a marker for the current boot into
    `/dev/pmsg0`. `touch /boot/r1-logs/.pstore-keep` keeps the records for one boot. Mounts the ESP itself if needed.
    Retention: 10 newest console-only folders, 20 newest with a crash dump.
  - `m5-netconsole-up` + `m5-netconsole.service` (after `network-online.target`), `m5-netconsole.conf`
    (`STUDIO_IP=@STUDIO_IP@` placeholder), `90-m5-netconsole.rules`. The script waits for an Ethernet route to the Studio,
    takes device and source from `ip route get`, looks up the next hop's MAC in the neighbour table (never stored), creates
    the configfs target `studio`; udev re-runs it after a replug.
- **Receiver:** `receiver/netconsole-recv.sh` (stock perl; writes `~/Work/agents/n1-wifi/logs/netconsole-<start>.log`).
  With `brew install socat moreutils`: `socat -u UDP-RECV:6666,reuseaddr STDOUT | ts '%Y-%m-%dT%H:%M:%S' | tee -a …`.
  `nc -kul 6666` only follows the first sender on macOS.
- **Payloads** (`payloads/`, `SHA256SUMS` + recipes):
  - T = `crashlog-t1-20261107-d88d56de.bin` (selftest, `printk.devkmsg=on ignore_loglevel`)
  - P = `daily-20261107-47920097.bin` (same ingredients, `--daily`, no selftest)

## The memory address, and why

`ramoops@10200000000`: 2 MiB at DRAM base + 8 GiB, `no-map`, `mem-type = <1>` (unbuffered), `ecc-size = <16>`.
Layout: `record-size 0x20000` (10 compressed dmesg records), `console-size 0x80000`, `pmsg-size 0x40000`, no ftrace.

- Linux owns that RAM: every boot log (r1-a/b/c, r2b, r3m/n/o) shows RAM `0x100_03b6_c000..0x10b_c89f_8000`, then m1n1's
  guard page and the stage-2 log; only the ADT copy and CMA move, near the bottom. The region is 7.9 GiB above the start
  and 39 GiB below the top; inside RAM on any size from 16 GiB up.
- m1n1 never touches it (stage-2 source `m1n1-r2/tree` `f7555558`): heap grows up from `top_of_kernel_data`; carve-outs
  come from the top; stage-1 chainload copies only into its heap; `dt_set_memory` skips `no-map`; nothing clears RAM.
- No firmware carve-out inside it; 2 MiB aligned; `no-map` keeps it out of the linear map.
- It captures the whole boot: ramoops probes early (postcore initcall) and the pstore console replays the log buffer,
  so `console-ramoops-0` holds the boot from 0.000000 (covers the DAILY-NEXT-T1 kind of hang).
- Survives the A/B stage-1 watchdog reset? Probably (warm reset; XNU's `/pram` relies on DRAM surviving). Unknown whether
  iBoot scrubs DRAM on warm boot. Never survives a cold boot or a boot of a payload without the node (old daily, B2,
  known-good). Unbuffered mapping per XNU's warning; if an SError at ramoops init, try `mem-type = <0>`.

## netconsole

Configured from userspace (adapter up ~3 s in, too late for `netconsole=`), at `network-online`. Target must be the
Studio's LAN address (raw Ethernet frames, not through tailscaled). Test payloads add `printk.devkmsg=on ignore_loglevel`.
Limits: userspace freeze with the kernel alive → everything; oops/WARN → gets out; panic over r8152 → only what was
printed before `panic()`; hard SoC freeze or before network → nothing (pstore covers both).

## Install on the root (once, from the Studio)

Safe on the current daily (without ramoops the store is empty; without netconsole configfs the unit exits 0).

```sh
H=root@LINUX_IP; SSHO=(-i "$HOME/.ssh/mbp" -o IdentitiesOnly=yes); C=~/Work/agents/crashlog/rootfs
scp "${SSHO[@]}" $C/m5-pstore-collect $C/m5-netconsole-up "$H:/usr/local/sbin/"
scp "${SSHO[@]}" $C/m5-pstore-collect.service $C/m5-netconsole.service "$H:/etc/systemd/system/"
scp "${SSHO[@]}" $C/90-m5-netconsole.rules "$H:/etc/udev/rules.d/"
scp "${SSHO[@]}" $C/m5-netconsole.conf "$H:/etc/m5-netconsole.conf"
ssh "${SSHO[@]}" "$H" 'chmod 755 /usr/local/sbin/m5-pstore-collect /usr/local/sbin/m5-netconsole-up &&
  sed -i "s/@STUDIO_IP@/<STUDIO LAN IP>/" /etc/m5-netconsole.conf &&
  systemctl daemon-reload && systemctl enable m5-pstore-collect.service m5-netconsole.service && udevadm control --reload'
```

## mk-daily commands (already run)

```sh
MK=~/Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py; cd ~/Work/agents/crashlog
python3 $MK --out payloads --label crashlog-t1 --battery --kernel build/Image.gz --dtb build/t6050-j716s-ramoops.dtb --extra "printk.devkmsg=on ignore_loglevel"
python3 $MK --out payloads --daily --battery --force --kernel build/Image.gz --dtb build/t6050-j716s-ramoops.dtb --extra "printk.devkmsg=on ignore_loglevel"
python3 $MK --deploy-plan --payload payloads/crashlog-t1-20261107-d88d56de.bin --host root@LINUX_IP
```
For a hang hunt add `initcall_debug` to `--extra`.

## Test plan

0. Deploy T from the daily (prev becomes the current daily, no ramoops node). Check `dmesg | grep -E 'ramoops|pstore'`:
   `OF: reserved mem: 0x0000010200000000..0x00000102001fffff (2048 KiB) nomap non-reusable ramoops@10200000000`,
   `ramoops: using 0x200000@0x10200000000, ecc: 16`, `Registered ramoops as persistent store backend`; `/dev/pmsg0`
   exists; `uname -r` = `7.3.0-crashlog-gf080637018df`; nproc 18; selftest "network OK".
1. Retention through a clean warm reboot (the core unknown):
   `echo "m5-ramoops-probe $(date +%s)" > /dev/pmsg0; echo "<3>m5-ramoops-probe kmsg" > /dev/kmsg; sync; systemctl reboot`
   Pass: newest `/boot/r1-logs/pstore-*/` has `pmsg-ramoops-0` with the probe line and `console-ramoops-0` ends with
   `reboot: Restarting system`. Fail: "store empty" or `found existing invalid buffer` → `/pram` route.
2. netconsole: `systemctl status m5-netconsole` up; `echo "<4>m5 netconsole test" > /dev/kmsg` and
   `echo h > /proc/sysrq-trigger` appear in the Studio log.
3. Deliberate panic: first put P in `boot.bin.prev` (manual exception to the rotation rule; verify sha before mv).
   Trigger on T: `touch /boot/r1-logs/.pstore-keep; sync; echo c > /proc/sysrq-trigger`. Expected: panic, restart after
   10 s, stage-1 boots P as `fallback-after-failure`. Check `/proc/device-tree/chosen/m5pro,boot-slot`,
   `ls -l /sys/fs/pstore/`, `grep -m3 -e 'Kernel panic' -e sysrq /sys/fs/pstore/dmesg-ramoops-0`.
   Pass: `dmesg-ramoops-0` holds `Kernel panic - not syncing: sysrq triggered crash` with backtrace, copy in `/boot/r1-logs/`.
3b. Optional, today's failure path (watchdog reset, no kernel restart): on T, `echo 0 > /proc/sys/kernel/panic;
   echo c > /proc/sysrq-trigger`; watchdog resets after `/sys/class/watchdog/watchdog0/timeout` s. Same checks.
4. Afterwards: promote (boot.bin = P, prev = dcec81ed) or restore. Once a payload with the node is the daily, every
   later deploy rotates a ramoops-capable payload into prev.

## Risk

Both changes are off the boot path (one reserved-memory node; ramoops/netconsole idle until configured; PANIC_TIMEOUT
only acts on a panic). Worst case: region collision or the unbuffered mapping faults → early oops/SError → kernel
restarts after 10 s or stage-1 watchdog resets in 150 s → fallback to prev (the old daily until step 3). Not covered:
a payload that never mounts the root, cold boots, evidence wiped by a node-less payload in between. ESP: ≤ ~45 MiB of
logs. Modules built for the daily will not load on the `-crashlog` kernel (rebuild with
`~/Work/agents/e0-and-modules/build-modules.sh`).

Worktree: `/Volumes/linux-cs/wt-crashlog`.
