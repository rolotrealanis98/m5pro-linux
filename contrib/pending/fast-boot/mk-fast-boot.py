#!/usr/bin/env python3
"""Pack the quiet-fast J716s payload: the daily's kernel, DTB and modules, with quiet bootargs and the v4q initramfs.

Same pattern as m5pro-linux-re/tooling/pr-verify/mk-next-test.py (it loads loop-safety/mk-daily.py and replaces its
BASE bootargs). Kernel, DTB and loader are taken from the daily 624bd344 unless overridden. A TEST payload by default:
m5.selftest=1 (no network 90 s after network-online -> logs to the ESP, boot.bin.prev restored, reboot) and
watchdog.open_timeout=300, so it reverts by itself. FASTBOOT_DAILY=1 builds the promoted form (no self-revert).

  FASTBOOT_LABEL=fast-boot-1 python3 -I -B mk-fast-boot.py
  FASTBOOT_LABEL=fast-boot-2 FASTBOOT_M1N1=/Volumes/m5pro/out/aura/fastboot-silent/aura.bin python3 -I -B mk-fast-boot.py
  FASTBOOT_EXTRA=" splash" ...            appended after the daily's extras
  FASTBOOT_VERBOSE=1 ...                  the daily's own verbose bootargs (a control build: same ingredients, old args)

Writes /Volumes/m5pro/bench/pr-verify/<label>-<date>-<sha8>.bin (+ .recipe.txt). Deletes nothing.
"""
import hashlib, importlib.util, os, pathlib, sys
H = pathlib.Path.home()
R = pathlib.Path(os.environ.get("M5", "/Volumes/m5pro")) / "bench/pr-verify"
K = R / os.environ.get("KBUILD", "kbuild-ane2293")
TOOL = H / "Documents/GitHub/m5pro/m5pro-linux-re/tooling/loop-safety/mk-daily.py"
sha = lambda b: hashlib.sha256(b).hexdigest()
LOADER = pathlib.Path(os.environ.get("FASTBOOT_M1N1", "/Volumes/m5pro/out/aura/aura-j716s-camera1-nohostwait.bin"))
IR = pathlib.Path(os.environ.get("FASTBOOT_IR", "/Volumes/m5pro/bench/fast-boot/initramfs-ftab-wdt2-fsck-v4q.cpio.gz"))
img = LOADER.read_bytes()
assert img[-8:] == b"STACKBOT" and len(img) % 0x10000 == 0, f"{LOADER} is not a plain stage 2 image"
sums = {l.split()[1]: l.split()[0] for l in (K/"SHA256SUMS").read_text().splitlines() if l.strip()}
rel = (K/"kernel.release").read_text().strip()
kern, dtb, mods = K/"Image.gz", K/"t6050-j716s-next.dtb", K/f"modules-{rel}.tar.zst"
for f in (kern, dtb, mods):
    assert sha(f.read_bytes()) == sums[f.name], f"{f} does not match SHA256SUMS"
if "ane2293" in str(K):   # the daily 624bd344 = these exact ingredients
    assert sha(kern.read_bytes()) == "bd9dcab2ea19f0c4a2bed813015ab69a3dc9be6f3653113545c8b1dd3e525c90"
    assert sha(dtb.read_bytes()) == "44180962c1972b9f97acc46feaec0790fde4f9e542784bd5bf8d4fabcaca7c10"
spec = importlib.util.spec_from_file_location("mk_daily", TOOL); mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk); mk.M1N1_SIZE = len(img)
if not os.environ.get("FASTBOOT_VERBOSE"):
    # was: earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend ...
    mk.BASE = ("console=tty0 quiet loglevel=3 vt.global_cursor_default=0 pd_ignore_unused clk_ignore_unused "
               "no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5 kvm-arm.wfi_trap_policy=trap")
mk.NOTCH = b"chosen.asahi,show-notch=1\nchosen.m5pro,gpu=1\nchosen.m5,t6050-display=1\n"
# the daily's extras, verbatim from its recipe
extra = ("log_buf_len=16M rcupdate.rcu_cpu_stall_timeout=21 aurora.m5_pause_timeout_us=2000 "
         "aurora.m5_controller_defaults=1 appledrm.fw27_3_edr=1") + os.environ.get("FASTBOOT_EXTRA", "")
common = ["--out", str(R), "--battery", "--m1n1", str(LOADER), "--kernel", str(kern), "--dtb", str(dtb),
          "--initramfs", str(IR), "--extra", extra]
if os.environ.get("FASTBOOT_DAILY"):
    sys.argv = [str(TOOL), "--daily", "--force"] + common            # promoted form: no m5.selftest, no self-revert
else:
    sys.argv = [str(TOOL), "--label", os.environ.get("FASTBOOT_LABEL", "fast-boot-1")] + common
mk.main()
print("release", rel)
