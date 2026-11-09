#!/usr/bin/env python3
"""Android boot image header v2 writer (AOSP mkbootimg layout). No deps.

  mkbootimg.py OUT KERNEL RAMDISK DTB CMDLINE
Offsets follow device-lenovo-tb710fu deviceinfo (base 0, pagesize 4096).
"""
import hashlib, struct, sys

PAGE = 4096
BASE = 0x0
KERNEL_OFF, RAMDISK_OFF, SECOND_OFF, TAGS_OFF, DTB_OFF = 0x8000, 0x01000000, 0x0, 0x100, 0x01f00000
HEADER_V2_SIZE = 1660


def pad(b):
    return b + b"\0" * (-len(b) % PAGE)


def build(kernel, ramdisk, dtb, cmdline):
    cmd = cmdline.encode()
    if len(cmd) > 512 + 1024 - 2:
        sys.exit("cmdline too long")
    cmd, extra = cmd[:511], cmd[511:]
    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, b"", b"", dtb):   # kernel, ramdisk, second, recovery_dtbo, dtb
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))
    hdr = struct.pack(
        "<8s10I16s512s32s1024sIQIIQ",
        b"ANDROID!",
        len(kernel), BASE + KERNEL_OFF,
        len(ramdisk), BASE + RAMDISK_OFF,
        0, BASE + SECOND_OFF,
        BASE + TAGS_OFF, PAGE, 2, 0,               # tags, page size, header version, os_version
        b"", cmd, sha.digest().ljust(32, b"\0"), extra,
        0, 0, HEADER_V2_SIZE,                      # recovery dtbo size/offset, header size
        len(dtb), BASE + DTB_OFF,
    )
    assert len(hdr) == HEADER_V2_SIZE, len(hdr)
    return pad(hdr) + pad(kernel) + pad(ramdisk) + pad(dtb)


def parse(img):
    f = struct.unpack("<8s10I16s512s32s1024sIQIIQ", img[:HEADER_V2_SIZE])
    return {"magic": f[0], "kernel_size": f[1], "ramdisk_size": f[3], "page": f[8], "version": f[9],
            "cmdline": (f[12].rstrip(b"\0") + f[14].rstrip(b"\0")).decode(), "dtb_size": f[18], "dtb_addr": f[19]}


def selftest():
    k, r, d = b"K" * 5000, b"R" * 9000, b"D" * 100
    img = build(k, r, d, "root=PARTUUID=x rw")
    h = parse(img)
    assert h["magic"] == b"ANDROID!" and h["version"] == 2 and h["page"] == PAGE
    assert (h["kernel_size"], h["ramdisk_size"], h["dtb_size"]) == (5000, 9000, 100)
    assert h["dtb_addr"] == DTB_OFF and h["cmdline"] == "root=PARTUUID=x rw"
    assert img[PAGE:PAGE + 5000] == k and img[3 * PAGE:3 * PAGE + 9000] == r
    assert img[6 * PAGE:6 * PAGE + 100] == d and len(img) == 7 * PAGE
    print("selftest ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["selftest"]:
        selftest()
    else:
        out, kernel, ramdisk, dtb, cmdline = sys.argv[1:6]
        rd = lambda p: open(p, "rb").read()
        open(out, "wb").write(build(rd(kernel), rd(ramdisk), rd(dtb), cmdline))
        print(parse(open(out, "rb").read()))
