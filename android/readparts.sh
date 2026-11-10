#!/system/bin/sh
# READ-ONLY partition survey + dump for TB710FU (run as root on Android).
# Writes only into $OUT on /data; never writes to a block device.
OUT=/data/local/tmp/tb710fu-dump
mkdir -p $OUT
cd /dev/block/by-name || exit 1

echo "== slot: $(getprop ro.boot.slot_suffix)  build: $(getprop ro.build.display.id)"
echo "== partitions (name -> dev, bytes)"
for p in *; do
	d=$(readlink -f $p)
	printf '%-28s %-14s %s\n' $p ${d#/dev/block/} $(blockdev --getsize64 $d)
done > $OUT/partitions.txt
cat $OUT/partitions.txt

echo "== dumping"
for p in boot_a boot_b vbmeta_a vbmeta_b vbmeta_system_a vbmeta_system_b \
	init_boot_a init_boot_b vendor_boot_a vendor_boot_b dtbo_a dtbo_b; do
	[ -e $p ] || { echo "skip $p (missing)"; continue; }
	dd if=$p of=$OUT/$p.img bs=1M 2>/dev/null && echo "ok $p $(stat -c %s $OUT/$p.img)"
done
(cd $OUT && sha256sum *.img > SHA256SUMS)

echo "== super (lpdump)"
lpdump > $OUT/lpdump.txt 2>&1 || echo "lpdump failed"
grep -iE "size|free|partition name|group" $OUT/lpdump.txt | head -60
echo "== storage"
df -h /data | tail -1
