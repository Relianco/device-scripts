# restore-windowsupdate-auto-policy module. The registry is a fake behind the module's seams; backups are real files in a temp directory.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resetPath = Join-Path $repoRoot 'windows/jobs/reset-windowsupdate-auto-policy.ps1'
$restorePath = Join-Path $repoRoot 'windows/jobs/restore-windowsupdate-auto-policy.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ("$Actual" -ne "$Expected") { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("wurestore-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpRoot

# Make a real backup with the reset module (fake registry), then load the restore module over it.
. $resetPath
$script:WuBackupDir = Join-Path $tmpRoot 'backups'
$script:Tree = @(@{ path = 'AU'; values = @(@{ name = 'NoAutoUpdate'; kind = 'DWord'; data = 1 }, @{ name = 'AUOptions'; kind = 'DWord'; data = 1 }, @{ name = 'Keep'; kind = 'DWord'; data = 7 }) })
$script:WuReadTree = { $script:Tree }
$script:WuDeleteValue = { param($Rel, $Name) $script:Tree[0].values = @($script:Tree[0].values | Where-Object { $_.name -ne $Name }) }
$script:WuProtectDir = { param($Path) }
$made = Invoke-WuJob
Assert-Same $made.Status 'removed' 'backup made by the reset module'
$backupDir = $script:WuBackupDir

. $restorePath
$script:WuBackupDir = $backupDir
function Reset-Test { param($Present = @{}) $script:Reg = [ordered]@{}; foreach ($k in $Present.Keys) { $script:Reg[$k] = $Present[$k] }; $script:Log = [Collections.Generic.List[string]]::new() }
$script:WuReadTargets = { $c = [ordered]@{}; foreach ($k in $script:Reg.Keys) { $c[$k] = $script:Reg[$k] }; $c }
$script:WuSetValue = { param($Rel, $Name, $Kind, $Data) $script:Log.Add("set $Rel\$Name $Kind $Data"); $script:Reg[$Name] = $Data }

# Restore: only the two values, with their kind, from the newest backup.
Reset-Test -Present @{ Keep = 7 }
$r = Invoke-WuRestoreJob
Assert-Same $r.ExitCode 0 'restore exit'
Assert-Same $r.Status 'restored' 'restore status'
Assert-Same ($script:Log -join ',') 'set AU\NoAutoUpdate DWord 1,set AU\AUOptions DWord 1' 'only the two values written'
Assert-Same $r.After.NoAutoUpdate 1 'after NoAutoUpdate'
Assert-True ($null -eq $r.Before.NoAutoUpdate) 'before is absent'
Assert-Same $r.Backup (@(Get-ChildItem -LiteralPath $backupDir -File)[0].Name) 'line names the backup'
$line = ConvertTo-WuJobLine $r | ConvertFrom-Json
Assert-Same $line.job 'restore-windowsupdate-auto-policy' 'job name'

# -ReportOnly: names the backup, writes nothing.
Reset-Test
$r = Invoke-WuRestoreJob -ReportOnly
Assert-Same $r.ExitCode 0 'report exit'
Assert-Same $r.Status 'would-restore' 'report status'
Assert-Same $script:Log.Count 0 'report writes nothing'
Assert-True ($r.Backup -like 'backup-*.json') 'report names the backup'

# No backup: fails cleanly, writes nothing.
$script:WuBackupDir = Join-Path $tmpRoot 'none'
Reset-Test
$r = Invoke-WuRestoreJob
Assert-Same $r.ExitCode 2 'no backup exit'
Assert-Same $r.Status 'failed' 'no backup status'
Assert-Same $r.Error 'no backup found' 'no backup error'
Assert-Same $script:Log.Count 0 'no backup writes nothing'

# The restore module never deletes, and shares its target list with the reset module.
$source = Get-Content -LiteralPath $restorePath -Raw
Assert-True ($source -notmatch 'DeleteValue|DeleteSubKey|Remove-Item') 'restore module has no delete'
Assert-True ($source -match "\`$script:WuTargets = @\('NoAutoUpdate', 'AUOptions'\)") 'target list is exactly the two values'

Remove-Item -LiteralPath $tmpRoot -Recurse -Force
Write-Output 'restore-windowsupdate-auto-policy tests passed'
