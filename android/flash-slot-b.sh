#!/system/bin/sh
# Prepare slot b for Linux from rooted Android (no EDL, no fastboot). Slot a is never written.
#
#   sh flash-slot-b.sh DIR            dry run: checks only
#   sh flash-slot-b.sh DIR --write    do it
#
# DIR holds boot-signed.img + SHA256SUMS (from build.sh sign, signed against slot a's vbmeta).
# Slot b's AVB chain is made identical to slot a's (known to boot, same rollback indices),
# then boot_b gets the Linux image. Slot b's own leftovers (059 ROW / PRC mix) fail AVB today.
set -e
DIR="${1:?usage: flash-slot-b.sh DIR [--write]}"
WRITE="$2"
B=/dev/block/by-name
COPY="vbmeta vbmeta_system dtbo vendor_boot init_boot recovery"

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ "$(getprop ro.boot.slot_suffix)" = _a ] || { echo "current slot is not _a - refusing"; exit 1; }
cd "$DIR"
sha256sum -c SHA256SUMS || { echo "payload checksum mismatch"; exit 1; }
for p in $COPY boot; do
	[ "$(blockdev --getsize64 $B/${p}_a)" = "$(blockdev --getsize64 $B/${p}_b)" ] ||
		{ echo "${p}_a/${p}_b size differ"; exit 1; }
done
[ "$(stat -c %s boot-signed.img)" = "$(blockdev --getsize64 $B/boot_b)" ] ||
	{ echo "boot-signed.img size != boot_b"; exit 1; }

echo "plan:"
for p in $COPY; do echo "  ${p}_a -> ${p}_b"; done
echo "  boot-signed.img -> boot_b"
[ "$WRITE" = --write ] || { echo "dry run OK (add --write)"; exit 0; }

mkdir -p backup-slot-b
for p in $COPY boot; do dd if=$B/${p}_b of=backup-slot-b/${p}_b.img bs=1M 2>/dev/null; done
echo "slot b backed up to $DIR/backup-slot-b"

for p in $COPY; do
	dd if=$B/${p}_a of=$B/${p}_b bs=1M conv=fsync 2>/dev/null
	cmp $B/${p}_a $B/${p}_b || { echo "verify failed: ${p}_b"; exit 1; }
	echo "ok ${p}_b"
done
dd if=boot-signed.img of=$B/boot_b bs=1M conv=fsync 2>/dev/null
cmp boot-signed.img $B/boot_b || { echo "verify failed: boot_b"; exit 1; }
echo "ok boot_b"
sync
echo "done. slot b is ready; slot a is untouched and still active."
echo "switch with the KernelSU 'Reboot to Linux' action (bootctl set-active-boot-slot 1)."
