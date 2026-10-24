$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/quicklook'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-QuickLook.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/quicklook.json'
$pin = '4.5.0.0'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Test-TextHasOtherQuad {
    param([string]$Text)
    # 4.5.0.0 is the package pin. Any other dotted quad is an address.
    $quads = [regex]::Matches($Text, '(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])')
    foreach ($hit in @($quads)) {
        if ($null -eq $hit) {
            continue
        }
        if ($hit.Value -cne $pin) {
            return $true
        }
    }
    return $false
}

function New-QuickLookDetectEntry {
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
    Fail 'intune.json does not exist'
}
if (-not (Test-Path -LiteralPath $detectPath)) {
    Fail 'Detect-QuickLook.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/quicklook.json does not exist'
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
if ([string]$meta.displayName -cne 'Relian QuickLook') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-QuickLook.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-QuickLook.ps1') {
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
$expectedInstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-QuickLook.ps1 -DeploymentType Install -Action Install -PinVersion $pin"
$expectedUninstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-QuickLook.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion $pin"
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
        Fail 'command pin is not 4.5.0.0'
    }
}
if (-not $installCommand.Contains('-DeploymentType Install') -or -not $installCommand.Contains('-Action Install')) {
    Fail 'install action'
}
if (-not $uninstallCommand.Contains('-DeploymentType Uninstall') -or -not $uninstallCommand.Contains('-Action Uninstall')) {
    Fail 'uninstall action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-QuickLook')) {
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
$registryAt = $detectText.LastIndexOf('Get-QuickLookDetectUninstallEntries', [System.StringComparison]::Ordinal)
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
if ($detectText.Contains('Write-Error') -or $detectText.Contains('[Console]::Error')) {
    Fail 'detection script writes to the error stream'
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
if (-not $successBlock.Contains("Write-Output 'Relian QuickLook'")) {
    Fail 'detection success path does not write Relian QuickLook'
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
        'Test-QuickLookDetectDisplayName',
        'Test-QuickLookDetectVersionAtPin',
        'Test-QuickLookDetectInstalled',
        'Get-QuickLookDetectUninstallEntries'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

if (-not (Test-QuickLookDetectDisplayName -Name 'QuickLook')) {
    Fail 'exact name is absent'
}
if (-not (Test-QuickLookDetectDisplayName -Name '  QuickLook  ')) {
    Fail 'trimmed exact name is absent'
}
if (Test-QuickLookDetectDisplayName -Name 'quicklook') {
    Fail 'different name is present'
}
if (Test-QuickLookDetectDisplayName -Name 'QuickLook Plugin') {
    Fail 'different name is present'
}
if (Test-QuickLookDetectDisplayName -Name 'Quick Look') {
    Fail 'different name is present'
}
if (Test-QuickLookDetectDisplayName -Name '') {
    Fail 'blank name is present'
}

if (-not (Test-QuickLookDetectInstalled -Entries @(New-QuickLookDetectEntry -DisplayName 'QuickLook' -DisplayVersion $pin))) {
    Fail 'exact name at the pin is absent'
}
if (-not (Test-QuickLookDetectInstalled -Entries @(New-QuickLookDetectEntry -DisplayName 'QuickLook' -DisplayVersion '4.5.0'))) {
    Fail 'three-part pin was absent'
}
$above = '{0}.{1}.{2}.{3}' -f 4, 5, 0, 1
if (-not (Test-QuickLookDetectInstalled -Entries @(New-QuickLookDetectEntry -DisplayName 'QuickLook' -DisplayVersion $above))) {
    Fail 'a version above the pin was absent'
}
if (-not (Test-QuickLookDetectInstalled -Entries @(New-QuickLookDetectEntry -DisplayName 'QuickLook' -DisplayVersion '4.6.0'))) {
    Fail 'a newer release was absent'
}
$otherPublisher = [pscustomobject]@{
    DisplayName    = 'QuickLook'
    DisplayVersion = $pin
    Publisher      = 'Other'
}
if (-not (Test-QuickLookDetectInstalled -Entries @($otherPublisher))) {
    Fail 'a different publisher hid QuickLook'
}
$below = '{0}.{1}.{2}.{3}' -f 4, 4, 0, 0
if (Test-QuickLookDetectInstalled -Entries @(New-QuickLookDetectEntry -DisplayName 'QuickLook' -DisplayVersion $below)) {
    Fail 'older version is present'
}
if (Test-QuickLookDetectInstalled -Entries @(New-QuickLookDetectEntry -DisplayName 'QuickLook' -DisplayVersion '4.4.0')) {
    Fail 'older three-part version is present'
}
if (Test-QuickLookDetectInstalled -Entries @(New-QuickLookDetectEntry -DisplayName 'quicklook' -DisplayVersion $pin)) {
    Fail 'different name is present'
}
if (Test-QuickLookDetectInstalled -Entries @(New-QuickLookDetectEntry -DisplayName 'QuickLook Plugin' -DisplayVersion '4.6.0')) {
    Fail 'different name is present'
}
if (Test-QuickLookDetectInstalled -Entries @(New-QuickLookDetectEntry -DisplayName 'QuickLook' -DisplayVersion '')) {
    Fail 'blank version is present'
}
if (Test-QuickLookDetectInstalled -Entries @(New-QuickLookDetectEntry -DisplayName 'QuickLook' -DisplayVersion 'not-a-version')) {
    Fail 'unreadable version is present'
}
$missingVersion = [pscustomobject]@{
    DisplayName = 'QuickLook'
}
if (Test-QuickLookDetectInstalled -Entries @($missingVersion)) {
    Fail 'missing version is present'
}
$mixed = @(
    (New-QuickLookDetectEntry -DisplayName 'QuickLook Plugin' -DisplayVersion '4.6.0'),
    $null,
    (New-QuickLookDetectEntry -DisplayName 'QuickLook' -DisplayVersion '4.5.0')
)
if (-not (Test-QuickLookDetectInstalled -Entries $mixed)) {
    Fail 'a matching entry was hidden'
}
if (Test-QuickLookDetectInstalled -Entries @()) {
    Fail 'no entries is present'
}
$live = @(Get-QuickLookDetectUninstallEntries)
if ($live.Count -ne 0) {
    Fail 'uninstall registry was read as installed entries'
}
if (Test-QuickLookDetectInstalled -Entries $live) {
    Fail 'missing uninstall keys were present'
}

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-TextHasOtherQuad -Text "prefix $sampleAddress suffix")) {
    Fail 'dotted-quad scanner missed an address'
}
if (Test-TextHasOtherQuad -Text "pin $pin") {
    Fail 'version pin was treated as an address'
}
$testText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8
foreach ($fileText in @(
        @{ Text = $jsonText; Label = 'intune.json' },
        @{ Text = $detectText; Label = 'Detect-QuickLook.ps1' },
        @{ Text = $testText; Label = 'intune-quicklook.Tests.ps1' }
    )) {
    if (Test-TextHasOtherQuad -Text ([string]$fileText.Text)) {
        Fail "$($fileText.Label) contains an address"
    }
}
foreach ($packageFile in @(
        @{ Text = $jsonText; Label = 'intune.json' },
        @{ Text = $detectText; Label = 'Detect-QuickLook.ps1' }
    )) {
    if ($packageFile.Text.Contains('/home/')) {
        Fail "$($packageFile.Label) contains a home path"
    }
}

Write-Output 'intune-quicklook tests passed'
exit 0
