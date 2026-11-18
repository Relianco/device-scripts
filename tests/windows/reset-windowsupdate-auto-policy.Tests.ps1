# reset-windowsupdate-auto-policy module. The registry is a fake behind the module's seams; backups are real files in a temp directory.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'windows/jobs/reset-windowsupdate-auto-policy.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ("$Actual" -ne "$Expected") { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
. $modulePath

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("wuauto-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpRoot

# Fake registry: the tree the module reads, and an ordered log of every change.
function Reset-Test {
    param($Root = @(), $Au = @())
    $script:Fake = @{ '' = [Collections.Generic.List[object]]::new(); 'AU' = [Collections.Generic.List[object]]::new() }
    foreach ($v in $Root) { $script:Fake[''].Add($v) }
    foreach ($v in $Au) { $script:Fake['AU'].Add($v) }
    $script:Log = [Collections.Generic.List[string]]::new()
    $script:DeleteThrows = $false
    $script:WuBackupDir = Join-Path $tmpRoot ([Guid]::NewGuid().ToString('N'))
}
function New-V { param($Name, $Kind, $Data) @{ name = $Name; kind = $Kind; data = $Data } }
$script:WuReadTree = {
    @(@{ path = ''; values = @($script:Fake[''].ToArray()) }, @{ path = 'AU'; values = @($script:Fake['AU'].ToArray()) })
}
$script:WuDeleteValue = { param($Rel, $Name)
    if ($script:DeleteThrows) { throw 'Access denied' }
    $script:Log.Add("delete $Rel\$Name")
    $null = $script:Fake[$Rel].RemoveAll([Predicate[object]]{ param($v) $v.name -eq $Name })
}
$script:WuSetValue = { param($Rel, $Name, $Kind, $Data)
    $script:Log.Add("set $Rel\$Name")
    $null = $script:Fake[$Rel].RemoveAll([Predicate[object]]{ param($v) $v.name -eq $Name })
    $script:Fake[$Rel].Add((New-V $Name $Kind $Data))
}
$script:WuProtectDir = { param($Path) $script:Log.Add('protect') }

function Names { param($Rel) (@($script:Fake[$Rel].ToArray()) | ForEach-Object { $_.name }) -join ',' }
function Backups { @(if (Test-Path -LiteralPath $script:WuBackupDir) { Get-ChildItem -LiteralPath $script:WuBackupDir -File }) }

$other = @((New-V 'DisableWindowsUpdateAccess' 'DWord' 1), (New-V 'WUServer' 'String' 'http://wsus:8530'))
$auAll = @((New-V 'NoAutoUpdate' 'DWord' 1), (New-V 'AUOptions' 'DWord' 1), (New-V 'ScheduledInstallDay' 'DWord' 0), (New-V 'Blob' 'Binary' 'AQID'))

# Run: backup written first, then only the two values removed; every other value and subkey value is kept.
Reset-Test -Root $other -Au $auAll
$r = Invoke-WuJob
Assert-Same $r.ExitCode 0 'run exit'
Assert-Same $r.Status 'removed' 'run status'
Assert-Same ($r.Before.NoAutoUpdate) 1 'before NoAutoUpdate'
Assert-Same ($r.Before.AUOptions) 1 'before AUOptions'
Assert-True ($null -eq $r.After.NoAutoUpdate -and $null -eq $r.After.AUOptions) 'after is absent'
Assert-Same ($script:Log -join ',') 'protect,delete AU\NoAutoUpdate,delete AU\AUOptions' 'only the two deletes, after the directory is protected'
Assert-Same (Names 'AU') 'ScheduledInstallDay,Blob' 'other AU values kept'
Assert-Same (Names '') 'DisableWindowsUpdateAccess,WUServer' 'root values kept'
$files = @(Backups)
Assert-Same $files.Count 1 'one backup'
Assert-Same $r.Backup $files[0].Name 'line names the backup'
$doc = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
Assert-Same $doc.targets.NoAutoUpdate.data 1 'backup holds NoAutoUpdate'
Assert-Same $doc.targets.AUOptions.kind 'DWord' 'backup holds the kind'
Assert-Same (@($doc.tree).Count) 2 'backup holds the whole tree'
Assert-True ((@($doc.tree | ForEach-Object { $_.values } | ForEach-Object { $_ }) | Where-Object { $_.name -eq 'WUServer' }) -ne $null) 'backup holds non-target values'
$line = ConvertTo-WuJobLine $r | ConvertFrom-Json
Assert-Same $line.job 'reset-windowsupdate-auto-policy' 'job name'
Assert-Same $line.status 'removed' 'line status'

# Restore round trip: newest backup, the two values come back with their kind, nothing else is touched.
$script:Log.Clear()
$r = Invoke-WuJob -Restore
Assert-Same $r.ExitCode 0 'restore exit'
Assert-Same $r.Status 'restored' 'restore status'
Assert-Same ($script:Log -join ',') 'set AU\NoAutoUpdate,set AU\AUOptions' 'restore writes only the two values'
Assert-Same $r.After.NoAutoUpdate 1 'restored NoAutoUpdate'
Assert-Same $r.After.AUOptions 1 'restored AUOptions'
Assert-Same $r.Backup $files[0].Name 'restore names the backup used'
Assert-Same (Names '') 'DisableWindowsUpdateAccess,WUServer' 'restore leaves root values'
# A named backup works, a bad name is refused.
$r = Invoke-WuJob -Restore -BackupName $files[0].Name
Assert-Same $r.Status 'restored' 'named restore'
$r = Invoke-WuJob -Restore -BackupName '..\..\x.json'
Assert-Same $r.ExitCode 2 'bad backup name exit'
Assert-Same $r.Status 'failed' 'bad backup name status'

# Never overwrite: a second delete after the values return makes a second file, the first is unchanged.
$first = Get-Content -LiteralPath $files[0].FullName -Raw
$null = Invoke-WuJob
$files2 = @(Backups)
Assert-Same $files2.Count 2 'second run adds a second backup'
Assert-Same (Get-Content -LiteralPath $files[0].FullName -Raw) $first 'first backup unchanged'
Assert-True ($files2.Name -contains $files[0].Name) 'first backup still there'
# Restore with no name takes the newest.
$newest = ($files2 | Sort-Object Name)[-1].Name
Assert-Same (Invoke-WuJob -Restore).Backup $newest 'restore takes the newest'

# Idempotent: absent values change nothing, write no backup, and say so.
Reset-Test -Root $other -Au @((New-V 'ScheduledInstallDay' 'DWord' 0))
$r = Invoke-WuJob
Assert-Same $r.ExitCode 0 'absent exit'
Assert-Same $r.Status 'unchanged' 'absent status'
Assert-Same $script:Log.Count 0 'absent changes nothing'
Assert-Same (@(Backups).Count) 0 'absent writes no backup'
Reset-Test
Assert-Same (Invoke-WuJob).Status 'unchanged' 'no policy key at all'

# One value present: only that one is removed.
Reset-Test -Au @((New-V 'AUOptions' 'DWord' 1), (New-V 'Keep' 'DWord' 5))
$r = Invoke-WuJob
Assert-Same ($script:Log -join ',') 'protect,delete AU\AUOptions' 'only the present value is deleted'
Assert-Same $r.Status 'removed' 'one value status'

# Fail closed: a backup that cannot be written blocks every delete. Here the backup directory path is a file.
Reset-Test -Root $other -Au $auAll
$blocker = Join-Path $tmpRoot 'blocker'
Set-Content -LiteralPath $blocker -Value 'x'
$script:WuBackupDir = $blocker
$r = Invoke-WuJob
Assert-Same $r.ExitCode 2 'backup failure exit'
Assert-Same $r.Status 'failed' 'backup failure status'
Assert-True (-not ($script:Log -match 'delete')) 'backup failure deletes nothing'
Assert-Same (Names 'AU') 'NoAutoUpdate,AUOptions,ScheduledInstallDay,Blob' 'backup failure keeps every value'
Assert-True ($r.Error.Length -gt 0) 'backup failure names an error'

# A failed delete is reported, not hidden.
Reset-Test -Au $auAll
$script:DeleteThrows = $true
$r = Invoke-WuJob
Assert-Same $r.ExitCode 2 'delete failure exit'
Assert-Same $r.Status 'failed' 'delete failure status'

# -ReportOnly: drift reported, no backup, no delete.
Reset-Test -Au $auAll
$r = Invoke-WuJob -ReportOnly
Assert-Same $r.ExitCode 1 'report-only drift exit'
Assert-Same $r.Status 'drift' 'report-only status'
Assert-Same $script:Log.Count 0 'report-only changes nothing'
Assert-Same (@(Backups).Count) 0 'report-only writes no backup'

# -Restore with no backup fails cleanly: exit 2, no change.
Reset-Test -Au @((New-V 'ScheduledInstallDay' 'DWord' 0))
$r = Invoke-WuJob -Restore
Assert-Same $r.ExitCode 2 'restore without backup exit'
Assert-Same $r.Status 'failed' 'restore without backup status'
Assert-Same $r.Error 'no backup found' 'restore without backup error'
Assert-Same $script:Log.Count 0 'restore without backup changes nothing'
(ConvertTo-WuJobLine $r | ConvertFrom-Json) | Out-Null

# The module never names a value other than the two it may delete.
$source = Get-Content -LiteralPath $modulePath -Raw
Assert-True ($source -match "\`$script:WuTargets = @\('NoAutoUpdate', 'AUOptions'\)") 'target list is exactly the two values'
Assert-True (([regex]::Matches($source, '\.DeleteValue\(|DeleteSubKey|Remove-Item|Remove-ItemProperty')).Count -eq 1) 'one delete call in the module'

Remove-Item -LiteralPath $tmpRoot -Recurse -Force
Write-Output 'reset-windowsupdate-auto-policy tests passed'
