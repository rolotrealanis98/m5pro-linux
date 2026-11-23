#!/bin/busybox sh
# /sbin/init of the QEMU test roots: report where we are and power off
/bin/busybox mount -t proc proc /proc 2>/dev/null
/bin/busybox echo "QEMU-ROOT-REACHED root=$(/bin/busybox sed -n 's/^\([^ ]*\) \/ .*/\1/p' /proc/mounts | /bin/busybox tail -n 1) canary=$(/bin/busybox cat /canary)"
[ -f /var/log/m5-crypt-selftest.log ] && { /bin/busybox echo "-- m5-crypt-selftest.log"; /bin/busybox cat /var/log/m5-crypt-selftest.log; }
/bin/busybox sync; /bin/busybox poweroff -f
