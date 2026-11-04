$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
. (Join-Path $PSScriptRoot '../../windows/packages/storage-maintenance/Invoke-StorageMaintenance.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Throws($Code) { try { & $Code; throw 'did not throw' } catch { if ($_.Exception.Message -eq 'did not throw') { throw } } }
$a = Get-SmArguments
Assert ($a.Mode -eq 'Report' -and -not $a.RemoveProfiles) 'safe defaults'
Throws { Get-SmArguments -ProfileAgeDays '29' }
Throws { Get-SmArguments -TempAgeDays '0' }
Throws { Get-SmArguments -RemoveProfiles 'yes' }
$now = [datetime]::UtcNow
$p = [pscustomobject]@{ SID='S-1-5-21-1-2-3-1001'; LocalPath='C:\Users\old'; Loaded=$false; Special=$false; LastUseTime=$now.AddDays(-200) }
Assert (Test-SmProfile $p 180 @() $now).Eligible 'old profile'
$p.Loaded=$true
Assert (-not (Test-SmProfile $p 180 @() $now).Eligible) 'loaded protected'
$p.Loaded=$false; $p.LastUseTime=$null
Assert (-not (Test-SmProfile $p 180 @() $now).Eligible) 'unknown age protected'
$p.LastUseTime=$now.AddDays(-200)
Assert (-not (Test-SmProfile $p 180 @('S-1-5-21-1-2-3-1001') $now).Eligible) 'explicit exclusion'
$root=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
$null=New-Item -ItemType Directory -Path $root
try {
 $old=Join-Path $root 'old.tmp'; $new=Join-Path $root 'new.tmp'
 Set-Content -LiteralPath $old -Value 'old'; Set-Content -LiteralPath $new -Value 'new'
 (Get-Item -LiteralPath $old).LastWriteTimeUtc=$now.AddDays(-10)
 Assert (Test-SmSafePath $old $root) 'safe descendant'
 Assert (-not (Test-SmSafePath $root $root)) 'root cannot be deleted'
 Assert (-not (Test-SmSafePath ($root+'-escape/file') $root)) 'prefix escape'
 $s=Get-SmScan @($root) 1 30 7
 Assert $s.Partial 'file bound reported'
 $s=Get-SmScan @($root) 100 30 7
 Assert ($s.Files.Count -eq 2) 'file scan'
 $script:SmGuards={ [pscustomobject]@{ Safe=$true; Light=$false; Reasons=@() } }
 $script:SmPrepareReport={ 'test-report.json' }; $script:SmAcquire={ $true }; $script:SmRelease={}; $script:SmVolumes={ @() }; $script:SmEvidence={ @{} }
 $script:SmDiagnosticRoots={ @() }; $script:SmProfiles={ @() }; $script:SmRoots={ @($root) }; $script:SmUi={ param($Step) 'noUser' }
 $r=Invoke-SmMaintenance (Get-SmArguments)
 Assert (Test-Path -LiteralPath $old) 'report does not delete'
 Assert ($r.Actions.Count -eq 0) 'report zero actions'
 $r=Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup)
 Assert (-not (Test-Path -LiteralPath $old)) 'old temp deleted'
 Assert (Test-Path -LiteralPath $new) 'recent preserved'
 Set-Content -LiteralPath $old -Value 'old'; (Get-Item $old).LastWriteTimeUtc=$now.AddDays(-10)
 $script:SmGuards={ [pscustomobject]@{ Safe=$false; Light=$true; Reasons=@('setup') } }
 $r=Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup)
 Assert ($r.Scan.Partial -and (Test-Path $old)) 'setup light and no mutation'
 $script:SmGuards={ [pscustomobject]@{ Safe=$true; Light=$false; Reasons=@() } }
 $script:SmDelete={ throw 'locked file' }
 $r=Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup)
 Assert ($r.Actions[0].Error -match 'locked file') 'deletion failure reported'
 Assert (Test-Path $old) 'failed deletion leaves file'
 $script:guardCalls=0
 $script:SmGuards={ $script:guardCalls++; [pscustomobject]@{Safe=($script:guardCalls -eq 1);Light=$false;Reasons=@('changed')} }
 $r=Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup)
 Assert ($r.Actions[0].Error -match 'guard changed') 'guard rechecked immediately before deletion'
 $script:SmUi={ throw 'notification unavailable' }
 $script:SmGuards={ [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
 $r=Invoke-SmMaintenance (Get-SmArguments)
 Assert ($r.Notifications[0] -match 'failed:') 'UI failure distinct from report success'
 $link=Join-Path $root 'link'
 $null=New-Item -ItemType SymbolicLink -Path $link -Target ([IO.Path]::GetTempPath())
 Assert (-not (Test-SmSafePath (Join-Path $link 'anything') $root)) 'symlink ancestor blocked'
 $scan=Get-SmScan @($root) 100 30 7
 Assert ($scan.SkippedReparseOrCloud -ge 1) 'symlink not traversed'
 # A changed profile cannot be deleted after the first inventory.
 $script:profileReads=0; $script:profileRemovals=0
 $script:SmProfileHiveLoaded={ $false }
 $script:MockProfile=$p; $script:MockProfile.LastUseTime=$now.AddDays(-200); $script:MockProfile.Loaded=$false
 $script:SmProfiles={ $script:profileReads++; if($script:profileReads -gt 1) { $script:MockProfile.Loaded=$true }; @($script:MockProfile) }
 $realScan=${function:Get-SmScan}
 function Get-SmScan { [pscustomobject]@{Files=@();TopFiles=@();TopFolders=@();Partial=$false;EntriesVisited=0;SkippedReparseOrCloud=0;Errors=@();Seconds=0} }
 $script:SmRemoveProfile={ $script:profileRemovals++ }
 $r=Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup -RemoveProfiles true)
 Assert ($script:profileRemovals -eq 0) 'newly loaded profile protected at deletion'
 Assert ($r.Actions[0].Error -match 'revalidation') ('profile recheck reported: '+($r | ConvertTo-Json -Depth 4 -Compress))
 ${function:Get-SmScan}=$realScan
 $r.Errors=@(('x'*10000)); $summary=ConvertTo-SmSummary $r 'report.json'
 Assert ([Text.Encoding]::UTF8.GetByteCount($summary) -le 8000) 'stdout summary byte bound'
 Assert (($summary | ConvertFrom-Json).ReportPath -eq 'report.json') 'summary remains JSON'
 $script:SmPrepareReport={ throw 'Evidence destination denied' }
 $r=Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup)
 Assert ($r.Status -eq 'failed' -and $r.Actions.Count -eq 0) 'evidence failure blocks cleanup'
 $script:SmAcquire={ $false }
 $r=Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup)
 Assert ($r.Status -eq 'busy') 'mutex exclusion'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
Write-Output 'storage-maintenance tests passed'
