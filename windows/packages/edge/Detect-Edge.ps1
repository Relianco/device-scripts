# Standalone Intune detection. Exit 0 when Microsoft Edge is at or above the pin.
# A display name containing WebView is not Edge. The WebView2 product code is not Edge.
# This file does not run the installer.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Convert-EdgeDetectVersionText {
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

function Get-EdgeDetectPropertyText {
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

function Test-EdgeDetectDisplayName {
    param([string]$Name)
    # Same rule as Test-EdgeMsiDisplayName.
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    $trimmed = $Name.Trim()
    if ($trimmed -like '*WebView*') {
        return $false
    }
    return $trimmed -eq 'Microsoft Edge'
}

function Test-EdgeDetectExcludedProductCode {
    param([string]$ProductCode)
    # Same rule as Test-EdgeExcludedProductCode. An empty code is excluded.
    if ([string]::IsNullOrWhiteSpace($ProductCode)) {
        return $true
    }
    # WebView2's Edge Update app id. It is not Microsoft Edge.
    $webview = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    return $ProductCode.Trim().Equals($webview, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-EdgeDetectProductCodeFromEntry {
    param(
        [string]$KeyName,
        [string]$UninstallString
    )
    $guid = '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
    if ($KeyName -match "^\{$guid\}$") {
        return $Matches[0]
    }
    if ($UninstallString -match "\{$guid\}") {
        return $Matches[0]
    }
    return ''
}

function Get-EdgeDetectProductCodeText {
    param($Entry)
    $explicit = Get-EdgeDetectPropertyText -Object $Entry -Name 'ProductCode'
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        return $explicit
    }
    $keyName = Get-EdgeDetectPropertyText -Object $Entry -Name 'PSChildName'
    $uninstall = Get-EdgeDetectPropertyText -Object $Entry -Name 'UninstallString'
    return Get-EdgeDetectProductCodeFromEntry -KeyName $keyName -UninstallString $uninstall
}

function Test-EdgeDetectVersionAtPin {
    param([string]$VersionText)
    $installed = Convert-EdgeDetectVersionText -Text $VersionText
    $minimum = Convert-EdgeDetectVersionText -Text '155.0.4283.62'
    if ($installed -isnot [version] -or $minimum -isnot [version]) {
        return $false
    }
    return $installed.CompareTo($minimum) -ge 0
}

function Test-EdgeDetectEntry {
    param($Entry)
    $displayName = Get-EdgeDetectPropertyText -Object $Entry -Name 'DisplayName'
    if (-not (Test-EdgeDetectDisplayName -Name $displayName)) {
        return $false
    }
    $code = Get-EdgeDetectProductCodeText -Entry $Entry
    if ($code -notmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
        return $false
    }
    if (Test-EdgeDetectExcludedProductCode -ProductCode $code) {
        return $false
    }
    $versionText = Get-EdgeDetectPropertyText -Object $Entry -Name 'DisplayVersion'
    return Test-EdgeDetectVersionAtPin -VersionText $versionText
}

function Test-EdgeDetectInstalled {
    param(
        [object[]]$Entries = @()
    )
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        # One unreadable entry must not hide another entry that matches.
        $matched = $false
        try {
            $matched = [bool](Test-EdgeDetectEntry -Entry $entry)
        } catch {
            $matched = $false
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

function Get-EdgeDetectRegistryEntries {
    # A missing uninstall key is not installed. It is not an error.
    $found = New-Object System.Collections.Generic.List[object]
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
            $found.Add($props)
        }
    }
    # The comma keeps an empty or one-item list from being unwrapped.
    return ,$found.ToArray()
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $present = [bool](Test-EdgeDetectInstalled -Entries @(Get-EdgeDetectRegistryEntries))
} catch {
    $present = $false
}
# Intune treats exit 0 with an empty stdout as not installed.
if ($present) {
    Write-Output 'Relian Microsoft Edge'
    exit 0
}
exit 1
