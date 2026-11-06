# Proposed `arch/arm64/boot/dts/apple/t6050-j716s.dts` for Aurora's tree

Base: `j716c/t6050-platform` `0b209c466e06` (`t6050-max.dtsi`, `t6050-die0.dtsi`, `t6050-dieX.dtsi`, `t6050-j716c.dts`).
Not compiled. Run `make dtbs` and `dtbs_check` once it is in a tree.

Source tags in the comments:
- **[ADT]**: J716s runtime ADT, `~/Work/studio-artifacts/adt-runtime-j716s.bin`. Hardware-description properties only.
- **[J716C]**: copied unchanged from `t6050-j716c.dts` because the J716s ADT shows the same value.
- **[OURS]**: our omarchy J716s tree (`/Volumes/linux-cs/wt-integration/arch/arm64/boot/dts/apple/`).
- **[INFER]**: inferred, not measured.

The file is staged with cpp switches so the first payload stays boot-safe:
- default: J716c-equivalent plus our ATC0 tether gadget, keyboard backlight and trackpad
- `-DJ716S_TYPEC_LEFT_FRONT`: SN201202x hpm1 + ATC1 (USB3/replug on the left-front port)
- `-DJ716S_TYPEC_RIGHT`: nub-spmi-a1 + hpm2 + ATC2 (right port; it shares ATC2 with the dcpext0 DP route)
- `-DJ716S_HWMON`: SMC fan sensors (their hwmon lacks our 0003, so a missing key fails the fan)

```dts
// SPDX-License-Identifier: GPL-2.0+ OR MIT
/*
 * MacBook Pro (16-inch, M5 Pro, 2026)
 *
 * target-type: J716s (Mac17,8)
 *
 * One T6050 die. The runtime ADT lists all 18 CPUs (cpu0-17), so the M5 Max
 * CPU list in t6050-max.dtsi applies unchanged; the boot loader removes any
 * core it did not start. Like t6050-j716c.dts, this file only enables and
 * configures what has been brought up; the SoC's other blocks stay disabled.
 *
 * Copyright The Asahi Linux Contributors
 */

/dts-v1/;

#include <dt-bindings/leds/common.h>
#include "t6050-max.dtsi"

/ {
	/* [ADT] /product sub-product-type "Mac17,8", product-name "MacBook Pro (16-inch, M5 Pro)" */
	compatible = "apple,j716s", "apple,t6050", "apple,arm-platform";
	model = "Apple MacBook Pro (16-inch, M5 Pro, 2026)";
	chassis-type = "laptop";

	aliases {
		serial0 = &dockchannel;			/* [J716C] */
		/* The loader fills the N1's factory addresses through these [J716C] */
		wifi0 = &n1_alpha;
		bluetooth0 = &n1_beta;
		/* m1n1 dt_set_ipd() fills the layout from the ADT keyboard node [OURS t6050-j716s.dts:21-25] */
		keyboard = &keyboard;
	};

	chosen {
		#address-cells = <2>;
		#size-cells = <2>;
		ranges;
		/* Normally replaced by the loader */
		bootargs = "maxcpus=1";

		framebuffer0: framebuffer@0 {
			compatible = "apple,simple-framebuffer", "simple-framebuffer";
			reg = <0 0 0 0>; /* To be filled by the loader */
			/* Format properties will be added by the loader */
			status = "disabled";
		};
	};

	/*
	 * Keyboard backlight. [ADT] /arm-io/pwm0/kbd-backlight: channel 0,
	 * default-hz 25000 -> period 40000 ns. [OURS t6050-j716s.dts:35-46]
	 */
	led-controller {
		compatible = "pwm-leds";

		led-0 {
			pwms = <&fpwm0 0 40000>;
			label = "kbd_backlight";
			function = LED_FUNCTION_KBD_BACKLIGHT;
			color = <LED_COLOR_ID_WHITE>;
			max-brightness = <255>;
			default-state = "keep";
		};
	};
};

/*
 * Blocks t6050-die0.dtsi does not describe yet (candidates for that file):
 * the keyboard backlight PWM, the ATC0 gadget this board's tether runs on,
 * and the third HPM SPMI bus.
 */
&die0 {
	/* [ADT] /arm-io/pwm0 reg 0x505040000 +0x4000, clock-gate FPWM0 [OURS t6050.dtsi:303-315] */
	fpwm0: pwm@505040000 {
		compatible = "apple,t6050-fpwm", "apple,s5l-fpwm";
		reg = <0x5 0x05040000 0x0 0x4000>;
		power-domains = <&ps_fpwm0>;
		clocks = <&clkref>;
		#pwm-cells = <2>;
	};

	/*
	 * ATC0 (left-back, the MagSafe side; [ADT] usb-drd0 port-number 1, hpm0
	 * port-location "left-back"). The combo PHY driver refuses port 0, and this
	 * port carries the USB tether, so it stays a device-mode controller on the
	 * PHY state m1n1's usb_phy_bringup() leaves. [OURS t6050-storage-net.dtsi:50-88]
	 * [ADT] /arm-io/usb-drd0 reg[0] 0x2a2280000, interrupts[0] 1419;
	 * /arm-io/dart-usb0 reg[0] 0x2a2f00000, reg[1] 0x2a2f80000, interrupt 1423.
	 */
	dwc3_0: usb@2a2280000 {
		compatible = "snps,dwc3";
		reg = <0x2 0xa2280000 0x0 0xcd00>;
		interrupts = <AIC_IRQ 0 1419 IRQ_TYPE_LEVEL_HIGH>;
		dr_mode = "peripheral";
		maximum-speed = "high-speed";
		iommus = <&dwc3_0_dart_0 0>, <&dwc3_0_dart_1 1>;
		snps,usb2-gadget-lpm-disable;
		snps,dis_u2_susphy_quirk;
		snps,dis_u3_susphy_quirk;
		snps,dis_enblslpm_quirk;
	};

	dwc3_0_dart_0: iommu@2a2f00000 {
		compatible = "apple,t6050-dart", "apple,t8110-dart";
		reg = <0x2 0xa2f00000 0x0 0xc000>;
		interrupts = <AIC_IRQ 0 1423 IRQ_TYPE_LEVEL_HIGH>;
		#iommu-cells = <1>;
	};

	dwc3_0_dart_1: iommu@2a2f80000 {
		compatible = "apple,t6050-dart", "apple,t8110-dart";
		reg = <0x2 0xa2f80000 0x0 0xc000>;
		interrupts = <AIC_IRQ 0 1423 IRQ_TYPE_LEVEL_HIGH>;
		#iommu-cells = <1>;
	};

	/*
	 * [ADT] /arm-io/nub-spmi-a1: reg[0] 0x8a1a8000 (+0x200000000), gen 4, the
	 * HPM bus of the right-hand port (hpm2). J716c uses nub-spmi-a2 instead;
	 * this board has no a2. Polled, like a0.
	 */
	nub_spmi_a1: spmi@28a1a8000 {
		compatible = "apple,t6050-spmi", "apple,t8142-spmi";
		reg = <0x2 0x8a1a8000 0x0 0x4000>;
		#address-cells = <2>;
		#size-cells = <0>;
		status = "disabled";
	};
};

/* [ADT] pmgr device FPWM0, group 1 + 0x2a8 [OURS t6050-pmgr.dtsi:952-959]; parent SIO left undescribed as for ps_i2c1/2 */
&pmgr1 {
	ps_fpwm0: power-controller@2a8 {
		compatible = "apple,t6050-pmgr-pwrstate", "apple,t8103-pmgr-pwrstate";
		reg = <0x2a8 4>;
		#power-domain-cells = <0>;
		#reset-cells = <0>;
		label = "fpwm0";
	};
};

/*
 * PCIe port 0: the N1 (Wi-Fi and Bluetooth). Port 1 is the SD reader
 * ([ADT] apcie0/pci-bridge1/pcie-sdreader), not described. The loader must
 * train port 0 and then enable port00 and dart_apcie0; until it does, both
 * stay disabled. m1n1 does not do this today.
 * [ADT] /arm-io/apcie0 reg[0] 0x1cb0000000, reg[1] 0x414000000 (rc),
 * reg[16] 0x410028000 (port0), reg[18] 0x417010000 (phy0), reg[19]
 * 0x410024000 (intr2axi0), interrupts[0] 1523: identical to J716c.
 */
&pcie0 {
	reg = <0x1c 0xb0000000 0x0 0x10000000>,
	      <0x4 0x14000000 0x0 0x4000>,
	      <0x4 0x10028000 0x0 0x8000>,
	      <0x4 0x17010000 0x0 0x4000>,
	      <0x4 0x10024000 0x0 0x4000>;
	reg-names = "config", "rc", "port0", "phy0", "intr2axi0";
	interrupts = <AIC_IRQ 0 1523 IRQ_TYPE_LEVEL_HIGH>;
	interrupt-names = "port0";

	/* The N1's three functions are on DART streams 1-3 [J716C] */
	iommu-map = <0x100 &dart_apcie0 1 3>;
	bus-range = <0 4>;

	port00: pci@0,0 {
		device_type = "pci";
		reg = <0x0 0 0 0 0>;
		bus-range = <1 1>;
		apple,link-trained-by-bootloader;
		/* PERST#: [ADT] pci-bridge0 function-perst = GPIO 80 */
		reset-gpios = <&pinctrl_ap 80 GPIO_ACTIVE_LOW>;
		status = "disabled";

		#address-cells = <3>;
		#size-cells = <2>;
		ranges;

		interrupt-controller;
		#interrupt-cells = <1>;
		interrupt-map-mask = <0 0 0 7>;
		interrupt-map = <0 0 0 1 &port00 0 0 0 0>,
				<0 0 0 2 &port00 0 0 0 1>,
				<0 0 0 3 &port00 0 0 0 2>,
				<0 0 0 4 &port00 0 0 0 3>;

		/*
		 * platform ID = (board << 16) | chip: [ADT] /chosen board-id = 0x0c,
		 * chip 0x6050 (binding apple,centauri.yaml: chip in bits 15..0,
		 * board in 30..16). The FTAB is personalised for each unit; its name
		 * follows J716c's scheme [INFER].
		 */
		n1_control: control@0,0 {
			compatible = "pci106b,1900";
			reg = <0x10000 0x0 0x0 0x0 0x0>;
			firmware-name = "apple/centauri/j716s-ftab.bin";
			apple,centauri-platform-id = <0x000c6050>;
			apple,centauri-protocol = <27>;
		};

		/* [ADT] apcie0/pci-bridge0/centauri-alpha (fn 1) */
		n1_alpha: wifi@0,1 {
			compatible = "pci106b,1902";
			reg = <0x10100 0x0 0x0 0x0 0x0>;
			local-mac-address = [00 00 00 00 00 00];
		};

		/* [ADT] apcie0/pci-bridge0/centauri-beta (fn 2) */
		n1_beta: bluetooth@0,2 {
			compatible = "pci106b,1903";
			reg = <0x10200 0x0 0x0 0x0 0x0>;
			local-bd-address = [00 00 00 00 00 00];
		};
	};
};

/*
 * Type-C. [ADT] port map:
 *   ATC0 usb-drd0 port 1 left-back  hpm0 nub-spmi-a0 SID 0x0c  (tether, dwc3_0 above)
 *   ATC1 usb-drd1 port 2 left-front hpm1 nub-spmi-a0 SID 0x0a
 *   ATC2 usb-drd2 port 3 right      hpm2 nub-spmi-a1 SID 0x0c
 *   MagSafe                          hpm5 nub-spmi-a0 SID 0x08 (port-type 17, not a USB-C connector)
 * There is no usb-drd3 in this ADT, so ATC3's USB chain stays off.
 */
&atc3_phy_mbox {
	status = "disabled";
};

&atc3_phy {
	status = "disabled";
};

&usb_drd3 {
	status = "disabled";
};

&usb_drd3_dart_0 {
	status = "disabled";
};

&usb_drd3_dart_1 {
	status = "disabled";
};

&nub_spmi_a2 {
	status = "disabled";			/* [ADT] this board has no nub-spmi-a2 */
};

#ifndef J716S_TYPEC_LEFT_FRONT
/* Default: as J716c, the left-front chain stays off until its PD controller is described */
&nub_spmi_a0 {
	status = "disabled";
};

&atc1_phy_mbox {
	status = "disabled";
};

&atc1_phy {
	status = "disabled";
};

&usb_drd1 {
	status = "disabled";
};

&usb_drd1_dart_0 {
	status = "disabled";
};

&usb_drd1_dart_1 {
	status = "disabled";
};
#else
/*
 * Left-front port: SN201202x hpm1, polled (no interrupts property).
 * Node shape from t8142-j813-usb.dtsi:208-239 (integration/aurora); the
 * endpoints into apple,t6050-combo-phy and apple,t6050-dwc3 are [INFER]
 * and need checking against their bindings.
 */
&nub_spmi_a0 {
	hpm1: usb-pd@a {
		compatible = "apple,sn201202x";
		reg = <0xa SPMI_USID>;			/* [ADT] hpm1 reg[0] = 0x0a */

		typec1: connector {
			compatible = "usb-c-connector";
			label = "USB-C Left-front";	/* [ADT] hpm1 port-location */
			power-role = "dual";
			data-role = "dual";

			ports {
				#address-cells = <1>;
				#size-cells = <0>;

				port@0 {
					reg = <0>;
					typec1_hs: endpoint {
						remote-endpoint = <&usb_drd1_hs>;
					};
				};

				port@1 {
					reg = <1>;
					typec1_ss: endpoint {
						remote-endpoint = <&atc1_phy_typec>;
					};
				};
			};
		};
	};
};

&usb_drd1 {
	port {
		usb_drd1_hs: endpoint {
			remote-endpoint = <&typec1_hs>;
		};
	};
};

&atc1_phy {
	port {
		atc1_phy_typec: endpoint {
			remote-endpoint = <&typec1_ss>;
		};
	};
};
#endif

#ifdef J716S_TYPEC_RIGHT
/* Right port: hpm2 on nub-spmi-a1, ATC2 (shared with the dcpext0 DP route, t6050-die0.dtsi:966-985) */
&nub_spmi_a1 {
	status = "okay";

	hpm2: usb-pd@c {
		compatible = "apple,sn201202x";
		reg = <0xc SPMI_USID>;			/* [ADT] hpm2 reg[0] = 0x0c */

		typec2: connector {
			compatible = "usb-c-connector";
			label = "USB-C Right";		/* [ADT] hpm2 port-location */
			power-role = "dual";
			data-role = "dual";

			ports {
				#address-cells = <1>;
				#size-cells = <0>;

				port@0 {
					reg = <0>;
					typec2_hs: endpoint {
						remote-endpoint = <&usb_drd2_hs>;
					};
				};

				port@1 {
					reg = <1>;
					typec2_ss: endpoint {
						remote-endpoint = <&atc2_phy_typec>;
					};
				};
			};
		};
	};
};

/* [ADT] usb-drd2 0x382280000 IRQ 1483, dart-usb2 IRQ 1487, atc-phy2 0x383000000: match t6050-die0.dtsi */
&ps_atc2_common { status = "okay"; };
&ps_atc2_usb_aon { status = "okay"; };
&ps_atc2_phymxwrap { status = "okay"; };
&ps_atc2_usb { status = "okay"; };
&atc2_phy_mbox { status = "okay"; };
&usb_drd2_dart_0 { status = "okay"; };
&usb_drd2_dart_1 { status = "okay"; };

&atc2_phy {
	status = "okay";

	port {
		atc2_phy_typec: endpoint {
			remote-endpoint = <&typec2_ss>;
		};
	};
};

&usb_drd2 {
	status = "okay";

	port {
		usb_drd2_hs: endpoint {
			remote-endpoint = <&typec2_hs>;
		};
	};
};
#endif

/* Audio is not brought up: 6x sn012776 on i2c1/i2c3 and cs42l84 on i2c2 [ADT]; i2c3 is not in the dtsi yet */
&i2c1 {
	status = "disabled";
};

&i2c2 {
	status = "disabled";
};

/*
 * Pin 112 takes an SError when read (J716c finding, same SoC), so only the
 * pins named here are exposed: 80 (PCIe port 0's PERST#, [ADT] pci-bridge0
 * function-perst GPIO 80).
 */
&pinctrl_ap {
	gpio-reserved-ranges = <0 80>, <81 140>;
};

#ifndef J716S_HWMON
/* As on J716c: this tree's macsmc-hwmon fails a fan on any missing key (no 0003) */
&smc_hwmon {
	status = "disabled";
};
#else
/*
 * The T6050 SMC spells the fan mode keys F0md/F1md (ui8) [OURS
 * t6050-j716s.dts:139-153]; F0Mn/F0Mx/F0Tg as on J714s, not re-probed on
 * J716s [OURS]. Temperatures come from apple,discover-temperatures in die0.
 */
#include "hwmon-fan-dual.dtsi"

&smc_hwmon {
	fan-F0Ac {
		apple,fan-mode = "F0md";
	};

	fan-F1Ac {
		apple,fan-mode = "F1md";
	};
};
#endif

/*
 * The console on the USB debug link drains only while a host reads it
 * [J716C]. On this board the tether is ATC0's gadget; keep earlycon=efifb.
 */
&dockchannel {
	apple,tx-never-wait;
	status = "okay";
};

/*
 * Keyboard and trackpad: the HID transport on the MTP's DockChannel FIFO [J716C].
 * Our 7.2 tree drives this MTP firmware (AppleMTPFirmwareMac-6320.86.1) in ring
 * mode; Aurora's T6050 runs it in FIFO mode. If FIFO fails here, add
 * "apple,t6041-dockchannel-hid" first in compatible, which selects the ring in
 * integration/aurora (dockchannel-hid.c:1574).
 */
&mtp_dockchannel {
	mtp_hid: input@8000 {
		compatible = "apple,dockchannel-hid";
		reg = <0x8000 0x1000>, <0xc000 0x1000>,
		      <0x0 0x1000>, <0x4000 0x1000>;
		reg-names = "config", "data", "rmt-config", "rmt-data";
		iommus = <&mtp_dart 0>;
		interrupt-parent = <&mtp_dockchannel>;
		interrupts = <2 IRQ_TYPE_LEVEL_HIGH>,
			     <3 IRQ_TYPE_LEVEL_HIGH>;
		interrupt-names = "tx", "rx";
		apple,fifo-size = <0x800>;		/* [ADT] dockchannel-mtp fifo-size 2048 [OURS] */
		apple,helper-cpu = <&mtp>;
		/*
		 * [ADT] multi-touch function-afe-reset = pKW8('pcIO', 0x10000, 0x11c0000):
		 * output 2 of the list below, exactly as J716c.
		 */
		apple,afe-reset-gpios = <&smc_pcio 2 GPIO_ACTIVE_HIGH>;

		multi-touch {
			apple,power-method = <2>;	/* [OURS] 6320.x accepts only method 2 */
			firmware-name = "apple/tpmtfw-j716s.bin";	/* [OURS t6050-j716s.dts:79] */
		};

		keyboard: keyboard {
			hid-country-code = <0>;		/* filled by m1n1 [OURS] */
			apple,keyboard-layout-id = <0>;
		};

		stm {
		};

		/* [ADT] mtp-transport children actuator and tp-accel; optional */
		actuator {
		};

		tp-accel {
		};
	};
};

/*
 * The SMC pcIO outputs, as pKW8('pcIO', lo, hi) templates (hi << 32) | lo [ADT]:
 *   0 dp2hdmi-gpio0 dp2hdmi_pwr_en (0x0, 0x1a0000)
 *   1 dp2hdmi-gpio0 hdmi_pwr_en    (0x800000, 0xf0000)
 *   2 multi-touch   afe-reset      (0x10000, 0x11c0000)
 * Identical to J716c. Not listed (not used yet): stm-reset (0x10000,
 * 0x11d0000), sd_pwr_en (0x0, 0x190000), stockholm enable (0x800000, 0x10e0000).
 */
&smc_pcio {
	apple,output-commands = /bits/ 64 <0x001a000000000000 0x000f000000800000 0x011c000000010000>;
};
```

## Makefile line
```make
dtb-$(CONFIG_ARCH_APPLE) += t6050-j716s.dtb
```
For the staged variants, add separate `.dts` wrappers that `#define` the switch and `#include "t6050-j716s.dts"`, e.g. `t6050-j716s-typec.dts`.

## J716s-specific values and their sources

| Value | Where in the file | Source |
|---|---|---|
| `apple,j716s`, model string | `/` | ADT `/product` (`Mac17,8`, "MacBook Pro (16-inch, M5 Pro)") |
| 18 CPUs, `t6050-max.dtsi` unchanged | include | ADT `/cpus` lists cpu0-17 |
| N1 `apple,centauri-platform-id = <0x000c6050>` | `n1_control` | ADT `/chosen board-id = 12` + binding formula |
| N1 `firmware-name = "apple/centauri/j716s-ftab.bin"` | `n1_control` | Inferred from J716c's naming. The file is per unit and must be extracted from this Mac. |
| apcie0 regs / IRQ 1523 / PERST GPIO 80 | `&pcie0` | ADT `/arm-io/apcie0` reg[0,1,16,18,19], interrupts[0]; `pci-bridge0 function-perst` |
| pcIO output templates (AFE reset = output 2) | `&smc_pcio`, `mtp_hid` | ADT `dp2hdmi-gpio0`, `multi-touch function-afe-reset` |
| `apple/tpmtfw-j716s.bin`, power method 2 | `multi-touch` | OURS `t6050-j716s.dts:79,101` |
| ATC0 gadget dwc3 0x2a2280000 / IRQ 1419 / DARTs 1423 | `&die0` | ADT `usb-drd0`, `dart-usb0`; OURS `t6050-storage-net.dtsi:50-88` |
| `fpwm0` 0x505040000, `ps_fpwm0` pmgr1+0x2a8, 25 kHz | `&die0`, `&pmgr1`, `led-controller` | ADT `/arm-io/pwm0`, `kbd-backlight`; OURS `t6050-pmgr.dtsi:952-959` |
| `nub_spmi_a1` 0x28a1a8000 | `&die0` | ADT `/arm-io/nub-spmi-a1` reg[0] |
| hpm1 SID 0x0a (a0), hpm2 SID 0x0c (a1), labels | `J716S_TYPEC_*` blocks | ADT `hpm1`/`hpm2` reg, port-location |
| ATC3 USB off, no a2 | disables | ADT has no `usb-drd3` and no `nub-spmi-a2` |
| `F0md`/`F1md` | `J716S_HWMON` | OURS `t6050-j716s.dts:139-153` |

## Open points before use
- `dtbs_check` the endpoint graph against `apple,t6050-dp-phy.yaml` and `apple,dwc3.yaml` (PLAT). The J813 shape is for `apple,t8142-atcphy`.
- The AOP window differs: ADT reg[2] is 0x2f0000, die0 has 0x1e0000. This matters only when the AOP is enabled.
- The FIFO vs ring MTP transport (see the comment). Our working setup uses ring.
- Nothing here enables the internal DCP. There is no `apple,t6050-dcp` node in any Aurora DT yet.
