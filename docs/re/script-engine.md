# GTA2 mission-script engine (11.44)

How vanilla `gta2.exe` 11.44 loads a `.scr` mission script and runs it: the file layout, the VM
structures, the two dispatch passes and every opcode handler with its Ghidra name. Addresses are
11.44 VAs, 1:1 with the Ghidra program `gta2.segments.fixed.exe` and with `re/`. Everything named
here is saved in the `gta-2-recovered` Ghidra project (Seq 34) and reaches `re/` through
`re/tools/export.sh`.

**Evidence levels**

- **V**: verified in the 11.44 code (decompile or `objdump` on `gta2.ebin`) and, for sizes and
  counts, against the shipped files in `data.pak`.
- **high / medium / low**: confidence of an opcode → handler → keyword assignment (see
  [How the opcode names were verified](#how-the-opcode-names-were-verified)).
- gta2_re names are cited as `Class::Name_XXXXXX`. The suffix is a **10.5** address. Do not read
  it as an 11.44 VA, with two measured exceptions: see
  [10.5 ↔ 11.44 address coincidences](#105--1144-address-coincidences).

## Overview

```
startGame ─► MissionScript_Load(g_MissionScript, "data\wil.scr")         0x47F280
             ├─ 12000 B pointer table, 65536 B code, u16 strlen, strings
             ├─ MissionScript_ParseStrings  0x475D30  (string index → Script4k)
             └─ MissionScript_LoadSubScripts 0x476070 (one .scr per "*.mis" string)
           ScriptLevelStart 0x481890
             ├─ FindScrCmdByType(LEVELSTART)
             ├─ ScriptThread_PreExecOpCode 0x481400   ← declaration pass, once
             └─ ScriptThread_Init(thread, LEVELSTART)  ← the main thread
GameTick ─► MissionScript_ExecuteScriptThreads 0x481900      every frame
             └─ ScriptThreadPool_UpdateNoDeallocate 0x481380
                  └─ ScriptThread_Update 0x481120   per live thread
                       └─ ScriptThread_ExecOpCode 0x4805B0  ← runtime dispatcher
                            └─ Script_Op_<KEYWORD>  (202 handlers, 406 opcodes)
```

## `.scr` file layout (V)

All little-endian. Checked against the 85 `.scr` files in `data.pak`. Decoder:
`tools/formats/scr.ts` (`bun tools/formats/cli.ts scr data/wil.scr --list`).

### Main script (`data/<map>.scr`, always 82656 bytes; 18 files)

| Offset | Size | Content | Lands in |
|---|---|---|---|
| `0x0000` | 12000 | `u16 ptr[6000]`: byte offset into the code of each pointer index (0 = unused) | `MissionScript+0x46C` `base_pointers` |
| `0x2EE0` | 65536 | code: commands, each starting with `SCR_CMD_HEADER` | `MissionScript+0x334C` `script` |
| `0x12EE0` | 2 | `u16` total size of the string area | local, passed to `ParseStrings` |
| `0x12EE2` | 5118 | strings: `{u16 id; u16 index; u32 type; u8 len; char text[len]}`, 9-byte header | `MissionScript+0x1334C` `ptrToStrings` |

`MissionScript_GetCmd` (`0x476200`) resolves a pointer index: `ptr[i] ? script + ptr[i] : NULL`.
Commands refer to each other, to variables and to objects only by **pointer index**, never by
byte offset.

`MissionScript_ParseStrings` walks the string area (`len + 9` per entry), resolves each name
through `FUN_00464d00(g_MapBlocks, …)` into the `u16` at +2, and stores the entry pointers in a
4000-byte `Script4k` (`u16 count; SCR_STRING_HEADER* strings[999]`).

### Sub-scripts (`data/<map>/<name>.scr`)

`MissionScript_LoadSubScripts` scans the strings for type `FILE_NAME_MISSIONS` (21): each such
string is a mission file name like `wil_tra.mis`. It rewrites the extension to `SCR` and loads
`data\<map name>\<file>`. Up to 30 sub-scripts; the first one found becomes slot 0, and so on.

| Offset | Size | Content | Lands in (slot `i`) |
|---|---|---|---|
| 0 | 2 | `u16 first`: global pointer index of local entry 0 | `+0xC1D72` `base_script_max_pointers[i]` |
| 2 | 2 | `u16 start`: global pointer index of the sub-script's `MISSIONSTART` (opcode 272 in all 67 files) | `+0xC1D34` `unk[i]` |
| 4 | 4 | `u32 size` of the code | `+0xC1DB0` `mission_script_size[i]` |
| 8 | 3072 | `u16 ptr[1536]`: local entry `j` is global pointer index `first + j` (every command's `cmd_this` equals `first + j`); values are **absolute** offsets in the shared code space | `+0xAA934` `missionScript[i]` |
| 3080 | `size` | code; its absolute origin is the smallest non-zero `ptr[j]`, so subtract that when parsing the file alone | `File_ReadRest` |

File size = `8 + 3072 + size`, `cmd_this == first + j` and `start` → `MISSIONSTART` hold for all 67
sub-scripts in the pak (e.g. `bil/bil_end.scr`: first 1129, start 1330, size 2380, file 5460).

## VM structures

### `SCR_CMD_HEADER` (8 bytes, every command)

| Off | Type | Name | Meaning |
|---|---|---|---|
| 0 | u16 | `cmd_this` | own pointer index |
| 2 | u16 | `type` | opcode (`SCR_CMD_TYPE`, gta2_re `SCRCMD_*` numbering) |
| 4 | u16 | `cmd_next` | pointer index of the next command; `0xFFFF` ends the thread |
| 6 | u16 | `return_value` | `1` = keep executing in the same frame (`ScriptThread_Update`) |

Arguments follow the header. Their layout per opcode is the `SCR_*` struct in the table below
(gta2_re names, e.g. `SCR_TWO_PARAMS`, `SCR_CHAR_OBJECTIVE`, `SCR_FOUR_PARAMS`). Handlers read
them through `g_ScriptCurCmd` (`0x6644CC`).

### `ScriptThread` (0x11C = 284 bytes; gta2_re `miss2_0x11C`) (V)

| Off | Type | Name | Evidence |
|---|---|---|---|
| 0x000 | `ScriptThread*` | `pool_next` | pool links, `ScriptThreadPool_Allocate` `0x4767A0` |
| 0x004 | u16 | `next_cmd` | `ScriptThread_Next` `0x476E50`, `EndCmd` writes `0xFFFF` |
| 0x006 | u8 | `flag_6` | copied by `ScriptThread_SpawnThread` `0x47ECB0` |
| 0x008 | s32 | `cond_result` | IF / compare handlers |
| 0x00C | u8 | `cmd_initialised` | cleared by `Next`; set by multi-frame commands (DELAY, phone) |
| 0x00E | s16 | `phone_timer` | phone templates |
| 0x010 | u8 | `stopped` | `ScriptThread_Update` returns at once; STOP_THREAD sets it |
| 0x012 | s16 | `exec_flag` | `EXEC` / `ENDEXEC` nesting; `Update` loops while > 0 |
| 0x014 | char[256] | `str` | scratch string |
| 0x114 | ptr | `gosub_stack` | GOSUB / RETURN frames (gta2_re `miss2_8*`) |
| 0x118 | u8 | `in_level_start` | `ScriptThread_AssignId` clears it |
| 0x11A | s16 | `thread_id` | `ScriptThread_AssignId`: `g_ScriptNextThreadId` (`0x5931F8`)++ |

### `ScriptThreadPool` (0x8EC bytes; global `g_ScriptThreadPool` `0x6644C0`) (V)

`+0 free_list`, `+4 active_list`, `+8 ScriptThread threads[8]`, `+0x8E8 s16 active_count`.
At most **8 threads** live at once. `ScriptThreadPool_Ctor` (`0x481310`, was `InitS16`) links the
free list; `ScriptThreadPool_UpdateNoDeallocate` runs every active thread and moves finished ones
(`ScriptThread_Update` returned 1) back to the free list.

### `MissionScript` (`g_MissionScript`, `0x6644BC`; gta2_re `ScriptManager_C1EA8`)

0xC1EA8 bytes in 10.5. The fields used here are in the tables above (`base_pointers +0x46C`,
`script +0x334C`, `ptrToStrings +0x1334C`, `pScript4k +0x13350`, the sub-script arrays at
`+0xAA934…+0xC1DB0`), plus `pathToScriptFile +0x35C` and `name +0x45C` (map name used for the
sub-script directory). The rest of the struct (car/phone triggers, weapon-hit records, flags at
`+0xC1E2C…`) is only partly typed. Not retyped in this pass.

### `MissionCleanupList` (0x25C bytes; `g_MissionCleanup` `0x6644B8`; gta2_re `Miss2_25C`) (V)

`MissionCleanupEntry entries[50]` at 0 and `u8 count` at `+0x258`. Each 12-byte entry is
`{void* entity; u8 type; u8 pad[3]; s32 entity_id}`. `type` is 1 for a car, 2 for an object and
3 for a ped (gta2_re `push_type_*`). `MissionCleanup_PushObject` stores type 2 and takes the id
from `obj+0x14`. The list holds what a mission created; `MissionCleanUp` deletes it when the
mission ends. Helpers: `MissionCleanup_Ctor` `0x474E50`, `MissionCleanup_FindFreeEntry`
`0x474E80` (the first slot with `entity == NULL`).

### Globals (V)

| VA | Name | gta2_re 10.5 |
|---|---|---|
| `0x6644B8` | `g_MissionCleanup` (was `ptrToS17Mission`) | `gMiss2_25C_6F805C` |
| `0x6644BC` | `g_MissionScript` | `gScriptManager_6F8060` |
| `0x6644C0` | `g_ScriptThreadPool` (was `ptrToS16_missions`) | `miss2_0x11C_Pool_6F8064` |
| `0x6644C4` | `g_ListNodePool` (GOSUB frame pool, name kept) | `gScriptStackFramePool_6F8068` |
| `0x6644C8` | `g_ScriptPrevCmdIdx` | `gPrevCmdIdx_6F806C` |
| `0x6644CC` | `g_ScriptCurCmd` | `gBasePtr_6F8070` |
| `0x6646BC` | `g_SavedAnsweredPhoneBits` | — |
| `0x6646C0` | `g_SavedDoneBasicKfBits` | — |
| `0x5931F8` | `g_ScriptNextThreadId` | — |

## Dispatch (V)

**Runtime: `ScriptThread_ExecOpCode` `0x4805B0`** (gta2_re `ExecOpCode_5061C0`). The thread is
passed in EDX. Index = `type - 0x29` (range 0..0x195, opcodes 41..446). A byte table at
`0x480F80` maps it to a case; the dword table at `0x480C50` maps the case to a stub
`mov ecx, edx; pop esi; jmp handler`. 406 opcodes reach 202 distinct handlers. Out of range or
case `default` → `0x480C46`, which just calls `ScriptThread_Next`.

**Declaration pass: `ScriptThread_PreExecOpCode` `0x481400`** (gta2_re `PreExecOpCode_5108D0`).
Runs once from `ScriptLevelStart`, over every command, before the first frame. Tables: byte
`0x4816B0[type-5]` (≤ 0xE1) → jump `0x481658`; type `0xF0` → `0x481583`; byte
`0x4817E8[type-0x113]` (≤ 0xA4) → jump `0x481794`; default `0x48162C`. 79 opcodes reach 36
handlers (`Script_Decl_*`): they create the level's static objects (cars, peds, objects, cranes,
doors, generators, gangs, lights, trigger threads). Afterwards come
`MissionScript_RestoreAnsweredPhones` and `ScriptThread_DisableBasicKfsFromSave` (state from the
save file).

**Per-frame step: `ScriptThread_Update` `0x481120`** (gta2_re `PoolUpdate_511840`). It returns 1
when the thread is stopped or `next_cmd == 0xFFFF`. Otherwise it first runs
`ScriptThread_MissionFailOnArrest` (`0x47F550`, was `JobFailed`), then:

- `EXEC`: dispatches in a loop while `exec_flag > 0` (the whole `EXEC … ENDEXEC` block runs in
  one frame);
- `return_value == 1`: keeps dispatching while each command has `return_value == 1`;
- anything else: exactly one command per frame.

Handlers advance with `ScriptThread_Next` (`0x476E50`: `g_ScriptPrevCmdIdx = next_cmd;
next_cmd = cmd.cmd_next; cmd_initialised = 0`, or `EndCmd` when `cmd_next == 0xFFFF`). Jumps use
`ScriptThread_JumpToCmd` (`0x476E80`). A command that is not finished (DELAY, waits) simply does
not call `Next`, so it runs again next frame.

**Opcodes without a handler** (57 of 447) are not a gap:

- Storage declarations (`CHAR_DATA`, `CAR_DATA`, `OBJ_DATA`, `COUNTER`, `SAVED_COUNTER`,
  `TIMER_DATA`, `ONSCREEN_COUNTER`, `SOUND`, `LIGHT`, …) are data slots. Other commands reach
  them by pointer index.
- Pure control-flow nodes (`GOTO`, `DO_NOWT`, `MISSIONSTART`, `FUNCTION`, `BONUS`) take the
  runtime default → `Next`. The compiler already put the target in `cmd_next`.

15 of them occur in `bil.scr`.

## Opcode table

Columns:

- **op**: the opcode value.
- **DMA keyword**: our name, matched to DMA's `.mis` keywords. Suffixes `_1/_2/_2D/_3D/_STR`
  mark the argument variant.
- **gta2_re enum**: the `SCRCMD_*` name.
- **runtime / declaration handler**: the 11.44 address and its Ghidra name.
- **args**: the gta2_re argument struct.
- **bil.scr**: how many times the opcode occurs in `data/bil.scr` plus `data/bil/*.scr`.
- **conf**: confidence of the assignment.

Handlers shared by several opcodes are named after the group (`Script_Op_S_OP_I`,
`Script_Op_SET_DENSITY_RATIO`, …). Their plate comment lists every opcode.

| op | DMA keyword | gta2_re enum | runtime handler | declaration handler | args | bil.scr | conf |
|---|---|---|---|---|---|---|---|
| 0 | ZERO | 0 | — | — | — | 0 | — |
| 1 | UNUSED_1 | 1 | — | — | — | 0 | — |
| 2 | UNUSED_2 | 2 | — | — | — | 0 | — |
| 3 | UNUSED_3 | 3 | — | — | — | 0 | — |
| 4 | UNUSED_4 | 4 | — | — | — | 0 | — |
| 5 | PLAYER_PED | PLAYER_PED | — | `0x477140` Script_Decl_PLAYER_PED | — | 1 | high |
| 6 | CHAR_DATA | CHAR_DEC | — | — | — | 168 | — |
| 7 | CHAR_DATA_SET_2D | CHAR_DECSET_2D | — | `0x477560` Script_Decl_CHAR_DATA_SET | — | 0 | medium |
| 8 | CHAR_DATA_SET_3D | CHAR_DECSET_3D | — | `0x477560` Script_Decl_CHAR_DATA_SET | — | 0 | medium |
| 9 | CAR_DATA | CAR_DEC | — | — | — | 74 | — |
| 10 | CAR_DATA_SET_2D | CAR_DECSET_2D | — | `0x477290` Script_Decl_CAR_DATA_SET | — | 0 | medium |
| 11 | CAR_DATA_SET_3D | CAR_DECSET_3D | — | `0x477290` Script_Decl_CAR_DATA_SET | — | 0 | medium |
| 12 | CAR_DATA_SET_2D_STR | CAR_DECSET_2D_STR | — | `0x477290` Script_Decl_CAR_DATA_SET | — | 0 | medium |
| 13 | CAR_DATA_SET_3D_STR | CAR_DECSET_3D_STR | — | `0x477290` Script_Decl_CAR_DATA_SET | — | 0 | medium |
| 14 | OBJ_DATA | OBJ_DEC | — | — | — | 103 | — |
| 15 | OBJ_DATA_SET_2D | OBJ_DECSET_2D | — | `0x476ea0` Script_Decl_OBJ_DATA_SET | — | 0 | high |
| 16 | OBJ_DATA_SET_3D | OBJ_DECSET_3D | — | `0x476ea0` Script_Decl_OBJ_DATA_SET | — | 141 | high |
| 17 | OBJ_DATA_SET_2D_INT | OBJ_DECSET_2D_INT | — | `0x476ff0` Script_Decl_OBJ_DATA_SET_EXTRA | — | 0 | high |
| 18 | OBJ_DATA_SET_3D_INT | OBJ_DECSET_3D_INT | — | `0x476ff0` Script_Decl_OBJ_DATA_SET_EXTRA | — | 119 | high |
| 19 | OBJ_DATA_SET_2D_STR | OBJ_DECSET_2D_STR | — | `0x476ff0` Script_Decl_OBJ_DATA_SET_EXTRA | — | 0 | high |
| 20 | OBJ_DATA_SET_3D_STR | OBJ_DECSET_3D_STR | — | `0x476ff0` Script_Decl_OBJ_DATA_SET_EXTRA | — | 16 | high |
| 21 | COUNTER | COUNTER | — | — | — | 582 | — |
| 22 | COUNTER_SET | COUNTER_SET | — | — | — | 0 | — |
| 23 | ARROW_DATA | ARROW_DEC | — | `0x475290` Script_Decl_ARROW_DATA | — | 5 | high |
| 24 | THREAD_ID | THREAD_ID | — | — | — | 0 | — |
| 25 | CONVEYOR | CONVEYOR_DEC | — | — | — | 0 | — |
| 26 | CONVEYOR_SET1 | CONVEYOR_DECSET1 | — | `0x4777e0` Script_Decl_CONVEYOR_SET | — | 0 | high |
| 27 | CONVEYOR_SET2 | CONVEYOR_DECSET2 | — | `0x4777e0` Script_Decl_CONVEYOR_SET | — | 12 | high |
| 28 | GENERATOR | GENERATOR_DEC | — | — | — | 0 | — |
| 29 | GENERATOR_SET1 | GENERATOR_DECSET1 | — | `0x477870` Script_Decl_GENERATOR_SET | — | 0 | high |
| 30 | GENERATOR_SET2 | GENERATOR_DECSET2 | — | `0x477870` Script_Decl_GENERATOR_SET | — | 13 | high |
| 31 | GENERATOR_SET3 | GENERATOR_DECSET3 | — | `0x477870` Script_Decl_GENERATOR_SET | — | 0 | high |
| 32 | GENERATOR_SET4 | GENERATOR_DECSET4 | — | `0x477870` Script_Decl_GENERATOR_SET | — | 21 | high |
| 33 | DESTRUCTOR | DESTRUCTOR_DEC | — | — | — | 0 | — |
| 34 | DESTRUCTOR_SET1 | DESTRUCTOR_DECSET1 | — | `0x477920` Script_Decl_DESTRUCTOR_SET | — | 0 | high |
| 35 | DESTRUCTOR_SET2 | DESTRUCTOR_DECSET2 | — | `0x477920` Script_Decl_DESTRUCTOR_SET | — | 12 | high |
| 36 | CRANE_DATA | CRANE_DEC | — | — | — | 0 | — |
| 37 | CRANE_DATA_BASIC | CRANE_BASIC_DEC | — | `0x477660` Script_Decl_CRANE_DATA | — | 0 | high |
| 38 | CRANE_DATA_TARGET | CRANE_TARGET_DEC | — | `0x477660` Script_Decl_CRANE_DATA | — | 7 | high |
| 39 | CRANE_DATA_2TARGET | CRANE2TARGET_DEC | — | `0x477660` Script_Decl_CRANE_DATA | — | 1 | high |
| 40 | CRUSHER | CRUSHER_BASIC | — | `0x4752a0` Script_Decl_CRUSHER | — | 3 | high |
| 41 | CREATE_CHAR_2D | CREATE_CHAR_2D | `0x479610` Script_Op_CREATE_CHAR | — | SCR_CHAR_DATA_DEC | 0 | high |
| 42 | CREATE_CHAR_3D | CREATE_CHAR_3D | `0x479610` Script_Op_CREATE_CHAR | — | SCR_CHAR_DATA_DEC | 153 | high |
| 43 | CREATE_CAR_2D | CREATE_CAR_2D | `0x478b10` Script_Op_CREATE_CAR | — | SCR_CAR_DATA_DEC | 0 | high |
| 44 | CREATE_CAR_3D | CREATE_CAR_3D | `0x478b10` Script_Op_CREATE_CAR | — | SCR_CAR_DATA_DEC | 37 | high |
| 45 | CREATE_CAR_2D_STR | CREATE_CAR_2D_STR | `0x478b10` Script_Op_CREATE_CAR | — | SCR_CAR_DATA_DEC | 0 | high |
| 46 | CREATE_CAR_3D_STR | CREATE_CAR_3D_STR | `0x478b10` Script_Op_CREATE_CAR | — | SCR_CAR_DATA_DEC | 1 | high |
| 47 | CREATE_OBJ_2D | CREATE_OBJ_2D | `0x478a80` Script_Op_CREATE_OBJ | — | SCR_OBJ_DATA | 30 | high |
| 48 | CREATE_OBJ_3D | CREATE_OBJ_3D | `0x478a80` Script_Op_CREATE_OBJ | — | SCR_OBJ_DATA | 0 | high |
| 49 | CREATE_OBJ_3D_INT | CREATE_OBJ_3D_INT | `0x478a80` Script_Op_CREATE_OBJ | — | SCR_OBJ_DATA | 64 | high |
| 50 | CREATE_OBJ_2D_INT | CREATE_OBJ_2D_INT | `0x478a80` Script_Op_CREATE_OBJ | — | SCR_OBJ_DATA | 0 | high |
| 51 | CREATE_OBJ_3D_STR | CREATE_OBJ_3D_STR | `0x478a80` Script_Op_CREATE_OBJ | — | SCR_OBJ_DATA | 0 | high |
| 52 | CREATE_OBJ_2D_STR | CREATE_OBJ_2D_STR | `0x478a80` Script_Op_CREATE_OBJ | — | SCR_OBJ_DATA | 0 | high |
| 53 | CREATE_CONVEYOR_2D | CREATE_CONVEYOR_2D | — | — | — | 0 | — |
| 54 | CREATE_CONVEYOR_3D | CREATE_CONVEYOR_3D | — | — | — | 0 | — |
| 55 | CREATE_GENERATOR_2D | CREATE_GENERATOR_2D | — | — | — | 0 | — |
| 56 | CREATE_GENERATOR_3D | CREATE_GENERATOR_3D | — | — | — | 0 | — |
| 57 | CREATE_DESTRUCTOR_2D | CREATE_DESTRUCTOR_2D | — | — | — | 0 | — |
| 58 | CREATE_DESTRUCTOR_3D | CREATE_DESTRUCTOR_3D | — | — | — | 0 | — |
| 59 | LEVELSTART | LEVELSTART | `0x4784d0` Script_Op_LEVELSTART | — | — | 1 | high |
| 60 | LEVELEND | LEVELEND | `0x4756f0` Script_Op_LEVELEND | — | — | 1 | high |
| 61 | CREATE_THREAD | CREATE_THREAD | `0x47f890` Script_Op_CREATE_THREAD | — | SCR_TWO_PARAMS | 0 | medium |
| 62 | STOP_THREAD | STOP_THREAD | `0x478500` Script_Op_STOP_THREAD | — | SCR_CMD_HEADER | 0 | medium |
| 63 | EXEC | START_EXEC | `0x4789e0` Script_Op_EXEC | — | — | 2 | high |
| 64 | ENDEXEC | STOP_EXEC | `0x478a00` Script_Op_ENDEXEC | — | — | 10 | high |
| 65 | FOR | FOR_LOOP | — | — | — | 0 | — |
| 66 | DO_WHILE | DO_WHILE | — | — | — | 0 | — |
| 67 | FUNCTION | FUNCTION | — | — | — | 85 | — |
| 68 | RETURN | RETURN | `0x478610` Script_Op_RETURN | — | — | 196 | high |
| 69 | WHILE | WHILE | — | — | — | 0 | — |
| 70 | WHILE_EXEC | WHILE_EXEC | — | — | — | 0 | — |
| 71 | NOT | NOT | `0x4789c0` Script_Op_NOT | — | — | 234 | high |
| 72 | AND | AND | — | — | — | 0 | — |
| 73 | OR | OR | — | — | — | 0 | — |
| 74 | IF | IF | — | — | — | 0 | — |
| 75 | THEN | THEN | — | — | — | 0 | — |
| 76 | ELSE | ELSE | — | — | — | 0 | — |
| 77 | GOTO | GOTO | — | — | — | 99 | — |
| 78 | GOSUB | GOSUB | `0x4785d0` Script_Op_GOSUB | — | SCR_TWO_PARAMS | 51 | high |
| 79 | S_PLUS_I | S_PLUS_I | `0x478650` Script_Op_S_OP_I | — | SCR_OPERATE_COUNTER_AND_INT | 0 | medium |
| 80 | I_PLUS_S | I_PLUS_S | `0x4788a0` Script_Op_I_OP_S | — | SCR_OPERATE_INT_AND_COUNTER | 0 | medium |
| 81 | S_PLUS_S | S_PLUS_S | `0x478770` Script_Op_S_OP_S | — | SCR_OPERATE_COUNTER_AND_COUNTER_2 | 0 | medium |
| 82 | S_MINUS_I | S_MINUS_I | `0x478650` Script_Op_S_OP_I | — | SCR_OPERATE_COUNTER_AND_INT | 0 | medium |
| 83 | I_MINUS_S | I_MINUS_S | `0x4788a0` Script_Op_I_OP_S | — | SCR_OPERATE_INT_AND_COUNTER | 0 | medium |
| 84 | S_MINUS_S | S_MINUS_S | `0x478770` Script_Op_S_OP_S | — | SCR_OPERATE_COUNTER_AND_COUNTER_2 | 0 | medium |
| 85 | SET | SET | — | — | — | 0 | — |
| 86 | S_LESS_I | S_LESS_I | `0x478650` Script_Op_S_OP_I | — | SCR_OPERATE_COUNTER_AND_INT | 30 | medium |
| 87 | S_LESS_S | S_LESS_S | `0x478770` Script_Op_S_OP_S | — | SCR_OPERATE_COUNTER_AND_COUNTER_2 | 0 | medium |
| 88 | S_LEQUAL_I | S_LEQUAL_I | `0x478650` Script_Op_S_OP_I | — | SCR_OPERATE_COUNTER_AND_INT | 0 | medium |
| 89 | S_LEQUAL_S | S_LEQUAL_S | `0x478770` Script_Op_S_OP_S | — | SCR_OPERATE_COUNTER_AND_COUNTER_2 | 0 | medium |
| 90 | S_GREATER_I | S_GREATER_I | `0x478650` Script_Op_S_OP_I | — | SCR_OPERATE_COUNTER_AND_INT | 0 | medium |
| 91 | S_GREATER_S | S_GREATER_S | `0x478770` Script_Op_S_OP_S | — | SCR_OPERATE_COUNTER_AND_COUNTER_2 | 0 | medium |
| 92 | S_GEQUAL_I | S_GEQUAL_I | `0x478650` Script_Op_S_OP_I | — | SCR_OPERATE_COUNTER_AND_INT | 3 | medium |
| 93 | S_GEQUAL_S | S_GEQUAL_S | `0x478770` Script_Op_S_OP_S | — | SCR_OPERATE_COUNTER_AND_COUNTER_2 | 0 | medium |
| 94 | S_EQUAL_I | S_EQUAL_I | `0x478650` Script_Op_S_OP_I | — | SCR_OPERATE_COUNTER_AND_INT | 1314 | medium |
| 95 | S_EQUAL_S | S_EQUAL_S | `0x478770` Script_Op_S_OP_S | — | SCR_OPERATE_COUNTER_AND_COUNTER_2 | 0 | medium |
| 96 | INCREMENT | INCREMENT | `0x478a20` Script_Op_INCREMENT | — | — | 219 | medium |
| 97 | DECREMENT | DECREMENT | `0x478a50` Script_Op_DECREMENT | — | — | 4 | medium |
| 98 | IF_JUMP | IF_JUMP | `0x478590` Script_Op_IF_JUMP | — | SCR_IF_JUMP | 2233 | medium |
| 99 | FORWARD | FORWARD_DECLARE | — | — | — | 0 | — |
| 100 | MAKE_CAR_A_DUMMY | MAKE_CAR_DUMMY | `0x478ba0` Script_Op_MAKE_CAR_A_DUMMY | — | SCR_POINTER | 0 | medium |
| 101 | MAP_ZONE_1 | MAP_ZONE1 | — | — | — | 0 | — |
| 102 | MAP_ZONE | MAP_ZONE_SET | — | `0x475230` Script_Decl_MAP_ZONE | — | 38 | high |
| 103 | SET_CAR_DENSITY | SET_CAR_DENSITY | `0x478c00` Script_Op_SET_DENSITY_RATIO | — | SCR_MAP_SET_ZONE_INFO | 64 | high |
| 104 | SET_GOODCAR_RATIO | SET_GOOD_CAR | `0x478c00` Script_Op_SET_DENSITY_RATIO | — | SCR_MAP_SET_ZONE_INFO | 0 | high |
| 105 | SET_BADCAR_RATIO | SET_BAD_CAR | `0x478c00` Script_Op_SET_DENSITY_RATIO | — | SCR_MAP_SET_ZONE_INFO | 0 | high |
| 106 | SET_POLICECAR_RATIO | SET_POLICE_CAR | `0x478c00` Script_Op_SET_DENSITY_RATIO | — | SCR_MAP_SET_ZONE_INFO | 0 | high |
| 107 | SET_PEDDENSITY | SET_PED_DENSITY | `0x478c00` Script_Op_SET_DENSITY_RATIO | — | SCR_MAP_SET_ZONE_INFO | 34 | high |
| 108 | SET_MUGGER_RATIO | SET_MUGGER | `0x478c00` Script_Op_SET_DENSITY_RATIO | — | SCR_MAP_SET_ZONE_INFO | 0 | high |
| 109 | SET_CARTHIEF_RATIO | SET_CARTHIEF | `0x478c00` Script_Op_SET_DENSITY_RATIO | — | SCR_MAP_SET_ZONE_INFO | 0 | high |
| 110 | SET_ELVIS_RATIO | SET_ELVIS | `0x478c00` Script_Op_SET_DENSITY_RATIO | — | SCR_MAP_SET_ZONE_INFO | 0 | high |
| 111 | SET_GANG_RATIO | SET_GANG | `0x478c00` Script_Op_SET_DENSITY_RATIO | — | SCR_MAP_SET_ZONE_INFO | 0 | high |
| 112 | SET_POLICEPED_RATIO | SET_POLICE_PED | `0x478c00` Script_Op_SET_DENSITY_RATIO | — | SCR_MAP_SET_ZONE_INFO | 0 | high |
| 113 | POINT_ARROW_AT | POINT_ARROW_AT | `0x478e90` Script_Op_POINT_ARROW_AT | — | SCR_POINT_ARROW_AT | 117 | high |
| 114 | POINT_ARROW_AT_3D | POINT_ARROW_3D | `0x478e10` Script_Op_POINT_ARROW_AT_3D | — | — | 59 | high |
| 115 | SET_ARROW_COLOUR | ARROW_COLOUR | `0x478fb0` Script_Op_SET_ARROW_COLOUR | — | SCR_TWO_PARAMS | 0 | medium |
| 116 | REMOVE_ARROW | REMOVE_ARROW | `0x479010` Script_Op_REMOVE_ARROW | — | SCR_POINTER | 195 | high |
| 117 | DISPLAY_MESSAGE | DISPLAY_MESSAGE | `0x4792b0` Script_Op_DISPLAY_MESSAGE | `0x4755f0` Script_Decl_DISPLAY_MESSAGE | SCR_TWO_PARAMS | 175 | high |
| 118 | DISPLAY_BRIEF | DISPLAY_BRIEF | `0x4792b0` Script_Op_DISPLAY_MESSAGE | `0x4755f0` Script_Decl_DISPLAY_MESSAGE | SCR_TWO_PARAMS | 293 | high |
| 119 | DISPLAY_TIMER | DISPLAY_TIMER | `0x4795c0` Script_Op_DISPLAY_TIMER | — | SCR_TWO_PARAMS | 2 | high |
| 120 | CLEAR_TIMER | CLEAR_TIMERS | `0x47b360` Script_Op_CLEAR_TIMER | — | SCR_POINTER | 8 | high |
| 121 | IS_CHARACTER_IN_CAR | IS_CHAR_IN_CAR | `0x479b70` Script_Op_IS_CHARACTER_IN_CAR | — | SCR_TWO_PARAMS | 65 | high |
| 122 | IS_CHARACTER_IN_MODEL | IS_CHAR_IN_MODEL | `0x479bf0` Script_Op_IS_CHARACTER_IN_MODEL | — | SCR_TWO_PARAMS | 41 | high |
| 123 | IS_CHARACTER_IN_ANY_CAR | IS_CHAR_IN_ANY_CAR | `0x479c60` Script_Op_IS_CHARACTER_IN_ANY_CAR | — | SCR_POINTER | 29 | high |
| 124 | IS_CHARACTER_STOPPED | IS_CHAR_STOPPED | `0x479da0` Script_Op_IS_CHARACTER_STOPPED | — | SCR_POINTER | 0 | medium |
| 125 | IS_CHAR_STUNNED | IS_CHAR_STUNNED | `0x47c050` Script_Op_IS_CHAR_STUNNED | — | SCR_POINTER | 0 | medium |
| 126 | CHECK_CHARACTER_HEALTH | CHECK_HEALTH | `0x4790a0` Script_Op_CHECK_CHARACTER_HEALTH | — | SCR_TWO_PARAMS | 1 | high |
| 127 | HAS_CHARACTER_DIED | HAS_CHAR_DIED | `0x479b20` Script_Op_HAS_CHARACTER_DIED | — | — | 123 | high |
| 128 | STORE_CAR_CHARACTER_IS_IN | STORE_CAR_INFO | `0x4790f0` Script_Op_STORE_CAR_CHARACTER_IS_IN | — | — | 12 | high |
| 129 | CHECK_CAR_DAMAGE_LEVEL | CHECK_CAR_DAMAGE | `0x479050` Script_Op_CHECK_CAR_DAMAGE_LEVEL | — | SCR_TWO_PARAMS | 0 | medium |
| 130 | CHECK_CAR_HAS_DRIVER | CHECK_CAR_DRIVER | `0x47f9f0` Script_Op_CHECK_CAR_STATE | — | SCR_POINTER | 0 | high |
| 131 | SET_CHAR_OBJECTIVE_1 | SET_CHAR_OBJ1 | `0x4796a0` Script_Op_SET_CHAR_OBJECTIVE_1 | — | SCR_CHAR_OBJECTIVE | 93 | high |
| 132 | SET_CHAR_OBJECTIVE_2 | SET_CHAR_OBJ2 | `0x47a1e0` Script_Op_SET_CHAR_OBJECTIVE_2 | — | SCR_CHAR_OBJECTIVE | 102 | high |
| 133 | SET_CHAR_OBJECTIVE_3 | SET_CHAR_OBJ3 | `0x47a330` Script_Op_SET_CHAR_OBJECTIVE_3 | — | SCR_CHAR_OBJ3 | 91 | high |
| 134 | IS_CHAR_OBJECTIVE_PASSED | IS_CHAR_OBJ_PASS | `0x4796e0` Script_Op_IS_CHAR_OBJECTIVE_PASSED | — | SCR_POINTER | 88 | high |
| 135 | IS_CHAR_OBJECTIVE_FAILED | IS_CHAR_OBJ_FAIL | `0x479740` Script_Op_IS_CHAR_OBJECTIVE_FAILED | — | SCR_POINTER | 0 | medium |
| 136 | SEND_CHAR_ON_FOOT | SEND_CHAR_FOOT | — | — | — | 0 | — |
| 137 | SEND_CHAR_BY_ANY_MEANS | SEND_CHAR_CAR | — | — | — | 0 | — |
| 138 | GIVE_WEAPON_1 | GIVE_WEAPON1 | `0x4797a0` Script_Op_GIVE_WEAPON | — | SCR_TWO_PARAMS | 133 | high |
| 139 | IS_CAR_IN_BLOCK | IS_CAR_IN_BLOCK | `0x479850` Script_Op_IS_CAR_IN_BLOCK | — | SCR_IS_CAR_IN_BLOCK | 1 | medium |
| 140 | DELETE_ITEM | DELETE_ITEM | `0x47f8f0` Script_Op_DELETE_ITEM | — | — | 54 | high |
| 141 | ADD_SCORE_1 | ADD_SCORE1 | `0x479cc0` Script_Op_ADD_SCORE | — | SCR_FOUR_PARAMS | 23 | high |
| 142 | EXPLODE_POS | EXPLODE | `0x479e10` Script_Op_EXPLODE_POS | — | SCR_EXPLODE | 2 | medium |
| 143 | EXPLODE_WALL | EXPLODE_BUILDING | `0x479ea0` Script_Op_EXPLODE_WALL | — | SCR_EXPLODE_WALL | 0 | medium |
| 144 | EXPLODE_ITEM | EXPLODE_ITEM | `0x47c1e0` Script_Op_EXPLODE_ITEM | — | SCR_POINTER | 14 | medium |
| 145 | LOCATE_CHARACTER_ANY_MEANS | LOCATE_CHAR_ANY | `0x479f10` Script_Op_LOCATE_CHARACTER | — | SCR_ONEVAR_RECT | 19 | high |
| 146 | LOCATE_CHARACTER_ON_FOOT | LOCATE_CHAR_ONFOOT | `0x479f10` Script_Op_LOCATE_CHARACTER | — | SCR_ONEVAR_RECT | 10 | high |
| 147 | LOCATE_CHARACTER_BY_CAR | LOCATE_CHAR_BY_CAR | `0x479f10` Script_Op_LOCATE_CHARACTER | — | SCR_ONEVAR_RECT | 5 | high |
| 148 | LOCATE_STOPPED_CHARACTER_ANY_MEANS | STOP_LOCATE_CHAR_ANY | `0x479f10` Script_Op_LOCATE_CHARACTER | — | SCR_ONEVAR_RECT | 0 | high |
| 149 | LOCATE_STOPPED_CHARACTER_ON_FOOT | STOP_LOCATE_CHAR_FOOT | `0x479f10` Script_Op_LOCATE_CHARACTER | — | SCR_ONEVAR_RECT | 0 | high |
| 150 | LOCATE_STOPPED_CHARACTER_BY_CAR | STOP_LOCATE_CHAR_CAR | `0x479f10` Script_Op_LOCATE_CHARACTER | — | SCR_ONEVAR_RECT | 0 | high |
| 151 | SET_CHAR_THREAT_SEARCH | SET_THREAT_SEARCH | `0x47b9a0` Script_Op_SET_CHAR_AI_PARAM | — | SCR_CHAR_OBJECTIVE | 130 | high |
| 152 | SET_CHAR_THREAT_REACTION | SET_THREAT_REACT | `0x47b9a0` Script_Op_SET_CHAR_AI_PARAM | — | SCR_CHAR_OBJECTIVE | 173 | high |
| 153 | ADD_GROUP_TO_CHARACTER | ADD_GROUP | `0x47b9a0` Script_Op_SET_CHAR_AI_PARAM | — | SCR_CHAR_OBJECTIVE | 52 | high |
| 154 | IS_CAR_WRECKED | IS_CAR_WRECKED | `0x47f9f0` Script_Op_CHECK_CAR_STATE | — | SCR_POINTER | 56 | high |
| 155 | CHANGE_CAR_REMAP | CHANGE_CAR_REMAP | `0x47a460` Script_Op_CHANGE_CAR_REMAP | — | SCR_TWO_PARAMS | 0 | medium |
| 156 | CHANGE_CHAR_REMAP | CHANGE_CHAR_REMAP | `0x47a4a0` Script_Op_CHANGE_CHAR_REMAP | — | SCR_TWO_PARAMS | 0 | medium |
| 157 | CHECK_CAR_MODEL | CHECK_CAR_MODEL | `0x47a4e0` Script_Op_CHECK_CAR_MODEL | — | SCR_TWO_PARAMS | 3 | high |
| 158 | CHECK_CAR_REMAP | CHECK_CAR_REMAP | `0x47a530` Script_Op_CHECK_CAR_REMAP | — | SCR_TWO_PARAMS | 0 | medium |
| 159 | CHECK_CAR_MODEL_AND_REMAP | CHECK_CAR_BOTH | `0x47a5a0` Script_Op_CHECK_CAR_MODEL_AND_REMAP | — | SCR_FOUR_PARAMS | 0 | medium |
| 160 | IS_ITEM_ONSCREEN | IS_ITEM_ONSCREEN | `0x47a620` Script_Op_IS_ITEM_ONSCREEN | — | SCR_POINTER | 13 | high |
| 161 | DELAY_HERE | DELAY_HERE | `0x47a7e0` Script_Op_DELAY_HERE | — | SCR_CMD_HEADER | 38 | high |
| 162 | DELAY | DELAY | `0x47a810` Script_Op_DELAY | — | SCR_CMD_HEADER | 56 | high |
| 163 | CLEAR_WANTED_LEVEL | CLEAR_WANTED_LEVEL | `0x47b780` Script_Op_CLEAR_WANTED_LEVEL | — | SCR_POINTER | 65 | high |
| 164 | ALTER_WANTED_LEVEL | ALT_WANTED_LEVEL | `0x47b7b0` Script_Op_ALTER_WANTED_LEVEL | — | SCR_CMD_ALTER_WANTED_LEVEL | 1 | high |
| 165 | IS_CHAR_FIRING_ONSCREEN | IS_CHAR_FIRE_ONSCREEN | `0x47b0c0` Script_Op_IS_CHAR_FIRING_ONSCREEN | — | SCR_POINTER | 0 | medium |
| 166 | ORDER_DRIVER_OUT_CAR | DRIVER_OUT_CAR | `0x47b270` Script_Op_ORDER_DRIVER_OUT_CAR | — | SCR_POINTER | 0 | medium |
| 167 | ORDER_CHAR_TO_DRIVE_CAR | CHAR_TO_DRIVE_CAR | `0x47b1d0` Script_Op_ORDER_CHAR_TO_DRIVE_CAR | — | SCR_CHAR_ENTER_CAR | 0 | high |
| 168 | ANSWER_PHONE | ANSWER_PHONE | `0x47aea0` Script_Op_ANSWER_PHONE | — | SCR_ANSWER_PHONE | 0 | medium |
| 169 | ORDER_CAR_TO_BLOCK | SEND_CAR_TO_BLOCK | `0x47b950` Script_Op_ORDER_CAR_TO_BLOCK | — | SCR_CAR_DATA_DEC | 0 | medium |
| 170 | GIVE_DRIVER_AND_BRAKE | GIVE_DRIVER_BRAKE | `0x47b2d0` Script_Op_GIVE_DRIVER_AND_BRAKE | — | SCR_POINTER | 0 | medium |
| 171 | ORDER_CHAR_TO_BACKDOOR | CHAR_TO_BACKDOOR | `0x47b1d0` Script_Op_ORDER_CHAR_TO_DRIVE_CAR | — | SCR_CHAR_ENTER_CAR | 6 | high |
| 172 | PLAY_SOUND | PLAY_SOUND | — | — | — | 0 | — |
| 173 | SET_CAR_NO_COLLIDE | SET_NO_COLLIDE | `0x47b580` Script_Op_SET_CAR_NO_COLLIDE | — | SCR_POINTER | 10 | high |
| 174 | CLEAR_CAR_NO_COLLIDE | CLEAR_NO_COLLIDE | — | — | — | 0 | — |
| 175 | MAKE_CAR_DRIVE_AWAY | CAR_DRIVE_AWAY | `0x47b130` Script_Op_MAKE_CAR_DRIVE_AWAY | — | SCR_POINTER | 1 | high |
| 176 | IS_CHAR_FIRING_IN_AREA | IS_CHAR_FIRING_AREA | `0x47b5e0` Script_Op_IS_CHAR_FIRING_IN_AREA | — | SCR_ONEVAR_RECT | 0 | medium |
| 177 | OPEN_DOOR | OPEN_DOOR | `0x47c4d0` Script_Op_DOOR_CONTROL | — | SCR_POINTER | 39 | high |
| 178 | CLOSE_DOOR | CLOSE_DOOR | `0x47c4d0` Script_Op_DOOR_CONTROL | — | SCR_POINTER | 13 | high |
| 179 | MAKE_DOOR_AUTOMATIC | SET_DOOR_AUTO | `0x47c4d0` Script_Op_DOOR_CONTROL | — | SCR_POINTER | 9 | high |
| 180 | MAKE_DOOR_MANUAL | SET_DOOR_MANUAL | `0x47c4d0` Script_Op_DOOR_CONTROL | — | SCR_POINTER | 30 | high |
| 181 | SWITCH_ROAD | ROAD_ON_OFF | `0x47c6f0` Script_Op_SWITCH_ROAD | — | SCR_SWITCH_ROAD_ON_OFF | 0 | medium |
| 182 | ADD_NEW_BLOCK | ADD_NEW_BLOCK | `0x47c6a0` Script_Op_ADD_NEW_BLOCK | — | SCR_ADD_BLOCK | 5 | high |
| 183 | REMOVE_BLOCK | REMOVE_BLOCK | `0x47c5e0` Script_Op_REMOVE_BLOCK | — | SCR_REMOVE_BLOCK | 0 | medium |
| 184 | LOWER_LEVEL | LOWER_LEVEL | `0x47c620` Script_Op_LOWER_LEVEL | — | SCR_LOWER_LEVEL | 2 | high |
| 185 | CHANGE_BLOCK_SIDE | CHANGE_BLOCK_SIDE | `0x47c660` Script_Op_CHANGE_BLOCK | — | SCR_CHANGE_BLOCK | 54 | medium |
| 186 | CHANGE_BLOCK_LID | CHANGE_BLOCK_LID | `0x47c660` Script_Op_CHANGE_BLOCK | — | SCR_CHANGE_BLOCK | 56 | medium |
| 187 | CHANGE_BLOCK_TYPE | CHANGE_BLOCK_TYPE | `0x47c660` Script_Op_CHANGE_BLOCK | — | SCR_CHANGE_BLOCK | 36 | medium |
| 188 | GET_CAR_INFO_FROM_CRANE | GET_CAR_FROM_CRANE | `0x47b160` Script_Op_GET_CAR_INFO_FROM_CRANE | — | SCR_TWO_PARAMS | 3 | high |
| 189 | CHECK_CAR_WRECKED_IN_AREA | CAR_WRECK_IN_LOCATION | `0x47b810` Script_Op_CHECK_CAR_WRECKED_IN_AREA | — | SCR_ONEVAR_RECT | 0 | medium |
| 190 | HAS_CAR_JUST_SUNK | CAR_SUNK | `0x47f9f0` Script_Op_CHECK_CAR_STATE | — | SCR_POINTER | 1 | high |
| 191 | IS_CAR_IN_AIR | CAR_IN_AIR | `0x47f9f0` Script_Op_CHECK_CAR_STATE | — | SCR_POINTER | 0 | high |
| 192 | CHECK_NUM_LIVES_GREATER | CHECK_NUM_LIVES | `0x47cae0` Script_Op_LIVES_MULTIPLIER | — | SCR_GET_NUM_LIVES_MULTIPLIERS | 0 | high |
| 193 | STORE_NUM_LIVES | GET_NUM_LIVES | `0x47cc50` Script_Op_STORE_LIVES_MULTIPLIER | — | — | 0 | medium |
| 194 | CHECK_SCORE_GREATER | CHECK_SCORE | `0x47b3c0` Script_Op_CHECK_SCORE_GREATER | — | SCR_CHECK_SCORE_GREATER | 3 | high |
| 195 | STORE_SCORE | GET_SCORE | `0x47b430` Script_Op_STORE_SCORE | — | SCR_GET_SCORE | 0 | medium |
| 196 | CHECK_MULTIPLIER_GREATER | CHECK_MULT | `0x47cae0` Script_Op_LIVES_MULTIPLIER | — | SCR_GET_NUM_LIVES_MULTIPLIERS | 0 | high |
| 197 | STORE_MULTIPLIER | GET_MULT | `0x47cc50` Script_Op_STORE_LIVES_MULTIPLIER | — | — | 0 | medium |
| 198 | CHECK_RESPECT_GREATER | CHECK_RESPECT_GREATER | `0x47acc0` Script_Op_CHECK_RESPECT | — | SCR_FOUR_PARAMS | 2 | high |
| 199 | CHECK_RESPECT_LOWER | CHECK_RESPECT_LESS | `0x47acc0` Script_Op_CHECK_RESPECT | — | SCR_FOUR_PARAMS | 0 | high |
| 200 | CHECK_CAR_DAMAGE_POSITION | CAR_DAMAGE_POS | `0x47c860` Script_Op_CHECK_CAR_DAMAGE_POSITION | — | SCR_TWO_PARAMS | 0 | medium |
| 201 | CHECK_PASSENGER_COUNT | GET_PASSENGER_NUM | `0x47b710` Script_Op_CHECK_PASSENGER_COUNT | — | SCR_TWO_PARAMS | 0 | medium |
| 202 | IS_CHAR_FALLING | CHAR_IN_AIR | `0x47cd40` Script_Op_IS_CHAR_FALLING | — | SCR_POINTER | 0 | medium |
| 203 | HAS_CHAR_JUST_SUNK | CHAR_SUNK | `0x47cda0` Script_Op_HAS_CHAR_JUST_SUNK | — | SCR_POINTER | 0 | medium |
| 204 | CHECK_LAST_WEAPON_HIT_CHAR | LAST_WEAPON_HIT | — | — | — | 0 | — |
| 205 | ADD_PATROL_POINT | ADD_PATROL_POINT | `0x47adf0` Script_Op_ADD_PATROL_POINT | — | SCR_ADD_PATROL_POINT | 124 | high |
| 206 | STORE_CAR_CURRENT_SPEED | GET_CAR_SPEED | `0x47d070` Script_Op_STORE_SPEED | — | SCR_TWO_PARAMS | 0 | medium |
| 207 | STORE_CHAR_CAR_CURRENT_SPEED | GET_CHAR_CAR_SPEED | `0x47d070` Script_Op_STORE_SPEED | — | SCR_TWO_PARAMS | 0 | medium |
| 208 | CHECK_CAR_SPEED | CHECK_CAR_SPEED | `0x47d170` Script_Op_CHECK_CAR_SPEED | — | SCR_CHECK_CAR_SPEED | 0 | medium |
| 209 | STORE_CAR_MAX_SPEED | GET_MAX_SPEED | `0x47d070` Script_Op_STORE_SPEED | — | SCR_TWO_PARAMS | 0 | medium |
| 210 | THREAD_TRIGGER_1 | THREAD_DECLARE1 | — | — | — | 0 | — |
| 211 | THREAD_WAIT_FOR_CHAR_IN_CAR | THREAD_DECLARE2 | — | `0x4779a0` Script_Decl_THREAD_WAIT_FOR_CHAR_IN_CAR | — | 5 | high |
| 212 | THREAD_WAIT_FOR_CHAR_IN_BLOCK | THREAD_DECLARE3 | — | `0x477a00` Script_Decl_THREAD_WAIT_FOR_CHAR_IN_BLOCK | — | 0 | medium |
| 213 | THREAD_WAIT_FOR_ANSWER_PHONE | THREAD_DECLARE4 | — | `0x477b70` Script_Decl_THREAD_WAIT_FOR_ANSWER_PHONE | — | 18 | high |
| 214 | THREAD_WAIT_FOR_CHAR_IN_AREA | THREAD_DECLARE5 | — | `0x477ac0` Script_Decl_THREAD_WAIT_FOR_CHAR_IN_AREA | — | 16 | high |
| 215 | ENABLE_THREAD_TRIGGER | ENABLE_THREAD | `0x47aa80` Script_Op_ENABLE_THREAD_TRIGGER | — | — | 0 | medium |
| 216 | DISABLE_THREAD_TRIGGER | DISABLE_THREAD | `0x47aa50` Script_Op_DISABLE_THREAD_TRIGGER | — | — | 22 | high |
| 217 | LIGHT_SET_1 | LIGHT_DEC | — | `0x47f710` Script_Decl_LIGHT_SET | — | 0 | low |
| 218 | LIGHT | LIGHT_DECSET1 | — | — | — | 6 | — |
| 219 | CREATE_LIGHT_1 | CREATE_LIGHT1 | `0x480040` Script_Op_CREATE_LIGHT | — | — | 0 | low |
| 220 | CHANGE_INTENSITY | CHANGE_INTENSITY | `0x47ca20` Script_Op_CHANGE_INTENSITY | — | SCR_CHANGE_LIGHT_INTENSITY | 0 | medium |
| 221 | CHANGE_COLOUR | CHANGE_COLOUR | `0x47ca60` Script_Op_CHANGE_COLOUR | — | SCR_FOUR_PARAMS | 0 | medium |
| 222 | CHANGE_RADIUS | CHANGE_RADIUS | `0x47caa0` Script_Op_CHANGE_RADIUS | — | SCR_CHANGE_LIGHT_RADIUS | 0 | medium |
| 223 | SET_GANG_INFO | SET_GANG_INFO1 | `0x47b340` Script_Op_SET_GANG_INFO | `0x477bd0` Script_Decl_SET_GANG_INFO | SCR_SET_GANG_INFO | 4 | high |
| 224 | SET_GANG_KILL_REACTION | SET_GANG_RESPECT | `0x47aab0` Script_Op_SET_GANG_KILL_REACTION | — | SCR_FOUR_PARAMS | 3 | low |
| 225 | SET_GANG_CHAR_RESPECT | SET_CHAR_RESPECT | `0x47ab80` Script_Op_CHANGE_GANG_CHAR_RESPECT | — | SCR_FOUR_PARAMS | 0 | high |
| 226 | SET_AMBIENT_LEVEL | SET_AMBIENT | `0x47ae70` Script_Op_SET_AMBIENT_LEVEL | — | SCR_SET_AMBIENT | 1 | high |
| 227 | CHECK_ANSWERED_PHONE | CHECK_PHONE | `0x47af50` Script_Op_CHECK_ANSWERED_PHONE | — | SCR_POINTER | 0 | medium |
| 228 | CHECK_FAIL_PHONE_TIMER | CHECK_PHONETIMER | `0x47afd0` Script_Op_CHECK_FAIL_PHONE_TIMER | — | SCR_POINTER | 0 | medium |
| 229 | STOP_PHONE_RINGING | STOP_PHONE_RING | `0x47b060` Script_Op_STOP_PHONE_RINGING | — | SCR_POINTER | 0 | medium |
| 230 | DECLARE_DOOR_INFO | SET_DOOR_INFO | — | `0x4752d0` Script_Decl_DECLARE_DOOR_INFO | — | 2 | high |
| 231 | CHECK_RESPECT_EQUAL | CHECK_RESPECT_IS | `0x47acc0` Script_Op_CHECK_RESPECT | — | SCR_FOUR_PARAMS | 6 | high |
| 232 | IS_CHAR_IN_GANGZONE | IS_CHAR_IN_GANG | `0x47b4a0` Script_Op_IS_CHAR_IN_GANGZONE | — | SCR_IS_CHAR_IN_GANG_ZONE | 9 | high |
| 233 | TIMER_DATA | TIMER_DECLARE | — | — | — | 3 | — |
| 234 | CHECK_NUMBER_ALIVE_IN_GROUP | CHECK_NUM_ALIVE | `0x47ba20` Script_Op_CHECK_NUMBER_ALIVE_IN_GROUP | — | SCR_CHAR_OBJECTIVE | 9 | high |
| 235 | ADD_EXISTING_CHAR_TO_GROUP | ADD_CHAR_TO_GROUP | `0x47bac0` Script_Op_GROUP_MEMBERSHIP | — | SCR_TWO_PARAMS | 7 | high |
| 236 | REMOVE_CHAR_FROM_GROUP | REMOVE_CHAR | `0x47bac0` Script_Op_GROUP_MEMBERSHIP | — | SCR_TWO_PARAMS | 4 | high |
| 237 | SET_MIN_MEMBERS_BEFORE_GROUP_SPLITS | SET_MIN_ALIVE | `0x47ba80` Script_Op_SET_MIN_MEMBERS_BEFORE_GROUP_SPLITS | — | SCR_CHAR_OBJECTIVE | 0 | medium |
| 238 | SET_CHAR_SHOOTING_SKILL | SET_CHAR_SHOOT | `0x47b9a0` Script_Op_SET_CHAR_AI_PARAM | — | SCR_CHAR_OBJECTIVE | 0 | high |
| 239 | SET_CHAR_BRAVERY_LEVEL | SET_CHAR_BRAVERY | `0x47b9a0` Script_Op_SET_CHAR_AI_PARAM | — | SCR_CHAR_OBJECTIVE | 0 | high |
| 240 | DECLARE_MISSION_FLAG | DECLARE_MISSION | — | `0x478120` Script_Decl_DECLARE_MISSION_FLAG | — | 1 | high |
| 241 | HAS_CAR_GOT_WEAPON | HAS_CAR_WEAPON | `0x47bb90` Script_Op_HAS_CAR_GOT_WEAPON | — | SCR_TWO_PARAMS | 0 | medium |
| 242 | IS_CHAR_IN_ZONE | IS_CHAR_IN_ZONE | `0x47bcd0` Script_Op_IS_CHAR_IN_ZONE | — | SCR_TWO_PARAMS | 31 | high |
| 243 | IS_CHAR_PRESSING_HORN | IS_CHAR_HORN | `0x47bbe0` Script_Op_IS_CHAR_PRESSING_HORN | — | SCR_POINTER | 5 | high |
| 244 | IS_CHAR_CAR_CAPACITY | CHECK_MAX_PASS | `0x47bc50` Script_Op_IS_CHAR_CAR_CAPACITY | — | SCR_TWO_PARAMS | 1 | high |
| 245 | SET_PHONE_DEAD | SET_PHONE_DEAD | `0x47f920` Script_Op_SET_PHONE_DEAD | — | SCR_POINTER | 22 | high |
| 246 | IS_TRAILER_ATTACHED | IS_TRAILER_ATT | `0x47be00` Script_Op_IS_TRAILER_ATTACHED | — | SCR_TWO_PARAMS | 2 | high |
| 247 | IS_CAR_ON_TRAILER | IS_CAR_ON_TRAIL | `0x47be90` Script_Op_IS_CAR_ON_TRAILER | — | SCR_TWO_PARAMS | 1 | high |
| 248 | ENABLE_CRANE | ENABLE_CRANE | `0x47bf00` Script_Op_ENABLE_DISABLE_CRANE | — | SCR_POINTER | 3 | high |
| 249 | DISABLE_CRANE | DISABLE_CRANE | `0x47bf00` Script_Op_ENABLE_DISABLE_CRANE | — | SCR_POINTER | 2 | high |
| 250 | HAS_CAR_GOT_DRIVER | CAR_GOT_DRIVER | `0x47bf80` Script_Op_HAS_CAR_GOT_DRIVER | — | SCR_POINTER | 0 | medium |
| 251 | HAS_CHAR_SPOTTED_PLAYER | SPOTTED_PLAYER | `0x47bfc0` Script_Op_HAS_CHAR_SPOTTED_PLAYER | — | SCR_POINTER | 69 | high |
| 252 | STORE_LAST_CHAR_PUNCHED | GET_LAST_PUNCHED | `0x47c000` Script_Op_STORE_LAST_CHAR_PUNCHED | — | SCR_TWO_PARAMS | 0 | medium |
| 253 | KILL_ALL_PASSENGERS | KILL_ALL_PASSENG | `0x47c0b0` Script_Op_KILL_ALL_PASSENGERS | — | SCR_POINTER | 7 | high |
| 254 | IS_GROUP_IN_CAR | IS_GROUP_IN_CAR | `0x47c110` Script_Op_IS_GROUP_IN_CAR | — | SCR_POINTER | 9 | high |
| 255 | HAS_CHAR_PUNCHED_SOMEONE | PUNCHED_SOMEONE | `0x47c150` Script_Op_HAS_CHAR_PUNCHED_SOMEONE | — | SCR_POINTER | 0 | medium |
| 256 | REMOVE_WEAPONS | REMOVE_WEAPON | `0x47c580` Script_Op_REMOVE_WEAPONS | — | SCR_POINTER | 0 | medium |
| 257 | DO_NOWT | DO_NOWT | — | — | — | 11 | — |
| 258 | ADD_CHAR_TO_GANG | ADD_CHAR_TO_GANG | `0x47c190` Script_Op_ADD_CHAR_TO_GANG | — | SCR_TWO_PARAMS | 143 | high |
| 259 | MAKE_NEW_LEADER_OF_GROUP | MAKE_LEADER | `0x47bac0` Script_Op_GROUP_MEMBERSHIP | — | SCR_TWO_PARAMS | 7 | high |
| 260 | PARK | PARK | `0x47c360` Script_Op_PARK | — | — | 14 | high |
| 261 | HAS_PARK_FINISHED | PARK_FINISHED | `0x47c8a0` Script_Op_HAS_PARK_FINISHED | — | — | 14 | high |
| 262 | CHANGE_GANG_CHAR_RESPECT | CHANGE_RESPECT | `0x47ab80` Script_Op_CHANGE_GANG_CHAR_RESPECT | — | SCR_FOUR_PARAMS | 1 | high |
| 263 | DO_PHONE_TEMPLATE | PHONE_TEMPLATE | `0x47fac0` Script_Op_DO_PHONE_TEMPLATE | — | SCR_PHONE_TEMPLATE | 9 | high |
| 264 | CHECK_CHAR_BEEN_PUNCHED_BY | BEEN_PUNCHED_BY | `0x47c3c0` Script_Op_CHECK_CHAR_BEEN_PUNCHED_BY | — | SCR_TWO_PARAMS | 0 | medium |
| 265 | UPDATE_DOOR_TARGET | UPDATE_DOOR | `0x47c410` Script_Op_UPDATE_DOOR_TARGET | — | SCR_UPDATE_DOOR | 14 | high |
| 266 | GIVE_WEAPON_2 | GIVE_WEAPON2 | `0x4797a0` Script_Op_GIVE_WEAPON | — | SCR_TWO_PARAMS | 0 | high |
| 267 | IS_CAR_CRUSHED | IS_CAR_CRUSHED | `0x47f9f0` Script_Op_CHECK_CAR_STATE | — | SCR_POINTER | 0 | high |
| 268 | SWITCH_GENERATOR_1 | SWITCH_GENERATOR1 | `0x47c740` Script_Op_SWITCH_GENERATOR_1_2 | — | SCR_TWO_PARAMS | 31 | high |
| 269 | SWITCH_GENERATOR_2 | SWITCH_GENERATOR2 | `0x47c740` Script_Op_SWITCH_GENERATOR_1_2 | — | SCR_TWO_PARAMS | 0 | high |
| 270 | IS_CAR_IN_BLOCK_AREA | CAR_IN_AREA | `0x4799d0` Script_Op_IS_CAR_IN_BLOCK_AREA | — | SCR_ONEVAR_RECT | 37 | medium |
| 271 | TAKE_REMOTE_CONTROL_OF_CAR | REMOTE_CONTROL | `0x47c910` Script_Op_TAKE_REMOTE_CONTROL_OF_CAR | — | SCR_REMOTE_CONTROL | 1 | high |
| 272 | MISSIONSTART | MISSIONSTART | — | — | — | 22 | — |
| 273 | MISSIONEND | MISSIONEND | `0x478610` Script_Op_RETURN | — | — | 22 | high |
| 274 | LAUNCH_MISSION | LAUNCH_MISSION | `0x47fe20` Script_Op_LAUNCH_MISSION | — | — | 1 | high |
| 275 | SAVED_COUNTER | COUNTER_SAVE | — | — | — | 11 | — |
| 276 | SAVED_COUNTER_SET | COUNTER_SET_SAVE | — | — | — | 96 | — |
| 277 | SAVE_GAME | SAVE_GAME | `0x47fe50` Script_Op_SAVE_GAME | — | — | 0 | medium |
| 278 | CHANGE_CAR_LOCK | CHANGE_CAR_LOCK | `0x47c980` Script_Op_CHANGE_CAR_LOCK | — | SCR_CHANGE_CAR_LOCK | 20 | high |
| 279 | DISPLAY_BRIEF_NOW | DISPLAY_BRIEF_NOW | `0x4792b0` Script_Op_DISPLAY_MESSAGE | `0x4755f0` Script_Decl_DISPLAY_MESSAGE | SCR_TWO_PARAMS | 367 | high |
| 280 | PARK_NO_RESPAWN | PARK_NO_RESPAWN | `0x47c360` Script_Op_PARK | — | — | 0 | high |
| 281 | ADD_LIVES | ADD_LIVES | `0x47cae0` Script_Op_LIVES_MULTIPLIER | — | SCR_GET_NUM_LIVES_MULTIPLIERS | 0 | high |
| 282 | ADD_MULTIPLIER | ADD_MULTIPLIER | `0x47cae0` Script_Op_LIVES_MULTIPLIER | — | SCR_GET_NUM_LIVES_MULTIPLIERS | 22 | high |
| 283 | SET_DIR_OF_TV_VANS | SET_DIR_OF_TVVAN | `0x47ccc0` Script_Op_SET_DIR_OF_TV_VANS | — | SCR_SET_DIR_OF_TVVAN | 1 | high |
| 284 | IS_POINT_ONSCREEN | POINT_ONSCREEN | `0x47cd00` Script_Op_IS_POINT_ONSCREEN | — | SCR_IS_POINT_ON_SCREEN | 8 | high |
| 285 | SET_STATION_INFO | SET_STATION | — | `0x4752f0` Script_Decl_SET_STATION_INFO | — | 6 | medium |
| 286 | SET_STATION_INFO_EMPTY | SET_EMPTY_STATION | — | `0x4752f0` Script_Decl_SET_STATION_INFO | — | 2 | medium |
| 287 | RADIO_STATION | RADIOSTATION_DEC | — | `0x4753b0` Script_Decl_RADIO_STATION | — | 4 | high |
| 288 | START_BONUS_CHECK_1 | START_BONUS1 | `0x47ce00` Script_Op_START_BONUS_CHECK | — | SCR_START_BONUS | 20 | high |
| 289 | START_BONUS_CHECK_2 | START_BONUS2 | `0x47ce00` Script_Op_START_BONUS_CHECK | — | SCR_START_BONUS | 0 | high |
| 290 | START_BONUS_CHECK_3 | START_BONUS3 | `0x47ce00` Script_Op_START_BONUS_CHECK | — | SCR_START_BONUS | 2 | high |
| 291 | START_BONUS_CHECK_4 | START_BONUS4 | `0x47ce00` Script_Op_START_BONUS_CHECK | — | SCR_START_BONUS | 0 | high |
| 292 | HAS_BONUS_PASSED | CHECK_BONUS1 | `0x47cfa0` Script_Op_CHECK_BONUS | — | — | 2 | high |
| 293 | HAS_BONUS_FAILED | CHECK_BONUS2 | `0x47cfa0` Script_Op_CHECK_BONUS | — | — | 2 | high |
| 294 | HAS_BONUS_FINISHED | CHECK_BONUS3 | `0x47cfa0` Script_Op_CHECK_BONUS | — | — | 0 | high |
| 295 | SET_STATION_4 | SET_STATION_4 | — | `0x4753d0` Script_Decl_SET_TRAIN_STATIONS | — | 0 | medium |
| 296 | SET_STATION_3 | SET_STATION_3 | — | `0x4753d0` Script_Decl_SET_TRAIN_STATIONS | — | 0 | medium |
| 297 | SET_STATION_2 | SET_STATION_2 | — | `0x4753d0` Script_Decl_SET_TRAIN_STATIONS | — | 0 | medium |
| 298 | SET_STATION_1 | SET_STATION_1 | — | `0x4753d0` Script_Decl_SET_TRAIN_STATIONS | — | 0 | medium |
| 299 | SETUP_MODELCHECK_DESTROY | SETUP_MODEL_CHECK | `0x47d010` Script_Op_SETUP_MODELCHECK_DESTROY | — | — | 3 | high |
| 300 | HAS_MODELCHECK_HAPPENED | MODEL_CHECK | `0x47d040` Script_Op_HAS_MODELCHECK_HAPPENED | — | — | 3 | high |
| 301 | CREATE_LIGHT_2 | LIGHT_DECSET2 | `0x480040` Script_Op_CREATE_LIGHT | — | — | 6 | low |
| 302 | LIGHT_SET_2 | CREATE_LIGHT2 | — | `0x47f710` Script_Decl_LIGHT_SET | — | 0 | low |
| 303 | SET_CAR_NUMBER_GRAPHIC | SET_CAR_GRAPHIC | `0x47d1e0` Script_Op_SET_CAR_NUMBER_GRAPHIC | — | SCR_SET_CAR_GRAPHIC | 0 | medium |
| 304 | DECLARE_POLICELEVEL | DECLARE_POLICE | — | `0x475420` Script_Decl_DECLARE_POLICELEVEL | — | 0 | medium |
| 305 | IS_CARBOMB_ACTIVE | CARBOMB_ACTIVE | `0x47f9f0` Script_Op_CHECK_CAR_STATE | — | SCR_POINTER | 0 | high |
| 306 | SET_CHAR_DRIVE_AGGRESSION | CHAR_DRIVE_AGGR | `0x47d450` Script_Op_SET_CHAR_DRIVE_AGGRESSION | — | SCR_SET_CHAR_DRIVE_AGGR | 4 | high |
| 307 | SET_CHAR_MAX_DRIVESPEED | CHAR_DRIVE_SPEED | `0x47d4a0` Script_Op_SET_CHAR_MAX_SPEED | — | SCR_SET_RUN_SPEED | 27 | high |
| 308 | S_IS_S_MINUS_S | S_IS_S_MINUS_S | `0x47d260` Script_Op_S_IS_S_OP_S | — | SCR_OPERATE_COUNTER_AND_COUNTER | 2 | medium |
| 309 | S_IS_S_PLUS_S | S_IS_S_PLUS_S | `0x47d260` Script_Op_S_IS_S_OP_S | — | SCR_OPERATE_COUNTER_AND_COUNTER | 0 | medium |
| 310 | GIVE_CAR_ALARM | GIVE_CAR_ALARM | `0x47d4f0` Script_Op_GIVE_CAR_ALARM | — | SCR_POINTER | 7 | high |
| 311 | SET_CAR_BULLETPROOF | CAR_BULLETPROOF | `0x47d520` Script_Op_SET_CAR_PROOF | — | SCR_SET_CAR_DAMAGE_PROOF | 11 | high |
| 312 | SET_CAR_ROCKETPROOF | CAR_ROCKETPROOF | `0x47d520` Script_Op_SET_CAR_PROOF | — | SCR_SET_CAR_DAMAGE_PROOF | 2 | high |
| 313 | SET_CAR_FLAMEPROOF | CAR_FLAMEPROOF | `0x47d520` Script_Op_SET_CAR_PROOF | — | SCR_SET_CAR_DAMAGE_PROOF | 5 | high |
| 314 | IS_CAR_ALARM_ON | IS_ALARM_RINGING | — | — | — | 0 | — |
| 315 | SET_CHAR_OBJECTIVE_FOLLOW | SET_CHAR_OBJ_FOLLOW | `0x47a3b0` Script_Op_SET_CHAR_OBJECTIVE_FOLLOW | — | SCR_CHAR_OBJECTIVE | 6 | high |
| 316 | PUT_CAR_ON_TRAILER | PUT_CAR_ON_TRAILER | `0x47d5d0` Script_Op_PUT_CAR_ON_TRAILER | — | SCR_PUT_CAR_ON_TRAILER | 3 | high |
| 317 | CLEAR_ALL_BRIEFS | CLEAR_BRIEFS | `0x47d650` Script_Op_CLEAR_ALL_BRIEFS | — | — | 134 | high |
| 318 | CHECK_HEADS_GREATER | CHECK_HEADS | `0x47d690` Script_Op_CHECK_HEADS_GREATER | — | SCR_CHECK_HEADS_GREATER | 0 | medium |
| 319 | FINISH_LEVEL | FINISH_LEVEL | `0x47d6e0` Script_Op_FINISH_LEVEL | — | SCR_FINISH_LEVEL | 1 | high |
| 320 | CHECK_WEAPON_TYPE_HIT_CHAR | CHECK_WEAPONHIT | `0x47d7a0` Script_Op_CHECK_WEAPON_TYPE_HIT_CHAR | — | SCR_CHECK_WEAPONHIT | 0 | medium |
| 321 | DISPLAY_BRIEF_SOON | DISPLAY_BRIEF_SOON | `0x4792b0` Script_Op_DISPLAY_MESSAGE | `0x4755f0` Script_Decl_DISPLAY_MESSAGE | SCR_TWO_PARAMS | 0 | high |
| 322 | SET_GANG_INFO_2 | SET_GANG_INFO2 | — | — | — | 0 | — |
| 323 | MAP_ZONE_2 | MAP_ZONE2 | — | — | — | 0 | — |
| 324 | IS_CHAR_ON_FIRE | IS_CHAR_ON_FIRE | `0x47d920` Script_Op_IS_CHAR_ON_FIRE | — | SCR_POINTER | 0 | medium |
| 325 | IS_BRIEF_ONSCREEN | BRIEF_ONSCREEN | `0x47d960` Script_Op_IS_BRIEF_ONSCREEN | — | — | 0 | medium |
| 326 | SOUND | SOUND | — | — | — | 41 | — |
| 327 | SOUND_SET | SOUND_DECSET | — | `0x475460` Script_Decl_SOUND_SET | — | 78 | high |
| 328 | CREATE_SOUND | CREATE_SOUND | `0x47d990` Script_Op_CREATE_SOUND | — | SCR_SOUND_DECSET | 70 | high |
| 329 | DO_EASY_PHONE_TEMPLATE | DO_EASY_PHONE | `0x480080` Script_Op_DO_EASY_PHONE_TEMPLATE | — | — | 6 | high |
| 330 | CREATE_CHAR_INSIDE_CAR | CHAR_INTO_CAR | `0x4802f0` Script_Op_CREATE_CHAR_INSIDE_CAR | — | SCR_CHAR_INTO_CAR | 10 | high |
| 331 | DELETE_GROUP_IN_CAR | DEL_GROUP_IN_CAR | — | — | — | 0 | — |
| 332 | S_IS_S_MINUS_I | S_IS_S_MINUS_I | `0x47d360` Script_Op_S_IS_S_OP_I | — | SCR_OPERATE_COUNTER_AND_OPERAND_INT | 0 | medium |
| 333 | S_IS_S_PLUS_I | S_IS_S_PLUS_I | `0x47d360` Script_Op_S_IS_S_OP_I | — | SCR_OPERATE_COUNTER_AND_OPERAND_INT | 0 | medium |
| 334 | S_IS_S_DIV_I | S_IS_S_DIV_I | `0x47d360` Script_Op_S_IS_S_OP_I | — | SCR_OPERATE_COUNTER_AND_OPERAND_INT | 0 | medium |
| 335 | S_IS_S_MULT_I | S_IS_S_MULT_I | `0x47d360` Script_Op_S_IS_S_OP_I | — | SCR_OPERATE_COUNTER_AND_OPERAND_INT | 0 | medium |
| 336 | S_IS_S_MOD_I | S_IS_S_MOD_I | `0x47d360` Script_Op_S_IS_S_OP_I | — | SCR_OPERATE_COUNTER_AND_OPERAND_INT | 0 | medium |
| 337 | S_IS_S_DIV_S | S_IS_S_DIV_S | `0x47d260` Script_Op_S_IS_S_OP_S | — | SCR_OPERATE_COUNTER_AND_COUNTER | 0 | medium |
| 338 | S_IS_S_MULT_S | S_IS_S_MULT_S | `0x47d260` Script_Op_S_IS_S_OP_S | — | SCR_OPERATE_COUNTER_AND_COUNTER | 0 | medium |
| 339 | S_IS_S_MOD_S | S_IS_S_MOD_S | `0x47d260` Script_Op_S_IS_S_OP_S | — | SCR_OPERATE_COUNTER_AND_COUNTER | 0 | medium |
| 340 | SET_COUNTER_INT | SET_COUNTER_INT | `0x47bb60` Script_Op_SET_COUNTER_INT | — | — | 1082 | medium |
| 341 | SET_COUNTER_VAR | SET_COUNTER_VAR | — | — | — | 0 | — |
| 342 | ADD_SCORE_2 | ADD_SCORE2 | `0x479d40` Script_Op_ADD_SCORE_2 | — | SCR_FOUR_PARAMS | 0 | medium |
| 343 | DECLARE_FINISH_SCORE | FINISH_SCORE | — | `0x4755b0` Script_Decl_DECLARE_FINISH_SCORE | — | 1 | high |
| 344 | DECLARE_TOTAL_MISSIONS | TOTAL_MISSIONS | — | `0x4754e0` Script_Decl_DECLARE_MISSIONS_TOTAL | — | 1 | high |
| 345 | DECLARE_TOTAL_SECRETS | TOTAL_SECRETS | — | `0x4754e0` Script_Decl_DECLARE_MISSIONS_TOTAL | — | 1 | high |
| 346 | DECLARE_MISSIONS_PASSED_FLAG | PASSED_FLAG | — | `0x478170` Script_Decl_DECLARE_PASSED_FAILED_FLAG | — | 1 | high |
| 347 | DECLARE_GANG_ONE_MISSIONS_PASSED_FLAG | 1_PASSED_FLAG | — | `0x478170` Script_Decl_DECLARE_PASSED_FAILED_FLAG | — | 1 | high |
| 348 | DECLARE_GANG_TWO_MISSIONS_PASSED_FLAG | 2_PASSED_FLAG | — | `0x478170` Script_Decl_DECLARE_PASSED_FAILED_FLAG | — | 1 | high |
| 349 | DECLARE_GANG_THREE_MISSIONS_PASSED_FLAG | 3_PASSED_FLAG | — | `0x478170` Script_Decl_DECLARE_PASSED_FAILED_FLAG | — | 1 | high |
| 350 | SUPPRESS_THIS_CAR_MODEL | SUPPRESS_MODEL | `0x47da80` Script_Op_SUPPRESS_THIS_CAR_MODEL | — | — | 0 | medium |
| 351 | SWITCH_GENERATOR_3 | SWITCH_GENERATOR3 | `0x47c7d0` Script_Op_SWITCH_GENERATOR_3_4 | — | SCR_FOUR_PARAMS | 0 | medium |
| 352 | SWITCH_GENERATOR_4 | SWITCH_GENERATOR4 | `0x47c7d0` Script_Op_SWITCH_GENERATOR_3_4 | — | SCR_FOUR_PARAMS | 0 | medium |
| 353 | DECLARE_POWERUP_CARLIST | DECLARE_CARLIST | — | `0x4755d0` Script_Decl_DECLARE_POWERUP_CARLIST | — | 1 | high |
| 354 | DECIDE_POWERUP_FOR_CRANE | DECIDE_POWERUP | `0x47d9d0` Script_Op_DECIDE_POWERUP_FOR_CRANE | — | SCR_TWO_PARAMS | 0 | medium |
| 355 | HAS_CHAR_BEEN_ARRESTED | CHAR_ARRESTED | `0x47d220` Script_Op_HAS_CHAR_BEEN_ARRESTED | — | SCR_POINTER | 0 | medium |
| 356 | IS_ITEM_ACCURATELY_ONSCREEN | ONSCREEN_ACCURACY | `0x47a620` Script_Op_IS_ITEM_ONSCREEN | — | SCR_POINTER | 66 | high |
| 357 | WARP_FROM_CAR_TO_POINT | WARP_CHAR | `0x47dad0` Script_Op_WARP_FROM_CAR_TO_POINT | — | — | 0 | medium |
| 358 | CHECK_WEAPON_TYPE_HIT_CAR | WEAP_HIT_CAR | `0x47d860` Script_Op_CHECK_WEAPON_HIT_CAR | — | SCR_CHECK_WEAPONHIT | 8 | high |
| 359 | SET_GROUP_TYPE | SET_GROUP_TYPE | `0x47dbd0` Script_Op_SET_GROUP_TYPE | — | SCR_SET_GROUP_TYPE | 8 | high |
| 360 | MAKE_CHAR_DO_NOTHING | CHAR_DO_NOTHING | `0x47dc10` Script_Op_MAKE_CHAR_DO_NOTHING | — | SCR_POINTER | 41 | high |
| 361 | SET_CAR_EMERG_LIGHTS | EMERG_LIGHTS | `0x4803c0` Script_Op_SET_CAR_EMERG_LIGHTS | — | SCR_TWO_PARAMS | 0 | medium |
| 362 | CHECK_OBJ_MODEL | CHECK_OBJ_MODEL | `0x47dc50` Script_Op_CHECK_OBJ_MODEL | — | SCR_FOUR_PARAMS | 21 | high |
| 363 | SET_CHAR_INVINCIBLE | CHAR_INVINCIBLE | `0x47dcf0` Script_Op_SET_CHAR_FLAG | — | SCR_SET_STATE | 2 | high |
| 364 | SET_CHAR_GRAPHIC_TYPE | PED_GRAPHIC | `0x47dca0` Script_Op_SET_CHAR_GRAPHIC_TYPE | — | SCR_SET_CHAR_GRAPHIC_TYPE | 10 | high |
| 365 | MAKE_ALL_CHARS_MUGGERS | MAKE_MUGGERS | `0x47de50` Script_Op_MAKE_ALL_CHARS_MUGGERS | — | SCR_SET_STATE | 1 | high |
| 366 | CHECK_ANY_WEAPON_TYPE_HIT_CAR | ANY_WEAPON_HIT_CAR | `0x47d860` Script_Op_CHECK_WEAPON_HIT_CAR | — | SCR_CHECK_WEAPONHIT | 0 | high |
| 367 | LOCATE_ANOTHER_CHARACTER_ON_FOOT | LOC_SECOND_CHAR | `0x47de70` Script_Op_LOCATE_ANOTHER_CHARACTER | — | SCR_LOC_SEC_CHAR | 17 | high |
| 368 | STOP_CHAR_DRIVING | STOP_CAR_DRIVE | `0x47e040` Script_Op_STOP_CHAR_DRIVING | — | SCR_POINTER | 0 | medium |
| 369 | IS_BUS_FULL | IS_BUS_FULL | `0x47e090` Script_Op_IS_BUS_FULL | — | SCR_POINTER | 1 | high |
| 370 | STOP_CHARS_GETTING_OFF_BUS | NO_CHARS_OFF_BUS | `0x47e100` Script_Op_STOP_CHARS_GETTING_OFF_BUS | — | SCR_SET_STATE | 2 | high |
| 371 | KILL_CHAR | KILL_CHAR | `0x47e130` Script_Op_KILL_CHAR | — | SCR_POINTER | 1 | high |
| 372 | SET_GANGCAR_RATIO | SET_GANGCARRATIO | `0x478c00` Script_Op_SET_DENSITY_RATIO | — | SCR_MAP_SET_ZONE_INFO | 0 | high |
| 373 | SET_SHADING_LEVEL | SET_SHADING_LEV | `0x47e170` Script_Op_SET_SHADING_LEVEL | — | SCR_CMD_HEADER | 1 | high |
| 374 | SET_CAR_JAMMED_ACCELERATOR | SET_CAR_JAMMED | `0x47e1a0` Script_Op_SET_CAR_JAMMED_ACCELERATOR | — | SCR_SET_CAR_JAMMED | 0 | medium |
| 375 | DOOR_DATA_SINGLE_1 | DOOR_DECLARE_S1 | — | `0x477d20` Script_Decl_DOOR_DATA_1 | — | 0 | high |
| 376 | DOOR_DATA_SINGLE_2 | DOOR_DECLARE_S2 | — | `0x477ee0` Script_Decl_DOOR_DATA_2 | — | 0 | medium |
| 377 | DOOR_DATA_SINGLE_3 | DOOR_DECLARE_S3 | — | — | — | 0 | — |
| 378 | DOOR_DATA_DOUBLE_1 | DOOR_DECLARE_D1 | — | `0x477d20` Script_Decl_DOOR_DATA_1 | — | 21 | high |
| 379 | DOOR_DATA_DOUBLE_2 | DOOR_DECLARE_D2 | — | `0x477ee0` Script_Decl_DOOR_DATA_2 | — | 0 | medium |
| 380 | DOOR_DATA_DOUBLE_3 | DOOR_DECLARE_D3 | — | — | — | 0 | — |
| 381 | LOCATE_ANOTHER_CHARACTER_BY_CAR | LOC_SEC_CHAR_CAR | `0x47de70` Script_Op_LOCATE_ANOTHER_CHARACTER | — | SCR_LOC_SEC_CHAR | 19 | high |
| 382 | LOCATE_ANOTHER_CHARACTER_ANY_MEANS | LOC_SEC_CHAR_ANY | `0x47de70` Script_Op_LOCATE_ANOTHER_CHARACTER | — | SCR_LOC_SEC_CHAR | 6 | high |
| 383 | SET_CHAR_MAX_RUNSPEED | SET_RUN_SPEED | `0x47d4a0` Script_Op_SET_CHAR_MAX_SPEED | — | SCR_SET_RUN_SPEED | 0 | high |
| 384 | SET_CHAR_TO_STAY_IN_CAR | SET_STAY_IN_CAR | `0x47dcf0` Script_Op_SET_CHAR_FLAG | — | SCR_SET_STATE | 0 | high |
| 385 | SET_CHAR_TO_USE_CAR_WEAPON | SET_USE_CAR_WEAPON | `0x47dcf0` Script_Op_SET_CHAR_FLAG | — | SCR_SET_STATE | 0 | high |
| 386 | DECLARE_GANG_ONE_MISSIONS_TOTAL | GANG_1_MISSION_TOTAL | — | `0x4754e0` Script_Decl_DECLARE_MISSIONS_TOTAL | — | 1 | high |
| 387 | DECLARE_GANG_TWO_MISSIONS_TOTAL | GANG_2_MISSION_TOTAL | — | `0x4754e0` Script_Decl_DECLARE_MISSIONS_TOTAL | — | 1 | high |
| 388 | DECLARE_GANG_THREE_MISSIONS_TOTAL | GANG_3_MISSION_TOTAL | — | `0x4754e0` Script_Decl_DECLARE_MISSIONS_TOTAL | — | 1 | high |
| 389 | DECLARE_SECRETS_PASSED_FLAG | SECRETS_PASSED | — | `0x478170` Script_Decl_DECLARE_PASSED_FAILED_FLAG | — | 1 | high |
| 390 | DECLARE_SECRETS_FAILED_FLAG | SECRETS_FAILED | — | `0x478170` Script_Decl_DECLARE_PASSED_FAILED_FLAG | — | 1 | high |
| 391 | MISSION_HAS_FINISHED | FINISH_MISSION | `0x47e1f0` Script_Op_MISSION_HAS_FINISHED | — | — | 22 | high |
| 392 | ADD_SCORE_NO_MULT | ADDSCORE_NO_MULT | `0x479cc0` Script_Op_ADD_SCORE | — | SCR_FOUR_PARAMS | 0 | high |
| 393 | CHANGE_GANG_CHAR_RESPECT_AND_UPDATE | CHANGE_GANG_RESP | `0x47ab80` Script_Op_CHANGE_GANG_CHAR_RESPECT | — | SCR_FOUR_PARAMS | 63 | high |
| 394 | CREATE_GANG_CAR_1 | CREATE_GANG_CAR1 | `0x478b10` Script_Op_CREATE_CAR | — | SCR_CAR_DATA_DEC | 0 | high |
| 395 | CREATE_GANG_CAR_2 | CREATE_GANG_CAR2 | `0x478b10` Script_Op_CREATE_CAR | — | SCR_CAR_DATA_DEC | 7 | high |
| 396 | CREATE_GANG_CAR_3 | CREATE_GANG_CAR3 | `0x478b10` Script_Op_CREATE_CAR | — | SCR_CAR_DATA_DEC | 0 | high |
| 397 | CREATE_GANG_CAR_4 | CREATE_GANG_CAR4 | `0x478b10` Script_Op_CREATE_CAR | — | SCR_CAR_DATA_DEC | 0 | high |
| 398 | EXPLODE_LARGE_ITEM | EXPLODE_LARGE1 | `0x47c1e0` Script_Op_EXPLODE_ITEM | — | SCR_POINTER | 0 | medium |
| 399 | EXPLODE_LARGE_POS | EXPLODE_LARGE2 | `0x479e10` Script_Op_EXPLODE_POS | — | SCR_EXPLODE | 9 | medium |
| 400 | SET_ENTER_CONTROL_STATUS | SET_ENTER_STATUS | `0x47e280` Script_Op_SET_CONTROL_STATUS | — | — | 0 | medium |
| 401 | BONUS | BONUS_DECLARE | — | — | — | 22 | — |
| 402 | STORE_BONUS_COUNT | STORE_BONUS | `0x47e210` Script_Op_STORE_BONUS_COUNT | — | SCR_STORE_BONUS_COUNT | 2 | high |
| 403 | EXPLODE_SMALL_ITEM | EXPLODE_SMALL1 | `0x47c1e0` Script_Op_EXPLODE_ITEM | — | SCR_POINTER | 0 | medium |
| 404 | EXPLODE_SMALL_POS | EXPLODE_SMALL2 | `0x479e10` Script_Op_EXPLODE_POS | — | SCR_EXPLODE | 0 | medium |
| 405 | EXPLODE_NO_RING_ITEM | EXPLODE_NO_RING1 | `0x47c1e0` Script_Op_EXPLODE_ITEM | — | SCR_POINTER | 0 | medium |
| 406 | EXPLODE_NO_RING_POS | EXPLODE_NO_RING2 | `0x479e10` Script_Op_EXPLODE_POS | — | SCR_EXPLODE | 46 | medium |
| 407 | SET_ALL_CONTROLS_STATUS | SET_ALL_CONTROLS | `0x47e280` Script_Op_SET_CONTROL_STATUS | — | — | 0 | medium |
| 408 | SET_FAVOURITE_MODEL | SET_FAV_CAR | `0x47e320` Script_Op_SET_FAVOURITE_MODEL | — | SCR_SET_FAV_CAR | 10 | high |
| 409 | IS_GROUP_IN_AREA | GROUP_IN_AREA | `0x47e360` Script_Op_IS_GROUP_IN_AREA | — | SCR_ONEVAR_RECT | 0 | medium |
| 410 | SET_CHAR_OCCUPATION | SET_CHAR_OCCUPATION | `0x479660` Script_Op_SET_CHAR_OCCUPATION | — | SCR_FOUR_PARAMS | 6 | high |
| 411 | SET_KF_WEAPON | SET_KF_WEAPON | `0x47e5b0` Script_Op_SET_KF_WEAPON | — | SCR_SET_KF_WEAPON | 0 | medium |
| 412 | CLEAR_KF_WEAPON | CLEAR_KF_WEAPON | `0x47e620` Script_Op_CLEAR_KF_WEAPON | — | SCR_POINTER | 0 | medium |
| 413 | ONSCREEN_COUNTER | ONSCREEN_COUNTER_DEC | — | — | — | 3 | — |
| 414 | ADD_ONSCREEN_COUNTER | ADD_ONSCREEN_COUNTER | `0x47e660` Script_Op_ADD_ONSCREEN_COUNTER | — | SCR_ADD_ONSCREEN_COUNTER | 2 | high |
| 415 | CLEAR_ONSCREEN_COUNTER | CLEAR_COUNTER | `0x47e6b0` Script_Op_CLEAR_ONSCREEN_COUNTER | — | — | 5 | high |
| 416 | CLEAR_CLOCK_ONLY | CLEAR_CLOCK_ONLY | `0x47e6b0` Script_Op_CLEAR_ONSCREEN_COUNTER | — | — | 0 | high |
| 417 | ARE_EMERG_LIGHTS_ON | EMERG_LIGHTS_ON | `0x47f9f0` Script_Op_CHECK_CAR_STATE | — | SCR_POINTER | 1 | high |
| 418 | CHANGE_POLICE_LEVEL | CHANGE_POLICE | `0x47e720` Script_Op_CHANGE_POLICE_LEVEL | — | SCR_DECLARE_POLICELEVEL | 0 | medium |
| 419 | DESTROY_GROUP | DESTROY_GROUP | `0x47e740` Script_Op_DESTROY_GROUP | — | SCR_POINTER | 4 | high |
| 420 | CHECK_CHAR_CURR_WEAPON | CHECK_CURRENT_WEAPON | `0x47e780` Script_Op_CHECK_CHAR_CURR_WEAPON | — | SCR_CHECK_CURRENT_WEAPON | 0 | medium |
| 421 | ALTER_WANTED_LEVEL_NO_DROP | ALTER_WANTED_LEVEL | `0x47b7b0` Script_Op_ALTER_WANTED_LEVEL | — | SCR_CMD_ALTER_WANTED_LEVEL | 0 | high |
| 422 | START_BASIC_KF_TEMPLATE | START_BASIC_KF | `0x480430` Script_Op_START_BASIC_KF_TEMPLATE | `0x4756b0` Script_Decl_START_BASIC_KF_TEMPLATE | — | 20 | high |
| 423 | DO_BASIC_KF_TEMPLATE | DO_BASIC_KF | `0x47e7f0` Script_Op_DO_BASIC_KF_TEMPLATE | — | SCR_DO_BASIC_KF_TEMPLATE | 20 | high |
| 424 | SET_BONUS_RATING_TEXT_ID | SET_BONUS_RATING | `0x47ea80` Script_Op_SET_BONUS_RATING_TEXT_ID | — | SCR_CMD_HEADER | 0 | medium |
| 425 | PARKED_CAR_DATA_2D | PARKED_CAR_DECSET_2D | — | `0x477530` Script_Decl_PARKED_CAR_DATA | — | 0 | high |
| 426 | PARKED_CAR_DATA_3D | PARKED_CAR_DECSET_3D | — | `0x477530` Script_Decl_PARKED_CAR_DATA | — | 60 | high |
| 427 | PARKED_CAR_DATA_2D_STR | PARKED_CAR_DECSET_2D_STR | — | `0x477530` Script_Decl_PARKED_CAR_DATA | — | 0 | high |
| 428 | PARKED_CAR_DATA_3D_STR | PARKED_CAR_DECSET_3D_STR | — | `0x477530` Script_Decl_PARKED_CAR_DATA | — | 0 | high |
| 429 | DECLARE_GANG_ONE_MISSION_FLAG | DEC_GANG_1_FLAG | — | `0x478120` Script_Decl_DECLARE_MISSION_FLAG | — | 1 | high |
| 430 | DECLARE_GANG_TWO_MISSION_FLAG | DEC_GANG_2_FLAG | — | `0x478120` Script_Decl_DECLARE_MISSION_FLAG | — | 1 | high |
| 431 | DECLARE_GANG_THREE_MISSION_FLAG | DEC_GANG_3_FLAG | — | `0x478120` Script_Decl_DECLARE_MISSION_FLAG | — | 1 | high |
| 432 | SET_DEATHARREST_STATE | DEATH_ARR_STATE | `0x47dcf0` Script_Op_SET_CHAR_FLAG | — | SCR_SET_STATE | 8 | high |
| 433 | ADD_TIME_TO_TIMER | ADD_TIME | `0x47eab0` Script_Op_ADD_TIME_TO_TIMER | — | SCR_FOUR_PARAMS | 0 | medium |
| 434 | THREAD_WAIT_FOR_CHAR_IN_AREA_ANY_MEANS | CHAR_AREA_ANY_MEANS | — | `0x477ac0` Script_Decl_THREAD_WAIT_FOR_CHAR_IN_AREA | — | 0 | high |
| 435 | DECLARE_GANG_ONE_DEATH_BASE_BRIEF | DEC_DEATH_BASE_1 | — | `0x475650` Script_Decl_DECLARE_DEATH_BASE_BRIEF | — | 1 | high |
| 436 | DECLARE_GANG_TWO_DEATH_BASE_BRIEF | DEC_DEATH_BASE_2 | — | `0x475650` Script_Decl_DECLARE_DEATH_BASE_BRIEF | — | 1 | high |
| 437 | DECLARE_GANG_THREE_DEATH_BASE_BRIEF | DEC_DEATH_BASE_3 | — | `0x475650` Script_Decl_DECLARE_DEATH_BASE_BRIEF | — | 1 | high |
| 438 | PERFORM_SAVE_GAME | DO_SAVE_GAME | `0x47fe80` Script_Op_PERFORM_SAVE_GAME | — | SCR_DO_SAVE_GAME | 1 | high |
| 439 | DECLARE_CRANE_POWERUP | DO_CRANE_POWERUP | — | `0x4784a0` Script_Decl_DECLARE_CRANE_POWERUP | — | 3 | high |
| 440 | LEVEL_END_POINT_ARROW_AT | LEVEL_END_ARROW1 | `0x478e90` Script_Op_POINT_ARROW_AT | — | SCR_POINT_ARROW_AT | 0 | high |
| 441 | LEVEL_END_POINT_ARROW_AT_3D | LEVEL_END_ARROW2 | `0x478e10` Script_Op_POINT_ARROW_AT_3D | — | — | 1 | high |
| 442 | SET_RECYCLE_MODEL_WANTED | SET_MODEL_WANTED | `0x47eb00` Script_Op_SET_RECYCLE_MODEL_WANTED | — | SCR_TWO_PARAMS | 0 | medium |
| 443 | CHECK_DEATHARREST_EXECUTED | CHECK_DEATH_ARR | `0x47eb40` Script_Op_CHECK_DEATHARREST_EXECUTED | — | — | 21 | high |
| 444 | FORCE_CLEANUP | FORCE_CLEANUP | `0x47eb70` Script_Op_FORCE_CLEANUP | — | SCR_POINTER | 120 | high |
| 445 | STORE_CURRENT_RESPECT | SAVE_RESPECT | `0x47ebe0` Script_Op_SAVE_RESTORE_RESPECT | — | — | 0 | medium |
| 446 | RESTORE_SAVED_RESPECT | RESTORE_RESPECT | `0x47ebe0` Script_Op_SAVE_RESTORE_RESPECT | — | — | 0 | medium |

## How the opcode names were verified

1. **Dispatch grouping 1:1.** The opcode → handler maps of both passes were extracted from the
   jump tables in the 11.44 binary. They match gta2_re's `ExecOpCode_5061C0` /
   `PreExecOpCode_5108D0` switch grouping one to one: 406 runtime opcodes in 202 groups and 79
   declaration opcodes in 36 groups, with no group split or merged. Seq 27 extracted the runtime
   map independently and got the same 406/406.
2. **Counts against DMA's sources.** For every opcode, its occurrences in `data/bil.scr` plus
   `data/bil/*.scr` were counted and compared with the keyword occurrences in DMA's
   `docs/formats/specs/scripting/example/bil*.mis`. **high** = the counts agree (145 handlers).
   **medium** = the handler is only exercised outside bil, or the opcode is emitted by the
   compiler (`IF_JUMP`, `S_*_I`, increments, `IS_CAR_IN_BLOCK`), where a keyword count cannot
   match (90 handlers).
3. **Spot decompiles** of handlers, e.g. `DELAY`, `GOSUB` / `RETURN`, `STOP_THREAD`,
   `CLEAR_WANTED_LEVEL`, `ALTER_WANTED_LEVEL` (Seq 27), `KILL_CHAR` → `Ped::Kill`.

**low** (3) are the open questions below.

## Functions named in this pass

- **238 opcode handlers**: `Script_Op_<KEYWORD>` (202, runtime) and `Script_Decl_<KEYWORD>` (36,
  declaration pass). Each has a plate comment with its opcodes, keywords, the gta2_re function
  with its 10.5 address, the argument struct and the confidence. Renamed user names:
  `SCRCMD_PLAYER_PED` → `Script_Decl_PLAYER_PED`.
- **VM core**:
  - dispatch and stepping: `ScriptThread_ExecOpCode` `0x4805B0`, `ScriptThread_PreExecOpCode`
    `0x481400`, `ScriptThread_Update` `0x481120`, `ScriptThread_Next` `0x476E50`,
    `ScriptThread_EndCmd` `0x4751E0`, `ScriptThread_JumpToCmd` `0x476E80`,
    `ScriptThread_GetOperationType` `0x475700`, `ScriptThread_GetEntityTypeOfCommand` `0x475010`,
    `ScriptThread_SetCharObjective` `0x4751F0`;
  - thread lifetime: `ScriptThread_Init` `0x475B70`, `ScriptThread_AssignId` `0x4751B0`,
    `ScriptThread_SpawnThread` `0x47ECB0`, `MissionScript_SpawnThread` `0x47F200`;
  - thread state: `ScriptThread_DisableThread` `0x478240`, `ScriptThread_EnableThread`
    `0x47A860`, `ScriptThread_GetBonusResult` `0x478450`,
    `ScriptThread_DisableBasicKfsFromSave` `0x481270`, `ScriptThread_MissionFailOnArrest`
    `0x47F550` (was `JobFailed`);
  - pool: `ScriptThreadPool_Ctor` `0x481310` (was `InitS16`), `ScriptThreadPool_Dtor` `0x4812E0`,
    `ScriptThreadPool_DeletingDtor` `0x481C10`, `ScriptThreadPool_Allocate` `0x4767A0` (was
    `relToMissions`), `ScriptThreadPool_UpdateNoDeallocate` `0x481380`;
  - manager and cleanup: `MissionScript_ExecuteScriptThreads` `0x481900` (was `relToMissions`),
    `MissionScript_RestoreAnsweredPhones` `0x481200`, `MissionScript_RemovePhoneThread`
    `0x4763B0`, `MissionScript_FindPhoneThreadByObjId` `0x4763E0`, `MissionCleanup_Ctor`
    `0x474E50` (was `initS17_mission`), `MissionCleanup_FindFreeEntry` `0x474E80`,
    `MissionCleanup_PushObject` `0x476D50`.
- **Types**: `S16` → `ScriptThreadPool`, `S16_sub1` → `ScriptThread` (fields named as above),
  `S17_mission` → `MissionCleanupList` (relaid out, new `MissionCleanupEntry`). Globals as in the table above.

### Handler callees (from gta2_re, by call-sequence alignment)

For each handler, the sequence of its direct calls in 11.44 was aligned (Needleman-Wunsch,
iterated with already-known pairs as anchors) with the calls in its gta2_re counterpart. A callee
was renamed only when the match is strong: either its 10.5 address equals its 11.44 address, or at
least two handlers agree with no dissent. Only `FUN_` functions were renamed. A spot check of four
single-vote candidates found two wrong (`0x476270` is `Car_AddFlags(0x10)`, `0x4340F0` a plain
getter), so those were **not** applied; they are listed further down.

| VA | Ghidra name now | gta2_re | evidence |
|---|---|---|---|
| `0x403a80` | Ped_GetObjective | Ped::get_objective_403A80 | 10.5 address = 11.44 address |
| `0x411940` | Car_GetCarInfoIdx | Car_BC::GetCarInfoIdx_411940 | 10.5 address = 11.44 address |
| `0x421720` | Car_IsOnTrailer | Car_BC::IsOnTrailer_421720 | 10.5 address = 11.44 address |
| `0x421980` | Player_GetScore | Player::GetScore_421980 | 10.5 address = 11.44 address |
| `0x421d80` | Car_HasSpriteZoom | Car_BC::HasSpriteZoom_43A230 | 2 handlers agree |
| `0x44d670` | Door_RegisterDoubleDoor | Door_4D4::RegisterDoubleDoor_49D1F0 | 2 handlers agree |
| `0x44db00` | Door_RegisterDoubleDoorNoCheck | Door_4D4::RegisterDoubleDoorNoCheck_49CFA0 | 2 handlers agree |
| `0x463f10` | LightIntensityRadius_SetRadius | LightIntensityRadius::SetRadius_463F10 | 10.5 address = 11.44 address |
| `0x469010` | Light_Init | Light_1D4CC::Init_469010 | 10.5 address = 11.44 address |
| `0x469070` | Light_SetFlashing | Light_1D4CC::SetFlashing_469070 | 10.5 address = 11.44 address |
| `0x475010` | ScriptThread_GetEntityTypeOfCommand | miss2_0x11C::GetEntityTypeOfCommand_503410 | 4 handlers agree |
| `0x4751f0` | ScriptThread_SetCharObjective | miss2_0x11C::SetCharObjective_504110 | 4 handlers agree |
| `0x4754d0` | Fix16_GetValue | Fix16::get_value_4754D0 | 10.5 address = 11.44 address |
| `0x4758a0` | Gang_SetRemap | Gang_144::SetRemap_4758A0 | 10.5 address = 11.44 address |
| `0x4758b0` | Gang_SetBasicWeapon | Gang_144::SetBasicWeapon_4758B0 | 10.5 address = 11.44 address |
| `0x4758c0` | Gang_SetAngryWeapon | Gang_144::SetAngryWeapon_4758C0 | 10.5 address = 11.44 address |
| `0x4758d0` | Gang_SetHateWeapon | Gang_144::SetHateWeapon_4758D0 | 10.5 address = 11.44 address |
| `0x4758e0` | Gang_SetGangCarModel | Gang_144::SetGangCarModel_4758E0 | 10.5 address = 11.44 address |
| `0x4758f0` | Gang_SetGangCarRemap | Gang_144::SetGangCarRemap_4758F0 | 10.5 address = 11.44 address |
| `0x475900` | Gang_SetKillAffectsRespect | Gang_144::SetKillAffectsRespect_475900 | 10.5 address = 11.44 address |
| `0x475940` | Gang_SetArrowColour | Gang_144::SetArrowColour_475940 | 10.5 address = 11.44 address |
| `0x475b40` | Ped_ClearLastCharPunched | Ped::clear_last_char_punched_475B40 | 10.5 address = 11.44 address |
| `0x475b50` | Ped_IsOnFire | Ped::IsOnFire_475B50 | 10.5 address = 11.44 address |
| `0x4763b0` | MissionScript_RemovePhoneThread | ScriptManager_C1EA8::RemovePhoneThread_512A70 | 2 handlers agree |
| `0x4763e0` | MissionScript_FindPhoneThreadByObjId | ScriptManager_C1EA8::FindPhoneThreadByObjId_512AD0 | 3 handlers agree |
| `0x4766d0` | Player_GetGangCurrLocation | Player::get_gang_curr_location_4766D0 | 10.5 address = 11.44 address |
| `0x476790` | Game_GetLocalPlayerIdx | Game_0x40::GetLocalPlayerIdx_476790 | 10.5 address = 11.44 address |
| `0x476840` | Hud_Arrow_SetArrowAim | Hud_Arrow_7C::SetArrowAim_476840 | 10.5 address = 11.44 address |
| `0x476850` | Hud_Arrow_SetArrowTargetPed | Hud_Arrow_7C::SetArrowTargetPed_476850 | 10.5 address = 11.44 address |
| `0x476860` | Hud_Arrow_SetArrowTargetCar | Hud_Arrow_7C::SetArrowTargetCar_476860 | 10.5 address = 11.44 address |
| `0x476870` | Hud_Arrow_SetArrowTargetObject | Hud_Arrow_7C::SetArrowTargetObject_476870 | 10.5 address = 11.44 address |
| `0x476930` | Generator_Activate | Generator_2C::Activate_4C1A70 | 4 handlers agree |
| `0x476a90` | Door_GetState | Door_38::get_state_476A90 | 10.5 address = 11.44 address |
| `0x476ae0` | Light_SetIntensity | Light_28::SetIntensity_476AE0 | 10.5 address = 11.44 address |
| `0x476d50` | MissionCleanup_PushObject | Miss2_25C::push_type_2_502FF0 | 2 handlers agree |
| `0x476e80` | ScriptThread_JumpToCmd | miss2_0x11C::JumpToCmd_503650 | 2 handlers agree |
| `0x478240` | ScriptThread_DisableThread | miss2_0x11C::DisableThread_505790 | 2 handlers agree |
| `0x478450` | ScriptThread_GetBonusResult | miss2_0x11C::GetBonusResult_505EA0 | 2 handlers agree |
| `0x47a860` | ScriptThread_EnableThread | miss2_0x11C::EnableThread_50A9E0 | 2 handlers agree |
| `0x483c50` | Object_PoolGiveAndMarkDone | Object_2C::PoolGiveAndMarkDone_5291D0 | 3 handlers agree |
| `0x483c60` | Object_PoolGiveAndSetDone | Object_2C::PoolGiveAndSetDone_5291E0 | 2 handlers agree |
| `0x485320` | Object_NewWithPedRefIdx | Object_5C::NewWithPedRefIdx_5299F0 | 2 handlers agree |
| `0x485480` | Object_NewPhysicsObjUnlessBlocked | Object_5C::NewPhysicsObjUnlessBlocked_529BC0 | 2 handlers agree |
| `0x485540` | Object_CreateExplosion | Object_5C::CreateExplosion_52A3D0 | 2 handlers agree |
| `0x4af660` | PublicTransport_TrainStationForZone | PublicTransport_181C::TrainStationForZone_57B4B0 | 2 handlers agree |
| `0x4c5e60` | Hud_Arrow_SetArrowColour | Hud_Arrow_7C::SetArrowColour_5D0510 | 2 handlers agree |
| `0x4c6860` | Hud_Brief_ClearAllBriefsWithPriority | Hud_Brief_704::ClearAllBriefsWithPriority_5D4890 | 2 handlers agree |
| `0x4c9310` | Hud_Pager_C_Array_CreateTimer | Hud_Pager_C_Array::CreateTimer_5D31F0 | 2 handlers agree |
| `0x4c9360` | Hud_Pager_C_Array_AddOnScreenCounter | Hud_Pager_C_Array::AddOnScreenCounter_5D3220 | 2 handlers agree |
| `0x4ca8e0` | Hud_Arrow_7C_Array_AllocArrow | Hud_Arrow_7C_Array::AllocArrow_5D1050 | 2 handlers agree |

**Candidates, not applied** (one handler votes for them; about half are wrong in the spot check):

| VA | current | gta2_re candidate |
|---|---|---|
| `0x40e2f0` | FUN_0040e2f0 | RouteFinder::RoadOn_588950 |
| `0x410580` | FUN_00410580 | root_sound::DeclareRadioStation_40F030 |
| `0x4119b0` | FUN_004119b0 | gtx_0x106C::get_car_info_5AA3B0 |
| `0x411a00` | FUN_00411a00 | Game_0x40::IsSpriteInAnyPlayerView_4B9890 |
| `0x414f80` | FUN_00414f80 | SpriteList_4::GetSpriteForModel_5A6A50 |
| `0x41de40` | FUN_0041de40 | BonusTracker_1C0::AllocRule_431FE0 |
| `0x421c00` | FUN_00421c00 | CarPhysics_B0::get_car_velocity_4211C0 |
| `0x421df0` | FUN_00421df0 | Car_BC::IsBeingCrushed_43DD50 |
| `0x422e00` | FUN_00422e00 | Car_BC::SetCarGraphic_43CDF0 |
| `0x4230d0` | FUN_004230d0 | Car_BC::IsAreaDamaged_43D1C0 |
| `0x4340f0` | FUN_004340f0 | Map_0x370::FindGroundZForCoord_4E5B60 |
| `0x445bb0` | FUN_00445bb0 | Ped_List_4::GetPedsCount_4716B0 |
| `0x446120` | FUN_00446120 | Ped_List_4::KillAndClearAllPeds_4715A0 |
| `0x4497d0` | FUN_004497d0 | Crane_15C::GetCarFromCrane_480DA0 |
| `0x44a3e0` | FUN_0044a3e0 | Car_BC::AddFlags_421890 |
| `0x44c760` | FUN_0044c760 | Door_4D4::RegisterDoorInfo_49D2D0 |
| `0x45a480` | FUN_0045a480 | Game_0x40::ExitGame_4B8BD0 |
| `0x45bb50` | FUN_0045bb50 | Crane_15C::GetRotorSprite_411A00 |
| `0x45da20` | FUN_0045da20 | Gang_144::SetRespect_4BEE30 |
| `0x45db20` | FUN_0045db20 | Gang_144::SetGangKillReaction_4BEF50 |
| `0x45e5f0` | FUN_0045e5f0 | GameSession_578::SetBonusRatingTextIdx_4C5AB0 |
| `0x462ce0` | FUN_00462ce0 | Map_0x370::SetZoneCarDensity_4DF9D0 |
| `0x462d00` | FUN_00462d00 | Map_0x370::SetZoneBadCarRatio_4DFA10 |
| `0x462d20` | FUN_00462d20 | Map_0x370::SetZonePedDensity_4DFA70 |
| `0x462d40` | FUN_00462d40 | Map_0x370::SetZoneCarThiefRatio_4DFAB0 |
| `0x462d80` | FUN_00462d80 | Map_0x370::SetZoneGangCharRatio_4DFAF0 |
| `0x462da0` | FUN_00462da0 | Map_0x370::SetZoneGangCarRatio_4DFA50 |
| `0x462ea0` | FUN_00462ea0 | Ang16::MultiplyByFix16_401CB0 |
| `0x463f60` | FUN_00463f60 | Map_0x370::ChangeBlock_4E8620 |
| `0x464060` | FUN_00464060 | Map_0x370::AddNewBlock_4E87C0 |
| `0x464110` | FUN_00464110 | Map_0x370::RemoveBlock_4E8940 |
| `0x464210` | FUN_00464210 | Map_0x370::LowerLevel_4E8B70 |
| `0x465280` | FUN_00465280 | Map_0x370::SetZoneInfo_4DF8C0 |
| `0x46c140` | FUN_0046c140 | MapRenderer::SetAmbientLevel_4E9D50 |
| `0x474ed0` | FUN_00474ed0 | Miss2_25C::push_type_2_503050 |
| `0x474fb0` | FUN_00474fb0 | miss2_8::add_503160 |
| `0x4751d0` | FUN_004751d0 | miss2_0x11C::StopThread_503610 |
| `0x475910` | FUN_00475910 | Gang_144::SetKillRespectChange_475950 |
| `0x475950` | FUN_00475950 | GangPool_CA8::SwapGangSlots_4BF230 |
| `0x475b20` | FUN_00475b20 | PedGroup::IsAllMembersInSomeCar_4CAA20 |
| `0x475b70` | FUN_00475b70 | miss2_0x11C::InitThread_511930 |
| `0x475c30` | FUN_00475c30 | CarManager_6C::SpawnCar_426E10 |
| `0x476270` | FUN_00476270 | Sprite::DispatchCollisionEvent_5A3100 |
| `0x476280` | FUN_00476280 | Car_BC::SetCarThreadPending_476360 |
| `0x4764a0` | CarManager_SpawnCarScript | Car_BC::UpdateSpriteNum_4435F0 |
| `0x4766e0` | FUN_004766e0 | Map_0x370::GetZoneAtPosOfType_4DF4D0 |
| `0x476a30` | FUN_00476a30 | DoorData_10::Close_49C590 |
| `0x476a60` | FUN_00476a60 | DoorData_10::Open_49C4E0 |
| `0x476bc0` | FUN_00476bc0 | Miss2_25C::MissionCleanUp_502DC0 |
| `0x476df0` | FUN_00476df0 | miss2_8::AllocFrame_5031A0 |
| `0x47ecb0` | FUN_0047ecb0 | miss2_0x11C::SpawnThread_511960 |
| `0x47f420` | FUN_0047f420 | ScriptManager_C1EA8::RemovePhoneThreadByObjId_512AA0 |
| `0x47f760` | FUN_0047f760 | miss2_0x11C::DeallocOrDeleteItem_505B10 |
| `0x485290` | FUN_00485290 | Object_2C::SetConveyorSpeed_529030 |
| `0x4af460` | FUN_004af460 | TrainStation_34::CalculateWagonCount_578820 |
| `0x4af5f0` | FUN_004af5f0 | PublicTransport_181C::KillAllPassengers_579B20 |
| `0x4b9d50` | FUN_004b9d50 | Sprite::ResolveCollisionWithCarPedOrObject_5A2A30 |
| `0x4bea90` | FUN_004bea90 | SpriteList_4::FirstSpriteOfType_5A6CA0 |
| `0x4c93b0` | FUN_004c93b0 | Hud_Pager_C_Array::ClearPager_5D3280 |
| `0x4c93f0` | FUN_004c93f0 | Hud_Pager_C_Array::AddTime_5D32F0 |

**Existing names that gta2_re contradicts.** Told to the owners, not renamed:

- `Ped_AttachToGame` `0x4411B0`: the only callee of `Script_Op_KILL_CHAR`, aligned to
  `Ped::Kill_46F9D0`.
- `Ped_GetField20e` `0x4039F0` = `Ped::GetOffscreenCounter_4039F0` (same address).
- `unsure_Ped_GetBit11` `0x433CA0` = `Ped::GetAttacking_433CA0` (same address, 2 handlers).
- `unclear` `0x44C840` = `gmp_block_info::init_44C840`.
- `?isPlayerAlive` `0x475A20` = `ScriptManager::get_field_C1E2C_475A20` (kept; the gta2_re name
  says less).

## 10.5 ↔ 11.44 address coincidences

gta2_re's suffixes are 10.5 addresses, but two kinds of coincidence are real and measurable:

- **Functions**: 42 callees sit at exactly their 10.5 address, e.g. `Player::AddScore_41DC40`,
  `Ped::SetRemap_433C10`, the inline `Gang_144` setters at `0x4758A0…0x475940`, and
  `Hud_Arrow_7C::SetArrow*` at `0x476840…`. gta2_re itself quotes 9.6f addresses that equal ours
  (`Allocate_4767A0`, "9.6f inlined ctor 0x481310"). 11.44 apparently keeps the 9.6f layout for
  large parts of `.text`.
- **Script globals**: 10.5 `0x6F805C…0x6F8070` = 11.44 `0x6644B8…0x6644CC`, a constant delta of
  `0x93BA4` for that block (checked on 6 globals with matching xrefs). Do not extrapolate the
  delta to other blocks without checking.

## Open questions

- **217 / 218 / 301 / 302 (lights)**: 219 and 301 dispatch to one runtime handler
  (`Script_Op_CREATE_LIGHT`), 217 and 302 to `Script_Decl_LIGHT_SET`, and 218 has no handler.
  gta2_re's enum calls 218 and 301 `LIGHT_DECSET*`, which contradicts the dispatch. Probably the
  gta2_re enum swaps 301/302 (and 217/218). Confidence low until a handler is read.
- **224**: `bil.scr` uses it 3 times, while the keyword `SET_GANG_RESPECT` never occurs in the
  bil `.mis` files. The name `SET_GANG_KILL_REACTION` comes from gta2_re; its callee
  `FUN_0045db20` aligns to `Gang::SetGangKillReaction`.
- **67 `FUNCTION`**: 85 occurrences in bil.scr, the same count as `WHILE_EXEC`. It has no
  handler, so it may be the compiled form of a `WHILE_EXEC` head rather than a `FUNCTION`
  keyword.
- **`GIVE_WEAPON_1` vs `_2`** (138 / 266): one handler. What the argument variants mean is not
  confirmed.
- `SCR_CMD_TYPE` in Ghidra has only values 0..231; the remaining names (232..446) are in this
  table but not yet in the enum.

Sources: the binary (11.44), DMA's scripting docs and bil missions
(`docs/formats/specs/scripting/`), gta2_re (see [CREDITS.md](../../CREDITS.md)), and Seq 27's
police research for opcodes 163/164/318/418/421.
