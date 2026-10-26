# moorhuhn/ — Moorhuhn Winter Edition port

Second game in this repo (ownership table: root [CLAUDE.md](../CLAUDE.md), "Two games in this repo").
Goal, same as GTA2: load the **original, vanilla game exe** into memory under Rosetta, run its own code, and
provide every OS/library service it expects on macOS with SDL3. Then mods on top.

Status 2026-10-26: nothing yet. What is known:

- The file we have, `Moorhuhn winter edition.ebin` (14.4 MB, `~/Downloads`, from a 2001 English CD release), is
  **the installer, not the game**: Smart Install Maker, Delphi + KOL, ~100 KB of code, the game sits in its
  ~14 MB overlay (cabinet, extracted with FDI). Its Ghidra program in `gta-2-recovered` is the installer too.
  The game exe and its imports (DirectDraw? DirectSound?) are still unknown.

Layout (create as needed):

| Path | What | Owner |
|---|---|---|
| `moorhuhn/re/` | Ghidra exports (CSV, headers), like the root `re/` | Moorhuhn RE task |
| `moorhuhn/docs/re/` | RE notes | Moorhuhn RE task |
| `moorhuhn/tools/` | unpack the installer, build `moorhuhn.pak` | Moorhuhn RE task |
| `moorhuhn/host/` | the wrapper: loader, NASM shims, host C, C32 | Moorhuhn host task |
| `moorhuhn/tests/` | tests, a control socket like gta2ctl if useful | Moorhuhn host task |
| `moorhuhn/docs/` | host docs | Moorhuhn host task |

Rules (the root rules apply too, these override where they differ):

- **Game files are never committed**, as with GTA2: the canonical copy is `moorhuhn.pak` (Stored-only zip, same
  format and rules as `data.pak`) in the main checkout, git-ignored and in `clonePaths`. Writing it there is the
  one allowed write to the main checkout. The installer and anything unpacked stay git-ignored (`/moorhuhn-game/`,
  `/downloads/`). Every `.exe` is renamed `.ebin` (company policy).
- **Never run the installer or the game exe natively** (no Wine, no CrossOver); unpack it with `7zz` / `cabextract`
  or a small reader of our own.
- Reuse from GTA2 by copying into `moorhuhn/host/`, with a comment naming the source file; do not edit `host/`.
- Build output stays git-ignored; build and test in a visible dev3 pane, as in the root rules.
