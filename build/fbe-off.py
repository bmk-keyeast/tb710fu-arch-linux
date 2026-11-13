#!/usr/bin/env python3
"""Turn off userdata encryption on the stock ROM (slot a): patch /vendor/etc/fstab.qcom, rebuild
vendor's dm-verity hashtree, put the new hashtree descriptor into vbmeta_a and re-sign it (testkey).

  fbe-off.py build STOCK_VENDOR STOCK_VBMETA_A KEY OUTDIR
      STOCK_VENDOR   = vendor_a as raw partition (the ROM's super_7.img is exactly vendor_a)
      OUTDIR gets vendor_a.img, vbmeta_a.img, SHA256SUMS (+ stock hashes for the device-side checks)
  fbe-off.py verify VBMETA VENDOR    recompute VENDOR's hashtree, compare with VBMETA's descriptor

Why in place: vendor is ext4 with shared_blocks (dedup), which e2fsprogs won't write. fstab.qcom
keeps its size: the dropped flags become a trailing comment line, so no fs metadata changes.
FEC is dropped from the descriptor (fec_num_roots 0): it would not match the new data and
dm-verity works without it.
"""
import hashlib
import mmap
import os
import re
import shutil
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import avbinfo  # noqa: E402
import avbsign  # noqa: E402

HT = ">IQQQIIIQQ32sIIII60s"  # AVB hashtree descriptor fixed part (164 bytes)
HT_SIZE = struct.calcsize(HT)
# fs_mgr flags that set up encryption, then the inlinecrypt mount option (as DFE-NEO does)
DROP = [rb",fileencryption=[^,\s]*", rb",keydirectory=[^,\s]*", rb",metadata_encryption=[^,\s]*",
        rb",inlinecrypt(?=[\s,])"]


def ht_parse(body):
    f = list(struct.unpack(HT, body[:HT_SIZE]))
    nl, sl, dl = f[10], f[11], f[12]
    o = HT_SIZE
    name = body[o:o + nl].decode()
    salt = body[o + nl:o + nl + sl]
    digest = body[o + nl + sl:o + nl + sl + dl]
    return f, name, salt, digest


def ht_pack(f, name, salt, digest):
    f = list(f)
    f[10], f[11], f[12] = len(name), len(salt), len(digest)
    return struct.pack(HT, *f) + name.encode() + salt + digest


def hashtree(path, image_size, block, alg, salt):
    """AVB/dm-verity hash tree (avbtool generate_hash_tree): returns (root digest, tree bytes)."""
    dsize = hashlib.new(alg).digest_size
    pad_d = (1 << (dsize - 1).bit_length()) - dsize
    rnd = lambda n: (n + block - 1) // block * block
    sizes, size = [], image_size
    while size > block:
        size = rnd(((size + block - 1) // block) * (dsize + pad_d))
        sizes.append(size)
    offs = [sum(sizes[n + 1:]) for n in range(len(sizes))]
    tree = bytearray(sum(sizes))
    level, src = None, None
    with open(path, "rb") as img:
        for n, lsize in enumerate(sizes):
            out = bytearray()
            if n == 0:
                left = image_size
                while left > 0:
                    chunk = img.read(min(left, 1024 * block))  # big reads: 4 KiB reads crawl on Windows
                    left -= len(chunk)
                    for i in range(0, len(chunk), block):
                        out += hashlib.new(alg, salt + chunk[i:i + block].ljust(block, b"\0")).digest() + bytes(pad_d)
            else:
                for i in range(0, len(src), block):
                    out += hashlib.new(alg, salt + src[i:i + block]).digest() + bytes(pad_d)
            out = out.ljust(rnd(len(out)), b"\0")
            tree[offs[n]:offs[n] + len(out)] = out
            src = level = bytes(out)
    return hashlib.new(alg, salt + level).digest(), bytes(tree)


def vendor_desc(blob):
    for tag, body in avbsign.raw_descriptors(blob)[1]:
        if tag == 1:
            f, name, salt, digest = ht_parse(body)
            if name == "vendor":
                return f, salt, digest
    sys.exit("no 'vendor' hashtree descriptor")


def footer_blob(path):
    with open(path, "rb") as fh:
        fh.seek(-64, 2)
        foot = fh.read(64)
        assert foot[:4] == b"AVBf", "no AVB footer"
        _, _, _, orig, off, size = struct.unpack(">4sIIQQQ", foot[:36])
        fh.seek(off)
        return orig, off, fh.read(size)


def patch_fstab(path, image_size):
    """edit the unique userdata line in place, same length; returns (offset, old, new)"""
    # anchor on a unique substring, then take its line (a line regex over 1.8 GB of binary backtracks forever)
    with open(path, "rb") as fh, mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ) as mm:
        anchor = b"keydirectory=/metadata/vold/metadata_encryption"
        at = mm.find(anchor, 0, image_size)
        if at < 0 or mm.find(anchor, at + 1, image_size) >= 0:
            sys.exit("expected exactly one encrypted /data fstab line")
        start = mm.rfind(b"\n", max(0, at - 4096), at) + 1
        end = mm.find(b"\n", at, at + 4096)
        old = bytes(mm[start:end])
    if not re.search(rb"\s/data\s+f2fs\s", old):
        sys.exit(f"anchor is not on the /data line: {old!r}")
    new = old
    for d in DROP:
        new = re.sub(d, b"", new)
    n = len(old) - len(new)
    assert n >= 2 and b"crypt" not in new, new
    new += b"\n#" + b"-" * (n - 2)  # keep the file size: dropped bytes become a comment line
    assert len(new) == len(old)
    with open(path, "r+b") as fh:
        fh.seek(start)
        fh.write(new)
    return start, old, new


def sha256(path, size=None):
    h, left = hashlib.sha256(), size
    with open(path, "rb") as fh:
        while left is None or left > 0:
            b = fh.read(1 << 20 if left is None else min(1 << 20, left))
            if not b:
                break
            h.update(b)
            if left is not None:
                left -= len(b)
    return h.hexdigest()


def build(stock_vendor, stock_vbmeta, keypath, outdir):
    os.makedirs(outdir, exist_ok=True)
    vb = open(stock_vbmeta, "rb").read()
    f, salt, root = vendor_desc(vb)
    image_size, tree_off, tree_size, block = f[1], f[2], f[3], f[4]
    alg = f[9].rstrip(b"\0").decode()
    print(f"vendor: data {image_size} B, tree @{tree_off} ({tree_size} B), {alg}, fec roots {f[6]}")

    print("checking stock hashtree ...")
    sroot, stree = hashtree(stock_vendor, image_size, block, alg, salt)
    with open(stock_vendor, "rb") as fh:
        fh.seek(tree_off)
        on_disk = fh.read(tree_size)
    if sroot != root or stree != on_disk:
        sys.exit("stock vendor does not match vbmeta_a's hashtree (wrong vendor image or tree port bug)")

    out_vendor = os.path.join(outdir, "vendor_a.img")
    print("copying vendor ...")
    shutil.copyfile(stock_vendor, out_vendor)
    off, old, new = patch_fstab(out_vendor, image_size)
    print(f"fstab.qcom /data line @{off}:\n  - {old.decode()}\n  + {new.decode()}")

    print("rebuilding hashtree ...")
    nroot, ntree = hashtree(out_vendor, image_size, block, alg, salt)
    with open(out_vendor, "r+b") as fh:
        fh.seek(tree_off)
        fh.write(ntree)
    f[6], f[7], f[8] = 0, 0, 0  # no FEC
    new_ht = ht_pack(f, "vendor", salt, nroot)

    # same descriptor in vendor's own footer vbmeta (unsigned), same size since only digest/fec change
    _, foff, fblob = footer_blob(out_vendor)
    h, descs = avbsign.raw_descriptors(fblob)
    for tag, body in descs:
        if tag == 1 and ht_parse(body)[1] == "vendor":
            i = fblob.index(body)
            fblob = fblob[:i] + new_ht.ljust(len(body), b"\0") + fblob[i + len(body):]
    with open(out_vendor, "r+b") as fh:
        fh.seek(foff)
        fh.write(fblob)

    h, descs = avbsign.raw_descriptors(vb)
    buf = b""
    for tag, body in descs:
        if tag == 1 and ht_parse(body)[1] == "vendor":
            body = new_ht
        buf += avbsign.descriptor(tag, body)
    key = avbsign.load_key(keypath)
    blob = avbsign.make_vbmeta(buf, key, rollback_index=h[16], flags=h[17], rollback_location=h[18])
    out_vb = os.path.join(outdir, "vbmeta_a.img")
    open(out_vb, "wb").write(blob + bytes(max(0, len(vb) - len(blob))))
    assert avbsign.verify(out_vb, key[0]), "vbmeta signature check failed"
    verify(out_vb, out_vendor)

    with open(os.path.join(outdir, "SHA256SUMS"), "w") as fh:
        for p in ("vendor_a.img", "vbmeta_a.img"):
            fh.write(f"{sha256(os.path.join(outdir, p))}  {p}\n")
    with open(os.path.join(outdir, "stock.sha256"), "w") as fh:  # device-side: refuse anything else
        fh.write(f"{sha256(stock_vendor)}  vendor_a\n{sha256(stock_vbmeta)}  vbmeta_a\n")
    print(f"done: {outdir}")


def verify(vbmeta, vendor):
    f, salt, root = vendor_desc(open(vbmeta, "rb").read())
    alg = f[9].rstrip(b"\0").decode()
    r, tree = hashtree(vendor, f[1], f[4], alg, salt)
    with open(vendor, "rb") as fh:
        fh.seek(f[2])
        ok = r == root and fh.read(f[3]) == tree
    print("verify:", "OK" if ok else "MISMATCH")
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["build"] and len(a) == 5:
        build(*a[1:])
    elif a[:1] == ["verify"] and len(a) == 3:
        verify(*a[1:])
    else:
        sys.exit(__doc__)
