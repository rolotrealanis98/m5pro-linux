Thanks. Of the two findings:

- `src/usb.c` (gadget buffers kept after `usb_t6050_host_prep()`): that code is in edimoldovan's #30 (`usb: T6050 leaves the free ports in USB 2.0 host mode for the next stage`). It shows up here only because this PR is stacked on #30 while #30 is unmerged. It belongs on #30.
- `tests/python/test_universal_boot.py`: fixed. The harness now runs the cases #30 adds. With `boot_spec` set, and again with an appended kernel, a configured stage 1 target adds neither a chainload target nor its ESP hint, and a `chainload=` line is kept rather than refused. T6050 joins the configured-target chip list. The change is folded into `tests: build the T6050 paths that #30 adds`.
