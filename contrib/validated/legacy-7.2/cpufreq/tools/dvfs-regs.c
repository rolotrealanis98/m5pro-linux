// SPDX-License-Identifier: MIT
/*
 * dvfs-regs - READ-ONLY dump of the T6050 cluster DVFS registers that
 * apple-soc-cpufreq uses: command (+0x20, 64-bit) and status (+0x50,
 * 32-bit) of the performance controller at 0x21Xe20000, X = cluster 0..2.
 * Both registers were already read safely on the J716s by m5pro-linux
 * scripts/probes/cluster-pstate-probe.py (as DVFS block + 0x20020/0x20050).
 * Needs root and CONFIG_DEVMEM (IO_STRICT_DEVMEM off, as in omarchy configs).
 *
 * Build: see cpuhz.c (static, nolibc; add -fno-builtin).
 */
#ifndef NOLIBC
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
#endif

static const char *const names[3] = { "M0 (cpu0-5)", "M1 (cpu6-11)", "P (cpu12-17)" };

int main(void)
{
	int fd = open("/dev/mem", O_RDONLY | O_SYNC);
	int cl;

	if (fd < 0) {
		printf("open /dev/mem failed (root? CONFIG_DEVMEM?)\n");
		return 1;
	}
	for (cl = 0; cl < 3; cl++) {
		uint64_t base = 0x210e20000ull + 0x1000000ull * cl;
		volatile uint8_t *m = mmap(0, 0x1000, PROT_READ, MAP_SHARED, fd, base);
		uint64_t cmd;
		uint32_t st;

		if (m == MAP_FAILED) {
			printf("cluster %d: mmap %llx failed\n", cl, (unsigned long long)base);
			continue;
		}
		cmd = *(volatile uint64_t *)(m + 0x20);
		st = *(volatile uint32_t *)(m + 0x50);
		printf("cluster %d %-13s @%llx: cmd %#llx (req p%llu, busy %llu, apsc_dis(b23) %llu, b22 %llu) "
		       "status %#x (cur p%u, tgt p%u)\n",
		       cl, names[cl], (unsigned long long)base, (unsigned long long)cmd,
		       (unsigned long long)(cmd & 0x1f), (unsigned long long)((cmd >> 31) & 1),
		       (unsigned long long)((cmd >> 23) & 1), (unsigned long long)((cmd >> 22) & 1),
		       st, (st >> 5) & 0x1f, st & 0x1f);
		munmap((void *)m, 0x1000);
	}
	close(fd);
	return 0;
}
