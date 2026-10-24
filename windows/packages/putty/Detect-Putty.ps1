# Intune runs this file with no arguments. Exit 0 when the selected x64
# PuTTY release is at or above the pin. Do not dot-source the installer.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-PuttyDetectVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-PuttyDetectVersionText {
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

function Get-PuttyDetectPropertyText {
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

function Get-PuttyDetectProductCodeText {
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

function Test-PuttyDetectX64ReleaseName {
    param([string]$Name)
    # x64 ProductName is "PuTTY release <version> (64-bit)". Arm is "(64-bit Arm)".
    return $Name -match '^PuTTY release [0-9]+(\.[0-9]+){1,3} \(64-bit\)$'
}

function Find-PuttyDetectProduct {
    param([object[]]$Entries)

    $complete = $null
    $completeVersion = $null
    $partial = $null
    foreach ($item in @($Entries)) {
        if ($null -eq $item) {
            continue
        }
        $displayName = (Get-PuttyDetectPropertyText -Object $item -Name 'DisplayName').Trim()
        if (-not (Test-PuttyDetectX64ReleaseName -Name $displayName)) {
            continue
        }
        $publisher = (Get-PuttyDetectPropertyText -Object $item -Name 'Publisher').Trim()
        # A blank Publisher still matches. Any other value must be Simon Tatham.
        if (-not [string]::IsNullOrWhiteSpace($publisher) -and $publisher -cne 'Simon Tatham') {
            continue
        }
        $versionText = (Get-PuttyDetectPropertyText -Object $item -Name 'DisplayVersion').Trim()
        if ([string]::IsNullOrWhiteSpace($versionText)) {
            $nameMatch = [regex]::Match($displayName, '^PuTTY release ([0-9]+(?:\.[0-9]+){1,3}) \(64-bit\)$')
            if ($nameMatch.Success) {
                $versionText = $nameMatch.Groups[1].Value
            }
        }
        $uninstallText = (Get-PuttyDetectPropertyText -Object $item -Name 'UninstallString') + ' ' + (Get-PuttyDetectPropertyText -Object $item -Name 'QuietUninstallString')
        $keyName = Get-PuttyDetectPropertyText -Object $item -Name 'KeyName'
        $code = Get-PuttyDetectProductCodeText -KeyName $keyName -UninstallText $uninstallText
        $parsed = Convert-PuttyDetectVersionText -Text $versionText
        $formatted = ''
        if ($parsed -is [version]) {
            $formatted = Format-PuttyDetectVersion -Version $parsed
        }
        $hasVersion = -not [string]::IsNullOrWhiteSpace($formatted)
        $hasCode = -not [string]::IsNullOrWhiteSpace($code)
        $entry = [pscustomobject]@{ Version = $formatted; ProductCode = $code }
        if ($hasVersion -and $hasCode) {
            $candidate = [version]$formatted
            if ($null -eq $complete -or $candidate.CompareTo($completeVersion) -gt 0) {
                $complete = $entry
                $completeVersion = $candidate
            }
            continue
        }
        if ($null -eq $partial -and ($hasVersion -or $hasCode)) {
            $partial = $entry
        }
    }
    if ($null -ne $complete) {
        return $complete
    }
    if ($null -ne $partial) {
        return $partial
    }
    return [pscustomobject]@{ Version = ''; ProductCode = '' }
}

function Test-PuttyDetectPresent {
    param([object[]]$Entries)

    $product = Find-PuttyDetectProduct -Entries $Entries
    $installed = Convert-PuttyDetectVersionText -Text ([string]$product.Version)
    $minimum = Convert-PuttyDetectVersionText -Text '0.85.0.0'
    if ($installed -isnot [version] -or $minimum -isnot [version]) {
        return $false
    }
    return $installed.CompareTo($minimum) -ge 0
}

function Get-PuttyDetectUninstallEntries {
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
                    KeyName              = [string]$key.PSChildName
                    DisplayName          = Get-PuttyDetectPropertyText -Object $props -Name 'DisplayName'
                    Publisher            = Get-PuttyDetectPropertyText -Object $props -Name 'Publisher'
                    DisplayVersion       = Get-PuttyDetectPropertyText -Object $props -Name 'DisplayVersion'
                    UninstallString      = Get-PuttyDetectPropertyText -Object $props -Name 'UninstallString'
                    QuietUninstallString = Get-PuttyDetectPropertyText -Object $props -Name 'QuietUninstallString'
                })
        }
    }
    return @($found.ToArray())
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

try {
    if (Test-PuttyDetectPresent -Entries (Get-PuttyDetectUninstallEntries)) {
        Write-Output 'Relian PuTTY'
        exit 0
    }
} catch {
    exit 1
}
exit 1
