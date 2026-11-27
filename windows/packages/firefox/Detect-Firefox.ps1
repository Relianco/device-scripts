# Intune runs this file with no arguments.
# Exit 0 when Firefox is at or above the pin. Exit 1 otherwise.
# A missing key is not installed. This file does not run setup.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-FirefoxDetectPropertyNames {
    param($Object)
    if ($null -eq $Object) {
        return @()
    }
    return @($Object.PSObject.Properties.Name)
}

function Convert-FirefoxDetectVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $token = ($Text.Trim() -split '\s+', 2)[0]
    if ($token.Length -gt 3 -and $token.EndsWith('esr', [System.StringComparison]::OrdinalIgnoreCase)) {
        $token = $token.Substring(0, $token.Length - 3)
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        return 'invalid'
    }
    try {
        return [version]$token
    } catch {
        return 'invalid'
    }
}

function Get-FirefoxDetectNormalizedVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return [version]::new($Version.Major, $Version.Minor, $build, $revision)
}

function Compare-FirefoxDetectVersion {
    param(
        [version]$Left,
        [version]$Right
    )
    $leftNormalized = Get-FirefoxDetectNormalizedVersion -Version $Left
    $rightNormalized = Get-FirefoxDetectNormalizedVersion -Version $Right
    return $leftNormalized.CompareTo($rightNormalized)
}

function Get-FirefoxDetectVersionFromKeys {
    param([object[]]$ProductKeys)
    foreach ($props in @($ProductKeys)) {
        if ($null -eq $props) {
            continue
        }
        $names = @(Get-FirefoxDetectPropertyNames -Object $props)
        if ($names -notcontains 'CurrentVersion') {
            continue
        }
        $parsed = Convert-FirefoxDetectVersionText -Text ([string]$props.CurrentVersion)
        if ($parsed -is [version]) {
            return $parsed
        }
    }
    return $null
}

function Get-FirefoxDetectVersionFromUninstall {
    param([object[]]$UninstallEntries)
    foreach ($props in @($UninstallEntries)) {
        if ($null -eq $props) {
            continue
        }
        $names = @(Get-FirefoxDetectPropertyNames -Object $props)
        if ($names -notcontains 'DisplayName') {
            continue
        }
        $display = [string]$props.DisplayName
        if ($display -notlike 'Mozilla Firefox*') {
            continue
        }
        if ($names -notcontains 'DisplayVersion') {
            continue
        }
        $parsed = Convert-FirefoxDetectVersionText -Text ([string]$props.DisplayVersion)
        if ($parsed -is [version]) {
            return $parsed
        }
    }
    return $null
}

function Test-FirefoxDetectInstalled {
    param(
        [object[]]$ProductKeys = @(),
        [object[]]$UninstallEntries = @()
    )
    # The product key wins, including when it is older than a later uninstall entry.
    $installed = Get-FirefoxDetectVersionFromKeys -ProductKeys $ProductKeys
    if ($installed -isnot [version]) {
        $installed = Get-FirefoxDetectVersionFromUninstall -UninstallEntries $UninstallEntries
    }
    $pin = Convert-FirefoxDetectVersionText -Text '158.0'
    if ($installed -isnot [version] -or $pin -isnot [version]) {
        return $false
    }
    return (Compare-FirefoxDetectVersion -Left $installed -Right $pin) -ge 0
}

function Get-FirefoxDetectProductKeys {
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($key in @(
            'HKLM:\SOFTWARE\Mozilla\Mozilla Firefox',
            'HKLM:\SOFTWARE\WOW6432Node\Mozilla\Mozilla Firefox'
        )) {
        $props = $null
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

function Get-FirefoxDetectUninstallEntries {
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
            $props = $null
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

$detected = $false
try {
    $detected = [bool](Test-FirefoxDetectInstalled -ProductKeys (Get-FirefoxDetectProductKeys) -UninstallEntries (Get-FirefoxDetectUninstallEntries))
} catch {
    $detected = $false
}
# Intune treats exit 0 with an empty stdout as not installed.
if ($detected) {
    Write-Output 'Relian Mozilla Firefox'
    exit 0
}
exit 1
