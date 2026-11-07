# Checks for the M5 27.2+ GPU firmware-interface PR

These scripts back the claims in `../patches/0001-0013`, the branch `pr/m5-gpu-27.2` stacked on aurora-silicon/linux#1012 (`funkzy/t6050-gpu-on-integration`, b1615e3fca90). None of them needs a kernel build. They read Apple's binaries locally and print only offsets, constants and digests. The `*.out` files are the outputs on the PR head, 34f2f5bb4d03.

Inputs:
- Kernelcache and GPU firmware (`armfw_g17x.im4p`, `armfw1_g17x.im4p`) from Apple's public Mac17,8 IPSWs for 27.0 (26A428) and 27.2 (26B123), and from the 27.3 beta 1 (26C5035r) restore bundle.
- `com.apple.AGXG17X` carved out of each kernelcache. Disassemble it, and the a010 Mach-O of each firmware, with `llvm-objdump -d`.
- A J716s ADT (only for the board and mailbox checks).

| Script | Command | Checks |
|---|---|---|
| `check_layout.py` | `python3 -I check_layout.py <kernel tree> <5th commit of the series>` | 26A428 byte identity of the roots, main configs, private cluster, bundle policy and the HW data of every board; 27.2+ sizes and offsets; 26C5035r HW data = 26B123 kext stores moved by the bands, plus 5000 at 0x2720. Needs rustc. `--compile-only` type-checks an intermediate commit. |
| `rustcheck.py` | `python3 -I rustcheck.py <tree>/drivers/gpu/drm/asahi/g17/fw/m5/initdata.rs <workdir>` | The 26A428 status-config map path writes the same 0x780 bytes as `write_relocated_words()`; prints the 26B123 words. Needs rustc. |
| `verify_policy.py` | `python3 -I verify_policy.py <initdata.rs> <dir>` | Policy bands vs every kext policy store (27.0 -> 27.2/27.3) and GFX1 firmware access; the driver's encoders and relayout, compiled out of the source, vs an independent relocation. `<dir>` holds `store-lists/*` and the GFX1 disassemblies `fw170.dis`, `fw172.dis`, `fw173.dis` (27.0, 27.2, 27.3). |
| `verify_statuscfg.py` | `python3 -I verify_statuscfg.py --kext0 <27.0 kext.dis> --kext2 <27.2 or 27.3 kext.dis> --src <initdata.rs> --base-src <#1012 initdata.rs> --fw0 <27.0 armfw1.dis> --fw2 <27.2 or 27.3 armfw1.dis>` | Every status-config kext store and firmware read maps through the driver's bands; the inserted words are the only new ones. |
| `check_fwid.py` | `FW_ROOT=<dir> python3 -I check_fwid.py <tree>/drivers/gpu/drm/asahi/hw/t6050.rs` | Recomputes every T6050 fwid build pinned in `hw/t6050.rs`: the three G17S builds, plus #1012's G17C and G17D 26A428 pins. |
| `check_board.py`, `check_mailbox.py` | `M1N1_PROXYCLIENT=<m1n1>/proxyclient python3 -I check_board.py <initdata.rs> <adt.bin>` (and `check_mailbox.py <mailbox.c> <adt.bin>`) | J716s perf, SRAM and AFR tables and the native mailbox addresses vs the ADT. |
| `fmtcheck.py` | `python3 -I fmtcheck.py <tree> b1615e3fca90 <head>` | Added Rust lines that rustfmt (the tree's `.rustfmt.toml`) would change. Exits 1 when there are any; there are 13, in code whose surrounding style is not rustfmt-clean either. |

`store-lists/` holds the derived kext policy-store lists (`pol-*.txt`: offset and instruction address) and GFX1 firmware policy-access lists (`fu7*.txt`) for 27.0, 27.2 and 27.3 that `verify_policy.py` reads.
