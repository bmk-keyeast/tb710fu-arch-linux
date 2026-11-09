#!/bin/bash
# Cross-build qbootctl (A/B slot switching, linux-msm) for aarch64 against out/rootfs's glibc.
# Not packaged in ALARM. Output: out/qbootctl (build.sh rootfs installs it to /usr/bin).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
. "$HERE/config.env"
R="$OUT/rootfs" SRC="$OUT/src/qbootctl"
QBOOTCTL_REV="${QBOOTCTL_REV:-39a6e6d}"
[ -f "$R/usr/lib/crt1.o" ] || { echo "no aarch64 glibc in $R, run build.sh rootfs first"; exit 1; }
[ -d "$SRC/.git" ] || git clone -q https://github.com/linux-msm/qbootctl.git "$SRC"
git -C "$SRC" checkout -q "$QBOOTCTL_REV"
# no gcc in the rootfs -> no crtbegin/libgcc.a; plain C needs only glibc's crt files
clang --target=aarch64-linux-gnu --sysroot="$R" -fuse-ld=lld -O2 -std=gnu11 -nostartfiles -nodefaultlibs -mno-outline-atomics \
	-I"$SRC" "$R/usr/lib/crt1.o" "$R/usr/lib/crti.o" \
	"$SRC"/{qbootctl,bootctrl_impl,gpt-utils,ufs-bsg,crc32}.c \
	-lc "$R/usr/lib/crtn.o" -o "$OUT/qbootctl"
file "$OUT/qbootctl" 2>/dev/null || ls -l "$OUT/qbootctl"
echo "qbootctl @ $(git -C "$SRC" rev-parse --short HEAD) -> $OUT/qbootctl"
