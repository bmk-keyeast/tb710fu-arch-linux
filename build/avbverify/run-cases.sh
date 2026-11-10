#!/bin/bash
# Assemble each candidate slot from dumps/payloads and run real libavb avb_slot_verify on it.
#   run-cases.sh DUMP_DIR      (DUMP_DIR has the stock *_a.img read from the device)
set -u
DUMP="${1:?dump dir with *_a.img}"
H=~/tb710fu/libavb/avbverify KEY=~/tb710fu/build/avbverify/testkey_rsa4096.avbpubkey
OUT=~/tb710fu/out
PARTS="boot dtbo vendor_boot init_boot vbmeta vbmeta_system recovery"
# rollback floors as slot a currently carries them: loc0 vbmeta 0, loc1 recovery 1,
# loc2 vbmeta_system 1780617600, loc3 boot 1736035200
FLOORS="0 1 1780617600 1736035200"

slot() {  # slot NAME PAYLOAD_DIR_OR_- [boot override file]
	local name=$1 payload=$2 boot=${3:-} d=$(mktemp -d)
	for p in $PARTS; do
		if [ -n "$boot" ] && [ $p = boot ]; then ln -s "$boot" $d/${p}_b.img
		elif [ "$payload" != - ] && [ -f "$payload/${p}_b.img" ]; then ln -s "$payload/${p}_b.img" $d/${p}_b.img
		else ln -s "$DUMP/${p}_a.img" $d/${p}_b.img; fi
	done
	for fl in "" "$FLOORS"; do
		printf '%-34s floors=%-28s ' "$name" "${fl:-0}"
		$H $d _b $KEY $fl | head -1
	done
	[ -n "${VERBOSE:-}" ] && $H $d _b $KEY $FLOORS | tail -n +2
	rm -rf $d
}

printf '%-34s floors=%-28s ' "stock slot a (control)" "$FLOORS"; $H "$DUMP" _a $KEY $FLOORS | head -1
slot "v2 boot (rejected 11-10)" - "$OUT/../out/boot-signed.img"
slot "E1 stock kernel baseline" $OUT/v4/e1
VERBOSE=1 slot "E2 mainline v4" $OUT/v4/e2
slot "E3 mainline v4 + empty dtbo" $OUT/v4/e3
