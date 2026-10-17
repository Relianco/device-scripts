$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'packages/teams/Invoke-Teams.ps1'
$recordPath = Join-Path $repoRoot 'releases/teams.json'

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Fail 'Invoke-Teams.ps1 does not exist'
}

$source = [System.IO.File]::ReadAllText($scriptPath)
if ($source -match '\[Parameter\(Mandatory') {
    Fail 'a parameter is Mandatory'
}
foreach ($banned in @('disableAutoUpdate', 'MsRdcWebRTCSvc', 'Reset-AppxPackage', 'Ninja-Property-', 'relian_git_deploy_token')) {
    if ($source.Contains($banned)) {
        Fail "source contains $banned"
    }
}

$record = Get-Content -LiteralPath $recordPath -Raw -Encoding utf8 | ConvertFrom-Json
$base = [string]$record.blobBase
if (-not $base.EndsWith('/')) { $base += '/' }
$bootUrl = $base + ('teamsbootstrapper-' + [string]$record.bootstrapperSha256 + '.exe')
$msixUrl = $base + ('MSTeams-x64-' + [string]$record.msixSha256 + '.msix')
foreach ($needle in @(
        $bootUrl,
        $msixUrl,
        [string]$record.bootstrapperSha256,
        [string]$record.msixSha256,
        'BootstrapperUrl',
        'BootstrapperSha256',
        'MsixUrl',
        'MsixSha256'
    )) {
    if (-not $source.Contains($needle)) {
        Fail "source missing $needle"
    }
}

function Assert-Before {
    param([string]$Earlier, [string]$Later, [string]$Label)
    $left = $source.IndexOf($Earlier, [System.StringComparison]::Ordinal)
    $right = $source.IndexOf($Later, [System.StringComparison]::Ordinal)
    if ($left -lt 0 -or $right -lt 0 -or $left -gt $right) {
        Fail $Label
    }
}

$guardNeedle = "if (`$env:RELIAN_DEPLOY_TEST -eq '1' -and `$MyInvocation.InvocationName -eq '.')"
Assert-Before -Earlier $guardNeedle -Later 'Import-Module' -Label 'module import is not behind the dot-source guard'
Assert-Before -Earlier 'Test-TeamsDeferralBlock' -Later 'Open-ADTSession @adtSession' -Label 'deferral block is not before Open-ADTSession'
Assert-Before -Earlier 'Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession' -Later 'Open-ADTSession @adtSession' -Label 'empty session values are not removed before Open-ADTSession'
Assert-Before -Earlier 'SetOptimizationKey' -Later 'StartBootstrapper' -Label 'optimization does not run before the bootstrapper'
Assert-Before -Earlier 'StartBootstrapper' -Later 'ReregisterTeams' -Label 'bootstrapper does not run before re-register'
Assert-Before -Earlier 'ReregisterTeams' -Later 'RemoveClassicTeams' -Label 're-register does not run before classic removal'
Assert-Before -Earlier '1602' -Later 'marker.txt' -Label '1602 is not handled before the marker write'

foreach ($needle in @(
        'PSBoundParameters.ContainsKey',
        'DeploymentType',
        'Get-TeamsCloseList',
        '-AllowDefer -DeferTimes 1',
        'Get-TeamsNotice',
        'IsWVDEnvironment',
        'Get-TeamsPlan'
    )) {
    if (-not $source.Contains($needle)) {
        Fail "source missing $needle"
    }
}
$planCalls = ([regex]::Matches($source, 'Get-TeamsPlan')).Count
if ($planCalls -lt 2) {
    Fail "Get-TeamsPlan appears $planCalls times"
}
if ($source.IndexOf('exit 1', [System.StringComparison]::Ordinal) -lt 0) {
    Fail 'source does not exit 1'
}

$env:RELIAN_DEPLOY_TEST = '1'
. $scriptPath

foreach ($name in @('Test-TeamsDeferralBlock', 'Get-TeamsCloseList', 'Get-TeamsNotice')) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Fail "$name was not defined"
    }
}

if (-not (Test-TeamsDeferralBlock -SessionStates @('Disc') -CloseProcessRunning $true -DeferralAlreadyUsed $false)) {
    Fail 'disconnected session with Teams running did not block'
}
if (Test-TeamsDeferralBlock -SessionStates @('Active') -CloseProcessRunning $true -DeferralAlreadyUsed $false) {
    Fail 'an active session was blocked'
}
if (Test-TeamsDeferralBlock -SessionStates @('Disc') -CloseProcessRunning $false -DeferralAlreadyUsed $false) {
    Fail 'a disconnected session with nothing to close was blocked'
}
if (Test-TeamsDeferralBlock -SessionStates @('Disc') -CloseProcessRunning $true -DeferralAlreadyUsed $true) {
    Fail 'a used deferral blocked again'
}
if (Test-TeamsDeferralBlock -SessionStates @('Disc', 'Active') -CloseProcessRunning $true -DeferralAlreadyUsed $false) {
    Fail 'a mixed session was blocked'
}

$close = @(Get-TeamsCloseList -RunningNames @('OUTLOOK', 'notepad', 'ms-teams', 'Teams'))
$expectedClose = @('ms-teams', 'Teams', 'OUTLOOK')
if ($close.Count -ne 3 -or ($close -join ',') -cne ($expectedClose -join ',')) {
    Fail "close list '$($close -join ',')'"
}
$none = @(Get-TeamsCloseList -RunningNames @('notepad'))
if ($none.Count -ne 0) {
    Fail 'an unrelated process was closed'
}

$installNotice = 'Teams will close for an update. You can wait once. The next run will close it and continue.'
$repairNotice = 'Teams will close for a repair. You can wait once. The next run will close it and continue.'
$uninstallNotice = 'Teams will close. You can wait once. The next run will close it and continue. This removes the Teams sign-in on this PC.'
if ((Get-TeamsNotice -Action 'Install') -cne $installNotice) { Fail 'install notice' }
if ((Get-TeamsNotice -Action 'Update') -cne $installNotice) { Fail 'update notice' }
if ((Get-TeamsNotice -Action 'Repair') -cne $repairNotice) { Fail 'repair notice' }
if ((Get-TeamsNotice -Action 'Uninstall') -cne $uninstallNotice) { Fail 'uninstall notice' }

if (Get-Module -Name PSAppDeployToolkit -ErrorAction SilentlyContinue) {
    Fail 'dot-source imported PSAppDeployToolkit'
}

Write-Output 'teams-session tests passed'
exit 0
