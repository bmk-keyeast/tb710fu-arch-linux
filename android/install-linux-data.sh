#!/system/bin/sh
# Install the CI Linux rootfs into Android's /data as /data/linux (ROOT_DEV=userdata), as root on
# the running Android (KernelSU). Needs Android's encryption off (AGENTS.md).
#
#   adb push android/install-linux-data.sh /data/local/tmp/
#   adb push out/tb710fu-personal.tar /data/local/tmp/        # build.sh personal: Wi-Fi, SSH, DSP libs
#   adb shell su -c "sh /data/local/tmp/install-linux-data.sh"
#
# The rootfs tarball (~1.3 GB, rootfs.yml release rootfs-latest) is downloaded by the tablet itself
# unless /data/local/tmp/tb710fu-rootfs.tar.xz is already there (adb push it to skip the download).
# An existing /data/linux is only replaced with REPLACE=1.
set -eu
URL=https://github.com/bmk-keyeast/tb710fu-arch-linux/releases/download/rootfs-latest
T=/data/local/tmp
D=/data/linux
TAR=$T/tb710fu-rootfs.tar.xz
PERSONAL=$T/tb710fu-personal.tar
die() { echo "install-linux-data: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (su -c)"
BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=$(command -v busybox) || die "no busybox (KernelSU's /data/adb/ksu/bin/busybox)"
for a in xz tar sha256sum wget; do "$BB" --list | grep -qx "$a" || die "busybox lacks $a"; done
[ "$(getprop ro.crypto.state)" != encrypted ] || die "/data is encrypted: turn encryption off first"

if [ -e "$D" ]; then
	[ "${REPLACE:-}" = 1 ] || die "$D exists (REPLACE=1 to install again from scratch)"
	rm -rf "$D"
fi
free=$(df -k /data | tail -1 | awk '{print $4}')
[ "$free" -gt $((12 * 1024 * 1024)) ] || die "need 12 GiB free on /data (have $((free / 1024)) MiB)"

"$BB" wget -q -O $T/SHA256SUMS "$URL/SHA256SUMS" || die "can't fetch $URL/SHA256SUMS"
if [ ! -f "$TAR" ]; then
	echo "downloading the rootfs (~1.3 GB) ..."
	"$BB" wget -O "$TAR.part" "$URL/tb710fu-rootfs.tar.xz" || die "download failed (or adb push the tarball to $TAR)"
	mv "$TAR.part" "$TAR"
fi
want=$(awk '$2 == "tb710fu-rootfs.tar.xz" {print $1}' $T/SHA256SUMS)
[ "$("$BB" sha256sum "$TAR" | cut -d' ' -f1)" = "$want" ] || die "$TAR does not match the release (stale? delete it)"

echo "unpacking into $D ..."
mkdir -m 755 "$D"
# root: busybox tar keeps the numeric owners and modes; xattrs (file capabilities) are lost and
# re-applied by tb710fu-firstboot from /usr/share/tb710fu/file-caps
"$BB" xz -dc "$TAR" | "$BB" tar -x -p -C "$D"
[ -x "$D/usr/lib/systemd/systemd" ] || die "unpacked tree has no systemd"
if [ -f "$PERSONAL" ]; then
	"$BB" tar -x -p -C "$D" -f "$PERSONAL"
	echo "personal files: $PERSONAL"
else
	echo "warning: no $PERSONAL (no Wi-Fi/SSH config, no sensor DSP libs)"
fi
# the initramfs mounts / (= /data/linux) and /mnt/android; no SSD partitions
printf '# ROOT_DEV=userdata: / (= /linux on userdata) and /mnt/android are mounted by the initramfs\n' > "$D/etc/fstab"
sed -i '/^ROOT_DEV=/d' "$D/etc/tb710fu.conf"
echo "ROOT_DEV=userdata" >> "$D/etc/tb710fu.conf"
mkdir -p "$D/mnt/android"
# firstboot stays armed: it re-applies the file capabilities
rm -f "$D/var/lib/tb710fu/firstboot-done"
sync
echo "done: $D ($(du -sm "$D" | cut -f1) MiB). Boot it from the kShimC menu (ROOT_DEV=userdata boot_a)."
echo "the tarball can go: rm $TAR"
