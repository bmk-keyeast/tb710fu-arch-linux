#!/usr/bin/env python3
"""Classify a pulled tb710fu-bootlog dir: did the mainline kernel run on slot b, and how far did it get?

  bootlog.py DIR
"""
import glob, os, re, sys

MARKERS = [  # (regex, meaning) in boot order; the last one seen is how far the boot got
    (r"Linux version 7\.", "mainline kernel started"),
    (r"Kernel command line:.*tb710fu\.wait", "mainline cmdline seen"),
    (r"Unpacking initramfs|Freeing initrd memory", "initramfs unpacked"),
    (r"Run /init as init process", "initramfs /init started"),
    (r"tb710fu: waiting up to", "fallback hook waiting for root SSD"),
    (r"tb710fu: root PARTUUID=.* not found", "root SSD not found -> switched to slot a"),
    (r"EXT4-fs \(sd[a-z]\d*\): mounted", "root filesystem mounted"),
    (r"systemd\[1\]: .*(Reached target|Started)", "systemd running"),
]
BAD = r"Kernel panic|Unable to handle|Internal error|BUG:|Oops|Initramfs unpacking failed|VFS: Unable"


def main(d):
    state = open(os.path.join(d, "state.txt"), errors="replace").read() if os.path.exists(os.path.join(d, "state.txt")) else ""
    print(state.strip())
    logs = sorted(glob.glob(os.path.join(d, "console-ramoops*")) + glob.glob(os.path.join(d, "dmesg-ramoops*")))
    if not logs:
        print("no ramoops files")
        return
    for f in logs:
        t = open(f, "rb").read().decode(errors="replace")
        ver = re.search(r"Linux version (\S+)", t)
        print(f"== {os.path.basename(f)}: kernel {ver.group(1) if ver else '?'}")
        if not ver or not ver.group(1).startswith("7."):
            if "tb710fu.e1big=1" in t:
                print("   E1big: stock kernel ran from slot b with the 64 MiB vendor ramdisk -> ABL loads big vendor ramdisks")
            elif "tb710fu-e1" in t:
                print("   E1: stock kernel ran from slot b -> slot b firmware chain + signing accepted by ABL")
            else:
                print("   stock Android log only -> no slot-b kernel ran: ABL rejected or did not load slot b")
            for line in t.splitlines():
                if re.search(r"Kernel command line|No working init|Kernel panic", line):
                    print("   " + line.strip()[:160])
            continue
        last = None
        for rx, meaning in MARKERS:
            if re.search(rx, t):
                last = meaning
                print(f"   + {meaning}")
        for line in t.splitlines():
            if re.search(BAD, line):
                print(f"   ! {line.strip()[:160]}")
        print(f"   furthest: {last}")
        print("   --- last 15 lines ---")
        for line in t.splitlines()[-15:]:
            print("   " + line[:160])


if __name__ == "__main__":
    main(sys.argv[1])
