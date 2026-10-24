$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/putty'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Putty.ps1'
$setupPath = Join-Path $packageDir 'Invoke-Putty.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/putty.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

foreach ($path in @($jsonPath, $detectPath, $setupPath, $releasePath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "missing $path"
    }
}

$jsonText = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8
$meta = $jsonText | ConvertFrom-Json
foreach ($field in @(
        'displayName',
        'publisher',
        'setupFile',
        'installCommand',
        'uninstallCommand',
        'detectionScript',
        'detectReplace'
    )) {
    if ($meta.PSObject.Properties.Name -notcontains $field) {
        Fail "intune.json missing $field"
    }
}
if ([string]$meta.displayName -cne 'Relian PuTTY') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-Putty.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-Putty.ps1') {
    Fail "detectionScript '$($meta.detectionScript)'"
}
if ($jsonText -notmatch '"detectReplace"\s*:\s*\[\s*\]') {
    Fail 'detectReplace is not an empty array'
}
if (-not (Test-Path -LiteralPath (Join-Path $packageDir ([string]$meta.setupFile)))) {
    Fail 'setupFile is not next to intune.json'
}
if (-not (Test-Path -LiteralPath (Join-Path $packageDir ([string]$meta.detectionScript)))) {
    Fail 'detectionScript is not next to intune.json'
}

$expectedInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Putty.ps1 -DeploymentType Install -Action Install -PinVersion 0.85.0.0'
$expectedUninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Putty.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion 0.85.0.0'
$install = [string]$meta.installCommand
$uninstall = [string]$meta.uninstallCommand
if ($install -cne $expectedInstall) {
    Fail "installCommand '$install'"
}
if ($uninstall -cne $expectedUninstall) {
    Fail "uninstallCommand '$uninstall'"
}
foreach ($command in @($install, $uninstall)) {
    if (-not $command.Contains('powershell.exe')) {
        Fail 'command does not use powershell.exe'
    }
    if ($command.Contains('pwsh')) {
        Fail 'command uses pwsh'
    }
    if (-not $command.Contains('-PinVersion 0.85.0.0')) {
        Fail 'command is missing the pin'
    }
}
if (-not $install.Contains('-Action Install') -or -not $install.Contains('-DeploymentType Install')) {
    Fail 'install command action'
}
if (-not $uninstall.Contains('-Action Uninstall') -or -not $uninstall.Contains('-DeploymentType Uninstall')) {
    Fail 'uninstall command action'
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.version -cne '0.85.0.0') {
    Fail "release version '$($release.version)'"
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-Putty.ps1')) {
    Fail 'detection script names the installer'
}
if ($detectText -match '(?m)^\s*\.\s') {
    Fail 'detection script dot-sources a file'
}
if (-not $detectText.Contains('^PuTTY release [0-9]+(\.[0-9]+){1,3} \(64-bit\)$')) {
    Fail 'display name rule drifted'
}
if (-not $detectText.Contains("-cne 'Simon Tatham'")) {
    Fail 'publisher rule drifted'
}
if (-not $detectText.Contains("'0.85.0.0'")) {
    Fail 'detection minimum is not the pin'
}
$successAt = $detectText.IndexOf("Write-Output 'Relian PuTTY'", [System.StringComparison]::Ordinal)
$exitAt = $detectText.IndexOf('exit 0', [System.StringComparison]::Ordinal)
if ($successAt -lt 0 -or $exitAt -lt $successAt) {
    Fail 'success output is missing'
}
foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
    if (-not $detectText.Contains($root)) {
        Fail 'detection script is missing an uninstall root'
    }
}

function Assert-NoAddress {
    param(
        [string]$Text,
        [string]$Label
    )
    # 0.85.0.0 is the package pin. Any other dotted quad is an address.
    $quads = [regex]::Matches($Text, '(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])')
    foreach ($hit in @($quads)) {
        if ($null -eq $hit) {
            continue
        }
        if ($hit.Value -cne '0.85.0.0') {
            Fail "$Label contains an address"
        }
    }
}

$testText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8
Assert-NoAddress -Text $jsonText -Label 'intune.json'
Assert-NoAddress -Text $detectText -Label 'Detect-Putty.ps1'
Assert-NoAddress -Text $testText -Label 'intune-putty.Tests.ps1'
foreach ($packageFile in @(
        @{ Text = $jsonText; Label = 'intune.json' },
        @{ Text = $detectText; Label = 'Detect-Putty.ps1' }
    )) {
    if ($packageFile.Text.Contains('/home/')) {
        Fail "$($packageFile.Label) contains a home path"
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

if (-not (Get-Command Test-PuttyDetectPresent -ErrorAction SilentlyContinue)) {
    Fail 'Test-PuttyDetectPresent was not defined'
}

function New-PuttyEntry {
    param(
        [string]$DisplayName,
        [string]$DisplayVersion,
        [string]$Publisher = 'Simon Tatham',
        [string]$KeyName = '{11111111-1111-1111-1111-111111111111}',
        [string]$UninstallString
    )
    if (-not $PSBoundParameters.ContainsKey('UninstallString')) {
        $UninstallString = ''
        if (-not [string]::IsNullOrWhiteSpace($KeyName)) {
            $UninstallString = 'MsiExec.exe /X' + $KeyName
        }
    }
    return [pscustomobject]@{
        KeyName              = $KeyName
        DisplayName          = $DisplayName
        DisplayVersion       = $DisplayVersion
        Publisher            = $Publisher
        UninstallString      = $UninstallString
        QuietUninstallString = ''
    }
}

$pinned = New-PuttyEntry -DisplayName 'PuTTY release 0.85 (64-bit)' -DisplayVersion '0.85.0.0'
if (-not (Test-PuttyDetectPresent -Entries @($pinned))) {
    Fail 'pinned x64 release was absent'
}

$shortVersion = New-PuttyEntry -DisplayName 'PuTTY release 0.85 (64-bit)' -DisplayVersion '0.85'
if (-not (Test-PuttyDetectPresent -Entries @($shortVersion))) {
    Fail 'two-part x64 release was absent'
}

$nameOnly = New-PuttyEntry -DisplayName 'PuTTY release 0.85 (64-bit)' -DisplayVersion ''
if (-not (Test-PuttyDetectPresent -Entries @($nameOnly))) {
    Fail 'x64 release version from the display name was absent'
}

$blankPublisher = New-PuttyEntry -DisplayName 'PuTTY release 0.85 (64-bit)' -DisplayVersion '0.85.0.0' -Publisher ''
if (-not (Test-PuttyDetectPresent -Entries @($blankPublisher))) {
    Fail 'blank publisher was absent'
}

$newer = New-PuttyEntry -DisplayName 'PuTTY release 0.86 (64-bit)' -DisplayVersion '0.86' -KeyName '{22222222-2222-2222-2222-222222222222}'
if (-not (Test-PuttyDetectPresent -Entries @($newer))) {
    Fail 'newer x64 release was absent'
}

$arm = New-PuttyEntry -DisplayName 'PuTTY release 0.85 (64-bit Arm)' -DisplayVersion '0.85.0.0'
if (Test-PuttyDetectPresent -Entries @($arm)) {
    Fail 'Arm release was present'
}

$older = New-PuttyEntry -DisplayName 'PuTTY release 0.84 (64-bit)' -DisplayVersion '0.84' -KeyName '{33333333-3333-3333-3333-333333333333}'
if (Test-PuttyDetectPresent -Entries @($older)) {
    Fail 'older release was present'
}

$otherPublisher = New-PuttyEntry -DisplayName 'PuTTY release 0.85 (64-bit)' -DisplayVersion '0.85.0.0' -Publisher 'Someone Else'
if (Test-PuttyDetectPresent -Entries @($otherPublisher)) {
    Fail 'other publisher was present'
}

$lowerPublisher = New-PuttyEntry -DisplayName 'PuTTY release 0.85 (64-bit)' -DisplayVersion '0.85.0.0' -Publisher 'simon tatham'
if (Test-PuttyDetectPresent -Entries @($lowerPublisher)) {
    Fail 'publisher case was ignored'
}

$partialNewer = New-PuttyEntry -DisplayName 'PuTTY release 0.90 (64-bit)' -DisplayVersion '0.90' -KeyName '' -UninstallString ''
if (Test-PuttyDetectPresent -Entries @($older, $partialNewer)) {
    Fail 'older complete product was replaced by a newer partial'
}

$olderFirst = New-PuttyEntry -DisplayName 'PuTTY release 0.84 (64-bit)' -DisplayVersion '0.84' -KeyName '{44444444-4444-4444-4444-444444444444}'
if (-not (Test-PuttyDetectPresent -Entries @($olderFirst, $newer))) {
    Fail 'newer complete release was hidden by an older one'
}

if (Test-PuttyDetectPresent -Entries @()) {
    Fail 'no entries was present'
}

$liveEntries = @(Get-PuttyDetectUninstallEntries)
if ($liveEntries.Count -eq 0 -and (Test-PuttyDetectPresent -Entries $liveEntries)) {
    Fail 'empty uninstall list was present'
}
