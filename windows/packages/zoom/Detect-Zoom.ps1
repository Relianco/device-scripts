# Intune runs this file with no arguments.
# Exit 0 when Zoom Workplace (64-bit) is installed at or above the pin.
# A missing uninstall key is not installed. This file does not run setup.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-RelianZoomVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-RelianZoomVersionText {
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

function Get-RelianZoomPropertyText {
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

function Test-RelianZoomClientDisplayName {
    param([string]$DisplayName)
    # The client only. A plugin, Rooms, or another Zoom product stays installed.
    if ([string]::IsNullOrWhiteSpace($DisplayName) -or $DisplayName -like '*Plugin*') {
        return $false
    }
    return $DisplayName -eq 'Zoom Workplace (64-bit)'
}

function Test-RelianZoomVersionAtPin {
    param(
        [string]$VersionText,
        [string]$PinVersion
    )
    # The installer pads the registry version to four parts, then compares it to the raw pin.
    $parsed = Convert-RelianZoomVersionText -Text $VersionText
    $pin = Convert-RelianZoomVersionText -Text $PinVersion
    if ($parsed -isnot [version] -or $pin -isnot [version]) {
        return $false
    }
    $installed = Convert-RelianZoomVersionText -Text (Format-RelianZoomVersion -Version $parsed)
    if ($installed -isnot [version]) {
        return $false
    }
    return $installed.CompareTo($pin) -ge 0
}

function Test-RelianZoomEntry {
    param(
        $Entry,
        [string]$PinVersion
    )
    $displayName = (Get-RelianZoomPropertyText -Object $Entry -Name 'DisplayName').Trim()
    if (-not (Test-RelianZoomClientDisplayName -DisplayName $displayName)) {
        return $false
    }
    $displayVersion = (Get-RelianZoomPropertyText -Object $Entry -Name 'DisplayVersion').Trim()
    return Test-RelianZoomVersionAtPin -VersionText $displayVersion -PinVersion $PinVersion
}

function Test-RelianZoomInstalled {
    param(
        $Entries,
        [string]$PinVersion = '7.2.48556'
    )
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        # One unreadable entry must not hide another entry that matches.
        $matched = $false
        try {
            $matched = [bool](Test-RelianZoomEntry -Entry $entry -PinVersion $PinVersion)
        } catch {
            $matched = $false
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

function Get-RelianZoomUninstallEntries {
    # A missing uninstall key is not installed. It is not an error.
    $found = [System.Collections.Generic.List[object]]::new()
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
            $found.Add($props)
        }
    }
    if ($found.Count -eq 0) {
        return
    }
    return $found.ToArray()
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $present = [bool](Test-RelianZoomInstalled -Entries @(Get-RelianZoomUninstallEntries))
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed.
if ($present) {
    Write-Output 'Relian Zoom Workplace (64-bit)'
    exit 0
}
exit 1
