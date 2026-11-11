#!/usr/bin/env python3
"""Copy the in-use blocks of an ext4 partition on a raw disk into a sparse image (Windows, admin).
For when WSL cannot attach the disk: read/modify the image with debugfs in WSL instead.

  ext4grab.py \\\\.\\PhysicalDrive1 PARTNO OUT.img     sparse image (NTFS: 64 KiB allocation units!)
  ext4grab.py \\\\.\\PhysicalDrive1 PARTNO OUT.pack    used blocks back to back + (offset, length)
  ext4grab.py unpack OUT.pack IMG                     pack -> sparse image (run in WSL, 4 KiB holes)
Unused blocks are left as holes (zeros). Scattered 4 KiB blocks cost 64 KiB each in an NTFS sparse
file, so use .pack on Windows and unpack it on a Linux filesystem.
"""
import os, struct, subprocess, sys

CHUNK = 4 << 20


def gpt_part(f, n):
    for ss in (512, 4096):
        f.seek(ss); h = f.read(ss)
        if h[:8] == b"EFI PART":
            lba, cnt, esz = struct.unpack("<QII", h[72:88])
            f.seek(lba * ss); e = f.read(-(-cnt * esz // ss) * ss)[(n - 1) * esz:n * esz]
            first, last = struct.unpack("<QQ", e[32:48])
            return first * ss, (last - first + 1) * ss
    sys.exit("no GPT")


def used_ranges(f, base):
    f.seek(base + 1024 - 1024); sb = f.read(4096)[1024:2048]
    if struct.unpack("<H", sb[56:58])[0] != 0xEF53:
        sys.exit("not ext4")
    blocks = struct.unpack("<I", sb[4:8])[0] | (struct.unpack("<I", sb[0x150:0x154])[0] << 32)
    bs = 1024 << struct.unpack("<I", sb[24:28])[0]
    per_group = struct.unpack("<I", sb[32:36])[0]
    first_data = struct.unpack("<I", sb[20:24])[0]
    incompat = struct.unpack("<I", sb[96:100])[0]
    dsz = struct.unpack("<H", sb[0xFE:0x100])[0] if incompat & 0x80 else 32
    ngroups = -(-(blocks - first_data) // per_group)
    gdt_off = base + (first_data + 1) * bs
    f.seek(gdt_off - gdt_off % 4096); raw = f.read(-(-(gdt_off % 4096 + ngroups * dsz) // 4096) * 4096)
    gdt = raw[gdt_off % 4096:]
    ranges = []
    for g in range(ngroups):
        d = gdt[g * dsz:(g + 1) * dsz]
        bb = struct.unpack("<I", d[0:4])[0] | ((struct.unpack("<I", d[32:36])[0] << 32) if dsz >= 64 else 0)
        flags = struct.unpack("<H", d[18:20])[0]
        start = first_data + g * per_group
        n = min(per_group, blocks - start)
        if flags & 0x2:                     # BLOCK_UNINIT: bitmap never written; only metadata there
            ranges.append((start, min(n, 64))); continue
        f.seek(base + bb * bs); bm = f.read(bs)
        run = None
        for i in range(n):
            if bm[i >> 3] >> (i & 7) & 1:
                run = run or [start + i, 0]; run[1] += 1
            elif run:
                ranges.append(tuple(run)); run = None
        if run: ranges.append(tuple(run))
    return bs, blocks, ranges


def main(disk, partno, out):
    with open(disk, "rb", buffering=0) as f:
        base, size = gpt_part(f, int(partno))
        bs, blocks, ranges = used_ranges(f, base)
        used = sum(n for _, n in ranges) * bs
        print(f"partition {partno}: offset {base}, {size >> 20} MiB, block {bs}, in use {used >> 20} MiB")
        pack = out.endswith(".pack")
        open(out, "wb").close()
        if os.name == "nt" and not pack:
            subprocess.run(["fsutil", "sparse", "setflag", out], check=True, stdout=subprocess.DEVNULL)
        with open(out, "r+b") as o:
            if pack:
                o.write(struct.pack("<Q", blocks * bs))
            else:
                o.truncate(blocks * bs)
            done = 0
            for s, n in ranges:
                off, left = s * bs, n * bs
                if pack:
                    o.write(struct.pack("<QQ", off, left))
                while left:
                    k = min(CHUNK, left)
                    f.seek(base + off)
                    if not pack:
                        o.seek(off)
                    o.write(f.read(k))
                    off += k; left -= k; done += k
                print(f"\r{done >> 20} / {used >> 20} MiB", end="", flush=True)
    print(f"\n{out} done")


def unpack(pack, img):
    with open(pack, "rb") as p, open(img, "wb") as o:
        o.truncate(struct.unpack("<Q", p.read(8))[0])
        while h := p.read(16):
            off, n = struct.unpack("<QQ", h)
            o.seek(off)
            while n:
                k = min(CHUNK, n); o.write(p.read(k)); n -= k
    print(f"{img} done")


if __name__ == "__main__":
    unpack(*sys.argv[2:4]) if sys.argv[1] == "unpack" else main(*sys.argv[1:4])
