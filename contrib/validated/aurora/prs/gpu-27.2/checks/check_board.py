#!/usr/bin/env python3
"""Check the J716S board tables in g17/fw/m5/initdata.rs against the J716s runtime ADT, plus
table sanity (monotonic, SRAM >= max(775, core), 14 states, base pstate). Prints GPU values only.
usage: <m1n1 venv python> -I check_board.py initdata.rs adt.bin"""
import os, re, sys
sys.path.insert(0, os.environ.get("M1N1_PROXYCLIENT", os.path.expanduser("~/Work/m1n1/proxyclient")))
from m1n1.adt import load_adt

src = open(sys.argv[1]).read()
adt = load_adt(open(sys.argv[2], "rb").read())
sgx = adt["/arm-io/sgx"]

def tuples(name):
    body = re.search(name + r": \[\w+; 14\] = \w+\(\[(.*?)\]\);", src, re.S).group(1)
    return [tuple(int(x) for x in t.split(",")) for t in re.findall(r"\(([^)]*)\)", body)]

main, aux = tuples("J716S_GPU_PERF_STATES"), tuples("J716S_AUX_PERF_STATES")
ps, ss = list(sgx.perf_states), list(sgx.perf_states_sram)
n = sgx.perf_state_count
adt_main = [(ps[i].freq // 10**6, ps[i].volt, ps[n + i].volt, ss[i].volt, ss[n + i].volt) for i in range(n)]
assert [(s.freq, s.volt) for s in sgx.perf_states1] == [(s.freq, s.volt) for s in ps[n:]]
assert [(s.freq, s.volt) for s in sgx.perf_states_sram1] == [(s.freq, s.volt) for s in ss[n:]]
lane = sgx.afr_perf_states.states[0]
adt_aux = [(s.freq // 10**6, s.volt // 1000, max(775, s.volt // 1000)) for s in lane]
cs = [(s.freq, s.volt) for s in sgx.cs_perf_states.states[0]]
checks = [
    ("perf-state-count 14, table count 2", n == 14 and sgx.perf_state_table_count == 2),
    ("main table == ADT perf-states/-1/-sram/-sram1", main == adt_main),
    ("aux table == ADT afr-perf-states (SRAM max(775, core))", aux == adt_aux),
    ("afr-perf-states == cs-perf-states, one lane", cs == [(s.freq, s.volt) for s in lane]
        and sgx.afr_perf_states.dies == 1 and len(sgx.afr_perf_states.states) == 1),
    ("frequencies strictly increasing", all(a[0] < b[0] for t in (main, aux) for a, b in zip(t, t[1:]))),
    ("voltages non-decreasing per lane", all(a[k] <= b[k] for t, ks in ((main, (1, 2, 3, 4)), (aux, (1, 2)))
        for a, b in zip(t, t[1:]) for k in ks)),
    ("SRAM >= max(775, core)", all(r[3] >= max(775, r[1]) and r[4] >= max(775, r[2]) for r in main)
        and all(r[2] >= max(775, r[1]) for r in aux)),
    ("max frequency 1620 MHz", main[13][0] == 1620 and aux[13][0] == 1620),
    ("gpu-perf-base-pstate 1 (relative_frequency floor)", sgx.gpu_perf_base_pstate == 1
        and "relative_frequency(&J716S_GPU_PERF_STATES, 1)" in src),
    ("active-mcc-bit-vector 0xf (mcc_mask None)", sgx.active_mcc_bit_vector == 0xf
        and adt["/arm-io/mcc"].amcc_enable_mask == 0xf),
    ("gpu-num-perf-states 13, sample period 200000 AIC clocks (the shared J714 constants)",
        sgx.gpu_num_perf_states == 13 and sgx.gpu_pwr_sample_period_aic_clks == 200000),
]
board = re.search(r"pub\(crate\) const J716S: Board = Board \{(.*?)\n\};", src, re.S).group(1)
checks.append(("clusters 2, cores 20, perf_tables 2", all(s in board for s in
    ("clusters: 2,", "gpu_cores: 20,", "perf_tables: 2,"))))
# AON rows
import struct
t = adt["/arm-io/aon-ptd"]._properties["ptd_data_table"]
rows = [struct.unpack_from("<III", t, o) for o in range(0, len(t) - 11, 4)
        if struct.unpack_from("<I", t, o)[0] in (0x67305452, 0x67315452, 0x72305452)]
j714 = re.search(r"const J714_AON_RECORDS: \[\[u32; 3\]; 3\] = \[(.*?)\];", src, re.S).group(1)
j714 = [tuple(int(x.replace("_", ""), 0) for x in r.split(",")) for r in re.findall(r"\[([^\]]+)\]", j714)]
checks.append(("ADT aon-ptd RT0g/RT1g/RT0r == J714_AON_RECORDS", rows == j714 and "aon_records: &J714_AON_RECORDS" in board))
# register windows that have an ADT node
def reg(path, i):
    return adt[path].get_reg(i)
mcc = [reg("/arm-io/mcc", 14 + k)[0] + 0x104000 for k in range(4)]
win = {
    "slot 0 = sgx meta-sw-interrupt page": struct.unpack_from("<Q", sgx.meta_sw_interrupt, 0)[0] & ~0x3fff == 0x2_8041_4000,
    "slot 3 = mcc reg[14..17] + 0x104000": mcc == [0x22_2010_4000, 0x22_2210_4000, 0x22_2410_4000, 0x22_2610_4000],
    "slot 9 = pmp0 reg[3]": reg("/arm-io/pmp0", 3)[0] == 0x2_8425_0000,
    "slot 10 = mcc reg[2]": reg("/arm-io/mcc", 2)[0] == 0x2_8424_0000,
    "slot 12 in ane0 reg[0]": reg("/arm-io/ane0", 0)[0] <= 0x5_0965_c000 < sum(reg("/arm-io/ane0", 0)),
    "slot 15 = aon-ptd reg[0]": reg("/arm-io/aon-ptd", 0)[0] == 0x2_8cdc_0000,
    "slots 17.. in sgx reg[0] (0x23_0000_0000)": reg("/arm-io/sgx", 0)[0] == 0x23_0000_0000,
    "slot 20: 2 cluster instances in sgx": all(reg("/arm-io/sgx", 0)[0] <= a < sum(reg("/arm-io/sgx", 0)) for a in (0x23_0300_0000, 0x23_0320_0000)),
}
checks += [(k, v) for k, v in win.items()]
for name, good in checks:
    print(("ok   " if good else "FAIL ") + name)
print("main (MHz, core0, core1, sram0, sram1):", main)
print("aux (MHz, core, sram):", aux)
sys.exit(0 if all(g for _, g in checks) else 1)
