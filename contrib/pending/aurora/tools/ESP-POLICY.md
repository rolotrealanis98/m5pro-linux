# ESP policy for the J716s payloads

What goes on the 500 MB ESP (`/dev/nvme0n1p4`; `/boot` in Linux, `/Volumes/OMARCHY` in macOS) and how
`mk-daily.py` (same folder) keeps it in a state you can always boot back from. The tool only builds
payloads and prints the commands for the swap; you run them.

## What lives on the ESP

| Path | Holds | Who writes it |
|---|---|---|
| `m1n1/boot.bin` | the one daily, or the test payload currently under test | the deploy plan, the self-revert |
| `m1n1/boot.bin.prev` | the rollback: the last payload known to reach the network | the deploy plan (step 2), never a test payload |
| `m1n1/boot.bin.b2` | B2, our 7.2 stack (sha256 `55d95928...`), the boot-from-macOS fallback if Aurora's kernel is broken | by hand only |
| `m1n1/boot.bin.known-good` | the pinned last-resort payload (sha256 `a2407e83...`) | by hand only |
| `r1-local.sh` | the on-device R1 collection script (`bash /boot/r1-local.sh d`) | `host/macos/r1-deploy.sh deploy` |
| `r1-logs/` | R1 logs, and `selftest-*/` directories from every failed test (dmesg, journal, links, cmdline, and a 25 MB `boot.bin.failed`) | `r1-local.sh`, the self-revert service |

Transient names that must never survive a deploy: `boot.bin.new` and `boot.bin.prev.new` (the plan removes
stale ones in step 0). Anything else on the ESP (the stub, EFI files) is outside this policy and not touched.
Payload sources and every payload ever built live on the Studio (`~/Work/agents/aurora-kernel/payloads/` with
`SHA256SUMS`), so an ESP file can always be deleted and rebuilt from its recipe.

## Rule: at most four payloads

At rest the ESP holds `boot.bin`, `boot.bin.prev`, `boot.bin.b2`, `boot.bin.known-good`, and nothing else
named `boot.bin*`. No `boot.bin.r3q`-style spares: copy a spare to the Studio, then delete it. Reasons: a payload
is about 25 MB, a deploy needs two more in flight (`.new` and `.prev.new`), and every failed test leaves a
25 MB `boot.bin.failed` under `r1-logs/selftest-*/`; the ESP filled up once on spares (RESULTS.md, R3-R). With
four payloads it is also never ambiguous which file is the rollback. The deploy plan's step 0 refuses to run
with more than four or with less than two payloads' worth of free space. After every self-revert, copy the
log directory to the Studio and delete the `boot.bin.failed` in it.

## Self-revert contract

A payload built with `m5.selftest=1` makes the initramfs (`mk-selftest-initramfs.sh`) install a service into the
root. Ninety seconds after `network-online.target`, it checks for a route and a ping to 1.1.1.1. If either fails it
saves logs to `r1-logs/selftest-*/`, copies `boot.bin.prev` over `boot.bin`, and reboots.

So `boot.bin.prev` must be a payload **known to reach the network**: a revert to a payload that does not is
not a recovery. "Known" means it booted on this machine and you (or the service's "network OK" journal line)
saw the network up. Consequences, all encoded in the deploy plan:

- **prev is rotated only from a running daily.** If the running payload carries `m5.selftest=1` it is a test
  and may not have been confirmed, so prev stays as it is. Iterating tests (T1, then T2, then T3) therefore
  keeps prev on the daily the whole time, and a failing test returns you to the daily.
- **prev should itself not carry `m5.selftest=1`** (see the loop below). A promoted test is rebuilt as `--daily`,
  so the daily and the test it came from differ only in that one argument.
- **The copy is verified before anything moves**: `.new` is checked against the sha256, prev is copied to
  `.prev.new`, checked, then `mv`; `boot.bin` is replaced last.
- **Limit**: the service exists only once the root has mounted. A payload that never mounts the root is not
  reverted: recover from macOS (`host/macos/r1-deploy.sh restore prev`, then `restore b2` or `restore
  known-good` if prev is also bad). Booting macOS once clears the PMU boot-error counter.

## How the selftest flag interacts with the daily

The initramfs always carries the installer; only the kernel command line switches it on. The service the
installer leaves in the root has `ConditionKernelCommandLine=m5.selftest=1`, so on a payload without the flag it
does nothing (the files stay installed but inert).

- **Test payloads (default): `m5.selftest=1` ON.** They self-revert. Boot them only with the network up (the
  USB-Ethernet adapter attached).
- **The daily (`--daily`): OFF.** The daily has to boot where there is no network (no adapter, away from home).
  With the flag on, one network-less boot reverts: the daily is silently replaced by `boot.bin.prev` and the machine
  reboots. If `boot.bin.prev` also carries the flag, the revert copies a payload onto itself and the machine
  reboots every 90 s plus boot time, each pass writing a `selftest-*/` directory with a 25 MB `boot.bin.failed`
  into the ESP, until it is stopped from macOS.
  `--daily --selftest` is allowed but prints a warning for this reason; `--no-selftest` turns the flag off for a
  test payload, which then has no watchdog.
- **Promotion:** a test that reached the network (`journalctl -b -t m5-selftest` shows "network OK") is
  promoted by rebuilding the same ingredients with `--daily` and deploying that. The deploy runs from the test
  boot, so by the rule above prev stays on the old daily; the daily has no watchdog, and its rollback is that
  older, known-good prev.
- **Battery:** `--battery` payloads are attended only (R3-S: the probe hang is not self-recoverable). `--daily
  --battery` is refused without `--force`.
- **Audio:** the audio DTBs need the audio (Rust) kernel; `--dtb audio` picks it, and a mismatch is refused.
  `audio-spk` adds `snd_soc_macaudio.speaker_max_db=-40` for the first speaker boot.
