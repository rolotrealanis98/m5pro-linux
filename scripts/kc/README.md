# Kernelcache / SPTM static-analysis helpers

Small capstone scripts used on 2026-10-20 to read the macOS 27.2 (26B5112a) kernelcache and
`sptm.t6050.release` extracted from the M5. They need `~/Work/m1n1/.venv` (capstone installed)
and are run from this directory: `../../../m1n1/.venv/bin/python fn.py <kernelcache> <VA>`.
The kernelcache and SPTM blobs are not in this repo (Apple boot objects); the disassembly excerpts
that mattered are in `docs/re/`.

| Script | What |
|---|---|
| `kcscan.py` | Parses the fileset kernelcache (kexts, sections); the others `exec` its parser. |
| `fn.py` | Disassembles the function enclosing a VA (vtable targets = `bti c` landing pads handled). |
| `funcs.py` | Maps assert/log strings to the function that branches to their cold stubs (names functions). |
| `vt2.py` | Finds a kext's vtables and resolves slot offsets (as used after `ldr x16,[obj]`). |
| `callers.py` | Finds `blraa` sites that load a given vtable slot offset, across all kexts. |
| `xref.py`, `got.py` | Branch xrefs inside a kext; GOT-slot cross-kext callers (chained-fixup decode). |
| `sptmscan.py`, `sptmfn.py` | Same for the plain Mach-O SPTM: string refs, PMGR immediates, disassembly. |
