# AI Tool Context Menu for Windows 11

Adds a top-level Windows 11 right-click menu entry for AI coding CLI tools (Claude Code, Codex, or any other CLI you configure). Each tool becomes its own submenu in the modern (not "Show more options") context menu.

![Windows 11 Context Menu](https://img.shields.io/badge/Windows_11-Context_Menu-0078D6?style=flat&logo=windows11)

<img width="429" height="339" alt="image" src="https://github.com/user-attachments/assets/f15d4b86-1ed9-4788-a076-98b45966bc6d" />

## Supported tools out of the box

| Tool | Config | Default menu items |
|---|---|---|
| Claude Code | `configs/claude-code.json` | Open (Default), Open (Auto), Open (YOLO) |
| Codex | `configs/codex.json` | Open (Default), Open (Auto-approve) |

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
