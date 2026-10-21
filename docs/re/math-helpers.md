# Fixed-point, angle and vector helpers in gta2.exe 11.44

GTA2 does almost all gameplay maths with three small C++ value classes: a Q14 fixed-point
number (`Fix16`), a 16-bit angle (`Ang16`) and a 2D vector of two `Fix16` (`Vec2`). Their
operators are out-of-line `__thiscall` functions, so every `a + b` in the source became a call such
as `Fix16_Add(&a, &tmp, &b)`, and these few helpers carry tens of thousands of cross-references.
This page is the reference for them: formats, units, every helper with its prototype, and how
the decompiled code reads now.

Every address is a VA in vanilla `gta2.exe` 11.44 (base `0x3F0000`); every name and prototype is
in the Ghidra DB (`gta-2-recovered.gpr`, program `gta2.segments.fixed.exe`) and therefore in `re/`.
"Verified" means the body was read in the disassembly (`ret N`, registers, shifts) and checked
in the decompiler; `unsure_` marks a hypothesis. Source: Seq 42 analysis, building on the
Seq 33 car-physics pass (its comments are kept in Ghidra) and Seq 37's ped work.

## 1. Formats and units

| Type | Storage | Meaning | 1.0 / full turn |
|---|---|---|---|
| `Fix16` | `int32`, **Q14** | value = raw / 16384 (`0x4000`). The name is historical: it is not Q16. Same format as the mission-script `SCR_f` | 1.0 = `0x4000` |
| `Ang16` | `int16` | angle units, **1440 per turn** (`0x5A0`), 4 per degree, kept wrapped in 0..1439 | 90° = 360, 180° = 720, 270° = 1080 |
| `Vec2` | `{Fix16 x; Fix16 y;}`, 8 bytes | 2D point / velocity / direction | |

- **World units**: a `Fix16` position is in map blocks — 1 block = 1.0 = `0x4000` raw (car and ped
  positions, see [car-physics.md](car-physics.md) §1). Speeds are blocks per tick.
- **Heading convention**: angle 0 points along **+y**, 90° along **+x**. `Vec2_FromPolar` and
  `Ang16_PolarToXY` build `x = len·sin(a)`, `y = len·cos(a)`; `Ang16_ATan2` is the inverse
  (`atan2(x, y)` in C terms).
- **"Radians"**: angular velocity and a few physics angles are a `Fix16` holding
  `Ang16 × 71` raw (`Ang16_ToFix16` / `Fix16_ToAng16`). 1440 × 71 / 16384 = 6.2402, the game's
  2π (0.7 % short); `g_Fix16TwoPi` 0x5D7DE8 = raw `0x18F60` is that value.
- **Rounding**: `Fix16_ToInt` is `SAR 14` (toward −∞: −0.5 → −1). `Fix16_Mul` is
  `(int64)a·b >> 14` (64-bit product, floor). `Fix16_Div` is `((int64)a << 14) / b` with signed
  `__alldiv` (toward zero, **no zero check**). `Fix16_FromDouble` truncates (`__ftol`). Add, sub,
  neg and the `*Int` helpers wrap silently on 32-bit overflow; nothing saturates.
- **Tables**: `g_Fix16SinTable` 0x5D3938, `g_Fix16CosTable` 0x5D6718 and `g_Fix16TanTable` 0x5D5090
  are `Fix16[1440]`, indexed by `Ang16`, filled at CRT start-up with `fsin`/`fcos`/`fptan` of
  `i·π/720` (`Fix16Table_Init*`). `Ang16_Sin/Cos` are plain table loads, no interpolation.
- **Constants**: `g_Ang16_0/90/180/270` (0x5D3900, 0x5D7E2C, 0x5D5074, 0x5D4FFC), `g_Ang16PerDegree`
  0x5D5040 (= 4), `g_Fix16Zero_Math` 0x5D4FE4 (another copy of 0 is `g_Fix16Zero` 0x66ACDC).
  Constants that are zero in the file image are set by CRT initialisers: read them from
  `re/static_constants.csv`.

### Why `Ang16_MulFix16` has 1947 references

`Ang16_MulFix16` (0x401CB0) is the census's top unnamed function, but 1916 of its calls are CRT
static initialisers between 0x4E0000 and 0x56C000. A header defines a per-degree angle constant
(4 units) as a `static`, so **each translation unit has its own copy** (0x5D5040, 0x664E00,
0x66A030, 0x5E4E74, …, each initialised from a `short 4` such as .rdata 0x573F40), and every
degree constant in the game is built at start-up as `copy * Fix16(degrees)`:

```c
// 0x4EBA70, CRT initialiser of g_Ang16_90
Fix16 deg; Fix16_FromInt(&deg, 90);              // deg = 90.0 (raw 0x168000)
Ang16_MulFix16(&g_Ang16PerDegree, &g_Ang16_90, &deg);   // 4 * 90 = 360
```

The same pattern explains `Fix16_FromRaw` (7083 refs) and `Fix16_FromInt` (6550 refs): they
initialise thousands of `Fix16` constants (`Fix16_FromRaw(&k, 0x1333, 0)` = 0.3).

## 2. Calling conventions as typed in Ghidra

The value classes' methods are MSVC `__thiscall` (object in `ECX`, the rest on the stack, callee
pops). Ghidra's `__thiscall` would keep `this` as an untyped auto-parameter, so these helpers use
**custom storage** instead: the object is an ordinary first parameter of the right type pinned
to `ECX`, and the stack parameters follow at `Stack[0x4]`, `Stack[0x8]`. The prototype therefore
reads `__stdcall` in `re/functions.csv`, but the storage is exact. Helpers that take only the
object are `__fastcall(T *self)` (ECX), and true `__stdcall` ones are typed as such.

Operators that return a value take a **caller-provided result slot** (`out`) and return it; they
never return a struct in `EAX`. Two quirks:

- `Fix16_FromRaw(self, raw, unused)`, `Ang16_Assign(self, src, unused)` and
  `Ang16_FromFix16(self, value, unused)` pop an extra stack word: every caller pushes 0 (an
  overload tag of the original constructors).
- Several helpers exist as byte-identical copies in different modules (`Fix16_FromInt`/`B`/`C`,
  `Fix16_ToInt`/`B`/`C`/`D`, `Fix16_ToFloat`/`B`, `Vec2_Set`/`B`): inline functions the linker did
  not fold. Their semantics are identical.

## 3. Reference table

### Fix16

| Address | Name | Prototype | Semantics |
|---|---|---|---|
| 0x401AD0 | `Fix16_FromRaw` | `Fix16 *(Fix16 *self /*ECX*/, int raw, int unused)` | `*self = raw` (no shift) |
| 0x401AE0 | `Fix16_FromInt16` | `Fix16 *(Fix16 *self, short value)` | `*self = value << 14` |
| 0x401AF0 | `Fix16_FromInt` | `Fix16 *(Fix16 *self, int value)` | `*self = value << 14`; copies 0x40CE00 `…B`, 0x41F980 `…C` |
| 0x40CE30 | `Fix16_FromUChar` | `Fix16 *(Fix16 *self, uchar value)` | `*self = (value & 0xFF) << 14` |
| 0x41F990 | `Fix16_FromUShort` | `Fix16 *(Fix16 *self, ushort value)` | `*self = (value & 0xFFFF) << 14` |
| 0x40E510 | `Fix16_FromDouble` | `Fix16 *(Fix16 *self, double value)` | `__ftol(value · 16384)` |
| 0x403770 | `Fix16_DefaultCtor` | `Fix16 *__fastcall(Fix16 *self)` | empty ctor (element ctor of the tables) |
| 0x401B00 | `Fix16_ToInt` | `int __fastcall(Fix16 *self)` | `*self >> 14` (floor); copies 0x41C1E0, 0x41F9D0, 0x41F9E0 |
| 0x401B10 | `Fix16_ToFloat` | `float __fastcall(Fix16 *self)` | `*self · (1/16384)` in ST0; copy 0x410BA0 |
| 0x40F4B0 | `Fix16_GetRaw` | `int __fastcall(Fix16 *self)` | `*self` |
| 0x4754D0 | `Fix16_GetValue` | `int __stdcall(Fix16 *value)` | `*value` |
| 0x401B20 | `Fix16_Add` | `Fix16 *(Fix16 *a /*ECX*/, Fix16 *out, Fix16 *b)` | `*out = *a + *b` |
| 0x401B40 | `Fix16_Sub` | same | `*out = *a − *b` |
| 0x401B60 | `Fix16_Mul` | same | `*out = (int64)*a · *b >> 14` |
| 0x401B90 | `Fix16_Div` | same | `*out = ((int64)*a << 14) / *b` |
| 0x401BD0 | `Fix16_MulInt` | `Fix16 *(Fix16 *a, Fix16 *out, int *n)` | `*out = *a · *n` (raw) |
| 0x401BF0 | `Fix16_DivInt` | `Fix16 *(Fix16 *a, Fix16 *out, int *n)` | `*out = *a / *n` (raw) |
| 0x403780 | `Fix16_Neg` | `Fix16 *(Fix16 *a, Fix16 *out)` | `*out = −*a` |
| 0x403840 | `Fix16_Abs` | `Fix16 *__stdcall(Fix16 *out, Fix16 *v)` | `*out = |*v|` |
| 0x40E530 / 0x40E550 | `Fix16_AddAssign` / `Fix16_SubAssign` | `Fix16 *(Fix16 *a, Fix16 *b)` | `*a ±= *b` |
| 0x41E0D0 / 0x48A1A0 | `Fix16_MulAssign` / `Fix16_DivAssign` | `Fix16 *(Fix16 *a, Fix16 *b)` | `*a = *a·*b`, `*a = *a / *b` (Q14) |
| 0x4037E0 0x403800 0x40CE50 0x40CE70 0x40E570 0x403820 | `Fix16_IsLess`, `IsGreater`, `IsLessEqual`, `IsGreaterEqual`, `IsEqual`, `IsNotEqual` | `int (Fix16 *a, Fix16 *b)` | signed compare, 0/1 |
| 0x41E130 | `Fix16_Max` | `Fix16 *__stdcall(Fix16 *out, Fix16 *a, Fix16 *b)` | `max(a, b)` |
| 0x49E2C0 | `Fix16_Max3` | `Fix16 *__stdcall(Fix16 *out, Fix16 *a, Fix16 *b, Fix16 *c)` | `max(a, b, c)` (was `Fix16_Median3`) |
| 0x49E0E0 | `Fix16_Square` | `Fix16 *__stdcall(Fix16 *out, Fix16 *v)` | `v·v` |
| 0x410C10 | `Fix16_Sqrt` | `Fix16 *__stdcall(Fix16 *out, Fix16 *v)` | x87 `fsqrt`, truncated |
| 0x482730 | `Fix16_ApplyDeadZone` | `Fix16 *__stdcall(Fix16 *out, Fix16 *v)` | `|v| < 0x6658DC ? 0 : v` |
| 0x40E790 | `Fix16_WrapRadians` | `Fix16 *__stdcall(Fix16 *out, Fix16 value)` | wrap into `[0, g_Fix16TwoPi)`; value by value |
| 0x41E160 | `Fix16_RangesOverlap` | `bool __stdcall(Fix16 *aMin, Fix16 *aMax, Fix16 *bMin, Fix16 *bMax)` | closed-interval overlap |
| 0x40F540 | `Fix16_ToAng16` | `Ang16 *__stdcall(Ang16 *out, Fix16 *radians)` | `wrap(raw / 71)` |

### Ang16

| Address | Name | Prototype | Semantics |
|---|---|---|---|
| 0x401C10 | `Ang16_Wrap` | `void __fastcall(Ang16 *self)` | add/sub 1440 until 0..1439 |
| 0x401C60 | `Ang16_Assign` | `Ang16 *(Ang16 *self, Ang16 *src, int unused)` | `*self = wrap(*src)` |
| 0x401C40 | `Ang16_FromFix16` | `Ang16 *(Ang16 *self, Fix16 *value, int unused)` | `*self = wrap(ToInt(value))` |
| 0x40E590 | `Ang16_SetZero` | `Ang16 *__fastcall(Ang16 *self)` | `= 0` |
| 0x40E5A0 / 0x40E5D0 | `Ang16_Add` / `Ang16_Sub` | `Ang16 *(Ang16 *a, Ang16 *out, Ang16 *b)` | `wrap(a ± b)` |
| 0x41FA70 / 0x41FA90 | `Ang16_AddAssign` / `Ang16_SubAssign` | `Ang16 *(Ang16 *a, Ang16 *b)` | `a = wrap(a ± b)` |
| 0x401C80 | `Ang16_Neg` | `Ang16 *(Ang16 *a, Ang16 *out)` | `wrap(−a)` |
| 0x401CB0 | `Ang16_MulFix16` | `Ang16 *(Ang16 *a, Ang16 *out, Fix16 *f)` | `wrap(int(a · f))` (§1) |
| 0x40E600 | `Ang16_DivFix16` | `Ang16 *(Ang16 *a, Ang16 *out, Fix16 *d)` | `wrap(int(a / d))` |
| 0x40E640 | `Ang16_DivAng16` | `Fix16 *(Ang16 *a, Fix16 *out, Ang16 *b)` | `(a << 14) / b`, a ratio |
| 0x40E670 0x41E0F0 0x40E690 0x40F4C0 0x40F4E0 | `Ang16_IsGreater`, `IsLess`, `IsEqual`, `IsLessEqual`, `IsGreaterEqual` | `int (Ang16 *a, Ang16 *b)` | signed int16 compare, no wrap |
| 0x41E110 | `Ang16_IsRightAngle` | `bool __fastcall(Ang16 *self)` | `self ∈ {0, 360, 720, 1080}`; thunk 0x41E3C0 |
| 0x40E4D0 / 0x40E4F0 | `Ang16_GetQuadrant` / `Ang16_GetOctant` | `int __fastcall(Ang16 *self)` | `self / 360`, `self / 180` |
| 0x40EAB0 | `Ang16_AbsDelta` | `Ang16 *__stdcall(Ang16 *out, Ang16 *a, Ang16 *b)` | shortest distance 0..720 |
| 0x40EC20 | `Ang16_AbsDeltaDivAng16` | `Fix16 *__stdcall(Fix16 *out, Ang16 *a, Ang16 *b, Ang16 *d)` | shortest distance / d |
| 0x40EC80 | `Ang16_IsWithinHalfTurnAhead` | `bool __stdcall(Ang16 *a, Ang16 *b)` | `wrap(b − a) ≤ 720` |
| 0x40EB10 | `Ang16_Bisect` | `Ang16 *__stdcall(Ang16 *out, Ang16 *a, Ang16 *b)` | midpoint on the shorter arc (no callers) |
| 0x40EBB0 | `Ang16_SignedDeltaDivFix16` | `Ang16 *__stdcall(Ang16 *out, Ang16 *a, Ang16 *b, Fix16 *d)` | signed shortest delta / d (no callers) |
| 0x40EA70 | `Ang16_ClampSymmetric` | `void (Ang16 *a, Ang16 *limit)` | clamp to ±limit around 0 (no callers) |
| 0x40F500 / 0x40F520 | `Ang16_Sin` / `Ang16_Cos` | `Fix16 *__stdcall(Fix16 *out, Ang16 *a)` | table lookup |
| 0x40E810 | `Ang16_ArcTanFirstQuadrant` | `Ang16 *__stdcall(Ang16 *out, Fix16 *ratio)` | binary search of the tan table, 0..360 |
| 0x40E8D0 | `Ang16_ATan2` | `Ang16 *__stdcall(Ang16 *out, Fix16 *y, Fix16 *x)` | heading of (x, y), 0 = +y (§1) |
| 0x40F580 | `Ang16_ToFix16` | `Fix16 *__stdcall(Fix16 *out, Ang16 *a)` | `a · 71` raw |
| 0x41FC20 | `Ang16_PolarToXY` | `void __stdcall(Ang16 *angle, Fix16 *length, Fix16 *outX, Fix16 *outY)` | `x = len·sin`, `y = len·cos` |
| 0x472C00 | `Ang16_ToHeadingClass` | `int __stdcall(Ang16 *a)` | compass class 1..4 from four thresholds |
| 0x49E240 | `Ang16_FormatDegrees` | `wchar_t *__fastcall(Ang16 *self)` | `"%3.2f"` of `a · 0.25` into a static buffer |
| 0x40F390 0x40E6B0 0x40E720 | `Fix16Table_InitSin/Cos/Tan` | `Fix16 *__fastcall(Fix16 *table)` | CRT table builders |

### Vec2

| Address | Name | Prototype | Semantics |
|---|---|---|---|
| 0x401D20 | `Vec2_Set` | `Vec2 *(Vec2 *self, Fix16 *x, Fix16 *y)` | copy 0x432860 `Vec2_SetB` returns nothing |
| 0x41E1E0 / 0x45B0E0 / 0x45C030 | `Vec2_SetZero` / `Vec2_Clear` / `Vec2_CtorZero` | `__fastcall(Vec2 *self)` | `(0, 0)` |
| 0x40F5C0 / 0x40F600 | `Vec2_Add` / `Vec2_Sub` | `Vec2 *(Vec2 *a, Vec2 *out, Vec2 *b)` | per component |
| 0x40F680 / 0x4828C0 | `Vec2_AddAssign` / `Vec2_SubAssign` | `Vec2 *(Vec2 *a, Vec2 *b)` | per component |
| 0x40F640 / 0x40F760 | `Vec2_Neg` / `Vec2_NegAssign` | `(Vec2 *a, Vec2 *out)` / `__fastcall(Vec2 *self)` | `−v` |
| 0x41E1A0 / 0x4202E0 | `Vec2_MulFix16` / `Vec2_DivFix16` | `Vec2 *(Vec2 *a, Vec2 *out, Fix16 *s)` | `v · s`, `v / s` |
| 0x4202A0 / 0x49E360 | `Vec2_MulInt` / `Vec2_DivInt` | `Vec2 *(Vec2 *a, Vec2 *out, int *n)` | raw `· n`, `/ n` |
| 0x49E3A0 | `Vec2_MulAssignFix16` | `Vec2 *(Vec2 *a, Fix16 *s)` | `v ·= s` |
| 0x40F6B0 | `Vec2_RotateByAng16` | `void (Vec2 *self, Ang16 *a)` | `x' = x·c + y·s`, `y' = y·c − x·s` |
| 0x41E210 | `Vec2_FromPolar` | `void (Vec2 *self, Fix16 *length, Ang16 *a)` | `(len·sin a, len·cos a)` |
| 0x40F790 | `Fix16Vec2_GetAngle` | `Ang16 *(Vec2 *self, Ang16 *out)` | `Ang16_ATan2(out, &y, &x)` |
| 0x41E260 | `Fix16Vec2_GetLength` | `Fix16 *(Vec2 *self, Fix16 *out)` | `|x|` or `|y|` if the other is 0, else `sqrt(x² + y²)` |
| 0x420390 | `Vec2_Normalize` | `Vec2 *(Vec2 *self, Vec2 *out)` | `v / |v|`; a length of 0 retries on `v · 128` |
| 0x49E500 | `Vec2_Dot` | `Fix16 *__stdcall(Fix16 *out, Vec2 *a, Vec2 *b)` | `a.x·b.x + a.y·b.y` |
| 0x49E420 | `Vec2_Perpendicular` | `Vec2 *(Vec2 *self, Vec2 *out)` | `(−y, x)` |
| 0x420360 / 0x49E450 | `Fix16Vec2_IsZero` / `Vec2_HasZeroComponent` | `__fastcall(Vec2 *self)` | both zero / either zero |
| 0x49E3C0 | `Vec2_ApplyDeadZone` | `void __fastcall(Vec2 *self)` | `|x| + |y| < 1/256` → `(0, 0)` |
| 0x49E480 | `Fix16Vec2_ClampTowardsZero` | `void (Vec2 *self, Vec2 *limit)` | per component, only shrinks |

Prototypes written without a convention are the custom-storage `__thiscall` form of §2 (first
parameter in `ECX`).

### Neighbours that are not math

- 0x401CF0 `vector_constructor_iterator(array, elemSize, count, ctor)` — the MSVC helper.
- 0x401000–0x402FFF outside 0x401AD0–0x401D40 is an **unreferenced float 3D node library**
  (Euler-angle nodes, a 3×4 float matrix stack at 0x599EC0, vertex transform): `Mat34f_Mul`
  0x401180 plus `unsure_Mat34f_*` / `unsure_Node3D_*`. No outside callers (dead code); several of
  its chunks are not even functions in Ghidra.
- 0x41E2F0 `unsure_Box3_Overlaps` — three `Fix16_RangesOverlap` tests; collision owns the struct.
- Census candidates that turned out to belong to other owners (facts sent, not renamed):
  0x416B50 (Ped field +0x1B4 getter), 0x4207B0 (`(x, y)` at +0x14/+0x18, probably a sprite),
  0x41E440/0x41E450 (`Car_GetSpriteY/Z`, siblings of `Car_GetSpriteX` 0x41E430), 0x41BF90 (police
  radio queue), 0x462FF0 (slope-table entry ctor for `MapBlocks_InitSlopeTable`), 0x40F7B0…0x40F830
  (sprite / trailer field accessors).

## 4. Worked example: `CarPhysics_LimitSpeed` 0x4A1B20

The car speed cap, as the decompiler shows it now (parameter of the outer function still
untyped — it is a `CarPhysics *`, owned by Seq 27):

```c
void __fastcall CarPhysics_LimitSpeed(int param_1)
{
  ...
    local_c = *(Fix16 *)(g_CurCarEngineData + 0x28);          // cap = max_speed
    self = (Vec2 *)(param_1 + 0x40);                           // linVel
    a = Fix16Vec2_GetLength(self, &local_10);                  // |linVel|
    if (Fix16_IsGreater(a, &local_c) != 0) {                   // |v| > cap
      a_00 = Fix16Vec2_GetAngle(self, (Ang16 *)&local_10);     // heading of v
      Vec2_FromPolar(&local_8, &local_c, a_00);                // capped vector
      Fix16Vec2_ClampTowardsZero(self, &local_8);              // shrink, never grow
    }
}
```

Read as source: `if (|v| > cap) v = clampTowardsZero(v, polar(cap, angle(v)))`. With
`max_speed` = 0.5 blocks/tick (raw `0x2000`) and `v = (0x3000, 0x3000)`: `Fix16_Mul(0x3000,
0x3000) = 0x2400`, the sum `0x4800`, `Fix16_Sqrt` → 1.06 (raw `0x43E1`) > 0.5; the angle is
`Ang16_ATan2(&y, &x)` = 90° − atan(1) = 180 units (45°; ±1 unit depending on where the binary
search of the `fptan` table lands); `Vec2_FromPolar(0x2000, 180)` = `(0x2000·sin, 0x2000·cos)`
= `(0x16A0, 0x16A0)` (0.354 each), and the clamp replaces both components because they are
smaller. Before this pass the same body read `FUN_0041e260(param_1 + 0x40, &local_10)` with
`void *` operands and a hidden ECX.

The prototypes are also exact at the binary level, which matters for host code that calls these
helpers from NASM: put the object in `ECX`, push the stack arguments right to left, and the
callee pops them (`ret 4/8/0x10`).
