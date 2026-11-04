$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
. (Join-Path $PSScriptRoot '../../windows/packages/storage-maintenance/Invoke-StorageMaintenance.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$script:SmScanGuard={ [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
function Throws($Code) { try { & $Code; throw 'did not throw' } catch { if ($_.Exception.Message -eq 'did not throw') { throw } } }
# Profile age sources are independent: registry pair is primary, not hive file time.
function New-AgePair($Date) {
 $ft=[uint64]$Date.ToFileTimeUtc()
 @{ Low=[uint32]($ft -band [uint64]4294967295); High=[uint32]($ft -shr 32) }
}
$ageNow=[datetime]::SpecifyKind([datetime]'2026-11-04T12:00:00',[DateTimeKind]::Utc)
$zeroLow=ConvertFrom-SmFileTimePair 0 30000000 $ageNow
Assert ($zeroLow.State -eq 'valid') 'zero low DWORD valid'
$smallLow=ConvertFrom-SmFileTimePair '00000015' 30000000 $ageNow
Assert ($smallLow.TimestampUtc.ToFileTimeUtc() -eq (([int64]30000000 -shl 32)+15)) 'leading zero low DWORD stays decimal'
$signed=ConvertFrom-SmFileTimePair -1 30000000 $ageNow
Assert ($signed.TimestampUtc.ToFileTimeUtc() -eq (([int64]30000000 -shl 32)+4294967295)) 'signed DWORD normalized'
Assert ((ConvertFrom-SmFileTimePair $null 30000000 $ageNow).State -eq 'missing') 'missing low is not zero'
Assert ((ConvertFrom-SmFileTimePair 0 0 $ageNow).State -eq 'zero') 'zero combined rejected'
Assert ((ConvertFrom-SmFileTimePair 'bad' 1 $ageNow).State -eq 'malformed') 'malformed DWORD rejected'
Assert ((ConvertFrom-SmFileTimePair 0 4294967295 $ageNow).State -eq 'invalid') 'overflow FILETIME rejected'
$future=New-AgePair ($ageNow.AddDays(1))
Assert ((ConvertFrom-SmFileTimePair $future.Low $future.High $ageNow).State -eq 'future') 'future FILETIME rejected'
function New-TestAgeEvidence($Now) {
 $l=New-AgePair ($Now.AddDays(-300)); $u=New-AgePair ($Now.AddDays(-200))
 [pscustomobject]@{Registry=[pscustomobject]@{ReadState='ok';IdentityMatches=$true;Raw=@{};Load=(ConvertFrom-SmFileTimePair $l.Low $l.High $Now);Unload=(ConvertFrom-SmFileTimePair $u.Low $u.High $Now);Cleanup=(ConvertFrom-SmFileTimePair $null $null $Now)};Identity=[pscustomobject]@{Resolved=$true;Account='EXAMPLE\old'};Sessions=[pscustomobject]@{Known=$true;Sids=@();CurrentSid='S-1-5-18'};Hives=[pscustomobject]@{Known=$true;Loaded=$false;ClassesLoaded=$false};NtUser=[pscustomobject]@{DatUtc=$Now;ManUtc=$null;Errors=@()};Events=[pscustomobject]@{ProbeComplete=$true;Recent=@();Truncated=$false;Error=$null;Coverage='unknown'};Errors=@()}
}
$ageProfile=[pscustomobject]@{SID='S-1-5-21-1-2-3-1001';LocalPath='C:\Users\old';Loaded=$false;Special=$false;LastUseTime=$ageNow.AddDays(-90);Status=0;RoamingConfigured=$false;RoamingPreference=$false;refCount=0}
$ev=New-TestAgeEvidence $ageNow
Assert (Test-SmProfile $ageProfile 60 @() $ageNow $ev).Eligible 'coherent old pair survives servicing NTUSER touch'
$ageProfile.LastUseTime=$ageNow
Assert ((Test-SmProfile $ageProfile 60 @() $ageNow $ev).Decision -eq 'ReviewTimestampConflict') 'recent CIM conflicts with old pair'
$ageProfile.LastUseTime=$ageNow.AddDays(-90)
$ev.Registry.Load=$ev.Registry.Unload; $ev.Registry.Unload=(New-TestAgeEvidence $ageNow).Registry.Load
Assert ((Test-SmProfile $ageProfile 60 @() $ageNow $ev).Decision -eq 'ReviewInconsistent') 'load newer than unload is review'
$ev=New-TestAgeEvidence $ageNow; $cut=New-AgePair ($ageNow.AddDays(-60)); $ev.Registry.Unload=ConvertFrom-SmFileTimePair $cut.Low $cut.High $ageNow
Assert (-not (Test-SmProfile $ageProfile 60 @() $ageNow $ev).Eligible) 'cutoff equality retained'
$ev=New-TestAgeEvidence $ageNow; $ev.Hives.ClassesLoaded=$true
Assert (-not (Test-SmProfile $ageProfile 60 @() $ageNow $ev).Eligible) 'SID Classes hive protected'
$ev=New-TestAgeEvidence $ageNow; $ev.Sessions.Sids=@($ageProfile.SID)
Assert (-not (Test-SmProfile $ageProfile 60 @() $ageNow $ev).Eligible) 'disconnected or active session SID protected'
$ev=New-TestAgeEvidence $ageNow; $ev.Events.Recent=@([pscustomobject]@{Sid=$ageProfile.SID;LogonType=10;TimeUtc=$ageNow})
Assert ((Test-SmProfile $ageProfile 60 @() $ageNow $ev).Decision -eq 'KeepRecentConfirmed') 'positive interactive event veto'
$ev=New-TestAgeEvidence $ageNow; $ev.Registry.Load=ConvertFrom-SmFileTimePair $null 1 $ageNow
Assert (-not (Test-SmProfile $ageProfile 60 @() $ageNow $ev).Eligible) 'CIM and file-only age cannot delete'
$ev=New-TestAgeEvidence $ageNow; $ev.Events.ProbeComplete=$false
Assert (-not (Test-SmProfile $ageProfile 60 @() $ageNow $ev).Eligible) 'failed event query requires review'
$ev=New-TestAgeEvidence $ageNow; $ev.Sessions.Known=$false
Assert (-not (Test-SmProfile $ageProfile 60 @() $ageNow $ev).Eligible) 'unknown sessions require review'
$ev=New-TestAgeEvidence $ageNow; $recent=New-AgePair $ageNow; $ev.Registry.Cleanup=ConvertFrom-SmFileTimePair $recent.Low $recent.High $ageNow
Assert ((Test-SmProfile $ageProfile 60 @() $ageNow $ev).Decision -eq 'ReviewPolicyTracking') 'cleanup-check date remains policy evidence'
foreach($state in @(1,2,4,8,16)) { $ageProfile.Status=$state; Assert (-not (Test-SmProfile $ageProfile 60 @() $ageNow (New-TestAgeEvidence $ageNow)).Eligible) 'temporary/roaming/mandatory/corrupt/unknown status protected' }
$ageProfile.Status=0; $ageProfile.RoamingConfigured=$true
Assert (-not (Test-SmProfile $ageProfile 60 @() $ageNow (New-TestAgeEvidence $ageNow)).Eligible) 'roaming configured protected'
$ageProfile.RoamingConfigured=$false
# XML parsing uses TargetUserSid; all interactive/cached/unlock types are keep vetoes.
$script:FakeEvents=@()
foreach($type in @(2,7,10,11,12,13,3)) {
 $record=[pscustomobject]@{TimeCreated=$ageNow;Xml="<Event><EventData><Data Name='SubjectUserSid'>S-1-5-18</Data><Data Name='TargetUserSid'>$($ageProfile.SID)</Data><Data Name='LogonType'>$type</Data></EventData></Event>"}
 $record | Add-Member ScriptMethod ToXml { $this.Xml }; $script:FakeEvents+=$record
}
function Get-WinEvent { [CmdletBinding()]param($FilterHashtable,$MaxEvents); $script:FakeEvents }
$context=Get-SmProfileContext 60 $ageNow
Assert ($context.Events.ProbeComplete -and $context.Events.Recent.Count -eq 6) 'bounded event parser accepts only requested target interactive types'
Assert (@($context.Events.Recent | Where-Object {$_.Sid -ne $ageProfile.SID}).Count -eq 0) 'subject SID not used for target activity'
$script:FakeEvents=@($script:FakeEvents[0])*2001
$context=Get-SmProfileContext 60 $ageNow
Assert $context.Events.Truncated 'event cap cannot imply complete activity probe'
Remove-Item Function:Get-WinEvent
$a = Get-SmArguments
Assert ($a.Mode -eq 'Report' -and $a.ProfileAgeDays -eq 60 -and -not $a.RemoveProfiles) 'safe defaults'
Throws { Get-SmArguments -ProfileAgeDays '29' }
Throws { Get-SmArguments -TempAgeDays '0' }
Throws { Get-SmArguments -RemoveProfiles 'yes' }
$now = [datetime]::UtcNow
$p = [pscustomobject]@{ SID='S-1-5-21-1-2-3-1001'; LocalPath='C:\Users\old'; Loaded=$false; Special=$false; LastUseTime=$now.AddDays(-200);Status=0;RoamingConfigured=$false;RoamingPreference=$false;refCount=0 }
Assert (Test-SmProfile $p 180 @() $now (New-TestAgeEvidence $now)).Eligible 'old profile'
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
 $script:FixtureAgeEvidence=New-TestAgeEvidence $now; $script:SmProfileContext={ [pscustomobject]@{} }; $script:SmProfileEvidence={ $script:FixtureAgeEvidence }; $script:SmDiagnosticRoots={ @() }; $script:SmProfiles={ @() }; $script:SmRoots={ @($root) }; $script:SmUi={ param($Step) 'noUser' }
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
 # The cleanup root itself can be ordinary while an ancestor was replaced.
 $outside=Join-Path $root 'outside'; $null=New-Item -ItemType Directory -Path $outside
 $outsideTemp=Join-Path $outside 'Temp'; $null=New-Item -ItemType Directory -Path $outsideTemp
 $outsideFile=Join-Path $outsideTemp 'keep'; Set-Content -LiteralPath $outsideFile -Value 'keep'
 $ancestor=Join-Path $root 'ancestor'; $null=New-Item -ItemType SymbolicLink -Path $ancestor -Target $outside
 Assert (-not (Test-SmSafePath (Join-Path $ancestor 'Temp/keep') (Join-Path $ancestor 'Temp'))) 'junction above temp cleanup root blocked'
 # A scan can validate the filesystem root without authorizing root deletion.
 Assert (Test-SmScanDirectory ([IO.Path]::GetPathRoot($root))) 'volume root is valid for scanning'
 $profile=Join-Path $root 'profile'; $profileTemp=Join-Path $profile 'AppData/Local/Temp'
 $null=New-Item -ItemType Directory -Path $profileTemp -Force
 Set-Content -LiteralPath (Join-Path $profileTemp 'only.tmp') -Value 'temporary bytes'
 $scan=Get-SmScan @($profileTemp,$profile) 100 30 7
 $size=Get-SmProfileSize $scan $profile
 Assert ($size.LogicalBytes -eq (Get-Item (Join-Path $profileTemp 'only.tmp')).Length -and -not $size.Partial) 'profile includes temp queued as another scan root'
 $scan.Errors=@('unreadable subtree')
 Assert (Get-SmProfileSize $scan $profile).Partial 'enumeration errors make profile size partial'
 $scan.Errors=@(); $scan.SkippedReparseOrCloud=1
 Assert (Get-SmProfileSize $scan $profile).Partial 'omitted cloud subtree makes profile size partial'
 $many=Join-Path $root 'many'; $null=New-Item -ItemType Directory -Path $many
 1..140 | ForEach-Object { Set-Content -LiteralPath (Join-Path $many "$_.tmp") -Value 'sample' }
 $script:scanGuardReads=0
 $script:SmScanGuard={ $script:scanGuardReads++; [pscustomobject]@{Safe=($script:scanGuardReads -lt 2);Light=($script:scanGuardReads -ge 2);Reasons=@('Setup started')} }
 $scan=Get-SmScan @($many) 1000 30 7
 Assert ($scan.Partial -and $scan.Light -and $scan.EntriesVisited -lt 140) 'Setup starting during scan stops traversal'
 $script:SmScanGuard={ [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
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
 Assert ($r.Actions[0].Error -match 'revalidation') ('profile recheck reported: '+($r | ConvertTo-Json -Depth 12 -Compress))
 # A newly loaded Classes hive or new session also vetoes deletion on recheck.
 $script:SmProfiles={ @($script:MockProfile) }; $script:MockProfile.Loaded=$false
 foreach($race in @('classes','session')) {
  $script:ageEvidenceReads=0; $script:ageRace=$race
  $script:SmProfileEvidence={
   $script:ageEvidenceReads++; $e=New-TestAgeEvidence $now
   if($script:ageEvidenceReads -gt 1) { if($script:ageRace -eq 'classes') { $e.Hives.ClassesLoaded=$true } else { $e.Sessions.Sids=@($script:MockProfile.SID) } }
   $e
  }
  $r=Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup -RemoveProfiles true)
  Assert ($script:profileRemovals -eq 0 -and $r.Actions[0].Error -match 'revalidation') ('fresh '+$race+' activity veto')
 }
 $script:SmProfileEvidence={ $script:FixtureAgeEvidence }
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
