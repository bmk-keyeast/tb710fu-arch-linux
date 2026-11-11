#!/usr/bin/env python3
"""Unpack a Qualcomm ABL partition: ELF -> LZMA-compressed UEFI FV -> PE32 images (LinuxLoader etc.).

  ablunpack.py ABL.img OUTDIR
Writes OUTDIR/fv.bin (decompressed volume) and OUTDIR/pe<N>_<name>.efi for every PE32 found,
and prints the AVB RSA public keys embedded in them (sha1 of the AVB key blob, as LTBox reports).
"""
import hashlib, lzma, os, re, struct, sys

LZMA_OFFSET = 0x1078            # same offset LTBox's abl_key.rs uses


def decompress(raw):
    stream = raw[LZMA_OFFSET:]
    return lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(stream)


def pe_images(fv):
    for m in re.finditer(rb"MZ", fv):
        o = m.start()
        if o + 0x40 > len(fv):
            continue
        pe = struct.unpack("<I", fv[o + 0x3c:o + 0x40])[0]
        if fv[o + pe:o + pe + 4] != b"PE\0\0":
            continue
        nsec = struct.unpack("<H", fv[o + pe + 6:o + pe + 8])[0]
        opt = struct.unpack("<H", fv[o + pe + 20:o + pe + 22])[0]
        sh = o + pe + 24 + opt
        end = 0
        for i in range(nsec):
            s = fv[sh + i * 40:sh + (i + 1) * 40]
            rsz, rptr = struct.unpack("<II", s[16:24])
            end = max(end, rptr + rsz)
        yield o, fv[o:o + end]


def avb_keys(blob):
    """AVB public key blobs: be32 bits, be32 n0inv, modulus, rr with rr == 2^(2*bits) mod n."""
    keys = []
    for bits in (2048, 4096, 8192):
        hdr = struct.pack(">I", bits)
        k = bits // 8
        for m in re.finditer(re.escape(hdr), blob):
            o = m.start()
            if o + 8 + 2 * k > len(blob):
                continue
            n = int.from_bytes(blob[o + 8:o + 8 + k], "big")
            rr = int.from_bytes(blob[o + 8 + k:o + 8 + 2 * k], "big")
            if n.bit_length() != bits or n % 2 == 0:
                continue
            if pow(2, 2 * bits, n) != rr:
                continue
            n0inv = struct.unpack(">I", blob[o + 4:o + 8])[0]
            if (n0inv * n) % (1 << 32) != (1 << 32) - 1:
                continue
            kb = blob[o:o + 8 + 2 * k]
            keys.append((o, bits, hashlib.sha1(kb).hexdigest()))
    return keys


def pe_name(pe):
    m = re.search(rb"([A-Za-z0-9_]+)\.dll\0", pe) or re.search(rb"/([A-Za-z0-9_]+)\.(?:debug|pdb)\0", pe)
    return m.group(1).decode() if m else "unknown"


def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    fv = decompress(open(src, "rb").read())
    open(os.path.join(out, "fv.bin"), "wb").write(fv)
    print(f"{src}: decompressed FV {len(fv)} bytes")
    for i, (o, pe) in enumerate(pe_images(fv)):
        name = pe_name(pe)
        open(os.path.join(out, f"pe{i}_{name}.efi"), "wb").write(pe)
        print(f"  pe{i} @ {o:#x} {len(pe)} B  {name}  sha256 {hashlib.sha256(pe).hexdigest()[:16]}")
        for ko, bits, sha1 in avb_keys(pe):
            print(f"     AVB key RSA{bits} @ {ko:#x}  sha1 {sha1}")


if __name__ == "__main__":
    main()
