#!/system/bin/sh
# Run as root in the background from Android, then plug the Linux USB disk into the tablet:
#   su -c 'nohup sh grab-linux-logs.sh >/dev/null 2>&1 &'
# Waits up to 10 min for a USB block device, mounts its partitions READ-ONLY, copies the logs
# of the Linux boots to /data/local/tmp/linuxlogs, unmounts. Writes nothing to the USB disk.
O=/data/local/tmp/linuxlogs
rm -rf $O; mkdir -p $O; exec > $O/grab.log 2>&1
echo "start $(date)"
dev=""
for i in $(seq 600); do
	for b in /sys/block/sd*; do
		case "$(readlink -f $b)" in *usb*) dev=${b##*/}; break 2 ;; esac
	done
	sleep 1
done
[ -n "$dev" ] || { echo "no USB disk"; echo done > $O/DONE; exit 1; }
echo "usb disk: $dev"; sleep 3
M=/data/local/tmp/linuxmnt
for p in 1 2; do
	n=$dev$p; mkdir -p $M$p
	[ -b /dev/block/$n ] || mknod /dev/block/$n b $(sed 's/:/ /' /sys/block/$dev/$n/dev)
	mount -t ext4 -o ro,noload /dev/block/$n $M$p && echo "mounted $n" || echo "mount $n failed"
done
R=${M}1; H=${M}2
cp -r $R/var/log $O/var-log 2>&1 | tail -3
for f in $R/var/lib/sddm/.local/share/sddm $R/etc/sddm.conf.d $R/etc/sddm.conf; do [ -e $f ] && cp -r $f $O/; done
for u in $H/*; do
	[ -d "$u" ] || continue
	mkdir -p $O/home-${u##*/}
	cp -r $u/.local/share/sddm $u/.local/share/kwin* $u/.cache/kwin $O/home-${u##*/}/ 2>/dev/null
	cp $u/.local/share/xorg/*.log $O/home-${u##*/}/ 2>/dev/null
done
ls -laR $O | head -60
umount $M1 $M2 2>/dev/null; umount ${M}1 ${M}2
chmod -R a+rX $O
echo "end $(date)"; echo done > $O/DONE
