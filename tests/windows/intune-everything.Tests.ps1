$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/everything'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Everything.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/everything.json'
$pin = '1.5.0.1423'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function New-EverythingDetectEntry {
    param(
        [string]$DisplayName,
        [string]$Publisher,
        [string]$DisplayVersion,
        [string]$ProductCode = ''
    )
    return [pscustomobject]@{
        DisplayName    = $DisplayName
        Publisher      = $Publisher
        DisplayVersion = $DisplayVersion
        ProductCode    = $ProductCode
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
    Fail 'Detect-Everything.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/everything.json does not exist'
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.version -cne $pin) {
    Fail "release version '$($release.version)'"
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
if ([string]$meta.displayName -cne 'Relian Everything') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-Everything.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-Everything.ps1') {
    Fail "detectionScript '$($meta.detectionScript)'"
}
if ($jsonText -notmatch '"detectReplace"\s*:\s*\[\s*\]') {
    Fail 'detectReplace must be an empty array'
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
$expectedInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Everything.ps1 -DeploymentType Install -Action Install -PinVersion 1.5.0.1423'
$expectedUninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Everything.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion 1.5.0.1423'
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
    if (-not $command.Contains('-PinVersion 1.5.0.1423')) {
        Fail 'command pin is not 1.5.0.1423'
    }
}
if (-not $installCommand.Contains('-DeploymentType Install') -or -not $installCommand.Contains('-Action Install')) {
    Fail 'install action'
}
if (-not $uninstallCommand.Contains('-DeploymentType Uninstall') -or -not $uninstallCommand.Contains('-Action Uninstall')) {
    Fail 'uninstall action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-Everything')) {
    Fail 'detection script references the installer'
}
if (-not $detectText.Contains("`$ErrorActionPreference = 'Stop'")) {
    Fail 'detection script does not stop on errors'
}
if (-not $detectText.Contains('Set-StrictMode -Version Latest')) {
    Fail 'detection script does not set strict mode'
}
if (-not $detectText.Contains('if ($env:RELIAN_DEPLOY_TEST -eq ''1'')')) {
    Fail 'detection script has no test guard'
}
$guardAt = $detectText.IndexOf('RELIAN_DEPLOY_TEST', [System.StringComparison]::Ordinal)
$exitAt = $detectText.IndexOf("`nexit ", [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $exitAt -lt 0 -or $exitAt -lt $guardAt) {
    Fail 'detection exits before the test guard'
}
$registryAt = $detectText.LastIndexOf('Get-EverythingDetectUninstallEntries', [System.StringComparison]::Ordinal)
if ($registryAt -lt 0 -or $registryAt -lt $guardAt) {
    Fail 'registry is read before the test guard returns'
}
foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
    if (-not $detectText.Contains($root)) {
        Fail "detection script misses $root"
    }
}
if (-not $detectText.Contains('^Everything 1\.5\..+ \(x64\)$')) {
    Fail 'detection script is missing the display name pattern'
}
if (-not $detectText.Contains('1.5.0.1423')) {
    Fail 'detection script is missing the pin'
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
if (-not $successBlock.Contains("Write-Output 'Relian Everything'")) {
    Fail 'detection success path does not write Relian Everything'
}
$afterSuccess = $afterPresent.Substring($successExit)
$failureExit = $afterSuccess.IndexOf('exit 1', [System.StringComparison]::Ordinal)
if ($failureExit -lt 0) {
    Fail 'detection failure path is missing'
}
$failureBlock = $afterSuccess.Substring(0, $failureExit)
if ($failureBlock.Contains('Write-Output') -or $failureBlock.Contains('Write-Error') -or $failureBlock.Contains('Write-Host') -or $failureBlock.Contains('[Console]::Error')) {
    Fail 'detection failure path writes output'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

foreach ($command in @(
        'Test-EverythingDetectProductName',
        'Select-EverythingDetectRegistryProduct',
        'Test-EverythingDetectInstalled'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$matchingName = 'Everything 1.5.0.1423b (x64)'
if (-not (Test-EverythingDetectInstalled -Entries @(New-EverythingDetectEntry -DisplayName $matchingName -Publisher 'voidtools' -DisplayVersion $pin))) {
    Fail 'matching x64 1.5 name was absent'
}
if (-not (Test-EverythingDetectInstalled -Entries @(New-EverythingDetectEntry -DisplayName 'Everything 1.5.0.1500b (x64)' -Publisher 'VoidTools' -DisplayVersion '1.5.0.1500'))) {
    Fail 'a newer 1.5 x64 name was absent'
}
if (-not (Test-EverythingDetectInstalled -Entries @(New-EverythingDetectEntry -DisplayName $matchingName -Publisher '' -DisplayVersion $pin))) {
    Fail 'empty publisher was absent'
}
if (-not (Test-EverythingDetectInstalled -Entries @(New-EverythingDetectEntry -DisplayName $matchingName -Publisher '   ' -DisplayVersion $pin))) {
    Fail 'blank publisher was absent'
}
$mixed = @(
    (New-EverythingDetectEntry -DisplayName $matchingName -Publisher 'Other' -DisplayVersion '1.5.0.1600'),
    (New-EverythingDetectEntry -DisplayName $matchingName -Publisher '' -DisplayVersion $pin)
)
if (-not (Test-EverythingDetectInstalled -Entries $mixed)) {
    Fail 'a matching entry was hidden by another publisher'
}
if (Test-EverythingDetectInstalled -Entries @(New-EverythingDetectEntry -DisplayName $matchingName -Publisher 'Other' -DisplayVersion $pin)) {
    Fail 'wrong publisher was present'
}
if (Test-EverythingDetectInstalled -Entries @(New-EverythingDetectEntry -DisplayName 'Everything 1.5.0.1423b (x86)' -Publisher 'voidtools' -DisplayVersion $pin)) {
    Fail 'a name outside the x64 1.5 pattern was present'
}
if (Test-EverythingDetectInstalled -Entries @(New-EverythingDetectEntry -DisplayName 'Everything 1.4.1.1032 (x64)' -Publisher 'voidtools' -DisplayVersion '1.4.1.1032')) {
    Fail 'a 1.4 name was present'
}
if (Test-EverythingDetectInstalled -Entries @(New-EverythingDetectEntry -DisplayName 'Everything 1.5.0.1400b (x64)' -Publisher 'voidtools' -DisplayVersion '1.5.0.1400')) {
    Fail 'a version below the pin was present'
}
if (Test-EverythingDetectInstalled -Entries @()) {
    Fail 'no entries was present'
}

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (Test-IntuneTextHasIpv4 -Text 'pin 1.5.0.1423') {
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

Write-Output 'intune-everything tests passed'
exit 0
