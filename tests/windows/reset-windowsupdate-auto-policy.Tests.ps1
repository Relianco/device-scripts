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
$script:WuReadPolBytes = { return $null }
$script:WuWritePolBytes = { param($Bytes) }

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("wuauto-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpRoot

# Fake registry: the tree the module reads, and an ordered log of every change.
function Reset-Test {
    param($Root = @(), $Au = @(), [byte[]]$PolBytes = $null)
    $script:Fake = @{ '' = [Collections.Generic.List[object]]::new(); 'AU' = [Collections.Generic.List[object]]::new() }
    foreach ($v in $Root) { $script:Fake[''].Add($v) }
    foreach ($v in $Au) { $script:Fake['AU'].Add($v) }
    $script:FakePolBytes = $PolBytes
    $script:Log = [Collections.Generic.List[string]]::new()
    $script:DeleteThrows = $false
    $script:PolWriteThrows = $false
    $script:WuBackupDir = Join-Path $tmpRoot ([Guid]::NewGuid().ToString('N'))
}
function New-V { param($Name, $Kind, $Data) @{ name = $Name; kind = $Kind; data = $Data } }
function New-PRegRecord {
    param([string]$Key, [string]$Name, [uint32]$Type, [byte[]]$Data)
    $u = [Text.Encoding]::Unicode
    $ms = [IO.MemoryStream]::new()
    $bw = [IO.BinaryWriter]::new($ms)
    $bw.Write([uint16]0x5B)
    $bw.Write($u.GetBytes($Key)); $bw.Write([uint16]0); $bw.Write([uint16]0x3B)
    $bw.Write($u.GetBytes($Name)); $bw.Write([uint16]0); $bw.Write([uint16]0x3B)
    $bw.Write($Type); $bw.Write([uint16]0x3B)
    $bw.Write([uint32]$Data.Length); $bw.Write([uint16]0x3B)
    $bw.Write($Data)
    $bw.Write([uint16]0x5D)
    $bw.Flush()
    return ,($ms.ToArray())
}
function New-PRegFile {
    param([object[]]$Records = @())
    $ms = [IO.MemoryStream]::new()
    $ms.Write([Text.Encoding]::ASCII.GetBytes('PReg'), 0, 4)
    $ms.Write([BitConverter]::GetBytes([uint32]1), 0, 4)
    foreach ($rec in $Records) { $b = [byte[]]$rec; $ms.Write($b, 0, $b.Length) }
    return ,($ms.ToArray())
}
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
$script:WuReadPolBytes = { $script:FakePolBytes }
$script:WuWritePolBytes = { param([byte[]]$Bytes)
    if ($script:PolWriteThrows) { throw 'Pol locked' }
    $script:Log.Add("writepol $($Bytes.Length)")
    $script:FakePolBytes = $Bytes
}

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

# The real reader emits nothing for an absent policy key: the tree is $null, and that is clean, not a failure.
$savedRead = $script:WuReadTree
$script:WuReadTree = { return @() }
Reset-Test
$r = Invoke-WuJob
Assert-Same $r.ExitCode 0 'absent key exit'
Assert-Same $r.Status 'unchanged' 'absent key status'
Assert-Same $r.Error '' 'absent key has no error'
Assert-Same (Invoke-WuJob -ReportOnly).Status 'unchanged' 'absent key report-only'
$script:WuReadTree = $savedRead

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

# A target that changes between the snapshot and the delete aborts the run: nothing deleted, backup holds the snapshot.
Reset-Test -Au $auAll
$script:ReadCount = 0
$script:WuReadTree = {
    $script:ReadCount++
    if ($script:ReadCount -eq 2) { $script:Fake['AU'][0] = (New-V 'NoAutoUpdate' 'DWord' 0) }
    @(@{ path = ''; values = @($script:Fake[''].ToArray()) }, @{ path = 'AU'; values = @($script:Fake['AU'].ToArray()) })
}
$r = Invoke-WuJob
Assert-Same $r.ExitCode 2 'changed target exit'
Assert-Same $r.Status 'failed' 'changed target status'
Assert-True (-not ($script:Log -match 'delete')) 'changed target deletes nothing'
Assert-Same (Names 'AU') 'NoAutoUpdate,AUOptions,ScheduledInstallDay,Blob' 'changed target keeps every value'
Assert-Same $script:ReadCount 2 'the tree is read once for the snapshot, once to re-check'
$script:WuReadTree = $savedRead

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

Reset-Test -Au $auAll
$null = Invoke-WuJob
$script:Log.Clear()
# -ReportOnly with -Restore is a preview: nothing is written.
$script:Log.Clear()
$r = Invoke-WuJob -Restore -ReportOnly
Assert-Same $r.ExitCode 0 'restore preview exit'
Assert-Same $r.Status 'would-restore' 'restore preview status'
Assert-Same $script:Log.Count 0 'restore preview writes nothing'
Assert-True ($r.Backup -like 'backup-*.json') 'restore preview names the backup'

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

# Registry.pol with NoAutoUpdate + AUOptions alongside other entries (Defender, TargetReleaseVersion, **del.ScheduledInstallDay):
# only NoAutoUpdate and AUOptions under AU are stripped; all other PReg records remain byte-identical; Registry.pol is backed up and restored.
$auPolKey = 'Software\Policies\Microsoft\Windows\WindowsUpdate\AU'
$wuPolKey = 'Software\Policies\Microsoft\Windows\WindowsUpdate'
$defPolKey = 'SOFTWARE\Policies\Microsoft\Windows Defender'
$recDefender = New-PRegRecord $defPolKey 'DisableAntiSpyware' 4 ([BitConverter]::GetBytes([uint32]0))
$recTrv = New-PRegRecord $wuPolKey 'TargetReleaseVersion' 4 ([BitConverter]::GetBytes([uint32]1))
$recDelDirective = New-PRegRecord $auPolKey '**del.ScheduledInstallDay' 1 ([Text.Encoding]::Unicode.GetBytes("`0"))
$recNoAuto = New-PRegRecord $auPolKey 'NoAutoUpdate' 4 ([BitConverter]::GetBytes([uint32]1))
$recAuOpt = New-PRegRecord $auPolKey 'AUOptions' 4 ([BitConverter]::GetBytes([uint32]1))
$polWithAll = New-PRegFile @($recDefender, $recNoAuto, $recTrv, $recAuOpt, $recDelDirective)
$expectedFiltered = New-PRegFile @($recDefender, $recTrv, $recDelDirective)

# Drift detected even when registry values were already cleared, if Registry.pol still holds NoAutoUpdate/AUOptions.
Reset-Test -PolBytes $polWithAll
$r = Invoke-WuJob -ReportOnly
Assert-Same $r.ExitCode 1 'pol-only report-only drift exit'
Assert-Same $r.Status 'drift' 'pol-only report-only status'
Assert-Same $r.Before.NoAutoUpdate 1 'pol-only before NoAutoUpdate'
Assert-Same $r.Before.AUOptions 1 'pol-only before AUOptions'

# Live run: backs up Registry.pol + registry, writes filtered Registry.pol before deleting registry keys, preserves other records byte-for-byte.
Reset-Test -Au $auAll -PolBytes $polWithAll
$r = Invoke-WuJob
Assert-Same $r.ExitCode 0 'pol+reg run exit'
Assert-Same $r.Status 'removed' 'pol+reg run status'
Assert-True ($null -eq $r.After.NoAutoUpdate -and $null -eq $r.After.AUOptions) 'pol+reg after is absent'
Assert-Same ($script:FakePolBytes.Length) ($expectedFiltered.Length) 'filtered Registry.pol exact byte length'
Assert-Same ([Convert]::ToBase64String($script:FakePolBytes)) ([Convert]::ToBase64String($expectedFiltered)) 'filtered Registry.pol exact bytes preserved'
Assert-True ($script:Log[0] -eq 'protect' -and $script:Log[1] -like 'writepol *' -and $script:Log[2] -eq 'delete AU\NoAutoUpdate') 'writepol happens before registry deletes'

# Backup contains original Registry.pol base64 + polTargets, and Restore splices only NoAutoUpdate/AUOptions back while preserving new unrelated entries.
$polBakFile = @(Backups)[0]
$polDoc = Get-Content -LiteralPath $polBakFile.FullName -Raw | ConvertFrom-Json
Assert-Same $polDoc.registryPol.present $true 'backup marks registryPol present'
Assert-Same $polDoc.registryPol.base64 ([Convert]::ToBase64String($polWithAll)) 'backup stores exact original Registry.pol bytes'
Assert-Same $polDoc.polTargets.NoAutoUpdate.present $true 'backup records polTargets.NoAutoUpdate'
Assert-Same $polDoc.polTargets.AUOptions.data 1 'backup records polTargets.AUOptions data'
$recNewPostReset = New-PRegRecord $defPolKey 'PUAProtection' 4 ([BitConverter]::GetBytes([uint32]1))
$script:FakePolBytes = New-PRegFile @($recDefender, $recTrv, $recDelDirective, $recNewPostReset)
$script:Log.Clear()
$r = Invoke-WuJob -Restore
Assert-Same $r.ExitCode 0 'pol restore exit'
Assert-Same $r.Status 'restored' 'pol restore status'
$restoredSplit = Split-WuPolTargets $script:FakePolBytes
Assert-Same $restoredSplit.targets.NoAutoUpdate.data 1 'restore splices NoAutoUpdate back into Registry.pol'
Assert-Same $restoredSplit.targets.AUOptions.data 1 'restore splices AUOptions back into Registry.pol'
Assert-Same ([Convert]::ToBase64String($restoredSplit.filteredBytes)) ([Convert]::ToBase64String((New-PRegFile @($recDefender, $recTrv, $recDelDirective, $recNewPostReset)))) 'restore preserves post-reset Registry.pol entries byte-for-byte'
Assert-Same $r.After.NoAutoUpdate 1 'restore puts back NoAutoUpdate'
Assert-Same $r.After.AUOptions 1 'restore puts back AUOptions'

# Registry.pol containing ONLY NoAutoUpdate leaves a valid 8-byte empty PReg header.
Reset-Test -PolBytes (New-PRegFile @($recNoAuto))
$r = Invoke-WuJob
Assert-Same $r.ExitCode 0 'single-record pol exit'
Assert-Same $r.Status 'removed' 'single-record pol status'
Assert-Same ($script:FakePolBytes.Length) 8 'empty PReg header is 8 bytes'
Assert-Same (Invoke-WuJob -ReportOnly).Status 'unchanged' 'clean pol reports unchanged'

# Malformed Registry.pol (truncated OR missing ';' separator) fails closed without touching registry or Registry.pol.
$badPol = [byte[]](0x50, 0x52, 0x65, 0x67, 0x01, 0x00, 0x00, 0x00, 0x5B, 0x00)
Reset-Test -Au $auAll -PolBytes $badPol
$r = Invoke-WuJob
Assert-Same $r.ExitCode 2 'malformed pol exit'
Assert-Same $r.Status 'failed' 'malformed pol status'
Assert-Same $r.Error 'malformed Registry.pol' 'malformed pol error'
Assert-True (-not ($script:Log -match 'delete|writepol')) 'malformed pol touches nothing'
Assert-Same (Names 'AU') 'NoAutoUpdate,AUOptions,ScheduledInstallDay,Blob' 'malformed pol keeps registry'

# Corrupt ';' separator after key\0 in PReg entry also throws 'malformed Registry.pol'.
$badSepRec = [byte[]](New-PRegRecord $defPolKey 'X' 4 ([BitConverter]::GetBytes([uint32]1)))
$sepOffset = 2 + ($defPolKey.Length * 2) + 2
$badSepRec[$sepOffset] = 0x00
Reset-Test -Au $auAll -PolBytes (New-PRegFile @($badSepRec))
$r = Invoke-WuJob
Assert-Same $r.ExitCode 2 'missing semicolon pol exit'
Assert-Same $r.Error 'malformed Registry.pol' 'missing semicolon pol error'
Assert-True (-not ($script:Log -match 'delete|writepol')) 'missing semicolon touches nothing'

# Non-DWORD target entry in Registry.pol fails closed with 'unsupported target type in Registry.pol'.
$strNoAuto = New-PRegRecord $auPolKey 'NoAutoUpdate' 1 ([Text.Encoding]::Unicode.GetBytes("1`0"))
Reset-Test -Au $auAll -PolBytes (New-PRegFile @($strNoAuto))
$r = Invoke-WuJob
Assert-Same $r.ExitCode 2 'non-dword pol target exit'
Assert-Same $r.Status 'failed' 'non-dword pol target status'
Assert-Same $r.Error 'unsupported target type in Registry.pol' 'non-dword pol target error'
Assert-True (-not ($script:Log -match 'delete|writepol')) 'non-dword pol target touches nothing'

# Live registry value takes precedence over differing Registry.pol value in Before and targets backup.
Reset-Test -Au @((New-V 'AUOptions' 'DWord' 3)) -PolBytes (New-PRegFile @($recAuOpt))
$r = Invoke-WuJob
Assert-Same $r.ExitCode 0 'differing reg vs pol exit'
Assert-Same $r.Before.AUOptions 3 'live registry value wins in Before'
$diffDoc = Get-Content -LiteralPath (@(Backups)[0].FullName) -Raw | ConvertFrom-Json
Assert-Same $diffDoc.targets.AUOptions.data 3 'targets backup records live registry value'
Assert-Same $diffDoc.polTargets.AUOptions.data 1 'polTargets backup records Registry.pol value'

# Pol-only restore reports restored Registry.pol value in After; failed persist exits 2.
Reset-Test -PolBytes (New-PRegFile @($recNoAuto))
$null = Invoke-WuJob
$r = Invoke-WuJob -Restore
Assert-Same $r.ExitCode 0 'pol-only restore exit'
Assert-Same $r.After.NoAutoUpdate 1 'pol-only restore After reports NoAutoUpdate'
$savedWritePol = $script:WuWritePolBytes
$script:WuWritePolBytes = { param([byte[]]$Bytes) }   # drops write silently
$script:FakePolBytes = New-PRegFile @()
$r = Invoke-WuJob -Restore
Assert-Same $r.ExitCode 2 'pol restore verify failure exit'
Assert-Same $r.Status 'failed' 'pol restore verify failure status'
Assert-Same $r.Error 'restored Registry.pol value missing or differs' 'pol restore verify failure error'
$script:WuWritePolBytes = $savedWritePol

# Registry.pol changed between snapshot and write aborts cleanly without touching anything.
$savedReadPol = $script:WuReadPolBytes
$script:PolReadCount = 0
$script:WuReadPolBytes = {
    $script:PolReadCount++
    if ($script:PolReadCount -eq 2) { return (New-PRegFile @($recDefender)) }
    return $polWithAll
}
Reset-Test -Au $auAll -PolBytes $polWithAll
$r = Invoke-WuJob
Assert-Same $r.ExitCode 2 'changed pol TOCTOU exit'
Assert-Same $r.Status 'failed' 'changed pol TOCTOU status'
Assert-True (-not ($script:Log -match 'delete|writepol')) 'changed pol TOCTOU deletes/writes nothing'
$script:WuReadPolBytes = $savedReadPol

# Conflicting **del.NoAutoUpdate directive in Registry.pol fails closed without touching registry or Registry.pol.
$recDelNoAuto = New-PRegRecord $auPolKey '**del.NoAutoUpdate' 1 ([Text.Encoding]::Unicode.GetBytes("`0"))
Reset-Test -Au $auAll -PolBytes (New-PRegFile @($recDelNoAuto))
$r = Invoke-WuJob
Assert-Same $r.ExitCode 2 'conflicting del directive exit'
Assert-Same $r.Status 'failed' 'conflicting del directive status'
Assert-Same $r.Error 'conflicting delete directive in Registry.pol' 'conflicting del directive error'
Assert-True (-not ($script:Log -match 'delete|writepol')) 'conflicting del directive touches nothing'

Remove-Item -LiteralPath $tmpRoot -Recurse -Force
Write-Output 'reset-windowsupdate-auto-policy tests passed'
