#!/usr/bin/env python3
"""Check a slot's vbmeta hash descriptors against that slot's partition dumps.

  avbcheck.py DUMP_DIR SLOT        (expects vbmeta_<slot>.img, <part>_<slot>.img)
Prints MATCH / MISMATCH per hash descriptor, the way libavb would verify it.
"""
import hashlib, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import avbinfo, avbsign


def hash_descs(blob):
    for tag, body in avbsign.raw_descriptors(blob)[1]:
        if tag != 2:
            continue
        size, alg, nl, sl, dl = struct.unpack(">Q32sIII", body[:52])
        name = body[116:116 + nl].decode()
        salt = body[116 + nl:116 + nl + sl]
        digest = body[116 + nl + sl:116 + nl + sl + dl]
        yield name, size, alg.rstrip(b"\0").decode(), salt, digest


def check(dump, slot):
    vb = open(os.path.join(dump, f"vbmeta_{slot}.img"), "rb").read()
    ok = True
    for name, size, alg, salt, digest in hash_descs(vb):
        path = os.path.join(dump, f"{name}_{slot}.img")
        if not os.path.exists(path):
            print(f"  {name:12} (no dump)")
            continue
        data = open(path, "rb").read()[:size]
        h = hashlib.new(alg, salt + data).digest()
        good = h == digest
        ok &= good
        print(f"  {name:12} {'MATCH' if good else 'MISMATCH'}  (descriptor size {size})")
    return ok


if __name__ == "__main__":
    dump, slot = sys.argv[1], sys.argv[2]
    print(f"slot {slot}:")
    sys.exit(0 if check(dump, slot) else 1)
