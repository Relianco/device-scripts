# Intune runs this file with no arguments.
# Exit 0 when Wazuh Agent is installed at or above 4.14.9.
# The display name match is the installer's whole-string check.
# Version keys apply only when no Wazuh Agent uninstall entry has a version or a product code.
# A missing key is not installed. This file does not run setup.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-RelianWazuhVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-RelianWazuhVersionText {
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

function Get-RelianWazuhPropertyText {
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

function Get-RelianWazuhProductCodeText {
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

function Find-RelianWazuhProduct {
    param(
        $Entries,
        [string]$VersionValue = ''
    )
    $best = $null
    $items = @()
    if ($null -ne $Entries) {
        $items = @($Entries)
    }
    foreach ($props in $items) {
        if ($null -eq $props) {
            continue
        }
        $candidate = $null
        $complete = $false
        try {
            $displayName = (Get-RelianWazuhPropertyText -Object $props -Name 'DisplayName').Trim()
            if ($displayName -ne 'Wazuh Agent') {
                $candidate = $null
            } else {
                $versionText = (Get-RelianWazuhPropertyText -Object $props -Name 'DisplayVersion').Trim()
                $uninstallText = (Get-RelianWazuhPropertyText -Object $props -Name 'UninstallString') + ' ' + (Get-RelianWazuhPropertyText -Object $props -Name 'QuietUninstallString')
                $keyName = (Get-RelianWazuhPropertyText -Object $props -Name 'PSChildName').Trim()
                $code = Get-RelianWazuhProductCodeText -KeyName $keyName -UninstallText $uninstallText
                $parsed = Convert-RelianWazuhVersionText -Text $versionText
                $formatted = ''
                if ($parsed -is [version]) {
                    $formatted = Format-RelianWazuhVersion -Version $parsed
                }
                $hasVersion = -not [string]::IsNullOrWhiteSpace($formatted)
                $hasCode = -not [string]::IsNullOrWhiteSpace($code)
                if ($hasVersion -or $hasCode) {
                    $candidate = [pscustomobject]@{ Version = $formatted; ProductCode = $code }
                    $complete = $hasVersion -and $hasCode
                }
            }
        } catch {
            $candidate = $null
            $complete = $false
        }
        if ($null -eq $candidate) {
            continue
        }
        if ($complete) {
            return $candidate
        }
        if ($null -eq $best) {
            $best = $candidate
        }
    }
    if ($null -ne $best) {
        return $best
    }
    $parsedUpdate = Convert-RelianWazuhVersionText -Text $VersionValue
    if ($parsedUpdate -is [version]) {
        return [pscustomobject]@{
            Version     = (Format-RelianWazuhVersion -Version $parsedUpdate)
            ProductCode = ''
        }
    }
    return [pscustomobject]@{ Version = ''; ProductCode = '' }
}

function Test-RelianWazuhInstalled {
    param(
        $Entries,
        [string]$VersionValue = '',
        [string]$PinVersion = '4.14.9'
    )
    $pin = Convert-RelianWazuhVersionText -Text $PinVersion
    if ($pin -isnot [version]) {
        return $false
    }
    $product = Find-RelianWazuhProduct -Entries $Entries -VersionValue $VersionValue
    $installed = Convert-RelianWazuhVersionText -Text ([string]$product.Version)
    if ($installed -isnot [version]) {
        return $false
    }
    $candidate = [version](Format-RelianWazuhVersion -Version $installed)
    $required = [version](Format-RelianWazuhVersion -Version $pin)
    return $candidate.CompareTo($required) -ge 0
}

function Get-RelianWazuhUninstallEntries {
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
    return $found.ToArray()
}

function Get-RelianWazuhVersionValue {
    # First parseable agent version. Find ignores it when an uninstall entry already identifies the product.
    $versionKeys = @(
        'HKLM:\SOFTWARE\Wazuh, Inc.\Wazuh Agent',
        'HKLM:\SOFTWARE\WOW6432Node\Wazuh, Inc.\Wazuh Agent',
        'HKLM:\SOFTWARE\Wazuh',
        'HKLM:\SOFTWARE\WOW6432Node\Wazuh'
    )
    foreach ($versionKey in $versionKeys) {
        if (-not (Test-Path -LiteralPath $versionKey)) {
            continue
        }
        try {
            $versionProps = Get-ItemProperty -LiteralPath $versionKey -ErrorAction Stop
        } catch {
            continue
        }
        $updateVersion = (Get-RelianWazuhPropertyText -Object $versionProps -Name 'version').Trim()
        $parsedUpdate = Convert-RelianWazuhVersionText -Text $updateVersion
        if ($parsedUpdate -is [version]) {
            return $updateVersion
        }
    }
    return ''
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $present = [bool](Test-RelianWazuhInstalled -Entries @(Get-RelianWazuhUninstallEntries) -VersionValue ([string](Get-RelianWazuhVersionValue)) -PinVersion '4.14.9')
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed. Stderr is also a failure.
if ($present) {
    Write-Output 'Relian Wazuh Agent'
    exit 0
}
exit 1
