# Intune runs this file with no arguments.
# Exit 0 when PDF-XChange PRO is installed at or above the pin. Exit 1 otherwise, so Intune
# runs the install, which upgrades an older V10 or V11 in place.
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

function Test-RelianPdfXchangeEntry {
    param(
        $Entry,
        [string]$PinVersion
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
    return Test-RelianPdfXchangeVersionAtPin -VersionText $displayVersion -PinVersion $PinVersion
}

function Test-RelianPdfXchangeInstalled {
    param(
        $Entries,
        [string]$PinVersion = '11.1.2.0'
    )
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        # One unreadable entry must not hide another entry that matches.
        $matched = $false
        try {
            $matched = [bool](Test-RelianPdfXchangeEntry -Entry $entry -PinVersion $PinVersion)
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
    $present = [bool](Test-RelianPdfXchangeInstalled -Entries @(Get-RelianPdfXchangeUninstallEntries))
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed. Stderr is also a failure.
if ($present) {
    Write-Output 'Relian PDF-XChange PRO'
    exit 0
}
exit 1
