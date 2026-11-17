# Intune runs this file with no arguments.
# Exit 0 only when that browser lists the extension. A leftover placeholder is not installed.
# Chromium matches a forcelist value that starts with the id and a semicolon. The update URL is not required.
# Firefox matches policies.ExtensionSettings for that id when installation_mode is force_installed.
# install_url is not required. This file does not run the installer.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Browser = '__BROWSER__'
$script:ExtensionId = '__EXTENSION_ID__'

function Get-RelianBrowserExtensionBrowsers {
    # Same four browsers and policy keys as the installer. Do not dot-source it.
    return @(
        [pscustomobject]@{
            Name   = 'Chrome'
            Kind   = 'Chromium'
            Policy = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
        }
        [pscustomobject]@{
            Name   = 'Edge'
            Kind   = 'Chromium'
            Policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist'
        }
        [pscustomobject]@{
            Name   = 'Brave'
            Kind   = 'Chromium'
            Policy = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave\ExtensionInstallForcelist'
        }
        [pscustomobject]@{
            Name   = 'Firefox'
            Kind   = 'Firefox'
            Policy = 'policies.json'
        }
    )
}

function Get-RelianBrowserExtensionBrowser {
    param([string]$Name)
    foreach ($browser in @(Get-RelianBrowserExtensionBrowsers)) {
        if ($browser.Name -eq $Name) {
            return $browser
        }
    }
    return $null
}

function Get-RelianBrowserExtensionFirefoxPolicyPath {
    $root = $env:ProgramFiles
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = 'C:\Program Files'
    }
    return ($root.TrimEnd('\', '/') + '\Mozilla Firefox\distribution\policies.json')
}

function Test-RelianBrowserExtensionTokenLeft {
    param([string]$Value)
    return [regex]::IsMatch([string]$Value, '__[A-Z0-9_]+__')
}

function Get-RelianBrowserExtensionChild {
    param(
        $Object,
        [string]$Name
    )
    if ($null -eq $Object -or [string]::IsNullOrEmpty($Name)) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in @($Object.Keys)) {
            if ([string]$key -eq $Name) {
                return $Object[$key]
            }
        }
        return $null
    }
    foreach ($property in @($Object.PSObject.Properties)) {
        if ($null -eq $property) {
            continue
        }
        if ([string]$property.Name -eq $Name) {
            return $property.Value
        }
    }
    return $null
}

function Test-RelianBrowserExtensionForcelistListed {
    param(
        $Items,
        [string]$ExtensionId
    )
    $prefix = $ExtensionId + ';'
    foreach ($item in @($Items)) {
        if ($null -ne $item -and ([string]$item.Data).StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

function Test-RelianBrowserExtensionFirefoxForceInstalled {
    param(
        $Policy,
        [string]$ExtensionId
    )
    # The id's entry is the object Set-BrowserExtensionFirefoxEntry writes.
    $policies = Get-RelianBrowserExtensionChild -Object $Policy -Name 'policies'
    $settings = Get-RelianBrowserExtensionChild -Object $policies -Name 'ExtensionSettings'
    $entry = Get-RelianBrowserExtensionChild -Object $settings -Name $ExtensionId
    if ($null -eq $entry) {
        return $false
    }
    $mode = Get-RelianBrowserExtensionChild -Object $entry -Name 'installation_mode'
    return ([string]$mode -ceq 'force_installed')
}

function Test-RelianBrowserExtensionInstalled {
    param(
        [string]$Browser,
        [string]$ExtensionId,
        $Forcelist,
        $FirefoxPolicy
    )
    if ((Test-RelianBrowserExtensionTokenLeft -Value $Browser) -or (Test-RelianBrowserExtensionTokenLeft -Value $ExtensionId)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Browser) -or [string]::IsNullOrWhiteSpace($ExtensionId)) {
        return $false
    }
    $info = Get-RelianBrowserExtensionBrowser -Name $Browser
    if ($null -eq $info) {
        return $false
    }
    if ($info.Kind -eq 'Firefox') {
        return [bool](Test-RelianBrowserExtensionFirefoxForceInstalled -Policy $FirefoxPolicy -ExtensionId $ExtensionId)
    }
    return [bool](Test-RelianBrowserExtensionForcelistListed -Items $Forcelist -ExtensionId $ExtensionId)
}

function Get-RelianBrowserExtensionForcelist {
    param(
        [string]$PolicyPath,
        [object[]]$Found
    )
    if (-not $PSBoundParameters.ContainsKey('Found')) {
        if ($env:RELIAN_DEPLOY_TEST -eq '1') {
            throw 'refusing to query the registry while a test is running'
        }
        $list = [System.Collections.Generic.List[object]]::new()
        if (-not [string]::IsNullOrWhiteSpace($PolicyPath)) {
            $key = $null
            try {
                if (Test-Path -LiteralPath $PolicyPath) {
                    $key = Get-Item -LiteralPath $PolicyPath
                }
            } catch {
                $key = $null
            }
            if ($null -ne $key) {
                foreach ($name in @($key.GetValueNames())) {
                    if ([string]::IsNullOrEmpty([string]$name)) {
                        continue
                    }
                    $list.Add([pscustomobject]@{
                            Name = [string]$name
                            Data = [string]$key.GetValue($name)
                        })
                }
            }
        }
        $Found = $list.ToArray()
    }
    # Caller uses @(). A unary comma would nest the list and detection would miss every value.
    return @($Found)
}

function Get-RelianBrowserExtensionFirefoxPolicy {
    param(
        [string]$Path,
        $Found
    )
    if (-not $PSBoundParameters.ContainsKey('Found')) {
        if ($env:RELIAN_DEPLOY_TEST -eq '1') {
            throw 'refusing to read policies.json while a test is running'
        }
        $Found = $null
        if (-not [string]::IsNullOrWhiteSpace($Path)) {
            try {
                if (Test-Path -LiteralPath $Path) {
                    $raw = [System.IO.File]::ReadAllText($Path)
                    if (-not [string]::IsNullOrWhiteSpace($raw)) {
                        $Found = $raw | ConvertFrom-Json
                    }
                }
            } catch {
                $Found = $null
            }
        }
    }
    return $Found
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

if ((Test-RelianBrowserExtensionTokenLeft -Value $script:Browser) -or (Test-RelianBrowserExtensionTokenLeft -Value $script:ExtensionId)) {
    exit 1
}

$present = $false
try {
    $info = Get-RelianBrowserExtensionBrowser -Name $script:Browser
    if ($null -ne $info) {
        if ($info.Kind -eq 'Firefox') {
            $policy = Get-RelianBrowserExtensionFirefoxPolicy -Path (Get-RelianBrowserExtensionFirefoxPolicyPath)
            $present = [bool](Test-RelianBrowserExtensionInstalled -Browser $script:Browser -ExtensionId $script:ExtensionId -FirefoxPolicy $policy)
        } else {
            $items = @(Get-RelianBrowserExtensionForcelist -PolicyPath ([string]$info.Policy))
            $present = [bool](Test-RelianBrowserExtensionInstalled -Browser $script:Browser -ExtensionId $script:ExtensionId -Forcelist $items)
        }
    }
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed. Stderr is also a failure.
if ($present) {
    Write-Output 'Relian __BROWSER__ extension __EXTENSION_ID__'
    exit 0
}
exit 1
