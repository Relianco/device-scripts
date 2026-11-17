$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/thin-manager'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-ThinManager.ps1'

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
    # 1.0.0.0 is the shortcut package sentinel. It is not an address.
    $found = [regex]::Matches($Text, '(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])')
    foreach ($match in @($found)) {
        if ($null -eq $match) {
            continue
        }
        if ($match.Value -eq '1.0.0.0') {
            continue
        }
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
    Fail 'Detect-ThinManager.ps1 does not exist'
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
if ([string]$meta.displayName -cne 'Relian Thin Manager startup') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-ThinManager.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-ThinManager.ps1') {
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
$expectedInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-ThinManager.ps1 -DeploymentType Install -Action Install -PinVersion 1.0.0.0'
$expectedUninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-ThinManager.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion 1.0.0.0'
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
    if (-not $command.Contains('-PinVersion 1.0.0.0')) {
        Fail 'command pin is not 1.0.0.0'
    }
    if ($command.Contains('-StartupFolder')) {
        Fail 'command passes StartupFolder'
    }
}
if (-not $installCommand.Contains('-Action Install')) {
    Fail 'install action'
}
if (-not $uninstallCommand.Contains('-Action Uninstall')) {
    Fail 'uninstall action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-ThinManager.ps1')) {
    Fail 'detection script references the installer'
}
if ($detectText -match '(?m)^\s*\.\s') {
    Fail 'detection script dot-sources a file'
}
if (-not $detectText.Contains('if ($env:RELIAN_DEPLOY_TEST -eq ''1'')')) {
    Fail 'detection script has no test guard'
}
$guardAt = $detectText.IndexOf('RELIAN_DEPLOY_TEST', [System.StringComparison]::Ordinal)
$exitAt = $detectText.IndexOf("`nexit ", [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $exitAt -lt 0 -or $exitAt -lt $guardAt) {
    Fail 'detection exits before the test guard'
}
if (-not $detectText.Contains('Microsoft\Windows\Start Menu\Programs\StartUp\')) {
    Fail 'detection script misses the Startup folder'
}
if (-not $detectText.Contains('RelianThinManager.lnk')) {
    Fail 'detection script misses the shortcut name'
}
$successLine = "Write-Output 'Relian Thin Manager startup'"
if (-not $detectText.Contains($successLine)) {
    Fail 'detection success path does not write Relian Thin Manager startup'
}
if (([regex]::Matches($detectText, 'Write-Output')).Count -ne 1) {
    Fail 'detection script Write-Output count'
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
if (-not $successBlock.Contains($successLine)) {
    Fail 'detection success path does not write Relian Thin Manager startup'
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
if (Test-IntuneTextHasIpv4 -Text 'pin 1.0.0.0') {
    Fail 'version pin was treated as an address'
}
$nearAddress = (@(11, 0, 0, 1) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text $nearAddress)) {
    Fail 'ipv4 scanner missed an address near the pin'
}
$committed = @(
    (Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8),
    (Get-Content -LiteralPath $detectPath -Raw -Encoding utf8),
    (Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8)
)
foreach ($text in $committed) {
    if (Test-IntuneTextHasIpv4 -Text $text) {
        Fail 'committed file contains an IPv4 address'
    }
}
foreach ($packageFile in @(
        @{ Text = $jsonText; Label = 'intune.json' },
        @{ Text = $detectText; Label = 'Detect-ThinManager.ps1' }
    )) {
    if ($packageFile.Text.Contains('/home/')) {
        Fail "$($packageFile.Label) contains a home path"
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
$env:SystemRoot = 'C:\Windows'
$env:ProgramData = 'C:\ProgramData'
. $detectPath

foreach ($command in @(
        'Get-RelianThinManagerShortcutSpec',
        'Test-RelianThinManagerShortcutMatches',
        'Test-RelianThinManagerInstalled',
        'Get-RelianThinManagerStartupShortcutPath'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$startupPath = Get-RelianThinManagerStartupShortcutPath
if ($startupPath -cne 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\RelianThinManager.lnk') {
    Fail "startup shortcut path '$startupPath'"
}

$powershell = 'C:\Windows\system32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -File "C:\Relian\shell.ps1"'
$matching = [pscustomobject]@{
    TargetPath   = $powershell
    Arguments    = $arguments
    Description  = 'Relian Thin Manager'
    IconLocation = $powershell
}
if (-not (Test-RelianThinManagerInstalled -Entry $matching)) {
    Fail 'a matching shortcut was absent'
}

$iconIndex = [pscustomobject]@{
    TargetPath   = $powershell.ToUpperInvariant()
    Arguments    = $arguments
    Description  = 'Relian Thin Manager'
    IconLocation = ($powershell + ',0')
}
if (-not (Test-RelianThinManagerInstalled -Entry $iconIndex)) {
    Fail 'icon index or target case was treated as a different shortcut'
}

$differentArgument = [pscustomobject]@{
    TargetPath   = $powershell
    Arguments    = '-ExecutionPolicy Bypass -WindowStyle Normal -NoProfile -File "C:\Relian\shell.ps1"'
    Description  = 'Relian Thin Manager'
    IconLocation = $powershell
}
if (Test-RelianThinManagerInstalled -Entry $differentArgument) {
    Fail 'a shortcut with a different argument was present'
}

$markerOnly = [pscustomobject]@{
    MarkerVersion = '1.0.0.0'
}
if (Test-RelianThinManagerInstalled -Entry $markerOnly) {
    Fail 'a marker without the shortcut was present'
}

$fileOnly = [pscustomobject]@{
    Path = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\RelianThinManager.lnk'
}
if (Test-RelianThinManagerInstalled -Entry $fileOnly) {
    Fail 'a shortcut file without a match was present'
}

$displayName = [pscustomobject]@{
    TargetPath   = $powershell
    Arguments    = $arguments
    Description  = 'Relian Thin Manager startup'
    IconLocation = $powershell
}
if (Test-RelianThinManagerInstalled -Entry $displayName) {
    Fail 'the display name was accepted as the shortcut description'
}

if (Test-RelianThinManagerInstalled -Entry $null) {
    Fail 'a missing shortcut was present'
}
