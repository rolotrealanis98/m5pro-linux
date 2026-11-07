PCI: apple: Keep T6050 adopted links out of ASPM

[Note for Rolando, delete before sending: HOLD. Needs a J716s boot WITHOUT `pcie_aspm=off` to confirm: the W3b/DAILY-WIFI-T1 recipe (stitched-FTAB initramfs, m1n1 `n1-smc` n1=4, cold start) with this patch on the daily kernel (`git format-patch -1 pr/pcie-apple-adopted-port-aspm` applies to `j716s-series` a83b052e9ffb with a 53-line offset) and `pcie_aspm=off` removed. Pass: dmesg `ASPM: Link Capabilities L0s L1 treated as unsupported` for 0000:00:00.0, `lspci -vv -s 00:00.0` and `01:00.*` LnkCtl `ASPM Disabled`, still up 10 min after login, wlan0 associates. Then delete the "not yet booted" line below. The branch is stacked on #937's head a873be047e9a (which itself no longer merges cleanly into integration/aurora 4114f761f469); alternative: offer the commit to Jeff Queisser for #937 instead of a separate PR.]

On the J716s (MacBook Pro 16-inch, M5 Pro) the N1 Wi-Fi/Bluetooth on the adopted apcie0 port 0 takes the machine down shortly after boot unless ASPM is off. A cold boot with the N1 firmware accepted froze about 30 s after login and the SoC watchdog reset it (W3); the same payload with `pcie_aspm=off` stayed up (W3b), brought up `wlan0` and `hci0`, and in a later boot associated to a WPA2 5 GHz network, got a DHCP lease and passed traffic (17 ms pings). edimoldovan saw the same freeze on the J714c (20-40 s after boot, clean with `pcie_aspm=off` or with the PCIe node disabled) and strips ASPM from adopted root ports in his tree (ab24d156868e on `edimoldovan/linux-aurora` `t6050-j714c`).

This does the same on top of #937: the bus notifier that already strips L1 from cold-initialized tunnel root ports is registered for `adopt_link` hosts too, and there it treats L0s and L1 as unsupported on each root port when the port is added, before the bus behind it is scanned. `pcie_aspm_cap_init()` then finds no common ASPM state and leaves the link alone, which is what `pcie_aspm=off` does globally. Adopted functions do not get the tunnel path's runtime PM reference.

**Tested on:** not yet booted with this patch. Built: `drivers/pci/controller/pcie-apple.o` with `W=1` (LLVM, arm64) on #937's head (CONFIG_RUST off for that build); checkpatch `--strict` clean. The evidence above is from `pcie_aspm=off` boots of the same kernel (#937 included).

**Dependencies:** #937 (adds `adopt_link`); stacked on its head a873be047e9a, only the last commit is new. Without #937 nothing on `integration/aurora` adopts a link.

**Open questions:**
- Per host (every adopted root port, as here) or only when the endpoint is the N1 (106b:1900)? The root port is added before its endpoint is known, so an endpoint check would have to use a FINAL fixup and `pci_disable_link_state()`, after the ASPM core has already configured the link once. The other adopted ports I know of are J775D ports 2 and 3; is ASPM known good there?
- Would you rather have this folded into #937?
- The J714c fix also adds a shutdown that parks the adopted port; on the J716s a restart with the N1 link alive does not come back either (iBoot counts a failed boot). I will send that separately once it is tested here.
