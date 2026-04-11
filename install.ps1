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

# ─── Artifact install ─────────────────────────────────────────────────────
function Install-ToolArtifacts {
    param($Paths, [string]$DllSrcPath)

    # Stop explorer if DLL is locked at the destination
    if (Test-Path $Paths.InstallDir) {
        $dllDest = Join-Path $Paths.InstallDir "AIToolContextMenu.dll"
        if (Test-Path $dllDest) {
            try { [IO.File]::OpenWrite($dllDest).Close() }
            catch {
                Write-Host "  DLL locked. Restarting Explorer..." -ForegroundColor Yellow
                Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        }
    }

    if (-not (Test-Path $Paths.InstallDir)) {
        New-Item -ItemType Directory -Path $Paths.InstallDir -Force | Out-Null
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

    if ($Slug -eq "claude-code") { Invoke-LegacyClaudeSweep }

    Write-ToolConfigHeader -Config $cfg -Paths $paths
    $dllSrc = Build-ToolDll
    Install-ToolArtifacts -Paths $paths -DllSrcPath $dllSrc
    Register-ToolComClass -Paths $paths
    Write-AppxManifest -Config $cfg -Paths $paths
    $cert = Ensure-SigningCert -Paths $paths
    Pack-AndRegisterMsix -Paths $paths -Cert $cert

    Write-Host "  $Slug installed." -ForegroundColor Green
}

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

# ─── Top-level dispatch ────────────────────────────────────────────────────
function Invoke-Main {
    # Enforce elevation here (not via #Requires) so dot-sourcing for unit tests works
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "install.ps1 must be run from an elevated PowerShell session (Run as Administrator)."
    }

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

# Only run Invoke-Main when this script is executed directly, not when dot-sourced
# (dot-sourcing is how Tasks 4+ verify helper functions incrementally).
if ($MyInvocation.InvocationName -ne ".") {
    Invoke-Main
}
