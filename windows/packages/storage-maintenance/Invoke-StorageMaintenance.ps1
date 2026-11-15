<# .SYNOPSIS
Bounded storage evidence and explicitly requested conservative cleanup. No reboot.
Logical bytes are observations, not guaranteed reclaimable physical space.
#>
[CmdletBinding()]
param([string]$DeploymentType, [string]$Action, [string]$PinVersion,
 [string]$Mode='Report', [string]$TempAgeDays='7', [string]$ProfileAgeDays='60',
 [string]$RemoveProfiles='false', [string]$ExcludeProfiles='', [string]$ComponentCleanup='false',
 [string]$MaxFiles='20000', [string]$MaxSeconds='30', [string]$ProfileReport='false', [string]$PrimaryUserHint='', [string]$SharedDevices='')

$script:SmPackagePath=$PSCommandPath

function Get-SmArguments {
 param([string]$Mode='Report',[string]$TempAgeDays='7',[string]$ProfileAgeDays='60',
 [string]$RemoveProfiles='false',[string]$ExcludeProfiles='', [string]$ComponentCleanup='false',
 [string]$MaxFiles='20000',[string]$MaxSeconds='30',[string]$ProfileReport='false',[string]$PrimaryUserHint='',[string]$SharedDevices='')
 if ($Mode -cnotin @('Report','Cleanup')) { throw 'Mode must be Report or Cleanup' }
 $a=@{ Mode=$Mode; ExcludeProfiles=@($ExcludeProfiles.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
 if ($PrimaryUserHint.Length -gt 256 -or $PrimaryUserHint -match '[\x00-\x1f]') { throw 'Invalid PrimaryUserHint' }; $a.PrimaryUserHint=$PrimaryUserHint.Trim()
 $a.SharedDevices=@($SharedDevices.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
 if ($a.SharedDevices.Count -gt 100 -or @($a.SharedDevices | Where-Object { $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$' }).Count) { throw 'SharedDevices must be a comma-separated list of computer names' }
 foreach($b in @(@('RemoveProfiles',$RemoveProfiles),@('ComponentCleanup',$ComponentCleanup),@('ProfileReport',$ProfileReport))) {
  if ($b[1] -cnotin @('true','false')) { throw "$($b[0]) must be true or false" }; $a[$b[0]]=$b[1] -ceq 'true'
 }
 foreach($n in @(@('TempAgeDays',$TempAgeDays,1,365),@('ProfileAgeDays',$ProfileAgeDays,30,3650),@('MaxFiles',$MaxFiles,1,2000000),@('MaxSeconds',$MaxSeconds,1,1800))) {
  if ($n[1] -notmatch '^\d{1,7}$' -or [int]$n[1] -lt $n[2] -or [int]$n[1] -gt $n[3]) { throw "Invalid $($n[0])" }; $a[$n[0]]=[int]$n[1]
 }
 if ($a.ProfileReport -and ($a.Mode -ne 'Report' -or $a.RemoveProfiles -or $a.ComponentCleanup)) { throw 'ProfileReport is report-only: Mode must be Report and RemoveProfiles and ComponentCleanup false' }
 return $a
}

# Registry profile-service dates are primary evidence on Windows 10 1809+.
# https://learn.microsoft.com/en-us/troubleshoot/windows-server/support-tools/scripts-to-retrieve-profile-age
function ConvertFrom-SmFileTimePair {
 param($Low,$High,[datetime]$Now=[datetime]::UtcNow)
 $r=[ordered]@{Low=$Low;High=$High;State='missing';TimestampUtc=$null}
 if($null -eq $Low -or $null -eq $High) { return [pscustomobject]$r }
 $words=@()
 foreach($word in @($Low,$High)) {
  if("$word" -notmatch '^-?\d{1,10}$') { $r.State='malformed'; return [pscustomobject]$r }
  $n=[decimal]::Parse("$word",[Globalization.CultureInfo]::InvariantCulture)
  if($n -lt -2147483648 -or $n -gt 4294967295) { $r.State='malformed'; return [pscustomobject]$r }
  if($n -lt 0) { $n+=4294967296 }; $words+=([uint64]$n)
 }
 $ft=($words[1] -shl 32) -bor $words[0]
 if($ft -eq 0) { $r.State='zero'; return [pscustomobject]$r }
 try {
  if($ft -gt [int64]::MaxValue) { throw 'FILETIME outside signed range' }
  $time=[datetime]::FromFileTimeUtc([int64]$ft)
  if($time -lt [datetime]'1970-01-01') { throw 'Implausible profile-service date before 1970' }
  $r.TimestampUtc=$time; $r.State=if($time -gt $Now.ToUniversalTime()){'future'}else{'valid'}
 } catch { $r.State='invalid' }
 return [pscustomobject]$r
}

function Test-SmProfilePath {
 param([string]$Path)
 return ($Path -match '^[A-Za-z]:\\Users\\[^\\]+$' -and ($Path -split '\\')[-1] -notmatch '^(Public|Default.*|All Users|Administrator|defaultuser.*)$')
}

function Test-SmProfile {
 param($Profile,[int]$AgeDays,[string[]]$Exclusions,[datetime]$Now=[datetime]::UtcNow,$Evidence=$null)
 $nowUtc=$Now.ToUniversalTime(); $cutoff=$nowUtc.AddDays(-$AgeDays); $last=$null; $cimState='missing'
 try { if($Profile.LastUseTime) { $last=([datetime]$Profile.LastUseTime).ToUniversalTime(); $cimState=if($last -gt $nowUtc){'future'}else{'valid'} } } catch { $cimState='invalid' }
 $decision='ReviewInsufficientEvidence'; $reason='Required profile-service age, identity or activity evidence unavailable'; $age=$null; $fingerprint=$null
 if($Profile.Loaded -ne $false -or $Profile.Special -ne $false) { $decision='Protected'; $reason='Loaded, special or unknown loaded/special state' }
 elseif($Profile.SID -notmatch '^S-1-(5-21-|12-1-)' -or $Profile.SID -match '-(500|501|503|504)$') { $decision='Protected'; $reason='Protected SID' }
 elseif(-not (Test-SmProfilePath $Profile.LocalPath)) { $decision='Protected'; $reason='Protected profile path' }
 elseif($Exclusions -contains $Profile.SID -or $Exclusions -contains $Profile.LocalPath -or $Profile.LocalPath -eq $env:USERPROFILE) { $decision='Protected'; $reason='Explicit exclusion or current profile' }
 elseif($null -eq $Profile.Status -or $null -eq $Profile.RoamingConfigured -or $null -eq $Profile.RoamingPreference) { $reason='Unknown profile status/roaming state' }
 elseif([int64]$Profile.Status -ne 0 -or $Profile.RoamingConfigured -or $Profile.RoamingPreference -or $Profile.refCount -gt 0) { $decision='Protected'; $reason='Temporary, roaming, mandatory, corrupt or referenced profile' }
 elseif($null -ne $Evidence) {
  $reg=$Evidence.Registry; $sessions=$Evidence.Sessions; $hives=$Evidence.Hives; $events=$Evidence.Events
  if(-not $sessions.Known -or -not $hives.Known -or -not $Evidence.Identity.Resolved -or $reg.ReadState -ne 'ok' -or -not $reg.IdentityMatches) { $reason='Identity, session, hive or ProfileList mapping cannot be verified' }
  elseif($sessions.CurrentSid -eq $Profile.SID -or $sessions.Sids -contains $Profile.SID -or $hives.Loaded -or $hives.ClassesLoaded -or $Evidence.NtUser.ManUtc) { $decision='Protected'; $reason='Current/session SID, loaded SID or SID_Classes hive, or mandatory NTUSER.MAN' }
  elseif(@($events.Recent | Where-Object { $_.Sid -eq $Profile.SID -and $_.LogonType -in @(2,7,10,11,12,13) -and $_.TimeUtc -ge $cutoff }).Count) { $decision='KeepRecentConfirmed'; $reason='Positive recent interactive/unlock Security 4624 target SID' }
  elseif(@($reg.Load,$reg.Unload,$reg.Cleanup | Where-Object { $_.State -in @('future','invalid','malformed') }).Count -or $cimState -in @('future','invalid')) { $decision='ReviewInconsistent'; $reason='Invalid, malformed or future source date' }
  elseif(($reg.Load.State -eq 'valid' -and $reg.Load.TimestampUtc -ge $cutoff) -or ($reg.Unload.State -eq 'valid' -and $reg.Unload.TimestampUtc -ge $cutoff)) { $decision='KeepRecentProfileService'; $reason='Profile-service load/unload at or after cutoff' }
  elseif($reg.Cleanup.State -eq 'valid' -and $reg.Cleanup.TimestampUtc -ge $cutoff) { $decision='ReviewPolicyTracking'; $reason='Recent cleanup-policy tracking date; not a logon date' }
  elseif($reg.Load.State -ne 'valid' -or $reg.Unload.State -ne 'valid') { $decision='ReviewFallbackOnly'; $reason='Coherent registry load/unload pair missing; CIM, cleanup-only and NTUSER dates never authorize deletion' }
  elseif($reg.Load.TimestampUtc -gt $reg.Unload.TimestampUtc) { $decision='ReviewInconsistent'; $reason='Load is newer than unload; crash or active-profile ambiguity' }
  elseif($last -and $last -ge $cutoff) { $decision='ReviewTimestampConflict'; $reason='Recent CIM profile use conflicts with old profile-service evidence' }
  elseif(-not $events.ProbeComplete -or $events.Truncated -or @($Evidence.Errors).Count -or @($Evidence.NtUser.Errors).Count) { $reason='Activity or required evidence collection failed/truncated; absence of events never proves inactivity' }
  else {
   $decision='StaleCandidate'; $reason='Coherent profile-service load <= unload strictly older than cutoff; no positive recent veto. Not proof of last human logon.'
   $age=[math]::Floor(($nowUtc-$reg.Unload.TimestampUtc).TotalDays)
   $fingerprint=(@($reg.Load.TimestampUtc.ToString('o'),$reg.Unload.TimestampUtc.ToString('o'),$reg.Cleanup.State,"$($reg.Cleanup.TimestampUtc)") -join '|')
  }
 }
 [pscustomobject]@{SID=$Profile.SID;Path=$Profile.LocalPath;LastUseTime=$last;CimDateState=$cimState;CutoffUtc=$cutoff;ObservedAgeDays=$age;Decision=$decision;Eligible=($decision -eq 'StaleCandidate');Reason=$reason;AgeSource='ProfileList load/unload; NTUSER is diagnostic only';AgeEvidenceFingerprint=$fingerprint;ServicingTouchPossible=($null -ne $Evidence -and $Evidence.NtUser.DatUtc -and $Evidence.NtUser.DatUtc -ge $cutoff);Evidence=$Evidence;LogicalBytes=$null;SizePartial=$true}
}

function Get-SmSessionEvidence {
 $sessions=[ordered]@{Known=$false;Sids=@();CurrentSid=$null;Error=$null}
 try {
  $sessions.CurrentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  if(-not (Get-Command Get-ADTLoggedOnUser -ErrorAction SilentlyContinue)) { throw 'Toolkit user-session probe unavailable' }
  $sessions.Sids=@(Get-ADTLoggedOnUser -ErrorAction Stop | Where-Object { $_.IsUserSession } | ForEach-Object { $account=New-Object Security.Principal.NTAccount("$($_.NTAccount)"); $account.Translate([Security.Principal.SecurityIdentifier]).Value })
  $console=Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 5 -ErrorAction Stop
  if($console.UserName) { $account=New-Object Security.Principal.NTAccount("$($console.UserName)"); $sessions.Sids+= $account.Translate([Security.Principal.SecurityIdentifier]).Value }
  foreach($proc in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -OperationTimeoutSec 5 -ErrorAction Stop)) {
   $owner=Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid -OperationTimeoutSec 5 -ErrorAction Stop
   if($owner.ReturnValue -ne 0 -or -not $owner.Sid) { throw 'Explorer owner SID unavailable' }; $sessions.Sids+="$($owner.Sid)"
  }
  $sessions.Sids=@($sessions.Sids | Select-Object -Unique); $sessions.Known=$true
 } catch { $sessions.Error=$_.Exception.Message }
 return [pscustomobject]$sessions
}

function Get-SmProfileContext {
 param([int]$AgeDays,[datetime]$Now=[datetime]::UtcNow)
 $sessions=Get-SmSessionEvidence
 $events=[ordered]@{ProbeComplete=$false;Recent=@();Truncated=$false;Error=$null;Coverage='Positive evidence only: absent, rotated or cleared logs never establish inactivity. Historical audit continuity unknown.';EntriesRead=0}
 $watch=[Diagnostics.Stopwatch]::StartNew()
 try {
  $records=@(Get-WinEvent -FilterHashtable @{LogName='Security';Id=4624;StartTime=$Now.AddDays(-$AgeDays)} -MaxEvents 2001 -ErrorAction Stop)
  if($records.Count -gt 2000) { $events.Truncated=$true }
  foreach($record in @($records | Select-Object -First 2000)) {
   if($watch.Elapsed.TotalSeconds -gt 5) { $events.Truncated=$true; break }
   $events.EntriesRead++; [xml]$xml=$record.ToXml(); $data=@{}
   foreach($field in $xml.Event.EventData.Data) { $data["$($field.Name)"]="$($field.'#text')" }
   if($data.LogonType -in @('2','7','10','11','12','13') -and $data.TargetUserSid -match '^S-1-') { $events.Recent+=[pscustomobject]@{Sid=$data.TargetUserSid;LogonType=[int]$data.LogonType;TimeUtc=$record.TimeCreated.ToUniversalTime()} }
  }
  $events.ProbeComplete=$true
 } catch { if($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $events.ProbeComplete=$true } else { $events.Error=$_.Exception.Message } }
 [pscustomobject]@{Sessions=[pscustomobject]$sessions;Events=[pscustomobject]$events;AssessedUtc=$Now}
}

function Get-SmProfileEvidence {
 param($Profile,[int]$AgeDays,[datetime]$Now,$Context)
 $errors=@(); $reg=[ordered]@{ReadState='unknown';IdentityMatches=$false;ProfileImagePath=$null;Raw=@{};Load=$null;Unload=$null;Cleanup=$null;Error=$null}
 $pairs=@(@('Load','LocalProfileLoadTimeLow','LocalProfileLoadTimeHigh'),@('Unload','LocalProfileUnLoadTimeLow','LocalProfileUnLoadTimeHigh'),@('Cleanup','LocalProfileCleanupCheckTimeLow','LocalProfileCleanupCheckTimeHigh'))
 try {
  if($Profile.SID -notmatch '^S-1-\d+(?:-\d+)+$') { throw 'Malformed profile SID' }
  $key='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$Profile.SID
  $values=Get-ItemProperty -LiteralPath $key -ErrorAction Stop; $reg.ReadState='ok'
  $reg.ProfileImagePath=[Environment]::ExpandEnvironmentVariables("$($values.ProfileImagePath)")
  $reg.IdentityMatches=[string]::Equals([IO.Path]::GetFullPath($reg.ProfileImagePath).TrimEnd('\'),[IO.Path]::GetFullPath($Profile.LocalPath).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)
  foreach($pair in $pairs) { $low=$values.($pair[1]); $high=$values.($pair[2]); $reg.Raw[$pair[1]]=$low; $reg.Raw[$pair[2]]=$high; $reg[$pair[0]]=ConvertFrom-SmFileTimePair $low $high $Now }
 } catch { $reg.Error=$_.Exception.Message; $errors+='ProfileList: '+$_.Exception.Message }
 foreach($pair in $pairs) { if(-not $reg[$pair[0]]) { $reg[$pair[0]]=ConvertFrom-SmFileTimePair $null $null $Now } }
 $identity=[ordered]@{Resolved=$false;Account=$null;Error=$null}
 try { $sid=New-Object Security.Principal.SecurityIdentifier($Profile.SID); $identity.Account=$sid.Translate([Security.Principal.NTAccount]).Value; $identity.Resolved=$true } catch { $identity.Error=$_.Exception.Message }
 $hives=[ordered]@{Known=$false;Loaded=$false;ClassesLoaded=$false;Error=$null}
 try {
  $hives.Loaded=Test-Path -LiteralPath ('Registry::HKEY_USERS\'+$Profile.SID) -ErrorAction Stop
  $hives.ClassesLoaded=Test-Path -LiteralPath ('Registry::HKEY_USERS\'+$Profile.SID+'_Classes') -ErrorAction Stop
  $hives.Known=$true
 } catch { $hives.Error=$_.Exception.Message }
 $nt=[ordered]@{DatUtc=$null;ManUtc=$null;Errors=@();Meaning='Diagnostic only; servicing can touch hive files independently of profile-service aging'}
 foreach($file in @(@('NTUSER.DAT','DatUtc'),@('NTUSER.MAN','ManUtc'))) {
  try {
   $path=Join-Path $Profile.LocalPath $file[0]
   if(Test-Path -LiteralPath $path -ErrorAction Stop) { if(-not (Test-SmSafePath $path $Profile.LocalPath)) { throw 'Unsafe hive metadata path' }; $nt[$file[1]]=(Get-Item -LiteralPath $path -Force -ErrorAction Stop).LastWriteTimeUtc }
  } catch { $nt.Errors+=$_.Exception.Message }
 }
 $events=[pscustomobject]@{ProbeComplete=$Context.Events.ProbeComplete;Truncated=$Context.Events.Truncated;Error=$Context.Events.Error;Coverage=$Context.Events.Coverage;EntriesRead=$Context.Events.EntriesRead;Recent=@($Context.Events.Recent | Where-Object {$_.Sid -eq $Profile.SID} | Select-Object -First 20)}
 [pscustomobject]@{Registry=[pscustomobject]$reg;Identity=[pscustomobject]$identity;Sessions=$Context.Sessions;Hives=[pscustomobject]$hives;NtUser=[pscustomobject]$nt;Events=$events;Errors=$errors}
}
$script:SmProfileContext={ param($Days,$Now) Get-SmProfileContext $Days $Now }
$script:SmProfileEvidence={ param($Profile,$Days,$Now,$Context) Get-SmProfileEvidence $Profile $Days $Now $Context }

# All domain identity lookups and event-provider work run in a disposable read-only
# process. The parent owns the absolute deadline and observes Setup between waits.
function Wait-SmEvidenceWorker {
 param($Process,[double]$Seconds)
 $watch=[Diagnostics.Stopwatch]::StartNew(); $nextGuard=0.0
 $r=[ordered]@{TimedOut=$false;GuardChanged=$false;Reasons=@();ElapsedSeconds=0.0}
 while($true) {
  if($watch.Elapsed.TotalSeconds -ge $Seconds) { $r.TimedOut=$true; break }
  if($watch.Elapsed.TotalSeconds -ge $nextGuard) {
   try { $g=& $script:SmGuards; if($null -eq $g -or $g.Light) { $r.GuardChanged=$true; $r.Reasons=@($g.Reasons); break } }
   catch { $r.GuardChanged=$true; $r.Reasons=@('unknown worker servicing guard'); break }
   $nextGuard=$watch.Elapsed.TotalSeconds+2
  }
  if($watch.Elapsed.TotalSeconds -ge $Seconds) { $r.TimedOut=$true; break }
  $waitMs=[int][math]::Max(1,[math]::Min(200,($Seconds-$watch.Elapsed.TotalSeconds)*1000))
  if($Process.WaitForExit($waitMs)) { break }
 }
 if($r.TimedOut -or $r.GuardChanged) { try { $Process.Kill() } catch { $r.Reasons+=('Read-only worker termination failed: '+$_.Exception.Message) } }
 $r.ElapsedSeconds=$watch.Elapsed.TotalSeconds
 [pscustomobject]$r
}

function Get-SmFinalProfileVeto {
 param($Profile)
 $sessions=Get-SmSessionEvidence
 $r=[ordered]@{Clear=$false;Reason='Final session identity unavailable';Sessions=$sessions;Profile=$null;LoadedHive=$null}
 if(-not $sessions.Known) { return [pscustomobject]$r }
 if($sessions.Sids -contains $Profile.SID -or $sessions.CurrentSid -eq $Profile.SID) { $r.Reason='Session SID appeared'; return [pscustomobject]$r }
 try {
  if($Profile.SID -notmatch '^S-1-\d+(?:-\d+)+$') { throw 'Malformed SID' }
  $fresh=@(Get-CimInstance Win32_UserProfile -Filter ("SID='"+$Profile.SID+"'") -OperationTimeoutSec 5 -ErrorAction Stop)
  if($fresh.Count -ne 1) { throw 'Final profile identity ambiguous' }
  $p=$fresh[0]; $r.Profile=$p
  if($p.LocalPath -ne $Profile.LocalPath -or $p.Loaded -ne $false -or $p.Special -ne $false -or $null -eq $p.Status -or [int64]$p.Status -ne 0 -or $p.RoamingConfigured -ne $false -or $p.RoamingPreference -ne $false -or $p.refCount -gt 0) { throw 'Final profile loaded/status/identity changed' }
  $r.LoadedHive=(Test-Path -LiteralPath ('Registry::HKEY_USERS\'+$Profile.SID) -ErrorAction Stop) -or (Test-Path -LiteralPath ('Registry::HKEY_USERS\'+$Profile.SID+'_Classes') -ErrorAction Stop)
  if($r.LoadedHive) { throw 'Final profile hive appeared' }
  $r.Clear=$true; $r.Reason='Final session, CIM identity/loaded/status and hive vetoes clear'
 } catch { $r.Reason=$_.Exception.Message }
 [pscustomobject]$r
}

function Invoke-SmProfileWorker {
 param($Profiles,[int]$Days,[datetime]$Now,[double]$Seconds,[string]$Directory,[string]$Mode='Full')
 $watch=[Diagnostics.Stopwatch]::StartNew()
 $r=[ordered]@{Complete=$false;TimedOut=$false;GuardChanged=$false;Reasons=@();Error=$null;Entries=@();FinalVeto=$null;ReportContext=$null;ElapsedSeconds=0.0}
 $process=$null
 try {
  if($Seconds -le 0) { $r.TimedOut=$true; throw 'Aggregate profile evidence budget exhausted' }
  if(-not (Test-SmSafePath $Directory $env:ProgramData)) { throw 'Unsafe profile evidence directory' }
  $id=[guid]::NewGuid().ToString('n')
  $inputPath=Join-Path $Directory ($id+'.input.xml'); $outputPath=Join-Path $Directory ($id+'.output.xml'); $workerPath=Join-Path $Directory ($id+'.worker.ps1')
  [pscustomobject]@{Profiles=@($Profiles);Days=$Days;Now=$Now;Mode=$Mode} | Export-Clixml -LiteralPath $inputPath -Depth 6 -ErrorAction Stop
  $worker=@'
param([string]$PackagePath,[string]$InputPath,[string]$OutputPath)
$ErrorActionPreference='Stop'
$env:RELIAN_DEPLOY_TEST='1'
. $PackagePath
$result=[ordered]@{Complete=$false;Error=$null;Entries=@();FinalVeto=$null;ReportContext=$null}
try {
 $data=Import-Clixml -LiteralPath $InputPath
 $manifest=Join-Path (Split-Path -Parent $PackagePath) 'PSAppDeployToolkit\PSAppDeployToolkit.psd1'
 Import-Module -FullyQualifiedName @{ModuleName=$manifest;ModuleVersion='4.1.8';Guid='8c3c366b-8606-4576-9f2d-4051144f7ca2'} -Force -ErrorAction Stop
 if($data.Mode -eq 'Final') { $result.FinalVeto=Get-SmFinalProfileVeto $data.Profiles[0] }
 else {
  $context=Get-SmProfileContext $data.Days $data.Now
  foreach($profile in $data.Profiles) {
   $evidence=Get-SmProfileEvidence $profile $data.Days $data.Now $context
   $result.Entries+=[pscustomobject]@{SID=$profile.SID;Path=$profile.LocalPath;Evidence=$evidence}
  }
  if($data.Mode -eq 'Report') { $result.ReportContext=Get-SmReportContext $context $data.Profiles $data.Now }
 }
 $result.Complete=$true
} catch { $result.Error=$_.Exception.Message }
[pscustomobject]$result | Export-Clixml -LiteralPath $OutputPath -Depth 16
'@
  Set-Content -LiteralPath $workerPath -Value $worker -Encoding UTF8 -ErrorAction Stop
  $quote={ param($Text) "'"+$Text.Replace("'","''")+"'" }
  $command='& '+(& $quote $workerPath)+' -PackagePath '+(& $quote $script:SmPackagePath)+' -InputPath '+(& $quote $inputPath)+' -OutputPath '+(& $quote $outputPath)
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $remaining=$Seconds-$watch.Elapsed.TotalSeconds
  if($remaining -le 0) { $r.TimedOut=$true; throw 'Aggregate profile evidence budget exhausted before launch' }
  $process=Start-Process -FilePath $exe -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+$encoded) -RedirectStandardOutput (Join-Path $Directory ($id+'.stdout.log')) -RedirectStandardError (Join-Path $Directory ($id+'.stderr.log')) -WindowStyle Hidden -PassThru -ErrorAction Stop
  $wait=Wait-SmEvidenceWorker $process ($Seconds-$watch.Elapsed.TotalSeconds)
  $r.TimedOut=$wait.TimedOut; $r.GuardChanged=$wait.GuardChanged; $r.Reasons=$wait.Reasons
  if($r.TimedOut -or $r.GuardChanged) { throw 'Read-only profile evidence interrupted; all profiles require review' }
  if($process.ExitCode -ne 0 -or -not (Test-SmSafePath $outputPath $Directory)) { throw 'Read-only evidence worker failed or produced unsafe output' }
  $out=Import-Clixml -LiteralPath $outputPath -ErrorAction Stop
  $r.Complete=$out.Complete; $r.Entries=@($out.Entries); $r.FinalVeto=$out.FinalVeto; $r.ReportContext=$out.ReportContext; $r.Error=$out.Error
 } catch {
  $r.Error=$_.Exception.Message
  if($process) { try { if(-not $process.HasExited) { $process.Kill() } } catch { $r.Reasons+='Read-only worker could not be confirmed stopped' } }
 }
 finally { if($process) { $process.Dispose() }; $r.ElapsedSeconds=$watch.Elapsed.TotalSeconds }
 [pscustomobject]$r
}

function New-SmMissingEvidence {
 param([string]$Reason)
 [pscustomobject]@{Registry=@{ReadState='unknown'};Identity=@{Resolved=$false};Sessions=@{Known=$false};Hives=@{Known=$false};Events=@{ProbeComplete=$false;Recent=@()};NtUser=@{DatUtc=$null;Errors=@()};Errors=@($Reason);CollectionError=$Reason}
}
$script:SmCollectProfiles={ param($Profiles,$Days,$Now,$Seconds,$Directory,$Mode='Full') Invoke-SmProfileWorker $Profiles $Days $Now $Seconds $Directory $Mode }

# Literal canonical containment and EVERY ancestor checked immediately before deletion.
# Reparse points and offline/recall files are never enumerated or deleted.
function Test-SmSafePath {
 param([string]$Path,[string]$Root)
 try {
  if ($Path.IndexOfAny([char[]]'*?[]') -ge 0 -or $Path -match '(^\\\\|:)+' -and $Path -notmatch '^[A-Za-z]:\\') { return $false }
  $r=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
  $p=[IO.Path]::GetFullPath($Path)
  if (-not $p.StartsWith($r+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { return $false }
  $cur=$p
  while ($cur) {
   $item=Get-Item -LiteralPath $cur -Force -ErrorAction Stop
   if (([int64]$item.Attributes -band (1024 -bor 4096 -bor 262144 -bor 4194304)) -ne 0) { return $false }
   $cur=[IO.Path]::GetDirectoryName($cur)
  }
 } catch { return $false }; return $true
}

function Test-SmScanDirectory {
 param([string]$Path)
 try {
  $cur=[IO.Path]::GetFullPath($Path)
  while($cur) {
   $item=Get-Item -LiteralPath $cur -Force -ErrorAction Stop
   if(-not $item.PSIsContainer -or ([int64]$item.Attributes -band (1024 -bor 4096 -bor 262144 -bor 4194304)) -ne 0) { return $false }
   $cur=[IO.Path]::GetDirectoryName($cur)
  }
  return $true
 } catch { return $false }
}

function Get-SmProfileSize {
 param($Scan,[string]$Path)
 if(-not $Path) { return [pscustomobject]@{LogicalBytes=0;Partial=$true} }
 $prefix=[IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
 $covered=@($Scan.Roots | Where-Object { $_ } | Where-Object { $scanRoot=[IO.Path]::GetFullPath($_).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar; $prefix.StartsWith($scanRoot,[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
 $observed=@($Scan.Files | Where-Object { [IO.Path]::GetFullPath($_.Path).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) })
 [pscustomobject]@{LogicalBytes=[int64]($observed | Measure-Object LogicalBytes -Sum).Sum;Partial=(-not $covered -or $Scan.Partial -or @($Scan.Errors).Count -gt 0 -or $Scan.SkippedReparseOrCloud -gt 0)}
}

# ---- ProfileReport: report-only. Nothing below deletes, writes or changes a setting. ----

# Byte census of one profile from directory metadata only: no file is opened or recalled.
# Junctions and symlinks are never entered. A non-link (cloud) reparse directory is entered
# only inside a top-level OneDrive* folder; recall-on-open directories are skipped. A link
# swapped in mid-walk can only inflate these read-only counts. Hard links count per name.
# Inside OneDrive, an unpopulated (recall-on-open or offline) cloud directory holds nothing local,
# so it is counted, not skipped. Windows' own hidden+system compatibility junctions point back
# into the profile, which is walked by its real paths, so they do not make the size partial.
# OneDrive files without a reparse tag were never converted to placeholders: not yet uploaded.
# The leading comma returns the lazy enumerator itself, so budgets and guards apply per entry.
# Like Get-SmScan, the walk stays in this process: local profile metadata reads are not the
# identity/event-provider calls that need the killable worker, and recall-on-open dirs are skipped.
$script:SmEnumerate={ param($Dir) ,([IO.DirectoryInfo]::new($Dir)).EnumerateFileSystemInfos() }
$script:SmCompatJunctions=@('\Application Data','\Cookies','\Local Settings','\My Documents','\NetHood','\PrintHood','\Recent','\SendTo','\Start Menu','\Templates','\AppData\Local\Application Data','\AppData\Local\History','\AppData\Local\Temporary Internet Files','\Documents\My Music','\Documents\My Pictures','\Documents\My Videos')
# Names OneDrive never uploads (docs: invalid file names and types), plus its sync-root marker.
$script:SmSyncIgnored='^(desktop\.ini|~\$.*|\.849C9593-D756-4E56-8D6E-42412F2A707B)$'
function Get-SmProfileBytes {
 param([string]$Path,[string]$RecycleRoot,[int]$FileLimit,[double]$Seconds,$RecentSinceUtc=$null)
 $b=[ordered]@{ost=[int64]0;pst=[int64]0;oneDriveHydrated=[int64]0;oneDriveOnlineOnly=[int64]0;teamsCache=[int64]0;browserCache=[int64]0;temp=[int64]0;downloads=[int64]0;recycleBin=[int64]0;outsideKfm=[int64]0}
 $r=[ordered]@{TotalBytes=[int64]0;Bytes=$b;Partial=$false;Light=$false;EntriesVisited=0;Skipped=0;CompatLinks=0;CloudDirs=0;PstFiles=0;OneDriveLocalOnly=0;OneDriveRecent=$(if($RecentSinceUtc){0});OutsideKfmFiles=0;Errors=@()}
 $watch=[Diagnostics.Stopwatch]::StartNew(); $nextGuard=0; $lastGuard=-2
 $queue=New-Object 'Collections.Generic.Queue[object]'; $base=$Path.TrimEnd('\','/')
 if(Test-SmScanDirectory $base) { $queue.Enqueue(@($base,$false)) } else { $r.Partial=$true; $r.Errors+='Profile root missing, not a directory, or has a reparse ancestor' }
 if($RecycleRoot -and (Test-Path -LiteralPath $RecycleRoot)) { if(Test-SmScanDirectory $RecycleRoot) { $queue.Enqueue(@($RecycleRoot,$true)) } else { $r.Partial=$true; $r.Errors+='Recycle Bin root unsafe' } }
 :walk while($queue.Count) {
  $item=$queue.Dequeue(); $dir=$item[0]; $recycle=$item[1]
  try {
   $entries=& $script:SmEnumerate $dir
   foreach($e in $entries) {
    if($r.EntriesVisited -ge $nextGuard -or $watch.Elapsed.TotalSeconds-$lastGuard -ge 2) {
     try { $g=& $script:SmScanGuard; if($null -eq $g -or $g.Light) { $r.Light=$true } } catch { $r.Light=$true }
     $lastGuard=$watch.Elapsed.TotalSeconds; $nextGuard=$r.EntriesVisited+128
     if($r.Light) { $r.Partial=$true; break walk }
    }
    if($r.EntriesVisited -ge $FileLimit -or $watch.Elapsed.TotalSeconds -ge $Seconds) { $r.Partial=$true; break walk }
    $r.EntriesVisited++
    $attr=[int64]$e.Attributes; $rel=if($recycle){''}else{"$($e.FullName)".Substring($base.Length)}
    $oneDrive=$rel -match '^[\\/]OneDrive[^\\/]*([\\/]|$)'
    if($attr -band 16) {
     if($oneDrive -and -not $recycle -and -not $e.LinkType -and ($attr -band (4096 -bor 262144 -bor 4194304))) { $r.CloudDirs++; continue }
     if($e.LinkType -eq 'Junction' -and ($attr -band 6) -eq 6 -and $script:SmCompatJunctions -contains $rel) { $r.CompatLinks++; continue }
     if(($attr -band (4096 -bor 262144 -bor 4194304)) -or (($attr -band 1024) -and ($recycle -or -not $oneDrive -or $e.LinkType))) { $r.Skipped++; continue }
     $queue.Enqueue(@($e.FullName,$recycle)); continue
    }
    if(($attr -band 1024) -and $e.LinkType) { $r.Skipped++; continue }
    $len=[int64]$e.Length
    if($attr -band (4096 -bor 4194304)) { if($oneDrive) { $b.oneDriveOnlineOnly+=$len }; continue }
    if($recycle) { $b.recycleBin+=$len; continue }
    $r.TotalBytes+=$len; $leaf=($rel -split '[\\/]')[-1]
    if($oneDrive) {
     if(-not ($attr -band 1024) -and $leaf -notmatch $script:SmSyncIgnored) { $r.OneDriveLocalOnly++ }
     # A local file written in the last day of the user's session may not have uploaded before sign-out.
     if($RecentSinceUtc -and $e.LastWriteTimeUtc -ge $RecentSinceUtc) { $r.OneDriveRecent++ }
    }
    elseif($rel -match '^[\\/](Desktop|Documents|Pictures)[\\/]' -and $leaf -ne 'desktop.ini') { $b.outsideKfm+=$len; $r.OutsideKfmFiles++ }
    $cat=switch -Regex ($rel) {
     '\.pst$' { 'pst'; break }
     '\.ost$' { 'ost'; break }
     '^[\\/]OneDrive[^\\/]*[\\/]' { 'oneDriveHydrated'; break }
     '^[\\/]AppData[\\/](Local[\\/]Packages[\\/]MSTeams_[^\\/]+[\\/]LocalCache|Roaming[\\/]Microsoft[\\/]Teams)[\\/]' { 'teamsCache'; break }
     '^[\\/]AppData[\\/]Local[\\/](Microsoft[\\/]Edge|Google[\\/]Chrome)[\\/]User Data[\\/].*[\\/](Cache|Code Cache|GPUCache|CacheStorage)[\\/]' { 'browserCache'; break }
     '^[\\/]AppData[\\/]Local[\\/]Temp[\\/]' { 'temp'; break }
     '^[\\/]Downloads[\\/]' { 'downloads'; break }
    }
    if($cat) { $b[$cat]+=$len; if($cat -eq 'pst') { $r.PstFiles++ } }
   }
  } catch { $r.Partial=$true; if($r.Errors.Count -lt 5) { $r.Errors+=$_.Exception.Message } }
 }
 if($r.Skipped) { $r.Partial=$true }
 [pscustomobject]$r
}

# Identity context for the report. Runs inside the read-only evidence worker because
# local-group and event-provider lookups can hang on an unreachable domain.
function Get-SmReportContext {
 param($Context,$Profiles,[datetime]$Now)
 $c=[ordered]@{Log=[pscustomobject]@{Known=$false;OldestUtc=$null;NewestUtc=$null};Admins=[pscustomobject]@{Known=$false;Sids=@()};IntuneUpns=@();LapsNames=@();Upns=@{};LogonCounts=@{};LogonsComplete=$false;Errors=@()}
 try {
  $oldest=Get-WinEvent -LogName Security -Oldest -MaxEvents 1 -ErrorAction Stop
  $newest=Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction Stop
  $c.Log=[pscustomobject]@{Known=$true;OldestUtc=$oldest.TimeCreated.ToUniversalTime();NewestUtc=$newest.TimeCreated.ToUniversalTime()}
 } catch { $c.Errors+=('Security log range: '+$_.Exception.Message) }
 try { $c.Admins=[pscustomobject]@{Known=$true;Sids=@(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { "$($_.SID)" })} }
 catch {
  # Get-LocalGroupMember fails on orphaned or Entra SIDs and in 32-bit hosts; ADSI does not.
  try {
   $name=(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
   $sids=@(([ADSI]('WinNT://./'+$name+',group')).psbase.Invoke('Members') | ForEach-Object { (New-Object Security.Principal.SecurityIdentifier([byte[]]$_.GetType().InvokeMember('objectSid','GetProperty',$null,$_,$null),0)).Value })
   $c.Admins=[pscustomobject]@{Known=$true;Sids=$sids}
  } catch { $c.Errors+=('Local Administrators: '+$_.Exception.Message) }
 }
 try {
  $key='HKLM:\SOFTWARE\Microsoft\Enrollments'
  if(Test-Path -LiteralPath $key) { $c.IntuneUpns=@(Get-ChildItem -LiteralPath $key -ErrorAction Stop | Select-Object -First 64 | ForEach-Object { "$((Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).UPN)" } | Where-Object { $_ -match '^[^@\s]+@[^@\s]+$' } | Select-Object -Unique) }
 } catch { $c.Errors+=('Intune enrollment: '+$_.Exception.Message) }
 foreach($k in @(@('HKLM:\SOFTWARE\Microsoft\Policies\LAPS','AdministratorAccountName'),@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\LAPS','AdministratorAccountName'),@('HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd','AdminAccountName'))) {
  try { $v=(Get-ItemProperty -LiteralPath $k[0] -ErrorAction Stop).($k[1]); if($v) { $c.LapsNames+="$v" } } catch { }
 }
 foreach($p in @($Profiles)) {
  if("$($p.SID)" -match '^S-1-12-1-[\d-]+$') { try { $u=(Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\'+$p.SID+'\IdentityCache\'+$p.SID) -ErrorAction Stop).UserName; if($u) { $c.Upns["$($p.SID)"]="$u" } } catch { } }
 }
 # Human logons only: window manager, font driver and built-in RID accounts are not users.
 foreach($e in @($Context.Events.Recent)) { if($e.Sid -match '^S-1-(5-21-|12-1-)' -and $e.Sid -notmatch '-(500|501|503|504)$') { $c.LogonCounts[$e.Sid]=1+[int]$c.LogonCounts[$e.Sid] } }
 $c.LogonsComplete=($Context.Events.ProbeComplete -and -not $Context.Events.Truncated)
 [pscustomobject]$c
}

# Offline read of an unloaded NTUSER.DAT (regf format). The hive is never loaded or mounted:
# loading replays its logs into the file and holds it against the user's next logon. A dirty
# hive (base-block sequence numbers differ) needs those logs, so it is unreadable, never guessed.
# Returns $null for an absent key, else its subkey names and its string values by lower-case
# name (a non-string value is present with a $null value). Malformed structure throws.
function Get-SmHiveKey {
 param([byte[]]$Hive,[string]$Path)
 $h=$Hive
 $u32={ param([int64]$o) if($o -lt 0 -or $o+4 -gt $h.Length) { throw 'Hive offset out of range' }; [int64][BitConverter]::ToUInt32($h,[int]$o) }
 $u16={ param([int64]$o) if($o -lt 0 -or $o+2 -gt $h.Length) { throw 'Hive offset out of range' }; [int][BitConverter]::ToUInt16($h,[int]$o) }
 $cell={ param([int64]$off) $o=4096+$off+4; if($off -lt 0 -or $o+4 -gt $h.Length) { throw 'Hive cell out of range' }; $o }
 $is={ param([int64]$o,[string]$sig) [Text.Encoding]::ASCII.GetString($h,[int]$o,2) -ceq $sig }
 $text={ param([int64]$o,[int64]$len,[bool]$latin1) if($o+$len -gt $h.Length) { throw 'Hive data out of range' }; if($latin1) { [Text.Encoding]::GetEncoding(28591).GetString($h,[int]$o,[int]$len) } else { [Text.Encoding]::Unicode.GetString($h,[int]$o,[int]$len) } }
 $keyName={ param([int64]$nk) & $text ($nk+0x4C) (& $u16 ($nk+0x48)) ([bool]((& $u16 ($nk+2)) -band 0x20)) }
 $children={ param([int64]$nk)
  $out=New-Object Collections.Generic.List[int64]
  if(-not (& $u32 ($nk+0x14))) { return ,$out }
  $lists=New-Object Collections.Generic.Queue[int64]; $lists.Enqueue((& $cell (& $u32 ($nk+0x1C)))); $seen=0
  while($lists.Count) {
   $l=$lists.Dequeue(); if(++$seen -gt 4096) { throw 'Hive subkey index too large or cyclic' }
   $n=& $u16 ($l+2)
   if(& $is $l 'ri') { for($i=0;$i -lt $n;$i++) { $lists.Enqueue((& $cell (& $u32 ($l+4+4*$i)))) } }
   elseif((& $is $l 'lf') -or (& $is $l 'lh')) { for($i=0;$i -lt $n;$i++) { $out.Add((& $cell (& $u32 ($l+4+8*$i)))) } }
   elseif(& $is $l 'li') { for($i=0;$i -lt $n;$i++) { $out.Add((& $cell (& $u32 ($l+4+4*$i)))) } }
   else { throw 'Unknown hive subkey list' }
  }
  ,$out
 }
 if($h.Length -lt 8192 -or [Text.Encoding]::ASCII.GetString($h,0,4) -cne 'regf') { throw 'Not a registry hive' }
 if((& $u32 4) -ne (& $u32 8)) { throw 'Hive is dirty: its transaction logs would be needed' }
 $nk=& $cell (& $u32 0x24)
 foreach($part in @($Path.Split('\') | Where-Object { $_ })) {
  if(-not (& $is $nk 'nk')) { throw 'Malformed hive key' }
  $next=$null
  foreach($c in (& $children $nk)) { if(-not (& $is $c 'nk')) { throw 'Malformed hive key' }; if([string]::Equals((& $keyName $c),$part,[StringComparison]::OrdinalIgnoreCase)) { $next=$c; break } }
  if($null -eq $next) { return $null }; $nk=$next
 }
 if(-not (& $is $nk 'nk')) { throw 'Malformed hive key' }
 $values=@{}; $count=& $u32 ($nk+0x24)
 if($count -gt 65536) { throw 'Hive value list too large' }
 if($count) {
  $list=& $cell (& $u32 ($nk+0x28))
  for($i=0;$i -lt $count;$i++) {
   $vk=& $cell (& $u32 ($list+4*$i)); if(-not (& $is $vk 'vk')) { throw 'Malformed hive value' }
   $nameLength=& $u16 ($vk+2); $name=if($nameLength) { & $text ($vk+0x14) $nameLength ([bool]((& $u16 ($vk+0x10)) -band 1)) } else { '' }
   $size=& $u32 ($vk+4); $length=$size -band 2147483647; $data=$null
   if((& $u32 ($vk+0xC)) -in @(1,2) -and $length -le 16344) {
    $at=if($size -band 2147483648) { if($length -gt 4) { throw 'Malformed inline hive value' }; $vk+8 } else { & $cell (& $u32 ($vk+8)) }
    $data=(& $text $at $length $false).Split([char]0)[0]
   }
   $values[$name.ToLowerInvariant()]=$data
  }
 }
 [pscustomobject]@{Values=$values;Subkeys=@(foreach($c in (& $children $nk)) { & $keyName $c })}
}

# One bounded read, closed at once. Read/write/delete sharing never blocks another handle, but a
# logon needing the file exclusively in those milliseconds would fail, so only profiles the age
# engine already found unloaded and stale are read.
$script:SmReadHive={ param([string]$Path,[string]$Root)
 if(-not (Test-SmSafePath $Path $Root)) { throw 'NTUSER.DAT missing, outside the profile or behind a reparse point' }
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]'ReadWrite, Delete')
 try {
  if($stream.Length -gt 67108864) { throw 'NTUSER.DAT is larger than 64 MB' }
  $buffer=New-Object byte[] ([int]$stream.Length); $read=0
  while($read -lt $buffer.Length) { $n=$stream.Read($buffer,$read,$buffer.Length-$read); if($n -le 0) { throw 'NTUSER.DAT short read' }; $read+=$n }
  ,$buffer
 } finally { $stream.Dispose() }
}

# Strictly below, compared as literal Windows paths: no relative, empty, dot or trailing-dot/space
# segment, no device, UNC or alternate-stream form, so a crafted value cannot alias another folder.
function Test-SmUnderPath {
 param([string]$Child,[string]$Parent)
 $c=$Child.TrimEnd('\'); $p=$Parent.TrimEnd('\')
 foreach($x in @($c,$p)) { if($x -notmatch '^[A-Za-z]:(\\[^\\/:*?"<>|\x00-\x1f]+)+$' -or $x -match '\\\.{1,2}(\\|$)|[. ](\\|$)') { return $false } }
 $c.StartsWith($p+'\',[StringComparison]::OrdinalIgnoreCase)
}

# Desktop, Documents and Pictures, each by its legacy User Shell Folders name and its known-folder GUID.
$script:SmKfmFolders=@(@('Desktop','{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}'),@('Personal','{F42EE2D3-909F-4907-8871-4C22FC0BF756}'),@('My Pictures','{0DDD015D-B06C-45D5-8C4C-F59713854639}'))
# KFM is verified only when all three folders (both names, where the GUID one exists) resolve
# strictly inside a OneDrive account's sync root that is a top-level OneDrive* folder of this
# profile, so the byte walk has listed it. Upload state comes from that listing, never by opening
# a file. Any other state, or any read failure, is unverified.
function Get-SmKfmState {
 param([string]$ProfilePath,$Sizes)
 $k=[ordered]@{state='unknown';redirected=0;accounts=0;pendingUploads=$Sizes.OneDriveLocalOnly;recentWrites=$Sizes.OneDriveRecent;outsideKfmFiles=$Sizes.OutsideKfmFiles;error=$null}
 try {
  $root=$ProfilePath.TrimEnd('\')
  $hive=& $script:SmReadHive ($root+'\NTUSER.DAT') $root
  $folders=Get-SmHiveKey $hive 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
  $accounts=Get-SmHiveKey $hive 'Software\Microsoft\OneDrive\Accounts'
  $syncRoots=@(foreach($n in @($accounts.Subkeys | Where-Object { $_ -match '^(Business\d{1,3}|Personal)$' })) { "$((Get-SmHiveKey $hive ('Software\Microsoft\OneDrive\Accounts\'+$n)).Values['userfolder'])".TrimEnd('\') | Where-Object { $_ } })
  $k.accounts=$syncRoots.Count
  $walked=@($syncRoots | Where-Object { (Test-SmUnderPath $_ $root) -and $_.Substring($root.Length+1) -match '^OneDrive[^\\]*$' })
  $state='verified'
  foreach($f in $script:SmKfmFolders) {
   # The legacy value must exist; the GUID value counts only where present.
   $targets=@(foreach($n in $f) {
    $key=$n.ToLowerInvariant()
    if($folders -and $folders.Values.ContainsKey($key)) { $v="$($folders.Values[$key])"; if($v -match '^%USERPROFILE%(\\.*)?$') { $root+$Matches[1] } else { $v } }
    elseif($n -eq $f[0]) { '' }
   })
   $inWalked=@($targets | Where-Object { $t=$_; $t -notmatch '%' -and @($walked | Where-Object { Test-SmUnderPath $t $_ }).Count })
   if($inWalked.Count -eq $targets.Count) { $k.redirected++; continue }
   $inAny=@($targets | Where-Object { $t=$_; $t -notmatch '%' -and @($syncRoots | Where-Object { Test-SmUnderPath $t $_ }).Count })
   if($state -eq 'verified') { $state=if($inAny.Count -eq $targets.Count) {'syncRootNotWalked'} else {'notRedirected'} }
  }
  $k.state=$state
 } catch { $k.state='unknown'; $k.error=([string]$_.Exception.Message).Substring(0,[math]::Min(80,([string]$_.Exception.Message).Length)) }
 [pscustomobject]$k
}

# What a delete run would decide. Gates only narrow the age engine's StaleCandidate, and a
# StaleCandidate here is still only a report line: nothing in this package acts on it.
function Get-SmReportDecision {
 param([string]$Decision,[string]$Reason,$F)
 $out={ param($d,$why) [pscustomobject]@{Decision=$d;Reason=$why} }
 if($Decision -eq 'Protected' -or $Decision -like 'Keep*') { return (& $out $Decision $Reason) }
 if($F.IsPrimary) { return (& $out 'KeepPrimaryUser' 'Primary user: Intune enrollment, top 4624 logon SID or caller hint') }
 if($F.IsService) { return (& $out 'Protected' 'Service, technician or LAPS account name') }
 if($F.IsAdmin) { return (& $out 'Protected' 'Member of local Administrators') }
 if($Decision -ne 'StaleCandidate') { return (& $out $Decision $Reason) }
 if(-not $F.Shared) { return (& $out 'KeepNotSharedDevice' 'Stale by age, but this device is not on the shared list; personal devices never delete profiles') }
 if(-not $F.AdminKnown) { return (& $out 'ReviewAdminUnknown' 'Local Administrators membership could not be read') }
 if(-not $F.PrimaryKnown) { return (& $out 'ReviewPrimaryUnknown' 'No primary-user source was available') }
 if($null -eq $F.CoverageDays -or $F.CoverageDays -lt $F.AgeDays) { return (& $out 'ReviewLogCoverage' 'Security log does not cover the threshold window or its clock is inconsistent; age rests on ProfileList only') }
 if($F.SizePartial -or $null -eq $F.PstBytes -or $F.PstBytes -gt 0 -or $null -eq $F.PstFiles -or $F.PstFiles -gt 0) { return (& $out 'ReviewPst' 'PST present (an OST alone re-downloads), or not ruled out because the size walk was partial') }
 $k=$F.Kfm
 if(-not $k -or $k.state -ne 'verified') {
  $code=switch("$($k.state)") { 'notRedirected' {'ReviewKfmNotRedirected'} 'syncRootNotWalked' {'ReviewKfmSyncRootNotWalked'} default {'ReviewKfmUnknown'} }
  return (& $out $code ('OneDrive KFM not verified for Desktop, Documents and Pictures: '+$(if($k){"$($k.state) $($k.error)".Trim()}else{'not probed'})))
 }
 if($null -eq $k.pendingUploads -or $k.pendingUploads -gt 0 -or $null -eq $k.recentWrites -or $k.recentWrites -gt 0) { return (& $out 'ReviewKfmPendingUploads' 'OneDrive files not yet uploaded, written in the last day of use, or not countable') }
 if($null -eq $k.outsideKfmFiles -or $k.outsideKfmFiles -gt 0) { return (& $out 'ReviewOutsideKfm' 'Files remain in the profile''s own Desktop, Documents or Pictures, outside OneDrive') }
 & $out 'StaleCandidate' 'Every gate passed: stale on a shared device, KFM verified, no pending upload, no PST. Report line only; nothing is deleted'
}

function Get-SmProfileReport {
 param($A,$Assessed,$Context,[datetime]$Now,[string]$ComputerName=$env:COMPUTERNAME)
 $rep=[ordered]@{EventLog=$null;DeviceClass=$null;Profiles=@();Summary=$null;Errors=@()}
 if(-not $Context) { $rep.Errors+='Report identity context unavailable; candidates require review'; $Context=[pscustomobject]@{Log=$null;Admins=$null;IntuneUpns=@();LapsNames=@();Upns=@{};LogonCounts=@{};LogonsComplete=$false;Errors=@()} }
 $rep.Errors+=@($Context.Errors | Select-Object -First 5)
 $iso={ param($d) if($d) { ([datetime]$d).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } }
 $lower={ param($s) if("$s") { "$s".ToLowerInvariant() } }
 # A newest event in the future or a log silent for 2 days means the clock or log is not trustworthy.
 $log=$Context.Log; $coverage=$null
 if($log.Known -and $log.NewestUtc -le $Now.AddHours(1) -and $log.NewestUtc -ge $Now.AddDays(-2)) { $coverage=[int][math]::Floor(($Now-$log.OldestUtc).TotalDays) }
 $counts=$Context.LogonCounts; if(-not $counts) { $counts=@{} }; $total=0; $max=0
 foreach($k in @($counts.Keys)) { $total+=$counts[$k]; if($counts[$k] -gt $max) { $max=$counts[$k] } }
 $top=@(if($max) { @($counts.Keys) | Where-Object { $counts[$_] -eq $max } })
 $distinct=@($counts.Keys).Count
 $shared=[bool]($ComputerName -and @($A.SharedDevices) -contains $ComputerName)
 $rep.EventLog=[ordered]@{securityOldestUtc=(& $iso $log.OldestUtc);securityNewestUtc=(& $iso $log.NewestUtc);coverageDays=$coverage;logonsComplete=[bool]$Context.LogonsComplete}
 $rep.DeviceClass=[ordered]@{distinctInteractiveSids=$distinct;topSidShare=$(if($total){[math]::Round($max/$total,2)}else{$null});suggested=$(switch($distinct){0{'unknown'}1{'personal'}2{'secondary'}default{'shared'}});configuredShared=$shared}
 $intune=@(foreach($u in @($Context.IntuneUpns)) { & $lower $u; & $lower ("$u" -split '@')[0] }) | Where-Object { $_ }
 $hint="$($A.PrimaryUserHint)".Trim(); $leaf=($hint -split '\\')[-1]
 $hinted=@(if($hint) { & $lower $hint; & $lower $leaf; & $lower ($leaf -split '@')[0] }) | Where-Object { $_ }
 $primaryKnown=[bool]($top.Count -or @($intune).Count -or @($hinted).Count)
 $adminKnown=[bool]$Context.Admins.Known; $laps=@($Context.LapsNames | ForEach-Object { & $lower $_ })
 $watch=[Diagnostics.Stopwatch]::StartNew(); $left=@($Assessed).Count; $used=0; $light=$false
 foreach($p in @($Assessed)) {
  $sid="$($p.SID)"; $account="$($p.Evidence.Identity.Account)"; $user=($account -split '\\')[-1]; $upn="$($Context.Upns[$sid])"
  $names=@($sid,$account,$user,$upn,($upn -split '@')[0],("$($p.Path)" -split '[\\/]')[-1] | Where-Object { $_ } | ForEach-Object { & $lower $_ })
  $source=if(@($names | Where-Object { $intune -contains $_ }).Count) {'intune'} elseif($top -contains $sid) {'logon4624'} elseif(@($names | Where-Object { $hinted -contains $_ }).Count) {'hint'} else {$null}
  $isAdmin=[bool]($adminKnown -and @($Context.Admins.Sids) -contains $sid)
  $isService=[bool]($user -match '^(opadmin|admin|svc)' -or $user -match '\$$' -or ($user -and $laps -contains (& $lower $user)))
  $unload=$p.Evidence.Registry.Unload; $unloadUtc=if($unload.State -eq 'valid') { $unload.TimestampUtc }
  $sizes=$null; $kfm=$null
  if(-not $light -and (Test-SmProfilePath $p.Path)) {
   # Shares the run's MaxFiles/MaxSeconds as a separate budget, split over the profiles left.
   $volume=[IO.Path]::GetPathRoot("$($p.Path)"); $recycle=if($volume -and $sid -match '^S-1-\d+(-\d+)+$') { Join-Path $volume ('$Recycle.Bin\'+$sid) }
   $sizes=Get-SmProfileBytes $p.Path $recycle ([int][math]::Floor(($A.MaxFiles-$used)/[math]::Max(1,$left))) (($A.MaxSeconds-$watch.Elapsed.TotalSeconds)/[math]::Max(1,$left)) $(if($unloadUtc){$unloadUtc.AddDays(-1)})
   $used+=$sizes.EntriesVisited
   if($sizes.Light) { $light=$true; $rep.Errors+='Setup or unknown servicing appeared; remaining profile sizes withheld' }
  }
  $left--
  # The hive is read only for a profile the age engine found unloaded and stale.
  if($sizes -and -not $light -and $p.Decision -eq 'StaleCandidate') { $kfm=Get-SmKfmState $p.Path $sizes }
  $last=@($p.Evidence.Events.Recent | Where-Object { $_.Sid -eq $sid } | Sort-Object TimeUtc -Descending | Select-Object -First 1)
  $flags=@{IsPrimary=[bool]$source;IsService=$isService;IsAdmin=$isAdmin;AdminKnown=$adminKnown;PrimaryKnown=$primaryKnown;CoverageDays=$coverage;AgeDays=$A.ProfileAgeDays;PstBytes=$(if($sizes){$sizes.Bytes.pst});PstFiles=$(if($sizes){$sizes.PstFiles});Kfm=$kfm;SizePartial=(-not $sizes -or $sizes.Partial);Shared=$shared}
  $d=Get-SmReportDecision $p.Decision $p.Reason $flags
  $rep.Profiles+=[pscustomobject][ordered]@{sid=$sid;account=$account;path="$($p.Path)";totalBytes=$(if($sizes){$sizes.TotalBytes});sizePartial=$flags.SizePartial;bytes=$(if($sizes){$sizes.Bytes});lastLogon4624Utc=(& $iso $(if($last.Count){$last[0].TimeUtc}));profileUnloadUtc=(& $iso $unloadUtc);ageDays=$(if($unloadUtc){[int][math]::Floor(($Now-$unloadUtc).TotalDays)});ageSource='ProfileList';isPrimary=$flags.IsPrimary;primarySource=$source;isAdmin=$isAdmin;isService=$isService;kfm=$kfm;ageDecision=$p.Decision;decision=$d.Decision;reason=$d.Reason}
 }
 $all=@($rep.Profiles); $cand=@($all | Where-Object { $_.decision -eq 'StaleCandidate' })
 $rep.Summary=[ordered]@{profiles=$all.Count;staleByAge=@($all | Where-Object { $_.ageDecision -eq 'StaleCandidate' }).Count;candidates=$cand.Count;candidateBytes=[int64]($cand | Measure-Object totalBytes -Sum).Sum;review=@($all | Where-Object { $_.decision -like 'Review*' }).Count;keep=@($all | Where-Object { $_.decision -like 'Keep*' }).Count;protected=@($all | Where-Object { $_.decision -eq 'Protected' }).Count}
 [pscustomobject]$rep
}

# Compact v2 stdout for a NinjaOne custom field. Counts cover every profile; profile
# entries are ranked (candidates, review, rest by size) and dropped from the tail to fit.
function ConvertTo-SmProfileReportJson {
 param($Report,[int]$MaxBytes=9500)
 $pr=$Report.ProfileReport
 $clip={ param($Value,[int]$Limit) $text=[string]$Value; if($text.Length -gt $Limit) { return $text.Substring(0,$Limit)+'...' }; $text }
 $rank={ param($d) if($d -eq 'StaleCandidate') {0} elseif($d -like 'Review*') {1} else {2} }
 $profiles=@($pr.Profiles | Sort-Object @{Expression={ & $rank $_.decision }},@{Expression={ [int64]$_.totalBytes };Descending=$true} | ForEach-Object {
  $c=[ordered]@{}; foreach($n in $_.PSObject.Properties.Name) { $c[$n]=$_.$n }
  $c.account=& $clip $c.account 64; $c.path=& $clip $c.path 96; $c.reason=& $clip $c.reason 140; $c })
 $doc=[ordered]@{schemaVersion=2;package='storage-maintenance';mode=$Report.Mode;status=$Report.Status;timestamp=$Report.Timestamp;reportPath=(& $clip $Report.ReportPath 200);volumes=@($Report.Before | Select-Object -First 4 | ForEach-Object { [ordered]@{drive=$_.DeviceID;capacityBytes=$_.Size;freeBytes=$_.FreeSpace} });eventLog=$pr.EventLog;deviceClass=$pr.DeviceClass;profiles=$profiles;summary=$pr.Summary;errors=@(@($pr.Errors)+@($Report.Errors) | Select-Object -First 3 | ForEach-Object { & $clip $_ 160 });truncated=$false}
 # A slim entry is about 90 bytes, so more than 100 can never fit; counts stay in the summary.
 if($doc.profiles.Count -gt 100) { $doc.profiles=@($doc.profiles | Select-Object -First 100); $doc.truncated=$true }
 $json=$doc | ConvertTo-Json -Depth 6 -Compress
 # Degrade whole objects only: detail goes first, lowest rank up; whole entries go after every entry is slim.
 $slim=$doc.profiles.Count-1
 while([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxBytes -and $doc.profiles.Count) {
  if($slim -ge 0) { $p=$doc.profiles[$slim]; $doc.profiles[$slim]=[ordered]@{sid=$p.sid;decision=$p.decision;ageDays=$p.ageDays;totalBytes=$p.totalBytes}; $slim-- }
  else { $doc.profiles=@($doc.profiles | Select-Object -First ($doc.profiles.Count-1)) }
  $doc.truncated=$true; $json=$doc | ConvertTo-Json -Depth 6 -Compress
 }
 $json
}

$script:SmScanGuard={ & $script:SmGuards }
function Get-SmScan {
 param([string[]]$Roots,[int]$FileLimit,[int]$Seconds,[int]$AgeDays)
 $watch=[Diagnostics.Stopwatch]::StartNew(); $files=New-Object Collections.Generic.List[object]; $errors=New-Object Collections.Generic.List[string]
 $folders=@{}; $partial=$false; $visited=0; $skipped=0; $light=$false; $guardReasons=@(); $nextGuardEntry=0; $lastGuardSeconds=-2
 $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 $queue=New-Object 'Collections.Generic.Queue[object]'
 foreach($root in $Roots) {
  try { if (Test-Path -LiteralPath $root -PathType Container -ErrorAction Stop) { $queue.Enqueue(@($root,$root)) } else { $partial=$true; if($errors.Count -lt 50) { $errors.Add('Scan root unavailable: '+$root) } } } catch { $partial=$true; if($errors.Count -lt 50) { $errors.Add($_.Exception.Message) } }
 }
 :scanLoop while($queue.Count) {
    if($visited -ge $nextGuardEntry -or $watch.Elapsed.TotalSeconds - $lastGuardSeconds -ge 2) {
     try { $scanGuard=& $script:SmScanGuard; if($null -eq $scanGuard -or $scanGuard.Light) { $light=$true; $guardReasons=@($scanGuard.Reasons) } } catch { $light=$true; $guardReasons=@('unknown scan guard: '+$_.Exception.Message) }
     $lastGuardSeconds=$watch.Elapsed.TotalSeconds; $nextGuardEntry=$visited+128
     if($light) { $partial=$true; break scanLoop }
    }
  if($visited -ge $FileLimit -or $watch.Elapsed.TotalSeconds -ge $Seconds) { $partial=$true; break }
  $pair=$queue.Dequeue(); $dir=$pair[0]; $root=$pair[1]
  if(-not $seen.Add([IO.Path]::GetFullPath($dir))) { continue }
  try {
   if (-not (Test-SmScanDirectory $dir)) { $skipped++; continue }
   $di=Get-Item -LiteralPath $dir -Force -ErrorAction Stop
   if (([int64]$di.Attributes -band (1024 -bor 4096 -bor 262144 -bor 4194304)) -ne 0) { $skipped++; continue }
   # Streaming enumeration; do not materialize an unbounded directory listing.
   foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
    if($visited -ge $nextGuardEntry -or $watch.Elapsed.TotalSeconds - $lastGuardSeconds -ge 2) {
     try { $scanGuard=& $script:SmScanGuard; if($null -eq $scanGuard -or $scanGuard.Light) { $light=$true; $guardReasons=@($scanGuard.Reasons) } } catch { $light=$true; $guardReasons=@('unknown scan guard: '+$_.Exception.Message) }
     $lastGuardSeconds=$watch.Elapsed.TotalSeconds; $nextGuardEntry=$visited+128
     if($light) { $partial=$true; break scanLoop }
    }
    if($visited -ge $FileLimit -or $watch.Elapsed.TotalSeconds -ge $Seconds) { $partial=$true; break }
    $visited++
    try {
     $i=Get-Item -LiteralPath $entry -Force -ErrorAction Stop
     if (([int64]$i.Attributes -band (1024 -bor 4096 -bor 262144 -bor 4194304)) -ne 0) { $skipped++; continue }
     if($i.PSIsContainer) { $queue.Enqueue(@($i.FullName,$root)); continue }
     $f=[pscustomobject]@{ Path=$i.FullName; Root=$root; LogicalBytes=[int64]$i.Length; LastWriteUtc=$i.LastWriteTimeUtc; Old=($i.LastWriteTimeUtc -lt [datetime]::UtcNow.AddDays(-$AgeDays)) }
     $files.Add($f); if(-not $folders.ContainsKey($dir)) { $folders[$dir]=[int64]0 }; $folders[$dir]+=$f.LogicalBytes
    } catch { if($errors.Count -lt 50) { $errors.Add($_.Exception.Message) } }
   }
  } catch { if($errors.Count -lt 50) { $errors.Add($_.Exception.Message) } }
 }
 [pscustomobject]@{ Roots=@($Roots); Files=@($files.ToArray()); TopFiles=@($files | Sort-Object LogicalBytes -Descending | Select-Object -First 20); TopFolders=@($folders.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object { [pscustomobject]@{Path=$_.Key;DirectFileLogicalBytes=$_.Value} }); Partial=($partial -or $errors.Count -gt 0 -or $skipped -gt 0); Light=$light; GuardReasons=$guardReasons; EntriesVisited=$visited; SkippedReparseOrCloud=$skipped; Errors=@($errors.ToArray()); Seconds=$watch.Elapsed.TotalSeconds }
}

# Residual rollback folders are safe only with independent completed-upgrade evidence.
function Get-SmUpgradeDirectoryState {
 param($DirectoryCreatedUtc,[int]$CurrentBuild,$PriorBuilds,[datetime]$InstalledUtc,[datetime]$BootUtc)
 if(-not @($DirectoryCreatedUtc).Count) { return 'absent' }
 if($InstalledUtc.Year -lt 2000 -or $BootUtc -lt $InstalledUtc -or -not @($PriorBuilds | Where-Object { $_ -match '^\d+$' -and [int]$_ -lt $CurrentBuild }).Count) { return 'unknownStaging' }
 foreach($created in $DirectoryCreatedUtc) { if(-not $created -or [datetime]$created -gt $InstalledUtc) { return 'unknownStaging' } }
 'completedResidual'
}
function Test-SmHistoricalUpgrade {
 param($RegistryImage,$IniImage,$Setup,$Values,$State,[int]$CurrentBuild,$PriorBuilds,[datetime]$InstalledUtc,[datetime]$BootUtc,[bool]$MarkerAbsent=$false,$SourceEntries)
 try {
  $InstalledUtc=$InstalledUtc.ToUniversalTime(); $BootUtc=$BootUtc.ToUniversalTime()
  if($RegistryImage -cne 'IMAGE_STATE_COMPLETE' -or $IniImage -cne 'IMAGE_STATE_COMPLETE') { return $false }
  foreach($n in @('SystemSetupInProgress','OOBEInProgress','SetupPhase','SetupType','RestartSetup')) { if($Setup.$n -isnot [ValueType] -or [string]$Setup.$n -cne '0') { return $false } }
  if($MarkerAbsent) {
   if($null -ne $State -or [string]$CurrentBuild -notmatch '^\d{5,6}$' -or $CurrentBuild -lt 10240 -or $InstalledUtc.Year -lt 2000 -or $InstalledUtc -gt $BootUtc -or $BootUtc -gt [datetime]::UtcNow) { return $false }
  } else {
   if($State.status -cne 'running' -or [string]$State.isoBuild -notmatch '^\d{5,6}$' -or [int]$State.isoBuild -ne $CurrentBuild) { return $false }
   $stamp=[datetime]::Parse([string]$State.time,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
   if($stamp.Year -lt 2000 -or $stamp -ge $InstalledUtc -or $InstalledUtc -gt $BootUtc -or $BootUtc -gt [datetime]::UtcNow) { return $false }
  }
  if(-not $Values.ContainsKey('SetupHostResult') -or -not $Values.ContainsKey('DownlevelBuildNumber')) { return $false }
  foreach($n in $Values.Keys) {
   switch -Exact ($n) {
    {$_ -in @('SetupHostResult','SetupHostError','SetupPhase')} { if($Values[$n] -isnot [ValueType] -or [string]$Values[$n] -cne '0') { return $false } }
    'DownlevelBuildNumber' { if([string]$Values[$n] -notmatch '^\d{5,6}$') { return $false } }
    'InstallScenario' { if($Values[$n] -isnot [ValueType] -or [string]$Values[$n] -notmatch '^\d{1,10}$') { return $false } }
    'DownlevelProductName' { if($Values[$n] -isnot [string] -or $Values[$n].Length -gt 256) { return $false } }
    default { return $false }
   }
  }
  if(-not @($PriorBuilds).Count) { return $false }
  foreach($p in $PriorBuilds) { if([string]$p -notmatch '^\d{5,6}$' -or [int]$p -lt 10240 -or [int]$p -ge $CurrentBuild) { return $false } }
  if($MarkerAbsent) {
   $matching=@($SourceEntries | Where-Object { [string]$_.CurrentBuild -eq [string]$Values.DownlevelBuildNumber })
   if(-not $matching.Count) { return $false }
   foreach($entry in $matching) {
    if($entry.InstallDate -isnot [ValueType] -or [string]$entry.InstallDate -notmatch '^\d{1,12}$') { return $false }
    $sourceInstalled=([datetime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)).AddSeconds([double]$entry.InstallDate)
    if($sourceInstalled.Year -lt 2000 -or $sourceInstalled -ge $InstalledUtc) { return $false }
   }
  }
  return ([int]$Values.DownlevelBuildNumber -in @($PriorBuilds | ForEach-Object { [int]$_ }))
 } catch { return $false }
}
function Read-SmBoundedText {
 param([string]$Path,[int]$MaxBytes)
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try { if($stream.Length -gt $MaxBytes) { throw 'Guard file exceeds bound' }; $reader=[IO.StreamReader]::new($stream); try { $buffer=New-Object char[] ($MaxBytes+1); $count=$reader.ReadBlock($buffer,0,$buffer.Length); if($count -gt $MaxBytes) { throw 'Guard file exceeds bound' }; [string]::new($buffer,0,$count) } finally { $reader.Dispose() } } finally { $stream.Dispose() }
}
function Get-SmMoSetupState {
 param($Values,[bool]$Completed)
 if(-not $Values.Count) { return 'residual' }
 if(-not $Completed) { return 'unknownOrActive' }
 foreach($name in $Values.Keys) { if($name -notin @('SetupHostResult','SetupHostError','SetupPhase') -or [string]$Values[$name] -ne '0') { return 'unknownOrActive' } }
 'residual'
}
function Get-SmOwnUpgradeState {
 param($State,[int]$CurrentBuild,[datetime]$BootUtc)
 if($State.status -eq 'staged') {
  try {
   if($CurrentBuild -lt 10240) { return 'unknown' }
   if([string]$State.isoBuild -notmatch '^\d{5,6}$' -or [int]$State.isoBuild -lt 10240 -or -not $State.time) { return 'unknown' }
   $staged=[datetime]::Parse([string]$State.time,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
   if($staged -gt [datetime]::UtcNow) { return 'unknown' }
   if($CurrentBuild -ge [int]$State.isoBuild -or $BootUtc -gt $staged) { return 'residual' }
   return 'staged'
  } catch { return 'unknown' }
 }
 if($State.status -in @('finished','alreadyCurrent','failed','rolledBack')) { return 'residual' }
 'unknown'
}
function Get-SmNativeMarkerPaths {
 # Legacy markers are guard evidence only; never initialize, rewrite or remove them.
 Join-Path $env:ProgramData 'RelianMaintenance\native-active.json'
 Join-Path $env:ProgramData 'Relian\Maintenance\native-active.json'
}
function Get-SmGuards {
 $reasons=New-Object Collections.Generic.List[string]; $light=$false; $historical=$false; $observations=@(); $historicalEvidence=$null
 try {
  if (@(Get-CimInstance Win32_Process -Filter "Name='setup.exe' OR Name='setuphost.exe' OR Name='setupprep.exe' OR Name='dism.exe' OR Name='sfc.exe' OR Name='TiWorker.exe' OR Name='TrustedInstaller.exe' OR Name='msiexec.exe'" -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object { $_.Name -match '^(setup|setuphost|setupprep|dism|sfc|TiWorker|TrustedInstaller|msiexec)\.exe$' }).Count) { $reasons.Add('setup/servicing process'); $light=$true }
  foreach($nativeMarker in @(Get-SmNativeMarkerPaths)) {
   if(Test-Path -LiteralPath $nativeMarker -ErrorAction Stop) { $reasons.Add('native-active marker present; verified process reconciliation required'); $light=$true }
  }
  $setup=Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
  foreach($n in @('SystemSetupInProgress','OOBEInProgress','SetupPhase')) { if($setup.$n) { $reasons.Add("Setup $n"); $light=$true } }
  foreach($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
   if(Test-Path -LiteralPath $key -ErrorAction Stop) { $reasons.Add($key) }
  }
  $session=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
  if($session.PendingFileRenameOperations) { $reasons.Add('pending file rename') }
  $created=@(); foreach($name in @('$WINDOWS.~BT','$WINDOWS.~WS')) { $path=Join-Path $env:SystemDrive $name; if(Test-Path -LiteralPath $path -ErrorAction Stop) { $stageItem=Get-Item -LiteralPath $path -Force -ErrorAction Stop; if(-not $stageItem.PSIsContainer -or ([int64]$stageItem.Attributes -band (1024 -bor 4096)) -ne 0) { throw 'Upgrade staging metadata is not an ordinary readable directory' }; $created+=$stageItem.CreationTimeUtc } }
  $moPath='HKLM:\SYSTEM\Setup\MoSetup\Volatile'; $hasMo=Test-Path -LiteralPath $moPath -ErrorAction Stop
  $state=Join-Path $env:ProgramData 'Relian\FeatureUpgrade\state.json'; $hasState=Test-Path -LiteralPath $state -ErrorAction Stop
  if($hasState -isnot [bool]) { throw 'Feature upgrade marker presence unknown' }
  if($created.Count -or $hasMo -or $hasState) {
   $os=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
   if([string]$os.CurrentBuild -notmatch '^\d{5,6}$') { throw 'Current Windows build unknown' }
   $sourceKeys=@(Get-ChildItem 'HKLM:\SYSTEM\Setup' -ErrorAction Stop | Where-Object { $_.PSChildName -like 'Source OS*' } | Select-Object -First 17)
   if($sourceKeys.Count -gt 16) { throw 'Source OS metadata exceeds bound' }
   $sourceEntries=@($sourceKeys | ForEach-Object { $source=Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop; [pscustomobject]@{CurrentBuild=$source.CurrentBuild;InstallDate=$source.InstallDate} })
   $prior=@($sourceEntries | ForEach-Object { $_.CurrentBuild })
   $installed=([datetime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)).AddSeconds([double]$os.InstallDate)
   $boot=(Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop).LastBootUpTime.ToUniversalTime()
   $completed=(Get-SmUpgradeDirectoryState @($installed) ([int]$os.CurrentBuild) $prior $installed $boot) -eq 'completedResidual'
   if($created.Count -and (Get-SmUpgradeDirectoryState $created ([int]$os.CurrentBuild) $prior $installed $boot) -ne 'completedResidual') { $reasons.Add('unknown upgrade staging; completion not established'); $light=$true }
  }
  $values=@{}; $s=$null
  if($hasMo) {
   $moKey=Get-Item -LiteralPath $moPath -ErrorAction Stop; $names=@($moKey.GetValueNames()); if($names.Count -gt 32) { throw 'MoSetup metadata exceeds bound' }
   foreach($name in $names) { if($name -notin @('SetupHostResult','SetupHostError','SetupPhase','DownlevelBuildNumber','InstallScenario','DownlevelProductName')) { $values[$name]=$null; continue }; if($moKey.GetValueKind($name) -notin @('DWord','QWord','String')) { throw 'MoSetup metadata type unknown' }; $values[$name]=$moKey.GetValue($name) }
  }
  if($hasState) { $s=Read-SmBoundedText $state 65536 | ConvertFrom-Json -ErrorAction Stop }
  if($hasMo -and ((-not $hasState) -or $s.status -eq 'running') -and -not $light -and -not $created.Count) {
   $image=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction Stop).ImageState
   $ini=Read-SmBoundedText (Join-Path $env:SystemRoot 'Setup\State\State.ini') 16384
   $matches=@([regex]::Matches($ini,'(?m)^\s*ImageState\s*=\s*("?)(IMAGE_STATE_[A-Z_]+)\1\s*$'))
   $iniImage=$null; if($matches.Count -eq 1 -and [regex]::Matches($ini,'(?m)^\s*ImageState\s*=').Count -eq 1) { $iniImage=$matches[0].Groups[2].Value }
   $historical=Test-SmHistoricalUpgrade $image $iniImage $setup $values $s ([int]$os.CurrentBuild) $prior $installed $boot (-not $hasState) $sourceEntries
   if($historical) { $historicalEvidence=[pscustomobject]@{MarkerAbsent=(-not $hasState); MatchingSource=@($sourceEntries | Where-Object { [string]$_.CurrentBuild -eq [string]$values.DownlevelBuildNumber }); CurrentBuild=[int]$os.CurrentBuild; DownlevelBuildNumber=[int]$values.DownlevelBuildNumber; SourceBuilds=$prior; InstalledUtc=$installed; BootUtc=$boot; LegacyTime=$s.time; SetupHostResult=$values.SetupHostResult; SetupHostError=$values.SetupHostError; SetupPhase=$values.SetupPhase; InstallScenario=$values.InstallScenario}; $observations=@('INFERENCE: corroborated historical upgrade residue; marker absence or exact legacy target, image states, chronology and downlevel build agree; not proof of repair or update currency') }
  }
  if($hasMo -and -not $historical -and (Get-SmMoSetupState $values $completed) -ne 'residual') { $reasons.Add('MoSetup state active or unknown'); $light=$true }
  if($hasState -and -not $historical -and (Get-SmOwnUpgradeState $s ([int]$os.CurrentBuild) $boot) -ne 'residual') { $reasons.Add('feature upgrade staged or unknown'); $light=$true }
 } catch { $reasons.Add('unknown guard: evidence unavailable'); $light=$true }
 [pscustomobject]@{ Safe=($reasons.Count -eq 0); Light=$light; Reasons=@($reasons.ToArray()); HistoricalUpgradeInference=$historical; HistoricalUpgradeEvidence=$historicalEvidence; Observations=$observations }
}

# Protect the local evidence directory before any cleanup is authorized.
# Direct native file handles: no parent-owned managed stream pumps. The explicit
# inheritance list also prevents a servicing child retaining the runner's pipes.
function Start-SmDurableProcess {
 param([string]$Executable,[string]$Arguments,[string]$Stdout,[string]$Stderr)
 if(-not ('RelianSmNative' -as [type])) {
 Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RelianSmNative {
 [StructLayout(LayoutKind.Sequential)] struct SA { public int length; public IntPtr descriptor; public int inherit; }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct SI { public int cb; public string reserved,desktop,title; public int x,y,xsize,ysize,xchars,ychars,fill,flags; public short show,reservedSize; public IntPtr reservedBytes,input,output,error; }
 [StructLayout(LayoutKind.Sequential)] struct SIX { public SI startup; public IntPtr attributes; }
 [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr process,thread; public int pid,tid; }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,ref SA security,uint disposition,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,int flags,ref IntPtr size);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
 [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string directory,ref SIX startup,out PI process);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint exitCode);
 static Exception Error() { return new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
 public static Process Start(string executable,string arguments,string stdout,string stderr) {
  SA sa=new SA(); sa.length=Marshal.SizeOf(typeof(SA)); sa.inherit=1;
  using(SafeFileHandle output=CreateFile(stdout,0x40000000,1,ref sa,1,0x80,IntPtr.Zero))
  using(SafeFileHandle error=CreateFile(stderr,0x40000000,1,ref sa,1,0x80,IntPtr.Zero))
  using(SafeFileHandle input=CreateFile("NUL",0x80000000,3,ref sa,3,0x80,IntPtr.Zero)) {
   if(output.IsInvalid||error.IsInvalid||input.IsInvalid) throw Error();
   IntPtr bytes=IntPtr.Zero,list=IntPtr.Zero,handles=IntPtr.Zero; bool initialized=false;
   PI pi=new PI(); bool created=false,resumed=false; Process acquired=null;
   try {
    InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref bytes);
    list=Marshal.AllocHGlobal(bytes);
    if(!InitializeProcThreadAttributeList(list,1,0,ref bytes)) throw Error(); initialized=true;
    handles=Marshal.AllocHGlobal(3*IntPtr.Size);
    Marshal.WriteIntPtr(handles,0,input.DangerousGetHandle()); Marshal.WriteIntPtr(handles,IntPtr.Size,output.DangerousGetHandle()); Marshal.WriteIntPtr(handles,2*IntPtr.Size,error.DangerousGetHandle());
    if(!UpdateProcThreadAttribute(list,0,new IntPtr(0x20002),handles,new IntPtr(3*IntPtr.Size),IntPtr.Zero,IntPtr.Zero)) throw Error();
    SIX si=new SIX(); si.startup.cb=Marshal.SizeOf(typeof(SIX)); si.attributes=list; si.startup.flags=0x100; si.startup.input=input.DangerousGetHandle(); si.startup.output=output.DangerousGetHandle(); si.startup.error=error.DangerousGetHandle();
    // Create suspended so the exact managed identity/handle is acquired before a
    // very short process can exit. No shell interprets executable or arguments.
    if(!CreateProcess(executable,new StringBuilder("\""+executable+"\" "+arguments),IntPtr.Zero,IntPtr.Zero,true,0x08080004,IntPtr.Zero,System.IO.Path.GetDirectoryName(stdout),ref si,out pi)) throw Error(); created=true;
    acquired=Process.GetProcessById(pi.pid); IntPtr retained=acquired.Handle; DateTime started=acquired.StartTime;
    if(ResumeThread(pi.thread)==0xffffffff) throw Error(); resumed=true;
    return acquired;
   } finally {
    if(created&&!resumed) TerminateProcess(pi.process,1);
    if(!resumed&&acquired!=null) acquired.Dispose();
    if(pi.thread!=IntPtr.Zero) CloseHandle(pi.thread); if(pi.process!=IntPtr.Zero) CloseHandle(pi.process);
    if(initialized) DeleteProcThreadAttributeList(list); if(list!=IntPtr.Zero) Marshal.FreeHGlobal(list); if(handles!=IntPtr.Zero) Marshal.FreeHGlobal(handles);
   }
  }
 }
}
'@
 }
 [RelianSmNative]::Start($Executable,$Arguments,$Stdout,$Stderr)
}

function Initialize-SmSecureDirectory {
 param([string]$Path)
 $base=[IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
 $full=[IO.Path]::GetFullPath($Path)
 $owned=Join-Path $base 'RelianMaintenance'
 if($full -ne $owned -and -not $full.StartsWith($owned+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence path must be under the owned maintenance root' }
 $current=$base
 if(-not (Test-SmSafePath $base ([IO.Path]::GetPathRoot($base)))) { throw 'Reparse ProgramData ancestor refused' }
 foreach($part in $full.Substring($base.Length+1).Split('\')) {
  if(-not $part -or $part -in @('.','..')) { throw 'Invalid evidence directory' }
  $current=Join-Path $current $part
  $created=$false
  if(-not (Test-Path -LiteralPath $current -ErrorAction Stop)) { $null=New-Item -ItemType Directory -Path $current -ErrorAction Stop; $created=$true }
  $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
  if(-not $item.PSIsContainer -or ([int64]$item.Attributes -band 1024) -ne 0) { throw 'Reparse evidence directory refused' }
  if(-not $created) {
   # Existing owned directories must already be trusted; never adopt or repair an untrusted root.
   $existing=Get-Acl -LiteralPath $current -ErrorAction Stop
   $ownerSid=$existing.GetOwner([Security.Principal.SecurityIdentifier]).Value
   if($ownerSid -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Shared evidence ancestor has an untrusted owner' }
   $writeMask=[Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
   foreach($rule in $existing.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
    if($rule.AccessControlType -ne 'Allow' -or ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
    $ruleSid=$rule.IdentityReference.Value
    if($ruleSid -notin @('S-1-5-18','S-1-5-32-544') -and ($rule.FileSystemRights -band $writeMask)) { throw 'Shared evidence ancestor grants untrusted modification rights' }
   }
   continue
  }
  $acl=New-Object Security.AccessControl.DirectorySecurity
  $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
  Set-Acl -LiteralPath $current -AclObject $acl -ErrorAction Stop
 }
 return $full
}
$script:SmPrepareReport={
 $dir=Initialize-SmSecureDirectory (Join-Path $env:ProgramData 'RelianMaintenance\Storage')
 $path=Join-Path $dir ((Get-Date -Format 'yyyyMMddTHHmmss')+'-'+[guid]::NewGuid().ToString('n')+'.json')
 if(-not (Test-SmSafePath $path $dir)) {
  # The new file does not exist yet; validate its ordinary, protected parent.
  if(-not (Test-SmSafePath $dir $env:ProgramData)) { throw 'Unsafe report directory' }
 }
 '{"Status":"started","Note":"Maintenance is running or ended before final evidence persisted"}' | Set-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop
 $path
}
$script:SmGuards={ Get-SmGuards }
$script:SmAcquire={ $script:SmMutex=New-Object Threading.Mutex($false,'Global\RelianWindowsMaintenance'); try { $script:SmMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $true } }
$script:SmRelease={ if($script:SmMutex) { $script:SmMutex.ReleaseMutex(); $script:SmMutex.Dispose() } }
$script:SmVolumes={ @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object DeviceID,Size,FreeSpace) }
$script:SmProfiles={ @(Get-CimInstance Win32_UserProfile -OperationTimeoutSec 5 -ErrorAction Stop) }
$script:SmRoots={ @(Join-Path $env:windir 'Temp') }
$script:SmDelete={ param($Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
$script:SmRemoveProfile={ param($Profile) $Profile | Remove-CimInstance -ErrorAction Stop }
$script:SmProfileHiveLoaded={ param($Sid) (Test-Path -LiteralPath ('Registry::HKEY_USERS\'+$Sid) -ErrorAction Stop) -or (Test-Path -LiteralPath ('Registry::HKEY_USERS\'+$Sid+'_Classes') -ErrorAction Stop) }
$script:SmDiagnosticRoots={ @($env:ProgramData,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:windir) | Where-Object { $_ } }
$script:SmComponent={
 $logDir=Initialize-SmSecureDirectory (Join-Path $env:ProgramData 'RelianMaintenance\Storage')
 $id=[guid]::NewGuid().ToString('n')
 $markerDir=Initialize-SmSecureDirectory (Join-Path $env:ProgramData 'RelianMaintenance')
 $markerPath=Join-Path $markerDir 'native-active.json'
 if(Test-Path -LiteralPath $markerPath -ErrorAction Stop) { throw 'Native marker already exists; reconcile exact process identity first' }
 $native=[ordered]@{pid=$null;creationTimeUtc=$null;executable=(Join-Path $env:windir 'System32\dism.exe');phase='startingComponentCleanup';startedUtc=[datetime]::UtcNow.ToString('o');stdoutPath=(Join-Path $logDir ($id+'.stdout.log'));stderrPath=(Join-Path $logDir ($id+'.stderr.log'))}
 $native | ConvertTo-Json -Compress | Set-Content -LiteralPath $markerPath -Encoding UTF8 -ErrorAction Stop
 $p=Start-SmDurableProcess (Join-Path $env:windir 'System32\dism.exe') '/Online /Cleanup-Image /StartComponentCleanup /NoRestart' $native.stdoutPath $native.stderrPath
 $native.pid=$p.Id; $native.creationTimeUtc=$p.StartTime.ToUniversalTime().ToString('o'); $native.phase='componentCleanup'
 $native | ConvertTo-Json -Compress | Set-Content -LiteralPath $markerPath -Encoding UTF8 -ErrorAction Stop
 if(-not $p.WaitForExit(300000)) { throw 'Component cleanup still running after five minutes; not terminated; do not start another maintenance job.' }
 # This exact Process instance has exited; never clear a marker on PID lookup alone.
 Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
 if($p.ExitCode -notin @(0,3010)) { throw "DISM exit $($p.ExitCode)" }; $p.ExitCode
}
$script:SmEvidence={
 $e=[ordered]@{}
 foreach($class in @('Win32_DiskDrive','Win32_PageFileUsage','Win32_ShadowStorage','Win32_Volume')) {
  try { $e[$class]=@(Get-CimInstance $class -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -First 20 -Property DeviceID,Model,Status,AllocatedBaseSize,CurrentUsage,AllocatedSpace,UsedSpace,MaxSpace,Capacity,FreeSpace) } catch { $e[$class]=@{Error=$_.Exception.Message} }
 }
 $paths=@('Windows.old','$WINDOWS.~BT','$WINDOWS.~WS','hiberfil.sys','pagefile.sys','Windows\WinSxS','Windows\SoftwareDistribution\Download','Windows\Installer','ProgramData\Package Cache')
 $e['Opportunities']=@($paths | ForEach-Object { $p=Join-Path $env:SystemDrive $_; try { $i=Get-Item -LiteralPath $p -Force -ErrorAction Stop; @{ Path=$p; Present=$true; LogicalBytes=if($i.PSIsContainer){$null}else{$i.Length}; Policy='preserved; no recursive scan' } } catch { @{Path=$p;Present=$null;Error=$_.Exception.Message} } })
 $e['ReservedStorage']='Not queried: servicing command deliberately omitted; inspect with DISM /Get-ReservedStorageState in a separate maintenance window.'
 $e['ComponentStore']='WinSxS logical sizes include hardlinks and are not reclaimable estimates. Optional supported StartComponentCleanup requires clear guards; no ResetBase.'
 $e
}

function Grant-SmThemeReadAccess {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)) { throw 'Path must not be empty' }
    $sessions = @(Get-ADTLoggedOnUser -ErrorAction Stop | Where-Object { $_.IsActiveUserSession })
    if (-not $sessions.Count) { throw 'no active user session for dialog theme' }
    foreach ($session in $sessions) {
        [PSADT.ClientServer.ClientPermissions]::Remediate($session.ToRunAsActiveUser(), [IO.FileInfo[]]@($Path))
    }
}

# The user-check package's dialog theme, copied: the runner downloads each package
# as one file by hash, so the two cannot share a file. The mark and subtitle parts
# are left out. The toolkit's client process (PSADT.ClientServer.Client.exe, started
# in the user's session for notice 1, and again through its launcher for the
# countdown) loads this assembly as its AppDomainManager from the .exe.config, so it
# runs inside the process that owns the WPF window although this script runs as
# SYSTEM. A background thread polls the open windows every 150 ms, paints
# SidebarAccentFill and SidebarPanel black, recolours resource keys holding
# "Accent" (OnAccent and Foreground keys white) and whitens text on black buttons.
# It stops about 4 seconds after the last window closes, or after 4000 styled
# polls; what it painted stays. It never touches a dialog result.
function Install-SmDialogTheme {
    param([string]$ClientExe)
    if([string]::IsNullOrWhiteSpace($ClientExe)) { throw 'ClientExe must not be empty' }
    $ErrorActionPreference = 'Stop'
    $dll = Join-Path (Split-Path -Parent $ClientExe) 'RelianRestartNoticeTheme.dll'
    $source = @'
using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

[assembly: AssemblyVersion("1.0.0.0")]

namespace Relian.RestartNoticeTheme
{
    public sealed class ThemeDomainManager : AppDomainManager
    {
        public override void InitializeNewDomain(AppDomainSetup appDomainInfo)
        {
            base.InitializeNewDomain(appDomainInfo);
            try
            {
                TryLog("manager loaded");
                var thread = new Thread(Watch);
                thread.IsBackground = true;
                thread.Start();
            }
            catch (Exception ex)
            {
                TryLog(ex.ToString());
            }
        }

        private static void Watch()
        {
            var missing = 0;
            var seen = 0;
            while (seen < 4000 && missing < 25)
            {
                Thread.Sleep(150);
                try
                {
                    var app = Application.Current;
                    if (app == null)
                    {
                        if (seen > 0)
                        {
                            missing++;
                        }
                        continue;
                    }
                    var found = (bool)app.Dispatcher.Invoke(new Func<bool>(StyleOpenWindows));
                    if (found)
                    {
                        seen++;
                        missing = 0;
                    }
                    else if (seen > 0)
                    {
                        missing++;
                    }
                }
                catch (Exception ex)
                {
                    TryLog(ex.Message);
                    if (seen > 0)
                    {
                        missing++;
                    }
                }
            }
        }

        private static bool StyleOpenWindows()
        {
            var app = Application.Current;
            if (app == null || app.Windows.Count == 0)
            {
                return false;
            }
            var black = new SolidColorBrush(Color.FromRgb(0, 0, 0));
            var white = new SolidColorBrush(Color.FromRgb(255, 255, 255));
            black.Freeze();
            white.Freeze();
            Recolor(app.Resources, black, white);
            var any = false;
            foreach (Window window in app.Windows)
            {
                any = true;
                Paint(window, "SidebarAccentFill", black);
                Paint(window, "SidebarPanel", black);
                WhitenBlackButtons(window, white);
            }
            if (any && Interlocked.Exchange(ref styledOnce, 1) == 0)
            {
                TryLog("styled");
            }
            return any;
        }

        private static int styledOnce;

        private static void Paint(DependencyObject root, string name, Brush brush)
        {
            var element = Find(root, name);
            if (element == null)
            {
                return;
            }
            var opacity = element.GetType().GetProperty("Opacity");
            if (opacity != null && opacity.CanWrite)
            {
                opacity.SetValue(element, 1.0, null);
            }
            var fill = element.GetType().GetProperty("Fill");
            if (fill != null && fill.CanWrite)
            {
                fill.SetValue(element, brush, null);
            }
            var background = element.GetType().GetProperty("Background");
            if (background != null && background.CanWrite)
            {
                background.SetValue(element, brush, null);
            }
        }

        private static void WhitenBlackButtons(Window window, Brush white)
        {
            foreach (var name in new[] { "ButtonLeft", "ButtonMiddle", "ButtonRight" })
            {
                var button = Find(window, name) as Button;
                if (button == null || !ButtonLooksBlack(button))
                {
                    continue;
                }
                button.Foreground = white;
                WhitenText(button, white);
            }
        }

        private static bool ButtonLooksBlack(Button button)
        {
            return LooksBlack(button.Background) || LooksBlack(button.BorderBrush) || AnyBlackFill(button);
        }

        private static bool AnyBlackFill(DependencyObject node)
        {
            var border = node as Border;
            if (border != null && LooksBlack(border.Background))
            {
                return true;
            }
            var count = VisualTreeHelper.GetChildrenCount(node);
            for (var i = 0; i < count; i++)
            {
                if (AnyBlackFill(VisualTreeHelper.GetChild(node, i)))
                {
                    return true;
                }
            }
            return false;
        }

        private static bool LooksBlack(Brush brush)
        {
            var solid = brush as SolidColorBrush;
            if (solid == null)
            {
                return false;
            }
            var color = solid.Color;
            return color.A > 200 && color.R < 40 && color.G < 40 && color.B < 40;
        }

        private static void WhitenText(DependencyObject node, Brush white)
        {
            var block = node as TextBlock;
            if (block != null)
            {
                block.Foreground = white;
            }
            var access = node as AccessText;
            if (access != null)
            {
                access.Foreground = white;
            }
            var count = VisualTreeHelper.GetChildrenCount(node);
            for (var i = 0; i < count; i++)
            {
                WhitenText(VisualTreeHelper.GetChild(node, i), white);
            }
        }

        private static FrameworkElement Find(DependencyObject node, string name)
        {
            var named = node as FrameworkElement;
            if (named != null && named.Name == name)
            {
                return named;
            }
            var window = node as Window;
            if (window != null)
            {
                var found = window.FindName(name) as FrameworkElement;
                if (found != null)
                {
                    return found;
                }
            }
            var count = VisualTreeHelper.GetChildrenCount(node);
            for (var i = 0; i < count; i++)
            {
                var child = Find(VisualTreeHelper.GetChild(node, i), name);
                if (child != null)
                {
                    return child;
                }
            }
            return null;
        }

        private static void Recolor(ResourceDictionary dictionary, Brush black, Brush white)
        {
            if (dictionary == null)
            {
                return;
            }
            try
            {
                var keys = new object[dictionary.Keys.Count];
                dictionary.Keys.CopyTo(keys, 0);
                foreach (var key in keys)
                {
                    var label = key == null ? string.Empty : key.ToString();
                    if (label.IndexOf("Accent", StringComparison.OrdinalIgnoreCase) < 0)
                    {
                        continue;
                    }
                    var lightText = label.IndexOf("OnAccent", StringComparison.OrdinalIgnoreCase) >= 0
                        || label.IndexOf("Foreground", StringComparison.OrdinalIgnoreCase) >= 0;
                    try
                    {
                        var value = dictionary[key];
                        if (value is SolidColorBrush)
                        {
                            dictionary[key] = lightText ? (object)white : black;
                        }
                        else if (value is Color)
                        {
                            dictionary[key] = lightText ? (object)Colors.White : Colors.Black;
                        }
                    }
                    catch
                    {
                    }
                }
            }
            catch
            {
            }
            foreach (ResourceDictionary child in dictionary.MergedDictionaries)
            {
                Recolor(child, black, white);
            }
        }

        private static void TryLog(string message)
        {
            try
            {
                var dir = Path.GetDirectoryName(typeof(ThemeDomainManager).Assembly.Location);
                File.AppendAllText(Path.Combine(dir, "relian-dialog-theme.log"), message + Environment.NewLine);
            }
            catch
            {
            }
        }
    }
}
'@

    if (Test-Path -LiteralPath $dll) { Remove-Item -LiteralPath $dll -Force }
    Add-Type -TypeDefinition $source -OutputAssembly $dll -ReferencedAssemblies @('System', 'System.Xaml', 'WindowsBase', 'PresentationCore', 'PresentationFramework')
    Grant-SmThemeReadAccess -Path $dll
    $fullName = [System.Reflection.AssemblyName]::GetAssemblyName($dll).FullName
    # The config is written last, after the assembly exists: a config naming a
    # missing or unreadable assembly would stop the client process from starting.
    $configPath = "$ClientExe.config"
    [xml]$config = [System.IO.File]::ReadAllText($configPath)
    $runtime = $config.configuration.runtime
    if ($null -eq $runtime) { throw 'client config has no runtime element' }
    foreach ($name in @('appDomainManagerAssembly', 'appDomainManagerType')) {
        foreach ($node in @($runtime.ChildNodes | Where-Object { $_.LocalName -eq $name })) { [void]$runtime.RemoveChild($node) }
    }
    $assemblyNode = $config.CreateElement('appDomainManagerAssembly')
    [void]$assemblyNode.SetAttribute('value', $fullName)
    [void]$runtime.AppendChild($assemblyNode)
    $typeNode = $config.CreateElement('appDomainManagerType')
    [void]$typeNode.SetAttribute('value', 'Relian.RestartNoticeTheme.ThemeDomainManager')
    [void]$runtime.AppendChild($typeNode)
    $config.Save($configPath)
    Write-Verbose 'dialog theme installed'
}


$script:SmUiOpen=$false
$script:SmThemeError=$null
$script:SmUi={ param($Step)
 if(-not $script:SmUiOpen) {
  $module=Join-Path $PSScriptRoot 'PSAppDeployToolkit\PSAppDeployToolkit.psd1'
  Import-Module -FullyQualifiedName @{ModuleName=$module;ModuleVersion='4.1.8';Guid='8c3c366b-8606-4576-9f2d-4051144f7ca2'} -Force -ErrorAction Stop
  if(-not @(Get-ADTLoggedOnUser | Where-Object { $_.IsActiveUserSession }).Count) { return 'noUser' }
  try {
   $client=Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'PSAppDeployToolkit') -Filter 'PSADT.ClientServer.Client.exe' -Recurse -File | Select-Object -First 1
   if(-not $client) { throw 'Toolkit client not found' }; Install-SmDialogTheme $client.FullName
  } catch { $script:SmThemeError=$_.Exception.Message }
  $null=Open-ADTSession -AppName 'Relian storage maintenance' -AppVersion '1' -DeploymentType Install -DeployMode Interactive -PassThru
  $script:SmUiOpen=$true
 }
 Show-ADTInstallationProgress -StatusMessage $Step
 if($script:SmThemeError) { 'shown; black theme unavailable: '+$script:SmThemeError } else { 'shown' }
}

function ConvertTo-SmSummary {
 param($Report,[string]$ReportPath)
 # All strings are clipped before serialization; item limits and the UTF8 byte
 # fallback make truncation explicit without losing measured volume evidence.
 $clip={ param($Value,[int]$Limit=180) $text=[string]$Value; if($text.Length -gt $Limit) { return $text.Substring(0,$Limit)+'...' }; $text }
 $volumes={ param($Items) @($Items | Select-Object -First 4 | ForEach-Object { @{DeviceID=(& $clip $_.DeviceID 20);Size=$_.Size;FreeSpace=$_.FreeSpace} }) }
 $summary=[ordered]@{SchemaVersion=1;Status=$Report.Status;Mode=$Report.Mode;ReportPath=(& $clip $ReportPath 300);ActionCount=$Report.Actions.Count;GuardReasons=@($Report.Guards.Reasons | Select-Object -First 5 | ForEach-Object { & $clip $_ });PartialScan=if($Report.Scan){$Report.Scan.Partial}else{$true};Before=@(& $volumes $Report.Before);After=@(& $volumes $Report.After);FreeSpaceDelta=@($Report.FreeSpaceDelta | Select-Object -First 4);TopFiles=@($Report.Scan.TopFiles | Where-Object { $null -ne $_ } | Select-Object -First 3 | ForEach-Object { @{Path=(& $clip $_.Path);LogicalBytes=$_.LogicalBytes} });TopFolders=@($Report.Scan.TopFolders | Where-Object { $null -ne $_ } | Select-Object -First 3 | ForEach-Object { @{Path=(& $clip $_.Path);DirectFileLogicalBytes=$_.DirectFileLogicalBytes} });TempOpportunities=@($Report.Scan.TempCategories | Where-Object { $null -ne $_ } | Select-Object -First 3 | ForEach-Object { @{Root=(& $clip $_.Root);LogicalBytes=$_.LogicalBytes;AgeQualifiedLogicalBytes=$_.AgeQualifiedLogicalBytes;ReclaimableBytes=$null} });ProfileDecisions=@($Report.Profiles | Group-Object Decision | Select-Object -First 8 | ForEach-Object { @{Decision=(& $clip $_.Name 60);Count=$_.Count} });OpportunityCount=@($Report.Evidence.Opportunities | Where-Object { $null -ne $_ }).Count;ProfileCount=@($Report.Profiles).Count;Notifications=@($Report.Notifications | Select-Object -First 3 | ForEach-Object { & $clip $_ });Errors=@($Report.Errors | Select-Object -First 3 | ForEach-Object { & $clip $_ });Truncated=$true;Truncation='Summary limits: 4 volumes, 3 consumers/category, 8 profile decisions; strings clipped. Full evidence in ReportPath.';ScanWithheld=($Report.Guards.Light -eq $true)}
 $json=$summary | ConvertTo-Json -Depth 6 -Compress
 if([Text.Encoding]::UTF8.GetByteCount($json) -gt 8000) {
  $summary.GuardReasons=@($summary.GuardReasons | Select-Object -First 1 | ForEach-Object { & $clip $_ 80 }); $summary.Notifications=@(); $summary.Errors=@($summary.Errors | Select-Object -First 1 | ForEach-Object { & $clip $_ 80 }); $summary.FreeSpaceDelta=@(); $summary.TopFolders=@($summary.TopFolders | Select-Object -First 1 | ForEach-Object { $_.Path=& $clip $_.Path 80; $_ }); $summary.TopFiles=@($summary.TopFiles | Select-Object -First 1 | ForEach-Object { $_.Path=& $clip $_.Path 80; $_ }); $summary.TempOpportunities=@($summary.TempOpportunities | Select-Object -First 1 | ForEach-Object { $_.Root=& $clip $_.Root 80; $_ }); $summary.Truncation='Byte cap reached; volume measurements, one consumer/category, first error and decision counts retained. See full local report.'
  $json=$summary | ConvertTo-Json -Depth 6 -Compress
 }
 return $json
}

function Invoke-SmMaintenance {
 param($A)
 $r=[ordered]@{ SchemaVersion=1; Timestamp=[datetime]::UtcNow.ToString('o'); Mode=$A.Mode; Status='complete'; ReportPath=$null; Guards=$null; Before=@(); After=@(); FreeSpaceDelta=@(); Profiles=@(); Scan=$null; Actions=@(); Notifications=@(); Errors=@(); Omissions=@('User documents/downloads, rollback/recovery, installer cache and Windows components are never deleted.','Logical sizes exclude unreadable/reparse/cloud entries; hardlinks, compression and sparse files make reclaimable bytes uncertain.','App caches are reported as opportunities only; no application cache reset.','Directory ranking counts direct files, not recursively accumulated subtree sizes; categories may overlap.','Upgrade staging/Windows.old are preserved. Historical staging needs independent Source OS, install and boot completion evidence; unestablished status stays light/withheld.'); Evidence=$null; ProfileReport=$null }
 $acquired=$false
 try {
  $acquired=& $script:SmAcquire
  if(-not $acquired) { $r.Status='busy'; return [pscustomobject]$r }
  $g=& $script:SmGuards; $r.Guards=$g
  $r.ReportPath=& $script:SmPrepareReport
  try { $r.Notifications+=& $script:SmUi 'Checking free space and upgrade safety before storage inspection.' } catch { $r.Notifications+=('failed: '+$_.Exception.Message) }
  try { $r.Before=@(& $script:SmVolumes) } catch { $r.Errors+=$_.Exception.Message }
  if($g.Light) {
   $r.Status='partial'; $r.Scan=[pscustomobject]@{Partial=$true;Files=@();Reason='Upgrade active or guard unknown: light volume summary only'}
   $r.Omissions+='Profile, cache, health and recursive scans withheld to avoid competing with Setup.'
  } else {
   try { $r.Evidence=& $script:SmEvidence } catch { $r.Errors+=$_.Exception.Message }
   $initialEvidenceWatch=[Diagnostics.Stopwatch]::StartNew()
   $profiles=@(); try { $profiles=@(& $script:SmProfiles) } catch { $r.Errors+=$_.Exception.Message }
   if($profiles.Count -gt 200) { $r.Status='partial'; $r.Omissions+='Profile list capped at 200.'; $profiles=@($profiles | Select-Object -First 200) }
   $r.Evidence['ApplicationCachePolicy']='Per-profile Edge/Chrome/WebView Cache, Code Cache, GPUCache, ShaderCache, CacheStorage, Teams LocalCache and Adobe AcroCef are report-only. Outlook OST, OfficeFileCache, Wef and offline documents are preserved.'
   $evidenceLimit=[double][math]::Min(30,$A.MaxSeconds); $evidenceRemaining=$evidenceLimit-$initialEvidenceWatch.Elapsed.TotalSeconds; $assessedUtc=[datetime]::UtcNow
   $evidenceDirectory=Split-Path -Parent $r.ReportPath
   $collected=& $script:SmCollectProfiles $profiles $A.ProfileAgeDays $assessedUtc $evidenceRemaining $evidenceDirectory $(if($A.ProfileReport){'Report'}else{'Full'})
   $evidenceRemaining-=[double]$collected.ElapsedSeconds
   $evidenceRemaining=[math]::Min($evidenceRemaining,$evidenceLimit-$initialEvidenceWatch.Elapsed.TotalSeconds)
   if($evidenceRemaining -le 0) { $collected.Complete=$false; $collected.Error='Aggregate profile evidence deadline exhausted' }
   if(-not $collected.Complete) { $r.Status='partial'; $r.Omissions+=('Profile evidence incomplete: '+$collected.Error) }
   if($collected.GuardChanged) { $g=[pscustomobject]@{Safe=$false;Light=$true;Reasons=@($collected.Reasons)}; $r.Guards=$g }
   $r.Profiles=@($profiles | ForEach-Object {
    $profile=$_; $found=@($collected.Entries | Where-Object { $_.SID -eq $profile.SID -and $_.Path -eq $profile.LocalPath })
    $profileEvidence=if($collected.Complete -and $found.Count -eq 1){$found[0].Evidence}else{New-SmMissingEvidence ('Collection incomplete/timeout/guard transition: '+$collected.Error)}
    Test-SmProfile $profile $A.ProfileAgeDays $A.ExcludeProfiles $assessedUtc $profileEvidence
   })
   # One globally bounded scan: safe temps plus profile trees (diagnostic only).
   $roots=@(& $script:SmRoots); $roots+=@($profiles | Where-Object { $_.LocalPath -match '^[A-Za-z]:\\Users\\[^\\]+$' -and $_.Special -eq $false } | ForEach-Object { $_.LocalPath.TrimEnd('\')+'\AppData\Local\Temp' }); $scanRoots=@(& $script:SmRoots)+@($profiles | Where-Object { $_.LocalPath -match '^[A-Za-z]:\\Users\\[^\\]+$' } | ForEach-Object { $_.LocalPath })
   try { $r.Notifications+=& $script:SmUi 'Measuring bounded folders and old temporary files; cloud placeholders are skipped.' } catch { $r.Notifications+=('failed: '+$_.Exception.Message) }
   $scanRoots+=@(& $script:SmDiagnosticRoots)
   $scanRoots+=@($r.Before | Where-Object { $_.DeviceID -match '^[A-Za-z]:$' } | ForEach-Object { $_.DeviceID+'\' })
   $scan=if($collected.GuardChanged){[pscustomobject]@{Roots=@();Files=@();TopFiles=@();TopFolders=@();Partial=$true;Light=$true;GuardReasons=@($collected.Reasons);EntriesVisited=0;SkippedReparseOrCloud=0;Errors=@();Seconds=0}}else{Get-SmScan $scanRoots $A.MaxFiles $A.MaxSeconds $A.TempAgeDays}; $r.Scan=$scan
   if($scan.Light) { $g=[pscustomobject]@{Safe=$false;Light=$true;Reasons=@($scan.GuardReasons)}; $r.Guards=$g; $r.Omissions+='Traversal abandoned because Setup/unknown servicing state appeared during scan.' }
   foreach($f in $scan.Files) { $f | Add-Member -NotePropertyName CleanupRoot -NotePropertyValue $null; foreach($tempRoot in $roots) { if($f.Path.StartsWith($tempRoot.TrimEnd('\')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { $f.CleanupRoot=$tempRoot; break } } }
   if($scan.Partial -or $scan.Errors.Count) { $r.Status='partial' }
   $cacheFiles=@($scan.Files | Where-Object { $_.Path -match '(?i)\\(Cache|Code Cache|GPUCache|ShaderCache|CacheStorage)\\|\\MSTeams_[^\\]+\\LocalCache\\|\\Adobe\\AcroCef\\' })
   $r.Evidence['ApplicationCaches']=@($cacheFiles | Group-Object { if($_.Path -match '(?i)^(.+?\\(?:Cache|Code Cache|GPUCache|ShaderCache|CacheStorage))\\') { $Matches[1] } else { $_.Root } } | Sort-Object Count -Descending | Select-Object -First 30 | ForEach-Object { @{Path=$_.Name;ObservedLogicalBytes=($_.Group | Measure-Object LogicalBytes -Sum).Sum;Partial=$scan.Partial;Policy='report only; close owning application and review before manual cleanup';ReclaimableBytes=$null} })
   foreach($p in $r.Profiles) { $size=Get-SmProfileSize $scan $p.Path; $p.LogicalBytes=$size.LogicalBytes; $p.SizePartial=$size.Partial }
   if($A.ProfileReport) { $r.ProfileReport=Get-SmProfileReport $A $r.Profiles $collected.ReportContext $assessedUtc }
   # A profile report never enters the mutating branch, whatever else $A says.
   if($A.Mode -eq 'Cleanup' -and -not $A.ProfileReport) {
    if(-not $g.Safe) { $r.Status='withheld' }
    else {
     $cleanupWatch=[Diagnostics.Stopwatch]::StartNew()
     foreach($f in @($scan.Files | Where-Object { $_.Old -and $_.CleanupRoot })) {
      if($cleanupWatch.Elapsed.TotalSeconds -ge $A.MaxSeconds) { $r.Status='partial'; $r.Omissions+='Cleanup time budget exhausted; remaining actions withheld.'; break }
      $step=[ordered]@{Kind='temp';Path=$f.Path;Status='withheld';LogicalBytes=$f.LogicalBytes;Error=$null}
      try {
       if(-not (& $script:SmGuards).Safe) { throw 'Servicing guard changed; cleanup stopped' }
       if(-not (Test-SmSafePath $f.Path $f.CleanupRoot)) { throw 'Unsafe path or attributes' }
       $i=Get-Item -LiteralPath $f.Path -Force -ErrorAction Stop
       if($i.PSIsContainer -or $i.LastWriteTimeUtc -ge [datetime]::UtcNow.AddDays(-$A.TempAgeDays)) { throw 'File no longer age eligible' }
       & $script:SmDelete $f.Path; $step.Status='deleted'
      } catch { $step.Error=$_.Exception.Message; $r.Status='partial' }
      $r.Actions+=[pscustomobject]$step
      if($step.Error -like 'Servicing guard changed*') { break }
     }
     if($A.RemoveProfiles) {
      foreach($candidate in @($r.Profiles | Where-Object { $_.Eligible })) {
       if($cleanupWatch.Elapsed.TotalSeconds -ge $A.MaxSeconds) { $r.Status='partial'; $r.Omissions+='Profile cleanup time budget exhausted.'; break }
       $remainingAtStepStart=$evidenceRemaining; $profileStepWatch=[Diagnostics.Stopwatch]::StartNew()
       $step=[ordered]@{Kind='profile';Path=$candidate.Path;Status='withheld';Error=$null}
       try {
        if(-not (& $script:SmGuards).Safe) { throw 'Servicing guard changed' }
        $fresh=@(& $script:SmProfiles | Where-Object { $_.SID -eq $candidate.SID })
        if(& $script:SmProfileHiveLoaded $candidate.SID) { throw 'Profile hive is loaded' }
        if($fresh.Count -ne 1 -or $fresh[0].LocalPath -ne $candidate.Path) { throw 'Profile revalidation failed: SID/path changed or ambiguous' }
        $evidenceRemaining=[math]::Min($evidenceRemaining,$remainingAtStepStart-$profileStepWatch.Elapsed.TotalSeconds)
        if($evidenceRemaining -le 0) { throw 'Aggregate profile evidence budget exhausted' }
        $recheckUtc=[datetime]::UtcNow
        $recollected=& $script:SmCollectProfiles $fresh $A.ProfileAgeDays $recheckUtc $evidenceRemaining $evidenceDirectory 'Full'
        $evidenceRemaining-=[double]$recollected.ElapsedSeconds
        if(-not $recollected.Complete -or $recollected.TimedOut -or $recollected.GuardChanged -or $evidenceRemaining -le 0) { throw 'Profile revalidation failed: evidence deadline or servicing transition' }
        $found=@($recollected.Entries | Where-Object { $_.SID -eq $candidate.SID -and $_.Path -eq $candidate.Path })
        if($found.Count -ne 1) { throw 'Profile revalidation failed: incomplete identity evidence' }
        $recheck=Test-SmProfile $fresh[0] $A.ProfileAgeDays $A.ExcludeProfiles $recheckUtc $found[0].Evidence
        $step['Revalidation']=$recheck
        if(-not $recheck.Eligible -or $recheck.AgeEvidenceFingerprint -ne $candidate.AgeEvidenceFingerprint) { throw ('Profile revalidation failed: '+$recheck.Reason) }
        # Profile root and all ancestors must be ordinary directories.
        if(-not (Test-SmSafePath $candidate.Path ([IO.Path]::GetPathRoot($candidate.Path)))) { throw 'Unsafe profile path' }
        # Refresh cheap session/CIM/hive vetoes AFTER expensive age/event work.
        $final=& $script:SmCollectProfiles $fresh $A.ProfileAgeDays ([datetime]::UtcNow) ([math]::Min(5,[math]::Min($evidenceRemaining,$remainingAtStepStart-$profileStepWatch.Elapsed.TotalSeconds))) $evidenceDirectory 'Final'
        $evidenceRemaining-=[double]$final.ElapsedSeconds
        $step['FinalVeto']=$final.FinalVeto
        if(-not $final.Complete -or $final.TimedOut -or $final.GuardChanged -or -not $final.FinalVeto.Clear) { throw 'Profile final session/loaded/hive veto failed or unavailable' }
        if($evidenceRemaining -le 0 -or $cleanupWatch.Elapsed.TotalSeconds -ge $A.MaxSeconds) { throw 'Profile cleanup/evidence deadline exhausted before removal' }
        if(-not (& $script:SmGuards).Safe) { throw 'Servicing guard changed immediately before profile removal' }
        if($evidenceRemaining -le 0 -or $profileStepWatch.Elapsed.TotalSeconds -ge $remainingAtStepStart -or $cleanupWatch.Elapsed.TotalSeconds -ge $A.MaxSeconds -or (& $script:SmProfileHiveLoaded $candidate.SID)) { throw 'Final profile deadline or loaded hive veto' }
        & $script:SmRemoveProfile $fresh[0]; $step.Status='removedByCim'
       } catch { $step.Error=$_.Exception.Message; $r.Status='partial' }
       $evidenceRemaining=[math]::Min($evidenceRemaining,$remainingAtStepStart-$profileStepWatch.Elapsed.TotalSeconds)
       $r.Actions+=[pscustomobject]$step
      }
     }
     if($A.ComponentCleanup) {
      $step=[ordered]@{Kind='componentCleanup';Status='withheld';Error=$null}
      try { if(-not (& $script:SmGuards).Safe) { throw 'Servicing guard changed' }; $step['ExitCode']=& $script:SmComponent; $step.Status='commandCompleted' } catch { $step.Error=$_.Exception.Message; $r.Status='partial' }; $r.Actions+=[pscustomobject]$step
     }
    }
   }
   # Full file list is internal only; output bounded top lists and category totals.
   $r.Scan=[pscustomobject]@{Partial=$scan.Partial;Light=$scan.Light;GuardReasons=$scan.GuardReasons;EntriesVisited=$scan.EntriesVisited;Seconds=$scan.Seconds;SkippedReparseOrCloud=$scan.SkippedReparseOrCloud;Errors=$scan.Errors;TopFiles=$scan.TopFiles;TopFolders=$scan.TopFolders;TempCategories=@($roots | ForEach-Object { $root=$_; $fs=@($scan.Files | Where-Object {$_.CleanupRoot -eq $root}); @{Root=$root;LogicalBytes=($fs | Measure-Object LogicalBytes -Sum).Sum;AgeQualifiedLogicalBytes=($fs | Where-Object {$_.Old} | Measure-Object LogicalBytes -Sum).Sum;ReclaimableBytes=$null} })}
  }
  try { $r.Notifications+=& $script:SmUi ('Storage inspection '+$r.Status+'. Checking final free-space measurements.') } catch { $r.Notifications+=('failed: '+$_.Exception.Message) }
  try { $r.After=@(& $script:SmVolumes); $r.FreeSpaceDelta=@($r.After | ForEach-Object { $after=$_; $before=@($r.Before | Where-Object {$_.DeviceID -eq $after.DeviceID}); if($before.Count -eq 1) { @{DeviceID=$after.DeviceID;Bytes=([int64]$after.FreeSpace-[int64]$before[0].FreeSpace);IncludesConcurrentActivity=$true} } }) } catch { $r.Errors+=$_.Exception.Message }
 } catch { $r.Status='failed'; $r.Errors+=$_.Exception.Message }
 finally { if($acquired) { & $script:SmRelease } }
 if($r.Errors.Count -and $r.Status -eq 'complete') { $r.Status='partial' }
 if($A.ProfileReport -and -not $r.ProfileReport) { $r.ProfileReport=[pscustomobject]@{EventLog=$null;DeviceClass=$null;Profiles=@();Summary=$null;Errors=@('Profile report not collected: scans withheld or run failed')} }
 return [pscustomobject]$r
}

# Final evidence and stdout must precede Close-ADTSession: PSADT 4.1.8 can
# terminate PowerShell while closing its final session/client-server process.
$script:SmSave={
 param($Report)
 $path=$Report.ReportPath
 if(-not $path) { throw 'Report destination unavailable' }
 if(-not (Test-SmSafePath $path (Split-Path -Parent $path))) { throw 'Report path changed or became unsafe' }
 $Report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop
}
function Close-SmSession {
 param([int]$Code)
 if($script:SmUiOpen) {
  $script:SmUiOpen=$false
  Close-ADTSession -ExitCode $Code
 }
}
function Complete-SmRun {
 param($Report)
 $script:SmExitCode=1
 try {
  if($script:SmUiOpen) { try { Close-ADTInstallationProgress } catch { $Report.Notifications+=('close failed: '+$_.Exception.Message) } }
  try { & $script:SmSave $Report } catch { $Report.Errors+=('Report file write failed: '+$_.Exception.Message); $Report.Status='failed' }
  Write-Host "Storage maintenance: $($Report.Status); mode $($Report.Mode); actions $($Report.Actions.Count). Free-space delta includes concurrent system activity."
  if($Report.ProfileReport) { ConvertTo-SmProfileReportJson $Report } else { ConvertTo-SmSummary $Report $Report.ReportPath }
  $script:SmExitCode=if($Report.Status -eq 'failed') {1}else{0}
 } finally { Close-SmSession $script:SmExitCode }
}

if($env:RELIAN_DEPLOY_TEST -ne '1') {
 $ErrorActionPreference='Stop'
 $r=$null
 if($Action -eq 'Uninstall' -or $DeploymentType -eq 'Uninstall') { Write-Output '{"Status":"notApplicable","Reason":"Maintenance has no uninstall action"}'; exit 0 }
 try {
  $a=Get-SmArguments -Mode $Mode -TempAgeDays $TempAgeDays -ProfileAgeDays $ProfileAgeDays -RemoveProfiles $RemoveProfiles -ExcludeProfiles $ExcludeProfiles -ComponentCleanup $ComponentCleanup -MaxFiles $MaxFiles -MaxSeconds $MaxSeconds -ProfileReport $ProfileReport -PrimaryUserHint $PrimaryUserHint -SharedDevices $SharedDevices
  $r=Invoke-SmMaintenance $a
  Complete-SmRun $r
  exit $script:SmExitCode
 } catch {
  if($r) { $r.Status='failed'; $r.Errors+='Runtime or toolkit session closure failed'; try { & $script:SmSave $r } catch { } }
  Write-Output '{"Status":"failed","Reason":"Runtime or toolkit session closure failed; inspect durable report and runner exit code"}'
  try { Close-SmSession 1 } catch { }
  exit 1
 }
}
