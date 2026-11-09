#!/usr/bin/env python3
"""dcp-rpc-decode.py - decode an hv27-dcp-trace.py (SYNC mode) JSONL capture of the IOMFB RPC conversation.

Usage:
  dcp-rpc-decode.py [capture.jsonl] [--tag D414 --tag A451 ...] [--phase props] [--no-async]
                    [--raw] [--no-acks] [--collapse N] [--dicts] [--summary] [--md-tags] [--phases]

  --tag T        only transactions whose tag is T (repeatable; "A" / "D" prefix-only also works: --tag D4)
  --phase P      only transactions in phase P (boot props publish hw_boot dfb_alloc modes async_start ap_init steady swap)
  --no-async     drop ASYNC / OOBASYNC context traffic (the D300 flood, D204, D006, async D406)
  --raw          add the raw hex of every in/out payload (never truncated beyond the capture's 4096-byte cap)
  --no-acks      do not print ack lines (the out data is then not shown)
  --collapse N   print at most N consecutive transactions that differ only in payload (default 3), then a count line
  --dicts        also print the full decoded DCPAV dictionaries (ColorElements, TimingElements, ...)
  --summary      tag inventory (count, ctx, lengths, name) instead of the conversation
  --md-tags      the tag inventory as a markdown table
  --phases       phase boundaries only
  --pr-table     D300 pr_publish table: property id, count, distinct values, first/last seq

Pure standard library. Nothing here touches hardware.

Record model (see hv/DCP-TRACE-MODULE.md): every record has seq, t, dir (AP>DCP / DCP>AP), kind (call, ack, set_shmem,
init_complete), ctx/ctxn (CB=0 ASYNC_CB=1 CMD=2 ASYNC=3 OOBCB=4 OOBCMD=6 OOBASYNC=7), tag, in_len, out_len and hex
payload capped at 4096 bytes.  A call carries `in`; the ack that completes it carries `out`.

IMPORTANT, found while writing this: the module's `call_seq` on an ack is not always the call that the ack completes.
The firmware, like the Linux driver (iomfb.c dcpep_handle_ack/dcp_ack), keeps one LIFO stack per *context* (CB, CMD,
ASYNC, OOBCB, OOBCMD ...); an ack pops the innermost call of the context it names, whichever direction that call went
(a callback from the DCP and an AP command nested inside it share the CB stack).  This script re-pairs with that rule.
In this capture it differs from the module's call_seq on 6 of 8958 acks (seq 405/406/407/491/661/699); for those the
module also read the ack's out data from the wrong buffer slot, so their out data is marked unreliable.
"""
import argparse
import collections
import json
import struct
import sys

# ----------------------------------------------------------------------------------------------------------------
# Tag knowledge.  name, where it comes from, expected (in,out) length of the layout we know (None = layout unknown).
# Sources: m1n1 = proxyclient/m1n1/fw/dcp/ipc.py (V13_5/V14_7 tables, tags shift per firmware); lx27 = Linux
# iomfb_v27.c tables (27.0 / 27.2 / 27.3) and callback_sizes[]; "obs" = shape seen in this 27.3 capture only.
# ----------------------------------------------------------------------------------------------------------------
# status: C confirmed here (tag and length match a known table entry), S shape only (layout seen, name inferred),
#         U unknown (not in any table)
A_TAGS = {
    "A000": ("late_init_signal", "m1n1 A000 (V13_5+), Linux all tables", (4, 4), "C"),
    "A027": ("setup_video_limits", "Linux 27.0/27.2/27.3 (m1n1 A029)", (0, 0), "C"),
    "A033": ("pipe_cfg_031 (update_notify_clients_dcp)", "Linux 27.x table (m1n1 A034 -1)", (0x6c, 0), "-"),
    "A034": ("is_hilo? (bool query)", "inferred: m1n1 A035 is_hilo, same -1 shift as A036/A037; not in Linux 27 tables", (0, 4), "S"),
    "A035": ("dfb_query / apt_supported? (bool query)", "Linux 27.x dcpep_dfb_query; m1n1 A036 apt_supported -1", (0, 4), "C"),
    "A036": ("get_dfb_info", "Linux 27.x; m1n1 A037 -1", (44, 44), "C"),
    "A037": ("get_dfb_compression_info", "Linux 27.x; m1n1 A038 -1", (8, 8), "C"),
    "A103": ("get_config_frame_size (Linux: get_dfb_layout)", "m1n1 UPPipe2 A103, Linux 27.x", (12, 8), "C"),
    "A104": ("set_config_frame_size (Linux: set_dfb_dimensions)", "m1n1 UPPipe2 A104, Linux 27.x", (8, 0), "C"),
    "A105": ("program_config_frame_size (Linux: commit_dfb_info)", "m1n1 UPPipe2 A105, Linux 27.x", (0, 0), "C"),
    "A135": ("init_ca_pmu? (bool query)", "inferred: m1n1 A130 init_ca_pmu, +5 like A131->A136, A132->A137", (0, 4), "S"),
    "A136": ("pmu_service_matched", "Linux 27.x (m1n1 A131 +5)", (0, 4), "C"),
    "A137": ("backlight_service_matched", "Linux 27.x (m1n1 A132 +5)", (0, 4), "C"),
    "A352": ("pipe_set_352 (applyProperty)", "m1n1 A352, Linux 27.x", None, "-"),
    "A353": ("pipe_query_353 (27.x out is 8 bytes; m1n1 get_system_type returned 4)", "Linux 27.x table name only (Linux never calls it)", (0, 8), "S"),
    "A378": ("UNKNOWN query (in 44 / out 40)", "no table has it; in V14_7 A378 is vi_set_temperature_hint (0/4): different method", (44, 40), "U"),
    "A379": ("UNKNOWN query (0/4, returns 0x7f2600)", "no table has it", (0, 4), "U"),
    "A381": ("UNKNOWN query (0/4)", "no table has it", (0, 4), "U"),
    "A384": ("UNKNOWN OOBCMD query (0/4)", "27.0 table: dfb_ready_query; in 27.2/27.3 that moved to A385", (0, 4), "U"),
    "A385": ("dfb_ready_query", "Linux 27.2/27.3 (inferred in 27.2 commit, now observed)", (0, 4), "C"),
    "A390": ("set_create_DFB", "Linux 27.2/27.3 (27.0: A389; m1n1 A373/A377)", (0, 0), "C"),
    "A391": ("vi_set_temperature_hint", "Linux 27.2/27.3 (27.0: A390; m1n1 A374/A378)", (0, 4), "C"),
    "A400": ("UNKNOWN OOBCMD query (0/4)", "no table has it", (0, 4), "U"),
    "A451": ("start_signal", "Linux 27.2/27.3 (27.0: A401; m1n1 A401)", (0, 4), "C"),
    "A456": ("swap_start", "Linux 27.2/27.3 table (not observed)", (0x10, 8), "-"),
    "A458": ("swap_submit", "Linux 27.2/27.3 table (not observed); 27.3 request 0x1144", None, "-"),
    "A461": ("set_display_device", "Linux 27.2/27.3 table (not observed)", (4, 4), "-"),
    "A462": ("is_main_display", "Linux 27.2/27.3 table (not observed)", (0, 4), "-"),
    "A463": ("set_digital_out_mode", "Linux 27.2/27.3 table (not observed)", (8, 4), "-"),
    "A464": ("pipe_cfg_414", "Linux 27.2/27.3 table (not observed)", (8, 8), "-"),
    "A465": ("pipe_cfg_415", "Linux 27.2/27.3 table (not observed)", (12, 12), "-"),
    "A473": ("set_matrix", "Linux 27.2/27.3 table (not observed)", None, "-"),
    "A477": ("get_color_remap_mode", "Linux 27.2/27.3 table (not observed)", None, "-"),
    "A478": ("set_brightness_correction", "Linux 27.2/27.3 table (not observed)", (4, 4), "-"),
    "A500": ("set_parameter_dcp", "Linux 27.2/27.3 table (not observed)", (0x28, 4), "-"),
    "A503": ("get_display_size (Linux: get_dfb_state)", "Linux 27.2/27.3; m1n1 get_display_size shape (4/8)", (4, 8), "C"),
    "A504": ("do_create_default_frame_buffer", "Linux 27.2/27.3 dcpep_create_default_fb", (0, 4), "C"),
    "A508": ("enable_disable_video_power_savings", "Linux 27.2/27.3 table (not observed)", (4, 4), "-"),
    "A515": ("UNKNOWN command (in 8: u32 0x800, u32 0x20 / out 0)", "no table has it", (8, 0), "U"),
    "A516": ("first_client_open", "Linux 27.2/27.3 table (not observed)", (0, 0), "-"),
    "A517": ("last_client_close", "Linux 27.2/27.3 table (not observed)", None, "-"),
    "A526": ("set_display_refresh_properties", "Linux 27.3 only (27.2: A525)", (0, 4), "C"),
    "A529": ("flush_supports_power", "Linux 27.3 only (27.2: A528; 27.2's A529 is abort_swaps_dcp)", (4, 0), "C"),
    "A530": ("abort_swaps_dcp", "Linux 27.3 table (not observed)", None, "-"),
    "A534": ("register_dfb_surface (m1n1 update_dfb: one IOSurface)", "Linux 27.3 only (27.2: A533; 27.2's A534 is set_power_state)", (560, 4), "C"),
    "A535": ("set_power_state", "Linux 27.3 table (not observed)", (0x10, 8), "-"),
    "A536": ("pipe_query_474", "Linux 27.3 table (not observed)", (0, 4), "-"),
    "A538": ("pipe_set_476", "Linux 27.3 table (not observed)", (4, 0), "-"),
    "A540": ("pipe_query_478", "Linux 27.3 table (not observed)", (0, 4), "-"),
}
# DCP -> AP callbacks. Expected lengths = Linux iomfb_v27.c callback_sizes[] (27.0), m1n1 where noted.
D_TAGS = {
    "D000": ("did_boot_signal", "m1n1 D000, Linux [0]", (0, 4), "C"),
    "D001": ("did_power_on_signal", "m1n1 D001, Linux [1]", (0, 4), "C"),
    "D003": ("rt_bandwidth_setup_ap (H17P reply: 4 in / 20 out)", "Linux [3] (m1n1 V13_5 had 4/60)", (4, 20), "C"),
    "D006": ("set_frame_sync_props (84 in / 80 out)", "Linux [6] (m1n1 V13_5 32/28, V14_7 60/56)", (84, 80), "C"),
    "D100": ("match_pmu_service", "m1n1 D100, Linux [100]", (0, 0), "C"),
    "D101": ("get_display_default_stride (m1n1 UNK_get_some_field)", "m1n1 D101, Linux [101]", (0, 4), "C"),
    "D102": ("set_number_property", "m1n1 D102, Linux [102]", (68, 0), "C"),
    "D104": ("set_boolean_property", "m1n1 V13_5 D104, Linux [104]", (68, 0), "C"),
    "D107": ("create_provider_service", "27.x numbering = m1n1 V13_5 D108 -1 (m1n1 D107 there is removeProperty 64/0); shape 0/4", (0, 4), "S"),
    "D108": ("create_product_service", "= m1n1 V13_5 D109 -1; shape 0/4", (0, 4), "S"),
    "D109": ("create_PMU_service", "= m1n1 V13_5 D110 -1; shape 0/4", (0, 4), "S"),
    "D110": ("create_iomfb_service", "= m1n1 V13_5 D111 -1; shape 0/4", (0, 4), "S"),
    "D111": ("create_backlight_service", "= m1n1 V13_5 D112 -1; Linux [111] create_backlight_service", (0, 4), "C"),
    "D112": ("create_nvram_service", "= m1n1 V13_5 D113 -1; Linux [112] trampoline_true", (0, 4), "S"),
    "D120": ("start_hardware_boot", "m1n1 V13_5 D120, Linux [120] dcpep_cb_boot_1", (0, 4), "C"),
    "D122": ("is_waking_from_hibernate", "m1n1 V13_5 D122, Linux [122]", (0, 4), "C"),
    "D124": ("read_edt_data", "m1n1 V13_5 D124, Linux [124]", (100, 36), "C"),
    "D126": ("setDCPAVPropStart", "m1n1 V13_5 D126, Linux [126]", (4, 4), "C"),
    "D127": ("setDCPAVPropChunk", "m1n1 V13_5 D127, Linux [127] (data[0x1000], offset, length)", (4104, 4), "C"),
    "D128": ("setDCPAVPropEnd", "m1n1 V13_5 D128, Linux [128]", (64, 4), "C"),
    "D201": ("map_buf (piodma)", "m1n1 D201 (12/20); Linux [201] H17P reply 16 bytes", (12, 16), "C"),
    "D204": ("get_ideal_screen_space (new in 27.x)", "Linux [204] trampoline_ideal_screen_space_v27; not in m1n1", (0, 4), "C"),
    "D206": ("match_pmu_service_2", "m1n1 D206, Linux [206]", (0, 4), "C"),
    "D207": ("match_backlight_service", "m1n1 D207, Linux [207]", (0, 4), "C"),
    "D209": ("get_calendar_time_ms (get_time)", "m1n1 V13_5 D209, Linux [209]", (0, 8), "C"),
    "D300": ("pr_publish (id, value, unk0, unk1)", "m1n1 V13_5 D300, Linux [300]", (16, 0), "C"),
    "D400": ("get_property (out 0xc04)", "m1n1 D400 (out 0x204); Linux [400] 0x4c/0xc04", (76, 3076), "C"),
    "D401": ("sr_get_uint_prop", "m1n1 D401, Linux [401]", (80, 12), "C"),
    "D406": ("set_fx_prop", "m1n1 D406, Linux [406]", (72, 0), "C"),
    "D408": ("sr_getClockFrequency", "m1n1 D408, Linux [408]", (8, 8), "C"),
    "D413": ("sr_setProperty_dict", "m1n1 D413, Linux [413]", (4168, 4), "C"),
    "D414": ("sr_setProperty_int", "m1n1 D414, Linux [414]", (80, 4), "C"),
    "D415": ("sr_setProperty_bool", "m1n1 D415, Linux [415]", (76, 4), "C"),
    "D451": ("allocate_buffer (27.x: 20 in / 20 out)", "m1n1 D451 (20/28); Linux [451] dcp_allocate_buffer_{req,resp}_v27", (20, 20), "C"),
    "D552": ("setProperty_dict", "m1n1 D552, Linux [552]", (4164, 4), "C"),
    "D561": ("setProperty_dict", "m1n1 D561, Linux [561]", (4164, 4), "C"),
    "D563": ("setProperty_int", "m1n1 D563, Linux [563]", (76, 4), "C"),
    "D565": ("setProperty_bool", "m1n1 D565, Linux [565]", (72, 4), "C"),
    "D575": ("hotPlug_notify_gated (88 in / 76 out)", "Linux [575] (m1n1 V14_7 D576 -1)", (88, 76), "C"),
    "D586": ("create_default_fb_surface (m1n1 V14_7 D582 +4)", "Linux [586] iomfbep_cb_create_dfb_surface", (8, 4), "C"),
    "D594": ("swap_complete (0x730)", "Linux [594] (not observed)", (0x730, 0), "-"),
    "D603": ("find_swap_function_gated (m1n1 V14_7 D598 +5)", "Linux [603] trampoline_nop 0/0", (0, 0), "C"),
}
TAGDB = dict(A_TAGS)
TAGDB.update(D_TAGS)

CTX = {0: "CB", 1: "ASYNC_CB", 2: "CMD", 3: "ASYNC", 4: "OOBCB", 6: "OOBCMD", 7: "OOBASYNC"}
PHASES = ["boot", "props", "publish", "hw_boot", "dfb_alloc", "modes", "async_start", "ap_init", "steady", "swap"]
PHASE_DOC = {
    "boot": "set_shmem, init_complete, start_signal (A451) and the first service callbacks, up to the first property",
    "props": "property setup: D406/D414/D415/D413 (IOMF objects), D111/D112 services, D575 hotplug",
    "publish": "D300 pr_publish burst (~160 property publications), until the first D100",
    "hw_boot": "D100..D120 start_hardware_boot, with the nested A-calls: create_default_fb, dfb info, setup_video_limits, ...",
    "dfb_alloc": "D451/D201 buffer allocation and piodma mapping (29 buffers, one D451+D201 pair each)",
    "modes": "D104 NormalModeActive .. D122: refresh properties, create_dfb_surface/register_dfb_surface, DCPAV dicts (colour + timing elements)",
    "async_start": "start_signal acked; first ASYNC callbacks (D204 ideal screen space, D006, async D406)",
    "ap_init": "AP-initiated CMD/OOBCMD queries (A515, A400, A353, A384, A379, A378, A391, A136) - no swap, no mode set",
    "steady": "periodic D006 and the D300 id 0x77 flood",
    "swap": "(empty in this capture) from the first A456/A458 on",
}


def u32(b, o=0):
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o=0):
    return struct.unpack_from("<Q", b, o)[0]


def cstr(b):
    return b.split(b"\0")[0].decode("latin1")


def fcc(b):
    """FourCC objects are sent byte-reversed ('IOMF' arrives as 'FMOI')."""
    return b[::-1].decode("latin1")


def hexs(b, n=None):
    return (b if n is None else b[:n]).hex()


# ---------------------------------------------------------------- OSSerialize (DCPAV property blobs, binary format)
def parse_os(b):
    if b[:1] != b"\xd3":
        raise ValueError("no OSSerialize signature")
    pos = 4
    objs = []

    def rd():
        nonlocal pos
        w = struct.unpack_from("<I", b, pos)[0]
        pos += 4
        t = (w >> 24) & 0x7F
        n = w & 0xFFFFFF
        if t in (1,):
            d = {}
            objs.append(d)
            for _ in range(n):
                k = rd()
                d[k] = rd()
            return d
        if t in (2, 3):
            l = []
            objs.append(l)
            for _ in range(n):
                l.append(rd())
            return l
        if t == 4:
            v = int.from_bytes(b[pos:pos + 8], "little")
            pos += 8
            objs.append(v)
            return v
        if t in (8, 9):
            s = b[pos:pos + n].rstrip(b"\0").decode("latin1")
            pos += (n + 3) & ~3
            objs.append(s)
            return s
        if t == 10:
            s = bytes(b[pos:pos + n])
            pos += (n + 3) & ~3
            objs.append(s)
            return s
        if t == 11:
            v = bool(n)
            objs.append(v)
            return v
        if t == 12:
            return objs[n]
        raise ValueError("OSSerialize type %d at %#x" % (t, pos - 4))

    return rd()


# DCP callback dictionaries (D413/D552/D561): d<u32 count>(key value)*, s<u32 len>chars\0, n<u64>, a<u32 count>values
def parse_osd(b):
    pos = 0

    def rd():
        nonlocal pos
        tag = chr(b[pos])
        pos += 1
        if tag == "d":
            n = u32(b, pos)
            pos += 4
            d = {}
            for _ in range(n):
                k = rd()
                d[k] = rd()
            return d
        if tag == "a":
            n = u32(b, pos)
            pos += 4
            return [rd() for _ in range(n)]
        if tag == "n":
            v = u64(b, pos)
            pos += 8
            return v
        if tag == "s":
            n = u32(b, pos)
            pos += 4
            s = b[pos:pos + n].decode("utf-8", "replace")
            pos += n + 1
            return s
        raise ValueError("unknown dict tag %r at %d" % (tag, pos - 1))

    return rd()


def brief(o, limit=700):
    def conv(x):
        if isinstance(x, bytes):
            return x.hex()
        if isinstance(x, dict):
            return {k: conv(v) for k, v in x.items()}
        if isinstance(x, list):
            return [conv(v) for v in x]
        return x
    s = json.dumps(conv(o), separators=(",", ":"))
    return s if len(s) <= limit else s[:limit] + "...(+%d chars)" % (len(s) - limit)


# ---------------------------------------------------------------- field decoders: each returns a list of lines
def need(b, n):
    return len(b) >= n


def d_bool_in(inb, outb):
    return ["in: %s" % ("true" if inb[:1] == b"\x01" else "false (%s)" % hexs(inb[:4]))] if inb else []


def retbool(outb):
    return "ret=%s" % ("true" if outb[:1] == b"\x01" else ("false" if outb[:1] == b"\x00" else "?" + hexs(outb[:4])))


def dec_prop_int(tag, inb, outb):
    if tag == "D414":
        return ["IOMF-obj %s key %r = %d (%#x)" % (fcc(inb[:4]), cstr(inb[4:68]), u64(inb, 68), u64(inb, 68))]
    if tag == "D563":
        return ["key %r = %d (%#x)" % (cstr(inb[:64]), u64(inb, 64), u64(inb, 64))]
    if tag == "D406":
        v = u32(inb, 68)
        return ["obj %s key %r = %d (%#x; as 16.16 = %.4f)" % (fcc(inb[:4]), cstr(inb[4:68]), v, v, v / 65536)]
    return []


def dec_prop_bool(tag, inb, outb):
    if tag == "D415":
        return ["obj %s key %r = %d" % (fcc(inb[:4]), cstr(inb[4:68]), u32(inb, 68))]
    if tag == "D565":
        return ["key %r = %d" % (cstr(inb[:64]), u32(inb, 64))]
    return []


def dec_prop_dict(tag, inb, outb):
    o = 4 if tag == "D413" else 0
    obj = ("obj %s " % fcc(inb[:4])) if tag == "D413" else ""
    key = cstr(inb[o:o + 64])
    blob = inb[o + 64:o + 64 + 4096]
    try:
        val = parse_osd(blob)
        return ["%skey %r = %s" % (obj, key, brief(val))]
    except Exception as e:
        return ["%skey %r: value did not parse (%s); raw %s" % (obj, key, e, hexs(blob, 96))]


PR_NAMES = {
    20: "panel level (Linux 27.x H17P 'case 20': value / Brightness_Scale = nits)",
    0x77: "unknown, ASYNC flood, constant 0x10000",
}


def dec_pr_publish(inb, outb):
    pid, val, a, b2 = struct.unpack_from("<IiII", inb, 0)
    s = "id %d (%#x) value %d (%#x) unk0 %#x unk1 %#x" % (pid, pid, val, val & 0xFFFFFFFF, a, b2)
    if pid in PR_NAMES:
        s += "  <- " + PR_NAMES[pid]
    if pid == 20:
        s += "  = %.3f nits at Brightness_Scale 0x10000" % ((val & 0xFFFFFFFF) / 65536)
    elif (val & 0xFFFFFFFF) == 0x6400000:
        s += "  (= 1600.0 as 16.16; meaning not in any table)"
    return [s]


def dec_get_uint(inb, outb):
    s = "obj %s key %r in-value %#x" % (fcc(inb[:4]), cstr(inb[4:68]), u64(inb, 68))
    return [s]


def dec_get_uint_out(outb):
    return ["out: value %#x ret %d" % (u64(outb, 0), outb[8])]


def dec_d400(inb, outb):
    return ["obj %s key %r length %d (data_null=%d length_null=%d)" % (fcc(inb[:4]), cstr(inb[4:68]), u32(inb, 68), inb[72], inb[73])]


def dec_d400_out(outb):
    if len(outb) >= 0xC04:
        ln = u32(outb, 0xC00)
        return ["out: length field %d, first bytes %s (rest of the 0xc00 data area is stale buffer)" % (ln, hexs(outb[:16]))]
    return []


def dec_hotplug(inb, outb):
    conn = u64(inb, 0)
    td = inb[8:8 + 0x4C]
    nz = any(td)
    return ["connected=%d tiled_display[0x4c] %s null=%d" % (conn, "all zero" if not nz else hexs(td), inb[8 + 0x4C])]


def dec_edt(inb, outb):
    return ["key %r count %d value[0..7] %s" % (cstr(inb[:64]), u32(inb, 64), [u32(inb, 68 + 4 * i) for i in range(8)])]


def dec_edt_out(outb):
    return ["out: value[0] %d (value[1..] stale), ret %d" % (u32(outb, 0), outb[32])]


def dec_alloc(inb, outb):
    o, sz, al = struct.unpack_from("<IQI", inb, 0)
    return ["options %#x size %#x alignment/flags %#x dva_null %d capacity_null %d" % (o, sz, al, inb[16], inb[17])]


def dec_alloc_out(outb):
    dva, cap, mid = struct.unpack_from("<QQI", outb, 0)
    return ["out: dva %#x capacity %#x mem_desc_id %d" % (dva, cap, mid)]


def dec_map(inb, outb):
    buf, unk = struct.unpack_from("<QB", inb, 0)
    return ["buffer(mem_desc_id) %d unk %d nulls %s" % (buf, unk, hexs(inb[9:12]))]


def dec_map_out(outb):
    buf, dva, unk = struct.unpack_from("<IQI", outb, 0)
    return ["out: buffer %d dva %#x unk %d" % (buf, dva, unk)]


def dec_clock(inb, outb):
    return ["obj %s clock id %d" % (fcc(inb[:4]), u32(inb, 4))]


def dec_clock_out(outb):
    return ["out: %d Hz" % u64(outb, 0)]


def dec_dfb_info_out(outb):
    fmt = u32(outb, 0)
    a, b2 = u64(outb, 4), u64(outb, 12)
    return ["out: format fourcc %r (%#x); word@4 u64 %#x; word@12 u64 %#x (second - first = %#x = plane0 size 3456*2234*4 rounded to 16K, so these look like"
            " the RGB10 and A8 plane DVAs of the default framebuffer); u32@28 %#x (=3456*4 stride); u32@32 %d (width); u32@36 %d; flag@0x28 %d (Linux: dfb_format_valid)" % (
                struct.pack("<I", fmt)[::-1].decode("latin1"), fmt, a, b2, b2 - a, u32(outb, 28), u32(outb, 32), u32(outb, 36), outb[40] & 1)]


def dec_wh_out(outb):
    return ["out: %d x %d" % (u32(outb, 0), u32(outb, 4))]


def dec_surface(inb, outb):
    """dcp_surface_v27 (Linux iomfb_plane.h; 509-byte base + 47 padding) + surf null flag + pad = 560 bytes."""
    f = struct.unpack_from("<BBBIIIIBBIHBBIIIIQI", inb, 0)
    names = ["is_tiled", "is_tearing_allowed", "is_premultiplied", "plane_cnt", "plane_cnt2", "format", "ycbcr_matrix",
             "xfer_func", "colorspace", "stride", "pix_size", "pel_w", "pel_h", "offset", "width", "height", "buf_size",
             "protection_opts", "surface_id"]
    parts = []
    for n, v in zip(names, f):
        if n == "format":
            parts.append("format=%r(%#x)" % (struct.pack("<I", v)[::-1].decode("latin1"), v))
        elif v:
            parts.append("%s=%#x (%d)" % (n, v, v) if n in ("buf_size",) else "%s=%d" % (n, v))
    base = inb[:509]
    nz = ["+%#x=%#x" % (i, x) for i, x in enumerate(base) if x]
    return ["surface base: nonzero named fields: " + " ".join(parts) + "  (all other named fields 0)",
            "surface base: every nonzero byte: " + " ".join(nz) + "  (has_comp@0x51=%d has_planes@0x149=%d, plane/compression infos all zero)" % (base[0x51], base[0x149]),
            "padding[47] is stale 0xaa fill; byte@509 (surf null flag) = %#x; tail %s" % (inb[509 + 47] if len(inb) > 556 else -1, hexs(inb[-8:]))]


def dec_frame_sync(inb, outb):
    w = [u32(inb, i) for i in range(0, len(inb) - len(inb) % 4, 4)]
    nz = [(i * 4, hex(x)) for i, x in enumerate(w) if x]
    return ["nonzero words (offset: value) %s" % nz]


def dec_frame_sync_out(outb):
    w = [u32(outb, i) for i in range(0, len(outb), 4)]
    return ["out: nonzero words %s  (identity 0x10000 at +0x24/+0x28/+0x2c, as Linux dcpep_cb_set_frame_sync_props_h17p writes)" % [(i * 4, hex(x)) for i, x in enumerate(w) if x]]


def dec_rtbw(inb, outb):
    return ["in: %s" % hexs(inb)]


def dec_rtbw_out(outb):
    scratch, clk, tail = u64(outb, 0), u64(outb, 8), u32(outb, 16)
    return ["out[20]: reg_scratch %#x (= PMC window 0x286700000 + 0x20000: the DISP_INT bw-scratch of contrib/pending/dcp/BW-SCRATCH.md), second u64 %#x, u32 %#x" % (scratch, clk, tail)]


def dec_a378_out(outb):
    return ["out[40] as u32: %s  (unknown struct; 12800 = MaxGPBandwidthLimitKey, 25000/25600 appear in the D552 bandwidth dict)" % [hex(u32(outb, i)) for i in range(0, 40, 4)]]


def dec_swap_start(inb, outb):
    sid, cl = struct.unpack_from("<IQ", inb, 0)
    return ["swap_id %d client %#x null %d" % (sid, cl, inb[12])]


def dec_swap_submit(inb, outb):
    # Linux 27.3 layout (commit 716bce007fd3): IOMFBSwap 0x830, surfaces at 0x830; 27.0/27.2: 0xff4 and 0x6e0. NOT observed.
    L = len(inb)
    if L == 0x1144:
        sw, sw_off = 0x830, 0x40
        lay = "27.3 (0x1144)"
    elif L == 0xFF4:
        sw, sw_off = 0x6E0, 0
        lay = "27.0/27.2 (0xff4)"
    else:
        return ["LENGTH %#x matches neither 27.3 (0x1144) nor 27.0/27.2 (0xff4); raw %s" % (L, hexs(inb, 256))]
    sid = u32(inb, 0x98 + sw_off)
    ids = [u32(inb, 0x9C + sw_off + 4 * i) for i in range(4)]
    return ["layout %s: swap_id %d surf_ids %s swap_enabled %#x bg %#x" % (lay, sid, ids, u32(inb, 0x14C + sw_off), u32(inb, 0x154 + sw_off))]


def dec_set_mode(inb, outb):
    return ["color_mode_id %d timing_mode_id %d" % (u32(inb, 0), u32(inb, 4))]


def dec_a515(inb, outb):
    return ["args u32 %#x u32 %#x" % (u32(inb, 0), u32(inb, 4))]


def dec_a000(inb, outb):
    return ["arg bool %d" % inb[0]]


def dec_a529(inb, outb):
    return ["arg bool %d" % inb[0]]


def dec_a037_in(inb, outb):
    return ["in: ptr value %#x (zero input, size-checked only)" % u32(inb, 0)]


def dec_a037_out(outb):
    return ["out: u32 %#x (Linux dfb_compression: 3 = DCP_COMPRESSION_INTERCHANGE), u32 %#x (byte@4&1 = Linux dfb_compression_valid: %s)" % (
        u32(outb, 0), u32(outb, 4), "valid" if outb[4] & 1 else "invalid")]


def dec_a103_in(inb, outb):
    return ["in: width/height in-out pointers, values %d x %d, null flags %s" % (u32(inb, 0), u32(inb, 4), hexs(inb[8:10]))]


def dec_a104(inb, outb):
    return ["width %d height %d" % (u32(inb, 0), u32(inb, 4))]


def dec_a503_in(inb, outb):
    return ["in: null flags width_null=%d height_null=%d" % (inb[0], inb[1])]


def dec_set_param(inb, outb):
    return ["param %d value %s count %d" % (u32(inb, 0), [u32(inb, 4 + 4 * i) for i in range(8)], u32(inb, 36))]


def dec_power(inb, outb):
    return ["state %#x flags %#x null %d" % (u64(inb, 0), u32(inb, 8), inb[12])]


def retu32(outb):
    return "ret=%#x" % u32(outb, 0)


# per-tag: (in decoder, out decoder). A decoder takes (inb, outb) or (outb) as appropriate.
DEC_IN = {
    "D414": lambda t, i: dec_prop_int("D414", i, None), "D563": lambda t, i: dec_prop_int("D563", i, None),
    "D406": lambda t, i: dec_prop_int("D406", i, None),
    "D415": lambda t, i: dec_prop_bool("D415", i, None), "D565": lambda t, i: dec_prop_bool("D565", i, None),
    "D413": lambda t, i: dec_prop_dict("D413", i, None), "D552": lambda t, i: dec_prop_dict("D552", i, None),
    "D561": lambda t, i: dec_prop_dict("D561", i, None),
    "D102": lambda t, i: ["key %r value %#x" % (cstr(i[:64]), u32(i, 64))],
    "D104": lambda t, i: ["key %r value %d" % (cstr(i[:64]), u32(i, 64))],
    "D300": lambda t, i: dec_pr_publish(i, None),
    "D401": lambda t, i: dec_get_uint(i, None), "D400": lambda t, i: dec_d400(i, None),
    "D408": lambda t, i: dec_clock(i, None), "D575": lambda t, i: dec_hotplug(i, None),
    "D124": lambda t, i: dec_edt(i, None), "D451": lambda t, i: dec_alloc(i, None), "D201": lambda t, i: dec_map(i, None),
    "D586": lambda t, i: ["default fb surface %d x %d" % (u32(i, 0), u32(i, 4))],
    "D126": lambda t, i: ["DCPAV property length %d (%#x)" % (u32(i, 0), u32(i, 0))],
    "D127": lambda t, i: ["chunk, first 16 bytes %s (offset/length fields lie past the capture's 4096-byte cap)" % hexs(i, 16)],
    "D128": lambda t, i: ["DCPAV property key %r" % cstr(i[:64])],
    "D006": lambda t, i: dec_frame_sync(i, None), "D003": lambda t, i: dec_rtbw(i, None),
    "A000": lambda t, i: dec_a000(i, None), "A529": lambda t, i: dec_a529(i, None),
    "A037": lambda t, i: dec_a037_in(i, None), "A103": lambda t, i: dec_a103_in(i, None),
    "A104": lambda t, i: dec_a104(i, None), "A503": lambda t, i: dec_a503_in(i, None),
    "A515": lambda t, i: dec_a515(i, None), "A534": lambda t, i: dec_surface(i, None),
    "A456": lambda t, i: dec_swap_start(i, None), "A458": lambda t, i: dec_swap_submit(i, None),
    "A463": lambda t, i: dec_set_mode(i, None), "A500": lambda t, i: dec_set_param(i, None),
    "A535": lambda t, i: dec_power(i, None),
}
DEC_OUT = {
    "D401": dec_get_uint_out, "D400": dec_d400_out, "D408": dec_clock_out, "D124": dec_edt_out, "D451": dec_alloc_out,
    "D201": dec_map_out, "D006": dec_frame_sync_out, "D003": dec_rtbw_out,
    "A036": dec_dfb_info_out, "A037": dec_a037_out, "A103": dec_wh_out, "A503": dec_wh_out,
    "A378": dec_a378_out,
    "A353": lambda o: ["out: u64 %#x = %d (as nanoseconds %.4f ms; 1/120 s = 8.3333 ms - inference)" % (u64(o), u64(o), u64(o) / 1e6)],
    "A379": lambda o: ["out: u32 %#x = %d" % (u32(o), u32(o))],
    "D209": lambda o: ["out: u64 %#x" % u64(o)],
    "D204": lambda o: ["out: u32 %d  (Linux: 1 sRGB/unspecified, 2 P3, 3 AdobeRGB)" % u32(o)],
}
BOOL_OUT = {"A000", "A034", "A035", "A135", "A136", "A137", "A385", "A526", "A504", "D000", "D001", "D101", "D107", "D108", "D109", "D110", "D111",
            "D112", "D120", "D122", "D206", "D207", "D413", "D414", "D415", "D552", "D561", "D563", "D565", "D586", "D126", "D127", "D128", "A451"}
SKIP_OUT_DECODE = set()


def decode_in(tag, inb):
    f = DEC_IN.get(tag)
    if not f or not inb and tag not in ("D006",):
        return []
    try:
        return f(tag, inb)
    except Exception as e:
        return ["in decode failed (%s); raw %s" % (e, hexs(inb, 96))]


def decode_out(tag, outb, reliable):
    if not outb:
        return []
    if not reliable:
        return ["out: UNRELIABLE (module read the wrong slot for this ack); stale bytes %s" % hexs(outb, 16)]
    f = DEC_OUT.get(tag)
    try:
        if f:
            return f(outb)
        if tag in BOOL_OUT:
            return ["out: %s (raw %s)" % (retbool(outb), hexs(outb, 8))]
    except Exception as e:
        return ["out decode failed (%s); raw %s" % (e, hexs(outb, 96))]
    return ["out: raw %s" % hexs(outb, 64)]


# ---------------------------------------------------------------- load, pair, phase
class Txn:
    __slots__ = ("call", "ack", "depth", "phase", "mod_ok", "out", "inb")


def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def pair(rows):
    """LIFO per context (see module docstring). Returns txns in call order and a seq->txn map for acks."""
    stacks = collections.defaultdict(list)
    txns = []
    ack_of = {}
    for r in rows:
        k = r["kind"]
        if k == "call":
            t = Txn()
            t.call = r
            t.ack = None
            t.depth = len(stacks[r["ctx"]]) + (len(stacks[0]) if r["ctx"] != 0 and False else 0)
            t.phase = None
            t.mod_ok = True
            t.out = b""
            t.inb = bytes.fromhex(r.get("in", ""))
            stacks[r["ctx"]].append(t)
            txns.append(t)
        elif k == "ack":
            st = stacks[r["ctx"]]
            if not st:
                continue
            t = st.pop()
            t.ack = r
            t.mod_ok = (r.get("call_seq") == t.call["seq"])
            t.out = bytes.fromhex(r.get("out", ""))
            ack_of[r["seq"]] = t
    return txns, ack_of


def assign_phases(rows, txns):
    def first(pred):
        for t in txns:
            if pred(t.call):
                return t.call["seq"]
        return None
    s_props = first(lambda c: c["tag"] == "D406" and c["ctxn"] == "CB")
    s_pub = first(lambda c: c["tag"] == "D575")
    s_hw = first(lambda c: c["tag"] == "D100" and c["ctxn"] == "CB")
    s_dfb = first(lambda c: c["tag"] == "D451")
    s_modes = first(lambda c: c["tag"] == "D104")
    s_async = first(lambda c: c["ctxn"] == "ASYNC")
    s_ap = first(lambda c: c["dir"] == "AP>DCP" and c["ctxn"] in ("CMD", "OOBCMD") and c["seq"] > (s_async or 0))
    s_swap = first(lambda c: c["tag"] in ("A456", "A458", "A406", "A407", "A408"))
    last_ap = None
    for t in txns:
        c = t.call
        if c["dir"] == "AP>DCP" and c["ctxn"] in ("CMD", "OOBCMD") and s_ap and c["seq"] >= s_ap and t.ack:
            last_ap = max(last_ap or 0, t.ack["seq"])
    bounds = [("boot", 0), ("props", s_props), ("publish", s_pub), ("hw_boot", s_hw), ("dfb_alloc", s_dfb), ("modes", s_modes),
              ("async_start", s_async), ("ap_init", s_ap)]
    bounds = [(n, s) for n, s in bounds if s is not None]
    out = {}
    for t in txns:
        seq = t.call["seq"]
        ph = "boot"
        for n, s in bounds:
            if seq >= s:
                ph = n
        if last_ap and seq > last_ap and ph == "ap_init":
            ph = "steady"
        if s_swap and seq >= s_swap:
            ph = "swap"
        t.phase = ph
    ranges = {}
    for t in txns:
        r = ranges.setdefault(t.phase, [t.call["seq"], t.call["seq"], t.call["t"], t.call["t"], 0])
        r[1] = t.call["seq"]
        r[3] = t.call["t"]
        r[4] += 1
    return ranges


# ---------------------------------------------------------------- DCPAV property reassembly (D126/D127/D128)
def dcpav_props(txns):
    cur = None
    out = []
    for t in txns:
        tag = t.call["tag"]
        if t.call["dir"] != "DCP>AP":
            continue
        if tag == "D126":
            cur = {"len": u32(t.inb, 0), "chunks": [], "seq": t.call["seq"]}
        elif tag == "D127" and cur is not None:
            got = sum(len(c) for c in cur["chunks"])
            cur["chunks"].append(t.inb[:min(4096, cur["len"] - got)])  # offset/length live past the 4096-byte cap: assume contiguous
        elif tag == "D128" and cur is not None:
            key = cstr(t.inb[:64])
            blob = b"".join(cur["chunks"])
            try:
                val = parse_os(blob)
                err = None
            except Exception as e:
                val, err = None, str(e)
            out.append({"key": key, "len": cur["len"], "seq": cur["seq"], "end_seq": t.call["seq"], "chunks": len(cur["chunks"]),
                        "blob": blob, "value": val, "err": err})
            cur = None
    return out


COLOR_FIELDS = ["Score", "ID", "IsVirtual", "ElementType", "Depth", "PixelEncoding", "DynamicRange", "EOTF", "Colorimetry",
                "SupportsDSC", "StandardType"]
ENUM_NOTE = ("EOTF: 0 SDR gamma, 1 'HDR gamma', 2 ST2084 PQ, 3 HLG (Linux parser.h:57); PixelEncoding 0 RGB; "
             "Colorimetry 16 = Default RGB, 9 = BT.2020 RGB (HDR-STUDY.md section 1)")


def describe_dcpav(p, full=False):
    lines = []
    v = p["value"]
    lines.append("DCPAV property %r: %d bytes in %d chunk(s), D126 seq %d .. D128 seq %d%s" % (
        p["key"], p["len"], p["chunks"], p["seq"], p["end_seq"], "" if not p["err"] else "  PARSE ERROR " + p["err"]))
    if v is None:
        return lines
    if p["key"] == "ColorElements":
        lines.append("  %d colour element(s)" % len(v))
        for e in v:
            lines.append("  element ID %d: " % e["ID"] + " ".join("%s=%s" % (k, e[k]) for k in COLOR_FIELDS if k in e)
                         + "  ElementData=%s" % e["ElementData"].hex())
        lines.append("  " + ENUM_NOTE)
    elif p["key"] in ("TimingElements", "PreferredTimingElements"):
        lines.append("  %d timing element(s)" % len(v))
        for e in v:
            h, vv = e["HorizontalAttributes"], e["VerticalAttributes"]
            ed = e["ElementData"]
            pclk = u32(ed, 0x5C - 0x0 + 0) if False else None
            lines.append("  timing ID %d: %dx%d @ %.4f Hz (precise %.4f) Htotal %d Vtotal %d score %d preferred=%s promoted=%s "
                         "ColorModes=%s Unsafe=%s DSCRequired=%s VRR min/max=%d/%d TimingType=%d AspectRatio=%d ValidPixelEncodings=%d" % (
                             e["ID"], h["Active"], vv["Active"], vv["SyncRate"] / 65536, vv["PreciseSyncRate"] / 65536, h["Total"],
                             vv["Total"], e["Score"], e["IsPreferred"], e["IsPromoted"], [c["ID"] for c in e["ColorModes"]],
                             e["UnsafeColorElementIDs"], e["DSCRequiredColorElementIDs"], e["MinimumVariableRefreshRate"],
                             e["MaximumVariableRefreshRate"], e["TimingType"], e["AspectRatio"], e["ValidPixelEncodings"]))
            if full:
                lines.append("    H: %s" % h)
                lines.append("    V: %s" % vv)
                lines.append("    ElementData[%d]=%s" % (len(ed), ed.hex()))
    else:
        lines.append("  " + brief(v, 1500))
    if full and p["key"] in ("ColorElements",):
        pass
    return lines


# ---------------------------------------------------------------- printing
def check_len(t):
    c = t.call
    kn = TAGDB.get(c["tag"])
    if not kn or kn[2] is None:
        return None
    exp = kn[2]
    got = (c["in_len"], c["out_len"])
    if exp != got:
        return "LENGTH DIFFERS from the known layout: expected in/out %d/%d, got %d/%d -> raw hex below" % (exp + got)
    return None


def fmt_txn(t, a, out):
    c = t.call
    kn = TAGDB.get(c["tag"])
    name = kn[0] if kn else "UNKNOWN (no table has it)"
    ind = "  " * min(t.depth, 6)
    lines = []
    ack = t.ack
    head = "%6d %9.4f %-11s %-6s %-8s %s %-5s in=%-4d out=%-4d %s%s" % (
        c["seq"], c["t"], t.phase, c["dir"], c["ctxn"], ind, c["tag"], c["in_len"], c["out_len"], name,
        "" if kn is None else "  [%s]" % kn[3])
    lines.append(head)
    cl = check_len(t)
    if cl:
        lines.append("%s    !! %s" % (ind, cl))
        lines.append("%s    raw in : %s" % (ind, t.inb.hex()))
    for l in decode_in(c["tag"], t.inb):
        lines.append("%s    %s" % (ind, l))
    if a.raw and t.inb and not cl:
        lines.append("%s    raw in : %s" % (ind, t.inb.hex()))
    if out:
        if ack is None:
            lines.append("%s    (no ack in capture)" % ind)
        else:
            lines.append("%s    ack seq %d at t=%.4f (+%.1f ms)%s" % (
                ind, ack["seq"], ack["t"], (ack["t"] - c["t"]) * 1000,
                "" if t.mod_ok else "  [module paired this ack with call #%d; LIFO says #%d]" % (ack["call_seq"], c["seq"])))
            for l in decode_out(c["tag"], t.out, t.mod_ok):
                lines.append("%s    %s" % (ind, l))
            if a.raw and t.out:
                lines.append("%s    raw out: %s" % (ind, t.out.hex()))
    return lines


def inventory(rows, txns):
    inv = collections.OrderedDict()
    for t in txns:
        c = t.call
        k = (c["dir"], c["ctxn"], c["tag"])
        e = inv.setdefault(k, {"n": 0, "lens": collections.Counter(), "first": c["seq"], "t0": c["t"], "phases": collections.Counter()})
        e["n"] += 1
        e["lens"][(c["in_len"], c["out_len"])] += 1
        e["phases"][t.phase] += 1
    return inv


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", nargs="?", default="<agent dir>/captures/dcp-rpc-sync-20261109-0243.jsonl")
    ap.add_argument("--tag", action="append", default=[])
    ap.add_argument("--phase", action="append", default=[], choices=PHASES)
    ap.add_argument("--no-async", action="store_true")
    ap.add_argument("--raw", action="store_true")
    ap.add_argument("--no-acks", action="store_true")
    ap.add_argument("--collapse", type=int, default=3)
    ap.add_argument("--dicts", action="store_true")
    ap.add_argument("--summary", action="store_true")
    ap.add_argument("--md-tags", action="store_true")
    ap.add_argument("--phases", action="store_true")
    ap.add_argument("--pr-table", action="store_true")
    a = ap.parse_args()

    rows = load(a.capture)
    txns, ack_of = pair(rows)
    ranges = assign_phases(rows, txns)
    mism = [t for t in txns if t.ack and not t.mod_ok]

    if a.phases:
        for p in PHASES:
            if p in ranges:
                r = ranges[p]
                print("%-12s seq %5d..%-5d t %.3f..%.3f  %5d calls  %s" % (p, r[0], r[1], r[2], r[3], r[4], PHASE_DOC[p]))
        return
    if a.pr_table:
        tab = collections.OrderedDict()
        for t in txns:
            if t.call["tag"] != "D300":
                continue
            pid, val = struct.unpack_from("<Ii", t.inb, 0)[:2]
            e = tab.setdefault(pid, {"n": 0, "vals": collections.Counter(), "first": t.call["seq"], "last": t.call["seq"], "t0": t.call["t"],
                                     "t1": t.call["t"], "ctx": set()})
            e["n"] += 1
            e["vals"][val & 0xFFFFFFFF] += 1
            e["last"] = t.call["seq"]
            e["t1"] = t.call["t"]
            e["ctx"].add(t.call["ctxn"])
        print("%-8s %-10s %6s  %-14s %s" % ("id", "ctx", "count", "seq first..last", "values (value x count)"))
        for pid, e in sorted(tab.items()):
            vals = ", ".join("%#x%s" % (v, "" if c == 1 else " x%d" % c) for v, c in sorted(e["vals"].items())[:6])
            if len(e["vals"]) > 6:
                vals += ", ... (%d distinct)" % len(e["vals"])
            print("%-3d %#-4x %-10s %6d  %5d..%-5d  %s%s" % (pid, pid, "/".join(sorted(e["ctx"])), e["n"], e["first"], e["last"], vals,
                                                       "   <- " + PR_NAMES[pid] if pid in PR_NAMES else ""))
        return
    if a.summary or a.md_tags:
        inv = inventory(rows, txns)
        if a.md_tags:
            print("| tag | direction / ctx | count | in/out lengths seen | name (27.3) | status | where it matches |")
            print("|---|---|---|---|---|---|---|")
        else:
            print("%-6s %-7s %-8s %6s  %-22s %s" % ("tag", "dir", "ctx", "count", "in/out", "name"))
        for (d, cx, tag), e in sorted(inv.items(), key=lambda x: (x[0][2][0] == "D", x[0][2], x[0][1])):
            kn = TAGDB.get(tag)
            lens = ", ".join("%d/%d" % k + ("" if v == e["n"] else " x%d" % v) for k, v in sorted(e["lens"].items()))
            if a.md_tags:
                print("| %s | %s %s | %d | %s | %s | %s | %s |" % (tag, d, cx, e["n"], lens, kn[0] if kn else "**unknown/new**",
                                                               kn[3] if kn else "U", kn[1] if kn else "no m1n1 or Linux table"))
            else:
                print("%-6s %-7s %-8s %6d  %-22s %s" % (tag, d, cx, e["n"], lens, kn[0] if kn else "UNKNOWN"))
        return

    want_tags = tuple(a.tag)
    last_key = None
    run = 0
    suppressed = 0
    props = dcpav_props(txns) if a.dicts else []
    shown_props = set()
    for t in txns:
        c = t.call
        if a.no_async and c["ctxn"] in ("ASYNC", "OOBASYNC"):
            continue
        if want_tags and not c["tag"].startswith(want_tags):
            continue
        if a.phase and t.phase not in a.phase:
            continue
        key = (c["dir"], c["ctxn"], c["tag"], c["in_len"], c["out_len"], t.phase)
        if a.collapse and c["tag"] in ("D300", "D006", "D201", "D451", "D127") and key == last_key:
            run += 1
            if run > a.collapse:
                suppressed += 1
                continue
        else:
            if suppressed:
                print("       ... %d more identical-shape %s transactions suppressed (--collapse 0 shows all)" % (suppressed, last_key[2]))
                suppressed = 0
            run = 1
        last_key = key
        for l in fmt_txn(t, a, not a.no_acks):
            print(l)
        if a.dicts and c["tag"] == "D128":
            for p in props:
                if p["end_seq"] == c["seq"] and p["key"] not in shown_props:
                    for l in describe_dcpav(p, True):
                        print("        " + l)
    if suppressed:
        print("       ... %d more identical-shape %s transactions suppressed" % (suppressed, last_key[2]))
    if mism and not want_tags and not a.phase:
        print("\nNOTE: %d ack(s) were re-paired by the per-context LIFO rule (module call_seq differed): %s" % (
            len(mism), ", ".join("ack#%d->call#%d(%s)" % (t.ack["seq"], t.call["seq"], t.call["tag"]) for t in mism)))


if __name__ == "__main__":
    main()
