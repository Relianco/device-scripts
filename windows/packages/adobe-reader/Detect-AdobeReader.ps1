# Intune runs this file with no arguments.
# Exit 0 when Adobe Acrobat Reader is installed at or above the pin.
# The display name is exact, or it continues from that text. Acrobat itself stays.
# A missing uninstall key is not installed. This file does not run setup.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-RelianAdobeReaderVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-RelianAdobeReaderVersionText {
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

function Get-RelianAdobeReaderPropertyText {
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

function Test-RelianAdobeReaderDisplayName {
    param([string]$Name)
    # Exact Reader, and names that continue from it such as Reader DC. Acrobat itself stays.
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    $trimmed = $Name.Trim()
    if ($trimmed -ceq 'Adobe Acrobat Reader') {
        return $true
    }
    return $trimmed.StartsWith('Adobe Acrobat Reader', [System.StringComparison]::Ordinal)
}

function Test-RelianAdobeReaderVersionAtPin {
    param(
        [string]$VersionText,
        [string]$PinVersion
    )
    # Pad a short registry version to four parts, then compare it to the pin.
    $parsed = Convert-RelianAdobeReaderVersionText -Text $VersionText
    $pin = Convert-RelianAdobeReaderVersionText -Text $PinVersion
    if ($parsed -isnot [version] -or $pin -isnot [version]) {
        return $false
    }
    $installed = Convert-RelianAdobeReaderVersionText -Text (Format-RelianAdobeReaderVersion -Version $parsed)
    if ($installed -isnot [version]) {
        return $false
    }
    return $installed.CompareTo($pin) -ge 0
}

function Test-RelianAdobeReaderEntry {
    param(
        $Entry,
        [string]$PinVersion
    )
    $displayName = Get-RelianAdobeReaderPropertyText -Object $Entry -Name 'DisplayName'
    if (-not (Test-RelianAdobeReaderDisplayName -Name $displayName)) {
        return $false
    }
    $displayVersion = Get-RelianAdobeReaderPropertyText -Object $Entry -Name 'DisplayVersion'
    return Test-RelianAdobeReaderVersionAtPin -VersionText $displayVersion -PinVersion $PinVersion
}

function Test-RelianAdobeReaderInstalled {
    param(
        $Entries,
        [string]$PinVersion = '26.2.22031.0'
    )
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        # One unreadable entry must not hide another entry that matches.
        $matched = $false
        try {
            $matched = [bool](Test-RelianAdobeReaderEntry -Entry $entry -PinVersion $PinVersion)
        } catch {
            $matched = $false
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

function Get-RelianAdobeReaderUninstallEntries {
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
                    DisplayName    = Get-RelianAdobeReaderPropertyText -Object $props -Name 'DisplayName'
                    DisplayVersion = Get-RelianAdobeReaderPropertyText -Object $props -Name 'DisplayVersion'
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
    $present = [bool](Test-RelianAdobeReaderInstalled -Entries @(Get-RelianAdobeReaderUninstallEntries))
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed.
if ($present) {
    Write-Output 'Relian Adobe Acrobat Reader'
    exit 0
}
exit 1
