#!/usr/bin/env python3
"""Build GKI-style header v4 boot / init_boot / vendor_boot images from the stock ones. No deps.

The stock images are used as templates so every header field ABL looks at (addresses, page size,
os_version, vendor cmdline, bootconfig, ramdisk table) stays exactly as Lenovo shipped it;
only the payloads are swapped.

  bootv4.py boot        STOCK_BOOT OUT [--kernel F] [--cmdline S]
  bootv4.py init_boot   STOCK_INIT_BOOT OUT --ramdisk F          (use 'empty' for an empty cpio)
  bootv4.py vendor_boot STOCK_VENDOR_BOOT OUT [--ramdisk F] [--dtb F] [--overlay DEST=SRC ...]
      --overlay appends a root-owned cpio after the ramdisk; the kernel unpacks it last, so DEST
      (e.g. hooks/tb710fu-fallback) replaces the same path from the ramdisk
  bootv4.py selftest    DUMP_DIR      (rebuild stock a-slot images from their own parts, compare)
Output is the bare image (no AVB footer, no padding); sign/footer with avbsign.py.
"""
import argparse, os, struct, sys

PAGE = 4096


def pad(b, n=PAGE):
    return b + b"\0" * (-len(b) % n)


def strip_footer(d):
    """Image bytes without AVB footer/padding (original_image_size from the footer)."""
    if d[-64:-60] == b"AVBf":
        return d[:struct.unpack(">Q", d[-64 + 12:-64 + 20])[0]]
    return d


def newc(entries):
    """Uncompressed newc cpio of (path, mode, data) owned by root, with trailer, padded to 512."""
    out = b""
    for ino, (name, mode, data) in enumerate(list(entries) + [("TRAILER!!!", 0, b"")], 1):
        nm = name.encode() + b"\0"
        fields = (ino if name != "TRAILER!!!" else 0, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nm), 0)
        hdr = b"070701" + b"".join(b"%08X" % f for f in fields)
        out += pad(hdr + nm, 4) + pad(data, 4)
    return pad(out, 512)


EMPTY_CPIO = newc([])

# ---------------------------------------------------------------- boot / init_boot (v4)


def parse_boot(d):
    kernel_size, ramdisk_size, os_version, header_size = struct.unpack("<IIII", d[8:24])
    ver = struct.unpack("<I", d[40:44])[0]
    if d[:8] != b"ANDROID!" or ver != 4:
        sys.exit("not a boot header v4 image")
    cmdline = d[44:44 + 1536]
    sig_size = struct.unpack("<I", d[1580:1584])[0]
    o = PAGE
    kernel = d[o:o + kernel_size]; o += len(pad(kernel)) if kernel_size else 0
    ramdisk = d[o:o + ramdisk_size]; o += len(pad(ramdisk)) if ramdisk_size else 0
    sig = d[o:o + sig_size]
    return dict(os_version=os_version, header_size=header_size, cmdline=cmdline, kernel=kernel,
                ramdisk=ramdisk, sig=sig)


def build_boot(t, kernel=None, ramdisk=None, cmdline=None):
    kernel = t["kernel"] if kernel is None else kernel
    ramdisk = t["ramdisk"] if ramdisk is None else ramdisk
    cmd = t["cmdline"] if cmdline is None else cmdline.encode().ljust(1536, b"\0")
    if len(cmd) > 1536:
        sys.exit("cmdline too long")
    sig = t["sig"] if (kernel is t["kernel"] and ramdisk is t["ramdisk"]) else b""
    hdr = struct.pack("<8sIIII4I I", b"ANDROID!", len(kernel), len(ramdisk), t["os_version"],
                      t["header_size"], 0, 0, 0, 0, 4) + cmd + struct.pack("<I", len(sig))
    out = pad(hdr)
    for blob in (kernel, ramdisk, sig):
        if blob:
            out += pad(blob)
    return out

# ---------------------------------------------------------------- vendor_boot (v4)


def parse_vendor(d):
    if d[:8] != b"VNDRBOOT":
        sys.exit("not a vendor_boot image")
    ver, page, kaddr, raddr, vr_size = struct.unpack("<5I", d[8:28])
    if ver != 4 or page != PAGE:
        sys.exit(f"unsupported vendor_boot v{ver} page {page}")
    head = d[:2112]                       # fixed v3 part, sizes patched later
    hdr_size, dtb_size = struct.unpack("<II", d[2096:2104])
    tbl_size, tbl_n, tbl_esz, bc_size = struct.unpack("<IIII", d[2112:2128])
    o = len(pad(d[:hdr_size]))
    vr = d[o:o + vr_size]; o += len(pad(vr))
    dtb = d[o:o + dtb_size]; o += len(pad(dtb))
    tbl = d[o:o + tbl_size]; o += len(pad(tbl))
    bc = d[o:o + bc_size]
    entries = [tbl[i * tbl_esz:(i + 1) * tbl_esz] for i in range(tbl_n)]
    return dict(head=head, hdr_size=hdr_size, vr=vr, dtb=dtb, entries=entries, esz=tbl_esz, bc=bc)


def build_vendor(t, ramdisk=None, dtb=None):
    if ramdisk is None:
        vr, entries = t["vr"], t["entries"]
    else:
        # one platform ramdisk entry, keeping the stock entry's type/name/board_id fields
        e0 = t["entries"][0]
        vr = ramdisk
        entries = [struct.pack("<II", len(ramdisk), 0) + e0[8:]]
    dtb = t["dtb"] if dtb is None else dtb
    tbl = b"".join(entries)
    head = bytearray(t["head"])
    struct.pack_into("<I", head, 24, len(vr))          # vendor_ramdisk_size
    struct.pack_into("<I", head, 2100, len(dtb))       # dtb_size
    tail = struct.pack("<IIII", len(tbl), len(entries), t["esz"], len(t["bc"]))
    hdr = bytes(head) + tail
    hdr = hdr.ljust(t["hdr_size"], b"\0")
    return pad(hdr) + pad(vr) + pad(dtb) + pad(tbl) + pad(t["bc"])

# ---------------------------------------------------------------- self test


def selftest(dump):
    rd = lambda n: strip_footer(open(os.path.join(dump, n), "rb").read())
    ok = True
    for name in ("boot_a.img", "init_boot_a.img"):
        d = rd(name)
        r = build_boot(parse_boot(d))
        # stock GKI boot carries an extra, header-undeclared certificate blob after the kernel
        same = d[:len(r)] == r
        ok &= same
        extra = len(d) - len(r)
        print(f"{name:20} round-trip {'identical' if same else 'DIFFERENT'}"
              + (f" (+{extra} B undeclared trailer: {d[len(r):len(r)+4]})" if extra else ""))
    d = rd("vendor_boot_a.img")
    t = parse_vendor(d)
    same = build_vendor(t) == d
    ok &= same
    print(f"{'vendor_boot_a.img':20} round-trip {'identical' if same else 'DIFFERENT'}")
    # swapping payloads keeps the header otherwise intact
    v2 = build_vendor(t, ramdisk=EMPTY_CPIO, dtb=b"\xd0\x0d\xfe\xed" + b"\0" * 60)
    p2 = parse_vendor(v2)
    b2 = parse_boot(build_boot(parse_boot(rd("boot_a.img")), kernel=b"K" * 5000, cmdline="x=1"))
    checks = {
        "vendor ramdisk swapped": p2["vr"] == EMPTY_CPIO,
        "vendor header kept": p2["head"][28:2096] == t["head"][28:2096],
        "vendor bootconfig kept": p2["bc"] == t["bc"],
        "vendor one table entry": len(p2["entries"]) == 1,
        "boot kernel swapped": b2["kernel"] == b"K" * 5000,
        "boot cmdline set": b2["cmdline"].rstrip(b"\0") == b"x=1",
    }
    for k, v in checks.items():
        print(f"  {k:24} {'ok' if v else 'FAILED'}")
    ok &= all(checks.values())
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kind", choices=["boot", "init_boot", "vendor_boot", "selftest"])
    ap.add_argument("stock")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--kernel"); ap.add_argument("--cmdline"); ap.add_argument("--ramdisk"); ap.add_argument("--dtb")
    ap.add_argument("--overlay", action="append", default=[])
    a = ap.parse_args()
    if a.kind == "selftest":
        sys.exit(0 if selftest(a.stock) else 1)
    rd = lambda p: open(p, "rb").read()
    stock = strip_footer(rd(a.stock))
    ramdisk = None if a.ramdisk is None else (EMPTY_CPIO if a.ramdisk == "empty" else rd(a.ramdisk))
    if a.kind in ("boot", "init_boot"):
        img = build_boot(parse_boot(stock), kernel=None if a.kernel is None else rd(a.kernel),
                         ramdisk=ramdisk, cmdline=a.cmdline)
    else:
        if a.overlay:
            # the kernel only recognises an appended raw cpio at a 4-byte aligned offset;
            # zero padding between archives is skipped
            ramdisk = pad(ramdisk if ramdisk is not None else parse_vendor(stock)["vr"], 512) + newc(
                (dest, 0o100755, rd(src)) for dest, src in (o.split("=", 1) for o in a.overlay))
        img = build_vendor(parse_vendor(stock), ramdisk=ramdisk, dtb=None if a.dtb is None else rd(a.dtb))
    open(a.out, "wb").write(img)
    print(f"{a.out}: {len(img)} bytes")


if __name__ == "__main__":
    main()
