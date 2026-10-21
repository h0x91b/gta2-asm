#!/usr/bin/env python3
"""Decode the Fix16 globals that gta2.exe fills in its CRT static initialisers.

Hundreds of DAT_ globals (physics constants such as restitution, damping, gravity) are zero in
the file image and only get their value when the CRT runs the static-initialiser thunks before
WinMain. Each thunk is a few instructions; this script disassembles .text with llvm-objdump and
evaluates every thunk made ONLY of these shapes:

  push imm ; mov ecx,&G ; call 0x401AD0   WriteToFirstArg   G = imm (raw Q14)
  push imm ; mov ecx,&G ; call 0x401AF0   bitShiftLeft14    G = imm << 14
  mov eax,[S] ; mov [G],eax                                 G = S
  push &B ; push &G ; mov ecx,&A ; call 0x401B20/40/60/90   G = A + - * / B  (Fix16 Q14)

Thunks with any other instruction are skipped, so a value is either exact or absent.
Values computed at run time outside the initialisers (or rewritten later) are not covered.

Usage: re/tools/static_constants.py path/to/gta2.ebin > re/static_constants.csv
Needs Xcode's llvm-objdump (xcrun). Output: address,kind,operands,raw,value,thunk
"""
import re
import subprocess
import sys

TEXT_START, TEXT_END = 0x3F1000, 0x56DBC0
OPS = {"401b20": "add", "401b40": "sub", "401b60": "mul", "401b90": "div"}


def s32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v >= 1 << 31 else v


def disassemble(exe):
    out = subprocess.run(
        ["xcrun", "llvm-objdump", "-d", "--no-show-raw-insn",
         f"--start-address={TEXT_START:#x}", f"--stop-address={TEXT_END:#x}", exe],
        check=True, capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = re.match(r"\s+([0-9a-f]+):\s*(.*)", line)
        if m:
            yield int(m.group(1), 16), m.group(2).split("#")[0].strip()


def eval_thunk(block):
    """Return [(dst, kind, operand, addr)] or None if the thunk has a foreign instruction."""
    stack, ecx, eax, out = [], None, None, []
    for addr, ins in block:
        if ins.startswith("ret") or ins in ("nop", "int3"):
            continue
        if m := re.match(r"pushl\s+\$(-?0x[0-9a-f]+|-?\d+)$", ins):
            stack.append(int(m.group(1), 0))
        elif m := re.match(r"movl\s+\$0x([0-9a-f]+),\s+%ecx$", ins):
            ecx = int(m.group(1), 16)
        elif m := re.match(r"movl\s+0x([0-9a-f]+),\s+%eax$", ins):
            eax = int(m.group(1), 16)
        elif (m := re.match(r"movl\s+%eax,\s+0x([0-9a-f]+)$", ins)) and eax:
            out.append((int(m.group(1), 16), "copy", eax, addr))
        elif (m := re.match(r"calll\s+0x(401b20|401b40|401b60|401b90)", ins)) and len(stack) >= 2 and ecx:
            dst, b = stack.pop(), stack.pop()
            out.append((dst, OPS[m.group(1)], (ecx, b), addr))
            stack, ecx = [], None
        elif (m := re.match(r"calll\s+0x(401ad0|401af0)", ins)) and stack and ecx:
            out.append((ecx, "raw" if m.group(1) == "401ad0" else "shl14", s32(stack.pop()), addr))
            stack, ecx = [], None
        else:
            return None
    return out


def main(exe):
    rows, block = {}, []
    for addr, ins in disassemble(exe):
        block.append((addr, ins))
        if ins.startswith("ret"):
            for row in eval_thunk(block) or []:
                rows.setdefault(row[0], row)
            block = []
    val = {d: (x if k == "raw" else x << 14) for d, (_, k, x, _) in rows.items() if k in ("raw", "shl14")}
    for _ in range(10):  # resolve copies / arithmetic in dependency order
        for d, (_, k, x, _) in rows.items():
            if d in val:
                continue
            if k == "copy" and x in val:
                val[d] = val[x]
            elif k in ("add", "sub", "mul", "div") and x[0] in val and x[1] in val:
                a, b = val[x[0]], val[x[1]]
                if k == "add":
                    val[d] = s32(a + b)
                elif k == "sub":
                    val[d] = s32(a - b)
                elif k == "mul":
                    val[d] = s32((a * b) >> 14)
                elif b:
                    q = abs(a << 14) // abs(b)
                    val[d] = s32(q if (a < 0) == (b < 0) else -q)
    print("address,kind,operands,raw,value,thunk")
    for d in sorted(rows):
        _, k, x, a = rows[d]
        ops = f"{x:#08x}" if k == "copy" else (f"{x[0]:#08x} {x[1]:#08x}" if isinstance(x, tuple) else "")
        r = val.get(d)
        raw = "" if r is None else f"{r & 0xFFFFFFFF:#x}"
        v = "" if r is None else f"{r / 16384:.6f}"
        print(f"{d:#08x},{k},{ops},{raw},{v},{a:#08x}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
