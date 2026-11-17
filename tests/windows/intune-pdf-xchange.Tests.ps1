$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/pdf-xchange'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-PdfXchange.ps1'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function New-PdfXchangeDetectEntry {
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
    Fail 'Detect-PdfXchange.ps1 does not exist'
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
if ([string]$meta.displayName -cne 'Relian PDF-XChange PRO') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-PdfXchange.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-PdfXchange.ps1') {
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
$expectedInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PdfXchange.ps1 -DeploymentType Install -Action Install -PinVersion 11.1.2.0'
$expectedUninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PdfXchange.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion 11.1.2.0'
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
    if (-not $command.Contains('-PinVersion 11.1.2.0')) {
        Fail 'command pin is not 11.1.2.0'
    }
}
if (-not $installCommand.Contains('-Action Install')) {
    Fail 'install action'
}
if (-not $uninstallCommand.Contains('-Action Uninstall')) {
    Fail 'uninstall action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-PdfXchange.ps1')) {
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
if (-not $successBlock.Contains("Write-Output 'Relian PDF-XChange PRO'")) {
    Fail 'detection success path does not write Relian PDF-XChange PRO'
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
        'Format-RelianPdfXchangeVersion',
        'Convert-RelianPdfXchangeVersionText',
        'Convert-RelianPdfXchangeComparableVersion',
        'Test-RelianPdfXchangeX64EditionName',
        'Test-RelianPdfXchangeInstalled'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$shortVersion = Convert-RelianPdfXchangeVersionText -Text '11.1.2'
$fullVersion = Convert-RelianPdfXchangeVersionText -Text '11.1.2.0'
if ($shortVersion -isnot [version] -or $fullVersion -isnot [version]) {
    Fail 'version text did not parse'
}
$shortCompare = Convert-RelianPdfXchangeComparableVersion -Version $shortVersion
$fullCompare = Convert-RelianPdfXchangeComparableVersion -Version $fullVersion
if ($shortCompare.CompareTo($fullCompare) -ne 0) {
    Fail '11.1.2 and 11.1.2.0 are not the same release'
}

$pinName = 'PDF-XChange PRO'
$v11Publisher = 'PDF-XChange Co Ltd.'
$v10Publisher = 'Tracker Software Products (Canada) Ltd.'
if (-not (Test-RelianPdfXchangeInstalled -Entries @(New-PdfXchangeDetectEntry -DisplayName $pinName -Publisher $v11Publisher -DisplayVersion '11.1.2.0'))) {
    Fail 'PRO at the pin was absent'
}
if (-not (Test-RelianPdfXchangeInstalled -Entries @(New-PdfXchangeDetectEntry -DisplayName $pinName -Publisher $v11Publisher -DisplayVersion (@(11, 2, 0, 0) -join '.')))) {
    Fail 'a version above the pin was absent'
}
# Older installs must read as absent so Intune runs the in-place upgrade.
foreach ($old in @(@('10.6.0.396', $v10Publisher), @('10.3.0.386', $v10Publisher), @((@(11, 0, 1, 0) -join '.'), $v11Publisher))) {
    if (Test-RelianPdfXchangeInstalled -Entries @(New-PdfXchangeDetectEntry -DisplayName $pinName -Publisher $old[1] -DisplayVersion $old[0])) {
        Fail "$($old[0]) was present"
    }
}
if (-not (Test-RelianPdfXchangeInstalled -Entries @(New-PdfXchangeDetectEntry -DisplayName $pinName -Publisher $v10Publisher -DisplayVersion '11.1.2.0'))) {
    Fail 'the Tracker Software publisher was not accepted'
}
foreach ($otherName in @('PDF-XChange Editor', 'PDF-XChange PRO 11', 'pdf-xchange pro')) {
    if (Test-RelianPdfXchangeInstalled -Entries @(New-PdfXchangeDetectEntry -DisplayName $otherName -Publisher $v11Publisher -DisplayVersion '11.1.2.0')) {
        Fail "'$otherName' counted as PRO"
    }
}
if (Test-RelianPdfXchangeInstalled -Entries @(New-PdfXchangeDetectEntry -DisplayName $pinName -Publisher 'Someone Else' -DisplayVersion '11.1.2.0')) {
    Fail 'publisher Someone Else was present'
}
if (-not (Test-RelianPdfXchangeInstalled -Entries @(New-PdfXchangeDetectEntry -DisplayName $pinName -Publisher '' -DisplayVersion '11.1.2.0'))) {
    Fail 'empty publisher at the pin was absent'
}
$mixed = @(
    (New-PdfXchangeDetectEntry -DisplayName $pinName -Publisher 'Someone Else' -DisplayVersion '11.1.2.0'),
    (New-PdfXchangeDetectEntry -DisplayName $pinName -Publisher '' -DisplayVersion '11.1.2.0')
)
if (-not (Test-RelianPdfXchangeInstalled -Entries $mixed)) {
    Fail 'a matching entry was hidden by another publisher'
}

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
# The pin 11.1.2.0 has the shape of an address. It is the only such text allowed.
$pinText = (@(11, 1, 2, 0) -join '.')
$banned = @(
    ('Le' + 'ague'),
    ('PI' + 'LA'),
    ('Sit' + 'ka'),
    ('/' + 'home' + '/')
)
$committed = @(
    (Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8),
    (Get-Content -LiteralPath $detectPath -Raw -Encoding utf8),
    (Get-Content -LiteralPath (Join-Path $packageDir 'Invoke-PdfXchange.ps1') -Raw -Encoding utf8),
    (Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8)
)
foreach ($text in $committed) {
    if (Test-IntuneTextHasIpv4 -Text $text.Replace($pinText, '')) {
        Fail 'committed file contains an IPv4 address'
    }
    foreach ($word in $banned) {
        if ($text.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Fail 'committed file contains a banned marker'
        }
    }
}
