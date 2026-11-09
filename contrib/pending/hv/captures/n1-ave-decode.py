#!/usr/bin/env python3
# Offline decoder for hv27 apcie0/ave0 MMIO traces (read-only).
# Usage: python3 -I n1-ave-decode.py LOG [apcie|ave|gpio|pmgr|ecam|iters|timeline [FIRST_LINE LAST_LINE]]
#   apcie, ave   original modes (apcie0 / ave0 register windows; output unchanged)
#   gpio         gpio0.pcie with pad numbers, pad-field decode, PERST#/CLKREQ# labels, RMW loops collapsed
#   pmgr         pmgr.apcie (0x280900100+0x200) with device names and decoded PS fields
#   ecam         apcie0.ecam as bus:dev.fn + register name (config reads/writes, endpoint check)
#   iters        port bring-up milestones (reset table, LTSSM start, link up, PERST#, PME_Turn_Off, counters)
#   timeline     all regions merged in log order, polls/loops/sequential writes collapsed
# Line numbers are log lines.  Pure offline parser: reads the log only.
import re, sys, itertools
rx = re.compile(r'^\[cpu(\d+)\] \[(0x[0-9a-f]+)\] MMIO: ([RW])\.(\d)\s+(0x[0-9a-f]+) \(([\w.]+), offset (0x[0-9a-f]+)\) = (0x[0-9a-f]+)')

# ---- device tables: /arm-io/pmgr `devices` (ps group 1, window 0x280900100..0x280900300); pad roles from the ADT ----
PMGR_G1 = {0x280900100: 'ISPSENS0', 0x280900108: 'GLOBAL_AUX_HPD_0', 0x280900110: 'GLOBAL_AUX_HPD_1', 0x280900118: 'APCIE_GP', 0x280900120: 'APCIE_GE', 0x280900128: 'APCIE_ST0', 0x280900130: 'APCIE_ST1', 0x280900138: 'FAB6_SOC', 0x280900140: 'ANS', 0x280900148: 'APCIE_SYS_GP', 0x280900150: 'APCIE_SYS_ST0', 0x280900158: 'APCIE_SYS_ST1', 0x280900160: 'APCIE_SYS_GP_OC', 0x280900168: 'APCIE_SYS_ST0_O', 0x280900170: 'APCIE_SYS_ST1_O', 0x280900178: 'FAB7_SOC', 0x280900180: 'DISP_SYS', 0x280900188: 'APCIE_SYS_GE', 0x280900190: 'SCODEC', 0x280900198: 'DISP_FE', 0x2809001a0: 'DISP_ADMA', 0x2809001a8: 'DISP_CPU', 0x2809001b0: 'APCIE_PHY_SW', 0x2809001b8: 'APCIE_SYS_GE_OL', 0x2809001c0: 'SCODEC_STREAMING', 0x2809001c8: 'DISP_SPI', 0x2809001d0: 'DISP_SPMI', 0x2809001d8: 'DISP_SMB0', 0x2809001e0: 'DISP_SMB1', 0x2809001e8: 'DISP_DBE', 0x2809001f0: 'DP', 0x2809001f8: 'DISP_GP0', 0x280900200: 'DISP_GP1', 0x280900208: 'DISP_GPL', 0x280900210: 'DISP_CMB', 0x280900218: 'DISP_PPP', 0x280900220: 'DISP_BRC', 0x280900228: 'DISP_BLC', 0x280900230: 'DISP_HILO', 0x280900238: 'DISP_RCA', 0x280900240: 'APHY_ST0_AUS5_A', 0x280900248: 'APHY_ST1_AUS5_A', 0x280900250: 'APHY_GE_AUS5_A', 0x280900258: 'APHY_GP_AUS5_A', 0x280900260: 'DISP_DSC', 0x280900268: 'APHY_ST0_AUS5', 0x280900270: 'APHY_ST1_AUS5', 0x280900278: 'APHY_GE_AUS5', 0x280900280: 'APHY_GP_AUS5', 0x280900288: 'FAB8_SOC', 0x280900290: 'SIO', 0x280900298: 'SEP', 0x2809002a0: 'SIO_CPU', 0x2809002a8: 'FPWM0', 0x2809002b0: 'FPWM1', 0x2809002b8: 'FPWM2', 0x2809002c0: 'I2C0', 0x2809002c8: 'I2C1', 0x2809002d0: 'I2C2', 0x2809002d8: 'I2C3', 0x2809002e0: 'I2C4', 0x2809002e8: 'I2C5', 0x2809002f0: 'I2C6', 0x2809002f8: 'I2C7'}
# pad -> role.  ADT: function-perst / -clkreq / -debug_gpio of /arm-io/apcie0 and pci-bridge*, IRQ pins of spi2/mesa etc.
PAD_ROLE = {76: 'CLKREQ#0 (ADT pci-bridge0)', 77: 'CLKREQ#1 (ADT pci-bridge1)', 80: 'PERST#0 (ADT pci-bridge0)',
            81: 'PERST#1 (ADT pci-bridge1)', 109: 'debug_gpio (ADT apcie0)', 138: 'mesa IRQ (ADT spi2/mesa)',
            52: 'spi4 cs0 (ADT)', 106: 'audio-speaker IRQ (ADT)', 134: 'audio-codec IRQ (ADT)'}
for _p in range(58, 76):
    PAD_ROLE.setdefault(_p, 'clkreq-class pad (func1 at boot; role not in ADT)')
ECAM_REG = {0x00: 'ID', 0x04: 'CMD/STS', 0x08: 'CLASS/REV', 0x0c: 'HDR', 0x10: 'BAR0', 0x14: 'BAR1', 0x18: 'BUSES',
            0x1c: 'IO/SECSTS', 0x20: 'MEM base/limit', 0x24: 'PREF base/limit', 0x28: 'PREF base hi', 0x2c: 'PREF limit hi',
            0x30: 'IO hi', 0x34: 'CAPPTR', 0x38: 'ROMBAR', 0x3c: 'INTR/BRCTL', 0x40: 'PM cap', 0x44: 'PMCSR', 0x50: 'MSI cap',
            0x70: 'PCIe cap', 0x74: 'DevCap', 0x78: 'DevCtl/Sta', 0x7c: 'LnkCap', 0x80: 'LnkCtl/Sta', 0x94: 'DevCap2',
            0x98: 'DevCtl2', 0x9c: 'LnkCap2', 0xa0: 'LnkCtl2/Sta2', 0xa8: 'SltCtl2', 0x100: 'AER hdr', 0x104: 'AER UE sta',
            0x108: 'AER UE mask', 0x10c: 'AER UE sev', 0x110: 'AER CE sta', 0x114: 'AER CE mask', 0x118: 'AER ctl',
            0x12c: 'AER root cmd', 0x130: 'AER root sta', 0x148: 'SECPCI hdr', 0x154: 'SECPCI lane EQ', 0x158: 'PL16 hdr',
            0x178: 'PL16 lane EQ', 0x17c: 'LMR hdr', 0x18c: 'PL32 hdr', 0x194: 'PL32 ctl', 0x1ac: 'PL32 lane EQ',
            0x1b8: 'L1SS hdr', 0x1bc: 'L1SS cap', 0x1c0: 'L1SS ctl1', 0x1c4: 'L1SS ctl2', 0x1c8: 'VSEC hdr',
            0x2c8: 'DLF hdr', 0x2d4: 'PTM hdr', 0x2d8: 'PTM cap', 0x2dc: 'PTM ctl', 0x2e0: 'VSEC hdr',
            0x318: 'vendor (PTM table val A)', 0x31c: 'vendor (PTM table val B)', 0x328: 'vendor (PTM table idx)',
            0x710: 'PORT_LINK_CTRL', 0x728: 'PORT_DEBUG0', 0x80c: 'GEN2_CTRL', 0x890: 'GEN3_RELATED',
            0x8a8: 'GEN3_EQ_CTRL', 0x8ac: 'GEN3_EQ_FB', 0x8bc: 'MISC_CTRL_1'}
PORT_REG = {0x80: 'LTSSMCTL', 0x88: 'PME/L2', 0xa8: 'CLKRST', 0x100: 'INTSTAT', 0x104: 'INTMSK', 0x124: 'MSICFG',
            0x16c: 'MSIADDR', 0x170: 'MSIADDR_HI', 0x208: 'LINKSTS', 0x800: 'APPCLK', 0x804: 'STATUS',
            0x82c: 'PERST/RESET', 0x4000: 'cnt0', 0x4020: 'cnt-ctl'}


def parse(path):
    ev = []
    for i, l in enumerate(open(path), 1):
        m = rx.match(l)
        if m:
            c, pc, rw, sz, a, reg, off, v = m.groups()
            ev.append((i, rw, reg, int(off, 16), int(v, 16), int(sz), int(a, 16), int(pc, 16)))
    return ev


def old_modes(ev, want):
    ev = [e[:5] for e in ev if e[2].startswith('apcie0' if want == 'apcie' else 'ave0')]
    i = 0
    while i < len(ev):
        ln, rw, reg, off, v = ev[i]
        j = i
        if rw == 'R':
            while j + 1 < len(ev) and ev[j+1][1] == 'R' and ev[j+1][2] == reg and ev[j+1][3] == off:
                j += 1
            if j > i:
                vals = [ev[k][4] for k in range(i, j + 1)]
                runs = [[x, len(list(g))] for x, g in itertools.groupby(vals)]
                print('L%d..%d R %s+%#x x%d: %s' % (ln, ev[j][0], reg, off, j - i + 1,
                      ' '.join('%#x%s' % (x, '(x%d)' % n if n > 1 else '') for x, n in runs)))
                i = j + 1
                continue
        else:
            while j + 1 < len(ev) and ev[j+1][1] == 'W' and ev[j+1][2] == reg and ev[j+1][3] == ev[j][3] + 4 and ev[j+1][4] == v:
                j += 1
            if j > i + 1:
                print('L%d..%d W %s+%#x..+%#x x%d = %#x' % (ln, ev[j][0], reg, off, ev[j][3], j - i + 1, v))
                i = j + 1
                continue
        print('L%d %s %s+%#x = %#x' % (ln, rw, reg, off, v))
        i += 1


# ---- field decoders ----
def pad_fields(v):
    mode = (v >> 1) & 7
    mname = {1: 'OUT', 2: 'IRQ_HI', 3: 'IRQ_LO', 4: 'IRQ_UP', 5: 'IRQ_DN', 6: 'IRQ_ANY', 7: 'IN/IRQ_OFF', 0: 'mode0'}[mode]
    return 'data=%d mode=%s periph=%d inen=%d grp=%d%s' % (v & 1, mname, (v >> 5) & 3, (v >> 9) & 1, (v >> 16) & 7,
                                                           ' bit4' if v & 0x10 else '')


def ps_fields(v):
    s = 'target=%x actual=%x' % (v & 0xf, (v >> 4) & 0xf)
    fl = []
    if v & 0x100: fl.append('WAS_PWRGATED')
    if v & 0x200: fl.append('WAS_CLKGATED')
    if v & 0x10000000: fl.append('AUTO_EN')
    if (v >> 24) & 0xf: s += ' auto=%x' % ((v >> 24) & 0xf)
    return s + (' ' + '+'.join(fl) if fl else '')


def ecam_name(a):
    o = a - 0x1cb0000000
    return o >> 20, (o >> 15) & 0x1f, (o >> 12) & 7, o & 0xfff


def label(e):
    ln, rw, reg, off, v, sz, a, pc = e
    if reg == 'gpio0.pcie':
        if off < 0x400:
            p = off // 4
            return 'gpio pad%d%s' % (p, ' [%s]' % PAD_ROLE[p] if p in PAD_ROLE else '')
        return 'gpio irq-reg+%#x' % off
    if reg == 'pmgr.apcie':
        return 'pmgr %s' % PMGR_G1.get(a, hex(a))
    if reg == 'apcie0.ecam':
        b, d, f, r = ecam_name(a)
        n = ECAM_REG.get(r & ~3, '')
        return 'ecam %02x:%02x.%d+%#x%s' % (b, d, f, r, ' [%s]' % n if n else '')
    if reg in ('apcie0.reg16', 'apcie0.reg22'):
        n = PORT_REG.get(off)
        return '%s+%#x%s' % (reg.replace('apcie0.', ''), off, ' [%s]' % n if n else '')
    return '%s+%#x' % (reg.replace('apcie0.', ''), off)


def decorate(e):
    ln, rw, reg, off, v, sz, a, pc = e
    if reg == 'gpio0.pcie' and off < 0x400:
        return pad_fields(v)
    if reg == 'pmgr.apcie':
        return ps_fields(v)
    return ''


def is_poll_pad(e):
    return e[2] == 'gpio0.pcie' and e[3] in (0x110, 0x114, 0x118, 0x11c)


def timeline(ev):
    out = []
    i, n = 0, len(ev)
    while i < n:
        e = ev[i]
        if is_poll_pad(e):
            j = i
            while j + 1 < n and is_poll_pad(ev[j + 1]):
                j += 1
            pads = sorted(set(x[3] // 4 for x in ev[i:j + 1]))
            vals = sorted(set('%#x' % x[4] for x in ev[i:j + 1]))
            out.append('L%d-%d GPIO RMW loop pads %s n=%d values %s (R,W,R of one pad per round; PCs %s)' % (
                e[0], ev[j][0], pads, j - i + 1, vals, '/'.join(sorted(set('%x' % (x[7] & 0xfffff) for x in ev[i:j + 1])))))
            i = j + 1
            continue
        if e[1] == 'R':
            j = i
            while j + 1 < n and ev[j+1][1] == 'R' and label(ev[j+1]) == label(e) and ev[j+1][5] == e[5] and not is_poll_pad(ev[j+1]):
                j += 1
            if j > i:
                vals = [ev[k][4] for k in range(i, j + 1)]
                runs = [[x, len(list(g))] for x, g in itertools.groupby(vals)]
                out.append('L%d-%d R %s x%d: %s' % (e[0], ev[j][0], label(e), j - i + 1,
                           ' '.join('%#x%s' % (x, '(x%d)' % c if c > 1 else '') for x, c in runs)))
                i = j + 1
                continue
        else:
            j = i
            if e[2] not in ('apcie0.ecam', 'pmgr.apcie'):
                while j + 1 < n and ev[j+1][1] == 'W' and ev[j+1][2] == e[2] and ev[j+1][3] == ev[j][3] + 4 and ev[j+1][4] == e[4]:
                    j += 1
            if j > i + 1:
                out.append('L%d-%d W %s..+%#x x%d = %#x' % (e[0], ev[j][0], label(e), ev[j][3], j - i + 1, e[4]))
                i = j + 1
                continue
        d = decorate(e)
        out.append('L%d %s%d %s = %#x%s' % (e[0], e[1], e[5], label(e), e[4], '  (%s)' % d if d else ''))
        i += 1
    return out


def iters(ev):
    ports = {'apcie0.reg16': 'port0(N1)', 'apcie0.reg22': 'port1(SD)'}
    seen_up = {}
    for e in ev:
        ln, rw, reg, off, v, sz, a, pc = e
        if reg in ports:
            p = ports[reg]
            if rw == 'W' and off == 0x88 and v == 0x110:
                print('L%d %s reset table begins (0x88=0x110)' % (ln, p))
            elif rw == 'W' and off == 0x80 and v == 1:
                seen_up[p] = False
                print('L%d %s LTSSM start' % (ln, p))
            elif rw == 'R' and off == 0x100 and (v & 0x1000) and not seen_up.get(p):
                seen_up[p] = True
                print('L%d %s first INTSTAT %#x after LTSSM start (bit12 LINK_UP)' % (ln, p, v))
            elif rw == 'W' and off == 0x88 and v == 0x11:
                print('L%d %s PME_Turn_Off' % (ln, p))
            elif rw == 'R' and off == 0x4000 and v:
                print('L%d %s counter0 %#x = %d (%.2f s if 24 MHz, %.2f s if 100 MHz)' % (ln, p, v, v, v / 24e6, v / 100e6))
            elif rw == 'W' and off == 0x4020:
                print('L%d %s counter ctl <- %#x' % (ln, p, v))
            elif rw == 'W' and off == 0x3004 and v:
                print('L%d %s RID2SID slot1 <- %#x (RID %#x SID %d)' % (ln, p, v, v & 0xffff, (v >> 16) & 0xff))
        elif reg == 'gpio0.pcie' and off in (0x140, 0x144, 0x130, 0x134) and rw == 'W':
            print('L%d gpio pad%d [%s] <- %#x (%s)' % (ln, off // 4, PAD_ROLE.get(off // 4), v, pad_fields(v)))
        elif reg == 'apcie0.ecam' and rw == 'W' and ecam_name(a)[3] in (0x18, 0xa0, 0x24, 0x20, 0x1c, 0x4):
            b, d, f, r = ecam_name(a)
            print('L%d ecam %02x:%02x.%d+%#x <- %#x [%s]' % (ln, b, d, f, r, v, ECAM_REG.get(r, '')))
    busx = [e for e in ev if e[2] == 'apcie0.ecam' and ecam_name(e[6])[0] != 0]
    print('ECAM accesses to bus != 0 (endpoint config space): %d' % len(busx))


def main():
    ev = parse(sys.argv[1])
    mode = sys.argv[2] if len(sys.argv) > 2 else 'apcie'
    if mode in ('apcie', 'ave'):
        old_modes(ev, mode)
        return
    lo = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    hi = int(sys.argv[4]) if len(sys.argv) > 4 else 1 << 30
    ev = [e for e in ev if lo <= e[0] <= hi]
    if mode == 'gpio':
        ev = [e for e in ev if e[2] == 'gpio0.pcie']
    elif mode == 'pmgr':
        ev = [e for e in ev if e[2] == 'pmgr.apcie']
    elif mode == 'ecam':
        ev = [e for e in ev if e[2] == 'apcie0.ecam']
    elif mode == 'iters':
        iters(ev)
        return
    elif mode != 'timeline':
        sys.exit('unknown mode ' + mode)
    print('\n'.join(timeline(ev)))


main()
