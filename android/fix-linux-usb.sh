#!/system/bin/sh
# Patch the Linux root on the USB SSD from rooted Android: extracts a tarball of files (paths
# relative to /, owned by root) over it. Start it, plug the SSD in if it isn't yet:
#   su -c 'nohup sh /data/local/tmp/fix-linux-usb.sh /data/local/tmp/linux-fix.tar >/dev/null 2>&1 &'
# Waits up to 10 min for the disk, mounts the root partition read-write, extracts, unmounts.
# Log: /data/local/tmp/fix-linux-usb.log (DONE / FAILED on the last line). ext4 roots only:
# Android's kernel has no btrfs.
TAR=${1:-/data/local/tmp/linux-fix.tar}
L=/data/local/tmp/fix-linux-usb.log
exec > $L 2>&1
echo "start $(date) $TAR"
[ -f "$TAR" ] || { echo "no $TAR FAILED"; exit 1; }
dev=""
for i in $(seq 600); do
	for b in /sys/block/sd*; do
		case "$(readlink -f $b)" in *usb*) dev=${b##*/}; break 2 ;; esac
	done
	sleep 1
done
[ -n "$dev" ] || { echo "no USB disk FAILED"; exit 1; }
echo "usb disk: $dev"; sleep 3
n=${dev}1
[ -b /dev/block/$n ] || mknod /dev/block/$n b $(sed 's/:/ /' /sys/block/$dev/$n/dev)
M=/data/local/tmp/linuxroot; mkdir -p $M
mount -t ext4 -o rw /dev/block/$n $M || { echo "mount FAILED"; exit 1; }
[ -f $M/etc/arch-release ] && [ -f $M/etc/tb710fu.conf ] || { umount $M; echo "not our rootfs FAILED"; exit 1; }

tar -xvpf "$TAR" -C $M --no-same-owner || { umount $M; echo "extract FAILED"; exit 1; }

sync; umount $M && echo "DONE $(date)" || echo "umount FAILED"
