#!/usr/bin/env python3
"""Compile the status-config map items of g17/fw/m5/initdata.rs on their own and test them.

  rustcheck.py initdata.rs workdir

Pulls the map, the band helpers and both word writers out of the driver source, adds stubs for
what they use, and runs a test: the 26A428 path must write exactly what
write_relocated_words(.., COMMON26_STATUS_CONFIG_BANDS, ..) writes, and the 26B123 words are
printed. Needs rustc only.
"""
import re, subprocess, sys, os

src = open(sys.argv[1]).read()
work = sys.argv[2]
ITEMS = [
    r'pub\(crate\) enum Evidence', r'pub\(crate\) struct LayoutBand', r'const fn band\(',
    r'pub\(crate\) const fn relocate_by_bands', r'pub\(crate\) const COMMON26_STATUS_CONFIG_BANDS',
    r'pub\(crate\) const M5_26B123_STATUS_CONFIG_BANDS', r'pub\(crate\) const M5_26B123_STATUS_CONFIG_SIZE',
    r'pub\(crate\) const M5_26B123_STATUS_CONFIG_INSERTED', r'const M5_25G76_STATUS_CONFIG_WORDS',
    r'fn write_relocated_words', r'fn write_m5_status_config_words', r'fn put_u32',
    r'pub\(crate\) struct M5StatusConfigMap', r'impl M5StatusConfigMap',
    r'pub\(crate\) const M5_26A428_STATUS_CONFIG:', r'pub\(crate\) const M5_26B123_STATUS_CONFIG:',
    r'pub\(crate\) const M5_STATUS_CONFIG_LINK_WORD', r'pub\(crate\) const M5_STATUS_CONFIG_LINK_PTR',
    r'pub\(crate\) const M5_STATUS_CONFIG_HISTORY:', r'pub\(crate\) const M5_STATUS_CONFIG_HISTORY_GENERATION',
    r'pub\(crate\) const M5_STATUS_CONFIG_HISTORY_SLOTS',
    # Integration: the 26B123 size comes from A's allocation size table.
    r'pub\(crate\) const ABI_ALLOCATION_SIZES_26B123_M5', r'pub\(crate\) const ALLOC_STATUS_CONFIG:',
]


def item(pat):
    m = re.search(r'^(#\[derive[^\n]*\n)?' + pat, src, re.M)
    if not m:
        sys.exit('missing ' + pat)
    i, depth, assigned = m.start(), 0, False
    while True:
        c = src[i]
        if c == '=' and depth == 0 and src[i + 1] != '>':
            assigned = True
        elif c in '{[(':
            depth += 1
        elif c in '}])':
            depth -= 1
            if depth == 0 and c == '}' and not assigned:
                return src[m.start():i + 1]
        elif c == ';' and depth == 0:
            return src[m.start():i + 1]
        i += 1


body = '\n\n'.join(item(p) for p in ITEMS)
test = r'''
#![allow(dead_code)]
#[derive(Debug, PartialEq)]
pub(crate) enum InitdataError { BufferSize }
pub(crate) const M5_STATUS_CONFIG_SIZE: usize = 0x780;
pub(crate) const M5_25G76_HW_DATA_SIZE: usize = 0x2708;
''' + body + r'''

fn main() {
    let mut old = vec![0u8; M5_STATUS_CONFIG_SIZE];
    write_relocated_words(M5_25G76_STATUS_CONFIG_WORDS, 0, COMMON26_STATUS_CONFIG_BANDS, &mut old).unwrap();
    let mut new = vec![0u8; M5_STATUS_CONFIG_SIZE];
    write_m5_status_config_words(&M5_26A428_STATUS_CONFIG, &mut new).unwrap();
    assert_eq!(old, new, "26A428 path differs");
    println!("26A428: map path byte-identical to write_relocated_words ({:#x} bytes)", old.len());
    let mut b = vec![0u8; M5_26B123_STATUS_CONFIG.size];
    write_m5_status_config_words(&M5_26B123_STATUS_CONFIG, &mut b).unwrap();
    assert!(write_m5_status_config_words(&M5_26B123_STATUS_CONFIG, &mut new).is_err());
    let r = |o| M5_26B123_STATUS_CONFIG.relocate(o).unwrap();
    println!("26B123: link {:#x}/{:#x}, history {:#x} {:#x} {:#x}", r(M5_STATUS_CONFIG_LINK_WORD),
        r(M5_STATUS_CONFIG_LINK_PTR), r(M5_STATUS_CONFIG_HISTORY),
        r(M5_STATUS_CONFIG_HISTORY_GENERATION), r(M5_STATUS_CONFIG_HISTORY_SLOTS));
    assert_eq!(M5_26A428_STATUS_CONFIG.relocate(0x780), None);
    assert_eq!(M5_26B123_STATUS_CONFIG.relocate(0x780), None);
    for o in (0..b.len()).step_by(4) {
        let w = u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]);
        if w != 0 { print!("{o:#05x}={w:#x} "); }
    }
    println!();
}
'''
os.makedirs(work, exist_ok=True)
path = os.path.join(work, 'statuscfg.rs')
open(path, 'w').write(test)
exe = os.path.join(work, 'statuscfg')
subprocess.run(['rustc', '--edition', '2021', '-O', '-o', exe, path], check=True)
subprocess.run([exe], check=True)
