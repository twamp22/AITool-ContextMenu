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

$forwardArgs = @("-ToolName", "claude-code")
if ($Uninstall)  { $forwardArgs += "-Uninstall" }
if ($ClaudePath) { $forwardArgs += @("-ExecutablePath", $ClaudePath) }

& (Join-Path $PSScriptRoot "install.ps1") @forwardArgs
