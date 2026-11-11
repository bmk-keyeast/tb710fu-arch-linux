#!/usr/bin/env python3
"""Check a DTB for the node paths Qualcomm ABL's UpdateDeviceTree() looks up (libfdt rules:
'name' also matches 'name@unit').  Exit 1 if a path whose absence aborts the boot is missing.

  dtcheck.py DTB
"""
import struct, sys

# from QcomModulePkg/Library/BootLib/UpdateDeviceTree.c: missing -> EFI_NOT_FOUND -> BootLinux fails
FATAL = ["/", "/memory", "/chosen", "/reserved-memory",
         "/soc/cache-controller"]           # LLCC: ABL appends qcom,sct-config (SCT-capable DDR)
# looked up but only warned about
OPTIONAL = ["/soc/disp_rdump_region", "/reserved-memory/splash_region", "/mem-offline", "/ddr-regions"]


def nodes(blob):
    off_struct = struct.unpack(">I", blob[8:12])[0]
    p, stack, out = off_struct, [], set()
    while True:
        tok = struct.unpack(">I", blob[p:p + 4])[0]; p += 4
        if tok == 1:
            e = blob.index(b"\0", p)
            stack.append(blob[p:e].decode()); p = (e + 4) & ~3
            out.add(tuple(stack[1:]))
        elif tok == 2:
            stack.pop()
        elif tok == 3:
            ln = struct.unpack(">I", blob[p:p + 4])[0]; p = (p + 8 + ln + 3) & ~3
        elif tok == 4:
            continue
        else:
            return out


def has(tree, path):
    cur = ()
    for c in [c for c in path.split("/") if c]:
        hit = [n for n in tree if len(n) == len(cur) + 1 and n[:-1] == cur
               and (n[-1] == c or ("@" not in c and n[-1].split("@")[0] == c))]
        if not hit:
            return False
        cur = hit[0]
    return True


def main(path):
    tree = nodes(open(path, "rb").read())
    ok = True
    for p in FATAL + OPTIONAL:
        present = has(tree, p)
        if not present and p in FATAL:
            ok = False
        print(f"  {'ok  ' if present else ('MISSING' if p in FATAL else 'absent')} {p}")
    return ok


if __name__ == "__main__":
    sys.exit(0 if main(sys.argv[1]) else 1)
