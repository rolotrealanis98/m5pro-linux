Thanks. Of the findings here:

- `src/usb.c` (registers read on a port that failed to power): that code is in edimoldovan's #30. It shows up in this diff because the stack sits on #30 while #30 is unmerged. It belongs on #30.
- `src/pcie_t6050.c:698` (storage not checked after a failed stage) and `src/smc.c:70` (notifications restart the SMC timeout) are N1 code from #34. Both are fixed there:
  - A training that stops partway now compares storage again before boot continues.
  - Each SMC command, and the SMC initialisation, has one 2 s deadline from the moment it is sent. Notifications no longer extend it.

None of the display commits in this PR changed.
