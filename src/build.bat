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

REM Include claude_path.h if it exists
set "EXTRA_FLAGS="
if exist claude_path.h set "EXTRA_FLAGS=/DCLAUDE_PATH_H"

cl /LD /O2 %EXTRA_FLAGS% ClaudeCodeContextMenu.c /link /DEF:ClaudeCodeContextMenu.def ole32.lib shell32.lib shlwapi.lib uuid.lib user32.lib
if exist ClaudeCodeContextMenu.dll (echo BUILD_SUCCESS) else (echo BUILD_FAILED)
