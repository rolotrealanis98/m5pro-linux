# ane-2: first H17 compute test on the J716s ANE, 2026-11-23

No new boot. Needs the running test kernel 7.3.0-g0c6bb36ed14a (branch j716s-ane2293) with the ANE up
(`/dev/accel/accel0`, ABI 3). No kernel change, no reboot, no module load. Root needed only for /dev/accel and dmesg.
Everything lives in `/root/ane-2`; the script creates `results/` there and deletes nothing, mounts nothing.

## What was built (Studio, 2026-11-23)

- Compiler: `aurora-silicon/mil-hwx-compiler` main @ 36feecaa7476, built with `make build/mil-hwxc` on macOS (no container needed). Clone and build: `/Volumes/m5pro/bench/ane-2/mil-hwx-compiler`.
- Programs (`--target H17`, MIL in `hwx/*.mil`, each from a decoded oracle point of the compiler, encoder `h17-oracle-parity`; byte parity with Apple's output only, NEVER run on a device before):
  add128, mul128, sub128 (fp16 [1,128,1,1] x,z -> y; y = x op z), relu64 and relu512 (fp16 [1,C,1,1]).
- Surface layout (from the HWX tensor descriptor, strides 8192/64/64/2): channel c at byte c*64 (fp16 index c*32), 31 padding lanes per
  channel; surfaces are 16384 B (relu512: 32768 B). Inputs have 0 in padding; expected files have 0xffff there, which ane-run skips.
- Expected outputs: fp16 exact (double add/sub/mul, one rounding), cross-checked against an independent Fraction round-to-nearest-even oracle: 0 mismatches. Gating cases avoid overflow, subnormals and exact zero results (hardware corners). `edge` cases (zeros, subnormals, overflow, inf) are informational only.
- Runner: `ane-run-all.py` is ane-run.py from the worktree (`tools/testing/selftests/drivers/ane/`, unchanged logic) with one change: with an expected file it compares EVERY run (stock compares only the first and last) and prints "N/M runs bit-exact". `h16-sections.py` is the stock file. ane-run's check of H17: `PROLOGUE` has subtype 9 and `CHIPS=(16,17)`; the four LOAD sections build offline for all five HWX (buffer IDs input0=5 [x], output0=4, input1=6 [z]; BAR refs slot 6->5, 7->4, 8->6; 1 task). Not yet run against the device.

## Files to copy to the Mac

One tar: `/Volumes/m5pro/bench/ane-2/ane-2-files.tar` sha256 `0a28fcee96434a748db728f255a07d534e0176eaa23a94ff4caf107c258e961c` (76 entries). Per-file sums: `/Volumes/m5pro/bench/ane-2/SHA256SUMS` (path relative to the tar root):

- `c70620e37fc3e926320557d72e1e61621e3f77a777343d9a311f22fc2a50b3de`  ane-run-all.py
- `7edb3cd1fb61d2d33bdb36f47a6a4dcc1a00e947d8542790508ec5e395a1d381`  h16-sections.py
- `0807e94f436b81c8b8bfe15ec4cd3c9092fac7f7d082f88c1330c77823c47e64`  hwx/add128.mil
- `3a12e0790bd4dadbc6b53a13cb9dcf31a670dce7f82b7cb8d39512982de60d46`  hwx/h17-add128.hwx
- `3420078bb0113504dd63cdb31f3f8971ee0fa8077f957b382da56e9440879673`  hwx/h17-mul128.hwx
- `815682c4126d89d448d2e4bb7bdfcdb41346c430652418b386c0cff6f61781f0`  hwx/h17-relu512.hwx
- `e5bec009af1ab8309d200fc2ea44c9f7002a9966a3d911b0494a559068e52617`  hwx/h17-relu64.hwx
- `749943031222a979b42557ada5978b10e5baa9a7156001abb217a0ad673f0ff0`  hwx/h17-sub128.hwx
- `7aa0fcf97112fcc028c065de16f67eed8296aef641ea7604714fa162b9bfbfca`  hwx/mul128.mil
- `2dcb1d3cd1a921794cb26d9d7fa3aa74025163e003b656108643431ad0b89a2f`  hwx/relu512.mil
- `fb1bbbec34b7171226481f34b33c0e28c259efdd5f034d76e08ac1e122968a71`  hwx/relu64.mil
- `8ec28e838cc0692f28c6e5aa0bdb0586b10247911960b1f8db1a9dd69f597f59`  hwx/sub128.mil
- `8b912f5297f0a66138ae49512bf9a6ff46d7d31dbb7f26a586e3609c407e2788`  run-h17.sh
- (cases/*/*.bin: 59 files, sums in SHA256SUMS)

## Commands (as root on the J716s, non-interactive)

```
mkdir -p /root/ane-2
cp <wherever-you-put-it>/ane-2-files.tar /root/ane-2.tar
sha256sum /root/ane-2.tar            # must equal the tar sha above
tar -xf /root/ane-2.tar -C /root/ane-2
timeout 20 ls -l /dev/accel/
timeout 10 dmesg | grep -iE 'H17 ANE|accel0|Initialized ane' | tail -8
timeout 900 /root/ane-2/run-h17.sh /root/ane-2
echo rc=$?
```

\`run-h17.sh\` does, in order, with \`timeout 120\` per program: add128 (4 cases: ramp, rand_small, rand_wide, near_cancel), mul128 (3), sub128 (4),
relu64 (2), relu512 (2), each case x 1000 runs, \`--max-ulp 0\`; stops at the first failing program (a failure could mean a wedged engine).
Then three informational edge runs, then the dmesg check (lines after a \`ane-2 start\` marker written to /dev/kmsg).
Smoke only, quicker: \`cd /root/ane-2 && timeout 60 python3 -B ane-run-all.py --hwx hwx/h17-add128.hwx --case cases/add128/ramp.x.bin,cases/add128/ramp.z.bin:cases/add128/ramp.expected.bin --runs 1000 --max-ulp 0\`

Copy back to the Studio: \`/root/ane-2/results/\` (run log + dmesg-after.txt) into \`/Volumes/m5pro/bench/ane-2/results/\`.

## Pass / fail

- PASS (add128, the gate): for every case "1000/1000 runs bit-exact, max 0 ulp over all runs" and the final line \`ANE-2 RESULT: PASS\` (exit 0).
  mul128, sub128, relu64, relu512 are the same criterion; a failure there with add128 passing is a program/layout finding, not a driver failure.
- dmesg: zero lines after the marker matching error|fail|timeout|hang|recover|reset|fault|SError|oops|BUG|WARN. The script counts them (\`dmesg error/recovery lines\`);
  any nonzero count makes the result FAIL: read results/dmesg-after.txt (a benign line is possible, say so).
- Failure signatures worth reporting verbatim: \`H16_LOAD: <errno>\` (load rejected: sections or HWX), \`H16_EXEC: <errno>\` (engine/IPC), mismatches
  (is the output all 0xff? = not written; a wrong-but-nonzero pattern = layout or semantics), a hang (the 120 s timeout kills the process; check dmesg for recovery
  and \`ls /dev/accel\` afterwards).
- Edge cases (informational): report the exact counts; differences from IEEE on subnormals or overflow are expected hardware behaviour, not failures.

## Safety

- Compute only: no audio, no display, no sleep, no network, no reboot. ioctl on /dev/accel/accel0 only. No bind mounts, no \`rm\`. The only writes are \`/root/ane-2/*\` and one line to /dev/kmsg.
- First H17 program ever executed by this driver: the earlier \`add-128 1000/1000\` in ane-1.md was H16G on other machines. If \`H16_LOAD\` fails on the very first program, stop and send the output.
