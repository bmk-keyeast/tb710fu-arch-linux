#!/system/bin/sh
# Read-only: how stock Android powers the Keyboard Pack (PM8550 LDO B8 = pm_humu_l8).
# Run as root once with the keyboard detached and once attached:
#   adb push android/kb-power-probe.sh /data/local/tmp/ && adb shell su -c sh /data/local/tmp/kb-power-probe.sh
# Writes nothing. Answers: which voltage/mode stock uses, and who else is on the rail.
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
echo "== gpio81 plug detect (low = attached)"
grep -E "gpio81 |gpio100 |gpio137 " /sys/kernel/debug/gpio 2>/dev/null
for r in /sys/class/regulator/regulator.*; do
	n=$(cat "$r/name" 2>/dev/null)
	case "$n" in *l8*|*L8*|*humu_l1*)
		echo "== $r $n"
		for f in state microvolts min_microvolts max_microvolts opmode num_users requested_microamps; do
			[ -r "$r/$f" ] && echo "$f: $(cat "$r/$f")"
		done
		ls "$r" | grep -v -E "^(power|subsystem|uevent|device)$" | tr '\n' ' '; echo ;;
	esac
done
echo "== regulator_summary (l8 and its consumers)"
awk '/humu_l8|vreg_l8/{p=8} p>0{print; p--}' /sys/kernel/debug/regulator/regulator_summary 2>/dev/null
echo "== kernel log"
dmesg | grep -i -E "lenovo_kb|lenovo_keyboard|humu_l8|ocp|pon_reason|power-on reason|power-off reason|PON" | tail -40
