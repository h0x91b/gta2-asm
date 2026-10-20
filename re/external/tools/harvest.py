"""Harvest address-bearing RE facts from the external GTA2 repos and diff them against re/.

    python3 -I re/external/tools/harvest.py [--ext .external] [--exe gta2/gta2.ebin]

Reads the clones made by fetch.sh, the Ghidra export of gta2-resurection's .gzf made by
export_gzf.sh (re/external/gzf/), and our own export in re/. Writes re/external/*.csv,
struct_diff.md and stats.txt. Only facts (addresses, names, offsets, signatures) and
file:line references are written, never the repos' code.
"""
import argparse
import collections
import csv
import os
import re
import struct as st
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layouts  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
RE_DIR = os.path.join(REPO, "re")
OUT = os.path.join(RE_DIR, "external")
GZF = os.path.join(OUT, "gzf")

IMAGE_LO, IMAGE_HI = 0x3F0000, 0x67A000
TEXT_LO, TEXT_HI = 0x3F1000, 0x56DBC0
HEX_RE = re.compile(r"\b0x(0*[3-6][0-9a-fA-F]{5})\b")

SEUKO, RESUR, MOUSE, GZFR = "gta2-seuko-mod", "gta2-resurection", "gta2-mouse", "gta2-resurection.gzf"
REPOS = [SEUKO, RESUR, MOUSE, GZFR]


# ---------------------------------------------------------------- helpers

def rel(path, ext):
    return os.path.relpath(path, ext)


def norm_name(n):
    n = re.sub(r"^(p|g_|m_)(?=[A-Z])", "", n or "")  # pGame, g_Foo
    n = re.sub(r"[^a-z0-9]", "", n.lower())
    for p in ("ptrto", "ptr", "fn"):
        if n.startswith(p) and len(n) > len(p) + 2:
            n = n[len(p):]
    return n


def names_match(a, b):
    return bool(a) and bool(b) and norm_name(a) == norm_name(b)


STOP_TOKENS = {"ptr", "to", "p", "get", "the", "of", "a", "fn", "g", "do", "is", "ptrto", "rel"}


def tokens(n):
    n = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", n or "")
    n = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", n)
    out = set()
    for t in re.split(r"[^A-Za-z0-9]+", n.lower()):
        if not t or t in STOP_TOKENS:
            continue
        for suf in ("ed", "s"):
            if len(t) > 4 and t.endswith(suf):
                t = t[: -len(suf)]
        out.add(t)
    return out


def similar(a, b):
    """Same thing under another naming scheme: one token set contains the other
    (ptrToS15_script ~ S15, window_width ~ WindowedWidth, do_show_ids ~ Show id's)."""
    ta, tb = tokens(a), tokens(b)
    na, nb = norm_name(a), norm_name(b)
    if len(na) > 3 and len(nb) > 3 and (na in nb or nb in na):
        return True
    return bool(ta) and bool(tb) and (ta <= tb or tb <= ta)


def in_image(a):
    return IMAGE_LO <= a < IMAGE_HI


PLACEHOLDER_RE = re.compile(
    r"^(field\d*_0x[0-9a-f]+|_?gap_?0x[0-9a-f]+\w*|_gap\w*|unk\w*|pad\w*|padding\w*|unused\w*|"
    r"undefined\d*|field\d+|f\d+|u\d*_?0x[0-9a-f]+|_?\d+)$", re.I)


def is_placeholder(name, typ=""):
    if not name:
        return True
    if PLACEHOLDER_RE.match(name):
        return True
    return False


def split_params(p):
    p = p.strip()
    if p in ("", "void"):
        return []
    out, depth, cur = [], 0, ""
    for ch in p:
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
            continue
        depth += ch in "(<"
        depth -= ch in ")>"
        cur += ch
    out.append(cur.strip())
    return out


def effective_cc(cc, params):
    """MSVC mods spell __thiscall as __fastcall(this, edx_dummy, ...)."""
    cc = (cc or "").strip() or "__cdecl"
    ps = list(params)
    if cc == "__fastcall" and len(ps) >= 2 and re.search(r"\bedx\b|^(DWORD|dword|int|uint)$", ps[1]):
        return "__thiscall", [ps[0]] + ps[2:]
    return cc, ps


# ---------------------------------------------------------------- the exe

class Exe:
    def __init__(self, path):
        self.data = open(path, "rb").read()
        pe = st.unpack_from("<I", self.data, 0x3C)[0]
        nsec = st.unpack_from("<H", self.data, pe + 6)[0]
        opt = st.unpack_from("<H", self.data, pe + 20)[0]
        self.base = st.unpack_from("<I", self.data, pe + 24 + 28)[0]
        self.secs = []
        o = pe + 24 + opt
        for i in range(nsec):
            name = self.data[o:o + 8].rstrip(b"\0").decode()
            vsz, va, rsz, raw = st.unpack_from("<IIII", self.data, o + 8)
            self.secs.append((name, self.base + va, vsz, rsz, raw))
            o += 40

    def section(self, a):
        for name, va, vsz, rsz, raw in self.secs:
            if va <= a < va + max(vsz, rsz):
                return name
        return ""

    def read(self, a, n):
        for name, va, vsz, rsz, raw in self.secs:
            if va <= a and a + n <= va + rsz:
                return self.data[raw + a - va: raw + a - va + n]
        return None

    def prologue_check(self, a):
        """MSVC pads functions to 16 bytes with 0x90/0xCC; a real start follows padding
        or a ret. Returns (verdict, bytes)."""
        b = self.read(a, 8)
        prev = self.read(a - 8, 8)
        if b is None or prev is None:
            return "NOT_IN_TEXT", ""
        hexb = b.hex(" ")
        if b[0] in (0x90, 0xCC, 0x00):
            return "SUSPECT(starts with padding)", hexb
        jt = st.unpack("<I", prev[4:])[0]
        after = (prev[-1] in (0x90, 0xCC, 0xC3) and "pad/ret") or (prev[-3] == 0xC2 and "ret n") \
            or (prev[-5] == 0xE9 and "jmp") or (prev[-2] == 0xEB and "jmp short") \
            or (TEXT_LO <= jt < TEXT_HI and "jump table")
        if after:
            return ("OK" if a % 16 == 0 else "OK(unaligned)") + f"(after {after})", hexb
        return "SUSPECT(no padding/ret before)", hexb

    def call_target(self, a):
        b = self.read(a, 5)
        if b is None:
            return None, None
        if b[0] in (0xE8, 0xE9):
            return b[0], (a + 5 + st.unpack("<i", b[1:5])[0]) & 0xFFFFFFFF
        return b[0], None


# ---------------------------------------------------------------- our export

class Ours:
    def __init__(self):
        rd = lambda f: list(csv.DictReader(open(os.path.join(RE_DIR, f), encoding="utf-8")))
        self.fn = {int(r["address"], 16): r for r in rd("functions.csv")}
        self.fn_typed = {int(r["address"], 16): r for r in rd("functions_typed_unnamed.csv")}
        self.gl = {}
        for r in rd("globals.csv"):
            a = int(r["address"], 16)
            self.gl.setdefault(a, r)
        self.gl_typed = {int(r["address"], 16): r for r in rd("globals_typed_unnamed.csv")}
        self.comments = {(int(r["address"], 16), r["comment"].strip()) for r in rd("comments.csv")}
        self.fn_by_name = collections.defaultdict(list)
        for a, r in self.fn.items():
            self.fn_by_name[norm_name(r["name"])].append(a)
        self.gl_by_name = collections.defaultdict(list)
        for a, r in self.gl.items():
            self.gl_by_name[norm_name(r["name"])].append(a)
        self.ranges = sorted((a, a + int(r["size"] or 0), r["name"]) for a, r in self.fn.items()
                             if r["size"] and r["size"].isdigit())
        self.layouts = layouts.measure(os.path.join(RE_DIR, "gta2_types.h"), False)
        self.enums = parse_enums(open(os.path.join(RE_DIR, "gta2_types.h")).read(), ours=True)

    def containing(self, a):
        for lo, hi, name in self.ranges:
            if lo <= a < hi:
                return name, a - lo
        return None, None


def parse_enums(text, ours=False):
    """{enum_name: {const: value}}; ours are `enum X_values {` with `X__CONST` prefixes."""
    out = {}
    for m in re.finditer(r"(?:typedef\s+)?enum\s+(\w+)\s*(?::\s*[\w ]+?)?\s*\{(.*?)\}", text, re.S):
        name, body = m.group(1), m.group(2)
        if ours:
            name = re.sub(r"_values$", "", name)
        consts, val = {}, -1
        for item in re.split(r",", re.sub(r"//[^\n]*", "", body)):
            item = item.strip()
            if not item:
                continue
            if "=" in item:
                k, v = [x.strip() for x in item.split("=", 1)]
                try:
                    val = int(v, 0)
                except ValueError:
                    continue
            else:
                k, val = item, val + 1
            if ours and k.startswith(name + "__"):
                k = k[len(name) + 2:]
            consts[k] = val
        out[name] = consts
    return out


# ---------------------------------------------------------------- extraction

Item = collections.namedtuple("Item", "repo ref kind addr name cc sig typ note")


def fn_typedefs(text):
    """typedef name -> (ret, cc, params) for function types (pointer or not)."""
    out = {}
    for m in re.finditer(r"typedef\s+([\w\s\*]+?)\s*\(\s*(__\w+)?\s*\*?\s*(\w+)\s*\)\s*\(([^;{]*?)\)\s*;", text):
        out[m.group(3)] = (m.group(1).strip(), m.group(2) or "", split_params(m.group(4)))
    for m in re.finditer(r"typedef\s+([\w\*]+(?:\s*\*)?)\s+(__\w+\s+)?(\w+)\s*\(([^;{()]*)\)\s*;", text):
        out.setdefault(m.group(3), (m.group(1).strip(), (m.group(2) or "").strip(), split_params(m.group(4))))
    return out


def sig_str(ret, cc, name, params):
    return f"{ret} {cc + ' ' if cc else ''}{name}({', '.join(params) or 'void'})"


def lineno(text, pos):
    return text.count("\n", 0, pos) + 1


def extract_seuko(ext):
    root = os.path.join(ext, SEUKO, "src")
    items, consumed = [], set()
    # functions.h: typed function pointers and function-pointer slots
    fpath = os.path.join(root, "game", "functions.h")
    text = open(fpath).read()
    tds = fn_typedefs(text)
    for m in re.finditer(r"static constexpr (\w+)\* (\w+) = \(\w+\*\)0x([0-9a-fA-F]+);", text):
        t, name, a = m.group(1), m.group(2), int(m.group(3), 16)
        ret, cc, ps = tds.get(t, ("?", "", []))
        ecc, eps = effective_cc(cc, ps)
        ln = lineno(text, m.start())
        note = _comment_above(text, m.start())
        items.append(Item(SEUKO, f"src/game/functions.h:{ln}", "function", a, name, ecc,
                          sig_str(ret, cc, name, ps), "", note))
        consumed.add((fpath, ln))
    for m in re.finditer(r"static (\w+)\* (\w+)Func = \*\((\w+)\*\*\)0x([0-9a-fA-F]+);", text):
        t, name, a = m.group(1), m.group(2), int(m.group(4), 16)
        ret, cc, ps = tds.get(t, ("?", "", []))
        ecc, _ = effective_cc(cc, ps)
        ln = lineno(text, m.start())
        items.append(Item(SEUKO, f"src/game/functions.h:{ln}", "fnptr_slot", a, f"p{name}", ecc,
                          sig_str(ret, cc, name, ps), f"{t}*",
                          "global slot holding a pointer to the function (renderer/video DLL export)"))
        consumed.add((fpath, ln))
    # memory.h: global getters
    mpath = os.path.join(root, "game", "memory.h")
    text = open(mpath).read()
    for m in re.finditer(r"static ([\w:]+\*{1,2}) Get(\w+)\(\) \{ return \(([\w:]+\*{1,2})\)(\*\(DWORD\*\))?0x([0-9a-fA-F]+); \}", text):
        rt, name, a = m.group(1), m.group(2), int(m.group(5), 16)
        deref = bool(m.group(4))
        typ = rt.replace("Game::", "") + ("" if not deref else "")
        typ = (rt + "") if deref else rt[:-1]
        ln = lineno(text, m.start())
        items.append(Item(SEUKO, f"src/game/memory.h:{ln}", "global", a, name, "", "", typ,
                          "holds a pointer" if deref else "object at address"))
        consumed.add((mpath, ln))
    # leftovers in memory.h (renderer base computation)
    for i, line in enumerate(text.splitlines(), 1):
        if (mpath, i) in consumed:
            continue
        for h in HEX_RE.findall(line):
            a = int(h, 16)
            if a == 0x5952A8:
                items.append(Item(SEUKO, f"src/game/memory.h:{i}", "fnptr_slot", a, "pgbh_InitDLL",
                                  "", "", "", "d3ddll.dll gbh_InitDLL pointer; renderer base = it - 0x00e053f0"))
    # everything else: hook sites, return addresses, asm constants
    for dp, dns, fns in os.walk(root):
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            if p in (fpath, mpath) or not fn.endswith((".cpp", ".h")):
                continue
            items += code_refs(p, SEUKO, ext, os.path.join(ext, SEUKO))
    return items


def _comment_above(text, pos):
    lines = text[:pos].splitlines()
    notes = []
    for l in reversed(lines[-3:]):
        s = l.strip()
        if s.startswith("//"):
            notes.insert(0, s[2:].strip())
        elif s.startswith("typedef") or not s:
            continue
        else:
            break
    return " ".join(notes)[:200]


DECL_RE = re.compile(r"(?:const\s+)?(\w*Hook|DWORD|std::vector<DWORD>)\s+(\w+)\s*=")


def code_refs(path, repo, ext, repo_root):
    """Generic line classifier for hook sites, ffi casts, #defines and raw constants."""
    text = open(path, encoding="utf-8", errors="replace").read()
    lines = text.splitlines()
    tds = fn_typedefs(text)
    items = []
    r = os.path.relpath(path, repo_root)
    for i, line in enumerate(lines, 1):
        hexes = HEX_RE.findall(line)
        if not hexes:
            continue
        s = line.strip()
        commented = s.startswith(("//", "--"))
        cnote = "commented-out line" if commented else ""
        for h in hexes:
            a = int(h, 16)
            ref = f"{r}:{i}"
            m = re.search(r"thisCallHook\((\w+),\s*0x" + h, line)
            if m:
                items.append(Item(repo, ref, "function", a, m.group(1), "__thiscall", "", "", "hooked with thisCallHook"))
                continue
            m = re.search(r"(?:local\s+)?([\w.]+)\s*=\s*ffi\.cast\('([^']+)',\s*0x" + h, line)
            m2 = re.search(r"ffi\.cast\('([^']+)',\s*0x" + h + r"\)\[0\]\s*=\s*getSetting\(\"([^\"]+)\"\)", line)
            if m2:
                items.append(Item(repo, ref, "global", a, re.sub(r"\W+", "_", m2.group(2)).strip("_"), "", "",
                                  m2.group(1).rstrip("*").strip(), "debug toggle; setting \"" + m2.group(2) + "\""))
                continue
            if m or "ffi.cast(" in line:
                t = m.group(2) if m else re.search(r"ffi\.cast\('([^']+)'", line).group(1)
                name = (m.group(1).split(".")[-1] if m else "")
                if not t.endswith("*"):
                    items.append(Item(repo, ref, "function", a, re.sub(r"^fn", "", name) or t, "", "", t,
                                      ("ffi function type " + t + "; " + cnote).strip("; ")))
                else:
                    items.append(Item(repo, ref, "global", a, name, "", "", t[:-1].strip(),
                                      ("ffi.cast to " + t + "; " + cnote).strip("; ")))
                continue
            m = re.search(r"#define\s+(\w+)\s+0x" + h, line)
            if m:
                items.append(Item(repo, ref, "global", a, m.group(1), "", "", "", "#define"))
                continue
            m = re.search(r"(\w+)\*\s+(\w+)\s*=\s*\(\w+\*\)\s*0x" + h, line)
            if m and m.group(1) in tds:
                ret, cc, ps = tds[m.group(1)]
                ecc, _ = effective_cc(cc, ps)
                items.append(Item(repo, ref, "function", a, re.sub(r"^fn", "", m.group(2)), ecc,
                                  sig_str(ret, cc, m.group(1), ps), "", ""))
                continue
            m = re.search(r"(WNDPROC)\s+(\w+)\s*=\s*\(WNDPROC\)0x" + h, line)
            if m:
                items.append(Item(repo, ref, "function", a, re.sub(r"^fn", "", m.group(2)), "__stdcall",
                                  "LRESULT __stdcall WndProc(HWND, UINT, WPARAM, LPARAM)", "", "game window procedure"))
                continue
            m = re.search(r"DWORD\s+(\w+)\s*=\s*0x" + h, line)
            if m and not re.search(r"Return|Fn$|Function", m.group(1)):
                items.append(Item(repo, ref, "global", a, m.group(1), "", "", "", ""))
                continue
            m = re.search(r"\((\w+)\*\)\s*\*\s*\(DWORD\*\)\s*0x" + h, line)
            if m:
                items.append(Item(repo, ref, "global", a, "", "", "", m.group(1) + "*", "dereferenced as " + m.group(1) + "*"))
                continue
            # hook sites and labels: name the nearest declaration above
            ctx, hook = _decl_context(lines, i)
            kind = "code_ref"
            if hook:
                kind = "hook_site"
            if re.search(r"(Fn|Function)\b", ctx or "") and re.search(r"DWORD\s+" + (ctx or "x") + r"\s*=\s*0x" + h, line):
                kind = "function"
            if re.search(r"cmp\s+\w+\s*,\s*0x" + h, line, re.I):
                kind, hook = "code_ref", "asm cmp (return address of a call)"
            m = re.search(r"mov\s+ds\s*:\s*\[0x" + h, line)
            if m:
                kind, hook = "global", "written by hook asm"
            items.append(Item(repo, ref, kind, a, ctx or "", "", "", hook or "",
                              (s[:120] if kind != "function" else "") + (" " + cnote if cnote else "")))
    return items


def _decl_context(lines, i):
    line = lines[i - 1]
    m = DECL_RE.search(line)
    if m:
        return m.group(2), (m.group(1) if m.group(1).endswith("Hook") else "")
    for j in range(i - 2, max(-1, i - 12), -1):
        m = DECL_RE.search(lines[j])
        if m:
            return m.group(2), (m.group(1) if m.group(1).endswith("Hook") else "")
        if re.match(r"\s*(static|bool|void|\}|//\s*0x)", lines[j]) and "{" not in lines[j]:
            break
    m = re.search(r"//\s*0x[0-9a-fA-F]+\s*-?\s*(.*)", line)
    return (m.group(1).strip()[:60] if m else ""), ""


def extract_resur(ext):
    root = os.path.join(ext, RESUR, "gta2-resurection")
    items = []
    for fn in sorted(os.listdir(root)):
        if fn.endswith((".cpp", ".h", ".lua")) and not fn.startswith(("imgui", "imstb", "imconfig")) \
                and fn not in ("gta2.h", "gta2-def.lua"):
            items += code_refs(os.path.join(root, fn), RESUR, ext, os.path.join(ext, RESUR))
    items += extract_ct(os.path.join(ext, RESUR, "gta2-resurected.ct"), ext)
    return items


def extract_mouse(ext):
    root = os.path.join(ext, MOUSE)
    items = []
    for fn in sorted(os.listdir(root)):
        if fn.endswith((".cpp", ".h")) and fn != "gta2.segments.fixed.exe.h":
            items += code_refs(os.path.join(root, fn), MOUSE, ext, root)
    return items


CT_ROWS = []


def extract_ct(path, ext):
    """Cheat Engine table: static entries become globals; pointer chains are kept in
    ct_entries.csv. Heap addresses (a single debugging session) are dropped."""
    items = []
    tree = ET.parse(path)
    src = open(path, encoding="utf-8", errors="replace").read().splitlines()

    def line_of(addr_text, start=[0]):
        for k in range(start[0], len(src)):
            if "<Address>" + addr_text in src[k]:
                start[0] = k + 1
                return k + 1
        return 0

    def walk(node, path_desc):
        for ce in node.findall("CheatEntry"):
            desc = (ce.findtext("Description") or "").strip().strip('"')
            addr_t = (ce.findtext("Address") or "").strip()
            vt = (ce.findtext("VariableType") or "").strip()
            offs = [o.text.strip() for o in ce.findall("Offsets/Offset")]
            ln = line_of(addr_t) if addr_t else 0
            base = None
            m = re.fullmatch(r'"[^"]+\.exe"\+([0-9A-Fa-f]+)', addr_t)
            if m:
                base = 0x3F0000 + int(m.group(1), 16)
            elif re.fullmatch(r"(0x)?[0-9A-Fa-f]+", addr_t):
                base = int(addr_t, 16)
            if addr_t:
                static = base is not None and in_image(base)
                CT_ROWS.append({"source_ref": f"gta2-resurected.ct:{ln}", "description": desc,
                                "address_expr": addr_t, "base": f"0x{base:08x}" if static else "",
                                "offsets_outer_to_inner": " -> ".join("+0x" + o.lower() for o in reversed(offs)),
                                "variable_type": vt, "static": "yes" if static else "no (heap address)"})
                if static and not offs:
                    nm = "" if desc == "No description" else re.sub(r"\W+", "_", desc).strip("_")
                    items.append(Item(RESUR, f"gta2-resurected.ct:{ln}", "global", base, nm, "", "", vt,
                                      "Cheat Engine entry" + ("" if nm else " (no description)")))
            kids = ce.find("CheatEntries")
            if kids is not None:
                walk(kids, path_desc + [desc])

    walk(tree.getroot().find("CheatEntries"), [])
    return items


def extract_gzf():
    """The Ghidra archive in gta2-resurection, exported by export_gzf.sh."""
    items = []
    rd = lambda f: list(csv.DictReader(open(os.path.join(GZF, f), encoding="utf-8")))
    for i, r in enumerate(rd("functions.csv"), 2):
        if r["name_source"] != "USER_DEFINED" and r["signature_source"] != "USER_DEFINED":
            continue
        items.append(Item(GZFR, f"gzf/functions.csv:{i}", "function", int(r["address"], 16), r["name"],
                          r["calling_convention"], r["signature"], "", ""))
    for i, r in enumerate(rd("functions_typed_unnamed.csv"), 2):
        items.append(Item(GZFR, f"gzf/functions_typed_unnamed.csv:{i}", "function", int(r["address"], 16), "",
                          r["calling_convention"], r["signature"], "", "typed, unnamed"))
    for i, r in enumerate(rd("globals.csv"), 2):
        if r["name_source"] != "USER_DEFINED":
            continue
        kind = "code_ref" if r["in_function"] else "global"
        items.append(Item(GZFR, f"gzf/globals.csv:{i}", kind, int(r["address"], 16), r["name"], "", "",
                          r["datatype"], ("label in " + r["in_function"]) if r["in_function"] else ""))
    for i, r in enumerate(rd("globals_typed_unnamed.csv"), 2):
        items.append(Item(GZFR, f"gzf/globals_typed_unnamed.csv:{i}", "global", int(r["address"], 16), "",
                          "", "", r["datatype"], "typed, unnamed"))
    return items


# ---------------------------------------------------------------- classification

# Ghidra placeholders, and a custom convention from the 2021 DB with no meaning today
UNCOMPARABLE_CC = ("", "unknown", "default", "__fakethis")


def classify_function(it, ours, exe):
    a = it.addr
    detail, status = [], "NEW"
    o = ours.fn.get(a)
    oname = osrc = osig = ""
    if o:
        oname, osrc, osig = o["name"], o["name_source"], o["signature"]
        if not it.name or names_match(it.name, o["name"]):
            status = "SAME"
        else:
            status = "CONFLICT"
            detail.append("name" + (" (similar)" if similar(it.name, o["name"]) else ""))
            if o["name"].startswith("relTo"):
                detail.append("ours is a relTo* guess")
            if o["name_source"] != "USER_DEFINED":
                detail.append(f"ours name from Ghidra {o['name_source']} (library match)")
        if o["signature_source"] == "USER_DEFINED" and it.cc not in UNCOMPARABLE_CC:
            occ = o["calling_convention"]
            if occ not in ("default", "unknown") and it.cc.replace("__", "") != occ.replace("__", ""):
                detail.append(f"cc ours {occ} vs {it.cc}")
                status = "CONFLICT"
    elif a in ours.fn_typed:
        t = ours.fn_typed[a]
        osig = t["signature"]
        detail.append("ours: typed but unnamed")
        if it.cc not in UNCOMPARABLE_CC and t["calling_convention"] not in ("default", "unknown") and \
                it.cc.replace("__", "") != t["calling_convention"].replace("__", ""):
            detail.append(f"cc ours {t['calling_convention']} vs {it.cc}")
    else:
        cn, off = ours.containing(a)
        if cn and off:
            status = "CONFLICT"
            detail.append(f"inside ours {cn}+0x{off:x} (function boundary disagrees)")
            oname = f"{cn}+0x{off:x}"
    if it.name and status != "SAME":
        others = [x for x in ours.fn_by_name.get(norm_name(it.name), []) if x != a]
        if others:
            status = "CONFLICT"
            detail.append("ours has this name at " + ", ".join(f"0x{x:08x}" for x in others))
    bc = ""
    if status != "SAME":
        if TEXT_LO <= a < TEXT_HI:
            v, b = exe.prologue_check(a)
            bc = f"{v} [{b}]"
        else:
            bc = "not in .text (" + (exe.section(a) or "outside image") + ")"
    return status, "; ".join(detail), oname, osrc, osig, bc


def classify_global(it, ours, exe, their_layouts):
    a = it.addr
    detail, status = [], "NEW"
    o = ours.gl.get(a)
    oname = otype = ""
    if o:
        oname, otype = o["name"], o["datatype"]
        if not it.name or names_match(it.name, o["name"]):
            status = "SAME"
        else:
            # a struct-typed global whose first field is what we named
            t = re.sub(r"\W", "", it.typ or "")
            lay = their_layouts.get(t)
            if lay and lay["fields"] and names_match(lay["fields"][0]["name"], o["name"]) and "pointer" not in it.note:
                status = "SAME"
                detail.append(f"ours names its first field ({lay['fields'][0]['name']})")
            else:
                status = "CONFLICT"
                detail.append("name" + (" (similar)" if similar(it.name, o["name"]) else ""))
    elif a in ours.gl_typed:
        otype = ours.gl_typed[a]["datatype"]
        detail.append("ours: typed but unnamed")
    if it.name and status != "SAME":
        others = [x for x in ours.gl_by_name.get(norm_name(it.name), []) if x != a]
        if others:
            status = "CONFLICT"
            detail.append("ours has this name at " + ", ".join(f"0x{x:08x}" for x in others))
    # ours labels that fall inside a struct-typed object
    t = re.sub(r"[^\w]", "", it.typ or "")
    lay = their_layouts.get(t)
    if lay and lay["size"] and "object at address" in it.note:
        inside = []
        for oa, orow in ours.gl.items():
            if a < oa < a + lay["size"]:
                off = oa - a
                f = next((f for f in lay["fields"] if f["offset"] == off), None)
                inside.append(f"{orow['name']}@+0x{off:x}" + (f"={f['name']}" if f else ""))
        if inside:
            detail.append("ours labels inside: " + ", ".join(sorted(inside)[:12]) + (" …" if len(inside) > 12 else ""))
    sec = exe.section(a)
    if not sec:
        detail.append("outside image")
    return status, "; ".join(detail), oname, otype, sec


def classify_code_ref(it, ours, exe):
    a = it.addr
    cn, off = ours.containing(a)
    o = ours.gl.get(a)
    status, detail = "NEW", []
    if o and it.name:
        status = "SAME" if names_match(o["name"], it.name) else "NEW"
        detail.append(f"ours label {o['name']}")
    if a in ours.fn:
        detail.append(f"is ours function start {ours.fn[a]['name']}")
    op, tgt = exe.call_target(a) if TEXT_LO <= a < TEXT_HI else (None, None)
    bc = ""
    if op is not None:
        if tgt is not None:
            tn = ours.fn.get(tgt, {}).get("name") or ours.fn_typed.get(tgt, {}).get("name") or ""
            bc = f"{'call' if op == 0xE8 else 'jmp'} 0x{tgt:08x}" + (f" ({tn})" if tn else "")
        else:
            bc = f"opcode {op:02x}"
        if "CallHook" in (it.typ or "") and op == 0x0F:
            detail.append("site is a near jcc (0f 8x) that the hook overwrites")
        elif "CallHook" in (it.typ or "") and op != 0xE8:
            status = "CONFLICT"
            detail.append("hook expects a call (E8) at this address")
    elif not exe.section(a):
        detail.append("outside image")
    else:
        bc = f"in {exe.section(a)}"
    where = f"{cn}+0x{off:x}" if cn else ""
    return status, "; ".join(detail), where, bc


# ---------------------------------------------------------------- structs & enums

def struct_diff(repo, src_ref, theirs, ours_l, rows, summary):
    ours_ci = {k.lower(): k for k in ours_l}
    for sname in sorted(theirs):
        t = theirs[sname]
        oname = sname if sname in ours_l else ours_ci.get(sname.lower())
        o = ours_l.get(oname) if oname else None
        named = [f for f in t["fields"] if not is_placeholder(f["name"], f["type"])]
        cnt = collections.Counter()
        conflicts = []
        if o is None:
            for f in named:
                rows.append(_srow(repo, src_ref, sname, f, "NEW", None, "struct not in ours"))
                cnt["NEW"] += 1
            summary.append((repo, sname, t["size"], None, cnt, len(t["fields"]) - len(named), conflicts, "NEW_STRUCT"))
            continue
        by_off = {}
        for f in o["fields"]:
            by_off.setdefault(f["offset"], f)
        ofields = sorted(o["fields"], key=lambda f: f["offset"])
        for f in named:
            of = by_off.get(f["offset"])
            st_, det = "NEW", ""
            if f["offset"] >= (o["size"] or 0):
                det = "beyond ours struct size"
            elif of is not None and not is_placeholder(of["name"], of["type"]):
                if names_match(of["name"], f["name"]):
                    st_ = "SAME"
                    if of["size"] and f["size"] and of["size"] != f["size"]:
                        st_, det = "CONFLICT", f"size ours {of['size']} vs {f['size']}"
                else:
                    st_ = "CONFLICT"
                    det = "name" + (" (similar)" if similar(of["name"], f["name"]) else "") + (f"; size ours {of['size']} vs {f['size']}"
                                    if of["size"] and f["size"] and of["size"] != f["size"] else "")
            elif of is not None:
                det = "ours placeholder " + of["name"]
                if of["size"] and f["size"] and f["size"] > of["size"]:
                    nxt = [g for g in ofields if f["offset"] < g["offset"] < f["offset"] + f["size"]
                           and not is_placeholder(g["name"], g["type"])]
                    if nxt:
                        st_, det = "CONFLICT", "overlaps ours " + ", ".join(g["name"] for g in nxt)
            else:
                cov = [g for g in ofields if g["offset"] < f["offset"] < g["offset"] + (g["size"] or 1)]
                if cov and not is_placeholder(cov[-1]["name"], cov[-1]["type"]):
                    st_, det = "CONFLICT", f"inside ours {cov[-1]['name']} (+0x{cov[-1]['offset']:x})"
                    of = cov[-1]
                else:
                    det = "inside ours gap"
            cnt[st_] += 1
            rows.append(_srow(repo, src_ref, sname, f, st_, of, det))
            if st_ == "CONFLICT":
                conflicts.append((f, of, det))
        status = "SAME_SIZE" if t["size"] == o["size"] else "SIZE_CONFLICT"
        summary.append((repo, sname, t["size"], o["size"], cnt, len(t["fields"]) - len(named), conflicts,
                        status + ("" if oname == sname else f" (ours: {oname})")))


def _srow(repo, src, sname, f, status, of, det):
    return {"source_repo": repo, "source_file": src, "struct": sname, "offset": f"0x{f['offset']:x}",
            "size": f["size"] if f["size"] is not None else "", "bits": f["bits"], "field": f["name"],
            "type": f["type"], "status": status, "ours_field": of["name"] if of else "",
            "ours_type": of["type"] if of else "", "ours_size": (of["size"] or "") if of else "", "detail": det}


def enum_diff(repo, src, theirs, ours_e, rows):
    for en in sorted(theirs):
        oe = ours_e.get(en)
        for k, v in theirs[en].items():
            if oe is None:
                st_, det, ok = "NEW", "enum not in ours", ""
            elif k in oe:
                st_ = "SAME" if oe[k] == v else "CONFLICT"
                det, ok = ("" if st_ == "SAME" else f"value ours {oe[k]}"), k
            else:
                same_v = [n for n, x in oe.items() if x == v]
                short = k[len(en) + 1:] if k.startswith(en + "_") else k
                if any(norm_name(n) == norm_name(short) for n in same_v):
                    st_, det, ok = "SAME", "enum-name prefix dropped", same_v[0]
                elif same_v:
                    sim = any(similar(n, short) for n in same_v)
                    st_, det, ok = "CONFLICT", "same value, different name" + (" (similar)" if sim else ""), \
                        "/".join(same_v[:3])
                else:
                    st_, det, ok = "NEW", "constant not in ours", ""
            rows.append({"source_repo": repo, "source_file": src, "enum": en, "constant": k, "value": v,
                         "status": st_, "ours_constant": ok, "detail": det})


# ---------------------------------------------------------------- main

def severity(row):
    """CONFLICT rows: `naming` = the same thing under another naming scheme,
    `semantic` = the sources disagree about what lives there."""
    if row.get("status") != "CONFLICT":
        return ""
    parts = [p.strip() for p in row.get("detail", "").split(";") if p.strip()]
    hard = [p for p in parts if not (p.endswith("(similar)") or p.startswith(("ours labels inside", "ours: typed")))]
    return "semantic" if hard or not parts else "naming"


def retarget(it, exe):
    """Fix the kind once the address is known: a DWORD constant pointing into .text is a
    code address, a FunctionPtrHook site in .data is a function-pointer slot."""
    sec = exe.section(it.addr)
    if it.kind == "global" and sec == ".text" and it.repo != GZFR:
        return it._replace(kind="code_ref")
    if it.kind in ("hook_site", "code_ref") and it.typ == "FunctionPtrHook" and sec != ".text":
        name = re.sub(r"Hook$", "", it.name)
        return it._replace(kind="fnptr_slot", name="p" + name[:1].upper() + name[1:],
                           note="function-pointer slot the mod hooks (FunctionPtrHook " + it.name + ")")
    return it


def write_csv(path, rows, fields):
    if "status" in fields:
        fields = fields[:fields.index("status") + 1] + ["severity"] + fields[fields.index("status") + 1:]
        for r in rows:
            r.setdefault("severity", severity(r))
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
        w.writeheader()
        for r in rows:
            w.writerow(r)


def dedupe(items):
    """One row per (repo, kind, address, name); extra occurrences become a ref count."""
    out = collections.OrderedDict()
    for it in items:
        k = (it.repo, it.kind, it.addr, norm_name(it.name))
        if k in out:
            out[k][1].append(it.ref)
            first = out[k][0]
            if not first.sig and it.sig or not first.cc and it.cc or not first.typ and it.typ:
                out[k][0] = first._replace(sig=first.sig or it.sig, cc=first.cc or it.cc, typ=first.typ or it.typ)
        else:
            out[k] = [it, [it.ref]]
    return out.values()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ext", default=os.path.join(REPO, ".external"))
    ap.add_argument("--exe", default=os.path.join(REPO, "gta2", "gta2.ebin"))
    args = ap.parse_args()
    ext, exe = args.ext, Exe(args.exe)
    assert exe.base == IMAGE_LO, "not the 0x3F0000 gta2.exe"
    ours = Ours()

    # (header, C++?, packing). All are Ghidra exports, whose structs are unaligned, so
    # they are measured packed — the layout Ghidra meant. resurection compiles its header
    # that way too (#pragma pack(1) in gta-helper.h); seuko-mod compiles with MSVC default
    # packing, so structs where that moves fields are flagged ALIGN_SENSITIVE.
    # The gzf header from our exporter is packed itself.
    hdrs = {
        SEUKO: ("src/game/gta2.h", os.path.join(ext, SEUKO, "src", "game", "gta2.h"), True, 1),
        RESUR: ("gta2-resurection/gta2.h", os.path.join(ext, RESUR, "gta2-resurection", "gta2.h"), True, 1),
        MOUSE: ("gta2.segments.fixed.exe.h", os.path.join(ext, MOUSE, "gta2.segments.fixed.exe.h"), True, 1),
        GZFR: ("gzf/gta2_types.h", os.path.join(GZF, "gta2_types.h"), False, None),
    }
    lays = {r: layouts.measure(p, cpp, pk) for r, (_, p, cpp, pk) in hdrs.items()}
    seuko_packed = layouts.measure(hdrs[SEUKO][1], True, None)  # as seuko-mod compiles it
    align_sensitive = {n for n, r in lays[SEUKO].items() if n in seuko_packed and
                       [(f["offset"], f["name"]) for f in r["fields"]] !=
                       [(f["offset"], f["name"]) for f in seuko_packed[n]["fields"]]}

    items = extract_seuko(ext) + extract_resur(ext) + extract_mouse(ext) + extract_gzf()
    items = [retarget(it, exe) for it in items if in_image(it.addr) or it.repo != GZFR]

    frows, grows, crows = [], [], []
    for it, refs in dedupe(items):
        base = {"source_repo": it.repo, "source_ref": it.ref, "occurrences": len(refs),
                "address": f"0x{it.addr:08x}", "name": it.name}
        if it.kind == "function":
            s, d, on, osrc, osig, bc = classify_function(it, ours, exe)
            frows.append({**base, "calling_convention": it.cc, "signature": it.sig or it.typ, "status": s,
                          "detail": d, "ours_name": on, "ours_name_source": osrc, "ours_signature": osig,
                          "byte_check": bc, "note": it.note})
        elif it.kind in ("global", "fnptr_slot"):
            s, d, on, ot, sec = classify_global(it, ours, exe, lays.get(it.repo if it.repo != GZFR else GZFR, {}))
            grows.append({**base, "kind": it.kind, "type": it.typ, "signature": it.sig, "section": sec,
                          "status": s, "detail": d, "ours_name": on, "ours_type": ot, "note": it.note})
        else:
            s, d, where, bc = classify_code_ref(it, ours, exe)
            crows.append({**base, "kind": it.kind, "hook_type": it.typ, "status": s, "detail": d,
                          "ours_containing_function": where, "bytes": bc, "note": it.note})
    key = lambda r: (r["source_repo"], r["address"])
    frows.sort(key=key), grows.sort(key=key), crows.sort(key=key)

    srows, ssum = [], []
    for r, (src, _, _, _) in hdrs.items():
        struct_diff(r, src, lays[r], ours.layouts, srows, ssum)
    ssum = [x[:7] + (x[7] + (f" ALIGN_SENSITIVE(compiled by seuko-mod: size {seuko_packed[x[1]]['size']})"
                             if x[0] == SEUKO and x[1] in align_sensitive else ""),) for x in ssum]
    erows = []
    for r, (src, p, _, _) in hdrs.items():
        enum_diff(r, src, parse_enums(open(p, encoding="utf-8", errors="replace").read(), ours=(r == GZFR)),
                  ours.enums, erows)

    # gzf comments not in ours
    cmrows = []
    for i, c in enumerate(csv.DictReader(open(os.path.join(GZF, "comments.csv"), encoding="utf-8")), 2):
        a = int(c["address"], 16)
        if (a, c["comment"].strip()) not in ours.comments:
            cmrows.append({"source_ref": f"gzf/comments.csv:{i}", "address": c["address"], "kind": c["kind"],
                           "function": c["function"], "comment": c["comment"],
                           "ours_has_comment_here": "yes" if any(x == a for x, _ in ours.comments) else "no"})

    write_csv(os.path.join(OUT, "functions.csv"), frows,
              ["source_repo", "source_ref", "occurrences", "address", "name", "calling_convention", "signature",
               "status", "detail", "ours_name", "ours_name_source", "ours_signature", "byte_check", "note"])
    write_csv(os.path.join(OUT, "globals.csv"), grows,
              ["source_repo", "source_ref", "occurrences", "address", "name", "kind", "type", "signature",
               "section", "status", "detail", "ours_name", "ours_type", "note"])
    write_csv(os.path.join(OUT, "code_refs.csv"), crows,
              ["source_repo", "source_ref", "occurrences", "address", "name", "kind", "hook_type", "status",
               "detail", "ours_containing_function", "bytes", "note"])
    write_csv(os.path.join(OUT, "struct_fields.csv"), srows,
              ["source_repo", "source_file", "struct", "offset", "size", "bits", "field", "type", "status",
               "ours_field", "ours_type", "ours_size", "detail"])
    write_csv(os.path.join(OUT, "enums.csv"), erows,
              ["source_repo", "source_file", "enum", "constant", "value", "status", "ours_constant", "detail"])
    write_csv(os.path.join(OUT, "ct_entries.csv"), CT_ROWS,
              ["source_ref", "description", "address_expr", "base", "offsets_outer_to_inner", "variable_type",
               "static"])
    write_csv(os.path.join(OUT, "gzf_comments_new.csv"), cmrows,
              ["source_ref", "address", "kind", "function", "comment", "ours_has_comment_here"])
    write_candidates(frows, grows)
    write_struct_md(ssum)
    write_stats(frows, grows, crows, srows, erows, ssum, cmrows)
    write_summary(frows, grows, crows, srows, erows, ssum)


PREFER = [SEUKO, GZFR, RESUR, MOUSE]  # most maintained first


def write_candidates(frows, grows):
    """One row per address that ours does not name (or names differently): every
    source's name side by side, so importing into Ghidra is a single review pass."""
    rows = []
    for kind, src in (("function", frows), ("global", grows)):
        by = collections.defaultdict(list)
        for r in src:
            if r["status"] in ("NEW", "CONFLICT") and r["name"]:
                by[r["address"]].append(r)
        for addr, rs in sorted(by.items()):
            names = collections.OrderedDict()
            for r in sorted(rs, key=lambda r: PREFER.index(r["source_repo"])):
                names.setdefault(r["source_repo"], r["name"])
            groups = collections.Counter(norm_name(n) for n in names.values())
            best_repo = next(iter(names))
            sig = next((r["signature"] for r in sorted(rs, key=lambda r: PREFER.index(r["source_repo"]))
                        if r.get("signature")), "")
            rows.append({"kind": kind, "address": addr, "suggested_name": names[best_repo],
                         "suggested_from": best_repo, "sources_agreeing": groups[norm_name(names[best_repo])],
                         "sources_total": len(names),
                         "names_by_source": "; ".join(f"{k}={v}" for k, v in names.items()),
                         "ours_name": rs[0]["ours_name"], "status": "CONFLICT" if any(
                             r["status"] == "CONFLICT" for r in rs) else "NEW",
                         "severity": "semantic" if any(severity(r) == "semantic" for r in rs) else
                         ("naming" if any(r["status"] == "CONFLICT" for r in rs) else ""),
                         "signature": sig,
                         "byte_check": next((r.get("byte_check", "") for r in rs if r.get("byte_check")), "")})
    write_csv(os.path.join(OUT, "import_candidates.csv"), rows,
              ["kind", "address", "suggested_name", "suggested_from", "sources_agreeing", "sources_total",
               "names_by_source", "ours_name", "status", "signature", "byte_check"])
    global CANDIDATES
    CANDIDATES = rows


CANDIDATES = []


def write_struct_md(ssum):
    L = ["# Struct diff: external headers vs re/gta2_types.h", "",
         "Generated by `re/external/tools/harvest.py`; do not edit. Layouts measured by clang "
         "(`i686-pc-windows-msvc`, the headers' own packing). Placeholder fields (`field_0x..`, "
         "`undefined`, `pad`, `unk`…) are not compared, only counted. Per-field rows: `struct_fields.csv`.", "",
         "| repo | struct | their size | our size | status | NEW | SAME | CONFLICT | placeholders |",
         "|---|---|---|---|---|---|---|---|---|"]
    for repo, s, ts, os_, cnt, ph, conf, status in sorted(ssum, key=lambda x: (x[0], x[1])):
        L.append(f"| {repo} | {s} | {ts} | {os_ if os_ is not None else '—'} | {status} | {cnt['NEW']} | "
                 f"{cnt['SAME']} | {cnt['CONFLICT']} | {ph} |")
    L += ["", "## Field conflicts", ""]
    for repo, s, ts, os_, cnt, ph, conf, status in sorted(ssum, key=lambda x: (x[0], x[1])):
        if not conf and "SIZE_CONFLICT" not in status:
            continue
        L.append(f"### {repo}: {s} ({status}, theirs {ts} / ours {os_})")
        L.append("")
        for f, of, det in conf[:40]:
            L.append(f"- +0x{f['offset']:x} `{f['type']} {f['name']}` vs ours "
                     f"`{(of['type'] + ' ' + of['name']) if of else '—'}` — {det}")
        if len(conf) > 40:
            L.append(f"- … {len(conf) - 40} more in struct_fields.csv")
        L.append("")
    open(os.path.join(OUT, "struct_diff.md"), "w").write("\n".join(L) + "\n")


def write_stats(frows, grows, crows, srows, erows, ssum, cmrows):
    L = []
    for title, rows in (("functions", frows), ("globals", grows), ("code_refs", crows),
                        ("struct_fields", srows), ("enum_constants", erows)):
        c = collections.Counter((r["source_repo"], r["status"]) for r in rows)
        for repo in REPOS:
            L.append(f"{title}.{repo}=" + " ".join(f"{s}:{c[(repo, s)]}" for s in ("NEW", "SAME", "CONFLICT")))
    sc = collections.Counter((x[0], "NEW_STRUCT" if x[7] == "NEW_STRUCT" else x[7].split()[0]) for x in ssum)
    for repo in REPOS:
        L.append(f"structs.{repo}=" + " ".join(f"{s}:{sc[(repo, s)]}" for s in ("NEW_STRUCT", "SAME_SIZE", "SIZE_CONFLICT")))
    sus = [r for r in frows if r["byte_check"].startswith("SUSPECT")]
    L.append(f"functions.byte_check_suspect={len(sus)} of "
             f"{sum(1 for r in frows if r['byte_check'] and r['byte_check'] != '')} checked")
    L.append(f"gzf_comments_new={len(cmrows)}")
    L.append(f"ct_entries={len(CT_ROWS)} static={sum(1 for r in CT_ROWS if r['static'] == 'yes')}")
    open(os.path.join(OUT, "stats.txt"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))


def write_summary(frows, grows, crows, srows, erows, ssum):
    L = ["# re/external summary (generated)", "",
         "Generated by `re/external/tools/harvest.py`; do not edit. See README.md for method.", "",
         "## Counts", "", "| category | repo | NEW | SAME | CONFLICT (semantic / naming) |", "|---|---|---|---|---|"]
    for title, rows in (("functions", frows), ("globals + fn-pointer slots", grows), ("code refs / hook sites", crows),
                        ("struct fields", srows), ("enum constants", erows)):
        for repo in REPOS:
            rs = [r for r in rows if r["source_repo"] == repo]
            if not rs:
                continue
            c = collections.Counter(r["status"] for r in rs)
            sv = collections.Counter(r["severity"] for r in rs if r["status"] == "CONFLICT")
            L.append(f"| {title} | {repo} | {c['NEW']} | {c['SAME']} | {c['CONFLICT']} "
                     f"({sv['semantic']} / {sv['naming']}) |")
    L += ["", "| structs | repo | NEW_STRUCT | SAME_SIZE | SIZE_CONFLICT |", "|---|---|---|---|---|"]
    for repo in REPOS:
        c = collections.Counter(x[7].split()[0] for x in ssum if x[0] == repo)
        L.append(f"| | {repo} | {c['NEW_STRUCT']} | {c['SAME_SIZE']} | {c['SIZE_CONFLICT']} |")

    def rank(r):
        return (PREFER.index(r["source_repo"]) if r["source_repo"] != SEUKO else -1,
                r.get("ours_name_source", "") != "USER_DEFINED", r["address"])
    L += ["", "## Semantic conflicts: functions", "",
          "Sources disagree about what lives at the address (not just naming style). Ordered: "
          "seuko-mod first, then by how much we trust our own name.", "",
          "| address | source | their name | ours | detail | ref |", "|---|---|---|---|---|---|"]
    for r in sorted((r for r in frows if r["severity"] == "semantic"), key=rank):
        L.append(f"| {r['address']} | {r['source_repo']} | {r['name'] or '(typed)'} | {r['ours_name']} "
                 f"({r['ours_name_source'] or '—'}) | {r['detail']} | {r['source_ref']} |")
    L += ["", "## Semantic conflicts: globals", "", "| address | source | their name | their type | ours | detail |",
          "|---|---|---|---|---|---|"]
    for r in sorted((r for r in grows if r["severity"] == "semantic"), key=rank):
        L.append(f"| {r['address']} | {r['source_repo']} | {r['name']} | {r['type']} | {r['ours_name']} "
                 f"({r['ours_type']}) | {r['detail']} |")
    L += ["", "## Struct size conflicts (struct exists in both)", "",
          "| repo | struct | theirs | ours | field conflicts |", "|---|---|---|---|---|"]
    for x in sorted((x for x in ssum if "SIZE_CONFLICT" in x[7]), key=lambda x: (PREFER.index(x[0]), x[1])):
        L.append(f"| {x[0]} | {x[1]} | {x[2]} | {x[3]} | {len(x[6])} |")
    L += ["", "## Names found in more than one source but not in ours", "",
          "| kind | address | names |", "|---|---|---|"]
    for r in CANDIDATES:
        if r["status"] == "NEW" and int(r["sources_total"]) > 1:
            L.append(f"| {r['kind']} | {r['address']} | {r['names_by_source']} |")
    open(os.path.join(OUT, "summary.md"), "w").write("\n".join(L) + "\n")


if __name__ == "__main__":
    main()
