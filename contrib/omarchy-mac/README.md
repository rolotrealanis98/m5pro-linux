# omarchy-mac: tracking every Mac customization for Omarchy

Everything we change on a MacBook running Omarchy (the J716s, 16-inch M5 Pro, is the test machine) is listed here, can be put on a fresh
install, and says where it could go upstream. This folder is the tracking layer; most of the actual files still live where they were
written (`contrib/distro/`, `contrib/validated/desktop/`, `contrib/pending/*`), and the inventory points at them. **Existing directories
are not moved or renamed** because reports link to them.

## What is here

| File | Purpose |
|---|---|
| `INVENTORY.md` | One row per customization: what it does, scope, status, repo path, installed paths on the Mac, install, undo, upstream target. Also: untracked-on-purpose items, PRIVATE per-machine data, drift, and things that look wrong on the Mac |
| `UPSTREAM.md` | Grouped by upstream target: what is ready to propose, what each needs first. Nothing outward-facing has been done |
| `audit-macbook.sh` | Read-only audit run from the Studio over SSH: lists what differs from stock, then prints what `INVENTORY.md` does not track (and what it lists that is not on the Mac) |
| `audit-ignore.txt` | Findings that are stock Omarchy output, machine state or third-party, each with a reason |
| `install-item.sh` | Puts an item of this folder onto a Mac, or removes it |
| `<item>/` | Files for items first captured here (see "New items") |

## The three labels

**Scope** - who the item is for:

- `generic`: any Apple Silicon Mac on Omarchy.
- `t6050`: the M5 Pro / M5 Max family (J714s, J716s and siblings). Needs T6050 hardware or the T6050 kernel work.
- `j716s`: this machine only (panel size, partition numbers, owner's accounts or taste).

**Status**:

- `installed`: on the MacBook now (the audit confirms the paths).
- `staged`: in the repo and ready, not installed or not booted on the Mac.
- `experimental`: built or sketched, not proven on hardware, or a rescue/legacy path.

**Upstream target**, with a one-line reason in the row:

- `aurora-silicon/<repo>`: Aurora's repositories (`alarm-aurora`, `linux`, `aura`, `speakerguardd`, `asahi-audio`, `alsa-ucm-conf-asahi`, `aurora-diag`, ...).
- `omacom/omarchy-mac-pkgs`: the Mac's own Omarchy packages (`omarchy-mac`, `omarchy-mac-boot`).
- `Omarchy itself` (omacom/omarchy): desktop, shell, bindings, the places a platform plugs in.
- `none/personal`: stays ours (taste, one machine, bring-up tooling, or no maintainer for it).

## Using it

```sh
# From the Studio: what differs from stock, and what is not tracked yet
MBP_HOST=<macbook address> contrib/omarchy-mac/audit-macbook.sh            # add --raw for every finding, --strict for exit 1 on untracked

# On a Mac: an item captured in this folder
sudo contrib/omarchy-mac/install-item.sh --user NAME --dry-run lid-sleep-s2idle
sudo contrib/omarchy-mac/install-item.sh --user NAME lid-sleep-s2idle
sudo contrib/omarchy-mac/install-item.sh --remove lid-sleep-s2idle
```

`install-item.sh` lays `files/` over `/` and `home/` over the user's home, keeps what it replaces as `*.before-omarchy-mac`, fills in
`@USER@`, and starts or enables nothing: each item's `README.md` lists the follow-up commands. Items that still live in older
folders are installed the way their row says (`apply.sh`, `install.sh`, `makepkg`).

## Rules

- **New items go under `contrib/omarchy-mac/<item>/` from now on**, with `files/` and/or `home/`, a short `README.md`, and a row in `INVENTORY.md`. Do not add new customizations to the older folders.
- The inventory is the contract: put every installed path in backticks (`/etc/...`, `~/...`, `pkg:NAME`, `unit:NAME`; a trailing `/` covers a directory). The audit treats those as tracked.
- Run the audit after any change on the Mac. Untracked output means: capture the file here (or in an existing folder) and add the row, or add a reasoned line to `audit-ignore.txt`.
- **PRIVATE data is never committed**: per-machine firmware and calibration (`mesacal-*.bin`, `msrk-*.bin`, `aop-als-cal.bin`, `tpmtfw-*.bin`, panel calibration), Wi-Fi and VPN profiles, Tailscale state, keys, tokens, host keys, serials, MAC and IP addresses, the netconsole target address. The audit prints names only. `INVENTORY.md` section H lists the private files; a fresh install regenerates them from the owner's own macOS.
- Rows owned by other work in progress say so (Touch ID: `contrib/pending/touchid-omarchy/`; speakers and speakerguardd: `/Volumes/m5pro/bench/requests/speakers-5.md`); do not edit their files from here.
- The 8TB bench is a workbench, not an archive: if a file on the bench is the only copy of something installed on the Mac, copy it into the repo and push it.
