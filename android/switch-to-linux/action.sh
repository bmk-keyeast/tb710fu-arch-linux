#!/system/bin/sh
# KernelSU/Magisk Action: switch to the other A/B slot (Linux) and reboot.
# Uses Android's own boot control HAL client; nothing is written if it is missing.
cur=$(getprop ro.boot.slot_suffix)
case "$cur" in
	_a) other=1; name=b ;;
	_b) other=0; name=a ;;
	*) echo "unknown current slot '$cur'"; exit 1 ;;
esac
if ! command -v bootctl >/dev/null 2>&1; then
	echo "bootctl not found on this ROM - switch slots from LTBox/EDL instead"
	exit 1
fi
echo "current slot $cur -> activating slot _$name (Linux)"
bootctl set-active-boot-slot "$other" || exit 1
bootctl get-active-boot-slot
sleep 1
reboot
