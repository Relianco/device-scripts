$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/apply-action'
$actionRoot = Join-Path $repoRoot 'windows/actions'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-ApplyAction.ps1'
$setupName = 'Invoke-ApplyAction.ps1'

$expectedApps = @(
    @{ Id = 'avd-logon-timeouts'; DisplayName = 'Relian AVD logon timeouts' },
    @{ Id = 'azure-ad-sso-zone'; DisplayName = 'Relian Azure AD SSO zone' },
    @{ Id = 'cloud-kerberos-ticket'; DisplayName = 'Relian cloud Kerberos ticket' },
    @{ Id = 'edge-startup-boost-off'; DisplayName = 'Relian Edge startup boost off' },
    @{ Id = 'fast-startup-off'; DisplayName = 'Relian fast startup off' },
    @{ Id = 'fslogix-cleanup-invalid-sessions'; DisplayName = 'Relian FSLogix cleanup invalid sessions' },
    @{ Id = 'fslogix-no-roam-recycle-bin'; DisplayName = 'Relian FSLogix roam recycle bin off' },
    @{ Id = 'long-paths'; DisplayName = 'Relian long paths' },
    @{ Id = 'mapped-drive-reconnect'; DisplayName = 'Relian mapped drive reconnect' },
    @{ Id = 'onedrive-dehydrate-team-sites'; DisplayName = 'Relian OneDrive dehydrate team sites' },
    @{ Id = 'teams-avd-media'; DisplayName = 'Relian Teams AVD media' }
)

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

function Get-ActionHash {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function New-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value
    )
    return [pscustomobject]@{
        Path  = $Path
        Name  = $Name
        Value = $Value
    }
}

function Get-ActionView {
    param($Document)
    $view = foreach ($step in @($Document.steps)) {
        New-RegistryValue -Path ([string]$step.path) -Name ([string]$step.name) -Value $step.value
    }
    return @($view)
}

if (-not (Test-Path -LiteralPath $jsonPath)) {
    Fail 'intune.json does not exist'
}
if (-not (Test-Path -LiteralPath $detectPath)) {
    Fail 'Detect-ApplyAction.ps1 does not exist'
}

$jsonText = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8
$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
$meta = $jsonText | ConvertFrom-Json

foreach ($text in @($jsonText, $detectText)) {
    if (Test-IntuneTextHasIpv4 -Text $text) {
        Fail 'committed file contains an IPv4 address'
    }
    if ($text.Contains('/home/')) {
        Fail 'committed file contains a home path'
    }
}
$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (Test-IntuneTextHasIpv4 -Text 'pin 30000') {
    Fail 'a dword was treated as an address'
}

$metaFields = @($meta.PSObject.Properties.Name)
$expectedMeta = @('publisher', 'setupFile', 'detectionScript', 'detectReplace', 'apps')
if ($metaFields.Count -ne $expectedMeta.Count) {
    Fail 'intune.json field count'
}
foreach ($field in $expectedMeta) {
    if ($metaFields -cnotcontains $field) {
        Fail "intune.json missing $field"
    }
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne $setupName) {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-ApplyAction.ps1') {
    Fail "detectionScript '$($meta.detectionScript)'"
}
if ($jsonText -notmatch '"detectReplace"\s*:\s*\[\s*"__ACTION_ID__"\s*\]') {
    Fail 'detectReplace is not the action id token'
}
$replace = @($meta.detectReplace)
if ($replace.Count -ne 1 -or [string]$replace[0] -cne '__ACTION_ID__') {
    Fail 'detectReplace did not parse as the action id token'
}

$setupPath = Join-Path $packageDir ([string]$meta.setupFile)
$namedDetectPath = Join-Path $packageDir ([string]$meta.detectionScript)
if (-not (Test-Path -LiteralPath $setupPath)) {
    Fail 'setupFile is not next to intune.json'
}
if (-not (Test-Path -LiteralPath $namedDetectPath)) {
    Fail 'detectionScript is not next to intune.json'
}

$actionFiles = @(Get-ChildItem -LiteralPath $actionRoot -Filter '*.json' | Sort-Object -Property Name)
$apps = @($meta.apps)
if ($apps.Count -ne $expectedApps.Count -or $apps.Count -ne $actionFiles.Count) {
    Fail 'app count does not match the action catalog'
}

$expectedAppFields = @('id', 'displayName', 'pinVersion', 'installCommand', 'uninstallCommand', 'uninstallWorks')
$seenIds = @{}
for ($i = 0; $i -lt $expectedApps.Count; $i++) {
    $expected = $expectedApps[$i]
    $app = $apps[$i]
    $appFields = @($app.PSObject.Properties.Name)
    if ($appFields.Count -ne $expectedAppFields.Count) {
        Fail "$($expected.Id) field count"
    }
    foreach ($field in $expectedAppFields) {
        if ($appFields -cnotcontains $field) {
            Fail "$($expected.Id) missing $field"
        }
    }
    $id = [string]$app.id
    if ($id -cne [string]$expected.Id) {
        Fail "app order at $i is $id"
    }
    if ($seenIds.ContainsKey($id)) {
        Fail "duplicate app $id"
    }
    $seenIds[$id] = $true
    if ([string]$app.displayName -cne [string]$expected.DisplayName) {
        Fail "$id displayName '$($app.displayName)'"
    }
    $actionPath = Join-Path $actionRoot ($id + '.json')
    if (-not (Test-Path -LiteralPath $actionPath)) {
        Fail "$id action file is missing"
    }
    $hash = Get-ActionHash -Path $actionPath
    if ($hash -notmatch '^[0-9a-f]{64}$' -or $hash -match '^(.)\1{63}$') {
        Fail "$id hash is not a real sha256"
    }
    $pin = $id + ':' + $hash
    if ([string]$app.pinVersion -cne $pin) {
        Fail "$id pin disagrees with the action file"
    }
    $install = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-ApplyAction.ps1 -DeploymentType Install -Action Install -PinVersion ' + $pin
    $uninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-ApplyAction.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion ' + $pin
    if ([string]$app.installCommand -cne $install) {
        Fail "$id install command"
    }
    if ([string]$app.uninstallCommand -cne $uninstall) {
        Fail "$id uninstall command"
    }
    foreach ($command in @([string]$app.installCommand, [string]$app.uninstallCommand)) {
        if (-not $command.StartsWith('powershell.exe')) {
            Fail "$id command does not use powershell.exe"
        }
        foreach ($banned in @('-ActionBaseUrl', '-MarkerRoot', '-CancelPath', 'pwsh', 'cmd.exe', 'cmd /c', 'exit 0')) {
            if ($command.Contains($banned)) {
                Fail "$id command contains $banned"
            }
        }
        if (-not $command.Contains('-PinVersion ' + $pin)) {
            Fail "$id command does not bake the pin"
        }
    }
    if (-not $install.Contains('-DeploymentType Install') -or -not $install.Contains('-Action Install')) {
        Fail "$id install action"
    }
    if (-not $uninstall.Contains('-DeploymentType Uninstall') -or -not $uninstall.Contains('-Action Uninstall')) {
        Fail "$id uninstall action"
    }
    $works = $app.PSObject.Properties['uninstallWorks'].Value
    if ($works -isnot [bool] -or $works) {
        Fail "$id uninstallWorks is not false"
    }
}

foreach ($file in $actionFiles) {
    if (-not $seenIds.ContainsKey($file.BaseName)) {
        Fail "catalog action $($file.BaseName) has no app"
    }
}

if ($detectText.Contains($setupName)) {
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
foreach ($bannedCall in @('Write-Error', 'Write-Host', '[Console]::Error', 'New-ItemProperty', 'Set-ItemProperty', 'Remove-ItemProperty', 'New-Item', 'reg.exe')) {
    if ($detectText.Contains($bannedCall)) {
        Fail "detection script contains $bannedCall"
    }
}
$tokens = [regex]::Matches($detectText, '__[A-Z0-9_]+__')
if ($tokens.Count -ne 1 -or $tokens[0].Value -cne '__ACTION_ID__') {
    Fail 'detection placeholder is not the action id token'
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
$presentAt = $detectText.LastIndexOf('if ($installed) {', [System.StringComparison]::Ordinal)
if ($presentAt -lt 0) {
    Fail 'detection success path is missing'
}
$afterPresent = $detectText.Substring($presentAt)
$successExit = $afterPresent.IndexOf('exit 0', [System.StringComparison]::Ordinal)
if ($successExit -lt 0) {
    Fail 'detection success path is missing'
}
$successBlock = $afterPresent.Substring(0, $successExit)
$successLines = $successBlock -split "`n"
$wroteDisplayName = $false
foreach ($line in $successLines) {
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith('#')) {
        continue
    }
    if ($trimmed -ceq 'Write-Output $displayName') {
        $wroteDisplayName = $true
    }
}
if (-not $wroteDisplayName) {
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

$PSNativeCommandUseErrorActionPreference = $false
$savedTest = $env:RELIAN_DEPLOY_TEST
Remove-Item Env:RELIAN_DEPLOY_TEST -ErrorAction SilentlyContinue
$combined = & pwsh -NoProfile -File $detectPath *>&1
$probeCode = $LASTEXITCODE
if ($null -ne $savedTest) {
    $env:RELIAN_DEPLOY_TEST = $savedTest
}
if ($probeCode -ne 1) {
    Fail "leftover action token exited $probeCode"
}
if ($null -ne $combined) {
    Fail 'leftover action token wrote output'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

foreach ($command in @(
        'Test-RelianApplyActionUnresolvedToken',
        'Get-RelianApplyActionDisplayName',
        'Get-RelianApplyActionRequirements',
        'Test-RelianApplyActionInstalled'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

if (-not (Test-RelianApplyActionUnresolvedToken -Text '__ACTION_ID__')) {
    Fail 'leftover action token was not detected'
}
if (-not (Test-RelianApplyActionUnresolvedToken -Text 'prefix __OTHER_TOKEN__ suffix')) {
    Fail 'another placeholder was not detected'
}
if (Test-RelianApplyActionUnresolvedToken -Text 'avd-logon-timeouts') {
    Fail 'an action id was treated as a placeholder'
}
if (Test-RelianApplyActionUnresolvedToken -Text '__[A-Z0-9_]+__') {
    Fail 'the placeholder pattern was treated as a placeholder'
}

try {
    $live = Test-RelianApplyActionInstalled -ActionId 'mapped-drive-reconnect'
    if ($live -isnot [bool]) {
        Fail 'live registry check did not return a bool'
    }
} catch {
    Fail 'a missing registry key threw'
}

foreach ($expected in $expectedApps) {
    $id = [string]$expected.Id
    $actionPath = Join-Path $actionRoot ($id + '.json')
    $document = Get-Content -LiteralPath $actionPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ([string]$document.id -cne $id) {
        Fail "$id document id disagrees with the file name"
    }
    $steps = @($document.steps)
    $requirements = @(Get-RelianApplyActionRequirements -ActionId $id)
    if ($requirements.Count -ne $steps.Count -or $requirements.Count -lt 1) {
        Fail "$id requirement count $($requirements.Count)"
    }
    if ([string](Get-RelianApplyActionDisplayName -ActionId $id) -cne [string]$expected.DisplayName) {
        Fail "$id display name disagrees with intune.json"
    }
    for ($n = 0; $n -lt $steps.Count; $n++) {
        $step = $steps[$n]
        $requirement = $requirements[$n]
        if ($requirement -is [System.Array]) {
            Fail "$id requirement was wrapped in an array"
        }
        if ([string]$step.hive -cne 'HKLM' -or [string]$step.op -cne 'set' -or [string]$step.type -cne 'dword') {
            Fail "$id step is not an HKLM dword set"
        }
        if ([string]$step.path -cne [string]$requirement.Path) {
            Fail "$id path disagrees with the action file"
        }
        if ([string]$step.name -cne [string]$requirement.Name) {
            Fail "$id name disagrees with the action file"
        }
        if ([int64]$step.value -ne [int64]$requirement.Value) {
            Fail "$id value disagrees with the action file"
        }
        if ($id -eq 'avd-logon-timeouts' -and [string]$requirement.Path -eq 'SOFTWARE\Policies\Microsoft\Windows\System') {
            Fail 'avd followed the policy path instead of the action file'
        }
    }
    $view = Get-ActionView -Document $document
    if (-not (Test-RelianApplyActionInstalled -ActionId $id -Registry $view)) {
        Fail "$id was absent when its registry values matched"
    }
}

if (Test-RelianApplyActionInstalled -ActionId 'not-a-catalog-action' -Registry @()) {
    Fail 'an unknown id was installed'
}
$avdPath = Join-Path $actionRoot 'avd-logon-timeouts.json'
$avdDocument = Get-Content -LiteralPath $avdPath -Raw -Encoding utf8 | ConvertFrom-Json
$avdView = Get-ActionView -Document $avdDocument
if ($avdView.Count -ne 4) {
    Fail 'avd view count'
}
if (Test-RelianApplyActionInstalled -ActionId '__ACTION_ID__' -Registry $avdView) {
    Fail 'leftover __ACTION_ID__ was installed'
}
$avdCleanup = @($avdView | Where-Object { [string]$_.Name -eq 'CleanupInvalidSessions' })
if ($avdCleanup.Count -ne 1 -or [int64]$avdCleanup[0].Value -ne 1) {
    Fail 'avd cleanup step was not CleanupInvalidSessions=1'
}
$onlyCleanup = @(New-RegistryValue -Path ([string]$avdCleanup[0].Path) -Name ([string]$avdCleanup[0].Name) -Value $avdCleanup[0].Value)
if (Test-RelianApplyActionInstalled -ActionId 'avd-logon-timeouts' -Registry $onlyCleanup) {
    Fail 'avd passed when only CleanupInvalidSessions=1'
}
if (-not (Test-RelianApplyActionInstalled -ActionId 'fslogix-cleanup-invalid-sessions' -Registry $onlyCleanup)) {
    Fail 'fslogix cleanup did not pass on CleanupInvalidSessions=1'
}
if (Test-RelianApplyActionInstalled -ActionId 'avd-logon-timeouts' -Registry @()) {
    Fail 'avd passed with no registry values'
}

$wrongTimeout = foreach ($entry in $avdView) {
    $value = $entry.Value
    if ([string]$entry.Name -eq 'FirstLogonTimeout') {
        $value = 31
    }
    New-RegistryValue -Path ([string]$entry.Path) -Name ([string]$entry.Name) -Value $value
}
if (Test-RelianApplyActionInstalled -ActionId 'avd-logon-timeouts' -Registry @($wrongTimeout)) {
    Fail 'avd passed with the wrong FirstLogonTimeout'
}

$roamPath = Join-Path $actionRoot 'fslogix-no-roam-recycle-bin.json'
$roamDocument = Get-Content -LiteralPath $roamPath -Raw -Encoding utf8 | ConvertFrom-Json
$roamStep = @($roamDocument.steps)[0]
if ([string]$roamStep.name -cne 'RoamRecycleBin' -or [int64]$roamStep.value -ne 0) {
    Fail 'roam action file is not RoamRecycleBin=0'
}
$roamOff = @(New-RegistryValue -Path ([string]$roamStep.path) -Name ([string]$roamStep.name) -Value $roamStep.value)
$roamOn = @(New-RegistryValue -Path ([string]$roamStep.path) -Name ([string]$roamStep.name) -Value 1)
$roamText = @(New-RegistryValue -Path ([string]$roamStep.path) -Name ([string]$roamStep.name) -Value '0')
$roamMissing = @(New-RegistryValue -Path ([string]$roamStep.path) -Name 'OtherValue' -Value 0)
if (-not (Test-RelianApplyActionInstalled -ActionId 'fslogix-no-roam-recycle-bin' -Registry $roamOff)) {
    Fail 'roam recycle bin value 0 was not installed'
}
if (Test-RelianApplyActionInstalled -ActionId 'fslogix-no-roam-recycle-bin' -Registry $roamOn) {
    Fail 'roam recycle bin value 1 was installed'
}
if (Test-RelianApplyActionInstalled -ActionId 'fslogix-no-roam-recycle-bin' -Registry $roamText) {
    Fail 'roam recycle bin string 0 was installed'
}
if (Test-RelianApplyActionInstalled -ActionId 'fslogix-no-roam-recycle-bin' -Registry $roamMissing) {
    Fail 'a missing roam recycle bin value was installed'
}
if (Test-RelianApplyActionInstalled -ActionId 'fslogix-no-roam-recycle-bin' -Registry @()) {
    Fail 'an empty roam recycle bin view was installed'
}

$cleanupOn = @(New-RegistryValue -Path 'SOFTWARE\FSLogix\Apps' -Name 'CleanupInvalidSessions' -Value $true)
if (Test-RelianApplyActionInstalled -ActionId 'fslogix-cleanup-invalid-sessions' -Registry $cleanupOn) {
    Fail 'a bool was treated as the cleanup dword'
}

Write-Output 'intune-apply-action tests passed'
exit 0
