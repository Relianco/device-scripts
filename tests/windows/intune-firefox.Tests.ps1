$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/firefox'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Firefox.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/firefox.json'
$pin = '158.0'
$productVersion = $pin + '.0.0'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Assert-CleanText {
    param(
        [string]$Label,
        [string]$Text
    )
    if ([string]::IsNullOrEmpty($Text)) {
        Fail "$Label is empty"
    }
    $banned = @(
        -join @('Le', 'ague'),
        -join @('PI', 'LA'),
        -join @('Sit', 'ka'),
        -join @('/', 'home', '/')
    )
    foreach ($word in $banned) {
        if ($Text.Contains($word)) {
            Fail "$Label contains forbidden text"
        }
    }
    if ($Text.Contains($productVersion)) {
        Fail "$Label contains the product version"
    }
    $ipv4 = [regex]'(?<![0-9])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?![0-9])'
    foreach ($match in $ipv4.Matches($Text)) {
        $valid = $true
        foreach ($part in $match.Value.Split('.')) {
            $number = 0
            if (-not [int]::TryParse($part, [ref]$number) -or $number -gt 255) {
                $valid = $false
            }
        }
        if ($valid) {
            Fail "$Label contains an IPv4 address"
        }
    }
}

function New-FirefoxUninstallEntry {
    param(
        [string]$DisplayName,
        [string]$DisplayVersion,
        [switch]$OmitVersion
    )
    if ($OmitVersion) {
        return [pscustomobject]@{
            DisplayName = $DisplayName
        }
    }
    return [pscustomobject]@{
        DisplayName    = $DisplayName
        DisplayVersion = $DisplayVersion
    }
}

if (-not (Test-Path -LiteralPath $jsonPath)) {
    Fail 'windows/packages/firefox/intune.json does not exist'
}
if (-not (Test-Path -LiteralPath $detectPath)) {
    Fail 'Detect-Firefox.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/firefox.json does not exist'
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.version -cne $pin) {
    Fail "release version '$($release.version)' is not $pin"
}

$jsonText = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8
$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
$testText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8
Assert-CleanText -Label 'intune.json' -Text $jsonText
Assert-CleanText -Label 'Detect-Firefox.ps1' -Text $detectText
Assert-CleanText -Label 'intune-firefox.Tests.ps1' -Text $testText

$json = $jsonText | ConvertFrom-Json
foreach ($name in @(
        'displayName',
        'publisher',
        'setupFile',
        'installCommand',
        'uninstallCommand',
        'detectionScript',
        'detectReplace'
    )) {
    $names = @($json.PSObject.Properties.Name)
    if ($names -cnotcontains $name) {
        Fail "intune.json is missing $name"
    }
}
if ([string]$json.displayName -cne 'Relian Mozilla Firefox') {
    Fail "displayName '$($json.displayName)'"
}
if ([string]$json.publisher -cne 'Relian') {
    Fail "publisher '$($json.publisher)'"
}
if ([string]$json.setupFile -cne 'Invoke-Firefox.ps1') {
    Fail "setupFile '$($json.setupFile)'"
}
if ([string]$json.detectionScript -cne 'Detect-Firefox.ps1') {
    Fail "detectionScript '$($json.detectionScript)'"
}
if ($jsonText -notmatch '"detectReplace"\s*:\s*\[\s*\]') {
    Fail 'detectReplace is not an empty array'
}
if ($null -ne $json.detectReplace -and @($json.detectReplace).Count -ne 0) {
    Fail 'detectReplace is not empty'
}

$setupPath = Join-Path $packageDir ([string]$json.setupFile)
$detectionPath = Join-Path $packageDir ([string]$json.detectionScript)
if (-not (Test-Path -LiteralPath $setupPath)) {
    Fail 'setupFile is not next to intune.json'
}
if (-not (Test-Path -LiteralPath $detectionPath)) {
    Fail 'detectionScript is not next to intune.json'
}

$expectedInstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Firefox.ps1 -DeploymentType Install -Action Install -PinVersion $pin"
$expectedUninstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Firefox.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion $pin"
if ([string]$json.installCommand -cne $expectedInstall) {
    Fail "installCommand '$($json.installCommand)'"
}
if ([string]$json.uninstallCommand -cne $expectedUninstall) {
    Fail "uninstallCommand '$($json.uninstallCommand)'"
}
foreach ($command in @([string]$json.installCommand, [string]$json.uninstallCommand)) {
    if ($command -notlike 'powershell.exe *') {
        Fail "command does not use powershell.exe: $command"
    }
    if ($command -match 'pwsh') {
        Fail "command contains pwsh: $command"
    }
    $pinMatch = [regex]::Match($command, '-PinVersion\s+(\S+)')
    if (-not $pinMatch.Success -or $pinMatch.Groups[1].Value -cne $pin) {
        Fail "pin is not exactly ${pin}: $command"
    }
}
if ($json.installCommand -notlike '*-Action Install*') {
    Fail 'install command is missing Action Install'
}
if ($json.uninstallCommand -notlike '*-Action Uninstall*') {
    Fail 'uninstall command is missing Action Uninstall'
}

if ($detectText -match 'Invoke-Firefox') {
    Fail 'detection script references the installer'
}
if ($detectText -match '(?m)^\s*\.\s') {
    Fail 'detection script dot-sources a file'
}
if ($detectText.Contains('Publisher')) {
    Fail 'detection script checks a publisher'
}
if ($detectText -match 'Write-Error|\[Console\]::Error') {
    Fail 'detection script writes to the error stream'
}
if ($detectText -notmatch '\$ErrorActionPreference\s*=\s*''Stop''') {
    Fail 'detection script does not set ErrorActionPreference'
}
if ($detectText -notmatch 'Set-StrictMode\s+-Version\s+Latest') {
    Fail 'detection script does not set StrictMode'
}
if ($detectText -notmatch 'RELIAN_DEPLOY_TEST') {
    Fail 'detection script ignores RELIAN_DEPLOY_TEST'
}
foreach ($path in @(
        'HKLM:\SOFTWARE\Mozilla\Mozilla Firefox',
        'HKLM:\SOFTWARE\WOW6432Node\Mozilla\Mozilla Firefox',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
    if (-not $detectText.Contains($path)) {
        Fail "detection script is missing $path"
    }
}
if (-not $detectText.Contains('CurrentVersion')) {
    Fail 'detection script does not read CurrentVersion'
}
if (-not $detectText.Contains('Mozilla Firefox*')) {
    Fail 'detection script does not match Mozilla Firefox*'
}

$successPattern = "(?s)if \(\`$detected\) \{\r?\n    Write-Output 'Relian Mozilla Firefox'\r?\n    exit 0\r?\n\}"
if ($detectText -notmatch $successPattern) {
    Fail 'success output was missing'
}
$successProbe = Join-Path ([System.IO.Path]::GetTempPath()) ('firefox-detect-success-' + [guid]::NewGuid().ToString('n') + '.ps1')
$successOutFile = Join-Path ([System.IO.Path]::GetTempPath()) ('firefox-detect-success-out-' + [guid]::NewGuid().ToString('n'))
$successErrFile = Join-Path ([System.IO.Path]::GetTempPath()) ('firefox-detect-success-err-' + [guid]::NewGuid().ToString('n'))
$successExit = -1
try {
    Set-Content -LiteralPath $successProbe -Value ("`$detected = `$true`n" + $Matches[0] + "`nexit 1`n") -Encoding utf8
    & pwsh -NoProfile -File $successProbe 1> $successOutFile 2> $successErrFile
    $successExit = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $successProbe -Force -ErrorAction SilentlyContinue
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
if ($successOut.Trim() -cne 'Relian Mozilla Firefox') {
    Fail 'success output was missing'
}
if (-not [string]::IsNullOrWhiteSpace($successErr)) {
    Fail 'success path wrote to the error stream'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

if (-not (Get-Command Test-FirefoxDetectInstalled -ErrorAction SilentlyContinue)) {
    Fail 'Test-FirefoxDetectInstalled was not defined'
}

$wildcard = New-FirefoxUninstallEntry -DisplayName 'Mozilla Firefox (x64 en-US)' -DisplayVersion $pin
if (-not (Test-FirefoxDetectInstalled -UninstallEntries @($wildcard))) {
    Fail 'a Mozilla Firefox* entry was absent'
}

$plain = New-FirefoxUninstallEntry -DisplayName 'Mozilla Firefox' -DisplayVersion $pin
if (-not (Test-FirefoxDetectInstalled -UninstallEntries @($plain))) {
    Fail 'Mozilla Firefox was absent'
}

$caseName = New-FirefoxUninstallEntry -DisplayName 'mozilla firefox ESR' -DisplayVersion " $pin "
if (-not (Test-FirefoxDetectInstalled -UninstallEntries @($caseName))) {
    Fail 'Mozilla Firefox* comparison was case-sensitive'
}

$sameRelease = New-FirefoxUninstallEntry -DisplayName 'Mozilla Firefox' -DisplayVersion $productVersion
if (-not (Test-FirefoxDetectInstalled -UninstallEntries @($sameRelease))) {
    Fail 'the four-part product version was absent'
}

$above = New-FirefoxUninstallEntry -DisplayName 'Mozilla Firefox' -DisplayVersion '158.0.1'
if (-not (Test-FirefoxDetectInstalled -UninstallEntries @($above))) {
    Fail 'Mozilla Firefox newer than the pin was absent'
}

$esrAtPin = New-FirefoxUninstallEntry -DisplayName 'Mozilla Firefox ESR' -DisplayVersion '158.0esr'
if (-not (Test-FirefoxDetectInstalled -UninstallEntries @($esrAtPin))) {
    Fail 'an esr build at the pin was absent'
}

$otherPublisher = New-FirefoxUninstallEntry -DisplayName 'Mozilla Firefox (x64 en-US)' -DisplayVersion $pin
$otherPublisher | Add-Member -NotePropertyName 'Publisher' -NotePropertyValue 'Not Mozilla'
if (-not (Test-FirefoxDetectInstalled -UninstallEntries @($otherPublisher))) {
    Fail 'a publisher the installer does not read was treated as absent'
}

$unrelated = New-FirefoxUninstallEntry -DisplayName 'Mozilla Thunderbird' -DisplayVersion '999.0'
if (Test-FirefoxDetectInstalled -UninstallEntries @($unrelated)) {
    Fail 'an unrelated name was present'
}

$bareFirefox = New-FirefoxUninstallEntry -DisplayName 'Firefox' -DisplayVersion $pin
if (Test-FirefoxDetectInstalled -UninstallEntries @($bareFirefox)) {
    Fail 'a name other than Mozilla Firefox* was present'
}

$leadingSpace = New-FirefoxUninstallEntry -DisplayName ' Mozilla Firefox' -DisplayVersion $pin
if (Test-FirefoxDetectInstalled -UninstallEntries @($leadingSpace)) {
    Fail 'a padded display name was present'
}

$older = New-FirefoxUninstallEntry -DisplayName 'Mozilla Firefox (x64 en-US)' -DisplayVersion '115.14.0esr'
if (Test-FirefoxDetectInstalled -UninstallEntries @($older)) {
    Fail 'Mozilla Firefox older than the pin was present'
}

$nameOnly = New-FirefoxUninstallEntry -DisplayName 'Mozilla Firefox' -OmitVersion
if (Test-FirefoxDetectInstalled -UninstallEntries @($nameOnly)) {
    Fail 'a Mozilla Firefox entry without DisplayVersion was present'
}

$unparsed = New-FirefoxUninstallEntry -DisplayName 'Mozilla Firefox' -DisplayVersion 'not-a-version'
if (Test-FirefoxDetectInstalled -UninstallEntries @($unparsed)) {
    Fail 'an unparsed DisplayVersion was present'
}

if (-not (Test-FirefoxDetectInstalled -UninstallEntries @($null, $wildcard))) {
    Fail 'an unreadable uninstall key stopped the search'
}

$olderFirst = New-FirefoxUninstallEntry -DisplayName 'Mozilla Firefox' -DisplayVersion '157.0'
if (Test-FirefoxDetectInstalled -UninstallEntries @($olderFirst, $wildcard)) {
    Fail 'a later uninstall entry replaced the first Mozilla Firefox match'
}

$current = [pscustomobject]@{ CurrentVersion = '158.0 (x64 en-US)' }
if (-not (Test-FirefoxDetectInstalled -ProductKeys @($current))) {
    Fail 'CurrentVersion at the pin was absent'
}

$currentEsr = [pscustomobject]@{ CurrentVersion = '158.0esr (x64 en-US)' }
if (-not (Test-FirefoxDetectInstalled -ProductKeys @($currentEsr))) {
    Fail 'an esr CurrentVersion at the pin was absent'
}

$currentAbove = [pscustomobject]@{ CurrentVersion = '159.0' }
if (-not (Test-FirefoxDetectInstalled -ProductKeys @($currentAbove))) {
    Fail 'CurrentVersion newer than the pin was absent'
}

$currentOld = [pscustomobject]@{ CurrentVersion = '115.0 (x64 en-US)' }
if (Test-FirefoxDetectInstalled -ProductKeys @($currentOld)) {
    Fail 'CurrentVersion below the pin was present'
}

if (Test-FirefoxDetectInstalled -ProductKeys @($currentOld) -UninstallEntries @($wildcard)) {
    Fail 'a later uninstall entry replaced an earlier CurrentVersion'
}

$missingCurrent = [pscustomobject]@{ InstallDirectory = 'C:\Program Files\Mozilla Firefox' }
if (-not (Test-FirefoxDetectInstalled -ProductKeys @($missingCurrent, $current))) {
    Fail 'a product key without CurrentVersion stopped the search'
}

$badCurrent = [pscustomobject]@{ CurrentVersion = 'not-a-version' }
if (-not (Test-FirefoxDetectInstalled -ProductKeys @($null, $badCurrent) -UninstallEntries @($wildcard))) {
    Fail 'an unparsed CurrentVersion stopped the uninstall search'
}

if (Test-FirefoxDetectInstalled -ProductKeys @() -UninstallEntries @()) {
    Fail 'no entries was present'
}

$registryMissing = $true
foreach ($root in @(
        'HKLM:\SOFTWARE\Mozilla\Mozilla Firefox',
        'HKLM:\SOFTWARE\WOW6432Node\Mozilla\Mozilla Firefox',
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
    $liveOutFile = Join-Path ([System.IO.Path]::GetTempPath()) ('firefox-detect-miss-out-' + [guid]::NewGuid().ToString('n'))
    $liveErrFile = Join-Path ([System.IO.Path]::GetTempPath()) ('firefox-detect-miss-err-' + [guid]::NewGuid().ToString('n'))
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

Write-Output 'PASS intune-firefox'
exit 0
