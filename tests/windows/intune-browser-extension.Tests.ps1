$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageDir = Join-Path $repoRoot 'windows/packages/browser-extension'
$jsonPath = Join-Path $packageDir 'intune.json'
$detectPath = Join-Path $packageDir 'Detect-BrowserExtension.ps1'
$setupPath = Join-Path $packageDir 'Invoke-BrowserExtension.ps1'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

foreach ($path in @($jsonPath, $detectPath, $setupPath)) {
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
for ($i = 0; $i -lt $expectedFields.Count; $i++) {
    if ([string]$fieldNames[$i] -cne $expectedFields[$i]) {
        Fail "intune.json field $($fieldNames[$i])"
    }
}
if ([string]$meta.displayName -cne 'Relian __BROWSER__ extension __EXTENSION_ID__') {
    Fail "displayName '$($meta.displayName)'"
}
if ([string]$meta.publisher -cne 'Relian') {
    Fail "publisher '$($meta.publisher)'"
}
if ([string]$meta.setupFile -cne 'Invoke-BrowserExtension.ps1') {
    Fail "setupFile '$($meta.setupFile)'"
}
if ([string]$meta.detectionScript -cne 'Detect-BrowserExtension.ps1') {
    Fail "detectionScript '$($meta.detectionScript)'"
}
if (-not (Test-Path -LiteralPath (Join-Path $packageDir ([string]$meta.setupFile)))) {
    Fail 'setupFile is not next to intune.json'
}
if (-not (Test-Path -LiteralPath (Join-Path $packageDir ([string]$meta.detectionScript)))) {
    Fail 'detectionScript is not next to intune.json'
}
if ($jsonText.Contains('PinVersion') -or $jsonText.Contains('ExtensionUrl')) {
    Fail 'intune.json contains PinVersion or ExtensionUrl'
}

$tokens = @('__BROWSER__', '__EXTENSION_ID__')
$replace = @($meta.detectReplace)
if ($replace.Count -ne $tokens.Count) {
    Fail 'detectReplace count'
}
for ($i = 0; $i -lt $tokens.Count; $i++) {
    if ([string]$replace[$i] -cne $tokens[$i]) {
        Fail "detectReplace[$i] '$($replace[$i])'"
    }
    if ($tokens[$i] -notmatch '^__[A-Z0-9_]+__$') {
        Fail "token shape $($tokens[$i])"
    }
}

# {env:BROWSER} and {env:EXTENSION_ID} stay in the command because the packager fills them before upload.
$expectedInstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-BrowserExtension.ps1 -DeploymentType Install -Action Install -Browser "{env:BROWSER}" -ExtensionId "{env:EXTENSION_ID}"'
$expectedUninstall = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-BrowserExtension.ps1 -DeploymentType Uninstall -Action Uninstall -Browser "{env:BROWSER}" -ExtensionId "{env:EXTENSION_ID}"'
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
    foreach ($piece in @('{env:BROWSER}', '{env:EXTENSION_ID}', '-Browser', '-ExtensionId')) {
        if (-not $command.Contains($piece)) {
            Fail "command is missing $piece"
        }
    }
    if ($command.Contains('PinVersion') -or $command.Contains('ExtensionUrl')) {
        Fail 'command passes PinVersion or ExtensionUrl'
    }
    if ($command.Contains('-Help') -or $command.Contains('-CancelPath') -or $command.Contains('-MarkerRoot')) {
        Fail 'command passes a parameter the template omits'
    }
    foreach ($baked in @('Chrome', 'Edge', 'Brave', 'Firefox')) {
        if ($command.Contains($baked)) {
            Fail "command bakes $baked"
        }
    }
}
if (-not $install.Contains('-Action Install') -or -not $install.Contains('-DeploymentType Install')) {
    Fail 'install command action'
}
if (-not $uninstall.Contains('-Action Uninstall') -or -not $uninstall.Contains('-DeploymentType Uninstall')) {
    Fail 'uninstall command action'
}

$detectText = Get-Content -LiteralPath $detectPath -Raw -Encoding utf8
foreach ($token in $tokens) {
    if (-not $detectText.Contains($token)) {
        Fail "detection script is missing $token"
    }
}
foreach ($line in @(
        '$script:Browser = ''__BROWSER__''',
        '$script:ExtensionId = ''__EXTENSION_ID__'''
    )) {
    if (-not $detectText.Contains($line)) {
        Fail "detection script is missing $line"
    }
}
foreach ($location in @(
        'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist',
        'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist',
        'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave\ExtensionInstallForcelist',
        'Mozilla Firefox\distribution\policies.json'
    )) {
    if (-not $detectText.Contains($location)) {
        Fail "detection script is missing $location"
    }
}
if ($detectText.Contains('Invoke-BrowserExtension.ps1')) {
    Fail 'detection script dot-sources the installer'
}
if ($detectText -match '(?m)^\s*\.\s+') {
    Fail 'detection script dot-sources a file'
}
if ($detectText.Contains('Get-ItemProperty')) {
    Fail 'detection script calls Get-ItemProperty'
}
if ($detectText.Contains('pwsh')) {
    Fail 'detection script uses pwsh'
}
$guard = "if (`$env:RELIAN_DEPLOY_TEST -eq '1') {`n    return`n}"
if (-not $detectText.Contains($guard)) {
    Fail 'test guard does not return'
}
$guardAt = $detectText.IndexOf($guard, [System.StringComparison]::Ordinal)
$exitAt = $detectText.IndexOf("`nexit ", [System.StringComparison]::Ordinal)
if ($guardAt -lt 0 -or $exitAt -lt 0 -or $exitAt -lt $guardAt) {
    Fail 'detection exits before the test guard'
}
$tail = $detectText.Substring($guardAt)
$tokenAt = $tail.IndexOf('Test-RelianBrowserExtensionTokenLeft', [System.StringComparison]::Ordinal)
$readAt = $tail.IndexOf('Get-RelianBrowserExtensionForcelist', [System.StringComparison]::Ordinal)
$firefoxAt = $tail.IndexOf('Get-RelianBrowserExtensionFirefoxPolicy -Path', [System.StringComparison]::Ordinal)
$successLine = "Write-Output 'Relian __BROWSER__ extension __EXTENSION_ID__'"
$successAt = $tail.IndexOf($successLine, [System.StringComparison]::Ordinal)
if ($tokenAt -lt 0 -or $readAt -lt 0 -or $firefoxAt -lt 0 -or $successAt -lt 0) {
    Fail 'detection path is incomplete'
}
if ($tokenAt -gt $readAt -or $tokenAt -gt $firefoxAt -or $tokenAt -gt $successAt) {
    Fail 'placeholder check is not before detection'
}
if (([regex]::Matches($detectText, 'Write-Output')).Count -ne 1) {
    Fail 'detection script writes more than the success line'
}
$presentAt = $detectText.LastIndexOf('if ($present) {', [System.StringComparison]::Ordinal)
if ($presentAt -lt 0) {
    Fail 'detection success path is missing'
}
$afterPresent = $detectText.Substring($presentAt)
$successExit = $afterPresent.IndexOf('exit 0', [System.StringComparison]::Ordinal)
if ($successExit -lt 0 -or -not $afterPresent.Substring(0, $successExit).Contains($successLine)) {
    Fail 'success line is missing'
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

$testText = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding utf8
$chromiumIdPattern = '[a-p]{32}'
foreach ($committed in @(
        @{ Text = $jsonText; Label = 'intune.json' },
        @{ Text = $detectText; Label = 'Detect-BrowserExtension.ps1' },
        @{ Text = $testText; Label = 'intune-browser-extension.Tests.ps1' }
    )) {
    if ([regex]::IsMatch($committed.Text, $chromiumIdPattern)) {
        Fail "$($committed.Label) contains a chromium extension id"
    }
}
foreach ($packageFile in @(
        @{ Text = $jsonText; Label = 'intune.json' },
        @{ Text = $detectText; Label = 'Detect-BrowserExtension.ps1' }
    )) {
    if ($packageFile.Text.Contains('/home/')) {
        Fail "$($packageFile.Label) contains a home path"
    }
}

$env:RELIAN_DEPLOY_TEST = '1'
$dotOutput = . $detectPath
if ($null -ne $dotOutput) {
    Fail 'detection wrote output while a test is running'
}

foreach ($command in @(
        'Get-RelianBrowserExtensionBrowsers',
        'Get-RelianBrowserExtensionBrowser',
        'Get-RelianBrowserExtensionFirefoxPolicyPath',
        'Test-RelianBrowserExtensionTokenLeft',
        'Test-RelianBrowserExtensionForcelistListed',
        'Test-RelianBrowserExtensionFirefoxForceInstalled',
        'Test-RelianBrowserExtensionInstalled',
        'Get-RelianBrowserExtensionForcelist',
        'Get-RelianBrowserExtensionFirefoxPolicy'
    )) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Fail "$command was not defined"
    }
}

$expectedBrowsers = @(
    @{ Name = 'Chrome'; Kind = 'Chromium'; Policy = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist' }
    @{ Name = 'Edge'; Kind = 'Chromium'; Policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist' }
    @{ Name = 'Brave'; Kind = 'Chromium'; Policy = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave\ExtensionInstallForcelist' }
    @{ Name = 'Firefox'; Kind = 'Firefox'; Policy = 'policies.json' }
)
$catalog = @(Get-RelianBrowserExtensionBrowsers)
if ($catalog.Count -ne 4) {
    Fail 'catalog does not list four browsers'
}
for ($i = 0; $i -lt $expectedBrowsers.Count; $i++) {
    $want = $expectedBrowsers[$i]
    $have = $catalog[$i]
    if ([string]$have.Name -cne [string]$want.Name -or [string]$have.Kind -cne [string]$want.Kind -or [string]$have.Policy -cne [string]$want.Policy) {
        Fail "$($want.Name) catalog entry does not match the installer"
    }
}
$matched = Get-RelianBrowserExtensionBrowser -Name 'chrome'
if ($null -eq $matched -or [string]$matched.Name -cne 'Chrome') {
    Fail 'browser match was not the installer comparison'
}
if ($null -ne (Get-RelianBrowserExtensionBrowser -Name 'Opera')) {
    Fail 'an unknown browser was recognized'
}
$firefoxSuffix = '\Mozilla Firefox\distribution\policies.json'
$firefoxPath = Get-RelianBrowserExtensionFirefoxPolicyPath
if (-not $firefoxPath.EndsWith($firefoxSuffix, [System.StringComparison]::Ordinal)) {
    Fail "firefox policy path '$firefoxPath'"
}

function New-ForcelistValue {
    param([string]$Data)
    return [pscustomobject]@{
        Name = '1'
        Data = $Data
    }
}

function New-DetectFirefoxPolicy {
    param(
        [string]$Id,
        [string]$Mode,
        [string]$InstallUrl = ''
    )
    $entry = [ordered]@{
        installation_mode = $Mode
    }
    if (-not [string]::IsNullOrWhiteSpace($InstallUrl)) {
        $entry['install_url'] = $InstallUrl
    }
    $settings = [ordered]@{}
    $settings[$Id] = $entry
    $document = [ordered]@{
        policies = [ordered]@{
            ExtensionSettings = $settings
        }
    }
    return ($document | ConvertTo-Json -Depth 8 -Compress | ConvertFrom-Json)
}

$extensionId = 'a' * 32
$otherId = 'b' * 32
$firefoxId = 'fx-' + ('c' * 8)
$chromeListed = New-ForcelistValue -Data ($extensionId + ';https://example.invalid/not-required')
$chromeMiss = New-ForcelistValue -Data ('1;' + $extensionId + ';https://example.invalid/crx')
$edgeListed = New-ForcelistValue -Data ($extensionId + ';https://example.invalid/edge')
$braveListed = New-ForcelistValue -Data ($extensionId + ';')
$caseId = 'A' + ('b' * 8)
$caseItem = New-ForcelistValue -Data ('a' + ('b' * 8) + ';https://example.invalid/crx')

if (-not (Test-RelianBrowserExtensionInstalled -Browser 'Chrome' -ExtensionId $extensionId -Forcelist @($chromeListed))) {
    Fail 'Chrome id was not listed'
}
if (-not (Test-RelianBrowserExtensionInstalled -Browser 'chrome' -ExtensionId $extensionId -Forcelist @($chromeListed))) {
    Fail 'browser match was not the installer comparison'
}
$edgeSecond = New-ForcelistValue -Data ($otherId + ';https://example.invalid/other')
if (-not (Test-RelianBrowserExtensionInstalled -Browser 'Edge' -ExtensionId $extensionId -Forcelist @($edgeSecond, $edgeListed))) {
    Fail 'Edge id was not listed'
}
if (-not (Test-RelianBrowserExtensionInstalled -Browser 'Brave' -ExtensionId $extensionId -Forcelist @($braveListed))) {
    Fail 'Brave id was not listed'
}
if (Test-RelianBrowserExtensionInstalled -Browser 'Chrome' -ExtensionId $extensionId -Forcelist @($chromeMiss)) {
    Fail 'a Chrome value that does not start with the id was listed'
}
if (Test-RelianBrowserExtensionInstalled -Browser 'Chrome' -ExtensionId $caseId -Forcelist @($caseItem)) {
    Fail 'forcelist comparison was not ordinal'
}
if (Test-RelianBrowserExtensionInstalled -Browser 'Chrome' -ExtensionId $extensionId -Forcelist @()) {
    Fail 'an empty forcelist was installed'
}

$firefoxListed = New-DetectFirefoxPolicy -Id $firefoxId -Mode 'force_installed'
if (-not (Test-RelianBrowserExtensionInstalled -Browser 'Firefox' -ExtensionId $firefoxId -FirefoxPolicy $firefoxListed)) {
    Fail 'Firefox force_installed was absent'
}
$firefoxUrl = New-DetectFirefoxPolicy -Id $firefoxId -Mode 'force_installed' -InstallUrl 'https://example.invalid/ext'
if (-not (Test-RelianBrowserExtensionInstalled -Browser 'Firefox' -ExtensionId $firefoxId -FirefoxPolicy $firefoxUrl)) {
    Fail 'Firefox install_url was required'
}
$firefoxBlocked = New-DetectFirefoxPolicy -Id $firefoxId -Mode 'blocked' -InstallUrl 'https://example.invalid/ext'
if (Test-RelianBrowserExtensionInstalled -Browser 'Firefox' -ExtensionId $firefoxId -FirefoxPolicy $firefoxBlocked) {
    Fail 'a Firefox entry that is not force_installed was present'
}
$firefoxCase = New-DetectFirefoxPolicy -Id $firefoxId -Mode 'Force_Installed'
if (Test-RelianBrowserExtensionInstalled -Browser 'Firefox' -ExtensionId $firefoxId -FirefoxPolicy $firefoxCase) {
    Fail 'Firefox installation_mode comparison was not case-sensitive'
}
if (Test-RelianBrowserExtensionInstalled -Browser 'Firefox' -ExtensionId $firefoxId -FirefoxPolicy $null) {
    Fail 'a missing Firefox policy was installed'
}
if (Test-RelianBrowserExtensionInstalled -Browser 'Opera' -ExtensionId $extensionId -Forcelist @($chromeListed)) {
    Fail 'an unknown browser was installed'
}

$tokenItem = New-ForcelistValue -Data ('__TOKEN__' + ';https://example.invalid/crx')
if (-not (Test-RelianBrowserExtensionTokenLeft -Value '__TOKEN__')) {
    Fail 'leftover __TOKEN__ was accepted'
}
if (-not (Test-RelianBrowserExtensionTokenLeft -Value '__BROWSER__') -or -not (Test-RelianBrowserExtensionTokenLeft -Value '__EXTENSION_ID__')) {
    Fail 'leftover placeholder was accepted'
}
if (Test-RelianBrowserExtensionTokenLeft -Value $extensionId) {
    Fail 'an extension id looked like a placeholder'
}
if (Test-RelianBrowserExtensionInstalled -Browser 'Chrome' -ExtensionId '__TOKEN__' -Forcelist @($tokenItem)) {
    Fail 'leftover __TOKEN__ was installed'
}

$consumed = @(Get-RelianBrowserExtensionForcelist -PolicyPath 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist' -Found @($chromeListed))
if ($consumed.Count -ne 1) {
    Fail 'one forcelist value was nested'
}
$consumedNames = @($consumed[0].PSObject.Properties.Name)
if ($consumedNames -notcontains 'Data') {
    Fail 'one forcelist value was nested'
}
if (-not (Test-RelianBrowserExtensionInstalled -Browser 'Chrome' -ExtensionId $extensionId -Forcelist $consumed)) {
    Fail 'one forcelist value was nested'
}
$consumedTwo = @(Get-RelianBrowserExtensionForcelist -PolicyPath 'unused' -Found @($edgeSecond, $edgeListed))
if ($consumedTwo.Count -ne 2) {
    Fail 'two forcelist values were nested'
}

$liveThrew = $false
try {
    Get-RelianBrowserExtensionForcelist -PolicyPath 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist' | Out-Null
} catch {
    $liveThrew = $true
}
if (-not $liveThrew) {
    Fail 'forcelist query ran during a test'
}
$policyThrew = $false
try {
    Get-RelianBrowserExtensionFirefoxPolicy -Path $firefoxPath | Out-Null
} catch {
    $policyThrew = $true
}
if (-not $policyThrew) {
    Fail 'policies.json was read during a test'
}

$savedTest = $env:RELIAN_DEPLOY_TEST
$errFile = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-browser-detect-' + [guid]::NewGuid().ToString('n') + '.err')
try {
    Remove-Item Env:\RELIAN_DEPLOY_TEST -ErrorAction SilentlyContinue
    $stdout = & pwsh -NoProfile -File $detectPath 2> $errFile
    $code = $LASTEXITCODE
    $stderr = ''
    if (Test-Path -LiteralPath $errFile) {
        $stderr = [System.IO.File]::ReadAllText($errFile)
    }
    if ($code -ne 1) {
        Fail "leftover placeholder exited $code"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$stdout) -or -not [string]::IsNullOrWhiteSpace($stderr)) {
        Fail 'leftover placeholder wrote output'
    }
} finally {
    if ([string]::IsNullOrEmpty($savedTest)) {
        Remove-Item Env:\RELIAN_DEPLOY_TEST -ErrorAction SilentlyContinue
    } else {
        $env:RELIAN_DEPLOY_TEST = $savedTest
    }
    if (Test-Path -LiteralPath $errFile) {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}
