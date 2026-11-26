# printer-defaults job. Printers, print jobs and the registry are fakes behind the module's seams.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'windows/jobs/printer-defaults.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ("$Actual" -ne "$Expected") { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
. $modulePath

# A DEVMODEW public part: dmFields at 72, dmColor at 92, dmDuplex at 94. 0 leaves the field unset.
function New-DevMode {
    param([int]$Color, [int]$Duplex)
    $b = New-Object byte[] 220
    $fields = [uint32]0
    if ($Color) { $fields = $fields -bor 0x800; [Array]::Copy([BitConverter]::GetBytes([int16]$Color), 0, $b, 92, 2) }
    if ($Duplex) { $fields = $fields -bor 0x1000; [Array]::Copy([BitConverter]::GetBytes([int16]$Duplex), 0, $b, 94, 2) }
    [Array]::Copy([BitConverter]::GetBytes($fields), 0, $b, 72, 4)
    return , $b
}

# --- which printers are left alone
foreach ($p in @(
        @('Adobe PDF', 'Adobe PDF Converter'), @('Microsoft Print to PDF', 'Microsoft Print To PDF'),
        @('OneNote (Desktop)', 'Send to Microsoft OneNote 16 Driver'), @('Fax', 'Microsoft Shared Fax Driver'),
        @('Microsoft XPS Document Writer', 'Microsoft XPS Document Writer v4'),
        @('TOSHIBA e-STUDIO3505AC-11780774', 'TOSHIBA e-STUDIO Fax'), @('Splashtop PDF Remote Printer', 'Microsoft Print To PDF'),
        @('PaperPort Image Printer', 'Nuance Image Printer Driver'), @('Xerox AltaLink C8055 (9C:93:4E:99:75:7C) (Fax)', ''))) {
    Assert-True (Test-PdSkipPrinter -Name $p[0] -Driver $p[1]) "skip $($p[0])"
}
foreach ($p in @(@('Convey', 'TOSHIBA Universal Printer 2'), @('CX3535 MFP(PCL)', 'CX3535 MFP(PCL)'), @('\\svfs\TOSHIBA Universal PS3', ''))) {
    Assert-True (-not (Test-PdSkipPrinter -Name $p[0] -Driver $p[1])) "keep $($p[0])"
}

# --- a saved per-user DEVMODE is fine only when it says monochrome and not two-sided
Assert-True (Test-PdUserDevModeOk (New-DevMode 1 1)) 'mono simplex ok'
Assert-True (Test-PdUserDevModeOk (New-DevMode 1 0)) 'mono, duplex unset ok'
Assert-True (-not (Test-PdUserDevModeOk (New-DevMode 2 1))) 'colour not ok'
Assert-True (-not (Test-PdUserDevModeOk (New-DevMode 0 1))) 'colour unset not ok'
Assert-True (-not (Test-PdUserDevModeOk (New-DevMode 1 2))) 'long-edge not ok'
Assert-True (-not (Test-PdUserDevModeOk (New-DevMode 1 3))) 'short-edge not ok'
Assert-True (-not (Test-PdUserDevModeOk ([byte[]]@(1, 2, 3)))) 'a short buffer is not ok'

# --- fake machine
function Reset-Test {
    param($Printers = @(), $Jobs = @{}, $Loaded = @(), $Profiles = @(), $Values = @{}, $InUse = @(), [switch]$SetIgnored, [switch]$DevModeFixes, [switch]$UnloadFails, $ReadThrows = '')
    $script:F = @{ Config = @{}; Driver = @{}; Jobs = $Jobs; Loaded = [Collections.Generic.List[string]]::new(); Profiles = $Profiles
        Values = $Values; InUse = $InUse; SetIgnored = [bool]$SetIgnored; DevModeFixes = [bool]$DevModeFixes; UnloadFails = [bool]$UnloadFails; ReadThrows = $ReadThrows }
    foreach ($p in $Printers) { $script:F.Config[$p[0]] = @{ Color = $p[2]; Duplex = $p[3] }; $script:F.Driver[$p[0]] = $p[1] }
    foreach ($s in $Loaded) { $script:F.Loaded.Add($s) }
    $script:Log = [Collections.Generic.List[string]]::new()
}
$script:PdGetPrinters = { @($script:F.Driver.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Name = $_; Driver = $script:F.Driver[$_] } }) }
$script:PdGetConfig = { param($Name) [pscustomobject]$script:F.Config[$Name] }
$script:PdSetConfig = { param($Name, $Color, $Duplex)
    $script:Log.Add("set $Name color=$Color duplex=$Duplex")
    if (-not $script:F.SetIgnored) {
        if ($null -ne $Color) { $script:F.Config[$Name].Color = $Color }
        if ($null -ne $Duplex) { $script:F.Config[$Name].Duplex = $Duplex }
    }
}
$script:PdSetDevMode = { param($Name)
    $script:Log.Add("devmode $Name")
    if ($script:F.DevModeFixes) { $script:F.Config[$Name] = @{ Color = $false; Duplex = 'OneSided' } }
}
$script:PdJobCount = { param($Name) if ($script:F.Jobs.ContainsKey($Name)) { $script:F.Jobs[$Name] } else { 0 } }
$script:PdHiveNames = { @($script:F.Loaded) }
$script:PdProfiles = { @($script:F.Profiles | ForEach-Object { [pscustomobject]@{ Sid = $_; Path = "C:\Users\$_" } }) }
$script:PdLoadHive = { param($Mount, $File)
    $sid = $Mount.Substring('RelianPD_'.Length)
    if ($script:F.InUse -contains $sid) { return $false }
    $script:Log.Add("load $Mount"); $script:F.Loaded.Add($Mount); return $true
}
$script:PdUnloadHive = { param($Mount)
    $script:Log.Add("unload $Mount")
    if ($script:F.UnloadFails) { return $false }
    [void]$script:F.Loaded.Remove($Mount); return $true
}
$script:PdReadUserValues = { param($Root)
    $sid = $Root -replace '^RelianPD_', ''
    if ($script:F.ReadThrows -eq $sid) { throw 'read failed' }
    @(if ($script:F.Values.ContainsKey($sid)) { $script:F.Values[$sid] | ForEach-Object { [pscustomobject]@{ Key = $_[0]; Name = $_[1]; Bytes = [byte[]]$_[2] } } })
}
$script:PdDeleteUserValue = { param($Root, $Key, $Name) $script:Log.Add("delete $Root $Key $Name") }

function Lines { param($Pattern) @($script:Log | Where-Object { $_ -like $Pattern }) }
function Entry { param($Result, $Name) @($Result.Printers | Where-Object { $_.name -eq $Name })[0] }

$machine = @(@('Convey', 'TOSHIBA Universal Printer 2', $true, 'TwoSidedLongEdge'), @('Copy Room', 'TOSHIBA Universal Printer 2', $false, 'OneSided'),
    @('Adobe PDF', 'Adobe PDF Converter', $true, 'OneSided'), @('Konica', 'KONICA MINOLTA Universal PCL', $false, 'TwoSidedLongEdge'),
    @('TOSHIBA e-STUDIO3505AC-1', 'TOSHIBA e-STUDIO Fax', $true, 'TwoSidedLongEdge'))

# Run: only the drifted printers are set, each to exactly the setting it lacks; PDF and fax queues untouched.
Reset-Test -Printers $machine
$r = Invoke-PdJob
Assert-Same $r.ExitCode 0 'run exit'
Assert-Same $r.Status 'changed' 'run status'
Assert-Same ((Lines 'set *') -join ';') 'set Convey color=False duplex=OneSided;set Konica color= duplex=OneSided' 'set calls'
Assert-Same @(Lines 'devmode *').Count 0 'no DEVMODE fallback when Set-PrintConfiguration took'
Assert-Same (Entry $r 'Convey').status 'changed' 'Convey status'
Assert-Same (Entry $r 'Convey').before 'color/TwoSidedLongEdge' 'Convey before'
Assert-Same (Entry $r 'Convey').after 'mono/OneSided' 'Convey after'
Assert-Same (Entry $r 'Copy Room').status 'unchanged' 'Copy Room status'
Assert-Same (Entry $r 'Adobe PDF').status 'skipped' 'PDF skipped'
Assert-Same (Entry $r 'TOSHIBA e-STUDIO3505AC-1').status 'skipped' 'fax driver skipped'

# Second run: nothing to do.
$r = Invoke-PdJob
Assert-Same $r.Status 'compliant' 'idempotent status'
Assert-Same $r.ExitCode 0 'idempotent exit'
Assert-Same @(Lines 'set *').Count 2 'no new set calls on the second run'

# ReportOnly: changes nothing and reports drift.
Reset-Test -Printers $machine -Loaded @('S-1-5-21-1-2-3-1001') -Values @{ 'S-1-5-21-1-2-3-1001' = @(, @('DevModePerUser', 'Convey', (New-DevMode 2 1))) }
$r = Invoke-PdJob -ReportOnly
Assert-Same $r.Status 'drift' 'report status'
Assert-Same $r.ExitCode 1 'report exit'
Assert-Same @(Lines 'set *').Count 0 'report sets nothing'
Assert-Same @(Lines 'delete *').Count 0 'report deletes nothing'
Assert-Same (Entry $r 'Convey').status 'drift' 'report printer status'
Assert-Same $r.Users[0].drift 'DevModePerUser\Convey' 'report names the user value'

# A printer with a job in its queue is not touched; the run says busy so it is retried.
Reset-Test -Printers $machine -Jobs @{ 'Convey' = 1 }
$r = Invoke-PdJob
Assert-Same (Entry $r 'Convey').status 'busy' 'busy printer status'
Assert-Same @(Lines 'set Convey*').Count 0 'busy printer untouched'
Assert-Same @(Lines 'set Konica*').Count 1 'the other printer is still done'
Assert-Same $r.Status 'busy' 'overall busy'
Assert-Same $r.ExitCode 1 'busy exit'

# A driver that ignores Set-PrintConfiguration gets the DEVMODE write.
Reset-Test -Printers $machine -SetIgnored -DevModeFixes
$r = Invoke-PdJob
Assert-Same ((Lines 'devmode *') -join ';') 'devmode Convey;devmode Konica' 'DEVMODE fallback'
Assert-Same (Entry $r 'Convey').status 'changed' 'fallback status'
Assert-Same $r.ExitCode 0 'fallback exit'

# Neither works: failed, exit 2.
Reset-Test -Printers $machine -SetIgnored
$r = Invoke-PdJob
Assert-Same (Entry $r 'Convey').status 'failed' 'still colour after both writes'
Assert-Same $r.Status 'failed' 'overall failed'
Assert-Same $r.ExitCode 2 'failed exit'

# Users: signed-in hive in place; signed-out hive loaded, fixed and unloaded; an in-use hive is skipped.
$a = 'S-1-5-21-1-2-3-1001'; $b = 'S-1-12-1-4-5-6-7'; $c = 'S-1-5-21-1-2-3-1003'
Reset-Test -Printers $machine -Loaded @($a, "$($a)_Classes", '.DEFAULT', 'S-1-5-18') -Profiles @($a, $b, $c) -InUse @($c) -Values @{
    $a = @(@('DevModePerUser', 'Convey', (New-DevMode 2 1)), @('DevModePerUser', 'Microsoft Print to PDF', (New-DevMode 2 1)),
        @('DevModes2', 'Copy Room', (New-DevMode 1 1)), @('DevModePerUser', 'TOSHIBA e-STUDIO3505AC-1', (New-DevMode 2 2)))
    $b = @(, @('DevModes2', '\\svfs\TOSHIBA Universal PS3', (New-DevMode 1 2)))
}
$r = Invoke-PdJob
Assert-Same ((Lines 'delete *') -join ';') "delete $a DevModePerUser Convey;delete RelianPD_$b DevModes2 \\svfs\TOSHIBA Universal PS3" 'only drifted, non-skipped user values deleted'
Assert-Same ((Lines '*load *') -join ';') "load RelianPD_$b;unload RelianPD_$b" 'signed-out hive loaded once and unloaded'
Assert-Same ((@($r.Users | Where-Object { $_.sid -eq $c }))[0].status) 'in-use' 'in-use hive skipped'
Assert-Same ((@($r.Users | Where-Object { $_.sid -eq $b }))[0].status) 'changed' 'signed-out user fixed'
Assert-Same $r.ExitCode 0 'users exit'
Assert-Same (@($script:F.Loaded) -join ',') "$a,$($a)_Classes,.DEFAULT,S-1-5-18" 'no hive left loaded'

# A read that throws still unloads the hive and fails the run.
Reset-Test -Printers @() -Profiles @($b) -ReadThrows $b
$r = Invoke-PdJob
Assert-Same ((Lines '*load *') -join ';') "load RelianPD_$b;unload RelianPD_$b" 'unload after a throw'
Assert-Same $r.ExitCode 2 'throw fails the run'

# An unload that fails is a failed run, never a silent success.
Reset-Test -Printers @() -Profiles @($b) -UnloadFails
$r = Invoke-PdJob
Assert-Same $r.ExitCode 2 'unload failure exit'
Assert-True ($r.Error -like '*RelianPD_*') 'unload failure named'

# A mount left by an earlier crashed run is unloaded first.
Reset-Test -Printers @() -Loaded @("RelianPD_$c")
$r = Invoke-PdJob
Assert-Same ((Lines '*load *') -join ';') "unload RelianPD_$c" 'stale mount unloaded'

# One JSON line.
$line = ConvertTo-PdJobLine $r
$obj = $line | ConvertFrom-Json
Assert-Same $obj.job 'printer-defaults' 'json job'
Assert-True ($line -notmatch "\n") 'one line'

Write-Output 'printer-defaults tests passed'
