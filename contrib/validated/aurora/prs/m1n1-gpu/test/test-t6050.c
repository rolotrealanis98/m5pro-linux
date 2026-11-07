/* Host test: run dt_set_gpu_t6050() (pr/t6050-gpu-handoff) against the J716s ADT and a J716s DTB. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "adt.h"
#include "xnuboot.h"
#include "utils.h"
#include "libfdt/libfdt.h"


void *adt;
struct boot_args cur_boot_args;

#include "t6050-extract.inc"

static void *slurp(const char *p, size_t *len)
{
    FILE *f = fopen(p, "rb"); if (!f) { perror(p); exit(1); }
    fseek(f, 0, SEEK_END); *len = ftell(f); fseek(f, 0, SEEK_SET);
    void *b = malloc(*len + 0x40000); if (fread(b, 1, *len, f) != *len) exit(1); fclose(f); return b;
}

#define GPU "/soc@2300000000/gpu@2300000000"
#define PMGR "/soc@2300000000/power-management@2300e80000"
#define MB0 "/soc@2300000000/mailbox@2302600000"
#define MB1 "/soc@2300000000/mailbox@2302e00000"

static void show(void *dt, const char *path)
{
    int n = fdt_path_offset(dt, path);
    if (n < 0) { printf("  %s: missing\n", path); return; }
    int len; const char *st = fdt_getprop(dt, n, "status", NULL);
    const fdt32_t *reg = fdt_getprop(dt, n, "reg", &len);
    printf("  %-40s status=%-8s reg=", path, st ? st : "(none)");
    for (int i = 0; reg && i < len / 4; i++) printf("%08x ", fdt32_ld(&reg[i]));
    printf("\n");
}

static void okay(void *dt, const char *p) { fdt_setprop_string(dt, fdt_path_offset(dt, p), "status", "okay"); }

int main(int argc, char **argv)
{
    size_t alen, dlen;
    adt = slurp(argv[1], &alen);
    cur_boot_args.devtree_size = alen;
    cur_boot_args.phys_base = 0x10003b64000;   /* boot-arch-1.log */
    cur_boot_args.mem_size = 0xbc4e94000;
    const char *mode = argv[3];
    void *in = slurp(argv[2], &dlen);
    void *dt = malloc(dlen + 0x40000);
    if (fdt_open_into(in, dt, dlen + 0x40000)) { printf("fdt_open_into failed\n"); return 1; }
    if (strcmp(mode, "asis")) { okay(dt, GPU); okay(dt, PMGR); }
    if (!strcmp(mode, "bad-sgx")) {
        fdt64_t r[2]; fdt64_st(&r[0], 0x2300004000ULL); fdt64_st(&r[1], 0x3fd8000);
        fdt_setprop(dt, fdt_path_offset(dt, GPU), "reg", r, sizeof(r));
    }
    if (!strcmp(mode, "bad-role")) fdt_setprop_string(dt, fdt_path_offset(dt, MB1), "apple,firmware-role", "GFX");
    if (!strcmp(mode, "bad-irq")) {
        const fdt32_t *p = fdt_getprop(dt, fdt_path_offset(dt, MB0), "interrupts", NULL);
        fdt32_t v[8]; memcpy(v, p, sizeof(v)); v[6] = cpu_to_fdt32(2801);
        fdt_setprop(dt, fdt_path_offset(dt, MB0), "interrupts", v, sizeof(v));
    }
    if (!strcmp(mode, "one-mbox")) {
        const fdt32_t *p = fdt_getprop(dt, fdt_path_offset(dt, GPU), "mboxes", NULL);
        fdt32_t v = p[0]; fdt_setprop(dt, fdt_path_offset(dt, GPU), "mboxes", &v, 4);
    }
    int ret = dt_set_gpu_t6050(dt);
    printf("dt_set_gpu_t6050 -> %d\n", ret);
    const char *paths[] = {"/reserved-memory/uat-ttbs", "/reserved-memory/uat-pagetables",
        "/reserved-memory/uat-handoff", "/reserved-memory/uat-l2-pagetables",
        "/reserved-memory/gpu-fw-text", "/reserved-memory/gpu-fw-data", MB0, MB1, GPU, PMGR};
    for (unsigned i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) show(dt, paths[i]);
    if (argc > 4) { fdt_pack(dt); FILE *f = fopen(argv[4], "wb"); fwrite(dt, 1, fdt_totalsize(dt), f); fclose(f); }
    return 0;
}
