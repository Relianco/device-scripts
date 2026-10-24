$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/7-zip'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-7Zip.ps1'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function New-7ZipDetectEntry {
    param(
        [string]$DisplayName,
        [string]$Publisher,
        [string]$DisplayVersion
    )
    return [pscustomobject]@{
        DisplayName    = $DisplayName
        Publisher      = $Publisher
        DisplayVersion = $DisplayVersion
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
    Fail 'Detect-7Zip.ps1 does not exist'
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
if ([string]$meta.displayName -cne 'Relian 7-Zip') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-7Zip.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-7Zip.ps1') {
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
$expectedInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-7Zip.ps1 -DeploymentType Install -Action Install -PinVersion 26.04.00.0'
$expectedUninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-7Zip.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion 26.04.00.0'
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
    if (-not $command.Contains('-PinVersion 26.04.00.0')) {
        Fail 'command pin is not 26.04.00.0'
    }
}
if (-not $installCommand.Contains('-Action Install')) {
    Fail 'install action'
}
if (-not $uninstallCommand.Contains('-Action Uninstall')) {
    Fail 'uninstall action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-7Zip.ps1')) {
    Fail 'detection script references the installer'
}
if (-not $detectText.Contains('if ($env:RELIAN_DEPLOY_TEST -eq ''1'')')) {
    Fail 'detection script has no test guard'
}
$guardAt = $detectText.IndexOf('RELIAN_DEPLOY_TEST', [System.StringComparison]::Ordinal)
$exitAt = $detectText.IndexOf("`nexit ", [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $exitAt -lt 0 -or $exitAt -lt $guardAt) {
    Fail 'detection exits before the test guard'
}
foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
    if (-not $detectText.Contains($root)) {
        Fail "detection script misses $root"
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

foreach ($command in @(
        'Format-Relian7ZipVersion',
        'Convert-Relian7ZipVersionText',
        'Convert-Relian7ZipComparableVersion',
        'Test-Relian7ZipX64EditionName',
        'Test-Relian7ZipInstalled'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$shortVersion = Convert-Relian7ZipVersionText -Text '26.04'
$fullVersion = Convert-Relian7ZipVersionText -Text '26.04.00.0'
if ($shortVersion -isnot [version] -or $fullVersion -isnot [version]) {
    Fail 'version text did not parse'
}
$shortCompare = Convert-Relian7ZipComparableVersion -Version $shortVersion
$fullCompare = Convert-Relian7ZipComparableVersion -Version $fullVersion
if ($shortCompare.CompareTo($fullCompare) -ne 0) {
    Fail '26.04 and 26.04.00.0 are not the same release'
}

$pinName = '7-Zip 26.04.00.0 (x64 edition)'
if (-not (Test-Relian7ZipInstalled -Entries @(New-7ZipDetectEntry -DisplayName $pinName -Publisher 'Igor Pavlov' -DisplayVersion '26.04.00.0'))) {
    Fail 'matching x64 edition at 26.04.00.0 was absent'
}
if (-not (Test-Relian7ZipInstalled -Entries @(New-7ZipDetectEntry -DisplayName '7-Zip 26.04 (x64 edition)' -Publisher 'Igor Pavlov' -DisplayVersion '26.04'))) {
    Fail '26.04 was not treated as the pinned release'
}
if (-not (Test-Relian7ZipInstalled -Entries @(New-7ZipDetectEntry -DisplayName $pinName -Publisher 'Igor Pavlov' -DisplayVersion '26.05.00.0'))) {
    Fail 'a version above the pin was absent'
}
if (Test-Relian7ZipInstalled -Entries @(New-7ZipDetectEntry -DisplayName '7-Zip 26.03.00.0 (x64 edition)' -Publisher 'Igor Pavlov' -DisplayVersion '26.03.00.0')) {
    Fail '26.03.00.0 was present'
}
if (Test-Relian7ZipInstalled -Entries @(New-7ZipDetectEntry -DisplayName '7-Zip 26.04.00.0' -Publisher 'Igor Pavlov' -DisplayVersion '26.04.00.0')) {
    Fail 'a name without (x64 edition) was present'
}
if (Test-Relian7ZipInstalled -Entries @(New-7ZipDetectEntry -DisplayName $pinName -Publisher 'Someone Else' -DisplayVersion '26.04.00.0')) {
    Fail 'publisher Someone Else was present'
}
if (Test-Relian7ZipInstalled -Entries @(New-7ZipDetectEntry -DisplayName $pinName -Publisher 'igor pavlov' -DisplayVersion '26.04.00.0')) {
    Fail 'publisher comparison was not exact'
}
if (-not (Test-Relian7ZipInstalled -Entries @(New-7ZipDetectEntry -DisplayName $pinName -Publisher '' -DisplayVersion '26.04.00.0'))) {
    Fail 'empty publisher at the pin was absent'
}
$mixed = @(
    (New-7ZipDetectEntry -DisplayName $pinName -Publisher 'Someone Else' -DisplayVersion '26.04.00.0'),
    (New-7ZipDetectEntry -DisplayName $pinName -Publisher '' -DisplayVersion '26.04.00.0')
)
if (-not (Test-Relian7ZipInstalled -Entries $mixed)) {
    Fail 'a matching entry was hidden by another publisher'
}

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (Test-IntuneTextHasIpv4 -Text 'pin 26.04.00.0') {
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
