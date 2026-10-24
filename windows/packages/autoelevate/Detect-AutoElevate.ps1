# Intune runs this file with no arguments.
# Exit 0 when the trimmed display name is AutoElevate and the version is at or above the pin.
# ProductVersion 2.11.1959 and file version 2.11.1959.0 are the same build.
# A missing uninstall key is not installed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Convert-RelianAutoElevateVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    try {
        $parsed = [version]($Text.Trim())
    } catch {
        return 'invalid'
    }
    # ProductVersion is 2.11.1959. The file version is 2.11.1959.0. Those are the same build.
    $build = $parsed.Build
    $revision = $parsed.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return [version]::new($parsed.Major, $parsed.Minor, $build, $revision)
}

function Get-RelianAutoElevatePropertyText {
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

function Test-RelianAutoElevateVersionAtPin {
    param(
        [string]$VersionText,
        [string]$PinVersion
    )
    $parsed = Convert-RelianAutoElevateVersionText -Text $VersionText
    $pin = Convert-RelianAutoElevateVersionText -Text $PinVersion
    if ($parsed -isnot [version] -or $pin -isnot [version]) {
        return $false
    }
    return $parsed.CompareTo($pin) -ge 0
}

function Test-RelianAutoElevateEntry {
    param(
        $Entry,
        [string]$PinVersion
    )
    $displayName = (Get-RelianAutoElevatePropertyText -Object $Entry -Name 'DisplayName').Trim()
    if ($displayName -ne 'AutoElevate') {
        return $false
    }
    $versionText = (Get-RelianAutoElevatePropertyText -Object $Entry -Name 'DisplayVersion').Trim()
    return Test-RelianAutoElevateVersionAtPin -VersionText $versionText -PinVersion $PinVersion
}

function Test-RelianAutoElevateInstalled {
    param(
        $Entries,
        [string]$PinVersion = '2.11.1959'
    )
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        # One unreadable entry must not hide another entry that matches.
        $matched = $false
        try {
            $matched = [bool](Test-RelianAutoElevateEntry -Entry $entry -PinVersion $PinVersion)
        } catch {
            $matched = $false
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

function Get-RelianAutoElevateUninstallEntries {
    # A missing uninstall key is not installed. It is not an error.
    $found = [System.Collections.Generic.List[object]]::new()
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        $keys = @()
        try {
            if (-not (Test-Path -LiteralPath $root)) {
                continue
            }
            $keys = @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)
        } catch {
            continue
        }
        foreach ($key in $keys) {
            if ($null -eq $key) {
                continue
            }
            try {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            } catch {
                continue
            }
            $found.Add($props)
        }
    }
    return $found.ToArray()
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $present = [bool](Test-RelianAutoElevateInstalled -Entries @(Get-RelianAutoElevateUninstallEntries))
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed. Stderr is also a failure.
if ($present) {
    Write-Output 'Relian AutoElevate'
    exit 0
}
exit 1
