#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""mk-daily.py - build the daily and test payloads for the J716s from named ingredients.

Replaces the one-off mk-r3*.py scripts. Stdlib only. It reads its inputs, writes one payload
(and a recipe) into --out, and never touches the machine: --deploy-plan only PRINTS commands.
ESP rules (what stays where, the self-revert contract): ESP-POLICY.md next to this file.

  mk-daily.py --out DIR --daily                       # the daily: no m5.selftest, label "daily"
  mk-daily.py --out DIR --label r3y-foo               # a test payload: m5.selftest=1 (self-revert)
  mk-daily.py --out DIR --label audio-a --dtb audio   # audio DTB (its kernel is picked for you)
  mk-daily.py --out DIR --label p --battery           # drop the macsmc_power blacklist (attended only)
  mk-daily.py --out DIR --label x --extra "foo=1 bar=2"
  mk-daily.py --out DIR --daily --deploy-plan --host root@10.0.0.9   # build, then print the ESP swap
  mk-daily.py --deploy-plan --payload DIR/NAME.bin --host root@10.0.0.9   # plan for a built payload
  mk-daily.py --list                                  # ingredient table with file/hash status

Layout (identical to mk-r3.py, the R3-SERIES recipe):
  m1n1 (0x400000 B) | chosen.bootargs=...\\n | chosen.asahi,show-notch=1\\n | Image.gz | dtb | initramfs
Output: DIR/<label>-<YYYYMMDD>-<shortsha>.bin, one line appended to DIR/SHA256SUMS, and
DIR/<name>.recipe.txt (the recipe that is also printed).
"""
import argparse, datetime, hashlib, os, pathlib, re, shlex, struct, sys, zlib

H = pathlib.Path.home()
SERIES = pathlib.Path("/Volumes/linux-cs/wt-series-out/arch/arm64/boot")
AUDIO = H / "Work/agents/audio-aurora"

# ---- INGREDIENTS: edit here. "sha256": None means unpinned (the file is rebuilt in place).
# A pin that does not match stops the build; if the change is intended, update the pin here.
# dtb "kernel" = the kernel entry that DTB needs (picked by default, mismatch refused without
# --force); dtb "args" = bootargs that go with it.
INGREDIENTS = {
    "m1n1": {   # exactly 0x400000 bytes, plain (no payload appended)
        "default": "pipepark-atc",   # 0020 PIPE park + 0021 ATC tunables from the ADT (STATE.md)
        "pipepark-atc": {"path": H / "Work/agents/pipe-park/build/m1n1-plain-r2-pipepark-atc.bin",
                         "sha256": "28b26ebcf91e11e512ef100aae0b3e66d174ebf8a380c243dea4763ae2459a33"},
    },
    "kernel": {  # Image.gz: ONE gzip member
        "default": "series",
        "series": {"path": SERIES / "Image.gz",   # j716s-series b9cea5ab1b7d (built as 4f630b11270d, same content); SHA256SUMS has 975dab00
                   "sha256": None},
        "audio": {"path": AUDIO / "kbuild/obj/arch/arm64/boot/Image.gz",   # Rust kernel 00e8df6f
                  "sha256": "00e8df6f06a95e7e48577784a75d95be054c0b148ca829a8375cf5ed476f0480"},
    },
    "dtb": {
        "default": "series",
        "series": {"path": SERIES / "dts/apple/t6050-j716s.dtb",
                   "sha256": None, "kernel": "series", "args": []},
        "audio": {"path": AUDIO / "dt/t6050-j716s-audio-notun-edp.dtb",   # mic + jack, speakers off
                  "sha256": "d69345c1d7b0f3c4ce5edd32b254bb6e9985a637b6a8951de49d18feaa2c97f3",
                  "kernel": "audio", "args": []},
        "audio-spk": {"path": AUDIO / "dt/t6050-j716s-audio-spk-notun-edp.dtb",   # + speakers
                      "sha256": "9dce1b4fca95107d64841871c09fa539c9a27797012ab5a9f6a234c425c58772",
                      "kernel": "audio",
                      # first speaker boot: 10 dB under the kernel's -30 dB ceiling (can only lower it)
                      "args": ["snd_soc_macaudio.speaker_max_db=-40"]},
    },
    "initramfs": {  # ONE gzip member (m1n1 keeps only the last); DIAG block + self-revert installer
        "default": "selftest",
        "selftest": {"path": H / "Work/omarchy-m5/build/initramfs-selftest.cpio.gz",
                     "sha256": "1f61a850fb49764126d7a79e9f8adce5508cd6109b302e1441989bb89cd7903b"},
    },
}

BASE = ("earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused "
        "no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5")
BLACKLIST = "initcall_blacklist=macsmc_power_driver_init"   # battery driver: probe hang, attended only
SELFTEST = "m5.selftest=1"
NOTCH = b"chosen.asahi,show-notch=1\n"
M1N1_SIZE = 0x400000
KINDS = ("m1n1", "kernel", "dtb", "initramfs")


def die(msg):
    sys.exit(f"mk-daily: error: {msg}")


def sha(b):
    return hashlib.sha256(b).hexdigest()


# ---------------------------------------------------------------- ingredients
def resolve(kind, arg):
    """-> dict(name, path, sha256 pin|None, extra table fields). arg: table name, a path, or None."""
    table = INGREDIENTS[kind]
    if arg is None:
        arg = table["default"]
    if arg in table and arg != "default":
        e = dict(table[arg]); e["name"] = arg; e["custom"] = False
        return e
    p = pathlib.Path(arg).expanduser()
    if not p.is_file():
        names = ", ".join(k for k in table if k != "default")
        die(f"{kind} '{arg}' is neither a table name ({names}) nor an existing file")
    return {"name": f"custom:{p.name}", "path": p, "sha256": None, "custom": True}


def load(kind, e):
    if not e["path"].is_file():
        die(f"{kind} {e['name']}: {e['path']} does not exist (is /Volumes/linux-cs mounted?)")
    b = e["path"].read_bytes()
    e["bytes"], e["hash"] = b, sha(b)
    if e["sha256"] and e["hash"] != e["sha256"]:
        die(f"{kind} {e['name']} ({e['path']}): sha256 {e['hash']} != pin {e['sha256']}. "
            f"If the file changed on purpose, update its pin in INGREDIENTS.")
    e["pin"] = "pinned" if e["sha256"] else "UNPINNED"


def gzip_members(b, what):
    """Count gzip members; m1n1 keeps only the last one, so anything but exactly one is a bug.
    Returns (members, first member decompressed)."""
    n, first = 0, None
    while b:
        d = zlib.decompressobj(31)
        try:
            out = d.decompress(b)
        except zlib.error as ex:
            die(f"{what}: not valid gzip ({ex})")
        if not d.eof:
            die(f"{what}: truncated gzip member")
        first = out if first is None else first
        n += 1
        b = d.unused_data
    return n, first


def check_inputs(m1n1, kernel, dtb, initramfs):
    if len(m1n1["bytes"]) != M1N1_SIZE:
        die(f"m1n1 {m1n1['path']} is {len(m1n1['bytes']):#x} bytes, expected {M1N1_SIZE:#x} (plain build, no payload)")
    n, raw = gzip_members(kernel["bytes"], "kernel Image.gz")
    if n != 1:
        die(f"kernel Image.gz has {n} gzip members, need exactly 1")
    if raw[56:60] != b"ARM\x64":
        die("kernel Image.gz does not decompress to an arm64 Image (no 'ARM\\x64' at offset 56)")
    n, raw = gzip_members(initramfs["bytes"], "initramfs")
    if n != 1:
        die(f"initramfs has {n} gzip members, need exactly 1 (m1n1 keeps only the last)")
    if raw[:5] != b"07070":
        die("initramfs does not decompress to a cpio newc archive")
    d = dtb["bytes"]
    if len(d) < 40 or d[:4] != b"\xd0\x0d\xfe\xed" or struct.unpack(">I", d[4:8])[0] != len(d):
        die(f"dtb {dtb['path']}: bad magic or totalsize != file size")
    if b"apple,j716s" not in d:
        die(f"dtb {dtb['path']} is not a J716s device tree (no 'apple,j716s' compatible)")


# ---------------------------------------------------------------- bootargs and layout
def bootargs(battery, selftest, dtb_args, extra):
    parts = [BASE]
    if not battery:
        parts.append(BLACKLIST)
    if selftest:
        parts.append(SELFTEST)
    parts += dtb_args
    if extra:
        parts.append(extra.strip())
    s = " ".join(parts)
    if "\n" in s or not s.isascii():
        die("bootargs must be one ASCII line")
    return s


def assemble(m1n1, args, kernel, dtb, initramfs):
    line = f"chosen.bootargs={args}\n".encode()
    return m1n1 + line + NOTCH + kernel + dtb + initramfs, line


def verify_payload(blob, m1n1, line, kernel, dtb, initramfs):
    """Re-parse the finished blob by offsets and compare every part with its source."""
    off, rows = 0, []
    for name, part in (("m1n1", m1n1), ("bootargs", line), ("show-notch", NOTCH),
                       ("Image.gz", kernel), ("dtb", dtb), ("initramfs", initramfs)):
        if blob[off:off + len(part)] != part:
            die(f"layout check failed at {name} (offset {off:#x})")
        rows.append((name, off, len(part)))
        off += len(part)
    if off != len(blob):
        die("layout check failed: trailing bytes")
    return rows


# ---------------------------------------------------------------- recipe
def recipe(name, blob, rows, ing, args, mode, selftest, battery, force_notes):
    L = [f"payload   {name}", f"size      {len(blob)} bytes", f"sha256    {sha(blob)}",
         f"mode      {mode}; m5.selftest {'ON (self-reverts to boot.bin.prev without network in 90 s)' if selftest else 'OFF (no watchdog)'}"
         f"; battery driver {'ENABLED (attended boot only)' if battery else 'gated (initcall_blacklist)'}"]
    for k in KINDS:
        e = ing[k]
        L.append(f"{k:<9} {e['name']} [{e['pin']}]  {e['path']}")
        L.append(f"          sha256 {e['hash']}")
    L.append(f"bootargs  {args}")
    L.append("layout    " + " | ".join(f"{n} @{o:#x}+{s:#x}" for n, o, s in rows))
    L += [f"note      {n}" for n in force_notes]
    return "\n".join(L) + "\n"


# ---------------------------------------------------------------- deploy plan
def deploy_plan(path, name, digest, size, selftest, host):
    mb = -(-size // 1048576)
    need = 2 * mb + 20   # boot.bin.new + boot.bin.prev.new in flight, plus slack
    q = shlex.quote
    revert = ("a failed test reverts itself: if the root mounts but the network is not up 90 s after "
              "network-online, boot.bin.prev is copied over boot.bin and the machine reboots; a payload that never "
              "mounts the root is NOT covered (macOS: r1-deploy.sh restore prev)" if selftest else
              "this payload has NO watchdog (m5.selftest off): if it does not come up, recover from macOS with "
              "r1-deploy.sh restore prev (see ESP-POLICY.md)")
    return f"""\
# ---- deploy plan for {name} (PRINTED ONLY, nothing was run) ----
# Policy: ESP-POLICY.md. {revert}.
HOST={q(host)}            # the running Linux root, over ssh
SSHO=(-i "$HOME/.ssh/mbp" -o IdentitiesOnly=yes)
PAYLOAD={q(str(path))}
SHA={digest}

# 0. preflight on the machine: ESP mounted, room for two copies, at most four payloads at rest,
#    stale transients removed
ssh "${{SSHO[@]}}" "$HOST" 'bash -s' <<'REMOTE'
set -eu
mountpoint -q /boot || mount /dev/nvme0n1p4 /boot
cd /boot/m1n1
rm -f boot.bin.new boot.bin.prev.new
ls -l boot.bin*; sha256sum boot.bin*
free=$(df -Pm /boot | awk 'NR==2{{print $4}}')
[ "$free" -ge {need} ] || {{ echo "ESP has $free MB free, need {need}: prune first (ESP-POLICY.md)"; exit 1; }}
n=$(ls boot.bin* | wc -l)
[ "$n" -le 4 ] || {{ echo "$n payloads on the ESP, at most four: prune first"; exit 1; }}
echo "preflight ok: $free MB free, $n payloads"
REMOTE

# 1. copy to boot.bin.new (boot.bin is untouched until step 2)
scp "${{SSHO[@]}}" "$PAYLOAD" "$HOST:/boot/m1n1/boot.bin.new"

# 2. verify the sha, keep boot.bin.prev = the last known-good, then move into place
ssh "${{SSHO[@]}}" "$HOST" 'bash -s' <<'REMOTE'
set -eu
cd /boot/m1n1
SHA={digest}
sync
got=$(sha256sum boot.bin.new | cut -d' ' -f1)
[ "$got" = "$SHA" ] || {{ echo "boot.bin.new is $got, expected $SHA: boot.bin untouched"; rm -f boot.bin.new; exit 1; }}
echo "boot.bin.new verified"
# boot.bin.prev must be a payload known to reach the network. The running boot.bin is one (you are
# logged in over ssh), unless it is itself a test (m5.selftest=1): then prev stays the older daily.
if grep -q 'm5.selftest=1' /proc/cmdline; then
    echo "running payload is a test (m5.selftest=1): boot.bin.prev stays as is"
elif [ "$(sha256sum boot.bin | cut -d' ' -f1)" = "$SHA" ]; then
    echo "boot.bin already is this payload: boot.bin.prev stays as is"
else
    cur=$(sha256sum boot.bin | cut -d' ' -f1)
    cp boot.bin boot.bin.prev.new && sync
    [ "$(sha256sum boot.bin.prev.new | cut -d' ' -f1)" = "$cur" ] || {{ echo "prev copy mismatch: nothing replaced"; rm -f boot.bin.prev.new boot.bin.new; exit 1; }}
    mv -f boot.bin.prev.new boot.bin.prev
    echo "boot.bin.prev = $cur (the payload running now)"
fi
mv -f boot.bin.new boot.bin
sync
[ "$(sha256sum boot.bin | cut -d' ' -f1)" = "$SHA" ] || {{ echo "boot.bin hash wrong after the move: restore prev by hand"; exit 1; }}
echo "boot.bin = {name}"
ls -l boot.bin*
REMOTE

# 3. reboot into it (after reading the output above)
ssh "${{SSHO[@]}}" "$HOST" 'sync; systemctl reboot'

# 4. after the reboot (test payload: wait about 2 to 3 minutes; the revert, if any, has happened by then)
ssh "${{SSHO[@]}}" "$HOST" 'uname -r; cat /proc/cmdline; sha256sum /boot/m1n1/boot.bin; journalctl -b -t m5-selftest --no-pager; ls -d /boot/r1-logs/selftest-* 2>/dev/null | tail -3'
# a reverted test leaves /boot/r1-logs/selftest-*/ (logs plus a 25 MB boot.bin.failed): copy the logs
# to the Studio, then delete the boot.bin.failed files (ESP-POLICY.md).
"""


# ---------------------------------------------------------------- list
def list_table():
    for kind in KINDS:
        t = INGREDIENTS[kind]
        for name, e in t.items():
            if name == "default":
                continue
            p = e["path"]
            if p.is_file():
                h = sha(p.read_bytes())
                st = ("pin ok" if h == e["sha256"] else "PIN MISMATCH") if e["sha256"] else "unpinned"
                st += f", sha256 {h[:16]}"
            else:
                st = "MISSING"
            extra = (f" needs kernel '{e['kernel']}'" if e.get("kernel") else "")
            print(f"{kind:<9} {name}{'*' if t['default'] == name else '':<1} {p}\n          {st}{extra}")
    print("(* = default)")


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--out", type=pathlib.Path, help="output directory (created if missing)")
    ap.add_argument("--daily", action="store_true", help="the daily payload: label 'daily', m5.selftest OFF")
    ap.add_argument("--label", help="payload label for the file name (required unless --daily)")
    ap.add_argument("--battery", action="store_true",
                    help="omit the macsmc_power blacklist (battery driver on; attended boots only, R3-S)")
    ap.add_argument("--selftest", action=argparse.BooleanOptionalAction, default=None,
                    help="append m5.selftest=1 (self-revert). Default: on for test payloads, off for --daily")
    ap.add_argument("--extra", default="", help='extra bootargs, appended last, e.g. --extra "foo=1"')
    for k in KINDS:
        ap.add_argument(f"--{k}", help=f"{k}: a table name ({', '.join(x for x in INGREDIENTS[k] if x != 'default')}) or a file path")
    ap.add_argument("--date", default=datetime.date.today().strftime("%Y%m%d"), help="YYYYMMDD in the file name (default today)")
    ap.add_argument("--deploy-plan", action="store_true", help="print (never run) the ssh/scp commands for the ESP swap")
    ap.add_argument("--payload", type=pathlib.Path, help="with --deploy-plan: plan for this built payload, no build")
    ap.add_argument("--host", default="root@LINUX_IP", help="ssh target for the plan (default root@LINUX_IP)")
    ap.add_argument("--list", action="store_true", help="show the ingredient table and file/pin status, then exit")
    ap.add_argument("--force", action="store_true", help="allow: kernel/DTB pairing mismatch, --daily with --battery")
    a = ap.parse_args()

    if a.list:
        return list_table()
    if a.payload:
        if not a.deploy_plan:
            die("--payload only makes sense with --deploy-plan")
        if not a.payload.is_file():
            die(f"--payload {a.payload} is not a file")
        b = a.payload.read_bytes()
        st = SELFTEST in b[M1N1_SIZE:M1N1_SIZE + 2048].decode("ascii", "replace")
        return print(deploy_plan(a.payload.resolve(), a.payload.name, sha(b), len(b), st, a.host), end="")

    if not a.out:
        die("--out DIR is required")
    if not a.daily and not a.label:
        die("a test payload needs --label NAME (or use --daily)")
    if not re.fullmatch(r"\d{8}", a.date):
        die("--date is YYYYMMDD")
    label = a.label or "daily"
    if not re.fullmatch(r"[A-Za-z0-9._-]+", label):
        die("label may only hold letters, digits, . _ -")
    if a.daily and a.battery and not a.force:
        die("--daily --battery: the battery driver hung the boot at ~7.8 s (R3-S) and a probe hang is not "
            "self-recoverable. Use a test payload attended, or --force.")
    if SELFTEST.split("=")[0] in a.extra:
        die("use --selftest/--no-selftest, not --extra, for m5.selftest")
    selftest = (not a.daily) if a.selftest is None else a.selftest

    notes = []
    # DTB first: it can name the kernel it needs.
    ing = {"dtb": resolve("dtb", a.dtb)}
    want_k = ing["dtb"].get("kernel")
    ing["kernel"] = resolve("kernel", a.kernel if a.kernel else (want_k if not ing["dtb"]["custom"] else None))
    if want_k and not ing["kernel"]["custom"] and ing["kernel"]["name"] != want_k:
        if not a.force:
            die(f"dtb '{ing['dtb']['name']}' needs kernel '{want_k}', not '{ing['kernel']['name']}' (--force to override)")
        notes.append(f"FORCED kernel/DTB pairing: dtb {ing['dtb']['name']} wants kernel {want_k}")
    ing["m1n1"] = resolve("m1n1", a.m1n1)
    ing["initramfs"] = resolve("initramfs", a.initramfs)
    for k in KINDS:
        load(k, ing[k])
    check_inputs(*(ing[k] for k in KINDS))
    for k in KINDS:
        if ing[k]["pin"] == "UNPINNED":
            notes.append(f"{k} {ing[k]['name']} is unpinned: the sha256 above is the only record of it")
    if a.battery:
        notes.append("battery driver enabled: attended boot only; a probe hang is not self-recoverable")
    if a.daily and selftest:
        notes.append("--daily with m5.selftest=1: without the network (no adapter) this payload reverts and "
                     "reboots after 90 s, every boot (ESP-POLICY.md, 'selftest and the daily')")
    if not a.daily and not selftest:
        notes.append("test payload without m5.selftest: no self-revert, boot.bin.prev is not used automatically")

    args = bootargs(a.battery, selftest, ing["dtb"].get("args", []), a.extra)
    blob, line = assemble(ing["m1n1"]["bytes"], args, ing["kernel"]["bytes"], ing["dtb"]["bytes"], ing["initramfs"]["bytes"])
    rows = verify_payload(blob, ing["m1n1"]["bytes"], line, ing["kernel"]["bytes"], ing["dtb"]["bytes"], ing["initramfs"]["bytes"])
    digest = sha(blob)
    name = f"{label}-{a.date}-{digest[:8]}.bin"
    mode = "daily" if a.daily else "test"

    a.out.mkdir(parents=True, exist_ok=True)
    dest = a.out / name
    if dest.exists() and sha(dest.read_bytes()) != digest:
        die(f"{dest} exists with different content")
    tmp = a.out / (name + ".tmp")
    tmp.write_bytes(blob)
    os.replace(tmp, dest)
    sums = a.out / "SHA256SUMS"
    sline = f"{digest}  {name}"
    have = sums.read_text().splitlines() if sums.exists() else []
    if sline not in have:
        with open(sums, "a") as f:
            f.write(sline + "\n")
    text = recipe(name, blob, rows, ing, args, mode, selftest, a.battery, notes)
    (a.out / (name + ".recipe.txt")).write_text(text)
    print(text, end="")
    print(f"wrote     {dest}\nappended  {sums}: {sline}")
    if a.deploy_plan:
        print()
        print(deploy_plan(dest.resolve(), name, digest, len(blob), selftest, a.host), end="")


if __name__ == "__main__":
    main()
