# pacman-conf

`pacman.conf.m5pro-snippet` is the `IgnorePkg` line (and the extra repositories) from the MacBook's `/etc/pacman.conf`, with the reason. Merge by hand; there is no installer for it because `/etc/pacman.conf` also holds the mirror layout. The boot guard that backs it up is `contrib/distro/pkg/m5pro-boot/`. Scope `t6050`, status installed, upstream: the pacman platform guard is an Omarchy plug-in point (omacom/omarchy), implemented per Mac in `omarchy-mac-boot`.
