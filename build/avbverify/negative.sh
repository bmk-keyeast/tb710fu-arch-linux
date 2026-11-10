#!/bin/bash
# Negative controls: the harness must reject tampered images, a wrong trusted key and a rollback.
DUMP="${1:?dump dir}"
H=~/tb710fu/libavb/avbverify KEY=~/tb710fu/build/avbverify/testkey_rsa4096.avbpubkey E2=~/tb710fu/out/v4/e2
mk() { local d=$(mktemp -d); for p in boot dtbo vendor_boot init_boot vbmeta vbmeta_system recovery; do
	if [ -f $E2/${p}_b.img ]; then cp $E2/${p}_b.img $d/; else cp "$DUMP/${p}_a.img" $d/${p}_b.img; fi; done; echo $d; }
d=$(mk); printf 'flip 1 byte in vendor_boot ramdisk: '; printf '\xff' | dd of=$d/vendor_boot_b.img bs=1 seek=5000 conv=notrunc status=none; $H $d _b $KEY | head -1; rm -rf $d
d=$(mk); printf 'flip 1 byte in boot kernel:          '; printf '\xff' | dd of=$d/boot_b.img bs=1 seek=9000 conv=notrunc status=none; $H $d _b $KEY | head -1; rm -rf $d
d=$(mk); printf 'trust a different key:               '; head -c 1032 /dev/urandom > $d/k; $H $d _b $d/k | head -1; rm -rf $d
d=$(mk); printf 'boot rollback floor above image:     '; $H $d _b $KEY 0 1 1780617600 1999999999 | head -1; rm -rf $d
d=$(mk); printf 'stock v-boot_a with E2 vbmeta:       '; cp "$DUMP/vendor_boot_a.img" $d/vendor_boot_b.img; $H $d _b $KEY | head -1; rm -rf $d
