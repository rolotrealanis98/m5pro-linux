# builtins.exec()'d (the shell's own exec is u.exec, an assembler) in the m1n1 hv shell (hvsh.sh) after a break: everything needed to see why the
# SPTM/XNU guest stopped, in one go, before the dead-man watchdog or a reboot loses it.
def _diag():
    ctx()
    regs = {r: u.mrs(r) for r in ("ESR_EL12", "ELR_EL12", "FAR_EL12", "SPSR_EL12", "VBAR_EL12")}
    print("EL12:", {k: hex(v) for k, v in regs.items()})
    # SPTM's panic routine formats its message into the buffer it keeps in x19
    for name, va in (("x19", hv.ctx.regs[19]), ("x0", hv.ctx.regs[0])):
        pa = p.hv_translate(va) if va >= 0xfffff00000000000 else 0
        if not pa:
            continue
        msg = iface.readmem(pa, 0xaf0).split(b"\0")[0]
        if len(msg) > 8 and all(32 <= c < 127 or c in (9, 10) for c in msg):
            print(f"PANIC MESSAGE ({name}):", msg.decode())
    # the instruction that faulted (ELR_EL12), as raw words, to find it in the kernelcache offline
    elr = regs["ELR_EL12"]
    pa = p.hv_translate(elr - 0x20) if elr >= 0xfffff00000000000 else 0
    if pa:
        words = iface.readmem(pa, 0x40)
        print("ELR_EL12 code @", hex(elr - 0x20), words.hex())
    try:
        bt()
    except Exception as e:
        print("bt failed:", e)
_diag()
