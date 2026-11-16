#!/bin/bash
# Silent bring-up and verification of speakerguardd v2 on the J716s. Run as root ON the machine.
# NOTHING HERE PLAYS A SOUND. The only speaker streams are speakerguardd-selfcheck's own, whose
# samples are all zero (docs/NEW-PLATFORM.md section 6), and every volume read below is a read.
# It never writes a speaker volume, never starts a player, never touches speakersafetyd's lock.
#
#   sgv2-silent-check.sh pre              read only: kernel, device tree, controls, no audio clients
#   sgv2-silent-check.sh install DIR      pacman -U the packages in DIR, install the drop-ins and the UCM, no boot enable
#   sgv2-silent-check.sh seed             seat user's voicing sink first-start volume = 0, muted (before the switch)
#   sgv2-silent-check.sh check            aurora-speaker-upgrade --check (silent switch test), amp volumes watched
#   sgv2-silent-check.sh switch           aurora-speaker-upgrade run: moves the interface to v2 (only after a PASS of check)
#   sgv2-silent-check.sh verify           gate, services, interface, amp volumes, UCM, WirePlumber graph, telemetry header
#   sgv2-silent-check.sh undo             back to the kernel's legacy interface and the boot unit off
#
# Every step prints "RESULT <step> PASS|FAIL|INFO|SKIP: detail" and appends it to $OUT/results.txt; the raw output of
# each command is in $OUT/. Exit status 0 when no step of the subcommand FAILed. Bounded: every command has a timeout.
# The kernel's per-machine ceiling is SN012776_DB(-30) = raw 141 (0 dB is raw 201, 0.5 dB a step; macaudio.c).
CARD=AppleJ716
CEIL_RAW=141
OUT=${SGV2_OUT:-/root/speakers-silent}
mkdir -p "$OUT"
FAILS=0
res() { printf 'RESULT %s %s: %s\n' "$1" "$2" "$3" | tee -a "$OUT/results.txt"; [ "$2" = FAIL ] && FAILS=$((FAILS+1)); return 0; }
run() { # run NAME TIMEOUT cmd... : output to $OUT/NAME.txt, status in $RC
    local n=$1 t=$2; shift 2
    timeout -s KILL "$t" "$@" >"$OUT/$n.txt" 2>&1; RC=$?
}
hex() { od -An -tx1 -v "$1" 2>/dev/null | tr -s ' \n' ' ' | sed 's/^ //;s/ $//'; }

# "name max value" of every amp Speaker Volume and Amp Gain Volume control, from one amixer dump
amp_controls() {
    amixer -c "$CARD" contents 2>/dev/null | awk '
        /^numid=/ { name=$0; sub(/.*name=./,"",name); sub(/.$/,"",name); max=""; next }
        /; type=/ { m=$0; if (match(m,/max=[0-9]+/)) max=substr(m,RSTART+4,RLENGTH-4); next }
        /^  : values=/ { v=$0; sub(/.*values=/,"",v); if (name ~ /(Speaker Volume|Amp Gain Volume)$/) print name "|" max "|" v }'
}

seat_user() {
    local u
    u=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4=="seat0"{print $3}' | /usr/bin/grep -vx root | head -1)
    [ -z "$u" ] && u=$(awk -F: '$3>=1000 && $3<60000 && $7 !~ /nologin|false/ {print $1}' /etc/passwd | head -1)
    echo "$u"
}
as_user() { # as_user USER cmd... : run in the user's session bus/runtime dir
    local u=$1 uid; shift
    uid=$(id -u "$u")
    timeout -s KILL 30 runuser -u "$u" -- env XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus "$@"
}

pre() {
    res kernel INFO "$(uname -r), cmdline: $(cat /proc/cmdline)"
    [ -e /proc/asound/$CARD ] && res card PASS "/proc/asound/$CARD exists" || res card FAIL "no $CARD card"
    amixer -c "$CARD" contents > "$OUT/amixer-contents-pre.txt" 2>&1
    # device tree: speaker id, unit identity, amp levels, transport, card compatible
    if [ -e /proc/device-tree/chosen/asahi,speaker-id ]; then
        sid=$(hex /proc/device-tree/chosen/asahi,speaker-id)
        case $sid in
            "00 00 00 00"|"00 00 00 03") res speaker-id PASS "/chosen/asahi,speaker-id = $sid (the ADT's valid ids are 0 and 3)";;
            *) res speaker-id INFO "/chosen/asahi,speaker-id = $sid (65535 = 00 00 ff ff is the invalid strap): the check says whether AID41 needs it";;
        esac
    else
        res speaker-id INFO "no /chosen/asahi,speaker-id (this loader does not export it). Not a FAIL: only an AID whose tuning selects by speaker ID needs it; 'check' refuses with SpeakerIdUnknown if AID41 does. It is never guessed or faked"
    fi
    [ -s /proc/device-tree/serial-number ] && res unit-serial PASS "/proc/device-tree/serial-number present ($(wc -c < /proc/device-tree/serial-number) bytes; value not printed)" \
        || res unit-serial FAIL "no serial-number in the device tree: the bundle cannot be bound to this unit"
    for f in $(find /proc/device-tree -name 'apple,speaker-config' 2>/dev/null | sort); do
        n=$(tr -d '\0' < "$(dirname "$f")/sound-name-prefix" 2>/dev/null)
        res amp-level INFO "$n: apple,speaker-config = $(hex "$f") (second byte 0f = level 15 = macOS's 18.5 dBV; 0a = the old bring-up DT)"
    done
    res sound-compatible INFO "$(tr '\0' ' ' < /proc/device-tree/sound/compatible 2>/dev/null)"
    # kernel interface and volumes
    amixer -c "$CARD" cget name='Speaker Protection Interface' > "$OUT/iface-pre.txt" 2>&1
    if /usr/bin/grep -q "Speaker Protection" "$OUT/iface-pre.txt"; then
        res interface PASS "dual interface kernel: $(/usr/bin/grep -E ': values=|Item #' "$OUT/iface-pre.txt" | tr '\n' ' ')"
    else
        res interface FAIL "no 'Speaker Protection Interface' control (v2 needs it): $(head -2 "$OUT/iface-pre.txt" | tr '\n' ' ')"
    fi
    bad=0; n=0
    while IFS='|' read -r name max val; do
        n=$((n+1))
        case $name in *"Speaker Volume") [ "${max:-999}" -le "$CEIL_RAW" ] || bad=$((bad+1));; esac
        res amp-control INFO "$name: max=$max value=$val"
    done < <(amp_controls)
    [ "$n" -ge 12 ] && [ "$bad" = 0 ] && res ceiling-pre PASS "$n amp controls, every Speaker Volume max <= $CEIL_RAW (-30 dB)" \
        || res ceiling-pre FAIL "$n amp controls read, $bad Speaker Volume with max > $CEIL_RAW or too few controls"
    # who could play
    for u in speakersafetyd speakerguardd speakerguardd-v2; do
        res service INFO "$u: $(systemctl is-active $u.service 2>&1) / $(systemctl is-enabled $u.service 2>&1)"
    done
    if timeout 10 fuser /dev/snd/* >"$OUT/fuser-pre.txt" 2>&1 && [ -s "$OUT/fuser-pre.txt" ]; then
        res audio-clients INFO "processes with /dev/snd open: $(tr -s ' \n' ' ' < "$OUT/fuser-pre.txt" | head -c 300)"
    else
        res audio-clients PASS "nothing holds /dev/snd"
    fi
    u=$(seat_user)
    if [ -n "$u" ] && [ -S /run/user/$(id -u "$u")/pipewire-0 ]; then
        as_user "$u" pw-dump > "$OUT/pw-dump-pre.json" 2>&1
        python3 -I - "$OUT/pw-dump-pre.json" <<'EOF'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception as e: print("RESULT audio-streams INFO: pw-dump unreadable:", e); sys.exit()
run = [o["info"]["props"].get("node.name") for o in d if o.get("type") == "PipeWire:Interface:Node"
       and "Stream/Output/Audio" in (o["info"]["props"].get("media.class") or "") and o["info"].get("state") == "running"]
print("RESULT audio-streams", "FAIL" if run else "PASS", ": running playback streams:", run or "none")
EOF
    else
        res audio-streams INFO "no PipeWire session of the seat user ($u)"
    fi
    modprobe phram 2>/dev/null; /usr/bin/grep -q adt /proc/mtd && res adt PASS "adt MTD partition: $(/usr/bin/grep adt /proc/mtd)" \
        || res adt FAIL "no adt MTD partition after modprobe phram (pass --adt FILE to aurora-speaker-upgrade, a dd of the ADT)"
    # what the loader said about the speaker ID strap and the amp configuration (its stage 2 log is an MTD too)
    ml=$(awk -F'[: "]+' '/m1n1_stage2.log/ {print $1}' /proc/mtd | head -1)
    if [ -n "$ml" ]; then
        timeout 20 strings -a "/dev/${ml}ro" 2>/dev/null | /usr/bin/grep -E "kboot: audio" > "$OUT/loader-audio.txt"
        res loader-audio INFO "$(tr '\n' '|' < "$OUT/loader-audio.txt" | head -c 700)"
    else res loader-audio INFO "no m1n1_stage2.log MTD"; fi
    command -v sox >/dev/null && res sox INFO "sox present (MORNING.md needs it for the test signals)" || res sox INFO "sox missing: pacman -S sox before the morning"
    echo "seat user: ${u:-none}" | tee -a "$OUT/results.txt"
}

install_pkgs() {
    local d=${1:?directory with the three packages}
    # No `pacman -S`, no database sync: the owner decides on -Syu. Only report what is missing.
    miss=""; for p in python alsa-utils pipewire lilv util-linux systemd; do pacman -Q "$p" >/dev/null 2>&1 || miss="$miss $p"; done
    res deps INFO "$(pacman -Q python alsa-utils pipewire lilv util-linux 2>&1 | tr '\n' ' ')"
    [ -z "$miss" ] && res deps-missing PASS "every runtime dependency is installed" || res deps-missing FAIL "not installed:$miss (nothing was installed; the owner decides)"
    run pacman-U 300 pacman -U --noconfirm "$d"/lzfse-*.pkg.tar.* "$d"/speakerguardd-v2-*.pkg.tar.* "$d"/aurora-speaker-upgrade-*.pkg.tar.*
    [ $RC = 0 ] && res packages PASS "$(pacman -Q lzfse speakerguardd-v2 aurora-speaker-upgrade | tr '\n' ' ')" || res packages FAIL "pacman -U: $(tail -3 "$OUT/pacman-U.txt" | tr '\n' ' ')"
    here=$(cd "$(dirname "$0")" && pwd)
    # UCM (../install.sh), then the v2 drop-ins without enabling the boot unit
    if [ -f "$here/../install.sh" ]; then cd "$here/.." && run ucm-install 60 sh ./install.sh; else RC=99; echo "no $here/../install.sh (copy the whole audio/ folder)" > "$OUT/ucm-install.txt"; fi; [ $RC = 0 ] && res ucm PASS "UCM installed" || res ucm FAIL "install.sh: $(tail -2 "$OUT/ucm-install.txt" | tr '\n' ' ')"
    cd "$here" && SGV2_NO_ENABLE=1 run drop-ins 60 sh ./install.sh; [ $RC = 0 ] && res drop-ins PASS "drop-ins installed, boot unit not enabled" || res drop-ins FAIL "$(tail -2 "$OUT/drop-ins.txt" | tr '\n' ' ')"
    systemctl is-enabled aurora-speaker-upgrade.service > "$OUT/boot-unit.txt" 2>&1
    res boot-unit INFO "aurora-speaker-upgrade.service: $(cat "$OUT/boot-unit.txt")"
    # the gate before anything has run: it must name legacy or none, and speakersafetyd must be held
    run gate-before 30 /usr/lib/speakerguardd-v2/speakerguardd-gate explain
    res gate-before INFO "$(tr '\n' ' ' < "$OUT/gate-before.txt" | head -c 400)"
    # v2 builds its own voicing graph and owns hw:AppleJ716,1: the staged J616s-derived WirePlumber fragment must go
    # (kept as .j716-ab-orig). --no-restart: nothing is restarted, it takes effect when the session's WirePlumber next starts.
    # (the j716-audio-ab on the machine may predate its `v2` verb, so do what it does here)
    WP=/usr/share/wireplumber/wireplumber.conf.d/99-asahi-j716.conf
    if [ -e "$WP" ]; then
        [ -e "$WP.j716-ab-orig" ] || cp -a "$WP" "$WP.j716-ab-orig"
        rm -f "$WP"; res graph-fragment PASS "removed $WP (kept as $WP.j716-ab-orig); takes effect when the session's WirePlumber next starts"
    else res graph-fragment PASS "$WP already absent"; fi
    systemctl daemon-reload
    run sakd-hold 10 systemctl show speakersafetyd.service -p ExecCondition
    /usr/bin/grep -q j716 "$OUT/sakd-hold.txt" && res speakersafetyd-hold PASS "the hold drop-in is loaded" || res speakersafetyd-hold FAIL "hold drop-in not in speakersafetyd's ExecCondition"
}

seed() {
    u=$(seat_user)
    [ -z "$u" ] && { res seed SKIP "no seat user"; return; }
    home=$(getent passwd "$u" | cut -d: -f6); uid=$(id -u "$u"); gid=$(id -g "$u")
    d=$home/.local/state/speakerguardd
    install -d -m0700 -o "$uid" -g "$gid" "$home/.local" "$home/.local/state" "$d" 2>/dev/null
    printf '{"channelVolumes": [0.0, 0.0], "mute": true}\n' > "$d/voicing-j716.json"
    chown "$uid:$gid" "$d/voicing-j716.json"; chmod 0600 "$d/voicing-j716.json"
    res seed PASS "$d/voicing-j716.json = volume 0, muted: the first voicing sink the session builds starts there (the default would be 30 %)"
}

# poll the amp volumes while a command runs; FAIL if any value or max ever exceeds the ceiling
watch_amps() { # watch_amps STOPFILE
    local mx=0 seen=0 over=0 line
    while [ ! -e "$1" ]; do
        while IFS='|' read -r name max val; do
            case $name in *"Speaker Volume")
                v=${val%%,*}; v=${v:-0}
                seen=$((seen+1))
                [ "$v" -gt "$mx" ] && mx=$v
                [ "$v" -gt "$CEIL_RAW" ] && over=$((over+1))
                [ "${max:-0}" -gt "$CEIL_RAW" ] && over=$((over+1));;
            esac
        done < <(amp_controls)
        sleep 0.15
    done
    echo "$seen $mx $over" > "$1"
}

check() {
    install -d -m0755 /etc/speakerguardd
    stop=$OUT/watch.stop; rm -f "$stop"
    watch_amps "$stop" & W=$!
    run check 900 aurora-speaker-upgrade --check --json "$OUT/check.json"; crc=$RC
    : > "$stop"; wait $W 2>/dev/null
    read -r seen mx over < "$stop"
    [ "$over" = 0 ] && [ "$seen" -gt 0 ] && res ceiling-during-check PASS "$seen amp-volume reads while the self-check ran, highest raw value $mx (ceiling $CEIL_RAW = -30 dB), none over" \
        || res ceiling-during-check FAIL "$seen reads, highest $mx, $over over the ceiling (or no reads)"
    journalctl -k -b --no-pager 2>/dev/null | /usr/bin/grep -iE "speaker protection|speaker volume|speaker floor|tas2764|sn012776|fault|over-?(current|temp)" > "$OUT/kernel-speaker-lines.txt"
    res kernel-grants INFO "$(/usr/bin/grep -ci 'protection granted' "$OUT/kernel-speaker-lines.txt") grants, $(/usr/bin/grep -ci 'withdrawn' "$OUT/kernel-speaker-lines.txt") withdrawals logged (the self-check's own: zero samples)"
    if /usr/bin/grep -iE "over-?(current|temp)|clock error|latch|crit" "$OUT/kernel-speaker-lines.txt" >"$OUT/kernel-faults.txt"; then
        res amp-faults FAIL "$(head -3 "$OUT/kernel-faults.txt" | tr '\n' ' ')"
    else res amp-faults PASS "no amp fault line"; fi
    python3 -I - "$OUT/check.json" <<'EOF' | tee -a "$OUT/results.txt"
import json, sys
try: j = json.load(open(sys.argv[1]))
except Exception as e: print("RESULT check-json INFO: no JSON:", e); sys.exit()
for s in j.get("steps", []):
    print("RESULT check-step", {"pass":"PASS","refused":"INFO","cannot-run":"INFO"}.get(s["result"], "INFO"), f'{s["name"]}: {s["result"]} {s.get("detail","")[:300]}')
print("RESULT check-facts INFO: board", j.get("board"), "AID", j.get("acoustic_id"), "route", j.get("route"), "macOS build", j.get("macos_build"),
      "speaker_id", j.get("speaker_id"), "from", j.get("speaker_id_from"), "kernel_interface", j.get("kernel_interface"))
EOF
    case $crc in
        0) res check PASS "aurora-speaker-upgrade --check passed: macOS tuning read, compiled, parity attested, silent switch test passed";;
        1) res check FAIL "REFUSED (the safe outcome, speakers stay at the floor): $(tail -3 "$OUT/check.txt" | tr '\n' ' ')";;
        2) res check FAIL "cannot run: $(tail -3 "$OUT/check.txt" | tr '\n' ' ')";;
        *) res check FAIL "error rc=$crc: $(tail -3 "$OUT/check.txt" | tr '\n' ' ')";;
    esac
    return 0
}

switch_v2() {
    install -d -m0755 /etc/speakerguardd           # speakerguardd#186: the switch must not create it 0700
    seed
    run switch 1200 aurora-speaker-upgrade run --i-understand-preview; src=$RC
    chmod 0755 /etc/speakerguardd
    [ $src = 0 ] && res switch PASS "switched to v2: $(tail -2 "$OUT/switch.txt" | tr '\n' ' ')" || res switch FAIL "rc=$src: $(tail -4 "$OUT/switch.txt" | tr '\n' ' ')"
}

verify() {
    run gate 30 /usr/lib/speakerguardd-v2/speakerguardd-gate explain
    res gate INFO "$(tr '\n' ' ' < "$OUT/gate.txt" | head -c 500)"
    run status 60 aurora-speaker-upgrade status
    res upgrade-status INFO "$(tr '\n' ' ' < "$OUT/status.txt" | head -c 500)"
    for u in speakerguardd-v2 speakerguardd-v2-provision speakerguardd-v2-selfcheck speakerguardd-v2-switchtest; do
        res unit INFO "$u: $(systemctl is-active $u.service 2>&1)"
    done
    [ "$(systemctl is-active speakerguardd-v2.service)" = active ] && res supervisor PASS "speakerguardd-v2.service active" || res supervisor FAIL "speakerguardd-v2.service is not active"
    [ "$(systemctl is-active speakersafetyd.service)" = active ] && res speakersafetyd FAIL "speakersafetyd is running" || res speakersafetyd PASS "speakersafetyd not running"
    amixer -c "$CARD" cget name='Speaker Protection Interface' > "$OUT/iface-post.txt" 2>&1
    res interface INFO "$(/usr/bin/grep -E ': values=|Item #' "$OUT/iface-post.txt" | tr '\n' ' ') (expect the lease, 'Speaker Protection', as the current item)"
    # the kernel's ceiling and the amps' operating point, read-only
    bad=0; n=0; gains=""; vals=""
    while IFS='|' read -r name max val; do
        n=$((n+1))
        case $name in
            *"Speaker Volume") [ "${max:-999}" -le "$CEIL_RAW" ] || bad=$((bad+1)); [ "${val%%,*}" -le "$CEIL_RAW" ] || bad=$((bad+1)); vals="$vals ${val%%,*}";;
            *"Amp Gain Volume") gains="$gains ${val%%,*}/max$max";;
        esac
    done < <(amp_controls)
    [ "$n" -ge 12 ] && [ "$bad" = 0 ] && res ceiling PASS "every amp Speaker Volume max and value <= $CEIL_RAW (-30 dB); values:$vals" \
        || res ceiling FAIL "$bad over the ceiling among $n controls; values:$vals"
    res amp-gain INFO "Amp Gain Volume value/max per amp:$gains (v2 grants only when each reads back level 15)"
    # UCM
    run ucm 20 alsaucm -c "hw:$CARD" list _devices/HiFi
    marker=/run/speakerguardd-graph/speakerguardd-owns-speakers
    devs=$(tr '\n' ' ' < "$OUT/ucm.txt")
    if [ -e $marker ]; then
        echo "$devs" | /usr/bin/grep -qw Speaker && res ucm FAIL "marker present but UCM still offers a Speaker device: $devs" || res ucm PASS "marker present, no Speaker device offered: $devs"
    else
        res ucm INFO "marker $marker absent (graph not provisioned in this boot): devices $devs"
    fi
    # WirePlumber / PipeWire graph of the seat user
    u=$(seat_user)
    if [ -n "$u" ] && [ -S /run/user/$(id -u "$u")/pipewire-0 ]; then
        as_user "$u" pw-dump > "$OUT/pw-dump-post.json" 2>&1
        python3 -I - "$OUT/pw-dump-post.json" <<'EOF' | tee -a "$OUT/results.txt"
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception as e: print("RESULT graph FAIL: pw-dump unreadable:", e); sys.exit()
nodes = [o for o in d if o.get("type") == "PipeWire:Interface:Node"]
names = {o["info"]["props"].get("node.name"): o for o in nodes}
alsa = [n for n in names if "alsa" in n and "J716" in (names[n]["info"]["props"].get("device.name") or n or "")]
print("RESULT graph INFO: sgv2 nodes:", sorted(n for n in names if n and n.startswith("sgv2")))
print("RESULT graph INFO: ALSA nodes of the card:", sorted(a for a in alsa))
v = names.get("sgv2.voicing.j716")
print("RESULT graph-voicing", "PASS" if v else "FAIL", ": sgv2.voicing.j716 sink", "present, state " + str(v["info"].get("state")) if v else "missing")
run = [n for n, o in names.items() if "Stream/Output/Audio" in (o["info"]["props"].get("media.class") or "") and o["info"].get("state") == "running"]
print("RESULT graph-streams", "FAIL" if run else "PASS", ": running playback streams:", run or "none")
if v:
    for p in (v["info"].get("params") or {}).get("Props", []):
        if isinstance(p, dict) and "channelVolumes" in p:
            ok = p.get("mute") or all(x == 0 for x in p["channelVolumes"])
            print("RESULT graph-volume", "PASS" if ok else "FAIL", ": voicing sink channelVolumes", p["channelVolumes"], "mute", p.get("mute"), "(must be muted or 0 for the silent test)")
            break
    else:
        print("RESULT graph-volume INFO: no channelVolumes in the sink's Props yet")
EOF
        # the user-level helper
        as_user "$u" systemctl --user is-active speakerguardd-v2-graph.service speakerguardd-v2-session.service > "$OUT/user-units.txt" 2>&1
        res user-units INFO "$(tr '\n' ' ' < "$OUT/user-units.txt")"
        eng=$(ls /run/speakerguardd/$(id -u "$u")/engine 2>/dev/null)
        if [ -n "$eng" ]; then
            run telemetry 20 python3 -I /usr/local/bin/sgv2-telemetry "$eng"
            res telemetry INFO "$(tr '\n' ' ' < "$OUT/telemetry.txt" | head -c 600) (no signal: 'no telemetry yet' is expected; channels=6 sense=12 is the variant)"
        else
            res telemetry INFO "no engine page under /run/speakerguardd/$(id -u "$u")"
        fi
    else
        res graph SKIP "no PipeWire session for the seat user ($u): log in (or start the user session) and run verify again"
    fi
    journalctl -b --no-pager -u 'speakerguardd-v2*' -u aurora-speaker-upgrade -u speakersafetyd > "$OUT/journal-v2.txt" 2>&1
    res journal INFO "$(/usr/bin/grep -ciE 'refus|panic|fail' "$OUT/journal-v2.txt") refus/fail/panic lines in $OUT/journal-v2.txt: $(/usr/bin/grep -iE 'refus|panic|fail' "$OUT/journal-v2.txt" | tail -3 | cut -c1-200 | tr '\n' '|')"
    journalctl -k -b --no-pager > "$OUT/dmesg-post.txt" 2>&1
    /usr/bin/grep -iE "over-?(current|temp)|clock error|latch|speaker floor not set|safe level not set|crit" "$OUT/dmesg-post.txt" > "$OUT/faults-post.txt"
    [ -s "$OUT/faults-post.txt" ] && res amp-faults FAIL "$(head -3 "$OUT/faults-post.txt" | tr '\n' ' ')" || res amp-faults PASS "no amp fault or floor failure in the kernel log"
    res irq INFO "$(/usr/bin/grep -iE 'tas2764|sn012776|apple-gpio' /proc/interrupts | head -4 | tr -s ' ' | tr '\n' '|')"
}

undo() {
    run revert 600 aurora-speaker-upgrade --revert; res revert INFO "rc=$RC: $(tail -2 "$OUT/revert.txt" | tr '\n' ' ')"
    systemctl disable aurora-speaker-upgrade.service >/dev/null 2>&1
    amixer -c "$CARD" cget name='Speaker Protection Interface' 2>&1 | /usr/bin/grep -E ': values=|Item #' | tr '\n' ' ' | { read -r l; res interface INFO "$l"; }
    res speakersafetyd INFO "$(systemctl is-active speakersafetyd.service)"
}

case ${1:-} in
    pre) pre;; install) install_pkgs "$2";; seed) seed;; check) check;; switch) switch_v2;; verify) verify;; undo) undo;;
    *) sed -n 2,16p "$0"; exit 2;;
esac
echo "STEP ${1} DONE: $FAILS FAIL"
[ "$FAILS" = 0 ]
