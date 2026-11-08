# Kernel-side fix for "reboot while the SSD is still busy" (2026-11-08, compile-checked, not run)

Three patches on the daily tree (branch nvme-shutdown on 36845aa5f650; W=1 clean on apple.o and macsmc-reboot.o;
checkpatch --strict clean):
1. `nvme: apple: Flush and wait for SHN on the T6050 final shutdown`: Flush to every namespace before the queues
   freeze; the SHN wait is `clamp(shutdown_timeout, 30, 60)` s on T6050 only (`apple_nvme_hw.shutdown_min_timeout`);
   SHN skipped with a note when CSTS.RDY is clear (live-adoption `nvme-disabled-v1` case); elapsed time logged on every
   post-M4 final shutdown (`shutdown notification completed in N ms`), timeout warns with the old prefix. The platform
   `.shutdown()` runs for reboot, halt and power off; `reboot -f` and sysrq-b bypass it.
2. `power: reset: macsmc-reboot: Wait 2 s for the SMC restart`: after a successful MBSE=`phra` wait 2000 ms (was 100)
   before falling through to the next restart handler, with a `dev_emerg` line when it does.
3. (optional) `nvme: apple: Settle the T6050 storage before the reboot notifiers`: a reboot notifier at priority 100
   (before macsmc-reboot's boot_stage=0 write) that syncs and flushes, logging `storage settled before reboot in N ms`.

Bootarg alternative `nvme_core.shutdown_timeout=30`: honoured (NVME_CORE=y; `clamp(RTD3E, param, 60)`), but only
lengthens the SHN wait; redundant with patch 1.

Risk to check first: a 30-60 s SHN wait runs after userspace stopped petting `/dev/watchdog`; apple_wdt's default
timeout is 30 s. Check `systemctl show -p RuntimeWatchdogUSec -p ShutdownWatchdogUSec` on the MacBook before the loop.

Test (loop, patched test twin): 6 rounds of `dd if=/dev/zero of=/root/burst bs=1M count=70 conv=fsync; systemctl
reboot` within 1 s; expect 6/6 clean (stage marks 0x33/0x34, no fallback, kernel start 26-29 s after the command) and
the logged SHN durations; repeat with 1+2 only to see whether 3 matters; one power-off with a burst to confirm the log.
