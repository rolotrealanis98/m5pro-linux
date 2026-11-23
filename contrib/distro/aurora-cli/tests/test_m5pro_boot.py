#!/usr/bin/env python3
"""Unit tests for m5pro-boot against a fake root and a fake ESP directory. Run: python3 -I -B tests/test_m5pro_boot.py"""
import gzip, hashlib, importlib.machinery, importlib.util, io, json, os, pathlib, struct, sys, tempfile, unittest

HERE = pathlib.Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("m5pro_boot", str(HERE.parent / "m5pro-boot"))
spec = importlib.util.spec_from_loader("m5pro_boot", loader)
mb = importlib.util.module_from_spec(spec)
sys.modules["m5pro_boot"] = mb
loader.exec_module(mb)

KVER = "7.3.0-1-1-ARCH"
CMDLINE = "BOOT_IMAGE=/x earlycon=efifb console=tty0 loglevel=4 nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5 rw"


def fake_loader(tag=b"aura v1.0.0b13-gtest", size=0x10000):
    b = bytearray(size)
    b[0x100:0x100 + len(tag)] = tag
    b[-8:] = b"STACKBOT"
    return bytes(b)


def fake_image(extra=b""):
    b = bytearray(4096)
    b[56:60] = b"ARM\x64"
    v = b"Linux version " + KVER.encode() + b" (test)\0"
    b[100:100 + len(v)] = v
    return bytes(b) + extra


def fake_dtb(compat=b"apple,j716s\0apple,t6050\0"):
    body = compat + b"\0" * 64
    hdr = b"\xd0\x0d\xfe\xed" + struct.pack(">I", 8 + len(body)) + body
    return hdr


def fake_initramfs(extra=b""):
    return gzip.compress(b"07070" + b"0" * 200 + extra, mtime=0)


class Env:
    """A fake root + fake ESP in a temp dir."""

    def __init__(self, slot="primary", cmdline=CMDLINE, running="daily", net=True):
        self.t = tempfile.TemporaryDirectory()
        self.tp = pathlib.Path(self.t.name)
        r = self.root = self.tp / "root"
        self.esp = self.tp / "esp"
        (self.esp / "m1n1").mkdir(parents=True)
        self.state = self.tp / "state"
        (r / "proc/device-tree/chosen").mkdir(parents=True)
        (r / "proc/sys/kernel/random").mkdir(parents=True)
        (r / "proc/device-tree/compatible").write_bytes(b"apple,j716s\0apple,t6050\0apple,arm-platform\0")
        self.set_slot(slot)
        (r / "proc/cmdline").write_text(cmdline + "\n")
        (r / "proc/sys/kernel/random/boot_id").write_text("boot-1\n")
        (r / "proc/stat").write_text("cpu 0\nbtime 1700000000\n")
        m = r / "usr/lib/modules" / KVER
        (m / "dtbs").mkdir(parents=True)
        (m / "vmlinuz").write_bytes(fake_image())
        (m / "pkgbase").write_text("linux-aurora-j716s\n")
        (m / "dtbs/t6050-j716s.dtb").write_bytes(fake_dtb())
        (r / "var/lib/m5pro-boot").mkdir(parents=True)
        (r / "var/lib/m5pro-boot/initramfs-linux-aurora-j716s.img").write_bytes(fake_initramfs())
        (r / "usr/lib/aura-j716s").mkdir(parents=True)
        (r / "usr/lib/aura-j716s/aura-stage2.bin").write_bytes(fake_loader())
        self.out = io.StringIO()
        self.ctx = mb.Ctx(str(r), str(self.esp), str(self.state), out=lambda s="": self.out.write(s + "\n"))
        self.ctx.net_check = lambda: net
        self.ctx.sleep = lambda s: None
        self.ctx.min_free = None
        self.ctx.conf["MIN_FREE_MB"] = "0"
        self.rebooted = []
        self.ctx.reboot = lambda: self.rebooted.append(1)
        self.ctx.run = lambda cmd, **kw: type("R", (), {"returncode": 0, "stdout": "", "stderr": ""})()

    def set_slot(self, slot):
        f = self.root / "proc/device-tree/chosen/m5pro,boot-slot"
        if slot is None:
            f.unlink(missing_ok=True)
        else:
            f.write_bytes(slot.encode() + b"\0")

    def payload(self, tag, selftest=False, kernel_extra=b""):
        """Make a distinct valid payload (as a stage-2 + kernel + dtb + initramfs)."""
        args = "earlycon=efifb rw" + (" m5.selftest=1" if selftest else "")
        return mb.assemble(fake_loader(), args, gzip.compress(fake_image(tag), mtime=0), fake_dtb(), fake_initramfs())

    def put(self, name, blob, old=True):
        f = self.esp / "m1n1" / name
        f.write_bytes(blob)
        if old:   # older than the boot
            os.utime(f, (1699999000, 1699999000))
        return mb.sha(blob)

    def run(self, *argv):
        self.out.seek(0); self.out.truncate()
        rc = mb.main(["--root", str(self.root), "--esp-dir", str(self.esp), "--state-dir", str(self.state), *argv], ctx=self.ctx)
        return rc, self.out.getvalue()

    def esp_sha(self, name):
        f = self.esp / "m1n1" / name
        return mb.file_sha(f) if f.exists() else None

    def close(self):
        self.t.cleanup()


class Base(unittest.TestCase):
    def setUp(self):
        self.e = Env()
        self.addCleanup(self.e.close)


class TestBuild(Base):
    def test_daily_builds_and_reparses(self):
        dest, rec = mb.build(self.e.ctx, daily=True)
        f = mb.payload_facts(dest.read_bytes())
        self.assertFalse(f["selftest"])
        self.assertEqual(f["kernel"], KVER)
        self.assertEqual(f["board"], "j716s")
        self.assertIn("aura v1.0.0b13", f["loader"])
        self.assertNotIn("BOOT_IMAGE", rec["bootargs"])           # inherited from the running cmdline, minus the loader's token
        self.assertIn("m5.root=/dev/nvme0n1p5", rec["bootargs"])
        self.assertTrue((self.e.state / "payloads/SHA256SUMS").read_text().startswith(rec["sha256"]))

    def test_test_payload_carries_selftest_and_needs_label(self):
        with self.assertRaises(mb.Refused):
            mb.build(self.e.ctx)
        dest, rec = mb.build(self.e.ctx, label="t1")
        self.assertTrue(mb.payload_facts(dest.read_bytes())["selftest"])
        self.assertTrue(rec["bootargs"].endswith("m5.selftest=1"))

    def test_running_selftest_token_is_not_inherited(self):
        e = Env(cmdline=CMDLINE + " m5.selftest=1"); self.addCleanup(e.close)
        dest, rec = mb.build(e.ctx, daily=True)
        self.assertNotIn("selftest", rec["bootargs"])

    def test_deterministic(self):
        _, a = mb.build(self.e.ctx, daily=True, date="20261123")
        _, b = mb.build(self.e.ctx, daily=True, date="20261123")
        self.assertEqual(a["sha256"], b["sha256"])

    def test_refuses_wrong_dtb_zstd_multi_member_and_bad_loader(self):
        r = self.e.root
        (r / "usr/lib/modules" / KVER / "dtbs/t6050-j716s.dtb").write_bytes(fake_dtb(b"apple,j714s\0apple,t6050\0"))
        with self.assertRaisesRegex(mb.Refused, "not a j716s"):
            mb.build(self.e.ctx, daily=True)
        (r / "usr/lib/modules" / KVER / "dtbs/t6050-j716s.dtb").write_bytes(fake_dtb())
        ir = r / "var/lib/m5pro-boot/initramfs-linux-aurora-j716s.img"
        ir.write_bytes(b"\x28\xb5\x2f\xfd" + b"\0" * 50)
        with self.assertRaisesRegex(mb.Refused, "zstd"):
            mb.build(self.e.ctx, daily=True)
        ir.write_bytes(fake_initramfs() + fake_initramfs())
        with self.assertRaisesRegex(mb.Refused, "2 gzip members"):
            mb.build(self.e.ctx, daily=True)
        ir.write_bytes(fake_initramfs())
        (r / "usr/lib/aura-j716s/aura-stage2.bin").write_bytes(b"x" * 0x10000)
        with self.assertRaisesRegex(mb.Refused, "STACKBOT"):
            mb.build(self.e.ctx, daily=True)

    def test_kernel_without_t6050_dtb_is_refused(self):
        (self.e.root / "usr/lib/modules" / KVER / "dtbs/t6050-j716s.dtb").unlink()
        with self.assertRaisesRegex(mb.Refused, "not a J716s kernel"):
            mb.build(self.e.ctx, daily=True)

    def test_newest_kernel_is_picked(self):
        m2 = self.e.root / "usr/lib/modules/7.3.10-1-1-ARCH"
        (m2 / "dtbs").mkdir(parents=True)
        (m2 / "vmlinuz").write_bytes(fake_image()); (m2 / "dtbs/t6050-j716s.dtb").write_bytes(fake_dtb())
        self.assertEqual(mb.find_kernel(self.e.ctx).name, "7.3.10-1-1-ARCH")   # 10 sorts above 9, not as text

    def test_parse_rejects_loader_strings_and_trailing(self):
        blob = self.e.payload(b"a")
        self.assertEqual(mb.payload_facts(blob)["board"], "j716s")
        with self.assertRaises(mb.Refused):
            mb.parse_payload(blob + b"junk")      # extra bytes after the initramfs break the single-member rule
        with self.assertRaises(mb.Refused):
            mb.parse_payload(b"\0" * 100)


class TestInstall(Base):
    def setUp(self):
        super().setUp()
        e = self.e
        self.daily = e.payload(b"daily-old")
        self.prev = e.payload(b"prev-old")
        self.sd = e.put("boot.bin", self.daily)
        self.sp = e.put("boot.bin.prev", self.prev)
        self.new_path, self.new = mb.build(e.ctx, daily=True)
        self.sn = self.new["sha256"]

    def test_dry_run_changes_nothing(self):
        before = {n: self.e.esp_sha(n) for n in ("boot.bin", "boot.bin.prev")}
        rc, out = self.e.run("install", "latest")
        self.assertEqual(rc, 0)
        self.assertIn("DRY RUN", out)
        self.assertIn("prev := the running daily", out)
        self.assertEqual(before, {n: self.e.esp_sha(n) for n in before})
        self.assertEqual(sorted(p.name for p in (self.e.esp / "m1n1").iterdir()), ["boot.bin", "boot.bin.prev"])

    def test_apply_rotates_prev_from_running_daily(self):
        rc, out = self.e.run("install", "latest", "--apply")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.e.esp_sha("boot.bin"), self.sn)
        self.assertEqual(self.e.esp_sha("boot.bin.prev"), self.sd)      # the old daily, not the older prev
        self.assertEqual(sorted(p.name for p in (self.e.esp / "m1n1").iterdir()), ["boot.bin", "boot.bin.prev"])   # no transients left

    def test_running_test_keeps_prev(self):
        e = Env(cmdline=CMDLINE + " m5.selftest=1"); self.addCleanup(e.close)
        e.put("boot.bin", self.daily); e.put("boot.bin.prev", self.prev)
        _, rec = mb.build(e.ctx, daily=True)
        rc, out = e.run("install", "latest", "--apply")
        self.assertEqual(rc, 0, out)
        self.assertEqual(e.esp_sha("boot.bin.prev"), mb.sha(self.prev))
        self.assertIn("running payload is a test", out)

    def test_fallback_boot_keeps_prev_and_replaces_bad_boot_bin(self):
        e = Env(slot="fallback-after-failure"); self.addCleanup(e.close)
        e.put("boot.bin", self.daily); e.put("boot.bin.prev", self.prev)     # the running payload is prev
        mb.build(e.ctx, daily=True)
        rc, out = e.run("install", "latest", "--apply")
        self.assertEqual(rc, 0, out)
        self.assertEqual(e.esp_sha("boot.bin.prev"), mb.sha(self.prev))
        self.assertNotEqual(e.esp_sha("boot.bin"), mb.sha(self.daily))
        self.assertIn("prev already is the running payload", out)

    def test_no_network_keeps_prev(self):
        e = Env(net=False); self.addCleanup(e.close)
        e.put("boot.bin", self.daily); e.put("boot.bin.prev", self.prev)
        mb.build(e.ctx, daily=True)
        rc, out = e.run("install", "latest", "--apply")
        self.assertEqual(e.esp_sha("boot.bin.prev"), mb.sha(self.prev))
        self.assertIn("not been seen reaching the network", out)

    def test_boot_bin_changed_since_boot_means_unknown_running_payload(self):
        self.e.put("boot.bin", self.e.payload(b"installed-after-boot"), old=False)   # mtime now > btime
        # slot primary: running file is boot.bin, which changed after boot -> cannot tell -> prev stays
        rc, out = self.e.run("install", "latest", "--apply")
        self.assertEqual(self.e.esp_sha("boot.bin.prev"), self.sp)
        self.assertIn("cannot be told", out)

    def test_recorded_running_payload_beats_the_file(self):
        # install a daily, then reboot-less second install: the record says D is running, so prev must stay D's rotation
        self.e.state.mkdir(parents=True, exist_ok=True)
        (self.e.state / "running.json").write_text(json.dumps({"boot_id": "boot-1", "sha": self.sd, "slot": "primary", "selftest": False, "network_ok": True}))
        self.e.run("install", "latest", "--apply")
        self.assertEqual(self.e.esp_sha("boot.bin.prev"), self.sd)
        _, other = mb.build(self.e.ctx, daily=True, extra="foo=1")
        self.e.put("boot.bin", self.e.payload(b"x"), old=False)   # a not-yet-booted payload sits in boot.bin
        self.e.run("install", other["name"], "--apply")
        self.assertEqual(self.e.esp_sha("boot.bin.prev"), self.sd)   # still the running daily, not the unbooted boot.bin

    def test_stray_payload_and_low_space_refused(self):
        (self.e.esp / "m1n1/boot.bin.r3q").write_bytes(b"x")
        rc, out = self.e.run("install", "latest", "--apply")
        self.assertEqual(rc, 1); self.assertIn("stray payload", out)
        self.assertEqual(self.e.esp_sha("boot.bin"), self.sd)
        (self.e.esp / "m1n1/boot.bin.r3q").unlink()
        self.e.ctx.conf["MIN_FREE_MB"] = str(10 ** 9)
        rc, out = self.e.run("install", "latest", "--apply")
        self.assertEqual(rc, 1); self.assertIn("MB free", out)

    def test_stale_transients_are_removed_on_apply_only(self):
        (self.e.esp / "m1n1/boot.bin.new").write_bytes(b"half")
        (self.e.esp / "m1n1/boot.bin.prev.new").write_bytes(b"half")
        self.e.run("install", "latest")
        self.assertTrue((self.e.esp / "m1n1/boot.bin.new").exists())
        self.e.run("install", "latest", "--apply")
        self.assertFalse((self.e.esp / "m1n1/boot.bin.new").exists())
        self.assertFalse((self.e.esp / "m1n1/boot.bin.prev.new").exists())

    def test_bad_payload_never_touches_the_esp(self):
        bad = self.e.tp / "bad.bin"
        bad.write_bytes(self.new_path.read_bytes()[:-5])     # truncated initramfs
        rc, out = self.e.run("install", str(bad), "--apply")
        self.assertEqual(rc, 1)
        self.assertEqual(self.e.esp_sha("boot.bin"), self.sd)

    def test_copy_corruption_is_caught_before_the_move(self):
        orig = mb.Esp.stage
        def corrupt(self_, tmp, data, want):
            return orig(self_, tmp, data[:-1] + bytes([data[-1] ^ 1]), want)
        mb.Esp.stage = corrupt
        try:
            rc, out = self.e.run("install", "latest", "--apply")
        finally:
            mb.Esp.stage = orig
        self.assertEqual(rc, 1); self.assertIn("reads back wrong", out)
        self.assertEqual(self.e.esp_sha("boot.bin"), self.sd)
        self.assertEqual(self.e.esp_sha("boot.bin.prev"), self.sp)

    def test_mode_rules(self):
        rc, out = self.e.run("install", "latest", "--test")
        self.assertEqual(rc, 1); self.assertIn("no self-revert", out)
        _, t = mb.build(self.e.ctx, label="t1")
        rc, out = self.e.run("install", t["name"], "--daily")
        self.assertEqual(rc, 1); self.assertIn("reverts and reboots every 90 s", out)
        rc, out = self.e.run("install", t["name"], "--apply")      # auto mode = test
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.e.esp_sha("boot.bin"), t["sha256"])

    def test_wrong_board_refused(self):
        other = self.e.tp / "j714s.bin"
        other.write_bytes(mb.assemble(fake_loader(), "rw", gzip.compress(fake_image(), mtime=0), fake_dtb(b"apple,j714s\0apple,t6050\0"), fake_initramfs()))
        rc, out = self.e.run("install", str(other))
        self.assertEqual(rc, 1); self.assertIn("j714s", out)

    def test_same_payload_is_a_noop(self):
        self.e.run("install", "latest", "--apply")
        rc, out = self.e.run("install", "latest", "--apply")
        self.assertIn("nothing to write", out)


class TestRollbackAndStatus(Base):
    def setUp(self):
        super().setUp()
        self.good = self.e.payload(b"good"); self.bad = self.e.payload(b"bad")
        self.e.put("boot.bin", self.bad); self.e.put("boot.bin.prev", self.good)

    def test_rollback_dry_then_apply(self):
        rc, out = self.e.run("rollback")
        self.assertIn("DRY RUN", out); self.assertEqual(self.e.esp_sha("boot.bin"), mb.sha(self.bad))
        rc, out = self.e.run("rollback", "--apply")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.e.esp_sha("boot.bin"), mb.sha(self.good))
        self.assertEqual(self.e.esp_sha("boot.bin.prev"), mb.sha(self.good))     # prev is kept
        saved = list((self.e.state / "failed").glob("boot.bin-*"))
        self.assertEqual(len(saved), 1); self.assertEqual(saved[0].read_bytes(), self.bad)

    def test_rollback_to_missing_slot_and_to_boot(self):
        rc, out = self.e.run("rollback", "--to", "b2")
        self.assertEqual(rc, 1); self.assertIn("does not exist", out)
        rc, out = self.e.run("rollback", "--to", "boot")
        self.assertEqual(rc, 1)

    def test_rollback_warns_about_a_test_prev(self):
        self.e.put("boot.bin.prev", self.e.payload(b"t", selftest=True))
        rc, out = self.e.run("rollback")
        self.assertIn("reboots every 90 s", out)

    def test_status_ok_and_slots(self):
        rc, out = self.e.run("status")
        self.assertEqual(rc, 0, out); self.assertIn("slot:  primary", out.replace("boot slot:  ", "slot:  ")) 
        e2 = Env(slot="fallback-after-failure"); self.addCleanup(e2.close)
        e2.put("boot.bin", self.bad); e2.put("boot.bin.prev", self.good)
        rc, out = e2.run("status")
        self.assertEqual(rc, 1); self.assertIn("previous boot failed", out)
        rc, out = e2.run("status", "--json")
        j = json.loads(out)
        self.assertEqual(j["running_file"], "boot.bin.prev")
        self.assertEqual(j["running_payload"]["sha256"], mb.sha(self.good)[:12])

    def test_status_flags_stray_missing_prev_and_stale_kernel(self):
        (self.e.esp / "m1n1/boot.bin.prev").unlink()
        (self.e.esp / "m1n1/boot.bin.old").write_bytes(b"x")
        m2 = self.e.root / "usr/lib/modules/7.3.9-1-1-ARCH"
        (m2 / "dtbs").mkdir(parents=True); (m2 / "vmlinuz").write_bytes(fake_image()); (m2 / "dtbs/t6050-j716s.dtb").write_bytes(fake_dtb())
        rc, out = self.e.run("status")
        self.assertEqual(rc, 1)
        for s in ("no boot.bin.prev", "stray payload", "newest installed kernel is 7.3.9-1-1-ARCH"):
            self.assertIn(s, out)

    def test_status_without_esp_access_is_graceful(self):
        e = Env(); self.addCleanup(e.close)
        import shutil as sh; sh.rmtree(e.esp / "m1n1")
        rc, out = e.run("status")
        self.assertIn("not readable", out)

    def test_verify_slot_alias(self):
        rc, out = self.e.run("verify", "prev")
        self.assertEqual(rc, 0, out); self.assertIn("OK", out)


class TestServices(Base):
    def setUp(self):
        super().setUp()
        self.e.ctx.conf["SELFTEST_DELAY"] = "0"

    def _env_test_boot(self, net):
        e = Env(cmdline=CMDLINE + " m5.selftest=1", net=net); self.addCleanup(e.close)
        e.ctx.conf["SELFTEST_DELAY"] = "0"
        self.daily = e.payload(b"daily"); self.test = e.payload(b"test", selftest=True)
        e.put("boot.bin", self.test); e.put("boot.bin.prev", self.daily)
        return e

    def test_selftest_ok_keeps_payload_and_records(self):
        e = self._env_test_boot(True)
        self.assertEqual(mb.selftest_watch(e.ctx), 0)
        self.assertEqual(e.esp_sha("boot.bin"), mb.sha(self.test))
        self.assertEqual(json.loads((e.state / "running.json").read_text())["network_ok"], True)
        self.assertEqual(e.rebooted, [])

    def test_selftest_fail_reverts_once_then_stops(self):
        e = self._env_test_boot(False)
        self.assertEqual(mb.selftest_watch(e.ctx), 1)
        self.assertEqual(e.esp_sha("boot.bin"), mb.sha(self.daily))
        self.assertEqual(e.rebooted, [1])
        logs = list((e.state / "failed").glob("selftest-*/REVERTED"))
        self.assertEqual(len(logs), 1)
        # the guard stops a second revert (the loop the policy warns about)
        e.put("boot.bin", self.test)
        self.assertEqual(mb.selftest_watch(e.ctx), 1)
        self.assertEqual(e.esp_sha("boot.bin"), mb.sha(self.test))
        self.assertEqual(e.rebooted, [1])

    def test_selftest_does_nothing_without_the_flag(self):
        self.assertEqual(mb.selftest_watch(self.e.ctx), 0)

    def test_confirm_records_the_running_slot_file(self):
        e = Env(slot="fallback"); self.addCleanup(e.close)
        e.put("boot.bin", e.payload(b"bad")); h = e.put("boot.bin.prev", e.payload(b"good"))
        rec = mb.confirm(e.ctx)
        self.assertEqual(rec["sha"], h); self.assertTrue(rec["network_ok"])

    def test_promote_builds_the_daily_from_the_confirmed_test(self):
        e = Env(cmdline=CMDLINE + " m5.selftest=1"); self.addCleanup(e.close)
        daily = e.payload(b"d"); e.put("boot.bin.prev", daily)
        tpath, trec = mb.build(e.ctx, label="t1")
        e.put("boot.bin", tpath.read_bytes()); e.put("boot.bin.prev", daily)
        rc, out = e.run("promote", "--apply")
        self.assertEqual(rc, 0, out)
        got = mb.payload_facts((e.esp / "m1n1/boot.bin").read_bytes())
        self.assertFalse(got["selftest"])
        self.assertEqual(got["bootargs"] + " m5.selftest=1", trec["bootargs"])     # differs only by the one argument
        self.assertEqual(e.esp_sha("boot.bin.prev"), mb.sha(daily))                # prev stays: the running payload is a test

    def test_promote_refuses_without_network_or_changed_ingredient(self):
        e = Env(cmdline=CMDLINE + " m5.selftest=1", net=False); self.addCleanup(e.close)
        tpath, _ = mb.build(e.ctx, label="t1")
        e.put("boot.bin", tpath.read_bytes()); e.put("boot.bin.prev", e.payload(b"d"))
        rc, out = e.run("promote")
        self.assertEqual(rc, 1); self.assertIn("reaching the network", out)
        e.ctx.net_check = lambda: True
        (e.root / "var/lib/m5pro-boot/initramfs-linux-aurora-j716s.img").write_bytes(fake_initramfs(b"changed"))
        rc, out = e.run("promote")
        self.assertEqual(rc, 1); self.assertIn("changed since the test was built", out)


class TestHook(Base):
    def test_hook_builds_and_prints_a_dry_run_by_default(self):
        self.e.put("boot.bin", self.e.payload(b"d")); self.e.put("boot.bin.prev", self.e.payload(b"p"))
        before = self.e.esp_sha("boot.bin")
        rc, out = self.e.run("hook")
        self.assertEqual(rc, 0)
        self.assertIn("DRY RUN", out); self.assertIn("m5pro-boot install pkg-", out)
        self.assertEqual(self.e.esp_sha("boot.bin"), before)
        self.assertEqual(len(mb.staged(self.e.ctx)), 1)

    def test_hook_auto_install_test_only(self):
        self.e.put("boot.bin", self.e.payload(b"d")); self.e.put("boot.bin.prev", self.e.payload(b"p"))
        self.e.ctx.conf["AUTO_INSTALL"] = "test"
        rc, out = self.e.run("hook")
        f = mb.payload_facts((self.e.esp / "m1n1/boot.bin").read_bytes())
        self.assertTrue(f["selftest"])          # a hook never installs a daily

    def test_hook_failure_never_fails_the_transaction_or_touches_the_esp(self):
        self.e.put("boot.bin", self.e.payload(b"d"))
        (self.e.root / "usr/lib/modules" / KVER / "dtbs/t6050-j716s.dtb").unlink()
        before = self.e.esp_sha("boot.bin")
        rc, out = self.e.run("hook")
        self.assertEqual(rc, 0); self.assertIn("NOT updated", out)
        self.assertEqual(self.e.esp_sha("boot.bin"), before)

    def test_hook_is_a_noop_off_the_mac(self):
        (self.e.root / "proc/device-tree/compatible").write_bytes(b"linux,dummy-virt\0")
        rc, out = self.e.run("hook")
        self.assertEqual((rc, out), (0, ""))


class TestStubChecklist(Base):
    def test_supported_and_unsupported(self):
        d = self.e.root / "proc/device-tree/chosen"
        (d / "firmware-version").write_bytes(b"mBoot-20457.41.2\0"); (d / "system-firmware-version").write_bytes(b"mBoot-20457.60.65.0.1\0")
        rc, out = self.e.run("stub-checklist", "--json")
        j = json.loads(out)
        self.assertTrue(j["facts"]["stub_behind"]); self.assertTrue(j["facts"]["ok_to_refresh"])
        self.assertGreaterEqual(len(j["steps"]), 8)
        (d / "system-firmware-version").write_bytes(b"mBoot-20500.1.2\0")
        rc, out = self.e.run("stub-checklist")
        self.assertIn("NO (firmware not in the supported table", out)

    def test_not_ok_when_booted_from_fallback(self):
        self.e.set_slot("fallback-after-failure")
        d = self.e.root / "proc/device-tree/chosen"
        (d / "system-firmware-version").write_bytes(b"mBoot-20457.60.65.0.1\0")
        rc, out = self.e.run("stub-checklist", "--json")
        self.assertFalse(json.loads(out)["facts"]["ok_to_refresh"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
