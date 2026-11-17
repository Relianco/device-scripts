$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/sysmon'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Sysmon.ps1'
$setupPath = Join-Path $packageDir 'Invoke-Sysmon.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/sysmon.json'
$pin = '15.22'

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
    # Four numeric parts. 15.22 has two parts, so it is not an address.
    return [regex]::IsMatch($Text, '(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])')
}

foreach ($path in @($jsonPath, $detectPath, $setupPath, $releasePath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "missing $path"
    }
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
if ([string]$meta.displayName -cne 'Relian Sysmon') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-Sysmon.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-Sysmon.ps1') {
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

$expectedInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Sysmon.ps1 -DeploymentType Install -Action Install -PinVersion 15.22'
$expectedUninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Sysmon.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion 15.22'
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
    if ($command.Contains('pwsh')) {
        Fail 'command uses pwsh'
    }
    if (-not $command.Contains('-PinVersion 15.22')) {
        Fail 'command pin is not 15.22'
    }
}
if (-not $install.Contains('-Action Install') -or -not $install.Contains('-DeploymentType Install')) {
    Fail 'install command action'
}
if (-not $uninstall.Contains('-Action Uninstall') -or -not $uninstall.Contains('-DeploymentType Uninstall')) {
    Fail 'uninstall command action'
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.version -cne $pin) {
    Fail "release version '$($release.version)'"
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-Sysmon.ps1')) {
    Fail 'detection script names the installer'
}
if ($detectText -match '(?m)^\s*\.\s') {
    Fail 'detection script dot-sources a file'
}
if ($detectText.Contains('sysmonconfig')) {
    Fail 'detection script requires the config file'
}
if ($detectText.Contains('Publisher')) {
    Fail 'detection script checks the publisher'
}
if ($detectText.Contains('Write-Error') -or $detectText.Contains('Write-Warning') -or $detectText.Contains('Write-Host') -or $detectText.Contains('[Console]::Error')) {
    Fail 'detection script writes to the error stream'
}
foreach ($key in @(
        'HKLM:\SYSTEM\CurrentControlSet\Services\Sysmon64',
        'HKLM:\SYSTEM\CurrentControlSet\Services\Sysmon'
    )) {
    if (-not $detectText.Contains($key)) {
        Fail "detection script misses $key"
    }
}
if (-not $detectText.Contains('if ($env:RELIAN_DEPLOY_TEST -eq ''1'')')) {
    Fail 'detection script has no test guard'
}
$guardAt = $detectText.IndexOf('RELIAN_DEPLOY_TEST', [System.StringComparison]::Ordinal)
$exitAt = $detectText.IndexOf("`nexit ", [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $exitAt -lt 0 -or $exitAt -lt $guardAt) {
    Fail 'detection exits before the test guard'
}
$readAt = $detectText.LastIndexOf('Get-RelianSysmonServiceNames', [System.StringComparison]::Ordinal)
if ($readAt -lt $guardAt) {
    Fail 'service key read is not after the test guard'
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
if (-not $successBlock.Contains("Write-Output 'Relian Sysmon'")) {
    Fail 'detection success path does not write Relian Sysmon'
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

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (Test-IntuneTextHasIpv4 -Text $pin) {
    Fail 'version pin was treated as an address'
}
if (Test-IntuneTextHasIpv4 -Text '15.22.0') {
    Fail 'three-part version was treated as an address'
}

$testText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8
foreach ($text in @($jsonText, $detectText, $testText)) {
    if (Test-IntuneTextHasIpv4 -Text $text) {
        Fail 'committed file contains an IPv4 address'
    }
}
foreach ($packageFile in @(
        @{ Text = $jsonText; Label = 'intune.json' },
        @{ Text = $detectText; Label = 'Detect-Sysmon.ps1' }
    )) {
    if ($packageFile.Text.Contains('/home/')) {
        Fail "$($packageFile.Label) contains a home path"
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

if (-not (Get-Command Test-RelianSysmonInstalled -ErrorAction SilentlyContinue)) {
    Fail 'Test-RelianSysmonInstalled was not defined'
}
if (-not (Get-Command Get-RelianSysmonServiceNames -ErrorAction SilentlyContinue)) {
    Fail 'Get-RelianSysmonServiceNames was not defined'
}
if (-not (Test-RelianSysmonInstalled -ServiceNames @('Sysmon64'))) {
    Fail 'Sysmon64 service key was not installed'
}
if (-not (Test-RelianSysmonInstalled -ServiceNames @('Sysmon'))) {
    Fail 'Sysmon service key was not installed'
}
if (Test-RelianSysmonInstalled -ServiceNames @()) {
    Fail 'neither service key was installed'
}
if (Test-RelianSysmonInstalled -ServiceNames @('EventLog')) {
    Fail 'an unrelated service key was installed'
}
if (Test-RelianSysmonInstalled -ServiceNames $null) {
    Fail 'a null service list was installed'
}
