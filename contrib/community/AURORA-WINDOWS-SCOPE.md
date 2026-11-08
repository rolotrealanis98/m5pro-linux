# Scope: "Aurora Windows" (Windows on Apple Silicon) and the J716s (M5 Pro, T6050)

Written 2026-11-08 from public sources only (GitHub API, repository docs, commit and PR text, web search). Nothing was
booted, built or posted. Code was not read line by line: statements about code come from README/docs, commit messages,
PR bodies and file lists, and say so. "Unverified" = no primary source found or only a secondary summary. No per-unit
values appear here.

## 0. Recommendation

**WATCH, and harvest offline.** Do not try it on the J716s yet.

- No project called "Aurora Windows" exists. What exists is Aurora Silicon's Windows port, built on NT-for-ASi's Project Mu
  firmware plus an m1n1-derived EL2 hypervisor. The part that runs on our SoC (J714s, T6050) lives on an unmerged `dev`
  branch and needs a private resident (`x1n1`, not published) and private Windows drivers. Public code alone cannot
  reproduce a boot on a J716s. Windows is not installable from the public pieces on any M5 machine.
- Worth doing now, zero hardware risk: read the T6050 pieces in `aurora-silicon/mu` `dev` against our DT and gap map
  (section 5). First step: `git clone` it into the scratch area, pin `dev` at `8bac64d8`, and diff its T6050 AIC3 table, ANS
  hand-over notes and N1 admission rules against `contrib/pending/` notes.
- Re-evaluate when any of these happens: Aura PR #92 merges (Windows personality in public Aura), Mu PR #2 merges (J714 on
  `main`), or a T6050 Windows driver package is published.
- Correction for our own docs: `FULL-SUPPORT-GAP-MAP.md` (lines 35 and 73) calls Aura an "EL2 monitor, nested virt". Aura PR #77
  removed the monitor, PSCI, NV2 and PV-KVM on 2026-11-07 (section 3).

## 1. What it is

| Piece | What it is | Source |
|---|---|---|
| NT for Apple Silicon (NTASP), 2022-> | The original effort. UEFI (Project Mu) + m1n1 hypervisor fork + Windows drivers. Lead: Arminder Singh (amarioguy). Not installable. | https://github.com/NT-for-ASi/.github/blob/main/profile/README.md , https://github.com/NT-for-ASi/nt-for-asi.github.io/blob/master/docs/index.md |
| `aurora-silicon/mu` | Fork of NT-for-ASi's `apple_silicon_platforms_mu`; forked 2026-07-31; base 2026-07-08, "137 ours, 0 theirs". | https://github.com/aurora-silicon/mu , https://github.com/aurora-silicon/mu/blob/main/Docs/FORK.md |
| Aura `WINDOWS=1` personality | Opt-in build of Aurora's m1n1 fork (Aura) that runs Windows as an EL1 guest with native AIC, PSCI, a vGIC path, serial/framebuffer capture, and loads Mu as guest firmware. Open draft PR, not in `main`. | https://github.com/aurora-silicon/aura/pull/92 , https://github.com/aurora-silicon/aura/blob/98599af29c644e89ab7f844ce94633cd451fd63a/docs/windows-boot.md |
| `x1n1` (private) | The Windows resident the J714 docs depend on ("`aurora-silicon/x1n1:windows`"). Not in the public org list. | https://github.com/aurora-silicon/mu/blob/dev/Platform/MacBookProM5Pkg/WINDOWS.md , https://github.com/orgs/aurora-silicon/repositories |
| Windows drivers | Aurora's per-driver qualification is in a private path (`AuroraSilicon:targets/j714s/windows/README.md`). The public `Windows-driver-samples` repo is an unmodified Microsoft fork (0 commits ahead). NT-for-ASi's driver repo has only an AIC HAL extension plan. | same WINDOWS.md; https://github.com/NT-for-ASi/apple_silicon_nt_drivers |
| Earlier internal name | A "Windows On Silicon T8142 Mu platform" import (2026-08-08) appears in Mu `dev` history. | https://github.com/aurora-silicon/mu/commits/dev |

Architecture answer to the question asked: not an EL2 monitor that presents ACPI by itself and not a Linux-hosted VM.
Chain is **iBoot -> (proxy RAM-boot from a second Mac) -> Aura/x1n1 hypervisor at EL2 -> Mu UEFI+ACPI as guest firmware -> Windows Boot Manager -> Windows at EL1**.
Mu produces the ACPI (MADT, GTDT, PPTT, CSRT, FADT, MCFG, DSDT) because "a Mac publishes none", provides only boot-time
drivers (storage to read the installer/ESP, display, input, interrupts, DART, PCIe) and "hands off state Windows cannot
reconstruct" (wireless DART reservation, GPU initdata region, ANS ownership): https://github.com/aurora-silicon/mu/blob/main/Docs/FORK.md .
Tables come from the Apple Device Tree handed over at boot, not from Linux DTs (same document). Windows needs a GIC; Apple has
AIC, so older work emulated a GICv3; the M5 work publishes native AIC v3 ACPI (GICC-only MADT, AIC3 CSRT):
https://github.com/aurora-silicon/mu/commit/60ab0fa2 .
Older, different efforts: Parallels/UTM/VMware guests (Windows as a VM, no hardware ownership;
https://www.parallels.com/products/desktop/microsoft-authorized-solution-windows-11-arm/), Asahi's U-Boot/UEFI environment, and
a 2022 NTASP announcement (https://liliputing.com/m1-windows-project-aims-to-bring-microsofts-desktop-os-to-apple-silicon-unofficially/).

## 2. State per machine (public evidence only)

| Mac / SoC | Claim | Evidence level |
|---|---|---|
| M5 MacBook Air (J813, T8142) | Installed NVMe Windows reaches a rendered lock screen/desktop, built-in keyboard and trackpad work, ten-minute run, launched from a second Mac over USB. N1/Wi-Fi unqualified; no accelerated GPU; CPU frequency scaling is separate work. | PR text + hashed observation record, author-reported: https://github.com/aurora-silicon/aura/pull/92 , https://github.com/aurora-silicon/aura/blob/98599af29c644e89ab7f844ce94633cd451fd63a/docs/validation/windows-j813-20261106.json . No video found (unverified independently). |
| M5 Pro MacBook Pro 14 (J714s, T6050) | "boots WinPE on hardware with Wi-Fi, Bluetooth, DVFS and NVMe"; display is iBoot's framebuffer (DCP resources are only enumerated, "no Windows display takeover is claimed"); 17 guest CPUs plus one host monitor; N1 passed single-boot scan/associate/DHCP/HTTP and a Bluetooth radio query; reconnect, power transitions, all-18-CPU, stress and **Windows installation unfinished**; internal-SSD boot from firmware not finished; interactive UEFI menu is "host-tested but not hardware-tested". | https://github.com/aurora-silicon/mu/pull/2 , https://github.com/aurora-silicon/mu/blob/dev/Platform/MacBookProM5Pkg/WINDOWS.md , https://github.com/aurora-silicon/mu/commit/8029b3a7 . Author-reported, no independent confirmation. PR #2 is a parked draft ("Mu stays on `dev`"). |
| M1 MacBook Air (J313) | Separate third-party repo claims Windows 11 ARM64 from the internal SSD, all 8 cores, built-in input, a from-scratch WDDM GPU driver (D3D12 FL12_1, ~68% of Metal in one benchmark), native ANS driver. GPU still needs a second Mac. "Developed with substantial help from AI coding assistants." | https://github.com/ElfariaKensington/windows-on-m1-pro (repo created 2026-11-05, single main author, 0 stars). Unverified; screenshots only. Builds on NT-for-ASi. |
| M1/M2 (NTASP upstream) | "Not installable"; Windows "barely booting", only Windows-to-Go boots tested; a second machine is required; upstream Mu README: loader "hangs on the handoff between bootloader and kernel". | https://github.com/NT-for-ASi/nt-for-asi.github.io/blob/master/docs/project-info/when-will-ntasp-be-done.md , https://github.com/NT-for-ASi/apple_silicon_platforms_mu/blob/main/README.md |
| J716s | No Aurora/Mu Windows work. Mu `main` has no T6050 or MacBookPro M5 platform; only the J714s package exists, on `dev`. | https://github.com/aurora-silicon/mu/tree/main/Platform , https://github.com/aurora-silicon/mu/tree/dev/Platform/MacBookProM5Pkg |

Hardware and driver handling (what is verifiable): GPU none on M5; display = firmware framebuffer; storage = a Windows-side
NVMe read path (firmware ANS block driver exists but is off); input = MTP keyboard (Windows service `AppleMtpHid` started on
J813); Wi-Fi/BT = the N1 over an exclusive Aura-to-Mu-to-Windows handoff record; USB withheld while Aura owns the transport
(https://github.com/aurora-silicon/aura/blob/98599af29c644e89ab7f844ce94633cd451fd63a/docs/windows-n1.md). Who signs the
drivers, secure boot state and the Windows build number: **unverified** for Aurora (drivers private). The M1 repo says its
drivers are "installed as a standard boot driver with its own permanent test certificate"
(https://github.com/ElfariaKensington/windows-on-m1-pro), i.e. test signing; Aurora's approach is likely the same but not stated.

## 3. Status and credibility

- Authors: NT-for-ASi: amarioguy (lead), graphine27, "zx" (https://github.com/NT-for-ASi/.github/blob/main/profile/README.md).
  Aurora Windows commits: DjDeveloperr (Diljit Singh) and Acelogic (Miguel Cruz); site authors DjDeveloperr, RyanTheTide
  (https://github.com/aurora-silicon/aurora-silicon.github.io/blob/main/AUTHORS).
- Activity: Mu `dev` J714 work 2026-09-27..10-08; J813 Windows handoff PRs 2026-11-06..07 (mu #3, #6; aura #92-#96);
  NT-for-ASi upstream last push 2026-09-08. Aurora's org page: "We're also working on porting Windows to Apple Silicon"
  (https://github.com/aurora-silicon/.github/blob/main/profile/README.md); the website scope is Linux-only
  (https://github.com/aurora-silicon/aurora-silicon.github.io/blob/main/README.md). Windows is a side effort next to Linux.
- Heavily AI-assisted on the Aurora side (commit trailers "Co-Authored-By: Claude Opus 4.8" in
  https://github.com/aurora-silicon/mu/commit/60ab0fa2 ; PR bodies "Generated with Claude Code"). PR text is detailed and
  hedged ("document limits rather than claiming complete platform support"); treat results as author-reported.
- Aura just dropped its EL2 monitor: PR #77 (merged 2026-11-07, "has not booted on any hardware" at writing) removes monitor,
  PSCI, NV2, PV-KVM; Linux runs at EL2 inside the CTXR window; "aura's own hypervisor in `src/hv`" stays
  (https://github.com/aurora-silicon/aura/pull/77). The repo description is stale ("EL2-resident monitor... nested virtualization").
  The Windows hypervisor is separate (`src/hv/windows/`, PR #92); the J813 doc calls the Windows tree "the older local Aurora
  Windows development fork" (https://github.com/aurora-silicon/aura/blob/main/docs/j813-native-boot.md).
- Licences: Mu: README says BSD-2-Clause or MIT, some parts "(MIT OR BSD-2-clause) AND GPL"
  (https://github.com/aurora-silicon/mu/blob/main/README.md). Aura: inherited m1n1 code MIT, Aurora contributions
  GPL-2.0-only, mixed files "MIT AND GPL-2.0-only" (https://github.com/aurora-silicon/aura/blob/main/docs/licensing.md).
  NT-for-ASi m1n1_windows MIT, drivers MIT/GPL2 (https://github.com/NT-for-ASi/apple_silicon_nt_drivers). Asahi's stated
  policy favours permissive licences (https://asahilinux.org/copyright); I found no Asahi relicensing announcement (unverified
  that one exists).
- What Asahi people say: Mu README says Asahi maintainers gave "unofficial guidance" and the project is "explicitly not
  officially part of or affiliated with" Asahi, thanking marcan and Sven Peter. A 2023 marcan remark that bare-metal Windows
  was unlikely to ever run appears only in a search summary (unverified). No Asahi or Aurora statement on the M5 Windows work found.
- Not found: any blog post, video or third-party coverage of the M5 Windows boots (web searches 2026-11-08 returned only VM guides).

## 4. Feasibility on the J716s

Same SoC as the J714s (T6050) but a different board: Aurora's own device table lists J714s and J716s as separate boards
(https://github.com/aurora-silicon/aurora-silicon.github.io/blob/main/src/data/devices.json). Needed:

1. A resident with the Windows personality for T6050: Aura PR #92 is generic but "hardware qualification is limited to J813";
   the J714 Windows run used private x1n1. Gate: PR #92 merged plus a T6050 profile, or x1n1 published.
2. A J716s board package in Mu: copy of `MacBookProM5Pkg` (named J714, topology header "J714s", 18 captured MPIDRs) adapted to
   our ADT; the per-board ACPI (display, SMC, N1, MTP) must come from our ADT, not theirs.
3. Windows drivers (HAL/AIC, MTP, N1 transport, SMC, ANS) and a Windows 11 ARM64 ISO/WinPE: none public for M5.
4. A second Mac on USB (our Studio) and a matching proxy resident; our chain uses omacom/m1n1 with Linux at EL2 on the J716s,
   not Aura/x1n1, so the loader would change (boot-chain change = attended ceremony in our rules).
5. Per-unit firmware: N1 (extracted from our macOS as for Linux); GPU none on Windows.

Effort: XL and blocked on private pieces. Risk to the macOS install: RAM-boot from the Studio writes nothing, but a Windows
guest with an NVMe path to the internal SSD can corrupt APFS (the M1 repo warns that firmware or hypervisor defects "can corrupt any
partition"; https://github.com/ElfariaKensington/windows-on-m1-pro). Rules if it is ever tried: external USB SSD only
(Mu has `J714_USB_INSTALLER` USB installer selection; internal SSD boot unfinished), GPT with its own ESP and
`\EFI\Microsoft\Boot\bootmgfw.efi`, no change to the internal disk or our Linux ESP, USB0 stays the proxy port (as in Aurora's J714 notes),
Windows write support to internal NVMe off. First experiment, if/when unblocked: build Mu's UEFI-only profile
(`Tools/build-j714-uefi.sh`, host-tested only) and RAM-boot it to a menu without Windows; no disk access.

## 5. Relevance to us

| Our area | Overlap | Use |
|---|---|---|
| hv27 (m1n1 EL2, SPTM, macOS 27.3 guest) | Same family of problem: an m1n1-derived hypervisor on M5 with a non-Apple-OS-style guest (EL1 guest, native AIC/FIQ, PSCI, timer/PMU routing, SGI routing, counter conversion on T8142). Docs: `windows-sgi-routing`, `windows-counter-timeouts`, `windows-hv-smoke`, `windows-rtkit` in PR #92. NT's m1n1 fork also handles `TID3` traps. | Read for trap/timer/IPI lessons on M5. Guest type, SoC (T8142 vs T6050) and the macOS+SPTM goal differ; no code to reuse directly. |
| Aura / boot chain | Their Windows chain is Aura-only; Aura mainline now has no monitor and uses the CTXR-window mechanism on M4+. | Update gap map rows for Aura; our m1n1 chain unaffected. |
| T6050 ACPI/AIC | Mu publishes an AIC v3 description for T6050 (chip id, register geometry, IRQ counts, 18 CPUs) in the public commit. | Cross-check our DT `aic` node and CPU count against it (names/sizes only). |
| ANS hand-over (gap map line 72, "ANS live hand-over ported into stage 1") | Mu's `J714AnsDxe` plus the explicit finding that "native ANS retains fixed queue addresses" and the transfer to the next owner must reuse the reserved queue pages. | Direct input for our U-Boot/stage-1 ANS hand-over. |
| N1 (Wi-Fi/BT) | Aura's exclusive N1 handoff: seven APCIE gates must be at power state 0, PERST sequence, DART SID0 disabled, bus mastering off, `NW1H` record; J714s Windows ran N1 once. | Compare with our N1 training; reusable as a checklist (J813 is the implemented target; J714 uses private x1n1). |
| DCP | Mu `dev` adds an M5 display devnode with ASC/mailbox/VBAR/PMC mappings and an SPTM query alias, gated on "native mapping ABI". | Cross-check against our DCP phandle fix and hand-off. |
| GPU firmware | J813 only: Aura/Mu "G17 preserve" record (six SGX regions, two loaded TEXT images) and Aura's `kboot_gpu.c` (PR #94 and mu #6). | ABI knowledge for the G17 hand-off; not T6050-specific. |
| MTP / keyboard | Mu has M5 RTKit runtime core and MTP bootstrap/HID code. | Cross-check only; our keyboard already works. |
| Gap map | No row for Windows. Add one "Windows on T6050: not planned; watch" or leave it out. | Edit gap map lines 35/73 (Aura monitor). |

Not found helpful: Windows drivers (private), GPU on Windows for M5 (none), anything about T6050 power/idle.

## Sources (index)
- Org: https://github.com/aurora-silicon , site https://aurorasilicon.org/ (redirect of aurora-silicon.github.io)
- Mu fork: https://github.com/aurora-silicon/mu (branches `main`, `dev`, `codex/windows-mu-handoff`); PRs #2, #3, #6
- Aura: https://github.com/aurora-silicon/aura PRs #77, #92-#96; docs at commit 98599af2
- m1n1 Windows lineage: https://github.com/aurora-silicon/m1n1/commit/69534d4899e20108d2c7a085565a7097509fa17f (fork of https://github.com/omacom/m1n1)
- NT-for-ASi: https://github.com/NT-for-ASi
- Third-party M1: https://github.com/ElfariaKensington/windows-on-m1-pro
- Our docs: `contrib/community/FULL-SUPPORT-GAP-MAP.md`, `contrib/pending/hv/PLAN-27.3.md`
