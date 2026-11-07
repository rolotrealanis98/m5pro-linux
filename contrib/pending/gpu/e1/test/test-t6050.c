/* Host test: run dt_set_gpu_t6050() (m1n1 0026) against the J716s ADT and the built DTB. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "adt.h"
#include "pmgr.h"
#include "xnuboot.h"
#include "utils.h"
#include "libfdt/libfdt.h"

void *adt;
struct boot_args cur_boot_args;
static const char *chosen_val;
const char *kboot_get_chosen(const char *n) { return strcmp(n, "m5pro,gpu") ? NULL : chosen_val; }

#include "t6050-extract.inc"

static void *slurp(const char *p, size_t *len)
{
    FILE *f = fopen(p, "rb"); if (!f) { perror(p); exit(1); }
    fseek(f, 0, SEEK_END); *len = ftell(f); fseek(f, 0, SEEK_SET);
    void *b = malloc(*len + 0x40000); fread(b, 1, *len, f); fclose(f); return b;
}

static void show(void *dt, const char *path)
{
    int n = fdt_path_offset(dt, path);
    if (n < 0) { printf("  %s: missing\n", path); return; }
    int len; const char *st = fdt_getprop(dt, n, "status", NULL);
    const fdt32_t *reg = fdt_getprop(dt, n, "reg", &len);
    printf("  %-48s status=%-8s reg=", path, st ? st : "(none)");
    for (int i = 0; reg && i < len / 4; i++) printf("%08x ", fdt32_ld(&reg[i]));
    printf("\n");
}

int main(int argc, char **argv)
{
    size_t alen, dlen;
    adt = slurp(argv[1], &alen);
    cur_boot_args.devtree_size = alen;
    cur_boot_args.phys_base = 0x10003b64000;   /* boot-arch-1.log */
    cur_boot_args.mem_size = 0xbc4e94000;
    chosen_val = argc > 3 ? argv[3] : NULL;
    void *in = slurp(argv[2], &dlen);
    void *dt = malloc(dlen + 0x40000);
    if (fdt_open_into(in, dt, dlen + 0x40000)) { printf("fdt_open_into failed\n"); return 1; }
    if (pmgr_init()) printf("pmgr_init failed\n");
    printf("pmgr_psreg_by_name(GFX) = 0x%lx\n", (unsigned long)pmgr_psreg_by_name(0, "GFX"));
    int ret = dt_set_gpu_t6050(dt);
    printf("dt_set_gpu_t6050 -> %d\n", ret);
    const char *paths[] = {"/reserved-memory/uat-ttbs", "/reserved-memory/uat-pagetables",
        "/reserved-memory/uat-handoff", "/reserved-memory/uat-l2-pagetables",
        "/reserved-memory/gpu-fw-text", "/reserved-memory/gpu-fw-data",
        "/soc@2300000000/mailbox@2302600000", "/soc@2300000000/mailbox@2302e00000",
        "/soc@2300000000/gpu@2300000000", "/soc@2300000000/power-management@2300e80000"};
    for (unsigned i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) show(dt, paths[i]);
    if (argc > 4) { fdt_pack(dt); FILE *f = fopen(argv[4], "wb"); fwrite(dt, 1, fdt_totalsize(dt), f); fclose(f); }
    return 0;
}
