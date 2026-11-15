$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
$package = Join-Path $PSScriptRoot '../../windows/packages/storage-maintenance/Invoke-StorageMaintenance.ps1'
. $package
$packageEnumerate = $script:SmEnumerate
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Throws($Code, $Pattern) { $m = $null; try { & $Code } catch { $m = $_.Exception.Message }; Assert ($m -and $m -match $Pattern) "expected throw matching '$Pattern', got '$m'" }

# Device names and profile paths are generated per run; no identifier is committed.
$rand = { 'T' + [guid]::NewGuid().ToString('n').Substring(0, 10).ToUpperInvariant() }
$devA = & $rand; $devB = & $rand; $sharedPc = & $rand; $otherPc = & $rand
$userRoot = 'C:\' + (& $rand)
# --- Arguments: ProfileReport is report-only and cannot be combined with any mutation.
$a = Get-SmArguments
Assert (-not $a.ProfileReport -and $a.SharedDevices.Count -eq 0 -and $a.PrimaryUserHint -eq '') 'ProfileReport off by default'
$a = Get-SmArguments -ProfileReport true -SharedDevices " $devA , $($devB.ToLowerInvariant()) ," -PrimaryUserHint ' AzureAD\Someone '
Assert ($a.ProfileReport -and $a.SharedDevices.Count -eq 2 -and $a.SharedDevices[1] -ceq $devB.ToLowerInvariant() -and $a.PrimaryUserHint -eq 'AzureAD\Someone') 'ProfileReport arguments parsed'
Throws { Get-SmArguments -ProfileReport true -Mode Cleanup } 'report-only'
Throws { Get-SmArguments -ProfileReport true -RemoveProfiles true } 'report-only'
Throws { Get-SmArguments -ProfileReport true -ComponentCleanup true } 'report-only'
Throws { Get-SmArguments -ProfileReport yes } 'true or false'
Throws { Get-SmArguments -SharedDevices "$devA,..\x" } 'computer names'
Throws { Get-SmArguments -PrimaryUserHint "a`nb" } 'PrimaryUserHint'

# --- Decision gates. Every gate is flipped alone from an all-pass baseline.
$pass = @{IsPrimary=$false;IsService=$false;IsAdmin=$false;AdminKnown=$true;PrimaryKnown=$true;CoverageDays=120;AgeDays=90;PstBytes=0;SizePartial=$false;Shared=$true}
function Decide($Base, $Change) { $f = $pass.Clone(); foreach ($k in $Change.Keys) { $f[$k] = $Change[$k] }; (Get-SmReportDecision $Base 'age reason' $f).Decision }
Assert ((Decide 'StaleCandidate' @{}) -eq 'ReviewKfmUnverified') 'Until the KFM probe exists, an all-pass stale profile stays Review'
$cases = @(
 @(@{IsPrimary=$true}, 'KeepPrimaryUser'),
 @(@{IsService=$true}, 'Protected'),
 @(@{IsAdmin=$true}, 'Protected'),
 @(@{Shared=$false}, 'KeepNotSharedDevice'),
 @(@{AdminKnown=$false}, 'ReviewAdminUnknown'),
 @(@{PrimaryKnown=$false}, 'ReviewPrimaryUnknown'),
 @(@{CoverageDays=$null}, 'ReviewLogCoverage'),
 @(@{CoverageDays=89}, 'ReviewLogCoverage'),
 @(@{PstBytes=1}, 'ReviewPst'),
 @(@{PstBytes=$null}, 'ReviewPst'),
 @(@{SizePartial=$true}, 'ReviewPst')
)
foreach ($case in $cases) { $got = Decide 'StaleCandidate' $case[0]; Assert ($got -eq $case[1]) ("gate $(($case[0].Keys) -join ','): expected $($case[1]), got $got") }
Assert ((Decide 'StaleCandidate' @{CoverageDays=90}) -eq 'ReviewKfmUnverified') 'Coverage equal to the threshold passes'
foreach ($base in @('Protected','KeepRecentConfirmed','KeepRecentProfileService')) { Assert ((Decide $base @{IsPrimary=$true;Shared=$false}) -eq $base) "$base passes through unchanged" }
Assert ((Decide 'ReviewInconsistent' @{}) -eq 'ReviewInconsistent') 'Age-engine Review is never upgraded'
Assert ((Decide 'ReviewInconsistent' @{IsPrimary=$true}) -eq 'KeepPrimaryUser') 'Primary user is kept even when age evidence needs review'
# Exhaustive: no flag combination can produce a deletion candidate in this version.
$names = @('IsPrimary','IsService','IsAdmin','AdminKnown','PrimaryKnown','SizePartial','Shared')
for ($mask = 0; $mask -lt [math]::Pow(2, $names.Count); $mask++) {
 $change = @{}; for ($i = 0; $i -lt $names.Count; $i++) { $change[$names[$i]] = [bool]($mask -band (1 -shl $i)) }
 foreach ($cov in @($null, 10, 365)) { $change.CoverageDays = $cov; foreach ($pst in @($null, 0, 5)) { $change.PstBytes = $pst; Assert ((Decide 'StaleCandidate' $change) -ne 'StaleCandidate') 'No gate combination yields a candidate' } }
}

# --- Byte census. A mocked enumerator stands in for NTFS attributes Linux cannot create.
$root = Join-Path ([IO.Path]::GetTempPath()) ('m4pc2-profile-' + [guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory -Path $root
$recycleRoot = Join-Path $root 'recycle'; $null = New-Item -ItemType Directory -Path $recycleRoot
$profileRoot = Join-Path $root 'user'; $null = New-Item -ItemType Directory -Path $profileRoot
try {
 $D = 16; $RP = 1024; $OFF = 4096; $ROO = 262144; $RDA = 4194304
 function E($Rel, $Attr, $Len = 0, $Link = $null) { [pscustomobject]@{FullName=($profileRoot + $Rel); Attributes=$Attr; Length=$Len; LinkType=$Link} }
 $tree = @{}
 $tree[$profileRoot] = @(
  (E '\AppData' $D), (E '\Downloads' $D), (E '\OneDrive - Org' ($D -bor $RP)), (E '\Junction' ($D -bor $RP) 0 'Junction'),
  (E '\Cloudish' ($D -bor $RP)), (E '\file.bin' 32 100), (E '\link.pst' ($RP -bor 32) 999 'SymbolicLink'))
 $tree[$profileRoot + '\AppData'] = @((E '\AppData\Local' $D), (E '\AppData\Roaming' $D))
 $tree[$profileRoot + '\AppData\Local'] = @((E '\AppData\Local\Temp\t.tmp' 32 10), (E '\AppData\Local\Microsoft\Outlook\a.ost' 32 1000), (E '\AppData\Local\Microsoft\Outlook\old.PST' 32 2000),
  (E '\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\c' 32 30), (E '\AppData\Local\Microsoft\Edge\User Data\Default\Cache\Cache_Data\f' 32 40),
  (E '\AppData\Local\Google\Chrome\User Data\Profile 1\Code Cache\js\f' 32 50))
 $tree[$profileRoot + '\AppData\Roaming'] = @((E '\AppData\Roaming\Microsoft\Teams\x' 32 60))
 $tree[$profileRoot + '\Downloads'] = @((E '\Downloads\setup.exe' 32 70))
 $tree[$profileRoot + '\OneDrive - Org'] = @((E '\OneDrive - Org\local.docx' ($RP -bor 32) 80), (E '\OneDrive - Org\cloud.docx' ($RP -bor $RDA) 5000), (E '\OneDrive - Org\offline.docx' ($RP -bor $OFF) 6000),
  (E '\OneDrive - Org\Unpopulated' ($D -bor $RP -bor $ROO)), (E '\OneDrive - Org\Inner' ($D -bor $RP) 0 'Junction'))
 $tree[$profileRoot + '\Junction'] = @((E '\Junction\outside.bin' 32 777777))
 $tree[$profileRoot + '\Cloudish'] = @((E '\Cloudish\outside.bin' 32 888888))
 $tree[$recycleRoot] = @([pscustomobject]@{FullName=($recycleRoot + '\$RABC.docx');Attributes=32;Length=90;LinkType=$null}, [pscustomobject]@{FullName=($recycleRoot + '\$RDIR');Attributes=($D -bor $RP);Length=0;LinkType='Junction'})
 $script:enumerated = @()
 $script:SmEnumerate = { param($Dir) $script:enumerated += $Dir; if (-not $tree.ContainsKey($Dir)) { throw "unexpected enumeration of $Dir" }; $tree[$Dir] }
 $script:SmScanGuard = { [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
 $s = Get-SmProfileBytes $profileRoot $recycleRoot 1000 30
 Assert ($s.Bytes.ost -eq 1000 -and $s.Bytes.pst -eq 2000) 'OST and PST measured (extension match is case-insensitive)'
 Assert ($s.Bytes.temp -eq 10 -and $s.Bytes.downloads -eq 70 -and $s.Bytes.teamsCache -eq 90 -and $s.Bytes.browserCache -eq 90) 'Temp, Downloads, Teams and browser caches measured'
 Assert ($s.Bytes.oneDriveHydrated -eq 80 -and $s.Bytes.oneDriveOnlineOnly -eq 11000) 'OneDrive hydrated vs online-only split by attribute'
 Assert ($s.Bytes.recycleBin -eq 90) 'Per-SID Recycle Bin measured'
 Assert ($s.TotalBytes -eq (100+10+1000+2000+30+40+50+60+70+80)) "Total counts local bytes only, got $($s.TotalBytes)"
 Assert (-not ($script:enumerated -match 'Junction|Cloudish|Unpopulated|Inner|RDIR')) ('Never entered a junction, a non-OneDrive reparse dir or a recall-on-open dir: ' + ($script:enumerated -join ';'))
 Assert ($s.Partial -and $s.Skipped -eq 6) "Skipped entries make the size partial, skipped=$($s.Skipped)"
 $s = Get-SmProfileBytes $profileRoot $null 3 30
 Assert ($s.Partial -and $s.EntriesVisited -eq 3) 'Entry budget bounds the walk'
 $script:SmScanGuard = { [pscustomobject]@{Safe=$false;Light=$true;Reasons=@('Setup started')} }
 $s = Get-SmProfileBytes $profileRoot $null 1000 30
 Assert ($s.Light -and $s.Partial -and $s.EntriesVisited -eq 0) 'Setup appearing stops the walk'
 $script:SmScanGuard = { [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
 $s = Get-SmProfileBytes (Join-Path $root 'missing') $null 1000 30
 Assert ($s.Partial -and $s.TotalBytes -eq 0) 'Missing profile root is partial, not zero-and-complete'
 # Budgets bound enumeration itself: a huge directory is read lazily, not collected first.
 $real = $packageEnumerate
 $listing = & $real $profileRoot
 Assert ($listing -isnot [array] -and $listing -is [Collections.IEnumerable]) 'Enumerator returned unrolled, not collected into an array'
 $script:produced = 0
 $script:SmEnumerate = { param($Dir) , [Linq.Enumerable]::Select([Linq.Enumerable]::Range(0, 100000), [Func[int,object]]{ param($i) $script:produced++; [pscustomobject]@{FullName=($Dir + '\f' + $i);Attributes=32;Length=1;LinkType=$null} }) }
 $s = Get-SmProfileBytes $profileRoot $null 50 30
 Assert ($s.Partial -and $script:produced -le 52) "Walk stopped at the entry budget, produced=$($script:produced)"
 $script:SmEnumerate = $real
 # Real filesystem through the package's own enumerator: a symlink out of the profile is never followed.
 $real = Join-Path $root 'real'; $outside = Join-Path $root 'outside'
 $null = New-Item -ItemType Directory -Path (Join-Path $real 'Downloads') -Force; $null = New-Item -ItemType Directory -Path $outside
 [IO.File]::WriteAllBytes((Join-Path $real 'Downloads/a.bin'), [byte[]]::new(64))
 [IO.File]::WriteAllBytes((Join-Path $outside 'big.bin'), [byte[]]::new(4096))
 $null = New-Item -ItemType SymbolicLink -Path (Join-Path $real 'escape') -Target $outside
 $s = Get-SmProfileBytes $real $null 1000 30
 Assert ($s.TotalBytes -eq 64 -and $s.Bytes.downloads -eq 64 -and $s.Skipped -eq 1) "Real symlink skipped, total=$($s.TotalBytes)"
} finally { Remove-Item -LiteralPath $root -Recurse -Force }

# --- Report context collection (worker side), with every OS boundary mocked.
& {
 $now = [datetime]::SpecifyKind([datetime]'2026-11-20T00:00:00', 'Utc')
 function Get-WinEvent { [CmdletBinding()] param($LogName, [switch]$Oldest, $MaxEvents) if ($Oldest) { [pscustomobject]@{TimeCreated=$now.AddDays(-200)} } else { [pscustomobject]@{TimeCreated=$now.AddMinutes(-1)} } }
 function Get-LocalGroupMember { [CmdletBinding()] param($SID) [pscustomobject]@{SID='S-1-5-21-1-2-3-1100'} }
 function Test-Path { param($LiteralPath) $LiteralPath -like '*Enrollments' }
 function Get-ChildItem { [CmdletBinding()] param($LiteralPath) [pscustomobject]@{PSPath='enroll1'}, [pscustomobject]@{PSPath='enroll2'} }
 function Get-ItemProperty { [CmdletBinding()] param($LiteralPath)
  switch -Wildcard ($LiteralPath) {
   'enroll1' { [pscustomobject]@{UPN='Person@example.test'} }
   'enroll2' { [pscustomobject]@{UPN=''} }
   '*Microsoft\Policies\LAPS' { [pscustomobject]@{AdministratorAccountName='lapsadm'} }
   '*IdentityStore*' { [pscustomobject]@{UserName='cloud@example.test'} }
   default { throw 'absent' }
  }
 }
 $events = [pscustomobject]@{ProbeComplete=$true;Truncated=$false;Recent=@(
  [pscustomobject]@{Sid='S-1-5-21-1-2-3-1001';LogonType=2;TimeUtc=$now}, [pscustomobject]@{Sid='S-1-5-21-1-2-3-1001';LogonType=7;TimeUtc=$now},
  [pscustomobject]@{Sid='S-1-12-1-9-9-9-9';LogonType=11;TimeUtc=$now}, [pscustomobject]@{Sid='S-1-5-96-0-1';LogonType=2;TimeUtc=$now},
  [pscustomobject]@{Sid='S-1-5-90-0-1';LogonType=2;TimeUtc=$now}, [pscustomobject]@{Sid='S-1-5-21-1-2-3-500';LogonType=10;TimeUtc=$now})}
 $c = Get-SmReportContext ([pscustomobject]@{Events=$events}) @([pscustomobject]@{SID='S-1-12-1-9-9-9-9'}) $now
 Assert ($c.Log.Known -and $c.Log.OldestUtc -eq $now.AddDays(-200)) 'Security log oldest event read'
 Assert ($c.Admins.Known -and $c.Admins.Sids -contains 'S-1-5-21-1-2-3-1100') 'Local Administrators SIDs read'
 Assert ($c.IntuneUpns.Count -eq 1 -and $c.IntuneUpns[0] -eq 'Person@example.test') 'Intune enrollment UPN read, blanks ignored'
 Assert ($c.LapsNames -contains 'lapsadm') 'LAPS account name read'
 Assert ($c.Upns['S-1-12-1-9-9-9-9'] -eq 'cloud@example.test') 'Entra profile UPN read from the identity cache'
 Assert ($c.LogonCounts.Count -eq 2 -and $c.LogonCounts['S-1-5-21-1-2-3-1001'] -eq 2 -and $c.LogonsComplete) 'Window manager, font driver and RID 500 logons are not users'
 function Get-LocalGroupMember { [CmdletBinding()] param($SID) throw 'orphaned SID' }
 function Get-WinEvent { [CmdletBinding()] param($LogName, [switch]$Oldest, $MaxEvents) throw 'log unavailable' }
 if ($env:OS -ne 'Windows_NT') {
  $c = Get-SmReportContext ([pscustomobject]@{Events=$events}) @() $now
  Assert (-not $c.Admins.Known -and -not $c.Log.Known -and $c.Errors.Count -ge 2) 'Unreadable admins and log are unknown, not empty'
 }
}

# --- Report assembly: coverage, clock skew, primary user, admin and service flags.
$now = [datetime]::SpecifyKind([datetime]'2026-11-20T00:00:00', 'Utc')
function New-AgePair($Date) { $ft = [uint64]$Date.ToFileTimeUtc(); @{ Low=[uint32]($ft -band [uint64]4294967295); High=[uint32]($ft -shr 32) } }
function New-Assessed($Sid, $Account, $Path, $Decision = 'StaleCandidate') {
 $u = New-AgePair ($now.AddDays(-200))
 [pscustomobject]@{SID=$Sid;Path=$Path;Decision=$Decision;Reason='age';Evidence=[pscustomobject]@{Identity=[pscustomobject]@{Account=$Account};Registry=[pscustomobject]@{Unload=(ConvertFrom-SmFileTimePair $u.Low $u.High $now)};Events=[pscustomobject]@{Recent=@()}}}
}
function New-Context { [pscustomobject]@{Log=[pscustomobject]@{Known=$true;OldestUtc=$now.AddDays(-365);NewestUtc=$now.AddMinutes(-5)};Admins=[pscustomobject]@{Known=$true;Sids=@('S-1-5-21-9-9-9-1105')};IntuneUpns=@('owner.person@example.test');LapsNames=@('lapsadm');Upns=@{'S-1-12-1-1-1-1-1'='owner.person@example.test'};LogonCounts=@{'S-1-5-21-9-9-9-1101'=8;'S-1-5-21-9-9-9-1102'=2};LogonsComplete=$true;Errors=@()} }
$realProfilePath = ${function:Test-SmProfilePath}; $realBytes = ${function:Get-SmProfileBytes}
function Test-SmProfilePath($Path) { $true }
function Get-SmProfileBytes { [pscustomobject]@{TotalBytes=500;Bytes=[ordered]@{ost=0;pst=0};Partial=$false;Light=$false;EntriesVisited=1} }
$args90 = @{ProfileAgeDays=90;MaxFiles=1000;MaxSeconds=30;SharedDevices=@($sharedPc);PrimaryUserHint=''}
$assessed = @(
 (New-Assessed 'S-1-12-1-1-1-1-1' 'AzureAD\OwnerPerson' ($userRoot + '\OwnerPerson')),
 (New-Assessed 'S-1-5-21-9-9-9-1101' 'CORP\toplogon' ($userRoot + '\toplogon')),
 (New-Assessed 'S-1-5-21-9-9-9-1103' 'CORP\hinted' ($userRoot + '\hinted')),
 (New-Assessed 'S-1-5-21-9-9-9-1104' 'CORP\svc_backup' ($userRoot + '\svc_backup')),
 (New-Assessed 'S-1-5-21-9-9-9-1105' 'CORP\jdoe' ($userRoot + '\jdoe')),
 (New-Assessed 'S-1-5-21-9-9-9-1106' 'CORP\lapsadm' ($userRoot + '\lapsadm')),
 (New-Assessed 'S-1-5-21-9-9-9-1107' 'CORP\KIOSK$' ($userRoot + '\KIOSK$')),
 (New-Assessed 'S-1-5-21-9-9-9-1108' 'CORP\leaver' ($userRoot + '\leaver')))
$hintArgs = $args90.Clone(); $hintArgs.PrimaryUserHint = 'CORP\Hinted'
$rep = Get-SmProfileReport $hintArgs $assessed (New-Context) $now $sharedPc.ToLowerInvariant()
$by = @{}; foreach ($p in $rep.Profiles) { $by[$p.account] = $p }
Assert ($by['AzureAD\OwnerPerson'].decision -eq 'KeepPrimaryUser' -and $by['AzureAD\OwnerPerson'].primarySource -eq 'intune') 'Intune UPN protects the Entra profile through its cached UPN'
Assert ($by['CORP\toplogon'].primarySource -eq 'logon4624') 'Top 4624 SID protects'
Assert ($by['CORP\hinted'].primarySource -eq 'hint') 'Caller hint protects, case-insensitively'
Assert ($by['CORP\svc_backup'].isService -and $by['CORP\svc_backup'].decision -eq 'Protected') 'svc* name protected'
Assert ($by['CORP\jdoe'].isAdmin -and $by['CORP\jdoe'].decision -eq 'Protected') 'Local admin protected'
Assert ($by['CORP\lapsadm'].isService) 'LAPS account protected'
Assert ($by['CORP\KIOSK$'].isService) 'Name ending in $ protected'
Assert ($by['CORP\leaver'].decision -eq 'ReviewKfmUnverified' -and $by['CORP\leaver'].ageDays -eq 200 -and $by['CORP\leaver'].profileUnloadUtc -eq $now.AddDays(-200).ToString('yyyy-MM-ddTHH:mm:ssZ')) 'Leaver on a shared device reaches the last gate only'
Assert ($rep.EventLog.coverageDays -eq 365 -and $rep.DeviceClass.suggested -eq 'secondary' -and $rep.DeviceClass.topSidShare -eq 0.8 -and $rep.DeviceClass.configuredShared) 'Coverage and device class reported; shared match is case-insensitive'
Assert ($rep.Summary.profiles -eq 8 -and $rep.Summary.staleByAge -eq 8 -and $rep.Summary.candidates -eq 0 -and $rep.Summary.review -eq 1) 'Summary counts'
$leaver = @($assessed[-1])
Assert ((Get-SmProfileReport $args90 $leaver (New-Context) $now $otherPc).Profiles[0].decision -eq 'KeepNotSharedDevice') 'Device not on the shared list never deletes'
Assert ((Get-SmProfileReport $args90 $leaver (New-Context) $now '').Profiles[0].decision -eq 'KeepNotSharedDevice') 'Empty computer name is not shared'
foreach ($skew in @(
 @{OldestUtc=$now.AddDays(-365);NewestUtc=$now.AddDays(3)},
 @{OldestUtc=$now.AddDays(-365);NewestUtc=$now.AddDays(-5)},
 @{OldestUtc=$now.AddDays(1);NewestUtc=$now.AddDays(-1)},
 @{OldestUtc=$now.AddDays(-30);NewestUtc=$now})) {
 $ctx = New-Context; $ctx.Log = [pscustomobject]@{Known=$true;OldestUtc=$skew.OldestUtc;NewestUtc=$skew.NewestUtc}
 $p = (Get-SmProfileReport $args90 $leaver $ctx $now $sharedPc).Profiles[0]
 Assert ($p.decision -eq 'ReviewLogCoverage') "Clock skew, stopped log or short coverage downgrades to review: $($skew | ConvertTo-Json -Compress)"
}
$ctx = New-Context; $ctx.Log = [pscustomobject]@{Known=$false;OldestUtc=$null;NewestUtc=$null}
Assert ((Get-SmProfileReport $args90 $leaver $ctx $now $sharedPc).Profiles[0].decision -eq 'ReviewLogCoverage') 'Missing Security log coverage downgrades to review'
$ctx = New-Context; $ctx.Admins = [pscustomobject]@{Known=$false;Sids=@()}
Assert ((Get-SmProfileReport $args90 $leaver $ctx $now $sharedPc).Profiles[0].decision -eq 'ReviewAdminUnknown') 'Unknown admin membership downgrades to review'
$ctx = New-Context; $ctx.IntuneUpns = @(); $ctx.LogonCounts = @{}
Assert ((Get-SmProfileReport $args90 $leaver $ctx $now $sharedPc).Profiles[0].decision -eq 'ReviewPrimaryUnknown') 'No primary source downgrades to review'
$r = Get-SmProfileReport $args90 $leaver $null $now $sharedPc
Assert ($r.Profiles[0].decision -like 'Review*' -and $r.Errors.Count -ge 1) 'Missing worker context fails closed'
function Get-SmProfileBytes { [pscustomobject]@{TotalBytes=500;Bytes=[ordered]@{ost=0;pst=0};Partial=$true;Light=$false;EntriesVisited=1} }
Assert ((Get-SmProfileReport $args90 $leaver (New-Context) $now $sharedPc).Profiles[0].decision -eq 'ReviewPst') 'Partial size walk cannot rule out a PST'
function Test-SmProfilePath($Path) { $false }
$p = (Get-SmProfileReport $args90 $leaver (New-Context) $now $sharedPc).Profiles[0]
Assert ($p.decision -eq 'ReviewPst' -and $null -eq $p.totalBytes -and $p.sizePartial) 'Unconventional profile path is never walked'
${function:Test-SmProfilePath} = $realProfilePath; ${function:Get-SmProfileBytes} = $realBytes

# --- Compact JSON: schema v2, bounded for a custom field, counts survive trimming.
$many = 1..200 | ForEach-Object { [pscustomobject][ordered]@{sid="S-1-5-21-1-2-3-$_";account=('A' * 300);path=('P' * 300);totalBytes=$_;decision=$(if($_ -eq 7){'ReviewKfmUnverified'}else{'Protected'});reason=('R' * 300);ageDecision='StaleCandidate'} }
$report = [pscustomobject]@{Mode='Report';Status='complete';Timestamp='2026-11-20T00:00:00Z';ReportPath='C:\ProgramData\RelianMaintenance\Storage\x.json';Before=@(@{DeviceID='C:';Size=256;FreeSpace=20});Errors=@();
 ProfileReport=[pscustomobject]@{EventLog=@{coverageDays=10};DeviceClass=@{suggested='shared'};Profiles=$many;Summary=[ordered]@{profiles=200;review=1};Errors=@()}}
$json = ConvertTo-SmProfileReportJson $report
$doc = $json | ConvertFrom-Json
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 9500) 'Custom-field JSON stays under the byte cap'
Assert ($doc.schemaVersion -eq 2 -and $doc.truncated -and $doc.summary.profiles -eq 200 -and $doc.volumes[0].freeBytes -eq 20) 'Schema v2 keeps counts and volumes when profiles are trimmed'
Assert ($doc.profiles[0].decision -eq 'ReviewKfmUnverified' -and $doc.profiles[0].account.Length -le 67) 'Review entries rank first and strings are clipped'

# --- HARD RULE: the report path deletes nothing and changes no setting.
# 1. Static: no report function names a mutating command or a removal hook.
$reportFunctions = @('Get-SmProfileBytes','Get-SmReportContext','Get-SmReportDecision','Get-SmProfileReport','ConvertTo-SmProfileReportJson')
foreach ($fn in $reportFunctions) {
 $ast = (Get-Command $fn).ScriptBlock.Ast
 $commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
 $bad = @($commands | Where-Object { $_ -match '^(Remove|Set|New|Clear|Rename|Move|Copy|Add|Disable|Enable|Stop|Start|Restart|Invoke|Register|Unregister|Write|Out)-' -and $_ -notin @('New-Object','Write-Verbose') })
 Assert ($bad.Count -eq 0) "$fn calls mutating commands: $($bad -join ',')"
 $text = $ast.Extent.Text
 Assert ($text -notmatch 'SmDelete|SmRemoveProfile|SmComponent|SmSave|Remove-CimInstance|\.Delete\(|DeleteKey|SetValue') "$fn references a removal or write hook"
}
# 2. Dynamic: a full run with a deletable profile and an old temp file, every removal hook counted.
$root = Join-Path ([IO.Path]::GetTempPath()) ('m4pc2-run-' + [guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory -Path $root
try {
 $old = Join-Path $root 'old.tmp'; Set-Content -LiteralPath $old -Value 'old'; (Get-Item -LiteralPath $old).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-30)
 $u = New-AgePair ([datetime]::UtcNow.AddDays(-300)); $l = New-AgePair ([datetime]::UtcNow.AddDays(-301))
 $script:Evidence = [pscustomobject]@{Registry=[pscustomobject]@{ReadState='ok';IdentityMatches=$true;Load=(ConvertFrom-SmFileTimePair $l.Low $l.High);Unload=(ConvertFrom-SmFileTimePair $u.Low $u.High);Cleanup=(ConvertFrom-SmFileTimePair $null $null)};Identity=[pscustomobject]@{Resolved=$true;Account='CORP\leaver'};Sessions=[pscustomobject]@{Known=$true;Sids=@();CurrentSid='S-1-5-18'};Hives=[pscustomobject]@{Known=$true;Loaded=$false;ClassesLoaded=$false};NtUser=[pscustomobject]@{DatUtc=$null;ManUtc=$null;Errors=@()};Events=[pscustomobject]@{ProbeComplete=$true;Recent=@();Truncated=$false};Errors=@()}
 $script:Profile = [pscustomobject]@{SID='S-1-5-21-9-9-9-1108';LocalPath=(Join-Path $root 'leaver');Loaded=$false;Special=$false;LastUseTime=[datetime]::UtcNow.AddDays(-300);Status=0;RoamingConfigured=$false;RoamingPreference=$false;refCount=0}
 $null = New-Item -ItemType Directory -Path $script:Profile.LocalPath
 $script:mutations = New-Object Collections.Generic.List[string]
 $script:SmDelete = { param($Path) $script:mutations.Add('delete ' + $Path) }
 $script:SmRemoveProfile = { param($Profile) $script:mutations.Add('removeProfile ' + $Profile.SID) }
 $script:SmComponent = { $script:mutations.Add('componentCleanup'); 0 }
 $script:SmGuards = { [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
 $script:SmScanGuard = { [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
 $script:SmPrepareReport = { 'report.json' }; $script:SmAcquire = { $true }; $script:SmRelease = {}; $script:SmVolumes = { @() }; $script:SmEvidence = { @{} }
 $script:SmProfiles = { @($script:Profile) }; $script:SmRoots = { @($root) }; $script:SmDiagnosticRoots = { @() }; $script:SmUi = { param($Step) 'noUser' }
 $script:SmProfileHiveLoaded = { $false }
 $script:collectModes = @()
 $script:SmCollectProfiles = { param($Profiles,$Days,$Now,$Seconds,$Directory,$Mode)
  $script:collectModes += $Mode
  $ctx = [pscustomobject]@{Log=[pscustomobject]@{Known=$true;OldestUtc=[datetime]::UtcNow.AddDays(-400);NewestUtc=[datetime]::UtcNow};Admins=[pscustomobject]@{Known=$true;Sids=@()};IntuneUpns=@();LapsNames=@();Upns=@{};LogonCounts=@{'S-1-5-21-9-9-9-1101'=5};LogonsComplete=$true;Errors=@()}
  [pscustomobject]@{Complete=$true;TimedOut=$false;GuardChanged=$false;Reasons=@();Entries=@($Profiles | ForEach-Object { [pscustomobject]@{SID=$_.SID;Path=$_.LocalPath;Evidence=$script:Evidence} });FinalVeto=[pscustomobject]@{Clear=$true};ReportContext=$(if($Mode -eq 'Report'){$ctx});ElapsedSeconds=0.01;Error=$null}
 }
 $realProfilePath = ${function:Test-SmProfilePath}; $realSafePath = ${function:Test-SmSafePath}
 function Test-SmProfilePath($Path) { $Path -eq $script:Profile.LocalPath }
 function Test-SmSafePath { $true }
 $env:COMPUTERNAME = $sharedPc
 # Control: the same fixture in Cleanup mode does reach every removal hook, so the hooks are live.
 $null = Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup -RemoveProfiles true -ComponentCleanup true)
 Assert (($script:mutations -match '^removeProfile').Count -eq 1 -and ($script:mutations -match '^delete').Count -ge 1 -and $script:mutations -contains 'componentCleanup') ('Control run reaches removal hooks: ' + ($script:mutations -join ';'))
 $script:mutations.Clear(); $script:collectModes = @()
 $r = Invoke-SmMaintenance (Get-SmArguments -ProfileReport true -SharedDevices $sharedPc -ProfileAgeDays 90)
 Assert ($script:mutations.Count -eq 0 -and $r.Actions.Count -eq 0 -and (Test-Path -LiteralPath $old)) ('ProfileReport run mutated: ' + ($script:mutations -join ';'))
 Assert ($script:collectModes -contains 'Report' -and $r.ProfileReport.Profiles[0].ageDecision -eq 'StaleCandidate' -and $r.ProfileReport.Profiles[0].decision -eq 'ReviewKfmUnverified') 'Report collected identity context; deletable-by-age profile reported as review'
 # A hand-built argument set that skips Get-SmArguments still cannot reach the mutating branch.
 $hostile = Get-SmArguments -Mode Cleanup -RemoveProfiles true -ComponentCleanup true; $hostile.ProfileReport = $true; $hostile.SharedDevices = @($sharedPc); $hostile.PrimaryUserHint = ''
 $r = Invoke-SmMaintenance $hostile
 Assert ($script:mutations.Count -eq 0 -and $r.Actions.Count -eq 0 -and (Test-Path -LiteralPath $old)) ('ProfileReport with Cleanup arguments mutated: ' + ($script:mutations -join ';'))
 $script:SmSave = { param($Report) }
 $out = Complete-SmRun $r 6>$null | Select-Object -Last 1
 Assert (($out | ConvertFrom-Json).schemaVersion -eq 2) 'ProfileReport run prints the v2 JSON'
 # Guard light at start: no profile work, but the v2 output still says why.
 $script:SmGuards = { [pscustomobject]@{Safe=$false;Light=$true;Reasons=@('Setup')} }
 $r = Invoke-SmMaintenance (Get-SmArguments -ProfileReport true)
 Assert ($script:mutations.Count -eq 0 -and $r.ProfileReport.Errors[0] -match 'not collected') 'Light guard yields an explained empty profile report'
 ${function:Test-SmProfilePath} = $realProfilePath; ${function:Test-SmSafePath} = $realSafePath
} finally { Remove-Item -LiteralPath $root -Recurse -Force }

Write-Output 'storage-maintenance profile report tests passed'
