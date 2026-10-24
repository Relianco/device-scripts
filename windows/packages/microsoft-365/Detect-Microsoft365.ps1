# Intune runs this file with no arguments.
# Exit 0 when Microsoft 365 Apps is at or above the pin. Exit 1 otherwise.
# 16.0.0.0 is a sentinel. Any higher Click-to-Run build stays installed.
# A missing key is not installed. This file does not run setup.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-Microsoft365DetectPropertyText {
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

function Convert-Microsoft365DetectVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    try {
        $parsed = [version]($Text.Trim())
    } catch {
        return 'invalid'
    }
    # Undefined build or revision compares below an explicit 0. Normalize first.
    $build = $parsed.Build
    $revision = $parsed.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return [version]('{0}.{1}.{2}.{3}' -f $parsed.Major, $parsed.Minor, $build, $revision)
}

function Find-Microsoft365DetectVersion {
    param(
        [object[]]$ClickToRunEntries = @(),
        [object[]]$UninstallEntries = @()
    )

    foreach ($props in @($ClickToRunEntries)) {
        if ($null -eq $props) {
            continue
        }
        $ids = Get-Microsoft365DetectPropertyText -Object $props -Name 'ProductReleaseIds'
        $tokens = @($ids -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($tokens -notcontains 'O365ProPlusRetail') {
            continue
        }
        $parsed = Convert-Microsoft365DetectVersionText -Text (Get-Microsoft365DetectPropertyText -Object $props -Name 'VersionToReport')
        if ($parsed -is [version]) {
            return $parsed
        }
    }

    # Fallback display name is Microsoft 365 Apps for enterprise, not other Office products.
    foreach ($props in @($UninstallEntries)) {
        if ($null -eq $props) {
            continue
        }
        $displayName = (Get-Microsoft365DetectPropertyText -Object $props -Name 'DisplayName').Trim()
        if ($displayName -notlike 'Microsoft 365 Apps for enterprise*') {
            continue
        }
        $parsed = Convert-Microsoft365DetectVersionText -Text (Get-Microsoft365DetectPropertyText -Object $props -Name 'DisplayVersion')
        if ($parsed -is [version]) {
            return $parsed
        }
    }
    return $null
}

function Test-Microsoft365DetectInstalled {
    param(
        [object[]]$ClickToRunEntries = @(),
        [object[]]$UninstallEntries = @()
    )
    $installed = Find-Microsoft365DetectVersion -ClickToRunEntries $ClickToRunEntries -UninstallEntries $UninstallEntries
    $pin = Convert-Microsoft365DetectVersionText -Text '16.0.0.0'
    if ($installed -isnot [version] -or $pin -isnot [version]) {
        return $false
    }
    return $installed.CompareTo($pin) -ge 0
}

function Get-Microsoft365DetectClickToRunEntries {
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($key in @(
            'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration'
        )) {
        try {
            if (-not (Test-Path -LiteralPath $key)) {
                continue
            }
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        } catch {
            continue
        }
        if ($null -ne $props) {
            $found.Add($props)
        }
    }
    return ,$found.ToArray()
}

function Get-Microsoft365DetectUninstallEntries {
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($root in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        )) {
        $children = @()
        try {
            if (-not (Test-Path -LiteralPath $root)) {
                continue
            }
            $children = @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)
        } catch {
            continue
        }
        foreach ($child in $children) {
            if ($null -eq $child) {
                continue
            }
            try {
                $props = Get-ItemProperty -LiteralPath $child.PSPath -ErrorAction Stop
            } catch {
                continue
            }
            if ($null -ne $props) {
                $found.Add($props)
            }
        }
    }
    return ,$found.ToArray()
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $present = [bool](Test-Microsoft365DetectInstalled -ClickToRunEntries (Get-Microsoft365DetectClickToRunEntries) -UninstallEntries (Get-Microsoft365DetectUninstallEntries))
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed.
if ($present) {
    Write-Output 'Relian Microsoft 365 Apps'
    exit 0
}
exit 1
