# AI Tool-Agnostic Context Menu — Design

**Date:** 2026-04-11
**Status:** Implemented and verified on 2026-04-11. Shipped on branch `refactor/ai-tool-agnostic`. Two in-flight fixes were folded in during manual verification (DLL lock on re-install, shim splatting); both are reflected in §6.5 and §11.
**Scope:** Refactor the Windows 11 Explorer context menu integration from Claude-Code-specific to a configuration-driven framework that supports any AI coding CLI (Claude Code, Codex, future tools) with side-by-side installation.

---

## 1. Goals and non-goals

**Goals**

- One native COM DLL source that any AI CLI tool can drive via a JSON config file.
- Side-by-side installation: multiple tools (e.g. Claude Code **and** Codex) can each have their own top-level submenu in the Windows 11 right-click menu, with no GUID/registry/package collisions.
- Interactive installer that discovers configs and prompts the user to pick which tools to install or uninstall.
- Backward compatibility: users who previously installed via `add-claude-context-menu.ps1` can upgrade without manual cleanup and without losing their existing context menu.
- Out-of-the-box configs for two tools (Claude Code, Codex) so the multi-tool story is verifiable at merge time.
- Zero file I/O on the shell-menu-render hot path — config values are compiled into the DLL at build time.

**Non-goals**

- Runtime config reloading inside the COM DLL (compile-time is the design).
- A GUI installer — PowerShell with an interactive prompt is sufficient.
- Auto-updating tool executables or versions.
- Icon extraction beyond the current "index 0 of the exe" behavior.

---

## 2. Architecture

One C source file, one `.def` file, one `build.bat`, one `install.ps1`. Each tool is a separate compilation — its own generated header, its own DLL (identical bytes except for the embedded strings and GUID), its own MSIX package, its own install directory, its own shell verb ID. No two tools share any registry path or CLSID.

```
configs/claude-code.json ─┐
configs/codex.json        ├─▶ install.ps1  (interactive prompt OR -ToolName <slug>)
                          │        │
src/AIToolContextMenu.c   ─┤        ├─▶ generate src/tool_config.h  (per-tool: strings + GUID + menu array)
src/AIToolContextMenu.def ─┤        ├─▶ build.bat  →  AIToolContextMenu.dll
src/build.bat             ─┘        ├─▶ copy DLL + stub + logo  →  $ProgramFiles\AIToolContextMenu\<slug>\
                                    ├─▶ generate AppxManifest.xml
                                    ├─▶ makeappx pack  +  signtool sign
                                    ├─▶ Add-AppxPackage (sparse, external location)
                                    └─▶ restart explorer.exe
```

At shell-menu-invoke time, the DLL does nothing it didn't do before: `Par_GetTitle` returns a string literal, `Enum_Next` iterates a static array, `LaunchTool` calls `CreateProcessW` with a compiled-in exe path. No JSON parsing, no disk reads, no dynamic allocation tied to config.

---

## 3. Configuration file schema

Config lives at `configs/<tool-slug>.json`. Schema:

```json
{
  "toolSlug":    "claude-code",
  "toolName":    "Claude Code",
  "executable":  "claude.exe",
  "guid":        "E3C26D71-5A2F-4B89-9C7E-A1D3F6B84E52",
  "packageName": "ClaudeCode.ContextMenu",
  "publisher":   "CN=ClaudeCodeDev",
  "parentMenu": {
    "title":   "Claude Code",
    "tooltip": "Claude Code options"
  },
  "menuItems": [
    { "title": "Open (Default)", "tooltip": "Launch Claude Code in this folder",       "args": "" },
    { "title": "Open (Auto)",    "tooltip": "Launch with --enable-auto-mode",          "args": "--enable-auto-mode" },
    { "title": "Open (YOLO)",    "tooltip": "Launch with --dangerously-skip-permissions", "args": "--dangerously-skip-permissions" }
  ]
}
```

**Field semantics:**

| Field | Required | Notes |
|---|---|---|
| `toolSlug` | yes | kebab-case, canonical identifier. Used in install path, shell verb ID, default package name, UUIDv5 derivation, backward-compat detection. |
| `toolName` | yes | Display name shown in the context menu and in the installer UI. |
| `executable` | yes | Bare exe name resolvable via PATH, or an absolute path. CLI param `-ExecutablePath` overrides. |
| `guid` | no | If absent, derived via UUIDv5 from the project namespace UUID + `toolSlug`. If present, used verbatim (this is how `claude-code.json` pins the legacy GUID for backward compat). |
| `packageName` | no | Defaults to `AIToolContextMenu.<PascalSlug>`. `claude-code.json` pins `ClaudeCode.ContextMenu` for backward compat. |
| `publisher` | no | Defaults to `CN=AIToolContextMenuDev`. Override allowed but not needed for dev-self-signed use. |
| `parentMenu.title` | yes | The top-level dropdown label. |
| `parentMenu.tooltip` | yes | Tooltip for the top-level dropdown. |
| `menuItems` | yes | 1..N items. Each needs `title`, `tooltip`, `args` (empty string = no extra args). |

**Project namespace UUID** (hardcoded in `install.ps1`, never changes):
`7f3a2b18-9c4d-4e5f-a6b7-c8d9e0f1a2b3`

This is a random v4 UUID picked once and committed. Using a project-specific namespace means UUIDv5-derived CLSIDs for third-party tools will never collide with well-known namespaces.

**Shipped configs (v1):**

- `configs/claude-code.json` — pins legacy `guid` and `packageName` for backward compat.
- `configs/codex.json` — omits `guid` (gets derived), omits `packageName` (gets defaulted), demonstrates the zero-config path.

---

## 4. Generated header (`src/tool_config.h`)

Emitted by `install.ps1` on every run. Example for Claude Code:

```c
/* Auto-generated by install.ps1 — do not edit */
#ifndef TOOL_CONFIG_H
#define TOOL_CONFIG_H

#define TOOL_EXE_PATH       L"C:\\Users\\wrigh\\.local\\bin\\claude.exe"
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
    { L"Open (Auto)",    L"Launch with --enable-auto-mode",                       L"--enable-auto-mode" },
    { L"Open (YOLO)",    L"Launch with --dangerously-skip-permissions",           L"--dangerously-skip-permissions" },
};
#define NUM_MENU_ITEMS (sizeof(g_menuItems) / sizeof(g_menuItems[0]))

#endif /* TOOL_CONFIG_H */
```

PowerShell responsibilities when generating this file:

- C-escape backslashes in the exe path (existing logic already does this).
- C-escape embedded double-quotes and backslashes in `title`/`tooltip`/`args` strings.
- Parse the GUID string into the 11-field `{0xXXXXXXXX, 0xXXXX, 0xXXXX, {0xXX, ...}}` C literal form.
- Emit `NULL` for empty-string `args`, otherwise `L"..."`.

---

## 5. C code changes (`src/AIToolContextMenu.c`)

Renamed from `ClaudeCodeContextMenu.c`. Four categories of change:

**5.1 Header include — no fallback**

```c
#include "tool_config.h"
```

No more `#ifdef CLAUDE_PATH_H` guard. If the header is missing, the build fails with a clear compile error — that's the desired behavior because the header is always generated by the installer.

**5.2 Identifier rename**

| Old | New |
|---|---|
| `CLSID_ClaudeCode` | `CLSID_Tool` |
| `CLAUDE_EXE`, `CLAUDE_EXE_PATH` | `TOOL_EXE`, `TOOL_EXE_PATH` |
| `LaunchClaude()` | `LaunchTool()` |
| `ClaudeCodeFactory` | `ToolFactory` |

`CLSID_Tool` is defined in `tool_config.h` as `static const GUID CLSID_Tool = { ... };`. Since there is exactly one translation unit (`AIToolContextMenu.c`), `static const` in a header is safe — no ODR violation, no linker duplicate-symbol risk. The `.c` file just uses the name.

**5.3 `Enum_Next` reads `g_menuItems` instead of a switch**

```c
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
```

`#define NUM_SUBCMDS 3` is removed — `NUM_MENU_ITEMS` from the header replaces it.

**5.4 Parent menu strings come from header macros**

```c
static HRESULT STDMETHODCALLTYPE Par_GetTitle(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)This; (void)p; return SHStrDupW(TOOL_PARENT_TITLE, out);
}

static HRESULT STDMETHODCALLTYPE Par_GetToolTip(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)This; (void)p; return SHStrDupW(TOOL_PARENT_TOOLTIP, out);
}
```

No literal "Claude Code" strings anywhere in the `.c` file.

**5.5 Files renamed**

- `ClaudeCodeContextMenu.c` → `src/AIToolContextMenu.c`
- `ClaudeCodeContextMenu.def` → `src/AIToolContextMenu.def` (update the `LIBRARY` line)
- `build.bat` moves into `src/` and is updated to:
  - Reference the new source/def filenames.
  - Drop the `CLAUDE_PATH_H` conditional flag — the header is always required now.
  - Produce `AIToolContextMenu.dll` in the `src/` directory.

---

## 6. PowerShell installer (`install.ps1`)

New primary entry point. Signature:

```powershell
.\install.ps1 [-ToolName <slug>] [-ConfigFile <path>] [-ExecutablePath <path>] [-Uninstall]
```

### 6.1 Parameter semantics

- No `-ToolName` given → **interactive mode** (see §6.2).
- `-ToolName <slug>` → non-interactive, processes exactly that tool.
- `-ConfigFile <path>` → overrides config lookup (lets users point at an out-of-tree config).
- `-ExecutablePath <path>` → overrides the `executable` field for this run.
- `-Uninstall` → removes rather than installs; combines with the other params the same way.

### 6.2 Interactive flow (no `-ToolName`)

1. Scan `configs/*.json`. Error out if empty: *"No tool configs found in configs\. See README for how to add one."*
2. For each config, determine installation status by checking for the AppX package name (resolved via the same logic used at install time).
3. Render prompt:
   ```
   Available AI tool context menus:
     [1] Claude Code    (installed)
     [2] Codex          (not installed)

   Select tools to install (comma-separated numbers, 'all', or 'q' to cancel):
   ```
4. Parse input. Accept `1`, `1,2`, `all`, `q`. Invalid input reprompts.
5. For each selected tool, run the non-interactive pipeline sequentially. Per-tool errors abort that tool but do not abort the overall run — the installer reports per-tool success/failure at the end.

For `-Uninstall` without `-ToolName`: the same flow, but the prompt lists only tools that are **currently installed**, and the action is removal.

### 6.3 Install pipeline (per tool)

Steps, adapted from the existing `add-claude-context-menu.ps1`:

1. **Load config** from `configs/<slug>.json` (or `-ConfigFile`). JSON-parse and validate required fields.
2. **Resolve executable** in priority order: `-ExecutablePath` → absolute path in config `executable` → `Get-Command <executable>` on PATH → `$env:USERPROFILE\.local\bin\<exe>` fallback → hard error.
3. **Resolve GUID**: config `guid` if present, else UUIDv5 from namespace `7f3a2b18-9c4d-4e5f-a6b7-c8d9e0f1a2b3` + `toolSlug`.
4. **Resolve derived names**:
   - `$installDir` = `Join-Path $env:ProgramFiles "AIToolContextMenu\$toolSlug"`
   - `$packageName` = config `packageName` or `"AIToolContextMenu." + PascalCase($toolSlug)`
   - `$shellVerbId` = `PascalCase($toolSlug) + "CLI"`
   - `$shellKey` = `"Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\$shellVerbId"`
   - `$certFriendly` = `"$toolName Context Menu Dev Cert"`
   - `$publisher` = config `publisher` or `"CN=AIToolContextMenuDev"`
5. **Generate `src/tool_config.h`** from config + resolved exe + resolved GUID (see §4).
6. **Run `build.bat`** in `src/`. On failure, surface compiler output and abort this tool.
7. **Copy artifacts** (DLL, `logo.png`, `Stub.exe`) to `$installDir`. Create `logo.png` and `Stub.exe` per the existing logic if missing.
8. **Register CLSID** at `HKCR\CLSID\{<guid>}` pointing to the DLL in `$installDir`.
9. **Generate `AppxManifest.xml`** with `$packageName`, `$publisher`, `$shellVerbId`, the GUID, and display name = `toolName`.
10. **Ensure signing cert** exists (`$certFriendly`, subject = `$publisher`). Create and trust if missing. One cert per unique publisher — two tools with the same publisher reuse the cert.
11. **Pack + sign MSIX**, remove any previous package with the same name, `Add-AppxPackage -ExternalLocation $installDir`.
12. **Backward-compat sweep** (runs only when `toolSlug == "claude-code"`, AFTER step 11 completes). If `$env:ProgramFiles\ClaudeCodeContextMenu\` exists, remove it. If the old shell key `HKCR\Directory\Background\shell\ClaudeCodeCLI` exists, remove it. If any lingering `ClaudeCode.ContextMenu` AppX package with an `InstallLocation` under the legacy dir exists, remove it. The sweep runs *after* the new MSIX is fully registered so explorer's CLSID lookup is already pointed at the new DLL via both `Register-ToolComClass` and the new AppX manifest — removing legacy artifacts at that point cannot orphan the CLSID. In practice, on a typical upgrade, `Pack-AndRegisterMsix` (step 11) has already replaced the legacy AppX package by name, and the legacy `$ProgramFiles\ClaudeCodeContextMenu\` dir may not even exist, so the sweep is a silent no-op.
13. **Restart explorer.exe** once after all selected tools are processed, not once per tool.

### 6.4 Uninstall pipeline (per tool)

1. Resolve `$packageName`, `$installDir`, `$shellKey`, `$clsidKey`, `$certFriendly` from the config exactly as install does.
2. `Remove-AppxPackage` by name.
3. Remove the shell key and CLSID key if present.
4. Delete `$installDir`.
5. Remove the signing cert from both stores if no other installed tool references it.

Uninstall does **not** run the legacy backward-compat sweep — it only targets the artifacts for the tool being removed.

### 6.5 Backward-compat shim (`add-claude-context-menu.ps1`)

Reduced to a forwarder that preserves the old parameter surface. Uses **hashtable splatting** — not array splatting — so each arg binds by parameter name rather than position:

```powershell
#Requires -RunAsAdministrator
param([switch]$Uninstall, [string]$ClaudePath)

$forwardArgs = @{ ToolName = "claude-code" }
if ($Uninstall)  { $forwardArgs.Uninstall      = $true }
if ($ClaudePath) { $forwardArgs.ExecutablePath = $ClaudePath }

& (Join-Path $PSScriptRoot "install.ps1") @forwardArgs
```

Users with existing scripts or muscle memory see no change.

> **Gotcha we hit during Task 14 verification:** An earlier draft used array splatting (`$args = @("-ToolName", "claude-code"); & install.ps1 @args`). Array splat binds *positionally*, so `-ToolName` became the literal value of the first positional parameter and `claude-code` fell through to the second. Hashtable splat is the only form that binds by name.

### 6.6 UUIDv5 in PowerShell (reference implementation)

```powershell
function Get-UuidV5 {
    param(
        [Parameter(Mandatory)][string]$NamespaceUuid,
        [Parameter(Mandatory)][string]$Name
    )
    $ns = [Guid]::Parse($NamespaceUuid).ToByteArray()
    # .NET stores the first 3 fields in little-endian; convert to network order
    [Array]::Reverse($ns, 0, 4); [Array]::Reverse($ns, 4, 2); [Array]::Reverse($ns, 6, 2)

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
    $bytes[6] = ([byte]($bytes[6] -band 0x0F)) -bor 0x50   # version 5
    $bytes[8] = ([byte]($bytes[8] -band 0x3F)) -bor 0x80   # RFC 4122 variant

    [Array]::Reverse($bytes, 0, 4); [Array]::Reverse($bytes, 4, 2); [Array]::Reverse($bytes, 6, 2)
    return ([Guid]::new($bytes)).ToString().ToUpper()
}
```

---

## 7. File layout

```
ClaudeCodeContextMenu/                      (repo root — name unchanged to avoid breaking links)
├── src/
│   ├── AIToolContextMenu.c                 (renamed, generic)
│   ├── AIToolContextMenu.def                (renamed, updated LIBRARY line)
│   ├── build.bat                            (moved, simplified)
│   └── tool_config.h                        (tracked — committed dev stub; install.ps1 overwrites per-build)
├── configs/
│   ├── claude-code.json                     (pins legacy GUID + packageName)
│   └── codex.json                           (derived GUID + defaulted packageName)
├── install.ps1                              (new primary entry point)
├── add-claude-context-menu.ps1              (shim → install.ps1 -ToolName claude-code)
├── docs/
│   └── superpowers/specs/
│       └── 2026-04-11-ai-tool-agnostic-context-menu-design.md
├── .gitignore                               (add src/*.dll, src/*.obj, src/*.exp, src/*.lib, src/*.stale, *.msix)
├── README.md                                (updated — see §9)
└── LICENSE
```

---

## 8. Registry and isolation guarantees

Every per-tool resource is keyed on either `$toolSlug`, `$packageName`, or `$guid`. Two tools installed side-by-side touch:

| Resource | Claude Code | Codex |
|---|---|---|
| CLSID | `{E3C26D71-...}` (pinned) | `{derived from "codex"}` |
| Install dir | `...\AIToolContextMenu\claude-code\` | `...\AIToolContextMenu\codex\` |
| AppX package name | `ClaudeCode.ContextMenu` | `AIToolContextMenu.Codex` |
| Shell verb ID | `ClaudeCodeCLI` | `CodexCLI` |
| Shell registry key | `...\shell\ClaudeCodeCLI` | `...\shell\CodexCLI` |
| Cert friendly name | `Claude Code Context Menu Dev Cert` | `Codex Context Menu Dev Cert` |

Uninstalling one does not touch any resource belonging to the other.

---

## 9. README updates

- Retitle to *AI Tool Context Menu for Windows 11* (but keep the repo name for link stability).
- New *Supported tools* section listing the shipped configs.
- New *Install* section showing:
  ```
  .\install.ps1                              # interactive prompt
  .\install.ps1 -ToolName claude-code        # install one tool non-interactively
  .\install.ps1 -ToolName codex -ExecutablePath "C:\path\to\codex.exe"
  .\install.ps1 -Uninstall -ToolName codex   # uninstall one tool
  ```
- New *Adding a new tool* section walking through: create `configs/<slug>.json`, omit `guid` for zero-config, run `.\install.ps1`.
- Note that `add-claude-context-menu.ps1` still works for backward compatibility.
- Keep the *How It Works* section, updated to mention the config-driven codegen model.

---

## 10. Testing plan

Manual verification at merge time (no automated test framework in the project today — not introducing one as part of this refactor). **Status: all scenarios below were executed on the target machine on 2026-04-11 as part of the refactor completion. Two bugs were found and fixed in-flight: DLL lock on re-install (see §11) and the backward-compat shim's array splatting (see §6.5).**

1. **Legacy upgrade path.** Machine with the pre-refactor `ClaudeCode.ContextMenu` AppX already installed. Run new `.\install.ps1 -ToolName claude-code`; verify the legacy package is replaced cleanly (via `Pack-AndRegisterMsix`'s same-name removal), the legacy sweep reports nothing to clean (no old ProgramFiles dir, no old shell key), the new MSIX is registered, and the submenu still appears with the legacy CLSID `E3C26D71-...`. ✅
2. **Side-by-side operation.** Install Codex alongside Claude Code (using `powershell.exe` as a stand-in executable). Right-click in a folder — both "Claude Code" and "Codex" submenus appear, each launches the correct executable in the right-clicked folder's CWD. ✅
3. **Registry isolation.** `reg query` both CLSIDs. Both exist, each pointing to a different `AIToolContextMenu.dll` under its own subdir. ✅
4. **Isolated uninstall.** `.\install.ps1 -Uninstall -ToolName codex`; verify Codex submenu is gone, Codex dir and CLSID are gone, Claude Code menu and CLSID still present and working. ✅
5. **Legacy shim.** `.\add-claude-context-menu.ps1` without args forwards correctly to `install.ps1 -ToolName claude-code` and produces a working install. ✅ (fixed during testing: array splatting → hashtable splatting)
6. **Interactive mode, install.** `.\install.ps1` lists both configs with correct installed-status, accepts `q` to cancel. ✅
7. **Interactive mode, uninstall.** `.\install.ps1 -Uninstall` lists only currently-installed tools, accepts numeric selection. ✅
8. **Full uninstall cleanup.** After uninstalling everything, no `ClaudeCode.ContextMenu` AppX, no `AIToolContextMenu.Codex` AppX, no `HKCR\CLSID\{...}` keys, no new-installer-created certs. (The empty `$ProgramFiles\AIToolContextMenu\` parent dir remains — cosmetic, accepted.) ✅
9. **Re-install from clean state.** `.\install.ps1 -ToolName claude-code` succeeds on a machine with nothing installed, creates a fresh cert, registers cleanly. ✅

---

## 11. Open risks and mitigations

- **Explorer DLL lock during re-install.** On a re-install, the destination `AIToolContextMenu.dll` is often still loaded in the running explorer process. Stopping explorer and sleeping a couple seconds is NOT reliable because Windows 11 auto-restarts explorer within ~1 second and re-loads the COM DLL before `Copy-Item` can replace it. **Mitigation implemented in `Install-ToolArtifacts`:** rename-then-replace. Renaming a locked file to a `.<guid>.stale` suffix succeeds on NTFS even while a handle is held (MoveFile updates the directory entry while the open handle keeps pointing at the underlying file blob). The new DLL is then copied under the original name. If the rename itself fails, we fall back to stopping explorer, sleeping 3 seconds, and retrying the rename.
- **UUIDv5 byte-order + array-type bugs.** PowerShell's `[Guid]::ToByteArray()` uses mixed endianness for the first three fields. And `$hash[0..15]` array slicing returns `Object[]`, which `[Guid]::new()` rejects — an explicit `[byte[]]` cast is required. Both issues are addressed in the reference implementation in §6.6, and the implementation is verified against the RFC 4122 DNS namespace test vector (`www.example.com` → `2ED6657D-E927-568B-95E1-2665A8AEA6A2`).
- **MSIX signing with a shared publisher.** If two tool configs share a publisher, they share a cert. Uninstall must not remove the shared cert while another tool still depends on it — the uninstall pipeline (§6.4) handles this by only removing certs with no remaining referencing tool.
- **Legacy upgrade ordering.** `Invoke-LegacyClaudeSweep` must run *after* `Pack-AndRegisterMsix` completes, not before. Running it first would create a window where the legacy CLSID `{E3C26D71-...}` points at a deleted DLL path until the new install finishes. Running it after lets the new MSIX fully register (and, via the new manifest plus `Register-ToolComClass`, claim the same CLSID with the new DLL path) before any legacy artifacts are removed. By that point the legacy AppX package is already gone (replaced by name inside `Pack-AndRegisterMsix`), so the sweep typically finds nothing to do — its role is limited to cleaning up any stale `$ProgramFiles\ClaudeCodeContextMenu\` directory or old shell key that survived a previous install.
- **Backward-compat shim splatting.** The shim must use hashtable splatting (`@{ ToolName = "claude-code" }`), not array splatting (`@("-ToolName", "claude-code")`). Array splat binds positionally and will misroute the args. See §6.5.
- **Shell splat parameter semantics.** `[switch]` parameters in hashtable splats are enabled by setting the key to `$true`, not by including just the key. `$forwardArgs.Uninstall = $true` is correct; `$forwardArgs.Add("Uninstall", "")` is not.
- **Config typos.** Invalid JSON or missing required fields should fail with a clear, actionable error message, not a cryptic PowerShell stack trace. `install.ps1` validates required fields explicitly before starting the build.
- **Empty parent install directory after full uninstall.** After uninstalling every tool, the empty `$env:ProgramFiles\AIToolContextMenu\` parent directory remains on disk. This is cosmetic (no files inside, just an empty folder). Accepted as-is for v1 — not worth the complexity of reference counting when the directory's existence has no functional effect.

---

## 12. Out of scope / explicit non-changes

- `build.bat` still uses `cl.exe` via `vcvarsall.bat`. No move to a CMake/Meson build.
- No automated test harness added. Manual verification per §10.
- The native DLL still uses `IExplorerCommand` + `IEnumExplorerCommand` — no change to the COM model.
- Icon handling remains "index 0 of the tool exe". No config field for a custom icon path. (Could be added later; not needed for v1.)
- No localization. Strings are whatever the config file contains.
