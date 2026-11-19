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
$script:WuReadPolBytes = { return $null }
$script:WuWritePolBytes = { param($Bytes) }
$script:WuBackupDir = Join-Path $tmpRoot 'backups'
$script:Tree = @(@{ path = 'AU'; values = @(@{ name = 'NoAutoUpdate'; kind = 'DWord'; data = 1 }, @{ name = 'AUOptions'; kind = 'DWord'; data = 1 }, @{ name = 'Keep'; kind = 'DWord'; data = 7 }) })
$script:WuReadTree = { $script:Tree }
$script:WuDeleteValue = { param($Rel, $Name) $script:Tree[0].values = @($script:Tree[0].values | Where-Object { $_.name -ne $Name }) }
$script:WuProtectDir = { param($Path) }
$made = Invoke-WuJob
Assert-Same $made.Status 'removed' 'backup made by the reset module'
$backupDir = $script:WuBackupDir

. $restorePath
$script:WuReadPolBytes = { return $null }
$script:WuWritePolBytes = { param($Bytes) }
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

# Restore splices backed-up target PReg records into live Registry.pol while preserving unrelated entries added later.
function New-TestPRegRecord {
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
function New-TestPRegFile {
    param([object[]]$Records = @())
    $ms = [IO.MemoryStream]::new()
    $ms.Write([Text.Encoding]::ASCII.GetBytes('PReg'), 0, 4)
    $ms.Write([BitConverter]::GetBytes([uint32]1), 0, 4)
    foreach ($rec in $Records) { $b = [byte[]]$rec; $ms.Write($b, 0, $b.Length) }
    return ,($ms.ToArray())
}
$auPolKey = 'Software\Policies\Microsoft\Windows\WindowsUpdate\AU'
$recNoAuto = New-TestPRegRecord $auPolKey 'NoAutoUpdate' 4 ([BitConverter]::GetBytes([uint32]1))
$recOtherLive = New-TestPRegRecord 'SOFTWARE\Policies\Microsoft\Windows Defender' 'PUAProtection' 4 ([BitConverter]::GetBytes([uint32]1))
$livePolBeforeRestore = New-TestPRegFile @($recOtherLive)
$expectedPolAfterRestore = New-TestPRegFile @($recOtherLive, $recNoAuto)
$polBackupDir = Join-Path $tmpRoot 'pol-backups'
$null = New-Item -ItemType Directory -Path $polBackupDir
$polBackupFile = Join-Path $polBackupDir 'backup-20261119T120000000Z-12345678.json'
@{
    schemaVersion = 1; createdUtc = '2026-11-19T12:00:00Z'; key = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    targets = @{ NoAutoUpdate = @{ present = $true; kind = 'DWord'; data = 1 }; AUOptions = @{ present = $false } }
    polTargets = @{ NoAutoUpdate = @{ present = $true; kind = 'DWord'; data = 1; rawBase64 = [Convert]::ToBase64String($recNoAuto) }; AUOptions = @{ present = $false } }
    tree = @()
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $polBackupFile -Encoding UTF8
$script:WuBackupDir = $polBackupDir
$script:LivePolBytes = $livePolBeforeRestore
$script:WuReadPolBytes = { ,$script:LivePolBytes }
$script:WuWritePolBytes = { param([byte[]]$Bytes) $script:Log.Add("writepol $($Bytes.Length)"); $script:LivePolBytes = $Bytes }
Reset-Test
$r = Invoke-WuRestoreJob
Assert-Same $r.ExitCode 0 'pol restore exit'
Assert-Same $r.Status 'restored' 'pol restore status'
Assert-Same ([Convert]::ToBase64String($script:LivePolBytes)) ([Convert]::ToBase64String($expectedPolAfterRestore)) 'restore splices NoAutoUpdate and keeps existing live entries'
Assert-Same ($script:Log -join ',') "writepol $($expectedPolAfterRestore.Length),set AU\NoAutoUpdate DWord 1" 'restore writes spliced Registry.pol and registry value'

# Pol-only backup: After reports restored Registry.pol value, selective replace preserves unbacked-up AUOptions, and silent drop fails with exit 2.
$recAuOptLive = New-TestPRegRecord $auPolKey 'AUOptions' 4 ([BitConverter]::GetBytes([uint32]4))
$livePolWithAuOpt = New-TestPRegFile @($recOtherLive, $recAuOptLive)
$polOnlyFile = Join-Path $polBackupDir 'backup-20261119T120500000Z-abcdef12.json'
@{
    schemaVersion = 1; createdUtc = '2026-11-19T12:05:00Z'; key = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    targets = @{ NoAutoUpdate = @{ present = $false }; AUOptions = @{ present = $false } }
    polTargets = @{ NoAutoUpdate = @{ present = $true; kind = 'DWord'; data = 1; rawBase64 = [Convert]::ToBase64String($recNoAuto) }; AUOptions = @{ present = $false } }
    tree = @()
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $polOnlyFile -Encoding UTF8
$script:LivePolBytes = $livePolWithAuOpt
Reset-Test
$r = Invoke-WuRestoreJob
Assert-Same $r.ExitCode 0 'pol-only restore exit'
Assert-Same $r.After.NoAutoUpdate 1 'pol-only restore After reports NoAutoUpdate'
Assert-Same $r.After.AUOptions 4 'pol-only restore preserves unbacked-up AUOptions in live Registry.pol'
$script:LivePolBytes = $livePolBeforeRestore
$script:WuWritePolBytes = { param([byte[]]$Bytes) }
$r = Invoke-WuRestoreJob
Assert-Same $r.ExitCode 2 'pol restore verify failure exit'
Assert-Same $r.Status 'failed' 'pol restore verify failure status'
Assert-Same $r.Error 'restored Registry.pol value missing or differs' 'pol restore verify failure error'

Remove-Item -LiteralPath $tmpRoot -Recurse -Force
Write-Output 'restore-windowsupdate-auto-policy tests passed'
