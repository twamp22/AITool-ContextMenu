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
