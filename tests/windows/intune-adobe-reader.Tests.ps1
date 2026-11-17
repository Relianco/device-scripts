$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/adobe-reader'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-AdobeReader.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/adobe-reader.json'
$pin = '26.2.22031.0'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function New-AdobeReaderDetectEntry {
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
    Fail 'Detect-AdobeReader.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/adobe-reader.json does not exist'
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
if ([string]$meta.displayName -cne 'Relian Adobe Acrobat Reader') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-AdobeReader.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-AdobeReader.ps1') {
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
$expectedInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AdobeReader.ps1 -DeploymentType Install -Action Install -PinVersion ' + $pin
$expectedUninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-AdobeReader.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion ' + $pin
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
    if (-not $command.Contains('-PinVersion ' + $pin)) {
        Fail 'command pin is not 26.2.22031.0'
    }
}
if (-not $installCommand.Contains('-DeploymentType Install') -or -not $installCommand.Contains('-Action Install')) {
    Fail 'install action'
}
if (-not $uninstallCommand.Contains('-DeploymentType Uninstall') -or -not $uninstallCommand.Contains('-Action Uninstall')) {
    Fail 'uninstall action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-AdobeReader')) {
    Fail 'detection script references the installer'
}
if ($detectText.Contains('.ps1')) {
    Fail 'detection script references another script'
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
$registryAt = $detectText.LastIndexOf('Get-RelianAdobeReaderUninstallEntries', [System.StringComparison]::Ordinal)
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
if (-not $detectText.Contains("StartsWith('Adobe Acrobat Reader', [System.StringComparison]::Ordinal)")) {
    Fail 'detection script does not use the Reader display-name rule'
}
foreach ($bannedCall in @('Write-Error', 'Write-Host', '[Console]::Error')) {
    if ($detectText.Contains($bannedCall)) {
        Fail "detection script contains $bannedCall"
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
if (-not $successBlock.Contains("Write-Output 'Relian Adobe Acrobat Reader'")) {
    Fail 'detection success path does not write Relian Adobe Acrobat Reader'
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
        'Format-RelianAdobeReaderVersion',
        'Convert-RelianAdobeReaderVersionText',
        'Test-RelianAdobeReaderDisplayName',
        'Test-RelianAdobeReaderInstalled'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$padded = Convert-RelianAdobeReaderVersionText -Text '26.002.22031'
if ($padded -isnot [version]) {
    Fail 'padded version did not parse'
}
if ((Format-RelianAdobeReaderVersion -Version $padded) -cne $pin) {
    Fail 'adobe continuous version did not normalize'
}

if (-not (Test-RelianAdobeReaderDisplayName -Name 'Adobe Acrobat Reader')) {
    Fail 'exact Reader name was rejected'
}
if (-not (Test-RelianAdobeReaderDisplayName -Name 'Adobe Acrobat Reader DC')) {
    Fail 'Reader DC name was rejected'
}
if (-not (Test-RelianAdobeReaderDisplayName -Name 'Adobe Acrobat Reader (64-bit)')) {
    Fail 'Reader 64-bit name was rejected'
}
if (-not (Test-RelianAdobeReaderDisplayName -Name ' Adobe Acrobat Reader ')) {
    Fail 'trimmed Reader name was rejected'
}
$absentNames = @(
    'Adobe Acrobat',
    'Adobe Acrobat (64-bit)',
    'Adobe Acrobat Pro',
    'Adobe Acrobat Standard',
    'Adobe Acrobat Pro DC',
    'adobe acrobat reader',
    'Not Adobe Acrobat Reader',
    ''
)
foreach ($name in $absentNames) {
    if (Test-RelianAdobeReaderDisplayName -Name $name) {
        Fail "display name '$name' matched"
    }
}

if (-not (Test-RelianAdobeReaderInstalled -Entries @(New-AdobeReaderDetectEntry -DisplayName 'Adobe Acrobat Reader' -DisplayVersion $pin))) {
    Fail 'Adobe Acrobat Reader at the pin was absent'
}
if (-not (Test-RelianAdobeReaderInstalled -Entries @(New-AdobeReaderDetectEntry -DisplayName 'Adobe Acrobat Reader DC' -DisplayVersion '26.002.22031'))) {
    Fail 'Reader DC at the padded pin was absent'
}
if (-not (Test-RelianAdobeReaderInstalled -Entries @(New-AdobeReaderDetectEntry -DisplayName ' Adobe Acrobat Reader ' -DisplayVersion '26.2.22031'))) {
    Fail 'trimmed Reader at the three-part pin was absent'
}
if (-not (Test-RelianAdobeReaderInstalled -Entries @(New-AdobeReaderDetectEntry -DisplayName 'Adobe Acrobat Reader (64-bit)' -DisplayVersion '26.2.22032.0' -Publisher 'Other'))) {
    Fail 'Reader above the pin was absent'
}
if (-not (Test-RelianAdobeReaderInstalled -Entries @(New-AdobeReaderDetectEntry -DisplayName 'Adobe Acrobat Reader' -DisplayVersion '26.002.22032'))) {
    Fail 'padded Reader above the pin was absent'
}
$mixed = @(
    (New-AdobeReaderDetectEntry -DisplayName 'Adobe Acrobat' -DisplayVersion '26.2.22032.0'),
    (New-AdobeReaderDetectEntry -DisplayName 'Adobe Acrobat Reader' -DisplayVersion 'not-a-version'),
    (New-AdobeReaderDetectEntry -DisplayName 'Adobe Acrobat Reader DC' -DisplayVersion $pin)
)
if (-not (Test-RelianAdobeReaderInstalled -Entries $mixed)) {
    Fail 'Reader was hidden by Acrobat or an unreadable version'
}
foreach ($name in $absentNames) {
    if (Test-RelianAdobeReaderInstalled -Entries @(New-AdobeReaderDetectEntry -DisplayName $name -DisplayVersion '26.2.22032.0')) {
        Fail "'$name' was present"
    }
}
if (Test-RelianAdobeReaderInstalled -Entries @(New-AdobeReaderDetectEntry -DisplayName 'Adobe Acrobat Reader' -DisplayVersion '26.2.22030.0')) {
    Fail 'Reader below the pin was present'
}
if (Test-RelianAdobeReaderInstalled -Entries @(New-AdobeReaderDetectEntry -DisplayName 'Adobe Acrobat Reader' -DisplayVersion '')) {
    Fail 'Reader without a version was present'
}
if (Test-RelianAdobeReaderInstalled -Entries @()) {
    Fail 'no entries was present'
}
if (Test-RelianAdobeReaderInstalled -Entries @($null)) {
    Fail 'null entry was present'
}

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (Test-IntuneTextHasIpv4 -Text ('pin ' + $pin)) {
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
foreach ($text in @($jsonText, $detectText)) {
    if ($text.Contains('/home/')) {
        Fail 'committed file contains a home path'
    }
}

Write-Output 'intune-adobe-reader tests passed'
exit 0
