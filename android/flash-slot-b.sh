#!/system/bin/sh
# Prepare slot b from rooted Android (no EDL, no fastboot). Slot a is never written.
#
#   sh flash-slot-b.sh DIR            dry run: checks only
#   sh flash-slot-b.sh DIR --write    do it
#
# DIR holds <part>_b.img files + SHA256SUMS (build.sh v4 e1|e2). Every partition of slot b's
# AVB chain that has no file in DIR is copied from slot a, so slot b = slot a + the payload.
# The previous slot b contents are backed up to DIR/backup-slot-b before writing.
set -e
DIR="${1:?usage: flash-slot-b.sh DIR [--write]}"
WRITE="$2"
B=/dev/block/by-name
# everything ABL verifies for the slot: pvmfw is requested too (hash descriptor in vbmeta_system)
PARTS="vbmeta vbmeta_system pvmfw dtbo vendor_boot init_boot recovery boot"

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ "$(getprop ro.boot.slot_suffix)" = _a ] || { echo "current slot is not _a - refusing"; exit 1; }
cd "$DIR"
sha256sum -c SHA256SUMS || { echo "payload checksum mismatch"; exit 1; }
[ -f boot_b.img ] || { echo "no boot_b.img in $DIR"; exit 1; }

echo "plan:"
for p in $PARTS; do
	[ "$(blockdev --getsize64 $B/${p}_a)" = "$(blockdev --getsize64 $B/${p}_b)" ] ||
		{ echo "${p}_a/${p}_b size differ"; exit 1; }
	if [ -f ${p}_b.img ]; then
		[ "$(stat -c %s ${p}_b.img)" -le "$(blockdev --getsize64 $B/${p}_b)" ] ||
			{ echo "${p}_b.img larger than partition"; exit 1; }
		echo "  ${p}_b.img -> ${p}_b"
	else
		echo "  ${p}_a -> ${p}_b"
	fi
done
[ "$WRITE" = --write ] || { echo "dry run OK (add --write)"; exit 0; }

mkdir -p backup-slot-b
for p in $PARTS; do dd if=$B/${p}_b of=backup-slot-b/${p}_b.img bs=1M 2>/dev/null; done
echo "slot b backed up to $DIR/backup-slot-b"

for p in $PARTS; do
	if [ -f ${p}_b.img ]; then
		dd if=${p}_b.img of=$B/${p}_b bs=1M conv=fsync 2>/dev/null
		cmp -n "$(stat -c %s ${p}_b.img)" ${p}_b.img $B/${p}_b || { echo "verify failed: ${p}_b"; exit 1; }
	else
		dd if=$B/${p}_a of=$B/${p}_b bs=1M conv=fsync 2>/dev/null
		cmp $B/${p}_a $B/${p}_b || { echo "verify failed: ${p}_b"; exit 1; }
	fi
	echo "ok ${p}_b"
done
sync
echo "done. slot b is ready; slot a is untouched and still active."
