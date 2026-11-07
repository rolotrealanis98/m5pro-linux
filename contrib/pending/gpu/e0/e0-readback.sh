#!/bin/bash
# SPDX-License-Identifier: MIT
#
# e0-readback.sh: step E0 of the J716s (16-inch M5 Pro, T6050) GPU plan. Read-only readback of
#   stage 1   PMGR power-state words of the PMP and PMS_SRAM        (as pmp-readback.sh stage 1)
#   stage 1b  the PMP SRAM cold-marker words, 8 x 32 bit            (expect 0xfeed1b00 at +0x7bcd8)
#   stage 1c  the GPU power-domain words GPX / AFR / CS / GFX       (expect GFX 0x0f040300)
# Extends contrib/validated/integration/r1/pmp-readback.sh (not modified). Run as root on a normally
# booted daily kernel (CONFIG_DEVMEM=y). See E0-RUN.md.
#
#   bash e0-readback.sh --dry-run     validate and print the address plan, read nothing
#   bash e0-readback.sh               stages 1, 1b, 1c
#
# Options:
#   --with-asc          also stage 2: ASC CPU_CONTROL / CPU_STATUS (needs the dart-pmp0 DAPF open:
#                       the 0019 m1n1, see PMP-READBACK.md). Off by default.
#   --extra-ps          also stage 1d: the five GFX-adjacent PS words (aic_gfx, pms_gfx_c1ppt,
#                       soc_dpe_gfx, b2b_ctrl_gfx, fppt_gfx at 0x2380600108/110/118/128/198).
#                       Off by default: that block is not otherwise touched by our DT.
#   --reader R          busybox | python (default: busybox devmem if it has the applet, else python3)
#   --force-sram        read the SRAM words even if PMP/PMS_SRAM are not both actual=0xf
#   --force-asc         read the ASC window even if the gates are off or m1n1 is not the 0019 build
#   --out DIR           log root (default /boot/r1-logs; the ESP)
#
# It NEVER writes a device register. Every read is one aligned 32-bit load from a /dev/mem mapping
# (opened read-only, mapped PROT_READ), in its own short-lived process, so a synchronous external
# abort (SIGBUS) only kills that read. An asynchronous SError or bus hang cannot be caught from
# userspace: the kernel panics or the machine stops. Before each read the address is appended to
# readback.log and synced; after a hang the last "about to read" line on the ESP names the culprit.
#
# Guards, all checked BEFORE the first read (also in --dry-run), any failure aborts with exit 3:
#   - every read is exactly 4 bytes, 4-byte aligned, and lies fully inside one ALLOWED window below
#   - the windows are device MMIO from the J716s ADT, all above 0x2_0000_0000 (arm-io), none is RAM
#   - the stage 1b plan is exactly 8 words, 0x7bcc0..0x7bcdc, inside the 1 MiB SRAM window
#   - when /proc/iomem is readable, no read address may fall inside a "System RAM" entry
#   - the reader must return exactly one 32-bit hex token, anything else is ERR
set -u

# ---------------------------------------------------------------------------- constants
# ALLOWED windows (name|base|size|ADT source). Sizes are the ADT sizes where PMP-J716S.md /
# ANALYSIS.md state them, otherwise a narrowed window covering only the registers read here.
WINDOWS=(
 "pmgr-main|0x280600000|0x4000|narrowed: PS regs PMP 0x128, PMS_SRAM 0x130 (ADT gates 27/28, PMP-J716S.md)"
 "pmp-sram|0x284500000|0x100000|pmp0 reg[2], nub region-base/size (PMP-J716S.md)"
 "pmp-asc|0x284e00000|0x88000|pmp0 reg[0] (PMP-J716S.md)"
 "pmgr-gfx|0x2300e80000|0x30000|pmgr reg[51], PS group 3: GPX 0x0 AFR 0x100 CS 0x108 GFX 0x110 (ANALYSIS 1.5)"
 "pmgr-gfx-x|0x2380600000|0x1000|narrowed: the five extra GFX PS words (PMP-J716S.md); --extra-ps only"
)
SRAM=0x284500000
COLD_OFF=0x7bcc0        # first cold-marker word, offset into pmp-sram
COLD_WORDS=8            # 0x7bcc0..0x7bcdc; the t6050/pmp driver checks zeros +0x7bcc0..+0x7bce0
MARKER_OFF=0x7bcd8
MARKER=0xfeed1b00
ASC=0x284e00000
GATE_PMP=0x280600128
GATE_SRAM=0x280600130
GFX_PS_BASE=0x2300e80000
GFX_EXPECT=0x0f040300   # ANALYSIS E0: GFX off, auto
EXPECT_M1N1=d5b29b03
ESP_DEV=/dev/nvme0n1p4

WITH_ASC=0; EXTRA=0; READER=""; FORCE_ASC=0; FORCE_SRAM=0; DRY=0; LOGROOT=/boot/r1-logs
while [ $# -gt 0 ]; do
    case "$1" in
        --with-asc) WITH_ASC=1 ;;
        --extra-ps) EXTRA=1 ;;
        --reader) READER=${2:-}; shift ;;
        --force-asc) FORCE_ASC=1 ;;
        --force-sram) FORCE_SRAM=1 ;;
        --dry-run) DRY=1 ;;
        --out) LOGROOT=${2:-}; shift ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done

say() { printf '%s\n' "$*"; }
hex() { printf '0x%x' "$(($1))"; }
die() { echo "ABORT: $*" >&2; exit 3; }

# ---------------------------------------------------------------------------- plan
# entry: stage|name|address|width|expect|note      (expect: a 32-bit value, or "-" for none)
PLAN=()
add() { PLAN+=("$1|$2|$(hex "$3")|4|$4|$5"); }
add 1 "PMGR ps PMP (gate 27)"        $GATE_PMP  - "power state of the PMP; the kernel's pmgr driver reads it too"
add 1 "PMGR ps PMS_SRAM (gate 28)"   $GATE_SRAM - "power state of the PMP SRAM; stage 1b needs actual=0xf"
for ((i = 0; i < COLD_WORDS; i++)); do
    off=$((COLD_OFF + i * 4)); exp=0x00000000
    [ "$off" -eq $((MARKER_OFF)) ] && exp=$(printf '0x%08x' $((MARKER)))
    add 1b "SRAM+$(hex "$off")" $((SRAM + off)) "$exp" "cold marker region of the t6050/pmp driver"
done
add 1c "PS GPX (group 3 +0x0)"    $((GFX_PS_BASE + 0x0))   -            "ADT critical; no expectation recorded"
add 1c "PS AFR (group 3 +0x100)"  $((GFX_PS_BASE + 0x100)) -            "ADT critical; no expectation recorded"
add 1c "PS CS (group 3 +0x108)"   $((GFX_PS_BASE + 0x108)) -            "parent AFR; no expectation recorded"
add 1c "PS GFX (group 3 +0x110)"  $((GFX_PS_BASE + 0x110)) "$(printf '0x%08x' $((GFX_EXPECT)))" "parents AFR+GPX, notify_pmp, id1 16; ANALYSIS: off, auto"
if [ "$EXTRA" = 1 ]; then
    add 1d "PS aic_gfx"          0x2380600108 - "PMP-J716S.md"
    add 1d "PS pms_gfx_c1ppt"    0x2380600110 - "PMP-J716S.md"
    add 1d "PS soc_dpe_gfx"      0x2380600118 - "PMP-J716S.md"
    add 1d "PS b2b_ctrl_gfx"     0x2380600128 - "PMP-J716S.md"
    add 1d "PS fppt_gfx"         0x2380600198 - "PMP-J716S.md"
fi
if [ "$WITH_ASC" = 1 ]; then
    add 2 "ASC CPU_CONTROL" $((ASC + 0x44)) - "bit 4 RUN; cold = 0"
    add 2 "ASC CPU_STATUS"  $((ASC + 0x48)) - "bit 0 RUNNING, 1 STOPPED, 5 IDLE"
fi

# ---------------------------------------------------------------------------- validation
# System RAM ranges from /proc/iomem (top-level entries only), if readable.
RAMS=()
if [ -r /proc/iomem ]; then
    while read -r lo hi; do RAMS+=("$lo $hi"); done < <(
        awk '/^[0-9a-f]+-[0-9a-f]+ : System RAM/ {split($1,a,"-"); print a[1], a[2]}' /proc/iomem)
fi

validate_plan() {
    local e st nm ad w ex nt win wn wb ws ok r lo hi n1b=0 a
    for e in "${PLAN[@]}"; do
        IFS='|' read -r st nm ad w ex nt <<<"$e"
        [ "$w" = 4 ] || die "unexpected width $w for '$nm' (only 4-byte reads are allowed)"
        a=$((ad))
        [ $((a % 4)) -eq 0 ] || die "'$nm' $ad is not 4-byte aligned"
        [ "$a" -ge $((0x200000000)) ] || die "'$nm' $ad is below arm-io (0x2_0000_0000): could be RAM"
        ok=0
        for win in "${WINDOWS[@]}"; do
            IFS='|' read -r wn wb ws _ <<<"$win"
            if [ "$a" -ge $((wb)) ] && [ $((a + 4)) -le $((wb + ws)) ]; then ok=1; break; fi
        done
        [ $ok = 1 ] || die "'$nm' $ad lies in no allowed ADT device-MMIO window"
        case "$st" in 1b) n1b=$((n1b + 1)); [ "$wn" = pmp-sram ] || die "stage 1b '$nm' is not in the SRAM window" ;; esac
        for r in "${RAMS[@]+"${RAMS[@]}"}"; do
            [ -n "$r" ] || continue
            lo=$((16#${r% *})); hi=$((16#${r#* }))
            if [ "$a" -ge "$lo" ] && [ "$a" -le "$hi" ]; then die "'$nm' $ad is inside System RAM ($r in /proc/iomem)"; fi
        done
    done
    [ "$n1b" -eq "$COLD_WORDS" ] && [ "$COLD_WORDS" -eq 8 ] || die "stage 1b has $n1b words, expected exactly 8"
    [ $((SRAM + COLD_OFF)) -eq $((0x28457bcc0)) ] && [ $((SRAM + MARKER_OFF)) -eq $((0x28457bcd8)) ] \
        || die "SRAM cold-marker addresses do not match ANALYSIS.md (0x28457bcc0, marker 0x28457bcd8)"
    [ $((COLD_OFF + COLD_WORDS * 4)) -le $((0x100000)) ] || die "stage 1b runs past the 1 MiB SRAM window"
}
validate_plan

if [ "$DRY" = 1 ]; then
    say "e0-readback.sh plan (with-asc=$WITH_ASC extra-ps=$EXTRA); validation OK; nothing is read:"
    say "  allowed windows (ADT device MMIO):"
    for win in "${WINDOWS[@]}"; do IFS='|' read -r wn wb ws ws2 <<<"$win"; printf '    %-11s %s + %s  %s\n' "$wn" "$wb" "$ws" "$ws2"; done
    if [ "${#RAMS[@]}" -gt 0 ]; then say "  /proc/iomem System RAM ranges checked: ${#RAMS[@]}"; else say "  /proc/iomem not readable here: RAM-overlap check skipped (it runs on the MacBook)"; fi
    say "  reads (all 32-bit):"
    for e in "${PLAN[@]}"; do
        IFS='|' read -r st nm ad w ex nt <<<"$e"
        printf '    stage %-2s %-26s %-14s expect %-10s %s\n' "$st" "$nm" "$ad" "$ex" "$nt"
    done
    say "  total reads: ${#PLAN[@]}"
    exit 0
fi

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -e /dev/mem ] || { echo "/dev/mem does not exist (CONFIG_DEVMEM=n?)" >&2; exit 1; }
[ ${#RAMS[@]} -gt 0 ] || say "WARNING: no System RAM entries parsed from /proc/iomem; RAM-overlap check skipped"

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

# One 32-bit load: read-only open, PROT_READ mmap of one page; for a non-RAM page arm64 maps it
# Device-nGnRnE. memoryview.cast("I")[0] is a fixed 4-byte copy, compiled to one LDR.
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
DIR=$LOGROOT/e0-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$DIR" || exit 1
LOG=$DIR/readback.log; VAL=$DIR/values.tsv
: > "$LOG"; printf 'stage\tname\taddress\tvalue\texpect\tstatus\tverdict\n' > "$VAL"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }
flush() { sync -f "$LOG" 2>/dev/null || sync; }

# README first, so it exists even if a read hangs the machine.
{
    echo "# E0 readback, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "Read-only 32-bit loads through /dev/mem (reader: $READER). Nothing written. Plan:"
    echo
    echo "| stage | name | address | expect | note |"
    echo "|---|---|---|---|---|"
    for e in "${PLAN[@]}"; do IFS='|' read -r st nm ad w ex nt <<<"$e"; echo "| $st | $nm | $ad | $ex | $nt |"; done
    echo
    echo "Status: ok / SIGBUS (sync external abort) / TIMEOUT / ERR / SKIP. A hang leaves the last"
    echo "'about to read' line in readback.log as the answer. Verdict is the last line of readback.log."
} > "$DIR/README.md"
flush

# ---------------------------------------------------------------------------- stage 0 (no MMIO)
{
    echo "== uname"; uname -a
    echo "== m1n1 stage-2 version"; tr -d '\0' < /proc/device-tree/chosen/asahi,m1n1-stage2-version 2>/dev/null; echo
    echo "== firmware"
    for f in asahi,system-fw-version asahi,os-fw-version; do tr -d '\0' < "/proc/device-tree/chosen/$f" 2>/dev/null; echo; done
    echo "== cmdline"; cat /proc/cmdline
    echo "== devmem config"
    if [ -r /proc/config.gz ]; then zcat /proc/config.gz | grep -E '^(# )?CONFIG_(DEVMEM|STRICT_DEVMEM|IO_STRICT_DEVMEM|SECURITY_LOCKDOWN_LSM)[ =]'
    else echo "(no /proc/config.gz)"; fi
    echo "== lockdown"; cat /sys/kernel/security/lockdown 2>/dev/null || echo "(no lockdown file)"
    echo "== iomem around the windows read"
    grep -iE '^ *(280[0-9a-f]|2845|284e|2300|2380)' /proc/iomem 2>/dev/null || echo "(no matching iomem entries: unclaimed)"
    echo "== genpd (kernel's cached view, no MMIO)"
    grep -E '^(pmp|pms_sram|pms|gpx|afr|cs|gfx)\b' /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null \
        || echo "(debugfs not mounted or no such domains)"
    echo "== reader"; echo "$READER ${BB:-}"
} > "$DIR/system.txt" 2>&1
M1N1V=$(tr -d '\0' < /proc/device-tree/chosen/asahi,m1n1-stage2-version 2>/dev/null || true)
log "e0-readback.sh reader=$READER extra-ps=$EXTRA with-asc=$WITH_ASC m1n1=${M1N1V:-unknown} -> $DIR"
flush

# ---------------------------------------------------------------------------- reads
LAST=""; LASTST=""; LASTV=""
FAULTS=0; SOFT=0; HANG=0; MISMATCH=0   # FAULTS: stage 1/1c (blocks E1); SOFT: 1b/1d/2 (caveat only)
fault_note() { case "$1" in 1|1c) FAULTS=1 ;; *) SOFT=1 ;; esac; }
rd32() { # rd32 STAGE NAME ADDR WIDTH EXPECT
    local st=$1 nm=$2 a=$3 w=$4 ex=$5 out rc v
    [ "$w" = 4 ] || die "unexpected width $w for $nm"
    log "about to read $a ($nm)"; flush
    if [ "$READER" = busybox ]; then out=$($TO "$BB" devmem "$a" 32 2>&1); rc=$?
    else out=$($TO python3 -I -c "$PYRD" "$a" 2>&1); rc=$?; fi
    if [ $rc -eq 0 ] && [[ $out =~ ^0[xX][0-9a-fA-F]{1,8}$ ]]; then
        LAST=$(printf '0x%08x' "$out"); LASTST=ok
    elif [ $rc -eq 124 ] || { [ $rc -gt 128 ] && [ "$(kill -l $((rc - 128)) 2>/dev/null)" = KILL ]; }; then
        LAST=-; LASTST=TIMEOUT; HANG=1
    elif [ $rc -gt 128 ] && [ "$(kill -l $((rc - 128)) 2>/dev/null)" = BUS ]; then LAST=-; LASTST=SIGBUS
    else LAST=-; LASTST=ERR; fi
    LASTV=-
    if [ "$LASTST" = ok ]; then
        if [ "$LAST" = 0xffffffff ]; then LASTV="ALL-ONES"; fault_note "$st"
        elif [ "$ex" = - ]; then LASTV="recorded"
        elif [ $((LAST)) -eq $((ex)) ]; then LASTV=MATCH
        else LASTV=DIFF; MISMATCH=$((MISMATCH + 1)); fi
    else fault_note "$st"; fi
    log "  $nm @ $a = $LAST [$LASTST] expect $ex -> $LASTV$([ "$LASTST" = ERR ] && printf ' rc=%s: %s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$st" "$nm" "$a" "$LAST" "$ex" "$LASTST" "$LASTV" >> "$VAL"; flush
}
skip() { log "  SKIP $2 @ $3: $4"; printf '%s\t%s\t%s\t-\t-\tSKIP\t-\n' "$1" "$2" "$3" >> "$VAL"; flush; }
decode_ps() { local v=$(($1)); printf 'target %x actual %x was-pwrgated %d was-clkgated %d dev-disable %d parent-off %d auto %x auto-enable %d reset %d' \
    $((v & 0xf)) $(((v >> 4) & 0xf)) $(((v >> 8) & 1)) $(((v >> 9) & 1)) $(((v >> 10) & 1)) $(((v >> 11) & 1)) \
    $(((v >> 24) & 0xf)) $(((v >> 28) & 1)) $(((v >> 31) & 1)); }

GATES_ON=1; GATES_READ=1
GPX=-; AFR=-; CS=-; GFX=-; GFXST=-; MARKER_SEEN=-; CPUCTL=-
SRAM_RES=NOTREAD; GFX_RES=NOTREAD
STAGE_STOP=""      # stage name whose remaining entries are skipped
ABORT_ALL=""
for e in "${PLAN[@]}"; do
    IFS='|' read -r st nm ad w ex nt <<<"$e"
    if [ -n "$ABORT_ALL" ]; then skip "$st" "$nm" "$ad" "$ABORT_ALL"; continue; fi
    if [ "$STAGE_STOP" = "$st" ]; then skip "$st" "$nm" "$ad" "an earlier read in stage $st failed"; continue; fi
    # stage gates
    case "$st" in
        1b) if [ "$GATES_ON" = 0 ] && [ "$FORCE_SRAM" = 0 ]; then skip "$st" "$nm" "$ad" "PMP/PMS_SRAM not both actual=0xf (--force-sram to override)"; continue; fi ;;
        2)  why=""
            [ "$GATES_ON" = 1 ] || why="PMP/PMS_SRAM not both actual=0xf"
            case "$M1N1V" in *"$EXPECT_M1N1"*) ;; *) why="${why:+$why; }running m1n1 '${M1N1V:-unknown}' is not the 0019 build ($EXPECT_M1N1): dart-pmp0 DAPF probably closed" ;; esac
            if [ -n "$why" ] && [ "$FORCE_ASC" = 0 ]; then skip "$st" "$nm" "$ad" "$why"; continue; fi ;;
    esac
    rd32 "$st" "$nm" "$ad" "$w" "$ex"
    if [ "$HANG" = 1 ]; then ABORT_ALL="an earlier read timed out (possible fabric hang): not touching more MMIO"; fi
    if [ "$LASTST" != ok ]; then STAGE_STOP=$st; fi
    case "$st" in
        1) if [ "$LASTST" = ok ]; then
               log "    $(decode_ps "$LAST")"
               [ $(((LAST >> 4) & 0xf)) -eq 15 ] || GATES_ON=0
           else GATES_ON=0; GATES_READ=0; fi
           # an ERR in the safest stage means the access path itself is wrong: stop everything
           [ "$LASTST" = ERR ] && ABORT_ALL="stage 1 read failed with ERR: the access path itself is wrong" ;;
        1b) if [ "$LASTST" = ok ] && [ "$nm" = "SRAM+$(hex "$MARKER_OFF")" ]; then MARKER_SEEN=$LAST; fi ;;
        1c) if [ "$LASTST" = ok ]; then
                log "    $(decode_ps "$LAST")"
                case "$nm" in
                    "PS GPX"*) GPX=$LAST ;; "PS AFR"*) AFR=$LAST ;; "PS CS"*) CS=$LAST ;;
                    "PS GFX"*) GFX=$LAST; GFXST=$(((LAST >> 4) & 0xf)) ;;
                esac
            fi ;;
        1d) [ "$LASTST" = ok ] && log "    $(decode_ps "$LAST")" ;;
        2) if [ "$LASTST" = ok ]; then
               case "$nm" in
                   "ASC CPU_CONTROL") CPUCTL=$(((LAST >> 4) & 1)); log "    RUN=$CPUCTL" ;;
                   "ASC CPU_STATUS") log "    RUNNING=$((LAST & 1)) STOPPED=$(((LAST >> 1) & 1)) IDLE=$(((LAST >> 5) & 1))" ;;
               esac
           fi ;;
    esac
done

# ---------------------------------------------------------------------------- verdict
# Stage 1b: all 8 words must be MATCH.
N1B_OK=$(awk -F'\t' '$1=="1b" && $6=="ok" && $7=="MATCH"' "$VAL" | wc -l | tr -d ' ')
N1B_READ=$(awk -F'\t' '$1=="1b" && $6=="ok"' "$VAL" | wc -l | tr -d ' ')
if [ "$N1B_READ" -eq 0 ]; then SRAM_RES=NOTREAD
elif [ "$N1B_OK" -eq "$COLD_WORDS" ]; then SRAM_RES=COLD
else SRAM_RES=NOT-COLD; fi
GFXEXACT=$(awk -F'\t' '$1=="1c" && $2 ~ /^PS GFX/ && $7=="MATCH"' "$VAL" | wc -l | tr -d ' ')
if [ "$GFXST" = - ]; then GFX_RES=NOTREAD
elif [ "$GFXST" = 0 ]; then GFX_RES=$([ "$GFXEXACT" = 1 ] && echo OFF-EXACT || echo OFF-OTHERBITS)
else GFX_RES=ON-or-GATED; fi

log "---- summary"
column -t -s $'\t' "$VAL" 2>/dev/null | tee -a "$LOG" || cat "$VAL"
log "stage1 gates read=$GATES_READ both-on=$GATES_ON | sram-marker=$MARKER_SEEN sram=$SRAM_RES | gfx=$GFX gfx-actual=$GFXST gfx=$GFX_RES | asc-run=$CPUCTL"

# E1 gate (see E0-RUN.md): STOP on any fault/hang/all-ones or unreadable GFX word; otherwise GO,
# with a CAVEAT line for each deviation from the expectation.
if [ "$HANG" = 1 ] || [ "$FAULTS" = 1 ] || [ "$GFX_RES" = NOTREAD ] || [ "$GATES_READ" = 0 ]; then
    VERDICT="STOP: a read faulted, timed out, returned all-ones, or the GFX word was not read; do not go to E1 (see E0-RUN.md)"
else
    VERDICT="GO E1"
    CAV=""
    [ "$SOFT" = 0 ] || CAV="$CAV; a stage 1b/1d/2 read faulted or returned all-ones (see readback.log)"
    [ "$SRAM_RES" = COLD ] || CAV="$CAV; PMP SRAM is $SRAM_RES (marker $MARKER_SEEN)"
    [ "$CPUCTL" = - ] || [ "$CPUCTL" = 0 ] || CAV="$CAV; PMP CPU_CONTROL RUN=1 (PMP already started)"
    [ "$GFX_RES" = OFF-EXACT ] || CAV="$CAV; GFX word is $GFX ($GFX_RES), expected $(printf '0x%08x' $((GFX_EXPECT)))"
    [ -z "$CAV" ] || VERDICT="GO E1 with caveats${CAV}"
fi
log "VERDICT: $VERDICT"
dmesg 2>/dev/null | tail -n 80 > "$DIR/dmesg-after.txt"
flush
say "logs: $DIR"
