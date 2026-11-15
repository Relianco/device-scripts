$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
$package = Join-Path $PSScriptRoot '../../windows/packages/storage-maintenance/Invoke-StorageMaintenance.ps1'
. $package
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Throws($Code, $Pattern) { $m = $null; try { & $Code } catch { $m = $_.Exception.Message }; Assert ($m -and $m -match $Pattern) "expected throw matching '$Pattern', got '$m'" }

# Device names, SIDs' profile folders and paths are generated per run; no identifier is committed.
# The removal hook is always a recorder: nothing real is ever removed.
$rand = { 'T' + [guid]::NewGuid().ToString('n').Substring(0, 10).ToUpperInvariant() }
$sharedPc = & $rand; $otherPc = & $rand
$work = Join-Path ([IO.Path]::GetTempPath()) ('profile-removal-' + [guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory -Path $work

# --- Arguments: removal stays off by default; ReviewedReports is exactly two distinct hashes.
$h1 = 'a' * 64; $h2 = 'b' * 64
$a = Get-SmArguments
Assert (-not $a.RemoveProfiles -and $a.Mode -eq 'Report' -and $a.ReviewedReports.Count -eq 0 -and $a.RemovalCooldownDays -eq 1) 'Removal off by default, no reviewed reports, 1-day cooldown'
$a = Get-SmArguments -ReviewedReports (" $($h1.ToUpperInvariant()) , $h2 ")
Assert ($a.ReviewedReports.Count -eq 2 -and $a.ReviewedReports[0] -ceq $h1) 'Reviewed report hashes parsed and lower-cased'
foreach ($bad in @($h1, "$h1,$h2,$('c' * 64)", "$h1,$h1", "$h1,xyz", ('g' * 64) + ",$h2")) { Throws { Get-SmArguments -ReviewedReports $bad } 'ReviewedReports' }
Throws { Get-SmArguments -RemovalCooldownDays 0 } 'RemovalCooldownDays'
Throws { Get-SmArguments -ProfileReport true -Mode Cleanup -RemoveProfiles true -ReviewedReports "$h1,$h2" } 'report-only'

# --- Audit lines: canonical, free text refused, no names.
$t0 = [datetime]::SpecifyKind([datetime]'2026-11-20T00:00:00', 'Utc')
$e = New-SmAuditEntry 1 $script:SmAuditGenesis ('r' * 32) 'decision' $t0 @{sid='S-1-5-21-1-2-3-1001';pathHash='0123456789abcdef';decision='StaleCandidate';reason='StaleCandidate';bytes=5}
Assert ($e.hash -match '^[0-9a-f]{64}$' -and $e.ts -eq '20261120T000000Z' -and $e.bytes -is [int64]) 'Entry hashed, compact UTC time'
Throws { New-SmAuditEntry 1 $script:SmAuditGenesis 'r' 'decision' $t0 @{sid='CORP\jdoe'} } 'SID malformed'
Throws { New-SmAuditEntry 1 $script:SmAuditGenesis 'r' 'decision' $t0 @{reason='John Doe left'} } 'canonical alphabet'
Throws { New-SmAuditEntry 1 $script:SmAuditGenesis 'r' 'decision' $t0 @{account='jdoe'} } 'not allowed'
Throws { New-SmAuditEntry 1 $script:SmAuditGenesis 'r' 'erase' $t0 @{} } 'Unknown audit kind'
Assert ((Get-SmPathHash 'C:\Users\Someone\') -eq (Get-SmPathHash 'c:\users\someone')) 'Path hash ignores case and a trailing slash'

# Only the removal loop in Invoke-SmMaintenance reaches the removal hook; the gates and the audit cannot.
foreach ($fn in @('Get-SmRemovalPlan','Get-SmReviewedCandidates','Get-SmCooldownState','Sync-SmCooldownMarker','Test-SmAuditChain','Open-SmAudit','Add-SmAuditEntry','New-SmAuditEntry','Write-SmAtomicFile','Get-SmReportDecision')) {
 Assert ((Get-Command $fn).ScriptBlock.Ast.Extent.Text -notmatch 'SmRemoveProfile|Remove-CimInstance|Remove-Item|SmDelete|SmComponent') "$fn references a removal hook"
}

# --- Exhaustive removal-plan matrix: exactly one combination of all gates passing may remove.
function Seed-Reports($Dir, $Profiles, [datetime]$Now, [int[]]$DaysAgo = @(30, 10), $SecondProfiles = $Profiles) {
 $au = Open-SmAudit $Dir; $hashes = @()
 try {
  $i = 0
  foreach ($ago in $DaysAgo) {
   $run = [guid]::NewGuid().ToString('n'); $when = $Now.AddDays(-$ago); $set = if ($i -eq 0) { $Profiles } else { $SecondProfiles }
   foreach ($p in $set) { $null = Add-SmAuditEntry $au $run 'decision' @{sid=$p.SID;pathHash=(Get-SmPathHash $p.LocalPath);decision='StaleCandidate';reason='StaleCandidate';bytes=100} $when }
   $hashes += (Add-SmAuditEntry $au $run 'report' @{decision='ProfileReport';reason='candidates1'} $when).hash; $i++
  }
 } finally { Close-SmAudit $au }
 $hashes
}
$mx = Join-Path $work 'matrix'; $null = New-Item -ItemType Directory -Path $mx
$mp = [pscustomobject]@{SID='S-1-5-21-7-7-7-1201';LocalPath=($work + '\' + (& $rand))}
$mh = Seed-Reports $mx @($mp) $t0
$mchain = Test-SmAuditChain $mx
Assert ($mchain.Valid -and $mchain.Entries.Count -eq 4) "Seeded chain verifies: $($mchain.Code)"
$coolOk = [pscustomobject]@{Allowed=$true;Code='CooldownClear'}; $coolNo = [pscustomobject]@{Allowed=$false;Code='CooldownActive'}
$hits = 0
for ($mask = 0; $mask -lt 256; $mask++) {
 $g = @(0..7 | ForEach-Object { [bool]($mask -band (1 -shl $_)) })
 $args8 = Get-SmArguments -Mode $(if ($g[0]) { 'Cleanup' } else { 'Report' }) -RemoveProfiles true -SharedDevices $sharedPc -ReviewedReports $(if ($g[4]) { $mh -join ',' } else { "$($mh[0]),$h1" })
 $chain = [pscustomobject]@{Valid=$g[2];Code=$(if ($g[2]) { 'AuditChainVerified' } else { 'AuditEntryEdited' });Entries=$mchain.Entries;Unresolved=$(if ($g[3]) { @() } else { @($mchain.Entries[0]) })}
 $report = [pscustomobject]@{Profiles=@([pscustomobject]@{sid=$mp.SID;path=$(if ($g[7]) { $mp.LocalPath } else { $mp.LocalPath + 'x' });decision=$(if ($g[6]) { 'StaleCandidate' } else { 'ReviewPst' });totalBytes=1})}
 $plan = Get-SmRemovalPlan $args8 $report ([pscustomobject]@{Chain=$chain}) $(if ($g[5]) { $coolOk } else { $coolNo }) $t0 $(if ($g[1]) { $sharedPc.ToLowerInvariant() } else { $otherPc })
 if ($plan.Allowed) { $hits++; Assert ($mask -eq 255 -and $plan.Candidates.Count -eq 1 -and $plan.Code -eq 'Ready') "Removal allowed with a failing gate: mask $mask" }
 elseif ($mask -eq 255) { throw "All gates pass but removal refused: $($plan.Code)" }
}
Assert ($hits -eq 1) "Exactly one combination removes, got $hits"
# The plan refuses ProfileReport and a missing audit or cooldown, whatever else is set.
$a = Get-SmArguments -Mode Cleanup -RemoveProfiles true -SharedDevices $sharedPc -ReviewedReports ($mh -join ','); $a.ProfileReport = $true
$okReport = [pscustomobject]@{Profiles=@([pscustomobject]@{sid=$mp.SID;path=$mp.LocalPath;decision='StaleCandidate'})}
Assert ((Get-SmRemovalPlan $a $okReport ([pscustomobject]@{Chain=$mchain}) $coolOk $t0 $sharedPc).Code -eq 'RemoveProfilesOff') 'A hand-built ProfileReport argument set never plans a removal'
$a.ProfileReport = $false
Assert ((Get-SmRemovalPlan $a $okReport $null $coolOk $t0 $sharedPc).Code -eq 'AuditUnavailable') 'No audit, no removal'
Assert ((Get-SmRemovalPlan $a $okReport ([pscustomobject]@{Chain=$mchain}) $null $t0 $sharedPc).Code -eq 'CooldownUnknown') 'No cooldown state, no removal'

# --- Reviewed reports: both runs, the same path, far enough apart, in the past, really reports.
$rv = Join-Path $work 'reviewed'; $null = New-Item -ItemType Directory -Path $rv
$pA = [pscustomobject]@{SID='S-1-5-21-7-7-7-1301';LocalPath=($work + '\' + (& $rand))}; $pB = [pscustomobject]@{SID='S-1-5-21-7-7-7-1302';LocalPath=($work + '\' + (& $rand))}
$rh = Seed-Reports $rv @($pA, $pB) $t0 @(30, 10) @($pA)
$rc = Test-SmAuditChain $rv
$keys = (Get-SmReviewedCandidates $rc $rh $t0).Keys
Assert ($keys.Count -eq 1 -and $keys[0] -eq ($pA.SID + '|' + (Get-SmPathHash $pA.LocalPath))) 'Only a profile that is a candidate in BOTH reviewed reports is approved'
$decisionHash = ($rc.Entries | Where-Object { $_.kind -eq 'decision' } | Select-Object -First 1).hash
foreach ($c in @(
 @(@($rh[0]), 'ReviewedReportsMissing'),
 @(@($rh[0], $h1), 'ReviewedReportNotInChain'),
 @(@($rh[0], $decisionHash), 'ReviewedReportNotInChain'))) {
 Assert ((Get-SmReviewedCandidates $rc $c[0] $t0).Code -eq $c[1]) "Reviewed reports: expected $($c[1])"
}
$close = Join-Path $work 'close'; $null = New-Item -ItemType Directory -Path $close
$closeHashes = Seed-Reports $close @($pA) $t0 @(10, 5)
Assert ((Get-SmReviewedCandidates (Test-SmAuditChain $close) $closeHashes $t0).Code -eq 'ReviewedReportsTooClose') 'Two reports less than 7 days apart are one review cycle'
Assert ((Get-SmReviewedCandidates $rc $rh $t0.AddDays(-20)).Code -eq 'ClockSkew') 'A reviewed report dated after the device clock is clock skew'

# --- Hash chain: edit, deletion, insertion, reordering, truncation, torn line, head, archives.
$ch = Join-Path $work 'chain'; $null = New-Item -ItemType Directory -Path $ch
$au = Open-SmAudit $ch
Assert ($au.Chain.Valid -and $au.Seq -eq 0) 'An empty directory is a valid empty chain'
1..6 | ForEach-Object { $null = Add-SmAuditEntry $au ('c' * 32) 'decision' @{sid="S-1-5-21-1-2-3-$_";pathHash='00000000000000ff';decision='ReviewPst';reason='StaleCandidate';bytes=$_} $t0 }
Close-SmAudit $au
$file = Join-Path $ch 'audit.jsonl'; $head = Join-Path $ch 'audit.head'
$good = [IO.File]::ReadAllText($file); $goodHead = [IO.File]::ReadAllText($head)
Assert ((Test-SmAuditChain $ch).Valid) 'Untouched chain verifies'
Assert ($good -notmatch [regex]::Escape($work) -and $good -notmatch 'Users') 'Lines hold a path hash, never a path or a name'
function Tamper([scriptblock]$Edit, [string[]]$Codes, [string]$Why) {
 $lines = [Collections.Generic.List[string]]@($good.TrimEnd("`n").Split("`n")); $script:headText = $goodHead
 $text = & $Edit $lines
 [IO.File]::WriteAllText($file, $text); [IO.File]::WriteAllText($head, $script:headText)
 $v = Test-SmAuditChain $ch
 Assert (-not $v.Valid -and $v.Code -in $Codes) "$Why not detected: valid=$($v.Valid) code=$($v.Code)"
}
$rehash = { param($Line, $Change) $o = $Line | ConvertFrom-Json; foreach ($k in $Change.Keys) { $o.$k = $Change[$k] }; $o.hash = Get-SmSha256 (Get-SmAuditCanonical $o); $o | ConvertTo-Json -Compress }
Tamper { param($l) $l[2] = $l[2].Replace('"ReviewPst"', '"StaleCandidate"'); ($l -join "`n") + "`n" } @('AuditEntryEdited') 'An edited field'
Tamper { param($l) $l[2] = & $rehash $l[2] @{decision='StaleCandidate'}; ($l -join "`n") + "`n" } @('AuditChainBroken') 'An edited and re-hashed line'
Tamper { param($l) $l.RemoveAt(3); ($l -join "`n") + "`n" } @('AuditChainBroken','AuditSequenceBroken') 'A deleted line'
Tamper { param($l) $x = $l[1]; $l[1] = $l[2]; $l[2] = $x; ($l -join "`n") + "`n" } @('AuditChainBroken','AuditSequenceBroken') 'Reordered lines'
Tamper { param($l) $l.Insert(2, $l[2]); ($l -join "`n") + "`n" } @('AuditChainBroken','AuditSequenceBroken') 'A duplicated line'
Tamper { param($l) $l.RemoveAt($l.Count - 1); ($l -join "`n") + "`n" } @('AuditTruncated') 'A cut tail'
Tamper { param($l) $l.RemoveAt($l.Count - 1); $l.RemoveAt($l.Count - 1); ($l -join "`n") + "`n" } @('AuditTruncated') 'A cut tail of two lines'
Tamper { param($l) ($l -join "`n") + "`n" + $l[0].Substring(0, 40) } @('AuditTornLine') 'A torn last line'
Tamper { param($l) $o = $l[1] | ConvertFrom-Json; $o | Add-Member -NotePropertyName account -NotePropertyValue 'CORP\jdoe'; $l[1] = $o | ConvertTo-Json -Compress; ($l -join "`n") + "`n" } @('AuditLineMalformed') 'A smuggled name field'
Tamper { param($l) $script:headText = '{"seq":2,"hash":"' + ($l[1] | ConvertFrom-Json).hash + '"}'; ($l -join "`n") + "`n" } @('AuditHeadMismatch') 'A head pointing at an old line'
Tamper { param($l) $script:headText = '{broken'; ($l -join "`n") + "`n" } @('AuditHeadMalformed') 'A malformed head'
[IO.File]::WriteAllText($file, $good); Remove-Item -LiteralPath $head
Assert ((Test-SmAuditChain $ch).Code -eq 'AuditHeadMissing') 'A deleted head is refused'
# Crash window: the line landed, the head did not. One line behind is accepted, two is not.
$lines = $good.TrimEnd("`n").Split("`n")
[IO.File]::WriteAllText($head, '{"seq":5,"hash":"' + ($lines[4] | ConvertFrom-Json).hash + '"}')
$v = Test-SmAuditChain $ch
Assert ($v.Valid -and $v.HeadLag) 'A head one line behind (crash before the head update) still verifies'
[IO.File]::WriteAllText($head, $goodHead)
# Rotation keeps one chain across files; a missing or renamed archive is refused.
$rot = Join-Path $work 'rotate'; $null = New-Item -ItemType Directory -Path $rot
$script:SmAuditMaxBytes = 1200
$au = Open-SmAudit $rot
1..12 | ForEach-Object { $null = Add-SmAuditEntry $au ('d' * 32) 'decision' @{sid="S-1-5-21-1-2-3-$_";decision='ReviewPst'} $t0 }
Close-SmAudit $au
$archives = @(Get-ChildItem -LiteralPath $rot -Filter 'audit-*.jsonl' | Sort-Object Name)
$v = Test-SmAuditChain $rot
Assert ($archives.Count -ge 2 -and $v.Valid -and $v.LastSeq -eq 12 -and $v.Files -eq $archives.Count + 1) "Rotated chain verifies across $($archives.Count) archives: $($v.Code)"
$au = Open-SmAudit $rot; $null = Add-SmAuditEntry $au ('e' * 32) 'decision' @{decision='ReviewPst'} $t0; Close-SmAudit $au
Assert ((Test-SmAuditChain $rot).LastSeq -eq 13) 'The chain continues after a rotation'
$moved = Join-Path $work 'moved.jsonl'
Move-Item -LiteralPath $archives[0].FullName -Destination $moved
Assert ((Test-SmAuditChain $rot).Code -in @('AuditChainBroken','AuditSequenceBroken')) 'A deleted oldest archive is refused'
Move-Item -LiteralPath $moved -Destination $archives[0].FullName
Move-Item -LiteralPath $archives[1].FullName -Destination (Join-Path $rot 'audit-0000000099.jsonl')
Assert (-not (Test-SmAuditChain $rot).Valid) 'A renamed archive is refused'
Move-Item -LiteralPath (Join-Path $rot 'audit-0000000099.jsonl') -Destination $archives[1].FullName
$script:SmAuditMaxFiles = (Test-SmAuditChain $rot).Files
$au = Open-SmAudit $rot
Throws { 1..20 | ForEach-Object { $null = Add-SmAuditEntry $au ('e' * 32) 'decision' @{decision='ReviewPst'} $t0 } } 'file limit'
Close-SmAudit $au
Assert ((Test-SmAuditChain $rot).Valid) 'Reaching the file limit refuses the write and leaves the chain whole'
$script:SmAuditMaxBytes = 1048576; $script:SmAuditMaxFiles = 100
# One run at a time: the lock file is held from verification to the last append.
$au = Open-SmAudit $ch
Throws { Open-SmAudit $ch } 'held by another run'
Close-SmAudit $au
$au = Open-SmAudit $ch; Close-SmAudit $au
# Atomic replace: a reader never sees a partial file, and an abandoned temp file is ignored.
$m = Join-Path $work 'marker.json'
Write-SmAtomicFile $m 'one'; Write-SmAtomicFile $m 'two'
[IO.File]::WriteAllText($m + '.deadbeef.tmp', 'partial')
Assert ([IO.File]::ReadAllText($m) -eq 'two') 'Atomic write replaced the marker'

# --- Cooldown marker: missing, malformed or disagreeing fails safe; clock skew; window.
$cd = Join-Path $work 'cool'; $null = New-Item -ItemType Directory -Path $cd
$au = Open-SmAudit $cd; $runLine = Add-SmAuditEntry $au ('f' * 32) 'removalRun' @{} $t0; Close-SmAudit $au
$cc = Test-SmAuditChain $cd
$okMarker = [ordered]@{v=1;lastRemovalRunUtc=$runLine.ts;lastRemovalRunHash=$runLine.hash} | ConvertTo-Json -Compress
foreach ($c in @(
 @($null, $t0.AddDays(30), 'CooldownMarkerMissing', $true),
 @('{not json', $t0.AddDays(30), 'CooldownMarkerMalformed', $true),
 @('{"v":1,"lastRemovalRunUtc":null,"lastRemovalRunHash":null}', $t0.AddDays(30), 'CooldownMarkerMismatch', $true),
 @($okMarker, $t0.AddHours(12), 'CooldownActive', $false),
 @($okMarker, $t0.AddDays(-1), 'ClockSkew', $false),
 @($okMarker, $t0.AddDays(1), 'CooldownClear', $false))) {
 $s = Get-SmCooldownState $c[0] $cc $c[1] 1
 Assert ($s.Code -eq $c[2] -and $s.Rewrite -eq $c[3] -and $s.Allowed -eq ($c[2] -eq 'CooldownClear')) "Cooldown: expected $($c[2]), got $($s.Code)"
}
Assert ((Get-SmCooldownState $okMarker $cc $t0.AddDays(6) 7).Code -eq 'CooldownActive') 'RemovalCooldownDays widens the window'
$seed = (Get-SmCooldownState $null $cc $t0.AddDays(30) 1).Seed | ConvertTo-Json -Compress
Assert ((Get-SmCooldownState $seed $cc $t0.AddDays(30) 1).Allowed) 'The rewritten marker is accepted on the next run'

# --- End to end through Invoke-SmMaintenance. Every OS boundary is mocked; the removal hook records.
$suite = {
 $now = [datetime]::UtcNow
 function New-AgePair($Date) { $ft = [uint64]$Date.ToFileTimeUtc(); @{ Low=[uint32]($ft -band [uint64]4294967295); High=[uint32]($ft -shr 32) } }
 $u = New-AgePair ($now.AddDays(-300)); $l = New-AgePair ($now.AddDays(-301))
 $script:Evidence = [pscustomobject]@{Registry=[pscustomobject]@{ReadState='ok';IdentityMatches=$true;Load=(ConvertFrom-SmFileTimePair $l.Low $l.High);Unload=(ConvertFrom-SmFileTimePair $u.Low $u.High);Cleanup=(ConvertFrom-SmFileTimePair $null $null)};Identity=[pscustomobject]@{Resolved=$true;Account='CORP\leaver'};Sessions=[pscustomobject]@{Known=$true;Sids=@();CurrentSid='S-1-5-18'};Hives=[pscustomobject]@{Known=$true;Loaded=$false;ClassesLoaded=$false};NtUser=[pscustomobject]@{DatUtc=$null;ManUtc=$null;Errors=@()};Events=[pscustomobject]@{ProbeComplete=$true;Recent=@();Truncated=$false};Errors=@()}
 $script:SmGuards = { [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }; $script:SmScanGuard = $script:SmGuards
 $script:SmPrepareReport = { 'report.json' }; $script:SmAcquire = { $true }; $script:SmRelease = {}; $script:SmVolumes = { @() }; $script:SmEvidence = { @{} }
 $script:SmRoots = { @() }; $script:SmDiagnosticRoots = { @() }; $script:SmUi = { param($Step) 'noUser' }; $script:SmProfileHiveLoaded = { $false }
 $script:SmProfiles = { @($script:Profiles) }
 $script:SmCollectProfiles = { param($Profiles, $Days, $Now, $Seconds, $Directory, $Mode)
  $script:collects++
  $ctx = [pscustomobject]@{Log=[pscustomobject]@{Known=$true;OldestUtc=$Now.AddDays(-400);NewestUtc=$Now};Admins=[pscustomobject]@{Known=$true;Sids=@()};IntuneUpns=@();LapsNames=@();Upns=@{};LogonCounts=@{'S-1-5-21-9-9-9-1101'=5};LogonsComplete=$true;Errors=@()}
  $entries = @($Profiles | ForEach-Object { $ev = $script:Evidence
   if ($script:collects -gt 1 -and $script:oldLogonOnRecheck) { $ev = $script:Evidence.PSObject.Copy(); $ev.Events = [pscustomobject]@{ProbeComplete=$true;Truncated=$false;Recent=@([pscustomobject]@{Sid=$_.SID;LogonType=2;TimeUtc=$Now.AddDays(-200)})} }
   [pscustomobject]@{SID=$_.SID;Path=$_.LocalPath;Evidence=$ev} })
  [pscustomobject]@{Complete=$true;TimedOut=$false;GuardChanged=$false;Reasons=@();Entries=$entries;FinalVeto=[pscustomobject]@{Clear=$script:finalClear};ReportContext=$(if ($Mode -eq 'Report') { $ctx });ElapsedSeconds=0.01;Error=$null}
 }
 $script:SmRemoveProfile = { param($Profile)
  $tail = @((Test-SmAuditChain $script:auditDir).Entries)[-1]
  $script:intentFirst += [bool]($tail.kind -eq 'intent' -and $tail.sid -eq $Profile.SID)
  $script:attempts += $Profile.SID
  if ($script:failOn -contains $Profile.SID) { throw 'Remove-CimInstance: the profile is in use' }
  $script:removed += $Profile.SID
 }
 function Test-SmProfilePath($Path) { "$Path".StartsWith($script:base) }
 function Test-SmSafePath { if ($script:realSafePath) { & $script:realSafePathFn @args } else { $true } }
 function Get-SmKfmState { [pscustomobject]@{state=$(if ($script:kfmFailOnRecheck -and $script:collects -gt 1) { 'unknown' } else { 'verified' });redirected=3;accounts=1;localOneDriveFiles=0;outsideKfmFiles=0;error=$null} }
 $script:SmAuditDirectory = { $script:auditDir }
 function New-Fixture([int]$Count = 1) {
  $script:base = Join-Path $work ([guid]::NewGuid().ToString('n')); $null = New-Item -ItemType Directory -Path $script:base
  $script:auditDir = Join-Path $script:base 'audit'; $null = New-Item -ItemType Directory -Path $script:auditDir
  $script:Profiles = @(1..$Count | ForEach-Object { $p = [pscustomobject]@{SID="S-1-5-21-9-9-9-$(2000 + $_)";LocalPath=(Join-Path $script:base (& $rand));Loaded=$false;Special=$false;LastUseTime=$now.AddDays(-300);Status=0;RoamingConfigured=$false;RoamingPreference=$false;refCount=0}; $null = New-Item -ItemType Directory -Path $p.LocalPath; $p })
  $script:removed = @(); $script:attempts = @(); $script:intentFirst = @(); $script:failOn = @(); $script:finalClear = $true; $script:collects = 0
  $script:oldLogonOnRecheck = $false; $script:kfmFailOnRecheck = $false; $script:realSafePath = $false
  $env:COMPUTERNAME = $sharedPc
 }
 # One reviewed report from 30 days ago on the chain, then a real report run today: its hash is the second.
 function Approve {
  $old = Seed-Reports $script:auditDir $script:Profiles $now @(30)
  $script:collects = 0; $rep = Invoke-SmMaintenance (Get-SmArguments -ProfileReport true -SharedDevices $sharedPc -ProfileAgeDays 90)
  Assert ($rep.Audit.reportHash -and @($script:attempts).Count -eq 0 -and $rep.ProfileReport.Summary.candidates -eq @($script:Profiles).Count) "A report run approves nothing by itself and seals its candidates: $($rep.Audit | ConvertTo-Json -Compress)"
  @($old) + @($rep.Audit.reportHash)
 }
 function Remove-Run($Hashes) { $script:collects = 0; Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup -RemoveProfiles true -SharedDevices $sharedPc -ProfileAgeDays 90 -ReviewedReports ($Hashes -join ',')) }
 function Kinds { @((Test-SmAuditChain $script:auditDir).Entries | ForEach-Object { $_.kind }) -join ',' }

 # The one path that removes: shared, two reviewed reports, cooldown clear, fresh StaleCandidate.
 New-Fixture 1; $hs = Approve
 $r = Remove-Run $hs
 Assert (@($script:removed).Count -eq 1 -and $r.RemovalPlan.Removed -eq 1 -and $r.RemovalPlan.Code -eq 'Ready') "All gates pass: one removal, got $($r.RemovalPlan | ConvertTo-Json -Compress) $($r.Errors -join ';') $(@($r.Actions | ForEach-Object Error) -join ';')"
 Assert ((Kinds) -match 'decision,removalRun,intent,removed$' -and $script:intentFirst -notcontains $false) "Decision, run, intent are on the chain before the removal and its outcome after: $(Kinds)"
 $chain = Test-SmAuditChain $script:auditDir
 $marker = [IO.File]::ReadAllText((Join-Path $script:auditDir 'cooldown.json')) | ConvertFrom-Json
 Assert ($chain.Valid -and $marker.lastRemovalRunHash -eq @($chain.Entries | Where-Object kind -eq 'removalRun')[-1].hash) 'Chain valid and cooldown marker names the removal run'
 # Cooldown: a second removal run the same day removes nothing.
 $script:removed = @(); $r = Remove-Run $hs
 Assert (@($script:removed).Count -eq 0 -and $r.RemovalPlan.Code -eq 'CooldownActive') "Second run inside the cooldown: $($r.RemovalPlan.Code)"
 # A deleted marker fails safe for that run and is rewritten from the chain.
 Remove-Item -LiteralPath (Join-Path $script:auditDir 'cooldown.json')
 $r = Remove-Run $hs
 Assert (@($script:removed).Count -eq 0 -and $r.RemovalPlan.Code -eq 'CooldownMarkerMissing' -and (Test-Path -LiteralPath (Join-Path $script:auditDir 'cooldown.json'))) 'Missing marker: no removal, marker reseeded'

 # Gates that refuse the whole run.
 New-Fixture 1; $hs = Approve
 $env:COMPUTERNAME = $otherPc; $r = Remove-Run $hs
 Assert (@($script:attempts).Count -eq 0 -and $r.RemovalPlan.Code -eq 'NotSharedDevice') 'A device not on SharedDevices removes nothing'
 $env:COMPUTERNAME = $sharedPc
 $r = Remove-Run @()
 Assert (@($script:attempts).Count -eq 0 -and $r.RemovalPlan.Code -eq 'ReviewedReportsMissing') 'No reviewed reports, no removal'
 $r = Remove-Run @($hs[1], $h1)
 Assert (@($script:attempts).Count -eq 0 -and $r.RemovalPlan.Code -eq 'ReviewedReportNotInChain') 'An unknown report hash, no removal'
 $txt = [IO.File]::ReadAllText((Join-Path $script:auditDir 'audit.jsonl')); [IO.File]::WriteAllText((Join-Path $script:auditDir 'audit.jsonl'), $txt.Replace('"ReviewPst"', '"StaleCandidate"').Replace('candidates1', 'candidates2'))
 $r = Remove-Run $hs
 Assert (@($script:attempts).Count -eq 0 -and $r.RemovalPlan.Code -eq 'AuditEntryEdited') "A tampered chain, no removal: $($r.RemovalPlan.Code)"

 # Per-run cap: seven approved candidates, five removed, the rest wait.
 New-Fixture 7; $hs = Approve
 $r = Remove-Run $hs
 Assert (@($script:removed).Count -eq 5 -and $r.RemovalPlan.Attempted -eq 5 -and @($r.Omissions | Where-Object { $_ -match 'cap of 5' }).Count -eq 1) "Cap of five per run, removed $(@($script:removed).Count)"

 # A removal failure is recorded and stops every further removal.
 New-Fixture 3; $hs = Approve
 $script:failOn = @($script:Profiles[1].SID)
 $r = Remove-Run $hs
 Assert (@($script:attempts).Count -eq 2 -and @($script:removed).Count -eq 1 -and (Kinds) -match 'intent,failed$' -and @($r.Omissions | Where-Object { $_ -match 'stopped' }).Count -eq 1) "Failure stops the run: attempts $(@($script:attempts).Count), $(Kinds)"

 # Recheck right before removal: gate matrix and logon evidence evaluated again; a veto skips only that profile.
 New-Fixture 1; $hs = Approve
 $script:kfmFailOnRecheck = $true; $r = Remove-Run $hs
 Assert (@($script:attempts).Count -eq 0 -and $r.Actions[-1].Error -match 'gate matrix now ReviewKfmUnknown' -and (Kinds) -match 'vetoed$') "Fresh gate matrix vetoes: $($r.Actions[-1].Error)"
 New-Fixture 1; $hs = Approve
 $script:oldLogonOnRecheck = $true; $r = Remove-Run $hs
 Assert (@($script:attempts).Count -eq 0 -and $r.Actions[-1].Error -match 'logon evidence changed') "A new 4624 between plan and removal vetoes: $($r.Actions[-1].Error)"
 New-Fixture 2; $hs = Approve
 $script:finalClear = $false; $r = Remove-Run $hs
 Assert (@($script:attempts).Count -eq 0 -and @($r.Actions | Where-Object { $_.Error -match 'final session' }).Count -eq 2) 'A user logging on before removal vetoes; the next candidate is still checked'

 # Crash between the intent line and the removal: the next run records what it finds and removes nothing.
 New-Fixture 1; $hs = Approve
 $au = Open-SmAudit $script:auditDir; $null = Add-SmAuditEntry $au ('9' * 32) 'intent' @{sid=$script:Profiles[0].SID;pathHash=(Get-SmPathHash $script:Profiles[0].LocalPath);decision='StaleCandidate'}; Close-SmAudit $au
 $r = Remove-Run $hs
 Assert (@($script:attempts).Count -eq 0 -and $r.RemovalPlan.Code -eq 'UnresolvedIntent' -and (Test-SmAuditChain $script:auditDir).Entries[-1].decision -eq 'StillPresent') "Unresolved intent: $($r.RemovalPlan.Code)"
 $r = Remove-Run $hs
 Assert (@($script:removed).Count -eq 1) 'After reconciliation the next run proceeds'

 # SID/path confusion: the approved SID now owns another folder, or another SID owns the approved one.
 New-Fixture 2; $hs = Approve
 $p0 = $script:Profiles[0].LocalPath; $script:Profiles[0].LocalPath = $script:Profiles[1].LocalPath; $script:Profiles[1].LocalPath = $p0
 $r = Remove-Run $hs
 Assert (@($script:attempts).Count -eq 0 -and $r.RemovalPlan.Code -eq 'NoApprovedCandidate') "Swapped SID/path pairs are not approved: $($r.RemovalPlan.Code)"

 # Clock skew: a chain line dated in the future blocks removal.
 New-Fixture 1; $hs = Approve
 $au = Open-SmAudit $script:auditDir; $null = Add-SmAuditEntry $au ('8' * 32) 'decision' @{decision='ReviewPst'} $now.AddDays(2); Close-SmAudit $au
 $r = Remove-Run $hs
 Assert (@($script:attempts).Count -eq 0 -and $r.RemovalPlan.Code -eq 'ClockSkew') "Clock behind the chain: $($r.RemovalPlan.Code)"

 # The audit log at its size limit rotates during a removal run; the chain stays whole.
 New-Fixture 1; $hs = Approve
 $script:SmAuditMaxBytes = 1500
 try { $r = Remove-Run $hs } finally { $script:SmAuditMaxBytes = 1048576 }
 $v = Test-SmAuditChain $script:auditDir
 Assert (@($script:removed).Count -eq 1 -and $v.Valid -and $v.Files -gt 1) "Rotation mid-run keeps the chain: files $($v.Files), $($v.Code)"

 # A profile folder that is a link is never followed: no candidate, no removal.
 New-Fixture 1
 $target = Join-Path $script:base 'elsewhere'; $null = New-Item -ItemType Directory -Path $target
 Remove-Item -LiteralPath $script:Profiles[0].LocalPath; $null = New-Item -ItemType SymbolicLink -Path $script:Profiles[0].LocalPath -Target $target
 $hs = Seed-Reports $script:auditDir $script:Profiles $now @(30, 10)
 $script:realSafePath = $true; $r = Remove-Run $hs
 Assert (@($script:attempts).Count -eq 0) 'A linked profile folder is never removed'

 # Report-only stays unable to delete, even with every removal gate satisfied.
 New-Fixture 1; $hs = Approve
 $hostile = Get-SmArguments -Mode Cleanup -RemoveProfiles true -SharedDevices $sharedPc -ReviewedReports ($hs -join ','); $hostile.ProfileReport = $true
 $r = Invoke-SmMaintenance $hostile
 Assert (@($script:attempts).Count -eq 0 -and $r.Actions.Count -eq 0) 'ProfileReport with approved reports and Cleanup arguments removes nothing'

 # The user-folder gate is named and listed with the others.
 $f = @{IsPrimary=$false;IsService=$false;IsAdmin=$false;AdminKnown=$true;PrimaryKnown=$true;CoverageDays=120;AgeDays=90;PstBytes=0;PstFiles=0;MediaFiles=2;SizePartial=$false;Shared=$true;Kfm=[pscustomobject]@{state='verified';localOneDriveFiles=0;outsideKfmFiles=0}}
 Assert ((Get-SmReportDecision 'StaleCandidate' 'age' $f).Decision -eq 'ReviewUserFoldersNotEmpty') 'A file in Downloads, Videos or Music blocks candidacy'
}

$realSafePathFn = ${function:Test-SmSafePath}
try {
 & $suite
 # Stdout: the audit hash the owner approves survives the custom-field byte cap.
 $many = 1..200 | ForEach-Object { [pscustomobject][ordered]@{sid="S-1-5-21-1-2-3-$_";account=('A' * 300);path=('P' * 300);totalBytes=$_;decision='Protected';reason=('R' * 300);ageDecision='StaleCandidate'} }
 $report = [pscustomobject]@{Mode='Report';Status='complete';Timestamp='x';ReportPath='r';Before=@();Errors=@();Audit=[ordered]@{runId=('1' * 32);code='AuditChainVerified';reportHash=('f' * 64);headSeq=9;error=$null};ProfileReport=[pscustomobject]@{EventLog=@{};DeviceClass=@{};Profiles=$many;Summary=[ordered]@{profiles=200};Errors=@()}}
 $json = ConvertTo-SmProfileReportJson $report
 Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 9500 -and ($json | ConvertFrom-Json).audit.reportHash -eq ('f' * 64)) 'Report hash printed within the byte cap'

 # --- Mutation pass: disable each safeguard alone in a copy of the package; the suite must fail.
 $source = [IO.File]::ReadAllText((Resolve-Path $package))
 $mutations = [ordered]@{
  'shared-device gate' = @("if(-not (`$ComputerName -and @(`$A.SharedDevices) -contains `$ComputerName)) { return (& `$plan 'NotSharedDevice' @()) }", '')
  'audit chain gate' = @("if(-not `$Audit -or -not `$Audit.Chain.Valid) {", 'if($false) {')
  'unresolved intent gate' = @("if(@(`$Audit.Chain.Unresolved).Count) {", 'if($false) {')
  'reviewed reports gate' = @("if(-not `$reviewed.Valid) { return (& `$plan `$reviewed.Code @()) }", '')
  'both reports required' = @("Keys=@(`$sets[0] | Where-Object { `$sets[1] -contains `$_ })", 'Keys=@($sets[0])')
  'review gap' = @("-lt `$script:SmReviewGapDays) {", '-lt 0) {')
  'cooldown gate' = @("if(-not `$Cooldown -or -not `$Cooldown.Allowed) {", 'if($false) {')
  'missing marker fails safe' = @("if(`$null -eq `$MarkerText) { return (& `$out 'CooldownMarkerMissing' `$true) }", '')
  'clock skew' = @("{ return (& `$out 'ClockSkew' `$false) }", '{ }')
  'per-run cap' = @("if(`$r.RemovalPlan.Attempted -ge `$script:SmProfileRemovalCap) {", 'if($false) {')
  'stop after a failure' = @('if($stop) {', 'if($false) {')
  'intent before removal' = @("`$null=Add-SmAuditEntry `$audit `$runId 'intent'", '$null=@{} #')
  'fresh gate matrix' = @("if(`"`$(`$gate.decision)`" -ne 'StaleCandidate') {", 'if($false) {')
  'logon evidence unchanged' = @("if(`"`$(`$gate.lastLogon4624Utc)`" -ne `"`$(`$entry.lastLogon4624Utc)`") {", 'if($false) {')
  'entry hash check' = @("if((Get-SmSha256 `$canonical) -ne `$o.hash) {", 'if($false) {')
  'truncation check' = @("elseif(`$headSeq -gt `$seq) { return (& `$fail 'AuditTruncated') }", 'elseif($headSeq -gt $seq) { }')
  'user-folder gate' = @('$script:SmMediaFolderGate=$true', '$script:SmMediaFolderGate=$false')
 }
 $mutDir = Join-Path $work 'mutants'; $null = New-Item -ItemType Directory -Path $mutDir
 # The tamper and cooldown checks above run at script level, so the suite gets them as a block too.
 $staticChecks = {
  Tamper { param($l) $l[2] = $l[2].Replace('"ReviewPst"', '"StaleCandidate"'); ($l -join "`n") + "`n" } @('AuditEntryEdited') 'An edited field'
  Tamper { param($l) $l.RemoveAt($l.Count - 1); ($l -join "`n") + "`n" } @('AuditTruncated') 'A cut tail'
  [IO.File]::WriteAllText($file, $good); [IO.File]::WriteAllText($head, $goodHead)
  Assert ((Get-SmCooldownState $null $cc $t0.AddDays(30) 1).Code -eq 'CooldownMarkerMissing') 'Missing marker'
  Assert ((Get-SmCooldownState $okMarker $cc $t0.AddDays(-1) 1).Code -eq 'ClockSkew') 'Clock skew'
  Assert ((Get-SmReviewedCandidates $rc $rh $t0).Keys.Count -eq 1) 'Both reports'
  Assert ((Get-SmReviewedCandidates (Test-SmAuditChain $close) $closeHashes $t0).Code -eq 'ReviewedReportsTooClose') 'Gap'
 }
 # Control: an unmutated copy through the same harness passes, so a mutant fails for its change alone.
 $control = Join-Path $mutDir 'control.ps1'; [IO.File]::WriteAllText($control, $source)
 & { . $control; & $staticChecks; & $suite }
 foreach ($name in $mutations.Keys) {
  $find = $mutations[$name][0]
  Assert ($source.IndexOf($find) -ge 0 -and $source.IndexOf($find) -eq $source.LastIndexOf($find)) "Mutation '$name' no longer matches exactly one place in the package"
  $mutant = Join-Path $mutDir (($name -replace '\W', '-') + '.ps1')
  [IO.File]::WriteAllText($mutant, $source.Replace($find, $mutations[$name][1]))
  $failed = $false
  try { & { . $mutant; & $staticChecks; & $suite } } catch { $failed = $true; Write-Host "mutation '$name' caught: $($_.Exception.Message)" }
  Assert $failed "Mutation '$name' survived: no test failed with that safeguard disabled"
 }
} finally { Remove-Item -LiteralPath $work -Recurse -Force }

Write-Output 'storage-maintenance profile removal tests passed'
