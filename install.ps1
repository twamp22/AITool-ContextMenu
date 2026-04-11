<#
.SYNOPSIS
    Installs Windows 11 context-menu integration for one or more AI coding CLI tools.
.DESCRIPTION
    Reads per-tool config from configs/<slug>.json and builds a dedicated native
    COM DLL per tool, registered via a signed sparse MSIX package. Each tool gets
    its own CLSID, AppX package, install dir, and shell verb - side-by-side safe.

    Without -ToolName, prompts interactively for which tools to install/uninstall.
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
# Never change - changing this would invalidate all derived GUIDs for existing installs.
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
            Write-Host "Uninstall pipeline for $ToolName - not yet implemented" -ForegroundColor Yellow
        } else {
            Write-Host "Install pipeline for $ToolName - not yet implemented" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Interactive mode - not yet implemented" -ForegroundColor Yellow
    }
}

# Only run Invoke-Main when this script is executed directly, not when dot-sourced
# (dot-sourcing is how Tasks 4+ verify helper functions incrementally).
if ($MyInvocation.InvocationName -ne ".") {
    Invoke-Main
}
