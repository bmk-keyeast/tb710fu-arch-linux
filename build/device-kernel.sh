#!/bin/bash
# Build the kernel and package boot_a on the tablet itself (Arch Linux ARM, aarch64).
# Full procedure, timings and recovery: docs/KERNEL-BUILD.md
#
#   device-kernel.sh check            prerequisites (nothing is changed)
#   device-kernel.sh deps             install the build packages (sudo)
#   device-kernel.sh fetch            Armada kernel tree at the commit pinned in kernel.yml + overlay
#   device-kernel.sh prepare          download, patch and configure only (no compile): a quick dry run
#   device-kernel.sh build            compile kernel + modules + tb710fu-kbpack, stage into $W/out
#   device-kernel.sh import TAR       use a CI kernel instead (kernel-<release>.tar.gz from kernel.yml)
#   device-kernel.sh package          out/kshim/boot_a.img from the staged kernel (AVB-verified)
#   device-kernel.sh install          modules + boot_a onto this tablet (root, CONFIRM=write-boot_a)
#   device-kernel.sh rollback DIR     put a backup made by install back (root, CONFIRM=write-boot_a)
#
# Environment: TB_WORK (work dir, default /var/tmp/tb710fu-kernel), TB_STOCK (dir with the stock
# boot_a.img, default /var/lib/tb710fu/stock), JOBS (compile jobs, default 4), KBPACK (1 = keyboard
# kernel driver in the DTB, default 1).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(dirname "$HERE")
W="${TB_WORK:-/var/tmp/tb710fu-kernel}"
STOCK="${TB_STOCK:-/var/lib/tb710fu/stock}"
JOBS="${JOBS:-4}"
KBPACK="${KBPACK:-1}"
A="$W/armada"
KB="$W/kb"
STAGE="$W/out/kernel-armada"
TOOLS="$W/kshim-tools"
BACKUPS=/var/lib/tb710fu/backup
GH_REPO=bmk-keyeast/tb710fu-arch-linux
STOCK_SHA=37bb1bc53ca26c18
BOOT=/dev/disk/by-partlabel/boot_a
SHA=$(sed -n 's/^  ARMADA_SHA: *//p' "$REPO/.github/workflows/kernel.yml")

log() { printf '\033[1;32m[device-kernel]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[device-kernel]\033[0m %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }
# compile on $JOBS cores at the lowest priority: the desktop stays usable, and the kernel's own
# nproc-based -j follows the affinity mask
slow() {
	# lowest-numbered cores first: the prime core (cpu7) runs hottest
	local cpus; cpus=$(awk '/^processor/{print $NF}' /proc/cpuinfo | sort -n | head -n "$JOBS" | paste -sd,)
	taskset -c "$cpus" nice -n 19 ionice -c 3 "$@"
}
kver() { ls "$STAGE/lib/modules" 2>/dev/null | head -1; }

check() {
	local bad=0 p
	ok() { printf '  ok    %s\n' "$*"; }
	no() { printf '  FAIL  %s\n' "$*"; bad=1; }
	[ "$(uname -m)" = aarch64 ] && ok "aarch64" || no "not aarch64: $(uname -m)"
	local free; free=$(df -BG --output=avail "$(dirname "$W")" | tail -1 | tr -dc 0-9)
	[ "$free" -ge 30 ] && ok "${free} GB free for $W" || no "need 30 GB free for $W, have ${free} GB"
	local swap; swap=$(awk '/SwapTotal/{print int($2/1048576)}' /proc/meminfo)
	[ "$swap" -ge 3 ] && ok "${swap} GB swap" || no "need 3 GB of swap: the tablet froze in a big build without it"
	for p in gcc make bc flex bison pahole cpio python3 git curl zstd xz openssl depmod fdtget fdtput cmake taskset ionice; do
		command -v "$p" >/dev/null || no "missing $p (device-kernel.sh deps)"
	done
	[ -f /usr/include/libelf.h ] && ok "libelf headers" || no "missing libelf headers (device-kernel.sh deps)"
	if [ -r "$STOCK/boot_a.img" ]; then
		[ "$(sha256sum "$STOCK/boot_a.img" | cut -c1-16)" = "$STOCK_SHA" ] && ok "stock boot_a.img" ||
			no "$STOCK/boot_a.img is not the stock image ($STOCK_SHA...)"
	else
		no "no stock image: $STOCK/boot_a.img (docs/KERNEL-BUILD.md, Prerequisites)"
	fi
	[ -n "$SHA" ] && ok "Armada pin ${SHA:0:12}" || no "no ARMADA_SHA in kernel.yml"
	[ $bad = 0 ] && log "ready" || die "fix the items above"
}

deps() {
	sudo pacman -S --needed --noconfirm base-devel bc cpio pahole python git curl dtc zstd xz openssl \
		kmod libelf perl cmake util-linux
}

fetch() {
	log "Armada kernel tree at ${SHA:0:12}"
	mkdir -p "$W"
	if [ ! -d "$A/.git" ]; then
		git init -q "$A"
		git -C "$A" remote add origin https://github.com/ArmadaOS-Freedom/armadaos-freedom.git
		git -C "$A" sparse-checkout set packages/kernel
	fi
	git -C "$A" fetch -q --depth 1 --filter=blob:none origin "$SHA"
	git -C "$A" checkout -q --force FETCH_HEAD
	git -C "$A" clean -qfdx packages/kernel/overlays
	cp -r "$REPO/kernel/armada-overlay/tb710fu-locked" "$A/packages/kernel/overlays/"
}

armada_env() { export KERNEL_OVERLAYS=tb710fu-locked WORK_DIR="$KB" OUT_DIR="$W/kout"; }

prepare() {
	[ -d "$A/.git" ] || fetch
	armada_env
	# the same script, stopped right before the first compile
	local s="$A/packages/kernel/scripts/.prepare-only.sh"
	sed '/^make "\${MAKE_ARGS\[@\]}" Image dtbs modules$/i echo "==> prepare only: stopping before the compile"; exit 0' \
		"$A/packages/kernel/scripts/build-kernel.sh" > "$s"
	grep -q 'prepare only' "$s" || die "build-kernel.sh changed: no compile line to stop at"
	bash "$s"
	rm -f "$s"
	options
	log "patches and configuration are fine: $(src).config"
}

src() { ls -d "$KB"/linux-*/ | head -1; }

options() {
	local o c; c="$(src).config"
	while read -r o; do
		case "$o" in ''|\#*) continue ;; esac
		grep -qx "CONFIG_$o" "$c" || die "missing CONFIG_$o in $c"
	done < "$REPO/kernel/required-options.txt"
}

build() {
	[ -d "$A/.git" ] || fetch
	free -g | awk '/Swap/{ if ($2 < 3) exit 1 }' || die "no swap: run device-kernel.sh check"
	armada_env
	log "compiling on $JOBS cores (1-3 hours, log: $W/build.log)"
	( cd "$A/packages/kernel" && slow bash scripts/build-kernel.sh ) 2>&1 | tee "$W/build.log"
	options
	local s; s=$(ls -d "$KB"/staging-* | head -1)
	local v=${s##*/staging-}
	log "tb710fu-kbpack for $v"
	rm -rf "$W/kbpack" && cp -r "$REPO/kernel/tb710fu-kbpack" "$W/kbpack"
	cc -O2 -Wall -Wextra -Werror -o "$W/codec-test" "$W/kbpack/codec-test.c" && "$W/codec-test"
	slow make -C "$(src)" M="$W/kbpack" modules
	make -C "$(src)" M="$W/kbpack" INSTALL_MOD_PATH="$s" INSTALL_MOD_DIR=extra/tb710fu-kbpack \
		INSTALL_MOD_STRIP=1 modules_install
	depmod -b "$s" "$v"
	rm -rf "$STAGE" && mkdir -p "$STAGE"
	cp -a "$s/lib" "$STAGE/"
	echo "device build $(date -Is), Armada ${SHA:0:12}, repo $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)" > "$STAGE/RUN"
	log "staged $v in $STAGE; next: device-kernel.sh package"
}

import() {
	local t=${1:?device-kernel.sh import kernel-RELEASE.tar.gz}
	rm -rf "$STAGE" && mkdir -p "$STAGE"
	tar -C "$STAGE" -xzf "$t"
	echo "imported $(basename "$t")" > "$STAGE/RUN"
	log "staged $(kver) from $t"
}

kshim_tools() {
	# kshim.yml's release: kShimC runtime, pack_boot.py, avbtool.py and the aarch64 packer
	[ -x "$TOOLS/MultiBootKernelPatcher" ] && return
	log "kShimC tools from the kshim-latest release"
	mkdir -p "$TOOLS"
	local f
	curl -fsSL -o "$TOOLS/SHA256SUMS" "https://github.com/$GH_REPO/releases/download/kshim-latest/SHA256SUMS"
	for f in $(awk '{print $2}' "$TOOLS/SHA256SUMS"); do
		curl -fsSL -o "$TOOLS/$f" "https://github.com/$GH_REPO/releases/download/kshim-latest/$f"
	done
	(cd "$TOOLS" && sha256sum -c --quiet SHA256SUMS) || die "kShimC tools checksum mismatch"
	chmod +x "$TOOLS/MultiBootKernelPatcher" "$TOOLS/UnpackTool"
}

package() {
	[ -n "$(kver)" ] || die "no staged kernel: device-kernel.sh build (or import)"
	[ "$(sha256sum "$STOCK/boot_a.img" | cut -c1-16)" = "$STOCK_SHA" ] || die "$STOCK/boot_a.img is not the stock image"
	kshim_tools
	export T="$W" ROOT_DEV=userdata KBPACK KSHIM_TOOLS="$TOOLS"
	# the initramfs this system already boots with: the release one is rebuilt from newer packages
	if [ ! -f "$W/out/initramfs.img" ]; then
		mkdir -p "$W/out"
		sudo cat /boot/initramfs-tb710fu.img > "$W/out/initramfs.img"
	fi
	bash "$HERE/build.sh" kshim "$STOCK"
	log "$W/out/kshim/boot_a.img: $(cut -c1-16 "$W/out/kshim/SHA256SUMS")... (kernel $(kver): $(cat "$STAGE/RUN"))"
}

consent() {
	[ "${CONFIRM:-}" = write-boot_a ] || die "this writes boot_a. Only with the user's explicit consent: CONFIRM=write-boot_a $0 $*"
	[ "$(cat /sys/class/typec/port0/data_role 2>/dev/null | grep -o '\[host\]')" = "" ] ||
		die "USB-C is in host mode: unplug it first (a reset in host mode once blocked charging and EDL)"
}

put_boot() {
	local img=$1 want
	want=$(sha256sum "$img" | cut -d' ' -f1)
	[ "$(stat -c %s "$img")" = "$(blockdev --getsize64 "$(readlink -f "$BOOT")")" ] || die "$img is not partition-sized"
	dd if="$img" of="$BOOT" bs=4M conv=fsync status=none
	sync; echo 3 > /proc/sys/vm/drop_caches
	[ "$(sha256sum "$BOOT" | cut -d' ' -f1)" = "$want" ] || die "READBACK MISMATCH on boot_a: do not reboot, write it again"
	log "boot_a written and read back: ${want:0:16}"
}

install() {
	need_root; consent install
	local img="$W/out/kshim/boot_a.img" v; v=$(kver)
	[ -f "$img" ] || die "no image: device-kernel.sh package"
	[ "$v" = "$(uname -r)" ] || log "note: staged $v, running $(uname -r)"
	python3 -I "$HERE/avbsign.py" verify "$img" "$HERE/testkey_rsa4096.pem" | grep -qx OK || die "AVB verification failed"
	local b; b="$BACKUPS/$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$b"
	log "backup in $b"
	dd if="$BOOT" of="$b/boot_a.img" bs=4M status=none
	[ -d "/usr/lib/modules/$v" ] && cp -a "/usr/lib/modules/$v" "$b/modules"
	echo "$v" > "$b/RELEASE"
	rm -rf "/usr/lib/modules/$v"
	cp -a "$STAGE/lib/modules/$v" /usr/lib/modules/
	chown -R root:root "/usr/lib/modules/$v"
	depmod -a "$v"
	put_boot "$img"
	log "done. Reboot and pick Arch Linux in the kShimC menu. Back out: CONFIRM=write-boot_a $0 rollback $b"
}

rollback() {
	need_root; consent rollback "$@"
	local b=${1:?device-kernel.sh rollback $BACKUPS/DATE} v
	[ -f "$b/boot_a.img" ] && [ -f "$b/RELEASE" ] || die "$b is not a backup made by install"
	v=$(cat "$b/RELEASE")
	put_boot "$b/boot_a.img"
	if [ -d "$b/modules" ]; then
		rm -rf "/usr/lib/modules/$v"
		cp -a "$b/modules" "/usr/lib/modules/$v"
		depmod -a "$v"
	fi
	log "restored $b. Reboot and pick Arch Linux in the kShimC menu."
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
check|deps|fetch|prepare|build|import|package|install|rollback) "$cmd" "$@" ;;
*) sed -n '2,16p' "$0" | sed 's/^# \?//'; exit 2 ;;
esac
