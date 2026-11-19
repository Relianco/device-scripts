$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/app-cleanup/Invoke-AppCleanup.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

# Get-AcMode
Assert-Same (Get-AcMode -Action 'Install' -Fix '' -Target 'all') 'check' 'default is check'
Assert-Same (Get-AcMode -Action 'Install' -Fix 'true' -Target 'firefox') 'fix' 'fix'
Assert-Same (Get-AcMode -Action 'Uninstall' -Fix 'true' -Target 'all') 'none' 'uninstall changes nothing'
Assert-Same (Get-AcMode -Action 'Install' -Fix 'true' -Target 'all' -PinVersion '') 'none' 'empty pin is off'
foreach ($bad in @(@('Install', 'yes', 'all'), @('Install', '', 'edge'), @('Bogus', '', 'all'))) {
    $threw = $false
    try { Get-AcMode -Action $bad[0] -Fix $bad[1] -Target $bad[2] | Out-Null } catch { $threw = $true }
    if (-not $threw) { Fail "bad input $($bad -join '/') did not throw" }
}

# Get-AcFirefoxPlan
function New-Inst { param($Id, $Ver, $Scope = 'machine', $User = '', $Path = '') [pscustomobject]@{ Id = $Id; Version = $Ver; Scope = $Scope; User = $User; Path = $(if ($Path) { $Path } else { "c:\$Id\firefox.exe" }) } }
function Plan { param($Installs, $Idle = @{}, $Running = @()) @(Get-AcFirefoxPlan -Installs $Installs -IdleByUser $Idle -RunningPaths $Running -CurrentMajor 150 -IdleDays 90) }

$p = Plan @((New-Inst 'a' '158.0'))
Assert-Same $p[0].Action 'keep' 'current copy kept'

$p = Plan @((New-Inst 'a' '134.0'), (New-Inst 'b' '158.0' 'user' 'u1'))
Assert-Same $p[0].Action 'remove' 'old copy beside current is removed'
Assert-Same $p[1].Action 'keep' 'current beside old is kept'

$p = Plan @((New-Inst 'a' '72.0.1')) @{ u1 = 200 }
Assert-Same $p[0].Action 'remove' 'machine copy idle 200 days is removed'
$p = Plan @((New-Inst 'a' '72.0.1')) @{ u1 = 200; u2 = 5 }
Assert-Same $p[0].Action 'upgrade' 'machine copy used by one of two users is upgraded, not removed'
$p = Plan @((New-Inst 'a' '72.0.1')) @{}
Assert-Same $p[0].Action 'remove' 'no profile at all counts as unused'
$p = Plan @((New-Inst 'a' '72.0.1' 'user' 'u1')) @{ u1 = 89; u2 = 300 }
Assert-Same $p[0].Action 'upgrade' 'per-user copy looks at its own user only (89 days is in use)'
$p = Plan @((New-Inst 'a' '72.0.1' 'user' 'u1')) @{ u1 = 90 }
Assert-Same $p[0].Action 'remove' '90 days is unused'
$p = Plan @((New-Inst 'a' '72.0.1' 'user' 'u1' 'C:\Users\u1\x\Firefox.exe')) @{ u1 = 900 } @('c:\users\u1\x\firefox.exe')
Assert-Same $p[0].Action 'skip-running' 'running copy is never removed'
$p = Plan @((New-Inst 'a' '')) @{ u1 = 900 }
Assert-Same $p[0].Action 'remove' 'unparseable version is treated as old'

# Teams: nothing present, check mode touches nothing.
$script:calls = New-Object System.Collections.Generic.List[string]
function Get-AcRunning { @() }
function Get-AcUserDirs { @() }
function Invoke-AcProcess { param($File, $Arguments) $script:calls.Add("$File $Arguments"); 0 }
$r = Invoke-AcTeams -Fix $true
Assert-Same $r.failed 0 'empty teams fix has no failures'
Assert-Same $script:calls.Count 0 'no installer called when nothing is present'

# Teams: a user copy that is running is skipped; a stopped one is uninstalled.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-ac-' + [guid]::NewGuid().ToString('n'))
foreach ($u in 'busy', 'idle') {
    $d = Join-Path $tmp "$u\AppData\Local\Microsoft\Teams"
    [void](New-Item -ItemType Directory -Path $d -Force)
    Set-Content -LiteralPath (Join-Path $d 'Update.exe') -Value 'x'
}
try {
    function Get-AcUserDirs { @(Get-ChildItem -LiteralPath $tmp -Directory) }
    $busyDir = Join-Path $tmp 'busy\AppData\Local\Microsoft\Teams'
    function Get-AcRunning { @([pscustomobject]@{ Name = 'Teams.exe'; Path = (Join-Path $busyDir 'current\Teams.exe') }) }
    $r = Invoke-AcTeams -Fix $true
    Assert-Same @($r.items).Count 2 'two user copies found'
    Assert-Same (@($r.items | Where-Object { $_.id -eq 'busy' })[0].action) 'skip-running' 'running user copy skipped'
    Assert-Same $script:calls.Count 1 'only the idle copy was uninstalled'
    if ($script:calls[0] -notlike '*idle*Update.exe --uninstall -s') { Fail "uninstall call was [$($script:calls[0])]" }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force
}

Write-Host 'PASS app-cleanup'
