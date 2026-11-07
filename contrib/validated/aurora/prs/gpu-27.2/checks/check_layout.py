#!/usr/bin/env python3
"""Standalone check of the M5 InitData layout arithmetic for the 27.0 and 27.2+ profiles.

It compiles g17/fw/m5/initdata.rs whole with rustc, once from the base and once from the
patched tree (the file is self-contained apart from one helper of target.rs and, patched, the
M5Layouts enum of variant.rs, which are lifted in), together with the assertions below, and
runs them. No kernel build is involved.

usage: check_layout.py [--compile-only] <kernel worktree> [base ref]
"""
import os
import re
import subprocess
import sys
import tempfile

# --compile-only: only type-check both files (for an intermediate commit of the series).
COMPILE_ONLY = "--compile-only" in sys.argv
if COMPILE_ONLY:
    sys.argv.remove("--compile-only")
TREE = sys.argv[1]
# The base: the series' mailbox commit (the fifth), whose layout items are PR #1012's and
# which already has the J716S board table.
BASE = sys.argv[2]
FILE = "drivers/gpu/drm/asahi/g17/fw/m5/initdata.rs"
VARIANT = "drivers/gpu/drm/asahi/g17/fw/variant.rs"
TARGET = "drivers/gpu/drm/asahi/g17/fw/m5/target.rs"


# Stores (offset, bytes) of the HW data builders at and above 0x2700: the store tracker over the
# 26B123 kext (its 26A428 list is the same) and the 26C5035r kext, plus one register-addressed
# store per kext it misses (26B123 0xfffffe0008b8eb3c `str x11` to 0x27d4, 26C5035r
# 0xfffffe0008ba6d3c `str x12` to 0x2734).
STORES_26B123 = [
    (0x2700, 8), (0x2708, 4), (0x270c, 4), (0x2710, 4), (0x2714, 8), (0x271c, 4), (0x2720, 8),
    (0x2728, 4), (0x272c, 4), (0x2730, 8), (0x2738, 4), (0x27bc, 8), (0x27c4, 4), (0x27c8, 8),
    (0x27d4, 8), (0x27dc, 8), (0x27e4, 4), (0x27e8, 4), (0x27ec, 4), (0x27f0, 4), (0x27f4, 8),
    (0x27fc, 8), (0x2804, 4), (0x2808, 4), (0x2810, 8), (0x2818, 8), (0x2820, 4), (0x2824, 1),
    (0x2825, 1), (0x2832, 4), (0x2836, 4), (0x283a, 4), (0x2846, 4),
]
STORES_26C5035 = [
    (0x2700, 8), (0x2708, 4), (0x270c, 4), (0x2710, 4), (0x2714, 8), (0x271c, 4), (0x2720, 4),
    (0x2724, 8), (0x272c, 4), (0x2730, 4), (0x2734, 8), (0x273c, 4), (0x27c0, 8), (0x27c8, 4),
    (0x27cc, 8), (0x27d8, 8), (0x27e0, 8), (0x27e8, 4), (0x27ec, 4), (0x27f0, 4), (0x27f4, 4),
    (0x27f8, 16), (0x2808, 4), (0x280c, 4), (0x2814, 8), (0x281c, 8), (0x2824, 4), (0x2828, 1),
    (0x2829, 1), (0x2836, 4), (0x283a, 4), (0x283e, 4), (0x284a, 4),
]


def source(ref):
    if ref is None:
        return open(os.path.join(TREE, FILE)).read()
    return subprocess.run(["git", "-C", TREE, "show", f"{ref}:{FILE}"], check=True,
                          capture_output=True, text=True).stdout


def item(text, head):
    """The item whose declaration starts with `head` (after the visibility), with its docs and
    attributes, through its closing brace or semicolon."""
    lines = text.split("\n")
    pat = re.compile(r"^(pub\(crate\) )?" + re.escape(head) + r"\b")
    for i, line in enumerate(lines):
        if pat.match(line):
            start = i
            while start > 0 and (lines[start - 1].startswith("///")
                                 or lines[start - 1].startswith("#[")):
                start -= 1
            depth, out = 0, []
            for line2 in lines[i:]:
                out.append(line2)
                code = line2.split("//")[0]
                depth += code.count("{") + code.count("[") + code.count("(")
                depth -= code.count("}") + code.count("]") + code.count(")")
                if depth == 0 and (code.rstrip().endswith(";") or code.rstrip().endswith("}")):
                    break
            # The harness reaches private items from outside their module.
            if not out[0].startswith("pub(crate) ") and not out[0].startswith("impl "):
                out[0] = "pub(crate) " + out[0]
            return "\n".join(lines[start:i] + out)
    raise SystemExit(f"item not found: {head}")



MAIN = r'''
use std::collections::BTreeSet;

/// The two modules define their own (identically named and shaped) layout types: compare them
/// field by field through their Debug forms.
fn same<A: std::fmt::Debug, B: std::fmt::Debug>(a: &A, b: &B) {
    assert_eq!(format!("{a:?}"), format!("{b:?}"));
}

fn hx(v: &[usize]) -> String {
    v.iter().map(|x| format!("{x:#x}")).collect::<Vec<_>>().join(" ")
}

fn main() {
    let a = &new::M5_LAYOUT_26A428;
    let b = &new::M5_LAYOUT_26B123;
    let c = &new::M5_LAYOUT_26C5035;

    // 27.0: the new 26A428 layout reproduces every constant the driver had.
    assert_eq!(a.sizes, old::ABI_ALLOCATION_SIZES_26A428_M5);
    same(&a.shared, &old::M5_SHARED_LAYOUT);
    same(&a.private, &old::M5_PRIVATE_LAYOUT);
    assert_eq!(a.hw_data_size(), old::M5_HW_DATA_SIZE);
    assert_eq!(a.policy_size(), old::M5_POLICY_SIZE);
    assert_eq!(a.status_config_size(), old::M5_STATUS_CONFIG_SIZE);
    assert_eq!(a.shared_prefix_size(), old::M5_SHARED_PREFIX_SIZE);
    assert_eq!(a.bundle_view_offsets(), old::M5_BUNDLE_VIEW_OFFSETS);
    assert_eq!(a.bundle_view_extents(), old::M5_BUNDLE_VIEW_EXTENTS);
    assert_eq!(new::work_ring_offsets(&a.shared), old::M5_WORK_RING_BUNDLE_OFFSETS);
    assert_eq!(a.shared.main_config, old::M5_MAIN_BUNDLE_OFFSETS);
    assert_eq!(a.shared.control_ring, old::M5_CONTROL_RING_BUNDLE_OFFSETS);
    assert_eq!(a.private_status_a(), old::M5_PRIVATE_STATUS_A);
    assert_eq!(a.private_state_grids(), old::M5_PRIVATE_STATE_GRIDS);
    assert_eq!(a.status_config_in_status_b(), old::M5_STATUS_CONFIG_IN_STATUS_B);
    assert_eq!(a.status_b_span(), old::M5_STATUS_B_SPAN);
    assert_eq!(a.shared.total, old::M5_SHARED_CLUSTER_SIZE);
    assert_eq!(a.private.total, old::M5_PRIVATE_CLUSTER_SIZE);
    assert!(a.hw_data_bands.is_empty() && a.hw_data_words.is_empty());
    assert_eq!(a.hw_data_offset(old::M5_KICK_SHARED_POINTER), Some(0x27dc));
    assert_eq!(new::M5_INITDATA_VERSION_WORD, old::M5_INITDATA_VERSION_WORD);
    // The 27.0 constants the patch kept still name the 26A428 layout.
    same(&new::M5_SHARED_LAYOUT, &old::M5_SHARED_LAYOUT);
    same(&new::M5_PRIVATE_LAYOUT, &old::M5_PRIVATE_LAYOUT);
    // The profile methods: unchanged for every old profile, layout-driven for the M5 ones.
    use new::InstanceRole::{Primary, Secondary};
    let pairs = [
        (old::RootProfile::J700G17P, new::RootProfile::J700G17P),
        (old::RootProfile::J813G17G25G76, new::RootProfile::J813G17G25G76),
        (old::RootProfile::J873G18G26A428, new::RootProfile::J873G18G26A428),
        (old::RootProfile::J714G17S26A428, new::RootProfile::J714G17S26A428),
    ];
    for (o, n) in pairs {
        assert_eq!(o.version_word(), n.version_word());
        assert_eq!(o.root_size(old::InstanceRole::Primary), n.root_size(Primary));
        assert_eq!(o.root_size(old::InstanceRole::Secondary), n.root_size(Secondary));
        assert_eq!(o.control_opening_opcode(old::InstanceRole::Primary),
                   n.control_opening_opcode(Primary));
        assert_eq!(o.control_opening_opcode(old::InstanceRole::Secondary),
                   n.control_opening_opcode(Secondary));
        assert_eq!(o.control_register_opcode(), n.control_register_opcode());
        assert_eq!(o.bundle_view_offsets(), n.bundle_view_offsets());
        assert_eq!(o.bundle_view_extents(), n.bundle_view_extents());
        assert_eq!(o.repeated_region_bundle_offset(), n.repeated_region_bundle_offset());
        assert_eq!(o.work_ring_bundle_offsets(), n.work_ring_bundle_offsets());
    }
    let m5 = new::RootProfile::J714G17S26A428;
    for (n, layout, word) in [
        (m5, a, old::M5_INITDATA_VERSION_WORD),
        (new::RootProfile::J714G17S26B123, b, 0x0c8e_4339_8728_04c0),
        (new::RootProfile::J714G17S26C5035, c, 0x0c8e_4339_8728_04c0),
    ] {
        assert_eq!(n.m5_layout(), Some(layout));
        assert_eq!(n.version_word(), word);
        assert_eq!(n.root_size(Primary), m5.root_size(Primary));
        assert_eq!(n.root_size(Secondary), m5.root_size(Secondary));
        assert_eq!(n.control_opening_opcode(Primary), m5.control_opening_opcode(Primary));
        assert_eq!(n.control_opening_opcode(Secondary), m5.control_opening_opcode(Secondary));
        assert_eq!(n.control_register_opcode(), None);
        assert_eq!(n.bundle_view_offsets(), layout.bundle_view_offsets());
        assert_eq!(n.bundle_view_extents(), layout.bundle_view_extents());
        assert_eq!(n.repeated_region_bundle_offset(), layout.shared.block_88);
        assert_eq!(n.work_ring_bundle_offsets(), new::work_ring_offsets(&layout.shared));
    }
    for n in [new::RootProfile::J700G17P, new::RootProfile::J813G17G25G76,
              new::RootProfile::J873G18G26A428] {
        assert_eq!(n.m5_layout(), None);
    }
    println!("27.0 (26A428): every layout constant and profile method equals the base driver's");

    // 27.2 / 27.3 beta 1: the measured table and version word.
    assert_eq!(new::M5_26B123_INITDATA_VERSION_WORD, 0x0c8e_4339_8728_04c0);
    assert_eq!(new::M5_26B123_INITDATA_VERSION_WORD ^ old::M5_INITDATA_VERSION_WORD, 1 << 46);
    let mut table = old::ABI_ALLOCATION_SIZES_26A428_M5;
    table[new::ALLOC_POLICY] = 0x12728;
    table[new::ALLOC_STATUS_CONFIG] = 0x790;
    assert_eq!(b.sizes, table);
    assert_eq!(c.sizes, table);
    assert_eq!(b.shared, c.shared);
    assert_eq!(b.private, c.private);

    // Shared cluster: everything after the policy moves by 0x80 (0x5380 + 0x12728 rounds to
    // 0x17ac0 where 0x5380 + 0x126b0 rounded to 0x17a40).
    let (sa, sb) = (&a.shared, &b.shared);
    assert_eq!((sb.hw_data, sb.block_c18, sb.block_1048, sb.block_e10, sb.policy),
               (sa.hw_data, sa.block_c18, sa.block_1048, sa.block_e10, sa.policy));
    for (x, y) in [(sa.block_68, sb.block_68), (sa.block_800, sb.block_800),
                   (sa.brn_table, sb.brn_table), (sa.block_88, sb.block_88),
                   (sa.main_config[0], sb.main_config[0]), (sa.main_config[1], sb.main_config[1]),
                   (sa.control_ring[0], sb.control_ring[0]),
                   (sa.control_ring[1], sb.control_ring[1]), (sa.end, sb.end)] {
        assert_eq!(y, x + 0x80);
    }
    for i in 0..12 {
        assert_eq!(sb.dm_rings[i], sa.dm_rings[i] + 0x80);
    }
    assert_eq!(sb.total, sa.total);

    // Private cluster: everything after the status config moves by 0x40 (0x790 rounds to 0x7c0).
    let (pa, pb) = (&a.private, &b.private);
    assert_eq!((pb.dm_ring_states, pb.control_state, pb.status_b, pb.status_config),
               (pa.dm_ring_states, pa.control_state, pa.status_b, pa.status_config));
    for r in 0..2 {
        let (x, y) = (pa.roles[r], pb.roles[r]);
        for (u, v) in [(x.status_a, y.status_a), (x.event_state, y.event_state),
                       (x.log_state, y.log_state), (x.trace_state, y.trace_state),
                       (x.state_30, y.state_30), (x.event_ring, y.event_ring),
                       (x.buffer_28800, y.buffer_28800), (x.buffer_79800, y.buffer_79800),
                       (x.trace_ring, y.trace_ring), (x.buffer_4800, y.buffer_4800)] {
            assert_eq!(v, u + 0x40);
        }
    }
    for (u, v) in [(pa.secondary_control_state, pb.secondary_control_state),
                   (pa.secondary_extra_1, pb.secondary_extra_1),
                   (pa.policy_state, pb.policy_state), (pa.end, pb.end)] {
        assert_eq!(v, u + 0x40);
    }
    assert_eq!(pb.total, pa.total);
    assert_eq!(b.status_b_span(), a.status_b_span() + 0x40);
    assert_eq!(b.status_config_in_status_b(), a.status_config_in_status_b());
    println!("27.2+ (26B123/26C5035r): sizes 0x12728/0x790, shared +0x80 after the policy, \
              private +0x40 after the status config, totals unchanged");

    // HW data: 26B123 is 26A428's; 26C5035r inserts the forced-idle word at 0x2720.
    assert!(b.hw_data_bands.is_empty() && b.hw_data_words.is_empty());
    assert_eq!(c.hw_data_offset(0x271c), Some(0x271c));
    assert_eq!(c.hw_data_offset(0x2720), Some(0x2724));
    assert_eq!(c.hw_data_offset(0x2728), Some(0x272c));
    assert_eq!(c.hw_data_offset(0x272c), Some(0x2730));
    assert_eq!(c.hw_data_offset(old::M5_KICK_SHARED_POINTER), Some(0x27e0));
    assert_eq!(c.hw_data_offset(0x2846), Some(0x284a));
    assert_eq!(c.hw_data_words, &[(0x2720, 5000)]);
    assert_eq!(new::m5_forced_idle_timeout_ms(5), 5000);
    assert_eq!(new::m5_forced_idle_timeout_ms(0x41_8937), 0x41_8937 * 1000);
    assert_eq!(new::m5_forced_idle_timeout_ms(0x41_8938), u32::MAX);

    // Relocate a buffer holding a marker at each 26A428/26B123 store and compare with the
    // 26C5035r kext's stores; below 0x2700 nothing may move.
    let stores_b: &[(usize, usize)] = &STORES_26B123;
    let stores_c: &[(usize, usize)] = &STORES_26C5035;
    let cover = |stores: &[(usize, usize)]| -> BTreeSet<usize> {
        stores.iter().flat_map(|&(o, w)| o..o + w).collect()
    };
    let mut buf = vec![0u8; a.hw_data_size()];
    for (i, byte) in buf.iter_mut().enumerate().take(0x2700) {
        *byte = (i % 251 + 1) as u8;
    }
    for o in cover(stores_b) {
        buf[o] = 0xa5;
    }
    let before = buf.clone();
    new::relocate_hw_data(c.hw_data_bands, &mut buf).unwrap();
    for &(o, v) in c.hw_data_words {
        buf[o..o + 4].copy_from_slice(&v.to_le_bytes());
    }
    assert_eq!(buf[..0x2720], before[..0x2720]);
    let moved: BTreeSet<usize> = (0x2700..buf.len()).filter(|&i| buf[i] == 0xa5).collect();
    let word = new::M5_26C5035_HW_FORCED_IDLE_TIMEOUT;
    let want: BTreeSet<usize> =
        cover(stores_c).into_iter().filter(|&o| !(word..word + 4).contains(&o)).collect();
    assert_eq!(moved, want, "relocated 26B123 stores differ from the 26C5035r kext's");
    // The inserted word is the only 26C5035r store with no 26B123 counterpart.
    assert!(stores_c.contains(&(word, 4)));
    assert_eq!(u32::from_le_bytes(buf[0x2720..0x2724].try_into().unwrap()), 5000);
    // A non-zero byte in the four the move drops is refused.
    let mut bad = before.clone();
    bad[0x284d] = 1;
    assert!(new::relocate_hw_data(c.hw_data_bands, &mut bad).is_err());
    println!("26C5035r HW data: the 26B123 store bytes relocated by the bands are the 26C5035r \
              kext's ({} bytes at and above 0x2700), plus the word at 0x2720 = {}",
             want.len(), c.hw_data_words[0].1);

    println!();
    println!("{:<34} {:>12} {:>12}", "", "27.0 26A428", "27.2+");
    let rows: &[(&str, usize, usize)] = &[
        ("POLICY size", a.policy_size(), b.policy_size()),
        ("STATUS_CONFIG size", a.status_config_size(), b.status_config_size()),
        ("shared.policy", sa.policy, sb.policy),
        ("shared.block_68 (view 3)", sa.block_68, sb.block_68),
        ("shared.block_800 (view 4)", sa.block_800, sb.block_800),
        ("shared.brn_table (prefix size)", sa.brn_table, sb.brn_table),
        ("shared.block_88 (repeated region)", sa.block_88, sb.block_88),
        ("shared.main_config[0]", sa.main_config[0], sb.main_config[0]),
        ("shared.main_config[1]", sa.main_config[1], sb.main_config[1]),
        ("shared.control_ring[0]", sa.control_ring[0], sb.control_ring[0]),
        ("shared.control_ring[1]", sa.control_ring[1], sb.control_ring[1]),
        ("shared.end", sa.end, sb.end),
        ("shared.total", sa.total, sb.total),
        ("private.status_b", pa.status_b, pb.status_b),
        ("private.status_config", pa.status_config, pb.status_config),
        ("private.roles[0].status_a", pa.roles[0].status_a, pb.roles[0].status_a),
        ("private.roles[1].status_a", pa.roles[1].status_a, pb.roles[1].status_a),
        ("private.secondary_control_state", pa.secondary_control_state, pb.secondary_control_state),
        ("private.secondary_extra_1", pa.secondary_extra_1, pb.secondary_extra_1),
        ("private.policy_state", pa.policy_state, pb.policy_state),
        ("private.end", pa.end, pb.end),
        ("private.total", pa.total, pb.total),
        ("status_b span", a.status_b_span(), b.status_b_span()),
        ("state grid[1]", a.private_state_grids()[1], b.private_state_grids()[1]),
    ];
    for (name, x, y) in rows {
        println!("{:<34} {:>12} {:>12}", name, format!("{x:#x}"), format!("{y:#x}"));
    }
    println!("{:<34} {}", "work rings 26A428", hx(&new::work_ring_offsets(sa)));
    println!("{:<34} {}", "work rings 27.2+", hx(&new::work_ring_offsets(sb)));
    println!("{:<34} {:>12} {:>12}", "HW kick-shared pointer", "0x27dc",
             format!("{:#x} (26C5035r)", c.hw_data_offset(old::M5_KICK_SHARED_POINTER).unwrap()));
    encoders();
    println!("\nall checks passed");
}
'''


ENCODERS = r'''
/// The encoders, run on the base and the patched file with the addresses build_m5 uses.
fn encoders() {
    const BASE: u64 = 0xffff_fc20_0000_0000;
    const PRIVATE: u64 = BASE + 0x2_0000;
    const REGION_C: u64 = BASE + 0x1a_0000;
    const ROOTS: u64 = BASE + 0x1a_8000;
    const REGION_A: u64 = BASE + 0x1b_8000;
    const FWCTL: u64 = BASE + 0x1c_0000;
    const QOS: u64 = BASE + 0x1c_8000;
    const AON: u64 = BASE + 0x1d_0000;
    const KICK_SHARED: u64 = BASE + 0x1d_8000;
    const BUNDLE: u64 = BASE + 0xc078_8000;
    const PB: u64 = BASE + 0x15e_0000;
    const UMA: u64 = BASE + 0x15e_8000;
    let (a, b, c) = (&new::M5_LAYOUT_26A428, &new::M5_LAYOUT_26B123, &new::M5_LAYOUT_26C5035);
    let word = new::M5_26C5035_HW_FORCED_IDLE_TIMEOUT;

    // HW data, kick-shared pointer and enabled cores, per board.
    let boards: [(&str, &old::Board, &new::Board); 4] = [
        ("J714", &old::J714, &new::J714), ("J716C", &old::J716C, &new::J716C),
        ("J716S", &old::J716S, &new::J716S), ("J775D", &old::J775D, &new::J775D),
    ];
    for (name, ob, nb) in boards {
        let oa: [old::G17PKsmCompletionAliases; 4] = core::array::from_fn(|i| {
            old::G17PKsmCompletionAliases {
                low: 0x70_0184_8000 + i as u64 * 0x2_8000,
                high: BASE + 0xc080_0000 + i as u64 * 0x2_8000,
            }
        });
        let na: [new::G17PKsmCompletionAliases; 4] = core::array::from_fn(|i| {
            new::G17PKsmCompletionAliases { low: oa[i].low, high: oa[i].high }
        });
        let ow = ob.register_windows();
        let ow = &ow[..ob.register_window_count()];
        let nw = nb.register_windows();
        let nw = &nw[..nb.register_window_count()];
        let mut want = vec![0u8; old::M5_HW_DATA_SIZE];
        old::encode_m5_hw_data(ob, oa, QOS, ow, &mut want).unwrap();
        old::set_m5_kick_shared(&mut want, KICK_SHARED).unwrap();
        old::set_m5_enabled_cores(&mut want, nb.gpu_cores).unwrap();
        let encode = |layout: &new::M5Layout| {
            let mut out = vec![0u8; layout.hw_data_size()];
            new::encode_m5_hw_data(layout, nb, na, QOS, nw, &mut out).unwrap();
            new::set_m5_kick_shared(layout, &mut out, KICK_SHARED).unwrap();
            new::set_m5_enabled_cores(layout, &mut out, nb.gpu_cores).unwrap();
            out
        };
        assert_eq!(encode(a), want, "{name}: 26A428 HW data changed");
        assert_eq!(encode(b), want, "{name}: 26B123 HW data is not 26A428's");
        let got = encode(c);
        assert_eq!(got[..word], want[..word], "{name}: 26C5035r HW data below 0x2720");
        assert_eq!(u32::from_le_bytes(got[word..word + 4].try_into().unwrap()), 5000);
        assert_eq!(got[word + 4..], want[word..want.len() - 4], "{name}: 26C5035r tail");
        assert!(want[want.len() - 4..].iter().all(|x| *x == 0));
        assert_eq!(u64::from_le_bytes(got[0x27e0..0x27e8].try_into().unwrap()), KICK_SHARED);
        assert_eq!(u64::from_le_bytes(want[0x27dc..0x27e4].try_into().unwrap()), KICK_SHARED);
    }
    println!("HW data (J714, J716C, J716S, J775D): 26A428 and 26B123 byte-identical to the base; \
              26C5035r = base below 0x2720, 5000 at 0x2720, base[0x2720..0x284c] at 0x2724");

    // Private cluster.
    let mut want = vec![0u8; old::M5_PRIVATE_LAYOUT.total];
    old::encode_m5_private_cluster(PRIVATE, FWCTL, &mut want).unwrap();
    // Integration: the private cluster encoder takes the root profile, and the 27.2+ profiles
    // carry the 0x790-byte 26B123 status config (the status-config map, checked by verify_statuscfg.py
    // and rustcheck.py); here everything outside the status config is checked.
    let private = |profile: new::RootProfile| {
        let layout = profile.m5_layout().unwrap();
        let mut out = vec![0u8; layout.private.total];
        new::encode_m5_private_cluster(profile, PRIVATE, FWCTL, &mut out).unwrap();
        out
    };
    assert_eq!(private(new::RootProfile::J714G17S26A428), want);
    // 27.2+: the same bytes up to the status config's first moved word (0x5dc), the status
    // config 0x10 longer, and the bytes past the 0x780 status config moved by 0x40.
    let sc = old::M5_PRIVATE_LAYOUT.status_config;
    let end = sc + 0x780;
    let got = private(new::RootProfile::J714G17S26B123);
    // Status B's link pointer (status config - 0x20) names the link word, 0x10 higher.
    let lp = sc - 0x20;
    assert_eq!(got[..lp], want[..lp]);
    assert_eq!(u64::from_le_bytes(got[lp..lp + 8].try_into().unwrap()),
               u64::from_le_bytes(want[lp..lp + 8].try_into().unwrap()) + 0x10);
    assert_eq!(got[lp + 8..sc + 0x5dc], want[lp + 8..sc + 0x5dc]);
    assert!(got[sc + 0x790..end + 0x40].iter().all(|x| *x == 0));
    assert_eq!(got[end + 0x40..], want[end..want.len() - 0x40]);
    assert!(want[want.len() - 0x40..].iter().all(|x| *x == 0));
    // The link word/pointer pair of the 26B123 status config (0x784/0x788) points at status B.
    let link_ptr = u64::from_le_bytes(got[sc + 0x788..sc + 0x790].try_into().unwrap());
    let old_ptr = u64::from_le_bytes(want[sc + 0x778..sc + 0x780].try_into().unwrap());
    assert_eq!(link_ptr, old_ptr);
    assert_eq!(got[sc + 0x784], 1);
    assert_eq!(private(new::RootProfile::J714G17S26C5035), got);
    println!("private cluster: 26A428 byte-identical; 27.2+ = the base below status config \
              +0x5dc, the 0x790 status config with its link at +0x784/+0x788, and the base \
              moved by 0x40 past it; 26C5035 = 26B123");

    // Bundle prefix (views and policy) with the controller defaults.
    let bindings = |state| (state, AON);
    let mut want = vec![0u8; old::M5_SHARED_LAYOUT.total];
    let (state, aon) = bindings(PRIVATE + old::M5_PRIVATE_LAYOUT.policy_state as u64);
    old::encode_m5_bundle_policy(old::M5PolicyBindings { state, aon_ptd: aon, boot_timestamp: 0 },
                                 &mut want).unwrap();
    old::encode_m5_policy_controller_defaults(&mut want).unwrap();
    for layout in [a, b, c] {
        let mut out = vec![0u8; layout.shared.total];
        new::encode_m5_bundle_policy(layout,
            new::M5PolicyBindings { state, aon_ptd: aon, boot_timestamp: 0 }, &mut out).unwrap();
        new::encode_m5_policy_controller_defaults(&mut out).unwrap();
        assert_eq!(out, want);
    }
    println!("bundle policy prefix: byte-identical in every layout (the policy's own 27.2 \
              changes are not part of this series)");

    // Roots and main configs: 26A428 byte-identical; 27.2+ roots differ in the version word.
    let profiles = [
        (old::RootProfile::J714G17S26A428, new::RootProfile::J714G17S26A428),
        (old::RootProfile::J714G17S26A428, new::RootProfile::J714G17S26B123),
        (old::RootProfile::J714G17S26A428, new::RootProfile::J714G17S26C5035),
    ];
    for (op, np) in profiles {
        let layout = np.m5_layout().unwrap();
        let mut main_diff = Vec::new();
        for (index, (orole, nrole)) in [(old::InstanceRole::Primary, new::InstanceRole::Primary),
                                        (old::InstanceRole::Secondary, new::InstanceRole::Secondary)]
            .into_iter().enumerate()
        {
            let (os, ns) = (old::M5_SHARED_LAYOUT, layout.shared);
            let (opr, npr) = (old::M5_PRIVATE_LAYOUT, layout.private);
            let oi = old::InstanceAddresses {
                root: ROOTS + index as u64 * 0x8000,
                main_config: BUNDLE + os.main_config[index] as u64,
                status_a: PRIVATE + opr.roles[index].status_a as u64,
                status_b: if index == 0 { PRIVATE + opr.status_b as u64 } else { 0 },
                secondary_extras: if index == 0 { [0; 2] } else {
                    [PRIVATE + opr.status_config as u64, PRIVATE + opr.secondary_extra_1 as u64]
                },
            };
            let ni = new::InstanceAddresses {
                root: oi.root,
                main_config: BUNDLE + ns.main_config[index] as u64,
                status_a: PRIVATE + npr.roles[index].status_a as u64,
                status_b: if index == 0 { PRIVATE + npr.status_b as u64 } else { 0 },
                secondary_extras: if index == 0 { [0; 2] } else {
                    [PRIVATE + npr.status_config as u64, PRIVATE + npr.secondary_extra_1 as u64]
                },
            };
            let osh = old::SharedAddresses { region_a: REGION_A, region_c: REGION_C,
                hw_data_bundle: BUNDLE, hw_data_bundle_alloc: os.total };
            let nsh = new::SharedAddresses { region_a: REGION_A, region_c: REGION_C,
                hw_data_bundle: BUNDLE, hw_data_bundle_alloc: ns.total };
            let ov = old::PrimaryRegionViews { sentinel_high: BASE + 0xc07e_0000, alias_high: [PB, UMA] };
            let nv = new::PrimaryRegionViews { sentinel_high: BASE + 0xc07e_0000, alias_high: [PB, UMA] };
            let och = old::derive_channel_table_for_profile(op, orole,
                PRIVATE + old::M5_PRIVATE_STATE_GRIDS[index] as u64, oi.status_a, oi.main_config, BUNDLE);
            let nch = new::derive_channel_table_for_profile(np, nrole,
                PRIVATE + layout.private_state_grids()[index] as u64, ni.status_a, ni.main_config, BUNDLE);
            let mut om = vec![0u8; old::MAIN_CONFIG_SIZE];
            let mut nm = vec![0u8; new::MAIN_CONFIG_SIZE];
            old::encode_main_config_for_profile(op, orole, &osh, &oi, &och,
                if index == 0 { Some(&ov) } else { None }, &mut om).unwrap();
            new::encode_main_config_for_profile(np, nrole, &nsh, &ni, &nch,
                if index == 0 { Some(&nv) } else { None }, &mut nm).unwrap();
            let mut oroot = vec![0u8; old::M5_ROOT_SIZE];
            let mut nroot = vec![0u8; new::M5_ROOT_SIZE];
            old::encode_root_for_profile(op, orole, &osh, &oi, &mut oroot).unwrap();
            new::encode_root_for_profile(np, nrole, &nsh, &ni, &mut nroot).unwrap();
            if np == new::RootProfile::J714G17S26A428 {
                assert_eq!(nm, om);
                assert_eq!(nroot, oroot);
            } else {
                assert_eq!(u64::from_le_bytes(nroot[..8].try_into().unwrap()), 0x0c8e_4339_8728_04c0);
                assert_eq!(nroot[8..0x18], oroot[8..0x18]);
                assert_eq!(u64::from_le_bytes(nroot[0x18..0x20].try_into().unwrap()), ni.main_config);
                assert_eq!(nroot[0x20..0xa8], oroot[0x20..0xa8]);
                assert_eq!(u64::from_le_bytes(nroot[0xa8..0xb0].try_into().unwrap()), ni.status_a);
                // Every changed main-config byte belongs to a bundle or private address that
                // moved by 0x80 or 0x40.
                let mut explained = vec![false; nm.len()];
                for at in (0..nm.len() - 7).step_by(4) {
                    if nm[at..at + 8] == om[at..at + 8] { continue; }
                    let (o8, n8) = (u64::from_le_bytes(om[at..at + 8].try_into().unwrap()),
                                    u64::from_le_bytes(nm[at..at + 8].try_into().unwrap()));
                    if n8 == o8 + 0x80 || n8 == o8 + 0x40 {
                        main_diff.push((index, at, n8 - o8));
                        explained[at..at + 8].fill(true);
                    }
                }
                for at in 0..nm.len() {
                    assert!(nm[at] == om[at] || explained[at], "{np:?}: main config byte {at:#x}");
                }
            }
        }
        if np != new::RootProfile::J714G17S26A428 {
            assert!(!main_diff.is_empty());
            println!("{np:?}: root = base but version word and the moved status A / main config; \
                      main-config words moved: {}",
                     main_diff.iter().map(|(r, at, d)| format!("r{r}+{at:#x}:+{d:#x}"))
                         .collect::<Vec<_>>().join(" "));
        }
    }
    println!("roots and main configs: J714G17S26A428 byte-identical to the base");
}
'''


def whole(text):
    # The harness reaches the one private function it tests from outside the module.
    return text.replace("\nfn relocate_hw_data(", "\npub(crate) fn relocate_hw_data(")


def main():
    base, patched = source(BASE), source(None)
    variant = open(os.path.join(TREE, VARIANT)).read()
    layouts = item(variant, "enum M5Layouts")
    fmt = lambda lst: ", ".join(f"({o:#x}, {w})" for o, w in lst)
    stores = (f"const STORES_26B123: [(usize, usize); {len(STORES_26B123)}] = "
              f"[{fmt(STORES_26B123)}];\n"
              f"const STORES_26C5035: [(usize, usize); {len(STORES_26C5035)}] = "
              f"[{fmt(STORES_26C5035)}];\n")
    target = "pub(crate) mod target {\n" + item(open(os.path.join(TREE, TARGET)).read(),
                                                "const fn min_parameter_buffer_pages") + "\n}\n"
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "old.rs"), "w").write(whole(base))
        open(os.path.join(d, "new.rs"), "w").write(whole(patched))
        prog = ("#![allow(warnings)]\n"
                "mod fw_old { pub(crate) mod m5 {\n" + target +
                f'#[path = "{d}/old.rs"] pub(crate) mod initdata;\n}} }}\n'
                "mod g17 { pub(crate) mod fw { pub(crate) mod variant {\n" + layouts + "\n}\n"
                "pub(crate) mod m5 {\n" + target +
                f'#[path = "{d}/new.rs"] pub(crate) mod initdata;\n}} }} }}\n'
                "use fw_old::m5::initdata as old;\nuse g17::fw::m5::initdata as new;\n"
                + (stores + MAIN + ENCODERS if not COMPILE_ONLY else "fn main() {}\n"))
        src = os.path.join(d, "check.rs")
        open(src, "w").write(prog)
        exe = os.path.join(d, "check")
        r = subprocess.run(["rustc", "--edition", "2021", "-O", "-o", exe, src],
                           capture_output=True, text=True)
        if r.returncode:
            sys.stderr.write(r.stderr)
            raise SystemExit("rustc failed")
        r = subprocess.run([exe], capture_output=True, text=True)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        raise SystemExit(r.returncode)


if __name__ == "__main__":
    main()
