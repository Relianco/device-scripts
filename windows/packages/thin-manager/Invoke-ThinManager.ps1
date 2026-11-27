# File parameters are not Mandatory. A mandatory parameter prompts when this
# file is dot-sourced under RELIAN_DEPLOY_TEST.
# There is no Thin Manager installer. Install ensures one common Startup
# shortcut. Uninstall removes that shortcut and this package's marker only.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$CancelPath = '',
    [string]$MarkerRoot = '',
    [string]$StartupFolder = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:ThinManagerShortcutName = 'RelianThinManager.lnk'
$script:ThinManagerDescription = 'Relian Thin Manager'
$script:ThinManagerShellScript = 'C:\Relian\shell.ps1'

function Format-ThinManagerVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-ThinManagerVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    try {
        return [version]($Text.Trim())
    } catch {
        return 'invalid'
    }
}

function New-ThinManagerPlan {
    param(
        $ExitCode = $null,
        [string]$RunShortcut = '',
        [string]$WriteMarker = '',
        [bool]$ClearMarker = $false
    )
    return [pscustomobject]@{
        ExitCode    = $ExitCode
        RunShortcut = $RunShortcut
        WriteMarker = $WriteMarker
        ClearMarker = $ClearMarker
    }
}

function Get-ThinManagerPlan {
    param(
        [string]$Action,
        [string]$PinVersion,
        [string]$InstalledVersion,
        [string]$MarkerVersion,
        [bool]$ShortcutPresent
    )

    # An empty pin disables the package. Do not change the shortcut or the marker.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) {
        return New-ThinManagerPlan -ExitCode 0
    }
    $pin = Convert-ThinManagerVersionText -Text $PinVersion
    if ($pin -eq 'invalid' -or $null -eq $pin) {
        return New-ThinManagerPlan -ExitCode 1
    }
    # The runner sends Uninstall and then Install. This package does not.
    if ($Action -eq 'Reinstall') {
        return New-ThinManagerPlan -ExitCode 1
    }

    # Uninstall does not compare versions. It removes only this package's shortcut.
    if ($Action -eq 'Uninstall') {
        $hasMarker = -not [string]::IsNullOrWhiteSpace($MarkerVersion)
        if (-not $ShortcutPresent -and -not $hasMarker) {
            return New-ThinManagerPlan -ExitCode 0
        }
        if (-not $ShortcutPresent) {
            return New-ThinManagerPlan -ClearMarker $true
        }
        return New-ThinManagerPlan -RunShortcut 'remove' -ClearMarker $true
    }

    $installed = Convert-ThinManagerVersionText -Text $InstalledVersion
    $marker = Convert-ThinManagerVersionText -Text $MarkerVersion
    if ($installed -eq 'invalid' -or $marker -eq 'invalid') {
        return New-ThinManagerPlan -ExitCode 1
    }

    $normalized = $Action
    if ($Action -eq 'Update') {
        $normalized = 'Install'
    }

    $installedText = ''
    if ($null -ne $installed) {
        $installedText = Format-ThinManagerVersion -Version $installed
    }
    $markerText = ''
    if ($null -ne $marker) {
        $markerText = Format-ThinManagerVersion -Version $marker
    }
    $pinText = Format-ThinManagerVersion -Version $pin

    if ($normalized -eq 'Install') {
        if ($null -eq $installed) {
            return New-ThinManagerPlan -RunShortcut 'install' -WriteMarker $pinText
        }
        $compared = $installed.CompareTo($pin)
        if ($compared -lt 0) {
            return New-ThinManagerPlan -RunShortcut 'install' -WriteMarker $pinText
        }
        $write = ''
        if ($compared -gt 0) {
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
        } elseif ($markerText -cne $pinText) {
            $write = $pinText
        }
        if ([string]::IsNullOrWhiteSpace($write)) {
            return New-ThinManagerPlan -ExitCode 0
        }
        return New-ThinManagerPlan -WriteMarker $write
    }

    if ($normalized -eq 'Repair') {
        if ($null -ne $installed -and $installed.CompareTo($pin) -gt 0) {
            $write = ''
            if ($markerText -cne $installedText) {
                $write = $installedText
            }
            if ([string]::IsNullOrWhiteSpace($write)) {
                return New-ThinManagerPlan -ExitCode 0
            }
            return New-ThinManagerPlan -WriteMarker $write
        }
        return New-ThinManagerPlan -RunShortcut 'install' -WriteMarker $pinText
    }

    return New-ThinManagerPlan -ExitCode 1
}

function Get-ThinManagerPowerShellPath {
    $root = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = 'C:\Windows'
    }
    $root = $root.TrimEnd('\')
    return ($root + '\system32\WindowsPowerShell\v1.0\powershell.exe')
}

function Get-ThinManagerShortcutSpec {
    $powershell = Get-ThinManagerPowerShellPath
    $shell = $script:ThinManagerShellScript
    return [pscustomobject]@{
        TargetPath   = $powershell
        Arguments    = ('-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -File "' + $shell + '"')
        Description  = $script:ThinManagerDescription
        IconLocation = $powershell
    }
}

function Get-ThinManagerShortcutPath {
    param([string]$StartupFolder)
    return (Join-Path $StartupFolder $script:ThinManagerShortcutName)
}

function Convert-ThinManagerIconLocation {
    param([string]$IconLocation)
    if ([string]::IsNullOrWhiteSpace($IconLocation)) {
        return ''
    }
    $text = $IconLocation.Trim()
    if ($text.EndsWith(',0')) {
        $text = $text.Substring(0, $text.Length - 2)
    }
    return $text
}

function Test-ThinManagerShortcutMatches {
    param(
        $Shortcut,
        $Spec
    )
    if ($null -eq $Shortcut -or $null -eq $Spec) {
        return $false
    }
    $target = Convert-ThinManagerIconLocation -IconLocation ([string]$Shortcut.TargetPath)
    $icon = Convert-ThinManagerIconLocation -IconLocation ([string]$Shortcut.IconLocation)
    $wantTarget = Convert-ThinManagerIconLocation -IconLocation ([string]$Spec.TargetPath)
    $wantIcon = Convert-ThinManagerIconLocation -IconLocation ([string]$Spec.IconLocation)
    if (-not $target.Equals($wantTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if (-not $icon.Equals($wantIcon, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $arguments = [string]$Shortcut.Arguments
    $description = [string]$Shortcut.Description
    if (-not $arguments.Equals([string]$Spec.Arguments, [System.StringComparison]::Ordinal)) {
        return $false
    }
    if (-not $description.Equals([string]$Spec.Description, [System.StringComparison]::Ordinal)) {
        return $false
    }
    return $true
}

function Set-ThinManagerShellLink {
    param(
        $Link,
        $Spec
    )
    $Link.TargetPath = [string]$Spec.TargetPath
    $Link.Arguments = [string]$Spec.Arguments
    $Link.Description = [string]$Spec.Description
    $Link.IconLocation = [string]$Spec.IconLocation
}

function Save-ThinManagerShellLink {
    param(
        [string]$Path,
        $Spec
    )
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    Set-ThinManagerShellLink -Link $link -Spec $Spec
    $link.Save()
}

function Read-ThinManagerShellLink {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) {
        throw 'startup shortcut path is a directory'
    }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    return [pscustomobject]@{
        TargetPath   = [string]$link.TargetPath
        Arguments    = [string]$link.Arguments
        Description  = [string]$link.Description
        IconLocation = [string]$link.IconLocation
    }
}

function Remove-ThinManagerStartupShortcut {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) {
        throw 'refusing to remove a directory'
    }
    Remove-Item -LiteralPath $Path -Force
}

function Get-ThinManagerDefaultStartupFolder {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = 'C:\ProgramData'
    }
    $programData = $programData.TrimEnd('\')
    return ($programData + '\Microsoft\Windows\Start Menu\Programs\StartUp')
}

function Get-ThinManagerDefaultMarkerRoot {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        $programData = 'C:\ProgramData'
    }
    $programData = $programData.TrimEnd('\')
    return ($programData + '\Relian\thin-manager')
}

function Get-ThinManagerMarkerPath {
    param([string]$Root)
    return (Join-Path $Root 'marker.txt')
}

function Read-ThinManagerMarkerVersion {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }
    $path = Get-ThinManagerMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Write-ThinManagerMarker {
    param(
        [string]$Root,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Get-ThinManagerMarkerPath -Root $Root
    [System.IO.File]::WriteAllText($path, $Version)
}

function Remove-ThinManagerMarker {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return
    }
    $path = Get-ThinManagerMarkerPath -Root $Root
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Add-ThinManagerError {
    param([string]$Message)
    if ($null -eq $script:ThinManagerErrorLog) {
        $script:ThinManagerErrorLog = [System.Collections.Generic.List[string]]::new()
    }
    $script:ThinManagerErrorLog.Add($Message)
    if ($env:RELIAN_DEPLOY_TEST -ne '1') {
        [Console]::Error.WriteLine($Message)
    }
}

function Test-ThinManagerCancelled {
    param([string]$CancelPath)
    if ($env:RELIAN_DEPLOY_CANCEL -eq '1') {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CancelPath)) {
        return $false
    }
    return [bool](Test-Path -LiteralPath $CancelPath)
}

$script:ThinManagerErrorLog = [System.Collections.Generic.List[string]]::new()

$script:ReadThinManagerShortcut = {
    param($Path)
    return (Read-ThinManagerShellLink -Path $Path)
}

$script:WriteThinManagerShortcut = {
    param($Path, $Spec)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Save-ThinManagerShellLink -Path $Path -Spec $Spec
}

$script:RemoveThinManagerShortcut = {
    param($Path)
    Remove-ThinManagerStartupShortcut -Path $Path
}

function Invoke-ThinManagerAction {
    param(
        [string]$DeploymentType,
        [string]$Action,
        [string]$PinVersion,
        [string]$CancelPath,
        [string]$MarkerRoot,
        [string]$StartupFolder
    )

    if ([string]::IsNullOrWhiteSpace($MarkerRoot)) {
        $MarkerRoot = Get-ThinManagerDefaultMarkerRoot
    }
    if ([string]::IsNullOrWhiteSpace($StartupFolder)) {
        $StartupFolder = Get-ThinManagerDefaultStartupFolder
    }

    $shortcutPath = Get-ThinManagerShortcutPath -StartupFolder $StartupFolder
    $spec = Get-ThinManagerShortcutSpec
    $current = $null
    try {
        $current = & $script:ReadThinManagerShortcut $shortcutPath
    } catch {
        Add-ThinManagerError -Message 'could not read the startup shortcut'
        return 1
    }

    $present = $null -ne $current
    $matches = $false
    if ($present) {
        $matches = Test-ThinManagerShortcutMatches -Shortcut $current -Spec $spec
    }
    $marker = Read-ThinManagerMarkerVersion -Root $MarkerRoot
    $installed = ''
    if ($matches) {
        $installed = $marker
    }

    $plan = Get-ThinManagerPlan -Action $Action -PinVersion $PinVersion -InstalledVersion $installed -MarkerVersion $marker -ShortcutPresent ([bool]$present)
    if ($null -ne $plan.ExitCode) {
        return [int]$plan.ExitCode
    }
    if (Test-ThinManagerCancelled -CancelPath $CancelPath) {
        return 130
    }

    if ($plan.RunShortcut -eq 'install') {
        try {
            & $script:WriteThinManagerShortcut $shortcutPath $spec
        } catch {
            Add-ThinManagerError -Message 'could not create the startup shortcut'
            return 1
        }
    } elseif ($plan.RunShortcut -eq 'remove') {
        try {
            & $script:RemoveThinManagerShortcut $shortcutPath
        } catch {
            Add-ThinManagerError -Message 'could not remove the startup shortcut'
            return 1
        }
        if (Test-Path -LiteralPath $shortcutPath) {
            Add-ThinManagerError -Message 'could not remove the startup shortcut'
            return 1
        }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.RunShortcut)) {
        Add-ThinManagerError -Message 'unknown shortcut action'
        return 1
    }

    if ([bool]$plan.ClearMarker) {
        Remove-ThinManagerMarker -Root $MarkerRoot
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$plan.WriteMarker)) {
        Write-ThinManagerMarker -Root $MarkerRoot -Version ([string]$plan.WriteMarker)
    }
    return 0
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

foreach ($name in @('DeploymentType', 'Action', 'PinVersion')) {
    if (-not $PSBoundParameters.ContainsKey($name)) {
        [Console]::Error.WriteLine("missing parameter $name")
        exit 1
    }
}

try {
    $thinManagerExit = [int](Invoke-ThinManagerAction -DeploymentType $DeploymentType -Action $Action -PinVersion $PinVersion -CancelPath $CancelPath -MarkerRoot $MarkerRoot -StartupFolder $StartupFolder)
    exit $thinManagerExit
} catch {
    $detail = [string]$_.Exception.Message
    if ($detail -match '://') {
        $detail = 'thin manager package failed'
    }
    [Console]::Error.WriteLine($detail)
    exit 1
}
