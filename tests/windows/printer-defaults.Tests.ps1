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
        @('TOSHIBA e-STUDIO0000AC-1', 'TOSHIBA e-STUDIO Fax'), @('Splashtop PDF Remote Printer', 'Microsoft Print To PDF'),
        @('PaperPort Image Printer', 'Nuance Image Printer Driver'), @('Office Copier (Fax)', ''))) {
    Assert-True (Test-PdSkipPrinter -Name $p[0] -Driver $p[1]) "skip $($p[0])"
}
foreach ($p in @(@('Front Desk', 'TOSHIBA Universal Printer 2'), @('CX3535 MFP(PCL)', 'CX3535 MFP(PCL)'), @('\\svfs\TOSHIBA Universal PS3', ''))) {
    Assert-True (-not (Test-PdSkipPrinter -Name $p[0] -Driver $p[1])) "keep $($p[0])"
}

# --- a saved per-user DEVMODE is fine only when it says monochrome and not two-sided
Assert-True (Test-PdUserDevModeOk (New-DevMode 1 1)) 'mono simplex ok'
Assert-True (Test-PdUserDevModeOk (New-DevMode 1 0)) 'mono, duplex unset ok'
Assert-True (-not (Test-PdUserDevModeOk (New-DevMode 2 1))) 'colour not ok'
Assert-True (Test-PdUserDevModeOk (New-DevMode 0 1)) 'colour unset inherits the printer default, ok'
Assert-True (-not (Test-PdUserDevModeOk (New-DevMode 0 2))) 'colour unset, two-sided not ok'
Assert-True (Test-PdUserDevModeOk (New-DevMode 2 1) -KeepColour) 'a colour-option queue may keep colour'
Assert-True (-not (Test-PdUserDevModeOk (New-DevMode 2 2) -KeepColour)) 'a colour-option queue must still be one-sided'
Assert-True (-not (Test-PdUserDevModeOk (New-DevMode 1 2))) 'long-edge not ok'
Assert-True (-not (Test-PdUserDevModeOk (New-DevMode 1 3))) 'short-edge not ok'
Assert-True (-not (Test-PdUserDevModeOk ([byte[]]@(1, 2, 3)))) 'a short buffer is not ok'

# --- fake machine
function Reset-Test {
    param($Printers = @(), $Jobs = @{}, $Loaded = @(), $Profiles = @(), $Values = @{}, $InUse = @(), $Denied = @(), [switch]$SetIgnored, [switch]$DevModeFixes, [switch]$UnloadFails, $ReadThrows = '')
    $script:F = @{ Config = @{}; Driver = @{}; Jobs = $Jobs; Loaded = [Collections.Generic.List[string]]::new(); Profiles = $Profiles
        Values = $Values; InUse = $InUse; Denied = $Denied; SetIgnored = [bool]$SetIgnored; DevModeFixes = [bool]$DevModeFixes; UnloadFails = [bool]$UnloadFails; ReadThrows = $ReadThrows }
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
$script:PdProfiles = { @($script:F.Profiles | ForEach-Object { [pscustomobject]@{ Sid = $_; Path = "fixture\$_" } }) }
$script:PdLoadHive = { param($Mount, $File)
    $sid = $Mount.Substring('RelianPD_'.Length)
    if ($script:F.InUse -contains $sid) { return 'in-use' }
    if ($script:F.Denied -contains $sid) { return 'ERROR: Access is denied.' }
    $script:Log.Add("load $Mount"); $script:F.Loaded.Add($Mount); return 'ok'
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
$script:PdWriteUserValue = { param($Root, $Key, $Name, $Bytes)
    $script:Log.Add("write $Root $Key $Name color=$([BitConverter]::ToInt16($Bytes, 92)) duplex=$([BitConverter]::ToInt16($Bytes, 94)) fields=$([BitConverter]::ToUInt32($Bytes, 72))")
}
$script:PdBackupUserValues = { param($Sid, $Values)
    if ($script:F.ContainsKey('BackupThrows') -and $script:F.BackupThrows) { throw 'disk full' }
    $script:Log.Add("backup $Sid " + (@($Values | ForEach-Object { $_.Name }) -join ','))
}

function Lines { param($Pattern) @($script:Log | Where-Object { $_ -like $Pattern }) }
function Entry { param($Result, $Name) @($Result.Printers | Where-Object { $_.name -eq $Name })[0] }

$machine = @(@('Front Desk', 'TOSHIBA Universal Printer 2', $true, 'TwoSidedLongEdge'), @('Copy Room', 'TOSHIBA Universal Printer 2', $false, 'OneSided'),
    @('Adobe PDF', 'Adobe PDF Converter', $true, 'OneSided'), @('Konica', 'KONICA MINOLTA Universal PCL', $false, 'TwoSidedLongEdge'),
    @('TOSHIBA e-STUDIO3505AC-1', 'TOSHIBA e-STUDIO Fax', $true, 'TwoSidedLongEdge'))

# Run: only the drifted printers are set, each to exactly the setting it lacks; PDF and fax queues untouched.
Reset-Test -Printers $machine
$r = Invoke-PdJob
Assert-Same $r.ExitCode 0 'run exit'
Assert-Same $r.Status 'changed' 'run status'
Assert-Same ((Lines 'set *') -join ';') 'set Front Desk color=False duplex=OneSided;set Konica color= duplex=OneSided' 'set calls'
Assert-Same @(Lines 'devmode *').Count 0 'no DEVMODE fallback when Set-PrintConfiguration took'
Assert-Same (Entry $r 'Front Desk').status 'changed' 'Front Desk status'
Assert-Same (Entry $r 'Front Desk').before 'color/TwoSidedLongEdge' 'Front Desk before'
Assert-Same (Entry $r 'Front Desk').after 'mono/OneSided' 'Front Desk after'
Assert-Same (Entry $r 'Copy Room').status 'unchanged' 'Copy Room status'
Assert-Same (Entry $r 'Adobe PDF').status 'skipped' 'PDF skipped'
Assert-Same (Entry $r 'TOSHIBA e-STUDIO3505AC-1').status 'skipped' 'fax driver skipped'

# Second run: nothing to do.
$r = Invoke-PdJob
Assert-Same $r.Status 'compliant' 'idempotent status'
Assert-Same $r.ExitCode 0 'idempotent exit'
Assert-Same @(Lines 'set *').Count 2 'no new set calls on the second run'

# ReportOnly: changes nothing and reports drift.
Reset-Test -Printers $machine -Loaded @('S-1-5-21-1-2-3-1001') -Values @{ 'S-1-5-21-1-2-3-1001' = @(, @('DevModePerUser', 'Front Desk', (New-DevMode 2 1))) }
$r = Invoke-PdJob -ReportOnly
Assert-Same $r.Status 'drift' 'report status'
Assert-Same $r.ExitCode 1 'report exit'
Assert-Same @(Lines 'set *').Count 0 'report sets nothing'
Assert-Same @(Lines 'delete *').Count 0 'report deletes nothing'
Assert-Same (Entry $r 'Front Desk').status 'drift' 'report printer status'
Assert-Same $r.Users[0].drift 'DevModePerUser\Front Desk' 'report names the user value'

# A printer with a job in its queue is not touched; the run says busy so it is retried.
Reset-Test -Printers $machine -Jobs @{ 'Front Desk' = 1 } -Loaded @('S-1-5-21-1-2-3-1009') -Values @{ 'S-1-5-21-1-2-3-1009' = @(@('DevModePerUser', 'Front Desk', (New-DevMode 2 1)), @('DevModePerUser', 'Konica', (New-DevMode 2 1))) }
$r = Invoke-PdJob
Assert-Same ((Lines 'delete *') -join ';') 'delete S-1-5-21-1-2-3-1009 DevModePerUser Konica' 'busy printer user value kept for the next run'
Assert-Same ($r.Users[0].status) 'busy' 'user with a busy printer value is busy'
Assert-Same (Entry $r 'Front Desk').status 'busy' 'busy printer status'
Assert-Same @(Lines 'set Front Desk*').Count 0 'busy printer untouched'
Assert-Same @(Lines 'set Konica*').Count 1 'the other printer is still done'
Assert-Same $r.Status 'busy' 'overall busy'
Assert-Same $r.ExitCode 1 'busy exit'

# A compliant printer with a job queued: its users' preferences also wait.
Reset-Test -Printers $machine -Jobs @{ 'Copy Room' = 2 } -Loaded @('S-1-5-21-1-2-3-1009') -Values @{ 'S-1-5-21-1-2-3-1009' = @(, @('DevModePerUser', 'Copy Room', (New-DevMode 2 1))) }
$r = Invoke-PdJob
Assert-Same @(Lines 'delete *').Count 0 'compliant busy printer user value kept'
Assert-Same $r.Status 'busy' 'compliant busy printer makes the run busy'

# A driver that ignores Set-PrintConfiguration gets the DEVMODE write.
Reset-Test -Printers $machine -SetIgnored -DevModeFixes
$r = Invoke-PdJob
Assert-Same ((Lines 'devmode *') -join ';') 'devmode Front Desk;devmode Konica' 'DEVMODE fallback'
Assert-Same (Entry $r 'Front Desk').status 'changed' 'fallback status'
Assert-Same $r.ExitCode 0 'fallback exit'

# Neither works: failed, exit 2.
Reset-Test -Printers $machine -SetIgnored
$r = Invoke-PdJob
Assert-Same (Entry $r 'Front Desk').status 'failed' 'still colour after both writes'
Assert-Same $r.Status 'failed' 'overall failed'
Assert-Same $r.ExitCode 2 'failed exit'

# Users: signed-in hive in place; signed-out hive loaded, fixed and unloaded; an in-use hive is skipped.
$a = 'S-1-5-21-1-2-3-1001'; $b = 'S-1-12-1-4-5-6-7'; $c = 'S-1-5-21-1-2-3-1003'
Reset-Test -Printers $machine -Loaded @($a, "$($a)_Classes", '.DEFAULT', 'S-1-5-18') -Profiles @($a, $b, $c) -InUse @($c) -Values @{
    $a = @(@('DevModePerUser', 'Front Desk', (New-DevMode 2 1)), @('DevModePerUser', 'Microsoft Print to PDF', (New-DevMode 2 1)),
        @('DevModes2', 'Copy Room', (New-DevMode 1 1)), @('DevModePerUser', 'TOSHIBA e-STUDIO3505AC-1', (New-DevMode 2 2)))
    $b = @(, @('DevModes2', '\\svfs\TOSHIBA Universal PS3', (New-DevMode 1 2)))
}
$r = Invoke-PdJob
Assert-Same ((Lines 'delete *') -join ';') "delete $a DevModePerUser Front Desk;delete RelianPD_$b DevModes2 \\svfs\TOSHIBA Universal PS3" 'only drifted, non-skipped user values deleted'
Assert-Same ((Lines '*load *') -join ';') "load RelianPD_$b;unload RelianPD_$b" 'signed-out hive loaded once and unloaded'
Assert-Same ((@($r.Users | Where-Object { $_.sid -eq $c }))[0].status) 'in-use' 'in-use hive skipped'
Assert-Same ((@($r.Users | Where-Object { $_.sid -eq $b }))[0].status) 'changed' 'signed-out user fixed'
Assert-Same $r.ExitCode 0 'users exit'
Assert-Same (@($script:F.Loaded) -join ',') "$a,$($a)_Classes,.DEFAULT,S-1-5-18" 'no hive left loaded'

# Every value is backed up before it is deleted; a failed backup deletes nothing.
Reset-Test -Printers $machine -Loaded @($a) -Values @{ $a = @(@('DevModePerUser', 'Front Desk', (New-DevMode 2 1)), @('DevModes2', 'Konica', (New-DevMode 1 2))) }
$r = Invoke-PdJob
Assert-Same (($script:Log | Where-Object { $_ -like 'backup *' -or $_ -like 'delete *' }) -join ';') "backup $a Front Desk,Konica;delete $a DevModePerUser Front Desk;delete $a DevModes2 Konica" 'backup before delete'
Reset-Test -Printers $machine -Loaded @($a) -Values @{ $a = @(, @('DevModePerUser', 'Front Desk', (New-DevMode 2 1))) }
$script:F.BackupThrows = $true
$r = Invoke-PdJob
Assert-Same @(Lines 'delete *').Count 0 'failed backup deletes nothing'
Assert-Same $r.ExitCode 2 'failed backup fails the run'

# A hive that fails to load for any reason but contention fails the run.
Reset-Test -Printers @() -Profiles @($b) -Denied @($b)
$r = Invoke-PdJob
Assert-Same ($r.Users[0].status) 'failed' 'denied load is failed, not in-use'
Assert-Same $r.ExitCode 2 'denied load exit'

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

# Colour options: a Colour/Color name, or a plain queue with a BW twin, keeps colour; it is still made one-sided.
$names = @('Business Printer Colour', 'Business Printer BW', 'Xerox WorkCentre 7845', 'Xerox WorkCentre 7845 BW', 'Party Printer Color', 'Front Desk', '\\srv\Xerox AltaLink C8055', '\\srv\Xerox AltaLink C8055 BW')
Assert-True (Test-PdKeepColour -Name 'Business Printer Colour' -AllNames $names) 'Colour name kept'
Assert-True (Test-PdKeepColour -Name 'Party Printer Color' -AllNames $names) 'Color name kept'
Assert-True (Test-PdKeepColour -Name 'Xerox WorkCentre 7845' -AllNames $names) 'plain twin kept'
Assert-True (Test-PdKeepColour -Name '\\srv\Xerox AltaLink C8055' -AllNames $names) 'plain twin connection kept'
Assert-True (-not (Test-PdKeepColour -Name 'Business Printer BW' -AllNames $names)) 'BW queue not kept'
Assert-True (-not (Test-PdKeepColour -Name 'Xerox WorkCentre 7845 BW' -AllNames $names)) 'BW twin not kept'
Assert-True (-not (Test-PdKeepColour -Name 'Front Desk' -AllNames $names)) 'ordinary queue not kept'
Assert-True (-not (Test-PdKeepColour -Name 'Business Printer Colour' -AllNames $names -Pattern 'NOMATCH')) 'pattern is a parameter'

$x = 'S-1-5-21-1-2-3-1005'
Reset-Test -Printers @(@('Business Printer Colour', 'Xerox Global Print Driver PS', $true, 'TwoSidedLongEdge'), @('Business Printer BW', 'Xerox Global Print Driver PS', $true, 'TwoSidedLongEdge'),
    @('Xerox WorkCentre 7845', 'Xerox Global Print Driver PCL6', $true, 'OneSided'), @('Xerox WorkCentre 7845 BW', 'Xerox Global Print Driver PCL6', $true, 'OneSided')) -Loaded @($x) -Values @{
    $x = @(@('DevModePerUser', 'Business Printer Colour', (New-DevMode 2 1)), @('DevModePerUser', 'Business Printer BW', (New-DevMode 2 1)), @('DevModePerUser', 'Xerox WorkCentre 7845', (New-DevMode 2 2)))
}
$r = Invoke-PdJob
Assert-Same ((Lines 'set *') -join ';') 'set Business Printer BW color=False duplex=OneSided;set Business Printer Colour color= duplex=OneSided;set Xerox WorkCentre 7845 BW color=False duplex=' 'colour options only made one-sided'
Assert-Same (Entry $r 'Business Printer Colour').status 'changed' 'colour option status'
Assert-Same (Entry $r 'Business Printer Colour').after 'color/OneSided' 'colour option after'
Assert-Same (Entry $r 'Xerox WorkCentre 7845').status 'unchanged' 'twin already one-sided'
Assert-Same (Entry $r 'Xerox WorkCentre 7845').keepColour 'True' 'twin flagged'
Assert-Same ((Lines 'delete *') -join ';') "delete $x DevModePerUser Business Printer BW" 'user: BW queue colour deleted, colour option kept'
Assert-Same ((Lines 'write *') -join ';') "write $x DevModePerUser Xerox WorkCentre 7845 color=2 duplex=1 fields=6144" 'user: twin colour + two-sided made one-sided, colour kept'

# A colour option's saved preference that says colour and two-sided is rewritten one-sided, not deleted: deleting it
# would drop the user's colour choice wherever the queue's own default is black and white (codex review #242).
$y = 'S-1-5-21-1-2-3-1006'
Reset-Test -Printers @(@('Business Printer Colour', 'Xerox Global Print Driver PS', $false, 'OneSided'), @('Front Desk', 'TOSHIBA Universal Printer 2', $false, 'OneSided')) -Loaded @($y) -Values @{
    $y = @(@('DevModePerUser', 'Business Printer Colour', (New-DevMode 2 2)), @('DevModes2', 'Front Desk', (New-DevMode 2 2)))
}
$r = Invoke-PdJob
Assert-Same (($script:Log | Where-Object { $_ -match '^(backup|delete|write) ' }) -join ';') "backup $y Business Printer Colour,Front Desk;write $y DevModePerUser Business Printer Colour color=2 duplex=1 fields=6144;delete $y DevModes2 Front Desk" 'colour option rewritten one-sided keeping colour; other queue deleted'
Assert-Same $r.Users[0].status 'changed' 'rewritten user changed'
Reset-Test -Printers @(, @('Business Printer Colour', 'Xerox Global Print Driver PS', $false, 'OneSided')) -Loaded @($y) -Values @{ $y = @(, @('DevModePerUser', 'Business Printer Colour', [byte[]]@(1, 2, 3))) }
$r = Invoke-PdJob
Assert-Same ((Lines 'delete *') -join ';') "delete $y DevModePerUser Business Printer Colour" 'a short colour-option value is deleted, never parsed'

# A driver whose Color reads false while its PrintTicket still says Color is not compliant; DEVMODE fallback runs.
Reset-Test -Printers @(, @('Xerox Q BW', 'Xerox Global Print Driver PS', $false, 'OneSided')) -SetIgnored
$script:F.Config['Xerox Q BW'] = @{ Color = $false; Duplex = 'OneSided'; Ticket = 'Color' }
$script:PdSetDevMode = { param($Name) $script:Log.Add("devmode $Name"); $script:F.Config[$Name] = @{ Color = $false; Duplex = 'OneSided'; Ticket = 'Monochrome' } }
$r = Invoke-PdJob
Assert-Same (Entry $r 'Xerox Q BW').status 'changed' 'ticket colour is drift'
Assert-Same @(Lines 'devmode *').Count 1 'ticket colour gets the DEVMODE write'
Assert-Same (Entry $r 'Xerox Q BW').after 'mono/OneSided/ticket:Monochrome' 'ticket read back'

# A queue that cannot be read is not changed.
Reset-Test -Printers $machine -Jobs @{ 'Front Desk' = 'throw' }
$script:PdJobCount = { param($Name) if ($script:F.Jobs[$Name] -eq 'throw') { throw 'spooler RPC failed' } else { 0 } }
$r = Invoke-PdJob
Assert-Same (Entry $r 'Front Desk').status 'failed' 'unreadable queue fails'
Assert-Same @(Lines 'set Front Desk*').Count 0 'unreadable queue untouched'

# -Detect (Intune Remediation detection): exit 1 only when a run could fix something (a drifted printer or user value) or
# the job itself failed; a queue or hive that cannot be read is in the JSON line but does not start a remediation that
# would fail on it too.
Reset-Test -Printers $machine
Assert-Same (Get-PdDetectExit (Invoke-PdJob -ReportOnly)) 1 'detect: drifted printer'
Reset-Test -Printers @(, @('Copy Room', 'TOSHIBA Universal Printer 2', $false, 'OneSided')) -Loaded @($a) -Values @{ $a = @(, @('DevModePerUser', 'Copy Room', (New-DevMode 2 1))) }
Assert-Same (Get-PdDetectExit (Invoke-PdJob -ReportOnly)) 1 'detect: drifted user value'
Reset-Test -Printers @(, @('Copy Room', 'TOSHIBA Universal Printer 2', $false, 'OneSided'))
Assert-Same (Get-PdDetectExit (Invoke-PdJob -ReportOnly)) 0 'detect: compliant'
Reset-Test -Printers @(, @('Business Printer Colour', 'Xerox Global Print Driver PS', $true, 'OneSided')) -Loaded @($a) -Values @{ $a = @(, @('DevModePerUser', 'Business Printer Colour', (New-DevMode 2 1))) }
Assert-Same (Get-PdDetectExit (Invoke-PdJob -ReportOnly)) 0 'detect: a colour option kept in colour, machine and user, is compliant'
Reset-Test -Printers @(@('Copy Room', 'TOSHIBA Universal Printer 2', $false, 'OneSided'), @('Home Printer', 'HP WSD', $true, 'OneSided')) -Profiles @($b) -Denied @($b)
$script:PdGetConfig = { param($Name) if ($Name -eq 'Home Printer') { throw 'unspecified failure' }; [pscustomobject]$script:F.Config[$Name] }
$r = Invoke-PdJob -ReportOnly
Assert-Same $r.ExitCode 2 'report: unreadable queue and hive fail the report'
Assert-Same (Get-PdDetectExit $r) 0 'detect: unreadable queue or hive alone does not start a remediation'
$script:PdGetPrinters = { throw 'spooler stopped' }
Assert-Same (Get-PdDetectExit (Invoke-PdJob -ReportOnly)) 1 'detect: a job-level error is never compliant'

# The whole script with -Detect where there are no print cmdlets (Linux CI): job error, exit 1, one JSON line. Skipped
# where Get-Printer exists: the child would read that host's real printers and user hives, not a fixed failure.
if (-not (Get-Command Get-Printer -ErrorAction SilentlyContinue)) {
    $env:RELIAN_DEPLOY_TEST = ''
    $out = @(& pwsh -NoProfile -File $modulePath -Detect 2>&1)
    $code = $LASTEXITCODE
    $env:RELIAN_DEPLOY_TEST = '1'
    Assert-Same $code 1 'script -Detect exit with no spooler'
    Assert-Same (($out[-1] | ConvertFrom-Json).mode) 'report' 'script -Detect changes nothing'
}

# One JSON line.
$line = ConvertTo-PdJobLine $r
$obj = $line | ConvertFrom-Json
Assert-Same $obj.job 'printer-defaults' 'json job'
Assert-True ($line -notmatch "\n") 'one line'

Write-Output 'printer-defaults tests passed'
