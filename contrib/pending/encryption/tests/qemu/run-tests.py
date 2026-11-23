#!/usr/bin/env python3
"""QEMU test of the LUKS initramfs flow (init.v4 + m5-crypt.sh) on an aarch64 virt machine (HVF), no Apple hardware.
Kernel: Alpine linux-virt (dm-crypt and AF_ALG as modules); the SEP is replaced by the aurora-sep plugin's test build
(kernel user keys). What it proves: the initramfs logic, bounds, fallbacks and the "device untouched" guarantees.
What it cannot prove: dockchannel keyboard, apple_sep, the real SEP unseal, the m1n1/aura boot chain.
usage: run-tests.py QEMUDIR      (QEMUDIR has Image, initramfs-test.cpio.gz; creates vdb.img/vdc.img fresh)"""
import hashlib, os, re, select, subprocess, sys, time

Q = sys.argv[1]
PASS = "qemu-test-passphrase"

def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()

def qemu(append, timeout, sends=(), stop=None):
    """sends: list of (regex, text): when regex appears in the output, write text. stop: regex that ends the run."""
    cmd = ["qemu-system-aarch64", "-M", "virt", "-accel", "hvf", "-cpu", "host", "-m", "1024", "-smp", "2", "-nographic",
           "-kernel", f"{Q}/Image", "-initrd", f"{Q}/initramfs-test.cpio.gz", "-append", "console=ttyAMA0 loglevel=3 " + append,
           "-drive", f"file={Q}/vdb.img,if=none,id=d1,format=raw", "-device", "virtio-blk-pci,drive=d1,serial=qcrypt",
           "-drive", f"file={Q}/vdc.img,if=none,id=d2,format=raw", "-device", "virtio-blk-pci,drive=d2,serial=qplain",
           "-drive", f"file={Q}/vde.img,if=none,id=d3,format=raw", "-device", "virtio-blk-pci,drive=d3,serial=qesp", "-no-reboot"]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = ""; t0 = time.time(); pend = list(sends)
    while time.time() - t0 < timeout and p.poll() is None:
        r, _, _ = select.select([p.stdout], [], [], 0.2)
        if r:
            d = os.read(p.stdout.fileno(), 65536).decode("utf8", "replace")
            if not d: break
            out += d
        for item in list(pend):
            if re.search(item[0], out):
                time.sleep(0.5)
                try: p.stdin.write((item[1] + "\n").encode()); p.stdin.flush()
                except BrokenPipeError: out += "\n<<qemu exited before the host could type>>\n"
                pend.remove(item)
                out += f"\n<<host typed {'*' * len(item[1])}>>\n"
        if stop and re.search(stop, out): break
    p.kill(); p.wait()
    return out

results = []
def check(name, cond, why=""):
    results.append((name, bool(cond))); print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  -> " + why), flush=True)

for f in ("vdb.img", "vdc.img"):
    open(f"{Q}/{f}", "wb").close()
open(f"{Q}/vde.img", "wb").close(); os.truncate(f"{Q}/vde.img", 8 << 20)
os.truncate(f"{Q}/vdb.img", 64 << 20); os.truncate(f"{Q}/vdc.img", 96 << 20)
o = qemu("rdinit=/qemu-guest qt.mode=prep", 120, stop="PREP-DONE")
check("prep: disks built, token enrolled", "PREP-DONE" in o and "PREP-FAIL" not in o and "1 SEP enrolment" in o, o[-600:])
time.sleep(1)
BASE = "qt.mode=boot m5.crypt_kbd_wait=1 "
ROOT = r"QEMU-ROOT-REACHED root=(\S+) canary=(\S+)\r?\n"

# T1: SEP token unlock (user-key stand-in), no prompt, switch_root into the unlocked root
o = qemu(BASE + "rdinit=/qemu-guest m5.root=/dev/qcrypt", 90, stop=ROOT)
m = re.search(ROOT, o)
check("T1 token unlock -> root reached", m and m.group(1) == "/dev/mapper/m5root" and m.group(2) == "m5-crypt-canary-crypt-root" and "unlocked by the Secure Enclave" in o, o[-900:])
check("T1 never prompted", "unlock /dev/qcrypt (1/" not in o)

# T2: SEP off, wrong then right passphrase on the console
o = qemu(BASE + "rdinit=/qemu-guest m5.root=/dev/qcrypt m5.crypt_sep=0", 120,
         sends=[(r"\(1/3[^\n]*\n[^\n]*Enter passphrase", "wrong-one"), (r"\(2/3[^\n]*\n[^\n]*Enter passphrase", PASS)], stop=ROOT)
m = re.search(ROOT, o)
check("T2 wrong then right passphrase -> root reached", m and m.group(2) == "m5-crypt-canary-crypt-root" and "passphrase try 1 failed" in o and "unlocked by passphrase" in o, o[-1200:])

# T3: tries exhausted: device untouched, init stays up
h0 = sha(f"{Q}/vdb.img")
o = qemu(BASE + "rdinit=/qemu-guest m5.root=/dev/qcrypt m5.crypt_sep=0 m5.crypt_tries=2", 90,
         sends=[(r"\(1/2[^\n]*\n[^\n]*Enter passphrase", "bad1"), (r"\(2/2[^\n]*\n[^\n]*Enter passphrase", "bad2")], stop=r"LUKS root was not unlocked")
time.sleep(1)
check("T3 two wrong passphrases -> not unlocked, no root", "NOT unlocked after 2 tries" in o and "QEMU-ROOT-REACHED" not in o, o[-900:])
check("T3 LUKS device byte-identical afterwards", sha(f"{Q}/vdb.img") == h0)

# T4: m5.crypt=off leaves the LUKS device alone
o = qemu(BASE + "rdinit=/qemu-guest m5.root=/dev/qcrypt m5.crypt=off", 60, stop=r"did not mount|mount of")
time.sleep(1)
check("T4 m5.crypt=off: no unlock attempt, device untouched", "m5-crypt:" not in o.replace("m5-crypt.sh", "") and sha(f"{Q}/vdb.img") == h0, o[-700:])

# T5: plain ext4 root: unchanged path, no crypt activity
o = qemu(BASE + "rdinit=/qemu-guest m5.root=/dev/qplain", 90, stop=ROOT)
m = re.search(ROOT, o)
check("T5 plain root unaffected", m and m.group(2) == "m5-crypt-canary-plain-root" and "m5-crypt:" not in o, o[-700:])

# T6: selftest mode: SEP token against a scratch LUKS image FILE on the plain root
o = qemu(BASE + "rdinit=/qemu-guest m5.root=/dev/qplain m5.crypt_selftest=scratch.img", 120, stop=r"selftest: RESULT[^\n]*\n(.|\n)*QEMU-ROOT-REACHED|m5-crypt selftest: FAIL")
check("T6 selftest: scratch image unlocked by token, canary read, boot continues",
      "selftest: RESULT PASS" in o and "selftest[token]: canary=m5-crypt-canary-scratch" in o, o[-1200:])

# T7: attended selftest: token phase, then SEP forced off and the passphrase typed on the console
o = qemu(BASE + "rdinit=/qemu-guest m5.root=/dev/qplain m5.crypt_selftest=scratch.img m5.crypt_selftest_prompt=1", 150,
         sends=[(r"\(1/1[^\n]*\n[^\n]*Enter passphrase", PASS)], stop=r"selftest: RESULT[^\n]*\n(.|\n)*QEMU-ROOT-REACHED\S* canary=\S+\r?\n")
check("T7 selftest + prompt phase: token PASS then typed passphrase PASS",
      "selftest[token]: canary=m5-crypt-canary-scratch" in o and "selftest[prompt]: canary=m5-crypt-canary-scratch" in o and "selftest: RESULT PASS" in o, o[-1500:])

# T8: root-in-a-file rehearsal: token unlock of rootfile.img, switch_root into it, plain root at /outer
o = qemu(BASE + "rdinit=/qemu-guest m5.root=/dev/qplain m5.crypt_rootfile=rootfile.img", 90, stop=ROOT)
m = re.search(ROOT, o)
check("T8 root-in-a-file: booted the LUKS file as root", m and m.group(2) == "m5-crypt-canary-rootfile-root" and "root is the LUKS file" in o, o[-1200:])
# T9: root file that cannot be unlocked (token off, wrong passphrase): falls back to the plain root
o = qemu(BASE + "rdinit=/qemu-guest m5.root=/dev/qplain m5.crypt_rootfile=rootfile.img m5.crypt_sep=0 m5.crypt_tries=1", 120,
         sends=[(r"\(1/1[^\n]*\n[^\n]*Enter passphrase", "nope")], stop=ROOT)
m = re.search(ROOT, o)
check("T9 root file not unlocked: plain root boots instead", m and m.group(2) == "m5-crypt-canary-plain-root" and "booting the plain root" in o, o[-1200:])

# T10: key store from the ESP (m5sep/) is preferred over the embedded copy and logged
o = qemu(BASE + "rdinit=/qemu-guest m5.root=/dev/qcrypt m5.esp=/dev/qesp", 90, stop=ROOT)
check("T10 ESP key store copies used (and token unlock still works)", "key store (esp): aurora-sep-keybag.bin" in o and "unlocked by the Secure Enclave" in o, o[-1000:])
o = qemu(BASE + "rdinit=/qemu-guest m5.root=/dev/qcrypt m5.esp=/dev/nonexistent", 90, stop=ROOT)
check("T10b no ESP: embedded/absent copy path does not break the unlock", "unlocked by the Secure Enclave" in o)

bad = [n for n, ok in results if not ok]
print(f"\n{len(results) - len(bad)}/{len(results)} passed")
sys.exit(1 if bad else 0)
