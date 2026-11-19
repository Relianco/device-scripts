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

$p = Plan @((New-Inst 'a' '134.0'), (New-Inst 'b' '158.0'))
Assert-Same $p[0].Action 'remove' 'old copy beside current is removed'
Assert-Same $p[1].Action 'keep' 'current beside old is kept'
# A current copy of one user does not replace another user's old copy, nor a machine-wide old copy.
$p = Plan @((New-Inst 'a' '134.0' 'user' 'u1'), (New-Inst 'b' '158.0' 'user' 'u2')) @{ u1 = 1; u2 = 1 }
Assert-Same $p[0].Action 'upgrade' 'another user current copy does not replace this user old copy'
$p = Plan @((New-Inst 'a' '134.0'), (New-Inst 'b' '158.0' 'user' 'u2')) @{ u1 = 1 }
Assert-Same $p[0].Action 'upgrade' 'a per-user current copy does not replace a machine-wide old copy'
$p = Plan @((New-Inst 'a' '134.0' 'user' 'u1'), (New-Inst 'b' '158.0' 'user' 'u1')) @{ u1 = 1 }
Assert-Same $p[0].Action 'remove' 'same user current copy replaces this user old copy'
$p = Plan @((New-Inst 'a' '134.0' 'user' 'u1'), (New-Inst 'b' '158.0')) @{ u1 = 1 }
Assert-Same $p[0].Action 'remove' 'machine-wide current copy replaces a per-user old copy'

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
$fx = Join-Path ([System.IO.Path]::GetTempPath()) 'relian-ac-fx\Firefox.exe'
$p = Plan @((New-Inst 'a' '72.0.1' 'user' 'u1' $fx)) @{ u1 = 900 } @($fx.ToLowerInvariant())
Assert-Same $p[0].Action 'skip-running' 'running copy is never removed'
$p = Plan @((New-Inst 'a' '')) @{ u1 = 900 }
Assert-Same $p[0].Action 'remove' 'unparseable version is treated as old'

# Several installs: the inventory and the plan are flat arrays with one element per copy (a nested array would
# make the planner act on aggregated properties).
$ftmp = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-acf-' + [guid]::NewGuid().ToString('n'))
try {
    foreach ($u in 'ua', 'ub') {
        $d = Join-Path $ftmp "$u\AppData\Local\Mozilla Firefox"
        [void](New-Item -ItemType Directory -Path $d -Force)
        Set-Content -LiteralPath (Join-Path $d 'firefox.exe') -Value 'x'
    }
    function Get-AcUserDirs { @(Get-ChildItem -LiteralPath $ftmp -Directory) }
    function Get-AcMachineKeys { [pscustomobject]@{ Key = 'k1'; Name = 'Mozilla Firefox 72'; Version = '72.0.1'; Uninstall = ''; Location = (Join-Path $ftmp 'ua\AppData\Local\Mozilla Firefox') } }
    function Get-AcFileVersion { param([string]$Path) if ($Path -like '*ub*') { return '158.0' } return '72.0.1' }
    $inv = @(Get-AcFirefoxInventory)
    # ua's exe is listed by its machine key and as a user path: counted once. ub is separate.
    Assert-Same $inv.Count 2 'inventory has one element per distinct copy'
    Assert-Same $inv[0].Version '72.0.1' 'first copy version is a scalar'
    Assert-Same $inv[1].Version '158.0' 'second copy version is a scalar'
    $pl = @(Get-AcFirefoxPlan -Installs $inv -IdleByUser @{ ua = 1; ub = 1 } -RunningPaths @() -CurrentMajor 150 -IdleDays 90)
    Assert-Same $pl.Count 2 'plan has one element per copy'
    Assert-Same $pl[0].Action 'upgrade' 'old machine copy is not replaced by a per-user current copy'
    Assert-Same $pl[1].Action 'keep' 'current copy is kept'
} finally {
    Remove-Item -LiteralPath $ftmp -Recurse -Force
}

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
    Assert-Same $script:calls.Count 0 'no user-writable file is executed'
    if (-not (Test-Path -LiteralPath (Join-Path $tmp 'busy'))) { Fail 'running copy was deleted' }
    if (Test-Path -LiteralPath (Join-Path $tmp 'idle\AppData\Local\Microsoft\Teams')) { Fail 'idle copy was not deleted' }
    Assert-Same $r.failed 0 'verified removal has no failures'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force
}

# Remove-AcUserDir refuses a reparse-point ancestor (here a symlink standing in for a junction) and a dir outside the root.
$rt = Join-Path ([System.IO.Path]::GetTempPath()) ('relian-acr-' + [guid]::NewGuid().ToString('n'))
try {
    $outside = Join-Path $rt 'outside\victim'; $prof = Join-Path $rt 'prof'
    [void](New-Item -ItemType Directory -Path $outside -Force); [void](New-Item -ItemType Directory -Path $prof -Force)
    Set-Content -LiteralPath (Join-Path $outside 'f.txt') -Value 'x'
    [void](New-Item -ItemType SymbolicLink -Path (Join-Path $prof 'link') -Target (Join-Path $rt 'outside'))
    Assert-Same (Remove-AcUserDir -Dir (Join-Path $prof 'link\victim') -Root $prof) 2 'reparse ancestor refused'
    if (-not (Test-Path -LiteralPath (Join-Path $outside 'f.txt'))) { Fail 'file outside the profile was deleted' }
    Assert-Same (Remove-AcUserDir -Dir $outside -Root $prof) 2 'dir outside the root refused'
    $ok = Join-Path $prof 'plain'; [void](New-Item -ItemType Directory -Path $ok)
    Assert-Same (Remove-AcUserDir -Dir $ok -Root $prof) 0 'plain dir under the root is removed'
} finally { Remove-Item -LiteralPath $rt -Recurse -Force }

Write-Host 'PASS app-cleanup'
