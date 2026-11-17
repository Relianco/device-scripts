# intune.json and Detect-Wau.ps1 for the wau package. Offline. Runs under pwsh and Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/wau'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Wau.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/wau.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

foreach ($path in @($jsonPath, $detectPath, $releasePath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "$path does not exist"
    }
}

$meta = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
$fieldNames = @($meta.PSObject.Properties.Name)
$expectedFields = @('displayName', 'publisher', 'setupFile', 'installCommand', 'uninstallCommand', 'detectionScript', 'detectReplace')
if ($fieldNames.Count -ne $expectedFields.Count) {
    Fail 'intune.json field count'
}
foreach ($field in $expectedFields) {
    if ($fieldNames -notcontains $field) {
        Fail "intune.json missing $field"
    }
}
if ([string]$meta.displayName -cne 'Relian Winget-AutoUpdate') { Fail "displayName '$($meta.displayName)'" }
if ([string]$meta.publisher -cne 'Relian') { Fail "publisher '$($meta.publisher)'" }
if ([string]$meta.setupFile -cne 'Invoke-Wau.ps1') { Fail "setupFile '$($meta.setupFile)'" }
if ([string]$meta.detectionScript -cne 'Detect-Wau.ps1') { Fail "detectionScript '$($meta.detectionScript)'" }
if ($null -eq $meta.detectReplace -or @($meta.detectReplace).Count -ne 0) { Fail 'detectReplace is not empty' }
if (-not (Test-Path -LiteralPath (Join-Path $packageDir ([string]$meta.setupFile)))) { Fail 'setupFile is not next to intune.json' }

$pin = [string]$release.version
$expectedInstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Wau.ps1 -DeploymentType Install -Action Install -PinVersion $pin -ListUrl https://relianpub.blob.core.windows.net/pub/wau/broad/ -UpdatesAtTime 12:00:00 -AvdUpdatesAtTime 02:00:00"
$expectedUninstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Wau.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion $pin"
if ([string]$meta.installCommand -cne $expectedInstall) { Fail 'install command' }
if ([string]$meta.uninstallCommand -cne $expectedUninstall) { Fail 'uninstall command' }

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-Wau.ps1')) { Fail 'detection script references the installer' }
$guardAt = $detectText.IndexOf('RELIAN_DEPLOY_TEST', [System.StringComparison]::Ordinal)
$exitAt = $detectText.IndexOf("`nexit ", [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $exitAt -lt 0 -or $exitAt -lt $guardAt) { Fail 'detection exits before the test guard' }
$presentAt = $detectText.LastIndexOf('if ($present) {', [System.StringComparison]::Ordinal)
if ($presentAt -lt 0) { Fail 'detection success path is missing' }
$afterPresent = $detectText.Substring($presentAt)
$successExit = $afterPresent.IndexOf('exit 0', [System.StringComparison]::Ordinal)
if ($successExit -lt 0 -or -not $afterPresent.Substring(0, $successExit).Contains("Write-Output 'Relian Winget-AutoUpdate'")) {
    Fail 'detection success path does not write Relian Winget-AutoUpdate'
}
$afterSuccess = $afterPresent.Substring($successExit)
$failureExit = $afterSuccess.IndexOf('exit 1', [System.StringComparison]::Ordinal)
if ($failureExit -lt 0) { Fail 'detection failure path is missing' }
$failureBlock = $afterSuccess.Substring(0, $failureExit)
if ($failureBlock.Contains('Write-Output') -or $failureBlock.Contains('Write-Error') -or $failureBlock.Contains('[Console]::Error')) {
    Fail 'detection failure path writes output'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

# Detection carries the same pin, ring and times as the install command.
if ($WauPinVersion -cne $pin) { Fail "detection pin '$WauPinVersion' is not the release '$pin'" }
if ($expectedInstall -notmatch [regex]::Escape("-ListUrl $WauListUrl ")) { Fail 'detection list URL is not the install list URL' }
if ($expectedInstall -notmatch [regex]::Escape("-UpdatesAtTime $WauUpdatesAtTime ")) { Fail 'detection PC time is not the install time' }
if (-not $expectedInstall.EndsWith("-AvdUpdatesAtTime $WauAvdUpdatesAtTime")) { Fail 'detection AVD time is not the install time' }

# The installer and detection agree on every value. Build both from the installer's own functions.
$installerPath = Join-Path $packageDir 'Invoke-Wau.ps1'
. $installerPath
function New-InstalledFromInstaller {
    param([bool]$MultiSession, [string]$Version = '2.12.0')
    $props = Get-WauMsiProperties -MultiSession $MultiSession -ListUrl $WauListUrl -UpdatesAtTime $WauUpdatesAtTime -AvdUpdatesAtTime $WauAvdUpdatesAtTime
    $values = @{ ProductVersion = $Version; InstallLocation = 'C:\Program Files\Winget-AutoUpdate\'; WAU_MaxLogFiles = 7 }
    $expected = Get-WauExpectedConfig -Properties $props
    foreach ($name in @($expected.Keys)) {
        $value = [string]$expected[$name]
        if ($value -match '^[01]$') {
            $values[$name] = [int]$value
        } else {
            $values[$name] = $value
        }
    }
    return $values
}

$pc = New-InstalledFromInstaller -MultiSession $false
$avd = New-InstalledFromInstaller -MultiSession $true
if (-not (Test-RelianWauInstalled -Installed $pc -Policy $null -EditionId 'Professional')) { Fail 'PC install at the pin was absent' }
if (-not (Test-RelianWauInstalled -Installed $avd -Policy $null -EditionId 'ServerRdsh')) { Fail 'AVD install at the pin was absent' }
if (Test-RelianWauInstalled -Installed $pc -Policy $null -EditionId 'ServerRdsh') { Fail 'PC settings passed on a multi-session host' }
if (Test-RelianWauInstalled -Installed $avd -Policy $null -EditionId 'Enterprise') { Fail 'AVD settings passed on a PC' }
if (-not (Test-RelianWauInstalled -Installed (New-InstalledFromInstaller -MultiSession $false -Version '2.13.1') -Policy $null -EditionId 'Professional')) { Fail 'a version above the pin was absent' }
foreach ($below in @('2.11.9', '2.1.0', '', 'not-a-version')) {
    if (Test-RelianWauInstalled -Installed (New-InstalledFromInstaller -MultiSession $false -Version $below) -Policy $null -EditionId 'Professional') { Fail "version '$below' was present" }
}
if (Test-RelianWauInstalled -Installed $null -Policy $null -EditionId 'Professional') { Fail 'no install was present' }
foreach ($change in @(
        @('WAU_DisableAutoUpdate', 0), @('WAU_UseWhiteList', 0), @('WAU_UserContext', 1), @('WAU_UpdatesAtLogon', 0),
        @('WAU_ListPath', 'https://relianpub.blob.core.windows.net/pub/wau/early/'), @('WAU_ListPath', ''),
        @('WAU_NotificationLevel', 'Full'), @('WAU_UpdatesInterval', 'Weekly'), @('WAU_UpdatesAtTime', '06:00:00')
    )) {
    $c = New-InstalledFromInstaller -MultiSession $false
    $c[$change[0]] = $change[1]
    if (Test-RelianWauInstalled -Installed $c -Policy $null -EditionId 'Professional') { Fail "detection passed with $($change[0])=$($change[1])" }
    $c.Remove($change[0])
    if (Test-RelianWauInstalled -Installed $c -Policy $null -EditionId 'Professional') { Fail "detection passed without $($change[0])" }
}
# A WAU policy wins over the install values, as in WAU's Get-WAUConfig.
if (Test-RelianWauInstalled -Installed $pc -Policy @{ WAU_DisableAutoUpdate = 0 } -EditionId 'Professional') { Fail 'policy turning self-update on was ignored' }
if (Test-RelianWauInstalled -Installed $pc -Policy @{ WAU_UseWhiteList = 0 } -EditionId 'Professional') { Fail 'policy turning the allow list off was ignored' }
if (-not (Test-RelianWauInstalled -Installed $pc -Policy @{ WAU_DisableAutoUpdate = 1 } -EditionId 'Professional')) { Fail 'an agreeing policy failed detection' }
if (Test-RelianWauInstalled -Installed $null -Policy $pc -EditionId 'Professional') { Fail 'policy values alone were an install' }

# No client data in committed files.
$banned = @(('Le' + 'ague'), ('Sit' + 'ka'), ('/' + 'home' + '/'))
foreach ($path in @($jsonPath, $detectPath, $installerPath, $releasePath, $PSCommandPath)) {
    $text = Get-Content -LiteralPath $path -Raw -Encoding utf8
    foreach ($word in $banned) {
        if ($text.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Fail "$path contains a banned marker"
        }
    }
}

Write-Output 'intune-wau tests passed'
exit 0
