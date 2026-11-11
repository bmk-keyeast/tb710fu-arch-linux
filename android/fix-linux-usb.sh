#!/system/bin/sh
# Patch the Linux USB disk from rooted Android. Start it, then plug the USB disk into the tablet:
#   su -c 'nohup sh /data/local/tmp/fix-linux-usb.sh >/dev/null 2>&1 &'
# Waits up to 10 min for the disk, mounts the root partition read-write, writes the fixes below,
# unmounts. Log: /data/local/tmp/fix-linux-usb.log (DONE / FAILED on the last line).
L=/data/local/tmp/fix-linux-usb.log
exec > $L 2>&1
echo "start $(date)"
ROOT_PARTUUID=9d53a1f9-76da-45f9-840d-29fec7a13ce6
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
grep -qi "$ROOT_PARTUUID" /sys/block/$dev/$n/uevent 2>/dev/null || echo "note: PARTUUID not in uevent, checking contents"
M=/data/local/tmp/linuxroot; mkdir -p $M
mount -t ext4 -o rw /dev/block/$n $M || { echo "mount FAILED"; exit 1; }
[ -f $M/etc/arch-release ] && [ -d $M/etc/sddm.conf.d ] || { umount $M; echo "not our rootfs FAILED"; exit 1; }

# --- fixes ---
mkdir -p $M/etc/systemd/logind.conf.d
printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' \
	> $M/etc/systemd/logind.conf.d/10-tb710fu-lid.conf
chmod 644 $M/etc/systemd/logind.conf.d/10-tb710fu-lid.conf
cat $M/etc/systemd/logind.conf.d/10-tb710fu-lid.conf
# SDDM: no Xorg holding DRM master for the autologin Wayland session
printf '[General]\nDisplayServer=wayland\nGreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell\n\n[Wayland]\nCompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1\n' \
	> $M/etc/sddm.conf.d/10-wayland.conf
chmod 644 $M/etc/sddm.conf.d/10-wayland.conf
cat $M/etc/sddm.conf.d/10-wayland.conf
# ---

sync; umount $M && echo "DONE $(date)" || echo "umount FAILED"
