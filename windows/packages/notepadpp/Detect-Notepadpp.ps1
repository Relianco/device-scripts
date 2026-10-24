# Intune runs this file with no arguments. Exit 0 when the selected
# Notepad++ uninstall entry is at or above 8.9.8.1. Exit 1 otherwise.
# A missing uninstall key is not installed. This file does not run setup.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-NotepadppDetectVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-NotepadppDetectVersionText {
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

function Get-NotepadppDetectPropertyText {
    param(
        $Object,
        [string]$Name
    )
    if ($null -eq $Object) {
        return ''
    }
    $names = @($Object.PSObject.Properties.Name)
    if ($names -notcontains $Name) {
        return ''
    }
    return [string]$Object.$Name
}

function Get-NotepadppDetectUninstallExe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    $quoted = [regex]::Match($Text, '"([^"]+)"')
    if ($quoted.Success) {
        return $quoted.Groups[1].Value
    }
    $token = ($Text.Trim() -split '\s+', 2)[0]
    if ([string]::IsNullOrWhiteSpace($token)) {
        return ''
    }
    return $token
}

function Find-NotepadppDetectProduct {
    param($Entries)
    $best = $null
    $items = @()
    if ($null -ne $Entries) {
        $items = @($Entries)
    }
    foreach ($props in $items) {
        if ($null -eq $props) {
            continue
        }
        $displayName = (Get-NotepadppDetectPropertyText -Object $props -Name 'DisplayName').Trim()
        if ($displayName -ne 'Notepad++ (64-bit x64)') {
            continue
        }
        $versionText = (Get-NotepadppDetectPropertyText -Object $props -Name 'DisplayVersion').Trim()
        $quiet = Get-NotepadppDetectPropertyText -Object $props -Name 'QuietUninstallString'
        $uninstall = Get-NotepadppDetectPropertyText -Object $props -Name 'UninstallString'
        $exe = Get-NotepadppDetectUninstallExe -Text $quiet
        if ([string]::IsNullOrWhiteSpace($exe)) {
            $exe = Get-NotepadppDetectUninstallExe -Text $uninstall
        }
        $parsed = Convert-NotepadppDetectVersionText -Text $versionText
        $formatted = ''
        if ($parsed -is [version]) {
            $formatted = Format-NotepadppDetectVersion -Version $parsed
        }
        $hasVersion = -not [string]::IsNullOrWhiteSpace($formatted)
        $hasExe = -not [string]::IsNullOrWhiteSpace($exe)
        if ($hasVersion -and $hasExe) {
            return [pscustomobject]@{ Version = $formatted; UninstallPath = $exe }
        }
        if ($null -eq $best -and ($hasVersion -or $hasExe)) {
            $best = [pscustomobject]@{ Version = $formatted; UninstallPath = $exe }
        }
    }
    if ($null -ne $best) {
        return $best
    }
    return [pscustomobject]@{ Version = ''; UninstallPath = '' }
}

function Test-NotepadppDetectPresent {
    param(
        $Entries,
        [string]$MinimumVersion = '8.9.8.1'
    )
    $pin = Convert-NotepadppDetectVersionText -Text $MinimumVersion
    if ($pin -isnot [version]) {
        return $false
    }
    $product = Find-NotepadppDetectProduct -Entries $Entries
    $installed = Convert-NotepadppDetectVersionText -Text ([string]$product.Version)
    if ($installed -isnot [version]) {
        return $false
    }
    return $installed.CompareTo($pin) -ge 0
}

function Get-NotepadppDetectRegistryEntries {
    $found = @()
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            if ($null -eq $key) {
                continue
            }
            try {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            } catch {
                continue
            }
            $found += $props
        }
    }
    return $found
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $present = Test-NotepadppDetectPresent -Entries (Get-NotepadppDetectRegistryEntries)
} catch {
    $present = $false
}
# Intune treats exit 0 with an empty stdout as not installed.
if ($present) {
    Write-Output 'Relian Notepad++'
    exit 0
}
exit 1
