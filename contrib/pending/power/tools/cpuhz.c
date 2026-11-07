// SPDX-License-Identifier: MIT
/*
 * cpuhz [CPU] - estimate the clock of one core (omarchy-m5 tools/cpuhz.c,
 * plus pinning and integer-only output so it builds against the kernel's
 * nolibc). A chain of dependent adds retires one per cycle on Apple cores,
 * so adds per CPU-second ~= Hz. CPU time, so other load does not skew it.
 *
 * Build (static, no libc; KSRC = a kernel tree, UAPI = its
 * "make ARCH=arm64 headers_install INSTALL_HDR_PATH=$UAPI"):
 *   clang --target=aarch64-linux-gnu -O2 -static -nostdlib -nostdinc -fno-builtin \
 *     -fno-stack-protector -fuse-ld=lld -isystem $KSRC/tools/include/nolibc \
 *     -isystem $UAPI/include -isystem $(clang -print-resource-dir)/include \
 *     -o cpuhz cpuhz.c
 */
#ifndef NOLIBC
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/syscall.h>
#endif

static uint64_t now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

int main(int argc, char **argv)
{
	const uint64_t n = 500000000ull;	/* x8 adds per iteration */
	uint64_t x = 0, t0, dt, i;

	if (argc > 1) {
		int cpu = atoi(argv[1]);
		unsigned long mask[4] = { 0 };

		if (cpu < 0 || cpu >= 256) {
			printf("bad cpu %d\n", cpu);
			return 2;
		}
		mask[cpu / 64] = 1ul << (cpu % 64);
		if (syscall(__NR_sched_setaffinity, 0, sizeof(mask), mask) < 0) {
			printf("sched_setaffinity(%d) failed\n", cpu);
			return 1;
		}
	}

	t0 = now_ns();
	for (i = 0; i < n; i++)
		asm volatile("add %0, %0, #1\n\tadd %0, %0, #1\n\tadd %0, %0, #1\n\tadd %0, %0, #1\n\t"
			     "add %0, %0, #1\n\tadd %0, %0, #1\n\tadd %0, %0, #1\n\tadd %0, %0, #1"
			     : "+r"(x));
	dt = now_ns() - t0;
	/* MHz = 8n / dt[us] */
	printf("cpu %s: %llu MHz (%llu ms, x=%llu)\n", argc > 1 ? argv[1] : "any",
	       (unsigned long long)(8 * n * 1000 / dt),
	       (unsigned long long)(dt / 1000000), (unsigned long long)x);
	return 0;
}
