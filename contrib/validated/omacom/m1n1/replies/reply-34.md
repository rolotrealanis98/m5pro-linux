Thanks. Of the findings here:

- `src/kboot_n1.c:108` (N1 settings overwritten): fixed. `n1_set_control()` now fills `firmware-name` and `apple,centauri-platform-id` only when the DT leaves them unset, as it already did for `apple,centauri-protocol`. The log line says when a DT value was kept.
- `src/pcie_t6050.c:698` (storage not checked after a failed stage): fixed. Once a valid storage reference exists, a training that stops anywhere, including partway through stage A or S, compares storage again ("after the stop"). A change now ends in the same watchdog reset as a change after a completed stage, in every mode.
- `src/usb.c` (gadget buffers and DART mappings left after host prep): that code is in edimoldovan's #30. It shows up here because this stack sits on #30 while #30 is unmerged. It belongs on #30.

Both fixes are folded into the commits that introduced the code; the branch is force-updated.
