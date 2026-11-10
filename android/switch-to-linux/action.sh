#!/system/bin/sh
# KernelSU/Magisk Action: switch to the other A/B slot (Linux) and reboot.
# Talks to the boot control AIDL HAL directly (this ROM has no working bootctl CLI).
# IBootControl transaction codes: 1 getActiveBootSlot, 9 setActiveBootSlot(int).
S=android.hardware.boot.IBootControl/default
cur=$(getprop ro.boot.slot_suffix)
case "$cur" in
	_a) other=1; name=b ;;
	_b) other=0; name=a ;;
	*) echo "unknown current slot '$cur'"; exit 1 ;;
esac
active() { service call $S 1 | grep -o "00000000 0000000[01]" | tail -c 2; }
if [ -z "$(active)" ]; then
	echo "boot control HAL not reachable - nothing changed"
	exit 1
fi
echo "current slot $cur -> activating slot _$name (Linux)"
service call $S 9 i32 $other >/dev/null
if [ "$(active)" != "$other" ]; then
	echo "active slot is still $(active) - not rebooting"
	exit 1
fi
echo "active slot is now _$name, rebooting"
sleep 1
reboot
