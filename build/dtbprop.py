#!/usr/bin/env python3
"""Overwrite a root-node u32-array property of a flattened DT in place (same length only).

  dtbprop.py IN.dtb OUT.dtb qcom,board-id 0 0
"""
import struct, sys


def set_root_prop(blob, name, cells):
    blob = bytearray(blob)
    if blob[:4] != b"\xd0\x0d\xfe\xed":
        sys.exit("not a DTB")
    off_struct, off_strings = struct.unpack(">II", blob[8:16])
    p, depth = off_struct, 0
    while True:
        tok = struct.unpack(">I", blob[p:p + 4])[0]; p += 4
        if tok == 1:
            p = (blob.index(b"\0", p) + 4) & ~3; depth += 1
        elif tok == 2:
            depth -= 1
        elif tok == 3:
            ln, no = struct.unpack(">II", blob[p:p + 8]); p += 8
            pname = blob[off_strings + no:blob.index(b"\0", off_strings + no)].decode()
            if depth == 1 and pname == name:
                if ln != 4 * len(cells):
                    sys.exit(f"{name}: length {ln} != {4 * len(cells)}")
                blob[p:p + ln] = struct.pack(">%dI" % len(cells), *cells)
                return bytes(blob)
            p = (p + ln + 3) & ~3
        elif tok == 4:
            continue
        else:
            sys.exit(f"{name} not found at the root")


if __name__ == "__main__":
    src, dst, name = sys.argv[1:4]
    out = set_root_prop(open(src, "rb").read(), name, [int(x, 0) for x in sys.argv[4:]])
    open(dst, "wb").write(out)
    print(f"{dst}: {name} = <{' '.join(sys.argv[4:])}>")
