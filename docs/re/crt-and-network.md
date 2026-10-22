# CRT, startup and network code in gta2.exe 11.44

This page covers the code outside the game's own subsystems: the statically linked MSVC
runtime, the old iostream library, process startup, the 11.44 patch stubs, and the DirectPlay
multiplayer layer with its lobby dialog. It came out of a breadth-first naming pass (Seq 45)
that gave a name to every unnamed function in `0x400000-0x40FFFF`, `0x4D0000-0x52FFFF`
and `0x560000-0x56FFFF`. Before the pass those ranges had 181 + 164 + 15 = **360** unnamed
functions, and after it they have **0**. 30 of the new names carry `unsure_`.

Every address is a VA in vanilla `gta2.exe` 11.44 (base `0x3F0000`). Every name and plate
comment is in the Ghidra DB (`gta-2-recovered.gpr`, program `gta2.segments.fixed.exe`) and so in
`re/`. Each comment ends in `(Seq 45)` with one line of evidence. Five sub-agents proposed the
names. The coordinator then spot-checked about 15 of them in the decompiler and disassembly,
corrected five of them and named seven itself (both listed at the end of §5). So a `high` row means the body matches the
named CRT routine or Win32 call pattern, not that every line was audited.

## 1. Which compiler: Visual C++ .NET 2002 (7.0.9466)

Measured from the PE file itself:

- **Linker version** in the optional header: **7.0**.
- The **Rich header** lists compiler build **9466** for C (`prodid 28`, 140 objects), C++
  (`prodid 29`, 123 objects) and MASM (`prodid 64`). It also lists the 7.0 linker (`61`) and
  cvtres (`69`). 9466 is the RTM build of VC++ .NET 2002. 74 objects were built by VC6-era tools
  (`prodid 4`, build 8447), most likely import libraries such as the DirectX SDK `.lib`s.
- The CRT has the VC7 additions: `__security_check_cookie` / `___security_init_cookie` /
  `___report_gsfailure` (`/GS`, cookie at `0x595880`), `__ftol2`, `__SEH_prolog`/`__SEH_epilog`,
  `__resetstkoflw`, and a `__crtExitProcess` that tries `mscoree!CorExitProcess` first.
- The **old pre-standard iostream** (`<iostream.h>`: `ios`, `streambuf`, `filebuf`, `ostream`,
  `ofstream`) is statically linked at `0x4D48D0-0x4D5CC5`. VC++ 7.1 (2003) dropped that library,
  so its presence also points to 7.0.

Ghidra's FID labels some functions as "Visual Studio 2003". That label comes from FID's
signature database, which matches the nearest library it has, so it is not evidence against 7.0.
The PE timestamp says 2004-04-27, while the original 1999 release was built with VC6.
**Hypothesis (not checked):** the 9.6/11.x builds were recompiled with VS.NET 2002 at that time.

## 2. Layout of the range

| Range | What it is |
|---|---|
| `0x4D0000-0x4D47xx` | Game code: weapons tail, `WndProc`, `WinMain` (+ the false split `WinMain_AfterNoppedMutexCheck_Frag`, was `WinMain2`), `Startup_ConnectMultiplayerFromRegistry`, video/renderer DLL loading (`LoadRenderDll`, `InitVideoDll`). |
| `0x4D48D0-0x4D5CC5` | Old MSVC iostream (about 50 functions). The game uses it only for logs: `do_miss_logging` → `ofstream_Open`, and `DebugLog_WriteLine` → `ostream_OperatorShiftString`. |
| `0x4D5CE1-0x4E3Fxx` | MSVC 7.0 CRT in library link order: heap (`malloc`, `sbheap.c`), C++ EH (`frame.cpp`, `Unwind@` funclets), stdio, lowio, `output.c`/`input.c`, float conversion (`cvt.c`, `intrncvt.c`, `strgtold`, `x10fout`), mbctype, time/tz, environment, signals. |
| `0x51C730`, `0x52E0A0` | Two static-initialiser functions reached only through data pointers (`0x584498`, `0x586D48`, presumably the `__xc` initialiser table): `StaticInit_DebugFlagsDefaults` and `StaticInit_RandomDebugLog`. They are game code, not CRT. |
| `0x56DBE0-0x56DFxx` | Code that the 11.44 community patch put into `.text` raw slack past VirtualSize `0x56DBC0` (§4). |

### Process startup

`entry` `0x4D84F9` is patched to `JMP Patch1144_EntryStub` (`0x56DCDA`). The stub stores
`GetProcessHeap()` in `0x676CD4`, re-executes the two pushes that the JMP overwrote
(`push 0x60; push 0x5787B8`), and jumps to `WinMainCRTStartup_Body` `0x4D8500`. From there the
VC7.0 `crt0.c` sequence runs: `__SEH_prolog`, `GetVersionExA`, `__heap_init`, `__ioinit`,
`GetCommandLineA`, `___crtGetEnvironmentStringsA`, `__setargv`, `__setenvp`, `__cinit` (FP
init, `__xi`/`__xc` tables), `__wincmdln`, `WinMain` `0x4D1170`, `Crt_Exit`/`__cexit`.

## 3. CRT functions identified

The full list is the table in §6. By source module:

- **Heap**: `__heap_alloc`, `__nh_malloc`, `_malloc`, `_free`, `_calloc`, `_realloc`, `__msize`, `__heap_init`, `___heap_select`, `___sbh_*` (small-block heap), `__callnewh`, `operator_new`.
- **Startup/exit**: `WinMainCRTStartup_Body`, `__cinit`, `_doexit`, `__cexit`, `__c_exit`, `__exit`, `__crtExitProcess`, `__amsg_exit`, `__NMSG_WRITE`, `__FF_MSGBANNER`, `__setargv`, `_parse_cmdline`, `__setenvp`, `__wincmdln`, `__ioinit`, `___security_init_cookie`, `___report_gsfailure`, `__onexit`, `_atexit`.
- **C++ EH**: `___CxxFrameHandler`, `___InternalCxxFrameHandler`, `FindHandler`, `FindHandlerForForeignException`, `CatchIt`, `CallCatchBlock`, `BuildCatchObject`, `_AdjustPointer`, `TypeMatch`, `___FrameUnwindToState`, `___CxxExceptionFilter`, `__CxxUnhandledExceptionFilter`, `_CallSETranslator`, `CatchGuardHandler`, `__IsExceptionObjectToBeDestroyed`, `__EH_prolog`, `__SEH_prolog`/`epilog`, `__global_unwind2`, `__local_unwind2`, `_terminate`, `type_info_Dtor`, plus the `Unwind@<addr>` funclets from `0x4E3980`.
- **stdio**: `fopen`/`__fsopen`/`__openfile`/`__getstream`, `_fclose`, `__fread_lk`, `__fwrite_lk`, `__getc_lk`, `_ungetc`, `_fseek`, `_ftell`, `_rewind`, `_fflush`/`__flush`/`_flsall`, `__filbuf`, `__flsbuf`, `__flswbuf`, `__getbuf`, `__freebuf`. The `_lk` spelling follows FID. These bodies take no lock.
- **printf/scanf**: `__output`, `__woutput`, `__input`, `sprintf`, `_vsprintf`, `swprintf`, `_vswprintf`, `__scprintf`/`__vscprintf`/`__scwprintf`/`__vscwprintf`, `_sscanf`, `write_char`/`write_string`/`_write_wchar`.
- **Low-level I/O**: `__sopen`, `__read_lk`, `__write_lk`, `__close_lk`, `__lseek`, `__lseeki64`, `__chsize`, `__setmode_lk`, `__commit`, `__isatty`, `__alloc_osfhnd`, `__set_osfhnd`, `__free_osfhnd`, `__get_osfhandle`, `__open_osfhandle`, `__dosmaperr`.
- **Files/dirs**: `__findfirst`/`__findnext`/`__findclose`, `__stat`, `__fullpath`, `__getcwd`, `__getdcwd`, `__chdir`, `__chdrive`, `__validdrive`.
- **Strings/conversion**: `_strlen`, `_strcpy`, `_strcat`, `_strcmp`, `_strncmp`, `__stricmp`, `__strnicmp`, `_strrchr`, `_strpbrk`, `__strupr`, `__strdup`, `_memcpy`, `_memmove`, `_memset`, `_wcscpy`, `wcslen`, `_wcsncpy`, `_wcscmp`, `_tolower`, `_toupper`, `_isctype`, `_atol`, `_xtoa`/`__itoa`/`__ltoa`/`__ultoa`, `_x64toa`/`__i64toa`/`__ui64toa`, `__itow`/`__ltow`/`__ultow`/`__i64tow`/`__ui64tow`, `_bsearch`.
- **Floating point**: `__ftol2`, `__fpmath`, `__cfltcvt_init`, `__setdefaultprecision`, `__control87`/`__controlfp`, `__ms_p5_test_fdiv`, `__fassign`, `__cfltcvt`, `_cftoe`/`_cftof`/`_cftog`, `__fptostr`, `__fltout`, `__I10_OUTPUT`, `___strgtold12`, `___mtold12`, `__atodbl`/`__atoflt`/`__atoldbl`, `__ld12tod`/`__ld12tof`/`__ld12told`, `__ld12mul`, `___multtenpow12`, `___dtold`, `__ZeroTail` … `__ShrMan`, `__FillZeroMan`, `___add_12`/`___shl_12`/`___shr_12`. 64-bit helpers: `__allmul`, `__alldiv`, `__allshr`, `__aulldiv`, `__aulldvrm`.
- **Multibyte/locale**: `___initmbctable`, `__setmbcp`, `_setSBCS`, `_setSBUpLow`, `__CPtoLCID`, `__mbctoupper`/`lower`, `__ismbbtype`, `__ismbblead`, `__mbsicmp`, `__mbsrchr`, `__mbspbrk`, `__mbschr`, `__mbsnbicoll`, `__mbstowcs_lk`, `_mbtowc`, `_wctomb`, `___crtLCMapStringA`, `___crtGetStringTypeA`, `___crtCompareStringA`, `__ansicp`, `__convertcp`.
- **Time**: `_time`, `_ctime`, `_localtime`, `_gmtime`, `__tzset`, `_cvtdate`, `__isindst`, `___loctotime_t`, `___timet_from_ft`.
- **Environment/signals/misc**: `_getenv`, `__putenv_lk`, `_findenv`, `_copy_environ`, `__wtomb_environ`, `_signal`, `_raise`, `_siglookup`, `__XcptFilter`, `__chkstk`, `__resetstkoflw`, `___crtMessageBoxA`, `__ValidateRead`/`Write`, `_ValidateExecute`.

Game-renamed CRT functions kept as they were: `Crt_Srand` `0x4D71ED` and `Crt_Rand` (`srand`/`rand`),
`Crt_Exit` `0x4D73A7` (`exit`), `copySomething` `0x4D78E0`.

Random numbers: every game roll goes through `Random_S16` 0x472E00 (roll below a max) and `Crt_Rand` 0x4D71F7,
whose whole state is the MSVC seed `g_CrtRandSeed` 0x595410. `Crt_Srand(1)` runs in `RandomDebugLog_Ctor`
(static init) and again in `Game_Ctor`, so every level starts from seed 1. `g_RandomDebugLog` 0x663764 only keeps the
last value for a debug log; it is not generator state.

## 4. The 11.44 patch stubs (`Patch1144_*`)

The community 11.44 build adds about 15 small routines in `.text` slack. The game reaches them
through JMPs written over original instructions, and most of them jump straight back. Because of
that, Ghidra split some original functions into a head plus a detached tail. Those tails are
named `*_Frag`/`*Fragment` (for example `0x40653E`, `0x40667C`, `0x406C92`, `0x40720D`).

- `Patch1144_EntryStub` `0x56DCDA`: caches the process heap, see §2.
- `Patch1144_NetDlg_AllocMapTable` `0x56DCAB` (was `Patch1144_NetSession_AllocSlotBlock`): `HeapAlloc(…, 0x518)` into `NetDlg+4`. It moves
  the per-map lobby slot table out of the dialog object into a heap block. The seven
  `Patch1144_NetLobby_*Hook` stubs (`0x56DBE0-0x56DC4C`) redirect the old `this+0x30C`/`+0x410`
  table accesses to that block. Plausibly this raised the map-count limit (medium confidence).
- `Patch1144_Mmp_StrToLowerInPlace` `0x56DD18`: lowercases `.mmp` map file names
  (`NetDlg_ReadMmpMapFiles`).
- `Patch1144_NetDlg_SetMapNameNAText` `0x56DE0C`: shows `N/A: %s` for a map the player does not
  have (lobby item `0x41E`).
- `Patch1144_NetDlg_AutoCreateHook`/`StoreSessionsAvailableHook`/`AutoJoinHook` `0x56DE95-0x56DED4`
  (were `ChatFlagResetHook`/`StoreChatFlagHook`/`ChatFocusHook`): the `-c`/`-j` command-line
  auto-create and auto-join, flags `g_NetDlgAutoCreate`/`g_NetDlgAutoJoin`/`g_NetDlgSessionsAvailable`
  at `0x676FF0..2` (network.md §2).
- `Patch1144_OnKeyDown_LaunchManagerHook` `0x56DD67`: in `Player_OnKeyDown`, launches the GTA2 Manager
  unless flag `0x673E2C` is set.
- Seq 47: ten more stubs live in the code cave at the start of `.text` (`0x3F1000-0x3F1Cxx`, next to
  `appendToFile`/`RegGet`/`Game_FirstActiveCamera`, also patch code). Their jump-back targets are the
  `*_Frag` tails `0x4797BB`, `0x47AB91`, `0x47D615`, `0x45F269`, `0x45FAFF`, `0x45FB59`, `0x4A71F2`.

  | Address | Name | Hooked into / evidence |
  |---|---|---|
  | `0x3F10B0` | `Patch1144_Script_GetCharPlayer` | CALLed 4x from `Script_Op_SET_CONTROL_STATUS`; char → `Ped->player` (+0x15C) or 0 on a null ped |
  | `0x3F135C` | `Patch1144_Game_FirstActiveCamera_RandomHelper` | DL 0/1 → 0, else `Random_U8`; caller `Game_FirstActiveCamera` |
  | `0x3F1490` | `Patch1144_Debug_WriteSessionInfoDump_LogHook` | 2x `appendToFile(0x5738E4)`, back to `0x45F269` |
  | `0x3F14A8` | `Patch1144_Keyboard_RecordInputEvent_LogHook` | same, back to `0x45FAFF` |
  | `0x3F14C0` | `Patch1144_Keyboard_FlushReplayLog_LogHook` | same, back to `0x45FB59` |
  | `0x3F158C` | `Patch1144_NetDlg_SetIconHook` | `NetDlg_DialogProc`: LoadIcon(0x65) + WM_SETICON, then `0x56DE95` |
  | `0x3F15BC` | `Patch1144_Hud_DrawChatInput_LowercaseHook` | lowercases chat text at `0x5E9F08` (A-Z, '/'→'?'), back to `0x4C8990` |
  | `0x3F163C` | `Patch1144_Script_Op_GIVE_WEAPON_NullCheckHook` | skips on a null char/ped, back to `0x4797BB`/`0x4797E6` |
  | `0x3F1674` | `Patch1144_Script_Op_PUT_CAR_ON_TRAILER_NullCheckHook` | null check, back to `0x47D615`/`0x47D636` |
  | `0x3F1AFA` | `Patch1144_Script_Op_CHANGE_GANG_CHAR_RESPECT_ExtHook` | opcode 0x106 sub-types 0x65-0x68/0x6F-0x72/0x78-0x79 copy script variables (medium), else back to `0x47AB91` |

- Already named earlier: `Patch1144_LoadGXT_MmpOverrides` `0x56DF08` and
  `Patch1144_LoadGXT_ClearFlagAndContinue` `0x3F1664`.

## 5. Network architecture

The full reference is now [network.md](network.md) (Seq 27 networking pass): startup, the `Network`
object, the `NetDlg` lobby, the byte-exact wire format, the lockstep, MP game logic, 74 merged bugs
and the DirectPlay surface our host must provide. In short:

- DMA's source file is `NetworkX.cpp` (it appears in the `DisplayError` calls).

- The game uses **IDirectPlay3 (wide)** at `Network+0x5E0` and **IDirectPlayLobby2** at `+0x5DC`
  (`Network_CreateInterfaces` `0x408C80`), not IDirectPlay4. The vtable offsets (network.md §9.2) are the same.
- `Network.state` (`+0x44`): 1 = enumerating sessions, 2 = in game, 3 = hosting in the lobby,
  4 = joined in the lobby, 5 = idle (ctor). The earlier "2 = idle/hosting, 3/4 = in game" was wrong.
- Player tables: `pendingPlayers` `+0x5E4` and `players` `+0x754` (`NetPlayerTable`, 0x170; group
  id, count, `frameSeq[6]` `+0x75C`, six 0x2C slots from `+0x764`, settings blob, session desc).
- Wire messages are types 1..9; `0x409680` decodes them in place and is now
  `Network_DecodeReceivedMessage` (was `Network_PackMessage`). Lockstep frames go through
  `Network_ReceiveGameMessage` `0x40C120` (was `Network_ReceiveFrameData`).
- Startup is `Startup_ConnectMultiplayerFromRegistry` `0x4D0ED0`, called from `WinMain` after
  `CmdLine_ParseArguments` `0x461810` sets `isMultiplayer` (`-n`/`-c`/`-j`). The `.mmp` scan is
  `NetDlg_ReadMmpMapFiles` `0x407930`; the settings land in `g_NetGameSettings` `0x673E30`.

Struct facts for the layouts were sent to their owners: PedGroup/Ped → Seq 27,
TrailerController/Car → Seq 43 (which identified the `0x40F7C0-0x40F830` accessors as `CarPhysics_Get/Set{CenterPos,ZPos,Heading}`), PedGameObject/Object/collision record → Seq 46.

### Corrections made while checking the sub-agents' names

- `0x409BC0`/`0x409C80` were proposed as `Network_KickPlayer*`. vtbl+0x1C is
  `DeletePlayerFromGroup`, so they are now `Network_DeletePlayerFromGroupByName/ByIndex`, and
  `0x409A30` is `Network_SetGroupId` rather than "SetLocalDpid".
- `0x4D8770` was proposed as `__SEH_prolog`, which already exists at `0x4DC5E4`. Its body is
  `__EH_prolog`.
- `0x4D8500` was proposed as `__tmainCRTStartup`, a name that only exists from VC8. It is now
  `WinMainCRTStartup_Body`.
- Coordinator-named: `__atodbl`/`__atoflt`/`__atoldbl`, `__fptostr`, `__FillZeroMan`. It also split
  the FID conflict at `0x4DFF75`/`0x4DFF8B` into `__ld12tod`/`__ld12tof` by their format descriptor
  (`0x5959C4` has precision 53, i.e. double).

FID conflicts resolved by the sub-agents (names that already existed, not counted in §6):
`__fread_lk` `0x4D63FE`, `__fwrite_lk` `0x4D64E7`, `__getc_lk` `0x4D68F1`, `_ctime` `0x4D7A59`, `_time`
`0x4D7A72`, `__ValidateRead` `0x4E055F`, `__ValidateWrite` `0x4E057B`, `__CPtoLCID` `0x4E07BE`, `_ungetc` `0x4E0F48`.

## 6. Function table (the 360 functions named by this pass)

Confidence: `high` means the body matches the named routine; `medium` means a strong
structural match; `unsure`/`low` means a hypothesis, and the name carries `unsure_` where it
mattered. `coordinator` means the coordinator checked it.

### Network, lobby dialog and misc game code (0x400000-0x40FFFF)

| Address | Name | Confidence | Evidence |
|---|---|---|---|
| `0x401050` | `unsure_Node3DSubPart_RelocatePointers` | unsure | if type==0 adds base delta to nonzero pointers at +0x10,+0x18; called per 32-byte entry from mesh relocator |
| `0x401080` | `unsure_Node3DMesh_RelocatePointers` | unsure | adds delta to pointers of mesh header (+0xc, entries array, +0x10/+0x18), loops count entries calling SubPart relocator |
| `0x4010E0` | `unsure_Node3D_RelocatePointers` | unsure | recursive: adds delta to child/sibling/data pointers (+0x10..+0x24), per-mesh relocate, stores param at +0x3c; file-load fixup |
| `0x4023E0` | `Node3D_ProjectVerticesToScreen` | medium | projects float vertex list by matrix to screen via g_ViewCamera center and Fix16 scale, tracks min/max bounds; no xrefs |
| `0x4029A0` | `File_Write` | high | fastcall wrapper over fwrite(buf,size,count,FILE); mirror of fread at 0x402980 |
| `0x4029C0` | `File_GetSize` | high | ftell/fseek END/ftell/fseek back with DisplayError File.cpp lines 0x38-0x3e; used by ReadWholeFile |
| `0x402CF0` | `File_WriteWhole` | high | copyScriptNameToBuffer, fopen "wb", write once, fclose, DisplayError File.cpp |
| `0x402DA0` | `File_AppendWhole` | high | same as File_WriteWhole but fopen "ab"; only SaveGame calls it |
| `0x402F00` | `File_CloseGlobal` | medium | fcloses g_File if g_FileIsOpen then clears flag; called from error() |
| `0x403130` | `File_GetCharSkipBlanks` | medium | getc loop skipping space/CR/tab; returns 0 on newline/EOF; caller Seq_ReadLabelLine |
| `0x4035A0` | `PedGroup_ResetDoorCursor` | high | sets DAT_0058f512=1; that byte is the seat/door cursor used in PedGroup enter-car update 0x405240 |
| `0x4035B0` | `PedGroup_Init` | high | fastcall zeroes PedGroup fields (leader 0x2c,count 0x34, mode 0x38=2); called by PedGroupPool_Alloc |
| `0x4035E0` | `PedGroup_ClearAllObjectives` | high | Ped_SetObjective+Ped_SetTask NO_OBJ for leader and every member |
| `0x403650` | `PedGroup_KillMembersInCarAndCompact` | high | Ped_OnDeath on members with currentCar, nulls slots, compacts member array; returns bool |
| `0x4037A0` | `PedGroup_AllMembersOnFoot` | medium | returns 0 if any member's currentCar(+0x16c) nonzero, else 1 |
| `0x403870` | `PedGroupPool_Init` | high | startGame; calls 0x4035a0, then PedGroup_Init for 20 groups at 0x5D28C8 stride 0x44 |
| `0x4038E0` | `PedGroup_SetActive` | high | sets byte +0x40=1; paired with PedGroupPool_Alloc |
| `0x4038F0` | `PedGroup_IsActive` | high | returns byte +0x40 used by pool alloc |
| `0x403900` | `PedGameObject_GetCar` | medium | returns +0x84 (PedGameObject.car per gta2_types.h); callers pass ped->gameObject |
| `0x403930` | `Ped_SetGroup` | high | writes Ped+0x164 (group); called from PedGroup_SetLeader/SetMember |
| `0x403940` | `Ped_SetGroupSlot` | high | writes byte Ped+0x23c groupSlot; PedGroup_SetLeader passes 99 |
| `0x403950` | `Ped_SetEngaged` | high | flags |
| `0x403960` | `Ped_ClearEngaged` | high | flags &= ~4 (PED_FLAG_ENGAGED) |
| `0x4039C0` | `Ped_GetEnterCarAsPassenger` | high | returns Ped+0x248 enterCarAsPassenger; pair of Ped_SetEnterCarAsPassenger |
| `0x4039D0` | `Ped_GetCarEnterExitStage` | high | returns byte +0x226 (unsure_carEnterExitStage) |
| `0x403A20` | `Ped_ClearField228` | medium | zeroes byte Ped+0x228 (field82_0x228); caller Ped_ElvisHandling |
| `0x403A50` | `Ped_SetGameObjectField3C` | medium | writes gameObject(+0x168)+0x3c; caller Ped_ElvisHandling |
| `0x403A90` | `Ped_GetTask` | high | returns Ped+0x25c task; Ped_GetObjective is +0x258 |
| `0x403AB0` | `Ped_GetObjectiveTargetCar` | high | returns Ped+0x150 objectiveTargetCar |
| `0x403AD0` | `Ped_GetObjectiveTargetPed` | high | returns Ped+0x148 objectiveTargetPed |
| `0x403AF0` | `Ped_GetTaskTargetPed` | high | returns Ped+0x14c taskTargetPed (setter Ped_SetTarget2Ped) |
| `0x403B10` | `Ped_GetTaskTargetCar` | high | returns Ped+0x154 taskTargetCar (setter Ped_SetTargetCar) |
| `0x403B20` | `Ped_GetTaskTimer` | high | returns short Ped+0x21a taskTimer |
| `0x403B30` | `Ped_GetObjectiveTimer` | high | returns short Ped+0x218 objectiveTimer |
| `0x403B50` | `Ped_SetCarEnterExitStage` | high | writes byte Ped+0x226; pair of getter 0x4039d0 |
| `0x403B70` | `Ped_HasGameObject` | high | returns Ped+0x168 gameObject != 0 |
| `0x403B90` | `Ped_IsEngaged` | high | returns (flags>>2)&1 = PED_FLAG_ENGAGED |
| `0x403BC0` | `Car_IsBankVanOrSwatVan` | medium | Car+0x84 carModel is 4 (BANKVAN) or 0x34 (SWATVAN) |
| `0x403D10` | `PedGroup_LeaderIsInCar` | high | Ped_IsInCar(group+0x2c leader) |
| `0x403D50` | `PedGroup_ClearAndKillAllMembers` | high | Ped_ClearGroup+Ped_OnDeath for leader and members, active=0; no xrefs |
| `0x403DA0` | `PedGroup_DisbandToAmbient` | medium | if active: members clear group/objectives, class ambient, flag 0x400 removal request, then PedGroup_Reset |
| `0x404450` | `PedGroup_FindMemberNotEngaged` | medium | scans members from last to first, returns first with Ped_IsEngaged false else 0 |
| `0x404480` | `PedGroup_LeaderIsEngaged` | high | Ped_IsEngaged(group+0x2c leader) |
| `0x404490` | `PedGroup_FindFarthestMember` | medium | max Chebyshev Fix16 distance of members to leader; returns ped, out distance |
| `0x4045D0` | `unsure_PedGroup_MakeMembersFollowLeader` | unsure | if leader on foot: sets members task 9 and Ped_SetTarget2Ped leader/neighbour, clears bit 11 |
| `0x4046F0` | `PedGroup_UpdateMemberFollowLeader` | high | member idx: if leader has gameObject and dist<DAT_005d304c sets task 9 follow, else resets task |
| `0x404840` | `PedGroup_AllMembersInCar` | medium | no members: leader in car; else all members Ped_GetState==10 |
| `0x4048A0` | `PedGroup_AllMembersInCarOrDead` | medium | all members have state 10 or 9 |
| `0x404900` | `PedGroup_IsMemberFarFromLeader` | medium | Chebyshev Fix16 distance member idx to leader > DAT_005d2814 |
| `0x4049F0` | `PedGroup_IsLeaderNearTargetCar` | high | leader XY vs target(+0x50 sprite pos) Chebyshev dist not greater than DAT_005d2814 |
| `0x404AD0` | `PedGroup_FindNearestAttackingMember` | high | nearest member to idx within limit that is engaged in an attack task (Ped_IsEngagedInAttackTask); returns ped (Seq 48: was 'Aiming') |
| `0x404CE0` | `PedGroup_PromoteLeader` | medium | adds old leader as member, sets new leader slot 99, resets all member tasks; caller PedGroupSetLeader |
| `0x404EF0` | `PedGroup_ReactToAttacker` | medium | sets members/leader to kill attacker (KILL_CHAR_ON_FOOT, Ped_SetTarget2Ped); caller Ped_ReactToAttacker |
| `0x405240` | `PedGroup_UpdateEnterCar` | medium | leader state 3/10/5: sends members to enter car (ENTER_CAR task, door cursor 0x58f512); caller Ped_UpdateAI |
| `0x405760` | `unsure_PedGroup_UpdateMember` | unsure | per-member AI: Ped_SetEngaged, follow/attack by task, uses 0x4045d0 and 0x404ad0; caller Ped_UpdateAI |
| `0x405A40` | `NetDlg_Dtor` | high | sets vtable PTR_0056e598 only; called by 0x406bc0 scalar-deleting dtor |
| `0x405A50` | `NetDlg_SetHwnd` | high | stores HWND at this+0x20218; called from NetDlg_OnInitDialog |
| `0x405A60` | `NetDlg_GetHwnd` | high | returns this+0x20218, used as hDlg in SendDlgItemMessage/GetDlgItem |
| `0x405AA0` | `NetDlg_ShowPage` | high | ShowWindow(HIDE) 30 controls of current page, show 30 of new page (0x78 stride), stores prev/cur page |
| `0x405B10` | `NetDlg_GetPage` | high | returns this+0x2020c current page |
| `0x405B20` | `NetDlg_ClearListView` (was `NetDlg_ClearListControl`, Seq 27 net pass) | medium | SendDlgItemMessage msg 0x1009 (LVM_DELETEALLITEMS) on hDlg; no direct callers |
| `0x405EC0` | `NetDlg_AppendChatLine` | high | formats "name : text" with Network_GetPlayerName, appends to edit 0x3fe/0x41b via EM_SETSEL/EM_REPLACESEL |
| `0x4061C0` | `NetDlg_ShowPlayerName` | high | WideCharToMultiByte of name at +0x1fd78, SetDlgItemText id 0x3ec |
| `0x406210` | `NetDlg_IncPlayerCount` | medium | increments dword this+0x1fd6c (count compared >1 to enable start button) |
| `0x406220` | `NetDlg_GetPlayerCount` | medium | returns this+0x1fd6c |
| `0x406230` | `NetDlg_DecPlayerCount` | medium | decrements this+0x1fd6c |
| `0x406240` | `NetDlg_ResetPlayerCount` | medium | zeroes this+0x1fd6c |
| `0x406250` | `NetDlg_SetExitFlag` | high | writes this+0x1fd68; getter 0x406260 decides EndDialog in 0x406e40 |
| `0x406260` | `NetDlg_GetExitFlag` | high | returns this+0x1fd68; nonzero makes 0x406e40 EndDialog(1) |
| `0x406270` | `NetDlg_LoadPlayerNameFromRegistry` | high | reads HKCU Software\DMA Design Ltd\GTA2\Network "PlayerName" into wchar +0x1fd78 |
| `0x406320` | `NetDlg_SetPlayerName` | high | copies wstring to +0x1fd78 and writes "PlayerName" registry value |
| `0x4063C0` | `NetDlg_SendChatFromEdit` | medium | GetDlgItemText, converts to wide, sends via session 0x409d00, clears edit, echoes AppendChatLine |
| `0x406450` | `NetDlg_CopySettings` (was `NetDlg_CopyMapInfo`, Seq 27 net pass) | medium | copies 0x48 dwords from this+0x1ff84 into out buffer |
| `0x406470` | `NetDlg_LoadSettingsFromRegistry` | high | Reg_Network_GetDwordOrInit map_index/game_time_limit/game_speed/game_type/police/f_limit |
| `0x40653E` | `NetDlg_CopyMapNameFragment` | high | mid-function tail inside 0x56dbe0: strcpy param into ESI+0x1ff84 |
| `0x406550` | `NetDlg_GetSelectedGmpFile` (was `NetDlg_GetSelectedMapStr0`, Seq 27 net pass) | medium | session+4 array entry stride 0x518 indexed by +0x20088; offset 0 |
| `0x406570` | `NetDlg_GetSelectedStyFile` (was `NetDlg_GetSelectedMapStr1`, Seq 27 net pass) | medium | same entry array, offset 0x104 |
| `0x406590` | `NetDlg_GetSelectedScrFile` (was `NetDlg_GetSelectedMapStr2`, Seq 27 net pass) | medium | same entry array, offset 0x208 |
| `0x4065B0` | `NetDlg_ReportMmpFileOpenError` (was `Network_ReportMmpFileOpenError`) | high | sprintf "Unable to open file: %s in mmpfile: %s" + MessageBox; caller NetDlg_ReadMmpMapFiles |
| `0x406660` | `NetDlg_UpdateStartRejectButtons` | high (Seq 27) | Start 0x3FD enabled iff playerCount == map PlayerCount (or 0); Reject 0x3FC iff playerCount > 1 |
| `0x40667C` | `NetDlg_EnableStartReject_Frag` (was `NetDlg_EnableControls3FDAnd3FCFragment`, Seq 27 net pass) | high | mid-function tail inside 0x56dc04: EnableWindow ctrl 0x3fd/0x3fc by player count >1 |
| `0x4066E0` | `NetDlg_SetCopsCheckBox` (was `NetDlg_SetCheckBox403`, Seq 27 net pass) | medium | SendDlgItemMessage id 0x403 BM_SETCHECK(0xF1) 1 or 0 |
| `0x406B80` | `NetDlg_SetTimeLimitEditText` (was `NetDlg_SetNumericText40e`, Seq 27 net pass) | medium | sprintf "%d" into SetDlgItemText id 0x40e |
| `0x406BC0` | `NetDlg_ScalarDeletingDtor` | high | calls 0x405a40 vtable reset, _free if flag&1 |
| `0x406C92` | `NetDlg_EnableJoinButton_Frag` (was `NetDlg_EnableControlFragment`, Seq 27 net pass) | high | mid-function tail in 0x56dec0: EnableWindow(GetDlgItem(hDlg,id),flag) |
| `0x406E40` | `NetDlg_OnTimer` | high | if exit flag EndDialog(1) and frees locale; else listbox 1000 get sel text, Network refresh 0x40c380, reselect |
| `0x407070` | `NetDlg_InitControls` (was `NetDlg_InitListColumns`, Seq 27 net pass) | high | Adds "Player Name"/"Ping" columns to list controls 0x400/0x41a (LVM_INSERTCOLUMN), then combo init; called by NetDlg_OnInitDialog |
| `0x40720D` | `NetDlg_InitControls_Frag` | medium | Detached tail of NetDlg_InitListColumns: fills map list 0x402 (stride 0x518) and combo 0x40c with netui19/20/22 |
| `0x407362` | `NetDlg_UpdateSettingTexts_Frag` | medium | Detached fragment calling NetDlg_Set{PlayersRequired,ScoreLimit,GameSpeed}Text on dialog state |
| `0x4073D0` | `NetDlg_ApplyRemoteSettings` (was `NetDlg_SetSessionDesc`, Seq 27 net pass) | medium | Copies 0x120-byte game-settings blob into dialog+0x1ff84 |
| `0x407402` | `NetDlg_FindMapByName_Frag` | medium | Detached loop: wcscmp over map table stride 0x518, copies match to +0x1ff84, sets selected index +0x20088 |
| `0x407476` | `NetDlg_UpdateClientSettingTexts_Frag` (was `NetDlg_UpdateGameSpeedText_Frag`, Seq 27 net pass) | medium | Detached fragment: netui10/11/12 text into control 0x41f, then Cops/GameType/TimeLimit texts |
| `0x40748D` | `NetDlg_ShowMissingMapError_Frag` | high | sprintf "### ERROR ### Do Not Have Map %s", posts as chat text then refreshes texts |
| `0x4075C0` | `NetDlg_SetSetting` | high | switch(1..7): map, score limit, game type, speed, police, time limit; saves to registry (Reg_Network_SetDword) and syncs |
| `0x407605` | `NetDlg_SelectMap_Frag` | medium | Detached tail: copies map name, players-required text, Reg "map_index", pushes 0x120 settings blob |
| `0x407C90` | `NetDlg_OnHScroll` | high | WM_HSCROLL handler (0x114): trackbar 0x407 -> NetDlg_SetSetting(5=game speed) |
| `0x407D10` | `NetDlg_Ctor` | high | Sets vtable 0x56e598, zeroes dialog state, GetTickCount; called by FUN_004d0ed0 init |
| `0x407D8B` | `NetDlg_Ctor_Frag` | medium | Detached ctor tail: zero loop, NetDlg_LoadPlayerNameFromRegistry + NetDlg_ReadMmpMapFiles |
| `0x407DB0` | `NetDlg_OnCommand` | high | WM_COMMAND big switch: create/join/start/chat buttons, Network_HostSession, CloseSession, EndDialog |
| `0x408920` | `NetDlg_DialogProc` | high | DLGPROC: WM_INITDIALOG(0x110), WM_COMMAND(0x111), WM_TIMER(0x113), WM_HSCROLL(0x114) |
| `0x408954` | `NetDlg_CommandThunk` | medium | Splits wParam and forwards to NetDlg_OnCommand; callers are detached fragments |
| `0x4089C0` | `NetDlg_Run` | high | Registers 8 network event handlers then DialogBoxParamA(resource 0x67, NetDlg_DialogProc) |
| `0x408A90` | `Network_AddConnectionEntry` | medium | Appends 0x1c-byte entry (GUID, wide name copy, connection blob copy) to list +0x2c, max 8; called from Network_Connect |
| `0x408C40` | `Network_ReleaseDirectPlay` | high | Release (vtbl+8) on COM ptrs +0x5e0 (IDirectPlay3) and +0x5dc (IDirectPlayLobby2), nulls them |
| `0x408C80` | `Network_CreateInterfaces` (was `Network_CreateLobbyInterface`, Seq 27 net pass) | high | CoCreateInstance + DirectPlayLobbyCreateW + QueryInterface into +0x5dc/+0x5e0 |
| `0x408CF0` | `Network_CopyConnectionNames` | medium | Unused: duplicates wide names of connection entries into caller array, returns count |
| `0x408E80` | `Network_AddModemName` (was `Network_AddNameString`, Seq 27 net pass) | medium | Unused: appends wcsdup of string to list +0x30 (max 8) |
| `0x409460` | `Network_AddSessionDesc` | medium | Copies DPSESSIONDESC2 (0x50) + wide name into session table at +0xc0 (max 16), count +0x5c0 |
| `0x409620` | `Network_SetSessionListHandler` (was `Network_SetEventHandler5`, Seq 27 net pass) | high | Stores callback+ctx in slot 5 (+0x84); event 5 = session list updated (dispatched by Network_Update) |
| `0x409650` | `Network_SendTo` | high | IDirectPlay3::Send (vtbl+0x68) from local player to given dpid |
| `0x409680` | `Network_DecodeReceivedMessage` (was `Network_PackMessage`, Seq 27 net pass) | high | Rewrites a received wire message (types 1..9) in place into the 5-byte internal header form; DisplayError "NetworkX.cpp" |
| `0x409890` | `NetPlayerTable_FreeSlot` (was `Network_FreePlayerSlot`, Seq 27 net pass) | high | _free two buffers of 0x2c player slot, zero it, decrement player count |
| `0x4099B0` | `Network_SetPlayerAddedHandler` (was `Network_SetEventHandler2`, Seq 27 net pass) | high | Stores callback+ctx in slot 2 (+0x60); event 2 = player added |
| `0x4099D0` | `Network_AddEnumeratedPlayer` (was `Network_AddPlayerFromEvent`, Seq 27 net pass) | medium | Unused: calls Network_AddPlayerRecord on args, returns success |
| `0x409A30` | `Network_SetGroupId` | high | this+0x754 is the idGroup of DeletePlayerFromGroup/SetGroupData |
| `0x409A40` | `NetPlayerTable_Clear` (was `Network_FreeAllPlayerSlots`, Seq 27 net pass) | high | Loops Network_FreePlayerSlot, frees +0x150 buffer, zeroes block |
| `0x409A90` | `NetPlayerTable_FindByDpid` (was `Network_FindPlayerIndexByDpid`, Seq 27 net pass) | high | Scans 6 slots stride 0x2c comparing +0x20; returns 0xEEEEEEEE if none |
| `0x409AC0` | `Network_SetPlayerRemovedHandler` (was `Network_SetEventHandler3`, Seq 27 net pass) | high | Stores callback+ctx in slot 3 (+0x6c) |
| `0x409AE0` | `Network_SetSessionClosedHandler` (was `Network_SetEventHandler1`, Seq 27 net pass) | high | Stores callback+ctx in slot 1 (+0x54) |
| `0x409B10` | `Network_UpdatePlayerPing` | high | Running average ping per player, dispatches event 6 with name+ping |
| `0x409B90` | `Network_SetPingHandler` (was `Network_SetEventHandler6`, Seq 27 net pass) | high | Stores callback+ctx in slot 6 (+0x90); event 6 = ping update |
| `0x409BC0` | `Network_DeletePlayerFromGroupByName` | coordinator | DeletePlayerFromGroup = IDirectPlay3 vtbl+0x1C (dplay.h order) |
| `0x409C50` | `Network_SeqDelta` | high | Signed byte difference of two sequence counters |
| `0x409C80` | `Network_DeletePlayerFromGroupByIndex` | coordinator | same, by player index |
| `0x409CE0` | `Network_ClearPendingPackets` | high | Zeroes 0x30 pending-packet flags (stride 0x14 at +0x8f4) and count +0xcb4 |
| `0x409D00` | `Network_SendChatMessage` | high | IDirectPlay3::SendChatMessage (vtbl+0xa0) with 0xC-byte DPCHAT |
| `0x409D70` | `Network_SetChatHandler` (was `Network_SetEventHandler7`, Seq 27 net pass) | high | Stores callback+ctx in slot 7 (+0x9c) |
| `0x409DE0` | `Network_SetGroupDataHandler` (was `Network_SetEventHandler8`, Seq 27 net pass) | high | Stores callback+ctx in slot 8 (+0xa8); event 8 = group data (settings) received |
| `0x409E10` | `Network_PublishSettings` | medium | Copies settings blob to +0x86c and calls COM vtbl+0x6c (SetGroupData) with it |
| `0x409E90` | `Network_SetGameStartHandler` (was `Network_SetEventHandler9`, Seq 27 net pass) | high | Stores callback+ctx in slot 9 (+0xb4); event 9 = game start |
| `0x40A0F0` | `Network_QueuePendingPacket` | medium | Finds/inserts out-of-order packet in 0x30-entry table stride 0x14 |
| `0x40A190` | `Network_PopOldestPendingPacket` | medium | Scans pending table for lowest seq via Network_SeqDelta, returns slot |
| `0x40A250` | `Network_ApplyRepeatFrameInput` (was `Network_StoreLastSeqInfo`, Seq 27 net pass) | high (Seq 27) | Resolves the wire-9 FFFFFFFF repeat against g_netLastFrameInput 0x5d3378, else stores the new input |
| `0x40A2A0` | `Network_FreePendingPacketSlot` | high | Clears slot in-use flag, decrements count |
| `0x40A2C0` | `Network_Ctor` | high | Sets vtable 0x56e740, CreateEvent, allocs 0x1800/0x800 buffers, inits tables |
| `0x40A3A0` | `Network_Dtor` | high | Releases DirectPlay via vtbl 0x24/0x20/0x10, frees lists and buffers, CloseHandle |
| `0x40A7F0` | `Network_EncodePacket` | medium | Converts internal packet (types 1..4 / subtypes) into wire bytes 1..9; DisplayError NetworkX.cpp 0x8df |
| `0x40AAA0` | `NetPlayerTable_PromotePlayer` (was `Network_PromotePendingPlayer`, Seq 27 net pass) | medium | Matches pending slot by dpid, Network_AddPlayerRecord, frees slot |
| `0x40AB90` | `Network_SendStartAndLockSession` | high | Sends start packet, sets session flags |
| `0x40AC50` | `Network_BroadcastSyncReady` (was `Network_SendSyncPacket`, Seq 27 net pass) | medium | Encodes type-2 packet and Sends broadcast; used by WaitForAllPlayersSync |
| `0x40ACC0` | `Network_SendFrameDataToPlayer` | medium | Encodes type-3 frame packet with seq, sends to one player; called from game loop |
| `0x40AD70` | `Network_BroadcastFrameData` | medium | Encodes type-3 packet with seq, broadcasts, increments local seq |
| `0x40AF70` | `Network_SendDisconnectNotice` | medium | Broadcasts 1-byte payload 2; called from Network_CloseSession |
| `0x40B000` | `Network_BroadcastPlayerDropped` (was `Network_BroadcastCommand5`, Seq 27 net pass) | high (Seq 27) | Broadcasts wire 6 {1, int playerIndex} "player dropped" (5 = payload length) |
| `0x40B090` | `Network_BroadcastSyncInfo` (was `Network_BroadcastCommand1F`, Seq 27 net pass) | high (Seq 27) | Broadcasts wire 3 NetPacketSyncInfo (0x1F = payload length); used by WaitForAllPlayersSync |
| `0x40B120` | `Network_ScalarDeletingDtor` | high | Calls Network_Dtor, frees this if flag&1 |
| `0x40B140` | `Network_EnumModems` (was `Network_InitDirectPlay`, Seq 27 net pass) | medium | DirectPlayCreate(DPSPGUID_MODEM), QI to IDirectPlay3, lobby EnumAddress collects modem names into list +0x30 (never read); called by Network_Connect |
| `0x40B290` | `Network_SelectConnectionAndEnumSessions` | medium | Finds GUID in list, InitializeConnection (vtbl+0x98), EnumSessions (vtbl+0x34), state=1 |
| `0x40B380` | `Network_SendPingRequest` | high | Sends packet with timeGetTime stamp for RTT; called from Network_Update |
| `0x40B8F0` | `Network_JoinSession` | high | Open session (vtbl+0x60), CreatePlayer, enum players, GetPlayerData, dispatches events 2 and 8 |
| `0x40BEC0` | `Network_ReceiveMessage` | high | IDirectPlay3::Receive (vtbl+0x64) loop; system messages go to Network_HandleSystemMessage |
| `0x40BF80` | `Network_HandleLobbyMessage` (was `Network_HandleReceivedPacket`, Seq 27 net pass) | medium | Dispatches ping/pong (RTT -> Network_UpdatePlayerPing) and start-game (event 9) |
| `0x40C120` | `Network_ReceiveGameMessage` (was `Network_ReceiveFrameData`, Seq 27 net pass) | medium | Waits up to 500ms for next in-order frame packet from player, uses pending table |
| `0x40C380` | `Network_UpdateLobby` | high | Per-state poll: state1 EnumSessions refresh (event 5), state 3/4 pings and packet receive |
| `0x40CF60` | `Camera_BoundsContainPoint` | high | Four Fix16 compares of two stack args against bounds at +0x78..+0x84 |
| `0x40E490` | `Ang16_SnapToCardinal` | low | Clamps *short into 0, 0x168 or 0x438 buckets; used by PedGameObject_StateWalk |
| `0x40ECB0` | `Fix16_SteerAngleToward` | medium | Wraps delta to +-pi, ramps rate toward target with limits, WrapRadians; used by Car_UpdateSystems |
| `0x40EE60` | `TrailerController_ClampAngleDelta` | medium | Same wrap/clamp pattern, returns wrapped angle; sole caller TrailerController_UpdateAlignment |
| `0x40EF80` | `TrailerController_IsAngleNearTarget` | medium | Checks angle within window of target also +-2pi; called by ClampAngleToLimits |
| `0x40F0A0` | `TrailerController_ClampAngleToLimits` | medium | Clamps angle to limit zones around constants 0x5d3910/0x5d4ff0; sole caller UpdateAlignment |
| `0x40F410` | `TrailerController_GetOtherCar` | high | Returns +0xc if arg equals +8 else +8 |
| `0x40F450` | `TrailerController_CreatePhysics` | high | Car_CreatePhysics on cab (+8) and trailer (+0xc) |
| `0x40F470` | `TrailerController_FreePhysics` | high | Car_FreePhysics on cab (+8) and trailer (+0xc) |
| `0x40F5B0` | `Nop_ReturnThis` | medium | Returns its ecx argument; trivial ctor used by CarPhysics_Ctor/SpriteBounds_Ctor |
| `0x40F7B0` | `Sprite_SetLayer` | medium | Setter this+0x28; called by Car_SetSpriteLayer (40 callers) |
| `0x40F7C0` | `CarPhysics_GetCenterPos` | high (Seq 43) | Copies 2 dwords from this+0x38; used only by TrailerController_UpdateAlignment |
| `0x40F7E0` | `CarPhysics_SetCenterPos` | high (Seq 43) | Writes 2 dwords to this+0x38; used by UpdateAlignment |
| `0x40F800` | `CarPhysics_GetZPos` | high (Seq 43) | Reads dword this+0x6c; used by UpdateAlignment |
| `0x40F810` | `CarPhysics_SetZPos` | high (Seq 43) | Writes dword this+0x6c |
| `0x40F820` | `CarPhysics_GetHeading` | high (Seq 43) | Reads short this+0x58 (angle); used by UpdateAlignment and cab-trailer search |
| `0x40F830` | `CarPhysics_SetHeading` | high (Seq 43) | Writes short this+0x58 |
| `0x40FB70` | `TrailerController_ExplodeIfEitherWrecked` | high | If one of cab/trailer is wrecked, set other's hp 32000 and Car_Explode |
| `0x40FD40` | `TrailerController_ComputeHitchPosition` | medium | Vec2 rotate/add of hitch offsets by cab and trailer angles; sole caller CarManager_SpawnArticulated |
| `0x40FE30` | `SoundEvent_SetPosition` | medium | Stores 3 dwords at this+4..0xc; callers are collision-record fillers |
| `0x40FE60` | `SoundClientPool_Release` | medium | Unlinks node then makes it head (next at +0xc); used by Weapon_Release/Player_Dtor |
| `0x40FE80` | `Sprite_IsObjectKind` | low | Returns whether field +0x30 is 1, 4 or 5 |
| `0x40FEE0` | `CollisionResult_SetHitSprite` | medium | Sets this+0=3, +0x20=param |
| `0x40FEF0` | `Object_GetModel` | medium | Returns field +0x18; caller Script_Op_CHECK_OBJ_MODEL |
| `0x40FF00` | `unsure_WorldObject_GetPrefabByte63` | low | Returns byte at (*(this+8))+99 |
| `0x40FF10` | `SoundEvent_SetField24` | low | Writes this+0x24 |
| `0x40FF20` | `SoundEvent_SetFromCollisionResult` | medium | Sets kind 2/3/4/5 from g_CollisionResult.kind/.hitSprite |

### Game code, old iostream, CRT (0x4D0000-0x52FFFF)

| Address | Name | Confidence | Evidence |
|---|---|---|---|
| `0x4D07E0` | `WeaponPool_ScalarDeletingDtor` | high | calls WeaponPool_Dtor then _free if flag&1 |
| `0x4D0800` | `WeaponPool_Destroy` | high | deletes g_WeaponPool via scalar deleting dtor, nulls global |
| `0x4D09B0` | `Keyboard_SetActiveFlag` | medium | writes byte at this+0x75344 of _keyboard; called only from WndProc helper |
| `0x4D09D0` | `WndProc_ForwardKeyboardActive` | medium | WndProc helper: if !isExit set _keyboard flag else FrontEnd_SetKeyboardActive |
| `0x4D0ED0` | `Startup_ConnectMultiplayerFromRegistry` | medium | reads UseProtocol/UseConnection registry blobs, Network_Connect, sets menu gmp/sty/scr paths; called from WinMain (`0x4D11B8` `WinMain2` is now `WinMain_AfterNoppedMutexCheck_Frag`, a false split) |
| `0x4D48D0` | `ios_Ctor` | high | old MSVC iostream ios init: vptr, bp=0, state=4(badbit), fill=' ' at +0x2c, width at +0x30 |
| `0x4D4940` | `ios_Dtor` | high | ios dtor: deletes bp if delbuf(+0x1c), clears bp, state=badbit |
| `0x4D4969` | `ios_Init` | high | ios::init(streambuf*): frees old delbuf bp, sets bp, state=badbit if null |
| `0x4D4998` | `ios_Assign` | medium | ios::operator=: copies tie, flags, precision, fill, width, state from other |
| `0x4D4A49` | `ios_ScalarDeletingDtor` | high | calls ios_Dtor, _free if flag&1 |
| `0x4D4AC8` | `ofstream_Ctor` | medium | iostream ofstream() ctor: vbase ios, allocs 0x38 filebuf, ios::init |
| `0x4D4B4E` | `ofstream_CtorOpen` | high | ofstream(const char*,mode,prot): ctor plus filebuf::open(mode OR ios::out), sets failbit |
| `0x4D4C03` | `ofstream_CtorFd` | high | ofstream(int fd): allocs filebuf(fd) |
| `0x4D4C8C` | `ofstream_CtorFdBuf` | high | ofstream(int fd,char*,int): allocs filebuf(fd,buf,len) |
| `0x4D4D1B` | `ofstream_DtorVbaseFixup` | unsure | sets ios-relative vptrs only; called from FUN_0044dbf0 dtor path |
| `0x4D4D2E` | `ofstream_Setbuf` | medium | ofstream::setbuf-like: if filebuf fd==-1 call vfn[2]; else set failbit |
| `0x4D4D97` | `ofstream_Open` | high | ofstream::open(name,mode,prot): filebuf::open(mode OR out) else failbit; caller do_miss_logging |
| `0x4D4DD2` | `ofstream_Close` | high | calls filebuf::close; clears state or sets failbit |
| `0x4D4E2D` | `streambuf_Sputc` | high | inline sputc: store at pptr++ if pptr<epptr else virtual overflow vfn+0x1c |
| `0x4D4E49` | `ostream_Put` | high | ostream::put(char): opfx, sputc/overflow, writepad if width, osfx |
| `0x4D4ECA` | `ostream_Osfx` | high | ostream::osfx: width=0, flush if unitbuf(0x20), fflush stdout/stderr if stdio flag(0x40) |
| `0x4D4F46` | `ostream_Flush` | high | ostream::flush: calls streambuf sync vfn+4, sets failbit on -1 |
| `0x4D4F6C` | `ostream_CtorBase` | medium | ostream() base ctor: ios vptr, bp stays null state; vbase flag |
| `0x4D4FA2` | `ostream_CtorStreambuf` | high | ostream(streambuf*): vbase ios ctor + ios::init(sb) |
| `0x4D5007` | `ostream_CtorCopyBuf` | medium | ostream(ostream&): ios::init with other's streambuf |
| `0x4D5084` | `ostream_withassign_AssignStreambuf` | medium | operator=(streambuf*): frees bp, ios assign from default temp, init(sb) |
| `0x4D510A` | `ostream_withassign_Ctor` | high | vptr 0x5786b8 variant, ostream base ctor |
| `0x4D5165` | `ostream_withassign_CtorStreambuf` | high | vptr 0x5786b8 variant of ostream(streambuf*) |
| `0x4D51C3` | `ostream_withassign_DtorVbaseFixup` | unsure | resets vptrs to base; no callers found |
| `0x4D51E0` | `ostream_Writepad` | high | ostream::writepad(left,right): fill chars by width per adjustfield flags |
| `0x4D532E` | `ostream_Opfx` | high | ostream::opfx: fail if state!=0, flush tie ostream |
| `0x4D5357` | `ostream_OperatorShiftString` | high | ostream::operator<<(const char*): opfx, writepad, osfx; used by DebugLog_WriteLine |
| `0x4D539F` | `ostream_Dtor` | medium | ostream dtor: reset vptr, destroy embedded ios at +8 |
| `0x4D5465` | `filebuf_Ctor` | high | filebuf(): streambuf ctor, fd=-1, vptr 0x5786dc |
| `0x4D547F` | `filebuf_CtorFd` | high | filebuf(int fd): streambuf ctor, fd at +0x30 |
| `0x4D549E` | `filebuf_Close` | high | filebuf::close: sync (vfn+4) then _close(fd), fd=-1 |
| `0x4D54D5` | `filebuf_Setbuf` | high | filebuf::setbuf(char*,int): only if fd==-1 or unbuffered; calls setb |
| `0x4D5524` | `filebuf_CtorFdBuf` | high | filebuf(int fd,char*,int): ctor + setbuf |
| `0x4D556C` | `filebuf_Sync` | high | filebuf::sync: _write pending put area, _lseek back unread get area (CRLF count) |
| `0x4D564B` | `filebuf_Dtor` | high | filebuf dtor: close if opened by filebuf else sync, then streambuf dtor |
| `0x4D5690` | `filebuf_Overflow` | high | filebuf::overflow(int): allocate, sync, reset put area, write/sputc char |
| `0x4D5701` | `filebuf_Underflow` | high | filebuf::underflow: _read into buffer or single char |
| `0x4D57A2` | `filebuf_Seekoff` | medium | filebuf::seekoff: SEEK_CUR/END mapping, sync then _lseek (dir arg in EAX) |
| `0x4D57DE` | `filebuf_ScalarDeletingDtor` | high | calls filebuf_Dtor, _free if flag&1 |
| `0x4D57FA` | `filebuf_Attach` | high | filebuf::attach(fd): sets fd if -1, allocs 0x200 buffer |
| `0x4D584E` | `filebuf_Open` | high | filebuf::open: maps ios open modes to _O_ flags, _sopen, 0x200 buffer, ate seek |
| `0x4D59E3` | `streambuf_Ctor` | high | streambuf(): zeroes base/get/put pointers, unbuffered, vptr 0x57870c |
| `0x4D5AE4` | `streambuf_Xsgetn` | high | streambuf::xsgetn: memcpy loop calling underflow (vfn+0x20) |
| `0x4D5B7C` | `streambuf_Sync` | medium | default sync: 0 if get/put areas empty else -1; used by dtor |
| `0x4D5B93` | `streambuf_Allocate` | high | streambuf::allocate: if no buffer and buffered, call doallocate vfn+0x28 |
| `0x4D5BB1` | `streambuf_Setb` | high | streambuf::setb(base,ebuf,del): free old if allocated, set base/ebuf/alloc |
| `0x4D5BF9` | `streambuf_Sputbackc` | high | inline sputbackc: --gptr store else pbackfail vfn+0x24 |
| `0x4D5C1E` | `streambuf_Dtor` | high | streambuf dtor: sync, free base buffer if allocated |
| `0x4D5C6B` | `streambuf_Pbackfail` | medium | streambuf::pbackfail: seekoff(-1,cur) and shift buffer |
| `0x4D5CC5` | `streambuf_ScalarDeletingDtor` | high | calls streambuf_Dtor, _free if flag&1 |
| `0x4D5D66` | `__cfltcvt_init` | high | fills _cfltcvt_tab with __cfltcvt, __fassign, __forcdecpt (CRT cfltcvt.c) |
| `0x4D5DAE` | `__fpmath` | high | __cfltcvt_init + __ms_p5_mp_test_fdiv + setdefaultprecision (VC7 fpinit.c) |
| `0x4D5EE3` | `CatchGuardHandler` | medium | EH frame.cpp: calls ___InternalCxxFrameHandler with FuncInfo from frame, UnwindNestedFrames |
| `0x4D5FE7` | `__IsExceptionObjectToBeDestroyed` | medium | walks global list for exception object pointer (EH ehstate) |
| `0x4D603B` | `CallCatchBlock_CallSettingFrameGuarded` | high | Builds FS:[0] SEH frame (handler 4d5ebf) around __CallSettingFrame@12; only caller CallCatchBlock |
| `0x4D608C` | `_CallSETranslator` | medium | Calls __pSETranslator (DAT_0067503c) with SEH frame; only caller FindHandlerForForeignException |
| `0x4D682D` | `__scprintf` | high | FILE{cnt=INT_MAX,flag=0x42,base=0} then __output over varargs: counts chars without storing |
| `0x4D696F` | `Unwind@004d696f` | high | Unwind funclet of eh_vector_constructor_iterator: __ArrayUnwind |
| `0x4D6A3F` | `Unwind@004d6a3f` | high | Unwind funclet of eh_vector_destructor_iterator: __ArrayUnwind |
| `0x4D6AC7` | `_wcscpy` | high | Copies 16-bit units until 0, returns dest |
| `0x4D6B26` | `__chdir` | high | SetCurrentDirectoryA then sets =X: env var via SetEnvironmentVariableA, __dosmaperr |
| `0x4D6DCA` | `__scwprintf` | high | Same as __scprintf but wide __woutput (4dd5ec) |
| `0x4D721A` | `__crtExitProcess` | high | GetModuleHandle mscoree.dll, CorExitProcess then ExitProcess |
| `0x4D7280` | `__cinit` | high | Runs fp init ptr, xi_a..xi_z initterm, _atexit, xc table initterm |
| `0x4D72E5` | `_doexit` | high | Runs onexit table, pre-terminators, terminators; TerminateProcess if re-entered; args (code,quick,retcaller) |
| `0x4D73C9` | `__cexit` | high | doexit(0,0,1) |
| `0x4D73D8` | `__c_exit` | high | doexit(0,1,1) |
| `0x4D73E7` | `_xtoa` | high | Digit loop with '0'/'W' (lowercase hex) and reverse; backs itoa/ltoa/ultoa |
| `0x4D7476` | `__ultoa` | medium | Calls xtoa unsigned (neg=0), returns buf |
| `0x4D7490` | `_x64toa` | high | 64-bit xtoa using __aulldvrm |
| `0x4D74FD` | `__i64toa` | high | x64toa with neg flag when radix==10 and value<0 |
| `0x4D752E` | `__ui64toa` | high | x64toa with neg=0 |
| `0x4D7549` | `__findclose` | high | FindClose; errno=EINVAL on failure |
| `0x4D75CC` | `__findfirst` | high | FindFirstFileA, fills _finddata_t via timet_from_ft, ENOENT/EINVAL mapping |
| `0x4D76AC` | `__findnext` | high | FindNextFileA, same fill as findfirst |
| `0x4D7787` | `__itow` | high | _itoa into local buffer then widen |
| `0x4D77C8` | `__ltow` | high | _ltoa into buffer then widen |
| `0x4D7809` | `__ultow` | medium | _ultoa into buffer then widen |
| `0x4D784A` | `__i64tow` | high | _i64toa into buffer then widen (0x50 buffer) |
| `0x4D788E` | `__ui64tow` | high | _ui64toa into buffer then widen |
| `0x4D7D0E` | `__stat` | high | FindFirstFileA, __dtoxmode, IsRootUNCName, GetDriveTypeA, fills struct stat |
| `0x4D7FE6` | `_vsprintf` | high | FILE over buffer cnt=INT_MAX flag 0x42, __output, then NUL via _flsbuf |
| `0x4D803D` | `__vscprintf` | high | Like __scprintf but takes va_list |
| `0x4D806D` | `_vswprintf` | high | Wide output into buffer, two NUL bytes appended |
| `0x4D80DB` | `__vscwprintf` | high | Wide count-only with va_list |
| `0x4D8326` | `__validdrive` | high | GetDriveTypeA on "X:\\"; 0 for unknown/no-root |
| `0x4D835D` | `__getdcwd` | high | GetCurrentDirectory/GetFullPathName for "X:."; caller __getcwd; malloc if buf NULL |
| `0x4D8500` | `WinMainCRTStartup_Body` | high | crt0 WinMainCRTStartup body; patch stub redoes push 0x60/push 0x5787B8 (coordinator) |
| `0x4D86D2` | `type_info_Dtor` | high | Sets type_info vftable, frees m_data |
| `0x4D86E7` | `type_info_ScalarDeletingDtor` | high | dtor then free if flag&1 |
| `0x4D8770` | `__EH_prolog` | high | push -1; push eax; link FS:[0]: C++ EH prolog (coordinator) |
| `0x4D89EB` | `__close_lk` | high | CloseHandle on osfhnd, __free_osfhnd, clears flag; no lock (callers _fclose, _sopen) |
| `0x4D8B2A` | `__ioinit` | high | malloc 0x100 lowio array, GetStartupInfo lpReserved2 inherit, GetStdHandle for 0..2 |
| `0x4D8CF8` | `__write_lk` | high | WriteFile with LF->CRLF 1KB buffer; __lseeki64 for append |
| `0x4D8EAC` | `__read_lk` | high | ReadFile with CRLF translation and ctrl-Z handling |
| `0x4D908C` | `__sopen` | high | CreateFileA with access/share/creation mapping, GetFileType |
| `0x4D9373` | `__setmode_lk` | high | Toggles 0x80 text flag in lowio; returns old mode 0x4000/0x8000 |
| `0x4DA8D0` | `_shift` | high | memmove(p+n,p,strlen+1) |
| `0x4DA8ED` | `_cftoe` | high | Builds d.ddde+000 exponent form |
| `0x4DAA07` | `_cftof` | high | Fixed-point formatting with shift of digits |
| `0x4DAB07` | `_cftog` | high | Chooses e/f format by exponent, %g |
| `0x4DAC02` | `__setdefaultprecision` | medium | _controlfp(0x10000,0x30000): sets precision control to 53-bit; called from fp init |
| `0x4DAD92` | `Unwind@004dad92` | medium | Decrements __ProcessingThrow; unwind funclet of __FrameUnwindToState |
| `0x4DAE0D` | `_AdjustPointer` | medium | this + PMD displacement with vbtable lookup; caller BuildCatchObject |
| `0x4DB0DF` | `Unwind@004db0df` | medium | CallCatchBlock cleanup: FindAndUnlinkFrame, restores ProcessingThrow state, __DestructExceptionObject |
| `0x4DB2B9` | `___CxxExceptionFilter` | medium | Checks 0x19930520 EH exception code, TypeMatch, BuildCatchObject |
| `0x4DB416` | `FindHandlerForForeignException` | high | Non-C++ exception: SE translator, then CatchIt for catch(...) handlers |
| `0x4DB4D8` | `FindHandler` | high | Walks try blocks, matches handlers with TypeMatch and calls CatchIt; 0x19930520 magic |
| `0x4DB751` | `_terminate` | high | Calls terminate handler then raise(SIGABRT) and exit(3) |
| `0x4DBC47` | `__output` | high | printf formatter state machine over FILE; callers sprintf and _vsprintf wrappers |
| `0x4DC638` | `_tolower` | high | locale-aware tolower; callers __stricmp/__strnicmp; A-Z +0x20, LCMapString |
| `0x4DC9B6` | `__input` | high | scanf engine; sscanf caller; %d/%s/%[ parsing, _ungetc, _inc |
| `0x4DD5EC` | `__woutput` | high | wide printf engine; swprintf caller; same structure as __output; write_char/_multi_char/_string |
| `0x4DDDBC` | `CRT_RunInitTable_Empty` | high | loops over empty function-pointer table (start==end) from startup; _initterm-like |
| `0x4DE0F8` | `__mbstowcs_lk` | medium | MultiByteToWideChar(cp,9,-1); ANSI copy fallback when locale C |
| `0x4DE277` | `_asctime_FormatBuf` | medium | formats 'Sun Mon dd hh:mm:ss yyyy' into static buffer (asctime body) |
| `0x4DE558` | `__resetstkoflw` | high | VirtualQuery/GetSystemInfo/VirtualProtect PAGE_GUARD on stack page |
| `0x4DEA01` | `__mbsicmp` | high | mbcs case-insensitive compare via _mbctype, LCMapString, falls back to _stricmp |
| `0x4DEC3C` | `_getdrive` | high | CRT `_getdrive`: GetCurrentDirectoryA, returns toupper(letter)-0x40 (1 = A:) if 'X:', else 0; caller `__stat` |
| `0x4DEC95` | `__chdrive` | high | SetCurrentDirectoryA("X:"), errno=EACCES, doserrno=ERROR_INVALID_DRIVE for bad drive |
| `0x4DEDDD` | `__NMSG_WRITE` | high | callers __FF_MSGBANNER/__amsg_exit; builds runtime-error text, WriteFile or MessageBox |
| `0x4DF15F` | `__wincmdln` | high | skips program name (quoted or not) in lpCmdLine, uses _ismbblead |
| `0x4DF28F` | `_parse_cmdline` | high | tokenises command line honouring quotes/backslashes into argv; called by __setargv |
| `0x4DF3FB` | `__setargv` | high | GetModuleFileNameA, _parse_cmdline twice, malloc argv; sets __argc/__argv |
| `0x4DF772` | `__alloc_osfhnd` | high | finds free ioinfo slot in __pioinfo table, mallocs 0x100 block (0x20 entries) |
| `0x4DFA78` | `__chsize` | high | _lseek/SetEndOfFile, pads with zeros to extend; osfile flag check |
| `0x4DFBF3` | `_isctype` | high | ctype lookup via _pctype, else ___crtGetStringTypeA; callers __hextodec etc. |
| `0x4DFD7D` | `__FillZeroMan` | high | zeroes 3 dwords; between __CopyMan and __IsZeroMan (coordinator) |
| `0x4E001D` | `__atodbl` | high | __strgtold12 + __ld12tod (coordinator) |
| `0x4E0060` | `__atoldbl` | high | __strgtold12 + __ld12told (coordinator) |
| `0x4E00A4` | `__atoflt` | high | __strgtold12 + __ld12tof (coordinator) |
| `0x4E00E7` | `__fptostr` | high | digit copy with round-half-up on >'4' (coordinator) |
| `0x4E0218` | `__fltout` | high | ___dtold then $I10_OUTPUT into static STRFLT; used by float formatting |
| `0x4E02A0` | `_memset` | high | word-aligned fill loop; 8 callers |
| `0x4E0300` | `CRT_AmsgExit_FloatNotLoaded` | high | single call __amsg_exit(2); invalid-format/parameter abort from scanf/printf |
| `0x4E04F9` | `__CxxUnhandledExceptionFilter` | medium | checks 0xE06D7363 + 0x19930520 C++ EH magic, else calls registered filter after _ValidateExecute |
| `0x4E0816` | `_setSBUpLow` | high | GetCPInfo + LCMapString/GetStringType fills _mbctype upper/lower tables |
| `0x4E09A8` | `__setmbcp` | high | mbctype.c: GetACP/OEMCP, GetCPInfo lead bytes, _CPtoLCID, _setSBCS fallback |
| `0x4E0BC2` | `___security_init_cookie` | high | xors FILETIME/PID/TID/tick/QPC into __security_cookie (0x595880), default 0xBB40E64E |
| `0x4E0C18` | `___report_gsfailure` | high | caller __security_check_cookie; 'Buffer overrun detected!' MessageBox then _exit |
| `0x4E12E7` | `_write_wchar` | medium | wide write_char: wctomb to putc/_flsbuf or _flswbuf; caller _write_char |
| `0x4E17CF` | `__isindst` | high | DST check using _cvtdate begin/end; callers localtime, __loctotime_t |
| `0x4E1A6A` | `__ansicp` | high | GetLocaleInfoA(LOCALE_IDEFAULTANSICODEPAGE 0x1004) then atol |
| `0x4E1AB3` | `__convertcp` | high | WideChar/MultiByte conversion between code pages via calloc buffer |
| `0x4E1C8A` | `_toupper` | high | locale toupper; a-z -0x20 else LCMapString; caller drive-letter code |
| `0x4E1EA9` | `__ismbbtype` | high | (_mbctype[c]&mask) |
| `0x4E1F6E` | `__ismbblead` | high | _ismbbtype(c,0,_M1=4); caller __wincmdln |
| `0x4E2091` | `___mtold12` | high | string digits to 12-byte long double mantissa using ___add_12/___shl_12; exp base 0x404e |
| `0x4E2175` | `___strgtold12` | high | string to _LDBL12 parser; callers __atodbl/__atoflt/__atoldbl |
| `0x4E2602` | `___STRINGTOLD` | medium | ___strgtold12 then __ld12told; no callers (strtold-style wrapper) |
| `0x4E2654` | `__I10_OUTPUT` | high | long double to decimal digits (STRFLT); called by __fltout; uses ___add_12/shl/shr |
| `0x4E2D30` | `__ld12mul` | medium | 12-byte long double multiply using ___addl/___shl_12/___shr_12 |
| `0x4E2F68` | `___multtenpow12` | medium | multiplies by table power of ten (tenpow at 0x595bb0) via __ld12mul |
| `0x4E3033` | `__wtomb_environ` | high | WideCharToMultiByte of wide environ to narrow; caller _getenv/__putenv_lk |
| `0x4E30BA` | `___crtCompareStringA` | high | CompareStringW/A with MultiByteToWideChar; caller __mbsnbicoll |
| `0x4E34F2` | `__putenv_lk` | high | SetEnvironmentVariableA, _findenv, realloc _environ table, free/copy_environ |
| `0x4E36D2` | `__mbschr` | high | SWAR byte scan strchr, with _mbcs branch (_DAT_0067536c); caller __putenv_lk |
| `0x51C730` | `StaticInit_DebugFlagsDefaults` | medium | static-init ctor (data ref 0x584498): sets g_* debug flags false |
| `0x52E0A0` | `StaticInit_RandomDebugLog` | medium | static-init ctor (data ref 0x586d48): ctor of global g_RandomDebugLog at 0x663764, calls Crt_Srand |

### 11.44 patch code (0x56Dxxx)

| Address | Name | Confidence | Evidence |
|---|---|---|---|
| `0x56DBE0` | `Patch1144_NetLobby_MapSlotAddrHook` | medium | 11.44 hook: ECX=[blk+4]+idx*8+0x410 then jumps back to 0x40653e; from lobby settings load 0x406470 |
| `0x56DBF2` | `Patch1144_NetLobby_LoadSlotValueHook` | medium | EAX=[[this+4]+idx*8-4] then jmp 0x407362; hooks 0x40720d |
| `0x56DC04` | `Patch1144_NetLobby_LoadSlotValueX3Hook` | medium | idx*3 indexing of heap block, EDX=[blk+ECX*8-4], jmp 0x40667c; hooks 0x406660 |
| `0x56DC16` | `Patch1144_NetLobby_SlotTableBase30CHook` | medium | EAX=[this+4]+0x30c then jmp 0x40720d; hooks 0x407070 |
| `0x56DC28` | `Patch1144_NetLobby_SlotTableBase410Hook` | medium | EDI=[this+4]+0x410, jmp 0x407402; hooks 0x4073d0 |
| `0x56DC3A` | `Patch1144_NetLobby_SlotEntryAddr30CHook` | medium | EDX=blk+ECX*8+0x30c, jmp 0x407476; hooks 0x407402 |
| `0x56DC4C` | `Patch1144_NetLobby_SlotEntryAddr414Hook` | medium | EAX=blk+ECX*8+0x410, jmp 0x407605; hooks 0x4075c0 (case 1 map_index) |
| `0x56DCAB` | `Patch1144_NetDlg_AllocMapTable` (was `Patch1144_NetSession_AllocSlotBlock`, Seq 27 net pass) | high | HeapAlloc(heap@0x676cd4,flags 9,0x518) into [this+4], then back to ctor tail 0x407d8b |
| `0x56DCDA` | `Patch1144_EntryStub` | high | GetModuleHandle KERNEL32/GetProcAddress GetProcessHeap -> 0x676cd4, then jumps to original entry body 0x4d8500 |
| `0x56DD18` | `Patch1144_Mmp_StrToLowerInPlace` | high | lowercases A-Z in a C string in place; called from NetDlg_ReadMmpMapFiles |
| `0x56DD67` | `Patch1144_OnKeyDown_LaunchManagerHook` | medium | in Player_OnKeyDown: if [0x673e2c] flag set go on, else FrontEnd_LaunchGta2Manager |
| `0x56DE0C` | `Patch1144_NetDlg_SetMapNameNAText` | medium | sprintf 'N/A: %s' + SetDlgItemTextA(dlg item 0x41e); hooks 0x407476 call |
| `0x56DE95` | `Patch1144_NetDlg_AutoCreateHook` (was `Patch1144_NetDlg_ChatFlagResetHook`, Seq 27 net pass) | medium | if byte 0x676ff0==1 clears it and posts message 0x3ea; hooks lobby dlg proc 0x3f158c call |
| `0x56DEC0` | `Patch1144_NetDlg_StoreSessionsAvailableHook` (was `Patch1144_NetDlg_StoreChatFlagHook`, Seq 27 net pass) | medium | stores byte 0x676ff2 from stack, pushes 0x3e9, jmp 0x406c92 |
| `0x56DED4` | `Patch1144_NetDlg_AutoJoinHook` (was `Patch1144_NetDlg_ChatFocusHook`, Seq 27 net pass) | medium | if (0x676ff1 & 0x676ff2) clears 0x676ff1 and posts 0x3e9 (0xf000000); hooks dlg proc 0x408920 |

### Names added by Seq 47 (slice 2: 0x449000-0x4759FF)

Evidence is in each function's Ghidra plate comment. `unsure_` = honest guess, `_Frag` = tail Ghidra split off a function patched by 11.44 (see section 4).

| Address | Name | Confidence | Evidence |
|---|---|---|---|
| `0x449CE0` / `0x449D10` | `unsure_FrontEndItemList_Ctor` / `_Dtor` | unsure | 600 x 0x6C array at +2; InitFrontend / FrontEnd_Dtor |
| `0x449EF0` / `0x44A020` | `CrimeEventQueue_Dtor` / `thunk_CrimeEventQueue_Dtor` | high | 10 x 0x14 at +4, called from CrimeEventQueue_ScalarDeletingDtor |
| `0x449F50` | `CrimeStats_Dtor` | unsure | bare RET called from Player_Dtor |
| `0x44DBF0` / `0x4504D0` | `ofstream_Dtor` / `DebugLog_Dtor` | medium | ios_Dtor on vbase +8; DebugLog_WriteCoopHeader + ofstream_Close + free |
| `0x45A700` | `Game_OnSetFocus` | medium | WndProc message 7 only |
| `0x45AFD0` | `HudDebugLabel_SetColour` | medium | sets +0xB0=8, +0xB4=colour on Hud_DebugLabel_Show result |
| `0x45B0B0` | `PlayerScore_GetReverseCount` | high | printed as "reverse_count" by ShowCounters |
| `0x45F970`, `0x45FB10`, `0x45FBA0` | `Keyboard_IsReplayPlayback`, `_FlushReplayLog`, `_ResetReplayBufferOnMarker` | unsure | replay buffer (40000 x 12) around Keyboard +0x38 mode |
| `0x45F269`, `0x45FAFF`, `0x45FB59` | `Debug_WriteSessionInfoDump_Frag`, `Keyboard_RecordInputEvent_Tail`, `Keyboard_FlushReplayLog_Epilogue` | high | epilogues reached by JMP from 11.44 patch stubs |
| `0x461760` | `CmdLine_CountArguments` | high | whitespace token count, caller CmdLine_ParseArguments (was parseArguments) |
| `0x4619D0` | `Game_RequestForcedLogicStep` | medium | sets DAT_0066274C read by drawAndLimitFrames |
| `0x461DA0` | `Network_GetPlayerTableCount` (was a second `Network_GetPlayerCount`) | medium | +0x758 of g_NetworkSession (= players.count), tested >1 |
| `0x4620A0` | `Game_ShutdownOnce` | high | guarded by DAT_00662785, calls DeinitGame + SoundMgr_Shutdown |
| `0x4620E0` | `Multiplayer_RemoveLeftPlayer` (was `Multiplayer_ShowPlayerLeftMessage`, Seq 27 net pass) | high | GXT "comms1" to kill feed |
| `0x462140`, `0x462440`, `0x4624E0`, `0x4626D0` | `Multiplayer_ExchangeLockstepInputs`, `_BroadcastLocalInput`, `_ApplyBufferedInputs`, `Game_UpdateLockstepInputFrame` | medium | Main.cpp lockstep input exchange, caller drawAndLimitFrames |
| `0x462820` / `0x462850` | `Game_FatalExitWithAlert` / `Multiplayer_VerifySyncInfo` (was `Network_VerifyPlayerSyncInfo`) | high | "Player %s: ... is different" strings |
| `0x472620` | `RandomDebugLog_Ctor` | high | Crt_Srand(1), StaticInit_RandomDebugLog |
