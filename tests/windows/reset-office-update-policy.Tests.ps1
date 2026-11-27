# reset-office-update-policy module. The registry is a fake behind the module's seams; backups are real files in a temp directory.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'windows/jobs/reset-office-update-policy.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ("$Actual" -ne "$Expected") { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
. $modulePath

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("officeupd-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpRoot

function New-V { param($Name, $Kind, $Data) @{ name = $Name; kind = $Kind; data = $Data } }
# Fake registry: one value list per key ('pol' and 'c2r'), $null = key absent, and an ordered log of every change.
function Reset-Test {
    param($Pol = $null, $C2r = $null)
    $script:Fake = @{ pol = $null; c2r = $null }
    if ($null -ne $Pol) { $script:Fake.pol = [Collections.Generic.List[object]]::new(); foreach ($v in $Pol) { $script:Fake.pol.Add($v) } }
    if ($null -ne $C2r) { $script:Fake.c2r = [Collections.Generic.List[object]]::new(); foreach ($v in $C2r) { $script:Fake.c2r.Add($v) } }
    $script:Log = [Collections.Generic.List[string]]::new()
    $script:OuBackupDir = Join-Path $tmpRoot ([Guid]::NewGuid().ToString('N'))
}
$script:OuReadKey = { param($Key) if ($null -eq $script:Fake[$Key]) { return $null }; return ,@($script:Fake[$Key].ToArray()) }
$script:OuDeleteValue = { param($Key, $Name)
    $script:Log.Add("delete $Key\$Name")
    $null = $script:Fake[$Key].RemoveAll([Predicate[object]]{ param($v) $v.name -eq $Name })
}
$script:OuSetValue = { param($Key, $Name, $Kind, $Data)
    $script:Log.Add("set $Key\$Name=$Data")
    $null = $script:Fake[$Key].RemoveAll([Predicate[object]]{ param($v) $v.name -eq $Name })
    $script:Fake[$Key].Add((New-V $Name $Kind $Data))
}
$script:OuProtectDir = { param($Path) $script:Log.Add('protect') }
function Val { param($Key, $Name) $v = @($script:Fake[$Key].ToArray()) | Where-Object { $_.name -eq $Name }; if ($v) { "$($v.kind):$($v.data)" } else { 'absent' } }
function Backups { @(if (Test-Path -LiteralPath $script:OuBackupDir) { Get-ChildItem -LiteralPath $script:OuBackupDir -File }) }

# The values the "disable Office updates" script writes, as read on a PC (2026-11-27), plus values that must stay.
$polOff = @((New-V 'updatebranch' 'String' 'None'), (New-V 'EnableAutomaticUpdates' 'DWord' 0), (New-V 'hideenabledisableupdates' 'DWord' 1), (New-V 'hideupdatenotifications' 'DWord' 1))
$c2rOff = @((New-V 'VersionToReport' 'String' '16.0.20625.20142'), (New-V 'UpdatesEnabled' 'String' 'False'),
            (New-V 'CDNBaseUrl' 'String' 'http://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6'),
            (New-V 'UpdateUrl' 'String' ''), (New-V 'UpdateToVersion' 'String' ''))

# Report-only: drift, exit 1, nothing written.
Reset-Test -Pol $polOff -C2r $c2rOff
$r = Invoke-OuJob -ReportOnly
Assert-Same $r.ExitCode 1 'report exit'
Assert-Same $r.Status 'drift' 'report status'
Assert-Same $script:Log.Count 0 'report changes nothing'
Assert-Same (@(Backups).Count) 0 'report writes no backup'
Assert-Same (@($r.Plan) -join ',') 'pol\updatebranch,pol\EnableAutomaticUpdates,pol\hideenabledisableupdates,c2r\UpdatesEnabled,c2r\UpdateUrl,c2r\UpdateToVersion' 'report names the plan'

# Run: backup first, then exactly the disabling values go; every other value is kept.
$r = Invoke-OuJob
Assert-Same $r.ExitCode 0 'run exit'
Assert-Same $r.Status 'fixed' 'run status'
Assert-Same ($script:Log -join ',') 'protect,delete pol\updatebranch,delete pol\EnableAutomaticUpdates,delete pol\hideenabledisableupdates,set c2r\UpdatesEnabled=True,delete c2r\UpdateUrl,delete c2r\UpdateToVersion' 'only the planned changes, after the directory is protected'
Assert-Same (Val 'pol' 'hideupdatenotifications') 'DWord:1' 'other policy value kept'
Assert-Same (Val 'c2r' 'CDNBaseUrl') 'String:http://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6' 'install channel kept'
Assert-Same (Val 'c2r' 'UpdatesEnabled') 'String:True' 'Click-to-Run updates on'
$files = @(Backups)
Assert-Same $files.Count 1 'one backup'
Assert-Same $r.Backup $files[0].Name 'line names the backup'
$doc = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
Assert-Same (@($doc.changes).Count) 6 'backup lists every change'
Assert-Same (@($doc.keys.pol).Count) 4 'backup holds the whole policy key'
Assert-Same (@($doc.keys.c2r).Count) 5 'backup holds the whole Click-to-Run key'
$line = ConvertTo-OuJobLine $r | ConvertFrom-Json
Assert-Same $line.job 'reset-office-update-policy' 'job name'
Assert-Same $line.status 'fixed' 'line status'

# Idempotent: a second run finds nothing and writes no backup.
$script:Log.Clear()
$r = Invoke-OuJob
Assert-Same $r.Status 'unchanged' 'second run unchanged'
Assert-Same $script:Log.Count 0 'second run changes nothing'
Assert-Same (@(Backups).Count) 1 'second run writes no backup'

# Restore: the newest backup puts back exactly what was changed, with its kind and data.
$r = Invoke-OuJob -Restore
Assert-Same $r.ExitCode 0 'restore exit'
Assert-Same $r.Status 'restored' 'restore status'
Assert-Same (Val 'pol' 'EnableAutomaticUpdates') 'DWord:0' 'restored EnableAutomaticUpdates'
Assert-Same (Val 'pol' 'updatebranch') 'String:None' 'restored updatebranch'
Assert-Same (Val 'c2r' 'UpdatesEnabled') 'String:False' 'restored UpdatesEnabled'
Assert-Same (Val 'c2r' 'UpdateUrl') 'String:' 'restored empty UpdateUrl'
$r = Invoke-OuJob -Restore -BackupName '..\x.json'
Assert-Same $r.Status 'failed' 'bad backup name refused'

# Values set on purpose are not touched: updates on, a real channel, the option shown, a real update URL.
Reset-Test -Pol @((New-V 'EnableAutomaticUpdates' 'DWord' 1), (New-V 'updatebranch' 'String' 'Current'), (New-V 'hideenabledisableupdates' 'DWord' 0)) -C2r @((New-V 'UpdatesEnabled' 'String' 'True'), (New-V 'UpdateUrl' 'String' 'http://officecdn.microsoft.com/pr/492350f6-3a01-4f97-b9c0-c7c6ddf67d60'))
$r = Invoke-OuJob
Assert-Same $r.Status 'unchanged' 'deliberate values unchanged'
Assert-Same $script:Log.Count 0 'deliberate values not touched'

# Absent keys (no Office, no policy): unchanged, no error.
Reset-Test
$r = Invoke-OuJob
Assert-Same $r.ExitCode 0 'absent keys exit'
Assert-Same $r.Status 'unchanged' 'absent keys status'
Assert-Same $r.Error '' 'absent keys no error'

# Fail closed: a backup that cannot be written blocks every change.
Reset-Test -Pol $polOff -C2r $c2rOff
$blocker = Join-Path $tmpRoot 'blocker'
Set-Content -LiteralPath $blocker -Value 'x'
$script:OuBackupDir = $blocker
$r = Invoke-OuJob
Assert-Same $r.ExitCode 2 'backup failure exit'
Assert-Same $r.Status 'failed' 'backup failure status'
Assert-True (-not ($script:Log -match 'delete|set ')) 'backup failure changes nothing'
Assert-Same (Val 'pol' 'EnableAutomaticUpdates') 'DWord:0' 'backup failure keeps the value'

# A value that changes after the snapshot aborts the run before any change.
Reset-Test -Pol $polOff -C2r $c2rOff
$script:ReadCount = 0
$savedRead = $script:OuReadKey
$script:OuReadKey = { param($Key)
    $script:ReadCount++
    if ($script:ReadCount -eq 3) { $script:Fake.pol[1] = (New-V 'EnableAutomaticUpdates' 'DWord' 1) }
    return ,@($script:Fake[$Key].ToArray())
}
$r = Invoke-OuJob
Assert-Same $r.Status 'failed' 'changed snapshot status'
Assert-True ($r.Error -match 'changed after the snapshot') 'changed snapshot names the reason'
Assert-True (-not ($script:Log -match 'delete|set ')) 'changed snapshot changes nothing'
$script:OuReadKey = $savedRead

Remove-Item -LiteralPath $tmpRoot -Recurse -Force
Write-Output 'PASS reset-office-update-policy'
