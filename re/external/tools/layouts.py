"""Struct/union layouts of a C/C++ header, measured by clang for the game's ABI.

The headers in the external repos are Ghidra C exports without offsets. Rather than
re-implement C layout rules, compile the header for i686-pc-windows-msvc (the ABI the
game and the mods use) and read clang's own record-layout dump. Field sizes come from a
second pass that asks clang for sizeof(((T*)0)->field) through typedef'd char arrays.
"""
import os
import re
import subprocess
import tempfile

CLANG = os.environ.get("CLANG", "clang")
BASE = ["-target", "i686-pc-windows-msvc", "-fms-compatibility", "-fsyntax-only",
        "-Wno-everything", "-ferror-limit=0"]

# Win32 / stdint names the Ghidra exports use without declaring them.
PRELUDE = """
#include <stdint.h>
typedef signed char INT8; typedef void *HINSTANCE; typedef void *HWND; typedef long HRESULT;
typedef unsigned long DWORD; typedef wchar_t WCHAR;
typedef struct _GUID { uint32_t a; uint16_t b, c; uint8_t d[8]; } GUID;
"""

REC_RE = re.compile(r"^\s*0 \| (struct|union|class) (\S+)\s*$")
MEM_RE = re.compile(r"^\s*(\d+)(?::(\d+)-(\d+))? \|( +)(.*?)\s*$")
SIZE_RE = re.compile(r"\[sizeof=(\d+), (?:dsize=\d+, )?align=(\d+)")
SZ_RE = re.compile(r"TypedefDecl .* (__sz_\d+) 'char\[(\d+)\]'")


def _fixed_enum_forward_decls(text):
    """seuko-mod uses `enum X x;` before `typedef enum X : T {...}`; MSVC accepts it,
    clang wants an opaque declaration with the same underlying type first."""
    decls = re.findall(r"typedef enum (\w+) : ([\w ]+?) \{", text)
    if not decls:
        return text
    fwd = "".join(f"enum {n} : {t};\n" for n, t in decls)
    m = re.search(r"^(typedef )?(struct|union|enum) ", text, re.M)
    at = m.start() if m else 0
    # the underlying types (byte, uint, ...) are typedefs at the top of the header
    m2 = re.search(r"^typedef (struct|union|enum) ", text, re.M)
    at = m2.start() if m2 else at
    return text[:at] + fwd + text[at:]


def _run(args, cwd):
    p = subprocess.run([CLANG] + BASE + args, cwd=cwd, capture_output=True, text=True)
    return p.stdout


def _defined_records(text):
    return set(re.findall(r"^(?:typedef )?(?:struct|union) (\w+) \{", text, re.M))


def measure(header_path, cplusplus, pack=None):
    """Return {record_name: {"kind","size","fields":[{offset,size,bits,type,name}]}}.
    pack=1 measures the header the way it is included under `#pragma pack(1)`."""
    text = open(header_path, encoding="utf-8", errors="replace").read()
    if cplusplus:
        text = _fixed_enum_forward_decls(text)
    wanted = _defined_records(text)
    lang = ["-x", "c++", "-std=c++17"] if cplusplus else ["-x", "c"]
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "hdr.h"), "w") as f:
            f.write(text)
        with open(os.path.join(tmp, "tu.c"), "w") as f:
            f.write(PRELUDE + (f"#pragma pack({pack})\n" if pack else "") + '#include "hdr.h"\n')
        out = _run(lang + ["-Xclang", "-fdump-record-layouts-complete", "tu.c"], tmp)
        recs = _parse_dump(out, wanted)

        probes, n = [], 0
        for rname, r in recs.items():
            tag = f"{r['kind']} {rname}"
            for fl in r["fields"]:
                if fl["bits"] or not fl["name"]:
                    continue
                fl["_probe"] = f"__sz_{n}"
                probes.append(f"typedef char __sz_{n}[sizeof((({tag}*)0)->{fl['name']})];")
                n += 1
        with open(os.path.join(tmp, "tu2.c"), "w") as f:
            f.write(PRELUDE + (f"#pragma pack({pack})\n" if pack else "") + '#include "hdr.h"\n'
                    + "\n".join(probes) + "\n")
        out2 = _run(lang + ["-Xclang", "-ast-dump", "-Xclang", "-ast-dump-filter=__sz_", "tu2.c"], tmp)
        sizes = dict(SZ_RE.findall(out2))
    for r in recs.values():
        for fl in r["fields"]:
            p = fl.pop("_probe", None)
            fl["size"] = int(sizes[p]) if p in sizes else None
    return recs


def _parse_dump(out, wanted):
    recs, cur, base_indent = {}, None, 0
    for line in out.splitlines():
        if line.startswith("*** Dumping AST Record Layout"):
            cur = None
            continue
        m = REC_RE.match(line)
        if m and cur is None:
            kind, name = m.group(1), m.group(2)
            if name in wanted and name not in recs:
                cur = recs[name] = {"kind": "union" if kind == "union" else "struct",
                                    "size": None, "align": None, "fields": []}
                base_indent = len(line.split("|", 1)[1]) - len(line.split("|", 1)[1].lstrip())
            else:
                cur = False
            continue
        if not cur:
            continue
        s = SIZE_RE.search(line)
        if s:
            cur["size"], cur["align"] = int(s.group(1)), int(s.group(2))
            cur = False
            continue
        m = MEM_RE.match(line)
        if not m or len(m.group(4)) != base_indent + 2:
            continue
        body = m.group(5)
        if " " in body and not body.endswith(")"):
            typ, name = body.rsplit(" ", 1)
            name = name.lstrip("*&")
        else:
            typ, name = body, ""
        bits = f"{m.group(2)}-{m.group(3)}" if m.group(2) is not None else ""
        cur["fields"].append({"offset": int(m.group(1)), "bits": bits,
                              "type": typ.strip(), "name": name})
    return recs
