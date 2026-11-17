# SPDX-License-Identifier: MIT
# m5pro-1p-seal: sep-seal.c/.h are vendored from aurora-silicon/aurora-sep-userspace
# luks/ at a227a350d7ba (MIT), unchanged.
CC ?= cc
PKG_CONFIG ?= pkg-config
CFLAGS ?= -O2 -g
CFLAGS += -std=gnu11 -Wall -Wextra -Werror=implicit-function-declaration \
	-D_FORTIFY_SOURCE=2 -fstack-protector-strong
DEPS_CFLAGS := $(shell $(PKG_CONFIG) --cflags json-c)
DEPS_LIBS := $(shell $(PKG_CONFIG) --libs json-c)

m5pro-1p-seal: m5pro-1p-seal.c sep-seal.c sep-seal.h
	$(CC) $(CFLAGS) $(DEPS_CFLAGS) -fPIE -pie -Wl,-z,relro,-z,now -o $@ \
		m5pro-1p-seal.c sep-seal.c $(LDFLAGS) $(DEPS_LIBS)

clean:
	rm -f m5pro-1p-seal

.PHONY: clean
