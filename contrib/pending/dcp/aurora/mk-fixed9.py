# Make j716s-typec-fixed9.dts (private, per-unit: never publish) from fixed8 and compile it.
#   python3 -I ~/Work/agents/dcp-aurora/mk-fixed9.py
# fixed9 = fixed8 + the internal panel's display pipeline for Aurora's apple,t6050-dcp driver,
# every node "disabled": m1n1 0024 enables them (chosen.m5,t6050-display=1) only after checking
# that the DCP runs on locked four-level DART tables at the ADT's roots, and it adds the
# framebuffer memory-region and the firmware version. Values from the J716s runtime ADT:
#   /arm-io/dcp        reg 0x28ae00000+0x88000 (ASC; mailbox at +0x8000), 0x28a850000+0x4000
#                      (iop-vbar); interrupts 1044 1043 1046 1045 ... (mailbox 1043..1046 in
#                      send-empty, send-not-empty, recv-empty, recv-not-empty order, as dcpext0's
#                      1123..1126); clock-ids present and empty; iommu mapper-dcp SID 23
#   /arm-io/disp0      reg 0x288000000+0x4000000, 0x28a240000+0x10000, 0x28a3ac000+0x4000,
#                      0x28a800000+0x800000, 0x86700000+0x114000 (the PMC metadata window
#                      dcpext0's disp-4 also names); bwr-agent DISP_INT BIRQ 0x96
#   /arm-io/dart-dcp   0x28a340000+0x20000, IRQ 990, l1-tt-23, vm-base 1 TiB, vm-size 3 TiB
#   /arm-io/dart-disp0 0x28a300000+0xc000 (reg[0] only), IRQ 990, l1-tt-0 (scanout),
#                      l1-tt-16 (PIODMA); SIDs 3/4 are exclave planes: never attach them
# arm-io ranges add 0x200000000 to every arm-io address except the PMC window's.
import hashlib, pathlib, subprocess
H = pathlib.Path.home()
SRC = H/"Work/agents/trackpad-aurora/dt/j716s-typec-fixed8.dts"
FIXED8_DTB = H/"Work/agents/trackpad-aurora/dt/t6050-j716s-typec-fixed8.dtb"
OUT = H/"Work/agents/dcp-aurora/dt"
DTC = "/Volumes/linux-cs/wt-aurora/scripts/dtc/dtc"
if not pathlib.Path(DTC).exists():  # wt-aurora was cleaned away; any dtc >= 1.6 compiles this
    DTC = "/opt/homebrew/bin/dtc"
# The DISP_INT bandwidth scratch offset inside the PMC window 0x286700000 (static, macOS 27.0, 27.2
# and 27.3 kernelcaches agree; see ../BW-SCRATCH.md): the display kext answers D003 with the
# physical address of disp0's platform function function-bw_req_interrupt0 = <pmgr 'BIRQ' 0x96>;
# ApplePMC::getBWRMemory finds 0x96 in /arm-io/pmgr bwr-agent (DISP_INT, index byte 0) and the
# T6050 PMC returns 0x20000 + 0x4000 * index, on top of PMGR reg[8] + 0x700000 = 0x286700000.
# DISP_EXT0 (index 3) gives 0x2c000, the value Aurora's dcpext0 uses. Set to None to drop the
# property again (the driver then refuses the node: "Incompatible devicetree!").
BW_SCRATCH_OFFSET = 0x20000
sha = lambda b: hashlib.sha256(b).hexdigest()
f8 = SRC.read_text()

def sub(text, old, new):
    assert text.count(old) == 1, f"expected exactly one match for {old!r}"
    return text.replace(old, new)

used = {int(x, 16) for x in __import__("re").findall(r"phandle = <(0x[0-9a-f]+)>;", f8)}
PH = dict(dart_dcp=0xd0, dart_disp0=0xd1, dcp_mbox=0xd2, dcp=0xd3, display=0xd4)
assert not used & set(PH.values()), "phandle clash"
assert "apple,t6050-dcp\"" not in f8 and "display-subsystem" not in f8, "fixed8 already has them"
PMC = "pmc-metadata@286700000 {"
assert "phandle = <0x12>;" in f8.split(PMC, 1)[1].split("};", 1)[0], "PMC window is not 0x12"

bw = (f"\t\t\tapple,bw-scratch = <0x12 0x00 0x05 {BW_SCRATCH_OFFSET:#x}>;\n"
      if BW_SCRATCH_OFFSET is not None else
      "\t\t\t/* apple,bw-scratch: DISP_INT offset unknown (mk-fixed9.py BW_SCRATCH_OFFSET) */\n")

SOC_NODES = f"""iommu@48a340000 {{
			compatible = "apple,t6050-dart", "apple,t8110-dart";
			reg = <0x04 0x8a340000 0x00 0x20000>;
			interrupts = <0x00 0x00 0x3de 0x04>;
			#iommu-cells = <0x01>;
			apple,dma-range = <0x100 0x00 0x300 0x00>;
			status = "disabled";
			phandle = <{PH['dart_dcp']:#x}>;
		}};

		iommu@48a300000 {{
			compatible = "apple,t6050-dart", "apple,t8110-dart";
			reg = <0x04 0x8a300000 0x00 0xc000>;
			interrupts = <0x00 0x00 0x3de 0x04>;
			#iommu-cells = <0x01>;
			apple,dma-range = <0x100 0x00 0x300 0x00>;
			status = "disabled";
			phandle = <{PH['dart_disp0']:#x}>;
		}};

		mailbox@48ae08000 {{
			compatible = "apple,t6050-asc-mailbox", "apple,asc-mailbox-v4";
			reg = <0x04 0x8ae08000 0x00 0x4000>;
			interrupts = <0x00 0x00 0x413 0x04 0x00 0x00 0x414 0x04 0x00 0x00 0x415 0x04 0x00 0x00 0x416 0x04>;
			interrupt-names = "send-empty", "send-not-empty", "recv-empty", "recv-not-empty";
			#mbox-cells = <0x00>;
			status = "disabled";
			phandle = <{PH['dcp_mbox']:#x}>;
		}};

		dcp@48ae00000 {{
			compatible = "apple,t6050-dcp", "apple,dcp";
			reg = <0x04 0x8ae00000 0x00 0x4000 0x04 0x88000000 0x00 0x4000000 0x04 0x8a240000 0x00 0x10000 0x04 0x8a3ac000 0x00 0x4000 0x04 0x8a800000 0x00 0x800000 0x02 0x86700000 0x00 0x114000 0x04 0x8a850000 0x00 0x4000>;
			reg-names = "coproc", "disp-0", "disp-1", "disp-2", "disp-3", "disp-4", "iop-vbar";
			mboxes = <{PH['dcp_mbox']:#x}>;
			mbox-names = "mbox";
			iommus = <{PH['dart_dcp']:#x} 0x17>;
{bw}			apple,dcp-index = <0x00>;
			apple,clock-ids;
			status = "disabled";
			phandle = <{PH['dcp']:#x}>;

			piodma {{
				iommus = <{PH['dart_disp0']:#x} 0x10>;
			}};

			panel {{
				compatible = "apple,panel-j716", "apple,panel-mini-led", "apple,panel";
				width-mm = <0x159>;
				height-mm = <0xdf>;
				apple,max-brightness = <0x258>;
			}};
		}};

		{PMC}"""

ROOT_NODE = f"""display-subsystem {{
		compatible = "apple,display-subsystem";
		iommus = <{PH['dart_disp0']:#x} 0x00>;
		status = "disabled";
		phandle = <{PH['display']:#x}>;
	}};

	aliases {{"""

f9 = sub(f8, PMC, SOC_NODES)
f9 = sub(f9, "aliases {", ROOT_NODE)
dts = OUT/"j716s-typec-fixed9.dts"; dtb = OUT/"t6050-j716s-typec-fixed9.dtb"
dts.write_text(f9)
r = subprocess.run([DTC, "-q", "-I", "dts", "-O", "dtb", "-o", str(dtb), str(dts)],
                   capture_output=True, text=True)
assert r.returncode == 0, r.stderr
print(f"{sha(FIXED8_DTB.read_bytes())}  {FIXED8_DTB.name} (input)")
print(f"{sha(dtb.read_bytes())}  {dtb.name}")
