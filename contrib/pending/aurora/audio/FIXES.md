# Build fixes after the first Rust build (2026-11-06)

Worktree: `/Volumes/linux-cs/wt-aurora-audio`, branch `aurora-j716s-audio`, base `b790125548c4` (302945c1 + 0029).
Old tip `c75a3c91a327` -> new tip: see `git -C /Volumes/linux-cs/wt-aurora-audio log -1`. Tree after the fix: `60532256296e`.

## Errors in build.log (lines 2729-2743)
```
error[E0599]: no method named `dma_handle` found for reference `&Coherent<[u8]>`   aop.rs:2564
error[E0599]: no method named `dma_handle` found for struct `Coherent<T>`         aop.rs:2592
```

## Fix 1: `Coherent::dma_handle()` -> `Coherent::dma_address()` (drivers/soc/apple/aop.rs)
- Cause: Ed's `AopShmem` (from f4427365cc8f) was written against his tree's `kernel::dma::Coherent`, which had
  `dma_handle()`. This tree's `rust/kernel/dma.rs:632` names the same accessor `dma_address()` (returns `DmaAddress` =
  `dma_addr_t`); `aop.rs` already uses it elsewhere (`:626`, `:1083`).
- Change: the two calls in `impl rtkit::Buffer for AopShmem::iova()` and in `shmem_alloc()`'s debug line.
- Where: squashed into patch 0003 (`soc: apple: aop: T6050 setup port and firmware DMA window`) so every patch in the series
  builds on its own; its port note says so ("build fix after the first Rust build; Assisted-by: LLM").

## Checked, no change needed
- `sound/soc/apple/aop_audio.o` (with `aop_t8140.rs`, patches 0004-0010), `rust/kernel.o` (patch 0002's
  `new_with_placed_buffers_unacked`, Ed's `wake_early_ap`) and `drivers/dma/apple-admac.o` already compiled in this build
  without errors or warnings (build.log lines 146, 1576, 2513). There is no separate LEAP driver: the LEAP-S proxy uses
  apple-admac's `apple,t8140-admac` match.
- The two E0599s were aop.rs's only type-check errors (rustc reports all of them in one pass). Its borrow-check pass runs
  only after type-check succeeds, so it is next. I read the ported code for it: `wake()` (the `if` result bound before
  `inspect_err`), `AopShmem::buf/Drop` (copies the raw pointer out of `*self`, no move out of a `Drop` type), `shmem_map`,
  and the `setup_endpoints` / `placed_buffers` uses in probe. I found nothing that should fail.
- `CONFIG_WERROR` is not set in `kbuild/obj/.config`, so a leftover warning will not fail the build.

## Patch files
`patches/kernel-audio/0001-0011` regenerated with `git format-patch b790125548c4..HEAD`; only 0003 changed. Each set
applies in sequence on b790125548c4 (gives the worktree's tree 60532256), on 302945c1ecb3 and on 6d9f1ec652a6.
The source tree has no `.config` (stays mrproper-clean for the O= build).
