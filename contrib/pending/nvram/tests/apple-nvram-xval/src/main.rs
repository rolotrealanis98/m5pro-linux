// Cross-check: run apple-nvram's own v3 insert + apply (as asahi-bless set_boot_volume(next=false) does)
// on a dump file, with a file-backed writer that has NOR semantics (erase -> 0xFF, program -> AND).
use apple_nvram::{nvram_parse, NvramWriter, VarType};
use std::borrow::Cow;
struct Nor { data: Vec<u8>, erases: Vec<(u32, usize)>, writes: Vec<(u32, usize)> }
impl NvramWriter for Nor {
    fn erase_if_needed(&mut self, off: u32, size: usize) {
        self.erases.push((off, size));
        for b in &mut self.data[off as usize..off as usize + size] { *b = 0xFF; }
    }
    fn write_all(&mut self, off: u32, buf: &[u8]) -> std::io::Result<()> {
        self.writes.push((off, buf.len()));
        for (d, s) in self.data[off as usize..].iter_mut().zip(buf) { *d &= *s; }
        Ok(())
    }
}
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let input = std::fs::read(&a[1]).unwrap();
    let value = a[3].clone().into_bytes();
    let mut nor = Nor { data: input.clone(), erases: vec![], writes: vec![] };
    let mut nv = nvram_parse(&input).expect("parse");
    nv.prepare_for_write();
    nv.active_part_mut().insert_variable(b"boot-volume", Cow::Owned(value), VarType::System);
    match nv.apply(&mut nor) { Ok(_) => {}, Err(e) => { eprintln!("apply error {:?}", e); std::process::exit(2) } }
    eprintln!("erases {:?} writes {:?}", nor.erases, nor.writes);
    std::fs::write(&a[2], &nor.data).unwrap();
}
