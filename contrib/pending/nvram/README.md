# nvram: boot NOR and NVRAM from Linux on the J716s (T6050)

Goal: let Linux set the next boot to macOS (`asahi-bless --next`) without touching the Mac. Full write-up, safety
analysis and test plan: `~/Work/agents/nvram-t6050/REPORT.md` (Studio). Studio-only work: nothing here has run on the MacBook.

Base: `j716s-series` `a0f2f30c967b`; the three patches also apply on top of `dtprep-stack` `eb9d77674727`.
Author and Signed-off-by: Rolando Trevino.

| Patch | sha256 | Needs |
|---|---|---|
| `patches/0001-arm64-dts-apple-j716s-Enable-the-boot-NOR-and-its-NV.patch` | `b904827a87b993df9e3833998e20c78c26a109de0ac9543b4fda32f1b07277cc` | DTB: reads only; the driver refuses writes without 0002 |
| `patches/0002-spi-apple-qspi-admit-verified-NVRAM-writes-on-the-J7.patch` | `926c73c76b6f44acdd0868ef1e9b2d0329e1fe8047bf6f756a77a38282a83a67` | module `spi-apple-qspi.ko`: apply only after the read-only test passed |
| `patches/0003-spi-apple-qspi-log-the-flash-ID-and-status-when-a-wr.patch` | `622ec6e8ffa2990844019eaab04f163e29a7ceb11e98fc8dfe47553df01f801e` | module (diagnostics only) |

DTB built from base + 0001: `t6050-j716s-nvram.dtb` sha256 `a62ec79fc2a932ee5f937a2b1c0d88021d5daad4d0697eab006d30c3c0367001`
(base = next-daily DTB `659af884...`); `dt/nvram.vs-base.txt` is the semantic diff.
`tests/qspi-nvram-tests.out`: the driver's host test (`tools/asahi/qspi-nvram-tests.py`, extended by 0002), 32 PASS.

Tools (Linux, root, on the MacBook): `tools/nvram-probe.sh` (read-only checks, writes the `probe.pass` marker),
`tools/nvram-next-boot.sh status|to-macos|clear-next` (refuses without the marker; arms the driver for one call; verifies the diff),
`tools/v3-nvram.py` (read-only v3 NVRAM parser; names and sizes, never values). Dumps hold the user's NVRAM values:
keep them in `/var/lib/nvram-t6050` and off any repository.
