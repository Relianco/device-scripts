# Intune runs this file with no arguments.
# Exit 0 when Adobe Acrobat is installed at or above the pin. 0.0.0.0 is that pin.
# The display name starts with Adobe Acrobat and does not start with Adobe Acrobat Reader.
# Reader and Reader DC stay. Standard and Pro share the rule, so detection cannot tell them apart.
# A missing uninstall key is not installed. This file does not run setup or dot-source the installer.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-RelianAcrobatVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-RelianAcrobatVersionText {
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

function Get-RelianAcrobatPropertyText {
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

function Test-RelianAcrobatDisplayName {
    param([string]$Name)
    # Same display-name rule as the installer. Reader names stay, including Reader DC.
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    $trimmed = $Name.Trim()
    if ($trimmed -ceq 'Adobe Acrobat Reader') {
        return $false
    }
    if ($trimmed.StartsWith('Adobe Acrobat Reader', [System.StringComparison]::Ordinal)) {
        return $false
    }
    return $trimmed.StartsWith('Adobe Acrobat', [System.StringComparison]::Ordinal)
}

function Test-RelianAcrobatVersionAtPin {
    param(
        [string]$VersionText,
        [string]$PinVersion
    )
    # Pad a short registry version to four parts, then compare it to the pin.
    $parsed = Convert-RelianAcrobatVersionText -Text $VersionText
    $pin = Convert-RelianAcrobatVersionText -Text $PinVersion
    if ($parsed -isnot [version] -or $pin -isnot [version]) {
        return $false
    }
    $installed = Convert-RelianAcrobatVersionText -Text (Format-RelianAcrobatVersion -Version $parsed)
    $normalizedPin = Convert-RelianAcrobatVersionText -Text (Format-RelianAcrobatVersion -Version $pin)
    if ($installed -isnot [version] -or $normalizedPin -isnot [version]) {
        return $false
    }
    return $installed.CompareTo($normalizedPin) -ge 0
}

function Test-RelianAcrobatEntry {
    param(
        $Entry,
        [string]$PinVersion
    )
    $displayName = Get-RelianAcrobatPropertyText -Object $Entry -Name 'DisplayName'
    if (-not (Test-RelianAcrobatDisplayName -Name $displayName)) {
        return $false
    }
    $displayVersion = Get-RelianAcrobatPropertyText -Object $Entry -Name 'DisplayVersion'
    return Test-RelianAcrobatVersionAtPin -VersionText $displayVersion -PinVersion $PinVersion
}

function Test-RelianAcrobatInstalled {
    param(
        $Entries,
        [string]$PinVersion = '0.0.0.0'
    )
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        # One unreadable entry must not hide another entry that matches.
        $matched = $false
        try {
            $matched = [bool](Test-RelianAcrobatEntry -Entry $entry -PinVersion $PinVersion)
        } catch {
            $matched = $false
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

function Get-RelianAcrobatUninstallEntries {
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
                    DisplayName    = Get-RelianAcrobatPropertyText -Object $props -Name 'DisplayName'
                    DisplayVersion = Get-RelianAcrobatPropertyText -Object $props -Name 'DisplayVersion'
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
    $present = [bool](Test-RelianAcrobatInstalled -Entries @(Get-RelianAcrobatUninstallEntries))
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed.
if ($present) {
    Write-Output 'Relian Adobe Acrobat'
    exit 0
}
exit 1
