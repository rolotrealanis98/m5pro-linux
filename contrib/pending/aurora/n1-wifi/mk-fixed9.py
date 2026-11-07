#!/usr/bin/env python3
# Make j716s-typec-fixed9.dts from a private copy of fixed8 and compile it with Aurora's dtc.
#   python3 -I ~/Work/agents/n1-wifi/mk-fixed9.py
# fixed8 already carries the whole J716s N1 description (checked below against the ADT values,
# ANALYSIS.md section d): firmware-name, platform-id 0x000c6050, protocol 27, port0/phy0/intr2axi0
# windows, IRQ 1523, DART 0x410000000 IRQ 1524, iommu-map 0x100 -> SIDs 1-3, PERST# on pinctrl_ap
# pin 80, 64 MSIs at AIC 1888 with apple,msi-vector-base 64, zero MAC placeholders that m1n1
# fills through wifi0/bluetooth0. pci@0,0 and its DART stay disabled; m1n1 0022 enables both
# only when the link is up.
# fixed9 = fixed8 + the five root-port tunable lists on pci@0,0, which pcie-apple replays in the
# root-port reset of the N1's post-ROM port cycle. m1n1 0022 writes the same values from the ADT
# at every boot; having them in the DTB covers an m1n1 that skips the copy.
# Values: J716s ADT /arm-io/apcie0/pci-bridge0, 24-byte records (offset, size, mask, value),
# printed by ~/Work/agents/n1-wifi/tools/adt-n1.py. fixed8 has per-unit tunables elsewhere:
# keep both files in private folders, never publish them.
import hashlib, pathlib, subprocess
H = pathlib.Path.home()
SRC = H/"Work/agents/trackpad-aurora/dt/j716s-typec-fixed8.dts"
OUT = H/"Work/agents/n1-wifi/dt"
DTC = "/Volumes/linux-cs/wt-aurora/scripts/dtc/dtc"
sha = lambda b: hashlib.sha256(b).hexdigest()
assert sha(SRC.read_bytes()) == "999eeacb0759e34be252c00ed81b299cb24d182e4c1ff6cfe7dd308ade4c4c54"
f8 = SRC.read_text()

TUNABLES = {
    "apple,apcie-config-tunables": [(0x140, 4, 0x00000001, 0x00000001), (0x144, 4, 0x00ffffff, 0x00253770), (0x8a8, 4, 0x00000001, 0x00000001), (0x8ac, 4, 0x00000001, 0x00000001)],
    "apple,pcie-rc-tunables": [(0x78, 4, 0x00007000, 0x00000000), (0x194, 4, 0x00000002, 0x00000002), (0xb80, 4, 0x007f3f3f, 0x007f1e1e), (0xb88, 4, 0x007f3f3f, 0x007f1e1e)],
    "apple,pcie-rc-gen3-shadow-tunables": [(0x154, 4, 0x0f0f0f0f, 0x05050505), (0x890, 4, 0x03000000, 0x00000000), (0x8a8, 4, 0x00ffff0f, 0x00000001)],
    "apple,pcie-rc-gen4-shadow-tunables": [(0x178, 4, 0x0000ffff, 0x00005555), (0x890, 4, 0x03000000, 0x01000000), (0x8a8, 4, 0x00ffff0f, 0x00000001)],
    "apple,pcie-rc-gen5-shadow-tunables": [(0x1ac, 4, 0x0000ffff, 0x00005555), (0x890, 4, 0x03000000, 0x02000000), (0x8a8, 4, 0x00ffff0f, 0x00000001)],
}

for must in ('compatible = "apple,t6050-pcie";', 'firmware-name = "apple/centauri/j716s-ftab.bin";',
             "apple,centauri-platform-id = <0xc6050>;", "apple,centauri-protocol = <0x1b>;",
             "reset-gpios = <0x3c 0x50 0x01>;", "iommu-map = <0x100 0x4d 0x01 0x03>;",
             "apple,msi-vector-base = <0x40>;", "msi-ranges = <0x01 0x00 0x00 0x760 0x01 0x40>;",
             'reg-names = "config", "rc", "port0", "phy0", "intr2axi0";',
             "interrupts = <0x00 0x00 0x5f3 0x04>;", "gpio-reserved-ranges = <0x00 0x50 0x51 0x8c>;",
             "local-mac-address = [00 00 00 00 00 00];", "local-bd-address = [00 00 00 00 00 00];"):
    assert f8.count(must) == 1, must

ANCHOR = "\t\t\tapple,link-trained-by-bootloader;\n"
assert f8.count(ANCHOR) == 1
lines = "".join("\t\t\t%s = <%s>;\n" % (name, " ".join("0x%x 0x%x 0x%x 0x%x" % t for t in recs))
                for name, recs in TUNABLES.items())
f9 = f8.replace(ANCHOR, ANCHOR + lines)

dts = OUT/"j716s-typec-fixed9.dts"
dtb = OUT/"t6050-j716s-typec-fixed9.dtb"
OUT.mkdir(parents=True, exist_ok=True)
dts.write_text(f9)
subprocess.run([DTC, "-q", "-I", "dts", "-O", "dtb", "-o", str(dtb), str(dts)], check=True)
print(f"{sha(dts.read_bytes())}  {dts.name}")
print(f"{sha(dtb.read_bytes())}  {dtb.name}")
