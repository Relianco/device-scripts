$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/wdot/Invoke-Wdot.ps1'
$profileDir = Join-Path $repoRoot 'windows/packages/wdot/profile'
$releasePath = Join-Path $repoRoot 'windows/releases/wdot.json'

function Fail {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'test failed'
    }
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Read-Profile {
    param([string]$Name)
    $path = Join-Path $profileDir $Name
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "missing profile file $Name"
    }
    return @(Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json)
}

function Get-Applied {
    param($Items)
    return @($Items | Where-Object { [string]$_.OptimizationState -eq 'Apply' })
}

foreach ($path in @($scriptPath, $releasePath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "$path does not exist"
    }
}

# Every file WDOT reads from a profile folder is present.
foreach ($name in @(
        'AppxPackages.json', 'AppxPackages-KeepOutlook.json', 'Autologgers.Json', 'DefaultUserSettings.json',
        'EdgeSettings.json', 'LanManWorkstation.json', 'PolicyRegSettings.json', 'ScheduledTasks.json', 'Services.json'
    )) {
    [void](Read-Profile -Name $name)
}

# The appraiser tasks feed Windows Update its upgrade-compatibility data.
# Disabling them stops feature-update offers. WDOT passes each name to
# Get-ScheduledTask -TaskName, which takes wildcards, so match the same way.
$appraiserTasks = @('Microsoft Compatibility Appraiser', 'Microsoft Compatibility Appraiser Exp')
foreach ($task in (Get-Applied (Read-Profile -Name 'ScheduledTasks.json'))) {
    $name = [string]$task.ScheduledTask
    foreach ($appraiser in $appraiserTasks) {
        if ($appraiser -like $name) {
            Fail "ScheduledTasks.json disables $appraiser through entry [$name]"
        }
    }
    if ($name -like '*Appraiser*' -or $name -like '*Compatibility*') {
        Fail "ScheduledTasks.json disables [$name]"
    }
}

# Services Windows Update needs to scan, download, and install feature updates.
$updateServices = @('wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'BITS', 'DoSvc', 'TrustedInstaller', 'CryptSvc', 'msiserver')
$services = Read-Profile -Name 'Services.json'
foreach ($service in (Get-Applied $services)) {
    if ($updateServices -contains [string]$service.Name) {
        Fail "Services.json disables $($service.Name)"
    }
}
# DiagTrack stays disabled. That is the owner's choice.
if (@(Get-Applied $services | Where-Object { [string]$_.Name -eq 'DiagTrack' }).Count -ne 1) {
    Fail 'Services.json no longer disables DiagTrack'
}

# WDOT 1.1 renamed some value names from Enabled to Apply. Those write a value nothing reads.
foreach ($setting in (Read-Profile -Name 'PolicyRegSettings.json')) {
    if ([string]$setting.RegItemValueName -eq 'Apply') {
        Fail "PolicyRegSettings.json writes a value named Apply under $($setting.RegItemPath)"
    }
}

# Remove-WDOTAppxPackage matches *<name>* against PackageName. A space never matches.
$default = Read-Profile -Name 'AppxPackages.json'
$keep = Read-Profile -Name 'AppxPackages-KeepOutlook.json'
foreach ($item in @($default) + @($keep)) {
    if ([string]$item.AppxPackage -match '\s') {
        Fail "AppxPackage name [$($item.AppxPackage)] has whitespace"
    }
}
$outlookApps = @('Microsoft.OutlookForWindows', 'microsoft.windowscommunicationsapps')
$defaultApplied = @((Get-Applied $default).AppxPackage)
$keepApplied = @((Get-Applied $keep).AppxPackage)
foreach ($app in $outlookApps) {
    if ($defaultApplied -notcontains $app) {
        Fail "AppxPackages.json no longer removes $app"
    }
    if ($keepApplied -contains $app) {
        Fail "AppxPackages-KeepOutlook.json removes $app"
    }
}
$extra = @(Compare-Object -ReferenceObject $defaultApplied -DifferenceObject ($keepApplied + $outlookApps))
if ($extra.Count -ne 0) {
    Fail 'the two AppxPackages files differ in more than the Outlook apps'
}
foreach ($app in @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.OneDriveSync', 'Microsoft.WindowsCalculator')) {
    if ($defaultApplied -contains $app) {
        Fail "AppxPackages.json removes $app"
    }
}

# Pin record and inlined defaults agree.
$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$release.commit -notmatch '^[0-9a-f]{40}$') {
    Fail 'release commit is not a full SHA'
}
if ($ZipUrl -cne [string]$release.sourceUrl -or $ZipSha256 -cne [string]$release.sha256) {
    Fail 'script defaults do not match windows/releases/wdot.json'
}
if (-not (Test-WdotSha256Shape -Value $ZipSha256)) {
    Fail 'pinned hash is not a SHA256'
}
if (-not $ZipUrl.EndsWith('/' + [string]$release.file) -or -not ([string]$release.file).Contains($ZipSha256)) {
    Fail 'the blob name is not content-addressed by the pinned hash'
}
if (-not (Test-WdotUrl -Url $ZipUrl)) {
    Fail 'pinned URL refused'
}

# URL and hash checks.
foreach ($bad in @('http://example.com/a.zip', 'https://user@example.com/a.zip', 'not a url', '')) {
    if (Test-WdotUrl -Url $bad) {
        Fail "URL accepted: [$bad]"
    }
}
foreach ($bad in @('', 'PENDING', ('0' * 63), ('g' * 64))) {
    if (Test-WdotSha256Shape -Value $bad) {
        Fail "hash shape accepted: [$bad]"
    }
}

# Keep Outlook checkbox.
foreach ($case in @(@('true', $true), @('True', $true), @(' true ', $true), @('false', $false), @('', $false), @('1', $false))) {
    if ((Test-WdotKeepOutlook -KeepOutlook $case[0]) -ne $case[1]) {
        Fail "KeepOutlook [$($case[0])] was not $($case[1])"
    }
}

# WDOT invocation.
$argLine = (Get-WdotArgument -ScriptPath 'C:\w\Windows_Optimization.ps1') -join ' '
foreach ($needle in @('-File C:\w\Windows_Optimization.ps1', '-ConfigProfile Relian', '-Optimizations All', '-AcceptEULA', '-NonInteractive')) {
    if (-not $argLine.Contains($needle)) {
        Fail "WDOT arguments miss $needle"
    }
}
if ($argLine.Contains('-Restart')) {
    Fail 'WDOT arguments restart the device'
}

# The script turns the appraiser tasks back on after WDOT.
if ((@($script:AppraiserTasks) -join '|') -cne ($appraiserTasks -join '|')) {
    Fail 'script does not re-enable both appraiser tasks'
}
if ($script:AppraiserTaskPath -cne '\Microsoft\Windows\Application Experience\') {
    Fail 'appraiser task path'
}

# A hash mismatch returns 1 and expands nothing. The download is stubbed.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('wdot-test-' + [guid]::NewGuid().ToString('n'))
[void](New-Item -ItemType Directory -Path $work)
$script:expanded = $false
$script:ranChild = $false
function New-WdotWorkFolder { return $work }
function Invoke-WebRequest {
    param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
    [System.IO.File]::WriteAllText($OutFile, 'not the pinned zip')
}
function Expand-Archive {
    param([string]$LiteralPath, [string]$DestinationPath)
    $script:expanded = $true
}
function Invoke-WdotChild {
    param([string[]]$Argument)
    $script:ranChild = $true
    return 0
}
$result = Invoke-Wdot -ZipUrl $ZipUrl -ZipSha256 $ZipSha256 -KeepOutlook 'false'
if ($result -ne 1 -or $script:expanded -or $script:ranChild) {
    Fail "hash mismatch returned [$result], expanded [$($script:expanded)], ran WDOT [$($script:ranChild)]"
}
if (Test-Path -LiteralPath $work) {
    Fail 'work folder left behind after a mismatch'
}

# Refused input never downloads.
$script:downloaded = $false
function Invoke-WebRequest {
    param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
    $script:downloaded = $true
}
if ((Invoke-Wdot -ZipUrl $ZipUrl -ZipSha256 'PENDING' -KeepOutlook '') -ne 1 -or
    (Invoke-Wdot -ZipUrl 'http://example.com/a.zip' -ZipSha256 $ZipSha256 -KeepOutlook '') -ne 1 -or
    $script:downloaded) {
    Fail 'refused input downloaded or did not return 1'
}

Write-Output 'PASS wdot'
exit 0
