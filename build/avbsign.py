#!/usr/bin/env python3
"""Pure-Python AVB signing for TB710FU (SHA256_RSA4096, PKCS#1 v1.5). No deps.

  avbsign.py footer IMAGE PARTITION_SIZE ROLLBACK_INDEX KEY.pem [NAME]
      append hash descriptor vbmeta + AVBf footer, pad IMAGE to PARTITION_SIZE
  avbsign.py rekey STOCK_VBMETA OUT KEY.pem PARTITION[,PARTITION...]
      copy vbmeta, point the named chain descriptors at KEY's public key, re-sign with KEY
  avbsign.py refresh STOCK_VBMETA OUT KEY.pem part=IMAGE [...]
      recompute the named hash descriptors (stock salt kept) from new images, re-sign with KEY
  avbsign.py selftest KEY.pem
"""
import base64, hashlib, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # works under python -I too
import avbinfo

ALG_SHA256_RSA4096 = 2
SHA256_DIGESTINFO = bytes.fromhex("3031300d060960864801650304020105000420")


def pad(b, n):
    return b + b"\0" * (-len(b) % n)


# --- key handling -----------------------------------------------------------

def _der(buf, i):
    tag, ln = buf[i], buf[i + 1]
    i += 2
    if ln & 0x80:
        k = ln & 0x7F
        ln = int.from_bytes(buf[i:i + k], "big")
        i += k
    return tag, buf[i:i + ln], i + ln


def load_key(path):
    """RSA private key (PKCS#1 'RSA PRIVATE KEY' PEM) -> (n, e, d)."""
    pem = open(path).read()
    body = "".join(l for l in pem.splitlines() if l and not l.startswith("-----"))
    der = base64.b64decode(body)
    _, seq, _ = _der(der, 0)
    ints, i = [], 0
    while i < len(seq):
        _, v, i = _der(seq, i)
        ints.append(int.from_bytes(v, "big"))
    _, n, e, d = ints[:4]
    return n, e, d


def avb_pubkey(n):
    bits = n.bit_length()
    n0inv = (-pow(n, -1, 1 << 32)) % (1 << 32)
    rr = pow(2, 2 * bits, n)
    return struct.pack(">II", bits, n0inv) + n.to_bytes(bits // 8, "big") + rr.to_bytes(bits // 8, "big")


def rsa_sign(data, key):
    n, _, d = key
    k = n.bit_length() // 8
    t = SHA256_DIGESTINFO + hashlib.sha256(data).digest()
    em = b"\x00\x01" + b"\xff" * (k - len(t) - 3) + b"\x00" + t
    return pow(int.from_bytes(em, "big"), d, n).to_bytes(k, "big")


def rsa_verify(data, sig, n, e=65537):
    k = n.bit_length() // 8
    em = pow(int.from_bytes(sig, "big"), e, n).to_bytes(k, "big")
    return em.endswith(SHA256_DIGESTINFO + hashlib.sha256(data).digest()) and em[:2] == b"\x00\x01"


# --- vbmeta -----------------------------------------------------------------

def descriptor(tag, body):
    body = pad(body, 8)
    return struct.pack(">QQ", tag, len(body)) + body


def make_vbmeta(descriptors, key, rollback_index=0, flags=0, rollback_location=0, release=b"avbsign 1.0"):
    pk = avb_pubkey(key[0])
    aux = pad(descriptors + pk, 64)
    auth_size = 64 * ((32 + 512 + 63) // 64)
    hdr = struct.pack(
        ">4sIIQQI" + "Q" * 10 + "QII48s",
        b"AVB0", 1, 0, auth_size, len(aux), ALG_SHA256_RSA4096,
        0, 32, 32, 512,                       # hash, signature (in auth block)
        len(descriptors), len(pk), 0, 0,      # pubkey, pubkey metadata (in aux block)
        0, len(descriptors),                  # descriptors (in aux block)
        rollback_index, flags, rollback_location, release,
    )
    hdr = pad(hdr, 256)
    signed = hdr + aux
    auth = pad(hashlib.sha256(signed).digest() + rsa_sign(signed, key), 64)
    return hdr + auth + aux


def raw_descriptors(blob):
    """Split a vbmeta blob's descriptor area into (tag, body) pairs."""
    h = struct.unpack(">4sIIQQI" + "Q" * 10 + "QII48s", blob[:176])
    aux = blob[256 + h[3]:256 + h[3] + h[4]]
    out, d, end = [], h[14], h[14] + h[15]
    while d < end:
        tag, n = struct.unpack(">QQ", aux[d:d + 16])
        out.append((tag, aux[d + 16:d + 16 + n]))
        d += 16 + n
    return h, out


def refresh(stock, out, keypath, images):
    """Copy vbmeta, recompute the hash descriptors of {partition: image_path} (stock salt kept), re-sign."""
    key = load_key(keypath)
    data = open(stock, "rb").read()
    h, descs = raw_descriptors(data)
    buf, hit = b"", set()
    for tag, body in descs:
        if tag == 2:
            size, alg, nl, sl, dl, fl = struct.unpack(">Q32sIIII", body[:56])
            name = body[116:116 + nl].decode()
            if name in images:
                salt = body[116 + nl:116 + nl + sl]
                img = open(images[name], "rb").read()
                digest = hashlib.new(alg.rstrip(b"\0").decode(), salt + img).digest()
                body = struct.pack(">Q32sIIII", len(img), alg, nl, sl, len(digest), fl) + body[56:116] \
                    + name.encode() + salt + digest
                hit.add(name)
        buf += descriptor(tag, body)
    missing = set(images) - hit
    if missing:
        sys.exit(f"no hash descriptor for: {', '.join(sorted(missing))}")
    blob = make_vbmeta(buf, key, rollback_index=h[16], flags=h[17], rollback_location=h[18])
    open(out, "wb").write(blob + bytes(max(0, len(data) - len(blob))))


def rekey(stock, out, keypath, names):
    key = load_key(keypath)
    data = open(stock, "rb").read()
    h, descs = raw_descriptors(data)
    pk, hit, buf = avb_pubkey(key[0]), set(), b""
    for tag, body in descs:
        if tag == 4:
            loc, nl, pl, fl = struct.unpack(">IIII", body[:16])
            name = body[76:76 + nl].decode()
            if name in names:
                body = struct.pack(">IIII", loc, nl, len(pk), fl) + bytes(60) + name.encode() + pk
                hit.add(name)
        buf += descriptor(tag, body)
    missing = set(names) - hit
    if missing:
        sys.exit(f"no chain descriptor for: {', '.join(sorted(missing))}")
    blob = make_vbmeta(buf, key, rollback_index=h[16], flags=h[17], rollback_location=h[18])
    open(out, "wb").write(blob + bytes(max(0, len(data) - len(blob))))


def footer(image, psize, rollback_index, keypath, name="boot"):
    key = load_key(keypath)
    img = open(image, "rb").read()
    salt = os.urandom(32)
    digest = hashlib.sha256(salt + img).digest()
    hd = struct.pack(">Q32sIIII", len(img), b"sha256", len(name), 32, 32, 0) + bytes(60)
    hd += name.encode() + salt + digest
    vb = make_vbmeta(descriptor(2, hd), key, rollback_index=rollback_index)
    body = pad(img, 4096)
    foot = struct.pack(">4sIIQQQ", b"AVBf", 1, 0, len(img), len(body), len(vb)).ljust(64, b"\0")
    total = len(body) + len(pad(vb, 4096)) + 4096
    if total > psize:
        sys.exit(f"{image}: {total} B with AVB metadata > partition {psize} B")
    out = body + vb
    out += bytes(psize - 64 - len(out)) + foot
    open(image, "wb").write(out)


# --- checks -----------------------------------------------------------------

def verify(path, n):
    data = open(path, "rb").read()
    blob, orig = avbinfo.vbmeta_blob(data)
    h = struct.unpack(">4sIIQQI" + "Q" * 10 + "QII48s", blob[:176])
    auth, aux = blob[256:256 + h[3]], blob[256 + h[3]:256 + h[3] + h[4]]
    signed = blob[:256] + aux
    ok = auth[:32] == hashlib.sha256(signed).digest() and rsa_verify(signed, auth[32:32 + 512], n)
    if orig is not None:
        for tag, body in raw_descriptors(blob)[1]:
            if tag == 2:
                nl, sl, dl = struct.unpack(">III", body[40:52])
                salt = body[116 + nl:116 + nl + sl]
                ok &= hashlib.sha256(salt + data[:orig]).digest() == body[116 + nl + sl:116 + nl + sl + dl]
    return ok


def selftest(keypath):
    import tempfile
    key = load_key(keypath)
    pk = avb_pubkey(key[0])
    d = tempfile.mkdtemp()
    img = os.path.join(d, "boot.img")
    open(img, "wb").write(b"ANDROID!" + os.urandom(100000))
    footer(img, 1 << 20, 1736035200, keypath)
    v = avbinfo.parse(avbinfo.vbmeta_blob(open(img, "rb").read())[0])
    assert v["rollback_index"] == 1736035200 and v["pubkey_sha1"] == hashlib.sha1(pk).hexdigest()
    assert verify(img, key[0]), "footer signature/digest"
    stock = os.path.join(d, "vbmeta.img")
    other = bytes(8) + bytes(1032)  # fake 2048-bit-sized key blob
    ch = struct.pack(">IIII", 3, 4, len(other), 0) + bytes(60) + b"boot" + other
    open(stock, "wb").write(make_vbmeta(descriptor(4, ch), key) + bytes(4096))
    out = os.path.join(d, "vbmeta.new")
    rekey(stock, out, keypath, ["boot"])
    v = avbinfo.parse(avbinfo.vbmeta_blob(open(out, "rb").read())[0])
    assert v["descriptors"][0]["pubkey_sha1"] == hashlib.sha1(pk).hexdigest()
    assert v["descriptors"][0]["rollback_location"] == 3
    assert verify(out, key[0]), "vbmeta signature"
    print("selftest ok")


if __name__ == "__main__":
    cmd, a = sys.argv[1], sys.argv[2:]
    if cmd == "footer":
        footer(a[0], int(a[1]), int(a[2]), a[3], *(a[4:5]))
    elif cmd == "rekey":
        rekey(a[0], a[1], a[2], a[3].split(","))
    elif cmd == "refresh":   # refresh STOCK_VBMETA OUT KEY part=image [part=image...]
        refresh(a[0], a[1], a[2], dict(x.split("=", 1) for x in a[3:]))
    elif cmd == "verify":
        n = load_key(a[1])[0]
        print("OK" if verify(a[0], n) else "BAD")
    elif cmd == "selftest":
        selftest(a[0])
    else:
        sys.exit(__doc__)
