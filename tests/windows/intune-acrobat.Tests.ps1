$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/acrobat'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Acrobat.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/acrobat.json'
$pin = '0.0.0.0'
$editionPlaceholder = '{env:ACROBAT_EDITION}'
$quotedEdition = '"' + $editionPlaceholder + '"'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function New-AcrobatDetectEntry {
    param(
        [string]$DisplayName,
        [string]$DisplayVersion
    )
    return [pscustomobject]@{
        DisplayName    = $DisplayName
        DisplayVersion = $DisplayVersion
    }
}

function Test-IntuneTextHasIpv4 {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }
    # 0.0.0.0 is the Acrobat pin, not an address. Any other four-part address fails.
    $found = [regex]::Matches($Text, '(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])')
    foreach ($match in @($found)) {
        if ($null -eq $match) {
            continue
        }
        if ($match.Value -ceq '0.0.0.0') {
            continue
        }
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

foreach ($path in @($jsonPath, $detectPath, $releasePath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "missing $path"
    }
}
$setupOnDisk = Join-Path $packageDir 'Invoke-Acrobat.ps1'
if (-not (Test-Path -LiteralPath $setupOnDisk)) {
    Fail 'Invoke-Acrobat.ps1 does not exist'
}

$releaseText = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8
$release = $releaseText | ConvertFrom-Json
$releaseNames = @($release.PSObject.Properties.Name)
if ($releaseNames -contains 'version') {
    Fail 'release file is treated as having a version key'
}
if ($releaseText -match '(?m)^\s*"version"\s*:') {
    Fail 'release file is treated as having a version key'
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
    'detectReplace',
    'editions'
)
if ($fieldNames.Count -ne $expectedFields.Count) {
    Fail 'intune.json field count'
}
foreach ($field in $expectedFields) {
    if ($fieldNames -notcontains $field) {
        Fail "intune.json missing $field"
    }
}
if ([string]$meta.displayName -cne 'Relian Adobe Acrobat') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-Acrobat.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-Acrobat.ps1') {
    Fail "detectionScript '$($meta.detectionScript)'"
}
if ($jsonText -notmatch '"detectReplace"\s*:\s*\[\s*\]') {
    Fail 'detectReplace must be an empty array'
}
if ($null -eq $meta.detectReplace -or @($meta.detectReplace).Count -ne 0) {
    Fail 'detectReplace is not empty'
}
$editions = @($meta.editions)
if ($editions.Count -ne 2 -or [string]$editions[0] -cne 'Standard' -or [string]$editions[1] -cne 'Pro') {
    Fail 'editions must be Standard and Pro'
}
if ($jsonText -match '"version"\s*:') {
    Fail 'release file is treated as having a version key'
}

if (-not (Test-Path -LiteralPath (Join-Path $packageDir ([string]$meta.setupFile)))) {
    Fail 'setupFile is not next to intune.json'
}
if (-not (Test-Path -LiteralPath (Join-Path $packageDir ([string]$meta.detectionScript)))) {
    Fail 'detectionScript is not next to intune.json'
}

$expectedInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Acrobat.ps1 -DeploymentType Install -Action Install -Edition ' + $quotedEdition + ' -PinVersion ' + $pin
$expectedUninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Acrobat.ps1 -DeploymentType Uninstall -Action Uninstall -Edition ' + $quotedEdition + ' -PinVersion ' + $pin
$install = [string]$meta.installCommand
$uninstall = [string]$meta.uninstallCommand
foreach ($command in @($install, $uninstall)) {
    if (-not $command.StartsWith('powershell.exe')) {
        Fail 'command does not use powershell.exe'
    }
    if ($command.Contains('pwsh')) {
        Fail 'command uses pwsh'
    }
    if ($command -notlike ('*' + $editionPlaceholder + '*')) {
        Fail 'command lacks {env:ACROBAT_EDITION}'
    }
    if ($command -notlike ('*' + $pin + '*')) {
        Fail 'command lacks 0.0.0.0'
    }
    if ($command.Contains('InstallerUrl') -or $command.Contains('InstallerSha256')) {
        Fail 'command passes an installer override'
    }
    $editionArgs = [regex]::Matches($command, '-Edition\s+(\S+)')
    if ($editionArgs.Count -ne 1 -or [string]$editionArgs[0].Groups[1].Value -cne $quotedEdition) {
        Fail 'command contains a baked edition'
    }
    if ($command -match '(?<![A-Za-z0-9_])(Standard|Pro)(?![A-Za-z0-9_])') {
        Fail 'command contains a baked edition'
    }
}
if ($install -cne $expectedInstall) {
    Fail 'install command'
}
if ($uninstall -cne $expectedUninstall) {
    Fail 'uninstall command'
}
if (-not $install.Contains('-DeploymentType Install') -or -not $install.Contains('-Action Install')) {
    Fail 'install action'
}
if (-not $uninstall.Contains('-DeploymentType Uninstall') -or -not $uninstall.Contains('-Action Uninstall')) {
    Fail 'uninstall action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-Acrobat')) {
    Fail 'detection script references the installer'
}
if ($detectText.Contains('.ps1')) {
    Fail 'detection script references another script'
}
if ($detectText -match '(?m)^\s*\.\s') {
    Fail 'detection script dot-sources a file'
}
if ($detectText.Contains('Publisher')) {
    Fail 'detection script checks the publisher'
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
$registryAt = $detectText.LastIndexOf('Get-RelianAcrobatUninstallEntries', [System.StringComparison]::Ordinal)
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
if (-not $detectText.Contains($pin)) {
    Fail 'detection script is missing the pin'
}
if (-not $detectText.Contains("-ceq 'Adobe Acrobat Reader'")) {
    Fail 'detection script does not exclude the exact Reader name'
}
if (-not $detectText.Contains("StartsWith('Adobe Acrobat Reader', [System.StringComparison]::Ordinal)")) {
    Fail 'detection script does not exclude Reader names'
}
if (-not $detectText.Contains("StartsWith('Adobe Acrobat', [System.StringComparison]::Ordinal)")) {
    Fail 'detection script does not use the Acrobat display-name rule'
}
foreach ($bannedCall in @('Write-Error', 'Write-Warning', 'Write-Host', '[Console]::Error')) {
    if ($detectText.Contains($bannedCall)) {
        Fail "detection script contains $bannedCall"
    }
}
$outputCount = ([regex]::Matches($detectText, 'Write-Output')).Count
if ($outputCount -eq 0) {
    Fail 'Write-Output is missing'
}
if ($outputCount -ne 1) {
    Fail 'detection script writes more than the success line'
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
if (-not $successBlock.Contains("Write-Output 'Relian Adobe Acrobat'")) {
    Fail 'Write-Output is missing'
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
$versionAccess = '$release' + '.version'
if ($jsonText.Contains($versionAccess) -or $detectText.Contains($versionAccess)) {
    Fail 'release file is treated as having a version key'
}

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (Test-IntuneTextHasIpv4 -Text $pin) {
    Fail 'version sentinel was treated as an address'
}
if (Test-IntuneTextHasIpv4 -Text '24.2.22031.0') {
    Fail 'acrobat version was treated as an address'
}

$testText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8
if ($testText.Contains($versionAccess)) {
    Fail 'release file is treated as having a version key'
}
foreach ($text in @($jsonText, $detectText, $testText)) {
    if (Test-IntuneTextHasIpv4 -Text $text) {
        Fail 'committed file contains an IPv4 address'
    }
}
foreach ($packageFile in @(
        @{ Text = $jsonText; Label = 'intune.json' },
        @{ Text = $detectText; Label = 'Detect-Acrobat.ps1' }
    )) {
    if ($packageFile.Text.Contains('/home/')) {
        Fail "$($packageFile.Label) contains a home path"
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

foreach ($command in @(
        'Format-RelianAcrobatVersion',
        'Convert-RelianAcrobatVersionText',
        'Test-RelianAcrobatDisplayName',
        'Test-RelianAcrobatInstalled'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$padded = Convert-RelianAcrobatVersionText -Text '24.2.22031'
if ($padded -isnot [version]) {
    Fail 'short version did not parse'
}
if ((Format-RelianAcrobatVersion -Version $padded) -cne '24.2.22031.0') {
    Fail 'short version did not normalize'
}

if (Test-RelianAcrobatDisplayName -Name 'Adobe Acrobat Reader') {
    Fail 'Adobe Acrobat Reader was present'
}
if (Test-RelianAcrobatDisplayName -Name 'Adobe Acrobat Reader DC') {
    Fail 'Adobe Acrobat Reader DC was present'
}
if (Test-RelianAcrobatDisplayName -Name 'Adobe Acrobat Reader (64-bit)') {
    Fail 'Adobe Acrobat Reader (64-bit) was present'
}
if (Test-RelianAcrobatDisplayName -Name ' Adobe Acrobat Reader ') {
    Fail 'trimmed Reader name was present'
}
if (-not (Test-RelianAcrobatDisplayName -Name 'Adobe Acrobat Pro')) {
    Fail 'Adobe Acrobat Pro was absent'
}
if (-not (Test-RelianAcrobatDisplayName -Name 'Adobe Acrobat Standard')) {
    Fail 'Adobe Acrobat Standard was absent'
}
if (-not (Test-RelianAcrobatDisplayName -Name ' Adobe Acrobat Standard ')) {
    Fail 'trimmed Standard name was absent'
}
if (-not (Test-RelianAcrobatDisplayName -Name 'Adobe Acrobat')) {
    Fail 'Adobe Acrobat was absent'
}
if (-not (Test-RelianAcrobatDisplayName -Name 'Adobe Acrobat (64-bit)')) {
    Fail 'Adobe Acrobat (64-bit) was absent'
}
if (-not (Test-RelianAcrobatDisplayName -Name 'Adobe Acrobat Pro DC')) {
    Fail 'Adobe Acrobat Pro DC was absent'
}
foreach ($absentName in @('adobe acrobat pro', 'Not Adobe Acrobat', 'Notepad', '')) {
    if (Test-RelianAcrobatDisplayName -Name $absentName) {
        Fail "display name '$absentName' matched"
    }
}

$above = '24.2.22031.0'
if (-not (Test-RelianAcrobatInstalled -Entries @(New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Pro' -DisplayVersion $above))) {
    Fail 'Adobe Acrobat Pro was absent'
}
if (-not (Test-RelianAcrobatInstalled -Entries @(New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Standard' -DisplayVersion $above))) {
    Fail 'Adobe Acrobat Standard was absent'
}
if (-not (Test-RelianAcrobatInstalled -Entries @(New-AcrobatDetectEntry -DisplayName ' Adobe Acrobat Pro ' -DisplayVersion '24.2.22031'))) {
    Fail 'trimmed Pro at the short version was absent'
}
if (-not (Test-RelianAcrobatInstalled -Entries @(New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Standard' -DisplayVersion $pin))) {
    Fail 'Standard at the pin was absent'
}
if (-not (Test-RelianAcrobatInstalled -Entries @(New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat (64-bit)' -DisplayVersion '24.3.22032.0'))) {
    Fail 'Adobe Acrobat (64-bit) above the pin was absent'
}
if (Test-RelianAcrobatInstalled -Entries @(New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Reader' -DisplayVersion $above)) {
    Fail 'Adobe Acrobat Reader was present'
}
if (Test-RelianAcrobatInstalled -Entries @(New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Reader DC' -DisplayVersion $above)) {
    Fail 'Adobe Acrobat Reader DC was present'
}
if (Test-RelianAcrobatInstalled -Entries @(New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Reader (64-bit)' -DisplayVersion '24.3.22032.0')) {
    Fail 'Adobe Acrobat Reader (64-bit) was present'
}
if (Test-RelianAcrobatInstalled -Entries @(New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Pro' -DisplayVersion '24.1.22030.0') -PinVersion '24.2.22031.0') {
    Fail 'Pro below the pin was present'
}
if (-not (Test-RelianAcrobatInstalled -Entries @(New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Pro' -DisplayVersion '24.2.22031.0') -PinVersion '24.2.22031.0')) {
    Fail 'Pro at an explicit pin was absent'
}
if (Test-RelianAcrobatInstalled -Entries @(New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Standard' -DisplayVersion '')) {
    Fail 'Standard without a version was present'
}
if (Test-RelianAcrobatInstalled -Entries @(New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Pro' -DisplayVersion 'not-a-version')) {
    Fail 'Pro with an unreadable version was present'
}
$mixed = @(
    (New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Reader' -DisplayVersion $above),
    (New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Reader DC' -DisplayVersion $above),
    (New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Standard' -DisplayVersion 'not-a-version'),
    (New-AcrobatDetectEntry -DisplayName 'Adobe Acrobat Pro' -DisplayVersion $above)
)
if (-not (Test-RelianAcrobatInstalled -Entries $mixed)) {
    Fail 'Pro was hidden by Reader or an unreadable version'
}
if (Test-RelianAcrobatInstalled -Entries @()) {
    Fail 'no entries was present'
}
if (Test-RelianAcrobatInstalled -Entries @($null)) {
    Fail 'null entry was present'
}

Write-Output 'intune-acrobat tests passed'
exit 0
