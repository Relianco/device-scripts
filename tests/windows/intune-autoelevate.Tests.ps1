$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/autoelevate'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-AutoElevate.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/autoelevate.json'
$pin = '2.11.1959'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function New-AutoElevateDetectEntry {
    param(
        [string]$DisplayName,
        [string]$DisplayVersion,
        [string]$Publisher = ''
    )
    return [pscustomobject]@{
        DisplayName    = $DisplayName
        DisplayVersion = $DisplayVersion
        Publisher      = $Publisher
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
    Fail 'Detect-AutoElevate.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/autoelevate.json does not exist'
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
if ([string]$meta.displayName -cne 'Relian AutoElevate') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-AutoElevate.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-AutoElevate.ps1') {
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
$expectedInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AutoElevate.ps1 -DeploymentType Install -Action Install -PinVersion 2.11.1959'
$expectedUninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AutoElevate.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion 2.11.1959'
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
    if (-not $command.Contains('-PinVersion 2.11.1959')) {
        Fail 'command pin is not 2.11.1959'
    }
    if ($command.Contains('-PinVersion 2.11.1959.0')) {
        Fail 'command pin dropped a part'
    }
}
if (-not $installCommand.Contains('-DeploymentType Install') -or -not $installCommand.Contains('-Action Install')) {
    Fail 'install action'
}
if (-not $uninstallCommand.Contains('-DeploymentType Uninstall') -or -not $uninstallCommand.Contains('-Action Uninstall')) {
    Fail 'uninstall action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-AutoElevate')) {
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
$registryAt = $detectText.LastIndexOf('Get-RelianAutoElevateUninstallEntries', [System.StringComparison]::Ordinal)
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
if (-not $detectText.Contains("`$displayName -ne 'AutoElevate'")) {
    Fail 'detection script does not use the finder display name rule'
}
if (-not $detectText.Contains($pin)) {
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
if (-not $successBlock.Contains("Write-Output 'Relian AutoElevate'")) {
    Fail 'detection success path does not write Relian AutoElevate'
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
        'Convert-RelianAutoElevateVersionText',
        'Test-RelianAutoElevateEntry',
        'Test-RelianAutoElevateInstalled'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$threePart = Convert-RelianAutoElevateVersionText -Text '2.11.1959'
$fileVersion = Convert-RelianAutoElevateVersionText -Text '2.11.1959.0'
if ($threePart -isnot [version] -or $fileVersion -isnot [version]) {
    Fail 'version text did not parse'
}
if ($threePart.CompareTo($fileVersion) -ne 0) {
    Fail '2.11.1959 and 2.11.1959.0 are not the same build'
}

if (-not (Test-RelianAutoElevateInstalled -Entries @(New-AutoElevateDetectEntry -DisplayName 'AutoElevate' -DisplayVersion '2.11.1959'))) {
    Fail 'exact name at 2.11.1959 was absent'
}
if (-not (Test-RelianAutoElevateInstalled -Entries @(New-AutoElevateDetectEntry -DisplayName 'AutoElevate' -DisplayVersion '2.11.1959.0'))) {
    Fail 'file version 2.11.1959.0 was absent'
}
if (-not (Test-RelianAutoElevateInstalled -Entries @(New-AutoElevateDetectEntry -DisplayName ' AutoElevate ' -DisplayVersion '2.11.1959'))) {
    Fail 'trimmed display name was absent'
}
if (-not (Test-RelianAutoElevateInstalled -Entries @(New-AutoElevateDetectEntry -DisplayName 'AutoElevate' -DisplayVersion '2.12.0' -Publisher 'Other'))) {
    Fail 'a version above the pin was absent'
}
if (Test-RelianAutoElevateInstalled -Entries @(New-AutoElevateDetectEntry -DisplayName 'AutoElevate Agent' -DisplayVersion '2.11.1959')) {
    Fail 'a different name was present'
}
if (Test-RelianAutoElevateInstalled -Entries @(New-AutoElevateDetectEntry -DisplayName 'AutoElevate' -DisplayVersion '2.11.1958')) {
    Fail 'a version below the pin was present'
}
if (Test-RelianAutoElevateInstalled -Entries @(New-AutoElevateDetectEntry -DisplayName 'AutoElevate' -DisplayVersion '')) {
    Fail 'an empty version was present'
}
$mixed = @(
    (New-AutoElevateDetectEntry -DisplayName 'AutoElevate Agent' -DisplayVersion '9.0.0'),
    (New-AutoElevateDetectEntry -DisplayName 'AutoElevate' -DisplayVersion '2.11.1959')
)
if (-not (Test-RelianAutoElevateInstalled -Entries $mixed)) {
    Fail 'a matching entry was hidden by a different name'
}
if (Test-RelianAutoElevateInstalled -Entries @()) {
    Fail 'no entries was present'
}

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (Test-IntuneTextHasIpv4 -Text 'pin 2.11.1959') {
    Fail 'version pin was treated as an address'
}
$committed = @(
    (Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8),
    (Get-Content -LiteralPath $detectPath -Raw -Encoding utf8),
    (Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8)
)
foreach ($text in $committed) {
    if (Test-IntuneTextHasIpv4 -Text $text) {
        Fail 'committed file contains an IPv4 address'
    }
}
foreach ($packageFile in @(
        @{ Text = $jsonText; Label = 'intune.json' },
        @{ Text = $detectText; Label = 'Detect-AutoElevate.ps1' }
    )) {
    if ($packageFile.Text.Contains('/home/')) {
        Fail "$($packageFile.Label) contains a home path"
    }
}

Write-Output 'intune-autoelevate tests passed'
exit 0
