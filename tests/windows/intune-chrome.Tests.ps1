$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/chrome'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Chrome.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/chrome.json'
$pin = '155.0.8059.85'

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

function New-ChromeDetectEntry {
    param(
        [string]$DisplayName,
        [string]$DisplayVersion,
        [string]$UninstallString = '',
        [string]$QuietUninstallString = '',
        [string]$PSChildName = 'Google Chrome',
        [string]$Publisher = ''
    )
    return [pscustomobject]@{
        DisplayName          = $DisplayName
        DisplayVersion       = $DisplayVersion
        UninstallString      = $UninstallString
        QuietUninstallString = $QuietUninstallString
        PSChildName          = $PSChildName
        Publisher            = $Publisher
    }
}

if (-not (Test-Path -LiteralPath $jsonPath)) {
    Fail 'windows/packages/chrome/intune.json does not exist'
}
if (-not (Test-Path -LiteralPath $detectPath)) {
    Fail 'Detect-Chrome.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/chrome.json does not exist'
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.version -cne $pin) {
    Fail "release version '$($release.version)' is not $pin"
}

$jsonText = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8
$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
$testText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8
Assert-CleanText -Label 'intune.json' -Text $jsonText
Assert-CleanText -Label 'Detect-Chrome.ps1' -Text $detectText
Assert-CleanText -Label 'intune-chrome.Tests.ps1' -Text $testText

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
if ([string]$json.displayName -cne 'Relian Google Chrome') {
    Fail "displayName '$($json.displayName)'"
}
if ([string]$json.publisher -cne 'Relian') {
    Fail "publisher '$($json.publisher)'"
}
if ([string]$json.setupFile -cne 'Invoke-Chrome.ps1') {
    Fail "setupFile '$($json.setupFile)'"
}
if ([string]$json.detectionScript -cne 'Detect-Chrome.ps1') {
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

$expectedInstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Chrome.ps1 -DeploymentType Install -Action Install -PinVersion $pin"
$expectedUninstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Chrome.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion $pin"
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
    if (-not $command.Contains($pin)) {
        Fail "command is missing the pin: $command"
    }
}
if ($json.installCommand -notlike '*-Action Install*') {
    Fail 'install command is missing Action Install'
}
if ($json.uninstallCommand -notlike '*-Action Uninstall*') {
    Fail 'uninstall command is missing Action Uninstall'
}

if ($detectText -match 'Invoke-Chrome') {
    Fail 'detection script references the installer'
}
if ($detectText.Contains('Publisher')) {
    Fail 'detection script checks a publisher'
}
if ($detectText -notmatch '\$ErrorActionPreference\s*=\s*''Stop''') {
    Fail 'detection script does not set ErrorActionPreference'
}
if ($detectText -notmatch 'Set-StrictMode\s+-Version\s+Latest') {
    Fail 'detection script does not set StrictMode'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

if (-not (Get-Command Test-ChromeDetectInstalled -ErrorAction SilentlyContinue)) {
    Fail 'Test-ChromeDetectInstalled was not defined'
}
if (-not (Get-Command Convert-ChromeDetectVersionText -ErrorAction SilentlyContinue)) {
    Fail 'Convert-ChromeDetectVersionText was not defined'
}
if (-not (Get-Command Format-ChromeDetectVersion -ErrorAction SilentlyContinue)) {
    Fail 'Format-ChromeDetectVersion was not defined'
}

$productCode = '{11111111-2222-3333-4444-555555555555}'
$atPin = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion $pin
if (-not (Test-ChromeDetectInstalled -Entries @($atPin))) {
    Fail 'Google Chrome at the pin was absent'
}

$trimmed = New-ChromeDetectEntry -DisplayName '  Google Chrome  ' -DisplayVersion " $pin "
if (-not (Test-ChromeDetectInstalled -Entries @($trimmed))) {
    Fail 'trimmed Google Chrome display name or version was absent'
}

$differentCase = New-ChromeDetectEntry -DisplayName 'google chrome' -DisplayVersion $pin
if (-not (Test-ChromeDetectInstalled -Entries @($differentCase))) {
    Fail 'display name comparison was case-sensitive'
}

$abovePin = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion '155.0.8059.100'
if (-not (Test-ChromeDetectInstalled -Entries @($abovePin))) {
    Fail 'Google Chrome newer than the pin was absent'
}

$otherPublisher = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion $pin -Publisher 'Not Google LLC'
if (-not (Test-ChromeDetectInstalled -Entries @($otherPublisher))) {
    Fail 'a publisher the installer does not read was treated as absent'
}

$older = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion '155.0.8059.84'
if (Test-ChromeDetectInstalled -Entries @($older)) {
    Fail 'Google Chrome older than the pin was present'
}

$otherName = New-ChromeDetectEntry -DisplayName 'Google Chrome Beta' -DisplayVersion '999.0.0.0'
if (Test-ChromeDetectInstalled -Entries @($otherName)) {
    Fail 'a display name other than Google Chrome was present'
}

# The installer ignores a Google Chrome key with neither a parsed DisplayVersion nor a product code.
$unparsed = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion 'not-a-version'
if (Test-ChromeDetectInstalled -Entries @($unparsed)) {
    Fail 'an unparsed DisplayVersion with no product code was present'
}
$emptyVersion = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion ''
if (Test-ChromeDetectInstalled -Entries @($emptyVersion)) {
    Fail 'an empty DisplayVersion with no product code was present'
}

# A failed property read is skipped. It does not hide a later key.
if (-not (Test-ChromeDetectInstalled -Entries @($null, $atPin))) {
    Fail 'an unreadable uninstall key stopped the search'
}

# The first key that has both a version and a product code is returned immediately.
$olderComplete = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion '155.0.8059.84' -UninstallString $productCode -PSChildName $productCode
$laterComplete = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion $pin -UninstallString $productCode -PSChildName $productCode
if (Test-ChromeDetectInstalled -Entries @($olderComplete, $laterComplete)) {
    Fail 'a later key was read after the first complete Google Chrome match'
}

# A later partial key does not replace the first partial key.
$olderPartial = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion '155.0.8059.84'
$laterPartial = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion $pin
if (Test-ChromeDetectInstalled -Entries @($olderPartial, $laterPartial)) {
    Fail 'a later partial key replaced the first partial Google Chrome key'
}

$completeAfterPartial = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion $pin -PSChildName $productCode
if (-not (Test-ChromeDetectInstalled -Entries @($olderPartial, $completeAfterPartial))) {
    Fail 'a complete key was ignored after a partial Google Chrome key'
}

$fromUninstall = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion $pin -UninstallString ('MsiExec.exe /X' + $productCode)
if (-not (Test-ChromeDetectInstalled -Entries @($olderPartial, $fromUninstall))) {
    Fail 'a product code embedded in UninstallString was ignored'
}

$fromQuiet = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion $pin -QuietUninstallString ('MsiExec.exe /X' + $productCode)
if (-not (Test-ChromeDetectInstalled -Entries @($olderPartial, $fromQuiet))) {
    Fail 'a product code embedded in QuietUninstallString was ignored'
}

$looseKey = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion $pin -PSChildName ('prefix-' + $productCode)
if (Test-ChromeDetectInstalled -Entries @($olderPartial, $looseKey)) {
    Fail 'a key name that only contains a product code counted as one'
}

# Omaha pv is read only when no uninstall key had a version or a product code.
if (Test-ChromeDetectInstalled -Entries @($olderPartial) -UpdateVersion $pin) {
    Fail 'Omaha pv replaced an uninstall DisplayVersion'
}
$codeOnly = New-ChromeDetectEntry -DisplayName 'Google Chrome' -DisplayVersion '' -PSChildName $productCode
if (Test-ChromeDetectInstalled -Entries @($codeOnly) -UpdateVersion $pin) {
    Fail 'Omaha pv was used even though an uninstall key had a product code'
}
if (-not (Test-ChromeDetectInstalled -Entries @($otherName) -UpdateVersion $pin)) {
    Fail 'Omaha pv at the pin was absent when no uninstall key was selected'
}
if (Test-ChromeDetectInstalled -Entries @() -UpdateVersion '155.0.8059.84') {
    Fail 'older Omaha pv was present'
}
if (Test-ChromeDetectInstalled -Entries @() -UpdateVersion 'not-a-version') {
    Fail 'unparsed Omaha pv was present'
}
if (Test-ChromeDetectInstalled -Entries @()) {
    Fail 'no entries was present'
}

$registryMissing = $true
foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Google\Update\ClientState\{8A69D345-D564-463c-AFF1-A69D9E530F96}'
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
    try {
        Remove-Item -Path Env:RELIAN_DEPLOY_TEST -ErrorAction SilentlyContinue
        & pwsh -NoProfile -File $detectPath
        $liveExit = $LASTEXITCODE
    } finally {
        $env:RELIAN_DEPLOY_TEST = $savedTest
    }
    if ($liveExit -ne 1) {
        Fail "missing registry detection exited $liveExit"
    }
}

Write-Output 'PASS intune-chrome'
exit 0
