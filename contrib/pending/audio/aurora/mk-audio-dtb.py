# Make the J716s audio DTBs from the daily DT and compile them with Aurora's dtc
# (read-only use of /Volumes/linux-cs/wt-aurora/scripts/dtc/dtc).
#   python3 -I ~/Work/agents/audio-aurora/mk-audio-dtb.py            # from fixed8-notun-edp (current lineage)
#   python3 -I ~/Work/agents/audio-aurora/mk-audio-dtb.py fixed8     # from fixed8 (older lineage, per-unit tunables)
#
# Sources:
#   notun-edp  ~/Work/agents/aurora-kernel/dts/j716s-typec-fixed8-notun-edp.dts: fixed8 minus the 14 baked
#              apple,tunable-* lists (m1n1 patch 0021 fills them at boot) plus apple,internal-panel on the chosen
#              framebuffer. No per-unit values: outputs t6050-j716s-audio{,-spk}-notun-edp.dtb.
#   fixed8     ~/Work/agents/trackpad-aurora/dt/j716s-typec-fixed8.dts (carries per-unit tunables: keep private):
#              outputs t6050-j716s-audio{,-spk}.dtb.
#
# t6050-j716s-audio.dtb      (primary)  fixed8 + AOP (setup port), base-ns and LEAP-S ADMACs, the AOP audio
#                                       node, the amps and jack codec on i2c1/i2c2/i2c3, and the sound card.
#                                       SPEAKERS OFF: no amp carries apple,speaker-config, so macaudio logs
#                                       "the boot loader passed no amp levels, disabling speakers" and binds
#                                       the jack only; the amps never leave hardware shutdown (SDZ, GPIO 107,
#                                       is driven low by tas2764 at I2C probe and raised only by a card that
#                                       has them). Microphone array on (separate card AppleJ716AOP).
# t6050-j716s-audio-spk.dtb  (later)    the same plus apple,speaker-config on each amp with the level byte
#                                       lowered from the ADT's 15 to SPK_LEVEL (16 dBV instead of 18.5 dBV).
#                                       Use only after speakersafetyd is installed and verified (ROOT-SETUP.md).
#                                       The kernel (patch 0011) holds the speaker volume at -30 dB in every state.
#
# Every address, IRQ, GPIO, DART stream and slot is from the J716s ADT (adt-runtime-j716s.bin); node
# shapes follow edimoldovan's working J714c DT (linux-aurora t6050-j714c @ 671fd38e1c0d). The fixed8-based
# DTS files carry per-unit tunables inherited from fixed8: keep those private. The notun-edp ones do not.
import hashlib, pathlib, subprocess, sys
H = pathlib.Path.home()
SOURCES = {
    "notun-edp": (H/"Work/agents/aurora-kernel/dts/j716s-typec-fixed8-notun-edp.dts",
                  "90c604668bbdf03d27d149c29913b6418db33636607715524ac85153e6135cc0", "-notun-edp"),
    "fixed8": (H/"Work/agents/trackpad-aurora/dt/j716s-typec-fixed8.dts",
               "999eeacb0759e34be252c00ed81b299cb24d182e4c1ff6cfe7dd308ade4c4c54", ""),
}
which = sys.argv[1] if len(sys.argv) > 1 else "notun-edp"
SRC, SRC_SHA, SUFFIX = SOURCES[which]
OUT = H/"Work/agents/audio-aurora/dt"
DTC = "/Volumes/linux-cs/wt-aurora/scripts/dtc/dtc"
SPK_LEVEL = 10        # ADT speaker-config amp_gain is 15; macaudio caps "Amp Gain Volume" at this byte
sha = lambda b: hashlib.sha256(b).hexdigest()
assert sha(SRC.read_bytes()) == SRC_SHA, f"{SRC.name} changed"
src = SRC.read_text()

# New phandles; fixed8 uses up to 0x51.
P_LW1, P_LW2, P_LT, P_JACK, P_RW1, P_RW2, P_RT = 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66
P_SETUP_MBOX, P_LEAP_S, P_AOP_AUDIO, P_PS_I2C3 = 0x67, 0x68, 0x69, 0x6a
PINCTRL_AP, AOP_MBOX, AOP_DART, BASE_NS = 0x3c, 0x42, 0x41, 0x43       # existing fixed8 phandles
for p in range(0x60, 0x6b):
    assert f"phandle = <{p:#04x}>;" not in src, f"phandle {p:#x} already used"

def sub(text, old, new):
    assert text.count(old) == 1, f"expected exactly one match for {old[:70]!r}"
    return text.replace(old, new)

# ADT speaker-config rows (rx_slot, amp_gain, vsense_slot, isense_slot); row n = ADT speakerN.
ROWS = {"LW1": (0, 15, 0, 2), "RW1": (1, 15, 4, 6), "LW2": (2, 15, 8, 10),
        "RW2": (3, 15, 12, 14), "LT": (4, 15, 16, 18), "RT": (5, 15, 20, 22)}

def amp(label, name, addr, ph, imon, vmon, spk):
    cfg = ""
    if spk:
        r = ROWS[label]
        cfg = "\t\t\t\tapple,speaker-config = [%02x %02x %02x %02x];\n" % (r[0], SPK_LEVEL, r[2], r[3])
    return (f"\n\t\t\tcodec@{addr:x} {{\n"
            f"\t\t\t\tcompatible = \"ti,sn012776\", \"ti,tas2764\";\n"
            f"\t\t\t\treg = <{addr:#04x}>;\n"
            f"\t\t\t\tshutdown-gpios = <{PINCTRL_AP:#04x} 0x6b 0x00>;\n"      # AP 107, active high
            f"\t\t\t\tinterrupts-extended = <{PINCTRL_AP:#04x} 0x6a 0x08>;\n"  # AP 106, level low
            f"\t\t\t\t#sound-dai-cells = <0x00>;\n"
            f"\t\t\t\tsound-name-prefix = \"{name}\";\n"
            f"\t\t\t\tti,imon-slot-no = <{imon:#04x}>;\n"
            f"\t\t\t\tti,vmon-slot-no = <{vmon:#04x}>;\n"
            f"{cfg}"
            f"\t\t\t\tphandle = <{ph:#04x}>;\n"
            f"\t\t\t}};\n")

def strip_tunable_comments(t):
    # notun-edp keeps fixed7's comment block about the ATC1 tunables it no longer carries (names, banks and a
    # local script path, no values). Drop it from the published DTS; the DTB is the same either way.
    a = t.find("\t\t\t/* ATC1 (left-front) board tunables from the ADT")
    if a < 0:
        return t
    b = t.index("\t\t\t/* Present in the ADT, not consumed by the driver:", a)
    b = t.index("*/\n", b) + 3
    return t[:a] + t[b:]

def build(spk):
    t = strip_tunable_comments(src) if which == "notun-edp" else src
    # 1. pinctrl_ap: open the audio pins (106, 107 amps; 134, 139 jack codec) besides PERST# 80,
    #    the pattern of Aurora's t6050-j775d.dts.
    t = sub(t, "gpio-reserved-ranges = <0x00 0x50 0x51 0x8c>;",
               "gpio-reserved-ranges = <0x00 0x50 0x51 0x19 0x6c 0x1a 0x87 0x04 0x8c 0x51>;")
    # 2. i2c1 (left amps) and i2c2 (jack codec) on.
    i2c1_old = """			interrupts = <0x00 0x00 0x560 0x04>;
			#address-cells = <0x01>;
			#size-cells = <0x00>;
			power-domains = <0x3d>;
			status = "disabled";
		};"""
    i2c1_new = ("""			interrupts = <0x00 0x00 0x560 0x04>;
			#address-cells = <0x01>;
			#size-cells = <0x00>;
			power-domains = <0x3d>;
			status = "okay";
""" + amp("LW1", "Left Woofer 1", 0x38, P_LW1, 0, 2, spk)
    + amp("LW2", "Left Woofer 2", 0x39, P_LW2, 8, 10, spk)
    + amp("LT", "Left Tweeter", 0x3a, P_LT, 16, 18, spk) + "\t\t};")
    t = sub(t, i2c1_old, i2c1_new)
    i2c2_old = """			interrupts = <0x00 0x00 0x561 0x04>;
			#address-cells = <0x01>;
			#size-cells = <0x00>;
			power-domains = <0x3e>;
			status = "disabled";
		};"""
    i2c2_new = f"""			interrupts = <0x00 0x00 0x561 0x04>;
			#address-cells = <0x01>;
			#size-cells = <0x00>;
			power-domains = <0x3e>;
			status = "okay";

			codec@4b {{
				compatible = "cirrus,cs42l84";
				reg = <0x4b>;
				reset-gpios = <{PINCTRL_AP:#04x} 0x8b 0x00>;
				interrupts-extended = <{PINCTRL_AP:#04x} 0x86 0x08>;
				#sound-dai-cells = <0x00>;
				sound-name-prefix = "Jack";
				phandle = <{P_JACK:#04x}>;
			}};
		}};

		i2c@50501c000 {{
			compatible = "apple,t6050-i2c", "apple,t8103-i2c";
			reg = <0x05 0x501c000 0x00 0x4000>;
			clocks = <0x1e>;
			interrupt-parent = <0x01>;
			interrupts = <0x00 0x00 0x562 0x04>;
			#address-cells = <0x01>;
			#size-cells = <0x00>;
			power-domains = <{P_PS_I2C3:#04x}>;
			status = "okay";
""" + amp("RW1", "Right Woofer 1", 0x3b, P_RW1, 4, 6, spk) \
    + amp("RW2", "Right Woofer 2", 0x3c, P_RW2, 12, 14, spk) \
    + amp("RT", "Right Tweeter", 0x3d, P_RT, 20, 22, spk) + "\t\t};"
    t = sub(t, i2c2_old, i2c2_new)
    # 3. The I2C3 power state (pmgr 0x280900000 + 0x2d8, after I2C1 0x2c8 and I2C2 0x2d0).
    t = sub(t, """				label = "i2c2";
				phandle = <0x3e>;
			};
""", f"""				label = "i2c2";
				phandle = <0x3e>;
			}};

			power-controller@2d8 {{
				compatible = "apple,t6050-pmgr-pwrstate", "apple,t8103-pmgr-pwrstate";
				reg = <0x2d8 0x04>;
				#power-domain-cells = <0x00>;
				#reset-cells = <0x00>;
				label = "i2c3";
				phandle = <{P_PS_I2C3:#04x}>;
			}};
""")
    # 4. AOP mailbox on; the setup port (ADT aop-exclave-mailbox 0x2d067c000, IRQs 582/585,
    #    dart-aop stream 1, vm-base-1 0x20000000000) added and on.
    t = sub(t, """			interrupt-names = "send-empty", "send-not-empty", "recv-empty", "recv-not-empty";
			#mbox-cells = <0x00>;
			status = "disabled";
			phandle = <0x42>;
		};""", f"""			interrupt-names = "send-empty", "send-not-empty", "recv-empty", "recv-not-empty";
			#mbox-cells = <0x00>;
			status = "okay";
			phandle = <0x42>;
		}};

		mailbox@2d067c000 {{
			compatible = "apple,t6050-aop-setup-mailbox", "apple,t8140-aop-setup-mailbox";
			reg = <0x02 0xd067c000 0x00 0x4000>;
			interrupt-parent = <0x01>;
			interrupts = <0x00 0x00 0x246 0x04 0x00 0x00 0x249 0x04>;
			interrupt-names = "send-empty", "recv-not-empty";
			iommus = <{AOP_DART:#04x} 0x01>;
			apple,dma-range = <0x200 0x00 0x10 0x00>;
			#mbox-cells = <0x00>;
			status = "okay";
			phandle = <{P_SETUP_MBOX:#04x}>;
		}};""")
    # 5. dart-aop: locked by iBoot with inherited roots; the t8142 compatible selects apple-dart's
    #    per-stream retained-root path (fw_mirror), as on edimoldovan's J714c.
    t = sub(t, """			compatible = "apple,t6050-dart", "apple,t8110-dart";
			reg = <0x02 0x90fc0000 0x00 0xc000>;
			#iommu-cells = <0x01>;
			interrupt-parent = <0x01>;
			interrupts = <0x00 0x00 0x268 0x04>;
			status = "disabled";""", """			compatible = "apple,t6050-dart", "apple,t8142-dart", "apple,t8110-dart";
			reg = <0x02 0x90fc0000 0x00 0xc000>;
			#iommu-cells = <0x01>;
			interrupt-parent = <0x01>;
			interrupts = <0x00 0x00 0x268 0x04>;
			status = "okay";""")
    # 6. base-ns ADMAC on; the LEAP-S ADMAC through its non-secure proxy (ADT admac-hp-mic-ec-proxy
    #    0x2d3200000, IRQ 638, 9+9 channels, dart-aop stream 11) added and on.
    t = sub(t, """			iommus = <0x41 0x08>;
			apple,dma-range = <0x110 0x00 0x00 0x10000000>;
			status = "disabled";
			phandle = <0x43>;
		};""", f"""			iommus = <0x41 0x08>;
			apple,dma-range = <0x110 0x00 0x00 0x10000000>;
			status = "okay";
			phandle = <0x43>;
		}};

		dma-controller@2d3200000 {{
			compatible = "apple,t6050-admac", "apple,t8140-admac";
			reg = <0x02 0xd3200000 0x00 0x34000>;
			dma-channels = <0x09>;
			interrupts-extended = <0x01 0x00 0x00 0x27e 0x04 0x00 0x00 0x00>;
			#dma-cells = <0x01>;
			iommus = <{AOP_DART:#04x} 0x0b>;
			apple,dma-range = <0x110 0x00 0x00 0x10000000>;
			status = "okay";
			phandle = <{P_LEAP_S:#04x}>;
		}};""")
    # 7. The AOP on, with its setup port; the audio node with edimoldovan's DMA names and the
    #    microphone array on LEAP-S channel 1 (ADT leap-s-adma-rx-0).
    t = sub(t, """			mboxes = <0x42>;
			mbox-names = "mbox";
			iommus = <0x41 0x00>;
			apple,dma-range = <0x110 0x00 0x10 0x00>;
			status = "disabled";

			audio {
				compatible = "apple,t6050-aop-audio";
				dmas = <0x43 0x04 0x43 0x05 0x43 0x00 0x43 0x01>;
				dma-names = "cout", "cin", "spkr", "sense";
				#sound-dai-cells = <0x01>;
			};""", f"""			mboxes = <0x42 {P_SETUP_MBOX:#04x}>;
			mbox-names = "mbox", "setup";
			iommus = <0x41 0x00>;
			apple,dma-range = <0x110 0x00 0x10 0x00>;
			status = "okay";

			audio {{
				compatible = "apple,t6050-aop-audio";
				dmas = <{BASE_NS:#04x} 0x00 {BASE_NS:#04x} 0x01 {BASE_NS:#04x} 0x04 {BASE_NS:#04x} 0x05 {P_LEAP_S:#04x} 0x01>;
				dma-names = "spkr", "spkr-sense", "cout", "cin", "hpai";
				#sound-dai-cells = <0x01>;
				apple,chassis-name = "J716";
				apple,machine-kind = "MacBook Pro";
				phandle = <{P_AOP_AUDIO:#04x}>;
			}};""")
    # 8. The sound card: jack on AOP DAI 0 (cout), speakers on AOP DAI 4 (spkr), amps in ADT order.
    t = sub(t, "\n\taliases {\n", f"""
	sound {{
		compatible = "apple,j716-macaudio", "apple,macaudio";
		model = "MacBook Pro J716";
		#address-cells = <0x01>;
		#size-cells = <0x00>;

		dai-link@0 {{
			reg = <0x00>;
			link-name = "Headphone Jack";

			cpu {{
				sound-dai = <{P_AOP_AUDIO:#04x} 0x00>;
			}};

			codec {{
				sound-dai = <{P_JACK:#04x}>;
			}};
		}};

		dai-link@1 {{
			reg = <0x01>;
			link-name = "Speakers";
			dai-tdm-idle-mode-0 = "zero";
			dai-tdm-idle-mode-1 = "zero";
			dai-tdm-slot-tx-idle-mask-0 = <0xf0f0f0>;
			dai-tdm-slot-tx-idle-mask-1 = <0x0f0f0f>;

			cpu {{
				sound-dai = <{P_AOP_AUDIO:#04x} 0x04>;
			}};

			codec {{
				sound-dai = <{P_LW1:#04x} {P_RW1:#04x} {P_LW2:#04x} {P_RW2:#04x} {P_LT:#04x} {P_RT:#04x}>;
			}};
		}};
	}};

	aliases {{
""")
    return t

OUT.mkdir(parents=True, exist_ok=True)
for name, spk in (("j716s-audio", False), ("j716s-audio-spk", True)):
    dts = OUT/f"{name}{SUFFIX}.dts"; dtb = OUT/f"t6050-{name}{SUFFIX}.dtb"
    dts.write_text(build(spk))
    r = subprocess.run([DTC, "-q", "-I", "dts", "-O", "dtb", "-o", str(dtb), str(dts)],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    print(f"{sha(dtb.read_bytes())}  {dtb.name}")
