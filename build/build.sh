#!/bin/bash
# TB710FU: mainline kernel + Arch Linux ARM/KDE Plasma rootfs + boot.img, built in WSL Ubuntu (x86_64).
#
#   build.sh deps      apt deps (sudo)
#   build.sh kernel    KERNEL_SRC=armada: fetch the CI kernel (.github/workflows/kernel.yml);
#                      KERNEL_SRC=spendy: cross-compile $KSRC (LLVM=1). Both stage into $KDIR
#   build.sh rootfs    ALARM + Plasma via qemu chroot, modules, firmware, UCM, initramfs (sudo)
#   build.sh bootimg   out/boot.img (header v2, DTB appended), unsigned
#   build.sh image     out/tb710fu-ssd.img.xz for Rufus/balenaEtcher (sudo)
#   build.sh personalize  CI rootfs (rootfs.yml) + local-overlay + DSP libs -> out/tb710fu-ssd.img (sudo)
#   build.sh v4 e1|e1big|e2|e2b|e3 [STOCK_DIR]   locked-bootloader GKI v4 slot-b payload -> out/v4/<mode>/
#   build.sh kshim [STOCK_DIR]   kShimC menu boot_a (stock Android + this Linux) -> out/kshim/boot_a.img
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
# every kernel is staged the same way: $KDIR/lib/modules/<release>/{vmlinuz,dtb/qcom/*.dtb,kernel/..}
KDIR="$OUT/kernel-$KERNEL_SRC"
case "$KERNEL_SRC" in
armada) DTB_NAME=sm8650-lenovo-tb710fu-locked.dtb ;;
spendy) DTB_NAME=sm8650-lenovo-tb710fu.dtb ;;
*) printf 'KERNEL_SRC must be armada or spendy\n' >&2; exit 1 ;;
esac
kver() { ls "$KDIR/lib/modules" 2>/dev/null | head -1; }
kmod() { echo "$KDIR/lib/modules/$(kver)"; }
kimage() { echo "$(kmod)/vmlinuz"; }
kdtb() { echo "$(kmod)/dtb/qcom/$DTB_NAME"; }
mkdir -p "$OUT"

deps() {
	sudo apt-get update
	sudo apt-get install -y clang lld llvm flex bison bc libssl-dev libelf-dev dwarves cpio \
		python3 qemu-user-static binfmt-support arch-install-scripts \
		libarchive-tools gdisk e2fsprogs btrfs-progs rsync curl device-tree-compiler
}

kernel() {
	"kernel_$KERNEL_SRC"
	[ -f "$(kimage)" ] && [ -f "$(kdtb)" ] || die "kernel staging incomplete in $KDIR"
	log "kernel $(kver) staged in $KDIR"
}

kernel_armada() {
	# latest successful .github/workflows/kernel.yml run on main (RUN=<id> picks another);
	# gh.exe from Windows works too, it just needs a Windows path to download to
	local gh dl run f
	gh=$(command -v gh || command -v gh.exe) || die "gh (GitHub CLI) not found"
	run=${RUN:-$("$gh" run list -R "$GH_REPO" -w kernel.yml -b main -s success -L 1 --json databaseId -q '.[0].databaseId')}
	[ -n "$run" ] || die "no successful kernel.yml run in $GH_REPO yet"
	dl="$REPO/out/kernel-download" && rm -rf "$dl" && mkdir -p "$dl"
	"$gh" run download "$run" -R "$GH_REPO" -n kernel-tb710fu -D "$(wslpath -w "$dl" 2>/dev/null || echo "$dl")"
	(cd "$dl" && sha256sum -c kernel-tb710fu.sha256) || die "kernel artifact checksum mismatch"
	rm -rf "$KDIR" && mkdir -p "$KDIR"
	for f in "$dl"/kernel-*.tar.gz; do tar -C "$KDIR" -xzf "$f"; done
	[ -f "$dl/rootfs-extra.tar.gz" ] && cp "$dl/rootfs-extra.tar.gz" "$KDIR/"
	echo "$run" > "$KDIR/RUN"
	rm -rf "$dl"
}

kernel_spendy() {
	[ -f "$KSRC/Makefile" ] || die "no kernel tree at $KSRC"
	local p
	for p in "$HERE"/patches/kernel-*.patch; do
		git -C "$KSRC" apply --reverse --check "$p" 2>/dev/null || git -C "$KSRC" apply "$p"
	done
	cp "$KSRC/arch/arm64/configs/sm8650_defconfig" "$KSRC/.config"
	# USB NVMe enclosures want UAS; root lives there.
	# BOOT_CONFIG: ABL appends a bootconfig blob after the ramdisk (vendor_boot v4); the kernel must strip it.
	# REGULATOR_USERSPACE_CONSUMER: Keyboard Pack pogo power (keyboard-vdd), switched by tb710fu-keyboard
	# UNICODE, F2FS_FS_COMPRESSION/LZ4/ZSTD, FS_VERITY: features Android's make_f2fs puts on userdata
	# (casefold, compression, verity) - without them Linux can't mount /data (ROOT_DEV=userdata).
	# F2FS_FS_SECURITY: security.* xattrs (file capabilities) for a Linux root stored on f2fs
	"$KSRC/scripts/config" --file "$KSRC/.config" -e USB_UAS -e BOOT_CONFIG -e REGULATOR_USERSPACE_CONSUMER 		-e UNICODE -e F2FS_FS_SECURITY -e F2FS_FS_COMPRESSION -e F2FS_FS_LZ4 -e F2FS_FS_ZSTD -e FS_VERITY
	kmake olddefconfig
	kmake Image dtbs modules
	local rel
	rel=$(cat "$KSRC/include/config/kernel.release")
	rm -rf "$KDIR" && mkdir -p "$KDIR"
	kmake modules_install INSTALL_MOD_PATH="$KDIR" INSTALL_MOD_STRIP=1
	rm -f "$KDIR/lib/modules/$rel/build" "$KDIR/lib/modules/$rel/source"
	install -Dm644 "$KSRC/arch/arm64/boot/Image" "$KDIR/lib/modules/$rel/vmlinuz"
	install -Dm644 -t "$KDIR/lib/modules/$rel/dtb/qcom" "$KSRC/arch/arm64/boot/dts/qcom/$DTB_NAME"
}

rootfs() {
	[ -f "$(kimage)" ] || die "run: build.sh kernel"
	# x86 (WSL) runs the aarch64 chroot through qemu; .github/workflows/rootfs.yml runs natively
	[ "$(uname -m)" = aarch64 ] || ls /proc/sys/fs/binfmt_misc/qemu-aarch64 >/dev/null ||
		die "qemu-aarch64 binfmt not registered"
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

	sudo arch-chroot "$R" /bin/bash -e <<EOF
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Rdd --noconfirm linux-aarch64
EOF
	else
		log "reusing pacman stage in $R (FRESH=1 to redo)"
		sudo mount --bind "$R" "$R"
	fi
	# / must be 0755 (a 0700 root locks every non-root user and service out, and build.sh image
	# runs its checks as the build user); the stage directory came out 0700 on 2026-11-15
	sudo chmod 755 "$R"
	# every run, so PACKAGES added later reach a reused stage too (a no-op when up to date)
	log "pacman: update + Plasma (qemu, slow)"
	# pacman's download sandbox doesn't work under qemu-user
	sudo arch-chroot "$R" /bin/bash -e <<EOF
for i in 1 2 3 4 5; do
	pacman -Syu --noconfirm --needed --disable-sandbox --disable-download-timeout $(echo $PACKAGES) && break
	[ \$i = 5 ] && exit 1
	echo "pacman failed, retry \$i/5"; sleep 10
done
EOF

	log "kernel modules"
	# only this kernel's modules (the release string changes with every tree change, e.g. -dirty)
	sudo rm -rf "$R/usr/lib/modules" && sudo mkdir -p "$R/usr/lib/modules"
	sudo cp -a "$(kmod)" "$R/usr/lib/modules/"
	sudo chown -R 0:0 "$R/usr/lib/modules"

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
	# hexagonrpcd root for the ADSP sensor PD, at the path it derives from the DT
	# (/usr/share/qcom/<qcom,soc>/<model's first word>/<board compatible>) in its own layout;
	# configs/registry/socinfo from SpendyYT's dump, DSP libs from the stock dsp partition
	local s="$fw/usr/share/qcom/sm8650/Lenovo/TB710FU" q="$R/usr/share/qcom/sm8650/Lenovo/tb710fu"
	sudo rm -rf "$R/usr/share/qcom" && sudo mkdir -p "$q/sensors" "$q/dsp"
	sudo cp -r "$s/config" "$s/registry" "$q/sensors/"
	sudo cp "$s/vendor/etc/sensors/sns_reg_config" "$q/sensors/sns_reg.conf"
	sudo cp -r "$s/socinfo" "$q/"
	if [ -r "$DSPSO" ]; then
		dsp_libs "$R"
	else
		# CI has no ROM: build.sh personalize adds them to the image
		log "DSP libs skipped (no DSPSO $DSPSO): build.sh personalize adds them"
	fi
	sudo chmod -R a+rX "$R/usr/share/qcom"
	if [ -f "$KDIR/rootfs-extra.tar.gz" ]; then
		# ArmadaOS' TB710FU files that go with its kernel: aw882xx amp parameters, NT36532 touch
		# MP data, speaker topology, ALSA UCM, WirePlumber speaker setup (kernel.yml packs them)
		sudo tar -C "$R" -xzf "$KDIR/rootfs-extra.tar.gz" --no-same-owner
	else
		local dev="$REPO/device-lenovo-tb710fu" U="$R/usr/share/alsa/ucm2"
		sudo install -Dm644 -t "$U/Lenovo/tb710fu" "$dev/HiFi.conf" "$dev/Lenovo-TB710FU.conf"
		sudo mkdir -p "$U/conf.d/sm8650"
		sudo ln -sf ../../Lenovo/tb710fu/Lenovo-TB710FU.conf "$U/conf.d/sm8650/Lenovo-TB710FU.conf"
	fi

	# rebuilt only when the script (pinned commits) changed
	local stamp="$R/var/lib/tb710fu/build-sensors.sha256"
	# (not `sudo cmp <(...)`: sudo closes the process-substitution fd, so that always differed)
	if [ "$(sudo cat "$stamp" 2>/dev/null)" != "$(sha256sum < "$HERE/rootfs-files/build-sensors.sh")" ]; then
		log "sensors: hexagonrpcd + libssc + iio-sensor-proxy (qemu build)"
		sudo install -Dm755 "$HERE/rootfs-files/build-sensors.sh" "$R/usr/local/sbin/tb710fu-build-sensors"
		sudo arch-chroot "$R" /usr/local/sbin/tb710fu-build-sensors
		sha256sum < "$HERE/rootfs-files/build-sensors.sh" | sudo install -Dm644 /dev/stdin "$stamp"
	fi

	log "Keyboard Pack: UART -> uinput daemon"
	python3 -I "$HERE/rootfs-files/tb710fu-keyboard" --selftest
	sudo install -Dm755 "$HERE/rootfs-files/tb710fu-keyboard" "$R/usr/bin/tb710fu-keyboard"
	echo uinput | sudo tee "$R/etc/modules-load.d/uinput.conf" >/dev/null
	sudo tee "$R/etc/systemd/system/tb710fu-keyboard.service" >/dev/null <<'EOF'
[Unit]
Description=Lenovo Keyboard Pack (pogo UART) input
After=systemd-modules-load.service systemd-udev-settle.service

[Service]
ExecStart=/usr/bin/tb710fu-keyboard
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

	log "Android userdata tools + safe slot-b updates from Linux"
	sudo install -Dm755 -t "$R/usr/local/sbin" "$HERE/rootfs-files/tb710fu-android-fbe" 		"$HERE/rootfs-files/tb710fu-install-userdata" "$HERE/rootfs-files/tb710fu-update-slot-b"

	log "A/B slot tools"
	[ -x "$OUT/qbootctl" ] || bash "$HERE/qbootctl.sh"
	sudo install -Dm755 "$OUT/qbootctl" "$R/usr/bin/qbootctl"
	# ABL falls back to the other slot after a few boots unless the slot is marked successful
	sudo tee "$R/etc/systemd/system/qbootctl-mark-successful.service" >/dev/null <<'EOF'
[Unit]
Description=Mark the current A/B slot as successfully booted
# only once the desktop is up and has run a minute: a payload that resets later still falls back
After=graphical.target

[Service]
Type=oneshot
ExecStartPre=/usr/bin/sleep 60
ExecStart=/usr/bin/qbootctl -m

[Install]
WantedBy=multi-user.target
EOF
	sudo tee "$R/usr/bin/reboot-to-android" >/dev/null <<'EOF'
#!/bin/sh
# switch to the other A/B slot (Android) and reboot
set -e
# booted from the kShimC menu (build.sh kshim): Android is the menu default, a reboot is enough
grep -qw tb710fu.kshim=1 /proc/cmdline && exec systemctl reboot
cur=$(qbootctl -c | grep -o '_[ab]' | tr -d _)
[ "$cur" = a ] && other=b || other=a
qbootctl -s "$other"
systemctl reboot
EOF
	sudo chmod 755 "$R/usr/bin/reboot-to-android"
	# no password for the active session (the touch-only desktop may have no keyboard to type it)
	sudo install -Dm644 "$HERE/rootfs-files/org.tb710fu.reboot-to-android.policy" \
		"$R/usr/share/polkit-1/actions/org.tb710fu.reboot-to-android.policy"
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
	sudo install -Dm644 "$HERE/initcpio/install/tb710fu-fallback" "$R/etc/initcpio/install/tb710fu-fallback"
	sudo install -Dm644 "$HERE/initcpio/hooks/tb710fu-fallback" "$R/etc/initcpio/hooks/tb710fu-fallback"

	log "first boot: grow root, create /home"
	# The SSD image only carries a small root partition (build.sh image); the disk size is
	# known only on the device, so the rest is laid out on first boot.
	printf 'ROOT_SIZE=%s\nROOT_PARTUUID=%s\nHOME_PARTUUID=%s\nROOT_FS=%s\n' "$ROOT_SIZE" "$ROOT_PARTUUID" "$HOME_PARTUUID" "$ROOT_FS" |
		sudo tee "$R/etc/tb710fu.conf" >/dev/null
	sudo install -Dm755 "$HERE/rootfs-files/tb710fu-firstboot" "$R/usr/bin/tb710fu-firstboot"
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

	log "system config + initramfs ($ROOT_FS)"
	local fsopt="" fsck=1
	case "$ROOT_FS" in
	ext4) ;;
	btrfs) fsopt=",compress=zstd:1" fsck=0 ;;
	*) die "ROOT_FS must be ext4 or btrfs" ;;
	esac
	sudo tee "$R/etc/fstab" >/dev/null <<EOF
PARTUUID=$ROOT_PARTUUID  /      $ROOT_FS  rw,noatime,commit=60$fsopt  0 $fsck
PARTUUID=$HOME_PARTUUID  /home  $ROOT_FS  rw,noatime,commit=60$fsopt,nofail,x-systemd.device-timeout=60s  0 $((fsck * 2))
EOF
	# no autodetect: it would probe the build host
	sudo tee "$R/etc/mkinitcpio-tb710fu.conf" >/dev/null <<'EOF'
MODULES=(qcom_q6v5_pas)
BINARIES=()
FILES=(/usr/lib/firmware/qcom/sm8650/xiaoxin/gt/adsp.mbn /usr/lib/firmware/qcom/sm8650/xiaoxin/gt/adsp_dtb.mbn)
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
# touch tablet: KWin's input method = Plasma Keyboard (on-screen keyboard). Apps must use Wayland
# text-input for it, so no global QT_IM_MODULE/GTK_IM_MODULE=fcitx (earlier builds set them, which
# kept the on-screen keyboard from ever showing). Korean: switch KWin's input method to Fcitx 5
# under System Settings > Keyboard > Virtual Keyboard (one or the other, KWin runs a single one).
sed -i '/^\(GTK_IM_MODULE\|QT_IM_MODULE\|XMODIFIERS\)=/d' /etc/environment
mkdir -p /etc/xdg
printf '[Wayland]\nInputMethod=/usr/share/applications/org.kde.plasma.keyboard.desktop\nVirtualKeyboardEnabled=true\n' > /etc/xdg/kwinrc
# on-screen keyboard languages (default: only the system locale, ko_KR -> no Latin letters); the
# globe key switches between them
printf '[General]\nenabledLocales=en_US,ko_KR\n' > /etc/xdg/plasmakeyboardrc
systemctl enable sddm NetworkManager bluetooth qbootctl-mark-successful tb710fu-firstboot tb710fu-keyboard
# ALARM defaults: networkd fights NetworkManager; no sshd while the test password is set
systemctl disable systemd-networkd sshd 2>/dev/null || true
# touch-only tablet: skip the SDDM greeter
mkdir -p /etc/sddm.conf.d
printf '[Autologin]\nUser=$USERNAME\nSession=plasma\n' > /etc/sddm.conf.d/autologin.conf
# SDDM's default X11 display server starts Xorg on VT2 even for autologin and keeps DRM master:
# KWin on VT1 then cannot modeset (EACCES) -> black screen. The Wayland display server starts
# nothing for autologin (its compositor only runs with the greeter).
printf '[General]\nDisplayServer=wayland\nGreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell\n\n[Wayland]\nCompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1\n' > /etc/sddm.conf.d/10-wayland.conf
# the hall sensor (gpio-keys SW_LID) reads "closed" with no cover on: logind would suspend ~30 s
# after boot, the user session never starts (no /run/user), KWin aborts -> black screen
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' > /etc/systemd/logind.conf.d/10-tb710fu-lid.conf
# deep suspend does not come back on this kernel yet (Wi-Fi, SSH and the display stay dead)
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
# no idle display-off / lock: turning the DSI panel back on (DPMS) silently reset the tablet once
mkdir -p /etc/xdg
printf '[Daemon]\nAutolock=false\nLockOnResume=false\n' > /etc/xdg/kscreenlockerrc
for g in AC Battery LowBattery; do printf '[%s][Display]\nDimDisplayWhenIdle=false\nTurnOffDisplayWhenIdle=false\n\n[%s][SuspendAndShutdown]\nAutoSuspendAction=0\n\n' \$g \$g; done > /etc/xdg/powerdevilrc
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
	# untracked per-builder files (Wi-Fi keyfile, SSH key + sshd enable, ...) kept out of git;
	# existing directories keep their owner/mode
	if [ -d "$T/local-overlay" ]; then
		log "local overlay: $T/local-overlay"
		tar -C "$T/local-overlay" -c . | sudo tar -C "$R" -x --no-same-owner --no-overwrite-dir
	fi
	sudo cp "$R/boot/initramfs-tb710fu.img" "$OUT/initramfs.img"
	sudo chown "$(id -u):$(id -g)" "$OUT/initramfs.img"
	sudo umount "$R"
	log "rootfs ready: $R ($(sudo du -sh "$R" | cut -f1))"
}

# stock ADSP libraries (sensors PD) from the ROM's dspso.bin into ROOT's hexagonrpcd tree
dsp_libs() {
	local q="$1/usr/share/qcom/sm8650/Lenovo/tb710fu/dsp"
	[ -r "$DSPSO" ] || die "DSPSO ($DSPSO) not readable: stock dspso.bin from the ROM"
	sudo mkdir -p "$q"
	sudo debugfs -R "rdump /adsp $q" "$DSPSO" 2>/dev/null
	[ -n "$(ls "$q/adsp")" ] || die "no ADSP libs extracted from $DSPSO"
	sudo chmod -R a+rX "$q"
}

personalize() {
	# CI image (.github/workflows/rootfs.yml) -> out/tb710fu-ssd.img with what must not be public:
	# local-overlay (Wi-Fi keyfile, SSH key, sshd enable) and the ROM's DSP libraries. Writes the
	# raw image (write-usb.ps1 takes it as is) and its sha256; out/initramfs.img comes along.
	local run gh dl img="$OUT/tb710fu-ssd.img" mnt="$OUT/personalize.mnt"
	gh=$(command -v gh || command -v gh.exe) || die "gh (GitHub CLI) not found"
	run=${ROOTFS_RUN:-$("$gh" run list -R "$GH_REPO" -w rootfs.yml -b main -s success -L 1 --json databaseId -q '.[0].databaseId')}
	[ -n "$run" ] || die "no successful rootfs.yml run in $GH_REPO yet"
	dl="$REPO/out/rootfs-download" && rm -rf "$dl" && mkdir -p "$dl"
	"$gh" run download "$run" -R "$GH_REPO" -n rootfs-tb710fu -D "$(wslpath -w "$dl" 2>/dev/null || echo "$dl")"
	(cd "$dl" && sha256sum -c rootfs-tb710fu.sha256) || die "rootfs artifact checksum mismatch"
	cp "$dl/initramfs.img" "$OUT/initramfs.img"
	log "unpacking the SSD image"
	rm -f "$img" && xz -dc "$dl/tb710fu-ssd.img.xz" > "$img" && rm -rf "$dl"
	sudo umount "$mnt" 2>/dev/null || true
	mkdir -p "$mnt"
	sudo mount -o loop,offset=$((2048 * 512)) "$img" "$mnt"   # partition 1 at sector 2048 (image())
	dsp_libs "$mnt"
	if [ -d "$T/local-overlay" ]; then
		log "local overlay: $T/local-overlay"
		tar -C "$T/local-overlay" -c . | sudo tar -C "$mnt" -x --no-same-owner --no-overwrite-dir
	fi
	sudo umount "$mnt" && rmdir "$mnt"
	sha256sum "$img" | cut -d' ' -f1 > "$img.sha256"
	echo "$run" > "$OUT/ROOTFS_RUN"
	log "out/tb710fu-ssd.img ($(du -h "$img" | cut -f1), rootfs run $run): write it with write-usb.ps1"
}

bootimg() {
	local dtb
	dtb=$(kdtb)
	[ -f "$OUT/initramfs.img" ] || die "run: build.sh rootfs"
	# deviceinfo: append_dtb, header v2, pagesize 4096 (offsets in mkbootimg.py).
	# Ubuntu's mkbootimg package is broken (missing gki module), hence our own writer.
	{ gzip -9c "$(kimage)"; cat "$dtb"; } > "$OUT/Image.gz-dtb"
	python3 -I "$HERE/mkbootimg.py" "$OUT/boot.img" "$OUT/Image.gz-dtb" "$OUT/initramfs.img" "$dtb" "$CMDLINE"
	log "out/boot.img ($(du -h "$OUT/boot.img" | cut -f1)), cmdline: $CMDLINE"
}

# OV: --overlay args that bring the initramfs up to date without regenerating it (sudo)
initrd_overlays() {
	# USB-C host mode comes from pmic_glink, i.e. from the ADSP: without its remoteproc driver
	# and firmware in the initramfs dwc3 stays a peripheral and the root USB disk never shows up
	# modules from the staged kernel, so the initramfs matches it even if the rootfs is older
	local m="$(kmod)" f pas fw="usr/lib/firmware/qcom/sm8650/xiaoxin/gt" src="$REPO/linux-firmware-tb710fu/qcom/sm8650/xiaoxin/gt"
	OV=()
	[ -f "$m/modules.dep" ] || die "no staged kernel modules in $m: run build.sh kernel"
	# .ko, .ko.gz, .ko.zst: whatever this kernel's modules_install produced
	pas=$(sed -n 's|^\(kernel/drivers/remoteproc/qcom_q6v5_pas\.ko[^:]*\):.*|\1|p' "$m/modules.dep")
	[ -n "$pas" ] || die "qcom_q6v5_pas not in $m/modules.dep"
	for f in $(sed -n "s|^${pas//./\\.}: ||p" "$m/modules.dep") \
		"$pas" modules.dep modules.dep.bin modules.alias \
		modules.alias.bin modules.softdep modules.symbols modules.symbols.bin modules.builtin \
		modules.builtin.bin modules.builtin.alias.bin; do
		[ -r "$m/$f" ] || die "missing $m/$f"
		OV+=(--overlay "usr/lib/modules/$(kver)/$f=$m/$f")
	done
	# the same files build.sh rootfs installs; no rootfs needed (CI builds it)
	for f in adsp.mbn adsp_dtb.mbn; do OV+=(--overlay "$fw/$f=$src/$f"); done
	OV+=(--overlay hooks/tb710fu-fallback="$HERE/initcpio/hooks/tb710fu-fallback")
}

kshim() {
	# kShimC boot menu in boot_a (ArmadaOS Freedom, .github/workflows/kshim.yml): the stock Android
	# kernel and this Linux in one image, picked with the volume keys - no A/B slot switching.
	# Android is the default entry, so a Linux that can't find its root (initramfs fallback reboots)
	# or any other reset lands in Android. Linux gets its cmdline from the DTB's /chosen.
	local S="${1:-$T/dump}" d="$OUT/kshim" py="python3 -I" key="$HERE/testkey_rsa4096.pem" gh run dl
	[ -f "$(kimage)" ] || die "run: build.sh kernel"
	[ -f "$OUT/initramfs.img" ] || die "run: build.sh rootfs"
	rm -rf "$d" && mkdir -p "$d/tools"
	gh=$(command -v gh || command -v gh.exe) || die "gh (GitHub CLI) not found"
	run=${KSHIM_RUN:-$("$gh" run list -R "$GH_REPO" -w kshim.yml -b main -s success -L 1 --json databaseId -q '.[0].databaseId')}
	[ -n "$run" ] || die "no successful kshim.yml run in $GH_REPO yet"
	dl="$REPO/out/kshim-download" && rm -rf "$dl" && mkdir -p "$dl"
	"$gh" run download "$run" -R "$GH_REPO" -n kshim-tb710fu -D "$(wslpath -w "$dl" 2>/dev/null || echo "$dl")"
	cp "$dl"/* "$d/tools/" && rm -rf "$dl"
	(cd "$d/tools" && sha256sum -c --quiet SHA256SUMS) || die "kshim artifact checksum mismatch"
	chmod +x "$d/tools/MultiBootKernelPatcher" "$d/tools/UnpackTool"

	cp "$(kdtb)" "$d/linux.dtb"
	fdtget -p "$d/linux.dtb" /chosen >/dev/null 2>&1 || fdtput -c "$d/linux.dtb" /chosen
	# tb710fu.kshim: reboot-to-android just reboots (menu default) instead of switching slots
	fdtput -t s "$d/linux.dtb" /chosen bootargs "$CMDLINE tb710fu.kshim=1"
	fdtput -t u "$d/linux.dtb" /chosen kshim,initrd-entry 3
	initrd_overlays
	$py "$HERE/bootv4.py" ramdisk "$OUT/initramfs.img" "$d/initrd.img" "${OV[@]}"
	$py "$d/tools/pack_boot.py" --boot "$S/boot_a.img" --runtime "$d/tools/kShimC.bin" \
		--linux "$(kimage)" --dtb "$d/linux.dtb" --initrd "$d/initrd.img" \
		--packer "$d/tools/MultiBootKernelPatcher" --avbtool "$d/tools/avbtool.py" --key "$key" \
		--android-name Android --linux-name "Arch Linux" --default android --out "$d/boot_a.img"
	[ "$($py "$HERE/avbsign.py" verify "$d/boot_a.img" "$key")" = OK ] || die "boot_a verify failed"
	(cd "$d" && sha256sum boot_a.img > SHA256SUMS)
	log "out/kshim/boot_a.img ($(du -h "$d/boot_a.img" | cut -f1), kShimC run $run): write to boot_a"
}

v4() {
	# Locked-bootloader layout: mirror stock GKI v4 (boot = kernel only, vendor_boot = DTB + ramdisk,
	# init_boot = generic ramdisk) using the stock slot-a images as header templates.
	# out/v4/<mode>/ gets <part>_b.img for every partition that differs from slot a, plus SHA256SUMS.
	#   v4 e1   stock Android kernel, init=/nonexistent panic=5 -> proves ABL accepts slot b (no userspace)
	#   v4 e2   mainline kernel + DTB + our initramfs
	#   v4 e2b  e2 with the DTB's qcom,board-id = <0 0> like the stock base DTBs
	#   v4 e3   e2 + zeroed dtbo + board-id <8 0, 8 0x600>: a failed stock-overlay apply leaves no DTB at
	#           the load address (ApplyOverlay copies only on success) -> UpdateDeviceTree fails ->
	#           fastboot; an invalid dtbo makes ABL copy our DTB itself (appended-DT path)
	#   v4 e1big  e1 + 64 MiB vendor ramdisk filler (does ABL load a big vendor ramdisk?)
	local mode="${1:?v4 e1|e1big|e2|e2b|e3}" S="${2:-$T/dump}" py="python3 -I" key="$HERE/testkey_rsa4096.pem"
	local d="$OUT/v4/$mode" ri psize=100663296
	[ "$ROOT_DEV" = ssd ] || d="$d-$ROOT_DEV"
	rm -rf "$d" && mkdir -p "$d"
	ri=$($py -c 'import sys; sys.path.insert(0, sys.argv[1]); import avbinfo
print(avbinfo.parse(avbinfo.vbmeta_blob(open(sys.argv[2], "rb").read())[0])["rollback_index"])' "$HERE" "$S/boot_a.img")
	case "$mode" in
	e1)
		$py "$HERE/bootv4.py" boot "$S/boot_a.img" "$d/boot_b.img" \
			--cmdline "panic=5 rdinit=/tb710fu-e1 init=/tb710fu-e1"
		;;
	e1big)
		# e1 + 64 MiB of incompressible filler appended to the stock vendor ramdisk:
		# does this ABL load a vendor ramdisk well beyond 15 MiB? (marker in cmdline -> ramoops)
		head -c 67108864 /dev/urandom > "$d/filler"
		$py "$HERE/bootv4.py" boot "$S/boot_a.img" "$d/boot_b.img" \
			--cmdline "panic=5 rdinit=/tb710fu-e1 init=/tb710fu-e1 tb710fu.e1big=1"
		$py "$HERE/bootv4.py" vendor_boot "$S/vendor_boot_a.img" "$d/vendor_boot_b.img" \
			--overlay tb710fu-filler="$d/filler"
		rm -f "$d/filler"
		$py "$HERE/avbsign.py" refresh "$S/vbmeta_a.img" "$d/vbmeta_b.img" "$key" \
			vendor_boot="$d/vendor_boot_b.img"
		[ "$($py "$HERE/avbsign.py" verify "$d/vbmeta_b.img" "$key")" = OK ] || die "vbmeta_b verify failed"
		truncate -s "$(stat -c %s "$S/vendor_boot_a.img")" "$d/vendor_boot_b.img"
		;;
	e2|e2b|e3)
		local dtb="$d/tb710fu.dtb"
		# ABL's UpdateDeviceTree() aborts the boot (-> fastboot) when /soc/cache-controller is
		# missing: it appends qcom,sct-config to the LLCC node, which mainline names
		# system-cache-controller@25000000. An empty stub satisfies ABL; the kernel ignores it.
		dtc -q -I dtb -O dts -o "$d/tb710fu.dts" "$(kdtb)"
		printf '\n/ {\n\tsoc@0 {\n\t\tcache-controller {\n\t\t};\n\t};\n};\n' >> "$d/tb710fu.dts"
		if [ "$mode" = e3 ]; then
			# with dtbo invalid, ABL takes the appended-DT path (DeviceTreeAppended), which needs an
			# absolute match: MTP(8), subtype 0, HLOS DDR bits (subtype & 0x700) == DdrType<<8.
			# Board.c BoardDdrType() leaves DdrType 0 above 4 GiB (8 GiB here); 0x600 (4 GiB) kept
			# as a second entry in case Lenovo's ABL differs - each board-id entry is matched alone
			printf '\n/ {\n\tqcom,board-id = <8 0>, <8 0x600>;\n};\n' >> "$d/tb710fu.dts"
		fi
		dtc -q -I dts -O dtb -o "$dtb" "$d/tb710fu.dts"
		rm -f "$d/tb710fu.dts"
		$py "$HERE/dtcheck.py" "$dtb" || die "DTB lacks a node ABL requires"
		if [ "$mode" = e2b ]; then
			# stock base DTBs all use board-id <0 0> (default match); the MTP id lives in dtbo
			$py "$HERE/dtbprop.py" "$dtb" "$d/board0.dtb" qcom,board-id 0 0
			dtb="$d/board0.dtb"
		fi
		$py "$HERE/bootv4.py" boot "$S/boot_a.img" "$d/boot_b.img" \
			--kernel "$(kimage)" --cmdline "$CMDLINE"
		initrd_overlays
		$py "$HERE/bootv4.py" vendor_boot "$S/vendor_boot_a.img" "$d/vendor_boot_b.img" \
			--ramdisk "$OUT/initramfs.img" --dtb "$dtb" "${OV[@]}"
		# the overlays keep the payload current without regenerating the initramfs (sudo)
		# empty generic ramdisk: Android's first-stage init must not be appended over ours
		$py "$HERE/bootv4.py" init_boot "$S/init_boot_a.img" "$d/init_boot_b.img" --ramdisk empty
		local extra=""
		if [ "$mode" = e3 ]; then
			# hash covers 4 KiB of zeros; the rest of the partition is zeroed too
			head -c 4096 /dev/zero > "$d/dtbo_b.img"
			extra="dtbo=$d/dtbo_b.img"
		fi
		$py "$HERE/avbsign.py" refresh "$S/vbmeta_a.img" "$d/vbmeta_b.img" "$key" \
			vendor_boot="$d/vendor_boot_b.img" init_boot="$d/init_boot_b.img" $extra
		[ "$($py "$HERE/avbsign.py" verify "$d/vbmeta_b.img" "$key")" = OK ] || die "vbmeta_b verify failed"
		local p
		if [ "$mode" = e3 ]; then truncate -s 25165824 "$d/dtbo_b.img"; fi
		for p in vendor_boot init_boot; do truncate -s "$(stat -c %s "$S/${p}_a.img")" "$d/${p}_b.img"; done
		;;
	*) die "v4 e1|e1big|e2|e2b|e3" ;;
	esac
	# stock os_version/security_patch properties: ABL refuses a boot vbmeta without them (header os_version is 0)
	$py "$HERE/avbsign.py" footer "$d/boot_b.img" "$psize" "$ri" "$key" --props-from "$S/boot_a.img"
	[ "$($py "$HERE/avbsign.py" verify "$d/boot_b.img" "$key")" = OK ] || die "boot_b verify failed"
	(cd "$d" && sha256sum *.img > SHA256SUMS)
	log "${d#$OUT/}: $(ls "$d" | tr '\n' ' ')(boot rollback index $ri)"
}

image() {
	# SSD image for Rufus / balenaEtcher: GPT with only the root partition (fixed PARTUUID).
	# tb710fu-firstboot grows it to ROOT_SIZE and creates /home from the rest of the disk.
	[ -f "$R/usr/bin/tb710fu-firstboot" ] || die "run: build.sh rootfs"
	findmnt "$R" >/dev/null && die "$R is still mounted"
	local img="$OUT/tb710fu-ssd.img" fs="$OUT/root.$ROOT_FS" mib
	# fstab and firstboot come from build.sh rootfs
	grep -qx "ROOT_FS=$ROOT_FS" "$R/etc/tb710fu.conf" || die "rootfs was built for another ROOT_FS: run build.sh rootfs"
	# content + 30% + 1 GiB headroom; first boot grows it anyway
	mib=$(( $(sudo du -sm "$R" | cut -f1) * 13 / 10 + 1024 ))
	log "root filesystem ($ROOT_FS) ${mib} MiB from $R"
	sudo rm -f "$fs"
	case "$ROOT_FS" in
	ext4) sudo mkfs.ext4 -q -F -L tb710fu-root -d "$R" "$fs" "${mib}M" ;;
	# ponytail: files land uncompressed (Ubuntu's btrfs-progs predates --compress); new writes use
	# compress=zstd from fstab, `btrfs filesystem defragment -r -czstd /` on the device compresses the rest
	btrfs) truncate -s "${mib}M" "$fs" && sudo mkfs.btrfs -q -f -L tb710fu-root --rootdir "$R" "$fs" ;;
	esac
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
	$py "$HERE/avbsign.py" footer "$OUT/boot-signed.img" "$(stat -c %s "$stock")" "$ri" "$key" --props-from "$stock"
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
deps|kernel|rootfs|bootimg|image|personalize) "$1" ;;
v4) shift; v4 "$@" ;;
kshim) shift; kshim "$@" ;;
sign) shift; sign "$@" ;;
all) deps; kernel; rootfs; bootimg; image ;;
*) sed -n '2,13p' "$0"; exit 1 ;;
esac
