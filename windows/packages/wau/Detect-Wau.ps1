# Intune runs this file with no arguments.
# Exit 0 when Winget-AutoUpdate is at or above the pin and its effective config (install values with
# any WAU policy on top) is the one the package installs. Exit 1 otherwise.
# The values below must match the install command in intune.json. A caller that changes the ring or
# the times in the install command changes them here too.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$WauPinVersion = '2.12.0'
$WauListUrl = 'https://relianpub.blob.core.windows.net/pub/wau/broad/'
$WauUpdatesAtTime = '01:00:00'
$WauAvdUpdatesAtTime = '02:00:00'

function Convert-RelianWauVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    try {
        $parsed = [version]($Text.Trim())
    } catch {
        return $null
    }
    $build = $parsed.Build
    $revision = $parsed.Revision
    if ($build -lt 0) { $build = 0 }
    if ($revision -lt 0) { $revision = 0 }
    return [version]('{0}.{1}.{2}.{3}' -f $parsed.Major, $parsed.Minor, $build, $revision)
}

# The registry values the package installs. Never at logon; multi-session (EditionID ServerRdsh) has its own time.
function Get-RelianWauExpectedConfig {
    param(
        [string]$EditionId,
        [string]$ListUrl,
        [string]$UpdatesAtTime,
        [string]$AvdUpdatesAtTime
    )
    $multiSession = $EditionId -ceq 'ServerRdsh'
    $atLogon = '0'
    $time = $UpdatesAtTime
    $delay = '02:00'
    if ($multiSession) {
        $time = $AvdUpdatesAtTime
        $delay = '00:30'
    }
    return [ordered]@{
        WAU_DisableAutoUpdate = '1'
        WAU_UseWhiteList      = '1'
        WAU_ListPath          = $ListUrl
        WAU_UpdatesInterval   = 'Daily'
        WAU_UpdatesAtTime     = $time
        WAU_UpdatesTimeDelay  = $delay
        WAU_UpdatesAtLogon    = $atLogon
        WAU_UserContext       = '0'
        WAU_NotificationLevel = 'None'
    }
}

function Test-RelianWauInstalled {
    param(
        $Installed,
        $Policy,
        [string]$EditionId,
        [string]$PinVersion = $WauPinVersion,
        [string]$ListUrl = $WauListUrl,
        [string]$UpdatesAtTime = $WauUpdatesAtTime,
        [string]$AvdUpdatesAtTime = $WauAvdUpdatesAtTime
    )
    if ($null -eq $Installed) {
        return $false
    }
    # WAU's Get-WAUConfig puts policy values over the install values.
    $config = @{}
    foreach ($name in @($Installed.Keys)) {
        $config[$name] = $Installed[$name]
    }
    if ($null -ne $Policy) {
        foreach ($name in @($Policy.Keys)) {
            $config[$name] = $Policy[$name]
        }
    }
    if (-not $config.ContainsKey('ProductVersion') -or $null -eq $config['ProductVersion']) {
        return $false
    }
    $version = Convert-RelianWauVersionText -Text ([string]$config['ProductVersion'])
    $pin = Convert-RelianWauVersionText -Text $PinVersion
    if ($null -eq $version -or $null -eq $pin -or $version.CompareTo($pin) -lt 0) {
        return $false
    }
    $expected = Get-RelianWauExpectedConfig -EditionId $EditionId -ListUrl $ListUrl -UpdatesAtTime $UpdatesAtTime -AvdUpdatesAtTime $AvdUpdatesAtTime
    foreach ($name in @($expected.Keys)) {
        if (-not $config.ContainsKey($name) -or $null -eq $config[$name]) {
            return $false
        }
        if (([string]$config[$name]).Trim() -cne [string]$expected[$name]) {
            return $false
        }
    }
    return $true
}

# One HKLM key in the 64-bit view, so a 32-bit host reads what the x64 MSI wrote. Missing is $null.
function Read-RelianWauRegistryValues {
    param([string]$SubKey)
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey($SubKey)
        if ($null -eq $key) {
            return $null
        }
        try {
            $values = @{}
            foreach ($name in $key.GetValueNames()) {
                $values[$name] = $key.GetValue($name)
            }
            return $values
        } finally {
            $key.Dispose()
        }
    } finally {
        $base.Dispose()
    }
}

# mods\_WAU-mods.ps1 exactly as the package installer writes it (sha256 of its LF text).
$WauModsSha256 = '63a9ddce1de613900026482843d4610fd3a04ce510b36ffec2087b371d219512'
function Test-RelianWauMods {
    param([string]$InstallLocation)
    if ([string]::IsNullOrWhiteSpace($InstallLocation)) {
        return $false
    }
    $path = Join-Path (Join-Path $InstallLocation 'mods') '_WAU-mods.ps1'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $false
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($path)))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    return $hash -ceq $WauModsSha256
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $edition = Read-RelianWauRegistryValues -SubKey 'SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $editionId = ''
    if ($null -ne $edition -and $edition.ContainsKey('EditionID')) {
        $editionId = [string]$edition['EditionID']
    }
    $installed = Read-RelianWauRegistryValues -SubKey 'SOFTWARE\Romanitho\Winget-AutoUpdate'
    $present = [bool](Test-RelianWauInstalled -Installed $installed -Policy (Read-RelianWauRegistryValues -SubKey 'SOFTWARE\Policies\Romanitho\Winget-AutoUpdate') -EditionId $editionId)
    if ($present) {
        $present = [bool](Test-RelianWauMods -InstallLocation ([string]$installed['InstallLocation']))
    }
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed. Stderr is also a failure.
if ($present) {
    Write-Output 'Relian Winget-AutoUpdate'
    exit 0
}
exit 1
