$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/microsoft-365'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Microsoft365.ps1'
$pin = '16.0.0.0'
$toolVersion = '16.0.20326.20112'
$abovePin = '16.0.19426.20170'
$belowPin = '15.0.5600.1000'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Test-IntuneTextHasIpv4 {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }
    $found = [regex]::Matches($Text, '(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])')
    foreach ($match in $found) {
        # 16.0.0.0 is the sentinel pin, not an address.
        if ($match.Value -ceq '16.0.0.0') {
            continue
        }
        $valid = $true
        foreach ($part in $match.Value.Split('.')) {
            $number = 0
            if (-not [int]::TryParse([string]$part, [ref]$number) -or $number -lt 0 -or $number -gt 255) {
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

function New-Microsoft365ClickToRunEntry {
    param(
        [string]$ProductReleaseIds,
        [string]$VersionToReport
    )
    return [pscustomobject]@{
        ProductReleaseIds = $ProductReleaseIds
        VersionToReport   = $VersionToReport
    }
}

function New-Microsoft365UninstallEntry {
    param(
        [string]$DisplayName,
        [string]$DisplayVersion
    )
    return [pscustomobject]@{
        DisplayName    = $DisplayName
        DisplayVersion = $DisplayVersion
    }
}

if (-not (Test-Path -LiteralPath $jsonPath)) {
    Fail 'windows/packages/microsoft-365/intune.json does not exist'
}
if (-not (Test-Path -LiteralPath $detectPath)) {
    Fail 'Detect-Microsoft365.ps1 does not exist'
}

$jsonText = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8
$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
$testText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8
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
    if ($fieldNames -cnotcontains $field) {
        Fail "intune.json missing $field"
    }
}
if ([string]$meta.displayName -cne 'Relian Microsoft 365 Apps') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-Microsoft365.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-Microsoft365.ps1') {
    Fail "detectionScript '$($meta.detectionScript)'"
}
if ($jsonText -notmatch '"detectReplace"\s*:\s*\[\s*\]') {
    Fail 'detectReplace is not an empty array'
}
if ($null -eq $meta.detectReplace -or @($meta.detectReplace).Count -ne 0) {
    Fail 'detectReplace is not empty'
}
if (-not (Test-Path -LiteralPath (Join-Path $packageDir ([string]$meta.setupFile)))) {
    Fail 'setupFile is not next to intune.json'
}
if (-not (Test-Path -LiteralPath (Join-Path $packageDir ([string]$meta.detectionScript)))) {
    Fail 'detectionScript is not next to intune.json'
}

$expectedInstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Microsoft365.ps1 -DeploymentType Install -Action Install -PinVersion $pin"
$expectedUninstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Microsoft365.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion $pin"
$install = [string]$meta.installCommand
$uninstall = [string]$meta.uninstallCommand
if ($install -cne $expectedInstall) {
    Fail "installCommand '$install'"
}
if ($uninstall -cne $expectedUninstall) {
    Fail "uninstallCommand '$uninstall'"
}
foreach ($command in @($install, $uninstall)) {
    if (-not $command.StartsWith('powershell.exe')) {
        Fail 'command does not use powershell.exe'
    }
    if ($command -match 'pwsh') {
        Fail 'command uses pwsh'
    }
    if (-not $command.Contains('-PinVersion 16.0.0.0')) {
        Fail 'command is missing -PinVersion 16.0.0.0'
    }
    if ($command.Contains($toolVersion)) {
        Fail 'command contains 16.0.20326.20112'
    }
    if ($command.Contains('-SetupSha256')) {
        Fail 'command passes SetupSha256'
    }
}
if (-not $install.Contains('-DeploymentType Install') -or -not $install.Contains('-Action Install')) {
    Fail 'install command action'
}
if (-not $uninstall.Contains('-DeploymentType Uninstall') -or -not $uninstall.Contains('-Action Uninstall')) {
    Fail 'uninstall command action'
}

if ($detectText.Contains('Invoke-Microsoft365')) {
    Fail 'detection script references the installer'
}
if ($detectText -match '(?m)^\s*\.\s') {
    Fail 'detection script dot-sources a file'
}
if ($detectText.Contains('SetupSha256')) {
    Fail 'detection script passes SetupSha256'
}
if ($detectText.Contains('Publisher')) {
    Fail 'detection script checks a publisher'
}
if ($detectText.Contains('Write-Error') -or $detectText.Contains('Write-Warning') -or $detectText.Contains('Write-Host') -or $detectText.Contains('[Console]::Error')) {
    Fail 'detection script writes to the error stream'
}
if (([regex]::Matches($detectText, 'Write-Output')).Count -ne 1) {
    Fail 'detection script does not write exactly one success line'
}
if (-not $detectText.Contains("`$ErrorActionPreference = 'Stop'")) {
    Fail 'detection script does not set ErrorActionPreference'
}
if (-not $detectText.Contains('Set-StrictMode -Version Latest')) {
    Fail 'detection script does not set StrictMode'
}
if ($detectText -notmatch "if \(\`$env:RELIAN_DEPLOY_TEST -eq '1'\) \{\r?\n    return\r?\n\}") {
    Fail 'detection script does not return under the test guard'
}
$guardAt = $detectText.IndexOf('RELIAN_DEPLOY_TEST', [System.StringComparison]::Ordinal)
$exitMatches = [regex]::Matches($detectText, '(?m)^[ \t]*exit\s')
if ($guardAt -lt 0 -or $exitMatches.Count -lt 1 -or $exitMatches[0].Index -lt $guardAt) {
    Fail 'detection exits before the test guard'
}
foreach ($reader in @('Get-Microsoft365DetectClickToRunEntries', 'Get-Microsoft365DetectUninstallEntries')) {
    $readAt = $detectText.LastIndexOf($reader, [System.StringComparison]::Ordinal)
    if ($readAt -lt $guardAt) {
        Fail 'registry is read before the test guard returns'
    }
}
$nativeAt = $detectText.IndexOf('HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration', [System.StringComparison]::Ordinal)
$wowAt = $detectText.IndexOf('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration', [System.StringComparison]::Ordinal)
if ($nativeAt -lt 0 -or $wowAt -lt 0 -or $wowAt -lt $nativeAt) {
    Fail 'detection script is missing a ClickToRun configuration key'
}
foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
    if (-not $detectText.Contains($root)) {
        Fail "detection script is missing $root"
    }
}
if (-not $detectText.Contains("-notcontains 'O365ProPlusRetail'")) {
    Fail 'detection script does not require O365ProPlusRetail'
}
if (-not $detectText.Contains("-notlike 'Microsoft 365 Apps for enterprise*'")) {
    Fail 'detection script does not use the enterprise display name'
}
if (-not $detectText.Contains("Convert-Microsoft365DetectVersionText -Text '16.0.0.0'")) {
    Fail 'detection pin is not 16.0.0.0'
}
if ($detectText.Contains($toolVersion)) {
    Fail 'detection script uses the Office Deployment Tool version'
}

$endingPattern = "(?s)if \(\`$present\) \{\r?\n    Write-Output 'Relian Microsoft 365 Apps'\r?\n    exit 0\r?\n\}\r?\nexit 1\s*\z"
if ($detectText -notmatch $endingPattern) {
    Fail 'success output was missing'
}
$successBlock = $Matches[0]
$successProbe = Join-Path ([System.IO.Path]::GetTempPath()) ('microsoft-365-detect-success-' + [guid]::NewGuid().ToString('n') + '.ps1')
$successOutFile = Join-Path ([System.IO.Path]::GetTempPath()) ('microsoft-365-detect-success-out-' + [guid]::NewGuid().ToString('n'))
$successErrFile = Join-Path ([System.IO.Path]::GetTempPath()) ('microsoft-365-detect-success-err-' + [guid]::NewGuid().ToString('n'))
$failureProbe = Join-Path ([System.IO.Path]::GetTempPath()) ('microsoft-365-detect-failure-' + [guid]::NewGuid().ToString('n') + '.ps1')
$failureOutFile = Join-Path ([System.IO.Path]::GetTempPath()) ('microsoft-365-detect-failure-out-' + [guid]::NewGuid().ToString('n'))
$failureErrFile = Join-Path ([System.IO.Path]::GetTempPath()) ('microsoft-365-detect-failure-err-' + [guid]::NewGuid().ToString('n'))
$successExit = -1
$failureExit = -1
try {
    Set-Content -LiteralPath $successProbe -Value ("`$present = `$true`n" + $successBlock + "`nexit 1`n") -Encoding utf8
    & pwsh -NoProfile -File $successProbe 1> $successOutFile 2> $successErrFile
    $successExit = $LASTEXITCODE
    Set-Content -LiteralPath $failureProbe -Value ("`$present = `$false`n" + $successBlock) -Encoding utf8
    & pwsh -NoProfile -File $failureProbe 1> $failureOutFile 2> $failureErrFile
    $failureExit = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $successProbe, $failureProbe -Force -ErrorAction SilentlyContinue
}
if ($successExit -ne 0) {
    Fail "success path exited $successExit"
}
$successOut = ''
if (Test-Path -LiteralPath $successOutFile) {
    $successOut = [string](Get-Content -LiteralPath $successOutFile -Raw -Encoding utf8)
    Remove-Item -LiteralPath $successOutFile -Force -ErrorAction SilentlyContinue
}
$successErr = ''
if (Test-Path -LiteralPath $successErrFile) {
    $successErr = [string](Get-Content -LiteralPath $successErrFile -Raw -Encoding utf8)
    Remove-Item -LiteralPath $successErrFile -Force -ErrorAction SilentlyContinue
}
if ($successOut.Trim() -cne 'Relian Microsoft 365 Apps') {
    Fail 'success output was missing'
}
if (-not [string]::IsNullOrWhiteSpace($successErr)) {
    Fail 'success path wrote to the error stream'
}
if ($failureExit -ne 1) {
    Fail "failure path exited $failureExit"
}
$failureOut = ''
if (Test-Path -LiteralPath $failureOutFile) {
    $failureOut = [string](Get-Content -LiteralPath $failureOutFile -Raw -Encoding utf8)
    Remove-Item -LiteralPath $failureOutFile -Force -ErrorAction SilentlyContinue
}
$failureErr = ''
if (Test-Path -LiteralPath $failureErrFile) {
    $failureErr = [string](Get-Content -LiteralPath $failureErrFile -Raw -Encoding utf8)
    Remove-Item -LiteralPath $failureErrFile -Force -ErrorAction SilentlyContinue
}
if (-not [string]::IsNullOrWhiteSpace($failureOut) -or -not [string]::IsNullOrWhiteSpace($failureErr)) {
    Fail 'failure path wrote output'
}

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (Test-IntuneTextHasIpv4 -Text $pin) {
    Fail 'sentinel pin was treated as an address'
}
if (Test-IntuneTextHasIpv4 -Text $toolVersion) {
    Fail 'tool version was treated as an address'
}
foreach ($packageFile in @(
        @{ Text = $jsonText; Label = 'intune.json' },
        @{ Text = $detectText; Label = 'Detect-Microsoft365.ps1' }
    )) {
    if ($packageFile.Text.Contains('/home/')) {
        Fail "$($packageFile.Label) contains a home path"
    }
    if ($packageFile.Text.Contains($toolVersion)) {
        Fail "$($packageFile.Label) uses the Office Deployment Tool version"
    }
    if (Test-IntuneTextHasIpv4 -Text $packageFile.Text) {
        Fail "$($packageFile.Label) contains an IPv4 address"
    }
}
if (Test-IntuneTextHasIpv4 -Text $testText) {
    Fail 'intune-microsoft-365.Tests.ps1 contains an IPv4 address'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

if (-not (Get-Command Test-Microsoft365DetectInstalled -ErrorAction SilentlyContinue)) {
    Fail 'Test-Microsoft365DetectInstalled was not defined'
}

$retail = New-Microsoft365ClickToRunEntry -ProductReleaseIds 'O365ProPlusRetail' -VersionToReport $abovePin
if (-not (Test-Microsoft365DetectInstalled -ClickToRunEntries @($retail))) {
    Fail 'a ClickToRun entry with O365ProPlusRetail was absent'
}

$atPin = New-Microsoft365ClickToRunEntry -ProductReleaseIds 'O365ProPlusRetail' -VersionToReport $pin
if (-not (Test-Microsoft365DetectInstalled -ClickToRunEntries @($atPin))) {
    Fail 'a ClickToRun entry at the pin was absent'
}

$spaced = New-Microsoft365ClickToRunEntry -ProductReleaseIds ' VisioProRetail, O365ProPlusRetail ' -VersionToReport " $abovePin "
if (-not (Test-Microsoft365DetectInstalled -ClickToRunEntries @($spaced))) {
    Fail 'a ClickToRun token list containing O365ProPlusRetail was absent'
}

$lowerId = New-Microsoft365ClickToRunEntry -ProductReleaseIds 'o365proplusretail' -VersionToReport $abovePin
if (-not (Test-Microsoft365DetectInstalled -ClickToRunEntries @($lowerId))) {
    Fail 'O365ProPlusRetail comparison was case-sensitive'
}

$shortVersion = New-Microsoft365ClickToRunEntry -ProductReleaseIds 'O365ProPlusRetail' -VersionToReport '16.0'
if (-not (Test-Microsoft365DetectInstalled -ClickToRunEntries @($shortVersion))) {
    Fail 'a two-part build at the pin was absent'
}

$threePart = New-Microsoft365ClickToRunEntry -ProductReleaseIds 'O365ProPlusRetail' -VersionToReport '16.0.0'
if (-not (Test-Microsoft365DetectInstalled -ClickToRunEntries @($threePart))) {
    Fail 'a three-part build at the pin was absent'
}

$withPublisher = New-Microsoft365ClickToRunEntry -ProductReleaseIds 'O365ProPlusRetail' -VersionToReport $abovePin
$withPublisher | Add-Member -NotePropertyName 'Publisher' -NotePropertyValue 'Other'
if (-not (Test-Microsoft365DetectInstalled -ClickToRunEntries @($withPublisher))) {
    Fail 'a publisher the installer does not read was treated as absent'
}

$business = New-Microsoft365ClickToRunEntry -ProductReleaseIds 'O365BusinessRetail' -VersionToReport $abovePin
if (Test-Microsoft365DetectInstalled -ClickToRunEntries @($business)) {
    Fail 'a ClickToRun entry without O365ProPlusRetail was present'
}

$notAToken = New-Microsoft365ClickToRunEntry -ProductReleaseIds 'O365ProPlusRetailPreview' -VersionToReport $abovePin
if (Test-Microsoft365DetectInstalled -ClickToRunEntries @($notAToken)) {
    Fail 'a product id that only contains the token text was present'
}

$below = New-Microsoft365ClickToRunEntry -ProductReleaseIds 'O365ProPlusRetail' -VersionToReport $belowPin
if (Test-Microsoft365DetectInstalled -ClickToRunEntries @($below)) {
    Fail 'a ClickToRun build below the pin was present'
}

$blankVersion = New-Microsoft365ClickToRunEntry -ProductReleaseIds 'O365ProPlusRetail' -VersionToReport ''
if (Test-Microsoft365DetectInstalled -ClickToRunEntries @($blankVersion)) {
    Fail 'a ClickToRun entry without VersionToReport was present'
}

$badVersion = New-Microsoft365ClickToRunEntry -ProductReleaseIds 'O365ProPlusRetail' -VersionToReport 'not-a-version'
if (-not (Test-Microsoft365DetectInstalled -ClickToRunEntries @($null, $badVersion, $retail))) {
    Fail 'an unparsed VersionToReport stopped the search'
}

$olderFirst = New-Microsoft365ClickToRunEntry -ProductReleaseIds 'O365ProPlusRetail' -VersionToReport $belowPin
if (Test-Microsoft365DetectInstalled -ClickToRunEntries @($olderFirst, $retail)) {
    Fail 'a later ClickToRun entry replaced the first reported version'
}

if (Test-Microsoft365DetectInstalled -ClickToRunEntries @() -UninstallEntries @()) {
    Fail 'no entries was present'
}

$enterprise = New-Microsoft365UninstallEntry -DisplayName 'Microsoft 365 Apps for enterprise' -DisplayVersion $abovePin
if (-not (Test-Microsoft365DetectInstalled -UninstallEntries @($enterprise))) {
    Fail 'Microsoft 365 Apps for enterprise was absent'
}

$suffixed = New-Microsoft365UninstallEntry -DisplayName 'Microsoft 365 Apps for enterprise - en-us' -DisplayVersion $abovePin
if (-not (Test-Microsoft365DetectInstalled -UninstallEntries @($suffixed))) {
    Fail 'a suffixed enterprise display name was absent'
}

$trimmed = New-Microsoft365UninstallEntry -DisplayName ' Microsoft 365 Apps for enterprise ' -DisplayVersion $abovePin
if (-not (Test-Microsoft365DetectInstalled -UninstallEntries @($trimmed))) {
    Fail 'a trimmed enterprise display name was absent'
}

$lowerName = New-Microsoft365UninstallEntry -DisplayName 'microsoft 365 apps for enterprise' -DisplayVersion $abovePin
if (-not (Test-Microsoft365DetectInstalled -UninstallEntries @($lowerName))) {
    Fail 'enterprise display name comparison was case-sensitive'
}

$appsForBusiness = New-Microsoft365UninstallEntry -DisplayName 'Microsoft 365 Apps for business' -DisplayVersion $abovePin
if (Test-Microsoft365DetectInstalled -UninstallEntries @($appsForBusiness)) {
    Fail 'Microsoft 365 Apps for business was present'
}

$office = New-Microsoft365UninstallEntry -DisplayName 'Microsoft Office' -DisplayVersion $abovePin
if (Test-Microsoft365DetectInstalled -UninstallEntries @($office)) {
    Fail 'another Office product was present'
}

$appsOnly = New-Microsoft365UninstallEntry -DisplayName 'Microsoft 365 Apps' -DisplayVersion $abovePin
if (Test-Microsoft365DetectInstalled -UninstallEntries @($appsOnly)) {
    Fail 'Microsoft 365 Apps without enterprise was present'
}

$prefixed = New-Microsoft365UninstallEntry -DisplayName 'Copy of Microsoft 365 Apps for enterprise' -DisplayVersion $abovePin
if (Test-Microsoft365DetectInstalled -UninstallEntries @($prefixed)) {
    Fail 'a display name with a prefix was present'
}

$nameOnly = New-Microsoft365UninstallEntry -DisplayName 'Microsoft 365 Apps for enterprise' -DisplayVersion ''
if (Test-Microsoft365DetectInstalled -UninstallEntries @($nameOnly)) {
    Fail 'an enterprise entry without DisplayVersion was present'
}

$oldEnterprise = New-Microsoft365UninstallEntry -DisplayName 'Microsoft 365 Apps for enterprise' -DisplayVersion $belowPin
if (Test-Microsoft365DetectInstalled -UninstallEntries @($oldEnterprise)) {
    Fail 'an enterprise build below the pin was present'
}

if (-not (Test-Microsoft365DetectInstalled -UninstallEntries @($appsForBusiness, $enterprise))) {
    Fail 'another Office product hid Microsoft 365 Apps for enterprise'
}

if (Test-Microsoft365DetectInstalled -ClickToRunEntries @($below) -UninstallEntries @($enterprise)) {
    Fail 'a ClickToRun version below the pin was replaced by an uninstall entry'
}

if (-not (Test-Microsoft365DetectInstalled -ClickToRunEntries @($business) -UninstallEntries @($enterprise))) {
    Fail 'an enterprise uninstall entry was hidden by another ClickToRun product'
}

if (-not (Test-Microsoft365DetectInstalled -ClickToRunEntries @($badVersion) -UninstallEntries @($enterprise))) {
    Fail 'an unparsed ClickToRun version hid an enterprise uninstall entry'
}

$registryMissing = $true
foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
    $rootPresent = $false
    try {
        $rootPresent = Test-Path -LiteralPath $root
    } catch {
        $rootPresent = $false
    }
    if ($rootPresent) {
        $registryMissing = $false
    }
}
if ($registryMissing) {
    $savedTest = $env:RELIAN_DEPLOY_TEST
    $liveExit = -1
    $liveOutFile = Join-Path ([System.IO.Path]::GetTempPath()) ('microsoft-365-detect-miss-out-' + [guid]::NewGuid().ToString('n'))
    $liveErrFile = Join-Path ([System.IO.Path]::GetTempPath()) ('microsoft-365-detect-miss-err-' + [guid]::NewGuid().ToString('n'))
    try {
        Remove-Item -Path Env:RELIAN_DEPLOY_TEST -ErrorAction SilentlyContinue
        & pwsh -NoProfile -File $detectPath 1> $liveOutFile 2> $liveErrFile
        $liveExit = $LASTEXITCODE
    } finally {
        $env:RELIAN_DEPLOY_TEST = $savedTest
    }
    $liveOut = ''
    if (Test-Path -LiteralPath $liveOutFile) {
        $liveOut = [string](Get-Content -LiteralPath $liveOutFile -Raw -Encoding utf8)
        Remove-Item -LiteralPath $liveOutFile -Force -ErrorAction SilentlyContinue
    }
    $liveErr = ''
    if (Test-Path -LiteralPath $liveErrFile) {
        $liveErr = [string](Get-Content -LiteralPath $liveErrFile -Raw -Encoding utf8)
        Remove-Item -LiteralPath $liveErrFile -Force -ErrorAction SilentlyContinue
    }
    if ($liveExit -ne 1) {
        Fail "missing registry detection exited $liveExit"
    }
    if (-not [string]::IsNullOrWhiteSpace($liveOut) -or -not [string]::IsNullOrWhiteSpace($liveErr)) {
        Fail 'missing registry detection wrote output'
    }
}

Write-Output 'PASS intune-microsoft-365'
exit 0
