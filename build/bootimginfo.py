#!/usr/bin/env python3
"""Inspect Android boot / vendor_boot / init_boot images (header v0-v4). No deps.

  bootimginfo.py IMAGE...
"""
import struct, sys, zlib


def kernel_kind(b):
    if b[:2] == b"\x1f\x8b":
        return "gzip"
    if b[:4] == b"\x02\x21\x4c\x18" or b[:4] == b"\x04\x22\x4d\x18":
        return "lz4"
    if b[0x38:0x3c] == b"ARM\x64":
        return "Image (uncompressed arm64)"
    return b[:8].hex()


def ramdisk_kind(b):
    if not b:
        return "empty"
    for sig, n in ((b"\x1f\x8b", "gzip"), (b"\x02\x21\x4c\x18", "lz4-legacy"), (b"\x04\x22\x4d\x18", "lz4"),
                   (b"\x28\xb5\x2f\xfd", "zstd"), (b"070701", "cpio")):
        if b.startswith(sig):
            return n
    return b[:8].hex()


def fdt_ids(blob):
    """(model, msm-id, board-id) from a flattened DT, best effort."""
    out = {}
    if blob[:4] != b"\xd0\x0d\xfe\xed":
        return out
    off_struct, off_strings = struct.unpack(">II", blob[8:16])
    p = off_struct
    depth = 0
    while p < len(blob):
        tok = struct.unpack(">I", blob[p:p + 4])[0]; p += 4
        if tok == 1:
            end = blob.index(b"\0", p); p = (end + 4) & ~3; depth += 1
        elif tok == 2:
            depth -= 1
        elif tok == 3:
            ln, no = struct.unpack(">II", blob[p:p + 8]); p += 8
            name = blob[off_strings + no:blob.index(b"\0", off_strings + no)].decode()
            val = blob[p:p + ln]; p = (p + ln + 3) & ~3
            if depth == 1 and name in ("model", "qcom,msm-id", "qcom,board-id", "compatible"):
                out[name] = val.rstrip(b"\0").decode(errors="replace") if name in ("model", "compatible") \
                    else [hex(x) for x in struct.unpack(">%dI" % (ln // 4), val)]
        elif tok == 9:
            break
    return out


def dtbs(section):
    i = 0
    while True:
        j = section.find(b"\xd0\x0d\xfe\xed", i)
        if j < 0:
            return
        size = struct.unpack(">I", section[j + 4:j + 8])[0]
        if 0 < size <= len(section) - j:
            yield section[j:j + size]
            i = j + size
        else:
            i = j + 4


def pages(n, page):
    return (n + page - 1) // page * page


def boot(d, path):
    kernel_size, ramdisk_size, os_version, header_size = struct.unpack("<IIII", d[8:24])
    ver = struct.unpack("<I", d[40:44])[0]
    print(f"== {path}: boot header v{ver}")
    if ver >= 3:
        cmdline = d[44:44 + 1536].rstrip(b"\0").decode()
        page = 4096
        k = d[page:page + kernel_size]
        r = d[page + pages(kernel_size, page):][:ramdisk_size]
        sig = struct.unpack("<I", d[44 + 1536:44 + 1540])[0] if ver == 4 else 0
        print(f"   kernel {kernel_size} ({kernel_kind(k) if k else '-'}), ramdisk {ramdisk_size} ({ramdisk_kind(r)}),"
              f" os_version {os_version:#x}, sig {sig}, cmdline '{cmdline}'")
    else:
        print("   (v0-v2: see mkbootimg.py parse)")


def vendor_boot(d, path):
    ver, page, kaddr, raddr, vr_size = struct.unpack("<5I", d[8:28])
    cmdline = d[28:28 + 2048].rstrip(b"\0").decode()
    tags, name = struct.unpack("<I16s", d[2076:2096])
    hdr_size, dtb_size = struct.unpack("<II", d[2096:2104])
    dtb_addr = struct.unpack("<Q", d[2104:2112])[0]
    print(f"== {path}: vendor_boot v{ver}, page {page}, kernel_addr {kaddr:#x}, ramdisk_addr {raddr:#x}, "
          f"tags {tags:#x}, dtb_addr {dtb_addr:#x}")
    print(f"   name '{name.rstrip(chr(0).encode()).decode()}', cmdline '{cmdline}'")
    off = pages(hdr_size, page)
    vr = d[off:off + vr_size]
    off += pages(vr_size, page)
    dtb = d[off:off + dtb_size]
    off += pages(dtb_size, page)
    print(f"   vendor ramdisk total {vr_size} ({ramdisk_kind(vr)}), dtb section {dtb_size}")
    if ver >= 4:
        tbl_size, tbl_n, tbl_esz, bc_size = struct.unpack("<IIII", d[2112:2128])
        tbl = d[off:off + tbl_size]
        for i in range(tbl_n):
            e = tbl[i * tbl_esz:(i + 1) * tbl_esz]
            sz, o, typ = struct.unpack("<III", e[:12])
            nm = e[12:44].rstrip(b"\0").decode()
            print(f"   ramdisk[{i}] '{nm}' type {typ} off {o} size {sz} ({ramdisk_kind(vr[o:o + sz])})")
        print(f"   bootconfig {bc_size}")
    for i, b in enumerate(dtbs(dtb)):
        print(f"   dtb[{i}] {len(b)}B {fdt_ids(b)}")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        d = open(p, "rb").read()
        if d[:8] == b"ANDROID!":
            boot(d, p)
        elif d[:8] == b"VNDRBOOT":
            vendor_boot(d, p)
        else:
            print(f"== {p}: unknown magic {d[:8]}")
