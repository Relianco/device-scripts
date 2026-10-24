$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/vlc'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Vlc.ps1'
$setupPath = Join-Path $packageDir 'Invoke-Vlc.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/vlc.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

foreach ($path in @($jsonPath, $detectPath, $setupPath, $releasePath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "missing $path"
    }
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
$pin = [string]$release.version
if ($pin -cne '3.0.24') {
    Fail "release version '$pin'"
}

$jsonText = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8
$meta = $jsonText | ConvertFrom-Json
foreach ($name in @(
        'displayName',
        'publisher',
        'setupFile',
        'installCommand',
        'uninstallCommand',
        'detectionScript',
        'detectReplace'
    )) {
    if ($meta.PSObject.Properties.Name -notcontains $name) {
        Fail "intune.json missing $name"
    }
}
if ([string]$meta.displayName -cne 'Relian VLC media player') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-Vlc.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-Vlc.ps1') {
    Fail "detectionScript '$($meta.detectionScript)'"
}
if ($jsonText -notmatch '"detectReplace"\s*:\s*\[\s*\]') {
    Fail 'detectReplace must be an empty array'
}
$replaceValue = $meta.PSObject.Properties['detectReplace'].Value
if ($null -eq $replaceValue -or @($replaceValue).Count -ne 0) {
    Fail 'detectReplace did not parse as an empty array'
}

$install = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Vlc.ps1 -DeploymentType Install -Action Install -PinVersion $pin"
$uninstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Vlc.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion $pin"
if ([string]$meta.installCommand -cne $install) {
    Fail "installCommand '$($meta.installCommand)'"
}
if ([string]$meta.uninstallCommand -cne $uninstall) {
    Fail "uninstallCommand '$($meta.uninstallCommand)'"
}
foreach ($command in @([string]$meta.installCommand, [string]$meta.uninstallCommand)) {
    if ($command -notlike 'powershell.exe *') {
        Fail "command does not use powershell.exe: $command"
    }
    if ($command -match 'pwsh') {
        Fail "command contains pwsh: $command"
    }
    if ($command -notlike "*-PinVersion $pin") {
        Fail "command is missing the pin: $command"
    }
}
if ($meta.installCommand -notlike '*-DeploymentType Install *' -or $meta.installCommand -notlike '*-Action Install *') {
    Fail 'install command is missing DeploymentType or Action'
}
if ($meta.uninstallCommand -notlike '*-DeploymentType Uninstall *' -or $meta.uninstallCommand -notlike '*-Action Uninstall *') {
    Fail 'uninstall command is missing DeploymentType or Action'
}

$siblingSetup = Join-Path $packageDir ([string]$meta.setupFile)
$siblingDetect = Join-Path $packageDir ([string]$meta.detectionScript)
if (-not (Test-Path -LiteralPath $siblingSetup) -or -not (Test-Path -LiteralPath $siblingDetect)) {
    Fail 'setupFile or detectionScript is not next to intune.json'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

foreach ($command in @(
        'Convert-VlcDetectVersionText',
        'Format-VlcDetectVersion',
        'Test-VlcDetectInstalled'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

if ($null -ne (Convert-VlcDetectVersionText -Text ' ')) {
    Fail 'blank version text parsed'
}
if ((Convert-VlcDetectVersionText -Text 'not-a-version') -ne 'invalid') {
    Fail 'invalid version marker'
}
$parsedPin = Convert-VlcDetectVersionText -Text $pin
if ($parsedPin -isnot [version]) {
    Fail 'pin did not parse'
}
$formattedPin = Format-VlcDetectVersion -Version $parsedPin
$pinParts = @($formattedPin.Split('.'))
if ($pinParts.Count -ne 4 -or $pinParts[0] -cne '3' -or $pinParts[1] -cne '0' -or $pinParts[2] -cne '24' -or $pinParts[3] -cne '0') {
    Fail "formatted pin '$formattedPin'"
}

function New-VlcDetectEntry {
    param(
        [string]$DisplayName = 'VLC media player',
        [string]$DisplayVersion = '3.0.24',
        [string]$InstallLocation = 'C:\Program Files\VideoLAN\VLC',
        [string]$UninstallString = '"C:\Program Files\VideoLAN\VLC\uninstall.exe"',
        [string]$QuietUninstallString = '',
        [string]$Publisher = 'VideoLAN'
    )
    return [pscustomobject]@{
        DisplayName          = $DisplayName
        DisplayVersion       = $DisplayVersion
        InstallLocation      = $InstallLocation
        UninstallString      = $UninstallString
        QuietUninstallString = $QuietUninstallString
        Publisher            = $Publisher
    }
}

function New-VlcDetectProductKey {
    param(
        [string]$Version = '3.0.24',
        [string]$InstallDir = 'C:\Program Files\VideoLAN\VLC'
    )
    return [pscustomobject]@{
        Version    = $Version
        InstallDir = $InstallDir
    }
}

if (-not (Test-VlcDetectInstalled -Entries @(New-VlcDetectEntry -DisplayVersion $pin))) {
    Fail 'matching entry at the pin is absent'
}
if (-not (Test-VlcDetectInstalled -Entries @(New-VlcDetectEntry -DisplayVersion $formattedPin))) {
    Fail 'zero-revision pin is absent'
}
if (-not (Test-VlcDetectInstalled -Entries @(New-VlcDetectEntry -DisplayName '  VLC media player  ' -Publisher 'Other'))) {
    Fail 'trimmed name was absent'
}
if (-not (Test-VlcDetectInstalled -Entries @(New-VlcDetectEntry -DisplayVersion '3.0.25'))) {
    Fail 'newer version is absent'
}
$versionOnly = New-VlcDetectEntry -InstallLocation '' -UninstallString '' -QuietUninstallString ''
if (-not (Test-VlcDetectInstalled -Entries @($versionOnly))) {
    Fail 'version without a path is absent'
}

if (Test-VlcDetectInstalled -Entries @(New-VlcDetectEntry -DisplayName 'VLC')) {
    Fail 'different name is present'
}
if (Test-VlcDetectInstalled -Entries @(New-VlcDetectEntry -DisplayName 'VLC  media player')) {
    Fail 'spaced name is present'
}
if (Test-VlcDetectInstalled -Entries @(New-VlcDetectEntry -DisplayVersion '3.0.23')) {
    Fail 'older version is present'
}
$olderFormatted = Format-VlcDetectVersion -Version (Convert-VlcDetectVersionText -Text '3.0.23')
if (Test-VlcDetectInstalled -Entries @(New-VlcDetectEntry -DisplayVersion $olderFormatted)) {
    Fail 'older formatted version is present'
}
if (Test-VlcDetectInstalled -Entries @()) {
    Fail 'no entries is present'
}

$olderComplete = New-VlcDetectEntry -DisplayVersion '3.0.23'
$atPin = New-VlcDetectEntry -DisplayVersion '3.0.24'
if (-not (Test-VlcDetectInstalled -Entries @($olderComplete, $atPin))) {
    Fail 'later entry at the pin is absent'
}
if (Test-VlcDetectInstalled -Entries @($olderComplete, (New-VlcDetectEntry -DisplayVersion '3.0.22'))) {
    Fail 'entries below the pin are present'
}
if (Test-VlcDetectInstalled -Entries @($olderComplete) -ProductEntry (New-VlcDetectProductKey -Version '3.0.24')) {
    Fail 'product key replaced an uninstall version below the pin'
}

$quietOlder = New-VlcDetectEntry -DisplayVersion '3.0.23' -InstallLocation '' -UninstallString '' -QuietUninstallString '"C:\Program Files\VideoLAN\VLC\uninstall.exe"'
if (-not (Test-VlcDetectInstalled -Entries @($quietOlder, $atPin))) {
    Fail 'older quiet-path entry hid a later pin match'
}

$pathOnly = New-VlcDetectEntry -DisplayVersion '' -UninstallString ''
if (-not (Test-VlcDetectInstalled -Entries @($pathOnly) -ProductEntry (New-VlcDetectProductKey -Version '3.0.24'))) {
    Fail 'path without a display version ignored a product key at the pin'
}
if (Test-VlcDetectInstalled -Entries @($pathOnly) -ProductEntry (New-VlcDetectProductKey -Version '3.0.23')) {
    Fail 'product key below the pin filled an empty uninstall version'
}
if (-not (Test-VlcDetectInstalled -Entries @(New-VlcDetectEntry -DisplayVersion '3.0.24'))) {
    Fail 'uninstall display version at the pin needs a product key'
}

$invalidVersion = New-VlcDetectEntry -DisplayVersion 'not-a-version' -InstallLocation '' -UninstallString '' -QuietUninstallString ''
if (-not (Test-VlcDetectInstalled -Entries @($invalidVersion) -ProductEntry (New-VlcDetectProductKey))) {
    Fail 'unreadable version blocked the product key'
}
if (-not (Test-VlcDetectInstalled -Entries @(New-VlcDetectEntry -DisplayName 'Other player') -ProductEntry (New-VlcDetectProductKey))) {
    Fail 'product key fallback is absent'
}
if (Test-VlcDetectInstalled -Entries @() -ProductEntry (New-VlcDetectProductKey) -ProductUnreadable) {
    Fail 'unreadable product key is present'
}
if (Test-VlcDetectInstalled -Entries @() -ProductEntry (New-VlcDetectProductKey -Version '3.0.23')) {
    Fail 'older product key is present'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText -notlike "*`$ErrorActionPreference = 'Stop'*") {
    Fail 'detection script does not stop on errors'
}
if ($detectText -notlike '*Set-StrictMode -Version Latest*') {
    Fail 'detection script does not set strict mode'
}
if ($detectText -notlike "*if (`$env:RELIAN_DEPLOY_TEST -eq '1')*") {
    Fail 'detection script has no test guard'
}
$guardAt = $detectText.IndexOf('$env:RELIAN_DEPLOY_TEST')
$liveAt = $detectText.LastIndexOf('Get-VlcDetectRegistryState')
if ($guardAt -lt 0 -or $liveAt -lt $guardAt) {
    Fail 'registry is read under the test guard'
}
$successAt = $detectText.IndexOf("Write-Output 'Relian VLC media player'")
$exitOkAt = $detectText.IndexOf('exit 0', [Math]::Max($successAt, 0))
if ($successAt -lt $guardAt -or $exitOkAt -lt $successAt) {
    Fail 'success output is missing'
}
if ($detectText -match 'Invoke-Vlc') {
    Fail 'detection script references the installer'
}
if ($detectText -match 'Publisher') {
    Fail 'detection script checks publisher'
}
if ($detectText -notlike '*VLC media player*') {
    Fail 'detection script is missing the display name'
}
if ($detectText -notlike "*$pin*") {
    Fail 'detection script is missing the pin'
}
$nativeAt = $detectText.IndexOf('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
$wowAt = $detectText.IndexOf('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
$productAt = $detectText.IndexOf('HKLM:\SOFTWARE\VideoLAN\VLC')
if ($nativeAt -lt 0 -or $wowAt -lt 0 -or $productAt -lt 0 -or $nativeAt -ge $wowAt -or $wowAt -ge $productAt) {
    Fail 'registry roots are missing or out of order'
}

$banned = @(
    ('Le' + 'ague'),
    ('PI' + 'LA'),
    ('Sit' + 'ka'),
    ('/ho' + 'me/')
)
foreach ($path in @($jsonPath, $detectPath, $PSCommandPath)) {
    $text = Get-Content -LiteralPath $path -Raw -Encoding utf8
    foreach ($needle in $banned) {
        if ($text.Contains($needle)) {
            Fail "forbidden text in $(Split-Path -Leaf $path)"
        }
    }
    if ($text -match '(^|[^\d])(?:\d{1,3}\.){3}\d{1,3}($|[^\d])') {
        Fail "IPv4 address in $(Split-Path -Leaf $path)"
    }
}

Write-Output 'intune-vlc tests passed'
exit 0
