#!/bin/bash
# Boot the slot-b payload's kernel + ramdisks under QEMU virt (generic arm64 parts only: no Qualcomm
# hardware) to check what doesn't need the tablet: ABL-style initrd concatenation + bootconfig,
# initramfs, fallback hook, root by PARTUUID, systemd, first-boot partitioning.
#
#   qemu-test.sh nodisk|disk [PAYLOAD_DIR]    log -> out/qemu/<case>.log
set -u
CASE=${1:?nodisk|disk}
P=${2:-$HOME/tb710fu/out/v4/e2}
T=$HOME/tb710fu; Q=$T/qemu/root; W=$T/out/qemu; mkdir -p $W
export LD_LIBRARY_PATH=$Q/usr/lib/x86_64-linux-gnu

# initrd exactly as ABL builds it for v4: vendor ramdisk + generic (init_boot) ramdisk + bootconfig
python3 -I - "$P" "$W/initrd" <<'EOF'
import struct, sys
sys.path.insert(0, sys.argv[0] and __import__("os").path.expanduser("~/tb710fu/build"))
import bootv4
p, out = sys.argv[1], sys.argv[2]
v = bootv4.parse_vendor(bootv4.strip_footer(open(p + "/vendor_boot_b.img", "rb").read()))
g = bootv4.parse_boot(bootv4.strip_footer(open(p + "/init_boot_b.img", "rb").read()))
# ABL adds its own androidboot.* params to the vendor bootconfig
bc = v["bc"].rstrip(b"\0") + b"androidboot.slot_suffix=_b\nandroidboot.verifiedbootstate=green\n"
trailer = bc + struct.pack("<II", len(bc), sum(bc) & 0xffffffff) + b"#BOOTCONFIG\n"
open(out, "wb").write(v["vr"] + g["ramdisk"] + trailer)
print("initrd:", len(v["vr"]), "+", len(g["ramdisk"]), "+ bootconfig", len(bc))
EOF

CMD=$(python3 -I -c "import sys; sys.path.insert(0,'$T/build'); import bootv4
b=bootv4.parse_boot(bootv4.strip_footer(open('$P/boot_b.img','rb').read()))
v=bootv4.parse_vendor(bootv4.strip_footer(open('$P/vendor_boot_b.img','rb').read()))
print((b['cmdline'].rstrip(b'\0')+b' '+v['head'][28:2076].rstrip(b'\0')).decode())")
CMD="$CMD console=ttyAMA0 tb710fu.wait=8"
python3 -I -c "import sys; sys.path.insert(0,'$T/build'); import bootv4
open('$W/Image','wb').write(bootv4.parse_boot(bootv4.strip_footer(open('$P/boot_b.img','rb').read()))['kernel'])"

DISK=()
if [ "$CASE" = disk ]; then
	D=${DISK_IMG:-$W/disk.img}
	[ -f $D ] || { xz -dc $T/out/tb710fu-ssd.img.xz > $D; truncate -s 31G $D; }
	DISK=(-drive file=$D,format=raw,if=virtio)
fi
echo "cmdline: $CMD"
timeout ${TIMEOUT:-1500} $Q/usr/bin/qemu-system-aarch64 -M virt -cpu max -smp 4 -m 3072 -nographic \
	-L $Q/usr/share/qemu -kernel $W/Image -initrd $W/initrd -append "$CMD" "${DISK[@]}" \
	> $W/$CASE.log 2>&1
echo "exit $? -> $W/$CASE.log"
