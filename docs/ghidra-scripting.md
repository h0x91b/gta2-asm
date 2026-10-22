# Ghidra scripting through the MCP server

When the MCP tools cannot do an edit (clearing struct bytes, bulk retyping, comment sweeps), an
agent runs Java against the live `gta-2-recovered` project. Setup and the tool list:
`docs/ghidra-mcp.md`. API reference: `docs/ghidra/` (look a method up there before calling it).

Grep the reference: `grep -n -A12 'def replaceAtOffset' docs/ghidra/api/ghidra.program.model.data.pyi`.
Full javadoc / in-app help: `tools/ghidra-docs.sh`, then `ghidra-docs/javadoc/api/...`.

## Running a script

- **Gate.** Both runners refuse unless the user started Ghidra with `GHIDRA_MCP_ALLOW_SCRIPTS=1`.
  If they refuse, ask the user; do not work around it.
- **`run_script_inline(code, program="gta2.segments.fixed.exe", args="")`.** `code` is Java. If
  it contains no `extends GhidraScript`, the plugin wraps it as the body of `run()` and hoists
  any `import ...;` lines to the top, so a bare snippet works. A full class is written as
  `<ClassName>.java`: give it a **unique** name (`Seq50Foo`), because the plugin refuses to
  overwrite an existing file.
- **`run_ghidra_script(script_name)`** finds scripts only in `~/ghidra_scripts` (also
  `<cwd>/ghidra_scripts`); another absolute path ends in ClassNotFound. Default timeout 300 s,
  max 1800.
- **`args`** are split on whitespace with no quoting: `"a b"` arrives as two arguments. Read them
  with `getScriptArgs()`.
- **`~/ghidra_scripts` is one shared OSGi bundle.** A compile prints the errors of every *other*
  broken `.java` in that directory, and a broken file keeps being reported. A failed inline run
  leaves `<Class>.java` + `<Class>.java_failed` there until the next inline run purges them;
  delete your own failed hand-written files. First-run felix "Unable to cache bundle info"
  stack traces are harmless.
- Output: `println(...)`; it comes back in the tool response.
- **Never write to the old Ghidra projects**, and leave `.gpr`/`.rep` files alone on disk
  (`AGENTS.md`, "Ghidra project").

## Transactions and saving

Measured, not assumed (bytecode of `GhidraScript.executeNormal` in 12.1.4, plus the plugin
source): the plugin itself opens no transaction, but **`GhidraScript` wraps every run in one**:
`start(); run(); end(true)`, and `end(false)` (roll back) if `run()` throws.

- So a plain script can write without any transaction code, and **throwing an exception rolls
  back the whole run**. That is the cleanest abort: check, and `throw new Exception("...")`.
- `currentProgram.startTransaction(...)` inside a script opens a *sub*-transaction. Per
  `DomainObject.endTransaction` javadoc, if **any** sub-transaction ends with `commit=false`, the
  whole outer transaction is rolled back when it ends, i.e. everything the script did, and
  possibly other clients' concurrent transactions. Fine as an all-or-nothing guard; never as a
  "skip just this item".
- **`save_program` after the edit.** It fails with "Unable to lock due to active transaction" while
  any client (another agent's script) holds a transaction: wait and retry. After a naming pass
  regenerate `re/` (`re/tools/export.sh`).

## Calls we use

Class names link to the local javadoc (exists after `tools/ghidra-docs.sh`); the `api/` file
always exists. Inside `run()` every `FlatProgramAPI` method is callable directly: `toAddr(0x461DE0)`,
`getFunctionAt(addr)`, `getDataAt`, `createLabel`, `setPlateComment`, `currentProgram`, `monitor`.

| Task | Call | Reference |
|---|---|---|
| Find a type | `dtm = currentProgram.getDataTypeManager(); dtm.getDataType(new CategoryPath("/gta2"), "Ped")`; also `findDataTypes(name, list)`, `getAllDataTypes()` | [DataTypeManager](../ghidra-docs/javadoc/api/ghidra/program/model/data/DataTypeManager.html), `api/ghidra.program.model.data.pyi` |
| Inspect a struct | `Structure.getComponentAt(off)`, `getComponentContaining(off)`, `getDefinedComponents()` | [Structure](../ghidra-docs/javadoc/api/ghidra/program/model/data/Structure.html) |
| Clear struct bytes | `struct.clearComponent(ordinal)`: in a non-packed struct the field becomes undefined bytes, the length and later offsets stay | same |
| Put a field at an offset | `struct.replaceAtOffset(off, dt, len, name, comment)`; or `replace(ordinal, dt, len, name, comment)` | same |
| Rename/comment a field | `DataTypeComponent.setFieldName(n)`, `setComment(c)` | [DataTypeComponent](../ghidra-docs/javadoc/api/ghidra/program/model/data/DataTypeComponent.html) |
| Array type | `new ArrayDataType(elemDt, count, elemLen)` | [ArrayDataType](../ghidra-docs/javadoc/api/ghidra/program/model/data/ArrayDataType.html) |
| Merge two types | `dtm.replaceDataType(oldDt, newDt, false)` | DataTypeManager |
| Rename/move a type | `dt.setName(n)`, `dt.setCategoryPath(path)` | [DataType](../ghidra-docs/javadoc/api/ghidra/program/model/data/DataType.html) |
| Functions | `currentProgram.getFunctionManager().getFunctions(true)`; `f.setName(n, SourceType.USER_DEFINED)` | [FunctionManager](../ghidra-docs/javadoc/api/ghidra/program/model/listing/FunctionManager.html), [Function](../ghidra-docs/javadoc/api/ghidra/program/model/listing/Function.html) |
| Signature | `f.updateFunction(cc, returnVar, List<Variable> params, FunctionUpdateType, force, SourceType)`; `f.replaceParameters(List<? extends Variable>, FunctionUpdateType, force, SourceType)`; params are `new ParameterImpl(name, dt, currentProgram)` | Function, `Function.FunctionUpdateType` |
| Custom storage | `f.setCustomVariableStorage(true)`, then `updateFunction(..., FunctionUpdateType.CUSTOM_STORAGE, ...)` with storage on every param | Function |
| Symbols | `currentProgram.getSymbolTable().getSymbols(name)`, `createLabel(addr, name, SourceType.USER_DEFINED)` | [SymbolTable](../ghidra-docs/javadoc/api/ghidra/program/model/symbol/SymbolTable.html) |
| Comments | `listing.getComment(CommentType.PLATE, addr)`, `listing.setComment(addr, CommentType.EOL, text)`, `listing.getCommentAddressIterator(CommentType, mem, true)` | [Listing](../ghidra-docs/javadoc/api/ghidra/program/model/listing/Listing.html), CommentType |

Typing `this`: the `this` parameter of a `__thiscall` function with dynamic storage is an
**auto-parameter**: imposed by the calling convention and immutable through the API (in-app help,
`FunctionPlugin/Variables.htm`). Set the calling convention and the class, or use the MCP tool
`set_function_this_type`; with custom storage you declare `this` yourself as an ordinary
parameter.

## What bit us

From Seq 27 (Ghidra owner) runs, 2026-10:

- `replaceDataType(old, new, true)` **moves the surviving type into the old type's category**
  (Sprite ended up in `/imported/gta2-mouse`). Pass `false`, or `setCategoryPath` back after.
- `dtm.getDataType("/cat/Name")` (string path) returned `null` for types that exist, right after
  other edits in the same transaction. `getDataType(new CategoryPath("/cat"), "Name")` worked.
- The MCP `modify_struct_field` with `undefined1` does **not** clear a field (it leaves a 1-byte
  stub); `Structure.clearComponent` does. More MCP struct traps: `AGENTS.md`, "Ghidra project".
- Compile errors agents hit: `HighParam` has no `getHighVariable()`; `FlatProgramAPI.find(String)`
  is final, so do not name a helper method `find`; `replaceParameters` takes
  `(List, FunctionUpdateType, boolean, SourceType)`, check overloads in the `api/` stub first.
- Make a struct edit all-or-nothing: do the whole edit in one script, verify (e.g. length unchanged),
  and throw if the check fails.
