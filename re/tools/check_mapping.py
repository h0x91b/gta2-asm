"""Compare Ghidra memory blocks (dumped by ExportGta2Re.java) with vanilla gta2.exe.

usage: check_mapping.py gta2.ebin <blocks-dir>
Exits non-zero unless every section's raw bytes match the block at the same VA.
"""
import hashlib
import os
import struct
import sys

exe, blocks = sys.argv[1], sys.argv[2]
d = open(exe, "rb").read()
pe = struct.unpack_from("<I", d, 0x3C)[0]
nsec = struct.unpack_from("<H", d, pe + 6)[0]
opt = pe + 24
base = struct.unpack_from("<I", d, opt + 28)[0]
sec = opt + struct.unpack_from("<H", d, pe + 20)[0]
print(f"vanilla {os.path.basename(exe)} sha1={hashlib.sha1(d).hexdigest()} base=0x{base:x}")

ok = True
for i in range(nsec):
    name, vsize, va, rsize, raw = struct.unpack_from("<8sIIII", d, sec + i * 40)
    name = name.rstrip(b"\0").decode()
    path = os.path.join(blocks, f"{base + va:08x}.bin")
    if not os.path.exists(path):
        print(f"  {name:7} 0x{base + va:08x}: no Ghidra block starts here")
        ok = False
        continue
    g = open(path, "rb").read()
    n = min(rsize, vsize, len(g))
    diff = sum(1 for a, b in zip(g[:n], d[raw:raw + n]) if a != b)
    print(f"  {name:7} 0x{base + va:08x} +0x{n:x}: {diff} differing bytes")
    ok &= diff == 0
print("mapping: 1:1" if ok else "mapping: MISMATCH")
sys.exit(0 if ok else 1)
