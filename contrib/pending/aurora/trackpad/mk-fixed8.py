# Make j716s-typec-fixed8*.dts from a private copy of fixed7 and compile them with Aurora's dtc.
#   python3 -I ~/Work/agents/trackpad-aurora/mk-fixed8.py
# fixed8       (primary)  = fixed7 minus the driverless SMC pcIO node; AFE reset stays on gp1c
#                           (macsmc-low-gpio line 28, active low) on input@8000, as Aurora's J713 does.
# fixed8-ring  (fallback) = fixed8 with "apple,t6041-dockchannel-hid" first: ring transport, as our 7.2 tree.
# fixed8-pcio  (fallback) = fixed7 with the AFE reset on pcIO output 2, active high (Aurora's J716c shape);
#                           needs patches/optional-pcio/0005.
# The DTS files carry per-unit tunables: keep them in this folder, never publish them.
import hashlib, pathlib, subprocess
H = pathlib.Path.home()
SRC = H/"Work/agents/atc-tunables/j716s-typec-fixed7.dts"
FIXED7_DTB = H/"Work/agents/atc-tunables/t6050-j716s-typec-fixed7.dtb"
OUT = H/"Work/agents/trackpad-aurora/dt"
DTC = "/Volumes/linux-cs/wt-aurora/scripts/dtc/dtc"
sha = lambda b: hashlib.sha256(b).hexdigest()
assert sha(FIXED7_DTB.read_bytes()) == "1eb0fcef30554d7f6873c03372466daa837c0d2af7bba8eb138f0d1323347d25"
f7 = SRC.read_text()

def sub(text, old, new):
    assert text.count(old) == 1, f"expected exactly one match for {old!r}"
    return text.replace(old, new)

PCIO_NODE = """
			gpio {
				compatible = "apple,smc-pcio-gpio";
				gpio-controller;
				#gpio-cells = <0x02>;
				apple,output-commands = <0x1a0000 0x00 0xf0000 0x800000 0x11c0000 0x10000>;
				phandle = <0x48>;
			};
"""
AFE = "apple,afe-reset-gpios = <0x51 0x1c 0x01>;"      # &smc_gpio_low 28 GPIO_ACTIVE_LOW
HID = """input@8000 {
				compatible = "apple,dockchannel-hid";"""
assert "<0x48>" not in f7.replace("phandle = <0x48>;", ""), "something references the pcIO node"

fixed8 = sub(f7, PCIO_NODE, "")
fixed8 = sub(fixed8, AFE, AFE)                          # unchanged, asserted present
ring = sub(fixed8, HID, """input@8000 {
				compatible = "apple,t6041-dockchannel-hid", "apple,dockchannel-hid";""")
pcio = sub(f7, AFE, "apple,afe-reset-gpios = <0x48 0x02 0x00>;")  # &smc_pcio 2 GPIO_ACTIVE_HIGH

for name, text in (("j716s-typec-fixed8", fixed8), ("j716s-typec-fixed8-ring", ring),
                   ("j716s-typec-fixed8-pcio", pcio)):
    dts = OUT/f"{name}.dts"; dtb = OUT/f"t6050-{name}.dtb"
    dts.write_text(text)
    r = subprocess.run([DTC, "-q", "-I", "dts", "-O", "dtb", "-o", str(dtb), str(dts)],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    print(f"{sha(dtb.read_bytes())}  {dtb.name}")
