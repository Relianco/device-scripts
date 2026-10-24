# Intune runs this file with no arguments.
# Exit 0 when Everything 1.5 x64 is installed at or above the pin. Exit 1 otherwise.
# A non-empty publisher counts only when it is voidtools, ignoring case.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-EverythingDetectVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-EverythingDetectVersionText {
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

function Get-EverythingDetectPropertyText {
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

function Get-EverythingDetectProductCodeText {
    param(
        [string]$KeyName,
        [string]$UninstallText
    )
    $pattern = '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}'
    $match = [regex]::Match($UninstallText, $pattern)
    if ($match.Success) {
        return $match.Value
    }
    if ($KeyName -match "^$pattern$") {
        return $KeyName
    }
    return ''
}

function Test-EverythingDetectProductName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    # The MSI product name includes the build, so a newer build is a different DisplayName.
    return [regex]::IsMatch($Name.Trim(), '^Everything 1\.5\..+ \(x64\)$')
}

function Select-EverythingDetectRegistryProduct {
    param($Entries)
    $best = $null
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        $name = (Get-EverythingDetectPropertyText -Object $entry -Name 'DisplayName').Trim()
        if (-not (Test-EverythingDetectProductName -Name $name)) {
            continue
        }
        $publisher = (Get-EverythingDetectPropertyText -Object $entry -Name 'Publisher').Trim()
        if (-not [string]::IsNullOrWhiteSpace($publisher) -and -not $publisher.Equals('voidtools', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $versionText = (Get-EverythingDetectPropertyText -Object $entry -Name 'DisplayVersion').Trim()
        $parsed = Convert-EverythingDetectVersionText -Text $versionText
        $formatted = ''
        if ($parsed -is [version]) {
            $formatted = Format-EverythingDetectVersion -Version $parsed
        }
        $code = (Get-EverythingDetectPropertyText -Object $entry -Name 'ProductCode').Trim()
        $complete = (-not [string]::IsNullOrWhiteSpace($formatted)) -and (-not [string]::IsNullOrWhiteSpace($code))
        $parsedVersion = $null
        if ($parsed -is [version]) {
            $parsedVersion = $parsed
        }
        $candidate = [pscustomobject]@{
            Version     = $formatted
            ProductCode = $code
            Parsed      = $parsedVersion
            Complete    = [bool]$complete
        }
        if ($null -eq $best) {
            $best = $candidate
            continue
        }
        if ($candidate.Complete -and -not $best.Complete) {
            $best = $candidate
            continue
        }
        if (-not $candidate.Complete -and $best.Complete) {
            continue
        }
        if ($null -ne $candidate.Parsed -and $null -ne $best.Parsed -and $candidate.Parsed.CompareTo($best.Parsed) -gt 0) {
            $best = $candidate
        } elseif ($null -ne $candidate.Parsed -and $null -eq $best.Parsed) {
            $best = $candidate
        }
    }
    if ($null -eq $best) {
        return [pscustomobject]@{ Version = ''; ProductCode = '' }
    }
    return [pscustomobject]@{ Version = [string]$best.Version; ProductCode = [string]$best.ProductCode }
}

function Test-EverythingDetectInstalled {
    param(
        $Entries,
        [string]$PinVersion = '1.5.0.1423'
    )
    $selected = Select-EverythingDetectRegistryProduct -Entries $Entries
    $installed = Convert-EverythingDetectVersionText -Text ([string]$selected.Version)
    $pin = Convert-EverythingDetectVersionText -Text $PinVersion
    if ($installed -isnot [version] -or $pin -isnot [version]) {
        return $false
    }
    return $installed.CompareTo($pin) -ge 0
}

function Get-EverythingDetectUninstallEntries {
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
            $uninstallText = (Get-EverythingDetectPropertyText -Object $props -Name 'UninstallString') + ' ' + (Get-EverythingDetectPropertyText -Object $props -Name 'QuietUninstallString')
            $code = Get-EverythingDetectProductCodeText -KeyName ([string]$key.PSChildName) -UninstallText $uninstallText
            $found.Add([pscustomobject]@{
                    DisplayName    = (Get-EverythingDetectPropertyText -Object $props -Name 'DisplayName').Trim()
                    Publisher      = (Get-EverythingDetectPropertyText -Object $props -Name 'Publisher').Trim()
                    DisplayVersion = (Get-EverythingDetectPropertyText -Object $props -Name 'DisplayVersion').Trim()
                    ProductCode    = $code
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
    $present = [bool](Test-EverythingDetectInstalled -Entries @(Get-EverythingDetectUninstallEntries))
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed.
if ($present) {
    Write-Output 'Relian Everything'
    exit 0
}
exit 1
