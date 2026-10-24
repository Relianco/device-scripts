$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/teams'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Teams.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/teams.json'
$pin = '0.0.0.1'
$displayName = 'Relian Microsoft Teams'
$packageName = 'MSTeams'

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

function Remove-TeamsSentinelPin {
    param([string]$Text)
    $pattern = '(?<![0-9])' + [regex]::Escape($pin) + '(?![0-9])'
    return [regex]::Replace($Text, $pattern, '')
}

function New-TeamsDetectPackage {
    param([string]$Name)
    return [pscustomobject]@{
        Name = $Name
    }
}

if (-not (Test-Path -LiteralPath $jsonPath)) {
    Fail 'intune.json does not exist'
}
if (-not (Test-Path -LiteralPath $detectPath)) {
    Fail 'Detect-Teams.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/teams.json does not exist'
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
foreach ($releaseName in @($release.PSObject.Properties.Name)) {
    if ($releaseName -eq 'version') {
        Fail 'teams release has a product version'
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
if ([string]$meta.displayName -cne $displayName) {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-Teams.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-Teams.ps1') {
    Fail "detectionScript '$($meta.detectionScript)'"
}
if ($jsonText -notmatch '"detectReplace"\s*:\s*\[\s*\]') {
    Fail 'detectReplace must be an empty array'
}
if ($null -eq $meta.detectReplace -or @($meta.detectReplace).Count -ne 0) {
    Fail 'detectReplace is not empty'
}

$quads = [regex]::Matches($jsonText, '(?<![0-9])[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(?![0-9])')
if ($quads.Count -eq 0) {
    Fail 'intune.json is missing the pin'
}
foreach ($quad in $quads) {
    if ($quad.Value -cne $pin) {
        Fail "intune.json has four-part version $($quad.Value)"
    }
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
$expectedInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Teams.ps1 -DeploymentType Install -Action Install -PinVersion 0.0.0.1'
$expectedUninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Teams.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion 0.0.0.1'
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
    $pinMatch = [regex]::Match($command, '-PinVersion\s+(\S+)')
    if (-not $pinMatch.Success -or $pinMatch.Groups[1].Value -cne '0.0.0.1') {
        Fail 'pin is not exactly 0.0.0.1'
    }
}
if (-not $installCommand.Contains('-DeploymentType Install') -or -not $installCommand.Contains('-Action Install')) {
    Fail 'install action'
}
if (-not $uninstallCommand.Contains('-DeploymentType Uninstall') -or -not $uninstallCommand.Contains('-Action Uninstall')) {
    Fail 'uninstall action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
if ($detectText.Contains('Invoke-Teams')) {
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
if ($detectText.IndexOf('IsWVDEnvironment', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
    Fail 'detection script contains IsWVDEnvironment'
}
if (-not $detectText.Contains('Write-Output')) {
    Fail 'Write-Output is missing'
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
$readAt = $detectText.LastIndexOf('Get-RelianTeamsAppxPackages', [System.StringComparison]::Ordinal)
if ($readAt -lt 0 -or $readAt -lt $guardAt) {
    Fail 'Appx list is not read after the test guard'
}
$allUsersCall = "Get-AppxPackage -Name '$packageName' -AllUsers -ErrorAction Stop"
$currentUserCall = "Get-AppxPackage -Name '$packageName' -ErrorAction Stop"
if (-not $detectText.Contains($allUsersCall)) {
    Fail 'detection does not query Appx for all users'
}
if (-not $detectText.Contains($currentUserCall)) {
    Fail 'detection does not query Appx without AllUsers'
}
if (-not $detectText.Contains('Test-RelianTeamsCommandHasAllUsers')) {
    Fail 'detection does not check for the AllUsers parameter'
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
        'Test-RelianTeamsCommandHasAllUsers',
        'Test-RelianTeamsInstalled',
        'Get-RelianTeamsAppxPackages'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

function Get-AppxPackage {
    param(
        [string]$Name,
        [switch]$AllUsers
    )
    Fail 'Get-AppxPackage was called'
}

$presentPackage = New-TeamsDetectPackage -Name $packageName
if (-not (Test-RelianTeamsInstalled -Packages @($presentPackage))) {
    Fail 'a stub package named MSTeams was absent'
}
$otherPackage = New-TeamsDetectPackage -Name 'Teams'
if (Test-RelianTeamsInstalled -Packages @($otherPackage)) {
    Fail 'a different name was present'
}
if (-not (Test-RelianTeamsInstalled -Packages @($otherPackage, $null, $presentPackage))) {
    Fail 'a different name hid MSTeams'
}
if (Test-RelianTeamsInstalled -Packages @()) {
    Fail 'an empty package list was present'
}
if (Test-RelianTeamsInstalled -Packages $null) {
    Fail 'a null package list was present'
}
$noName = [pscustomobject]@{ PackageFullName = 'not-the-appx-name' }
if (Test-RelianTeamsInstalled -Packages @($noName)) {
    Fail 'a package without the Appx name was present'
}

$withAllUsers = [pscustomobject]@{ Parameters = @{ AllUsers = $true; Name = $true } }
$withoutAllUsers = [pscustomobject]@{ Parameters = @{ Name = $true } }
$noParameters = [pscustomobject]@{ Parameters = $null }
if (-not (Test-RelianTeamsCommandHasAllUsers -Command $withAllUsers)) {
    Fail 'AllUsers parameter was absent'
}
if (Test-RelianTeamsCommandHasAllUsers -Command $withoutAllUsers) {
    Fail 'AllUsers parameter was present on a command that lacks it'
}
if (Test-RelianTeamsCommandHasAllUsers -Command $noParameters) {
    Fail 'null parameters reported AllUsers'
}
if (Test-RelianTeamsCommandHasAllUsers -Command $null) {
    Fail 'null command reported AllUsers'
}

$seen = @{ Calls = 0; Flags = [System.Collections.Generic.List[bool]]::new() }
$allUsersStub = {
    param([bool]$AllUsers)
    $seen.Calls += 1
    $seen.Flags.Add($AllUsers)
    return @(New-TeamsDetectPackage -Name $packageName)
}.GetNewClosure()
$allUsersPackages = @(Get-RelianTeamsAppxPackages -Command $withAllUsers -InvokePackage $allUsersStub)
if ($seen.Calls -ne 1 -or $seen.Flags.Count -ne 1 -or -not $seen.Flags[0]) {
    Fail 'AllUsers stub was not the only Appx query'
}
if ($allUsersPackages.Count -ne 1 -or [string]$allUsersPackages[0].Name -cne $packageName) {
    Fail 'AllUsers stub package was not returned'
}
if (-not (Test-RelianTeamsInstalled -Packages $allUsersPackages)) {
    Fail 'AllUsers stub package was absent'
}

$seen.Calls = 0
$seen.Flags = [System.Collections.Generic.List[bool]]::new()
$currentUserStub = {
    param([bool]$AllUsers)
    $seen.Calls += 1
    $seen.Flags.Add($AllUsers)
    return @(New-TeamsDetectPackage -Name $packageName)
}.GetNewClosure()
$currentUserPackages = @(Get-RelianTeamsAppxPackages -Command $withoutAllUsers -InvokePackage $currentUserStub)
if ($seen.Calls -ne 1 -or $seen.Flags.Count -ne 1 -or $seen.Flags[0]) {
    Fail 'Appx was queried with AllUsers when the parameter is absent'
}
if ($currentUserPackages.Count -ne 1 -or [string]$currentUserPackages[0].Name -cne $packageName) {
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
    return @(New-TeamsDetectPackage -Name $packageName)
}.GetNewClosure()
$refusedPackages = @(Get-RelianTeamsAppxPackages -Command $withAllUsers -InvokePackage $refusedStub)
if ($seen.Calls -ne 2 -or $seen.Flags.Count -ne 2 -or -not $seen.Flags[0] -or $seen.Flags[1]) {
    Fail 'a refused AllUsers query did not fall back'
}
if ($refusedPackages.Count -ne 1 -or [string]$refusedPackages[0].Name -cne $packageName) {
    Fail 'AllUsers fallback package was not returned'
}
if (-not (Test-RelianTeamsInstalled -Packages $refusedPackages)) {
    Fail 'AllUsers fallback package was absent'
}

$seen.Calls = 0
$nullCommandPackages = @(Get-RelianTeamsAppxPackages -Command $null -InvokePackage $allUsersStub)
if ($seen.Calls -ne 0 -or $nullCommandPackages.Count -ne 0) {
    Fail 'null command queried Appx'
}

$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (-not (Test-IntuneTextHasIpv4 -Text $pin)) {
    Fail 'ipv4 scanner missed the sentinel pin'
}
if (Test-IntuneTextHasIpv4 -Text (Remove-TeamsSentinelPin -Text $pin)) {
    Fail 'scrubbed sentinel pin was treated as an address'
}
$hiddenAddress = '1' + $pin
if (-not (Test-IntuneTextHasIpv4 -Text (Remove-TeamsSentinelPin -Text $hiddenAddress))) {
    Fail 'ipv4 scanner missed an address that contains the pin'
}

$banned = @(
    ('Le' + 'ague'),
    ('PI' + 'LA'),
    ('Sit' + 'ka')
)
$homeNeedle = '/home/'
$testText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8
foreach ($text in @($jsonText, $detectText, $testText)) {
    if (Test-IntuneTextHasIpv4 -Text (Remove-TeamsSentinelPin -Text $text)) {
        Fail 'committed file contains an IPv4 address'
    }
    foreach ($word in $banned) {
        if ($text.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Fail 'committed file contains a banned marker'
        }
    }
}
foreach ($text in @($jsonText, $detectText)) {
    if ($text.Contains($homeNeedle)) {
        Fail 'committed file contains a home path'
    }
}
$homeCount = [regex]::Matches($testText, [regex]::Escape($homeNeedle)).Count
if ($homeCount -ne 1) {
    Fail 'test file home-path check is not the only home marker'
}

Write-Output 'intune-teams tests passed'
exit 0
