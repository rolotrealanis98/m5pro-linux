#!/bin/bash
# SPDX-License-Identifier: MIT
#
# pmp-readback.sh: read-only readback of the T6050 PMP coprocessor state from a running Linux on
# the 16-inch M5 Pro (J716s), for omacom/linux-aurora #293 (joshuaswarren's "does mBoot start the
# PMP" question, edimoldovan's dart-pmp0 DAPF finding).
#
# Run as root on the MacBook AFTER booting R2-C-usbhost-battery-pmpdapf.bin (or R2-D), whose
# stage-2 m1n1 (v2.0.0-71-gd5b29b03) programs the dart-pmp0 DAPF filter before Linux starts:
#
#   bash pmp-readback.sh --dry-run       print the plan, read nothing
#   bash pmp-readback.sh --gates-only    stage 1 only: the two PMGR power-state registers
#   bash pmp-readback.sh                 stages 1-4 (gates, ASC CPU words, mailbox control, hexdump)
#
# Other options:
#   --no-hexdump           stop after stage 3
#   --hexdump-bytes N      size of the stage-4 dump from the ASC base (default 0x100, max 0x1000)
#   --reader R             busybox | python (default: busybox devmem if it has the applet, else python3)
#   --force-asc            read the ASC window even if the gates are not fully on or the running
#                          m1n1 is not the 0019 build (you accept the risk described in README.md)
#   --out DIR              log root (default /boot/r1-logs; the ESP)
#
# It NEVER writes a device register. Every read is one 32-bit load from a /dev/mem mapping, in its
# own short-lived process, so a synchronous external abort (SIGBUS) only kills that one read.
# An asynchronous SError or a bus hang cannot be caught from userspace: the kernel panics or the
# machine stops. Before each read the address is appended to readback.log and the file is synced,
# so after a hang the last "about to read" line on the ESP names the register that did it.
#
# Addresses (J716s runtime ADT, mBoot-20457.41.2 capture; same as edimoldovan's J714c):
#   PMGR ps  PMP       (ADT gate 27)  0x280600128
#   PMGR ps  PMS_SRAM  (ADT gate 28)  0x280600130
#   PMP ASC  /arm-io/pmp0 reg[0]      0x284e00000 size 0x88000
#     +0x0044 CPU_CONTROL (bit 4 RUN)      +0x0048 CPU_STATUS (bit 0 RUNNING, 1 STOPPED, 5 IDLE)
#     +0x8110 mailbox A2I (inbox) control  +0x8114 mailbox I2A (outbox) control
#   Never read: +0x8800..+0x883f (mailbox message registers; reading the outbox pops its FIFO).
set -u

ASC=0x284e00000
GATE_PMP=0x280600128
GATE_SRAM=0x280600130
EXPECT_M1N1=d5b29b03
ESP_DEV=/dev/nvme0n1p4

MODE=full; HEXDUMP=1; HEXBYTES=0x100; READER=""; FORCE=0; DRY=0; LOGROOT=/boot/r1-logs
while [ $# -gt 0 ]; do
    case "$1" in
        --gates-only) MODE=gates ;;
        --no-hexdump) HEXDUMP=0 ;;
        --hexdump-bytes) HEXBYTES=$2; shift ;;
        --reader) READER=$2; shift ;;
        --force-asc) FORCE=1 ;;
        --dry-run) DRY=1 ;;
        --out) LOGROOT=$2; shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done
HEXBYTES=$((HEXBYTES))
if [ "$HEXBYTES" -le 0 ] || [ "$HEXBYTES" -gt $((0x1000)) ] || [ $((HEXBYTES % 4)) -ne 0 ]; then
    echo "--hexdump-bytes must be a multiple of 4 in 4..0x1000" >&2; exit 2
fi

say() { printf '%s\n' "$*"; }
hex() { printf '0x%x' "$(($1))"; }

# ---------------------------------------------------------------------------- plan
PLAN=()   # "stage|name|address|note"
PLAN+=("1|PMGR ps PMP (gate 27)|$GATE_PMP|power state of the PMP; read by the kernel's pmgr driver too")
PLAN+=("1|PMGR ps PMS_SRAM (gate 28)|$GATE_SRAM|power state of the PMP SRAM")
if [ "$MODE" = full ]; then
    PLAN+=("2|ASC CPU_CONTROL|$(hex "$ASC + 0x44")|bit 4 RUN")
    PLAN+=("2|ASC CPU_STATUS|$(hex "$ASC + 0x48")|bit 0 RUNNING, bit 1 STOPPED, bit 5 IDLE")
    PLAN+=("3|MBOX A2I control|$(hex "$ASC + 0x8110")|bit 0 ENABLE, 16 FULL, 17 EMPTY, 23:20 FIFOCNT")
    PLAN+=("3|MBOX I2A control|$(hex "$ASC + 0x8114")|same layout")
fi

if [ "$DRY" = 1 ]; then
    say "pmp-readback.sh plan (mode $MODE, hexdump $([ "$HEXDUMP" = 1 ] && [ "$MODE" = full ] && hex $HEXBYTES || echo off)); nothing is read:"
    for e in "${PLAN[@]}"; do IFS='|' read -r st nm ad nt <<<"$e"; printf '  stage %s  %-26s %s  %s\n' "$st" "$nm" "$ad" "$nt"; done
    if [ "$MODE" = full ] && [ "$HEXDUMP" = 1 ]; then
        printf '  stage 4  %-26s %s..%s  4-byte reads, stops at the first fault\n' "ASC hexdump" "$ASC" "$(hex "$ASC + $HEXBYTES - 4")"
    fi
    exit 0
fi

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -e /dev/mem ] || { echo "/dev/mem does not exist (CONFIG_DEVMEM=n?)" >&2; exit 1; }

# ---------------------------------------------------------------------------- reader
BB=""
for c in busybox /usr/lib/initcpio/busybox /bin/busybox /usr/bin/busybox; do
    p=$(command -v "$c" 2>/dev/null) || continue
    if "$p" --list 2>/dev/null | grep -qx devmem; then BB=$p; break; fi
done
if [ -z "$READER" ]; then
    if [ -n "$BB" ]; then READER=busybox
    elif command -v python3 >/dev/null 2>&1; then READER=python
    else echo "no reader: neither busybox (with devmem) nor python3 is installed" >&2; exit 1; fi
fi
case "$READER" in
    busybox) [ -n "$BB" ] || { echo "--reader busybox: no busybox with the devmem applet" >&2; exit 1; } ;;
    python) command -v python3 >/dev/null 2>&1 || { echo "--reader python: python3 not found" >&2; exit 1; } ;;
    *) echo "--reader must be busybox or python" >&2; exit 2 ;;
esac

# One 32-bit load. /dev/mem is opened read-only and mapped PROT_READ; for a non-RAM page arm64
# maps it Device-nGnRnE. memoryview.cast("I")[0] is a fixed 4-byte memcpy, compiled to one LDR.
PYRD='import mmap,os,sys
a=int(sys.argv[1],0)
if a%4: sys.exit("unaligned")
pg=mmap.PAGESIZE; base=a&~(pg-1)
fd=os.open("/dev/mem",os.O_RDONLY|os.O_SYNC)
m=mmap.mmap(fd,pg,mmap.MAP_SHARED,mmap.PROT_READ,offset=base)
print("0x%08x"%memoryview(m)[a-base:a-base+4].cast("I")[0],flush=True)'

TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout -s KILL 5"

# ---------------------------------------------------------------------------- log directory
if [ "$LOGROOT" = /boot/r1-logs ] && [ "$(findmnt -n -o FSTYPE -T /boot 2>/dev/null)" != vfat ]; then
    say "/boot is not a vfat mount: mounting $ESP_DEV on /boot"
    mkdir -p /boot && mount -t vfat "$ESP_DEV" /boot 2>&1 || say "WARNING: mounting $ESP_DEV failed"
fi
if ! mkdir -p "$LOGROOT" 2>/dev/null || [ ! -w "$LOGROOT" ]; then
    say "WARNING: cannot write $LOGROOT; using /var/tmp/r1-logs (copy it out by hand)"
    LOGROOT=/var/tmp/r1-logs; mkdir -p "$LOGROOT"
fi
DIR=$LOGROOT/pmp-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$DIR" || exit 1
LOG=$DIR/readback.log; VAL=$DIR/values.tsv; HX=$DIR/hexdump.txt
: > "$LOG"; printf 'stage\tname\taddress\tvalue\tstatus\n' > "$VAL"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }
flush() { sync -f "$LOG" 2>/dev/null || sync; }

# README first, so it exists even if a read hangs the machine.
cat > "$DIR/README.md" <<README
# PMP readback, $(date -u +%Y-%m-%dT%H:%M:%SZ)

Read-only reads through /dev/mem (reader: $READER), one 32-bit load per process. Nothing written.

| stage | register | address | meaning |
|---|---|---|---|
| 1 | PMGR ps PMP (ADT gate 27) | $GATE_PMP | bits 3:0 target, 7:4 actual (0xf on, 0x4 clock-gated, 0x0 off), 8 was-pwrgated, 9 was-clkgated, 10 dev-disable, 11 parent-off, 27:24 auto, 28 auto-enable, 31 reset |
| 1 | PMGR ps PMS_SRAM (ADT gate 28) | $GATE_SRAM | same layout |
| 2 | ASC CPU_CONTROL | $(hex "$ASC + 0x44") | bit 4 RUN (m1n1 ASC_CPU_CONTROL_START) |
| 2 | ASC CPU_STATUS | $(hex "$ASC + 0x48") | bit 0 RUNNING, 1 STOPPED, 5 IDLE (m1n1 proxyclient hw/asc.py) |
| 3 | mailbox A2I (inbox) control | $(hex "$ASC + 0x8110") | bit 0 ENABLE, 16 FULL, 17 EMPTY, 18 OVERFLOW, 23:20 FIFOCNT |
| 3 | mailbox I2A (outbox) control | $(hex "$ASC + 0x8114") | same layout |
| 4 | hexdump | $ASC + 0..$(hex "$HEXBYTES - 4") | 4-byte reads, stops at the first fault |

ASC window: /arm-io/pmp0 reg[0] = 0x284e00000 size 0x88000; mailbox block at ASC + 0x8000 (IRQs
396-399). Never read: ASC + 0x8800..0x883f (mailbox message registers; reading the outbox pops it).

Files: readback.log (every step, "about to read" synced before each load), values.tsv, hexdump.txt,
system.txt (kernel, m1n1 version, cmdline, devmem config, iomem, genpd), dmesg-after.txt.

Status column: ok = value read; SIGBUS = synchronous external abort (no DAPF/permission), the
read was killed and the run continued; TIMEOUT = the reader did not return in 5 s; ERR = other
failure (message in readback.log); SKIP = not attempted (reason in readback.log).
A hang leaves the last "about to read" line in readback.log as the answer.
README
flush

# ---------------------------------------------------------------------------- stage 0 (no MMIO)
{
    echo "== uname"; uname -a
    echo "== m1n1 stage-2 version (/proc/device-tree/chosen)"
    tr -d '\0' < /proc/device-tree/chosen/asahi,m1n1-stage2-version 2>/dev/null; echo
    echo "== firmware (asahi,system-fw-version / asahi,os-fw-version)"
    for f in asahi,system-fw-version asahi,os-fw-version; do tr -d '\0' < "/proc/device-tree/chosen/$f" 2>/dev/null; echo; done
    echo "== cmdline"; cat /proc/cmdline
    echo "== devmem config"
    if [ -r /proc/config.gz ]; then zcat /proc/config.gz | grep -E '^(# )?CONFIG_(DEVMEM|STRICT_DEVMEM|IO_STRICT_DEVMEM|SECURITY_LOCKDOWN_LSM)[ =]'
    else echo "(no /proc/config.gz; build config has DEVMEM=y STRICT_DEVMEM=y IO_STRICT_DEVMEM unset)"; fi
    echo "== lockdown"; cat /sys/kernel/security/lockdown 2>/dev/null || echo "(no lockdown file)"
    echo "== iomem around the PMGR and PMP windows"
    grep -iE '^ *28(06|4[0-9a-e])' /proc/iomem 2>/dev/null || echo "(no matching iomem entries: unclaimed)"
    echo "== genpd (kernel's cached view, no MMIO)"
    grep -E '^(pmp|pms_sram|pms)\b' /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null \
        || echo "(debugfs not mounted or no such domains)"
    echo "== reader"; echo "$READER ${BB:-}"
} > "$DIR/system.txt" 2>&1
M1N1V=$(tr -d '\0' < /proc/device-tree/chosen/asahi,m1n1-stage2-version 2>/dev/null || true)
log "pmp-readback.sh mode=$MODE hexdump=$HEXDUMP/$(hex $HEXBYTES) reader=$READER m1n1=${M1N1V:-unknown} -> $DIR"
flush

# ---------------------------------------------------------------------------- reads
LAST=""; LASTST=""
rd32() { # rd32 STAGE NAME ADDR
    local st=$1 nm=$2 a=$3 out rc
    log "about to read $a ($nm)"; flush
    if [ "$READER" = busybox ]; then out=$($TO "$BB" devmem "$a" 32 2>&1); rc=$?
    else out=$($TO python3 -I -c "$PYRD" "$a" 2>&1); rc=$?; fi
    if [ $rc -eq 0 ] && [[ $out =~ ^0[xX][0-9a-fA-F]+$ ]]; then
        LAST=$(printf '0x%08x' "$out"); LASTST=ok
    elif [ $rc -eq 124 ] || { [ $rc -gt 128 ] && [ "$(kill -l $((rc - 128)) 2>/dev/null)" = KILL ]; }; then
        LAST=-; LASTST=TIMEOUT
    elif [ $rc -gt 128 ] && [ "$(kill -l $((rc - 128)) 2>/dev/null)" = BUS ]; then LAST=-; LASTST=SIGBUS
    else LAST=-; LASTST=ERR; fi
    log "  $nm @ $a = $LAST [$LASTST]$([ "$LASTST" = ERR ] && printf ' rc=%s: %s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$st" "$nm" "$a" "$LAST" "$LASTST" >> "$VAL"; flush
}
skip() { log "  SKIP $2 @ $3: $4"; printf '%s\t%s\t%s\t-\tSKIP\n' "$1" "$2" "$3" >> "$VAL"; flush; }
decode_ps() { local v=$(($1)); printf 'target %x actual %x auto-enable %d dev-disable %d reset %d' \
    $((v & 0xf)) $(((v >> 4) & 0xf)) $(((v >> 28) & 1)) $(((v >> 10) & 1)) $(((v >> 31) & 1)); }

# stage 1: PMGR power-state registers (safest: the kernel's pmgr-pwrstate driver reads these)
GATES_ON=1
for e in "${PLAN[@]:0:2}"; do
    IFS='|' read -r st nm ad nt <<<"$e"
    rd32 "$st" "$nm" "$ad"
    if [ "$LASTST" = ok ]; then
        log "    $(decode_ps "$LAST")"
        [ $(((LAST >> 4) & 0xf)) -eq 15 ] || GATES_ON=0
    else GATES_ON=0; fi
done

ASC_OK=1; WHY=""
if [ "$MODE" = full ]; then
    [ "$GATES_ON" = 1 ] || { ASC_OK=0; WHY="PMP/PMS_SRAM not both actual=0xf"; }
    case "$M1N1V" in *"$EXPECT_M1N1"*) ;; *) ASC_OK=0; WHY="${WHY:+$WHY; }running m1n1 '${M1N1V:-unknown}' is not the 0019 build ($EXPECT_M1N1), so dart-pmp0's DAPF is probably closed" ;; esac
    if [ "$ASC_OK" = 0 ] && [ "$FORCE" = 1 ]; then log "WARNING: $WHY; continuing because of --force-asc"; ASC_OK=1; fi
fi

# stages 2 and 3: ASC CPU words, then mailbox control words
STOP=0
for e in "${PLAN[@]:2}"; do
    IFS='|' read -r st nm ad nt <<<"$e"
    if [ "$ASC_OK" = 0 ]; then skip "$st" "$nm" "$ad" "$WHY"; continue; fi
    if [ "$STOP" = 1 ]; then skip "$st" "$nm" "$ad" "an earlier ASC read failed"; continue; fi
    rd32 "$st" "$nm" "$ad"
    [ "$LASTST" = ok ] || STOP=1
    case "$nm" in
        "ASC CPU_CONTROL") [ "$LASTST" = ok ] && log "    RUN=$(((LAST >> 4) & 1))" ;;
        "ASC CPU_STATUS") [ "$LASTST" = ok ] && log "    RUNNING=$((LAST & 1)) STOPPED=$(((LAST >> 1) & 1)) IDLE=$(((LAST >> 5) & 1))" ;;
        MBOX*) [ "$LASTST" = ok ] && log "    ENABLE=$((LAST & 1)) FULL=$(((LAST >> 16) & 1)) EMPTY=$(((LAST >> 17) & 1)) FIFOCNT=$(((LAST >> 20) & 0xf))" ;;
    esac
done

# stage 4: bounded hexdump of the ASC base (riskiest: unknown registers)
if [ "$MODE" = full ] && [ "$HEXDUMP" = 1 ]; then
    if [ "$ASC_OK" = 0 ] || [ "$STOP" = 1 ]; then
        log "SKIP stage 4 hexdump: ${WHY:-an earlier ASC read failed}"
    else
        printf '# ASC %s, %s bytes, 4-byte reads; "--------" = not read (fault or stopped)\n' "$ASC" "$(hex $HEXBYTES)" > "$HX"
        line=""; fault=0
        for ((o = 0; o < HEXBYTES; o += 4)); do
            a=$(hex "$ASC + $o")
            if [ $fault = 0 ]; then rd32 4 "ASC+$(printf '0x%04x' $o)" "$a"; else LASTST=SKIP; fi
            if [ "$LASTST" = ok ]; then w=${LAST#0x}; else w=--------; fault=1; fi
            [ $((o % 16)) -eq 0 ] && line=$(printf '+%04x:' $o)
            line="$line $w"
            [ $((o % 16)) -eq 12 ] && { printf '%s\n' "$line" >> "$HX"; line=""; }
        done
        [ -n "$line" ] && printf '%s\n' "$line" >> "$HX"
        [ $fault = 1 ] && log "stage 4 stopped at the first failed read; the rest is marked --------"
        flush
    fi
fi

dmesg 2>/dev/null | tail -n 80 > "$DIR/dmesg-after.txt"
log "done. Summary:"
column -t -s $'\t' "$VAL" 2>/dev/null | tee -a "$LOG" || cat "$VAL"
flush
say "logs: $DIR"
