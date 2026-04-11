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
