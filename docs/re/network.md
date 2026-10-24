# Multiplayer in gta2.exe 11.44: DirectPlay, lobby, wire protocol, lockstep

This page is the reference for GTA2 multiplayer. It covers how the game decides to run a network
game, the `Network` object over DirectPlay, the `NetDlg` lobby dialog, the bytes on the wire, the
input lockstep, and the gameplay code that branches on multiplayer. It also has a merged bug list
(§8) and a list of what a DirectPlay replacement on our host has to provide (§9).

It merges six shard reports of the Seq 27 networking pass (N1 startup, N2 `Network` object,
N3 lobby, N4 wire protocol, N5 lockstep, N6 game logic). The evidence is Ghidra decompile and
disassembly of `gta-2-recovered` (`gta2.segments.fixed.exe`), plus N1's own capstone disassembly
of `gta2.ebin` while the Ghidra MCP was down. DirectPlay offsets, flags, `DPSYS_*` codes and GUIDs
were checked against Wine's `dplay.h`/`dplobby.h`.

Every address is a VA in vanilla `gta2.exe` 11.44 (base `0x3F0000`). Names are the ones the shards
left in Ghidra. `re/` was **not** regenerated after the pass, so `re/functions.csv` still shows
many old names (`Network_PackMessage`, `parseArguments`, …); run `re/tools/export.sh`.

Confidence: **high** = read in the decompile or disassembly; **medium** = strong inference;
**low**/**guess** = hypothesis. Shard tags (`N2 B3`, `N5 H1`) point to the original report rows.

## Contents

1. The chain end to end
2. Startup: command line, registry, `.mmp` files, settings hand-off, exit (N1)
3. The `Network` object and DirectPlay (N2)
4. The lobby dialog `NetDlg` (N3)
5. Wire protocol (N4)
6. Lockstep (N5)
7. Multiplayer game logic (N6)
8. Bug catalogue
9. What our DirectPlay replacement must provide
10. Open questions and leftovers

## 1. The chain end to end

1. **Command line.** `WinMain` `0x4D1170` → `CmdLine_ParseArguments` `0x461810`: `-N` sets
   `isMultiplayer` `0x673E2C`; the 11.44 switches `-C`/`-J` also set auto-create/auto-join
   (`g_NetDlgAutoCreate` `0x676FF0`, `g_NetDlgAutoJoin` `0x676FF1`).
2. **Registry → connection.** `Startup_ConnectMultiplayerFromRegistry` `0x4D0ED0` reads
   `HKCU\SOFTWARE\DMA Design Ltd\GTA2\Network` `UseProtocol`/`UseConnection` and calls
   `Network_Connect` `0x40BD20` on `g_NetworkSession` `0x674268`. That creates IDirectPlay3 +
   IDirectPlayLobby2 (`Network_CreateInterfaces` `0x408C80`) and, without registry values,
   enumerates connections.
3. **Session list.** `Network_SelectConnectionAndEnumSessions` `0x40B290`: `InitializeConnection`,
   `EnumSessions`, state 1.
4. **Lobby.** `NetDlg_Ctor` `0x407D10` (on Startup's stack, reads `*.mmp`) → `NetDlg_Run` `0x4089C0`
   → `DialogBoxParamA(0x67)`. A 10 ms timer drives `Network_UpdateLobby` `0x40C380`.
5. **Session.** Create → `Network_HostSession` `0x40A5B0` (state 3). Join →
   `Network_JoinSession` `0x40B8F0` (state 4). Membership arrives as DPSYS messages
   (`Network_HandleSystemMessage` `0x40B520`). Settings travel as group data
   (`Network_PublishSettings` `0x409E10`).
6. **Start.** Host presses Start → `Network_SendStartAndLockSession` `0x40AB90` (wire 8 +
   `DPSESSION_JOINDISABLED`, state 2). Clients get wire 8 → event 9 → `NetDlg_OnGameStart` `0x407800`
   → `EndDialog(1)`. Startup copies the settings to `g_NetGameSettings` `0x673E30` and the Menu.
7. **Game init.** `InitGame` `0x461DE0` MP branch: `Game_Ctor(playerCount, localIndex)`, exit-game
   callback, lockstep globals zeroed, `startGame` (`Game_ApplyMultiplayerSpeedAndPolice` `0x45A540`).
8. **Start barrier.** `Network_WaitForAllPlayersSync` `0x40BFA0`: exchange `NetPacketSyncInfo`
   (wire 3) and "ready" (wire 4) with everyone, 20 s timeout.
9. **Lockstep loop.** `drawAndLimitFrames` `0x462A30` every 33 ms: `Game_RunLogicStep` +
   `Game_UpdateLockstepInputFrame` `0x4626D0` → broadcast own input (wire 1/9), `draw()`,
   `Multiplayer_ExchangeLockstepInputs` `0x462140` (wait, resend, drop), apply all inputs.
10. **MP game logic.** Kills → `Menu_RecordMultiplayerKill` `0x45EC70`; score limit in
    `PlayerScore_Update` `0x4B7770`; time limit `MultiplayerTimeLimit_Update` `0x462530`; Tag in
    `MultiplayerTag_*`; respawn `Player_RespawnPed` `0x4A6050`.
11. **Results / exit.** `quitGame(game, delay, reason)` → `Game_GetQuitReason` `0x4D09C0`. Reason 1
    (network loss) → `DestroyWindow` → process exit. Other reasons → `FrontEnd_GotoPage(7)` results
    → QUIT → same exit. **One process = one network game;** there is no way back to the lobby.

## 2. Startup (N1)

### 2.1 Flow

- **`WinMain` `0x4D1170`.** It calls `CoInitialize(0)` at `0x4D1182`. 11.44 NOPped
  `0x4D118C-0x4D11B7`, which was the `CreateMutexA` single-instance check ("GTA2 will now run
  multiple times"). So `0x4D11C2` stores the **CoInitialize HRESULT** into `mutex` `0x673D1C`, and
  the exit paths call `ReleaseMutex`/`CloseHandle` on 0 or 1. `WinMain_AfterNoppedMutexCheck_Frag`
  `0x4D11B8` (was `WinMain2`) is a false function start at the end of that NOP sled.
- **`CmdLine_ParseArguments` `0x461810`** (stdcall, `ret 4`). `_strupr` uppercases `lpCmdLine` in
  place, so the buffer must be writable. Tokens are split on space/tab/CR/LF
  (`CmdLine_CountArguments` `0x461760`); a switch starts with `-` or `/`.

  | Switch | Effect |
  |---|---|
  | `N` | `isMultiplayer` = 1 (original code `0x461860`) |
  | `C` | 11.44 hook `0x56DE4C`: `isMultiplayer` = 1, `g_NetDlgAutoCreate` = 1 → the lobby presses Create |
  | `J` | `isMultiplayer` = 1, `g_NetDlgAutoJoin` = 1 → the lobby presses Join once a session shows up |
  | `Q` | `g_replayKeyboardLive` `0x5EADA3` = 1 |
  | `R [name]` | `g_playReplay` `0x5EADAA` = 1; stub `0x3F14D8` copies an optional (quoted) name to `0x595F85`, making the path `test\<NAME>` |

- **`Startup_ConnectMultiplayerFromRegistry` `0x4D0ED0`** (`bool __stdcall (HINSTANCE)`).
  1. It always calls `Menu_ResetMultiplayerPlayerStats` (`mpWinner` = 6, kill matrix, frags,
     points and names cleared), then returns 1 at once in single player.
  2. `Reg_OpenNetworkKey` `0x4B58E0`: `RegCreateKeyExA(HKCU, "SOFTWARE\DMA Design Ltd\GTA2\Network",
     KEY_ALL_ACCESS)`. On failure it calls `DisplayError(0x2B, "registry.cpp", 0x38E)`, which does not
     return.
  3. Registry blobs use the pair DWORD `<name>s` = size, BINARY `<name>d` = data
     (`Reg_GetBlobSize` `0x4B5E20`, format `"%ss"`; `Reg_ReadSizedBlob` `0x4B5D80`, `"%sd"`).
  4. **Registry path:** if `UseProtocols` == 16, it reads `UseProtocold` (the service-provider
     GUID), then `UseConnections`/`UseConnectiond` (a DirectPlay address of N bytes), then calls
     `Network_Connect(&g_NetworkSession, &guid, &{blob, N})`.
  5. **No-registry path:** `Network_Connect(…, NULL, NULL)` uses the default GUID at `0x5769F4`,
     `{685BC400-9D2C-11CF-A9CD-00AA006886E3}` = `DPSPGUID_IPX` (N2 checked it in `dplay.h`), and
     enumerates connections.
  6. Any failure returns 0, and **the process exits silently**.
  7. `NetDlg_Ctor` on the stack (0x20220 bytes, `__chkstk`), then
     `Network_SelectConnectionAndEnumSessions` (its result is ignored), then `NetDlg_Run`.
  8. On `IDOK`:
     - `NetDlg_CopySettings` `0x406450` copies 0x120 bytes `NetDlg+0x1FF84` → `g_NetGameSettings`
       `0x673E30`.
     - `Menu_SetGmpPath/Sty/Scr` get `wsprintfA("data\%s", …)` of the **local** map entry
       `maps[settings.mapIndex]`.
     - `Menu_SetMultiplayerGameSettings` `0x45E6C0(gameType, scoreLimit, localIndex =
       Network_GetLocalPlayerIndex, playerCount = Network_GetPlayerCount 0x409F90, timeLimit)`
       writes Menu `+0x43B/+0x43C/+0x440/+0x441/+0x444`.
     - `NetDlg_Dtor`, return 1. Cancel returns 0.
- **Back in `WinMain`** (`0x4D12B9`). On 0 it releases `mutex` and returns. Otherwise: window,
  `InitVideo` (`RenderSettings_LoadFrameRateLighting` forces `max_frame_rate` = `min_frame_rate` = 1
  in MP), `InitRendererDevice`, `InitInputAndAudio`. MP sets `isExit` = 0, so the frontend is skipped.
- **`InitGame` `0x461DE0` MP branch.** `MultiplayerTag_Reset`,
  `Cheats_DisableDebugFlagsForMultiplayer` `0x461AF0`, `Game_Ctor(game, Network_GetPlayerCount,
  Network_GetLocalPlayerIndex)`, `Network_SetExitGameCallback(ExitGameCallback 0x461A50, game)`,
  `Menu_SetPlayerName` per active player, lockstep globals zeroed (§6), time limit clamped to 60.
  Then `LoadGMP_and_STY_Files`. The 11.44 `LoadGXT` hook `Patch1144_LoadGXT_MmpOverrides`
  `0x56DF08` opens `data\<g_NetGameSettings.mmpFileName>` and applies its `GCIFile`/`GXTFile`.
  Finally `startGame` skips the CD check and calls `Game_ApplyMultiplayerSpeedAndPolice` `0x45A540`.
- **Start barrier** `Network_WaitForAllPlayersSync` runs right after `InitGame`. If it fails,
  `WinMain` does `CoUninitialize(); return 0` (NET-24).
- **Main loop.** `PeekMessage` pump. `drawAndLimitFrames` is skipped while `g_windowMinimizedState`
  `0x673F50` == 2 (WM_SIZE minimized) or `relatedTod3d` (fullscreen focus lost), **in MP too**
  (NET-23).
- **End of the game.** When `drawAndLimitFrames` returns true, `WinMain` reads
  `Game_GetQuitReason` `0x4D09C0` (Game+0x2C, set by `quitGame` → `Game_ScheduleLevelExit` `0x45A480`,
  which keeps the earliest pending exit):

  | Reason | Set by | Result |
  |---|---|---|
  | 1 | `ExitGameCallback` (network event 4, always 1) | `DestroyWindow` → WM_DESTROY `0x4D0C39` → `Network_CloseSession`, `Game_ShutdownOnce`, `ShutdownVideo`, `PostQuitMessage`: **process ends, no results** |
  | 2 | local quit `0x4627E2`/`0x4A7075`, lockstep `g_mpQuitRequested` | `DeinitGame`, `isExit` = 1, `FrontEnd_GotoPage(7)` (results) |
  | 5 | frag/points/time limit `0x4625B7`, `0x4B7D15` (delay 2) | same as 2 |

  Results page 7 only offers QUIT (`FrontEnd_Tick` 1 → `DestroyWindow` → the same exit path).

### 2.2 Where every setting ends up

| Lobby value (registry name, default) | `NetGameSettings` | Reaches the game via |
|---|---|---|
| map (`map_index`, 0) | `+0x000` mmpFileName, `+0x104` mapIndex | Menu gmp/sty/scr from the local map table; mmp name → GCI/GXT override |
| `game_speed` (1) | `+0x108` | `Game_ApplyMultiplayerSpeedAndPolice` → Game+0x34 = 50/33/20, **never read** (NET-51) |
| `f_limit` (3) / `s_limit` (10000) | `+0x10C` | Menu `fragLimit` (score limit for frags and points) |
| `game_type` (1) | `+0x110` | Menu `mpGameType` (byte): 1 frags, 2 points, 3 tag |
| none (SetSetting case 4, not saved) | `+0x114` | no reader found (`unsure_randomSeed`, see §10) |
| `police` (0) | `+0x118` | `g_skipPolice` = (police == 0) in `startGame` |
| `game_time_limit` (1) | `+0x11C` | Menu `mpTimeLimitMinutes` → InitGame, clamped to 60 |
| player count / local index | none (DirectPlay slots) | Menu at lobby close, `Game_Ctor` args at InitGame (read twice, NET-16) |
| `PlayerName` | none | NetDlg → DirectPlay player name → `Player_Ctor` `0x4A83C0` → `Network_GetPlayerName` |

Defaults: the column above is the `Reg_Network_GetDwordOrInit` default (N1). `NetDlg_Ctor` first
writes its own defaults (game type 1, score limit 1, map 0, police 0, time limit 0, N3), which the
registry load then overrides.

### 2.3 Functions

| VA | Name | Role | Conf. |
|---|---|---|---|
| `0x4D1170` | `WinMain` | CoInitialize, cmdline, Startup, InitGame, barrier, main loop, exit | high |
| `0x4D11B8` | `WinMain_AfterNoppedMutexCheck_Frag` (was `WinMain2`) | false split after the 11.44 NOP sled | high |
| `0x461810` | `CmdLine_ParseArguments` (was `parseArguments`) | `-N/-C/-J/-Q/-R` | high |
| `0x4D0ED0` | `Startup_ConnectMultiplayerFromRegistry` | registry → connect → lobby → settings | high |
| `0x4B58E0` / `0x4B5E20` / `0x4B5D80` | `Reg_OpenNetworkKey` / `Reg_GetBlobSize` / `Reg_ReadSizedBlob` | registry blobs (thiscall with an unused `this`) | high |
| `0x45E6C0` | `Menu_SetMultiplayerGameSettings` | `(Menu*, byte gameType, int scoreLimit, byte localPlayerIndex, byte playerCount, int timeLimitMinutes)` | high |
| `0x4D09C0` | `Game_GetQuitReason` (was `relToQuitGame`) | returns Game+0x2C | high |
| `0x45A540` | `Game_ApplyMultiplayerSpeedAndPolice` (was `Game_ApplyMultiplayerPoliceSetting`) | Game+0x34 and `g_skipPolice` | high |
| `0x461A50` | `ExitGameCallback` | logs the reason, always `quitGame(game, 0, 1)` | high |

### 2.4 Globals

| VA | Name | Type | Notes |
|---|---|---|---|
| `0x673E2C` | `isMultiplayer` | dword | |
| `0x673E30` | `g_NetGameSettings` | `NetGameSettings` (0x120) | fields at `0x673F34` mapIndex, `0x673F38` speed, `0x673F3C` score, `0x673F40` type, `0x673F44` +0x114, `0x673F48` police, `0x673F4C` time |
| `0x673F50` | `g_windowMinimizedState` | byte | 2 = minimized |
| `0x676FF0` / `0x676FF1` / `0x676FF2` | `g_NetDlgAutoCreate` / `g_NetDlgAutoJoin` / `g_NetDlgSessionsAvailable` | byte | `-C` / `-J`; the third gates auto-join |
| `0x673D1C` | `mutex` | HANDLE slot | holds the CoInitialize HRESULT in 11.44 |
| `0x595F80` | (unnamed) `"test\replay.rep"` | char[123] | `-R` target, up to `replay_number` `0x595FFB` |

## 3. The `Network` object and DirectPlay (N2)

### 3.1 Interfaces (correction)

The game uses **IDirectPlay3 (wide)** and **IDirectPlayLobby2 (wide)**, not IDirectPlay4:
`CoCreateInstance(CLSID_DirectPlay {D1EB6D20-…}, IID 0x576A44 = {133EFE40-32DC-11D0-9CFB-00A0C90A43CB}
= IID_IDirectPlay3)` and `DirectPlayLobbyCreateW` + `QI(IID 0x576984 =
{0194C220-A303-11D0-9C4F-00A0C905425E} = IID_IDirectPlayLobby2)`. No method above `+0xA0` is called,
so the IDirectPlay3 vtable is enough. (N1, N4 and N5 wrote "IDirectPlay4" from the old docs; the
offsets they use are the same, because IDirectPlay4 only appends methods.)

### 3.2 Flow

1. **Construction.** Static init `0x56C775` → `Network_Ctor` `0x40A2C0`: vtable `0x56E740` (one entry,
   `Network_ScalarDeletingDtor`), tables zeroed, send/receive buffers 2 × 0x1800, six unused 0x800
   buffers, `hReceiveEvent` = auto-reset event (never waited on), state 5. `Network_Dtor` `0x40A3A0`
   runs from atexit `0x56DB75`.
2. **Connect** `Network_Connect` `0x40BD20`: `spGuid` from the registry or `DPSPGUID_IPX`;
   `Network_CreateInterfaces` `0x408C80`.
   - Registry path: one `NetConnectionEntry {spGuid, L"dummy prot", UseConnection blob}`, no
     enumeration.
   - Default path: `EnumConnections(appGuid 0x56E720 {561E8920-5C70-11D2-AD00-00A0C9B61398},
     Network_EnumConnectionsCallback 0x408B90, this, DPCONNECTION_DIRECTPLAY)` fills up to 8 entries.
     Then `Network_EnumModems` `0x40B140` (`DirectPlayCreate(DPSPGUID_MODEM)` → `GetPlayerAddress(0)`
     → lobby `EnumAddress`). Nothing reads the modem names.
3. **Select + enumerate** `0x40B290`: finds `spGuid` in `connections[]`, `InitializeConnection(conn, 0)`,
   `EnumSessions(sd{appGuid}, 0, Network_EnumSessionsCallback 0x40A7D0, this,
   DPENUMSESSIONS_AVAILABLE|ASYNC = 0x11)`, state 1.
4. **Lobby tick** `Network_UpdateLobby` `0x40C380` (from `NetDlg_OnTimer`, every 10 ms):
   - state 1: every 100 ms free the session names, zero `sessions[]`, `EnumSessions(…, 1000 ms,
     0x11)`, then event 5 with a copy of the names;
   - states 3/4: every 1000 ms `Network_SendPingRequest`; **one** `Network_ReceiveMessage` per tick,
     handed to `Network_HandleLobbyMessage` `0x40BF80` (ping/pong, start).
5. **Host** `Network_HostSession` `0x40A5B0` (was `Network_StartSession`):
   - `sessionDesc` = `{dwFlags 0x8000 OPTIMIZELATENCY, appGuid, dwMaxPlayers 6, name}`, then
     `Open(sd, DPOPEN_CREATE)`;
   - `CreatePlayer(&localDpid, {name}, hReceiveEvent, playerData, 0)`; the local player goes to
     `pendingPlayers`;
   - `CreateGroup(&groupId, {L"GBH Group"}, groupData, 0)`, `AddPlayerToGroup(groupId, localDpid)`;
   - isHost = 1, state 3.
6. **Join** `Network_JoinSession` `0x40B8F0`:
   - copy `sessions[i]`, then `Open(sd, DPOPEN_JOIN|DPOPEN_RETURNSTATUS = 0x81)`; anything but DP_OK
     fails;
   - `CreatePlayer`, `EnumGroups` (the callback `0x40AB40` stores the group dpid) and
     `EnumGroupPlayers(groupId)` (the same callback adds each player straight into `players`);
   - `GetPlayerData` per player (BUFFERTOOSMALL → allocate + retry), event 2 per player;
   - `AddPlayerToGroup(self)`, self → `pendingPlayers`, `GetGroupData` → `players.groupData` and a
     copy for the caller;
   - isHost = 0, state 4, event 8.
7. **Membership** (`Network_HandleSystemMessage` `0x40B520`, lobby states). The slot order in
   `players` is the arrival order of ADDPLAYERTOGROUP, and that slot index becomes the game player
   index.

   | Message | Action |
   |---|---|
   | `DPSYS_CREATEPLAYERORGROUP` (3), a player | → `pendingPlayers` |
   | `DPSYS_ADDPLAYERTOGROUP` (7) to our group | `NetPlayerTable_PromotePlayer` into `players`; `localPlayerIndex` fixed when it is us; event 2 |
   | `DPSYS_DELETEPLAYERFROMGROUP` (0x21), self | event 1 (NetDlg closes the session) |
   | `DPSYS_DELETEPLAYERFROMGROUP` (0x21), another player | event 3; free the slot and **compact** the later slots down; `localPlayerIndex--` if needed |
   | `DPSYS_SETPLAYERORGROUPDATA` (0x102) on our group | → `players.groupData`, event 8 |
   | `DPSYS_CHAT` (0x109) | event 7 |

   `DPSYS_SESSIONLOST` (0x31), `DPSYS_HOST` (0x101) and `DPSYS_DESTROYPLAYERORGROUP` (5) are ignored
   in the lobby.
8. **Start** (host, `0x40AB90`): wire 8 to the group, `sessionDesc.dwFlags |= DPSESSION_JOINDISABLED`,
   `SetSessionDesc`, state 2. Clients switch to state 2 when wire 8 arrives (`0x40B458`).
9. **In game** (state 2): `Network_HandleSystemMessage` raises event 4 with a reason and sets
   `sessionEnded`. Another player's 0x21 still takes the **lobby path** (event 3 + compaction,
   NET-12 and NET-30).

   | Message | Event 4 reason |
   |---|---|
   | `DPSYS_SESSIONLOST` | 0 |
   | `DESTROYPLAYERORGROUP` of our group | 1 |
   | `DESTROYPLAYERORGROUP` of the local player, or `DELETEPLAYERFROMGROUP` of the local player | 2 |
10. **Teardown** `Network_CloseSession` `0x40BC50` (from NetDlg and WM_DESTROY `0x4D0C42`):
    - a client with more than 1 player broadcasts the disconnect notice (wire 5);
    - the host calls `DeletePlayerFromGroup` for its players, then `DestroyGroup`;
    - `DestroyPlayer(local)`, `Close`, both tables cleared, state 1.

    `Network_Dtor` at exit does `DestroyPlayer`, `DestroyGroup` if host, `Close`, frees, `CloseHandle`,
    and `Release` on both interfaces. The double Close is harmless.

### 3.3 `NET_STATE` (`Network+0x44`)

| Value | Meaning | Set by |
|---|---|---|
| 1 | enumerating sessions (browser) | `SelectConnectionAndEnumSessions`, `CloseSession` |
| 2 | in game | host `SendStartAndLockSession`; client on wire 8 |
| 3 | hosting, lobby | `HostSession` |
| 4 | joined, lobby | `JoinSession` |
| 5 | idle | ctor |

The old sketch in `crt-and-network.md` ("2 = idle/hosting, 3/4 = in game") was wrong. N2 and N5
agree on this table independently.

### 3.4 Events (`Network.eventHandlers[id]`, `Network+0x48 + 12·id`, `{callback, context, eventId}`)

| id | Setter | Handler | Fired from | Argument |
|---|---|---|---|---|
| 1 session closed | `Network_SetSessionClosedHandler` `0x409AE0` | `NetDlg_OnSessionClosed` `0x407030` | 0x21 for self (lobby) | none |
| 2 player added | `Network_SetPlayerAddedHandler` `0x4099B0` | `NetDlg_OnPlayerAdded` `0x406CC0` | ADDPLAYERTOGROUP, JoinSession | `(ctx, slot->name, &slot->playerData)` |
| 3 player removed | `Network_SetPlayerRemovedHandler` `0x409AC0` | `NetDlg_OnPlayerDeleted` `0x406F20` | 0x21 for another player, **also in game** | `wchar16* name` |
| 4 exit game | `Network_SetExitGameCallback` `0x409F70` | `ExitGameCallback` `0x461A50` (ctx `Game*`) | state 2 system messages | `int reason` 0/1/2 |
| 5 session list | `Network_SetSessionListHandler` `0x409620` | `NetDlg_OnSessionListUpdated` `0x406BE0` | `UpdateLobby` state 1 | `NetEvtSessionList*` (0x44: `wchar16* names[16]; uint count` +0x40) |
| 6 ping | `Network_SetPingHandler` `0x409B90` | `NetDlg_OnPlayerPingUpdate` `0x405B50` | `Network_UpdatePlayerPing` | `NetEvtPing*` (0x20C: `wchar16 playerName[260]; uint avgPingMs` +0x208) |
| 7 chat | `Network_SetChatHandler` `0x409D70` | `NetDlg_OnChatReceived` `0x405CA0` | DPSYS_CHAT | `NetEvtChat*` (0x120: `wchar16 text[128]; wchar16 senderName[16]` +0x100) |
| 8 group data | `Network_SetGroupDataHandler` `0x409DE0` | `NetDlg_OnSettingsReceived` `0x408900` | 0x102, end of JoinSession | `NetDataRef* groupData` (`Network+0x86C`) |
| 9 game start | `Network_SetGameStartHandler` `0x409E90` | `NetDlg_OnGameStart` `0x407800` | wire 8 | none |

`Network_DispatchEvent` `0x4098E0` accepts ids 1..10 and NULL-checks every callback (verified), so
an unregistered event is simply dropped. `NetDlg_Run` registers 1-3 and 5-9 and **never unregisters
them** (NET-12). The three event argument structs are typed in Ghidra under `/net` (Seq 27 P1):
`NetEvtSessionList` (sender `0x40C54D..0x40C586`, reader `0x406BE0`), `NetEvtPing` (`0x409B65` /
`0x409B74` / `0x409B80`, reader `0x405BA7`), `NetEvtChat` (`0x40B711..0x40B722`, reader `0x405CA0`;
neither string is terminated when full, NET-04). Whether `Network_UpdateLobby` caps `count` at 16
before filling `names[16]` was not checked (hypothesis: the enum callback caps at 16).

### 3.5 Struct `Network` (0xCB8)

| Off | Type | Name | Notes |
|---|---|---|---|
| 0x000 | void* | vtable | `0x56E740` |
| 0x004 | GUID | spGuid | |
| 0x02C | NetConnectionEntry* | connections | `operator_new(0xE0)` = 8 × 0x1C |
| 0x030 | wchar16** | modemNames | dead data |
| 0x034 / 0x038 | uint | connectionCount / modemCount | |
| 0x03C / 0x040 | int | connectionsReady / modemsEnumerated | |
| 0x044 | NET_STATE | state | §3.3 |
| 0x048 | NetEventHandler[10] | eventHandlers | 12 bytes each, slot 0 unused |
| 0x0C0 | DPSESSIONDESC2[16] | sessions | rebuilt every 100 ms in state 1 |
| 0x5C0 | uint | sessionCount | |
| 0x5C4 / 0x5C8 / 0x5CC | int | inSession / isHost / unsure_hostLocalIndex | 0x5C4 and 0x5CC write-only |
| 0x5D0 | int | localPlayerIndex | = game local player index |
| 0x5D4 | uint | localDpid | |
| 0x5D8 | HANDLE | hReceiveEvent | passed to CreatePlayer, never waited |
| 0x5DC | IDirectPlayLobby2* | lobby | |
| 0x5E0 | IDirectPlay3* | directPlay | |
| 0x5E4 | NetPlayerTable | pendingPlayers | created, not yet in the group |
| 0x754 | NetPlayerTable | players | the group; `+0x758` count, `+0x75C` frameSeq, `+0x764` slots |
| 0x8C4 | void*[6] | unused_buffers | 6 × 0x800, never used |
| 0x8DC / 0x8E0 | byte* | sendBuffer / recvBuffer | 0x1800 each |
| 0x8E4 | uint | lastPollTime | ping / enum timer |
| 0x8EC | byte | sessionEnded | set with event 4; breaks the receive loops |
| 0x8F0 | uint | lastFrameWaitMs | time spent in the last `ReceiveGameMessage` |
| 0x8F4 | NetPendingPacket[48] | pendingPackets | §5.5 |
| 0xCB4 | int | pendingPacketCount | |

Sub-structs (category `/net`):

- **`NetPlayerTable`** (0x170):

  | Off | Field |
  |---|---|
  | 0x00 | `groupId` |
  | 0x04 | `count` |
  | 0x08 | `u8 frameSeq[6]` + 2 pad |
  | 0x10 | `NetPlayerSlot slots[6]` |
  | 0x118 | `NetDataRef groupData` (absolute `0x86C` for `players`) |
  | 0x120 | `DPSESSIONDESC2 sessionDesc` (absolute `0x874`, `dwFlags` at `0x878`) |

  `frameSeq[i]` holds the next seq expected from a remote slot, and the next seq to send for the
  local slot.
- **`NetPlayerSlot`** (0x2C):

  | Off | Field |
  |---|---|
  | 0x00 | `inUse` |
  | 0x04 | `pingCount` |
  | 0x08 | `avgPingMs` |
  | 0x0C | `pingSumMs` |
  | 0x10 | `dpid` |
  | 0x14 | `unused_nameSize` |
  | 0x18 | `unused_nameFlags` |
  | 0x1C | `wchar16* name` |
  | 0x20 | `unused_longName` |
  | 0x24 | `NetDataRef playerData` |

  Some functions (`NetPlayerTable_FindByDpid`, `UpdatePlayerPing`) take `&groupId` as the base and
  add +0x20 for the dpid: that is the same field seen from 0x10 lower.
- `NetConnectionEntry` 0x1C {GUID, wide name, address blob}; `DPSESSIONDESC2` 0x50; `DPNAME` 0x10;
  `NetEventHandler` {callback, context, eventId}.

### 3.6 Functions

| VA | Name (was) | Role | Conf. |
|---|---|---|---|
| `0x40A2C0` / `0x40A3A0` / `0x40B120` | `Network_Ctor` / `_Dtor` / `_ScalarDeletingDtor` | | high |
| `0x40BD20` | `Network_Connect` | GUID, connection list, interfaces | high |
| `0x408C80` | `Network_CreateInterfaces` (`Network_CreateLobbyInterface`) | CoCreate IDirectPlay3 + Lobby2 | high |
| `0x408C40` | `Network_ReleaseDirectPlay` | Release both | high |
| `0x408A90` | `Network_AddConnectionEntry` | append, max 8 | high |
| `0x408B90` | `Network_EnumConnectionsCallback` (new function) | EnumConnections cb | high |
| `0x40B140` | `Network_EnumModems` (`Network_InitDirectPlay`) | modem probe, result unused | high |
| `0x40A500` | `Network_EnumModemAddressCallback` (new) | lobby EnumAddress cb | high |
| `0x40B290` | `Network_SelectConnectionAndEnumSessions` | InitializeConnection + EnumSessions | high |
| `0x40A7D0` | `Network_EnumSessionsCallback` (new) | → `Network_AddSessionDesc` `0x409460` (max 16) | high |
| `0x40C380` | `Network_UpdateLobby` | per-state lobby poll | high |
| `0x40A5B0` | `Network_HostSession` (`Network_StartSession`) | Open CREATE, player, group | high |
| `0x40B8F0` | `Network_JoinSession` | Open JOIN, enum group, data | high |
| `0x40AB40` | `Network_EnumGroupMembersCallback` (new) | EnumGroups + EnumGroupPlayers cb | high |
| `0x40B520` | `Network_HandleSystemMessage` | DPSYS dispatcher (`RET 0x10`) | high |
| `0x40BEC0` | `Network_ReceiveMessage` | `bool (Network*, byte**, uint*, uint* idTo, uint* idFrom)`; loops over system messages | high |
| `0x409650` | `Network_SendTo` | `Send` +0x68 | high |
| `0x40BC50` | `Network_CloseSession` | teardown, returns 0xEEEEEEEE | high |
| `0x409360` | `NetPlayerTable_AddPlayer` (`Network_AddPlayerRecord`) | slot or 0xEEEEEEEE | high |
| `0x40AAA0` | `NetPlayerTable_PromotePlayer` (`Network_PromotePendingPlayer`) | pending → players | high |
| `0x409890` | `NetPlayerTable_FreeSlot` (`Network_FreePlayerSlot`) | no compaction | high |
| `0x409A40` | `NetPlayerTable_Clear` (`Network_FreeAllPlayerSlots`) | | high |
| `0x409A90` | `NetPlayerTable_FindByDpid` (`Network_FindPlayerIndexByDpid`) | | high |
| `0x4099D0` | `Network_AddEnumeratedPlayer` (`Network_AddPlayerFromEvent`) | called by `0x40AB40` | high |
| `0x409BC0` / `0x409C80` | `Network_DeletePlayerFromGroupByName` / `ByIndex` | kick; ByIndex called by the lockstep | high |
| `0x409D00` | `Network_SendChatMessage` | `SendChatMessage` +0xA0 | high |
| `0x409DA0` | `Network_GetPlayerName` | index 7 = local | high |
| `0x409C40` | `Network_GetLocalPlayerIndex` | +0x5D0 | high |
| `0x409F90` | `Network_GetPlayerCount` | counts `inUse` slots | high |
| `0x461DA0` | `Network_GetPlayerTableCount` (was a second `Network_GetPlayerCount`) | returns +0x758 = `players.count`; one caller `0x462446` | medium |
| `0x4098E0` | `Network_DispatchEvent` | | high |
| `0x409A30` | `Network_SetGroupId` | | high |
| dead | `Network_CopyConnectionNames` `0x408CF0`, `Network_GetConnectionKind` `0x408D70` (0 IPX, 1 TCP, 2 modem, 3 serial, 5 other), `Network_CopyModemNames` `0x408E10`, `Network_AddModemName` `0x408E80`, `Network_CreateTcpIpAddress` `0x408EE0`, `Network_CreateModemAddress` `0x409030`, `Network_CreateSerialAddress` `0x409210`, `Network_IsHost` `0x409F20`, `Network_GetConnectionGuid` `0x409FE0`, `Network_CopyConnectionAddress` `0x40A070` | address builders and getters with no callers | high |

## 4. The lobby dialog `NetDlg` (N3)

### 4.1 Flow

1. **Construction.** `NetDlg_Ctor` `0x407D10` runs on Startup's stack: vtable `0x56E598`, page 0,
   previous page 3, defaults (gameType 1, scoreLimit 1, the rest 0), `settings.+0x114 = GetTickCount()`.
   **`settings.gameSpeed` is not initialised** (no store to `+0x2008C`): it is stack garbage until
   `NetDlg_LoadSettingsFromRegistry` `0x406470` runs in WM_INITDIALOG (NET-75). The 11.44 tail
   `Patch1144_NetDlg_AllocMapTable` `0x56DCAB` `HeapAlloc`s `maps`. Then `NetDlg_Ctor_Frag`
   `0x407D8B` runs `NetDlg_LoadPlayerNameFromRegistry` `0x406270` (ANSI `PlayerName` → wide) and
   `NetDlg_ReadMmpMapFiles` `0x407930` (`*.mmp` → `NetDlgMapEntry[]`; `HeapReAlloc` to
   `(mapCount+1)*0x518` per good map, so one spare slot is always there for the next file; bubble
   sort by description at the end). The table is never freed (NET-74).
2. **`NetDlg_Run` `0x4089C0`.** Registers the 8 handlers with context = dialog, then
   `DialogBoxParamA(hInst, 0x67, NULL, NetDlg_DialogProc)`. It returns 1 only for `EndDialog(1)`.
   After that Startup reads only `NetDlg_CopySettings` (settings → `g_NetGameSettings` `0x673E30`)
   and `maps[settings.mapIndex].gmpFile/styFile/scrFile` through `NetDlg_GetSelected*File`
   `0x406550/70/90`; then `NetDlg_Dtor` `0x405A40`, which only rewrites the vtable.
3. **`NetDlg_DialogProc` `0x408920`.**
   - `WM_INITDIALOG`: `Patch1144_NetDlg_SetIconHook` `0x3F158C`, then `NetDlg_OnInitDialog` `0x408840`.
     That loads the lobby GXT into `g_NetDialogLocaleSettings`, does `SetWindowLong(DWL_USER)`,
     `SetTimer(id 10, 10 ms)` → `g_NetDlgTimerId` `0x5D31DC`, and `NetDlg_CreateControls` `0x4086A0`
     (90 controls from `g_NetDlgControlTable` `0x58F518`; the two chat edits are subclassed with
     `NetDlg_ChatEditSubclassProc` `0x407870`). Then `NetDlg_InitControls` `0x407070` and
     `ShowPage(0)`. Last, `Patch1144_NetDlg_AutoCreateHook` `0x56DE95` handles `-C`.
   - `WM_COMMAND` → `NetDlg_OnCommand` `0x407DB0`.
   - `WM_TIMER` → `Patch1144_NetDlg_AutoJoinHook` `0x56DED4` (`-J`) → `NetDlg_OnTimer` `0x406E40`. If
     the exit flag is set it calls `EndDialog(1)`; else `Network_UpdateLobby`, and it keeps the list
     selection by text.
   - `WM_HSCROLL` → `NetDlg_OnHScroll` `0x407C90` (speed trackbar).
4. **Page 0, the browser.** Event 5 refills listbox 1000; Join is enabled with at least 1 session.
   - **Create** (`0x3EA`): session `"%s's Game"`, `Network_HostSession(name, {&settings, 0x120})`,
     page 1.
   - **Join** (`0x3E9`): `Network_JoinSession(LB_GETITEMDATA, name, &tmp, &blob)`. Events 2 and 8 fire
     inside it while the page is still 0, so event 8 is dropped there. The `0x3E9` path then applies
     `blob` with `NetDlg_ApplyRemoteSettings` `0x4073D0`. The listbox **double-click path does not**
     (NET-38). Then page 2.
   - **Cancel** (2): free GXT, KillTimer, `EndDialog(0)`.
5. **Page 1, the host.**
   - Event 2 (also for the host itself) → list `0x400`, `playerCount++`,
     `NetDlg_UpdateStartRejectButtons` `0x406660`: Start `0x3FD` is enabled iff `playerCount` equals
     the map's `PlayerCount`, or that is 0; Reject `0x3FC` iff `playerCount > 1`.
   - Every settings change → `NetDlg_SetSetting` `0x4075C0` (registry + `Network_PublishSettings`, on
     every keystroke of the two number edits).
   - Chat goes through DirectPlay `SendChatMessage` to the group plus a local echo.
   - Reject kicks by row text (`Network_DeletePlayerFromGroupByName`, NET-44).
   - **Start:** `Network_UpdateLobby`, `Sleep(100)`, name → registry, `Network_SendStartAndLockSession`,
     `EndDialog(1)`.
6. **Page 2, the client.**
   - Event 8 → `NetDlg_OnSettingsReceived` `0x408900` → `ApplyRemoteSettings`: copy the blob, look the
     map up by `mmpName`, refresh the labels. A missing map shows `"N/A: %s"` and broadcasts the chat
     line `"### ERROR ### Do Not Have Map %s"` (NET-11).
   - Event 1 → `NetDlg_OnSessionClosed` → `Network_CloseSession`, page 0.
   - Event 9 → exit flag → `EndDialog(1)` at the next 10 ms tick.

`NetDlg_SetSetting` jump table (`0x4077D8`): 1 map `0x4075DF`, 2 score `0x40763C`, 3 type `0x407673`,
4 `+0x114` `0x4076E4` (no caller), 5 speed `0x4076F6`, 6 police `0x4076CC`, 7 time `0x40778D`.

### 4.2 Controls (`g_NetDlgControlTable` `0x58F518`, `NetDlgControlDef[3][30]`, captions from `e.gxt`)

| Page | Id | Class | Meaning |
|---|---|---|---|
| 0 | 1000 (`0x3E8`) | LISTBOX | sessions (item data = `sessions[]` index) |
| 0 | `0x3E9` / `0x3EA` | BUTTON | netui01 "&Join" (default, starts disabled) / netui02 "&Create" |
| all | 2 | BUTTON | netui03 "Cancel" |
| 0 | `0x3EB` / `0x3EC` | STATIC / EDIT | "Name" / player name |
| 1 | `0x400` | SysListView32 | players (Player Name, Ping) |
| 1 | `0x3FE` / `0x401` / `0x3FF` | EDIT / EDIT / BUTTON | chat log / chat input / "Send" |
| 1 | `0x3FC` / `0x3FD` | BUTTON | "Reject" / "&Start" (start disabled) |
| 1 | `0x402` | COMBOBOX | map (item data = map index) |
| 1 | `0x409` | STATIC | netui13 "Players Required: %d" |
| 1 | `0x407` / `0x408` | trackbar / STATIC | game speed / netui10-12 |
| 1 | `0x40C` | COMBOBOX | game type netui19/20/22 (Frag/Points/Tag) |
| 1 | `0x423` / `0x40B` | EDIT (ES_NUMBER) / STATIC | score limit / netui17 "Frags To Win" or netui18 |
| 1 | `0x40E` / `0x40D` | EDIT (ES_NUMBER) / STATIC | time limit / netui21 |
| 1 | `0x403` / `0x404` | checkbox / STATIC | cops / netui14 |
| 2 | `0x41A`, `0x41B`, `0x41D`, `0x41C` | list, log, input, Send | client copies of the above |
| 2 | `0x41E`, `0x421`, `0x422`, `0x420`, `0x41F`, `0x424` | STATIC | map, type, limit, cops, speed, time labels |

### 4.3 Structs

**`NetDlg`** (0x20220, the stack gap in Startup, probed by `__chkstk`; never on the heap). Rebuilt in
Ghidra by Seq 27 P1 with no undefined bytes. **In 11.44 only 0x538 of the 0x20220 bytes are live.**
Vanilla kept `NetDlgMapEntry maps[100]` inline at `+0x4..+0x1FCE4` (4 + 100·0x518; 100 is the 11.x
changelog's "Removed 100 MMP file limit"); 11.44 moved the table to the heap and turned +0x4 into
the pointer. The vanilla this-relative offsets survive in the hooks with base `maps-4`
(`0x56DC50 LEA EBX,[EBX+ECX*8-4]`, then `[EBX+0x518]` at `0x407617` = `maps[idx].playerCount`).
Two scans found no access to the dead range: every displacement ≥ 0x100 in all `NetDlg_*` /
`Patch1144_Net*` / `*Mmp*` / Startup functions, and a program-wide scan for base+displacement
`0x1F000..0x1FD63` (non-ESP): 0 hits.

| Off | Name (was) | Type | Meaning | Evidence VA |
|---|---|---|---|---|
| 0x0 | vtable | void* | `0x56E598`, slot 0 `NetDlg_ScalarDeletingDtor` `0x406BC0` | `0x407D16`, `0x405A40` |
| 0x4 | maps | NetDlgMapEntry* | 11.44 heap table: `HeapAlloc(0x676CD4, 9, 0x518)`, grown by `HeapReAlloc`; never freed | `0x56DCBE`, `0x407B1A`, `0x406550` |
| 0x8 | dead_vanillaMapTable (`_gap`) | byte[0x1FCDC] | rest of the vanilla `maps[100]`; no access in 11.44 | scans above |
| 0x1FCE4 | unsure_dead_vanillaTail (gap) | byte[0x80] | between the vanilla table end and `mapCount`; no access; vanilla meaning unknown | scans above |
| 0x1FD64 | mapCount (was int) | uint | valid `.mmp` maps; compared unsigned | `0x407B34` inc, `0x406484`, `0x407402` |
| 0x1FD68 | exitFlag | int (bool) | set by `OnGameStart`, read by `OnTimer` → `EndDialog(1)` | `0x406254`, `0x406260` |
| 0x1FD6C | playerCount | int | own counter, not `Network_GetPlayerCount` (NET-45) | `0x406210/30/40` |
| 0x1FD70 | origWndProcClientChat | WNDPROC | original WNDPROC of edit `0x41D` | `0x408792`, `0x4078EE` |
| 0x1FD74 | origWndProcHostChat | WNDPROC | original WNDPROC of edit `0x401` | `0x4087AA`, `0x40790A` |
| 0x1FD78 | playerName | wchar_t[260] | registry `Network\PlayerName` as UTF-16 | `0x4061D7`, `0x40632B` |
| 0x1FF80 | unused_0x1ff80 (`unsure_field_0x1ff80`) | uint | only `= 0` in the ctor | `0x407D3F` |
| 0x1FF84 | settings | NetGameSettings | the 0x120 blob | `0x40645A`, `0x4073EB`, `0x4075E7`, `0x4080D5` |
| 0x200A4 | pageControls (was HWND[90]) | HWND[3][30] | 30 per page, stride 0x78 | `0x4086B8`, `0x405ABF`, `0x405ADE` |
| 0x2020C | currentPage | NETDLG_PAGE | | `0x405B02`, `0x405B10`, `0x405F2D` |
| 0x20210 | previousPage | NETDLG_PAGE | write-only; ctor 3 (NONE) | `0x405AFC`, `0x407D35` |
| 0x20214 | unused_0x20214 (`unsure_field_0x20214`) | short | only `= 0` in the ctor | `0x407D28` |
| 0x20216 | pad_0x20216 | byte[2] | alignment | |
| 0x20218 | hwnd | HWND | dialog HWND (`NetDlg_SetHwnd` in WM_INITDIALOG) | `0x405A54` |
| 0x2021C | hInstance | HINSTANCE | `NetDlg_Run` arg | `0x4089D2`, `0x408701`, `0x408A4D` |

Enums (Ghidra `/auto_structs`): `NETDLG_PAGE` BROWSER 0, HOST 1, CLIENT 2, NONE 3 (ShowPage callers,
ctor `0x407D35`); `NETDLG_SETTING` MAP 1, SCORE_LIMIT 2, GAME_TYPE 3, RANDOM_SEED 4, GAME_SPEED 5,
POLICE 6, TIME_LIMIT 7 (jump table `0x4077D8`, the first argument of `NetDlg_SetSetting`). The event
argument structs `NetEvtSessionList` / `NetEvtPing` / `NetEvtChat` are in §3.4. All 51 `NetDlg_*`
prototypes are typed in Ghidra; the `_Frag` tails and `Patch1144_NetLobby_*` hooks keep untyped
prototypes on purpose (context in arbitrary registers, see their plates).

**`NetGameSettings`** (0x120): the group-data blob, `NetDlg+0x1FF84`, and `g_NetGameSettings`. The
size is proven by the `rep movsd ecx=0x48` copies (`0x40645A`, `0x4073F1`, `0x40744E`) and by
`Network_PublishSettings(…, 0x120)`.

| Off | Type | Name | Values |
|---|---|---|---|
| 0x000 | char[0x104] | mmpFileName | lower-case by 11.44 (`0x56DD18`) |
| 0x104 | int | mapIndex | index into the **sender's** map table |
| 0x108 | int | gameSpeed | 0/1/2 |
| 0x10C | int | scoreLimit | frags or points |
| 0x110 | int | gameType | 1 frags, 2 points, 3 tag |
| 0x114 | int | unsure_randomSeed | host's `GetTickCount` at ctor; no reader |
| 0x118 | int | police | 0/1 |
| 0x11C | int | timeLimit | minutes, 0 = none |

N4 described +0 as "a 0xA3-byte map record". N1 and N3 both read it as the mmp file name from map
entry +0x410, with Patch1144_LoadGXT reading it as a name. This page follows N1/N3.

**`NetDlgMapEntry`** (0x518): `gmpFile` +0, `styFile` +0x104, `scrFile` +0x208, `description` +0x30C,
`mmpFile` +0x410 (each `char[0x104]`, read with size 0x103), `int playerCount` +0x514 (`atol` of a
**2-byte** buffer, so one digit only; 0 = any).

**`NetDlgControlDef`** (0x74): `x, y, width, height, ctrlId, style, exStyle`, `className[0x50]` +0x1C,
`gxtKey[8]` +0x6C.

### 4.4 Functions renamed in this pass

| VA | Now (was) |
|---|---|
| `0x405B50` | `NetDlg_OnPlayerPingUpdate` (new function) |
| `0x405CA0` | `NetDlg_OnChatReceived` (new, was undisassembled) |
| `0x406BE0` | `NetDlg_OnSessionListUpdated` (new) |
| `0x406CC0` | `NetDlg_OnPlayerAdded` (new) |
| `0x406F20` | `NetDlg_OnPlayerDeleted` (new) |
| `0x407030` | `NetDlg_OnSessionClosed` (new) |
| `0x407800` | `NetDlg_OnGameStart` (new) |
| `0x407870` | `NetDlg_ChatEditSubclassProc` (new) |
| `0x408900` | `NetDlg_OnSettingsReceived` (new) |
| `0x4073D0` | `NetDlg_ApplyRemoteSettings` (`NetDlg_SetSessionDesc`) |
| `0x406450` | `NetDlg_CopySettings` (`NetDlg_CopyMapInfo`) |
| `0x406550` / `0x406570` / `0x406590` | `NetDlg_GetSelectedGmpFile` / `StyFile` / `ScrFile` (`…MapStr0/1/2`) |
| `0x407070` | `NetDlg_InitControls` (`NetDlg_InitListColumns`) |
| `0x405B20` | `NetDlg_ClearListView` (`NetDlg_ClearListControl`) |
| `0x4066E0` / `0x406B80` | `NetDlg_SetCopsCheckBox` / `NetDlg_SetTimeLimitEditText` |
| `0x40667C` / `0x406C92` / `0x407476` | `NetDlg_EnableStartReject_Frag` / `NetDlg_EnableJoinButton_Frag` / `NetDlg_UpdateClientSettingTexts_Frag` |
| `0x56DCAB` | `Patch1144_NetDlg_AllocMapTable` (`Patch1144_NetSession_AllocSlotBlock`) |
| `0x56DE95` / `0x56DEC0` / `0x56DED4` | `Patch1144_NetDlg_AutoCreateHook` / `StoreSessionsAvailableHook` / `AutoJoinHook` (were `ChatFlagResetHook` / `StoreChatFlagHook` / `ChatFocusHook`) |

## 5. Wire protocol (N4)

### 5.1 Two formats

- **Wire format** (what DirectPlay carries): byte 0 = wire type 1..9, then the payload.
- **Internal format** (what game code reads): `NetMsgHeader` (5 bytes `kind, seq, lenPlus2,
  subtype, payloadLen`), then the payload at +5.

Senders fill a `NetPacketDesc` (0x15 bytes, unaligned: `int kind; int subtype; u8 seq; int hasData;
void* data; uint len`) and `Network_EncodePacket` `0x40A7F0` writes wire bytes into the send buffer.
On receive, `Network_ReceiveMessage` gets the message into the receive buffer. System messages
(`idFrom == 0`) go to `Network_HandleSystemMessage`; everything else goes to
**`Network_DecodeReceivedMessage` `0x409680`** (was `Network_PackMessage`), which rewrites the
message in place into the internal format. It first copies the whole message into a **64-byte stack
buffer** (NET-01).

### 5.2 Wire types (byte-exact)

| Wire | Bytes | Decoded (kind, subtype) | Sender | Receiver |
|---|---|---|---|---|
| 1 | `01 seq input[4] (sync[4])` = 6 or 10 | (1,3) frame | `Network_BroadcastFrameData` `0x40AD70`, `Network_SendFrameDataToPlayer` `0x40ACC0` | `Network_ReceiveGameMessage` `0x40C120` |
| 2 | `02 NetPacketPing` = 13 | (1,1) ping | `Network_SendPingRequest` `0x40B380`; pong in `Network_HandleLobbyMessage` `0x40BF80` | `Network_HandleLobbyMessage` |
| 3 | `03 NetPacketSyncInfo` = 32 | (1,2), payload tag 5 | `Network_BroadcastSyncInfo` `0x40B090` | `Network_WaitForAllPlayersSync` `0x40BFA0` |
| 4 | `04` = 1 | kind 2 ("ready") | `Network_BroadcastSyncReady` `0x40AC50` | `Network_WaitForAllPlayersSync` |
| 5 | `05 02` = 2 | (1,2), tag 2 "sender leaving" | `Network_SendDisconnectNotice` `0x40AF70` | `Multiplayer_ExchangeLockstepInputs` |
| 6 | `06 01 idx[4]` = 6 | (1,2), tag 1 "player idx dropped" | `Network_BroadcastPlayerDropped` `0x40B000` | `Multiplayer_ExchangeLockstepInputs` |
| 7 | `07 03` = 2 | (1,2), tag 3 "game over" | **no sender in vanilla** | `Multiplayer_ExchangeLockstepInputs` → `g_mpQuitRequested` |
| 8 | `08` = 1 | (1,4) start | `Network_SendStartAndLockSession` `0x40AB90` (host) | `Network_HandleLobbyMessage` → event 9, state 2 |
| 9 | `09 seq (sync[4])` = 2 or 6 | (1,3), payload `FFFFFFFF (sync)` = "repeat" | as wire 1 | `Network_ReceiveGameMessage` → `Network_ApplyRepeatFrameInput` `0x40A250` |

- For wire 9 the decoder sets `payloadLen` from the **local** `g_doSyncCheck` (4 or 8), not from
  what arrived.
- Destinations: frames, sync info, ready, disconnect and player-dropped go to `DPID_ALLPLAYERS` (0).
  Ping requests and start go to the group. A single-frame resend goes to one slot dpid.
- Every send is `DPSEND_GUARANTEED` (1) **except the pong** (flags 0).
- Wire type 0 or > 9 hits `DisplayError` at `0x409838`, which is fatal (NET-14).

### 5.3 Lobby traffic

- **Ping.** Every 1000 ms the request `[2]{originDpid = local, responderDpid = 0, sendTime =
  timeGetTime}` goes to the group. A receiver that is not the origin writes its dpid into
  `responderDpid` and sends it straight back to the origin, non-guaranteed. The origin computes
  `rtt = now - sendTime` (a timestamp the peer echoes back, so trusted data) and calls
  `Network_UpdatePlayerPing` `0x409B10`: a lifetime mean in the slot, then event 6.
- **Chat** is not a game packet: `IDirectPlay3::SendChatMessage` (+0xA0) with `DPCHAT{dwSize 0xC,
  dwFlags 0, lpszMessage}`, guaranteed, to the group (`playerIndex < 0`) or one slot. Receivers get
  `DPSYS_CHAT` 0x109 (`lpChat` at msg+0x14, `lpszMessage` at +8, sender dpid at msg+8). The handler
  copies 128 wchar of text and 16 wchar of the sender's name.
- **Settings** are group data only: `Network_PublishSettings` `0x409E10` keeps a heap copy at
  `Network+0x86C/+0x870` and calls `SetGroupData` (+0x6C, `DPSET_GUARANTEED` 2) with the 0x120
  `NetGameSettings`. Clients get `DPSYS_SETPLAYERORGROUPDATA` 0x102 (`dwPlayerType` 0, `dpId` =
  group) and copy the blob **at its received size**. Then `NetDlg_ApplyRemoteSettings` copies a fixed
  0x120.
- **Start**: wire 8 to the group, `SetSessionDesc` with `DPSESSION_JOINDISABLED` (0x20), state 2.

### 5.4 Start barrier (`Network_WaitForAllPlayersSync` `0x40BFA0`)

1. `Network_BuildSyncInfo` `0x461C60` fills `g_netLocalSyncInfo` `0x6626C4`.
2. Send it (wire 3), then send "ready" (wire 4).
3. Busy-poll `Network_ReceiveMessage` for up to **20 s** until both a wire 3 and a wire 4 arrived from
   every occupied slot except our own. Each wire 3 goes through `Multiplayer_VerifySyncInfo`
   `0x462850`. Any field that differs → `Game_FatalExitWithAlert("Player %s: … is different")`,
   `exit(1)`.
4. **Every other message is discarded**, including early frames from faster peers (NET-52).
5. A message from an unknown dpid, or the timeout, returns 0.

`NetPacketSyncInfo` (0x1F, packed):

| Off | Field | Notes |
|---|---|---|
| 0 | `u8 tag` | 5 |
| 1 | `debugFlags` | bit0 `g_logRandomExtra`, bit1 `g_doSyncCheck`, bit2 `g_logRandom` |
| 5 | `gmpFileSize` | `_stat` size |
| 9 | `styFileSize` | `_stat` size |
| 0xD | `scrByteSum` | `File_SumBytes`, additive |
| 0x11 / 0x15 | `versionMajor` / `versionMinor` | |
| 0x19 | `gciByteSum` | `nyc.gci` |
| 0x1D | `u8 gxtMissing` | `g_gxtAllFilesMissing` |
| 0x1E | `u8 playerIndex` | unchecked |

### 5.5 Frames, sequence numbers, repeat compression

- **Sequence state.** `players.frameSeq[6]` at `Network+0x75C`, zeroed only by the ctor. The repeat
  compression is driven by `g_netLastFrameSeq` `0x5D3370` (u8[8]) and `g_netLastFrameInput`
  `0x5D3378` (u32[6]). For the local slot they hold the last frame sent, for remote slots the last
  frame received.
- **Send.** `Network_BroadcastFrameData` uses seq = `frameSeq[local]`, then increments it (byte wrap).
  The encoder emits wire 9 instead of 1 when `SeqDelta(seq, lastSeq[local]) == 1` and
  `input == lastInput[local]`. When the delta is 1 it also updates `lastSeq/lastInput[local]`
  (check at `0x40A94C`-`0x40A954`, update at `0x40AA03`).
- **Resend.** `Network_ResendFrameToPlayer` `0x461A00` → `Network_SendFrameDataToPlayer` encodes with
  **`desc.seq = 0`** and patches wire byte 1 to `frameSeq[local] - seqBack` after encoding (NET-32).
- **`Network_SeqDelta` `0x409C50`** = `(int8)(a - b)`. That is a correct mod-256 signed distance, and
  peers never drift more than 1-2 frames apart, so the byte wrap itself is safe.
- **Pending table.** 48 × `NetPendingPacket` (0x14: `NetFrameInput frame` +0, `playerIndex` +8,
  `len` +0xC, `u8 used` +0x10, `u8 seq` +0x11) at `Network+0x8F4`. It is de-duplicated on
  (player, seq) and stores only 8 payload bytes. When full, the frame is silently dropped.

### 5.6 Structs (`/net`)

| Struct | Size | Fields |
|---|---|---|
| `NetPacketDesc` | 0x15 | kind +0, subtype +4, u8 seq +8, hasData +9, data +0xD, len +0x11 |
| `NetDataRef` | 8 | data, len |
| `NetMsgHeader` | 5 | kind, seq, lenPlus2, subtype, payloadLen |
| `NetPacketPing` | 0xC | originDpid, responderDpid, sendTime |
| `NetPacketSyncInfo` | 0x1F | §5.4 |
| `NetPacketPlayerDropped` | 5 | u8 tag = 1, u32 playerIndex |
| `NetFrameInput` | 8 | input, syncValue |
| `NetPendingPacket` | 0x14 | §5.5 |

### 5.7 Functions

| VA | Name (was) | Conf. |
|---|---|---|
| `0x409680` | `Network_DecodeReceivedMessage` (`Network_PackMessage`) `int __stdcall (byte* msg, uint wireLen)` | high |
| `0x40A7F0` | `Network_EncodePacket` | high |
| `0x409C50` | `Network_SeqDelta` | high |
| `0x40A0F0` / `0x40A190` / `0x40A2A0` / `0x409CE0` | `Network_QueuePendingPacket` / `PopOldestPendingPacket` / `FreePendingPacketSlot` / `ClearPendingPackets` | high |
| `0x40A250` | `Network_ApplyRepeatFrameInput` (`Network_StoreLastSeqInfo`) | high |
| `0x409B10` | `Network_UpdatePlayerPing` | high |
| `0x40BF80` | `Network_HandleLobbyMessage` (`Network_HandleReceivedPacket`) | high |
| `0x40B380` | `Network_SendPingRequest` | high |
| `0x409E10` | `Network_PublishSettings` | high |
| `0x40AB90` | `Network_SendStartAndLockSession` | high |
| `0x40AC50` | `Network_BroadcastSyncReady` (`Network_SendSyncPacket`) | high |
| `0x40B090` | `Network_BroadcastSyncInfo` (`Network_BroadcastCommand1F`; 0x1F was the length) | high |
| `0x40B000` | `Network_BroadcastPlayerDropped` (`Network_BroadcastCommand5`) | high |
| `0x40AF70` | `Network_SendDisconnectNotice` | high |
| `0x40AD70` / `0x40ACC0` | `Network_BroadcastFrameData` / `Network_SendFrameDataToPlayer` | high |
| `0x461A00` | `Network_ResendFrameToPlayer` (`Network_SendFramePacket`) | high |
| `0x461C60` | `Network_BuildSyncInfo` (`Network_BuildSyncPacket`) | high |

## 6. Lockstep (N5)

### 6.1 Pacing: `drawAndLimitFrames` `0x462A30`

```
t = timeGetTime()
if (lastFrameTime <= t) {                 // unsigned compare
    Game_RunLogicStep()                   // one tick with the inputs applied last time
    Game_UpdateLockstepInputFrame()       // poll, send, draw, BLOCK for all inputs, apply
    lastFrameTime = t + nextFrameDeltaTime()   // always 33 in MP
}
```

- There is no catch-up and no frame skipping: the period is `max(33 ms, step + exchange + draw)`.
  A slow machine or a slow link slows **everyone** down.
- `draw()` runs exactly once per tick, inside the lockstep frame.
- `nextFrameDeltaTime` `0x45A460` returns 33 in MP, even with the debug `compensationFPSTime`.
- N1 described this as `lastFrameTime += 33` with catch-up bursts. The decompile (N5,
  `n5_decomp1.c`) shows `lastFrameTime = t + 33`, with `t` taken before the step; the single-player
  branch is the one that does `+=`.

### 6.2 One frame: `Game_UpdateLockstepInputFrame` `0x4626D0`

Single player: `SetKeyState(currentPlayer, Keyboard_PollControlStatus())` and return. In
multiplayer, in this order:

1. `MultiplayerTimeLimit_Update` `0x462530`, `MultiplayerTag_Update` `0x4821C0`.
2. `Game_TickExitCountdown`. If the level-exit countdown reached 0, skip the exchange and send
   `Network_SendDisconnectNotice` (wire 5) every tick instead.
3. Otherwise:
   1. For each bit in `g_mpPlayersLeftMask` `0x662736` whose player is still active:
      `Network_DeletePlayerFromGroupByIndex(i)`, then `Multiplayer_RemoveLeftPlayer` `0x4620E0`
      (`Player_ResetPedsAndDeactivate` + "comms1" kill-feed text). If `i == 0` (the host) or
      `i == g_localPlayerIndex`, set `g_mpQuitRequested` = 1.
   2. `g_mpFrameInputs[local].input = Keyboard_PollControlStatus()`.
   3. `Multiplayer_BroadcastLocalInput` `0x462440`: when `Network_GetPlayerTableCount` (`0x461DA0`) > 1,
      broadcast the 4-byte input, or 8 bytes `{input, rand() % 100}` with `g_doSyncCheck`.
   4. `draw()`.
   5. `Multiplayer_ExchangeLockstepInputs` `0x462140`.
   6. `g_mpAppliedInputs = g_mpFrameInputs` (0x30 bytes).
4. On the first frame: `lastFrameTime = timeGetTime()`, which absorbs the load-time skew.
5. `g_mpQuitRequested ? quitGame(game, 0, 2) : Multiplayer_ApplyBufferedInputs` `0x4624E0`. The
   latter calls `SetKeyState(player[i], applied[i].input)` for each active player, then masks the
   stored word with `0xFFC00FFF`, so a stale re-apply never repeats a key event.
6. `g_mpLockstepFrame++`.

- **Payload of one frame** = the full `Player.inputWord`:

  | Bits | Meaning |
  |---|---|
  | 0..11 | held controls: 0x1 forward, 0x2 back, 0x4 left, 0x8 right, 0x10 attack, 0x20 enter/exit, 0x40 jump, 0x80/0x100 prev/next weapon, 0x200/0x400/0x800 special 1..3 |
  | 12..20 | 9-bit key code |
  | 21 | key down (else key up), for `Player_OnKeyDown/OnKeyUp` |

  An optional second dword carries the sync roll. Nothing else goes on the wire: no positions, no
  state hashes.
- **Latency.** The input is applied at tick N+1 for everyone, the local player included. There is no
  local prediction, which is what keeps all machines identical.

### 6.3 Waiting: `Multiplayer_ExchangeLockstepInputs` `0x462140`

- `g_mpPrevSentInputs = g_mpLastSentInputs; g_mpLastSentInputs = g_mpFrameInputs`.
- The wait mask holds every occupied **network** slot (`players.slots[i].inUse`, read by game index)
  except `g_localPlayerIndex`. The retry limit is 6, or 25 on the first frame.
- Loop until the mask is empty:
  - exit countdown at 0 → return (missing inputs stay stale);
  - `Network_ReceiveGameMessage` → next in-order message;
  - type 3 frame from p: `memcpy(&g_mpFrameInputs[p], payload, len)` (NET-03), clear bit p. With
    `g_doSyncCheck`, a `syncValue` that differs from ours → `DisplayError(0x7EC, "Main.cpp", 0x338)`,
    a ready-made desync detector;
  - type 2 control by `payload[0]`:

    | payload[0] | Meaning | Action |
    |---|---|---|
    | 1 | `{1, int X}` X dropped | clear bit X, set left bit X |
    | 2 | `{2}` the sender is leaving | clear its bit, set its left bit |
    | 3 | `{3}` game over | clear the mask, `g_mpQuitRequested` = 1 |
    | anything else | | `DisplayError(0x431, "Main.cpp", 0x357)`, fatal |

  - any other type (1 ping, 4 start) → `DisplayError(…, 0x35E)`, **fatal** (NET-14, NET-15);
  - every 1000 ms without completion:
    - below the limit: resend our last two frames to each missing player only (seqBack 1 and 2);
    - at the limit: **drop** every missing player p (clear bit, set left bit,
      `Network_BroadcastPlayerDropped(p)`, `MultiplayerTag_MarkPlayerLeft(p)`).

  So a silent peer is dropped after about **7 s** (26 s on the first frame).
- It is a busy loop: no `Sleep`, no message pump (NET-29).

### 6.4 Receiving: `Network_ReceiveGameMessage` `0x40C120` (was `Network_ReceiveFrameData`)

`bool __thiscall (Network*, NetDataRef* out, uint* outPlayer, uint* outType)`. It busy-polls for up
to 500 ms and ends at once when `sessionEnded` is set.

1. **Pending table first** (oldest seq of any player). With `d = seq - expected[p]` and
   `l = seq - ownSeq`:
   - `d < 0`: stale, free it;
   - `d == 0 && l < 0`: accept. `Network_ApplyRepeatFrameInput` resolves a `FFFFFFFF` repeat against
     `g_netLastFrameInput[p]`, then `expected[p]++`;
   - otherwise stop checking pending for this call.
2. **Then a fresh message** from `Network_ReceiveMessage`. The dpid is mapped to a slot
   (`NetPlayerTable_FindByDpid`; unknown dpids are ignored). Non-frame types are returned at once.
   Frames get the same test; a future frame goes to `Network_QueuePendingPacket`.
3. `Network+0x8F0` = the time spent.

The `l < 0` test is what keeps the lockstep: a peer already one frame ahead is parked in the
pending table until we catch up.

### 6.5 Determinism model

- Pure input lockstep: state is never exchanged or checked (only one optional RNG roll per frame).
- The RNG is CRT `rand()` (`Crt_Rand` `0x4D71F7`, state `0x595410`), seeded to 1 in `Game_Ctor`
  (`ResetRandomSeedTo1`). `NetGameSettings.+0x114` is **not** used as a seed.
- `draw()` cannot reach `Crt_Rand` (378 functions walked, `n5_reach.txt`). `Game_StepByStatus` can,
  for example through `SoundMgr_Update_Thunk()` 0x410520 (was `audio`) → `SoundMgr_ReseedRandoms` (5 rolls per tick). That is safe only
  because `Cheats_DisableDebugFlagsForMultiplayer` forces `g_unsure_skipAudio` = 0: **a patch that
  skips `SoundMgr_Update_Thunk()` on one machine desyncs at once.**
- Pause is impossible in MP: `ToggleGamePause` `0x45BAA0` needs `Game+0x23` (player count) == 1.
  Debug keys are forced off.
- The tick length is fixed and the physics is Fix16, so frame-time and x87 differences do not leak
  into the main state. Floats in AI/sound were **not** audited.
- `Player_OnKeyDown` runs for every player's key events on every machine. The local-only branches
  are gated by `Player_IsLocal`, except radio, CD volume and `ChatInput_Open` (NET-55).
- The simulation reads `Game.currentPlayer` (the **local** player) in a few places (NET-41, NET-42).

### 6.6 Globals

| VA | Name | Type |
|---|---|---|
| `0x6626F8` | `g_mpFrameInputs` | `NetFrameInput[6]` |
| `0x662750` | `g_mpAppliedInputs` | `NetFrameInput[6]` |
| `0x662B4C` / `0x662B1C` | `g_mpLastSentInputs` / `g_mpPrevSentInputs` | `NetFrameInput[6]` |
| `0x6626F0` / `0x6626B0` | `g_mpRecvPayload` / `g_mpSendPayload` | `NetDataRef` |
| `0x6626C4` | `g_netLocalSyncInfo` | `NetPacketSyncInfo` |
| `0x6626AC` | `g_mpQuitRequested` | uint |
| `0x662736` | `g_mpPlayersLeftMask` | byte |
| `0x6626A4` / `0x6626BC` | `g_mpLockstepFrame` / `g_mpTotalRecvWaitMs` | uint, unread |
| `0x662784` | `g_mpFirstLockstepFrame` | bool |
| `0x662780` | `g_localPlayerIndex` | copied from `Network+0x5D0` at InitGame |
| `0x662748` | `lastFrameTime` | uint |
| `0x6626E3` / `0x66274C` | `g_spInputPollPending` / `g_forceLogicStepPending` | bool (SP pacing) |

### 6.7 Functions

| VA | Name (was) | Conf. |
|---|---|---|
| `0x462A30` | `drawAndLimitFrames` | high |
| `0x4626D0` | `Game_UpdateLockstepInputFrame` `void __cdecl(void)` | high |
| `0x462140` / `0x462440` / `0x4624E0` | `Multiplayer_ExchangeLockstepInputs` / `_BroadcastLocalInput` / `_ApplyBufferedInputs` | high |
| `0x40BFA0` | `Network_WaitForAllPlayersSync` `bool __fastcall(Network*)` | high |
| `0x40C120` | `Network_ReceiveGameMessage` (`Network_ReceiveFrameData`) | high |
| `0x462850` | `Multiplayer_VerifySyncInfo` (`Network_VerifyPlayerSyncInfo`; N4 also kept the old name, N5 renamed it later) | high |
| `0x4620E0` | `Multiplayer_RemoveLeftPlayer` (`Multiplayer_ShowPlayerLeftMessage`), `int playerIndex` in **EAX** | high |
| `0x4619E0` | `Game_ResetFrameClock` (`getTime`) | high |

## 7. Multiplayer game logic (N6)

### 7.1 Start

- `Menu` fields:

  | Off | Field |
  |---|---|
  | +0x43B | `mpGameType` |
  | +0x43C | `fragLimit` (for frags and points) |
  | +0x440 | `mpLocalPlayerIndex` |
  | +0x441 | `mpPlayerCount` |
  | +0x444 | `mpTimeLimitMinutes` |
  | +0x448 | `short killMatrix[6][6]` |
  | +0x490 | `ushort frags[6]` |
  | +0x49C | `int points[6]` |
  | +0x4B4 | `wchar names[6][16]` |

  `mpWinner` = 6 means none.
- `InitGame` sets the time limit: `g_mpTimeLeftMinutes = min(timeLimit, 60)` and
  `g_mpTimeLimitActive = (minutes != 0)`; `g_mpTimerPagerSlot` `0x66273C` = -1.
- `startGame` calls `Hud_OnGameStart` `0x4CAC30`. In a non-Tag game that gives every remote player a
  HUD arrow coloured by its ped remap.
- `Player_OnLevelStart` → `Player_SetMpColour` `0x4A66F0`: ped remap 5/6/7/8/9/10/0xB/0xD → HUD text
  remap 4/8/7/5/6/3/2 with `hudTextPaletteMode` (Player+0x78C) = 7. Remap 0xC keeps the default.
  Lives start at 5 and never decrease in MP.

### 7.2 Scoring

- `Ped_OnKilled` `0x43D880`, MP branch:
  - a player killed by a player → `Menu_RecordMultiplayerKill(killer, victim)` +
    `Hud_KillFeed_ShowMpKill`;
  - killed by a gang member → the first active player whose ped is in that group gets the kill;
  - no killer → suicide.
- `Menu_RecordMultiplayerKill` `0x45EC70`: `killMatrix[killer*6+victim]++`. A suicide does
  `frags[killer]--` (only if > 0); otherwise `frags++`. The HUD counter is `PlayerScore+0x38`
  (`PlayerScore_AddFrags` `0x4B7580`).
- Points: `PlayerScore_AddMoney` `0x4B7660` adds every money change to `Menu.points[i]`.
  `PlayerScore_OnPedKilled` `0x4B7EB0` pays 1000/5000/10000/2000 by weapon class × combo for a
  player kill.
- Score limit (`PlayerScore_Update` `0x4B7C62`): for type 1/2, a score ≥ `fragLimit` →
  `Menu_SetMultiplayerWinnerIfUnset(i)`, `g_over`, `quitGame(game, 2, 5)`. Type 3 has no limit.
- Time limit `MultiplayerTimeLimit_Update` `0x462530`: counts frames (30 = 1 s). Pager at the
  5-minute marks, blinking in the last minute (`g_mpTimeBlinkCounter` `0x662B7C`). At expiry:
  `g_over` + `quitGame(game, 2, 5)`, **without** setting `mpWinner`.
- Car shop prices ÷ 10 (`Car_BuyUpgrade` `0x4244A0`); `maxWantedStars` = 1 (`PoliceManager_Init`
  `0x4A9430`).

### 7.3 Tag (`MultiplayerTag` `0x665704`, 0x28 bytes, `multip.cpp`)

- Layout: `Player* itPlayer` +0, `int tagTime[6]` +4, `frameTick` +0x1C, `byte playerLeft[6]` +0x20.
- `MultiplayerTag_Update` `0x4821C0`:
  - every 30 frames `tagTime[it]++`, **only while a time limit runs**;
  - the it-player's car takes damage (`Car_AddDamage(car, 0x11)`);
  - game type 0 → `DisplayError(0x431, "multip.cpp", 0x6C)`.
- `MultiplayerTag_SetItPlayer` `0x4820D0` strips weapons/powerups from the new it-player. The
  it-player cannot pick anything up (`MultiplayerTag_IsPedIt` `0x434B60`).
- `MultiplayerTag_OnPlayerDeath` `0x4822A0` (`thiscall (Tag*, Player* dead, Player* killer)`): the
  killer of the it-player becomes it; otherwise the nearest active player becomes it.
- `MultiplayerTag_GetWinnerIndex` `0x453AB0` = max `tagTime` among players who did not leave; its only
  caller discards the result.

### 7.4 Respawn, leaving, results

- **Respawn** (`Player_RespawnPed` `0x4A6050`) uses `MapBlocks_PickNextZoneOfType(0x10)` `0x464DA0`:
  round-robin through the first ≤ 40 restart zones on a shared counter, no enemy check, then
  `Ped_ResetForRespawn` (health 100, invulnerable for 50 frames). Busted halves the multiplier and
  loses the weapons.
- **Quit** (ESC, then Enter, `Player_HandleQuitConfirmKey` `0x4C8690`): the local player calls
  `quitGame(game, 1, 2)`; every peer, which sees the key through the lockstep, calls
  `MultiplayerTag_MarkPlayerLeft(i)` `0x461DD0`.
- **Results** (`FrontEnd_GotoPage(7)` `0x4587B0`, `FrontEnd_DrawMultiplayerScores` `0x455C90`): one row
  per `mpPlayerCount` (name, `(mult_q)` if the player quit), frags/points/time, and the local player's
  kill-matrix row. Each peer computes its own verdict, local score vs the best remote that did not
  quit: `mult_w`/`mult_l`/`mult_d`. `mpWinner` is ignored.

### 7.5 Other `isMultiplayer` branches

| VA | Function | MP behaviour |
|---|---|---|
| `0x420A10` | `CarManager_BuildTrafficModelLists` | all car models allowed |
| `0x43BEB0` | `Ped_FindThreatArea` | gang peds target the nearest player not in their group |
| `0x44A470` | `CrusherSlot_Update` | crusher kills not credited |
| `0x45DB70` | `Gang_PickWeaponByRespect` | always the basic weapon |
| `0x45E000` / `0x45E3A0` | `GeneratorManager_Finalize` / `Generator_TurnOn` | generators fire next frame |
| `0x4A4780` / `0x4A47F0` / `0x4A51C0` | player car history | disabled |
| `0x4A8A90` / `0x4A8B00` | `PlayerData_UnlockLevel` / `PlayerData_UnlockAllLevels` | no profile save |
| `0x4C5F70` / `0x4C8880` / `0x4C8910` | chat input | key 0x44 opens chat; A-Z/0-9 consumed |
| `0x4C78A0` | `Hud_DrawPlayerNames` | remote names over peds if `show_player_names` |
| `0x4C9C20` | `Hud_DrawPlayerPanel` | local frags/tag time + every remote player's money and score |
| `0x4436A0`, `0x496880`, `0x4B34E0` | `Ped_Obj2_BeatOrRobChar`, `PedGameObject_StateFallOnGround`, `TrafficSpawner_TrySpawnSide` | MP branches **not analysed** |

Fields renamed: Game+0x34 `unsure_mpGameSpeedFrameMs` (was `relToSkipPoliceEnum`), Player+0x790
`hudTextRemap`, Player+0x78C `hudTextPaletteMode`. Function renamed: `0x462530`
`MultiplayerTimeLimit_Update` (was `UpdateMultiplayerTimeLimit`).

## 8. Bug catalogue

One row per defect. When several shards found the same bug, all of them are listed under Sources.
The order is remote-reachable memory corruption first, then crash, hang, desync, gameplay,
cosmetic/leak. "Host" in the fix column means it can be fixed in our DirectPlay replacement without
patching the game.

### 8.1 Remote memory corruption and overflows

| ID | VA / patch site | What goes wrong | Trigger | Severity | Conf. | Fix idea | Sources |
|---|---|---|---|---|---|---|---|
| NET-01 | `0x409680` (`sub esp,0x40`; `rep movs wireLen`) | The decoder copies the whole app message into a **64-byte stack buffer** with no length check. Anything over 64 bytes overwrites the saved registers and the return address. The largest legit message is 32 bytes. | one hostile or modded peer | **RCE** | high | Host: drop app messages > 0x40. Patch: `cmp [esp+8],0x40 / ja` error path. | N4 B1, N5 H16 |
| NET-02 | `0x406E40` `NetDlg_OnTimer`, `0x406BE0` | `LB_GETTEXT` into a 260-byte stack buffer without `LB_GETTEXTLEN`. Session names come from remote hosts, and `OnSessionListUpdated`'s 260-byte conversion is unterminated for names ≥ 260 bytes. So the listbox gets an arbitrarily long string and the next 10 ms tick overflows the frame (return address right above). | a session name ≥ ~253 chars on the LAN | **RCE** (remote stack smash) | medium-high | Select by `LB_GETITEMDATA`; terminate conversions; host: cap session names at 64. | N3 B4 |
| NET-03 | `0x462293` `memcpy` in `Multiplayer_ExchangeLockstepInputs` | The frame length comes from the wire (8-bit) and is copied into an 8-byte per-player record. A longer frame overwrites later players, then `g_mpPlayersLeftMask`, `lastFrameTime`, `g_mpAppliedInputs`, `g_localPlayerIndex`. | frame of 9..62 bytes (over that see NET-01) | **memory corruption** (remote) | high | Host: frame length 6/10 (wire 1), 2/6 (wire 9). Patch: `min(len, 8)`. | N4 B10, N5 H4 |
| NET-04 | `0x40B87C` (case 0x109), `0x405CA0` `NetDlg_OnChatReceived` | Chat text and sender are copied with `wcsncpy(128)` / `wcsncpy(16)` (no terminator when full), converted into unterminated 260-byte ANSI buffers, then `sprintf("%s : %s")` into 260 bytes, up to ~523 bytes. N2 called it a stack overflow; N3, which read the frame, found it overruns neighbouring buffers inside the 0x1310 frame, not the return address. | remote chat ≥ 128 wchar or name ≥ 16 | memory corruption (remote), crash possible | medium | Terminate at [127]/[15]; `snprintf`; host: truncate chat to 127 wchar. | N2 B6, N3 B6, N4 B12 |
| NET-05 | `0x40B8F0` `Network_JoinSession` | No `sessionIndex < sessionCount` check. `sessions[]` is wiped and rebuilt every 100 ms (NET-61), so a stale index gives `lpszSessionName == NULL` → `wcslen(NULL)`. | Join at a refresh, or the host vanished | crash | medium | Bounds + NULL check; refresh every 1 s; host: keep a stable list. | N2 B7 |
| NET-06 | `0x40B520` case 0x102, `0x4073D0`, `0x408900` | The settings blob is trusted. It is accepted at any size, then copied as a fixed 0x120 (heap over-read); `mmpName` has no NUL guarantee (it feeds `strcmp` and two `sprintf`s); type/speed/limits/police are not range-checked before Menu/Game. | malformed or older host | crash / desync | medium | Require size == 0x120, force `mmpName[0x103]=0`, clamp fields; host: only deliver 0x120 blobs. | N2 §5, N3 B8, N4 B13 |
| NET-07 | `0x462140` wire 6 handling; `0x462850` | The dropped-player index from the wire is used unchecked (`1 << idx` into a byte mask, `Game_GetPlayer(idx)`). A peer that names *our* index makes us quit. `NetPacketSyncInfo.playerIndex` is also unchecked (name lookup). | malformed packet, or the NET-31 race | crash (OOB) / self-kick | high | Validate `idx < playerCount` and ignore self; host: index bytes < 6. | N4 B11, N5 H15 |
| NET-08 | `0x56DF08` `Patch1144_LoadGXT_MmpOverrides` | The client opens `data\<host's mmpFileName>` for `GCIFile`/`GXTFile` with no path check (`..\` allowed) and reads up to 0xFE chars without a NUL guarantee. Read-only. | odd/hostile host | low (info/path) | high | Reject `\`, `/`, `..`. | N1 #13 |
| NET-09 | `0x3F14D8` (11.44 `-R` stub) | `-R name` is copied with no bound to `0x595F85`; past 118 chars it overwrites `replay_number` and the following `.data`. | long `-r` argument (local) | crash | high | Bound the copy. | N1 #9 |
| NET-10 | `0x4D1098` | `wsprintfA(buf[260], "data\%s", gmp)`: the mmp strings are up to 0x103 bytes, so "data\" + 258 + NUL = 264 overruns by 4 into the NetDlg object. | mmp with a ≥ 255-char file name (local) | crash / corruption | high (code), low (likelihood) | `snprintf`; clamp in the mmp reader. | N1 #8 |

### 8.2 Crash

| ID | VA / patch site | What goes wrong | Trigger | Severity | Conf. | Fix idea | Sources |
|---|---|---|---|---|---|---|---|
| NET-11 | `0x4073D0`/`0x407402`/`0x40748D` → `0x4D1082` | **Client lacks the host's map.** The 0x120 copy brings the host's `mapIndex`; only a name match (case-sensitive `strcmp` at `0x407402`) replaces it. Event 9 still closes the lobby, so Startup builds gmp/sty/scr from `localMaps[hostIndex]`: a different map (silent total desync) or a read past the heap block (garbage paths → crash). The host only sees a chat line and can still Start. Mixed-case names from a pre-11.44 host also miss. | missing `.mmp`, other map set/order, mixed-version peers | crash / desync | high | On no match set `mapIndex = -1` and refuse the start on the client; check `strcmp(settings.mmpName, entry->mmpFile)` in Startup after `NetDlg_Run`; compare case-insensitively. Patch site: `NetDlg_FindMapByName_Frag` exit → `0x56DE0C`. | N1 #1, #2; N3 B1 |
| NET-12 | `0x4089C0` `NetDlg_Run`; `0x40B694` | **Stale NetDlg callbacks.** The 8 handlers are never unregistered, and the NetDlg lives on Startup's stack, which is gone in game. In game, another player's 0x21 still fires event 3 → `NetDlg_OnPlayerDeleted(deadNetDlg)`. That reads the page from reused stack, may decrement a stack dword (`NetDlg_DecPlayerCount`), and touches a stale HWND. | a player leaves mid-game | memory corruption / crash | medium (path verified; damage depends on the stack) | Clear handlers 1-3, 5-9 after `DialogBoxParamA`; or skip event 3 in state 2; host: no 0x21 for remote players in game. | N2 B2, N3 B17 |
| NET-13 | `0x40B290` | The SP-GUID search scans all 8 slots and ignores `connectionCount`; with no match the index is 8 → read past the 0xE0 block → garbage to `InitializeConnection`. | no `UseProtocol` and no IPX among the connections (IPX is gone since Vista) | crash | high | Fail when not found; host: seed `UseProtocol`/`UseConnection`, or report IPX in `EnumConnections`. | N2 B1 |
| NET-14 | `0x409838`; `0x462250`-`0x462260` | Any unknown message is **fatal**: wire type 0 or > 9 in the decoder; an unknown control byte (Main.cpp `0x357`) or a non-frame/non-control type (`0x35E`) in the lockstep. | malformed/foreign/other-version packet | crash (DoS) | high | Host: validate type and exact length (§9.3). Patch: ignore. | N4 B2, N5 H5 |
| NET-15 | `0x40C120` → `0x462140` | `ReceiveGameMessage` returns lobby messages (ping 1, start 4) to the lockstep, which kills the process. The pong is the only non-guaranteed send, so it can overtake the guaranteed sync/ready and arrive after the barrier. | pong reordered over UDP at game start | crash | medium | Host: per-sender FIFO across guaranteed and non-guaranteed sends. Patch: ignore subtypes 1/4 in game. | N4 B4, N5 H6 |
| NET-16 | `0x4D110E` vs `0x461EA4` | Player count and local index are read twice, seconds apart (window, video and audio init in between). `Network_GetPlayerCount` counts occupied slots while the local index is a raw slot. A leave in between gives Menu ≠ Game counts, or `localIndex ≥ playerCount`. | player drops between lobby close and game start | crash / desync | low-medium | Snapshot once; validate. | N1 #11 |
| NET-17 | `0x4C78FC` `Hud_DrawPlayerNames` | `ped == NULL` jumps into the draw path → `Ped_GetX(NULL)`. | remote active player without a ped (not seen) | crash (latent) | high (asm), low (reach) | Retarget the JZ to `0x4C79B3`. | N6 B5 |
| NET-18 | `0x40B87C` | `DPMSG_CHAT.lpChat->lpszMessage` dereferenced without a NULL check. | malformed chat | crash | low | NULL check. | N2 B15 |
| NET-19 | `0x409BC0` | `DeletePlayerFromGroupByName` iterates `i < count`, but holes (from `DeletePlayerFromGroupByIndex`) give `wcscmp(NULL, …)`. | kick after an in-game drop | crash | low | Skip `!inUse`. | N2 B16 |
| NET-20 | `0x407930` `NetDlg_ReadMmpMapFiles` | `_chdir("data")` is unchecked but `_chdir("..")` always runs, so without `data` the cwd moves up for the rest of the run. `HeapReAlloc` is not NULL-checked. | broken install, OOM | crash later | high (code), low (likelihood) | Check; our VFS must make both chdirs succeed. | N1 #14, N3 B14 |
| NET-21 | `0x408840` `NetDlg_OnInitDialog` | A NULL `operator_new(0x14)` → `LoadGXT(NULL)`. | OOM | crash | high | none needed | N3 B18 |
| NET-22 | `0x464DA0` | MP respawn returns 0 when the map has no restart zone → `Ped_ResetForRespawn(ped, 0)`. In practice the `DisplayError(0x83)` in `Player_OnLevelStart` stops such maps earlier. | bad custom map | crash | high | none needed | N6 B12 |

### 8.3 Hang

| ID | VA / patch site | What goes wrong | Trigger | Severity | Conf. | Fix idea | Sources |
|---|---|---|---|---|---|---|---|
| NET-23 | `0x40BEC0` `Network_ReceiveMessage` | A fixed 0x1800 receive buffer. On `DPERR_BUFFERTOOSMALL` (or any failure) it returns "no message", and the oversized message stays at the head of the queue forever. Lobby frozen, lockstep drops everyone after ~7 s. | any message > 6 KB (big group/player data, session desc) | hang | high (code), low (vanilla reach) | Drop on BUFFERTOOSMALL; host: never deliver > 0x1800. | N2 B5, N4 B8 |
| NET-24 | `0x4D1536`, `0x4D0C28` | The frame loop is skipped while minimized (`g_windowMinimizedState` == 2) or after a fullscreen focus loss, in MP too. That player stops sending, so the others stall and drop it after 7 s. | alt-tab / minimize | hang for peers | high | In MP keep running logic + net, only skip the draw. | N1 #3 |
| NET-25 | `0x40BFA0` → `0x4D14E4` | Start-barrier failure (20 s timeout, or **any message from an unknown dpid**) → `CoUninitialize; return 0` with the window, the video mode and the session left as they are. The others wait 26 s, then drop it. | slow load > 20 s, a peer quits during load, late joiner | hang (peers) / desktop stuck in game mode | high | Route through `DestroyWindow`; ignore unknown dpids; longer timeout. | N1 #5, N5 H7 |
| NET-26 | `0x40B520` lobby states, `0x40A5B0` | No `DPSESSION_KEEPALIVE`, no `MIGRATEHOST`; `DPSYS_SESSIONLOST` (0x31), `DPSYS_HOST` (0x101) and `DESTROYPLAYERORGROUP` (5) are ignored in the lobby. A crashed host leaves clients on page 2 forever, and a dropped client may stay in the host's list. | host crash / cable pull in the lobby | hang (UI) | high | Handle 0x31/5 in lobby states → event 1/3; host: emit SESSIONLOST or 0x21(self) on host loss. | N2 B12, N3 B11 |
| NET-27 | `0x40C120`, `0x462140` | When `sessionEnded` is set, every receive returns at once with nothing, and the exchange spins until the 7 s drops or the exit countdown. | session lost in game | hang ≤ 7 s | high | Return "lost" and quit at once. | N5 H14 |
| NET-28 | `0x462A30` (`cmp timeGetTime, lastFrameTime; jb`, unsigned) | With `lastFrameTime = t + 33` just below 2^32 and the next sample wrapped to a small value, `lastFrameTime <= t` is false for ~49.7 days. | uptime crossing 2^32 ms mid-game | hang | high (code) | Host: `timeGetTime` starts at 0 per process. | N1 #15 (re-checked against N5's decompile) |
| NET-29 | `0x40C120`, `0x462140`, `0x40BFA0` | 500 ms / 20 s busy-polls with no `Sleep` and no message pump: 100 % CPU, "Not responding" during long waits. | any lag | cosmetic / perceived hang | high | Host: block ≤ 1 ms in `Receive` when empty, or signal `hReceiveEvent`. | N4 B9, N5 H9 |

### 8.4 Desync

| ID | VA / patch site | What goes wrong | Trigger | Severity | Conf. | Fix idea | Sources |
|---|---|---|---|---|---|---|---|
| NET-30 | `0x40B694` (state 2, 0x21) vs `0x462140`/`0x4626D0` | **Mid-game slot compaction.** The leaver's slot is freed, later slots shift down and `localPlayerIndex--`, but `frameSeq[]` (+0x75C), `g_netLastFrame*`, `g_localPlayerIndex` and the game's player indices do not move. Then: frames are filed under the wrong player and checked against the wrong seq; resends go to the wrong dpid; own seq is read from another counter; `Network_DeletePlayerFromGroupByIndex(i)` frees an **innocent** player, who gets 0x21 for itself → reason 2 → cascade. Machines that free in place and machines that compact end up with different tables. | a non-highest-index player leaves mid-game (its `DestroyPlayer` 0x21 arrives right after its wire 5) | desync / wrong player kicked / hang until drop | high (code), medium (DP message order) | In state 2 never compact (`NetPlayerTable_FreeSlot` in place); host: deliver no 0x21 for remote players in game. | N2 B3, N4 §5, N5 H1 |
| NET-31 | `0x462140` drop branch, `0x40B000` | Split brain on drop: each machine times out a missing peer on **its own** 7 s clock. One deactivates it at frame N+1 with a stale input; another applied the real frame N and learns of the drop from wire 6 frames later. | loss or lag > 7 s on only some links | desync (permanent) | medium | Two-phase drop (host decides "drop p after frame F"); host: never time out on one side only. | N5 H2 |
| NET-32 | `0x40ACC0` + `0x40A954` | **Resend with seq = 0 / wire 9.** The resend is encoded with `desc.seq = 0` and patched afterwards. When `g_netLastFrameSeq[local] == 0xFF` (once per 256 frames ≈ 8.5 s), the encoder sees `SeqDelta(0, 0xFF) == 1`. It may send a wire 9 "repeat" that the receiver expands with its own last input (frame 0xFE's), and it **sets `lastSeq[local] = 0`**, so the next real frames compare against stale state and can emit a wrong wire 9. | a resend (peer missing > 1 s) in that 1/256 window, with differing inputs | desync (rare) | high (mechanism), medium (frequency) | Patch `0x40A954` `75 64` → `EB 64` (never emit wire 9, +4 bytes/frame); or pass the real seq in `desc.seq`; host: none. | N4 B3, N5 H3 |
| NET-33 | `0x40A2C0` (`rep stosd` `0x40A34A`, then `0x40A35B`) | The ctor sets `g_netLastFrameInput[0..5] = -1`, then zeroes 6 dwords from `0x5D3370`, which clobbers `g_netLastFrameInput[0..3]` to 0. If a slot 0..3 player has input 0 at frame 1 but not at frame 0, it sends wire 9 and the receiver substitutes frame 0's input. The state is never reset between sessions. | key held at start and released by frame 1 | desync (rare) | high (mechanism), medium (impact) | Same patch as NET-32, or reset both arrays to -1 at game start. | N4 B6 |
| NET-34 | `0x40A250` | Input `0xFFFFFFFF` is both a legal word and the repeat marker. | all bits set (practically impossible) | desync | low | Same patch as NET-32. | N4 B7 |
| NET-35 | `0x40BA8A` + `0x40B590` | The slot order (= game index, colour, input slot) is built differently per machine: host and existing peers by ADDPLAYERTOGROUP arrival, a joiner by `EnumGroupPlayers` order + its own ADD. Nothing checks it (`NetPacketSyncInfo.playerIndex` is unchecked). | DP enumerating in another order than join order | desync from frame 0 | medium | Host: enumerate in join order and deliver ADDPLAYERTOGROUP in the same order to all; patch: sort by dpid at start. | N2 B9 |
| NET-36 | `0x40AAA0` | ADDPLAYERTOGROUP for a player whose CREATEPLAYERORGROUP we never saw (created before our Open, added after our enumeration) → promotion fails, and the player is missing only on our machine. | two people joining at once | desync | medium | On promote failure add from `GetPlayerName/Data`; host: replay CREATE before ADD. | N2 B10 |
| NET-37 | `0x40B623` | `pendingPlayers` entries are freed only by promotion or CloseSession (DESTROYPLAYERORGROUP is ignored in the lobby). After 6 joins that never reached the group, nobody can be promoted (`AddPlayer` full → 0xEEEEEEEE, silently). | flaky joins in a long-lived lobby | players missing → desync / cannot start | high (code) | Free the pending slot on 5 in the lobby. | N2 B11 |
| NET-38 | `0x407ED8` (LBN_DBLCLK in `NetDlg_OnCommand`) | A double-click join never applies the host settings: JoinSession's event 8 is dropped (page 0) and this path skips `ApplyRemoteSettings`. If the host just presses Start, the client loads its **own** map/type/limits. | join by double-click, host does not touch settings | desync | high | Jump the double-click case into the `0x3E9` code; or let `OnSettingsReceived` accept page 0. | N3 B2 |
| NET-39 | `0x407DB0` case `0x3FD` (Start) | The only start barrier is `UpdateLobby` + `Sleep(100)`. Nothing checks that every client has the map (NET-11) or the latest settings; a SetGroupData sent just before Start (number edits publish per keystroke) may arrive after the client left the lobby. | edit a number, press Start quickly | desync | medium | Put the final settings into the start packet, or ACK the settings before Start is enabled. | N3 B12 |
| NET-40 | `0x461C60` / `0x462850` | The "same files" check compares gmp/sty **sizes** and additive scr/gci **byte sums**, so same-size edits pass. `g_doSyncCheck` is part of the checked debug flags but not forced off in MP, so a registry debug flag on one machine blocks the game ("Debug flags are different"). | same-size modded map; registry debug flags | desync / refusal | high | Hash (CRC32); force the flag off; host: `_stat` sizes must match the pak on every peer. | N4 B15, N5 H8 |
| NET-41 | `0x43DAA1` `Ped_OnKilled` | Gang-respect credit for a kill by a group member is applied only when the group is the **local** player's (`Game.currentPlayer`). Peers apply different respect → different AI. | a follower of player B kills a ped | desync | high | Use the group's owning player (loop as at `0x43D9AE`). | N6 B3 |
| NET-42 | `0x4298B0` `Car_UpdateTrain`, `0x4AD6C0` `PoliceRoadblock_Update` | Simulation code uses the local player's position: the train collision box (local player within 10 tiles) and roadblock removal (200 off-screen ticks, distance from the local player). | maps with trains / police on | desync | medium | Use any/nearest active player. | N6 B4 |
| NET-43 | `0x4B7EB0` `PlayerScore_OnPedKilled` | In the MP player-kill path `(char)ped` (a pointer byte) and uninitialised locals are read in the `g_gxtAllFilesMissing` money test, so `GiveMoney` may run on one peer only. | MP with `g_gxtAllFilesMissing` set | desync (narrow) | medium (decompile only) | Initialise them / skip the test in MP. | N6 B11 |
| NET-44 | `0x407DB0` case `0x3FC` → `0x409BC0` | Reject kicks **by name** (first `wcscmp` match). The default `PlayerName` is empty, so duplicate names are realistic: rejecting a client named like the host removes the **host** → event 1 → the whole session is torn down. With nothing selected the name buffer is uninitialised stack. | duplicate names, Reject without a selection | teardown / wrong kick | high (mechanism) | Store the dpid as the row's lParam and kick by dpid; refuse empty names. | N3 B3 |
| NET-45 | `0x406F20`, `0x407030` | `NetDlg.playerCount--` even when the name is not in the list, and `OnSessionClosed` does not reset it. The Start rule (`== mmp PlayerCount`) then breaks both ways: Start disabled forever, or enabled with a ghost that `WaitForAllPlayersSync` waits for. | duplicate names; event 3 for an unlisted player; after NET-44 | hang / desync | medium | Derive the count from `Network_GetPlayerCount`. | N3 B9, B10 |
| NET-46 | `0x4626D0`, `0x45C3B0`, `0x462140` | `Game_TickExitCountdown` runs in `Game_StepByStatus`, again in the lockstep frame, and on every wait-loop iteration, so the exit countdown speed depends on the machine. After a game-wide `quitGame`, machines leave the lockstep at different ticks. | every end of game | cosmetic (results may differ by a few ticks) | high (calls), medium (effect) | Count down only in `Game_StepByStatus`. | N5 H10 |

### 8.5 Gameplay and robustness

| ID | VA / patch site | What goes wrong | Trigger | Severity | Conf. | Fix idea | Sources |
|---|---|---|---|---|---|---|---|
| NET-47 | `0x4626D0` (index 0), `0x40B520` | Player 0 (the host) leaving sets `g_mpQuitRequested` on every client: the game ends for all. No host migration, `DPSYS_HOST` unhandled in game. | host quits or crashes | game over for all | high | Treat index 0 like the others; host: keep the session alive. | N5 H12, N2 B12 |
| NET-48 | `0x461DD0` / `0x4620E0` | When the Tag **it-player leaves**, `itPlayer` keeps pointing at him. He is deactivated, so `OnPlayerDeath` can never pass "it" on; nobody scores for the rest of the game. | Tag, it-player quits/drops | gameplay (frozen game) | high | In `MarkPlayerLeft`/`RemoveLeftPlayer`: if he is it, `SetItPlayer(NULL)`. | N6 B1 |
| NET-49 | `0x4821C0` | Tag time only counts while a time limit runs, and Tag has no score limit. Tag with time limit 0 never scores and never ends; the result is always a draw. | Tag + time limit 0 | gameplay | high (code), medium (lobby allows it?) | Count regardless, or force a time limit for Tag. | N6 B2 |
| NET-50 | `0x4B7C62` | Score limit 0 ends the game on the first frame (`0 >= 0`). | lobby value 0 | gameplay | high | Clamp, or treat 0 as "no limit". | N6 B8 |
| NET-51 | `0x45A540` | The game-speed setting is dead: written to Game+0x34 as 50/33/20, never read; MP always runs 33 ms ticks. | always | feature broken | high | If wanted, feed it into `nextFrameDeltaTime` in MP. | N6 B6, N1 |
| NET-52 | `0x40BFA0` | The barrier discards early frames from peers that already passed it; lockstep recovers them only via the 1 s resend → ~1 s hitch at frame 0. | uneven start times (always) | hitch | high | Queue wire 1 frames into the pending table. | N4 B5, N5 H6 |
| NET-53 | `0x40A0F0` | Pending table full (48) → the frame is silently dropped, recovered by resend 1 s later. | many players + long stalls | hitch | high | none needed | N5 H13 |
| NET-54 | `0x461A50` + WinMain reason 1 | Any network exit (host gone, session lost) uses reason 1 → the process exits at once, no results, no message. | host quits / connection lost | UX | high | Use reason 5 or show a message. | N1 #6 |
| NET-55 | `0x4A7010` cases 0x3B-0x3E, 0x44 | Remote players' key events run the un-gated `Player_OnKeyDown` branches on every machine: radio station, CD volume (+ `Reg_Sound_SetDword("CDVol")` in **your** registry), `ChatInput_Open`. | remote player presses radio/volume keys | cosmetic | high | Gate with `Player_IsLocal`. | N5 H11 |
| NET-56 | `0x4D1062`, `0x4D0F58`, `0x4D0F89`, `0x4D0FED`, `0x4D1024` | Lobby cancel or any connect failure → Startup returns 0 → WinMain exits silently, with no `Network_CloseSession`. On real DirectPlay a joined client stays in the host's session until the SP times out. | cancel after joining; bad registry blob | ghost player | high | `Network_CloseSession` + a message on the failure path. | N1 #4 |
| NET-57 | `0x40B9ED` | `Open(JOIN|RETURNSTATUS)` is called once; `DPERR_CONNECTING` counts as failure. | slow join | join fails | high | Host: complete `Open` synchronously with DP_OK. | N2 B8 |

### 8.6 Cosmetic, leaks, host-side traps

| ID | VA | What goes wrong | Severity | Conf. | Sources |
|---|---|---|---|---|---|
| NET-58 | `0x407DB0` case `0x3EA` | `sprintf(buf[264], "%s's Game", name)` with name ≤ 0x103 → 2-byte overflow into a local that is overwritten next. Limit edit `0x3EC`. | cosmetic | high | N3 B5 |
| NET-59 | `0x405EC0` `NetDlg_AppendChatLine` | `sprintf` name (≤ 259) + " : " + text (≤ 127) into 260 → ≤ 130-byte overrun into a buffer above (no return address). `logId` is ignored. | cosmetic | high | N3 B7 |
| NET-60 | `0x40BC50` | The host's delete loop runs `count..1`: skips slot 0, touches `slots[count]` (dpid 0, or with 6 players the `sessionDesc` bytes). DestroyGroup follows anyway. | cosmetic | high | N2 B4 |
| NET-61 | `0x40C380` | `EnumSessions(1000 ms, ASYNC)` every 100 ms, with the table freed and rebuilt each time: CPU, list flicker, feeds NET-05. | cosmetic | high | N2 B14 |
| NET-62 | `0x406E40` / `0x406BE0` | The selection is restored with `LB_SELECTSTRING` (case-insensitive **prefix**), so "Bob's Game" vs "Bob's Game 2" can move it → Join joins another session. | wrong session | high | N3 B13 |
| NET-63 | `0x406980` `NetDlg_SetGameTypeText` | The client label prints "3 Frag Game" instead of "3 Frags To Win" (format overwritten by sprintf). | cosmetic | high | N3 B16 |
| NET-64 | `0x407DB0` case `0x407` | `MessageBoxA("TB_THUMBPOSITION ")` debug leftover, unreachable (trackbars use WM_HSCROLL). | none | high | N3 B15 |
| NET-65 | `0x409B10` | The ping is a lifetime mean, so the display reacts ever slower. | cosmetic | high | N4 B14 |
| NET-66 | `0x40AD70`, `0x40AC50`, `0x40B090`, `0x40AF70`, `0x40B000` | These go to `DPID_ALLPLAYERS`, not the group, so a session member outside the group still gets frames. | minor | medium | N4 B16 |
| NET-67 | `0x462530`, `0x4B7C62`, `0x4587B0` | A time-limit end never sets `mpWinner`; at the score limit the lower index wins ties. Harmless: the results page ignores `mpWinner` and decides win/lose/draw per peer. | cosmetic | high | N6 B7, B9 |
| NET-68 | `0x4822A0` | The nearest-player search for Tag starts at `Fix16(0xFFFF)` with strict `<`: ties go to the lower index, players farther than that never become it. Deterministic. | cosmetic | high | N6 B10 |
| NET-69 | `0x4CAC30` / `0x4620E0` | Remote HUD arrows are created once; a leaver keeps an arrow pointing at his dummy ped. | cosmetic | high | N6 B13 |
| NET-70 | `0x45E770` / `0x461EDA` | Result names are filled by enumerating active players with a running counter, but rows are read by player index: an inactive slot at InitGame shifts the names. | cosmetic | medium | N6 B14 |
| NET-71 | `0x461810` | Tokens split on spaces, but `-R` accepts a quoted name with spaces → later switches are read from the middle of the name (bounded, no overrun). | cosmetic | medium | N1 #10 |
| NET-72 | `0x4D11C2`, `0x4D0C4C` | The CoInitialize HRESULT (0/1) is stored as `mutex` and later passed to `ReleaseMutex`/`CloseHandle`. Harmless on Windows; **our `CloseHandle` shim must ignore values < 0x10** so it never closes a real file token. | host trap | high | N1 #12 |
| NET-73 | `0x407870` `NetDlg_ChatEditSubclassProc` | The original WNDPROC is chosen by page, not by hwnd; on page 0 every message to both edits returns 0, WM_NCDESTROY included (leak). | leak | high | N3 B19 |
| NET-74 | `0x4D1029`, `0x40BD20`, `0x40B140`, `0x40BBAB`, `0x408840`, `0x405A40` / `0x56DCAB` | Leaks: the `UseConnectiond` blob; connection entry names/blobs; `modemNames` realloc; JoinSession's GetGroupData retry; the lobby GXT on 3 of 4 exits; the 11.44 heap map table `NetDlg.maps` ((mapCount+1)·0x518 bytes, once per process: `NetDlg_Dtor` only rewrites the vtable, no `HeapFree` references it). | leak | high | N1 #7, N2 B13, N3 B18, P1 H1 |
| NET-75 | `0x407D10` `NetDlg_Ctor` | `settings.gameSpeed` (+0x2008C) is never initialised by the ctor; it is stack garbage until `NetDlg_LoadSettingsFromRegistry` in WM_INITDIALOG. Harmless in vanilla (LoadSettings always runs first, and gameSpeed is dead in game, NET-51), but a host `NetDlg_Run` replacement that skips the dialog must set it. | host trap | high (verified by code) | P1 H2 |
| NET-76 | `0x408900..0x40891A`, `0x4088BE`, `0x408915` | MSVC relies on the tiny getters/setters leaving **ECX** intact (`mov ecx,[esp+4]; call GetPage; …; call ApplyRemoteSettings` with no reload); the decompiler shows an uninitialised `this` there (decompile artifact, not a game bug). A C32/NASM replacement of `NetDlg_GetPage`, `NetDlg_SetHwnd`, `NetDlg_GetHwnd` or `NetDlg_Get/Inc/DecPlayerCount` **must preserve ECX**, or `NetDlg_OnSettingsReceived` / `NetDlg_OnInitDialog` / `NetDlg_OnPlayerAdded` (`extraout_ECX`) call the next method on garbage. | host trap (hooks) | high (verified in disassembly) | P1 H3 |

### 8.7 Count

| Severity class | IDs | Count |
|---|---|---|
| RCE / remote memory corruption / remote input trust | NET-01..04, NET-06, NET-07 | 6 |
| Other overflows and bounds (crash) | NET-05, NET-08..10 | 4 |
| Crash | NET-11..22 | 12 |
| Hang | NET-23..29 | 7 |
| Desync | NET-30..46 | 17 |
| Gameplay / robustness | NET-47..57 | 11 |
| Cosmetic / leak / host trap | NET-58..76 | 19 |
| **Total** | | **76** |

Highest value for "fix the network bugs": NET-01, NET-02, NET-03 (remote), NET-11, NET-12, NET-30,
NET-32, NET-38, NET-44, NET-47. Many of them are host-fixable: a strict input filter (§9.3)
neutralises NET-01/03/04/06/07/14; never delivering 0x21 for remote players in game
neutralises NET-12/30.

## 9. What our DirectPlay replacement must provide

Today `DPLAYX` is stubbed to `E_FAIL` (`docs/win32-shims.md`), and the command line has no
arguments, so multiplayer is unreachable.

### 9.1 Host-side prerequisites (N1, N3)

- **Command line.** `lpCmdLine` must carry `-n` (or `-c`/`-j`) and must be **writable** (`_strupr`).
- **Registry.** `HKCU\SOFTWARE\DMA Design Ltd\GTA2\Network` through `RegCreateKeyExA(KEY_ALL_ACCESS)`,
  with `RegQueryValueExA` honouring `cbData`:
  - DWORD `UseProtocols` = 16 + BINARY `UseProtocold` (SP GUID);
  - DWORD `UseConnections` = N + BINARY `UseConnectiond`.

  Seeding these avoids the `EnumConnections` path and NET-13. Also needed: `PlayerName` (REG_SZ ANSI,
  `IsTextUnicode` must say no), `map_index`, `game_type`, `game_speed`, `police`, `f_limit`,
  `s_limit`, `game_time_limit`, `show_player_names` (DWORDs, created on first read).
- **mmp scan.** `FindFirstFileA/FindNextFileA("*.mmp")` (from the pak root), **`GetPrivateProfileStringA`
  on pak files** (today it only copies the default, so every map fails with a MessageBox; also needed
  by `Patch1144_LoadGXT`), `GetFileAttributesA` relative to the cwd, `_chdir("data")`/`("..")` →
  `SetCurrentDirectoryA` (our shim only allows the root today), and `HeapAlloc`/`HeapReAlloc` on
  `GetProcessHeap()`.
- **Lobby UI: hook it, do not emulate it.** `DialogBoxParamA(0x67)` returns -1 today. The original
  dialog needs `LISTBOX`, `BUTTON`, `STATIC`, `EDIT`, `COMBOBOX`, `SysListView32`, `msctls_trackbar32`,
  subclassing, `SetTimer`, `EndDialog`: a whole widget toolkit. The cheap seam is **`NetDlg_Run`
  `0x4089C0`** (thiscall, returns 1 = start), driven by our own SDL UI. The UI calls the game's own
  functions the way `NetDlg_OnCommand` does:

  | Action | Game call |
  |---|---|
  | Create | `Network_HostSession(name, {&settings, 0x120})` |
  | Join | `Network_JoinSession(index, name, &tmp, &blob)` + `NetDlg_ApplyRemoteSettings` |
  | Settings | fill `dlg->settings`, then `Network_PublishSettings` |
  | Start | `Network_SendStartAndLockSession` |

  **What the replacement must fill before returning 1** (0 = cancel, and WinMain exits; Seq 27 P1):

  1. `dlg->settings` (`+0x1FF84`, 0x120): `mmpFileName` (lower-case `.mmp` name, NUL-terminated;
     `Patch1144_LoadGXT_MmpOverrides` opens `data\<mmpName>` for GXT/GCI overrides), `mapIndex`
     (`NetDlg+0x20088`, a valid index into **this process's** `dlg->maps`), `gameType` 1..3,
     `scoreLimit` > 0 (NET-50), `timeLimit` (minutes), `police` 0/1 and `gameSpeed` 0..2 (NET-75;
     dead in game). `unsure_randomSeed` has no reader.
  2. `dlg->maps[mapIndex].gmpFile/styFile/scrFile`: Startup builds `data\%s` from them. `NetDlg_Ctor`
     → `NetDlg_ReadMmpMapFiles` already fills them if the mmp-scan prerequisites above work from the
     pak (NET-20); otherwise the replacement writes its own entries into `maps`.
  3. The Network session state is not in NetDlg: do what `NetDlg_OnCommand` does (table above), on
     the host finish with `Network_SendStartAndLockSession`. Startup next reads
     `Network_GetPlayerCount` and `Network_GetLocalPlayerIndex`, so `g_NetworkSession` must be
     connected.
  4. Optional, and the fix for NET-12: with `NetDlg_Run` replaced its 8 `Network_Set*Handler`
     registrations never happen. `Network_DispatchEvent` NULL-checks every callback, so that is safe
     and the stale-NetDlg callbacks in game disappear. Register our own handlers if the UI needs the
     events, and clear them before returning.
  5. Registry `Network\PlayerName` is written by `NetDlg_SetPlayerName`; the in-game name comes from
     DirectPlay (`Network_GetPlayerName`), not from NetDlg.

  Hooking any of the small NetDlg getters instead: preserve ECX (NET-76).
- **Timing.** `timeGetTime` monotonic from process start (NET-28); 33 ms ticks.
- **Handles.** `CloseHandle` of 0/1 must be a no-op (NET-72).
- **Exit.** WM_DESTROY → `Network_CloseSession` (`DeletePlayerFromGroup`/`DestroyGroup`/
  `DestroyPlayer`/`Close`), then the process exits with **no Release**. Our objects must survive
  that.

### 9.2 COM surface

DLL entry points:

- `ole32!CoCreateInstance(CLSID_DirectPlay, NULL, CLSCTX_INPROC_SERVER = 1, IID_IDirectPlay3)`;
- `DPLAYX!DirectPlayLobbyCreateW` + QI(`IID_IDirectPlayLobby2`);
- `DPLAYX!DirectPlayCreate`, used only for the modem probe; it may fail or return `DPERR_UNAVAILABLE`.

All strings are wide.

**IDirectPlay3 methods called** (offsets from Wine `dplay.h` declaration order: 3 IUnknown, 29
IDirectPlay2 up to `SetSessionDesc` +0x7C, then IDirectPlay3 `AddGroupToGroup` +0x80 …
`EnumConnections` +0x8C, `InitializeConnection` +0x98, `SendChatMessage` +0xA0; every offset the game
uses lines up with that order):

| Off | Method | How the game calls it / what it needs |
|---|---|---|
| 0x08 | Release | at `Network_Dtor` only |
| 0x0C | AddPlayerToGroup | `(groupId, localDpid)`; must generate ADDPLAYERTOGROUP **to the caller too** |
| 0x10 | Close | |
| 0x14 | CreateGroup | `(&id, {0x10, 0, L"GBH Group", NULL}, data, size, 0)` |
| 0x18 | CreatePlayer | `(&id, {0x10, 0, name, NULL}, hEvent, data, size, 0)` |
| 0x1C | DeletePlayerFromGroup | `(groupId, dpid)`: kick, CloseSession, lockstep drop |
| 0x20 / 0x24 | DestroyGroup / DestroyPlayer | |
| 0x28 | EnumGroupPlayers | `(groupId, &guidInstance, cb, ctx, 0)`; cb `(dpid, type, DPNAME*, flags, ctx)`, type 1 = player, flags bit0 = end; **in join order** |
| 0x2C | EnumGroups | `(&guidInstance, cb, ctx, 0)`, type 0 = group |
| 0x34 | EnumSessions | `(sd{dwSize 0x50, guidApplication}, 0 or 1000, cb, ctx, 0x11)`; DP_OK with synchronous callbacks `cb(desc, &timeout, flags, ctx)`; ≤ 16 used; names ≤ 64 chars (NET-02) |
| 0x3C / 0x50 | GetGroupData / GetPlayerData | `(id, buf, &size, 0)`; NULL/too-small probe → `DPERR_BUFFERTOOSMALL` (0x8877001E) + size; `GetGroupData` after Open must return the current settings blob |
| 0x48 | GetPlayerAddress | `(0, …)` on the modem object only; `DPERR_UNAVAILABLE` is fine |
| 0x60 | Open | `(sd, 2 = CREATE)` or `(sd, 0x81 = JOIN|RETURNSTATUS)`; **must return DP_OK synchronously** (NET-57) |
| 0x64 | Receive | `(&from, &to, DPRECEIVE_ALL = 1, buf, &size = 0x1800)`; non-blocking, `DPERR_NOMESSAGES` quickly when empty (ideally yields ≤ 1 ms, NET-29); never more than 0x1800 bytes (NET-23); `from == 0` = system message |
| 0x68 | Send | `(localDpid, to, flags, data, len)`; `to` 0 = all *other* players, groupId, or one dpid; flags 1 guaranteed (pong 0); no loopback to the sender |
| 0x6C | SetGroupData | `(groupId, data, 0x120, DPSET_GUARANTEED = 2)` → `DPSYS_SETPLAYERORGROUPDATA` to the other members |
| 0x7C | SetSessionDesc | `(sd, 0)` with `DPSESSION_JOINDISABLED` (0x20) |
| 0x8C | EnumConnections | `(appGuid, cb, ctx, DPCONNECTION_DIRECTPLAY = 1)`; cb `(GUID*, conn, size, DPNAME*, flags, ctx)`; report at least the SP asked for (IPX by default, NET-13) |
| 0x98 | InitializeConnection | `(conn, 0)`; with the registry path `conn` is the raw `UseConnection` blob |
| 0xA0 | SendChatMessage | `(local, groupId or dpid, 1, DPCHAT{0xC, 0, msg})` → `DPSYS_CHAT` to the others |

IDirectPlayLobby2: 0x08 Release, 0x14 EnumAddress (modem probe only). `CreateCompoundAddress` (0x38)
is dead code.

### 9.3 Message semantics

- **Delivery.**
  - Reliable for guaranteed sends.
  - **Per-sender FIFO across guaranteed and non-guaranteed sends** (NET-15). Simplest: treat every
    send as reliable and ordered, one channel per peer.
  - The lobby pulls **one** message per 10 ms tick, so queue and never drop.
- **System message order.**
  - `DPSYS_CREATEPLAYERORGROUP` (3) for every new remote player **before** its
    `DPSYS_ADDPLAYERTOGROUP` (7) (NET-36).
  - ADDPLAYERTOGROUP goes to **all** members **including the player being added**: the host and a
    joiner enter their own `players` table only through it. Without it `localPlayerIndex` is wrong
    and the host is one short of the mmp `PlayerCount`.
  - The same order on every machine, which fixes the game player indices (NET-35). Index 0 must be
    the host (NET-47).
- **`DPSYS_DELETEPLAYERFROMGROUP` (0x21)** in the lobby goes to every member **including the removed
  player**: that is how a kicked client learns it (event 1). Reject and host Cancel depend on it.
  **In game (state 2), suppress 0x21 for remote players** (NET-12, NET-30). The game learns about
  leavers from wire 5/6 and calls `DeletePlayerFromGroup` itself. Deliver it only for the local
  player (exit reason 2).
- **Host loss.**
  - In game: `DPSYS_DESTROYPLAYERORGROUP` (5) for the group → reason 1, or `DPSYS_SESSIONLOST`
    (0x31) → reason 0.
  - In the lobby the game ignores both (NET-26), so a host-side workaround is to send 0x21 for the
    local player, which makes the client close the session.
- **Shapes** (`dplay.h`):

  | Message | Fields |
  |---|---|
  | `DPMSG_SETPLAYERORGROUPDATA` 0x102 | `{type, dwPlayerType = 0, dpId = groupId, lpData @+0xC, dwDataSize @+0x10}` |
  | `DPMSG_CHAT` 0x109 | `{type, flags, idFrom @+8, idToPlayer, idToGroup, lpChat @+0x14}` |
  | `DPMSG_DELETEPLAYERFROMGROUP` 0x21 | `{type, group, player}` |
  | `DPMSG_DESTROYPLAYERORGROUP` 5 | `{type, playerType, id, …}` |
- **Input filter** before `Receive` returns an app message (cheap, removes NET-01/03/06/07/14):

  | Wire type | Allowed length |
  |---|---|
  | 1 | 6 or 10 |
  | 2 | 13 |
  | 3 | 32 |
  | 4 | 1 |
  | 5 | 2 |
  | 6 | 6, index < 6 |
  | 7 | 2 |
  | 8 | 1 |
  | 9 | 2 or 6 |

  Also: total ≤ 64; truncate chat to 127 wchar and names to 15; deliver only 0x120 settings blobs;
  sender dpid must be one of the six slot dpids (unknown dpids abort the start barrier, NET-25).
- **Timing the game assumes:**

  | Event | Timing |
  |---|---|
  | Lobby timer | 10 ms |
  | Session refresh | 100 ms |
  | Lobby ping | 1 s |
  | Start barrier | 20 s |
  | Lockstep tick | 33 ms |
  | Per-call receive wait | 500 ms |
  | Resend | every 1 s |
  | Drop a silent peer | ~7 s (26 s on the first frame) |
  | Clients leaving the lobby after wire 8 | ≤ 10 ms |

  The lockstep paces itself, so no clock sync is needed. A same-machine loopback test only needs
  in-order delivery between processes.

## 10. Open questions and leftovers

- **Name collisions between shards: settled** (checked in Ghidra 2026-10-23). `0x4620E0`
  `Multiplayer_RemoveLeftPlayer`, `0x40BF80` `Network_HandleLobbyMessage`, `0x462850`
  `Multiplayer_VerifySyncInfo`, `0x40A250` `Network_ApplyRepeatFrameInput`. Older names in the shard
  notes (`Multiplayer_ShowPlayerLeftMessage`, `Network_HandleReceivedPacket`,
  `Network_VerifyPlayerSyncInfo`, `Network_ExpandRepeatFrame`) are gone.
- `0x461DA0` was a second `Network_GetPlayerCount`; it is now `Network_GetPlayerTableCount` (returns
  `players.count` +0x758, unlike `0x409F90`, which counts `inUse`; they disagree after a hole, NET-19).
- N1's prototypes (`CmdLine_ParseArguments`, `Startup_ConnectMultiplayerFromRegistry`, `Game_GetQuitReason`,
  `Menu_SetMultiplayerGameSettings`, `Reg_*`) are applied in Ghidra.
- `0x4065B0` is now `NetDlg_ReportMmpFileOpenError` (lobby-only).
- **Dead helpers** (no callers), named in Ghidra with a "No callers (dead)" plate:

  | VA, name | What it does |
  |---|---|
  | `0x409EC0` `NetMsg_SetSeq` | set msg[1] = seq |
  | `0x409ED0` `NetMsg_GetSeq` | get msg[1] |
  | `0x409EE0` `NetMsg_GetByte3` | get msg[3] |
  | `0x409EF0` `Network_IncrementSeqByte` | `frameSeq[i]++` |
  | `0x409F30` `NetMsg_GetPayload` | payload view: len at +2, data at +3 |
  | `0x40A040` `NetMsg_GetSeqChecked` | get seq; `DisplayError 0xFDC` if len < 3 |
  | `0x40AE30` `Network_BroadcastFrameDataSeqBack` | broadcast a frame with seq = `frameSeq[local] - arg` |
  | `0x40AED0` `Network_BroadcastControlTag0E` | broadcast control tag 0x0E |
- `NetGameSettings.+0x114`: written with the host's `GetTickCount` and by SetSetting case 4 (which
  has no caller). No reader found; the RNG is seeded with 1 instead.
- The DirectPlay message order on a leave (does 0x21 follow the leaver's wire 5 before the next
  frame?) decides how often NET-30 fires on real DirectPlay. That is irrelevant for our replacement,
  which can suppress 0x21.
- **Not analysed:**
  - the MP branches of `Ped_Obj2_BeatOrRobChar` `0x4436A0`, `PedGameObject_StateFallOnGround`
    `0x496880` and `TrafficSpawner_TrySpawnSide` `0x4B34E0`;
  - floats in AI/sound that might feed state;
  - what sets `g_gxtAllFilesMissing` (NET-43);
  - the full train semantics (NET-42).
- `g_cheatCocktart` `0x5EAD5D` comes from a per-machine Screen registry value in
  `RenderSettings_LoadFrameRateLighting`, also in MP. If it affects gameplay, it is a desync source
  (N1, unverified).
- Whether the lobby lets Tag run with time limit 0 (NET-49) and accepts score limit 0 (NET-50): the
  edits are ES_NUMBER, so 0 is probably reachable (unverified).
- **Wire 7 ("game over") has no sender** in vanilla. Its receiver works and could be used by our
  host for a clean all-quit.
- `Game_GetPlayer` `0x4219E0` is now `Player* __thiscall(Game*, int idx)` (the old 3-argument prototype
  made callers decompile with `unaff_EDI`).
- Two `Game_FirstActivePlayer`/`NextActivePlayer` copies exist: vanilla `0x45A8D0`/`0x45A910`, and
  11.44 `0x3F11A8`/`0x3F12A8` (used only by `TrafficSpawner_Update`). They share
  `Game.playerIterCursor`. No nested use was found in the simulation paths.
