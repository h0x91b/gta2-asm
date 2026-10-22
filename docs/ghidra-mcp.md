# Ghidra MCP — agents query the live Ghidra GUI

Claude Code agents in this repo get a `ghidra` MCP server (`.mcp.json`) that talks to the
user's **running** Ghidra: list functions, decompile, data types, xrefs, strings, and
(if asked) renames/comments.

```
Claude Code ──stdio──> bridge-mcp-ghidra ──HTTP 127.0.0.1:8089──> GhidraMCPPlugin (Ghidra project window)
```

Target: **Ghidra 12.1.4** (Homebrew formula, `/opt/homebrew/opt/ghidra/libexec`, user profile
`~/Library/ghidra/ghidra_12.1.4_PUBLIC`), project `/Users/arsenyp/ghidra/gta-2-recovered.gpr`,
program `gta2.segments.fixed.exe`.

## What is installed where

| Piece | Location | Notes |
|---|---|---|
| Release assets | `~/.local/share/ghidra-mcp/dl-7.0.0-rc.3/` | upstream release **v7.0.0-rc.3** (newest; built for 12.1.4) |
| Installed extension | `~/Library/ghidra/ghidra_12.1.4_PUBLIC/Extensions/GhidraMCP` | already unpacked, stamped `version=12.1.4` |
| Bridge venv | `~/.local/share/ghidra-mcp/venv` | Python 3.12, `ghidra_mcp_bridge-7.0.0` wheel |
| Launcher | `~/.local/share/ghidra-mcp/run-bridge.sh` | what `.mcp.json` runs |
| Upstream source | `~/.local/share/ghidra-mcp/src` | reference only (docs, `docs/INSTALL_GUI.md`) |

Everything lives outside the worktree, so it survives task cleanup. `tools/ghidra-mcp/install.sh`
reinstalls all of it (idempotent; refuses a zip whose Ghidra stamp does not match the install).

Why rc.3: an extension loads only in the exact Ghidra version it was stamped for. The last stable
tag, v6.0.0, is stamped for 12.1.2; every v7 release is an rc so far, and rc.3 is the one built for
12.1.4. When a final v7.0.0 ships: `GHIDRA_MCP_TAG=v7.0.0 tools/ghidra-mcp/install.sh`.

## One-time GUI setup (user)

The plugin is a **Utility** plugin for the **project window** (the small "Ghidra: gta-2-recovered"
window), not the CodeBrowser. In the CodeBrowser it is not under *Developer*.

1. **Restart Ghidra**: project window **File > Exit Ghidra** (save the program if it asks and you
   want to keep changes; "Save tool?" → **Yes**). Start Ghidra 12.1.4 again (`ghidraRun`), it
   reopens `gta-2-recovered`.
2. Project window **File > Install Extensions...** → **GhidraMCP** should be listed and **ticked**.
   - Not ticked → tick it. Missing → green **+** (top right), pick
     `~/.local/share/ghidra-mcp/dl-7.0.0-rc.3/GhidraMCP-7.0.0-rc.3.zip` (**⌘⇧G** pastes a path),
     **OK**.
   - **OK**. If it says a restart is needed → File > Exit Ghidra and start again.
3. If a **"New Plugins Found"** dialog appears → **Yes** → tick **GhidraMCPPlugin** → **OK**, skip to 5.
4. Project window **File > Configure...** → **Utility** row → **Configure** → tick
   **GhidraMCPPlugin** → **OK** → **Close**.
5. The server starts by itself. Check: project window **Tools > GhidraMCP > Server Status**
   (shows port 8089, version 7.0.0), or in a terminal:
   ```sh
   curl -s http://127.0.0.1:8089/check_connection   # {"status": "ok", "server_kind": "gui", "version": "7.0.0"}
   ```
6. Open `gta2.segments.fixed.exe` in the CodeBrowser as usual (double-click in the project tree).
7. On the next exit, answer **Yes** to saving the tool, otherwise the plugin is off next time.

Port / transports: **Edit > Tool Options... > GhidraMCP HTTP Server** in the project window, then
**Tools > GhidraMCP > Restart Server**. If 8089 is taken the plugin binds the next free port
(8089–8104) — `lsof -i :8089` names the squatter.

### What must stay open for agents

- Ghidra running with the **`gta-2-recovered` project open** (the plugin lives in the project
  window; closing the project stops the server).
- Keep **`gta2.segments.fixed.exe` open in the CodeBrowser**: that becomes the bridge's "current
  program". Without it the plugin can still open programs from the project on demand.

## Agent side

- `.mcp.json` registers server `ghidra`; `.claude/settings.json` pre-approves it
  (`enabledMcpjsonServers`), so every task worktree gets it without a prompt. Tools appear as
  `mcp__ghidra__*`.
- The bridge loads tools **lazily**: on connect it exposes the `function`, `listing` and `program`
  groups plus 8 static tools (`search_tools`, `load_tool_group`, `list_tool_groups`, ...). Need
  types, xrefs, structs? Call `search_tools` / `load_tool_group`; Claude Code picks up the new tools
  via `tools/list_changed`.
- If Ghidra was not up when the session started, the bridge keeps retrying in the background;
  `connect_instance` / `list_instances` force it.
- **The project is writable.** Rename/comment/retype/create tools change the user's Ghidra database.
  Agents call them only when the user asked for annotations. `.claude/settings.json` hard-denies the
  process/project-level destructive tools (`exit_ghidra`, `close_program`,
  `delete_file`, `set_image_base`, memory-block edits, imports, project moves/restores).
  `delete_function`, `delete_data_type`, `run_ghidra_script` and `run_script_inline` are allowed (user's call, 2026-10-22),
  but the plugin still refuses the two script runners unless the Ghidra process was started with
  `GHIDRA_MCP_ALLOW_SCRIPTS=1`.
- Read-only workhorses: `get_functions` (signature, callers/callees, xrefs, `decompiled_code` —
  up to 20 functions per call), `find_functions`, `get_function_count`, `list_strings`,
  `disassemble_function`, `read_memory`; xrefs/types live in lazy groups (`load_tool_group("xref")`).

## Verified end to end (2026-10-20)

Through the stdio bridge exactly as `.mcp.json` runs it: 75 tools after connect,
`get_function_count` → 4820, `find_functions("WinMain")` → `004d0820`, `get_functions(0x004d0820)`
→ the WinMain decompilation (`OpenMutexA(0x1f0001,0,"GBH_BOB_MUTEX")`, `ShellExecuteA(... "gta2manager.exe" ...)`),
matching the CodeBrowser.
- Without Claude Code the same data is plain HTTP: `curl 127.0.0.1:8089/<endpoint>`.
- Running Java through `run_script_inline` / `run_ghidra_script`: `docs/ghidra-scripting.md`; API reference: `docs/ghidra/`.
