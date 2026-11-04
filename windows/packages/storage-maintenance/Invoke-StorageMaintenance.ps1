<# .SYNOPSIS
Bounded storage evidence and explicitly requested conservative cleanup. No reboot.
Logical bytes are observations, not guaranteed reclaimable physical space.
#>
[CmdletBinding()]
param([string]$DeploymentType, [string]$Action, [string]$PinVersion,
 [string]$Mode='Report', [string]$TempAgeDays='7', [string]$ProfileAgeDays='60',
 [string]$RemoveProfiles='false', [string]$ExcludeProfiles='', [string]$ComponentCleanup='false',
 [string]$MaxFiles='20000', [string]$MaxSeconds='30')

$script:SmPackagePath=$PSCommandPath

function Get-SmArguments {
 param([string]$Mode='Report',[string]$TempAgeDays='7',[string]$ProfileAgeDays='60',
 [string]$RemoveProfiles='false',[string]$ExcludeProfiles='', [string]$ComponentCleanup='false',
 [string]$MaxFiles='20000',[string]$MaxSeconds='30')
 if ($Mode -cnotin @('Report','Cleanup')) { throw 'Mode must be Report or Cleanup' }
 $a=@{ Mode=$Mode; ExcludeProfiles=@($ExcludeProfiles.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
 foreach($b in @(@('RemoveProfiles',$RemoveProfiles),@('ComponentCleanup',$ComponentCleanup))) {
  if ($b[1] -cnotin @('true','false')) { throw "$($b[0]) must be true or false" }; $a[$b[0]]=$b[1] -ceq 'true'
 }
 foreach($n in @(@('TempAgeDays',$TempAgeDays,1,365),@('ProfileAgeDays',$ProfileAgeDays,30,3650),@('MaxFiles',$MaxFiles,1,2000000),@('MaxSeconds',$MaxSeconds,1,1800))) {
  if ($n[1] -notmatch '^\d{1,7}$' -or [int]$n[1] -lt $n[2] -or [int]$n[1] -gt $n[3]) { throw "Invalid $($n[0])" }; $a[$n[0]]=[int]$n[1]
 }; return $a
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
 $r=[ordered]@{Complete=$false;TimedOut=$false;GuardChanged=$false;Reasons=@();Error=$null;Entries=@();FinalVeto=$null;ElapsedSeconds=0.0}
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
$result=[ordered]@{Complete=$false;Error=$null;Entries=@();FinalVeto=$null}
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
  $r.Complete=$out.Complete; $r.Entries=@($out.Entries); $r.FinalVeto=$out.FinalVeto; $r.Error=$out.Error
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
 $r=[ordered]@{ SchemaVersion=1; Timestamp=[datetime]::UtcNow.ToString('o'); Mode=$A.Mode; Status='complete'; ReportPath=$null; Guards=$null; Before=@(); After=@(); FreeSpaceDelta=@(); Profiles=@(); Scan=$null; Actions=@(); Notifications=@(); Errors=@(); Omissions=@('User documents/downloads, rollback/recovery, installer cache and Windows components are never deleted.','Logical sizes exclude unreadable/reparse/cloud entries; hardlinks, compression and sparse files make reclaimable bytes uncertain.','App caches are reported as opportunities only; no application cache reset.','Directory ranking counts direct files, not recursively accumulated subtree sizes; categories may overlap.','Upgrade staging/Windows.old are preserved. Historical staging needs independent Source OS, install and boot completion evidence; unestablished status stays light/withheld.'); Evidence=$null }
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
   $collected=& $script:SmCollectProfiles $profiles $A.ProfileAgeDays $assessedUtc $evidenceRemaining $evidenceDirectory 'Full'
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
   if($A.Mode -eq 'Cleanup') {
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
 return [pscustomobject]$r
}

if($env:RELIAN_DEPLOY_TEST -ne '1') {
 $ErrorActionPreference='Stop'
 if($Action -eq 'Uninstall' -or $DeploymentType -eq 'Uninstall') { Write-Output '{"Status":"notApplicable","Reason":"Maintenance has no uninstall action"}'; exit 0 }
 try {
  $a=Get-SmArguments -Mode $Mode -TempAgeDays $TempAgeDays -ProfileAgeDays $ProfileAgeDays -RemoveProfiles $RemoveProfiles -ExcludeProfiles $ExcludeProfiles -ComponentCleanup $ComponentCleanup -MaxFiles $MaxFiles -MaxSeconds $MaxSeconds
  $r=Invoke-SmMaintenance $a
  if($script:SmUiOpen) { try { Close-ADTInstallationProgress } catch { $r.Notifications+=('close failed: '+$_.Exception.Message) } }
  Write-Host "Storage maintenance: $($r.Status); mode $($r.Mode); actions $($r.Actions.Count). Free-space delta includes concurrent system activity."
  $reportPath=$r.ReportPath
  try {
   if(-not $reportPath) { throw 'Report destination unavailable' }
   $reportDir=Split-Path -Parent $reportPath
   if(-not (Test-SmSafePath $reportPath $reportDir)) { throw 'Report path changed or became unsafe' }
   $r | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8 -ErrorAction Stop
  } catch { $r.Errors+=('Report file write failed: '+$_.Exception.Message); $r.Status='failed' }
  ConvertTo-SmSummary $r $reportPath
  if($r.Status -eq 'failed') { exit 1 }; exit 0
 } catch { Write-Error $_; exit 1 }
}
