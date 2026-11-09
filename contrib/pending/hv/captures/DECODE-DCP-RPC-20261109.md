# macOS 27.3 AppleDCP <-> DCP firmware RPC: decode of `dcp-rpc-sync-20261109-0243.jsonl` (M5 Pro / T6050 / J716s)

Studio-only analysis (2026-11-09), nothing run on hardware. Inputs: `captures/dcp-rpc-sync-20261109-0243.jsonl` (17,898 records:
set_shmem, init_complete, 8,948 calls, 8,948 acks), `captures/trace-cpus1-dcprpc-sync-20261109-0243.log`, `hv/hv27-dcp-trace.py`,
m1n1 `proxyclient/m1n1/fw/dcp/{ipc,dcpep,manager}.py` (V12_3 / V13_5 / V14_7 tables, loaded with `AGX_FWVER=` to get tag + size per method),
Linux `iomfb_v27.c` in `/Volumes/linux-cs/wt-dcp-27` (branch `dcp/27.3`: 27.0 / 27.2 / 27.3 tables, `callback_sizes[]`) and
`/Volumes/linux-cs/wt-dcp-aurora` (PR #1012: 27.0 only), plus `contrib/pending/dcp/{REPORT,BW-SCRATCH}.md`, `hdr/HDR-STUDY.md`,
`aurora/ANALYSIS.md`, `contrib/validated/display/stage-c-analysis.md`. Tool: `captures/dcp-rpc-decode.py` (stdlib only; `--help`).
**Fact** = read from the payload bytes or a source file. **Inference** = marked as such. Raw hex is quoted where unsure.

Note on trees: `/Volumes/linux-cs/wt-series` has `iomfb_v12_3/v13_3/v14_7(_tpl)/v26_6` and a separate DCPLink-style `iomfb_v26_6.c`
(`A(n)`/`D(n)` macros, keyed by firmware UUID) but **no `iomfb_v27*`**. The 27.x tables live in `wt-dcp-aurora` (one table, `apple,firmware-compat`
byte-exact `"27.0.0"`) and in `wt-dcp-27` (`iomfb_v27_methods(compat)`: `"27.0.0"`, `"27.2.0"`, `"27.3.0"`, NULL = refused at probe,
`dcp.c dcp_check_firmware_version()`). Everything in section 4 is relative to `wt-dcp-27` @ `716bce007fd3` ("Add the firmware 27.3 IOMFB method table and swap layout", Rolando, 2026-11-07).

## 0. Read this first: what the capture is, and its limits

- **Fact: this is the AppleDCP driver's own bring-up and nothing else.** 28 AP->DCP calls (19 of them nested inside DCP callbacks, 7 CMD, 2 OOBCMD) and 8,920 DCP->AP callbacks (330 on CB, 8,590 ASYNC). There is **no swap (A456/A458), no set_digital_out_mode (A463), no set_display_device, no first_client_open (A516), no set_power_state, no set_matrix / brightness correction, no `set_parameter_dcp`**: macOS had no WindowServer / display client (`guest nodisk`). Everything in section 3 that is not in this list is therefore "what the DCP and AppleDCP exchange at boot", not what macOS sends to show a frame. The capture ends in a 41 ms-period `pr_publish id 119` flood (t = 12.06 .. 368.07 s).
- **Fact: the module's `call_seq` on 6 of 8,948 acks is wrong, and the out bytes of those 6 are read from the wrong slot.** The firmware (and the Linux driver, `iomfb.c dcpep_handle_ack()`/`dcp_ack()`) keeps one LIFO stack per *context*: an ack pops the innermost call of the context named in the ack word, whichever direction that call went (a DCP callback and an AP command nested in it share the CB stack). Re-pairing that way empties every stack at the end of the capture and changes exactly these acks: #405 (D108, not D207), #406 (A137, not A451), #407 (D207, not D108), #491 (D107@490, not D120), #661 (D120, not D107@490), #699 (A451, not A137). Consequences: `A451 start_signal` completes at seq 699 / t = 12.06 s (4.92 s after the call, right after `D122`), `A137` completes at seq 406, `D120 start_hardware_boot` at seq 661 (+1.05 s). The **return values of A451, A137, D207, D108, D107@490 and D120 are not in the capture** (the module read stale bytes: `04000000`, `01000000`, ...). `dcp-rpc-decode.py` pairs by context stack and prints "UNRELIABLE" for those six. Module fix: pair acks by ctx stack, read `out` at the popped call's own offset.
- **Fact: payload hex is capped at 4096 bytes, so the `offset`/`length` fields of `D127 setDCPAVPropChunk` (they follow `data[0x1000]`) are not in the JSONL.** The four DCPAV blobs were reassembled as contiguous chunks of `min(4096, remaining)` using the length from `D126`; every blob parses completely as OSSerialize binary (`consumed = length - 1` each time, i.e. the D126 length counts one trailing byte), so the assumption holds.
- Fact: `captures/dcp-rpc-20261108-214404.jsonl` (22,046 records, run to t = 454.5 s) is a superset of the sync file (`cmp`: the sync file is an exact prefix); the 4,148 extra records are all more `D300 id 119`. Nothing new there.

## 1. Results in short

1. **27.3 method table (Linux `dcp_methods_27_3`) is confirmed where it can be**: 20 of its 41 tags were called with exactly the in/out lengths the table implies, among them the three that distinguish 27.3 from 27.2 (`A526 set_display_refresh_properties` 0/4, `A529 flush_supports_power` 4/0, `A534 register_dfb_surface` 560/4; 27.2 has nothing at A526 and puts abort_swaps_dcp at A529 and set_power_state at A534). The other 21 (swap_start/submit, set_digital_out_mode, set_display_device, first_client_open, set_power_state, brightness, matrix, ...) are **not exercised by this capture** and stay "assumed from the static dispatch emulation". Nothing observed contradicts the table. No callback (D-tag) is new: all 41 distinct D tags are in Linux's 27.0 `cb_handlers[]` and **every one has the same in/out lengths as `callback_sizes[]`**.
2. **New/unknown in 27.3 (no m1n1 or Linux entry): `A378` (in 44 / out 40), `A379`, `A381`, `A384` (OOBCMD), `A400` (OOBCMD), `A515` (in 8 `0x800, 0x20`)**; `A034`/`A135` are bool queries only named by shift pattern. All six unknowns are AP-initiated, none is needed by Linux so far.
3. **The firmware offers exactly ONE colour element to macOS too** (ID 1: 8 bit, RGB, SDR, EOTF 0, colorimetry 16, score 240999) and all six timings (120/60/48/59.94/47.95/50 Hz at 3456x2234, ID 2 = 120 Hz preferred) reference only it. The "one SDR element" seen on Linux is the firmware's own list, not a Linux artefact. A PQ/10-bit element is not coming from this list, so HDR on this panel in macOS cannot be a PQ link; section 5.
4. **Real answers macOS gave that Linux currently answers differently** (stage-C cross-check, section 6): `D408 sr_getClockFrequency('PROV', 0)` = **810,000,000 Hz** (Linux answers 0, which is the "EDT ERROR ... Giving up on frequencies" of stage-C item 8); `D003` reply = `{0x286720000, 0}` = **BW-SCRATCH.md's PMC + 0x20000, now confirmed from macOS**; `A534` returns **1** (Linux's `complete_dfb_surface()` treats non-zero as failure, a candidate cause of stage-C item 16 "Creating default FB surface failed"); macOS's default surface record has `surface_id = 3` (Linux sends 5) and `buf_size = 0x025ec000`, which Linux's own `apple_dcp_dfb_allocation()` reproduces to the byte.
5. Panel level facts: `pr_publish id 20 = 0x012c0000` = **300.000 nits** (16.16, matches Linux `case 20`); `0x06400000` = **1600.0** is published under four ids (25, 117, 118, 261); `Brightness_Scale` = 0x10000.

## 2. (a) Every tag seen

Legend, column `st`: **C** tag and in/out length match an m1n1 or Linux table entry, **S** length shape seen but the name is inferred (shift pattern) or Linux's placeholder, **U** in no table. "m1n1 Vx" = the tag in m1n1's table for that firmware (`ipc.py`, V13_5 / V14_7, tags shift between versions); "Linux 27.x" = `iomfb_v27.c`. Counts are calls; every call has one ack.

### 2.1 AP -> DCP (A tags: 28 calls, 28 distinct tags, each called once: 19 nested on CB, 7 on CMD, 2 on OOBCMD)

Context note: AP commands sent while a DCP callback is in flight go out on ctx CB (shared-memory buffer 0x0, offset 64), exactly as Linux `dcp_call_context()`; their acks come back on ctx CB (or, for the outermost command, ctx CMD).

| tag | direction / ctx | count | in/out seen | name (27.3) | st | where it matches |
|---|---|---|---|---|---|---|
| A000 | AP>DCP CB | 1 | 4/4 | late_init_signal | C | m1n1 A000 (V13_5+), Linux all tables |
| A027 | AP>DCP CB | 1 | 0/0 | setup_video_limits | C | Linux 27.0/27.2/27.3 (m1n1 A029) |
| A034 | AP>DCP CB | 1 | 0/4 | is_hilo? (bool query) | S | inferred: m1n1 A035 is_hilo, same -1 shift as A036/A037; not in Linux 27 tables |
| A035 | AP>DCP CB | 1 | 0/4 | dfb_query / apt_supported? (bool query) | C | Linux 27.x dcpep_dfb_query; m1n1 A036 apt_supported -1 |
| A036 | AP>DCP CB | 1 | 44/44 | get_dfb_info | C | Linux 27.x; m1n1 A037 -1 |
| A037 | AP>DCP CB | 1 | 8/8 | get_dfb_compression_info | C | Linux 27.x; m1n1 A038 -1 |
| A103 | AP>DCP CB | 1 | 12/8 | get_config_frame_size (Linux: get_dfb_layout) | C | m1n1 UPPipe2 A103, Linux 27.x |
| A104 | AP>DCP CB | 1 | 8/0 | set_config_frame_size (Linux: set_dfb_dimensions) | C | m1n1 UPPipe2 A104, Linux 27.x |
| A105 | AP>DCP CB | 1 | 0/0 | program_config_frame_size (Linux: commit_dfb_info) | C | m1n1 UPPipe2 A105, Linux 27.x |
| A135 | AP>DCP CB | 1 | 0/4 | init_ca_pmu? (bool query) | S | inferred: m1n1 A130 init_ca_pmu, +5 like A131->A136, A132->A137 |
| A136 | AP>DCP CMD | 1 | 0/4 | pmu_service_matched | C | Linux 27.x (m1n1 A131 +5) |
| A137 | AP>DCP CB | 1 | 0/4 | backlight_service_matched | C | Linux 27.x (m1n1 A132 +5) |
| A353 | AP>DCP CMD | 1 | 0/8 | pipe_query_353 (27.x out is 8 bytes; m1n1 get_system_type returned 4) | S | Linux 27.x table name only (Linux never calls it) |
| A378 | AP>DCP CMD | 1 | 44/40 | **UNKNOWN query (in 44 / out 40)** | U | no table has it; in V14_7 A378 is vi_set_temperature_hint (0/4): different method |
| A379 | AP>DCP CMD | 1 | 0/4 | **UNKNOWN query (0/4, returns 0x7f2600)** | U | no table has it |
| A381 | AP>DCP CB | 1 | 0/4 | **UNKNOWN query (0/4)** | U | no table has it |
| A384 | AP>DCP OOBCMD | 1 | 0/4 | **UNKNOWN OOBCMD query (0/4)** | U | 27.0 table: dfb_ready_query; in 27.2/27.3 that moved to A385 |
| A385 | AP>DCP CB | 1 | 0/4 | dfb_ready_query | C | Linux 27.2/27.3 (inferred in 27.2 commit, now observed) |
| A390 | AP>DCP CB | 1 | 0/0 | set_create_DFB | C | Linux 27.2/27.3 (27.0: A389; m1n1 A373/A377) |
| A391 | AP>DCP CMD | 1 | 0/4 | vi_set_temperature_hint | C | Linux 27.2/27.3 (27.0: A390; m1n1 A374/A378) |
| A400 | AP>DCP OOBCMD | 1 | 0/4 | **UNKNOWN OOBCMD query (0/4)** | U | no table has it |
| A451 | AP>DCP CMD | 1 | 0/4 | start_signal | C | Linux 27.2/27.3 (27.0: A401; m1n1 A401) |
| A503 | AP>DCP CB | 1 | 4/8 | get_display_size (Linux: get_dfb_state) | C | Linux 27.2/27.3; m1n1 get_display_size shape (4/8) |
| A504 | AP>DCP CB | 1 | 0/4 | do_create_default_frame_buffer | C | Linux 27.2/27.3 dcpep_create_default_fb |
| A515 | AP>DCP CMD | 1 | 8/0 | **UNKNOWN command (in 8: u32 0x800, u32 0x20 / out 0)** | U | no table has it |
| A526 | AP>DCP CB | 1 | 0/4 | set_display_refresh_properties | C | Linux 27.3 only (27.2: A525) |
| A529 | AP>DCP CB | 1 | 4/0 | flush_supports_power | C | Linux 27.3 only (27.2: A528; 27.2's A529 is abort_swaps_dcp) |
| A534 | AP>DCP CB | 1 | 560/4 | register_dfb_surface (m1n1 update_dfb: one IOSurface) | C | Linux 27.3 only (27.2: A533; 27.2's A534 is set_power_state) |

### 2.2 DCP -> AP (D tags; 8,920 callbacks, 41 distinct tags)

| tag | direction / ctx | count | in/out seen | name (27.3) | st | where it matches |
|---|---|---|---|---|---|---|
| D000 | DCP>AP CB | 1 | 0/4 | did_boot_signal | C | m1n1 D000, Linux [0] |
| D001 | DCP>AP CB | 1 | 0/4 | did_power_on_signal | C | m1n1 D001, Linux [1] |
| D003 | DCP>AP CB | 1 | 4/20 | rt_bandwidth_setup_ap (H17P reply: 4 in / 20 out) | C | Linux [3] (m1n1 V13_5 had 4/60) |
| D006 | DCP>AP ASYNC | 5 | 84/80 | set_frame_sync_props (84 in / 80 out) | C | Linux [6] (m1n1 V13_5 32/28, V14_7 60/56) |
| D100 | DCP>AP CB | 1 | 0/0 | match_pmu_service | C | m1n1 D100, Linux [100] |
| D101 | DCP>AP CB | 1 | 0/4 | get_display_default_stride (m1n1 UNK_get_some_field) | C | m1n1 D101, Linux [101] |
| D102 | DCP>AP CB | 2 | 68/0 | set_number_property | C | m1n1 D102, Linux [102] |
| D104 | DCP>AP CB | 1 | 68/0 | set_boolean_property | C | m1n1 V13_5 D104, Linux [104] |
| D107 | DCP>AP CB | 8 | 0/4 | create_provider_service | S | 27.x numbering = m1n1 V13_5 D108 -1 (m1n1 D107 there is removeProperty 64/0); shape 0/4 |
| D108 | DCP>AP CB | 2 | 0/4 | create_product_service | S | = m1n1 V13_5 D109 -1; shape 0/4 |
| D109 | DCP>AP CB | 3 | 0/4 | create_PMU_service | S | = m1n1 V13_5 D110 -1; shape 0/4 |
| D110 | DCP>AP CB | 2 | 0/4 | create_iomfb_service | S | = m1n1 V13_5 D111 -1; shape 0/4 |
| D111 | DCP>AP CB | 1 | 0/4 | create_backlight_service | C | = m1n1 V13_5 D112 -1; Linux [111] create_backlight_service |
| D112 | DCP>AP CB | 1 | 0/4 | create_nvram_service | S | = m1n1 V13_5 D113 -1; Linux [112] trampoline_true |
| D120 | DCP>AP CB | 1 | 0/4 | start_hardware_boot | C | m1n1 V13_5 D120, Linux [120] dcpep_cb_boot_1 |
| D122 | DCP>AP CB | 1 | 0/4 | is_waking_from_hibernate | C | m1n1 V13_5 D122, Linux [122] |
| D124 | DCP>AP CB | 1 | 100/36 | read_edt_data | C | m1n1 V13_5 D124, Linux [124] |
| D126 | DCP>AP CB | 4 | 4/4 | setDCPAVPropStart | C | m1n1 V13_5 D126, Linux [126] |
| D127 | DCP>AP CB | 6 | 4104/4 | setDCPAVPropChunk | C | m1n1 V13_5 D127, Linux [127] (data[0x1000], offset, length) |
| D128 | DCP>AP CB | 4 | 64/4 | setDCPAVPropEnd | C | m1n1 V13_5 D128, Linux [128] |
| D201 | DCP>AP CB | 29 | 12/16 | map_buf (piodma) | C | m1n1 D201 (12/20); Linux [201] H17P reply 16 bytes |
| D204 | DCP>AP ASYNC | 1 | 0/4 | get_ideal_screen_space (new in 27.x) | C | Linux [204] trampoline_ideal_screen_space_v27; not in m1n1 |
| D206 | DCP>AP CB | 1 | 0/4 | match_pmu_service_2 | C | m1n1 D206, Linux [206] |
| D207 | DCP>AP CB | 1 | 0/4 | match_backlight_service | C | m1n1 D207, Linux [207] |
| D209 | DCP>AP CB | 1 | 0/8 | get_calendar_time_ms (get_time) | C | m1n1 V13_5 D209, Linux [209] |
| D300 | DCP>AP CB + DCP>AP ASYNC | 8745 | 16/0 | pr_publish (id, value, unk0, unk1) | C | m1n1 V13_5 D300, Linux [300] |
| D400 | DCP>AP CB | 1 | 76/3076 | get_property (out 0xc04) | C | m1n1 D400 (out 0x204); Linux [400] 0x4c/0xc04 |
| D401 | DCP>AP CB | 2 | 80/12 | sr_get_uint_prop | C | m1n1 D401, Linux [401] |
| D406 | DCP>AP CB + DCP>AP ASYNC | 2 | 72/0 | set_fx_prop | C | m1n1 D406, Linux [406] |
| D408 | DCP>AP CB | 2 | 8/8 | sr_getClockFrequency | C | m1n1 D408, Linux [408] |
| D413 | DCP>AP CB | 1 | 4168/4 | sr_setProperty_dict | C | m1n1 D413, Linux [413] |
| D414 | DCP>AP CB | 23 | 80/4 | sr_setProperty_int | C | m1n1 D414, Linux [414] |
| D415 | DCP>AP CB | 5 | 76/4 | sr_setProperty_bool | C | m1n1 D415, Linux [415] |
| D451 | DCP>AP CB | 29 | 20/20 | allocate_buffer (27.x: 20 in / 20 out) | C | m1n1 D451 (20/28); Linux [451] dcp_allocate_buffer_{req,resp}_v27 |
| D552 | DCP>AP CB | 7 | 4164/4 | setProperty_dict | C | m1n1 D552, Linux [552] |
| D561 | DCP>AP CB | 2 | 4164/4 | setProperty_dict | C | m1n1 D561, Linux [561] |
| D563 | DCP>AP CB | 10 | 76/4 | setProperty_int | C | m1n1 D563, Linux [563] |
| D565 | DCP>AP CB | 8 | 72/4 | setProperty_bool | C | m1n1 D565, Linux [565] |
| D575 | DCP>AP CB | 1 | 88/76 | hotPlug_notify_gated (88 in / 76 out) | C | Linux [575] (m1n1 V14_7 D576 -1) |
| D586 | DCP>AP CB | 1 | 8/4 | create_default_fb_surface (m1n1 V14_7 D582 +4) | C | Linux [586] iomfbep_cb_create_dfb_surface |
| D603 | DCP>AP CB | 1 | 0/0 | find_swap_function_gated (m1n1 V14_7 D598 +5) | C | Linux [603] trampoline_nop 0/0 |

### 2.3 Classification of the candidates from the brief

| tag | verdict |
|---|---|
| A503 | in Linux 27.2/27.3 table (`dcpep_get_dfb_state`, 4/8); payload is `(width, height)` = 3456 x 2234, i.e. m1n1's `get_display_size(OutPtr, OutPtr)` shape |
| A504 | Linux 27.2/27.3 `dcpep_create_default_fb` (0/4), m1n1 `do_create_default_frame_buffer` (int, returns 1) |
| A526, A529, A534 | **27.3 positions** (27.2: A525, A528, A533). Seen with the sizes of `setDisplayRefreshProperties` (0/4), `flush_supportsPower(bool)` (4/0) and `update_dfb(IOSurface)` (560/4) |
| D451 | m1n1 `allocate_buffer` (20 in / **28** out in V13_5..V14_7); 27.x is 20/20 = Linux `dcp_allocate_buffer_{req,resp}_v27` (dva, capacity, mem_desc_id) |
| D552, D561, D563, D565 | not new: m1n1 `setProperty_dict/dict/int/bool` (same tags and lengths since V12_3); Linux 27.0 `[552]..[565]` |
| **A515, A378, A379, A381, A384, A400** | **unknown/new in 27.x** (no table has them) |

Tag provenance worth knowing when reading older notes: in 27.x the service-creation callbacks are one lower than in m1n1 V13_5 (`D107 create_provider_service`, `D108 product`, `D109 PMU`, `D110 iomfb`, `D111 backlight`, `D112 nvram`; m1n1 V13_5's `D107` is `removeProperty(64/0)`, which is `D106` in 27.x per Linux `[106] = {0x40, 0}`). `D120/D122/D124/D126-128/D209` keep their V13_5 numbers. `A451`..`A534` carry the 27.2 +50 renumbering of IOMobileFramebufferAP (27.0 `A401` start_signal -> `A451`) plus 27.3's +1 for tags >= A521.

## 3. (b) The init sequence

Phases (computed from anchor calls; `dcp-rpc-decode.py --phases`):

| phase | seq range | t (s) | calls | what happens |
|---|---|---|---|---|
| boot | 3-14 | 7.14-7.21 | 7 | set_shmem, init_complete, start_signal (A451) and the first service callbacks, up to the first property |
| props | 16-78 | 7.23-8.30 | 32 | property setup: D406/D414/D415/D413 (IOMF objects), D111/D112 services, D575 hotplug |
| publish | 80-396 | 8.34-9.98 | 159 | D300 pr_publish burst (~160 property publications), until the first D100 |
| hw_boot | 398-522 | 9.99-10.64 | 64 | D100..D120 start_hardware_boot, with the nested A-calls: create_default_fb, dfb info, setup_video_limits, ... |
| dfb_alloc | 524-642 | 10.65-11.27 | 60 | D451/D201 buffer allocation and piodma mapping (29 buffers, one D451+D201 pair each) |
| modes | 644-696 | 11.29-12.04 | 26 | D104 NormalModeActive .. D122: refresh properties, create_dfb_surface/register_dfb_surface, DCPAV dicts (colour + timing elements) |
| async_start | 698-779 | 12.06-12.51 | 41 | start_signal acked; first ASYNC callbacks (D204 ideal screen space, D006, async D406) |
| ap_init | 781-814 | 12.51-12.71 | 18 | AP-initiated CMD/OOBCMD queries (A515, A400, A353, A384, A379, A378, A391, A136) - no swap, no mode set |
| steady | 817-17897 | 12.72-368.07 | 8541 | periodic D006 and the D300 id 0x77 flood |

Full decoded conversation without the async flood: `captures/dcp-rpc-decode-20261109-conversation.txt` (`dcp-rpc-decode.py --no-async --collapse 3`); one tag: `--tag D414`; a phase: `--phase modes`; with raw hex: `--raw`; DCPAV dicts: `--dicts`.

### 3.1 boot (seq 1-14, t = 7.10-7.21 s)

- `1 AP>DCP set_shmem dva=0x10000044000 flag=4` (`msg0 0x0100000440000040`), `2 DCP>AP init_complete` (`msg0 0x0040227b39590101`, payload bits unexplained, as in DCP-UNDER-HV.md).
- `3 AP>DCP CMD A451 start_signal (0/4)` is sent 40 ms later and **stays outstanding for 4.9 s**: the whole boot below happens inside it (its ack is seq 699, see section 0).
- First callbacks: `D603 find_swap_function_gated`, `D107 x2 -> true` (the two provider services), `D108 -> true`, `D109 create_PMU_service -> false`, `D110 create_iomfb_service -> true`. Fact: macOS answers the PMU-service creation with false three times (seq 13, 811, 815); Linux's `[109] = trampoline_true`. Whether that matters is untested.

### 3.2 props (seq 16-78): property setup on the `IOMF` object

`D406 set_fx_prop`, `D414 sr_setProperty_int`, `D415 sr_setProperty_bool`, `D413 sr_setProperty_dict` carry `obj` = `IOMF` (FourCC arrives byte-reversed as `FMOI`); layouts as in m1n1 (`obj[4] key[0x40] value`), all answered `true`. Every property of the capture (`dcp-rpc-decode.py --tag D4`, `--tag D5`, `--tag D1`):

| seq | tag | obj | key | value |
|---|---|---|---|---|
| 16 | D406 | IOMF | InitialPanelTemperature | 0x1e0000 (16.16 = 30.000) |
| 18 | D414 | IOMF | bics_mode | 0 |
| 20 | D414 | IOMF | IdleState | 5 |
| 22 | D414 | IOMF | IdleCachingMethod | 2 |
| 24 | D413 | IOMF | M3TimingParameters | `{"subframe-duration-nclks":100000,"display-lead-time-nclks":15256,"initial-subframe-irq-time-lines":1060,"subframe-interrupt-time-lines":1060,"initial-vbi-advance-lines":2,"vbi-advance-lines":2}` |
| 26 | D414 | IOMF | IOMFBTestBacklightDimValue | 12288 |
| 28 | D415 | IOMF | BICSDaemonPanicOnStartFail | 0 |
| 30 | D414 | IOMF | IOMFBBICSType | 0 |
| 32 | D415 | IOMF | IOMFBSwapAppleLookSupported | 1 |
| 34 | D415 | IOMF | APTDevice | 1 |
| 36 | D414 | IOMF | W40a_Blending_OK | 1 |
| 38 | D414 | IOMF | color-accuracy-index | 239 |
| 40 | D414 | IOMF | IOMFBWPASupported | 1 |
| 42 | D414 | IOMF | IOMFBPPASupported | 1 |
| 44 | D414 | IOMF | MaxVideoSrcDownscalingWidth | 5120 |
| 46 | D414 | IOMF | VideoClock | 0 |
| 48 | D414 | IOMF | PixelClock | 0 |
| 50 | D414 | IOMF | DisplayClock | 0 |
| 52 | D414 | IOMF | DispPerfState | 0 |
| 54 | D414 | IOMF | ean-mode-update-thesh | 172800 (0x2a300) |
| 56 | D414 | IOMF | ean-mode-caching | 1 |
| 58 | D415 | IOMF | ADP is generic pipe | 1 |
| 60 | D415 | IOMF | NormalModeActive | 0 |
| 62 | D414 | IOMF | DisplayWidth | 3456 |
| 64 | D414 | IOMF | DisplayHeight | 2234 |
| 66 | D414 | IOMF | DPTimingModeId | 2 |
| 68 | D414 | IOMF | Brightness_Scale | 65536 |
| 70 | D414 | IOMF | IOMFBSecureContentFactor | 65536 |
| 72 | D414 | IOMF | IOMFBSecureIndicatorFactor | 65536 |
| 74 | D414 | IOMF | IOMFBSecureIndicatorSDRFactor | 65536 |
| 408 | D552 | - | DisplayPipeStrideRequirements | `{"StrideLinearHorizontal":64,"StrideLinearVertical":1}` |
| 410 | D552 | - | DisplayPipePlaneBaseAlignment | `{"PlaneBaseAlignmentLinear":64}` |
| 422 | D563 | - | MaxVideoSrcDownscalingWidth | 10744 |
| 424 | D563 | - | VideoClock | 521064960 (0x1f0ed200) |
| 426 | D563 | - | PixelClock | 810000000 (0x30479e80) |
| 428 | D563 | - | DisplayClock | 677384448 (0x28601100) |
| 430 | D563 | - | DispPerfState | 5 |
| 434 | D561 | - | M3TimingParameters | `{"subframe-duration-nclks":100000,"display-lead-time-nclks":15256,"initial-subframe-irq-time-lines":1060,"subframe-interrupt-time-lines":1060,"initial-vbi-advance-lines":2,"vbi-advance-lines":2}` |
| 436 | D552 | - | IOMFBNumLayers | `{"MaxNumLayers":3,"FullFrameRequired":0}` |
| 438 | D552 | - | IOMFBMaxSrcPixels | `{"MaxSrcRectWidthForPipe":[5120,0,0,0],"MaxSrcRectHeightForPipe":[4608,4608,4608,4608],"MaxSrcBufferWidth":16384,"MaxSrcBufferHeight":16384,"MaxVideoSrcDownscalingWidth":10744,"VideoClock":521064960,"PixelClock":810000000,"IOMFBMaxCompressedSizeInBytes":0,"IOMFBCompressionSupport":1,"IOMFBAsyncRGBCompressionSupport":1}` |
| 442 | D552 | - | DisplayPipePlaneBaseAlignment | `{"DefaultStride":0,"LinearX_Alignment":64,"LinearY_Alignment":1,"PlaneBaseAlignmentLinear":64}` |
| 444 | D552 | - | IOMFBScalingLimits | `{"RGBLayer_MinScaleFraction":2,"RGBLayer_MaxScale":4,"YUVLayer_MinScaleFraction":2,"YUVLayer_MaxScale":4}` |
| 446 | D565 | - | IOMFBSupportsYFlip | 1 |
| 448 | D565 | - | IOMFBSupportsXFlip | 1 |
| 450 | D565 | - | IOMFBSupportsYFlip | 1 |
| 452 | D565 | - | IOMFBSupportsXFlip | 1 |
| 454 | D565 | - | ALSSSupported | 0 |
| 456 | D565 | - | ACSSSupported | 1 |
| 458 | D565 | - | ELVSSCalDataReversed | 0 |
| 460 | D565 | - | SPLCSupported | 0 |
| 462 | D102 | - | PanelLayout | 0x0 |
| 464 | D102 | - | SupportRelbufInfoCb | 0x0 |
| 466 | D552 | - | MaxDisplayBandwidthLimitKey | `{"MaxGPBandwidthLimitKey":12800,"MaxGPLiteBandwidthLimitKey":1300,"MaxGPSumBandwidthLimitKey":25000}` |
| 500 | D563 | - | MaxVideoSrcDownscalingWidth | 10744 |
| 502 | D563 | - | VideoClock | 521064960 (0x1f0ed200) |
| 504 | D563 | - | PixelClock | 810000000 (0x30479e80) |
| 506 | D563 | - | DisplayClock | 677384448 (0x28601100) |
| 508 | D563 | - | DispPerfState | 5 |
| 644 | D104 | - | NormalModeActive | 1 |
| 658 | D561 | - | IOMFBDisplayRefresh | `{"displayMinRefreshInterval":35785667,"displayMinRefreshIntervalMachTime":200000,"displayMaxRefreshInterval":178928337,"displayMaxRefreshIntervalMachTime":1000000,"displayRefreshStep":4166000,"displayRefreshStepMachTime":100000}` |
| 713 | D406 async | IOMF | InitialPanelTemperature | 0xcf94e (16.16 = 12.974) |

Display-relevant points (fact): the DCP tells the AP the **current mode** before any mode set: `DisplayWidth 3456`, `DisplayHeight 2234`, **`DPTimingModeId 2`** (= TimingElements ID 2, 120 Hz preferred); there is **no colour-mode property** (no `DPColorModeId`) in the stream, so the active colour mode is implicit. `Brightness_Scale 0x10000` (1.0 in 16.16, same key Linux stores in `dcp->brightness.scale`), `IOMFBSecureContentFactor / IndicatorFactor / IndicatorSDRFactor 0x10000`. `IOMFBSwapAppleLookSupported 1`, `APTDevice 1`, `color-accuracy-index 239`, `W40a_Blending_OK 1`, `IOMFBWPASupported / PPASupported 1` (names only; meanings unknown). `D406 InitialPanelTemperature 0x1e0000` (30.0 in 16.16) at boot and again asynchronously at t = 12.22 s as 0xcf94e (12.97). `M3TimingParameters` = {subframe-duration-nclks 100000, display-lead-time-nclks 15256, initial-subframe-irq-time-lines 1060, subframe-interrupt-time-lines 1060, initial-vbi-advance-lines 2, vbi-advance-lines 2} (the DCP pushes these; the stage-C analysis item 13 compares them with the ADT's).

### 3.3 publish (seq 80-396): `D575` hotplug and ~160 `D300 pr_publish`

`D575 hotPlug_notify_gated` (88/76): `connected = 1`, `tiled_display[0x4c]` all zero, reply 76 zero bytes (matches Linux `[575] {0x58,0x4c}` layout `u64 connected; u8 tiled[0x4c]; null; pad`). Then 159 (162 in total on CB) `D300 {u32 id, i32 value, u32 unk0, u32 unk1}` that are the firmware's property relay; full table `dcp-rpc-decode.py --pr-table`. Facts: `id 20` = `0x012c0000` (**300.000 nits** as 16.16; Linux iomfb_template.c `case 20` for H17P >= 27.0 stores it as the initial panel level), `0x06400000` (1600.0) under ids 25 / 117 / 118 / 261, `0x10000` (1.0) under ids 18, 19, 21-24, 41, 51, 189, 229, `0x18000` (1.5) id 222, `0xc350` (50000) id 141, `0x13ec0000` (5100.0) id 225, `0xdc` (220) id 198, `0x230bc` id 181, ... All other ids carry small values (0, 1, 2, 9, 10, 0x100, 0xff, 0xffffffff). Meaning of everything but id 20 is **unknown** (no table), see section 5. The ASYNC flood is `id 119 = 0x10000` x 8,583 at 41.5 ms.

### 3.4 hw_boot (seq 398-522): `D120 start_hardware_boot` with the nested default-framebuffer sequence

`D100 match_pmu_service`, `D206 -> true`, `D207 match_backlight_service` (nests `A137 backlight_service_matched` and a `D108`), `D552` dicts (`DisplayPipeStrideRequirements {StrideLinearHorizontal 64, StrideLinearVertical 1}`, `DisplayPipePlaneBaseAlignment {PlaneBaseAlignmentLinear 64}`), `D107` + `D401 sr_get_uint_prop('PROV','minimum-frequency')` -> value 0, ret 0 (not found), `D107` + **`D408 sr_getClockFrequency('PROV', 0)` -> 810000000 Hz (0x30479e80)**, then `D563`: `MaxVideoSrcDownscalingWidth 10744, VideoClock 521064960, PixelClock 810000000, DisplayClock 677384448, DispPerfState 5`; `D124 read_edt_data('initial-vbi-advance-lines', count 1)` -> value[0] = 2, ret 0 (Linux's answer is the same: `value[0] = req->value[0], ret = 0`); `D561 M3TimingParameters`, `D552 IOMFBNumLayers {MaxNumLayers 3, FullFrameRequired 0}`, `IOMFBMaxSrcPixels {MaxSrcRectWidthForPipe [5120,0,0,0], MaxSrcRectHeightForPipe [4608 x4], MaxSrcBufferWidth/Height 16384, MaxVideoSrcDownscalingWidth 10744, VideoClock 521064960, PixelClock 810000000, IOMFBMaxCompressedSizeInBytes 0, IOMFBCompressionSupport 1, IOMFBAsyncRGBCompressionSupport 1}`, `IOMFBScalingLimits {RGBLayer_MinScaleFraction 2, RGBLayer_MaxScale 4, YUV 2/4}`, `D565` booleans (`IOMFBSupportsYFlip/XFlip 1`, `ALSSSupported 0`, `ACSSSupported 1`, `ELVSSCalDataReversed 0`, `SPLCSupported 0`), `D102 PanelLayout 0`, `SupportRelbufInfoCb 0`, `D552 MaxDisplayBandwidthLimitKey {GP 12800, GPLite 1300, GPSum 25000}`, `D000 did_boot_signal`, `D001 did_power_on_signal`, then `D120`.

Inside `D120` (CB stack depth 2) the AP issues, in this order, exactly the H17P default-framebuffer sequence Linux implements in `boot_1_5..boot_4` (`iomfb_template.c`): `A390 set_create_DFB` (0/0), `A504 create_default_fb` (-> 1), `A037 get_dfb_compression_info` (in `0`, out `u32 3, u32 1`: compression 3 = Interchange, valid), `A036 get_dfb_info` (out below), `A103 get_config_frame_size` (-> 0 x 0), `A503 get_display_size` (-> **3456 x 2234**), `A104 set_config_frame_size(3456, 2234)`, `A105 program_config_frame_size`, `A027 setup_video_limits` (outstanding 120 ms), `A529 flush_supports_power(true)`, `A035` (-> true), `A034` (-> false), `A381` (-> 0), `A135` (-> false), `A000 late_init_signal(true)` (outstanding 732 ms; -> true). `A036` out (44 bytes, raw `38613362 0080520200010000 00c0290400010000 0000000000000000 00360000 800d0000 00000000 01000000`): format fourcc **`b3a8`** (`0x62336138`, byte-reversed on the wire), two u64 `0x10002528000` and `0x1000429c000` (difference 0x1d74000 = 3456 x 2234 x 4 rounded up to 16 KiB, so the RGB10 and A8 plane DVAs of the default framebuffer: inference), `0x3600` (= 3456 x 4) and `3456`, valid flag byte@0x28 = 1. Linux reads exactly `format = out[0..3]` and `valid = out[0x28] & 1`.

### 3.5 dfb_alloc (seq 524-642): 29 x `D451 allocate_buffer` + `D201 map_buf`

Pairs of `D451 {options 0x703, size, alignment/flags} -> {dva, capacity, mem_desc_id}` and `D201 {buffer = mem_desc_id, unk 1} -> {buffer, dva, unk}` (the 16-byte H17P reply Linux describes). Sizes: two of `0x40000` (flags 4) then 27 of `0x1000` (14 with flags 4, 13 with flags 0x1000); allocation DVAs `0x10000174000`, `0x100001b8000`, `0x100001fc000`, ...; the piodma DVAs returned by `D201` are `0x10000000000`, **`0x10000044000` (= the SET_SHMEM dva, for mem_desc 2)**, `0x10000088000`, `0x10000090000`, then `0x8000` steps up to `0x10000158000`. One `D209 get_calendar_time_ms` (`0x1a1be312a89`) in the middle, one `D003 rt_bandwidth_setup_ap` before (below). Use `--phase dfb_alloc --collapse 0` for all 29.

### 3.6 modes (seq 644-696): mode / colour / timing information the DCP publishes

- `D104 NormalModeActive = 1`; `D400 get_property('PROV','power-lut-data-x', length 3072)` -> **length field 0** (no data: macOS gives none either, so Linux's stage-C line "init_power_lut: failed to read power-lut-data-x" is the normal outcome); `A385 dfb_ready_query` (-> 0); `A526 set_display_refresh_properties` (-> 1) with `D561 IOMFBDisplayRefresh {displayMinRefreshInterval 35785667, ...MachTime 200000, displayMaxRefreshInterval 178928337, ...MachTime 1000000, displayRefreshStep 4166000, ...MachTime 100000}` arriving while it is in flight (Linux's H17P comment says the same thing).
- `D586 create_default_fb_surface(3456, 2234)` -> true, with the nested **`A534 register_dfb_surface`** (surface, below), whose ack is 1.
- **The four DCPAV property blobs** (`D126 start(length)` / `D127 chunks` / `D128 end(key)`), OSSerialize binary: `ColorElements` (345 B, 1 chunk), `TimingElements` (9,513 B, 3 chunks), `PreferredTimingElements` (1,593 B), `DisplayAttributes` (285 B). Decoded:

**ColorElements: one element.**

```
ID 1  Score 240999  ElementType 1  IsVirtual false  Depth 8  PixelEncoding 0 (RGB)  DynamicRange 0 (SDR)  EOTF 0  Colorimetry 16 (Default RGB)
      SupportsDSC 0  StandardType 0  ElementData = 08000000 00000000 00000000 10000000 00000000 00000000 00000000 00000000
```

**TimingElements: six, all 3456x2234, all `ColorModes = [1]`, `UnsafeColorElementIDs = []`, `DSCRequiredColorElementIDs = []`, `DiscreteMediaRefreshRates = []`, min/max VRR 0/0, TimingType 3, AspectRatio 12, ValidPixelEncodings 1**:

| ID | refresh (SyncRate 16.16) | precise | Htotal x Vtotal | score | flags |
|---|---|---|---|---|---|
| 2 | 120.0000 | 120.0000 | 3536 x 2456 | 17026 | **IsPreferred** |
| 3 | 60.0000 | 60.0000 | 3536 x 2456 | 15523 | IsPromoted |
| 4 | 48.0000 | 48.0000 | 3536 x 2456 | 15419 | IsPromoted |
| 5 | 60.0000 | 59.9401 | 3536 x 2456 | 15523 | IsPromoted |
| 6 | 48.0000 | 47.9520 | 3536 x 2456 | 15418 | IsPromoted |
| 7 | 50.0000 | 50.0000 | 3536 x 2946 | 15436 | IsPromoted |

H: active 3456, front porch 8, sync 32, back porch 40, total 3536; V: active 2234, front porch 118, sync 8, back porch 96, total 2456 (ID 7: front porch 608, total 2946). `ElementData[80]` of ID 2 = `00000000 d00d0000 800d0000 20000000 28000000 08000000 53b82601 01000000 00000000 98090000 ba080000 08000000 60000000 76000000 01007800 01000000 00000000 50a41d3e 0c000000 00000000`: word 1 Htotal, 2 Hactive, 3 Hsync, 4 Hback, 5 Hfront, 6 precise H rate, 9 Vtotal, 10 Vactive, 11 Vsync, 12 Vback, 13 Vfront, 14 high half = refresh in Hz (0x78 = 120), word 17 = **pixel clock 0x3e1da450 = 1,042,130,000 Hz** (inference for the field meaning; consistent with 3536 x 2456 x 120). `PreferredTimingElements` = timing ID 2 alone. `DisplayAttributes` = `{TiledDisplayInfo {}, DisplayAllocation {MainUFP 0, PeerUFP 0, ExtraPipes 0, UseSingleTile false}, ProductAttributes {ManufacturerID "00-10-fa", LegacyManufacturerID 1552, ProductID 58502558069825}}` (ProductID is display data of the internal panel, quoted as seen).

Then `D126 ...` x4, `D110 create_iomfb_service`, `D122 is_waking_from_hibernate -> false`, and the ack of `A451` (seq 699).

### 3.7 async_start / ap_init / steady

- ASYNC: `D204 get_ideal_screen_space` -> **2** (Linux: 1 = sRGB/unspecified, **2 = P3**, 3 = AdobeRGB, from `apple,artwork-display-gamut`), `D006 set_frame_sync_props` (84/80; the reply is the request's words with `0x10000` at +0x24/+0x28/+0x2c, exactly what Linux's `dcpep_cb_set_frame_sync_props_h17p` writes; 5 times at t = 12.12, 12.46, 16.32, 111.6, 112.6 s), async `D406 InitialPanelTemperature`.
- AP commands after the start completes (t = 12.51-12.71 s): `A515 (0x800, 0x20)` -> void; OOBCMD `A400` -> 0; `A353` -> **u64 0x7f26c8 = 8,333,000** (inference: 1/120 s in ns); OOBCMD `A384` -> 0; `A379` -> u32 **0x7f2600 = 8,332,800**; `A378` (in 44 zero bytes) -> 40 bytes `00320000 00000000 00640000 00000000 84670000 00000000 00140000 001e0000 401a0000 01000000` (u32 words 0x3200, 0, 0x6400, 0, 0x6784, 0, 0x1400, 0x1e00, 0x1a40, 1; 12800 and 25600 echo the `MaxGPBandwidthLimitKey` 12800 / GPSum 25000 neighbourhood: unknown struct); `A391 vi_set_temperature_hint` -> 0 (interleaved with another `D109 -> false`); `A136 pmu_service_matched` -> false. Then only `D006` and the id-119 flood.

### 3.8 Surface structures (the "first surface"; no swap exists in this capture)

The only surface in the capture is the default-framebuffer surface that the AP registers inside `D586` via `A534` (560 bytes = `struct dcp_surface` 509 + 47 padding + `surface_null` + pad; Linux `dcp_surface_v27`, `0x22c` + null). Every nonzero byte of the 509-byte base: `+0x02 = 1` (is_premultiplied), `+0x0b..0x0e = 38 61 33 62` (format `b3a8`), `+0x19 = 1` (pix_size 1), `+0x1b = 1`, `+0x1c = 1` (pel 1x1), `+0x29..0x2c = 00 c0 5e 02` (**buf_size = 0x025ec000 = 39,763,968**), `+0x35 = 3` (**surface_id 3**), `+0x51 = 1` (has_comp), `+0x149 = 1` (has_planes). Everything else (stride, width, height, colorspace, xfer_func, planes, compression infos) is zero; the 47 padding bytes are `0xaa` fill and the null flag is 0. `xfer_func`/`colorspace` of the default surface are 0: it carries no colour tag.

Not in this capture: swap record (27.3 `IOMFBSwap` 0x830 bytes, request 0x1144, from the Linux commit's static analysis), `set_digital_out_mode` arguments (`color_mode_id`, `timing_mode_id` as two u32), brightness / EDR fields in a swap. The decoder already knows these layouts (`A456`, `A458`, `A463`, `A500`, `A535`) and will decode them when a capture contains them.

### 3.9 Brightness / backlight (what is in the stream)

`D111 create_backlight_service -> true`, `D207 match_backlight_service` + `A137 backlight_service_matched`, `D112 create_nvram_service -> true`, `D102/D104` flags, `D414 Brightness_Scale 0x10000`, **`D300 id 20 = 0x012c0000` -> 300.0 nits**, `D300 id 25/117/118/261 = 0x06400000` (1600.0), `D414 IOMFBTestBacklightDimValue 12288`, `D565 ALSSSupported 0 / ACSSSupported 1`. No AP-side brightness call exists (no `A478 set_brightness_correction`, no swap brightness fields): macOS did not set a level, the DCP kept iBoot's 300 nits.

## 4. (c) Draft firmware-27.3 IOMFB method table for the Linux driver

Where the driver keys it: `apple,firmware-compat = <27 3 0>` on the dcp node -> `dcp_check_firmware_version()` (hw `firmware_compat == DCP_FIRMWARE_V_27_0`) reads the property, `iomfb_v27_methods("27.3.0")` returns `dcp_methods_27_3`, stored as `dcp->v27_methods`; `NULL` = "no 27.x method table", refused at probe. All three 27.x builds share `DCP_FIRMWARE_V_27_0` and the h17p template; only the table (and for 27.3 the swap wire, `iomfb_v27_swap_wire()`) differ. **Result: the `27.3.0` entry already in `wt-dcp-27` (`716bce007fd3`) is consistent with this capture; no tag needs to change.** Status per entry below.

### 4.1 Diff 27.0 -> 27.2 -> 27.3, with capture evidence

Rules (all verified by the table): UnifiedPipeline `A0xx`/`A1xx` and the UP-pipe `A352/A353` tags are unchanged in all three; 27.0 -> 27.2: every IOMobileFramebufferAP method +50 (`A401 start_signal` -> `A451`), `set_create_DFB` A389 -> A390, `vi_set_temperature_hint` A390 -> A391, `dfb_ready_query` A384 -> A385; 27.2 -> 27.3: every AP method >= A521 +1 (`set_display_refresh_properties` A525 -> A526, `flush_supports_power` A528 -> A529, `abort_swaps_dcp` A529 -> A530, `register_dfb_surface` A533 -> A534, `set_power_state` A534 -> A535, `pipe_query_474` A535 -> A536, `pipe_set_476` A537 -> A538, `pipe_query_478` A539 -> A540).

| Linux method | 27.0 tag | 27.2 tag | **27.3 tag** | in/out (27.3) | status | evidence in this capture |
|---|---|---|---|---|---|---|
| dcpep_late_init_signal | A000 | A000 | **A000** | 4/4 | **confirmed** | 1 call(s), first seq 521, AP>DCP ctx CB, in/out 4/4 |
| dcpep_setup_video_limits | A027 | A027 | **A027** | 0/0 | **confirmed** | 1 call(s), first seq 489, AP>DCP ctx CB, in/out 0/0 |
| dcpep_pipe_cfg_031 | A033 | A033 | **A033** | 0x6c/0 | assumed | not called in this capture |
| dcpep_dfb_query | A035 | A035 | **A035** | 0/4 | **confirmed** | 1 call(s), first seq 513, AP>DCP ctx CB, in/out 0/4 |
| dcpep_get_dfb_info | A036 | A036 | **A036** | 0x2c/0x2c | **confirmed** | 1 call(s), first seq 479, AP>DCP ctx CB, in/out 44/44 |
| dcpep_get_dfb_compression_info | A037 | A037 | **A037** | 8/8 | **confirmed** | 1 call(s), first seq 477, AP>DCP ctx CB, in/out 8/8 |
| dcpep_get_dfb_layout | A103 | A103 | **A103** | 0xc/8 | **confirmed** | 1 call(s), first seq 481, AP>DCP ctx CB, in/out 12/8 |
| dcpep_set_dfb_dimensions | A104 | A104 | **A104** | 8/0 | **confirmed** | 1 call(s), first seq 485, AP>DCP ctx CB, in/out 8/0 |
| dcpep_commit_dfb_info | A105 | A105 | **A105** | 0/0 | **confirmed** | 1 call(s), first seq 487, AP>DCP ctx CB, in/out 0/0 |
| iomfbep_a131_pmu_service_matched | A136 | A136 | **A136** | 0/4 | **confirmed** | 1 call(s), first seq 813, AP>DCP ctx CMD, in/out 0/4 |
| iomfbep_a132_backlight_service_matched | A137 | A137 | **A137** | 0/4 | **confirmed** | 1 call(s), first seq 403, AP>DCP ctx CB, in/out 0/4 |
| dcpep_pipe_set_352 | A352 | A352 | **A352** | ? (m1n1 applyProperty: 8/4) | assumed | not called in this capture |
| dcpep_pipe_query_353 | A353 | A353 | **A353** | 0/8 | **confirmed** | 1 call(s), first seq 787, AP>DCP ctx CMD, in/out 0/8 |
| dcpep_dfb_ready_query | A384 | A385 | **A385** | 0/4 | **confirmed** | 1 call(s), first seq 655, AP>DCP ctx CB, in/out 0/4 |
| dcpep_set_create_dfb | A389 | A390 | **A390** | 0/0 | **confirmed** | 1 call(s), first seq 473, AP>DCP ctx CB, in/out 0/0 |
| iomfbep_a358_vi_set_temperature_hint | A390 | A391 | **A391** | 0/4 | **confirmed** | 1 call(s), first seq 805, AP>DCP ctx CMD, in/out 0/4 |
| dcpep_start_signal | A401 | A451 | **A451** | 0/4 | **confirmed** | 1 call(s), first seq 3, AP>DCP ctx CMD, in/out 0/4 |
| dcpep_swap_start | A406 | A456 | **A456** | 0x10/8 | assumed | not called in this capture |
| dcpep_swap_submit | A408 | A458 | **A458** | 0x1144/0xc (27.0/27.2: 0xff4/0xc) | assumed | not called in this capture |
| dcpep_set_display_device | A411 | A461 | **A461** | 4/4 | assumed | not called in this capture |
| dcpep_is_main_display | A412 | A462 | **A462** | 0/4 | assumed | not called in this capture |
| dcpep_set_digital_out_mode | A413 | A463 | **A463** | 8/4 | assumed | not called in this capture |
| dcpep_pipe_cfg_414 | A414 | A464 | **A464** | 8/8 | assumed | not called in this capture |
| dcpep_pipe_cfg_415 | A415 | A465 | **A465** | 0xc/0xc | assumed | not called in this capture |
| iomfbep_set_matrix | A423 | A473 | **A473** | ? | assumed | not called in this capture |
| iomfbep_get_color_remap_mode | A427 | A477 | **A477** | ? | assumed | not called in this capture |
| iomfbep_set_brightness_correction | A428 | A478 | **A478** | 4/4 | assumed | not called in this capture |
| dcpep_set_parameter_dcp | A450 | A500 | **A500** | 0x28/4 | assumed | not called in this capture |
| dcpep_get_dfb_state | A453 | A503 | **A503** | 4/8 | **confirmed** | 1 call(s), first seq 483, AP>DCP ctx CB, in/out 4/8 |
| dcpep_create_default_fb | A454 | A504 | **A504** | 0/4 | **confirmed** | 1 call(s), first seq 475, AP>DCP ctx CB, in/out 0/4 |
| dcpep_enable_disable_video_power_savings | A458 | A508 | **A508** | 4/4 | assumed | not called in this capture |
| dcpep_first_client_open | A466 | A516 | **A516** | 0/0 | assumed | not called in this capture |
| iomfbep_last_client_close | A467 | A517 | **A517** | ? | assumed | not called in this capture |
| dcpep_set_display_refresh_properties | A475 | A525 | **A526** | 0/4 | **confirmed** | 1 call(s), first seq 657, AP>DCP ctx CB, in/out 0/4 |
| dcpep_flush_supports_power | A478 | A528 | **A529** | 4/0 | **confirmed** | 1 call(s), first seq 511, AP>DCP ctx CB, in/out 4/0 |
| iomfbep_abort_swaps_dcp | A479 | A529 | **A530** | ? | assumed | not called in this capture |
| dcpep_register_dfb_surface | A483 | A533 | **A534** | 0x230/4 | **confirmed** | 1 call(s), first seq 663, AP>DCP ctx CB, in/out 560/4 |
| dcpep_set_power_state | A484 | A534 | **A535** | 0x10/8 | assumed | not called in this capture |
| dcpep_pipe_query_474 | A485 | A535 | **A536** | 0/4 | assumed | not called in this capture |
| dcpep_pipe_set_476 | A487 | A537 | **A538** | 4/0 | assumed | not called in this capture |
| dcpep_pipe_query_478 | A489 | A539 | **A540** | 0/4 | assumed | not called in this capture |

Sizes are `in/out` bytes; for the 20 confirmed rows they are the observed `in_len/out_len`. `A353`: confirmed tag and 0/8 shape, name is Linux's placeholder (m1n1's `get_system_type` returned 4 bytes). `A385`: confirmed tag and shape, **its position is the one the 27.2 commit message called "inferred, not yet observed"**; the macOS call sits where Linux never calls it, so the name stays by-table. `A503`: Linux's name `get_dfb_state` vs payload `(w, h)` (m1n1 `get_display_size`). Swap: `A458` request is **0x1144** on 27.3 (27.0/27.2 0xff4), response `0xc`; **not observed here**.

### 4.2 The table in the driver's shape

```c
/* Firmware 27.3 (AppleDCP-1317.60.10, mBoot-20457.60.65.0.1), apple,firmware-compat "27.3.0".
 * CONFIRMED = called in the macOS 27.3 capture with these in/out lengths (captures/dcp-rpc-sync-20261109-0243.jsonl). */
static const struct dcp_method_entry dcp_methods_27_3[dcpep_num_methods] = {
	IOMFB_METHOD("A000", dcpep_late_init_signal),                        /* in/out 4/4; CONFIRMED, capture seq 521 */
	IOMFB_METHOD("A027", dcpep_setup_video_limits),                      /* in/out 0/0; CONFIRMED, capture seq 489 */
	IOMFB_METHOD("A033", dcpep_pipe_cfg_031),                            /* in/out 0x6c/0; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A035", dcpep_dfb_query),                               /* in/out 0/4; CONFIRMED, capture seq 513 */
	IOMFB_METHOD("A036", dcpep_get_dfb_info),                            /* in/out 0x2c/0x2c; CONFIRMED, capture seq 479 */
	IOMFB_METHOD("A037", dcpep_get_dfb_compression_info),                /* in/out 8/8; CONFIRMED, capture seq 477 */
	IOMFB_METHOD("A103", dcpep_get_dfb_layout),                          /* in/out 0xc/8; CONFIRMED, capture seq 481 */
	IOMFB_METHOD("A104", dcpep_set_dfb_dimensions),                      /* in/out 8/0; CONFIRMED, capture seq 485 */
	IOMFB_METHOD("A105", dcpep_commit_dfb_info),                         /* in/out 0/0; CONFIRMED, capture seq 487 */
	IOMFB_METHOD("A136", iomfbep_a131_pmu_service_matched),              /* in/out 0/4; CONFIRMED, capture seq 813 */
	IOMFB_METHOD("A137", iomfbep_a132_backlight_service_matched),        /* in/out 0/4; CONFIRMED, capture seq 403 */
	IOMFB_METHOD("A352", dcpep_pipe_set_352),                            /* in/out ? (m1n1 applyProperty: 8/4); assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A353", dcpep_pipe_query_353),                          /* in/out 0/8; CONFIRMED, capture seq 787 */
	IOMFB_METHOD("A385", dcpep_dfb_ready_query),                         /* in/out 0/4; CONFIRMED, capture seq 655 */
	IOMFB_METHOD("A390", dcpep_set_create_dfb),                          /* in/out 0/0; CONFIRMED, capture seq 473 */
	IOMFB_METHOD("A391", iomfbep_a358_vi_set_temperature_hint),          /* in/out 0/4; CONFIRMED, capture seq 805 */
	IOMFB_METHOD("A451", dcpep_start_signal),                            /* in/out 0/4; CONFIRMED, capture seq 3 */
	IOMFB_METHOD("A456", dcpep_swap_start),                              /* in/out 0x10/8; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A458", dcpep_swap_submit),                             /* in/out 0x1144/0xc (27.0/27.2: 0xff4/0xc); assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A461", dcpep_set_display_device),                      /* in/out 4/4; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A462", dcpep_is_main_display),                         /* in/out 0/4; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A463", dcpep_set_digital_out_mode),                    /* in/out 8/4; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A464", dcpep_pipe_cfg_414),                            /* in/out 8/8; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A465", dcpep_pipe_cfg_415),                            /* in/out 0xc/0xc; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A473", iomfbep_set_matrix),                            /* in/out ?; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A477", iomfbep_get_color_remap_mode),                  /* in/out ?; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A478", iomfbep_set_brightness_correction),             /* in/out 4/4; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A500", dcpep_set_parameter_dcp),                       /* in/out 0x28/4; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A503", dcpep_get_dfb_state),                           /* in/out 4/8; CONFIRMED, capture seq 483 */
	IOMFB_METHOD("A504", dcpep_create_default_fb),                       /* in/out 0/4; CONFIRMED, capture seq 475 */
	IOMFB_METHOD("A508", dcpep_enable_disable_video_power_savings),      /* in/out 4/4; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A516", dcpep_first_client_open),                       /* in/out 0/0; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A517", iomfbep_last_client_close),                     /* in/out ?; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A526", dcpep_set_display_refresh_properties),          /* in/out 0/4; CONFIRMED, capture seq 657 */
	IOMFB_METHOD("A529", dcpep_flush_supports_power),                    /* in/out 4/0; CONFIRMED, capture seq 511 */
	IOMFB_METHOD("A530", iomfbep_abort_swaps_dcp),                       /* in/out ?; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A534", dcpep_register_dfb_surface),                    /* in/out 0x230/4; CONFIRMED, capture seq 663 */
	IOMFB_METHOD("A535", dcpep_set_power_state),                         /* in/out 0x10/8; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A536", dcpep_pipe_query_474),                          /* in/out 0/4; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A538", dcpep_pipe_set_476),                            /* in/out 4/0; assumed (static dispatch emulation, 716bce007fd3) */
	IOMFB_METHOD("A540", dcpep_pipe_query_478),                          /* in/out 0/4; assumed (static dispatch emulation, 716bce007fd3) */
};
```

### 4.3 Callbacks (D tags): the 27.0 table stands for 27.3

Fact: 41 distinct callback tags were seen, **every one is in Linux's 27.0 `cb_handlers[]`, with in/out lengths identical to `callback_sizes[]`** (column "MATCH"). Linux therefore needs **no new callback entry** for 27.3 from this capture. Unseen entries (`D113` CoreAnalytics, `D114/D115` tiling, `D130-D133`, `D452-D454`, `D567-D574`, `D589`, `D594-D599`, ...) are fine as they are but unverified for 27.3.

| tag | Linux 27.0 handler | in/out (Linux 27.0 callback_sizes) | seen in 27.3 capture | m1n1-derived / observed name |
|---|---|---|---|---|
| D000 | dcpep_cb_d000_h17p | 0x0/0x4 | 1 x, 0/4 MATCH | did_boot_signal |
| D001 | trampoline_true | 0x0/0x4 | 1 x, 0/4 MATCH | did_power_on_signal |
| D002 | trampoline_nop | 0x0/0x0 | - |  |
| D003 | trampoline_rt_bandwidth_h17p | 0x4/0x14 | 1 x, 4/20 MATCH | rt_bandwidth_setup_ap (H17P reply: 4 in / 20 out) |
| D006 | trampoline_set_frame_sync_props_h17p | 0x54/0x50 | 5 x, 84/80 MATCH | set_frame_sync_props (84 in / 80 out) |
| D100 | iomfbep_cb_match_pmu_service | 0x0/0x0 | 1 x, 0/0 MATCH | match_pmu_service |
| D101 | trampoline_zero | 0x0/0x4 | 1 x, 0/4 MATCH | get_display_default_stride (m1n1 UNK_get_some_field) |
| D102 | trampoline_nop | 0x44/0x0 | 2 x, 68/0 MATCH | set_number_property |
| D104 | trampoline_nop | 0x44/0x0 | 1 x, 68/0 MATCH | set_boolean_property |
| D106 | trampoline_nop | 0x40/0x0 | - |  |
| D107 | trampoline_true | 0x0/0x4 | 8 x, 0/4 MATCH | create_provider_service |
| D108 | trampoline_true | 0x0/0x4 | 2 x, 0/4 MATCH | create_product_service |
| D109 | trampoline_true | 0x0/0x4 | 3 x, 0/4 MATCH | create_PMU_service |
| D110 | trampoline_true | 0x0/0x4 | 2 x, 0/4 MATCH | create_iomfb_service |
| D111 | trampoline_create_backlight_service | 0x0/0x4 | 1 x, 0/4 MATCH | create_backlight_service |
| D112 | trampoline_true | 0x0/0x4 | 1 x, 0/4 MATCH | create_nvram_service |
| D113 | dcpep_cb_core_analytics_v27 | 0x1044/0x1004 | - |  |
| D114 | trampoline_tiling_state_v27 | 0x10/0x8 | - |  |
| D115 | trampoline_set_tiling_state_v27 | 0x10/0x4 | - |  |
| D116 | trampoline_nop | 0xc/0x0 | - |  |
| D117 | trampoline_zero | 0x14/0x4 | - |  |
| D118 | trampoline_zero | 0x3e88/0x4 | - |  |
| D119 | trampoline_zero | 0x4/0x4 | - |  |
| D120 | dcpep_cb_boot_1 | 0x0/0x4 | 1 x, 0/4 MATCH | start_hardware_boot |
| D121 | trampoline_false | 0x0/0x4 | - |  |
| D122 | trampoline_false | 0x0/0x4 | 1 x, 0/4 MATCH | is_waking_from_hibernate |
| D123 | trampoline_zero | 0x0/0x4 | - |  |
| D124 | trampoline_read_edt_data | 0x64/0x24 | 1 x, 100/36 MATCH | read_edt_data |
| D126 | trampoline_prop_start | 0x4/0x4 | 4 x, 4/4 MATCH | setDCPAVPropStart |
| D127 | trampoline_prop_chunk | 0x1008/0x4 | 6 x, 4104/4 MATCH | setDCPAVPropChunk |
| D128 | trampoline_prop_end | 0x40/0x4 | 4 x, 64/4 MATCH | setDCPAVPropEnd |
| D129 | trampoline_allocate_bandwidth | 0x1c/0x14 | - |  |
| D130 | trampoline_update_external_counts_v27 | 0x8/0x0 | - |  |
| D131 | trampoline_get_external_counts_v27 | 0x10/0xc | - |  |
| D132 | trampoline_apply_suppression_v27 | 0x4/0x0 | - |  |
| D133 | trampoline_display_identity_v27 | 0x0/0x4 | - |  |
| D201 | trampoline_map_piodma | 0xc/0x10 | 29 x, 12/16 MATCH | map_buf (piodma) |
| D202 | trampoline_unmap_piodma | 0x18/0x0 | - |  |
| D204 | trampoline_ideal_screen_space_v27 | 0x0/0x4 | 1 x, 0/4 MATCH | get_ideal_screen_space (new in 27.x) |
| D206 | iomfbep_cb_match_pmu_service_2 | 0x0/0x4 | 1 x, 0/4 MATCH | match_pmu_service_2 |
| D207 | iomfbep_cb_match_backlight_service | 0x0/0x4 | 1 x, 0/4 MATCH | match_backlight_service |
| D208 | trampoline_nop | 0x4/0x0 | - |  |
| D209 | trampoline_get_time | 0x0/0x8 | 1 x, 0/8 MATCH | get_calendar_time_ms (get_time) |
| D300 | trampoline_pr_publish | 0x10/0x0 | 8745 x, 16/0 MATCH | pr_publish (id, value, unk0, unk1) |
| D400 | trampoline_get_data_prop_v27 | 0x4c/0xc04 | 1 x, 76/3076 MATCH | get_property (out 0xc04) |
| D401 | trampoline_get_uint_prop | 0x50/0xc | 2 x, 80/12 MATCH | sr_get_uint_prop |
| D404 | trampoline_nop | 0x48/0x0 | - |  |
| D406 | trampoline_set_fx_prop | 0x48/0x0 | 2 x, 72/0 MATCH | set_fx_prop |
| D408 | trampoline_get_frequency_v27 | 0x8/0x8 | 2 x, 8/8 MATCH | sr_getClockFrequency |
| D411 | trampoline_map_reg | 0x10/0x1c | - |  |
| D413 | trampoline_true | 0x1048/0x4 | 1 x, 4168/4 MATCH | sr_setProperty_dict |
| D414 | trampoline_sr_set_property_int | 0x50/0x4 | 23 x, 80/4 MATCH | sr_setProperty_int |
| D415 | trampoline_true | 0x4c/0x4 | 5 x, 76/4 MATCH | sr_setProperty_bool |
| D451 | trampoline_allocate_buffer_v27 | 0x14/0x14 | 29 x, 20/20 MATCH | allocate_buffer (27.x: 20 in / 20 out) |
| D452 | trampoline_buffer_lifecycle_v27 | 0x8/0x4 | - |  |
| D453 | trampoline_buffer_lifecycle_v27 | 0x8/0x4 | - |  |
| D454 | trampoline_release_mem_desc | 0x4/0x4 | - |  |
| D552 | trampoline_true | 0x1044/0x4 | 7 x, 4164/4 MATCH | setProperty_dict |
| D561 | trampoline_true | 0x1044/0x4 | 2 x, 4164/4 MATCH | setProperty_dict |
| D563 | trampoline_true | 0x4c/0x4 | 10 x, 76/4 MATCH | setProperty_int |
| D565 | trampoline_true | 0x48/0x4 | 8 x, 72/4 MATCH | setProperty_bool |
| D567 | trampoline_true | 0x80/0x4 | - |  |
| D569 | trampoline_set_boolean_property_v27 | 0x44/0x4 | - |  |
| D572 | trampoline_zero | 0x4/0x4 | - |  |
| D574 | iomfbep_cb_video_range_h17p | 0x4/0x8 | - |  |
| D575 | trampoline_hotplug_h17p | 0x58/0x4c | 1 x, 88/76 MATCH | hotPlug_notify_gated (88 in / 76 out) |
| D576 | trampoline_nop | 0x4/0x0 | - |  |
| D586 | iomfbep_cb_create_dfb_surface | 0x8/0x4 | 1 x, 8/4 MATCH | create_default_fb_surface (m1n1 V14_7 D582 +4) |
| D587 | trampoline_nop | 0x0/0x0 | - |  |
| D588 | trampoline_nop | 0x18/0x0 | - |  |
| D589 | trampoline_swap_info_h17p | 0xe4/0xe0 | - |  |
| D592 | trampoline_nop | 0x0/0x0 | - |  |
| D594 | trampoline_swap_complete | 0x730/0x0 | - | swap_complete (0x730) |
| D596 | trampoline_swap_complete_intent_gated | 0x14/0x0 | - |  |
| D597 | trampoline_abort_swap_ap_gated | 0x4/0x0 | - |  |
| D598 | trampoline_enable_backlight_message_ap_gated | 0x4/0x0 | - |  |
| D599 | trampoline_nop | 0x4/0x0 | - |  |
| D601 | trampoline_false | 0x0/0x4 | - |  |
| D602 | trampoline_false | 0x0/0x4 | - |  |
| D603 | trampoline_nop | 0x0/0x0 | 1 x, 0/0 MATCH | find_swap_function_gated (m1n1 V14_7 D598 +5) |

Behavioural differences to check (fact = what macOS answered): `D109` false (Linux true); `D408` 810 MHz (Linux 0 with empty `apple,clock-ids`); `D400` length 0 (Linux copies a DT property if present); `A534` reply 1 (section 6).

## 5. (d) HDR-relevant findings

### 5.1 What this boot carries (facts)

| where | field | value |
|---|---|---|
| `D128 ColorElements` | element list | **one**: ID 1, Depth 8, PixelEncoding 0 (RGB), DynamicRange 0 (SDR), EOTF 0, Colorimetry 16, SupportsDSC 0, StandardType 0, Score 240999 |
| `D128 TimingElements` (x6) | `ColorModes` | `[1]` for every timing; `UnsafeColorElementIDs`/`DSCRequiredColorElementIDs` empty |
| `D128 TimingElements` | VRR | `MinimumVariableRefreshRate`/`Maximum...` 0 on every timing |
| `D414 DPTimingModeId` | current timing | 2 |
| `D414` (none) | current colour mode | no property carries it |
| `D204` (ASYNC) | ideal screen space | 2 (P3) |
| `D414 Brightness_Scale`, `IOMFBSecureContentFactor`, `IOMFBSecureIndicatorFactor`, `IOMFBSecureIndicatorSDRFactor` | | 0x10000 each (1.0) |
| `D414` / `D415` | `IOMFBSwapAppleLookSupported 1`, `APTDevice 1`, `color-accuracy-index 239`, `W40a_Blending_OK 1` | names only |
| `D300 id 20` | initial panel level | 0x012c0000 = 300.0 nits |
| `D300 ids 25, 117, 118, 261` | | 0x06400000 = 1600.0 (16.16) |
| `D300 ids 18, 19, 21-24, 41, 51, 189, 229` | | 0x10000 (1.0) |
| `D300 id 222` / `141` / `225` | | 0x18000 (1.5) / 0xc350 (50000) / 0x13ec0000 (5100.0) |
| swap / `A463` / EDR | | **not present in this capture** |

The decoder's enum note (Linux `parser.h:57`): EOTF 0 SDR gamma, 1 "HDR gamma", 2 ST 2084 PQ, 3 HLG; colorimetry 16 = Default RGB, 9 = BT.2020 RGB. So **no call in this boot carries a PQ / HLG / BT.2020 / 10-bit / YCbCr colour field with a non-SDR value**, and the colour elements are exactly the data Linux's `parse_color_modes()` would reduce to `sdr_rgb = 8-bit`, `pq = none`, `sdr_rgb10 = none` (HDR-STUDY.md rung 0 asked for exactly this list: it is now known without a Linux run).

### 5.2 What follows (inference, ranked by confidence)

1. **High: patch 0003's rung (b) "PQ element selected at a mode set" cannot happen with this firmware's list**: there is no PQ element to select, so `set_digital_out_mode` can only ever be sent with `color_mode_id = 1` (and `timing_mode_id` 2..7). HDR on the J716s internal panel has to be the **EDR path on the SDR link** (HDR-STUDY.md rung (c)), i.e. the colour/EDR information travels in the swap, not in the mode set. macOS cannot do better on the same firmware list.
2. **Medium-high: what the swap must therefore carry for HDR** (not observed; taken from Linux's desktop-26.6 EDR implementation, `dcp-edr.h`, and `iomfb_v27.h`): per surface `colorspace` (`dcp_surface +0x14`: 9 BT.2020, 11/12 P3) and `xfer_func` (`+0x13`: 16 PQ, 18 HLG, 8 linear for FP16 `AhGR` EDR surfaces) in the 0x22c-byte surface records; the swap-record brightness block (`brightness_update` byte, panel level as a binary64 in nits; on 27.3 these sit **0x60 later than in 27.2**: 0x3b4 / 0x3be, and the desktop-26.6 EDR fields at 0x358 / 0x376 / 0x37e / 0x3e6 move with the same rule); an HDR/EDR on-off is a mode set only if the firmware needs it (HDR-STUDY.md reports ~385 ms dark for a VRR toggle). The ADT's `EDRPotentialHeadroom` = 16.0 (HDR-STUDY.md section 2) and the 1600.0 / 300.0 numbers above are the likely bounds.
3. **Medium: panel peak luminance is probably already published** as `D300 pr_publish` value `0x06400000` (1600.0 nits) under ids 25, 117, 118, 261. HDR-STUDY.md found that on fw 27 the A128 `max_panel_brightness` call does not exist, leaving `peak_nits = 0` (no EDR, no EDID HDR block); `iomfb_cb_pr_publish()` ignores everything except id 20. Reading the 1600.0 from these ids (which of the four is "peak" is unknown: vary the level / HDR state in a capture and see which change) would give the driver its peak without A128. Treat as a hypothesis until a capture with HDR content shows an id move.
4. **Medium-low: `IOMFBSwapAppleLookSupported = 1` and `Brightness_Scale` / `IOMFBSecureContentFactor`** are the firmware-side knobs of macOS's tone mapping ("Apple Look") and secure-content dimming; whether Linux has to answer anything for them is unknown.

### 5.3 What a macOS capture must contain to settle HDR (not available in this one)

Boot macOS **with** WindowServer (not `nodisk`), same SYNC module (`HV27_DCP_TRACE_MODE=sync`), then (a) idle desktop, (b) brightness slider min/max, (c) an HDR clip (e.g. an HDR photo / HDR YouTube in Safari at full screen). In the JSONL look for: `A516 first_client_open`, `A463` (colour id, timing id), `A456/A458` pairs (diff two consecutive swaps field by field in the 0x1144-byte request: bytes that change between SDR and HDR content), `A478`, `A500 set_parameter_dcp` (param ids), `A473`, `A477`, which `D300` ids 20 / 25 / 117 / 118 / 261 / 222 / 225 change, any re-published `ColorElements`. The decoder will decode all of these once present; raise the module's 4096-byte payload cap (the swap request is 4,420 bytes) before that run or the swap tail is lost.

## 6. Cross-checks against Linux (stage C, `contrib/validated/display/stage-c-analysis.md`)

| item | macOS 27.3 (this capture, fact) | Linux today | note |
|---|---|---|---|
| `D408 sr_getClockFrequency('PROV', 0)` | **810,000,000 Hz** (seq 419, 497; pairing verified) | 0 (`apple,clock-ids` empty; stage-C item 8 "EDT ERROR ... Giving up on frequencies") | then the DCP publishes `VideoClock 521064960, PixelClock 810000000, DisplayClock 677384448, DispPerfState 5` (`D563`) |
| `D401 'minimum-frequency'` | value 0, ret 0 | not found | same |
| `D003 rt_bandwidth_setup_ap` | out `{u64 0x286720000, u64 0, u32 0}` = PMC 0x286700000 + 0x20000 | derived statically | **confirms `BW-SCRATCH.md` (offset 0x20000) on real firmware** (D003 is paired correctly: seq 522/523) |
| `A534 register_dfb_surface` | **reply = 1** (`01000000`), then `D586` answered `true` | `complete_dfb_surface()` answers `D586` with `out && !get_unaligned_le32(out)`, i.e. **false when the reply is non-zero** | inference: Linux inverts the success test on 27.3; matches stage-C item 16 "Creating default FB surface failed - width = 3456, height = 2234" (no driver error logged). Check by logging the A534 reply in `complete_dfb_surface()` |
| default surface record | `surface_id = 3`, `buf_size = 0x025ec000`, `pix_size 1`, `pel 1x1`, `is_premultiplied 1`, `has_comp 1`, `has_planes 1`, format `b3a8`, all else 0 | `surface_id = 5`; `buf_size` from `apple_dcp_dfb_allocation()` | the allocation formula gives **0x025ec000** for 3456x2234, comp 3 (4 B plane 31,490,048 + A8 plane 8,265,728 = 39,755,776, rounded to 16 KiB = 39,763,968): the Linux sizing is right; only `surface_id` differs |
| `A036` / `A037` | format `b3a8` (`0x62336138`), compression `3`, valid bits 1 | same parse (`out[0..3]`, `out[0x28]&1`, `out[4]&1`) | agrees |
| `D400 power-lut-data-x` | length field 0 (no data) | no DT property -> no data | stage-C item 15 is the normal outcome |
| `D124 initial-vbi-advance-lines` | value[0] 2, ret 0 | identical reply | |
| `D006` reply | `0x10000` at +0x24/+0x28/+0x2c | identical | |
| `D109 create_PMU_service` | **false** x3 | `[109] = trampoline_true` | unverified effect |
| `D586`, `D120` ordering, `A000` after the dfb block, `A529(true)` after `A027` | as Linux's `boot_1_5..boot_4` | same | |

## 7. Limits

- Facts above are for the **boot of macOS 27.3 beta 1's AppleDCP**; no swap, mode set, brightness set or HDR content ran. Section 5.2 items are inference.
- Return values of six calls are lost (section 0). Status letters `S` mean "layout seen, name by shift pattern".
- `D127` offset/length and every payload byte past 4096 are not in the JSONL (the DCPAV blobs were reassembled under a contiguity assumption that parsed cleanly).
- m1n1's tables stop at V14_7 (no 27.x): the names for `D107..D112`, `A034`, `A035`, `A135`, `A353`, `D586`, `D603` are shift-pattern or Linux-table names, flagged `S`.
- Reproduce: `python3 -I captures/dcp-rpc-decode.py --phases | --summary | --md-tags | --pr-table | --tag D414 | --phase modes --dicts | --raw`.
