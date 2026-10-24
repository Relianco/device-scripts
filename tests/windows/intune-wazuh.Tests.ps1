$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/wazuh'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Wazuh.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/wazuh.json'
$pin = '4.14.9'
$productCode = '{11111111-1111-1111-1111-111111111111}'

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

function New-WazuhDetectEntry {
    param(
        [string]$DisplayName,
        [string]$DisplayVersion,
        [string]$UninstallString = '',
        [string]$QuietUninstallString = '',
        [string]$PSChildName = '',
        [string]$Publisher = ''
    )
    return [pscustomobject]@{
        DisplayName           = $DisplayName
        DisplayVersion        = $DisplayVersion
        UninstallString       = $UninstallString
        QuietUninstallString  = $QuietUninstallString
        PSChildName           = $PSChildName
        Publisher             = $Publisher
    }
}

if (-not (Test-Path -LiteralPath $jsonPath)) {
    Fail 'intune.json does not exist'
}
if (-not (Test-Path -LiteralPath $detectPath)) {
    Fail 'Detect-Wazuh.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/wazuh.json does not exist'
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.version -cne $pin) {
    Fail "release version '$($release.version)' is not $pin"
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
if ([string]$meta.displayName -cne 'Relian Wazuh Agent') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-Wazuh.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-Wazuh.ps1') {
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
$expectedInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Wazuh.ps1 -DeploymentType Install -Action Install -PinVersion 4.14.9'
$expectedUninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Wazuh.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion 4.14.9'
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
    if (-not $command.Contains('-PinVersion 4.14.9')) {
        Fail 'command pin is not 4.14.9'
    }
}
if (-not $installCommand.Contains('-Action Install')) {
    Fail 'install action'
}
if (-not $uninstallCommand.Contains('-Action Uninstall')) {
    Fail 'uninstall action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-Wazuh')) {
    Fail 'detection script references the installer'
}
if ($detectText -match '(?m)^\s*\.\s') {
    Fail 'detection script dot-sources a file'
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
$registryAt = $detectText.LastIndexOf('Get-RelianWazuhUninstallEntries', [System.StringComparison]::Ordinal)
$versionAt = $detectText.LastIndexOf('Get-RelianWazuhVersionValue', [System.StringComparison]::Ordinal)
if ($registryAt -lt 0 -or $registryAt -lt $guardAt) {
    Fail 'registry is read before the test guard returns'
}
if ($versionAt -lt 0 -or $versionAt -lt $guardAt) {
    Fail 'version keys are read before the test guard returns'
}
foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Wazuh, Inc.\Wazuh Agent',
        'HKLM:\SOFTWARE\WOW6432Node\Wazuh, Inc.\Wazuh Agent',
        'HKLM:\SOFTWARE\Wazuh',
        'HKLM:\SOFTWARE\WOW6432Node\Wazuh'
    )) {
    if (-not $detectText.Contains($root)) {
        Fail "detection script misses $root"
    }
}
if (-not $detectText.Contains("`$displayName -ne 'Wazuh Agent'")) {
    Fail 'detection script does not use the finder display name rule'
}
if (-not $detectText.Contains($pin)) {
    Fail 'detection script is missing the pin'
}
if (-not $detectText.Contains("Write-Output 'Relian Wazuh Agent'")) {
    Fail 'detection success path does not write Relian Wazuh Agent'
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
if (-not $successBlock.Contains("Write-Output 'Relian Wazuh Agent'")) {
    Fail 'detection success path does not write Relian Wazuh Agent'
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
foreach ($bannedCall in @('Write-Error', 'Write-Host', '[Console]::Error')) {
    if ($detectText.Contains($bannedCall)) {
        Fail "detection script contains $bannedCall"
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

foreach ($command in @(
        'Format-RelianWazuhVersion',
        'Convert-RelianWazuhVersionText',
        'Find-RelianWazuhProduct',
        'Test-RelianWazuhInstalled'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$parsedPin = Convert-RelianWazuhVersionText -Text $pin
if ($parsedPin -isnot [version]) {
    Fail 'pin did not parse'
}
$paddedPin = Format-RelianWazuhVersion -Version $parsedPin
$paddedParsed = Convert-RelianWazuhVersionText -Text $paddedPin
if ($paddedParsed -isnot [version]) {
    Fail 'padded pin did not parse'
}
$normalizedPin = [version](Format-RelianWazuhVersion -Version $parsedPin)
$normalizedPadded = [version](Format-RelianWazuhVersion -Version $paddedParsed)
if ($normalizedPin.CompareTo($normalizedPadded) -ne 0) {
    Fail 'the pin and its padded form are not the same release'
}
if ($normalizedPin.Revision -ne 0) {
    Fail 'missing revision was not zero'
}

if (-not (Test-RelianWazuhInstalled -Entries @(New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion $pin))) {
    Fail 'exact name at 4.14.9 was absent'
}
if (-not (Test-RelianWazuhInstalled -Entries @(New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion $paddedPin))) {
    Fail 'padded version at the pin was absent'
}
if (-not (Test-RelianWazuhInstalled -Entries @(New-WazuhDetectEntry -DisplayName '  Wazuh Agent  ' -DisplayVersion "  $pin  "))) {
    Fail 'trimmed display name was absent'
}
if (-not (Test-RelianWazuhInstalled -Entries @(New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion '4.15.0' -Publisher 'Other'))) {
    Fail 'a version above the pin was absent'
}
if (-not (Test-RelianWazuhInstalled -Entries @(New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion '4.14.10'))) {
    Fail '4.14.10 was absent'
}
if (Test-RelianWazuhInstalled -Entries @(New-WazuhDetectEntry -DisplayName 'Wazuh' -DisplayVersion $pin)) {
    Fail 'a different name was present'
}
if (Test-RelianWazuhInstalled -Entries @(New-WazuhDetectEntry -DisplayName 'Wazuh Agent Service' -DisplayVersion $pin)) {
    Fail 'a longer name was present'
}
if (Test-RelianWazuhInstalled -Entries @(New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion '4.14.8')) {
    Fail 'a version below the pin was present'
}
if (Test-RelianWazuhInstalled -Entries @(New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion '')) {
    Fail 'an empty version was present'
}
if (Test-RelianWazuhInstalled -Entries @(New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion 'v4.14.9')) {
    Fail 'a prefixed version was present'
}
$olderPadded = Format-RelianWazuhVersion -Version (Convert-RelianWazuhVersionText -Text '4.14.8')
if (Test-RelianWazuhInstalled -Entries @(New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion $olderPadded)) {
    Fail 'a padded version below the pin was present'
}

$atPin = New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion $pin
$otherName = New-WazuhDetectEntry -DisplayName 'Other Agent' -DisplayVersion '9.9.9'
if (-not (Test-RelianWazuhInstalled -Entries @($otherName, $atPin))) {
    Fail 'a matching entry was hidden by a different name'
}
if (-not (Test-RelianWazuhInstalled -Entries @($null, $atPin))) {
    Fail 'a null entry hid the agent'
}
if (Test-RelianWazuhInstalled -Entries @()) {
    Fail 'no entries was present'
}
if (Test-RelianWazuhInstalled -Entries $null) {
    Fail 'a null entry list was present'
}
if (Test-RelianWazuhInstalled -Entries @($atPin) -PinVersion '') {
    Fail 'an empty pin was present'
}
if (Test-RelianWazuhInstalled -Entries @($atPin) -PinVersion 'not-a-version') {
    Fail 'an unparseable pin was present'
}

$uninstallCode = 'MsiExec.exe /X' + $productCode
$olderComplete = New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion '4.14.8' -UninstallString $uninstallCode -PSChildName $productCode
$newerComplete = New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion '4.15.0' -QuietUninstallString $uninstallCode -PSChildName $productCode
if (Test-RelianWazuhInstalled -Entries @($olderComplete, $newerComplete)) {
    Fail 'an older complete entry was not the selected product'
}
$olderPartial = New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion '4.14.8'
if (-not (Test-RelianWazuhInstalled -Entries @($olderPartial, $newerComplete))) {
    Fail 'a later complete entry was ignored'
}
$newerPartial = New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion '4.15.0'
if (Test-RelianWazuhInstalled -Entries @($newerPartial, $olderComplete)) {
    Fail 'a later complete entry did not replace a higher partial'
}
if (Test-RelianWazuhInstalled -Entries @($olderPartial, $newerPartial)) {
    Fail 'a later partial entry replaced the first'
}
$codeOnly = New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion '' -PSChildName $productCode
if (Test-RelianWazuhInstalled -Entries @($codeOnly) -VersionValue $pin) {
    Fail 'a product code without a version was present'
}
if (Test-RelianWazuhInstalled -Entries @($olderComplete) -VersionValue '4.15.0') {
    Fail 'a version key replaced a lower uninstall version'
}
$nameOnly = New-WazuhDetectEntry -DisplayName 'Wazuh Agent' -DisplayVersion ''
if (-not (Test-RelianWazuhInstalled -Entries @($nameOnly) -VersionValue $pin)) {
    Fail 'a version key was ignored when the uninstall entry had no version'
}
if (-not (Test-RelianWazuhInstalled -Entries @($otherName) -VersionValue $pin)) {
    Fail 'a different name hid the version key'
}
if (-not (Test-RelianWazuhInstalled -Entries @() -VersionValue $pin)) {
    Fail 'version key at the pin was absent'
}
if (-not (Test-RelianWazuhInstalled -Entries $null -VersionValue '4.15.0')) {
    Fail 'a version key above the pin was absent'
}
if (-not (Test-RelianWazuhInstalled -Entries @() -VersionValue "  $pin  ")) {
    Fail 'a trimmed version key at the pin was absent'
}
if (Test-RelianWazuhInstalled -Entries @() -VersionValue '4.14.8') {
    Fail 'a version key below the pin was present'
}
if (Test-RelianWazuhInstalled -Entries @() -VersionValue 'v4.14.9') {
    Fail 'an unparseable version key was present'
}
if (Test-RelianWazuhInstalled -Entries @() -VersionValue '') {
    Fail 'an empty version key was present'
}

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (Test-IntuneTextHasIpv4 -Text "pin $pin") {
    Fail 'version pin was treated as an address'
}
$testText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8
foreach ($text in @($jsonText, $detectText, $testText)) {
    if (Test-IntuneTextHasIpv4 -Text $text) {
        Fail 'committed file contains an IPv4 address'
    }
}
foreach ($text in @($jsonText, $detectText)) {
    if ($text.Contains('/home/')) {
        Fail 'committed file contains a home path'
    }
    foreach ($needle in @(
            'WAZUH_MANAGER',
            'WAZUH_REGISTRATION_KEY',
            'WAZUH_REGISTRATION_PASSWORD'
        )) {
        if ($text.Contains($needle)) {
            Fail 'committed file contains an enrollment setting'
        }
    }
}

Write-Output 'intune-wazuh tests passed'
exit 0
