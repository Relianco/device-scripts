# Standalone Intune detection. Exit 0 when Google Chrome is at or above the pin.
# Does not run the installer.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Format-ChromeDetectVersion {
    param([version]$Version)
    $build = $Version.Build
    $revision = $Version.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, $build, $revision
}

function Convert-ChromeDetectVersionText {
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

function Get-ChromeDetectPropertyText {
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

function Get-ChromeDetectProductCodeText {
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

function Find-ChromeDetectSelectedVersion {
    param(
        [object[]]$Entries,
        [string]$UpdateVersion
    )
    # Same order as Find-ChromeRegistryProduct. The first key with both a
    # version and a product code wins. A later partial key does not replace
    # an earlier one. Omaha runs only when nothing was selected.
    $best = $null
    foreach ($entry in $Entries) {
        if ($null -eq $entry) {
            continue
        }
        $displayName = (Get-ChromeDetectPropertyText -Object $entry -Name 'DisplayName').Trim()
        if ($displayName -ne 'Google Chrome') {
            continue
        }
        $versionText = (Get-ChromeDetectPropertyText -Object $entry -Name 'DisplayVersion').Trim()
        $uninstallText = (Get-ChromeDetectPropertyText -Object $entry -Name 'UninstallString') + ' ' + (Get-ChromeDetectPropertyText -Object $entry -Name 'QuietUninstallString')
        $keyName = Get-ChromeDetectPropertyText -Object $entry -Name 'PSChildName'
        $code = Get-ChromeDetectProductCodeText -KeyName $keyName -UninstallText $uninstallText
        $parsed = Convert-ChromeDetectVersionText -Text $versionText
        $formatted = ''
        if ($parsed -is [version]) {
            $formatted = Format-ChromeDetectVersion -Version $parsed
        }
        $hasVersion = -not [string]::IsNullOrWhiteSpace($formatted)
        $hasCode = -not [string]::IsNullOrWhiteSpace($code)
        if ($hasVersion -and $hasCode) {
            return $formatted
        }
        if ($null -eq $best -and ($hasVersion -or $hasCode)) {
            $best = $formatted
        }
    }
    if ($null -ne $best) {
        return [string]$best
    }
    $parsedUpdate = Convert-ChromeDetectVersionText -Text $UpdateVersion
    if ($parsedUpdate -is [version]) {
        return Format-ChromeDetectVersion -Version $parsedUpdate
    }
    return ''
}

function Test-ChromeDetectInstalled {
    param(
        [object[]]$Entries,
        [string]$UpdateVersion = ''
    )
    $selected = Find-ChromeDetectSelectedVersion -Entries $Entries -UpdateVersion $UpdateVersion
    $installed = Convert-ChromeDetectVersionText -Text $selected
    $minimum = Convert-ChromeDetectVersionText -Text '155.0.8059.85'
    if (-not ($installed -is [version]) -or -not ($minimum -is [version])) {
        return $false
    }
    return $installed.CompareTo($minimum) -ge 0
}

function Get-ChromeDetectRegistryEntries {
    $entries = New-Object System.Collections.Generic.List[object]
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
            $props = $null
            try {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            } catch {
                continue
            }
            $entries.Add([pscustomobject]@{
                    DisplayName          = Get-ChromeDetectPropertyText -Object $props -Name 'DisplayName'
                    DisplayVersion       = Get-ChromeDetectPropertyText -Object $props -Name 'DisplayVersion'
                    UninstallString      = Get-ChromeDetectPropertyText -Object $props -Name 'UninstallString'
                    QuietUninstallString = Get-ChromeDetectPropertyText -Object $props -Name 'QuietUninstallString'
                    PSChildName          = [string]$key.PSChildName
                })
        }
    }
    return ,$entries.ToArray()
}

function Get-ChromeDetectUpdateVersion {
    # Chrome stable Omaha id. Used only when no uninstall key was selected.
    $updateKey = 'HKLM:\SOFTWARE\Google\Update\ClientState\{8A69D345-D564-463c-AFF1-A69D9E530F96}'
    try {
        if (-not (Test-Path -LiteralPath $updateKey)) {
            return ''
        }
        $updateProps = Get-ItemProperty -LiteralPath $updateKey -ErrorAction Stop
    } catch {
        return ''
    }
    return (Get-ChromeDetectPropertyText -Object $updateProps -Name 'pv').Trim()
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$detected = $false
try {
    $detected = [bool](Test-ChromeDetectInstalled -Entries (Get-ChromeDetectRegistryEntries) -UpdateVersion (Get-ChromeDetectUpdateVersion))
} catch {
    $detected = $false
}
# Intune treats exit 0 with an empty stdout as not installed.
if ($detected) {
    Write-Output 'Relian Google Chrome'
    exit 0
}
exit 1
