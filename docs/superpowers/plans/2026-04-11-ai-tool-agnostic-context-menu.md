# AI Tool-Agnostic Context Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status (2026-04-11):** All 14 tasks completed and verified end-to-end on the target machine. Two in-flight fixes were folded in during Task 14 verification:
> 1. `Install-ToolArtifacts` switched from stop-explorer-and-sleep to rename-then-replace for handling a locked destination DLL (Windows 11 auto-restarts explorer too fast for the old approach).
> 2. The `add-claude-context-menu.ps1` shim switched from array splatting to hashtable splatting (array splatting binds positionally and misrouted the forwarded args).
>
> Both fixes are reflected in the task code blocks below. If you're re-executing this plan, use the updated code.

**Goal:** Refactor the Claude-Code-specific Windows 11 Explorer context menu into a config-driven framework that supports any AI CLI tool side-by-side, with interactive install/uninstall and backward compatibility for existing Claude Code installations.

**Architecture:** Per-tool compilation of one generic C source file. PowerShell installer reads `configs/<slug>.json`, generates a C header (`src/tool_config.h`) containing all tool-specific strings + GUID + menu items, runs `build.bat`, then packages and registers a signed sparse MSIX. Each tool gets its own CLSID, install dir, AppX package, and shell verb ID — no shared state between tools.

**Tech Stack:** Native C (MSVC `cl.exe`), Windows SDK (`makeappx.exe`, `signtool.exe`), PowerShell 5.1+, MSIX sparse packaging, `IExplorerCommand` COM interface.

**Testing note:** This project has no automated test framework and the spec explicitly scopes out adding one. Verification is manual at end-of-plan (Task 14). Individual tasks use a *write code → verify compile/run → commit* rhythm; the "verify" step is build success for C tasks and dot-source-and-invoke for PowerShell helper functions.

**Design spec:** `docs/superpowers/specs/2026-04-11-ai-tool-agnostic-context-menu-design.md` — read this first if any context is unclear.

---

## File Structure

```
ClaudeCodeContextMenu/
├── src/
│   ├── AIToolContextMenu.c        (NEW — replaces ClaudeCodeContextMenu.c)
│   ├── AIToolContextMenu.def      (NEW — replaces ClaudeCodeContextMenu.def)
│   ├── build.bat                  (MOVED from root, updated)
│   └── tool_config.h              (TRACKED dev stub; install.ps1 overwrites per-build)
├── configs/
│   ├── claude-code.json           (NEW)
│   └── codex.json                 (NEW)
├── install.ps1                    (NEW — primary entry point)
├── add-claude-context-menu.ps1    (REDUCED to a shim forwarder)
├── .gitignore                     (UPDATED)
├── README.md                      (UPDATED)
└── docs/superpowers/
    ├── specs/2026-04-11-ai-tool-agnostic-context-menu-design.md  (EXISTS)
    └── plans/2026-04-11-ai-tool-agnostic-context-menu.md         (THIS FILE)

DELETED:
    ClaudeCodeContextMenu.c
    ClaudeCodeContextMenu.def
    build.bat  (root-level)
    claude_path.h  (if present — auto-generated artifact)
```

**Unit responsibilities:**

- `src/AIToolContextMenu.c` — COM DLL entry points, `IExplorerCommand` / `IEnumExplorerCommand` implementations. Tool-specific values come from `tool_config.h` macros and static arrays. Zero string literals mentioning "Claude" remain.
- `src/tool_config.h` — per-tool compile-time config. Emitted by `install.ps1` before each build. A dev stub is committed so the source compiles standalone for developers who run `build.bat` without going through the installer.
- `configs/*.json` — per-tool declarative config consumed by `install.ps1`.
- `install.ps1` — configuration-driven installer. Exposes top-level flow + a set of helper functions (`Get-UuidV5`, `Read-ToolConfig`, `Resolve-ToolPaths`, `Write-ToolConfigHeader`, `Build-ToolDll`, `Install-ToolArtifacts`, `Register-ToolComClass`, `Write-AppxManifest`, `Ensure-SigningCert`, `Pack-AndRegisterMsix`, `Uninstall-Tool`, `Invoke-LegacyClaudeSweep`, `Get-AvailableConfigs`, `Show-InteractivePrompt`).
- `add-claude-context-menu.ps1` — 7-line backward-compat shim.

---

## Task 1: Directory restructure and .gitignore

**Files:**
- Create: `src/` directory
- Move: `ClaudeCodeContextMenu.c` → `src/AIToolContextMenu.c`
- Move: `ClaudeCodeContextMenu.def` → `src/AIToolContextMenu.def`
- Move: `build.bat` → `src/build.bat`
- Modify: `.gitignore`
- Delete: `claude_path.h` (if present)

- [ ] **Step 1: Create `src/` directory and move files using `git mv` to preserve history**

```bash
cd "C:/Users/wrigh/OneDrive/Documents/GitHub/ClaudeCodeContextMenu"
mkdir -p src
git mv ClaudeCodeContextMenu.c src/AIToolContextMenu.c
git mv ClaudeCodeContextMenu.def src/AIToolContextMenu.def
git mv build.bat src/build.bat
```

- [ ] **Step 2: Delete `claude_path.h` if present (auto-generated artifact, no longer needed)**

```bash
rm -f claude_path.h src/claude_path.h
```

- [ ] **Step 3: Update `.gitignore` — add build artifacts and generated header**

Read current `.gitignore`, then replace its contents with:

```
# Build artifacts
src/*.dll
src/*.obj
src/*.exp
src/*.lib
src/*.stale

# Legacy auto-generated header (pre-refactor — should not exist in new layout)
claude_path.h
src/claude_path.h

# MSIX build artifacts
*.msix
```

The `src/*.stale` pattern covers the renamed-out-of-the-way copies that `Install-ToolArtifacts` creates when displacing a locked destination DLL (see Task 7).

Note: `src/tool_config.h` is intentionally tracked. We commit a Claude-Code dev
stub so developers can build the DLL standalone from `src/` without running the
installer. `install.ps1` overwrites it per-tool at build time; after an install,
run `git checkout src/tool_config.h` to restore the committed stub if you want
a clean working tree.

- [ ] **Step 4: Verify git sees the moves as renames**

```bash
git status
```

Expected: `renamed: ClaudeCodeContextMenu.c -> src/AIToolContextMenu.c` etc. Modified `.gitignore`. No other changes.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Restructure: move sources into src/ subdirectory

Move ClaudeCodeContextMenu.{c,def} and build.bat into src/ in
preparation for renaming to AIToolContextMenu and making the code
tool-agnostic. No behavioral changes.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Refactor C source to use generated header

**Files:**
- Modify: `src/AIToolContextMenu.c` (full rewrite)
- Modify: `src/AIToolContextMenu.def` (LIBRARY line)
- Modify: `src/build.bat` (source/def names, drop CLAUDE_PATH_H flag)
- Create: `src/tool_config.h` (committed dev stub — Claude Code values)

- [ ] **Step 1: Create the committed dev stub `src/tool_config.h`**

This file is overwritten by `install.ps1` during real installs but is committed so developers can `cd src && build.bat` standalone for iteration.

```c
/* src/tool_config.h
 *
 * Per-tool compile-time configuration. Normally generated by install.ps1
 * immediately before each build. The committed version is a DEV STUB
 * containing Claude Code defaults so the source compiles standalone
 * during development.
 */
#ifndef TOOL_CONFIG_H
#define TOOL_CONFIG_H

#define TOOL_EXE_PATH       L"claude.exe"
#define TOOL_PARENT_TITLE   L"Claude Code"
#define TOOL_PARENT_TOOLTIP L"Claude Code options"

static const GUID CLSID_Tool = {
    0xE3C26D71, 0x5A2F, 0x4B89,
    {0x9C, 0x7E, 0xA1, 0xD3, 0xF6, 0xB8, 0x4E, 0x52}
};

typedef struct {
    const wchar_t *title;
    const wchar_t *tooltip;
    const wchar_t *args;  /* NULL = no extra args */
} MenuItemDef;

static const MenuItemDef g_menuItems[] = {
    { L"Open (Default)", L"Launch Claude Code in this folder",                    NULL },
    { L"Open (Auto)",    L"Launch Claude Code with --enable-auto-mode",           L"--enable-auto-mode" },
    { L"Open (YOLO)",    L"Launch Claude Code with --dangerously-skip-permissions", L"--dangerously-skip-permissions" },
};
#define NUM_MENU_ITEMS (sizeof(g_menuItems) / sizeof(g_menuItems[0]))

#endif /* TOOL_CONFIG_H */
```

- [ ] **Step 2: Rewrite `src/AIToolContextMenu.c` to consume `tool_config.h`**

Full new file contents (replaces whatever's currently in `src/AIToolContextMenu.c`):

```c
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <shlwapi.h>

#include "tool_config.h"

/* IEnumExplorerCommand {a88826f8-186f-4987-aade-ea0cef8fbfe8} */
static const IID IID_IEnumExplorerCommand = {
    0xa88826f8, 0x186f, 0x4987,
    {0xaa, 0xde, 0xea, 0x0c, 0xef, 0x8f, 0xbf, 0xe8}
};

static const wchar_t TOOL_EXE[] = TOOL_EXE_PATH;
static LONG g_dllRef = 0;

/* ── Helpers ─────────────────────────────────────────────────────────── */

static wchar_t *GetFolderFromShellItems(IShellItemArray *psia) {
    static wchar_t buf[MAX_PATH];
    buf[0] = 0;
    if (!psia) return buf;
    IShellItem *psi = NULL;
    if (SUCCEEDED(psia->lpVtbl->GetItemAt(psia, 0, &psi))) {
        LPWSTR path = NULL;
        if (SUCCEEDED(psi->lpVtbl->GetDisplayName(psi, SIGDN_FILESYSPATH, &path))) {
            lstrcpynW(buf, path, MAX_PATH);
            CoTaskMemFree(path);
        }
        psi->lpVtbl->Release(psi);
    }
    return buf;
}

static void LaunchTool(IShellItemArray *psia, const wchar_t *extraArgs) {
    wchar_t *folder = GetFolderFromShellItems(psia);
    wchar_t cmdLine[1024];

    if (extraArgs && extraArgs[0])
        wsprintfW(cmdLine, L"cmd.exe /k \"\"%s\" %s\"", TOOL_EXE, extraArgs);
    else
        wsprintfW(cmdLine, L"cmd.exe /k \"\"%s\"\"", TOOL_EXE);

    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi = {0};
    CreateProcessW(NULL, cmdLine, NULL, NULL, FALSE, CREATE_NEW_CONSOLE,
                   NULL, folder[0] ? folder : NULL, &si, &pi);
    if (pi.hProcess) CloseHandle(pi.hProcess);
    if (pi.hThread)  CloseHandle(pi.hThread);
}

/* ═══════════════════════════════════════════════════════════════════════
   Sub-command: a lightweight IExplorerCommand for each menu item
   ═══════════════════════════════════════════════════════════════════════ */

typedef struct {
    IExplorerCommandVtbl *lpVtbl;
    LONG                  refCount;
    const wchar_t        *title;
    const wchar_t        *tooltip;
    const wchar_t        *args;
} SubCommand;

static HRESULT STDMETHODCALLTYPE Sub_QI(IExplorerCommand *This, REFIID riid, void **ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IExplorerCommand)) {
        *ppv = This; This->lpVtbl->AddRef(This); return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE Sub_AddRef(IExplorerCommand *This) {
    return InterlockedIncrement(&((SubCommand *)This)->refCount);
}

static ULONG STDMETHODCALLTYPE Sub_Release(IExplorerCommand *This) {
    SubCommand *sc = (SubCommand *)This;
    LONG r = InterlockedDecrement(&sc->refCount);
    if (r == 0) { HeapFree(GetProcessHeap(), 0, sc); InterlockedDecrement(&g_dllRef); }
    return r;
}

static HRESULT STDMETHODCALLTYPE Sub_GetTitle(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)p; return SHStrDupW(((SubCommand *)This)->title, out);
}

static HRESULT STDMETHODCALLTYPE Sub_GetIcon(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)This; (void)p;
    wchar_t buf[MAX_PATH + 8];
    wsprintfW(buf, L"%s,0", TOOL_EXE);
    return SHStrDupW(buf, out);
}

static HRESULT STDMETHODCALLTYPE Sub_GetToolTip(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)p; return SHStrDupW(((SubCommand *)This)->tooltip, out);
}

static HRESULT STDMETHODCALLTYPE Sub_GetCanonicalName(IExplorerCommand *This, GUID *g) {
    (void)This; *g = CLSID_Tool; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Sub_GetState(IExplorerCommand *This, IShellItemArray *p, BOOL b, EXPCMDSTATE *s) {
    (void)This; (void)p; (void)b; *s = ECS_ENABLED; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Sub_Invoke(IExplorerCommand *This, IShellItemArray *psia, IBindCtx *pbc) {
    (void)pbc;
    LaunchTool(psia, ((SubCommand *)This)->args);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE Sub_GetFlags(IExplorerCommand *This, EXPCMDFLAGS *f) {
    (void)This; *f = ECF_DEFAULT; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Sub_EnumSub(IExplorerCommand *This, IEnumExplorerCommand **pp) {
    (void)This; *pp = NULL; return E_NOTIMPL;
}

static IExplorerCommandVtbl g_SubVtbl = {
    Sub_QI, Sub_AddRef, Sub_Release,
    Sub_GetTitle, Sub_GetIcon, Sub_GetToolTip,
    Sub_GetCanonicalName, Sub_GetState, Sub_Invoke,
    Sub_GetFlags, Sub_EnumSub
};

static SubCommand *CreateSubCommand(const wchar_t *title, const wchar_t *tooltip, const wchar_t *args) {
    SubCommand *sc = (SubCommand *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(SubCommand));
    if (!sc) return NULL;
    sc->lpVtbl   = &g_SubVtbl;
    sc->refCount = 1;
    sc->title    = title;
    sc->tooltip  = tooltip;
    sc->args     = args;
    InterlockedIncrement(&g_dllRef);
    return sc;
}

/* ═══════════════════════════════════════════════════════════════════════
   IEnumExplorerCommand — enumerates the sub-commands from g_menuItems
   ═══════════════════════════════════════════════════════════════════════ */

typedef struct {
    IEnumExplorerCommandVtbl *lpVtbl;
    LONG   refCount;
    ULONG  index;
} SubCmdEnum;

static HRESULT STDMETHODCALLTYPE Enum_QI(IEnumExplorerCommand *This, REFIID riid, void **ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IEnumExplorerCommand)) {
        *ppv = This; This->lpVtbl->AddRef(This); return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE Enum_AddRef(IEnumExplorerCommand *This) {
    return InterlockedIncrement(&((SubCmdEnum *)This)->refCount);
}

static ULONG STDMETHODCALLTYPE Enum_Release(IEnumExplorerCommand *This) {
    SubCmdEnum *e = (SubCmdEnum *)This;
    LONG r = InterlockedDecrement(&e->refCount);
    if (r == 0) { HeapFree(GetProcessHeap(), 0, e); InterlockedDecrement(&g_dllRef); }
    return r;
}

static HRESULT STDMETHODCALLTYPE Enum_Next(IEnumExplorerCommand *This,
    ULONG celt, IExplorerCommand **pUICommand, ULONG *pceltFetched)
{
    SubCmdEnum *e = (SubCmdEnum *)This;
    ULONG fetched = 0;

    while (fetched < celt && e->index < NUM_MENU_ITEMS) {
        const MenuItemDef *def = &g_menuItems[e->index];
        SubCommand *sc = CreateSubCommand(def->title, def->tooltip, def->args);
        if (!sc) break;
        pUICommand[fetched++] = (IExplorerCommand *)sc;
        e->index++;
    }
    if (pceltFetched) *pceltFetched = fetched;
    return (fetched == celt) ? S_OK : S_FALSE;
}

static HRESULT STDMETHODCALLTYPE Enum_Skip(IEnumExplorerCommand *This, ULONG celt) {
    SubCmdEnum *e = (SubCmdEnum *)This;
    e->index += celt;
    return (e->index <= NUM_MENU_ITEMS) ? S_OK : S_FALSE;
}

static HRESULT STDMETHODCALLTYPE Enum_Reset(IEnumExplorerCommand *This) {
    ((SubCmdEnum *)This)->index = 0; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Enum_Clone(IEnumExplorerCommand *This, IEnumExplorerCommand **pp) {
    (void)This; *pp = NULL; return E_NOTIMPL;
}

static IEnumExplorerCommandVtbl g_EnumVtbl = {
    Enum_QI, Enum_AddRef, Enum_Release,
    Enum_Next, Enum_Skip, Enum_Reset, Enum_Clone
};

static SubCmdEnum *CreateEnum(void) {
    SubCmdEnum *e = (SubCmdEnum *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(SubCmdEnum));
    if (!e) return NULL;
    e->lpVtbl   = &g_EnumVtbl;
    e->refCount = 1;
    e->index    = 0;
    InterlockedIncrement(&g_dllRef);
    return e;
}

/* ═══════════════════════════════════════════════════════════════════════
   Parent IExplorerCommand — the tool-specific dropdown
   ═══════════════════════════════════════════════════════════════════════ */

typedef struct {
    IExplorerCommandVtbl *lpVtbl;
    LONG refCount;
} ParentCmd;

static HRESULT STDMETHODCALLTYPE Par_QI(IExplorerCommand *This, REFIID riid, void **ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IExplorerCommand)) {
        *ppv = This; This->lpVtbl->AddRef(This); return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE Par_AddRef(IExplorerCommand *This) {
    return InterlockedIncrement(&((ParentCmd *)This)->refCount);
}

static ULONG STDMETHODCALLTYPE Par_Release(IExplorerCommand *This) {
    ParentCmd *p = (ParentCmd *)This;
    LONG r = InterlockedDecrement(&p->refCount);
    if (r == 0) { HeapFree(GetProcessHeap(), 0, p); InterlockedDecrement(&g_dllRef); }
    return r;
}

static HRESULT STDMETHODCALLTYPE Par_GetTitle(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)This; (void)p; return SHStrDupW(TOOL_PARENT_TITLE, out);
}

static HRESULT STDMETHODCALLTYPE Par_GetIcon(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)This; (void)p;
    wchar_t buf[MAX_PATH + 8];
    wsprintfW(buf, L"%s,0", TOOL_EXE);
    return SHStrDupW(buf, out);
}

static HRESULT STDMETHODCALLTYPE Par_GetToolTip(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)This; (void)p; return SHStrDupW(TOOL_PARENT_TOOLTIP, out);
}

static HRESULT STDMETHODCALLTYPE Par_GetCanonicalName(IExplorerCommand *This, GUID *g) {
    (void)This; *g = CLSID_Tool; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Par_GetState(IExplorerCommand *This, IShellItemArray *p, BOOL b, EXPCMDSTATE *s) {
    (void)This; (void)p; (void)b; *s = ECS_ENABLED; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Par_Invoke(IExplorerCommand *This, IShellItemArray *p, IBindCtx *b) {
    (void)This; (void)p; (void)b; return E_NOTIMPL;
}

static HRESULT STDMETHODCALLTYPE Par_GetFlags(IExplorerCommand *This, EXPCMDFLAGS *f) {
    (void)This; *f = ECF_HASSUBCOMMANDS; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Par_EnumSub(IExplorerCommand *This, IEnumExplorerCommand **ppEnum) {
    (void)This;
    SubCmdEnum *e = CreateEnum();
    if (!e) { *ppEnum = NULL; return E_OUTOFMEMORY; }
    *ppEnum = (IEnumExplorerCommand *)e;
    return S_OK;
}

static IExplorerCommandVtbl g_ParVtbl = {
    Par_QI, Par_AddRef, Par_Release,
    Par_GetTitle, Par_GetIcon, Par_GetToolTip,
    Par_GetCanonicalName, Par_GetState, Par_Invoke,
    Par_GetFlags, Par_EnumSub
};

/* ═══════════════════════════════════════════════════════════════════════
   IClassFactory
   ═══════════════════════════════════════════════════════════════════════ */

typedef struct { IClassFactoryVtbl *lpVtbl; } ToolFactory;

static HRESULT STDMETHODCALLTYPE CF_QI(IClassFactory *This, REFIID riid, void **ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IClassFactory)) {
        *ppv = This; return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE CF_AddRef(IClassFactory *This)  { (void)This; return 2; }
static ULONG STDMETHODCALLTYPE CF_Release(IClassFactory *This) { (void)This; return 1; }

static HRESULT STDMETHODCALLTYPE CF_CreateInstance(IClassFactory *This,
    IUnknown *pOuter, REFIID riid, void **ppv)
{
    (void)This;
    if (pOuter) return CLASS_E_NOAGGREGATION;
    ParentCmd *cmd = (ParentCmd *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(ParentCmd));
    if (!cmd) return E_OUTOFMEMORY;
    cmd->lpVtbl   = &g_ParVtbl;
    cmd->refCount = 1;
    InterlockedIncrement(&g_dllRef);
    HRESULT hr = cmd->lpVtbl->QueryInterface((IExplorerCommand *)cmd, riid, ppv);
    cmd->lpVtbl->Release((IExplorerCommand *)cmd);
    return hr;
}

static HRESULT STDMETHODCALLTYPE CF_LockServer(IClassFactory *This, BOOL fLock) {
    (void)This;
    if (fLock) InterlockedIncrement(&g_dllRef); else InterlockedDecrement(&g_dllRef);
    return S_OK;
}

static IClassFactoryVtbl g_CFVtbl = { CF_QI, CF_AddRef, CF_Release, CF_CreateInstance, CF_LockServer };
static ToolFactory g_Factory = { &g_CFVtbl };

/* ═══════════════════════════════════════════════════════════════════════
   DLL exports
   ═══════════════════════════════════════════════════════════════════════ */

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void **ppv) {
    if (IsEqualCLSID(rclsid, &CLSID_Tool))
        return CF_QI((IClassFactory *)&g_Factory, riid, ppv);
    *ppv = NULL;
    return CLASS_E_CLASSNOTAVAILABLE;
}

STDAPI DllCanUnloadNow(void) {
    return g_dllRef == 0 ? S_OK : S_FALSE;
}
```

- [ ] **Step 3: Update `src/AIToolContextMenu.def`**

Full file contents:

```
LIBRARY AIToolContextMenu
EXPORTS
    DllGetClassObject   PRIVATE
    DllCanUnloadNow     PRIVATE
```

- [ ] **Step 4: Update `src/build.bat`**

Full file contents (drops the `CLAUDE_PATH_H` flag, updates source/def names, updates output check):

```bat
@echo off
setlocal

REM Find Visual Studio via vswhere
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath 2^>nul`) do set "VSDIR=%%i"
if not defined VSDIR (
    echo ERROR: Visual Studio not found. Install VS with C++ desktop workload.
    exit /b 1
)

call "%VSDIR%\VC\Auxiliary\Build\vcvarsall.bat" amd64 >nul 2>nul
cd /d "%~dp0"

if not exist tool_config.h (
    echo ERROR: tool_config.h not found. Run install.ps1 from the repo root, or
    echo        ensure the committed dev stub exists in src\.
    exit /b 1
)

cl /LD /O2 AIToolContextMenu.c /link /DEF:AIToolContextMenu.def ole32.lib shell32.lib shlwapi.lib uuid.lib user32.lib
if exist AIToolContextMenu.dll (echo BUILD_SUCCESS) else (echo BUILD_FAILED)
```

- [ ] **Step 5: Verify standalone build works**

```bash
cd "C:/Users/wrigh/OneDrive/Documents/GitHub/ClaudeCodeContextMenu/src"
cmd //c build.bat
```

Expected last line: `BUILD_SUCCESS`. If `BUILD_FAILED`: read compiler output, fix. The most common issue is a missing include or a typo in the header — double-check `tool_config.h` exists and matches Step 1.

- [ ] **Step 6: Clean up build artifacts before commit**

```bash
cd "C:/Users/wrigh/OneDrive/Documents/GitHub/ClaudeCodeContextMenu/src"
rm -f AIToolContextMenu.dll AIToolContextMenu.obj AIToolContextMenu.exp AIToolContextMenu.lib
```

- [ ] **Step 7: Commit**

```bash
cd "C:/Users/wrigh/OneDrive/Documents/GitHub/ClaudeCodeContextMenu"
git add src/
git commit -m "Make C source tool-agnostic via generated tool_config.h

Replace hardcoded Claude Code strings and CLSID with macros and a
static menu array pulled from tool_config.h. The committed version of
the header is a dev stub with Claude Code values so the source still
compiles standalone; install.ps1 will overwrite it per-tool at build
time.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Create tool configuration files

**Files:**
- Create: `configs/claude-code.json`
- Create: `configs/codex.json`

- [ ] **Step 1: Create `configs/claude-code.json`**

The legacy `guid` and `packageName` are pinned so existing installs upgrade cleanly.

```json
{
  "toolSlug": "claude-code",
  "toolName": "Claude Code",
  "executable": "claude.exe",
  "guid": "E3C26D71-5A2F-4B89-9C7E-A1D3F6B84E52",
  "packageName": "ClaudeCode.ContextMenu",
  "publisher": "CN=ClaudeCodeDev",
  "parentMenu": {
    "title": "Claude Code",
    "tooltip": "Claude Code options"
  },
  "menuItems": [
    {
      "title": "Open (Default)",
      "tooltip": "Launch Claude Code in this folder",
      "args": ""
    },
    {
      "title": "Open (Auto)",
      "tooltip": "Launch Claude Code with --enable-auto-mode",
      "args": "--enable-auto-mode"
    },
    {
      "title": "Open (YOLO)",
      "tooltip": "Launch Claude Code with --dangerously-skip-permissions",
      "args": "--dangerously-skip-permissions"
    }
  ]
}
```

- [ ] **Step 2: Create `configs/codex.json`**

Omits `guid` (will be derived via UUIDv5) and `packageName` (will be defaulted).

```json
{
  "toolSlug": "codex",
  "toolName": "Codex",
  "executable": "codex.exe",
  "publisher": "CN=AIToolContextMenuDev",
  "parentMenu": {
    "title": "Codex",
    "tooltip": "OpenAI Codex options"
  },
  "menuItems": [
    {
      "title": "Open (Default)",
      "tooltip": "Launch Codex in this folder",
      "args": ""
    },
    {
      "title": "Open (Bypass)",
      "tooltip": "Launch Codex with --dangerously-bypass-approvals-and-sandbox",
      "args": "--dangerously-bypass-approvals-and-sandbox"
    }
  ]
}
```

- [ ] **Step 3: Validate both configs parse as JSON**

```bash
cd "C:/Users/wrigh/OneDrive/Documents/GitHub/ClaudeCodeContextMenu"
powershell -Command "Get-Content configs/claude-code.json | ConvertFrom-Json | Out-Null; 'claude-code: OK'"
powershell -Command "Get-Content configs/codex.json | ConvertFrom-Json | Out-Null; 'codex: OK'"
```

Expected: both print `OK`. If parse error: fix the JSON (most likely a trailing comma or unquoted key).

- [ ] **Step 4: Commit**

```bash
git add configs/
git commit -m "Add tool configs for Claude Code and Codex

claude-code.json pins the legacy CLSID and package name for backward
compatibility with existing installs. codex.json omits the guid and
packageName to exercise the default-derivation path.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: install.ps1 scaffolding + parameter parsing + UUIDv5 helper

**Files:**
- Create: `install.ps1`

- [ ] **Step 1: Create `install.ps1` with the top-level structure, param block, and `Get-UuidV5` helper**

Full initial contents:

```powershell
<#
.SYNOPSIS
    Installs Windows 11 context-menu integration for one or more AI coding CLI tools.
.DESCRIPTION
    Reads per-tool config from configs/<slug>.json and builds a dedicated native
    COM DLL per tool, registered via a signed sparse MSIX package. Each tool gets
    its own CLSID, AppX package, install dir, and shell verb — side-by-side safe.

    Without -ToolName, prompts interactively for which tools to install/uninstall.

    Elevation is enforced at runtime inside Invoke-Main (NOT via
    `#Requires -RunAsAdministrator`) so that dot-sourcing this file to
    unit-test helper functions works from a non-elevated shell.
.PARAMETER ToolName
    Optional. Tool slug (matches configs/<slug>.json). If omitted, runs interactively.
.PARAMETER ConfigFile
    Optional. Explicit path to a config file. Overrides configs/<ToolName>.json lookup.
.PARAMETER ExecutablePath
    Optional. Overrides the config's "executable" field for this run.
.PARAMETER Uninstall
    Switch. Remove rather than install.
#>
param(
    [string]$ToolName,
    [string]$ConfigFile,
    [string]$ExecutablePath,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

# Fixed namespace UUID for deterministic UUIDv5 derivation of per-tool CLSIDs.
# Never change — changing this would invalidate all derived GUIDs for existing installs.
$script:ProjectNamespaceUuid = "7f3a2b18-9c4d-4e5f-a6b7-c8d9e0f1a2b3"

$script:RepoRoot    = $PSScriptRoot
$script:SrcDir      = Join-Path $PSScriptRoot "src"
$script:ConfigsDir  = Join-Path $PSScriptRoot "configs"

# ─── UUIDv5 (RFC 4122 §4.3) ────────────────────────────────────────────────
function Get-UuidV5 {
    param(
        [Parameter(Mandatory)][string]$NamespaceUuid,
        [Parameter(Mandatory)][string]$Name
    )
    $ns = [Guid]::Parse($NamespaceUuid).ToByteArray()
    # .NET stores the first 3 fields little-endian; convert to network byte order
    [Array]::Reverse($ns, 0, 4)
    [Array]::Reverse($ns, 4, 2)
    [Array]::Reverse($ns, 6, 2)

    $nameBytes = [Text.Encoding]::UTF8.GetBytes($Name)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($ns + $nameBytes)
    } finally {
        $sha1.Dispose()
    }
    # Explicit [byte[]] cast is REQUIRED — PowerShell's array slicing returns
    # Object[], which [Guid]::new() rejects.
    $bytes = [byte[]]$hash[0..15]
    $bytes[6] = ([byte]($bytes[6] -band 0x0F)) -bor 0x50  # version 5
    $bytes[8] = ([byte]($bytes[8] -band 0x3F)) -bor 0x80  # RFC 4122 variant

    # Flip back to .NET Guid byte layout
    [Array]::Reverse($bytes, 0, 4)
    [Array]::Reverse($bytes, 4, 2)
    [Array]::Reverse($bytes, 6, 2)
    return ([Guid]::new($bytes)).ToString().ToUpper()
}

# ─── Top-level dispatch ────────────────────────────────────────────────────
function Invoke-Main {
    # Enforce elevation here (not via #Requires) so dot-sourcing for unit tests works
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "install.ps1 must be run from an elevated PowerShell session (Run as Administrator)."
    }

    if ($ToolName) {
        if ($Uninstall) {
            Write-Host "Uninstall pipeline for $ToolName — not yet implemented" -ForegroundColor Yellow
        } else {
            Write-Host "Install pipeline for $ToolName — not yet implemented" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Interactive mode — not yet implemented" -ForegroundColor Yellow
    }
}

# Only run Invoke-Main when this script is executed directly, not when dot-sourced
# (dot-sourcing is how Tasks 4+ verify helper functions incrementally).
if ($MyInvocation.InvocationName -ne ".") {
    Invoke-Main
}
```

- [ ] **Step 2: Verify `Get-UuidV5` produces correct output**

Test against a known UUIDv5 value. The DNS namespace `6ba7b810-9dad-11d1-80b4-00c04fd430c8` + name `"www.example.com"` should yield `2ED6657D-E927-568B-95E1-2665A8AEA6A2` (standard RFC test vector).

```bash
cd "C:/Users/wrigh/OneDrive/Documents/GitHub/ClaudeCodeContextMenu"
powershell -Command ". .\install.ps1; Get-UuidV5 -NamespaceUuid '6ba7b810-9dad-11d1-80b4-00c04fd430c8' -Name 'www.example.com'"
```

Expected: `2ED6657D-E927-568B-95E1-2665A8AEA6A2`

If output differs: the byte-order flipping is wrong. Fix before proceeding — every downstream task depends on this.

- [ ] **Step 3: Verify dispatch prints placeholder for `-ToolName claude-code`**

```bash
powershell -Command ".\install.ps1 -ToolName claude-code"
```

Expected: `Install pipeline for claude-code — not yet implemented`

- [ ] **Step 4: Commit**

```bash
git add install.ps1
git commit -m "Scaffold install.ps1 with param block and Get-UuidV5 helper

Verified Get-UuidV5 against the RFC 4122 DNS namespace test vector
(www.example.com -> 2ED6657D-E927-568B-95E1-2665A8AEA6A2). Top-level
dispatch is stubbed — subsequent tasks fill in install/uninstall.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Config loading, validation, and path resolution helpers

**Files:**
- Modify: `install.ps1` (append helper functions)

- [ ] **Step 1: Add `Read-ToolConfig` and `Resolve-ToolPaths` functions**

Insert these functions into `install.ps1` immediately after `Get-UuidV5` (before `Invoke-Main`):

```powershell
# ─── Config loading ───────────────────────────────────────────────────────
function Read-ToolConfig {
    param(
        [string]$ToolSlug,
        [string]$ExplicitPath
    )
    $path = if ($ExplicitPath) { $ExplicitPath } else { Join-Path $script:ConfigsDir "$ToolSlug.json" }
    if (-not (Test-Path $path)) {
        throw "Config file not found: $path"
    }
    $json = Get-Content $path -Raw | ConvertFrom-Json

    # Required fields
    foreach ($field in @("toolSlug", "toolName", "executable", "parentMenu", "menuItems")) {
        if (-not $json.$field) { throw "Config $path is missing required field: $field" }
    }
    foreach ($field in @("title", "tooltip")) {
        if (-not $json.parentMenu.$field) { throw "Config $path parentMenu is missing: $field" }
    }
    if ($json.menuItems.Count -lt 1) { throw "Config $path must define at least one menuItem" }
    foreach ($item in $json.menuItems) {
        foreach ($field in @("title", "tooltip")) {
            if (-not $item.$field) { throw "Config $path menuItem is missing: $field" }
        }
        if ($null -eq $item.args) { throw "Config $path menuItem is missing 'args' (use empty string for no args)" }
    }
    return $json
}

# ─── Executable resolution ────────────────────────────────────────────────
function Resolve-ToolExecutable {
    param(
        $Config,
        [string]$Override
    )
    if ($Override) {
        if (-not (Test-Path $Override)) { throw "ExecutablePath override not found: $Override" }
        return [IO.Path]::GetFullPath($Override)
    }
    $exe = $Config.executable
    if ([IO.Path]::IsPathRooted($exe)) {
        if (-not (Test-Path $exe)) { throw "Config executable path not found: $exe" }
        return [IO.Path]::GetFullPath($exe)
    }
    # Try PATH
    $cmd = Get-Command $exe -ErrorAction SilentlyContinue
    if ($cmd) { return [IO.Path]::GetFullPath($cmd.Source) }
    # Try ~/.local/bin
    $fallback = Join-Path $env:USERPROFILE ".local\bin\$exe"
    if (Test-Path $fallback) { return [IO.Path]::GetFullPath($fallback) }
    throw "Could not locate executable '$exe'. Install it, add to PATH, or pass -ExecutablePath."
}

# ─── Derived path/name helpers ────────────────────────────────────────────
function ConvertTo-PascalCase {
    param([string]$Slug)
    ($Slug -split '-' | ForEach-Object {
        if ($_.Length -gt 0) { $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower() }
    }) -join ''
}

function Resolve-ToolPaths {
    param($Config, [string]$ResolvedExePath)

    $slug = $Config.toolSlug
    $pascal = ConvertTo-PascalCase -Slug $slug

    # GUID: config override or UUIDv5 derivation
    $guid = if ($Config.guid) { $Config.guid.ToUpper() } else { Get-UuidV5 -NamespaceUuid $script:ProjectNamespaceUuid -Name $slug }

    $packageName = if ($Config.packageName) { $Config.packageName } else { "AIToolContextMenu.$pascal" }
    $publisher   = if ($Config.publisher)   { $Config.publisher }   else { "CN=AIToolContextMenuDev" }

    return [PSCustomObject]@{
        Slug          = $slug
        Name          = $Config.toolName
        Pascal        = $pascal
        ExePath       = $ResolvedExePath
        Guid          = $guid
        PackageName   = $packageName
        Publisher     = $publisher
        InstallDir    = Join-Path $env:ProgramFiles "AIToolContextMenu\$slug"
        ShellVerbId   = "${pascal}CLI"
        ShellKey      = "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\${pascal}CLI"
        ClsidKey      = "Registry::HKEY_CLASSES_ROOT\CLSID\{$guid}"
        CertFriendly  = "$($Config.toolName) Context Menu Dev Cert"
    }
}
```

- [ ] **Step 2: Verify each helper against the Claude Code config**

```bash
powershell -Command @"
. .\install.ps1
`$cfg = Read-ToolConfig -ToolSlug claude-code
Write-Host ('toolName: ' + `$cfg.toolName)
Write-Host ('menuItems: ' + `$cfg.menuItems.Count)
`$exe = Resolve-ToolExecutable -Config `$cfg
Write-Host ('exe: ' + `$exe)
`$paths = Resolve-ToolPaths -Config `$cfg -ResolvedExePath `$exe
Write-Host ('guid: ' + `$paths.Guid)
Write-Host ('installDir: ' + `$paths.InstallDir)
Write-Host ('packageName: ' + `$paths.PackageName)
Write-Host ('shellVerbId: ' + `$paths.ShellVerbId)
"@
```

Expected output (paths/exe may differ):
```
toolName: Claude Code
menuItems: 3
exe: C:\Users\wrigh\.local\bin\claude.exe   (or wherever claude.exe lives)
guid: E3C26D71-5A2F-4B89-9C7E-A1D3F6B84E52
installDir: C:\Program Files\AIToolContextMenu\claude-code
packageName: ClaudeCode.ContextMenu
shellVerbId: ClaudeCodeCLI
```

If the GUID is **not** `E3C26D71-...`: the config override path is broken. Fix before proceeding — backward compat depends on it.

- [ ] **Step 3: Verify `Resolve-ToolPaths` derives a GUID for Codex (no config override)**

```bash
powershell -Command @"
. .\install.ps1
`$cfg = Read-ToolConfig -ToolSlug codex
`$paths = Resolve-ToolPaths -Config `$cfg -ResolvedExePath 'C:\dummy\codex.exe'
Write-Host ('codex guid: ' + `$paths.Guid)
Write-Host ('codex packageName: ' + `$paths.PackageName)
"@
```

Expected:
```
codex guid: <some derived GUID, same every run>
codex packageName: AIToolContextMenu.Codex
```

Run it twice to confirm the GUID is deterministic. Record the value — we'll use it later to verify no collision with the Claude Code GUID.

- [ ] **Step 4: Commit**

```bash
git add install.ps1
git commit -m "Add config loader, exe resolver, and path derivation helpers

Read-ToolConfig validates required fields. Resolve-ToolExecutable
priority: -ExecutablePath > absolute in config > PATH > ~/.local/bin.
Resolve-ToolPaths derives CLSID via UUIDv5 when not overridden in
config, and computes all per-tool install paths, registry keys, and
AppX identifiers.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Header generator and build invocation

**Files:**
- Modify: `install.ps1` (append helpers)

- [ ] **Step 1: Add `Write-ToolConfigHeader` and `Build-ToolDll` functions**

Insert after `Resolve-ToolPaths`:

```powershell
# ─── C header generation ─────────────────────────────────────────────────
function ConvertTo-CEscapedWString {
    param([string]$S)
    if ($null -eq $S) { return '' }
    $escaped = $S.Replace('\', '\\').Replace('"', '\"')
    return $escaped
}

function Format-GuidAsCInitializer {
    param([string]$GuidString)
    $g = [Guid]::Parse($GuidString)
    $b = $g.ToByteArray()
    # .NET Guid byte order: first 4 LE, next 2 LE, next 2 LE, last 8 as-is.
    # We want the canonical 11-field C initializer:
    #   { 0xDATA1, 0xDATA2, 0xDATA3, {0xDATA4[0..7]} }
    $data1 = [BitConverter]::ToUInt32($b, 0)
    $data2 = [BitConverter]::ToUInt16($b, 4)
    $data3 = [BitConverter]::ToUInt16($b, 6)
    $data4 = ($b[8..15] | ForEach-Object { '0x{0:X2}' -f $_ }) -join ', '
    return ('{{ 0x{0:X8}, 0x{1:X4}, 0x{2:X4}, {{{3}}} }}' -f $data1, $data2, $data3, $data4)
}

function Write-ToolConfigHeader {
    param($Config, $Paths)

    $exeEscaped     = ConvertTo-CEscapedWString -S $Paths.ExePath
    $parentTitle    = ConvertTo-CEscapedWString -S $Config.parentMenu.title
    $parentTooltip  = ConvertTo-CEscapedWString -S $Config.parentMenu.tooltip
    $guidInitializer = Format-GuidAsCInitializer -GuidString $Paths.Guid

    $itemLines = @()
    foreach ($item in $Config.menuItems) {
        $t = ConvertTo-CEscapedWString -S $item.title
        $tt = ConvertTo-CEscapedWString -S $item.tooltip
        $args = ConvertTo-CEscapedWString -S $item.args
        $argsLiteral = if ([string]::IsNullOrEmpty($args)) { 'NULL' } else { "L`"$args`"" }
        $itemLines += "    { L`"$t`", L`"$tt`", $argsLiteral },"
    }
    $itemBlock = $itemLines -join "`n"

    $content = @"
/* Auto-generated by install.ps1 — do not edit */
#ifndef TOOL_CONFIG_H
#define TOOL_CONFIG_H

#define TOOL_EXE_PATH       L"$exeEscaped"
#define TOOL_PARENT_TITLE   L"$parentTitle"
#define TOOL_PARENT_TOOLTIP L"$parentTooltip"

static const GUID CLSID_Tool = $guidInitializer;

typedef struct {
    const wchar_t *title;
    const wchar_t *tooltip;
    const wchar_t *args;
} MenuItemDef;

static const MenuItemDef g_menuItems[] = {
$itemBlock
};
#define NUM_MENU_ITEMS (sizeof(g_menuItems) / sizeof(g_menuItems[0]))

#endif /* TOOL_CONFIG_H */
"@

    $headerPath = Join-Path $script:SrcDir "tool_config.h"
    [IO.File]::WriteAllText($headerPath, $content)
    Write-Host "  Generated tool_config.h" -ForegroundColor Green
}

# ─── Build ────────────────────────────────────────────────────────────────
function Build-ToolDll {
    $buildBat = Join-Path $script:SrcDir "build.bat"
    $dllPath  = Join-Path $script:SrcDir "AIToolContextMenu.dll"
    if (Test-Path $dllPath) { Remove-Item $dllPath -Force }

    Write-Host "Building native COM DLL..." -ForegroundColor Cyan
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $buildOut = cmd /c "`"$buildBat`"" 2>&1
    $ErrorActionPreference = $prevEAP

    if (-not (Test-Path $dllPath)) {
        $buildOut | Write-Host
        throw "Build failed. Ensure Visual Studio C++ desktop workload is installed."
    }
    Write-Host "  Build succeeded." -ForegroundColor Green
    return $dllPath
}
```

- [ ] **Step 2: Verify header generation for Claude Code**

```bash
powershell -Command @"
. .\install.ps1
`$cfg = Read-ToolConfig -ToolSlug claude-code
`$exe = Resolve-ToolExecutable -Config `$cfg
`$paths = Resolve-ToolPaths -Config `$cfg -ResolvedExePath `$exe
Write-ToolConfigHeader -Config `$cfg -Paths `$paths
Write-Host '---'
Get-Content src/tool_config.h
"@
```

Expected: file is written and its contents include the correct exe path, three menu items, and the CLSID `{ 0xE3C26D71, 0x5A2F, 0x4B89, {0x9C, 0x7E, 0xA1, 0xD3, 0xF6, 0xB8, 0x4E, 0x52} }`.

If the GUID initializer bytes look wrong (e.g., scrambled order): the `Format-GuidAsCInitializer` byte handling is wrong. `[BitConverter]::ToUInt32/16` already reads little-endian from the Guid byte array, so the output should match — but if you see `0x712DC2E3` instead of `0xE3C26D71`, you have a byte-order bug.

- [ ] **Step 3: Build the DLL using the generated header**

```bash
powershell -Command ". .\install.ps1; Build-ToolDll"
```

Expected: `Build succeeded.` and `src\AIToolContextMenu.dll` exists.

- [ ] **Step 4: Clean build artifacts, restore committed dev stub header**

```bash
cd "C:/Users/wrigh/OneDrive/Documents/GitHub/ClaudeCodeContextMenu"
rm -f src/AIToolContextMenu.dll src/AIToolContextMenu.obj src/AIToolContextMenu.exp src/AIToolContextMenu.lib
git checkout src/tool_config.h
```

- [ ] **Step 5: Commit**

```bash
git add install.ps1
git commit -m "Add tool_config.h generator and build invocation

Write-ToolConfigHeader renders the per-tool C header with C-escaped
strings and a proper GUID C initializer. Build-ToolDll runs build.bat
and returns the DLL path, or throws with compiler output on failure.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Artifact install + COM registration + AppxManifest generation

**Files:**
- Modify: `install.ps1` (append helpers)

- [ ] **Step 1: Add `Install-ToolArtifacts`, `Register-ToolComClass`, and `Write-AppxManifest` functions**

Insert after `Build-ToolDll`:

```powershell
# ─── Artifact install ─────────────────────────────────────────────────────
function Install-ToolArtifacts {
    param($Paths, [string]$DllSrcPath)

    if (-not (Test-Path $Paths.InstallDir)) {
        New-Item -ItemType Directory -Path $Paths.InstallDir -Force | Out-Null
    }

    # If the destination DLL is already there and possibly loaded by explorer,
    # rename it out of the way so we can write a fresh copy. Renaming a locked
    # DLL works on NTFS because MoveFile updates the directory entry while the
    # existing open handle keeps pointing at the underlying file blob.
    #
    # The naive approach (stop explorer + sleep + Copy-Item) does NOT work on
    # Windows 11: explorer auto-restarts within ~1 second and re-locks the DLL
    # before Copy-Item can complete. Rename-then-replace sidesteps the race.
    $dllDest = Join-Path $Paths.InstallDir "AIToolContextMenu.dll"
    if (Test-Path $dllDest) {
        $stale = "$dllDest.$([Guid]::NewGuid().ToString('N')).stale"
        try {
            Move-Item -Path $dllDest -Destination $stale -Force -ErrorAction Stop
        } catch {
            Write-Host "  DLL locked and rename failed. Restarting Explorer..." -ForegroundColor Yellow
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            try { Move-Item -Path $dllDest -Destination $stale -Force -ErrorAction Stop } catch {
                throw "Could not displace locked DLL at $dllDest — close File Explorer windows and retry."
            }
        }
    }

    # Clean up any prior .stale files best-effort (explorer may have released them by now)
    Get-ChildItem -Path $Paths.InstallDir -Filter "AIToolContextMenu.dll.*.stale" -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { Remove-Item -Path $_.FullName -Force -ErrorAction Stop } catch {}
        }

    Copy-Item $DllSrcPath $Paths.InstallDir -Force
    Write-Host "  Copied DLL to $($Paths.InstallDir)" -ForegroundColor Green

    # Placeholder logo
    $logo = Join-Path $Paths.InstallDir "logo.png"
    if (-not (Test-Path $logo)) {
        Add-Type -AssemblyName System.Drawing
        $bmp = New-Object System.Drawing.Bitmap(44, 44)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.Dispose()
        $bmp.Save($logo, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }

    # Stub exe (AppX manifest requires an .exe)
    $stub = Join-Path $Paths.InstallDir "Stub.exe"
    if (-not (Test-Path $stub)) {
        $fwDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
        $csc = Join-Path $fwDir "csc.exe"
        $stubSrc = Join-Path $env:TEMP "stub.cs"
        Set-Content -Path $stubSrc -Value "class S{static void Main(){}}"
        & $csc /nologo /target:exe /out:$stub $stubSrc 2>&1 | Out-Null
        Remove-Item $stubSrc -Force
    }
}

# ─── COM registration ─────────────────────────────────────────────────────
function Register-ToolComClass {
    param($Paths)
    Write-Host "Registering COM class..." -ForegroundColor Cyan
    New-Item -Path "$($Paths.ClsidKey)\InprocServer32" -Force | Out-Null
    Set-ItemProperty -Path $Paths.ClsidKey -Name "(Default)" -Value "$($Paths.Pascal)Command"
    Set-ItemProperty -Path "$($Paths.ClsidKey)\InprocServer32" -Name "(Default)" -Value (Join-Path $Paths.InstallDir "AIToolContextMenu.dll")
    Set-ItemProperty -Path "$($Paths.ClsidKey)\InprocServer32" -Name "ThreadingModel" -Value "Both"
    Write-Host "  Registered CLSID {$($Paths.Guid)}" -ForegroundColor Green
}

# ─── AppxManifest.xml generation ──────────────────────────────────────────
function Write-AppxManifest {
    param($Config, $Paths)
    $manifestPath = Join-Path $Paths.InstallDir "AppxManifest.xml"
    $displayName = [Security.SecurityElement]::Escape($Config.toolName)
    $description = [Security.SecurityElement]::Escape("$($Config.toolName) Context Menu")

    $content = @"
<?xml version="1.0" encoding="utf-8"?>
<Package
  xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:uap10="http://schemas.microsoft.com/appx/manifest/uap/windows10/10"
  xmlns:com="http://schemas.microsoft.com/appx/manifest/com/windows10"
  xmlns:desktop4="http://schemas.microsoft.com/appx/manifest/desktop/windows10/4"
  xmlns:desktop5="http://schemas.microsoft.com/appx/manifest/desktop/windows10/5"
  xmlns:desktop6="http://schemas.microsoft.com/appx/manifest/desktop/windows10/6"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
  IgnorableNamespaces="uap uap10 com desktop4 desktop5 desktop6 rescap">

  <Identity Name="$($Paths.PackageName)"
            Publisher="$($Paths.Publisher)"
            Version="1.0.0.0"
            ProcessorArchitecture="x64" />

  <Properties>
    <DisplayName>$displayName Context Menu</DisplayName>
    <PublisherDisplayName>$displayName</PublisherDisplayName>
    <Logo>logo.png</Logo>
    <uap10:AllowExternalContent>true</uap10:AllowExternalContent>
    <desktop6:RegistryWriteVirtualization>disabled</desktop6:RegistryWriteVirtualization>
    <desktop6:FileSystemWriteVirtualization>disabled</desktop6:FileSystemWriteVirtualization>
  </Properties>

  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop"
                        MinVersion="10.0.19041.0"
                        MaxVersionTested="10.0.26100.0" />
  </Dependencies>

  <Resources>
    <Resource Language="en-us" />
  </Resources>

  <Applications>
    <Application Id="App"
                 Executable="Stub.exe"
                 uap10:TrustLevel="mediumIL"
                 uap10:RuntimeBehavior="win32App">
      <uap:VisualElements
        DisplayName="$displayName"
        Description="$description"
        BackgroundColor="transparent"
        Square150x150Logo="logo.png"
        Square44x44Logo="logo.png"
        AppListEntry="none" />
      <Extensions>
        <desktop4:Extension Category="windows.fileExplorerContextMenus">
          <desktop4:FileExplorerContextMenus>
            <desktop5:ItemType Type="Directory\Background">
              <desktop5:Verb Id="$($Paths.ShellVerbId)" Clsid="$($Paths.Guid)" />
            </desktop5:ItemType>
          </desktop4:FileExplorerContextMenus>
        </desktop4:Extension>
        <com:Extension Category="windows.comServer">
          <com:ComServer>
            <com:SurrogateServer DisplayName="$displayName Context Menu Handler">
              <com:Class Id="$($Paths.Guid)"
                         Path="AIToolContextMenu.dll"
                         ThreadingModel="Both" />
            </com:SurrogateServer>
          </com:ComServer>
        </com:Extension>
      </Extensions>
    </Application>
  </Applications>

  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
    <rescap:Capability Name="unvirtualizedResources" />
  </Capabilities>
</Package>
"@

    [IO.File]::WriteAllText($manifestPath, $content, [Text.Encoding]::UTF8)
    Write-Host "  Generated AppxManifest.xml" -ForegroundColor Green
}
```

- [ ] **Step 2: Verify `Write-AppxManifest` produces valid XML**

```bash
powershell -Command @"
. .\install.ps1
`$cfg = Read-ToolConfig -ToolSlug claude-code
`$exe = Resolve-ToolExecutable -Config `$cfg
`$paths = Resolve-ToolPaths -Config `$cfg -ResolvedExePath `$exe
# Temporarily use a test dir instead of ProgramFiles
`$paths.InstallDir = Join-Path `$env:TEMP 'ai-tool-test'
if (-not (Test-Path `$paths.InstallDir)) { New-Item -ItemType Directory -Path `$paths.InstallDir | Out-Null }
Write-AppxManifest -Config `$cfg -Paths `$paths
[xml]`$x = Get-Content (Join-Path `$paths.InstallDir 'AppxManifest.xml')
Write-Host ('identity: ' + `$x.Package.Identity.Name)
Write-Host ('verb: ' + `$x.Package.Applications.Application.Extensions.Extension[0].FileExplorerContextMenus.ItemType.Verb.Id)
Remove-Item `$paths.InstallDir -Recurse -Force
"@
```

Expected:
```
identity: ClaudeCode.ContextMenu
verb: ClaudeCodeCLI
```

If `[xml]$x = ...` throws, the manifest has an XML validity error — inspect the generated file directly.

- [ ] **Step 3: Commit**

```bash
git add install.ps1
git commit -m "Add artifact installer, COM registration, and manifest generator

Install-ToolArtifacts copies the DLL plus a placeholder logo and csc-
compiled stub exe to the per-tool install directory, restarting
explorer if the destination DLL is locked. Register-ToolComClass
writes HKCR\CLSID entries. Write-AppxManifest emits a per-tool
AppxManifest.xml with tool-specific identity, verb, and display name.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Certificate handling + MSIX pack/sign/register

**Files:**
- Modify: `install.ps1` (append helpers)

- [ ] **Step 1: Add `Find-SdkBin`, `Ensure-SigningCert`, and `Pack-AndRegisterMsix` functions**

Insert after `Write-AppxManifest`:

```powershell
# ─── SDK tool lookup ──────────────────────────────────────────────────────
function Find-SdkBin {
    $kitsRoot = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots" -ErrorAction SilentlyContinue).KitsRoot10
    if (-not $kitsRoot) { throw "Windows SDK not found. Install the Windows 10/11 SDK." }
    $ver = Get-ChildItem (Join-Path $kitsRoot "bin") -Directory |
        Where-Object { $_.Name -match '^\d+\.' } |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $ver) { throw "No SDK version found under $kitsRoot\bin" }
    return Join-Path $kitsRoot "bin\$($ver.Name)\x64"
}

# ─── Signing cert ─────────────────────────────────────────────────────────
function Ensure-SigningCert {
    param($Paths)
    Write-Host "Setting up signing certificate..." -ForegroundColor Cyan
    $cert = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $Paths.Publisher -and $_.FriendlyName -eq $Paths.CertFriendly } |
        Select-Object -First 1

    if (-not $cert) {
        $cert = New-SelfSignedCertificate `
            -Type Custom -Subject $Paths.Publisher `
            -KeyUsage DigitalSignature `
            -FriendlyName $Paths.CertFriendly `
            -CertStoreLocation "Cert:\CurrentUser\My" `
            -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
        Write-Host "  Created signing certificate." -ForegroundColor Green
    } else {
        Write-Host "  Reusing existing certificate." -ForegroundColor Green
    }

    $trusted = Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
    if (-not $trusted) {
        $tmpCer = Join-Path $env:TEMP "$($Paths.Slug)_dev.cer"
        Export-Certificate -Cert $cert -FilePath $tmpCer | Out-Null
        Import-Certificate -FilePath $tmpCer -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null
        Remove-Item $tmpCer -Force
        Write-Host "  Certificate trusted." -ForegroundColor Green
    }
    return $cert
}

# ─── Pack, sign, register ─────────────────────────────────────────────────
function Pack-AndRegisterMsix {
    param($Paths, $Cert)

    $sdkBin   = Find-SdkBin
    $makeAppx = Join-Path $sdkBin "makeappx.exe"
    $signTool = Join-Path $sdkBin "signtool.exe"
    foreach ($tool in @($makeAppx, $signTool)) {
        if (-not (Test-Path $tool)) { throw "Missing SDK tool: $tool" }
    }

    $existing = Get-AppxPackage -Name $Paths.PackageName -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-AppxPackage $existing
        Write-Host "  Removed previous package." -ForegroundColor Green
    }

    Write-Host "Creating MSIX package..." -ForegroundColor Cyan
    $msixPath = Join-Path $env:TEMP "$($Paths.Slug).msix"
    if (Test-Path $msixPath) { Remove-Item $msixPath -Force }

    $packArgs = @("pack", "/d", "`"$($Paths.InstallDir)`"", "/p", "`"$msixPath`"", "/nv", "/o")
    $packResult = & $makeAppx @packArgs 2>&1
    if ($LASTEXITCODE -ne 0) { $packResult | Write-Host; throw "MakeAppx failed." }
    Write-Host "  Package created." -ForegroundColor Green

    $signResult = & $signTool sign /fd SHA256 /a /sha1 $Cert.Thumbprint "`"$msixPath`"" 2>&1
    if ($LASTEXITCODE -ne 0) { $signResult | Write-Host; throw "SignTool failed." }
    Write-Host "  Package signed." -ForegroundColor Green

    Write-Host "Registering sparse AppX package..." -ForegroundColor Cyan
    Add-AppxPackage -Path $msixPath -ExternalLocation $Paths.InstallDir
    Write-Host "  Package registered." -ForegroundColor Green
}
```

- [ ] **Step 2: Syntax-check by dot-sourcing**

```bash
powershell -Command ". .\install.ps1; Write-Host 'parsed ok'"
```

Expected: `parsed ok`. If you get a parser error, fix before moving on — a syntax error blocks all downstream tasks.

- [ ] **Step 3: Commit**

```bash
git add install.ps1
git commit -m "Add cert handling and MSIX pack/sign/register helpers

Ensure-SigningCert creates a per-publisher self-signed cert with a
friendly name scoped to the tool, and trusts it in LocalMachine\
TrustedPeople. Pack-AndRegisterMsix removes any previous package with
the same name, packs to TEMP, signs, and registers as a sparse
package with external location.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Install orchestration + legacy Claude Code sweep

**Files:**
- Modify: `install.ps1` (add `Install-Tool` + `Invoke-LegacyClaudeSweep`, wire into `Invoke-Main`)

- [ ] **Step 1: Add `Invoke-LegacyClaudeSweep` and `Install-Tool` functions**

Insert after `Pack-AndRegisterMsix`:

```powershell
# ─── Legacy backward-compat sweep (Claude Code only) ─────────────────────
function Invoke-LegacyClaudeSweep {
    $legacyDir     = Join-Path $env:ProgramFiles "ClaudeCodeContextMenu"
    $legacyShell   = "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\ClaudeCodeCLI"
    $legacyPkgName = "ClaudeCode.ContextMenu"
    $swept = $false

    $existingPkg = Get-AppxPackage -Name $legacyPkgName -ErrorAction SilentlyContinue
    if ($existingPkg -and $existingPkg.InstallLocation -like "$legacyDir*") {
        Remove-AppxPackage $existingPkg
        Write-Host "  Removed legacy AppX package at $legacyDir" -ForegroundColor Yellow
        $swept = $true
    }
    if (Test-Path $legacyShell) {
        Remove-Item $legacyShell -Recurse -Force
        Write-Host "  Removed legacy shell key" -ForegroundColor Yellow
        $swept = $true
    }
    if (Test-Path $legacyDir) {
        try {
            Remove-Item $legacyDir -Recurse -Force
            Write-Host "  Removed legacy install dir $legacyDir" -ForegroundColor Yellow
            $swept = $true
        } catch {
            Write-Host "  Could not remove $legacyDir (may be explorer-locked). Continuing." -ForegroundColor Yellow
        }
    }
    if ($swept) {
        Write-Host "  Legacy Claude Code install cleaned up." -ForegroundColor Green
    }
}

# ─── Full install pipeline for one tool ──────────────────────────────────
function Install-Tool {
    param([string]$Slug, [string]$ConfigPath, [string]$ExePathOverride)

    Write-Host ""
    Write-Host "═══ Installing $Slug ═══" -ForegroundColor Cyan

    $cfg   = Read-ToolConfig -ToolSlug $Slug -ExplicitPath $ConfigPath
    $exe   = Resolve-ToolExecutable -Config $cfg -Override $ExePathOverride
    $paths = Resolve-ToolPaths -Config $cfg -ResolvedExePath $exe
    Write-Host "Tool:       $($paths.Name)" -ForegroundColor Cyan
    Write-Host "Executable: $($paths.ExePath)" -ForegroundColor Cyan
    Write-Host "CLSID:      {$($paths.Guid)}" -ForegroundColor Cyan
    Write-Host "Install:    $($paths.InstallDir)" -ForegroundColor Cyan

    Write-ToolConfigHeader -Config $cfg -Paths $paths
    $dllSrc = Build-ToolDll
    Install-ToolArtifacts -Paths $paths -DllSrcPath $dllSrc
    Register-ToolComClass -Paths $paths
    Write-AppxManifest -Config $cfg -Paths $paths
    $cert = Ensure-SigningCert -Paths $paths
    Pack-AndRegisterMsix -Paths $paths -Cert $cert

    # Legacy sweep runs AFTER the new install is fully registered. This avoids
    # a window where the legacy CLSID {E3C26D71-...} would point at a deleted
    # DLL path during an in-place upgrade. By the time the sweep runs, both
    # Register-ToolComClass and the new AppX manifest have already pointed the
    # CLSID at the new DLL, so removing the legacy artifacts is safe.
    if ($Slug -eq "claude-code") { Invoke-LegacyClaudeSweep }

    Write-Host "  $Slug installed." -ForegroundColor Green
}
```

- [ ] **Step 2: Wire `Install-Tool` into `Invoke-Main`**

Replace the existing `Invoke-Main` function body with:

```powershell
function Invoke-Main {
    # Enforce elevation here (not via #Requires) so dot-sourcing for unit tests works
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "install.ps1 must be run from an elevated PowerShell session (Run as Administrator)."
    }

    if ($ToolName) {
        if ($Uninstall) {
            Write-Host "Uninstall pipeline — not yet implemented" -ForegroundColor Yellow
            return
        }
        Install-Tool -Slug $ToolName -ConfigPath $ConfigFile -ExePathOverride $ExecutablePath
        Write-Host ""
        Write-Host "Restarting Explorer..." -ForegroundColor Cyan
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Start-Process explorer.exe
        Write-Host "Done. Right-click inside any folder to see the tool's submenu." -ForegroundColor Green
    } else {
        Write-Host "Interactive mode — not yet implemented" -ForegroundColor Yellow
    }
}
```

- [ ] **Step 3: Full install smoke test for Claude Code**

Open a NEW elevated PowerShell window and run:

```powershell
cd "C:\Users\wrigh\OneDrive\Documents\GitHub\ClaudeCodeContextMenu"
.\install.ps1 -ToolName claude-code
```

Expected:
- Header generated, DLL built, copied to `C:\Program Files\AIToolContextMenu\claude-code\`
- CLSID `{E3C26D71-...}` registered
- Legacy sweep either reports "cleaned up" or is silent (if no legacy install)
- AppxManifest generated, MSIX packed, signed, registered
- Explorer restarts
- Right-click in any folder → see "Claude Code" submenu with 3 items
- Click "Open (Default)" → claude.exe launches in that folder

If any step fails: read the error, fix, commit the fix, rerun. Do NOT skip validation.

- [ ] **Step 4: Clean the dev-stub header back to committed state**

```bash
cd "C:/Users/wrigh/OneDrive/Documents/GitHub/ClaudeCodeContextMenu"
git checkout src/tool_config.h
```

- [ ] **Step 5: Commit**

```bash
git add install.ps1
git commit -m "Wire up Install-Tool orchestration + legacy Claude sweep

Install-Tool runs the full pipeline for one tool: load config, resolve
paths, generate header, build, install artifacts, register COM, write
manifest, sign, and register as sparse MSIX. Invoke-LegacyClaudeSweep
removes pre-refactor Claude Code artifacts (old install dir, shell
key, AppX package) when installing the claude-code config, preserving
backward compat for existing users because claude-code.json pins the
legacy CLSID.

Manually verified: .\install.ps1 -ToolName claude-code produces a
working 'Claude Code' submenu with all three items launching claude.exe.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Uninstall pipeline

**Files:**
- Modify: `install.ps1` (add `Uninstall-Tool`, wire into `Invoke-Main`)

- [ ] **Step 1: Add `Uninstall-Tool` function**

Insert after `Install-Tool`:

```powershell
# ─── Uninstall pipeline for one tool ─────────────────────────────────────
function Uninstall-Tool {
    param([string]$Slug, [string]$ConfigPath)

    Write-Host ""
    Write-Host "═══ Uninstalling $Slug ═══" -ForegroundColor Cyan

    $cfg = Read-ToolConfig -ToolSlug $Slug -ExplicitPath $ConfigPath
    # Uninstall doesn't need a real exe path — pass a placeholder so Resolve-ToolPaths works
    $paths = Resolve-ToolPaths -Config $cfg -ResolvedExePath "placeholder"

    $pkg = Get-AppxPackage -Name $paths.PackageName -ErrorAction SilentlyContinue
    if ($pkg) {
        Remove-AppxPackage $pkg
        Write-Host "  Removed AppX package $($paths.PackageName)" -ForegroundColor Green
    }

    if (Test-Path $paths.ShellKey) {
        Remove-Item $paths.ShellKey -Recurse -Force
        Write-Host "  Removed shell key" -ForegroundColor Green
    }

    if (Test-Path $paths.ClsidKey) {
        Remove-Item $paths.ClsidKey -Recurse -Force
        Write-Host "  Removed CLSID registration" -ForegroundColor Green
    }

    if (Test-Path $paths.InstallDir) {
        try {
            Remove-Item $paths.InstallDir -Recurse -Force
            Write-Host "  Removed install dir" -ForegroundColor Green
        } catch {
            Write-Host "  Install dir locked — restarting Explorer and retrying" -ForegroundColor Yellow
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Remove-Item $paths.InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Only remove the signing cert if no other installed tool still uses this publisher
    $stillInUse = $false
    $siblingFiles = Get-ChildItem $script:ConfigsDir -Filter "*.json" -ErrorAction SilentlyContinue
    foreach ($sibling in $siblingFiles) {
        if ($sibling.BaseName -eq $Slug) { continue }
        try {
            $other = Get-Content $sibling.FullName -Raw | ConvertFrom-Json
            $otherPub = if ($other.publisher) { $other.publisher } else { "CN=AIToolContextMenuDev" }
            if ($otherPub -eq $paths.Publisher) {
                $otherPkgName = if ($other.packageName) { $other.packageName } else { "AIToolContextMenu." + (ConvertTo-PascalCase -Slug $other.toolSlug) }
                if (Get-AppxPackage -Name $otherPkgName -ErrorAction SilentlyContinue) {
                    $stillInUse = $true
                    break
                }
            }
        } catch { }
    }
    if (-not $stillInUse) {
        foreach ($store in @("Cert:\CurrentUser\My", "Cert:\LocalMachine\TrustedPeople")) {
            Get-ChildItem $store -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq $paths.CertFriendly } |
                ForEach-Object { Remove-Item $_.PSPath -Force; Write-Host "  Removed cert from $store" -ForegroundColor Green }
        }
    }

    Write-Host "  $Slug uninstalled." -ForegroundColor Green
}
```

- [ ] **Step 2: Wire `Uninstall-Tool` into `Invoke-Main`**

Replace the `Uninstall` branch inside `Invoke-Main` with:

```powershell
        if ($Uninstall) {
            Uninstall-Tool -Slug $ToolName -ConfigPath $ConfigFile
            Write-Host ""
            Write-Host "Restarting Explorer..." -ForegroundColor Cyan
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Start-Process explorer.exe
            Write-Host "Done." -ForegroundColor Green
            return
        }
```

- [ ] **Step 3: Smoke test uninstall**

In an elevated PowerShell:

```powershell
cd "C:\Users\wrigh\OneDrive\Documents\GitHub\ClaudeCodeContextMenu"
.\install.ps1 -ToolName claude-code -Uninstall
```

Expected:
- AppX package removed
- Shell key removed
- CLSID removed
- Install dir `C:\Program Files\AIToolContextMenu\claude-code\` deleted
- Cert removed (no other tool uses `CN=ClaudeCodeDev`)
- Explorer restarts, "Claude Code" submenu is gone

- [ ] **Step 4: Commit**

```bash
git add install.ps1
git commit -m "Add Uninstall-Tool pipeline with shared-cert guard

Uninstall-Tool removes the AppX package, shell key, CLSID, install
dir, and — if no other installed tool shares the publisher — the
signing cert. The shared-cert guard scans sibling configs to avoid
orphaning a tool that depends on the same publisher identity.

Manually verified: install then uninstall of claude-code leaves no
registry or filesystem residue.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Interactive prompt for install and uninstall

**Files:**
- Modify: `install.ps1` (add `Get-AvailableConfigs`, `Show-InteractivePrompt`, wire into `Invoke-Main`)

- [ ] **Step 1: Add `Get-AvailableConfigs` and `Show-InteractivePrompt`**

Insert after `Uninstall-Tool`:

```powershell
# ─── Interactive discovery and prompt ─────────────────────────────────────
function Get-AvailableConfigs {
    if (-not (Test-Path $script:ConfigsDir)) {
        throw "No configs directory at $script:ConfigsDir"
    }
    $files = Get-ChildItem $script:ConfigsDir -Filter "*.json" -ErrorAction SilentlyContinue
    if (-not $files) {
        throw "No tool configs found in $script:ConfigsDir. See README for how to add one."
    }
    $result = @()
    foreach ($f in $files) {
        try {
            $cfg = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $pkgName = if ($cfg.packageName) { $cfg.packageName } else { "AIToolContextMenu." + (ConvertTo-PascalCase -Slug $cfg.toolSlug) }
            $installed = [bool](Get-AppxPackage -Name $pkgName -ErrorAction SilentlyContinue)
            $result += [PSCustomObject]@{
                Slug      = $cfg.toolSlug
                Name      = $cfg.toolName
                Installed = $installed
            }
        } catch {
            Write-Host "  Skipping invalid config $($f.Name): $_" -ForegroundColor Yellow
        }
    }
    return $result
}

function Show-InteractivePrompt {
    param(
        [Parameter(Mandatory)][array]$Configs,
        [ValidateSet("install", "uninstall")][string]$Mode
    )
    if ($Configs.Count -eq 0) {
        Write-Host "No tools available for $Mode." -ForegroundColor Yellow
        return @()
    }

    $verb = if ($Mode -eq "install") { "install" } else { "uninstall" }
    Write-Host ""
    Write-Host "Available AI tool context menus:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Configs.Count; $i++) {
        $c = $Configs[$i]
        $status = if ($c.Installed) { "(installed)" } else { "(not installed)" }
        $num = $i + 1
        "  [$num] $($c.Name.PadRight(20)) $status" | Write-Host
    }
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Select tools to $verb (comma-separated numbers, 'all', or 'q' to cancel)"
        $choice = $choice.Trim().ToLower()
        if ($choice -eq 'q' -or $choice -eq '') { return @() }
        if ($choice -eq 'all') { return $Configs }

        $selected = @()
        $valid = $true
        foreach ($token in ($choice -split ',')) {
            $token = $token.Trim()
            if ($token -notmatch '^\d+$') { $valid = $false; break }
            $idx = [int]$token - 1
            if ($idx -lt 0 -or $idx -ge $Configs.Count) { $valid = $false; break }
            $selected += $Configs[$idx]
        }
        if ($valid -and $selected.Count -gt 0) { return $selected }
        Write-Host "Invalid selection. Try again." -ForegroundColor Yellow
    }
}
```

- [ ] **Step 2: Update `Invoke-Main` to support interactive mode**

Full replacement for `Invoke-Main`:

```powershell
function Invoke-Main {
    if ($ToolName) {
        if ($Uninstall) {
            Uninstall-Tool -Slug $ToolName -ConfigPath $ConfigFile
        } else {
            Install-Tool -Slug $ToolName -ConfigPath $ConfigFile -ExePathOverride $ExecutablePath
        }
        Write-Host ""
        Write-Host "Restarting Explorer..." -ForegroundColor Cyan
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Start-Process explorer.exe
        Write-Host "Done." -ForegroundColor Green
        return
    }

    # Interactive mode
    $all = Get-AvailableConfigs
    $pool = if ($Uninstall) { $all | Where-Object { $_.Installed } } else { $all }
    if (-not $pool -or $pool.Count -eq 0) {
        $msg = if ($Uninstall) { "No tools are currently installed." } else { "No tool configs found." }
        Write-Host $msg -ForegroundColor Yellow
        return
    }

    $mode = if ($Uninstall) { "uninstall" } else { "install" }
    $selected = Show-InteractivePrompt -Configs $pool -Mode $mode
    if (-not $selected -or $selected.Count -eq 0) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }

    $failures = @()
    foreach ($sel in $selected) {
        try {
            if ($Uninstall) {
                Uninstall-Tool -Slug $sel.Slug
            } else {
                Install-Tool -Slug $sel.Slug -ExePathOverride $ExecutablePath
            }
        } catch {
            Write-Host "  Failed for $($sel.Slug): $_" -ForegroundColor Red
            $failures += $sel.Slug
        }
    }

    Write-Host ""
    Write-Host "Restarting Explorer..." -ForegroundColor Cyan
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Process explorer.exe

    if ($failures.Count -gt 0) {
        Write-Host "Completed with failures: $($failures -join ', ')" -ForegroundColor Yellow
    } else {
        Write-Host "Done." -ForegroundColor Green
    }
}
```

- [ ] **Step 3: Smoke-test the interactive prompt with no side effects**

Dot-source and invoke `Show-InteractivePrompt` directly (safe — doesn't touch the system):

```bash
powershell -Command @"
. .\install.ps1
`$configs = Get-AvailableConfigs
`$configs | Format-Table
"@
```

Expected: table listing both `claude-code` and `codex` with their installed status.

- [ ] **Step 4: Full interactive install test**

Elevated PowerShell:

```powershell
cd "C:\Users\wrigh\OneDrive\Documents\GitHub\ClaudeCodeContextMenu"
.\install.ps1
```

At the prompt, enter `1` (or whichever number is `claude-code`), press enter.

Expected: same behavior as Task 9 Step 3 (Claude Code submenu appears). Then run `.\install.ps1 -Uninstall` and verify the interactive uninstall prompt lists only installed tools.

- [ ] **Step 5: Commit**

```bash
git add install.ps1
git commit -m "Add interactive install/uninstall prompt

Get-AvailableConfigs scans configs/ and checks install status via
AppX package lookup. Show-InteractivePrompt renders a numbered list
and parses comma-separated selections, 'all', or 'q'. Invoke-Main
falls through to interactive mode when -ToolName is absent, handling
per-tool failures without aborting sibling installs.

Manually verified: .\install.ps1 without args prompts correctly and
successfully installs selected tools.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Backward-compat shim

**Files:**
- Modify: `add-claude-context-menu.ps1` (reduce to a forwarder)

- [ ] **Step 1: Replace `add-claude-context-menu.ps1` contents**

Full new file:

```powershell
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Backward-compat shim. Forwards to install.ps1 -ToolName claude-code.
.DESCRIPTION
    This script exists so users with existing scripts or muscle memory
    can continue to run add-claude-context-menu.ps1 and get the same
    behavior they had before the config-driven refactor. New usage
    should call install.ps1 directly.
#>
param(
    [switch]$Uninstall,
    [string]$ClaudePath
)

$forwardArgs = @{ ToolName = "claude-code" }
if ($Uninstall)  { $forwardArgs.Uninstall      = $true }
if ($ClaudePath) { $forwardArgs.ExecutablePath = $ClaudePath }

& (Join-Path $PSScriptRoot "install.ps1") @forwardArgs
```

> **Important:** Use hashtable splatting (`@{ key = value }`) — NOT array splatting (`@("-ToolName", "claude-code")`). Array splatting binds positionally, so the array form would make `-ToolName` the literal value of `$ToolName` inside `install.ps1` and push `claude-code` into the next positional parameter (`$ConfigFile`). This bit us during Task 14 verification.

- [ ] **Step 2: Verify shim dispatches correctly (dry run)**

```bash
powershell -Command ".\add-claude-context-menu.ps1 -ClaudePath 'C:\dummy\claude.exe' -Uninstall -WhatIf 2>&1 | Out-String"
```

Don't worry if `-WhatIf` isn't supported — what we care about is that the shim reaches `install.ps1` with the right args. A better smoke test: temporarily add `Write-Host "forwarding with: $forwardArgs"` inside the shim, run it with `-Uninstall`, verify the output, then remove the Write-Host.

Simpler: manually inspect the shim produces the right args by running:

```bash
powershell -Command "& { param(`$Uninstall, `$ClaudePath) `$forwardArgs = @('-ToolName', 'claude-code'); if (`$Uninstall) { `$forwardArgs += '-Uninstall' }; if (`$ClaudePath) { `$forwardArgs += @('-ExecutablePath', `$ClaudePath) }; `$forwardArgs -join ' ' } -Uninstall -ClaudePath 'C:\dummy.exe'"
```

Expected: `-ToolName claude-code -Uninstall -ExecutablePath C:\dummy.exe`

- [ ] **Step 3: Commit**

```bash
git add add-claude-context-menu.ps1
git commit -m "Reduce add-claude-context-menu.ps1 to backward-compat shim

Forwards to install.ps1 -ToolName claude-code, preserving the legacy
-Uninstall and -ClaudePath parameter surface so existing users'
scripts and muscle memory keep working post-refactor.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace README.md contents**

Full new content:

```markdown
# AI Tool Context Menu for Windows 11

Adds a top-level Windows 11 right-click menu entry for AI coding CLI tools (Claude Code, Codex, or any other CLI you configure). Each tool becomes its own submenu in the modern (not "Show more options") context menu.

![Windows 11 Context Menu](https://img.shields.io/badge/Windows_11-Context_Menu-0078D6?style=flat&logo=windows11)

<img width="519" height="480" alt="image" src="https://github.com/user-attachments/assets/e1abec12-4082-4bab-8406-3d40abf0fc95" />

## Supported tools out of the box

| Tool | Config | Default menu items |
|---|---|---|
| Claude Code | `configs/claude-code.json` | Open (Default), Open (Auto), Open (YOLO) |
| Codex | `configs/codex.json` | Open (Default), Open (Bypass) |

Multiple tools can be installed side-by-side — each gets its own top-level submenu.

> **Auto Mode** (Claude Code, new in March 2026) is the sweet spot — an AI classifier reviews each action before it runs, auto-approving safe operations and blocking risky ones. Requires Claude Code on a Team plan with Sonnet 4.6 or Opus 4.6.
>
> **Warning:** The YOLO option launches Claude Code with all permission checks disabled. Use at your own risk.

## Prerequisites

- **Windows 11** (22H2 or later)
- The CLI tool(s) you want to integrate, installed and available on PATH
- **Visual Studio** with the **C++ desktop development** workload (for compiling the native COM DLL)
- **Windows 10/11 SDK** (for MSIX packaging — typically installed with Visual Studio)

## Install

Run PowerShell **as Administrator** from the repo root:

```powershell
# Interactive — prompts you to pick which tools to install
.\install.ps1

# Non-interactive — install one tool by slug
.\install.ps1 -ToolName claude-code
.\install.ps1 -ToolName codex

# Override the executable location
.\install.ps1 -ToolName codex -ExecutablePath "C:\path\to\codex.exe"
```

The script will:

1. Read `configs\<slug>.json`
2. Resolve the tool's executable (override > config absolute path > PATH > `~/.local/bin` fallback)
3. Generate a per-tool C header and compile a dedicated native COM DLL
4. Create a self-signed certificate and signed sparse MSIX package
5. Register the package and restart Explorer

## Uninstall

```powershell
# Interactive — prompts you to pick which tools to uninstall
.\install.ps1 -Uninstall

# Non-interactive
.\install.ps1 -Uninstall -ToolName codex
```

Removes the AppX package, COM registration, certificate (unless shared with another installed tool), and installed files for the selected tool(s). Other installed tools are untouched.

## Backward compatibility

Users who previously installed via the old `add-claude-context-menu.ps1` can upgrade transparently:

```powershell
# Old script still works — forwards to install.ps1 -ToolName claude-code
.\add-claude-context-menu.ps1
.\add-claude-context-menu.ps1 -Uninstall
.\add-claude-context-menu.ps1 -ClaudePath "C:\path\to\claude.exe"
```

The Claude Code config pins the legacy CLSID (`E3C26D71-5A2F-4B89-9C7E-A1D3F6B84E52`) so existing installs upgrade in place without losing the registered handler.

## Adding a new tool

1. Create `configs\<your-slug>.json`:

   ```json
   {
     "toolSlug": "my-tool",
     "toolName": "My Tool",
     "executable": "my-tool.exe",
     "parentMenu": {
       "title": "My Tool",
       "tooltip": "My Tool options"
     },
     "menuItems": [
       { "title": "Open", "tooltip": "Launch My Tool here", "args": "" }
     ]
   }
   ```

2. Run `.\install.ps1 -ToolName my-tool` (or just `.\install.ps1` and pick it from the prompt).

**Optional fields:**
- `guid` — explicit CLSID. If omitted, derived via UUIDv5 from a fixed project namespace + `toolSlug` (deterministic, never collides with other tools).
- `packageName` — AppX package identifier. Defaults to `AIToolContextMenu.<PascalSlug>`.
- `publisher` — certificate subject. Defaults to `CN=AIToolContextMenuDev`.

## How it works

A native C COM DLL implements [`IExplorerCommand`](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-iexplorercommand) with `ECF_HASSUBCOMMANDS`, returning sub-commands via `IEnumExplorerCommand`. It is registered through a [sparse AppX package](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps) with `desktop5:FileExplorerContextMenus` — the only supported way to add items to Windows 11's modern context menu.

The C source is tool-agnostic: `install.ps1` generates a per-tool `src\tool_config.h` containing the CLSID, exe path, menu titles/tooltips/args, and parent-menu strings, then invokes `build.bat` to produce a dedicated DLL per tool. Each tool gets its own CLSID, install directory, AppX package, and shell verb ID, so multiple tools coexist without interference.

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Update README for tool-agnostic context menu

Documents the multi-tool workflow: interactive install/uninstall, the
config schema for adding new tools, backward compat via the
add-claude-context-menu.ps1 shim, and how the per-tool compilation
model works under the hood.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: End-to-end verification matrix

**Files:** none modified. This task runs the full manual verification plan from spec §10.

All commands run from an **elevated PowerShell** at the repo root:
```powershell
cd "C:\Users\wrigh\OneDrive\Documents\GitHub\ClaudeCodeContextMenu"
```

- [ ] **Verification 1: Clean slate interactive install**

Ensure nothing is installed:
```powershell
.\install.ps1 -Uninstall -ToolName claude-code 2>$null
.\install.ps1 -Uninstall -ToolName codex 2>$null
```

Then run interactive install:
```powershell
.\install.ps1
```

Enter `all` at the prompt. Expected:
- Both tools install without errors
- Right-click in any folder → both "Claude Code" and "Codex" submenus appear
- Each submenu has its own items

- [ ] **Verification 2: Side-by-side invocation**

In any folder, right-click → Claude Code → Open (Default). A cmd window should open running `claude` in that folder. Close it, right-click → Codex → Open (Default). A cmd window should open running `codex` in that folder (or fail cleanly if codex isn't installed — that's expected, the test is that the correct exe is invoked).

- [ ] **Verification 3: CLSID uniqueness**

```powershell
reg query "HKCR\CLSID\{E3C26D71-5A2F-4B89-9C7E-A1D3F6B84E52}" /ve
powershell -Command ". .\install.ps1; `$cfg = Read-ToolConfig -ToolSlug codex; (Resolve-ToolPaths -Config `$cfg -ResolvedExePath placeholder).Guid"
```

The second command prints the derived Codex GUID. It must NOT equal `E3C26D71-5A2F-4B89-9C7E-A1D3F6B84E52`. Query that GUID's CLSID key and confirm it exists too:
```powershell
reg query "HKCR\CLSID\{<derived-codex-guid>}" /ve
```

- [ ] **Verification 4: Isolated uninstall**

```powershell
.\install.ps1 -Uninstall -ToolName codex
```

Expected:
- Codex submenu gone from right-click
- Claude Code submenu still present and functional
- `C:\Program Files\AIToolContextMenu\codex\` gone
- `C:\Program Files\AIToolContextMenu\claude-code\` still present
- `reg query HKCR\CLSID\{<codex-guid>}` → not found
- `reg query HKCR\CLSID\{E3C26D71-...}` → still present

- [ ] **Verification 5: Legacy shim compatibility**

```powershell
.\install.ps1 -Uninstall -ToolName claude-code
.\add-claude-context-menu.ps1
```

Expected: the old script forwards correctly and Claude Code installs exactly as before.

- [ ] **Verification 6: Full uninstall leaves zero residue**

```powershell
.\install.ps1 -Uninstall
```

Select `all`. Then check:
```powershell
Test-Path "C:\Program Files\AIToolContextMenu"                                   # expect: False
Get-AppxPackage -Name "ClaudeCode.ContextMenu"                                    # expect: nothing
Get-AppxPackage -Name "AIToolContextMenu.Codex"                                   # expect: nothing
reg query "HKCR\Directory\Background\shell\ClaudeCodeCLI" 2>$null                 # expect: not found
reg query "HKCR\Directory\Background\shell\CodexCLI" 2>$null                      # expect: not found
reg query "HKCR\CLSID\{E3C26D71-5A2F-4B89-9C7E-A1D3F6B84E52}" 2>$null             # expect: not found
Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.FriendlyName -like "*Context Menu Dev Cert" } | Measure-Object
                                                                                  # expect: Count 0
```

- [ ] **Verification 7: Third-tool smoke test (validates the zero-config path)**

Create `configs\dummy.json`:
```json
{
  "toolSlug": "dummy",
  "toolName": "Dummy",
  "executable": "cmd.exe",
  "parentMenu": {
    "title": "Dummy",
    "tooltip": "Dummy test tool"
  },
  "menuItems": [
    { "title": "Echo Hello", "tooltip": "Echoes hello", "args": "/c echo hello && pause" }
  ]
}
```

Then:
```powershell
.\install.ps1 -ToolName dummy
```

Expected: builds, registers, "Dummy" submenu appears with "Echo Hello" item. Clicking it opens a cmd window printing "hello". Uninstall:
```powershell
.\install.ps1 -Uninstall -ToolName dummy
Remove-Item configs\dummy.json
```

- [ ] **Verification 8: No uncommitted changes**

```powershell
git status
```

Expected: `working tree clean` (or only unrelated untracked files).

- [ ] **Verification 9: Commit verification completion**

If Verifications 1–8 all passed, write a completion commit. If any verification fix was needed, fold the fix into an earlier task's commit and re-verify.

```bash
git commit --allow-empty -m "Verify end-to-end multi-tool install/uninstall matrix

All 8 verification scenarios from spec §10 passed:
- Clean slate interactive install of both tools
- Side-by-side invocation
- CLSID uniqueness between pinned and derived GUIDs
- Isolated uninstall preserves sibling tools
- Legacy add-claude-context-menu.ps1 shim works
- Full uninstall leaves zero residue
- Third-tool zero-config path works
- Working tree clean

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Self-review checklist

After each task: confirm the code shown matches any types/names referenced in earlier or later tasks. Key cross-task symbols:

| Symbol | Defined in | Referenced in |
|---|---|---|
| `$script:ProjectNamespaceUuid` | Task 4 | Task 5 (`Resolve-ToolPaths`) |
| `$script:RepoRoot` / `SrcDir` / `ConfigsDir` | Task 4 | Tasks 5, 6, 10, 11 |
| `Get-UuidV5` | Task 4 | Task 5 |
| `Read-ToolConfig` | Task 5 | Tasks 9, 10, 11 |
| `Resolve-ToolExecutable` | Task 5 | Task 9 |
| `Resolve-ToolPaths` → `.Slug/.Name/.Pascal/.ExePath/.Guid/.PackageName/.Publisher/.InstallDir/.ShellVerbId/.ShellKey/.ClsidKey/.CertFriendly` | Task 5 | Tasks 6, 7, 8, 9, 10 |
| `ConvertTo-PascalCase` | Task 5 | Task 10 (in shared-cert guard) |
| `Write-ToolConfigHeader` | Task 6 | Task 9 |
| `Build-ToolDll` | Task 6 | Task 9 |
| `Install-ToolArtifacts` | Task 7 | Task 9 |
| `Register-ToolComClass` | Task 7 | Task 9 |
| `Write-AppxManifest` | Task 7 | Task 9 |
| `Find-SdkBin` | Task 8 | Task 8 (`Pack-AndRegisterMsix`) |
| `Ensure-SigningCert` | Task 8 | Task 9 |
| `Pack-AndRegisterMsix` | Task 8 | Task 9 |
| `Invoke-LegacyClaudeSweep` | Task 9 | Task 9 (`Install-Tool`) |
| `Install-Tool` | Task 9 | Task 11 (`Invoke-Main`) |
| `Uninstall-Tool` | Task 10 | Task 11 (`Invoke-Main`) |
| `Get-AvailableConfigs` | Task 11 | Task 11 (`Invoke-Main`) |
| `Show-InteractivePrompt` | Task 11 | Task 11 (`Invoke-Main`) |

Spec coverage check:
- §1 Goals — Task 3 (config), Task 4 (installer skeleton), Task 11 (interactive), Task 12 (shim), Task 9 (backward compat sweep), Task 14 (side-by-side verification)
- §2 Architecture — Tasks 1, 2, 6 (the build pipeline)
- §3 Config schema — Task 3 (shipped configs), Task 5 (`Read-ToolConfig` validation)
- §4 Generated header — Task 6 (`Write-ToolConfigHeader`)
- §5 C code changes — Task 2
- §6 Installer + interactive + UUIDv5 + legacy sweep — Tasks 4–11
- §7 File layout — Task 1
- §8 Registry isolation — Task 5 (`Resolve-ToolPaths`), Task 14 Verification 3
- §9 README — Task 13
- §10 Testing plan — Task 14
- §11 Risks — mitigated: DLL lock (Task 7 Step 1), UUIDv5 byte order (Task 4 Step 2 test vector), shared publisher cert (Task 10 shared-cert guard), legacy upgrade race (Task 9 legacy sweep runs before build), config typos (Task 5 validation)
