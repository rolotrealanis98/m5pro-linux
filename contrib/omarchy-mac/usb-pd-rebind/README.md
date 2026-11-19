# USB-C port controller re-probe at boot

Status: **installed 2026-11-19, stopgap** until the kernel retries the failed read itself.

On 2 of 25 boots (Nov 17 on 7.3.0-gcee93f953357, Nov 19 on 7.3.0-gc1e08542a544) the left port's controller
(`sn201202x 1-0a`, SPMI bus 1) failed its probe: `spmi spmi-1: some frames failed parity check`, then
`failed to read power status: -5` and `probe with driver sn201202x failed with error -22`. That port then has no xHCI,
so nothing plugged into it (a hub, a mouse) shows up. Binding the driver again brings it up at once
(`echo 1-0a > /sys/bus/spmi/drivers/sn201202x/bind`, tested 2026-11-19: hub and Logitech receiver enumerated).

`m5pro-usbpd-rebind.service` runs once at boot and binds any `apple,sn201202x` controller left without a driver,
up to three tries. It does nothing on a boot where every controller probed.

Install: `sudo bash install.sh`. Undo: `sudo bash install.sh --uninstall`.

Kernel fix (next build): the probe's plug-present path turns one failed SPMI read into a permanent probe failure;
it should retry the read, or return `-EPROBE_DEFER`.
