#!/system/bin/sh
# READ-ONLY: after a slot-b attempt falls back to Android, save what the last boot left behind.
# Mainline and stock Android share the ramoops region (0xac300000), so a mainline kernel that ran
# leaves its console log here. Output: /data/local/tmp/tb710fu-bootlog/
OUT=/data/local/tmp/tb710fu-bootlog
rm -rf $OUT && mkdir -p $OUT
cp /sys/fs/pstore/* $OUT/ 2>/dev/null
S=android.hardware.boot.IBootControl/default
v() { service call $S "$@" | grep -o "0000000[0-9a-f] " | tail -1; }
{
	echo "slot_suffix=$(getprop ro.boot.slot_suffix) bootreason=$(getprop ro.boot.bootreason)"
	echo "active=$(v 1) bootable_b=$(v 6 i32 1) successful_b=$(v 7 i32 1)"
	getprop persist.sys.boot.reason.history
} > $OUT/state.txt
chmod -R a+r $OUT
ls -l $OUT
cat $OUT/state.txt
