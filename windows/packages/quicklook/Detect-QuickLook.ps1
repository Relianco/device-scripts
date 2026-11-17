# Intune runs this file with no arguments.
# Exit 0 when DisplayName is QuickLook and the version is at or above 4.5.0.0.
# A missing uninstall key is not installed. This file does not run setup.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-QuickLookDetectVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-QuickLookDetectVersionText {
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

function Get-QuickLookDetectPropertyText {
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
    $value = $Object.$Name
    if ($null -eq $value) {
        return ''
    }
    return [string]$value
}

function Test-QuickLookDetectDisplayName {
    param([string]$Name)
    # Ordinal match after trim. QuickLook Plugin is a different product.
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    return $Name.Trim().Equals('QuickLook', [System.StringComparison]::Ordinal)
}

function Test-QuickLookDetectVersionAtPin {
    param(
        [string]$VersionText,
        [string]$PinVersion
    )
    # Undefined build and revision count as zero, so 4.5.0 and 4.5.0.0 are one release.
    $parsed = Convert-QuickLookDetectVersionText -Text $VersionText
    $pin = Convert-QuickLookDetectVersionText -Text $PinVersion
    if ($parsed -isnot [version] -or $pin -isnot [version]) {
        return $false
    }
    $installed = Convert-QuickLookDetectVersionText -Text (Format-QuickLookDetectVersion -Version $parsed)
    $required = Convert-QuickLookDetectVersionText -Text (Format-QuickLookDetectVersion -Version $pin)
    if ($installed -isnot [version] -or $required -isnot [version]) {
        return $false
    }
    return $installed.CompareTo($required) -ge 0
}

function Test-QuickLookDetectEntry {
    param(
        $Entry,
        [string]$PinVersion
    )
    $displayName = Get-QuickLookDetectPropertyText -Object $Entry -Name 'DisplayName'
    if (-not (Test-QuickLookDetectDisplayName -Name $displayName)) {
        return $false
    }
    $displayVersion = Get-QuickLookDetectPropertyText -Object $Entry -Name 'DisplayVersion'
    return Test-QuickLookDetectVersionAtPin -VersionText $displayVersion -PinVersion $PinVersion
}

function Test-QuickLookDetectInstalled {
    param(
        $Entries,
        [string]$PinVersion = '4.5.0.0'
    )
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        # One unreadable entry must not hide another entry that matches.
        $matched = $false
        try {
            $matched = [bool](Test-QuickLookDetectEntry -Entry $entry -PinVersion $PinVersion)
        } catch {
            $matched = $false
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

function Get-QuickLookDetectUninstallEntries {
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
            $found.Add([pscustomobject]@{
                    DisplayName    = Get-QuickLookDetectPropertyText -Object $props -Name 'DisplayName'
                    DisplayVersion = Get-QuickLookDetectPropertyText -Object $props -Name 'DisplayVersion'
                })
        }
    }
    return $found.ToArray()
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $present = [bool](Test-QuickLookDetectInstalled -Entries @(Get-QuickLookDetectUninstallEntries))
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed.
if ($present) {
    Write-Output 'Relian QuickLook'
    exit 0
}
exit 1
