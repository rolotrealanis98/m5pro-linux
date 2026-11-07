/* host stub for m1n1's utils.h: no MMIO */
#pragma once
#include "types.h"
#include <stdio.h>
#define ARRAY_SIZE(s) (sizeof(s) / sizeof((s)[0]))
static inline u32 read32(u64 addr) { (void)addr; return 0x0f040300; }
static inline void mask32(u64 a, u32 c, u32 s) { (void)a; (void)c; (void)s; printf("STUB: mask32 called!\n"); }
static inline int poll32(u64 a, u32 m, u32 t, u32 to) { (void)a; (void)m; (void)t; (void)to; return 0; }
#define FIELD_PREP(m, v) (((u32)(v) << __builtin_ctz(m)) & (m))
#define FIELD_GET(m, v) (((v) & (m)) >> __builtin_ctz(m))
static inline void set32(u64 a, u32 s) { (void)a; (void)s; printf("STUB: set32 called!\n"); }
static inline void clear32(u64 a, u32 c) { (void)a; (void)c; printf("STUB: clear32 called!\n"); }
static inline void write32(u64 a, u32 v) { (void)a; (void)v; printf("STUB: write32 called!\n"); }
static inline void udelay(u32 d) { (void)d; }
