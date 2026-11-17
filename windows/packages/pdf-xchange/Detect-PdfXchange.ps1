# Intune runs this file with no arguments.
# Exit 0 when PDF-XChange PRO is installed at or above the pin AND this package's marker
# (ProgramData\Relian\pdf-xchange\marker.txt, written by the install script only after the
# licence key and machine policy are applied) agrees. Exit 1 otherwise, so Intune runs the install:
# it upgrades an older V10 or V11 in place, and finishes a hand-installed or half-done copy.
# The marker rules mirror Get-PdfXchangePlan (Install) in the install script; keep them in step.
# The two policy values are not checked: the marker is written after they are set, and the install
# script's plan exits 0 without touching them when the marker is right, so a policy check here
# could only make Intune re-run a no-op forever.
# 11.1.2 and 11.1.2.0 are one release. An empty publisher still counts.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-RelianPdfXchangeVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-RelianPdfXchangeVersionText {
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

function Convert-RelianPdfXchangeComparableVersion {
    param([version]$Version)
    return [version](Format-RelianPdfXchangeVersion -Version $Version)
}

function Get-RelianPdfXchangePropertyText {
    param(
        $Object,
        [string]$Name
    )
    if ($null -eq $Object) {
        return ''
    }
    $value = $null
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) {
            return ''
        }
        $value = $Object[$Name]
    } else {
        $propertyNames = @($Object.PSObject.Properties.Name)
        if ($propertyNames -notcontains $Name) {
            return ''
        }
        $value = $Object.$Name
    }
    if ($null -eq $value) {
        return ''
    }
    return ([string]$value).Trim()
}

function Test-RelianPdfXchangeX64EditionName {
    param([string]$Name)
    # V10 and V11 PRO MSIs both register the ProductName "PDF-XChange PRO".
    return $Name -ceq 'PDF-XChange PRO'
}

function Test-RelianPdfXchangePublisher {
    param([string]$Publisher)
    # V11 is published by PDF-XChange Co Ltd. V10 and older by Tracker Software.
    if ([string]::IsNullOrWhiteSpace($Publisher)) {
        return $true
    }
    return $Publisher -match '^(PDF-XChange|Tracker Software)'
}

function Test-RelianPdfXchangeVersionAtPin {
    param(
        [string]$VersionText,
        [string]$PinVersion
    )
    $parsed = Convert-RelianPdfXchangeVersionText -Text $VersionText
    $pin = Convert-RelianPdfXchangeVersionText -Text $PinVersion
    if ($parsed -isnot [version] -or $pin -isnot [version]) {
        return $false
    }
    $candidate = Convert-RelianPdfXchangeComparableVersion -Version $parsed
    $required = Convert-RelianPdfXchangeComparableVersion -Version $pin
    return $candidate.CompareTo($required) -ge 0
}

function Test-RelianPdfXchangeMarker {
    param(
        [string]$MarkerText,
        [string]$InstalledText,
        [string]$PinVersion
    )
    # Same as the install plan: at the pin the marker must equal the pin; vendor-newer needs a
    # marker at or above the pin (the plan rewrites it to the installed version without a rerun).
    $marker = Convert-RelianPdfXchangeVersionText -Text $MarkerText
    $installed = Convert-RelianPdfXchangeVersionText -Text $InstalledText
    $pin = Convert-RelianPdfXchangeVersionText -Text $PinVersion
    foreach ($v in @($marker, $installed, $pin)) {
        if ($v -isnot [version]) {
            return $false
        }
    }
    $pinCompare = Convert-RelianPdfXchangeComparableVersion -Version $pin
    $markerCompare = (Convert-RelianPdfXchangeComparableVersion -Version $marker).CompareTo($pinCompare)
    $installedCompare = (Convert-RelianPdfXchangeComparableVersion -Version $installed).CompareTo($pinCompare)
    if ($installedCompare -eq 0) {
        return $markerCompare -eq 0
    }
    return $markerCompare -ge 0
}

function Get-RelianPdfXchangeMarkerText {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        # Same path as Get-PdfXchangeDefaultMarkerRoot in the install script.
        $base = $env:ProgramData
        if ([string]::IsNullOrWhiteSpace($base)) {
            $base = [Environment]::GetFolderPath('CommonApplicationData')
        }
        $Root = Join-Path $base 'Relian\pdf-xchange'
    }
    $path = Join-Path $Root 'marker.txt'
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Test-RelianPdfXchangeEntry {
    param(
        $Entry,
        [string]$PinVersion,
        [string]$MarkerText = ''
    )
    $displayName = Get-RelianPdfXchangePropertyText -Object $Entry -Name 'DisplayName'
    if (-not (Test-RelianPdfXchangeX64EditionName -Name $displayName)) {
        return $false
    }
    $publisher = Get-RelianPdfXchangePropertyText -Object $Entry -Name 'Publisher'
    if (-not (Test-RelianPdfXchangePublisher -Publisher $publisher)) {
        return $false
    }
    $displayVersion = Get-RelianPdfXchangePropertyText -Object $Entry -Name 'DisplayVersion'
    if (-not (Test-RelianPdfXchangeVersionAtPin -VersionText $displayVersion -PinVersion $PinVersion)) {
        return $false
    }
    return Test-RelianPdfXchangeMarker -MarkerText $MarkerText -InstalledText $displayVersion -PinVersion $PinVersion
}

function Test-RelianPdfXchangeInstalled {
    param(
        $Entries,
        [string]$PinVersion = '11.1.2.0',
        [string]$MarkerText = ''
    )
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        # One unreadable entry must not hide another entry that matches.
        $matched = $false
        try {
            $matched = [bool](Test-RelianPdfXchangeEntry -Entry $entry -PinVersion $PinVersion -MarkerText $MarkerText)
        } catch {
            $matched = $false
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

function Get-RelianPdfXchangeUninstallEntries {
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
    $present = [bool](Test-RelianPdfXchangeInstalled -Entries @(Get-RelianPdfXchangeUninstallEntries) -MarkerText (Get-RelianPdfXchangeMarkerText))
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed. Stderr is also a failure.
if ($present) {
    Write-Output 'Relian PDF-XChange PRO'
    exit 0
}
exit 1
