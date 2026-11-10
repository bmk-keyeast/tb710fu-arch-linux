#!/bin/bash
# TB710FU: mainline kernel + Arch Linux ARM/KDE Plasma rootfs + boot.img, built in WSL Ubuntu (x86_64).
#
#   build.sh deps      apt deps (sudo)
#   build.sh kernel    cross-compile kernel (LLVM=1)
#   build.sh rootfs    ALARM + Plasma via qemu chroot, modules, firmware, UCM, initramfs (sudo)
#   build.sh bootimg   out/boot.img (header v2, DTB appended), unsigned
#   build.sh image     out/tb710fu-ssd.img.xz for Rufus/balenaEtcher (sudo)
#   build.sh sign STOCK_BOOT STOCK_VBMETA   testkey AVB footer -> out/boot-signed.img (+ out/vbmeta-signed.img if needed)
#   build.sh all       deps kernel rootfs bootimg image
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(dirname "$HERE")
. "$HERE/config.env"
R="$OUT/rootfs"
log() { printf '\033[1;32m[tb710fu]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[tb710fu]\033[0m %s\n' "$*" >&2; exit 1; }
kmake() { make -C "$KSRC" ARCH=arm64 LLVM=1 -j"$(nproc)" "$@"; }
kver() { cat "$KSRC/include/config/kernel.release"; }
mkdir -p "$OUT"

deps() {
	sudo apt-get update
	sudo apt-get install -y clang lld llvm flex bison bc libssl-dev libelf-dev dwarves cpio \
		python3 qemu-user-static binfmt-support arch-install-scripts \
		libarchive-tools gdisk e2fsprogs rsync curl
}

kernel() {
	[ -f "$KSRC/Makefile" ] || die "no kernel tree at $KSRC"
	cp "$KSRC/arch/arm64/configs/sm8650_defconfig" "$KSRC/.config"
	# USB NVMe enclosures want UAS; root lives there.
	"$KSRC/scripts/config" --file "$KSRC/.config" -e USB_UAS
	kmake olddefconfig
	kmake Image.gz dtbs modules
	log "kernel $(kver) built"
}

rootfs() {
	[ -f "$KSRC/arch/arm64/boot/Image.gz" ] || die "run: build.sh kernel"
	ls /proc/sys/fs/binfmt_misc/qemu-aarch64 >/dev/null || die "qemu-aarch64 binfmt not registered"
	local tgz="$OUT/$(basename "$ALARM_URL")"
	if [ ! -s "$tgz" ]; then
		curl -fL -o "$tgz.part" "$ALARM_URL" && mv "$tgz.part" "$tgz"
	fi
	curl -fsL "$ALARM_URL.md5" | sed "s#  .*#  $tgz#" | md5sum -c - || die "ALARM tarball md5 mismatch"

	sudo umount -R "$R" 2>/dev/null || true
	# pacman's free-space check needs / to be a mountpoint inside the chroot
	if [ -n "${FRESH:-}" ] || ! ls -d "$R"/var/lib/pacman/local/plasma-desktop-* >/dev/null 2>&1; then
	sudo rm -rf "$R" && sudo mkdir -p "$R"
	sudo mount --bind "$R" "$R"
	sudo bsdtar -xpf "$tgz" -C "$R"

	log "pacman: update + Plasma (qemu, slow)"
	# pacman's download sandbox doesn't work under qemu-user
	sudo arch-chroot "$R" /bin/bash -e <<EOF
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Rdd --noconfirm linux-aarch64
for i in 1 2 3 4 5; do
	pacman -Syu --noconfirm --needed --disable-sandbox --disable-download-timeout $(echo $PACKAGES) && break
	[ \$i = 5 ] && exit 1
	echo "pacman failed, retry \$i/5"; sleep 10
done
EOF
	else
		log "reusing pacman stage in $R (FRESH=1 to redo)"
		sudo mount --bind "$R" "$R"
	fi

	log "kernel modules"
	sudo make -C "$KSRC" ARCH=arm64 LLVM=1 modules_install INSTALL_MOD_PATH="$R/usr" INSTALL_MOD_STRIP=1
	sudo rm -f "$R/usr/lib/modules/$(kver)/build" "$R/usr/lib/modules/$(kver)/source"

	log "firmware + UCM"
	local fw="$REPO/linux-firmware-tb710fu" F="$R/usr/lib/firmware" gt=qcom/sm8650/xiaoxin/gt
	sudo install -Dm644 -t "$F/$gt" "$fw/$gt"/*
	# msm requests the GMU by its generic name (qcom/gmu_gen70900.bin); only the zap has a DTS path
	sudo install -Dm644 -t "$F/updates/qcom" "$fw/$gt/gmu_gen70900.bin"
	sudo install -Dm644 -t "$F/novatek" "$fw/novatek/novatek_nt36532_fw.bin"
	sudo install -Dm644 -t "$F/awinic" "$fw/awinic/aw88461_tb710fu.bin"
	# kernel looks for qcom/<driver_name>/<card model>-tplg.bin
	sudo install -Dm644 -t "$F/qcom/sm8650" "$fw/tplg/Lenovo-TB710FU-tplg.bin"
	# device-specific WCN7850 board/BT files override linux-firmware's (updates/ is searched first)
	sudo install -Dm644 -t "$F/updates/ath12k/WCN7850/hw2.0" "$fw/ath12k/WCN7850/hw2.0/board-2.bin"
	sudo install -Dm644 -t "$F/updates/qca" "$fw/qca"/*
	sudo mkdir -p "$R/usr/share" && sudo cp -r "$fw/usr/share/qcom" "$R/usr/share/"
	local dev="$REPO/device-lenovo-tb710fu" U="$R/usr/share/alsa/ucm2"
	sudo install -Dm644 -t "$U/Lenovo/tb710fu" "$dev/HiFi.conf" "$dev/Lenovo-TB710FU.conf"
	sudo mkdir -p "$U/conf.d/sm8650"
	sudo ln -sf ../../Lenovo/tb710fu/Lenovo-TB710FU.conf "$U/conf.d/sm8650/Lenovo-TB710FU.conf"

	log "A/B slot tools"
	[ -x "$OUT/qbootctl" ] || bash "$HERE/qbootctl.sh"
	sudo install -Dm755 "$OUT/qbootctl" "$R/usr/bin/qbootctl"
	# ABL falls back to the other slot after a few boots unless the slot is marked successful
	sudo tee "$R/etc/systemd/system/qbootctl-mark-successful.service" >/dev/null <<'EOF'
[Unit]
Description=Mark the current A/B slot as successfully booted
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/qbootctl -m

[Install]
WantedBy=multi-user.target
EOF
	sudo tee "$R/usr/bin/reboot-to-android" >/dev/null <<'EOF'
#!/bin/sh
# switch to the other A/B slot (Android) and reboot
set -e
cur=$(qbootctl -c | grep -o '_[ab]' | tr -d _)
[ "$cur" = a ] && other=b || other=a
qbootctl -s "$other"
systemctl reboot
EOF
	sudo chmod 755 "$R/usr/bin/reboot-to-android"
	sudo tee "$R/usr/share/applications/reboot-to-android.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Reboot to Android
Name[ko]=Android로 재부팅
Exec=pkexec /usr/bin/reboot-to-android
Icon=system-reboot
Categories=System;
EOF

	log "initramfs fallback: no root SSD -> slot a"
	# mkinitcpio hook: wait tb710fu.wait=N seconds (default 30) for the root partition;
	# if it never shows up (SSD unplugged/dead) make slot a active and reboot into Android.
	sudo mkdir -p "$R/etc/initcpio/install" "$R/etc/initcpio/hooks"
	sudo tee "$R/etc/initcpio/install/tb710fu-fallback" >/dev/null <<'EOF'
#!/bin/bash
build() {
	add_binary qbootctl
	add_runscript
}
help() {
	echo "Fall back to A/B slot a when the root device does not appear."
}
EOF
	sudo tee "$R/etc/initcpio/hooks/tb710fu-fallback" >/dev/null <<'EOF'
#!/usr/bin/ash
run_hook() {
	local wait=30 arg uuid i=0
	for arg in $(cat /proc/cmdline); do
		case "$arg" in tb710fu.wait=*) wait="${arg#tb710fu.wait=}" ;; esac
	done
	case "$root" in PARTUUID=*) uuid="${root#PARTUUID=}" ;; *) return 0 ;; esac
	while [ ! -e "/dev/disk/by-partuuid/$uuid" ]; do
		if [ "$i" -ge "$wait" ]; then
			echo ":: tb710fu: root PARTUUID=$uuid not found after ${wait}s -> slot a"
			qbootctl -s a && sleep 3 && reboot -f
			echo ":: tb710fu: could not switch slot/reboot, continuing"
			return 0
		fi
		[ "$i" = 0 ] && echo ":: tb710fu: waiting up to ${wait}s for the root SSD"
		sleep 1
		i=$((i + 1))
	done
}
EOF
	# The SSD image only carries a small root partition (build.sh image); the disk size is
	# known only on the device, so the rest is laid out on first boot.
	printf 'ROOT_SIZE=%s\nHOME_PARTUUID=%s\n' "$ROOT_SIZE" "$HOME_PARTUUID" | sudo tee "$R/etc/tb710fu.conf" >/dev/null
	sudo tee "$R/usr/bin/tb710fu-firstboot" >/dev/null <<'EOF'
#!/bin/sh
# Grow the root partition to ROOT_SIZE and turn the rest of the disk into /home.
set -eu
. /etc/tb710fu.conf
home=/dev/disk/by-partuuid/$HOME_PARTUUID
root=$(findmnt -no SOURCE /)
disk=/dev/$(lsblk -no PKNAME "$root")
if [ ! -e "$home" ]; then
	# the image was written to a bigger disk: move the backup GPT to the real end first
	sfdisk --relocate gpt-bak-std "$disk"
	# root gets ROOT_SIZE, but at most half the disk (e.g. a 32GB stick: ~15G / ~15G),
	# and never less than it already is
	disk_mib=$(( $(blockdev --getsize64 "$disk") / 1048576 ))
	cur_mib=$(( $(blockdev --getsize64 "$root") / 1048576 ))
	want_mib=$(( $(numfmt --from=iec "$ROOT_SIZE") / 1048576 ))
	[ "$want_mib" -gt $((disk_mib / 2)) ] && want_mib=$((disk_mib / 2))
	[ "$want_mib" -lt "$cur_mib" ] && want_mib=$cur_mib
	echo ", ${want_mib}MiB" | sfdisk --no-reread --force -N 1 "$disk"
	echo "type=933AC7E1-2EB4-4F13-B844-0E14E2AEF915, uuid=$HOME_PARTUUID, name=tb710fu-home" |
		sfdisk --no-reread --force --append "$disk"
	partx -u "$disk"
	resize2fs "$root"
	udevadm settle
	mkfs.ext4 -F -L tb710fu-home "$home"
	# carry over the home directories created at build time
	mnt=$(mktemp -d)
	mount "$home" "$mnt"
	cp -a /home/. "$mnt"/
	umount "$mnt"
	rmdir "$mnt"
fi
mkdir -p /var/lib/tb710fu
touch /var/lib/tb710fu/firstboot-done
EOF
	sudo chmod 755 "$R/usr/bin/tb710fu-firstboot"
	sudo tee "$R/etc/systemd/system/tb710fu-firstboot.service" >/dev/null <<'EOF'
[Unit]
Description=TB710FU first boot: grow root, create /home
DefaultDependencies=no
ConditionPathExists=!/var/lib/tb710fu/firstboot-done
After=systemd-remount-fs.service systemd-udevd.service
Before=local-fs-pre.target home.mount
Wants=local-fs-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/tb710fu-firstboot

[Install]
WantedBy=sysinit.target
EOF

	log "system config + initramfs"
	sudo tee "$R/etc/fstab" >/dev/null <<EOF
PARTUUID=$ROOT_PARTUUID  /      ext4  rw,relatime  0 1
PARTUUID=$HOME_PARTUUID  /home  ext4  rw,relatime,nofail,x-systemd.device-timeout=60s  0 2
EOF
	# no autodetect: it would probe the build host
	sudo tee "$R/etc/mkinitcpio-tb710fu.conf" >/dev/null <<'EOF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev modconf block tb710fu-fallback filesystems fsck)
COMPRESSION="zstd"
EOF
	sudo arch-chroot "$R" /bin/bash -e <<EOF
echo "$HOSTNAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
sed -i 's/^#\(en_US.UTF-8\|ko_KR.UTF-8\)/\1/' /etc/locale.gen && locale-gen
echo LANG=ko_KR.UTF-8 > /etc/locale.conf
userdel -r alarm 2>/dev/null || true
id $USERNAME >/dev/null 2>&1 || useradd -m -G wheel,audio,video,input -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
passwd -l root
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
grep -q QT_IM_MODULE /etc/environment || printf 'GTK_IM_MODULE=fcitx\nQT_IM_MODULE=fcitx\nXMODIFIERS=@im=fcitx\n' >> /etc/environment
systemctl enable sddm NetworkManager bluetooth qbootctl-mark-successful tb710fu-firstboot
# ALARM defaults: networkd fights NetworkManager; no sshd while the test password is set
systemctl disable systemd-networkd sshd 2>/dev/null || true
# touch-only tablet: skip the SDDM greeter
mkdir -p /etc/sddm.conf.d
printf '[Autologin]\nUser=$USERNAME\nSession=plasma\n' > /etc/sddm.conf.d/autologin.conf
rm -rf /var/cache/pacman/pkg/*
# host (x86) depmod leaves modules.dep empty for these aarch64 .ko.gz
depmod $(kver)
rm -f /boot/initramfs-tb710fu.img
# non-fatal: warns about modules this kernel doesn't build; the image check below is what counts
mkinitcpio -k $(kver) -c /etc/mkinitcpio-tb710fu.conf -g /boot/initramfs-tb710fu.img || true
lsinitcpio /boot/initramfs-tb710fu.img | grep -q "usr/lib/modules/$(kver)/modules.dep"
lsinitcpio /boot/initramfs-tb710fu.img | grep -q "hooks/tb710fu-fallback"
lsinitcpio /boot/initramfs-tb710fu.img | grep -q "bin/qbootctl"
EOF
	sudo cp "$R/boot/initramfs-tb710fu.img" "$OUT/initramfs.img"
	sudo chown "$(id -u):$(id -g)" "$OUT/initramfs.img"
	sudo umount "$R"
	log "rootfs ready: $R ($(sudo du -sh "$R" | cut -f1))"
}

bootimg() {
	local dtb="$KSRC/arch/arm64/boot/dts/qcom/sm8650-lenovo-tb710fu.dtb"
	[ -f "$OUT/initramfs.img" ] || die "run: build.sh rootfs"
	# deviceinfo: append_dtb, header v2, pagesize 4096 (offsets in mkbootimg.py).
	# Ubuntu's mkbootimg package is broken (missing gki module), hence our own writer.
	cat "$KSRC/arch/arm64/boot/Image.gz" "$dtb" > "$OUT/Image.gz-dtb"
	python3 -I "$HERE/mkbootimg.py" "$OUT/boot.img" "$OUT/Image.gz-dtb" "$OUT/initramfs.img" "$dtb" "$CMDLINE"
	log "out/boot.img ($(du -h "$OUT/boot.img" | cut -f1)), cmdline: $CMDLINE"
}

image() {
	# SSD image for Rufus / balenaEtcher: GPT with only the root partition (fixed PARTUUID).
	# tb710fu-firstboot grows it to ROOT_SIZE and creates /home from the rest of the disk.
	[ -f "$R/usr/bin/tb710fu-firstboot" ] || die "run: build.sh rootfs"
	findmnt "$R" >/dev/null && die "$R is still mounted"
	local img="$OUT/tb710fu-ssd.img" fs="$OUT/root.ext4" mib
	# content + 30% + 1 GiB headroom; first boot grows it anyway
	mib=$(( $(sudo du -sm "$R" | cut -f1) * 13 / 10 + 1024 ))
	log "root filesystem ${mib} MiB from $R"
	sudo rm -f "$fs"
	sudo mkfs.ext4 -q -F -L tb710fu-root -d "$R" "$fs" "${mib}M"
	sudo chown "$(id -u):$(id -g)" "$fs"
	rm -f "$img" "$img.xz"
	truncate -s $(( mib + 2 ))M "$img"       # 1 MiB GPT/alignment in front, backup GPT behind
	sgdisk -o -n1:2048:+"${mib}M" -t1:8300 -c1:tb710fu-root -u1:"$ROOT_PARTUUID" "$img" >/dev/null
	dd if="$fs" of="$img" bs=1M seek=1 conv=notrunc,sparse status=none
	rm -f "$fs"
	sgdisk -p "$img"
	log "compressing (xz)"
	xz -T0 -6 "$img"
	log "out/tb710fu-ssd.img.xz ($(du -h "$img.xz" | cut -f1)) - write it to the SSD with Rufus or balenaEtcher"
}

sign() {
	# Dumps of the slot Linux goes to (e.g. boot_b + vbmeta_b). Signing: build/avbsign.py.
	local stock="${1:?stock boot dump}" vbmeta="${2:?stock vbmeta dump}"
	local key="$HERE/testkey_rsa4096.pem" py="python3 -I"
	[ -f "$OUT/boot.img" ] || die "run: build.sh bootimg"
	local vb_key boot_chain ri
	read -r vb_key boot_chain ri < <($py -c '
import sys; sys.path.insert(0, sys.argv[1]); import avbinfo
info = lambda p: avbinfo.parse(avbinfo.vbmeta_blob(open(p, "rb").read())[0])
v, b = info(sys.argv[2]), info(sys.argv[3])
c = [d["pubkey_sha1"] for d in v["descriptors"] if d["type"] == "chain" and d["partition"] == "boot"]
print(v["pubkey_sha1"], c[0] if c else "none", b["rollback_index"])' "$HERE" "$vbmeta" "$stock")
	[ "$vb_key" = "$TESTKEY_SHA1" ] || die "vbmeta signed by $vb_key, not the testkey: testkey path closed on this firmware"
	[ "$boot_chain" != none ] || die "vbmeta has no 'boot' chain descriptor: layout not handled"

	cp "$OUT/boot.img" "$OUT/boot-signed.img"
	$py "$HERE/avbsign.py" footer "$OUT/boot-signed.img" "$(stat -c %s "$stock")" "$ri" "$key"
	[ "$($py "$HERE/avbsign.py" verify "$OUT/boot-signed.img" "$key")" = OK ] || die "boot-signed.img verify failed"
	log "out/boot-signed.img (rollback index $ri)"

	rm -f "$OUT/vbmeta-signed.img"
	if [ "$boot_chain" = "$TESTKEY_SHA1" ]; then
		log "vbmeta already chains boot to the testkey: flash boot only"
	else
		# stock chains boot to another key (Lenovo production): point it at the testkey, re-sign
		$py "$HERE/avbsign.py" rekey "$vbmeta" "$OUT/vbmeta-signed.img" "$key" boot
		[ "$($py "$HERE/avbsign.py" verify "$OUT/vbmeta-signed.img" "$key")" = OK ] || die "vbmeta-signed.img verify failed"
		log "out/vbmeta-signed.img (boot chain $boot_chain -> testkey); flash it to the same slot's vbmeta"
	fi
}

case "${1:-}" in
deps|kernel|rootfs|bootimg|image) "$1" ;;
sign) shift; sign "$@" ;;
all) deps; kernel; rootfs; bootimg; image ;;
*) sed -n '2,10p' "$0"; exit 1 ;;
esac
