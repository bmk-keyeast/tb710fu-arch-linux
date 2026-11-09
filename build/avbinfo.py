#!/usr/bin/env python3
"""Minimal AVB inspector (vbmeta header + descriptors, footer). No deps.

  avbinfo.py IMAGE...
"""
import hashlib, struct, sys

TAGS = {0: "property", 1: "hashtree", 2: "hash", 3: "cmdline", 4: "chain"}


def vbmeta_blob(data):
    if data[:4] == b"AVB0":
        return data, None
    foot = data[-64:]
    if foot[:4] != b"AVBf":
        return None, None
    _, _, _, orig, off, size = struct.unpack(">4sIIQQQ", foot[:36])
    return data[off:off + size], orig


def parse(blob):
    h = struct.unpack(">4sIIQQI" + "Q" * 10 + "QII48s", blob[:176])
    auth, aux, alg = h[3], h[4], h[5]
    pk_off, pk_size = h[10], h[11]
    d_off, d_size = h[14], h[15]
    ri, flags, ril, rel = h[16], h[17], h[18], h[19]
    a = blob[256 + auth:256 + auth + aux]
    pk = a[pk_off:pk_off + pk_size]
    out = {
        "algorithm": alg, "rollback_index": ri, "rollback_location": ril, "flags": flags,
        "release": rel.rstrip(b"\0").decode(), "pubkey_sha1": hashlib.sha1(pk).hexdigest() if pk else "",
        "descriptors": [],
    }
    d, end = d_off, d_off + d_size
    while d < end:
        tag, n = struct.unpack(">QQ", a[d:d + 16])
        body = a[d + 16:d + 16 + n]
        e = {"type": TAGS.get(tag, tag)}
        if tag == 0:
            kl, vl = struct.unpack(">QQ", body[:16])
            e["key"] = body[16:16 + kl].decode()
            e["value"] = body[17 + kl:17 + kl + vl].decode(errors="replace")
        elif tag == 2:
            size, _, nl = struct.unpack(">Q32sI", body[:44])
            e["partition"], e["image_size"] = body[116:116 + nl].decode(), size
        elif tag == 1:
            size = struct.unpack(">Q", body[:8])[0]
            nl = struct.unpack(">I", body[84:88])[0]
            e["partition"], e["image_size"] = body[160:160 + nl].decode(), size
        elif tag == 4:
            loc, nl, pl = struct.unpack(">III", body[:12])
            e["partition"], e["rollback_location"] = body[76:76 + nl].decode(), loc
            e["pubkey_sha1"] = hashlib.sha1(body[76 + nl:76 + nl + pl]).hexdigest()
        elif tag == 3:
            l = struct.unpack(">I", body[4:8])[0]
            e["cmdline"] = body[8:8 + l].decode()
        out["descriptors"].append(e)
        d += 16 + n
    return out


def main():
    for path in sys.argv[1:]:
        data = open(path, "rb").read()
        blob, orig = vbmeta_blob(data)
        print(f"== {path}  ({len(data)} B)")
        if blob is None:
            print("   no AVB")
            continue
        if orig is not None:
            print(f"   footer: original image size {orig}")
        v = parse(blob)
        for k in ("algorithm", "rollback_index", "rollback_location", "flags", "release", "pubkey_sha1"):
            print(f"   {k}: {v[k]}")
        for e in v["descriptors"]:
            print("   -", " ".join(f"{k}={e[k]}" for k in e))


if __name__ == "__main__":
    main()
