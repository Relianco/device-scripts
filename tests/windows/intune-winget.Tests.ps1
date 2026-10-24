$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/winget'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Winget.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/winget.json'
$pin = '1.29.380.0'
$above = '1.29.381.0'
$below = '1.29.379.0'
$packageName = 'Microsoft.DesktopAppInstaller'
$displayName = 'Relian Windows Package Manager'

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

function New-WingetDetectPackage {
    param(
        [string]$Name,
        [string]$Version
    )
    return [pscustomobject]@{
        Name    = $Name
        Version = $Version
    }
}

function New-WingetDetectDirectoryName {
    param(
        [string]$Version,
        [string]$Arch = 'x64'
    )
    return ($packageName + '_' + $Version + '_' + $Arch + '__8wekyb3d8bbwe')
}

if (-not (Test-Path -LiteralPath $jsonPath)) {
    Fail 'intune.json does not exist'
}
if (-not (Test-Path -LiteralPath $detectPath)) {
    Fail 'Detect-Winget.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/winget.json does not exist'
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.version -cne $pin) {
    Fail 'release version is not the detection pin'
}
$bundle = ''
$releaseNames = @($release.PSObject.Properties.Name)
if ($releaseNames -contains 'bundleVersion') {
    $bundle = [string]$release.bundleVersion
}
if ([string]::IsNullOrWhiteSpace($bundle) -or $bundle -ceq $pin) {
    Fail 'release bundle version is missing or was used as the pin'
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
if ([string]$meta.displayName -cne $displayName) {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-Winget.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-Winget.ps1') {
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
$expectedInstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Winget.ps1 -DeploymentType Install -Action Install -PinVersion $pin"
$expectedUninstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Winget.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion $pin"
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
    if (-not [string]::IsNullOrWhiteSpace($bundle) -and $command.Contains($bundle)) {
        Fail 'command uses the bundle version'
    }
}
if (-not $installCommand.Contains('-DeploymentType Install') -or -not $installCommand.Contains('-Action Install')) {
    Fail 'install action'
}
if (-not $uninstallCommand.Contains('-DeploymentType Uninstall') -or -not $uninstallCommand.Contains('-Action Uninstall')) {
    Fail 'uninstall action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-Winget')) {
    Fail 'detection script references the installer'
}
if ($detectText -match '(?m)^\s*\.\s+') {
    Fail 'detection script dot-sources a file'
}
if (-not $detectText.Contains("`$ErrorActionPreference = 'Stop'")) {
    Fail 'detection script does not stop on errors'
}
if (-not $detectText.Contains('Set-StrictMode -Version Latest')) {
    Fail 'detection script does not set strict mode'
}
if (-not $detectText.Contains($pin)) {
    Fail 'detection script is missing the pin'
}
if (-not $detectText.Contains("[string]`$PinVersion = '$pin'")) {
    Fail 'detection pin default is not the release version'
}
if (-not $detectText.Contains("-PinVersion '$pin'")) {
    Fail 'detection call pin is not the release version'
}
if (-not [string]::IsNullOrWhiteSpace($bundle) -and $detectText.Contains($bundle)) {
    Fail 'detection script uses the bundle version'
}
if ($jsonText.Contains($bundle)) {
    Fail 'intune.json uses the bundle version'
}
foreach ($bannedCall in @('Write-Error', 'Write-Host', '[Console]::Error')) {
    if ($detectText.Contains($bannedCall)) {
        Fail "detection script contains $bannedCall"
    }
}
$guard = "if (`$env:RELIAN_DEPLOY_TEST -eq '1') {`n    return`n}"
if (-not $detectText.Contains($guard)) {
    Fail 'test guard does not return'
}
$guardAt = $detectText.IndexOf('RELIAN_DEPLOY_TEST', [System.StringComparison]::Ordinal)
$exitAt = $detectText.IndexOf("`nexit ", [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $exitAt -lt 0 -or $exitAt -lt $guardAt) {
    Fail 'detection exits before the test guard'
}
foreach ($reader in @('Get-RelianWingetAppxPackages', 'Get-RelianWingetWindowsAppsDirectoryNames')) {
    $readerAt = $detectText.LastIndexOf($reader, [System.StringComparison]::Ordinal)
    if ($readerAt -lt 0 -or $readerAt -lt $guardAt) {
        Fail "$reader is read before the test guard returns"
    }
}
$allUsersCall = "Get-AppxPackage -Name '$packageName' -AllUsers -ErrorAction Stop"
$currentUserCall = "Get-AppxPackage -Name '$packageName' -ErrorAction Stop"
if (-not $detectText.Contains($allUsersCall)) {
    Fail 'detection does not query Appx for all users'
}
if (-not $detectText.Contains($currentUserCall)) {
    Fail 'detection does not query Appx without AllUsers'
}
if (-not $detectText.Contains('Test-RelianWingetCommandHasAllUsers')) {
    Fail 'detection does not check for the AllUsers parameter'
}
$directoryPattern = '^Microsoft\.DesktopAppInstaller_([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)_(x64|x86|arm64)__8wekyb3d8bbwe$'
if (-not $detectText.Contains($directoryPattern)) {
    Fail 'WindowsApps directory pattern is missing'
}
if (-not $detectText.Contains("Join-Path `$programFiles 'WindowsApps'")) {
    Fail 'detection does not read WindowsApps'
}
if (-not $detectText.Contains("Write-Output '$displayName'")) {
    Fail 'detection success line is missing'
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
if (-not $successBlock.Contains("Write-Output '$displayName'")) {
    Fail 'detection success path does not write the display name'
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
        'Format-RelianWingetVersion',
        'Convert-RelianWingetVersionText',
        'Test-RelianWingetCommandHasAllUsers',
        'Get-RelianWingetDirectoryVersion',
        'Find-RelianWingetInstalledVersion',
        'Test-RelianWingetInstalled',
        'Get-RelianWingetAppxPackages',
        'Get-RelianWingetWindowsAppsDirectoryNames'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$padded = Format-RelianWingetVersion -Version ([version]'1.29.380')
if ($padded -cne $pin) {
    Fail 'three-part client version was not padded to the pin'
}

$atPin = New-WingetDetectPackage -Name $packageName -Version $pin
if (-not (Test-RelianWingetInstalled -Packages @($atPin) -DirectoryNames @())) {
    Fail 'matching package name at the pin was absent'
}
$trimmed = New-WingetDetectPackage -Name "  $packageName  " -Version "  $pin  "
if (-not (Test-RelianWingetInstalled -Packages @($trimmed) -DirectoryNames @())) {
    Fail 'trimmed package name at the pin was absent'
}
$lowerName = New-WingetDetectPackage -Name $packageName.ToLowerInvariant() -Version $pin
if (-not (Test-RelianWingetInstalled -Packages @($lowerName) -DirectoryNames @())) {
    Fail 'package name compared with the wrong case was absent'
}
$threePart = New-WingetDetectPackage -Name $packageName -Version '1.29.380'
if (-not (Test-RelianWingetInstalled -Packages @($threePart) -DirectoryNames @())) {
    Fail 'three-part package version at the pin was absent'
}
$newer = New-WingetDetectPackage -Name $packageName -Version $above
if (-not (Test-RelianWingetInstalled -Packages @($newer) -DirectoryNames @())) {
    Fail 'a package version above the pin was absent'
}
$older = New-WingetDetectPackage -Name $packageName -Version $below
if (Test-RelianWingetInstalled -Packages @($older) -DirectoryNames @()) {
    Fail 'a package version below the pin was present'
}
$otherName = New-WingetDetectPackage -Name 'Other.Package' -Version $above
if (Test-RelianWingetInstalled -Packages @($otherName) -DirectoryNames @()) {
    Fail 'a different package name was present'
}
$fullOnly = [pscustomobject]@{
    PackageFullName = (New-WingetDetectDirectoryName -Version $pin)
    Version         = $pin
}
if (Test-RelianWingetInstalled -Packages @($fullOnly) -DirectoryNames @()) {
    Fail 'a package without the Appx name was present'
}
if (-not (Test-RelianWingetInstalled -Packages @($otherName, $null, $atPin) -DirectoryNames @())) {
    Fail 'a different package name hid the client'
}
if (-not (Test-RelianWingetInstalled -Packages @($older, $newer) -DirectoryNames @())) {
    Fail 'an older package hid a newer client'
}
if (-not (Test-RelianWingetInstalled -Packages @($older, $newer) -DirectoryNames @((New-WingetDetectDirectoryName -Version $below)))) {
    Fail 'a lower directory replaced a newer Appx version'
}
if (Test-RelianWingetInstalled -Packages @($older) -DirectoryNames @((New-WingetDetectDirectoryName -Version $above))) {
    Fail 'a lower Appx version did not hide a newer directory'
}
$unreadable = New-WingetDetectPackage -Name $packageName -Version 'not-a-version'
$directoryAtPin = New-WingetDetectDirectoryName -Version $pin
if (-not (Test-RelianWingetInstalled -Packages @($unreadable) -DirectoryNames @($directoryAtPin))) {
    Fail 'a directory was ignored when Appx had no version'
}
if (-not (Test-RelianWingetInstalled -Packages @($otherName) -DirectoryNames @($directoryAtPin))) {
    Fail 'a directory was ignored when the package name did not match'
}
if (-not (Test-RelianWingetInstalled -Packages @() -DirectoryNames @((New-WingetDetectDirectoryName -Version $pin -Arch 'x86')))) {
    Fail 'an x86 directory at the pin was absent'
}
if (-not (Test-RelianWingetInstalled -Packages @() -DirectoryNames @((New-WingetDetectDirectoryName -Version $above -Arch 'arm64')))) {
    Fail 'an arm64 directory above the pin was absent'
}
if (Test-RelianWingetInstalled -Packages @() -DirectoryNames @((New-WingetDetectDirectoryName -Version $below -Arch 'x64'))) {
    Fail 'a directory below the pin was present'
}
foreach ($absentDir in @(
        (New-WingetDetectDirectoryName -Version $pin -Arch 'arm'),
        ('Other.Package_' + $pin + '_x64__8wekyb3d8bbwe'),
        ($packageName + '_' + $pin + '_x64_8wekyb3d8bbwe'),
        ($packageName + '_' + $pin + '_x64__8wekyb3d8bbwf'),
        ($packageName + '_1.29.380_x64__8wekyb3d8bbwe')
    )) {
    if ($null -ne (Get-RelianWingetDirectoryVersion -Name $absentDir)) {
        Fail "directory name '$absentDir' matched"
    }
    if (Test-RelianWingetInstalled -Packages @() -DirectoryNames @($absentDir)) {
        Fail "directory name '$absentDir' was present"
    }
}
$matchedDir = Get-RelianWingetDirectoryVersion -Name $directoryAtPin
if ($matchedDir -isnot [version]) {
    Fail 'matching directory name was absent'
}
if (Test-RelianWingetInstalled -Packages @() -DirectoryNames @()) {
    Fail 'no packages or directories was present'
}
if (Test-RelianWingetInstalled -Packages $null -DirectoryNames $null) {
    Fail 'null packages and directories was present'
}
if (Test-RelianWingetInstalled -Packages @($atPin) -DirectoryNames @() -PinVersion '') {
    Fail 'an empty pin was present'
}
if (Test-RelianWingetInstalled -Packages @($atPin) -DirectoryNames @() -PinVersion '   ') {
    Fail 'a blank pin was present'
}
if (-not (Test-RelianWingetInstalled -Packages @($atPin) -DirectoryNames @((New-WingetDetectDirectoryName -Version $below)))) {
    Fail 'a lower directory hid an Appx package at the pin'
}

$withAllUsers = [pscustomobject]@{ Parameters = @{ AllUsers = $true; Name = $true } }
$withoutAllUsers = [pscustomobject]@{ Parameters = @{ Name = $true } }
$noParameters = [pscustomobject]@{ Parameters = $null }
if (-not (Test-RelianWingetCommandHasAllUsers -Command $withAllUsers)) {
    Fail 'AllUsers parameter was absent'
}
if (Test-RelianWingetCommandHasAllUsers -Command $withoutAllUsers) {
    Fail 'AllUsers parameter was present on a command that lacks it'
}
if (Test-RelianWingetCommandHasAllUsers -Command $noParameters) {
    Fail 'null parameters reported AllUsers'
}
if (Test-RelianWingetCommandHasAllUsers -Command $null) {
    Fail 'null command reported AllUsers'
}

$seen = @{ Calls = 0; Flags = [System.Collections.Generic.List[bool]]::new() }
$allUsersStub = {
    param([bool]$AllUsers)
    $seen.Calls += 1
    $seen.Flags.Add($AllUsers)
    return @(New-WingetDetectPackage -Name $packageName -Version $pin)
}.GetNewClosure()
$allUsersPackages = @(Get-RelianWingetAppxPackages -Command $withAllUsers -InvokePackage $allUsersStub)
if ($seen.Calls -ne 1 -or $seen.Flags.Count -ne 1 -or -not $seen.Flags[0]) {
    Fail 'AllUsers stub was not the only Appx query'
}
if ($allUsersPackages.Count -ne 1 -or [string]$allUsersPackages[0].Name -ne $packageName) {
    Fail 'AllUsers stub package was not returned'
}

$seen.Calls = 0
$seen.Flags = [System.Collections.Generic.List[bool]]::new()
$currentUserStub = {
    param([bool]$AllUsers)
    $seen.Calls += 1
    $seen.Flags.Add($AllUsers)
    return @(New-WingetDetectPackage -Name $packageName -Version $pin)
}.GetNewClosure()
$currentUserPackages = @(Get-RelianWingetAppxPackages -Command $withoutAllUsers -InvokePackage $currentUserStub)
if ($seen.Calls -ne 1 -or $seen.Flags.Count -ne 1 -or $seen.Flags[0]) {
    Fail 'Appx was queried with AllUsers when the parameter is absent'
}
if ($currentUserPackages.Count -ne 1) {
    Fail 'current-user stub package was not returned'
}

$seen.Calls = 0
$seen.Flags = [System.Collections.Generic.List[bool]]::new()
$refusedStub = {
    param([bool]$AllUsers)
    $seen.Calls += 1
    $seen.Flags.Add($AllUsers)
    if ($AllUsers) {
        throw 'refused'
    }
    return @(New-WingetDetectPackage -Name $packageName -Version $above)
}.GetNewClosure()
$refusedPackages = @(Get-RelianWingetAppxPackages -Command $withAllUsers -InvokePackage $refusedStub)
if ($seen.Calls -ne 2 -or $seen.Flags.Count -ne 2 -or -not $seen.Flags[0] -or $seen.Flags[1]) {
    Fail 'a refused AllUsers query did not fall back'
}
if ($refusedPackages.Count -ne 1 -or [string]$refusedPackages[0].Version -ne $above) {
    Fail 'AllUsers fallback package was not returned'
}
if (-not (Test-RelianWingetInstalled -Packages $refusedPackages -DirectoryNames @())) {
    Fail 'AllUsers fallback package was absent'
}

$seen.Calls = 0
$nullCommandPackages = @(Get-RelianWingetAppxPackages -Command $null -InvokePackage $allUsersStub)
if ($seen.Calls -ne 0 -or $nullCommandPackages.Count -ne 0) {
    Fail 'null command queried Appx'
}

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (Test-IntuneTextHasIpv4 -Text ('pin ' + $pin)) {
    Fail 'version pin was treated as an address'
}
$homeNeedle = '/home/'
foreach ($text in @($jsonText, $detectText)) {
    if (Test-IntuneTextHasIpv4 -Text $text) {
        Fail 'committed file contains an IPv4 address'
    }
    if ($text.Contains($homeNeedle)) {
        Fail 'committed file contains a home path'
    }
}
$testText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8
if (Test-IntuneTextHasIpv4 -Text $testText) {
    Fail 'committed file contains an IPv4 address'
}
$homeCount = [regex]::Matches($testText, [regex]::Escape($homeNeedle)).Count
if ($homeCount -ne 1) {
    Fail 'test file home-path check is not the only home marker'
}

Write-Output 'intune-winget tests passed'
exit 0
