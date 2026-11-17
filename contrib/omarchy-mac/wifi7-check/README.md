# wifi7-check

`m5pro-wifi7-check`: a read-only Wi-Fi 7 report for the N1 (`centauri` driver) on the J716s. It prints the kernel, the driver's
capability and link log lines, the US 6 GHz regulatory rule, the wiphy's HE/VHT/EHT capabilities, `iw dev wlan0 link`, the
firmware's own view of the association (debugfs `link_info`: PHY mode, channel width, MLO links) and a count of 6 GHz / EHT /
multi-link BSSes in the scan cache. With a server argument it adds an iperf3 run (4 streams, 20 s, upload then download).

SSIDs, BSSIDs and MAC addresses are filtered out. It starts no scan and touches no connection.

`link_info` exists only on a kernel with the `j716s-wifi7` change (`wifi: apple: centauri: t6050: report the PHY mode, width and
MLO links the firmware joined with`); on other kernels the script says so and prints the rest.

Use (as root on the Mac, or from the Studio):

```sh
sudo m5pro-wifi7-check                 # report
sudo m5pro-wifi7-check 192.0.2.10    # report + iperf3 to a wired iperf3 -s on the home network
ssh root@MAC 'sh -s' < files/usr/local/bin/m5pro-wifi7-check     # without installing
```

Install: `sudo contrib/omarchy-mac/install-item.sh wifi7-check`. Undo: `sudo contrib/omarchy-mac/install-item.sh --remove wifi7-check`.
Test plan this belongs to: `/Volumes/m5pro/bench/requests/wifi7-1.md`.
