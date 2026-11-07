Thanks for the review. All four points are fixed in the updated branch (same four commits, reworked in place):

**1. RTKit/SART buffers left live after the training (`src/kboot.c`).** You're right: on aurora-wip, `nvme_shutdown()` leaves an M4-class ANS running with its RTKit session and SART-mapped buffers, and nothing reserves them for Linux. I stopped ANS fully instead of adding a reservation. When ANS was stopped and m1n1 started it for the training, `nvme_stop()` (`src/nvme.c:800`) now runs the M1-M3 teardown (RTKit sleep, ANS/ANS2 reset, then the RTKit buffers, SART, ASC and queues are freed). It skips the post-M4 hand-off at `src/nvme.c:701` and `src/nvme.c:753`. `ans_stop()` (`src/pcie_t6050.c:708`) then requires the ANS CPU to read as stopped. This is the behaviour the J716s boots actually tested ("nvme: shutdown done", ANS stopped again), and Linux's nvme-apple restarts a stopped ANS itself. A stopped ANS owns nothing, so no allocation of that session outlives the hand-off. `nvme_shutdown()` itself is unchanged for every other caller.

**2. Storage failures could be treated as an optional N1 failure (`src/pcie_t6050.c`).** `storage_check()` now tells the two cases apart (`src/pcie_t6050.c:355`):
- before the training, a failed check only refuses it (-1);
- after any stage, a failed check returns `N1_STORAGE_LOST` (`src/pcie_t6050.h:9`), and `TRY()` passes that code through (`src/pcie_t6050.c:156`).

`kboot_setup_n1()` sends `N1_STORAGE_LOST` to the watchdog reset (`src/kboot_n1.c:281`) whoever started ANS. That covers modes 1/2 and modes 3/4 with ANS already running. `pcie_t6050_n1_train_ans()` does the same before its own read-back checks (`src/pcie_t6050.c:749`).

**3. Mode 5 was untested.** Removed: no J813 port order, and the stage split it needed is gone. `stage_e()` takes the link-up wait as an argument (`src/pcie_t6050.c:545`): 1 s after the SMC pulse, 500 ms otherwise (`src/pcie_t6050.c:677`). The `=4` path is register for register what the J716s ran. The comments, commit messages and description now cover modes 1-4 only (`src/kboot_n1.c:24`, `src/pcie_t6050.c:18`). A J716s boot of this exact tree with `chosen.asahi,t6050-n1=4` is prepared, and I'll report the result here.

**4. A port 0 that failed stage G could still be enabled (`src/kboot_n1.c`).** Two changes:
- A port 0 training that stopped now keeps port 0 and its DART disabled even with the link up (`src/kboot_n1.c:273`, `:284`, `:322`).
- `n1_port_up()` now applies the rest of the adoption preconditions before enabling any adopted port (`src/kboot_n1.c:229`-`:257`): no RID route valid, the endpoint's I/O/memory/bus-master bits clear, and the port's DART protection and stream registers still 0. So a port trained by anyone else gets the same check.
