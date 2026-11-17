#!/usr/bin/python3 -I
"""widevine_tool: helper for install.sh. Standard library plus the `openssl` CLI only.

  fetch DESTDIR [--version V]   ask Google's component update service for the linux_arm64 Widevine CDM, download the CRX3,
                                check size, sha256 (from the service's HTTPS answer), the CRX3 publisher signature (key id
                                must be the Widevine component id) and the zip, extract to DESTDIR, print "VERSION=x".
  latest                        print the version the service offers (no download)
  elfcheck LIB                  aarch64 ELF whose PT_LOAD segments are aligned for 16K pages (exit 0 = yes)
  dlopen LIB                    map the library with the system loader (this is the real 16K test)
  inspect LIB                   print machine, LOAD alignments, needed glibc symbol versions

No CDM bytes are stored in this repository: fetch downloads them from Google at install time.
"""
import ctypes, hashlib, io, json, os, re, struct, subprocess, sys, tempfile, urllib.request, zipfile

APPID = "oimompecagnajdejgnnjijobebaeigek"          # Widevine CDM component id (Chrome component updater)
SERVICE = "https://update.googleapis.com/service/update2/json"
PRODVER = "157.0.8103.78"                            # only sent as the "browser version"; any recent value works
MAX_SIZE = 64 * 1024 * 1024
PAGE = 16384


def die(msg, code=1):
    print("widevine_tool: " + msg, file=sys.stderr)
    sys.exit(code)


def query():
    body = {"request": {"@os": "linux", "@updater": "chrome", "acceptformat": "crx3", "arch": "arm64", "dedup": "cr",
                        "hw": {"physmemory": 16}, "os": {"arch": "arm64", "platform": "Linux", "version": ""},
                        "protocol": "3.1", "prodversion": PRODVER, "updaterversion": PRODVER,
                        "app": [{"appid": APPID, "version": "0.0.0.0", "updatecheck": {}}]}}
    req = urllib.request.Request(SERVICE, json.dumps(body).encode(), {"Content-Type": "application/json"})
    raw = urllib.request.urlopen(req, timeout=30).read().decode()
    if raw.startswith(")]}'"):
        raw = raw[raw.index("\n") + 1:]
    app = json.loads(raw)["response"]["app"][0]
    uc = app.get("updatecheck", {})
    if uc.get("status") != "ok":
        die("the update service has no linux_arm64 Widevine for this request: %s" % uc.get("status"))
    pkg = uc["manifest"]["packages"]["package"][0]
    urls = [u["codebase"] for u in uc["urls"]["url"] if u["codebase"].startswith("https://")]
    return uc["manifest"]["version"], urls, pkg


def varint(b, i):
    n = s = 0
    while True:
        c = b[i]; i += 1
        n |= (c & 0x7F) << s; s += 7
        if not c & 0x80:
            return n, i


def fields(b):
    i = 0
    while i < len(b):
        k, i = varint(b, i)
        f, w = k >> 3, k & 7
        if w == 2:
            ln, i = varint(b, i); yield f, b[i:i + ln]; i += ln
        elif w == 0:
            v, i = varint(b, i); yield f, v
        else:
            die("unexpected protobuf wire type in CRX3 header")


def crx_id(pub):
    h = hashlib.sha256(pub).hexdigest()[:32]
    return "".join(chr(ord("a") + int(c, 16)) for c in h)


def verify_crx3(data, want_id):
    if data[:4] != b"Cr24" or struct.unpack("<I", data[4:8])[0] != 3:
        die("not a CRX3 file")
    hl = struct.unpack("<I", data[8:12])[0]
    header, archive = data[12:12 + hl], data[12 + hl:]
    signed = b"".join(v for f, v in fields(header) if f == 10000)
    proofs = [v for f, v in fields(header) if f == 2]
    ok = False
    for p in proofs:
        d = dict(fields(p)); pub, sig = d.get(1), d.get(2)
        if not pub or not sig or crx_id(pub) != want_id:
            continue
        msg = b"CRX3 SignedData\x00" + struct.pack("<I", len(signed)) + signed + archive
        with tempfile.TemporaryDirectory() as t:
            for n, v in (("pub.der", pub), ("sig", sig), ("msg", msg)):
                open(os.path.join(t, n), "wb").write(v)
            subprocess.run(["openssl", "pkey", "-pubin", "-inform", "DER", "-in", t + "/pub.der", "-out", t + "/pub.pem"],
                           check=True, capture_output=True)
            r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", t + "/pub.pem", "-signature", t + "/sig", t + "/msg"],
                               capture_output=True, text=True)
        ok = r.returncode == 0 and "Verified OK" in r.stdout
    if not ok:
        die("CRX3 publisher signature does not verify for extension id " + want_id)
    return archive


def parse_elf(path):
    d = open(path, "rb").read()
    if d[:4] != b"\x7fELF" or d[4] != 2 or d[5] != 1:
        die("%s: not a 64-bit little-endian ELF" % path)
    machine = struct.unpack_from("<H", d, 18)[0]
    phoff, = struct.unpack_from("<Q", d, 0x20)
    phnum, = struct.unpack_from("<H", d, 0x38)
    loads = []
    for i in range(phnum):
        t, fl, off, va, pa, fs, ms, al = struct.unpack_from("<IIQQQQQQ", d, phoff + 56 * i)
        if t == 1:
            loads.append((off, va, al, fl))
    return d, machine, loads


def elfcheck(path, quiet=False):
    d, machine, loads = parse_elf(path)
    bad = []
    if machine != 183:
        bad.append("machine %d is not AArch64 (183)" % machine)
    for off, va, al, fl in loads:
        if al < PAGE or al % PAGE:
            bad.append("PT_LOAD align 0x%x is not a multiple of 16K (needs the Asahi padding fixup)" % al)
        elif (off - va) % al:
            bad.append("PT_LOAD offset 0x%x and vaddr 0x%x differ modulo align 0x%x" % (off, va, al))
        if fl & 3 == 3 and fl & 1:
            bad.append("RWX PT_LOAD segment")
    if not quiet:
        print("  ELF AArch64, %d PT_LOAD, alignments %s" % (len(loads), ",".join(sorted({"0x%x" % a for _, _, a, _ in loads}))))
    for b in bad:
        print("  BAD: " + b)
    return not bad


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__); sys.exit(2)
    if a[0] == "latest":
        print(query()[0])
    elif a[0] == "elfcheck":
        sys.exit(0 if elfcheck(a[1]) else 1)
    elif a[0] == "dlopen":
        if os.environ.get("WIDEVINE_TOOL_SKIP_DLOPEN"):   # test hook for hosts that cannot load an aarch64 Linux ELF
            print("  dlopen skipped"); sys.exit(0)
        try:
            ctypes.CDLL(os.path.abspath(a[1]))
        except OSError as e:
            print("  dlopen FAILED: %s" % e); sys.exit(1)
        print("  dlopen ok (page size %d)" % os.sysconf("SC_PAGE_SIZE"))
    elif a[0] == "inspect":
        d, m, loads = parse_elf(a[1])
        print("machine", m, "loads", [(hex(o), hex(v), hex(al)) for o, v, al, _ in loads])
        print("glibc versions:", sorted(set(re.findall(rb"GLIBC(?:_ABI)?_[A-Z0-9_.]+", d))))
    elif a[0] == "fetch":
        dest = a[1]
        ver, urls, pkg = query()
        if "--version" in a and a[a.index("--version") + 1] != ver:
            die("service offers %s, not the requested %s" % (ver, a[a.index("--version") + 1]))
        data = None
        for u in urls:
            try:
                data = urllib.request.urlopen(u + pkg["name"], timeout=120).read(MAX_SIZE + 1); break
            except Exception as e:
                print("  %s failed: %s" % (u, e), file=sys.stderr)
        if data is None:
            die("download failed from every mirror")
        if len(data) != int(pkg["size"]) or len(data) > MAX_SIZE:
            die("size %d does not match the service's %s" % (len(data), pkg["size"]))
        if hashlib.sha256(data).hexdigest() != pkg["hash_sha256"]:
            die("sha256 mismatch: got %s, service says %s" % (hashlib.sha256(data).hexdigest(), pkg["hash_sha256"]))
        archive = verify_crx3(data, APPID)
        z = zipfile.ZipFile(io.BytesIO(archive))
        man = json.loads(z.read("manifest.json"))
        if man.get("name") != "WidevineCdm" or man.get("version") != ver:
            die("manifest says %s %s, expected WidevineCdm %s" % (man.get("name"), man.get("version"), ver))
        want = {"manifest.json", "LICENSE", "_platform_specific/linux_arm64/libwidevinecdm.so"}
        os.makedirs(dest, exist_ok=True)
        for n in want:
            p = os.path.join(dest, n)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "wb").write(z.read(n))
        os.chmod(os.path.join(dest, "_platform_specific/linux_arm64/libwidevinecdm.so"), 0o755)
        print("  sha256 %s, CRX3 signature ok (id %s)" % (pkg["hash_sha256"], APPID), file=sys.stderr)
        print("VERSION=" + ver)
    else:
        print(__doc__); sys.exit(2)


main()
