Thanks. Of the findings here:

- `src/pcie_t6050.c:783` (a second preparation can reboot): fixed in #34. `pcie_t6050_n1_train_ans()` now runs once per boot, like `pcie_t6050_n1_train()`. A second kboot preparation gets the first result and does not start a second ANS session. The final storage check also only runs against a reference that passed its own checks.
- `src/pcie_t6050.c:698` (storage not checked after a failed stage) and `src/smc.c:70` (SMC wait extended by notifications): N1 code from #34, fixed there.
- `src/usb.c` (registers read on unpowered ports) and `src/nvme.c:726` (the unused `nvme_t6050_stop_coproc` branch): both are in edimoldovan's #30. They show up here because the stack sits on #30 while #30 is unmerged. They belong on #30.

The GPU commit in this PR did not change.
