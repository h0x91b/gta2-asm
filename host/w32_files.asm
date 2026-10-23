; w32_files.asm — the KERNEL32 file shim table. The handlers are 64-bit host C
; (host/c/files.c on top of the pak VFS host/c/vfs.c, docs/win32-shims.md "KERNEL32 —
; files"): each is an import handler uint64_t f(const uint32_t *args); the byte counts
; here are what common32 pops (docs/host-c.md, "Import shims in C").

extern _k32_CreateFileA, _k32_ReadFile, _k32_WriteFile, _k32_SetFilePointer
extern _k32_SetEndOfFile, _k32_GetFileType, _k32_GetStdHandle, _k32_GetFileAttributesA
extern _k32_FindFirstFileA, _k32_FindNextFileA, _k32_FindClose, _k32_GetCurrentDirectoryA
extern _k32_SetCurrentDirectoryA, _k32_GetFullPathNameA, _k32_GetDriveTypeA
extern _k32_GetPrivateProfileStringA

section .data
align 8
shimtab_kernel32_files:
    dq s_kernel32
    SHIM "CreateFileA", 28, _k32_CreateFileA
    SHIM "ReadFile", 20, _k32_ReadFile
    SHIM "WriteFile", 20, _k32_WriteFile
    SHIM "SetFilePointer", 16, _k32_SetFilePointer
    SHIM "SetEndOfFile", 4, _k32_SetEndOfFile
    SHIM "FlushFileBuffers", 4, h_ret1
    SHIM "GetFileType", 4, _k32_GetFileType
    SHIM "GetStdHandle", 4, _k32_GetStdHandle
    SHIM "GetFileAttributesA", 4, _k32_GetFileAttributesA
    SHIM "FindFirstFileA", 8, _k32_FindFirstFileA
    SHIM "FindNextFileA", 8, _k32_FindNextFileA
    SHIM "FindClose", 4, _k32_FindClose
    SHIM "GetCurrentDirectoryA", 8, _k32_GetCurrentDirectoryA
    SHIM "SetCurrentDirectoryA", 4, _k32_SetCurrentDirectoryA
    SHIM "GetFullPathNameA", 16, _k32_GetFullPathNameA
    SHIM "GetDriveTypeA", 4, _k32_GetDriveTypeA
    SHIM "GetPrivateProfileStringA", 24, _k32_GetPrivateProfileStringA
    dq 0
section .text
