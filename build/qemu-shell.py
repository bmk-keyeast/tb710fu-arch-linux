#!/usr/bin/env python3
"""Drive a root shell inside QEMU (init=/usr/bin/bash) over a unix-socket serial console.

  qemu-shell.py DISK.img CMDFILE [TIMEOUT]
Boots out/qemu/Image + out/qemu/initrd (made by qemu-test.sh) with DISK as virtio root, waits for
the shell, runs each line of CMDFILE, prints everything, powers off.
"""
import os, socket, subprocess, sys, time

T = os.path.expanduser("~/tb710fu")
Q = T + "/qemu/root"
W = T + "/out/qemu"
disk, cmdfile = sys.argv[1], sys.argv[2]
timeout = int(sys.argv[3]) if len(sys.argv) > 3 else 900
sock = W + "/serial.sock"
if os.path.exists(sock):
    os.unlink(sock)
cmdline = ("root=PARTUUID=9d53a1f9-76da-45f9-840d-29fec7a13ce6 rw rootwait console=ttyAMA0 "
           "init=/usr/bin/bash bootconfig tb710fu.wait=8")
env = dict(os.environ, LD_LIBRARY_PATH=Q + "/usr/lib/x86_64-linux-gnu")
qemu = subprocess.Popen(
    [Q + "/usr/bin/qemu-system-aarch64", "-M", "virt", "-cpu", "max", "-smp", "4", "-m", "2048",
     "-display", "none", "-L", Q + "/usr/share/qemu", "-kernel", W + "/Image", "-initrd", W + "/initrd",
     "-append", cmdline, "-drive", f"file={disk},format=raw,if=virtio",
     "-chardev", f"socket,id=s0,path={sock},server=on,wait=off", "-serial", "chardev:s0"],
    env=env, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
for _ in range(50):
    if os.path.exists(sock):
        break
    time.sleep(0.2)
s = socket.socket(socket.AF_UNIX)
s.connect(sock)
s.settimeout(1)
buf = b""


def read_until(token, limit):
    global buf
    end = time.time() + limit
    while time.time() < end:
        try:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
            sys.stdout.write(chunk.decode(errors="replace"))
            sys.stdout.flush()
            if token in buf:
                return True
        except socket.timeout:
            pass
    return False


try:
    # bash prints a prompt ending in '# ' once root is mounted and init=bash runs
    if not read_until(b"# ", timeout):
        print("\n!! no shell prompt")
        sys.exit(1)
    s.sendall(b"export PS1='QSH> ' LANG=C\n")
    read_until(b"QSH> ", 30)
    for line in open(cmdfile):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        buf = b""
        s.sendall(line.encode() + b"\n")
        if not read_until(b"QSH> ", 300):
            print("\n!! command timed out:", line)
    s.sendall(b"sync; echo o > /proc/sysrq-trigger\n")
    time.sleep(3)
finally:
    qemu.kill()
