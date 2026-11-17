# omarchy-extras

`omarchy-extras.sh` was run on the MacBook on 2026-11-16 to install the optional Omarchy packages the bring-up skipped (docker, ufw with Omarchy's firewall step, cups, avahi, libreoffice, moonlight, qemu binfmt, systemd-oomd). It was a bench request script; this is the copy of record.

- Scope: `generic`. Status: installed. Upstream: none/personal (Omarchy's installer does these steps itself).
- Install: `ssh root@MACBOOK 'bash -s' < contrib/omarchy-mac/omarchy-extras/omarchy-extras.sh`. It sets a 5-minute firewall dead-man timer: from another machine, confirm SSH still works and run `systemctl stop m5-ufw-deadman.timer`.
- Undo: `systemctl disable --now docker.socket cups.service avahi-daemon.service ufw.service` and `pacman -R` the packages. The script sets `U=rolo` (the desktop user): change it first on another machine.
