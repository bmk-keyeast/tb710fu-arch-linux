#!/bin/bash
# Replace one file inside the root ext4 of a disk image (partition 1 at 1 MiB), no mount, no sudo.
# Keeps root:root and the given mode; e2fsck must stay clean.
#   imgpatch.sh DISK.img /usr/bin/tb710fu-firstboot SRC_FILE [MODE_OCTAL=0755]
set -euo pipefail
IMG=$1 DEST=$2 SRC=$3 MODE=${4:-0755}
FS="$IMG?offset=1048576"
dir=$(dirname "$DEST") name=$(basename "$DEST")
debugfs -w -f - "$FS" >/dev/null <<EOF
cd $dir
rm $name
write $SRC $name
sif $name uid 0
sif $name gid 0
sif $name mode 0100${MODE#0}
EOF
debugfs -R "cat $DEST" "$FS" 2>/dev/null | cmp - "$SRC"
debugfs -R "stat $DEST" "$FS" 2>/dev/null | grep -E "Mode:|User:" | tr -s ' '
e2fsck -fn "$FS" >/dev/null && echo "e2fsck clean: $DEST"
