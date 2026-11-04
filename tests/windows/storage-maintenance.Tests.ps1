$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
. (Join-Path $PSScriptRoot '../../windows/packages/storage-maintenance/Invoke-StorageMaintenance.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }

foreach($helper in @('Grant-SmThemeReadAccess','Install-SmDialogTheme')) {
 $mandatory=@((Get-Command $helper).Parameters.Values | ForEach-Object { $_.Attributes } | Where-Object { $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory })
 Assert ($mandatory.Count -eq 0) 'Theme helpers cannot prompt for missing arguments'
 $refused=$false; try { & $helper } catch { $refused=$_.Exception.Message -match 'must not be empty' }
 Assert $refused 'Missing theme helper arguments fail explicitly before work'
}

$migrationData=$env:ProgramData; if(-not $env:ProgramData) { $env:ProgramData=[IO.Path]::GetTempPath() }

# Pilot regression: package evidence is independent of a pre-existing Relian root.
$paths=@(Get-SmNativeMarkerPaths)
Assert ($paths[0] -eq (Join-Path $env:ProgramData 'RelianMaintenance\native-active.json')) 'Owned maintenance marker root'
Assert ($paths[1] -eq (Join-Path $env:ProgramData 'Relian\Maintenance\native-active.json')) 'Legacy marker remains read-only guard evidence'
$initializer=${function:Initialize-SmSecureDirectory}.ToString()
Assert ($initializer.Contains("'RelianMaintenance'") -and $initializer.Contains('if(-not $created)')) 'Owned root itself is validated before existing-root reuse'
$env:ProgramData=$migrationData
# Run the real preparation block with only its ACL boundary replaced. Its requested
# destination must be the owned root, independently of the legacy Relian tree.
& {
 $scratch=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n')); $null=New-Item -ItemType Directory $scratch
 $priorData=$env:ProgramData; $env:ProgramData=$scratch
 try {
  function Initialize-SmSecureDirectory { param($Path) Assert ($Path.StartsWith((Join-Path $env:ProgramData 'RelianMaintenance'))) 'Actual preparation only requests owned root'; $scratch }
  function Test-SmSafePath { $true }
  $prepared=& $script:SmPrepareReport
  Assert ($prepared.StartsWith($scratch) -and (Test-Path -LiteralPath $scratch)) 'Actual evidence preparation succeeds with independent root'
 } finally { $env:ProgramData=$priorData; Remove-Item -LiteralPath $scratch -Recurse -Force }
}
# Exercise both guard marker branches before a deliberately unavailable registry.
& {
 $priorData=$env:ProgramData; $env:ProgramData=[IO.Path]::GetTempPath()
 try {
  function Get-CimInstance { @() }
  function Get-ItemProperty { throw 'offline registry boundary' }
  foreach($script:migrationMarker in @(Get-SmNativeMarkerPaths)) {
   function Test-Path { param($LiteralPath) $LiteralPath -eq $script:migrationMarker }
   $guard=Get-SmGuards
   Assert (-not $guard.Safe -and $guard.Light -and ($guard.Reasons -join ';') -match 'native-active marker present') 'New and legacy markers each fail closed'
  }
 } finally { $env:ProgramData=$priorData; Remove-Variable migrationMarker -Scope Script -ErrorAction SilentlyContinue }
}
Assert (${function:Get-SmGuards}.ToString().Contains('Relian\FeatureUpgrade\state.json')) 'FeatureUpgrade state remains at original read-only path'
if($env:OS -eq 'Windows_NT') {
 & {
  $priorData=$env:ProgramData; $root=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n')); $env:ProgramData=$root
  $null=New-Item -ItemType Directory -Path (Join-Path $root 'Relian') -Force
  $script:migrationAcl=[pscustomobject]@{Owner='S-1-5-18'}
  $script:migrationAcl | Add-Member ScriptMethod GetOwner { param($Type) [pscustomobject]@{Value=$this.Owner} }
  $script:migrationAcl | Add-Member ScriptMethod GetAccessRules { param($Explicit,$Inherited,$Type) @() }
  $script:migrationAclPaths=@()
  # Only the Windows ACL boundary is mocked. Path creation, ancestry walk,
  # existing-directory checks and reparse checks are the actual initializer.
  function Get-Acl { param($LiteralPath) $script:migrationAclPaths+=$LiteralPath; $script:migrationAcl }
  function Set-Acl { param($LiteralPath,$AclObject) $script:migrationAclPaths+=$LiteralPath }
  try {
   $owned=Join-Path $root 'RelianMaintenance'
   $result=Initialize-SmSecureDirectory (Join-Path $owned 'Storage')
   Assert (Test-Path -LiteralPath $result) 'Actual initialization creates independent report directory'
   Assert (@($script:migrationAclPaths | Where-Object { -not $_.StartsWith($owned+'\') -and $_ -ne $owned }).Count -eq 0) 'Initialization never inspects or changes unrelated Relian ACL'
   $script:migrationAcl.Owner='S-1-5-21-1-2-3-1001'; $refused=$false
   try { Initialize-SmSecureDirectory $owned } catch { $refused=$_.Exception.Message -match 'untrusted owner' }
   Assert $refused 'Existing untrusted owned root refused even when terminal target'
  } finally { $env:ProgramData=$priorData; Remove-Item -LiteralPath $root -Recurse -Force; Remove-Variable migrationAcl,migrationAclPaths -Scope Script -ErrorAction SilentlyContinue }
 }
} else { 'Windows actual-directory initialization/ACL-boundary isolation test skipped on this platform' }

$triage=[pscustomobject]@{Status='partial';Mode='Report';Actions=@();Guards=@{Reasons=@('Setup active')};Scan=@{Partial=$true;TopFiles=@(@{Path='C:\large.bin';LogicalBytes=100});TempCategories=@(@{Root='C:\Windows\Temp';AgeQualifiedLogicalBytes=50})};Before=@(@{DeviceID='C:';Size=1000;FreeSpace=100});After=@();Profiles=@(@{Decision='Protected'},@{Decision='StaleCandidate'});FreeSpaceDelta=@();Notifications=@();Errors=@();Evidence=@{Opportunities=@(@{Present=$true},@{Present=$false})}}
$triageSummary=ConvertTo-SmSummary $triage 'report.json' | ConvertFrom-Json
Assert ($triageSummary.Before[0].FreeSpace -eq 100 -and $triageSummary.TopFiles[0].LogicalBytes -eq 100) 'Storage stdout includes free space and top consumers'
Assert ($triageSummary.ProfileDecisions.Count -eq 2 -and $triageSummary.TempOpportunities.Count -eq 1) 'Storage stdout includes profile and temp decisions'
Assert ($triageSummary.OpportunityCount -eq 2 -and $triageSummary.ProfileCount -eq 2) 'Storage stdout reports opportunity and profile counts'
Assert ($null -ne $triageSummary.Truncated) 'Storage stdout declares truncation'
$script:SmScanGuard={ [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
function Throws($Code) { try { & $Code; throw 'did not throw' } catch { if ($_.Exception.Message -eq 'did not throw') { throw } } }
# Upgrade history distinguishes preserved residue from unestablished staging.
$install=[datetime]::SpecifyKind([datetime]'2026-10-01T12:00:00',[DateTimeKind]::Utc)
Assert ((Get-SmUpgradeDirectoryState @($install.AddDays(-1)) 26200 @('26100') $install $install.AddDays(1)) -eq 'completedResidual') 'completed upgrade residue preserved without blocking'
Assert ((Get-SmUpgradeDirectoryState @($install.AddDays(1)) 26200 @('26100') $install $install.AddDays(2)) -eq 'unknownStaging') 'new staging after OS install blocks'
Assert ((Get-SmUpgradeDirectoryState @($install.AddDays(-1)) 26200 @() $install $install.AddDays(1)) -eq 'unknownStaging') 'missing SourceOS completion evidence blocks'
Assert ((Get-SmMoSetupState @{} $false) -eq 'residual') 'empty Volatile key is not active evidence'
Assert ((Get-SmMoSetupState @{SetupHostResult=0;SetupPhase=0} $true) -eq 'residual') 'known zero MoSetup result with proven completion residual'
Assert ((Get-SmMoSetupState @{SetupHostResult=0} $false) -eq 'unknownOrActive') 'zero MoSetup values still need completion evidence'
Assert ((Get-SmMoSetupState @{SetupProgress=100} $true) -eq 'unknownOrActive') 'unsupported MoSetup fields fail closed'
$own=[pscustomobject]@{status='staged';isoBuild=26200;time='2026-10-02T12:00:00Z'}
Assert ((Get-SmOwnUpgradeState $own 26200 $install) -eq 'residual') 'target build reached clears stale own stage'
Assert ((Get-SmOwnUpgradeState $own 26100 $install.AddDays(3)) -eq 'residual') 'boot after own stage makes marker residual'
Assert ((Get-SmOwnUpgradeState $own 26100 $install) -eq 'staged') 'unbuilt own stage before reboot blocks'
$own.time='bad'; Assert ((Get-SmOwnUpgradeState $own 26200 $install) -eq 'unknown') 'malformed own stage unknown even when target build reached'
# Read-only evidence workers have an absolute parent-side timeout and Setup veto.
$script:workerKilled=$false
$fakeWorker=[pscustomobject]@{}
$fakeWorker | Add-Member ScriptMethod WaitForExit { param($Milliseconds) $false }
$fakeWorker | Add-Member ScriptMethod Kill { $script:workerKilled=$true }
$script:SmGuards={ [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
$wait=Wait-SmEvidenceWorker $fakeWorker 0.03
Assert ($wait.TimedOut -and $script:workerKilled) 'blocked identity/event child killed on deadline'
$script:workerKilled=$false
$script:SmGuards={ [pscustomobject]@{Safe=$false;Light=$true;Reasons=@('Setup started')} }
$wait=Wait-SmEvidenceWorker $fakeWorker 1
Assert ($wait.GuardChanged -and $script:workerKilled) 'Setup transition interrupts evidence worker'
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
Assert (-not (Test-SmProfilePath ([IO.Path]::GetTempPath()))) 'Temporary directories do not expand production profile eligibility'
Assert (-not (Test-SmProfilePath '')) 'Empty profile path protected'
$profileFixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('profile-fixtures-'+[guid]::NewGuid().ToString('n'))
$null=New-Item -ItemType Directory -Path $profileFixtureRoot
$realProfilePath=${function:Test-SmProfilePath}
# Age evidence tests isolate the conventional Windows path policy from their data.
function Test-SmProfilePath($Path) { $Path.StartsWith($profileFixtureRoot+[IO.Path]::DirectorySeparatorChar) }
$ageProfile=[pscustomobject]@{SID='S-1-5-21-1-2-3-1001';LocalPath=(Join-Path $profileFixtureRoot 'synthetic-profile');Loaded=$false;Special=$false;LastUseTime=$ageNow.AddDays(-90);Status=0;RoamingConfigured=$false;RoamingPreference=$false;refCount=0}
Assert ($ageProfile.LocalPath.StartsWith($profileFixtureRoot+[IO.Path]::DirectorySeparatorChar)) 'Profile fixture belongs to isolated temporary root'
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
$p = [pscustomobject]@{ SID='S-1-5-21-1-2-3-1001'; LocalPath=(Join-Path $profileFixtureRoot 'synthetic-profile'); Loaded=$false; Special=$false; LastUseTime=$now.AddDays(-200);Status=0;RoamingConfigured=$false;RoamingPreference=$false;refCount=0 }
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
 $script:SmCollectProfiles={ param($Profiles,$Days,$Now,$Seconds,$Directory,$Mode)
  if($Mode -eq 'Final') { return [pscustomobject]@{Complete=$true;TimedOut=$false;GuardChanged=$false;FinalVeto=[pscustomobject]@{Clear=$true};Entries=@();ElapsedSeconds=0.01;Error=$null} }
  $context=& $script:SmProfileContext $Days $Now
  [pscustomobject]@{Complete=$true;TimedOut=$false;GuardChanged=$false;Entries=@($Profiles | ForEach-Object { [pscustomobject]@{SID=$_.SID;Path=$_.LocalPath;Evidence=(& $script:SmProfileEvidence $_ $Days $Now $context)} });ElapsedSeconds=0.01;Error=$null}
 };
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
 # A blocked provider cannot silently qualify a profile after the aggregate deadline.
 $realCollector=$script:SmCollectProfiles
 $script:SmCollectProfiles={ [pscustomobject]@{Complete=$false;TimedOut=$true;GuardChanged=$false;Reasons=@();Entries=@();ElapsedSeconds=30;Error='provider timeout'} }
 $r=Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup -RemoveProfiles true)
 Assert ($r.Profiles[0].Decision -eq 'ReviewInsufficientEvidence' -and $script:profileRemovals -eq 0) 'timed-out aggregate collection yields review and no deletion'
 $script:SmCollectProfiles={ [pscustomobject]@{Complete=$false;TimedOut=$false;GuardChanged=$true;Reasons=@('Setup started');Entries=@();ElapsedSeconds=0.1;Error='guard transition'} }
 $r=Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup -RemoveProfiles true)
 Assert ($r.Scan.Light -and $r.Scan.EntriesVisited -eq 0 -and $script:profileRemovals -eq 0) 'guard transition during collection withholds scan/removal'
 $script:SmCollectProfiles=$realCollector
 $script:SmGuards={ [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
 # Simulate Setup starting inside expensive fresh evidence, after the first guard.
 $script:SmProfileEvidence={ $script:FixtureAgeEvidence }
 $script:evidenceCollectCalls=0
 $script:SmCollectProfiles={ param($Profiles,$Days,$Now,$Seconds,$Directory,$Mode)
  $script:evidenceCollectCalls++
  $result=& $realCollector $Profiles $Days $Now $Seconds $Directory $Mode
  if($script:evidenceCollectCalls -ge 2) { $script:SmGuards={ [pscustomobject]@{Safe=$false;Light=$true;Reasons=@('Setup started during identity lookup')} } }
  $result
 }
 # Keep filesystem validation independently mocked so the last guard is reached.
 $realSafePath=${function:Test-SmSafePath}; function Test-SmSafePath { $true }
 $realScan=${function:Get-SmScan}
 function Get-SmScan { [pscustomobject]@{Roots=@();Files=@();TopFiles=@();TopFolders=@();Partial=$false;EntriesVisited=0;SkippedReparseOrCloud=0;Errors=@();Seconds=0} }
 $r=Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup -RemoveProfiles true)
 Assert ($script:profileRemovals -eq 0 -and $r.Actions[0].Error -match 'guard changed immediately') 'fresh servicing guard after expensive evidence blocks removal'
 ${function:Test-SmSafePath}=$realSafePath; ${function:Get-SmScan}=$realScan
 $script:SmCollectProfiles=$realCollector
 # Exercise actual child-process/output plumbing with unavailable Windows toolkit.
 # No OS evidence is read: missing toolkit must return incomplete safely.
 $savedProgramData=$env:ProgramData; $savedSystemRoot=$env:SystemRoot
 $env:ProgramData=$root; $env:SystemRoot=$root
 $workerDir=Join-Path $root 'worker-evidence'; $null=New-Item -ItemType Directory -Path $workerDir
 function Start-Process {
  [CmdletBinding()]param($FilePath,$ArgumentList,$RedirectStandardOutput,$RedirectStandardError,$WindowStyle,[switch]$PassThru)
  Microsoft.PowerShell.Management\Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $ArgumentList -RedirectStandardOutput $RedirectStandardOutput -RedirectStandardError $RedirectStandardError -PassThru
 }
 $script:SmGuards={ [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
 try {
  $workerResult=Invoke-SmProfileWorker @() 60 $now 5 $workerDir Full
  Assert (-not $workerResult.Complete -and $workerResult.Error -match 'module|PSAppDeployToolkit' -and -not $workerResult.TimedOut -and @(Get-ChildItem -LiteralPath $workerDir -Filter '*.output.xml').Count -eq 1) 'provider/module failure crosses read-only child boundary as incomplete evidence'
 } finally { Remove-Item Function:Start-Process; $env:ProgramData=$savedProgramData; $env:SystemRoot=$savedSystemRoot }
 $script:SmPrepareReport={ throw 'Evidence destination denied' }
 $r=Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup)
 Assert ($r.Status -eq 'failed' -and $r.Actions.Count -eq 0) 'evidence failure blocks cleanup'
 $script:SmAcquire={ $false }
 $r=Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup)
 Assert ($r.Status -eq 'busy') 'mutex exclusion'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
Write-Output 'storage-maintenance tests passed'

$triage.Guards=@{Light=$true;Reasons=@('Setup active')}; $triage.Scan=@{Partial=$true;Light=$true}; $triage.Profiles=@()
$light=ConvertTo-SmSummary $triage 'report.json' | ConvertFrom-Json
Assert ($light.ScanWithheld -and $light.Before[0].FreeSpace -eq 100 -and @($light.TopFiles).Count -eq 0) 'Light stdout retains volume snapshot while scans withheld'
$triage.Scan=@{Partial=$true;TopFiles=@(1..20 | ForEach-Object { @{Path=('漢'*1000);LogicalBytes=100} });TopFolders=@(1..20 | ForEach-Object { @{Path=('漢'*1000);DirectFileLogicalBytes=100} });TempCategories=@(1..20 | ForEach-Object { @{Root=('漢'*1000);LogicalBytes=100;AgeQualifiedLogicalBytes=50} })}; $triage.Errors=@(('漢'*10000)); $triage.Guards.Reasons=@(('漢'*10000))
$bounded=ConvertTo-SmSummary $triage 'report.json'
Assert ([Text.Encoding]::UTF8.GetByteCount($bounded) -le 8000 -and ($bounded | ConvertFrom-Json).Truncated) 'UTF8 triage stdout is explicitly truncated within byte cap'

foreach($state in @(@{status='staged';isoBuild=1;time='2026-11-04T00:00:00Z'},@{status='staged';isoBuild=26200;time='2099-01-01T00:00:00Z'})) {
 Assert ((Get-SmOwnUpgradeState $state 22631 ([datetime]'2026-11-03')) -eq 'unknown') 'Paired storage invalid/future staged evidence must block'
}

${function:Test-SmProfilePath}=$realProfilePath
Remove-Item -LiteralPath $profileFixtureRoot -Recurse -Force
