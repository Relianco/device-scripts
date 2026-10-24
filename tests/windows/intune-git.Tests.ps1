$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/git'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Git.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/git.json'

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

function New-GitDetectEntry {
    param(
        [string]$DisplayName,
        [string]$Publisher,
        [string]$DisplayVersion,
        [string]$QuietUninstallString = '',
        [string]$UninstallString = ''
    )
    return [pscustomobject]@{
        DisplayName           = $DisplayName
        Publisher             = $Publisher
        DisplayVersion        = $DisplayVersion
        QuietUninstallString = $QuietUninstallString
        UninstallString       = $UninstallString
    }
}

if (-not (Test-Path -LiteralPath $jsonPath)) {
    Fail 'intune.json does not exist'
}
if (-not (Test-Path -LiteralPath $detectPath)) {
    Fail 'Detect-Git.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/git.json does not exist'
}

$pin = '2.56.0.2'
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.version -cne $pin) {
    Fail 'release version is not the detection pin'
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
if ([string]$meta.displayName -cne 'Relian Git for Windows') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-Git.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-Git.ps1') {
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
$expectedInstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Git.ps1 -DeploymentType Install -Action Install -PinVersion $pin"
$expectedUninstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Git.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion $pin"
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
    if (-not $command.Contains("-PinVersion $pin")) {
        Fail 'command pin is not the release version'
    }
}
if (-not $installCommand.Contains('-Action Install')) {
    Fail 'install action'
}
if (-not $uninstallCommand.Contains('-Action Uninstall')) {
    Fail 'uninstall action'
}
if (-not $installCommand.Contains('-DeploymentType Install')) {
    Fail 'install deployment type'
}
if (-not $uninstallCommand.Contains('-DeploymentType Uninstall')) {
    Fail 'uninstall deployment type'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-Git')) {
    Fail 'detection script references the installer'
}
if ($detectText -match '(?m)^\s*\.\s+') {
    Fail 'detection script dot-sources a file'
}
if (-not $detectText.Contains($pin)) {
    Fail 'detection script does not contain the pin'
}
if ($detectText.Contains('HKCU')) {
    Fail 'detection script contains HKCU'
}
if (-not $detectText.Contains("if (`$env:RELIAN_DEPLOY_TEST -eq '1')")) {
    Fail 'detection script has no test guard'
}
$guardAt = $detectText.IndexOf('RELIAN_DEPLOY_TEST', [System.StringComparison]::Ordinal)
$exitAt = $detectText.IndexOf("`nexit ", [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $exitAt -lt 0 -or $exitAt -lt $guardAt) {
    Fail 'detection exits before the test guard'
}
$registryAt = $detectText.LastIndexOf('Get-RelianGitUninstallEntries', [System.StringComparison]::Ordinal)
$currentAt = $detectText.LastIndexOf('Get-RelianGitCurrentVersion', [System.StringComparison]::Ordinal)
if ($registryAt -lt $guardAt -or $currentAt -lt $guardAt) {
    Fail 'registry read is not after the test guard'
}
foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\GitForWindows'
    )) {
    if (-not $detectText.Contains($root)) {
        Fail "detection script misses $root"
    }
}
if (-not $detectText.Contains("Write-Output 'Relian Git for Windows'")) {
    Fail 'detection success path does not write Relian Git for Windows'
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
if (-not $successBlock.Contains("Write-Output 'Relian Git for Windows'")) {
    Fail 'detection success path does not write Relian Git for Windows'
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
        'Format-RelianGitVersion',
        'Convert-RelianGitVersionText',
        'Find-RelianGitProduct',
        'Test-RelianGitInstalled'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$tagged = Convert-RelianGitVersionText -Text '2.56.0.windows.2'
$plain = Convert-RelianGitVersionText -Text $pin
if ($tagged -isnot [version] -or $plain -isnot [version]) {
    Fail 'version text did not parse'
}
$taggedCompare = [version](Format-RelianGitVersion -Version $tagged)
$plainCompare = [version](Format-RelianGitVersion -Version $plain)
if ($taggedCompare.CompareTo($plainCompare) -ne 0) {
    Fail '2.56.0.windows.2 is not the pinned release'
}

$publisher = 'The Git Development Community'
$quotedExe = '"C:\Program Files\Git\unins000.exe"'
$newer = '2.56.0' + '.3'
$older = '2.56.0' + '.1'
$atPin = New-GitDetectEntry -DisplayName 'Git' -Publisher $publisher -DisplayVersion $pin -QuietUninstallString $quotedExe
if (-not (Test-RelianGitInstalled -Entries @($atPin) -CurrentVersion '')) {
    Fail 'Git from The Git Development Community was absent'
}
$padded = New-GitDetectEntry -DisplayName '  Git  ' -Publisher "  $publisher  " -DisplayVersion "  $pin  " -UninstallString $quotedExe
if (-not (Test-RelianGitInstalled -Entries @($padded) -CurrentVersion '')) {
    Fail 'trimmed Git entry at the pin was absent'
}
if (-not (Test-RelianGitInstalled -Entries @((New-GitDetectEntry -DisplayName 'Git' -Publisher $publisher -DisplayVersion $newer -QuietUninstallString $quotedExe)) -CurrentVersion '')) {
    Fail 'a version above the pin was absent'
}
if (-not (Test-RelianGitInstalled -Entries @((New-GitDetectEntry -DisplayName 'Git' -Publisher $publisher -DisplayVersion '2.56.0.windows.2' -QuietUninstallString $quotedExe)) -CurrentVersion '')) {
    Fail 'the windows release tag at the pin was absent'
}
$versionOnly = New-GitDetectEntry -DisplayName 'Git' -Publisher $publisher -DisplayVersion $pin
if (-not (Test-RelianGitInstalled -Entries @($versionOnly) -CurrentVersion '')) {
    Fail 'a version at the pin without an uninstall program was absent'
}
$otherPublisher = New-GitDetectEntry -DisplayName 'Git' -Publisher 'Someone Else' -DisplayVersion $pin -QuietUninstallString $quotedExe
if (Test-RelianGitInstalled -Entries @($otherPublisher) -CurrentVersion '') {
    Fail 'a different publisher was present'
}
$otherName = New-GitDetectEntry -DisplayName 'Git for Windows' -Publisher $publisher -DisplayVersion $pin -QuietUninstallString $quotedExe
if (Test-RelianGitInstalled -Entries @($otherName) -CurrentVersion '') {
    Fail 'Git for Windows was present'
}
if (Test-RelianGitInstalled -Entries @((New-GitDetectEntry -DisplayName 'Git' -Publisher $publisher -DisplayVersion $older -QuietUninstallString $quotedExe)) -CurrentVersion '') {
    Fail 'a version below the pin was present'
}
if (-not (Test-RelianGitInstalled -Entries @($otherPublisher, $atPin) -CurrentVersion '')) {
    Fail 'a different publisher hid Git'
}
$olderComplete = New-GitDetectEntry -DisplayName 'Git' -Publisher $publisher -DisplayVersion $older -QuietUninstallString $quotedExe
$newerComplete = New-GitDetectEntry -DisplayName 'Git' -Publisher $publisher -DisplayVersion $newer -QuietUninstallString $quotedExe
if (Test-RelianGitInstalled -Entries @($olderComplete, $newerComplete) -CurrentVersion '') {
    Fail 'an older complete entry was not the selected product'
}
$exeOnly = New-GitDetectEntry -DisplayName 'Git' -Publisher $publisher -DisplayVersion '' -QuietUninstallString $quotedExe
if (Test-RelianGitInstalled -Entries @($exeOnly) -CurrentVersion $pin) {
    Fail 'GitForWindows replaced an uninstall entry that has no version'
}
if (Test-RelianGitInstalled -Entries @($olderComplete) -CurrentVersion $newer) {
    Fail 'GitForWindows replaced a lower uninstall version'
}
if (-not (Test-RelianGitInstalled -Entries @() -CurrentVersion '2.56.0.windows.2')) {
    Fail 'GitForWindows current version at the pin was absent'
}
if (-not (Test-RelianGitInstalled -Entries $null -CurrentVersion $newer)) {
    Fail 'GitForWindows current version above the pin was absent'
}
if (Test-RelianGitInstalled -Entries @() -CurrentVersion $older) {
    Fail 'GitForWindows current version below the pin was present'
}
if (Test-RelianGitInstalled -Entries @($otherPublisher) -CurrentVersion '') {
    Fail 'a different publisher was present without a current version'
}
$neither = New-GitDetectEntry -DisplayName 'Git' -Publisher $publisher -DisplayVersion ''
if (-not (Test-RelianGitInstalled -Entries @($neither, $atPin) -CurrentVersion '')) {
    Fail 'an entry with neither version nor uninstall program hid Git'
}
if (-not (Test-RelianGitInstalled -Entries @($null, $atPin) -CurrentVersion '')) {
    Fail 'a null entry hid Git'
}
if (Test-RelianGitInstalled -Entries @() -CurrentVersion '') {
    Fail 'an empty entry list was present'
}
if (Test-RelianGitInstalled -Entries $null -CurrentVersion '') {
    Fail 'a null entry list was present'
}
if (Test-RelianGitInstalled -Entries @($atPin) -CurrentVersion '' -PinVersion '') {
    Fail 'an empty pin was present'
}

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (-not (Test-IntuneTextHasIpv4 -Text $pin)) {
    Fail 'ipv4 scanner missed a dotted quad'
}
$scrubbedPin = [regex]::Replace("pin $pin", [regex]::Escape($pin), '')
if (Test-IntuneTextHasIpv4 -Text $scrubbedPin) {
    Fail 'scrubbed version pin was treated as an address'
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
    $scrubbed = [regex]::Replace($text, [regex]::Escape($pin), '')
    if (Test-IntuneTextHasIpv4 -Text $scrubbed) {
        Fail 'committed file contains an IPv4 address'
    }
    foreach ($word in $banned) {
        if ($text.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Fail 'committed file contains a banned marker'
        }
    }
}
