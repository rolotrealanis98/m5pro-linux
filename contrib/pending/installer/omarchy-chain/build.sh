#!/bin/bash
# Omarchy-chain test for the J716s: stage-2 m1n1 + U-Boot, composed the way Omarchy's packages do it.
# Apple `container`, Fedora 43 (arm64, so the native gcc is the aarch64 gcc; no cross prefix needed).
#
#   m1n1    edimoldovan j714c/m1n1 (5bb6965d99b1) + 4 J716s commits = branch j716s/omarchy-chain in
#           ~/Work/agents/aurora-prs-2/m1n1 (worktree ~/Work/agents/omarchy-chain/m1n1), built with
#           m1n1-aurora's flags (EXTRA_CFLAGS=-Os RELEASE=1 CHAINLOADING=1 ESP_STAGE2=1 USE_CLANG=1, rustc 1.89.0)
#             m1n1-test.bin : + -DT6050_NO_HOST_PREP (USB left as our daily stage 2 leaves it)   <- deployed
#             m1n1-ref.bin  : exactly m1n1-aurora's flags (Ed's USB 2.0 host prep runs)         reference only
#   U-Boot  edimoldovan u-boot j714c/t6050 (70e990818a), apple_m1_defconfig
#             u-boot-omarchy : uboot-aurora's recipe (quiet-console.patch, SILENT_CONSOLE*, no logo,
#                              BOOTDELAY 0, EFI_RT_VOLATILE_STORE)                               reference only
#             u-boot-test    : apple_m1_defconfig + EFI_RT_VOLATILE_STORE, console on the panel,
#                              WATCHDOG_AUTOSTART=n (stage 1's 150 s watchdog stays the only one),
#                              -DDEBUG for nvme_apple.c and board.c (ANS hand-over lines)      <- deployed
#   boot.bin  asahi-scripts 20261023-1 update-m1n1, unmodified, LC_ALL=C (omarchy-mac-boot's default):
#             m1n1.bin | DTBs (glob order) | gzip -c u-boot-nodtb.bin | m1n1.conf chosen.* lines
#             DTBs = linux-aurora 7.2.11.aurora15's 115 + our t6050-j716s.dtb (659af884)
set -euo pipefail
W=${OMARCHY_CHAIN_WORK:-$HOME/Work/agents/omarchy-chain}   # work dir: inputs/, u-boot/, out/, private/
M1N1_REPO=$HOME/Work/agents/aurora-prs-2/m1n1   # the worktree's .git file points here
M1N1_COMMIT=772ffa5e9619d65d6bbf199b0e8b16949f4a25cd
UB_TREE=$W/u-boot                                # blobless clone, checked out at UB_COMMIT
UB_COMMIT=70e990818a895454780797beedc6a7bdac9e2fd6
OUT=$W/out; IN=$W/inputs
mkdir -p "$OUT"
[ "$(git -C "$UB_TREE" rev-parse HEAD)" = "$UB_COMMIT" ] || { echo "u-boot tree is not at $UB_COMMIT"; exit 1; }
[ -z "$(git -C "$UB_TREE" status --porcelain --untracked-files=no)" ] || { echo "u-boot tree is dirty"; exit 1; }
git -C "$M1N1_REPO" cat-file -e "$M1N1_COMMIT^{commit}"
( cd "$IN/pkgs" && shasum -a 256 -c expected.sha >/dev/null )
echo "9c3db1a504c5eeac54fadb1dadb45ac5ea36316c39fadb73836102ac4bf125f0  $IN/quiet-console.patch" | shasum -a 256 -c >/dev/null
echo "659af884741861a6edd68b364d4f9ec04d624fe761dd0163e81964dafe136e8c  $IN/dtbs/t6050-j716s.dtb" | shasum -a 256 -c >/dev/null

C=omarchychain
container rm -f $C >/dev/null 2>&1 || true
container run -d --name $C -c 8 -m 12g -v "$M1N1_REPO:/m1n1src" -v "$UB_TREE:/ubsrc" -v "$IN:/in" -v "$OUT:/out" \
    docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f $C >/dev/null 2>&1 || true' EXIT
container exec -e M1N1_COMMIT=$M1N1_COMMIT -e UB_COMMIT=$UB_COMMIT $C bash -c '
set -euo pipefail
dnf -y -q install clang lld llvm make git python3 rustup gcc bison flex bc dtc python3-pyelftools swig \
    openssl-devel openssl-devel-engine python3-devel python3-setuptools gnutls-devel libuuid-devel perl gzip diffutils which patch >/dev/null 2>&1
rustup-init -y -q --no-modify-path --default-toolchain none >/dev/null 2>&1
export PATH=$HOME/.cargo/bin:$PATH
rustup toolchain install 1.89.0 --profile minimal --target aarch64-unknown-none-softfloat >/dev/null 2>&1
export RUSTUP_TOOLCHAIN=1.89.0
git config --global --add safe.directory "*"
{ echo "m1n1:"; clang --version | head -1; ld.lld --version | head -1; rustc --version; cargo --version
  echo "u-boot:"; gcc --version | head -1; ld --version | head -1; dtc --version; python3 --version
  make --version | head -1; gzip --version | head -1
  rpm -q clang lld llvm gcc binutils dtc make gzip; } > /out/toolchain.txt

# ---------------------------------------------------------------- m1n1 (m1n1-aurora PKGBUILD flags)
rm -rf /b/m1n1 && mkdir -p /b && git clone -q /m1n1src /b/m1n1 && cd /b/m1n1 && git checkout -q $M1N1_COMMIT
git log --oneline -6 > /out/m1n1.commits
m1() { # <name> <extra cflags>
    make clean >/dev/null
    make -j8 EXTRA_CFLAGS="-Os $2" RELEASE=1 CHAINLOADING=1 ESP_STAGE2=1 USE_CLANG=1 > /out/$1.log 2>&1
    cp build/m1n1.bin /out/$1.bin
    echo "$1: $(stat -c %s build/m1n1.bin) bytes, $(grep -c "warning:" /out/$1.log) warnings" >> /out/sizes.txt
}
: > /out/sizes.txt
m1 m1n1-test "-DT6050_NO_HOST_PREP"
m1 m1n1-ref ""

# ---------------------------------------------------------------- U-Boot
ub() { # <name> <omarchy|test>
    rm -rf /b/ub && mkdir -p /b/ub && git -C /ubsrc archive $UB_COMMIT | tar -x -C /b/ub
    cd /b/ub
    if [ "$2" = omarchy ]; then
        patch -p1 -s --fuzz=0 --no-backup-if-mismatch -f < /in/quiet-console.patch
    fi
    make O=build PYTHON3=/usr/bin/python3 apple_m1_defconfig > /out/$1.log 2>&1
    if [ "$2" = omarchy ]; then
        scripts/config --file build/.config -e SILENT_CONSOLE -e SILENT_CONSOLE_UPDATE_ON_SET \
            -e SILENT_CONSOLE_UPDATE_ON_RELOC -e SILENT_CONSOLE_UNTIL_ENV -e SILENT_U_BOOT_ONLY \
            -d VIDEO_LOGO --set-val BOOTDELAY 0
        scripts/config --file build/.config -e EFI_RT_VOLATILE_STORE
        extra=""
    else
        scripts/config --file build/.config -e EFI_RT_VOLATILE_STORE -d WATCHDOG_AUTOSTART
        extra="CFLAGS_nvme_apple.o=-DDEBUG CFLAGS_board.o=-DDEBUG"
    fi
    make O=build PYTHON3=/usr/bin/python3 olddefconfig >> /out/$1.log 2>&1
    grep -qx "CONFIG_EFI_RT_VOLATILE_STORE=y" build/.config
    if [ "$2" = test ]; then grep -qx "# CONFIG_WATCHDOG_AUTOSTART is not set" build/.config; fi
    make O=build PYTHON3=/usr/bin/python3 SOURCE_DATE_EPOCH=1794009600 -j8 $extra >> /out/$1.log 2>&1
    cp build/u-boot-nodtb.bin /out/$1-nodtb.bin
    cp build/.config /out/$1.config
    echo "$1: u-boot-nodtb.bin $(stat -c %s build/u-boot-nodtb.bin) bytes, $(grep -c "warning:" /out/$1.log) warnings" >> /out/sizes.txt
}
ub u-boot-omarchy omarchy
ub u-boot-test test

# ---------------------------------------------------------------- boot.bin with update-m1n1 (asahi-scripts)
mk() { # <name> <m1n1> <u-boot>
    rm -rf /b/stage && mkdir -p /b/stage/asahi-boot /b/stage/scripts
    cp /in/update-m1n1 /in/functions.sh /b/stage/scripts/
    cp /out/$2.bin /b/stage/asahi-boot/m1n1.bin
    cp /out/$3-nodtb.bin /b/stage/asahi-boot/u-boot-nodtb.bin
    # fixed mtime: gzip -c records it, so the payload is reproducible
    touch -d "2026-11-07 00:00:00 UTC" /b/stage/asahi-boot/u-boot-nodtb.bin
    printf "%s\n" "# J716s Omarchy-chain test (update-m1n1 copies chosen.* lines)" \
        "chosen.m5pro,stage2=omarchy-chain-$1" > /b/stage/m1n1.conf
    mkdir -p /out/esp/m1n1
    LC_ALL=C SOURCE=/b/stage/asahi-boot DTBS="/in/dtbs/*.dtb" CONFIG=/b/stage/m1n1.conf \
        TARGET=/out/$1.bin sh /b/stage/scripts/update-m1n1 > /out/$1.update-m1n1.log 2>&1
    echo "$1: $(stat -c %s /out/$1.bin) bytes (update-m1n1)" >> /out/sizes.txt
}
mk boot-b1 m1n1-test u-boot-test
mk boot-ref m1n1-ref u-boot-omarchy
cat /out/toolchain.txt /out/sizes.txt
'
cd "$OUT" && shasum -a 256 m1n1-test.bin m1n1-ref.bin u-boot-test-nodtb.bin u-boot-omarchy-nodtb.bin boot-b1.bin boot-ref.bin | tee SHA256SUMS
