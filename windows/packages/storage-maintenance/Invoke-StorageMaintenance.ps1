<# .SYNOPSIS
Bounded storage evidence and explicitly requested conservative cleanup. No reboot.
Logical bytes are observations, not guaranteed reclaimable physical space.
#>
[CmdletBinding()]
param([string]$DeploymentType, [string]$Action, [string]$PinVersion,
 [string]$Mode='Report', [string]$TempAgeDays='7', [string]$ProfileAgeDays='60',
 [string]$RemoveProfiles='false', [string]$ExcludeProfiles='', [string]$ComponentCleanup='false',
 [string]$MaxFiles='20000', [string]$MaxSeconds='30', [string]$ProfileReport='false', [string]$PrimaryUserHint='', [string]$SharedDevices='',
 [string]$ReviewedReports='', [string]$RemovalCooldownDays='1', [string]$Tier='None', [string]$CleanupSeconds='600')

$script:SmPackagePath=$PSCommandPath

function Get-SmArguments {
 param([string]$Mode='Report',[string]$TempAgeDays='7',[string]$ProfileAgeDays='60',
 [string]$RemoveProfiles='false',[string]$ExcludeProfiles='', [string]$ComponentCleanup='false',
 [string]$MaxFiles='20000',[string]$MaxSeconds='30',[string]$ProfileReport='false',[string]$PrimaryUserHint='',[string]$SharedDevices='',
 [string]$ReviewedReports='',[string]$RemovalCooldownDays='1',[string]$Tier='None',[string]$CleanupSeconds='600')
 if ($Mode -cnotin @('Report','Cleanup')) { throw 'Mode must be Report or Cleanup' }
 if ($Tier -cnotin @('None','Safe','Aggressive')) { throw 'Tier must be None, Safe or Aggressive' }
 if ($Tier -ne 'None' -and $Mode -ne 'Cleanup') { throw 'Tier needs Mode Cleanup' }
 $a=@{ Mode=$Mode; ExcludeProfiles=@($ExcludeProfiles.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
 if ($PrimaryUserHint.Length -gt 256 -or $PrimaryUserHint -match '[\x00-\x1f]') { throw 'Invalid PrimaryUserHint' }; $a.PrimaryUserHint=$PrimaryUserHint.Trim()
 $a.SharedDevices=@($SharedDevices.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
 if ($a.SharedDevices.Count -gt 100 -or @($a.SharedDevices | Where-Object { $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$' }).Count) { throw 'SharedDevices must be a comma-separated list of computer names' }
 # The audit hashes of the two report runs the owner reviewed; see docs/maintenance.md.
 $a.ReviewedReports=@($ReviewedReports.Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
 if ($a.ReviewedReports.Count -notin @(0,2) -or @($a.ReviewedReports | Where-Object { $_ -notmatch '^[0-9a-f]{64}$' }).Count -or ($a.ReviewedReports.Count -eq 2 -and $a.ReviewedReports[0] -eq $a.ReviewedReports[1])) { throw 'ReviewedReports must be empty or two distinct report hashes' }
 foreach($b in @(@('RemoveProfiles',$RemoveProfiles),@('ComponentCleanup',$ComponentCleanup),@('ProfileReport',$ProfileReport))) {
  if ($b[1] -cnotin @('true','false')) { throw "$($b[0]) must be true or false" }; $a[$b[0]]=$b[1] -ceq 'true'
 }
 foreach($n in @(@('TempAgeDays',$TempAgeDays,1,365),@('ProfileAgeDays',$ProfileAgeDays,30,3650),@('MaxFiles',$MaxFiles,1,2000000),@('MaxSeconds',$MaxSeconds,1,1800),@('RemovalCooldownDays',$RemovalCooldownDays,1,365),@('CleanupSeconds',$CleanupSeconds,60,3600))) {
  if ($n[1] -notmatch '^\d{1,7}$' -or [int]$n[1] -lt $n[2] -or [int]$n[1] -gt $n[3]) { throw "Invalid $($n[0])" }; $a[$n[0]]=[int]$n[1]
 }
 if ($a.ProfileReport -and ($a.Mode -ne 'Report' -or $a.RemoveProfiles -or $a.ComponentCleanup)) { throw 'ProfileReport is report-only: Mode must be Report and RemoveProfiles and ComponentCleanup false' }
 # Both tiers include supported component cleanup (never ResetBase). A tier never removes profiles.
 $a.Tier=$Tier; if ($Tier -ne 'None') { $a.ComponentCleanup=$true }
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
# Windows' own hidden+system compatibility junctions point back into the profile, which is walked
# by its real paths, so they do not make the size partial. An unpopulated cloud directory is never
# listed (listing would populate it), so it leaves the size partial wherever it is.
# A listing cannot prove a local OneDrive file's contents are uploaded: a placeholder keeps its tag
# while an edit waits for a paused or failing sync. Only online-only content is known to be in the
# cloud, so every local OneDrive file counts against the upload gate.
# The leading comma returns the lazy enumerator itself, so budgets and guards apply per entry.
# Like Get-SmScan, the walk stays in this process: local profile metadata reads are not the
# identity/event-provider calls that need the killable worker, and recall-on-open dirs are skipped.
$script:SmEnumerate={ param($Dir) ,([IO.DirectoryInfo]::new($Dir)).EnumerateFileSystemInfos() }
$script:SmCompatJunctions=@('\Application Data','\Cookies','\Local Settings','\My Documents','\NetHood','\PrintHood','\Recent','\SendTo','\Start Menu','\Templates','\AppData\Local\Application Data','\AppData\Local\History','\AppData\Local\Temporary Internet Files','\Documents\My Music','\Documents\My Pictures','\Documents\My Videos')
# Names OneDrive never uploads (docs: invalid file names and types), plus its sync-root marker.
$script:SmSyncIgnored='^(desktop\.ini|~\$.*|\.849C9593-D756-4E56-8D6E-42412F2A707B)$'
function Get-SmProfileBytes {
 param([string]$Path,[string]$RecycleRoot,[int]$FileLimit,[double]$Seconds)
 $b=[ordered]@{ost=[int64]0;pst=[int64]0;oneDriveHydrated=[int64]0;oneDriveOnlineOnly=[int64]0;teamsCache=[int64]0;browserCache=[int64]0;temp=[int64]0;downloads=[int64]0;recycleBin=[int64]0;outsideKfm=[int64]0}
 $r=[ordered]@{TotalBytes=[int64]0;Bytes=$b;Partial=$false;Light=$false;EntriesVisited=0;Skipped=0;CompatLinks=0;PstFiles=0;OneDriveLocal=0;OutsideKfmFiles=0;MediaFiles=0;Errors=@()}
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
     if($e.LinkType -eq 'Junction' -and ($attr -band 6) -eq 6 -and $script:SmCompatJunctions -contains $rel) { $r.CompatLinks++; continue }
     if(($attr -band (4096 -bor 262144 -bor 4194304)) -or (($attr -band 1024) -and ($recycle -or -not $oneDrive -or $e.LinkType))) { $r.Skipped++; continue }
     $queue.Enqueue(@($e.FullName,$recycle)); continue
    }
    if(($attr -band 1024) -and $e.LinkType) { $r.Skipped++; continue }
    $len=[int64]$e.Length
    # A PST counts as present wherever it is, online-only included: any PST file means review.
    if(-not $recycle -and $rel -match '\.pst$') { $r.PstFiles++ }
    if($attr -band (4096 -bor 4194304)) { if($oneDrive) { $b.oneDriveOnlineOnly+=$len }; continue }
    if($recycle) { $b.recycleBin+=$len; continue }
    $r.TotalBytes+=$len; $leaf=($rel -split '[\\/]')[-1]
    if($oneDrive) { if($leaf -notmatch $script:SmSyncIgnored) { $r.OneDriveLocal++ } }
    elseif($rel -match '^[\\/](Desktop|Documents|Pictures)[\\/]' -and $leaf -ne 'desktop.ini') { $b.outsideKfm+=$len; $r.OutsideKfmFiles++ }
    if($rel -match '^[\\/](Downloads|Videos|Music)[\\/]' -and $leaf -ne 'desktop.ini') { $r.MediaFiles++ }
    $cat=switch -Regex ($rel) {
     '\.pst$' { 'pst'; break }
     '\.ost$' { 'ost'; break }
     '^[\\/]OneDrive[^\\/]*[\\/]' { 'oneDriveHydrated'; break }
     '^[\\/]AppData[\\/](Local[\\/]Packages[\\/]MSTeams_[^\\/]+[\\/]LocalCache|Roaming[\\/]Microsoft[\\/]Teams)[\\/]' { 'teamsCache'; break }
     '^[\\/]AppData[\\/]Local[\\/](Microsoft[\\/]Edge|Google[\\/]Chrome)[\\/]User Data[\\/].*[\\/](Cache|Code Cache|GPUCache|CacheStorage)[\\/]' { 'browserCache'; break }
     '^[\\/]AppData[\\/]Local[\\/]Temp[\\/]' { 'temp'; break }
     '^[\\/]Downloads[\\/]' { 'downloads'; break }
    }
    if($cat) { $b[$cat]+=$len }
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
 $k=[ordered]@{state='unknown';redirected=0;accounts=0;localOneDriveFiles=$Sizes.OneDriveLocal;outsideKfmFiles=$Sizes.OutsideKfmFiles;error=$null}
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

# Owner gate (one line to drop it): a file in the profile's own Downloads, Videos or Music folder
# blocks candidacy with ReviewUserFoldersNotEmpty. Set to $false to remove this gate.
$script:SmMediaFolderGate=$true

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
 if($null -eq $k.localOneDriveFiles -or $k.localOneDriveFiles -gt 0) { return (& $out 'ReviewKfmUploadUnproven' 'Local OneDrive files: a listing cannot prove they are uploaded; only online-only content is') }
 if($null -eq $k.outsideKfmFiles -or $k.outsideKfmFiles -gt 0) { return (& $out 'ReviewOutsideKfm' 'Files remain in the profile''s own Desktop, Documents or Pictures, outside OneDrive') }
 if($script:SmMediaFolderGate -and ($null -eq $F.MediaFiles -or $F.MediaFiles -gt 0)) { return (& $out 'ReviewUserFoldersNotEmpty' 'Files remain in the profile''s own Downloads, Videos or Music folder') }
 & $out 'StaleCandidate' 'Every gate passed: stale on a shared device, KFM verified, OneDrive content online-only, no PST, no user media files. Removal still needs the reviewed-report, cooldown and cap gates'
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
   $sizes=Get-SmProfileBytes $p.Path $recycle ([int][math]::Floor(($A.MaxFiles-$used)/[math]::Max(1,$left))) (($A.MaxSeconds-$watch.Elapsed.TotalSeconds)/[math]::Max(1,$left))
   $used+=$sizes.EntriesVisited
   if($sizes.Light) { $light=$true; $rep.Errors+='Setup or unknown servicing appeared; remaining profile sizes withheld' }
  }
  $left--
  # The hive is read only for a profile the age engine found unloaded and stale.
  if($sizes -and -not $light -and $p.Decision -eq 'StaleCandidate') { $kfm=Get-SmKfmState $p.Path $sizes }
  $last=@($p.Evidence.Events.Recent | Where-Object { $_.Sid -eq $sid } | Sort-Object TimeUtc -Descending | Select-Object -First 1)
  $flags=@{IsPrimary=[bool]$source;IsService=$isService;IsAdmin=$isAdmin;AdminKnown=$adminKnown;PrimaryKnown=$primaryKnown;CoverageDays=$coverage;AgeDays=$A.ProfileAgeDays;PstBytes=$(if($sizes){$sizes.Bytes.pst});PstFiles=$(if($sizes){$sizes.PstFiles});MediaFiles=$(if($sizes){$sizes.MediaFiles});Kfm=$kfm;SizePartial=(-not $sizes -or $sizes.Partial);Shared=$shared}
  $d=Get-SmReportDecision $p.Decision $p.Reason $flags
  $rep.Profiles+=[pscustomobject][ordered]@{sid=$sid;account=$account;path="$($p.Path)";totalBytes=$(if($sizes){$sizes.TotalBytes});sizePartial=$flags.SizePartial;bytes=$(if($sizes){$sizes.Bytes});lastLogon4624Utc=(& $iso $(if($last.Count){$last[0].TimeUtc}));profileUnloadUtc=(& $iso $unloadUtc);ageDays=$(if($unloadUtc){[int][math]::Floor(($Now-$unloadUtc).TotalDays)});ageSource='ProfileList';isPrimary=$flags.IsPrimary;primarySource=$source;isAdmin=$isAdmin;isService=$isService;kfm=$kfm;mediaFiles=$flags.MediaFiles;ageDecision=$p.Decision;decision=$d.Decision;reason=$d.Reason}
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
 $doc=[ordered]@{schemaVersion=2;package='storage-maintenance';mode=$Report.Mode;status=$Report.Status;timestamp=$Report.Timestamp;reportPath=(& $clip $Report.ReportPath 200);volumes=@($Report.Before | Select-Object -First 4 | ForEach-Object { [ordered]@{drive=$_.DeviceID;capacityBytes=$_.Size;freeBytes=$_.FreeSpace} });eventLog=$pr.EventLog;deviceClass=$pr.DeviceClass;profiles=$profiles;summary=$pr.Summary;audit=$Report.Audit;errors=@(@($pr.Errors)+@($Report.Errors) | Select-Object -First 3 | ForEach-Object { & $clip $_ 160 });truncated=$false}
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

# ---- Profile removal safeguards: hash-chained audit, cooldown marker, reviewed reports, cap. ----
# Each audit line holds a SID, a hash of the profile path, codes and sizes: never a name or path.
# Its hash covers a canonical form of its fields plus the previous line's hash, so an edited,
# deleted or reordered line breaks the chain, and audit.head (seq and hash of the last line)
# exposes a cut tail. Anyone with admin rights can rewrite the whole chain; the copy the run
# prints to the RMM is the off-device anchor. Archives are never pruned, so the chain is whole.
$script:SmAuditFields=@('v','seq','ts','runId','kind','sid','pathHash','decision','reason','bytes','prev')
$script:SmAuditKinds=@('decision','report','removalRun','intent','removed','failed','vetoed','reconciled')
$script:SmAuditMaxBytes=1048576
$script:SmAuditMaxFiles=100
$script:SmProfileRemovalCap=5
$script:SmReviewGapDays=7
$script:SmAuditGenesis='0'*64
$script:SmAuditTimeFormat="yyyyMMdd'T'HHmmss'Z'"

function Get-SmSha256 {
 param([string]$Text)
 $sha=[Security.Cryptography.SHA256]::Create()
 try { -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}
function Get-SmPathHash { param([string]$Path) (Get-SmSha256 $Path.TrimEnd('\').ToLowerInvariant()).Substring(0,16) }
function ConvertFrom-SmAuditTime { param([string]$Text) [datetime]::ParseExact($Text,$script:SmAuditTimeFormat,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal) }

# Fixed field order and a restricted alphabet: the hash never depends on which PowerShell
# version's JSON serializer wrote or reads the line, and no free text can enter it.
function Get-SmAuditCanonical {
 param($Entry)
 @(foreach($n in $script:SmAuditFields) {
  $v=$Entry.$n
  if($null -ne $v -and "$v" -notmatch '^[A-Za-z0-9:._-]{1,128}$') { throw "Audit field $n is outside the canonical alphabet" }
  "$n=$v"
 }) -join '|'
}

function New-SmAuditEntry {
 param([int64]$Seq,[string]$Prev,[string]$RunId,[string]$Kind,[datetime]$Now,[hashtable]$Fields=@{})
 if($Kind -notin $script:SmAuditKinds) { throw 'Unknown audit kind' }
 $e=[ordered]@{v=1;seq=$Seq;ts=$Now.ToUniversalTime().ToString($script:SmAuditTimeFormat,[Globalization.CultureInfo]::InvariantCulture);runId=$RunId;kind=$Kind;sid=$null;pathHash=$null;decision=$null;reason=$null;bytes=$null;prev=$Prev}
 foreach($k in @($Fields.Keys)) { if($k -notin @('sid','pathHash','decision','reason','bytes')) { throw "Audit field $k not allowed" }; $e[$k]=$Fields[$k] }
 foreach($k in @('sid','pathHash','decision','reason')) { if("$($e[$k])" -eq '') { $e[$k]=$null } }
 if($null -ne $e.bytes) { $e.bytes=[int64]$e.bytes }
 if($null -ne $e.sid -and $e.sid -notmatch '^S-1-\d+(-\d+)+$') { throw 'Audit SID malformed' }
 $e.hash=Get-SmSha256 (Get-SmAuditCanonical $e)
 [pscustomobject]$e
}

function Get-SmAuditFiles {
 param([string]$Directory)
 $archives=@(Get-ChildItem -LiteralPath $Directory -File -Force -ErrorAction Stop | Where-Object { $_.Name -match '^audit-\d{10}\.jsonl$' } | Sort-Object Name | ForEach-Object { $_.FullName })
 $current=Join-Path $Directory 'audit.jsonl'
 @($archives)+@(if(Test-Path -LiteralPath $current) { $current })
}

# Detects an edited, deleted, inserted or reordered line (hash, prev, seq), a missing archive
# (seq gap, including the first), a torn last line and a cut tail (audit.head). A head one line
# behind the chain is the crash window between appending a line and updating the head.
function Test-SmAuditChain {
 param([string]$Directory)
 $res=[ordered]@{Valid=$false;Code='AuditUnreadable';Entries=@();LastSeq=[int64]0;LastHash=$script:SmAuditGenesis;CurrentFirstSeq=$null;Files=0;HeadLag=$false;Unresolved=@()}
 $fail={ param($c) $res.Code=$c; [pscustomobject]$res }
 $expected=@($script:SmAuditFields)+@('hash')
 try {
  $files=@(Get-SmAuditFiles $Directory); $res.Files=$files.Count
  if($files.Count -gt $script:SmAuditMaxFiles) { return (& $fail 'AuditTooManyFiles') }
  $entries=New-Object Collections.Generic.List[object]; $prev=$script:SmAuditGenesis; $seq=[int64]0
  foreach($f in $files) {
   $item=Get-Item -LiteralPath $f -Force -ErrorAction Stop
   if(([int64]$item.Attributes -band 1024) -ne 0) { return (& $fail 'AuditFileUnsafe') }
   $text=Read-SmBoundedText $f (2*$script:SmAuditMaxBytes)
   if($text.Length -and -not $text.EndsWith("`n")) { return (& $fail 'AuditTornLine') }
   $lines=@($text.Split("`n") | Where-Object { $_ })
   if(-not $lines.Count) { return (& $fail 'AuditEmptyFile') }
   $first=$true
   foreach($line in $lines) {
    try {
     $o=$line | ConvertFrom-Json -ErrorAction Stop
     $names=@($o.PSObject.Properties.Name)
     if($names.Count -ne $expected.Count -or @($names | Where-Object { $_ -cnotin $expected }).Count -or $o.kind -cnotin $script:SmAuditKinds) { throw 'shape' }
     $lineSeq=[int64]$o.seq; $null=ConvertFrom-SmAuditTime $o.ts; $canonical=Get-SmAuditCanonical $o
    } catch { return (& $fail 'AuditLineMalformed') }
    if((Get-SmSha256 $canonical) -ne $o.hash) { return (& $fail 'AuditEntryEdited') }
    if($o.prev -ne $prev) { return (& $fail 'AuditChainBroken') }
    if($lineSeq -ne $seq+1) { return (& $fail 'AuditSequenceBroken') }
    if($first -and $f -match 'audit-(\d{10})\.jsonl$' -and [int64]$Matches[1] -ne $lineSeq) { return (& $fail 'AuditArchiveMisnamed') }
    if($first -and $f -notmatch 'audit-\d{10}\.jsonl$') { $res.CurrentFirstSeq=$lineSeq }
    $first=$false; $prev="$($o.hash)"; $seq=$lineSeq; $entries.Add($o)
   }
  }
  $headPath=Join-Path $Directory 'audit.head'
  if(Test-Path -LiteralPath $headPath) {
   try { $h=Read-SmBoundedText $headPath 512 | ConvertFrom-Json -ErrorAction Stop; $headSeq=[int64]$h.seq } catch { return (& $fail 'AuditHeadMalformed') }
   if($headSeq -eq $seq -and "$($h.hash)" -eq $prev) { }
   elseif($headSeq -eq $seq-1 -and $seq -ge 1 -and "$($h.hash)" -eq $(if($seq -ge 2){"$($entries[$entries.Count-2].hash)"}else{$script:SmAuditGenesis})) { $res.HeadLag=$true }
   elseif($headSeq -gt $seq) { return (& $fail 'AuditTruncated') }
   else { return (& $fail 'AuditHeadMismatch') }
  } elseif($seq -gt 0) { return (& $fail 'AuditHeadMissing') }
  $all=$entries.ToArray()
  $res.Unresolved=@(foreach($i in @($all | Where-Object { $_.kind -eq 'intent' })) { if(-not @($all | Where-Object { [int64]$_.seq -gt [int64]$i.seq -and $_.sid -eq $i.sid -and $_.kind -in @('removed','failed','reconciled') }).Count) { $i } })
  $res.Entries=$all; $res.LastSeq=$seq; $res.LastHash=$prev; $res.Valid=$true; $res.Code='AuditChainVerified'
 } catch { $res.Code='AuditUnreadable' }
 [pscustomobject]$res
}

# Temp file in the same directory, flushed through, then renamed over the target: a reader sees
# the old or the new content, never a partial one. A crash leaves only an ignored *.tmp file.
function Write-SmAtomicFile {
 param([string]$Path,[string]$Text)
 $tmp=$Path+'.'+[guid]::NewGuid().ToString('n')+'.tmp'
 $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($Text)
 $fs=New-Object IO.FileStream($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
 try { $fs.Write($bytes,0,$bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
 if(Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp,$Path,[NullString]::Value) } else { [IO.File]::Move($tmp,$Path) }
}

# The lock file is held, unshared, from verification to the last append: a concurrent run
# cannot interleave lines or verify a chain that is being written.
function Open-SmAudit {
 param([string]$Directory)
 $lock=$null
 for($i=0;-not $lock;$i++) {
  try { $lock=[IO.File]::Open((Join-Path $Directory 'audit.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
  catch { if($i -ge 19) { throw 'Audit lock is held by another run' }; Start-Sleep -Milliseconds 100 }
 }
 $chain=Test-SmAuditChain $Directory
 [pscustomobject]@{Directory=$Directory;Lock=$lock;Chain=$chain;Seq=$chain.LastSeq;Prev=$chain.LastHash;CurrentFirstSeq=$chain.CurrentFirstSeq;Files=$chain.Files}
}
function Close-SmAudit { param($Audit) if($Audit -and $Audit.Lock) { $Audit.Lock.Dispose(); $Audit.Lock=$null } }

function Add-SmAuditEntry {
 param($Audit,[string]$RunId,[string]$Kind,[hashtable]$Fields=@{},[datetime]$Now=[datetime]::UtcNow)
 if(-not $Audit -or -not $Audit.Lock -or -not $Audit.Chain.Valid) { throw 'Audit chain unavailable or invalid' }
 $e=New-SmAuditEntry ($Audit.Seq+1) $Audit.Prev $RunId $Kind $Now $Fields
 $bytes=[Text.Encoding]::UTF8.GetBytes(($e | ConvertTo-Json -Compress)+"`n")
 $current=Join-Path $Audit.Directory 'audit.jsonl'
 # Rotation renames the full file by its first seq; the next line still links to its last hash.
 if($null -ne $Audit.CurrentFirstSeq -and (Get-Item -LiteralPath $current -Force -ErrorAction Stop).Length+$bytes.Length -gt $script:SmAuditMaxBytes) {
  [IO.File]::Move($current,(Join-Path $Audit.Directory ('audit-{0:D10}.jsonl' -f [int64]$Audit.CurrentFirstSeq))); $Audit.CurrentFirstSeq=$null
 }
 if($null -eq $Audit.CurrentFirstSeq) { if($Audit.Files -ge $script:SmAuditMaxFiles) { throw 'Audit file limit reached; archive the audit directory by hand' }; $Audit.Files++; $Audit.CurrentFirstSeq=$e.seq }
 $fs=New-Object IO.FileStream($current,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
 try { $fs.Write($bytes,0,$bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
 $Audit.Seq=$e.seq; $Audit.Prev=$e.hash
 Write-SmAtomicFile (Join-Path $Audit.Directory 'audit.head') ([ordered]@{seq=$e.seq;hash=$e.hash} | ConvertTo-Json -Compress)
 $e
}

# Cooldown: the chain's last removalRun line is the truth; cooldown.json must agree with it.
# A missing, malformed or disagreeing marker, or a clock behind the chain, allows no removal in
# this run; the caller then rewrites the marker from the verified chain for the next run.
function Get-SmCooldownState {
 param($MarkerText,$Chain,[datetime]$Now,[int]$Days)
 $runs=@($Chain.Entries | Where-Object { $_.kind -eq 'removalRun' })
 $last=if($runs.Count) { $runs[-1] }
 $seed=[ordered]@{v=1;lastRemovalRunUtc=$(if($last){"$($last.ts)"});lastRemovalRunHash=$(if($last){"$($last.hash)"})}
 $s=[ordered]@{Allowed=$false;Code='CooldownClear';Seed=$seed;Rewrite=$false}
 $out={ param($c,[bool]$rewrite) $s.Code=$c; $s.Rewrite=$rewrite; [pscustomobject]$s }
 if(@($Chain.Entries | Where-Object { (ConvertFrom-SmAuditTime $_.ts) -gt $Now.AddMinutes(5) }).Count) { return (& $out 'ClockSkew' $false) }
 if($null -eq $MarkerText) { return (& $out 'CooldownMarkerMissing' $true) }
 try { $m=$MarkerText | ConvertFrom-Json -ErrorAction Stop } catch { return (& $out 'CooldownMarkerMalformed' $true) }
 if($null -eq $m -or $m.v -ne 1 -or "$($m.lastRemovalRunUtc)" -ne "$($seed.lastRemovalRunUtc)" -or "$($m.lastRemovalRunHash)" -ne "$($seed.lastRemovalRunHash)") { return (& $out 'CooldownMarkerMismatch' $true) }
 if($last -and ($Now-(ConvertFrom-SmAuditTime $last.ts)).TotalDays -lt $Days) { return (& $out 'CooldownActive' $false) }
 $s.Allowed=$true; [pscustomobject]$s
}

function Sync-SmCooldownMarker {
 param($Audit,[datetime]$Now,[int]$Days)
 $path=Join-Path $Audit.Directory 'cooldown.json'
 $text=if(Test-Path -LiteralPath $path) { Read-SmBoundedText $path 4096 }
 $cool=Get-SmCooldownState $text $Audit.Chain $Now $Days
 if($cool.Rewrite) { Write-SmAtomicFile $path ($cool.Seed | ConvertTo-Json -Compress) }
 $cool
}

# The owner approves two report runs by their 'report' line hashes. Only a profile that was a
# StaleCandidate, at the same path, in both of those runs is approved for removal.
function Get-SmReviewedCandidates {
 param($Chain,[string[]]$Hashes,[datetime]$Now)
 $no={ param($c) [pscustomobject]@{Valid=$false;Code=$c;Keys=@()} }
 if(@($Hashes).Count -ne 2 -or $Hashes[0] -eq $Hashes[1]) { return (& $no 'ReviewedReportsMissing') }
 $reports=@(foreach($h in $Hashes) { $Chain.Entries | Where-Object { $_.hash -eq $h -and $_.kind -eq 'report' } })
 if($reports.Count -ne 2 -or $reports[0].runId -eq $reports[1].runId) { return (& $no 'ReviewedReportNotInChain') }
 $times=@($reports | ForEach-Object { ConvertFrom-SmAuditTime $_.ts })
 if(@($times | Where-Object { $_ -gt $Now.AddMinutes(5) }).Count) { return (& $no 'ClockSkew') }
 if([math]::Abs(($times[0]-$times[1]).TotalDays) -lt $script:SmReviewGapDays) { return (& $no 'ReviewedReportsTooClose') }
 $sets=@(foreach($rep in $reports) { ,@($Chain.Entries | Where-Object { $_.runId -eq $rep.runId -and $_.kind -eq 'decision' -and $_.decision -eq 'StaleCandidate' -and [int64]$_.seq -lt [int64]$rep.seq } | ForEach-Object { "$($_.sid)|$($_.pathHash)" }) })
 [pscustomobject]@{Valid=$true;Code='ReviewedReportsVerified';Keys=@($sets[0] | Where-Object { $sets[1] -contains $_ })}
}

# Every removal gate except the per-run cap, which the removal loop counts. Candidates are
# this run's fresh gate-matrix StaleCandidates that the two reviewed reports also approved.
function Get-SmRemovalPlan {
 param($A,$Report,$Audit,$Cooldown,[datetime]$Now,[string]$ComputerName)
 $plan={ param($c,$list) [pscustomobject]@{Allowed=[bool]@($list).Count;Code=$c;Candidates=@($list)} }
 if($A.Mode -ne 'Cleanup' -or -not $A.RemoveProfiles -or $A.ProfileReport) { return (& $plan 'RemoveProfilesOff' @()) }
 if(-not ($ComputerName -and @($A.SharedDevices) -contains $ComputerName)) { return (& $plan 'NotSharedDevice' @()) }
 if(-not $Audit -or -not $Audit.Chain.Valid) { return (& $plan $(if($Audit){$Audit.Chain.Code}else{'AuditUnavailable'}) @()) }
 if(@($Audit.Chain.Unresolved).Count) { return (& $plan 'UnresolvedIntent' @()) }
 $reviewed=Get-SmReviewedCandidates $Audit.Chain $A.ReviewedReports $Now
 if(-not $reviewed.Valid) { return (& $plan $reviewed.Code @()) }
 if(-not $Cooldown -or -not $Cooldown.Allowed) { return (& $plan $(if($Cooldown){$Cooldown.Code}else{'CooldownUnknown'}) @()) }
 $list=@($Report.Profiles | Where-Object { $_.decision -eq 'StaleCandidate' -and $reviewed.Keys -contains ("$($_.sid)|"+(Get-SmPathHash "$($_.path)")) })
 & $plan $(if($list.Count){'Ready'}else{'NoApprovedCandidate'}) $list
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
$script:SmAuditDirectory={ Initialize-SmSecureDirectory (Join-Path $env:ProgramData 'RelianMaintenance\Profiles') }
$script:SmRemovalPlan={ param($A,$Report,$Audit,$Cooldown,$Now,$ComputerName) Get-SmRemovalPlan $A $Report $Audit $Cooldown $Now $ComputerName }
# The full gate matrix for one profile, evaluated again from fresh evidence right before removal.
$script:SmRecheckGate={ param($A,$Assessed,$Context,$Now) @((Get-SmProfileReport $A @($Assessed) $Context $Now).Profiles)[0] }
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

# Non-profile cleanup tiers (Mode=Cleanup with Tier=Safe or Aggressive). Each category deletes only
# files older than TempAgeDays under a fixed root. Documents, Desktop, Downloads, OneDrive, Outlook
# data, hiberfil, pagefile, profiles and live upgrade staging are never roots. Profiles stay in the
# separate RemoveProfiles path above and are not part of any tier.
$script:SmSkipAttributes=1024 -bor 4096 -bor 262144 -bor 4194304
$script:SmCacheNames='^(Cache|Code Cache|GPUCache|CacheStorage|ShaderCache|GrShaderCache|DawnCache|DawnWebGPUCache|DawnGraphiteCache)$'
# cleanmgr handlers the Aggressive tier selects. Anything not listed (DownloadsFolder, Recycle Bin,
# User file versions, BranchCache, Language Pack) is cleared from the sageset profile every run.
$script:SmCleanmgrHandlers=@('Active Setup Temp Folders','D3D Shader Cache','Delivery Optimization Files','Device Driver Packages','Downloaded Program Files','Internet Cache Files','Old ChkDsk Files','Setup Log Files','System error memory dump files','System error minidump files','Temporary Files','Temporary Setup Files','Thumbnail Cache','Update Cleanup','Upgrade Discarded Files','Windows Error Reporting Files','Windows Upgrade Log Files')
$script:SmSageSet=77
$script:SmWindowsOldDays=10

# The path and every ancestor, read just before a delete. A junction swapped in after this
# check is a residual race; checking right before each delete keeps the window to one call.
function Test-SmPlainChain {
 param([string]$Path)
 $cur=[IO.Path]::GetFullPath($Path)
 while($cur) {
  try { if(([int64][IO.File]::GetAttributes($cur) -band $script:SmSkipAttributes) -ne 0) { return $false } } catch { return $false }
  $cur=[IO.Path]::GetDirectoryName($cur)
 }
 $true
}

function Remove-SmAgedFiles {
 param([string]$Root,[datetime]$CutoffUtc,[datetime]$DeadlineUtc,[string]$Include='.',[string]$Exclude='^$',[switch]$NoRecurse,[switch]$RemoveEmptyDirs,[switch]$IncludeRoot)
 $res=[ordered]@{Root=$Root;Files=0;LogicalBytes=[int64]0;Failed=0;TimedOut=$false;Error=$null}
 if(-not [IO.Directory]::Exists($Root)) { return [pscustomobject]$res }
 if(-not (Test-SmPlainChain $Root)) { $res.Error='Root or an ancestor is a reparse point or cloud file'; return [pscustomobject]$res }
 $dirs=New-Object Collections.Generic.List[string]; $stack=New-Object Collections.Generic.Stack[string]; $stack.Push($Root)
 while($stack.Count) {
  $dir=$stack.Pop(); $dirs.Add($dir)
  try { $entries=@([IO.DirectoryInfo]::new($dir).EnumerateFileSystemInfos()) } catch { $res.Failed++; continue }
  foreach($e in $entries) {
   if([datetime]::UtcNow -ge $DeadlineUtc) { $res.TimedOut=$true; return [pscustomobject]$res }
   if(([int64]$e.Attributes -band $script:SmSkipAttributes) -ne 0) { continue }
   if($e -is [IO.DirectoryInfo]) { if(-not $NoRecurse) { $stack.Push($e.FullName) }; continue }
   # A copied or extracted file keeps an old write time; the newer of the two dates counts.
   $stamp=if($e.CreationTimeUtc -gt $e.LastWriteTimeUtc){$e.CreationTimeUtc}else{$e.LastWriteTimeUtc}
   if($stamp -ge $CutoffUtc -or $e.Name -notmatch $Include -or $e.Name -match $Exclude) { continue }
   try {
    if(-not (Test-SmPlainChain $e.FullName)) { throw 'Reparse or cloud ancestor' }
    $len=$e.Length; & $script:SmDelete $e.FullName; $res.Files++; $res.LogicalBytes+=$len
   } catch { $res.Failed++ }
  }
 }
 if($RemoveEmptyDirs) {
  $last=if($IncludeRoot){0}else{1}
  for($i=$dirs.Count-1;$i -ge $last;$i--) {
   # Creation time, not write time: emptying a folder updates its write time. A folder an installer
   # created just now is never pruned.
   try { if([IO.Directory]::GetCreationTimeUtc($dirs[$i]) -lt $CutoffUtc -and -not ([IO.Directory]::EnumerateFileSystemEntries($dirs[$i]).GetEnumerator().MoveNext()) -and (Test-SmPlainChain $dirs[$i])) { [IO.Directory]::Delete($dirs[$i]) } } catch { }
  }
 }
 [pscustomobject]$res
}

# Browser and Teams cache folders only: never profile data, cookies, logins or IndexedDB.
function Get-SmAppCacheRoots {
 param([string]$ProfilePath)
 $bases=@('AppData\Local\Microsoft\Edge\User Data','AppData\Local\Google\Chrome\User Data','AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView','AppData\Roaming\Microsoft\Teams')
 foreach($b in $bases) {
  $base=Join-Path $ProfilePath $b
  if(-not [IO.Directory]::Exists($base) -or -not (Test-SmPlainChain $base)) { continue }
  # Depth 3 reaches User Data\<profile>\Service Worker\CacheStorage.
  $queue=New-Object Collections.Generic.Queue[object]; $queue.Enqueue(@($base,0))
  while($queue.Count) {
   $item=$queue.Dequeue()
   try { $children=@([IO.DirectoryInfo]::new($item[0]).EnumerateDirectories()) } catch { continue }
   foreach($c in $children) {
    if(([int64]$c.Attributes -band $script:SmSkipAttributes) -ne 0) { continue }
    if($c.Name -match $script:SmCacheNames) { $c.FullName } elseif($item[1] -lt 2) { $queue.Enqueue(@($c.FullName,($item[1]+1))) }
   }
  }
 }
}

# Fixed category roots for one run. Pure apart from Get-SmAppCacheRoots, so the roots are testable.
function Get-SmCleanupCategories {
 param([string[]]$ProfilePaths,[string]$WinDir,[string]$ProgramData)
 $wer=Join-Path $ProgramData 'Microsoft\Windows\WER'
 $c=@(
  @{Name='Temp';Root=(Join-Path $WinDir 'Temp');Prune=$true}
  @{Name='WindowsUpdateDownload';Root=(Join-Path $WinDir 'SoftwareDistribution\Download');Prune=$true}
  @{Name='CrashDumps';Root=(Join-Path $WinDir 'Minidump')}
  @{Name='CrashDumps';Root=(Join-Path $WinDir 'LiveKernelReports')}
  @{Name='CrashDumps';Root=$WinDir;Include='^MEMORY\.DMP$';NoRecurse=$true}
  @{Name='CrashDumps';Root=(Join-Path $wer 'ReportArchive');Prune=$true}
  @{Name='CrashDumps';Root=(Join-Path $wer 'ReportQueue');Prune=$true}
  @{Name='CrashDumps';Root=(Join-Path $wer 'Temp');Prune=$true}
  @{Name='ServicingLogs';Root=(Join-Path $WinDir 'Logs\CBS');Include='\.(log|cab)$';Exclude='^CBS\.log$';NoRecurse=$true}
  @{Name='ServicingLogs';Root=(Join-Path $WinDir 'Logs\DISM');Include='\.log$';Exclude='^dism\.log$';NoRecurse=$true}
 )
 foreach($p in @($ProfilePaths | Where-Object { $_ })) {
  $c+=@{Name='Temp';Root=(Join-Path $p 'AppData\Local\Temp');Prune=$true}
  $c+=@{Name='CrashDumps';Root=(Join-Path $p 'AppData\Local\CrashDumps')}
  # No folder pruning in caches: a running browser expects its cache subfolders to exist.
  foreach($cache in @(Get-SmAppCacheRoots $p)) { $c+=@{Name='AppCache';Root=$cache} }
 }
 $c
}

# Recycle Bin items are aged by their $I record (deletion time), not by the deleted file's dates.
function Remove-SmRecycleBin {
 param([string]$Root,[datetime]$CutoffUtc,[datetime]$DeadlineUtc)
 $res=[ordered]@{Root=$Root;Files=0;LogicalBytes=[int64]0;Failed=0;TimedOut=$false;Error=$null}
 if(-not [IO.Directory]::Exists($Root) -or -not (Test-SmPlainChain $Root)) { return [pscustomobject]$res }
 foreach($sidDir in @([IO.DirectoryInfo]::new($Root).EnumerateDirectories())) {
  if(([int64]$sidDir.Attributes -band $script:SmSkipAttributes) -ne 0) { continue }
  foreach($info in @($sidDir.EnumerateFiles('$I*'))) {
   if([datetime]::UtcNow -ge $DeadlineUtc) { $res.TimedOut=$true; return [pscustomobject]$res }
   $deleted=$null
   try { if(Test-SmPlainChain $info.FullName) { $deleted=ConvertFrom-SmRecycleRecord ([IO.File]::ReadAllBytes($info.FullName)) } } catch { }
   if($null -eq $deleted -or $deleted -ge $CutoffUtc) { continue }
   $data=Join-Path $sidDir.FullName ('$R'+$info.Name.Substring(2))
   try {
    if([IO.Directory]::Exists($data)) {
     $sub=Remove-SmAgedFiles $data ([datetime]::MaxValue) $DeadlineUtc -RemoveEmptyDirs -IncludeRoot
     $res.Files+=$sub.Files; $res.LogicalBytes+=$sub.LogicalBytes; $res.Failed+=$sub.Failed
     if($sub.TimedOut) { $res.TimedOut=$true; return [pscustomobject]$res }
     if([IO.Directory]::Exists($data)) { throw 'Recycled folder not empty' }
    } elseif([IO.File]::Exists($data)) {
     if(-not (Test-SmPlainChain $data)) { throw 'Reparse or cloud item' }
     $len=([IO.FileInfo]::new($data)).Length; & $script:SmDelete $data; $res.Files++; $res.LogicalBytes+=$len
    }
    if(-not (Test-SmPlainChain $info.FullName)) { throw 'Reparse or cloud item' }
    & $script:SmDelete $info.FullName
   } catch { $res.Failed++ }
  }
 }
 [pscustomobject]$res
}

function Get-SmCleanmgrSelection {
 param([string[]]$Available,[bool]$IncludePreviousInstallations)
 $want=@($script:SmCleanmgrHandlers)+@(if($IncludePreviousInstallations){'Previous Installations'})
 @($Available | Where-Object { $want -contains $_ })
}

# Deletion time from a $I record: version 1 or 2, deletion FILETIME at byte 16. Anything
# unreadable, zero or in the future returns $null and the item is kept.
function ConvertFrom-SmRecycleRecord {
 param([byte[]]$Bytes,[datetime]$Now=[datetime]::UtcNow)
 if($null -eq $Bytes -or $Bytes.Length -lt 24) { return $null }
 $version=[BitConverter]::ToInt64($Bytes,0); $ft=[BitConverter]::ToInt64($Bytes,16)
 if($version -notin @(1,2) -or $ft -le 0) { return $null }
 try { $t=[datetime]::FromFileTimeUtc($ft) } catch { return $null }
 if($t -lt [datetime]'2000-01-01' -or $t -gt $Now.ToUniversalTime()) { return $null }
 $t
}

# Windows.old removes the rollback option. Eligible only after the rollback window, counted from
# the current OS install (upgrade) date, with the window read from the device (DISM
# /Set-OSUninstallWindow writes UninstallWindow). Unknown dates or window keep Windows.old.
function Test-SmWindowsOldEligible {
 param($CreatedUtc,$InstalledUtc,$WindowDays,[datetime]$Now=[datetime]::UtcNow)
 if($null -eq $CreatedUtc -or $null -eq $InstalledUtc -or $null -eq $WindowDays) { return $false }
 if("$WindowDays" -notmatch '^\d{1,4}$') { return $false }
 $days=[math]::Max([int]$WindowDays,$script:SmWindowsOldDays); $limit=$Now.ToUniversalTime().AddDays(-$days)
 ([datetime]$CreatedUtc) -lt $limit -and ([datetime]$InstalledUtc) -lt $limit
}

# Shrink only a limit above 5 % of the volume; UNBOUNDED reads as the uint64 maximum.
function Test-SmShadowShrink { param($MaxSpace,$Capacity) [decimal]$Capacity -gt 0 -and [decimal]$MaxSpace -gt ([decimal]$Capacity*0.05) }

$script:SmFreeBytes={ [int64](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -OperationTimeoutSec 5 -ErrorAction Stop).FreeSpace }
$script:SmDeliveryOptimization={ if(-not (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) { throw 'Delete-DeliveryOptimizationCache unavailable' }; Delete-DeliveryOptimizationCache -Force -ErrorAction Stop }
$script:SmWindowsOldState={
 $s=@{CreatedUtc=$null;InstalledUtc=$null;WindowDays=$null}
 $p=Join-Path $env:SystemDrive 'Windows.old'; if(-not [IO.Directory]::Exists($p)) { return $s }
 $s.CreatedUtc=([IO.DirectoryInfo]::new($p)).CreationTimeUtc
 try { $s.InstalledUtc=([datetime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)).AddSeconds([double](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).InstallDate) } catch { }
 # No value means the Windows default of 10 days; an unreadable key leaves it unknown.
 try { $w=(Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction Stop).UninstallWindow; $s.WindowDays=if($null -eq $w){$script:SmWindowsOldDays}else{$w} } catch { }
 $s
}
$script:SmCleanmgr={
 param([bool]$IncludePreviousInstallations,[int]$Seconds)
 $base='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'; $flag='StateFlags{0:D4}' -f $script:SmSageSet
 $keys=@(Get-ChildItem -LiteralPath $base -ErrorAction Stop)
 $selected=Get-SmCleanmgrSelection @($keys | ForEach-Object { $_.PSChildName }) $IncludePreviousInstallations
 foreach($k in $keys) {
  if($selected -contains $k.PSChildName) { Set-ItemProperty -LiteralPath $k.PSPath -Name $flag -Value 2 -Type DWord -ErrorAction Stop }
  elseif($null -ne $k.GetValue($flag)) { Remove-ItemProperty -LiteralPath $k.PSPath -Name $flag -ErrorAction Stop }
 }
 $p=Start-Process -FilePath (Join-Path $env:windir 'System32\cleanmgr.exe') -ArgumentList ('/sagerun:'+$script:SmSageSet) -PassThru -WindowStyle Hidden
 # Not killed on timeout: cleanmgr may be inside a servicing call.
 if(-not $p.WaitForExit([math]::Max(1,$Seconds)*1000)) { return @{Handlers=$selected;State='stillRunning'} }
 @{Handlers=$selected;State='exited';ExitCode=$p.ExitCode}
}
$script:SmShadowShrink={
 $vol=@(Get-CimInstance Win32_Volume -Filter "DriveLetter='$($env:SystemDrive)'" -OperationTimeoutSec 5 -ErrorAction Stop)[0]
 $storage=@(Get-CimInstance Win32_ShadowStorage -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object { $_.Volume.DeviceID -eq $vol.DeviceID })
 if(-not $storage.Count) { return 'noShadowStorage' }
 if(-not (Test-SmShadowShrink $storage[0].MaxSpace $vol.Capacity)) { return 'alreadyAtOrBelow5Percent' }
 $out=& (Join-Path $env:windir 'System32\vssadmin.exe') Resize ShadowStorage ('/For='+$env:SystemDrive) ('/On='+$env:SystemDrive) '/MaxSize=5%' 2>&1
 if($LASTEXITCODE -ne 0) { throw ('vssadmin exit '+$LASTEXITCODE+': '+(($out | Out-String).Trim())) }
 'resizedTo5Percent'
}

function Invoke-SmCleanupTier {
 param($A,[string[]]$ProfilePaths)
 $steps=@(); $deadline=[datetime]::UtcNow.AddSeconds($A.CleanupSeconds); $cutoff=[datetime]::UtcNow.AddDays(-$A.TempAgeDays)
 $measure={ param($Name,$Work)
  $step=[ordered]@{Kind='category';Name=$Name;Status='withheld';Files=0;LogicalBytes=[int64]0;Failed=0;FreeBefore=$null;FreeAfter=$null;FreedBytes=$null;Detail=$null;Error=$null}
  try {
   if([datetime]::UtcNow -ge $deadline) { throw 'Cleanup time budget exhausted' }
   if(-not (& $script:SmGuards).Safe) { throw 'Servicing guard changed; tier stopped' }
   $step.FreeBefore=& $script:SmFreeBytes
   $out=& $Work
   foreach($o in @($out | Where-Object { $_ -is [Collections.IDictionary] -or $_.PSObject.Properties['Files'] })) {
    if($null -ne $o.Files) { $step.Files+=$o.Files; $step.LogicalBytes+=$o.LogicalBytes; $step.Failed+=$o.Failed; if($o.TimedOut) { $step.Error='Cleanup time budget exhausted' } elseif($o.Error -and -not $step.Error) { $step.Error=$o.Error } }
    if($o.Detail) { $step.Detail=$o.Detail }
   }
   # A refused root or files that could not be deleted (often in use) make the category partial.
   $step.Status=if($step.Error -or $step.Failed){'partial'}else{'done'}
  } catch { $step.Error=$_.Exception.Message }
  try { if($null -ne $step.FreeBefore) { $step.FreeAfter=& $script:SmFreeBytes; $step.FreedBytes=$step.FreeAfter-$step.FreeBefore } } catch { }
  [pscustomobject]$step
 }
 $categories=@(Get-SmCleanupCategories $ProfilePaths $env:windir $env:ProgramData)
 foreach($name in @($categories | ForEach-Object { $_.Name } | Select-Object -Unique)) {
  $mine=@($categories | Where-Object { $_.Name -eq $name })
  $steps+=& $measure $name { foreach($c in $mine) { $opt=@{}; foreach($k in 'Include','Exclude') { if($c[$k]) { $opt[$k]=$c[$k] } }; Remove-SmAgedFiles $c.Root $cutoff $deadline @opt -NoRecurse:([bool]$c.NoRecurse) -RemoveEmptyDirs:([bool]$c.Prune) } }
 }
 $steps+=& $measure 'RecycleBin' { Remove-SmRecycleBin (Join-Path $env:SystemDrive '$Recycle.Bin') $cutoff $deadline }
 $steps+=& $measure 'DeliveryOptimization' { $null=& $script:SmDeliveryOptimization; @{Detail='Delete-DeliveryOptimizationCache'} }
 # The feature-upgrade package removes its ISO itself after success; a failed or rolled-back
 # attempt leaves it. Only a terminal, aged attempt qualifies; a running or staged one never does.
 $steps+=& $measure 'FeatureUpgradeIso' {
  $dir=Join-Path $env:ProgramData 'Relian\FeatureUpgrade'; $statePath=Join-Path $dir 'state.json'
  if(-not [IO.File]::Exists($statePath)) { return @{Detail='no attempt state'} }
  $state=Read-SmBoundedText $statePath 65536 | ConvertFrom-Json -ErrorAction Stop
  if("$($state.status)" -notin @('failed','rolledBack','alreadyCurrent')) { return @{Detail=('attempt '+$state.status+'; ISO kept')} }
  $stamp=[datetime]::Parse([string]$state.time,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
  if($stamp -ge $cutoff) { return @{Detail='attempt newer than TempAgeDays; ISO kept'} }
  Remove-SmAgedFiles $dir $cutoff $deadline -Include '\.iso(\.part)?$' -NoRecurse
 }
 if($A.Tier -eq 'Aggressive') {
  $old=& $script:SmWindowsOldState
  $windowsOld=Test-SmWindowsOldEligible $old.CreatedUtc $old.InstalledUtc $old.WindowDays
  $steps+=& $measure 'Cleanmgr' { $r=& $script:SmCleanmgr $windowsOld ([int]($deadline-[datetime]::UtcNow).TotalSeconds); @{Detail=('{0}; previousInstallations={1}; handlers={2}' -f $r.State,$windowsOld,@($r.Handlers).Count)} }
  $steps+=& $measure 'ShadowStorage' { @{Detail=(& $script:SmShadowShrink)} }
 }
 $steps
}

function ConvertTo-SmSummary {
 param($Report,[string]$ReportPath)
 # All strings are clipped before serialization; item limits and the UTF8 byte
 # fallback make truncation explicit without losing measured volume evidence.
 $clip={ param($Value,[int]$Limit=180) $text=[string]$Value; if($text.Length -gt $Limit) { return $text.Substring(0,$Limit)+'...' }; $text }
 $volumes={ param($Items) @($Items | Select-Object -First 4 | ForEach-Object { @{DeviceID=(& $clip $_.DeviceID 20);Size=$_.Size;FreeSpace=$_.FreeSpace} }) }
 $summary=[ordered]@{SchemaVersion=1;Status=$Report.Status;Mode=$Report.Mode;ReportPath=(& $clip $ReportPath 300);ActionCount=$Report.Actions.Count;GuardReasons=@($Report.Guards.Reasons | Select-Object -First 5 | ForEach-Object { & $clip $_ });PartialScan=if($Report.Scan){$Report.Scan.Partial}else{$true};Before=@(& $volumes $Report.Before);After=@(& $volumes $Report.After);FreeSpaceDelta=@($Report.FreeSpaceDelta | Select-Object -First 4);TopFiles=@($Report.Scan.TopFiles | Where-Object { $null -ne $_ } | Select-Object -First 3 | ForEach-Object { @{Path=(& $clip $_.Path);LogicalBytes=$_.LogicalBytes} });TopFolders=@($Report.Scan.TopFolders | Where-Object { $null -ne $_ } | Select-Object -First 3 | ForEach-Object { @{Path=(& $clip $_.Path);DirectFileLogicalBytes=$_.DirectFileLogicalBytes} });TempOpportunities=@($Report.Scan.TempCategories | Where-Object { $null -ne $_ } | Select-Object -First 3 | ForEach-Object { @{Root=(& $clip $_.Root);LogicalBytes=$_.LogicalBytes;AgeQualifiedLogicalBytes=$_.AgeQualifiedLogicalBytes;ReclaimableBytes=$null} });ProfileDecisions=@($Report.Profiles | Group-Object Decision | Select-Object -First 8 | ForEach-Object { @{Decision=(& $clip $_.Name 60);Count=$_.Count} });OpportunityCount=@($Report.Evidence.Opportunities | Where-Object { $null -ne $_ }).Count;ProfileCount=@($Report.Profiles).Count;Notifications=@($Report.Notifications | Select-Object -First 3 | ForEach-Object { & $clip $_ });Errors=@($Report.Errors | Select-Object -First 3 | ForEach-Object { & $clip $_ });Truncated=$true;Truncation='Summary limits: 4 volumes, 3 consumers/category, 8 profile decisions; strings clipped. Full evidence in ReportPath.';ScanWithheld=($Report.Guards.Light -eq $true);Categories=@($Report.Actions | Where-Object { $_.Kind -eq 'category' } | Select-Object -First 12 | ForEach-Object { [ordered]@{Name=$_.Name;Status=$_.Status;Files=$_.Files;FreedBytes=$_.FreedBytes;Detail=(& $clip $_.Detail 80);Error=(& $clip $_.Error 80)} });ProfileRemoval=$Report.RemovalPlan;Audit=$(if($Report.Audit){[ordered]@{code=$Report.Audit.code;headSeq=$Report.Audit.headSeq;error=$Report.Audit.error}})}
 $json=$summary | ConvertTo-Json -Depth 6 -Compress
 if([Text.Encoding]::UTF8.GetByteCount($json) -gt 8000) {
  $summary.GuardReasons=@($summary.GuardReasons | Select-Object -First 1 | ForEach-Object { & $clip $_ 80 }); $summary.Notifications=@(); $summary.Errors=@($summary.Errors | Select-Object -First 1 | ForEach-Object { & $clip $_ 80 }); $summary.FreeSpaceDelta=@(); $summary.TopFolders=@($summary.TopFolders | Select-Object -First 1 | ForEach-Object { $_.Path=& $clip $_.Path 80; $_ }); $summary.TopFiles=@($summary.TopFiles | Select-Object -First 1 | ForEach-Object { $_.Path=& $clip $_.Path 80; $_ }); $summary.TempOpportunities=@($summary.TempOpportunities | Select-Object -First 1 | ForEach-Object { $_.Root=& $clip $_.Root 80; $_ }); $summary.Truncation='Byte cap reached; volume measurements, one consumer/category, first error and decision counts retained. See full local report.'
  $json=$summary | ConvertTo-Json -Depth 6 -Compress
 }
 return $json
}

function Invoke-SmMaintenance {
 param($A)
 $r=[ordered]@{ SchemaVersion=1; Timestamp=[datetime]::UtcNow.ToString('o'); Mode=$A.Mode; Status='complete'; ReportPath=$null; Guards=$null; Before=@(); After=@(); FreeSpaceDelta=@(); Profiles=@(); Scan=$null; Actions=@(); Notifications=@(); Errors=@(); Omissions=@('User documents/downloads, rollback/recovery, installer cache and Windows components are never deleted.','Logical sizes exclude unreadable/reparse/cloud entries; hardlinks, compression and sparse files make reclaimable bytes uncertain.','App caches are reported as opportunities only unless Tier is Safe or Aggressive, which delete cache-folder files older than TempAgeDays.','Directory ranking counts direct files, not recursively accumulated subtree sizes; categories may overlap.','Upgrade staging/Windows.old are preserved. Historical staging needs independent Source OS, install and boot completion evidence; unestablished status stays light/withheld.'); Evidence=$null; ProfileReport=$null; Audit=$null; RemovalPlan=$null }
 $acquired=$false; $audit=$null
 # A removal run evaluates the same gate matrix as a report run, freshly, in this run.
 $removal=($A.Mode -eq 'Cleanup' -and $A.RemoveProfiles -and -not $A.ProfileReport)
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
   $collected=& $script:SmCollectProfiles $profiles $A.ProfileAgeDays $assessedUtc $evidenceRemaining $evidenceDirectory $(if($A.ProfileReport -or $removal){'Report'}else{'Full'})
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
   $gateReport=$null
   if($A.ProfileReport -or $removal) {
    $gateReport=Get-SmProfileReport $A $r.Profiles $collected.ReportContext $assessedUtc
    if($A.ProfileReport) { $r.ProfileReport=$gateReport }
    # Every decision is on the chain before any removal; a report run seals its decisions with a
    # 'report' line whose hash is what the owner approves (ReviewedReports).
    $runId=[guid]::NewGuid().ToString('n'); $r.Audit=[ordered]@{runId=$runId;code=$null;reportHash=$null;headSeq=$null;error=$null}
    try {
     $audit=Open-SmAudit (& $script:SmAuditDirectory); $r.Audit.code=$audit.Chain.Code
     if($audit.Chain.Valid) {
      foreach($p in @($gateReport.Profiles)) { $null=Add-SmAuditEntry $audit $runId 'decision' @{sid=$(if("$($p.sid)" -match '^S-1-\d+(-\d+)+$'){"$($p.sid)"});pathHash=(Get-SmPathHash "$($p.path)");decision="$($p.decision)";reason="$($p.ageDecision)";bytes=$p.totalBytes} $assessedUtc }
      if($A.ProfileReport) {
       $r.Audit.reportHash=(Add-SmAuditEntry $audit $runId 'report' @{decision='ProfileReport';reason=('candidates'+[int]$gateReport.Summary.candidates);bytes=$gateReport.Summary.candidateBytes} $assessedUtc).hash
       # Seeds a missing cooldown marker, so a first removal run is not refused for lack of one.
       $null=Sync-SmCooldownMarker $audit $assessedUtc $A.RemovalCooldownDays
      }
     } else { $r.Errors+=('Audit chain not verified: '+$audit.Chain.Code) }
     $r.Audit.headSeq=$audit.Seq
    } catch {
     # A decision that is not on the chain withholds every removal in this run (plan: AuditUnavailable).
     Close-SmAudit $audit; $audit=$null
     $r.Audit.error=([string]$_.Exception.Message).Substring(0,[math]::Min(160,([string]$_.Exception.Message).Length)); $r.Errors+=('Audit: '+$r.Audit.error)
    }
   }
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
      $cool=$null
      if($audit -and $audit.Chain.Valid) {
       try {
        $cool=Sync-SmCooldownMarker $audit $assessedUtc $A.RemovalCooldownDays
        # An intent with no outcome is a crash between the audit write and the removal: record
        # what is there now. The plan below still refuses this run (UnresolvedIntent).
        foreach($u in @($audit.Chain.Unresolved)) { $null=Add-SmAuditEntry $audit $runId 'reconciled' @{sid="$($u.sid)";pathHash="$($u.pathHash)";decision=$(if(@($profiles | Where-Object { $_.SID -eq $u.sid }).Count){'StillPresent'}else{'Absent'})} }
       } catch { $cool=$null; $r.Errors+=('Profile removal state: '+$_.Exception.Message) }
      }
      $plan=& $script:SmRemovalPlan $A $gateReport $audit $cool $assessedUtc $env:COMPUTERNAME
      $r.RemovalPlan=[ordered]@{Code=$plan.Code;Candidates=@($plan.Candidates).Count;Attempted=0;Removed=0;Cap=$script:SmProfileRemovalCap}
      $runLine=$null
      foreach($entry in @($plan.Candidates)) {
       $candidate=@($r.Profiles | Where-Object { $_.SID -eq "$($entry.sid)" -and $_.Path -eq "$($entry.path)" -and $_.Eligible }) | Select-Object -First 1
       if(-not $candidate) { continue }
       if($r.RemovalPlan.Attempted -ge $script:SmProfileRemovalCap) { $r.Omissions+=('Per-run profile removal cap of '+$script:SmProfileRemovalCap+' reached; remaining candidates wait for a later run.'); break }
       if($cleanupWatch.Elapsed.TotalSeconds -ge $A.MaxSeconds) { $r.Status='partial'; $r.Omissions+='Profile cleanup time budget exhausted.'; break }
       $remainingAtStepStart=$evidenceRemaining; $profileStepWatch=[Diagnostics.Stopwatch]::StartNew()
       $step=[ordered]@{Kind='profile';Path=$candidate.Path;Status='withheld';Error=$null}
       $auditFields=@{sid="$($candidate.SID)";pathHash=(Get-SmPathHash "$($candidate.Path)")}
       $phase='check'
       try {
        if(-not (& $script:SmGuards).Safe) { throw 'Servicing guard changed' }
        $fresh=@(& $script:SmProfiles | Where-Object { $_.SID -eq $candidate.SID })
        if(& $script:SmProfileHiveLoaded $candidate.SID) { throw 'Profile hive is loaded' }
        if($fresh.Count -ne 1 -or $fresh[0].LocalPath -ne $candidate.Path) { throw 'Profile revalidation failed: SID/path changed or ambiguous' }
        $evidenceRemaining=[math]::Min($evidenceRemaining,$remainingAtStepStart-$profileStepWatch.Elapsed.TotalSeconds)
        if($evidenceRemaining -le 0) { throw 'Aggregate profile evidence budget exhausted' }
        $recheckUtc=[datetime]::UtcNow
        $recollected=& $script:SmCollectProfiles $fresh $A.ProfileAgeDays $recheckUtc $evidenceRemaining $evidenceDirectory 'Report'
        $evidenceRemaining-=[double]$recollected.ElapsedSeconds
        if(-not $recollected.Complete -or $recollected.TimedOut -or $recollected.GuardChanged -or $evidenceRemaining -le 0) { throw 'Profile revalidation failed: evidence deadline or servicing transition' }
        $found=@($recollected.Entries | Where-Object { $_.SID -eq $candidate.SID -and $_.Path -eq $candidate.Path })
        if($found.Count -ne 1) { throw 'Profile revalidation failed: incomplete identity evidence' }
        $recheck=Test-SmProfile $fresh[0] $A.ProfileAgeDays $A.ExcludeProfiles $recheckUtc $found[0].Evidence
        $step['Revalidation']=$recheck
        if(-not $recheck.Eligible -or $recheck.AgeEvidenceFingerprint -ne $candidate.AgeEvidenceFingerprint) { throw ('Profile revalidation failed: '+$recheck.Reason) }
        # Still a StaleCandidate under every gate (shared, primary, admin, coverage, PST, KFM, user
        # folders), and the newest 4624 logon for the SID is the one the plan saw.
        $gate=& $script:SmRecheckGate $A $recheck $recollected.ReportContext $recheckUtc
        if("$($gate.decision)" -ne 'StaleCandidate') { throw ('Profile revalidation failed: gate matrix now '+$gate.decision) }
        if("$($gate.lastLogon4624Utc)" -ne "$($entry.lastLogon4624Utc)") { throw 'Profile revalidation failed: logon evidence changed' }
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
        # The run line and cooldown marker precede the first removal, the intent precedes each.
        $phase='audit'
        if(-not $runLine) { $runLine=Add-SmAuditEntry $audit $runId 'removalRun'; Write-SmAtomicFile (Join-Path $audit.Directory 'cooldown.json') ([ordered]@{v=1;lastRemovalRunUtc=$runLine.ts;lastRemovalRunHash=$runLine.hash} | ConvertTo-Json -Compress) }
        $null=Add-SmAuditEntry $audit $runId 'intent' ($auditFields+@{decision='StaleCandidate';bytes=$entry.totalBytes})
        $r.RemovalPlan.Attempted++
        $phase='removing'; & $script:SmRemoveProfile $fresh[0]; $step.Status='removedByCim'
        $phase='recording'; $null=Add-SmAuditEntry $audit $runId 'removed' ($auditFields+@{decision='Removed';bytes=$entry.totalBytes}); $r.RemovalPlan.Removed++
       } catch { $step.Error=$_.Exception.Message; $r.Status='partial' }
       $evidenceRemaining=[math]::Min($evidenceRemaining,$remainingAtStepStart-$profileStepWatch.Elapsed.TotalSeconds)
       $r.Actions+=[pscustomobject]$step
       # Fail closed: a removal error or any audit write failure stops every further removal.
       if($step.Error) {
        $stop=($phase -ne 'check')
        if($phase -in @('check','removing')) { try { $null=Add-SmAuditEntry $audit $runId $(if($phase -eq 'removing'){'failed'}else{'vetoed'}) ($auditFields+@{reason=$(if($phase -eq 'removing'){'RemoveError'}else{'RecheckVeto'})}) } catch { $stop=$true; $step.Error+='; audit write failed' } }
        if($stop) { $r.Omissions+='Profile removal stopped: a removal or its audit record failed.'; break }
       }
      }
     }
     if($A.Tier -ne 'None') {
      try { $r.Notifications+=& $script:SmUi ('Freeing disk space: '+$A.Tier+' cleanup of caches and old temporary files.') } catch { $r.Notifications+=('failed: '+$_.Exception.Message) }
      $tierSteps=@(Invoke-SmCleanupTier $A @($profiles | Where-Object { $_.LocalPath -match '^[A-Za-z]:\\Users\\[^\\]+$' -and $_.Special -eq $false } | ForEach-Object { $_.LocalPath }))
      $r.Actions+=$tierSteps
      if(@($tierSteps | Where-Object { $_.Status -ne 'done' }).Count) { $r.Status='partial' }
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
 finally { Close-SmAudit $audit; if($acquired) { & $script:SmRelease } }
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
  $a=Get-SmArguments -Mode $Mode -TempAgeDays $TempAgeDays -ProfileAgeDays $ProfileAgeDays -RemoveProfiles $RemoveProfiles -ExcludeProfiles $ExcludeProfiles -ComponentCleanup $ComponentCleanup -MaxFiles $MaxFiles -MaxSeconds $MaxSeconds -ProfileReport $ProfileReport -PrimaryUserHint $PrimaryUserHint -SharedDevices $SharedDevices -ReviewedReports $ReviewedReports -RemovalCooldownDays $RemovalCooldownDays -Tier $Tier -CleanupSeconds $CleanupSeconds
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
