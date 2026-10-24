$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/zoom'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Zoom.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/zoom.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function New-ZoomDetectEntry {
    param(
        [string]$DisplayName,
        [string]$DisplayVersion
    )
    return [pscustomobject]@{
        DisplayName    = $DisplayName
        DisplayVersion = $DisplayVersion
        Publisher      = 'Someone Else'
    }
}

function Test-IntuneTextHasIpv4 {
    param([string]$Text)
    $found = [regex]::Matches($Text, '(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])')
    foreach ($match in $found) {
        $parts = $match.Value.Split('.')
        $valid = $true
        foreach ($part in $parts) {
            $number = 0
            $parsed = [int]::TryParse([string]$part, [ref]$number)
            $leadingZero = $part.Length -gt 1 -and $part.StartsWith('0')
            if (-not $parsed -or $leadingZero -or $number -lt 0 -or $number -gt 255) {
                $valid = $false
                break
            }
        }
        if ($valid) {
            return $true
        }
    }
    return $false
}

if (-not (Test-Path -LiteralPath $jsonPath)) {
    Fail 'intune.json does not exist'
}
if (-not (Test-Path -LiteralPath $detectPath)) {
    Fail 'Detect-Zoom.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/zoom.json does not exist'
}

$pin = '7.2.48556'
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.version -cne $pin) {
    Fail 'release version is not the detection pin'
}

$jsonText = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8
$meta = $jsonText | ConvertFrom-Json
$fieldNames = @($meta.PSObject.Properties.Name)
$expectedFields = @(
    'displayName',
    'publisher',
    'setupFile',
    'installCommand',
    'uninstallCommand',
    'detectionScript',
    'detectReplace'
)
if ($fieldNames.Count -ne $expectedFields.Count) {
    Fail 'intune.json field count'
}
foreach ($field in $expectedFields) {
    if ($fieldNames -notcontains $field) {
        Fail "intune.json missing $field"
    }
}
if ([string]$meta.displayName -cne 'Relian Zoom Workplace (64-bit)') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-Zoom.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-Zoom.ps1') {
    Fail "detectionScript '$($meta.detectionScript)'"
}
if ($null -eq $meta.detectReplace -or @($meta.detectReplace).Count -ne 0) {
    Fail 'detectReplace is not empty'
}

$setupPath = Join-Path $packageDir ([string]$meta.setupFile)
$namedDetectPath = Join-Path $packageDir ([string]$meta.detectionScript)
if (-not (Test-Path -LiteralPath $setupPath)) {
    Fail 'setupFile is not next to intune.json'
}
if (-not (Test-Path -LiteralPath $namedDetectPath)) {
    Fail 'detectionScript is not next to intune.json'
}

$installCommand = [string]$meta.installCommand
$uninstallCommand = [string]$meta.uninstallCommand
$expectedInstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Zoom.ps1 -DeploymentType Install -Action Install -PinVersion $pin"
$expectedUninstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Zoom.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion $pin"
if ($installCommand -cne $expectedInstall) {
    Fail 'install command'
}
if ($uninstallCommand -cne $expectedUninstall) {
    Fail 'uninstall command'
}
foreach ($command in @($installCommand, $uninstallCommand)) {
    if (-not $command.StartsWith('powershell.exe')) {
        Fail 'command does not use powershell.exe'
    }
    if ($command.Contains('pwsh')) {
        Fail 'command uses pwsh'
    }
    if (-not $command.Contains("-PinVersion $pin")) {
        Fail 'command pin is not 7.2.48556'
    }
}
if (-not $installCommand.Contains('-Action Install')) {
    Fail 'install action'
}
if (-not $uninstallCommand.Contains('-Action Uninstall')) {
    Fail 'uninstall action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-Zoom.ps1')) {
    Fail 'detection script references the installer'
}
if ($detectText -match '(?m)^\s*\.\s+') {
    Fail 'detection script dot-sources a file'
}
if ($detectText.Contains('Publisher')) {
    Fail 'detection script checks the publisher'
}
if (-not $detectText.Contains("'*Plugin*'")) {
    Fail 'a display name containing Plugin is not excluded'
}
if (-not $detectText.Contains("'Zoom Workplace (64-bit)'")) {
    Fail 'exact client name is absent'
}
if (-not $detectText.Contains("[string]`$PinVersion = '$pin'")) {
    Fail 'detection pin default is not 7.2.48556'
}
if (-not $detectText.Contains('if ($env:RELIAN_DEPLOY_TEST -eq ''1'')')) {
    Fail 'detection script has no test guard'
}
$guardAt = $detectText.IndexOf('RELIAN_DEPLOY_TEST', [System.StringComparison]::Ordinal)
$exitAt = $detectText.IndexOf('exit ', [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $exitAt -lt 0 -or $exitAt -lt $guardAt) {
    Fail 'detection exits before the test guard'
}
$registryAt = $detectText.LastIndexOf('Get-RelianZoomUninstallEntries', [System.StringComparison]::Ordinal)
if ($registryAt -lt $guardAt) {
    Fail 'registry read is not after the test guard'
}
foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
    if (-not $detectText.Contains($root)) {
        Fail "detection script misses $root"
    }
}
$presentAt = $detectText.LastIndexOf('if ($present) {', [System.StringComparison]::Ordinal)
if ($presentAt -lt 0) {
    Fail 'detection success path is missing'
}
$afterPresent = $detectText.Substring($presentAt)
$successExit = $afterPresent.IndexOf('exit 0', [System.StringComparison]::Ordinal)
if ($successExit -lt 0) {
    Fail 'detection success path is missing'
}
$successBlock = $afterPresent.Substring(0, $successExit)
if (-not $successBlock.Contains("Write-Output 'Relian Zoom Workplace (64-bit)'")) {
    Fail 'detection success path does not write Relian Zoom Workplace (64-bit)'
}
$afterSuccess = $afterPresent.Substring($successExit)
$failureExit = $afterSuccess.IndexOf('exit 1', [System.StringComparison]::Ordinal)
if ($failureExit -lt 0) {
    Fail 'detection failure path is missing'
}
$failureBlock = $afterSuccess.Substring(0, $failureExit)
if ($failureBlock.Contains('Write-Output') -or $failureBlock.Contains('Write-Error') -or $failureBlock.Contains('[Console]::Error')) {
    Fail 'detection failure path writes output'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

foreach ($command in @(
        'Format-RelianZoomVersion',
        'Convert-RelianZoomVersionText',
        'Test-RelianZoomClientDisplayName',
        'Test-RelianZoomVersionAtPin',
        'Test-RelianZoomInstalled'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$clientName = 'Zoom Workplace (64-bit)'
if (-not (Test-RelianZoomClientDisplayName -DisplayName $clientName)) {
    Fail 'exact client name was absent'
}
foreach ($name in @(
        'Zoom Plugin for Microsoft Outlook',
        'Zoom Workplace (64-bit) Plugin',
        'Zoom Rooms',
        'Zoom Workplace (32-bit)',
        'Zoom Workplace',
        ''
    )) {
    if (Test-RelianZoomClientDisplayName -DisplayName $name) {
        Fail "other product was treated as the client: $name"
    }
}

if (-not (Test-RelianZoomInstalled -Entries @(New-ZoomDetectEntry -DisplayName $clientName -DisplayVersion $pin))) {
    Fail 'exact client at 7.2.48556 was absent'
}
if (-not (Test-RelianZoomInstalled -Entries @(New-ZoomDetectEntry -DisplayName "  $clientName  " -DisplayVersion $pin))) {
    Fail 'trimmed client name at the pin was absent'
}
if (-not (Test-RelianZoomInstalled -Entries @(New-ZoomDetectEntry -DisplayName $clientName -DisplayVersion '7.2.48557'))) {
    Fail 'a version above the pin was absent'
}
if (-not (Test-RelianZoomInstalled -Entries @(New-ZoomDetectEntry -DisplayName $clientName -DisplayVersion '7.2.48556.0'))) {
    Fail 'the padded pin version was absent'
}
if (Test-RelianZoomInstalled -Entries @(New-ZoomDetectEntry -DisplayName $clientName -DisplayVersion '7.2.48555')) {
    Fail '7.2.48555 was present'
}
if (Test-RelianZoomInstalled -Entries @(New-ZoomDetectEntry -DisplayName 'Zoom Plugin for Microsoft Outlook' -DisplayVersion $pin)) {
    Fail 'a Plugin name was present'
}
if (Test-RelianZoomInstalled -Entries @(New-ZoomDetectEntry -DisplayName 'Zoom Workplace (64-bit) Plugin' -DisplayVersion '8.0.0')) {
    Fail 'a name containing Plugin was present'
}
if (Test-RelianZoomInstalled -Entries @(New-ZoomDetectEntry -DisplayName 'Zoom Rooms' -DisplayVersion $pin)) {
    Fail 'Zoom Rooms was present'
}
if (Test-RelianZoomInstalled -Entries @(New-ZoomDetectEntry -DisplayName $clientName -DisplayVersion '')) {
    Fail 'an entry with no version was present'
}
if (Test-RelianZoomInstalled -Entries @(New-ZoomDetectEntry -DisplayName $clientName -DisplayVersion 'nope')) {
    Fail 'an unparseable version was present'
}
$plugin = New-ZoomDetectEntry -DisplayName 'Zoom Plugin for Microsoft Outlook' -DisplayVersion $pin
$client = New-ZoomDetectEntry -DisplayName $clientName -DisplayVersion $pin
if (-not (Test-RelianZoomInstalled -Entries @($plugin, $null, $client))) {
    Fail 'a Plugin name hid the client'
}
if (Test-RelianZoomInstalled -Entries @()) {
    Fail 'an empty entry list was present'
}
if (Test-RelianZoomInstalled -Entries $null) {
    Fail 'a null entry list was present'
}

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (Test-IntuneTextHasIpv4 -Text "pin $pin") {
    Fail 'version pin was treated as an address'
}
$banned = @(
    ('Le' + 'ague'),
    ('PI' + 'LA'),
    ('Sit' + 'ka'),
    ('/' + 'home' + '/')
)
$committed = @(
    (Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8),
    (Get-Content -LiteralPath $detectPath -Raw -Encoding utf8),
    (Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8)
)
foreach ($text in $committed) {
    if (Test-IntuneTextHasIpv4 -Text $text) {
        Fail 'committed file contains an IPv4 address'
    }
    foreach ($word in $banned) {
        if ($text.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Fail 'committed file contains a banned marker'
        }
    }
}
