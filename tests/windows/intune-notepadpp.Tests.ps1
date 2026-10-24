$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/notepadpp'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Notepadpp.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/notepadpp.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $jsonPath)) {
    Fail 'intune.json does not exist'
}
if (-not (Test-Path -LiteralPath $detectPath)) {
    Fail 'Detect-Notepadpp.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/notepadpp.json does not exist'
}

$pin = '8.9.8.1'
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.version -cne $pin) {
    Fail 'release version is not the detection pin'
}

$meta = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json
$expectedNames = @(
    'displayName',
    'publisher',
    'setupFile',
    'installCommand',
    'uninstallCommand',
    'detectionScript',
    'detectReplace'
)
$actualNames = @($meta.PSObject.Properties.Name)
if ($actualNames.Count -ne $expectedNames.Count) {
    Fail 'intune.json fields'
}
foreach ($name in $expectedNames) {
    if ($actualNames -notcontains $name) {
        Fail "missing $name"
    }
}
if ([string]$meta.displayName -cne 'Relian Notepad++') {
    Fail 'displayName'
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail 'publisher'
}
if ([string]$meta.setupFile -cne 'Invoke-Notepadpp.ps1') {
    Fail 'setupFile'
}
if ([string]$meta.detectionScript -cne 'Detect-Notepadpp.ps1') {
    Fail 'detectionScript'
}
$setupPath = Join-Path $packageDir ([string]$meta.setupFile)
$detectBeside = Join-Path $packageDir ([string]$meta.detectionScript)
if (-not (Test-Path -LiteralPath $setupPath)) {
    Fail 'setupFile is not next to intune.json'
}
if (-not (Test-Path -LiteralPath $detectBeside)) {
    Fail 'detectionScript is not next to intune.json'
}
$install = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Notepadpp.ps1 -DeploymentType Install -Action Install -PinVersion $pin"
$uninstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Notepadpp.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion $pin"
if ([string]$meta.installCommand -cne $install) {
    Fail 'installCommand'
}
if ([string]$meta.uninstallCommand -cne $uninstall) {
    Fail 'uninstallCommand'
}
$otherHost = 'p' + 'wsh'
if ($install.Contains($otherHost) -or $uninstall.Contains($otherHost)) {
    Fail 'command uses the wrong PowerShell host'
}
if (-not $install.StartsWith('powershell.exe ') -or -not $uninstall.StartsWith('powershell.exe ')) {
    Fail 'command does not use powershell.exe'
}
if ($install -notlike '*-Action Install*' -or $uninstall -notlike '*-Action Uninstall*') {
    Fail 'Action value'
}
if ($install -notlike '*-DeploymentType Install*' -or $uninstall -notlike '*-DeploymentType Uninstall*') {
    Fail 'DeploymentType value'
}
if ($install -notlike "*-PinVersion $pin*" -or $uninstall -notlike "*-PinVersion $pin*") {
    Fail 'JSON pin'
}
$replace = @($meta.detectReplace)
if ($replace.Count -ne 0 -or $null -eq $meta.detectReplace) {
    Fail 'detectReplace is not empty'
}

$detectText = [System.IO.File]::ReadAllText($detectPath)
if ($detectText.Contains('Invoke-Notepadpp')) {
    Fail 'detection script names the installer'
}
if ($detectText -match '(?m)^\s*\.\s+') {
    Fail 'detection script dot-sources a file'
}
if ($detectText.Contains('Publisher')) {
    Fail 'detection script checks the publisher'
}
if (-not $detectText.Contains('Notepad++ (64-bit x64)')) {
    Fail 'detection script does not require the known display name'
}
if ($detectText.Contains($otherHost)) {
    Fail 'detection script names the wrong PowerShell host'
}
$guard = "if (`$env:RELIAN_DEPLOY_TEST -eq '1')"
$guardAt = $detectText.IndexOf($guard, [System.StringComparison]::Ordinal)
$registryAt = $detectText.LastIndexOf('Get-NotepadppDetectRegistryEntries', [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $registryAt -lt $guardAt) {
    Fail 'registry read is not after the test guard'
}
$exitAt = $detectText.IndexOf('exit ', [System.StringComparison]::Ordinal)
if ($exitAt -ge 0 -and $exitAt -lt $guardAt) {
    Fail 'detection script exits before the test guard'
}
$successLine = "Write-Output 'Relian Notepad++'"
$successAt = $detectText.IndexOf($successLine, [System.StringComparison]::Ordinal)
if ($successAt -lt $guardAt) {
    Fail 'success output is missing'
}
$exitZeroAt = $detectText.IndexOf('exit 0', $successAt, [System.StringComparison]::Ordinal)
if ($exitZeroAt -lt 0) {
    Fail 'success output is missing'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

foreach ($command in @(
        'Convert-NotepadppDetectVersionText',
        'Format-NotepadppDetectVersion',
        'Find-NotepadppDetectProduct',
        'Test-NotepadppDetectPresent'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}
if (-not $detectText.Contains("[string]`$MinimumVersion = '$pin'")) {
    Fail 'detection minimum is not the pin'
}

function New-NotepadppEntry {
    param(
        [string]$DisplayName,
        [string]$DisplayVersion,
        [string]$QuietUninstallString = '',
        [string]$UninstallString = ''
    )
    return [pscustomobject]@{
        DisplayName           = $DisplayName
        DisplayVersion        = $DisplayVersion
        QuietUninstallString = $QuietUninstallString
        UninstallString       = $UninstallString
        Publisher             = 'Someone Else'
    }
}

$knownName = 'Notepad++ (64-bit x64)'
$uninstallExe = '"C:\Program Files\Notepad++\uninstall.exe"'
$older = '8.9.8' + '.0'
$newer = '8.9.8' + '.2'

$atPin = New-NotepadppEntry -DisplayName $knownName -DisplayVersion $pin -QuietUninstallString $uninstallExe
if (-not (Test-NotepadppDetectPresent -Entries @($atPin))) {
    Fail 'matching entry at the pin is absent'
}
$versionOnly = New-NotepadppEntry -DisplayName $knownName -DisplayVersion $pin
if (-not (Test-NotepadppDetectPresent -Entries @($versionOnly))) {
    Fail 'version at the pin without an uninstall program was absent'
}
$padded = New-NotepadppEntry -DisplayName "  $knownName  " -DisplayVersion $pin -UninstallString $uninstallExe
if (-not (Test-NotepadppDetectPresent -Entries @($padded))) {
    Fail 'trimmed display name at the pin is absent'
}
if (-not (Test-NotepadppDetectPresent -Entries @((New-NotepadppEntry -DisplayName $knownName -DisplayVersion $newer -QuietUninstallString $uninstallExe)))) {
    Fail 'newer version is absent'
}

$otherName = New-NotepadppEntry -DisplayName 'Notepad++ (32-bit)' -DisplayVersion $pin -QuietUninstallString $uninstallExe
if (Test-NotepadppDetectPresent -Entries @($otherName)) {
    Fail 'Notepad++ (32-bit) was present'
}
$olderEntry = New-NotepadppEntry -DisplayName $knownName -DisplayVersion $older -QuietUninstallString $uninstallExe
if (Test-NotepadppDetectPresent -Entries @($olderEntry)) {
    Fail 'older version was present'
}
if (-not (Test-NotepadppDetectPresent -Entries @($otherName, $atPin))) {
    Fail 'a skipped name hid the matching entry'
}
if (Test-NotepadppDetectPresent -Entries @($olderEntry, (New-NotepadppEntry -DisplayName $knownName -DisplayVersion $newer -QuietUninstallString $uninstallExe))) {
    Fail 'an older complete entry was not the selected product'
}
$exeOnly = New-NotepadppEntry -DisplayName $knownName -DisplayVersion '' -QuietUninstallString $uninstallExe
if (Test-NotepadppDetectPresent -Entries @($exeOnly)) {
    Fail 'an entry with no version was present'
}
$neither = New-NotepadppEntry -DisplayName $knownName -DisplayVersion '' 
if (-not (Test-NotepadppDetectPresent -Entries @($neither, $atPin))) {
    Fail 'an entry with neither version nor uninstall program hid a match'
}
$unreadable = $null
if (Test-NotepadppDetectPresent -Entries @($unreadable, $otherName)) {
    Fail 'unreadable and other-name entries were present'
}
if (Test-NotepadppDetectPresent -Entries @()) {
    Fail 'an empty entry list was present'
}
if (Test-NotepadppDetectPresent -Entries $null) {
    Fail 'a null entry list was present'
}

function Assert-CleanText {
    param(
        [string]$Label,
        [string]$Text
    )
    $scrubbed = [regex]::Replace($Text, [regex]::Escape($pin), '')
    if ($scrubbed -match '(?<!\d)(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?!\d)') {
        Fail "$Label contains an address"
    }
    foreach ($word in @(
            ('Le' + 'ague'),
            ('PI' + 'LA'),
            ('Sit' + 'ka'),
            ('/' + 'home' + '/')
        )) {
        if ($Text.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Fail "$Label contains forbidden text"
        }
    }
}

$jsonText = [System.IO.File]::ReadAllText($jsonPath)
$testText = [System.IO.File]::ReadAllText($PSCommandPath)
Assert-CleanText -Label 'intune.json' -Text $jsonText
Assert-CleanText -Label 'Detect-Notepadpp.ps1' -Text $detectText
Assert-CleanText -Label 'intune-notepadpp.Tests.ps1' -Text $testText
