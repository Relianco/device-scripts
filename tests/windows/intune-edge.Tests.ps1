$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/edge'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-Edge.ps1'
$releasePath = Join-Path $repoRoot 'windows/releases/edge.json'
$pin = '155.0.4283.62'
$edgeCode = '{11111111-2222-3333-4444-555555555555}'
$webviewCode = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'

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
        $valid = $true
        foreach ($part in $match.Value.Split('.')) {
            $number = 0
            if (-not [int]::TryParse($part, [ref]$number) -or $number -gt 255) {
                $valid = $false
            }
        }
        if ($valid) {
            return $true
        }
    }
    return $false
}

function New-EdgeDetectEntry {
    param(
        [string]$DisplayName,
        [string]$DisplayVersion,
        [string]$ProductCode = '',
        [string]$UninstallString = '',
        [string]$PSChildName = '',
        [string]$Publisher = 'Other Publisher'
    )
    return [pscustomobject]@{
        DisplayName     = $DisplayName
        DisplayVersion  = $DisplayVersion
        ProductCode     = $ProductCode
        UninstallString = $UninstallString
        PSChildName     = $PSChildName
        Publisher       = $Publisher
    }
}

if (-not (Test-Path -LiteralPath $jsonPath)) {
    Fail 'windows/packages/edge/intune.json does not exist'
}
if (-not (Test-Path -LiteralPath $detectPath)) {
    Fail 'Detect-Edge.ps1 does not exist'
}
if (-not (Test-Path -LiteralPath $releasePath)) {
    Fail 'windows/releases/edge.json does not exist'
}

$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.version -cne $pin) {
    Fail "release version '$($release.version)' is not $pin"
}

$jsonText = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8
$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
$testText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8
$sampleAddress = (@(10, 1, 2, 3) -join '.')
if (-not (Test-IntuneTextHasIpv4 -Text "prefix $sampleAddress suffix")) {
    Fail 'ipv4 scanner missed an address'
}
if (Test-IntuneTextHasIpv4 -Text $pin) {
    Fail 'version pin was treated as an address'
}
$banned = @(
    -join @('Le', 'ague'),
    -join @('PI', 'LA'),
    -join @('Sit', 'ka'),
    -join @('/', 'home', '/')
)
foreach ($text in @($jsonText, $detectText, $testText)) {
    if (Test-IntuneTextHasIpv4 -Text $text) {
        Fail 'committed file contains an IPv4 address'
    }
    foreach ($word in $banned) {
        if ($text.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Fail 'committed file contains a banned marker'
        }
    }
}

$json = $jsonText | ConvertFrom-Json
$fieldNames = @($json.PSObject.Properties.Name)
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
foreach ($name in $expectedFields) {
    if ($fieldNames -cnotcontains $name) {
        Fail "intune.json is missing $name"
    }
}
if ([string]$json.displayName -cne 'Relian Microsoft Edge') {
    Fail "displayName '$($json.displayName)'"
}
if ([string]$json.publisher -cne 'Relian') {
    Fail "publisher '$($json.publisher)'"
}
if ([string]$json.setupFile -cne 'Invoke-Edge.ps1') {
    Fail "setupFile '$($json.setupFile)'"
}
if ([string]$json.detectionScript -cne 'Detect-Edge.ps1') {
    Fail "detectionScript '$($json.detectionScript)'"
}
if ($jsonText -notmatch '"detectReplace"\s*:\s*\[\s*\]') {
    Fail 'detectReplace is not an empty array'
}
if ($null -ne $json.detectReplace -and @($json.detectReplace).Count -ne 0) {
    Fail 'detectReplace is not empty'
}

$setupPath = Join-Path $packageDir ([string]$json.setupFile)
$detectionPath = Join-Path $packageDir ([string]$json.detectionScript)
if (-not (Test-Path -LiteralPath $setupPath)) {
    Fail 'setupFile is not next to intune.json'
}
if (-not (Test-Path -LiteralPath $detectionPath)) {
    Fail 'detectionScript is not next to intune.json'
}

$expectedInstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Edge.ps1 -DeploymentType Install -Action Install -PinVersion $pin"
$expectedUninstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Edge.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion $pin"
if ([string]$json.installCommand -cne $expectedInstall) {
    Fail "installCommand '$($json.installCommand)'"
}
if ([string]$json.uninstallCommand -cne $expectedUninstall) {
    Fail "uninstallCommand '$($json.uninstallCommand)'"
}
foreach ($command in @([string]$json.installCommand, [string]$json.uninstallCommand)) {
    if ($command -notlike 'powershell.exe *') {
        Fail "command does not use powershell.exe: $command"
    }
    if ($command -match 'pwsh') {
        Fail "command contains pwsh: $command"
    }
    if (-not $command.Contains($pin)) {
        Fail "command is missing the pin: $command"
    }
}
if ($json.installCommand -notlike '*-Action Install*') {
    Fail 'install command is missing Action Install'
}
if ($json.uninstallCommand -notlike '*-Action Uninstall*') {
    Fail 'uninstall command is missing Action Uninstall'
}

if ($detectText.Contains('Invoke-Edge')) {
    Fail 'detection script references the installer'
}
if ($detectText -match '(?m)^\s*\.\s+') {
    Fail 'detection script dot-sources a file'
}
if ($detectText.Contains('Publisher')) {
    Fail 'detection script checks a publisher'
}
if ($detectText -notmatch '\$ErrorActionPreference\s*=\s*''Stop''') {
    Fail 'detection script does not set ErrorActionPreference'
}
if ($detectText -notmatch 'Set-StrictMode\s+-Version\s+Latest') {
    Fail 'detection script does not set StrictMode'
}
if ($detectText -notmatch "Convert-EdgeDetectVersionText -Text '$([regex]::Escape($pin))'") {
    Fail 'detection pin is not 155.0.4283.62'
}
foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
    if (-not $detectText.Contains($root)) {
        Fail "detection script misses $root"
    }
}
$guard = "if (`$env:RELIAN_DEPLOY_TEST -eq '1')"
$guardAt = $detectText.IndexOf($guard, [System.StringComparison]::Ordinal)
$exitAt = $detectText.IndexOf('exit ', [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $exitAt -lt 0 -or $exitAt -lt $guardAt) {
    Fail 'detection script exits before the test guard'
}
$registryAt = $detectText.LastIndexOf('Get-EdgeDetectRegistryEntries', [System.StringComparison]::Ordinal)
if ($registryAt -lt $guardAt) {
    Fail 'registry read is not after the test guard'
}
$successLine = "Write-Output 'Relian Microsoft Edge'"
if ([regex]::Matches($detectText, [regex]::Escape($successLine)).Count -ne 1) {
    Fail 'success output was missing'
}
$successPattern = "(?s)if \(\`$present\) \{\r?\n    Write-Output 'Relian Microsoft Edge'\r?\n    exit 0\r?\n\}"
if ($detectText -notmatch $successPattern) {
    Fail 'success output was missing'
}
$successBlock = [string]$Matches[0]
$exitZeroAt = $detectText.LastIndexOf('exit 0', [System.StringComparison]::Ordinal)
$exitOneAt = $detectText.LastIndexOf('exit 1', [System.StringComparison]::Ordinal)
if ($exitZeroAt -lt 0 -or $exitOneAt -lt $exitZeroAt) {
    Fail 'failure path is missing'
}
$failureBlock = $detectText.Substring($exitZeroAt, $exitOneAt - $exitZeroAt)
if ($failureBlock.Contains('Write-Output') -or $failureBlock.Contains('Write-Error') -or $failureBlock.Contains('[Console]::Error') -or $failureBlock.Contains('Write-Host')) {
    Fail 'failure path writes output'
}

$successProbe = Join-Path ([System.IO.Path]::GetTempPath()) ('edge-detect-success-' + [guid]::NewGuid().ToString('n') + '.ps1')
$successOutFile = Join-Path ([System.IO.Path]::GetTempPath()) ('edge-detect-success-out-' + [guid]::NewGuid().ToString('n'))
$successErrFile = Join-Path ([System.IO.Path]::GetTempPath()) ('edge-detect-success-err-' + [guid]::NewGuid().ToString('n'))
$successExit = -1
try {
    Set-Content -LiteralPath $successProbe -Value ("`$present = `$true`n" + $successBlock + "`nexit 1`n") -Encoding utf8
    & pwsh -NoProfile -File $successProbe 1> $successOutFile 2> $successErrFile
    $successExit = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $successProbe -Force -ErrorAction SilentlyContinue
}
if ($successExit -ne 0) {
    Fail "success path exited $successExit"
}
$successOut = ''
if (Test-Path -LiteralPath $successOutFile) {
    $successOut = [string](Get-Content -LiteralPath $successOutFile -Raw -Encoding utf8)
    Remove-Item -LiteralPath $successOutFile -Force -ErrorAction SilentlyContinue
}
$successErr = ''
if (Test-Path -LiteralPath $successErrFile) {
    $successErr = [string](Get-Content -LiteralPath $successErrFile -Raw -Encoding utf8)
    Remove-Item -LiteralPath $successErrFile -Force -ErrorAction SilentlyContinue
}
if ($successOut.Trim() -cne 'Relian Microsoft Edge') {
    Fail 'success output was missing'
}
if (-not [string]::IsNullOrWhiteSpace($successErr)) {
    Fail 'success path wrote to the error stream'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $detectPath

foreach ($command in @(
        'Test-EdgeDetectDisplayName',
        'Test-EdgeDetectExcludedProductCode',
        'Test-EdgeDetectInstalled'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

if (-not (Test-EdgeDetectDisplayName -Name 'Microsoft Edge')) {
    Fail 'Microsoft Edge display name was rejected'
}
if (-not (Test-EdgeDetectDisplayName -Name '  Microsoft Edge  ')) {
    Fail 'trimmed Microsoft Edge display name was rejected'
}
if (-not (Test-EdgeDetectDisplayName -Name 'microsoft edge')) {
    Fail 'display name comparison diverged from the installer'
}
if (Test-EdgeDetectDisplayName -Name 'Microsoft Edge WebView2 Runtime') {
    Fail 'WebView display name was present'
}
if (Test-EdgeDetectDisplayName -Name 'MICROSOFT EDGE WEBVIEW2 RUNTIME') {
    Fail 'WebView display name was present'
}
if (Test-EdgeDetectDisplayName -Name 'Microsoft Edge Beta') {
    Fail 'a display name other than Microsoft Edge was present'
}
if (Test-EdgeDetectDisplayName -Name '') {
    Fail 'an empty display name was present'
}
if (-not (Test-EdgeDetectExcludedProductCode -ProductCode $webviewCode)) {
    Fail 'WebView2 product code was not excluded'
}
if (-not (Test-EdgeDetectExcludedProductCode -ProductCode $webviewCode.ToLowerInvariant())) {
    Fail 'WebView2 product code comparison was case-sensitive'
}
if (-not (Test-EdgeDetectExcludedProductCode -ProductCode '')) {
    Fail 'an empty product code was not excluded'
}
if (Test-EdgeDetectExcludedProductCode -ProductCode $edgeCode) {
    Fail 'an Edge product code was excluded'
}

$atPin = New-EdgeDetectEntry -DisplayName 'Microsoft Edge' -DisplayVersion $pin -ProductCode $edgeCode
if (-not (Test-EdgeDetectInstalled -Entries @($atPin))) {
    Fail 'matching Edge entry was absent'
}
$trimmed = New-EdgeDetectEntry -DisplayName '  Microsoft Edge  ' -DisplayVersion " $pin " -ProductCode $edgeCode
if (-not (Test-EdgeDetectInstalled -Entries @($trimmed))) {
    Fail 'trimmed Edge display name or version was absent'
}
$abovePin = New-EdgeDetectEntry -DisplayName 'Microsoft Edge' -DisplayVersion '155.0.4283.63' -ProductCode $edgeCode
if (-not (Test-EdgeDetectInstalled -Entries @($abovePin))) {
    Fail 'Edge newer than the pin was absent'
}
$older = New-EdgeDetectEntry -DisplayName 'Microsoft Edge' -DisplayVersion '155.0.4283.61' -ProductCode $edgeCode
if (Test-EdgeDetectInstalled -Entries @($older)) {
    Fail 'Edge older than the pin was present'
}
$webviewName = New-EdgeDetectEntry -DisplayName 'Microsoft Edge WebView2 Runtime' -DisplayVersion '999.0.0.0' -ProductCode $edgeCode
if (Test-EdgeDetectInstalled -Entries @($webviewName)) {
    Fail 'WebView display name was present'
}
$webviewProduct = New-EdgeDetectEntry -DisplayName 'Microsoft Edge' -DisplayVersion '999.0.0.0' -ProductCode $webviewCode
if (Test-EdgeDetectInstalled -Entries @($webviewProduct)) {
    Fail 'WebView2 product code was present'
}
$lowercaseWebView = New-EdgeDetectEntry -DisplayName 'Microsoft Edge' -DisplayVersion $pin -ProductCode $webviewCode.ToLowerInvariant()
if (Test-EdgeDetectInstalled -Entries @($lowercaseWebView)) {
    Fail 'WebView2 product code was present'
}
if (-not (Test-EdgeDetectInstalled -Entries @($webviewName, $webviewProduct, $atPin))) {
    Fail 'a WebView entry hid the matching Edge entry'
}
if (-not (Test-EdgeDetectInstalled -Entries @($null, $atPin))) {
    Fail 'an unreadable uninstall key stopped the search'
}
$beta = New-EdgeDetectEntry -DisplayName 'Microsoft Edge Beta' -DisplayVersion '999.0.0.0' -ProductCode $edgeCode
if (Test-EdgeDetectInstalled -Entries @($beta)) {
    Fail 'a display name other than Microsoft Edge was present'
}
$noVersion = New-EdgeDetectEntry -DisplayName 'Microsoft Edge' -DisplayVersion '' -ProductCode $edgeCode
if (Test-EdgeDetectInstalled -Entries @($noVersion)) {
    Fail 'an empty DisplayVersion was present'
}
$badVersion = New-EdgeDetectEntry -DisplayName 'Microsoft Edge' -DisplayVersion 'not-a-version' -ProductCode $edgeCode
if (Test-EdgeDetectInstalled -Entries @($badVersion)) {
    Fail 'an unparsed DisplayVersion was present'
}
$noCode = New-EdgeDetectEntry -DisplayName 'Microsoft Edge' -DisplayVersion $pin -ProductCode ''
if (Test-EdgeDetectInstalled -Entries @($noCode)) {
    Fail 'an entry with no product code was present'
}
$notGuid = New-EdgeDetectEntry -DisplayName 'Microsoft Edge' -DisplayVersion $pin -ProductCode 'not-a-guid'
if (Test-EdgeDetectInstalled -Entries @($notGuid)) {
    Fail 'a product code that is not a GUID was present'
}
$fromKey = New-EdgeDetectEntry -DisplayName 'Microsoft Edge' -DisplayVersion $pin -ProductCode '' -PSChildName $edgeCode
if (-not (Test-EdgeDetectInstalled -Entries @($fromKey))) {
    Fail 'a product code in the uninstall key name was ignored'
}
$fromUninstall = New-EdgeDetectEntry -DisplayName 'Microsoft Edge' -DisplayVersion $pin -ProductCode '' -UninstallString ('MsiExec.exe /X' + $edgeCode)
if (-not (Test-EdgeDetectInstalled -Entries @($fromUninstall))) {
    Fail 'a product code embedded in UninstallString was ignored'
}
$looseKey = New-EdgeDetectEntry -DisplayName 'Microsoft Edge' -DisplayVersion $pin -ProductCode '' -PSChildName ('prefix-' + $edgeCode)
if (Test-EdgeDetectInstalled -Entries @($looseKey)) {
    Fail 'a key name that only contains a product code counted as one'
}
$keyWins = New-EdgeDetectEntry -DisplayName 'Microsoft Edge' -DisplayVersion $pin -ProductCode '' -PSChildName $webviewCode -UninstallString ('MsiExec.exe /X' + $edgeCode)
if (Test-EdgeDetectInstalled -Entries @($keyWins)) {
    Fail 'WebView2 product code on the key was ignored'
}
if (Test-EdgeDetectInstalled -Entries @()) {
    Fail 'no entries was present'
}
if (-not (Test-EdgeDetectInstalled -Entries @($older, $atPin))) {
    Fail 'an older Edge entry hid the matching Edge entry'
}

$registryMissing = $true
foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
    $rootPresent = $false
    try {
        $rootPresent = Test-Path -LiteralPath $root
    } catch {
        $rootPresent = $false
    }
    if ($rootPresent) {
        $registryMissing = $false
    }
}
if ($registryMissing) {
    $savedTest = $env:RELIAN_DEPLOY_TEST
    $liveExit = -1
    $liveOutFile = Join-Path ([System.IO.Path]::GetTempPath()) ('edge-detect-miss-out-' + [guid]::NewGuid().ToString('n'))
    $liveErrFile = Join-Path ([System.IO.Path]::GetTempPath()) ('edge-detect-miss-err-' + [guid]::NewGuid().ToString('n'))
    try {
        Remove-Item -Path Env:RELIAN_DEPLOY_TEST -ErrorAction SilentlyContinue
        & pwsh -NoProfile -File $detectPath 1> $liveOutFile 2> $liveErrFile
        $liveExit = $LASTEXITCODE
    } finally {
        $env:RELIAN_DEPLOY_TEST = $savedTest
    }
    $liveOut = ''
    if (Test-Path -LiteralPath $liveOutFile) {
        $liveOut = [string](Get-Content -LiteralPath $liveOutFile -Raw -Encoding utf8)
        Remove-Item -LiteralPath $liveOutFile -Force -ErrorAction SilentlyContinue
    }
    $liveErr = ''
    if (Test-Path -LiteralPath $liveErrFile) {
        $liveErr = [string](Get-Content -LiteralPath $liveErrFile -Raw -Encoding utf8)
        Remove-Item -LiteralPath $liveErrFile -Force -ErrorAction SilentlyContinue
    }
    if ($liveExit -ne 1) {
        Fail "missing registry detection exited $liveExit"
    }
    if (-not [string]::IsNullOrWhiteSpace($liveOut) -or -not [string]::IsNullOrWhiteSpace($liveErr)) {
        Fail 'missing registry detection wrote output'
    }
}

Write-Output 'PASS intune-edge'
exit 0
