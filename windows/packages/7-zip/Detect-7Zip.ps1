# Intune runs this file with no arguments.
# Exit 0 when the x64 edition is installed at or above the pin. Exit 1 otherwise.
# 26.04 and 26.04.00.0 are one release. An empty publisher still counts.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-Relian7ZipVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-Relian7ZipVersionText {
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

# 7-Zip prints 26.04. The MSI ProductVersion is 26.04.00.0. Those are one release.
function Convert-Relian7ZipComparableVersion {
    param([version]$Version)
    return [version](Format-Relian7ZipVersion -Version $Version)
}

function Get-Relian7ZipPropertyText {
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

function Test-Relian7ZipX64EditionName {
    param([string]$Name)
    # The x64 MSI ProductName is "7-Zip <version> (x64 edition)". The exe installer is not.
    return $Name -match '^7-Zip [0-9]+(\.[0-9]+){1,3} \(x64 edition\)$'
}

function Test-Relian7ZipPublisher {
    param([string]$Publisher)
    # A non-empty publisher counts only when it is exactly Igor Pavlov.
    if ([string]::IsNullOrWhiteSpace($Publisher)) {
        return $true
    }
    return $Publisher -ceq 'Igor Pavlov'
}

function Test-Relian7ZipVersionAtPin {
    param(
        [string]$VersionText,
        [string]$PinVersion
    )
    $parsed = Convert-Relian7ZipVersionText -Text $VersionText
    $pin = Convert-Relian7ZipVersionText -Text $PinVersion
    if ($parsed -isnot [version] -or $pin -isnot [version]) {
        return $false
    }
    $candidate = Convert-Relian7ZipComparableVersion -Version $parsed
    $required = Convert-Relian7ZipComparableVersion -Version $pin
    return $candidate.CompareTo($required) -ge 0
}

function Test-Relian7ZipEntry {
    param(
        $Entry,
        [string]$PinVersion
    )
    $displayName = Get-Relian7ZipPropertyText -Object $Entry -Name 'DisplayName'
    if (-not (Test-Relian7ZipX64EditionName -Name $displayName)) {
        return $false
    }
    $publisher = Get-Relian7ZipPropertyText -Object $Entry -Name 'Publisher'
    if (-not (Test-Relian7ZipPublisher -Publisher $publisher)) {
        return $false
    }
    $displayVersion = Get-Relian7ZipPropertyText -Object $Entry -Name 'DisplayVersion'
    return Test-Relian7ZipVersionAtPin -VersionText $displayVersion -PinVersion $PinVersion
}

function Test-Relian7ZipInstalled {
    param(
        $Entries,
        [string]$PinVersion = '26.04.00.0'
    )
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        # One unreadable entry must not hide another entry that matches.
        $matched = $false
        try {
            $matched = [bool](Test-Relian7ZipEntry -Entry $entry -PinVersion $PinVersion)
        } catch {
            $matched = $false
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

function Get-Relian7ZipUninstallEntries {
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
    $present = [bool](Test-Relian7ZipInstalled -Entries @(Get-Relian7ZipUninstallEntries))
} catch {
    $present = $false
}
if ($present) {
    exit 0
}
exit 1
