$ErrorActionPreference = 'Stop'
$env:RELIAN_DEPLOY_TEST = '1'
$package = Join-Path $PSScriptRoot '../../windows/packages/storage-maintenance/Invoke-StorageMaintenance.ps1'
. $package
$packageEnumerate = $script:SmEnumerate; $packageReadHive = $script:SmReadHive
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
$kfmOk = [pscustomobject]@{state='verified';redirected=3;accounts=1;localOneDriveFiles=0;outsideKfmFiles=0;error=$null}
$pass = @{IsPrimary=$false;IsService=$false;IsAdmin=$false;AdminKnown=$true;PrimaryKnown=$true;CoverageDays=120;AgeDays=90;PstBytes=0;PstFiles=0;MediaFiles=0;SizePartial=$false;Shared=$true;Kfm=$kfmOk}
function Kfm($Change) { $k = [ordered]@{}; foreach ($p in $kfmOk.PSObject.Properties) { $k[$p.Name] = $p.Value }; foreach ($n in $Change.Keys) { $k[$n] = $Change[$n] }; [pscustomobject]$k }
function Decide($Base, $Change) { $f = $pass.Clone(); foreach ($k in $Change.Keys) { $f[$k] = $Change[$k] }; (Get-SmReportDecision $Base 'age reason' $f).Decision }
Assert ((Decide 'StaleCandidate' @{}) -eq 'StaleCandidate') 'Only a profile that passes every gate is a (report-only) candidate'
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
 @(@{PstFiles=1}, 'ReviewPst'),
 @(@{PstFiles=$null}, 'ReviewPst'),
 @(@{SizePartial=$true}, 'ReviewPst'),
 @(@{Kfm=$null}, 'ReviewKfmUnknown'),
 @(@{Kfm=(Kfm @{state='unknown';error='Hive is dirty'})}, 'ReviewKfmUnknown'),
 @(@{Kfm=(Kfm @{state='notRedirected'})}, 'ReviewKfmNotRedirected'),
 @(@{Kfm=(Kfm @{state='syncRootNotWalked'})}, 'ReviewKfmSyncRootNotWalked'),
 @(@{Kfm=(Kfm @{state='Verified '})}, 'ReviewKfmUnknown'),
 @(@{Kfm=(Kfm @{localOneDriveFiles=1})}, 'ReviewKfmUploadUnproven'),
 @(@{Kfm=(Kfm @{localOneDriveFiles=$null})}, 'ReviewKfmUploadUnproven'),
 @(@{Kfm=(Kfm @{outsideKfmFiles=1})}, 'ReviewOutsideKfm'),
 @(@{Kfm=(Kfm @{outsideKfmFiles=$null})}, 'ReviewOutsideKfm'),
 @(@{MediaFiles=1}, 'ReviewUserFoldersNotEmpty'),
 @(@{MediaFiles=$null}, 'ReviewUserFoldersNotEmpty')
)
foreach ($case in $cases) { $got = Decide 'StaleCandidate' $case[0]; Assert ($got -eq $case[1]) ("gate $(($case[0].Keys) -join ','): expected $($case[1]), got $got") }
Assert ((Decide 'StaleCandidate' @{CoverageDays=90}) -eq 'StaleCandidate') 'Coverage equal to the threshold passes'
# The Downloads/Videos/Music gate is one named switch: turning it off drops only that gate.
$script:SmMediaFolderGate = $false
Assert ((Decide 'StaleCandidate' @{MediaFiles=4}) -eq 'StaleCandidate' -and (Decide 'StaleCandidate' @{MediaFiles=4;PstFiles=1}) -eq 'ReviewPst') 'SmMediaFolderGate=$false drops the user-folder gate and nothing else'
$script:SmMediaFolderGate = $true
foreach ($base in @('Protected','KeepRecentConfirmed','KeepRecentProfileService')) { Assert ((Decide $base @{IsPrimary=$true;Shared=$false}) -eq $base) "$base passes through unchanged" }
Assert ((Decide 'ReviewInconsistent' @{}) -eq 'ReviewInconsistent') 'Age-engine Review is never upgraded'
Assert ((Decide 'ReviewFallbackOnly' @{}) -eq 'ReviewFallbackOnly') 'An all-pass KFM never upgrades an age-engine Review'
Assert ((Decide 'ReviewInconsistent' @{IsPrimary=$true}) -eq 'KeepPrimaryUser') 'Primary user is kept even when age evidence needs review'
# Exhaustive: exactly one combination, every gate passing, yields a candidate.
$names = @('IsPrimary','IsService','IsAdmin','AdminKnown','PrimaryKnown','SizePartial','Shared')
$kfms = @($null, $kfmOk, (Kfm @{state='unknown'}), (Kfm @{localOneDriveFiles=2}), (Kfm @{outsideKfmFiles=1}), (Kfm @{localOneDriveFiles=$null}))
$hits = 0
for ($mask = 0; $mask -lt [math]::Pow(2, $names.Count); $mask++) {
 $change = @{}; for ($i = 0; $i -lt $names.Count; $i++) { $change[$names[$i]] = [bool]($mask -band (1 -shl $i)) }
 foreach ($cov in @($null, 10, 365)) { $change.CoverageDays = $cov; foreach ($pst in @($null, 0, 5)) { $change.PstBytes = $pst; $change.PstFiles = $pst; foreach ($k in $kfms) { $change.Kfm = $k; foreach ($media in @($null, 0, 3)) { $change.MediaFiles = $media
  if ((Decide 'StaleCandidate' $change) -eq 'StaleCandidate') { $hits++; Assert ($mask -eq 88 -and $cov -eq 365 -and $pst -eq 0 -and $k -eq $kfmOk -and $media -eq 0) ('Candidate from a failing gate: ' + ($change | ConvertTo-Json -Compress -Depth 3)) } } } } }
}
Assert ($hits -eq 1) "Exactly one all-pass combination is a candidate, got $hits"

# --- Byte census. A mocked enumerator stands in for NTFS attributes Linux cannot create.
$root = Join-Path ([IO.Path]::GetTempPath()) ('profile-report-' + [guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory -Path $root
$recycleRoot = Join-Path $root 'recycle'; $null = New-Item -ItemType Directory -Path $recycleRoot
$profileRoot = Join-Path $root 'user'; $null = New-Item -ItemType Directory -Path $profileRoot
try {
 $D = 16; $RP = 1024; $OFF = 4096; $ROO = 262144; $RDA = 4194304
 $HS = 6
 function E($Rel, $Attr, $Len = 0, $Link = $null) { [pscustomobject]@{FullName=($profileRoot + $Rel); Attributes=$Attr; Length=$Len; LinkType=$Link} }
 $tree = @{}
 $tree[$profileRoot] = @(
  (E '\AppData' $D), (E '\Downloads' $D), (E '\OneDrive - Org' ($D -bor $RP)), (E '\Junction' ($D -bor $RP) 0 'Junction'),
  (E '\Cloudish' ($D -bor $RP)), (E '\file.bin' 32 100), (E '\link.pst' ($RP -bor 32) 999 'SymbolicLink'),
  (E '\Documents' $D), (E '\Desktop' $D), (E '\NetHood' ($D -bor $RP -bor $HS) 0 'Junction'), (E '\Recent' ($D -bor $RP) 0 'Junction'), (E '\Offlineish' ($D -bor $ROO)))
 # Windows' hidden+system compatibility junction is expected; the same name without those attributes is not.
 $tree[$profileRoot + '\Documents'] = @((E '\Documents\My Music' ($D -bor $RP -bor $HS) 0 'Junction'), (E '\Documents\desktop.ini' (32 -bor $HS) 400), (E '\Documents\report.docx' 32 500))
 $tree[$profileRoot + '\Desktop'] = @((E '\Desktop\note.txt' 32 300))
 $tree[$profileRoot + '\AppData'] = @((E '\AppData\Local' $D), (E '\AppData\Roaming' $D))
 $tree[$profileRoot + '\AppData\Local'] = @((E '\AppData\Local\Temp\t.tmp' 32 10), (E '\AppData\Local\Microsoft\Outlook\a.ost' 32 1000), (E '\AppData\Local\Microsoft\Outlook\old.PST' 32 2000),
  (E '\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\c' 32 30), (E '\AppData\Local\Microsoft\Edge\User Data\Default\Cache\Cache_Data\f' 32 40),
  (E '\AppData\Local\Google\Chrome\User Data\Profile 1\Code Cache\js\f' 32 50))
 $tree[$profileRoot + '\AppData\Roaming'] = @((E '\AppData\Roaming\Microsoft\Teams\x' 32 60))
 $tree[$profileRoot + '\Downloads'] = @((E '\Downloads\setup.exe' 32 70))
 $tree[$profileRoot + '\OneDrive - Org'] = @((E '\OneDrive - Org\local.docx' ($RP -bor 32) 80), (E '\OneDrive - Org\cloud.docx' ($RP -bor $RDA) 5000), (E '\OneDrive - Org\archive.pst' ($RP -bor $RDA) 4000), (E '\OneDrive - Org\offline.docx' ($RP -bor $OFF) 6000),
  (E '\OneDrive - Org\Unpopulated' ($D -bor $RP -bor $ROO)), (E '\OneDrive - Org\Inner' ($D -bor $RP) 0 'Junction'),
  (E '\OneDrive - Org\pending.xlsx' 32 700), (E '\OneDrive - Org\desktop.ini' (32 -bor $HS) 200), (E '\OneDrive - Org\~$pending.xlsx' 32 165),
  (E '\OneDrive - Org\.849C9593-D756-4E56-8D6E-42412F2A707B' (32 -bor $HS) 0), (E '\OneDrive - Org\edited.docx' ($RP -bor 32) 90))
 $tree[$profileRoot + '\Junction'] = @((E '\Junction\outside.bin' 32 777777))
 $tree[$profileRoot + '\Cloudish'] = @((E '\Cloudish\outside.bin' 32 888888))
 $tree[$recycleRoot] = @([pscustomobject]@{FullName=($recycleRoot + '\$RABC.docx');Attributes=32;Length=90;LinkType=$null}, [pscustomobject]@{FullName=($recycleRoot + '\$RDIR');Attributes=($D -bor $RP);Length=0;LinkType='Junction'})
 $script:enumerated = @()
 $script:SmEnumerate = { param($Dir) $script:enumerated += $Dir; if (-not $tree.ContainsKey($Dir)) { throw "unexpected enumeration of $Dir" }; $tree[$Dir] }
 $script:SmScanGuard = { [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
 $s = Get-SmProfileBytes $profileRoot $recycleRoot 1000 30
 Assert ($s.Bytes.ost -eq 1000 -and $s.Bytes.pst -eq 2000 -and $s.PstFiles -eq 2) 'OST and PST measured (extension match is case-insensitive); an online-only PST still counts as a PST file'
 Assert ($s.Bytes.temp -eq 10 -and $s.Bytes.downloads -eq 70 -and $s.Bytes.teamsCache -eq 90 -and $s.Bytes.browserCache -eq 90) 'Temp, Downloads, Teams and browser caches measured'
 Assert ($s.Bytes.oneDriveHydrated -eq 1235 -and $s.Bytes.oneDriveOnlineOnly -eq 15000) 'OneDrive hydrated vs online-only split by attribute'
 Assert ($s.Bytes.recycleBin -eq 90) 'Per-SID Recycle Bin measured'
 Assert ($s.TotalBytes -eq (100+10+1000+2000+30+40+50+60+70+80+400+500+300+700+200+165+90)) "Total counts local bytes only, got $($s.TotalBytes)"
 Assert (-not ($script:enumerated -match 'Junction|Cloudish|Unpopulated|Inner|RDIR|NetHood|My Music|Recent|Offlineish')) ('Never entered a junction, a non-OneDrive reparse dir or a recall-on-open dir: ' + ($script:enumerated -join ';'))
 Assert ($s.Partial -and $s.Skipped -eq 8 -and $s.CompatLinks -eq 2) "Unexpected links and every unpopulated cloud dir make the size partial; compat junctions do not, skipped=$($s.Skipped)"
 Assert ($s.OneDriveLocal -eq 3) "Every local OneDrive file counts, placeholder or not (an edit can wait behind a tag); desktop.ini, ~`$ owner files and the sync-root marker never upload, got $($s.OneDriveLocal)"
 Assert ($s.Bytes.outsideKfm -eq 800 -and $s.OutsideKfmFiles -eq 2) "Desktop/Documents files outside OneDrive counted, desktop.ini excluded, got $($s.Bytes.outsideKfm)"
 Assert ($s.MediaFiles -eq 1) "A file in Downloads counts for the user-folder gate, got $($s.MediaFiles)"
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

# --- Offline hive reader. A minimal regf writer builds fixtures (one hbin, lf subkey lists).
# The reader was also checked key-for-key against an independent parser on real Windows hives.
function New-TestHive($Tree, [switch]$Dirty) {
 $hb = New-Object Collections.Generic.List[byte]; $hb.AddRange([byte[]](@(0x68,0x62,0x69,0x6e) + @(0) * 28))
 $alloc = { param([byte[]]$Data) $off = $hb.Count; $size = 4 + $Data.Length; $pad = (8 - $size % 8) % 8; $hb.AddRange([BitConverter]::GetBytes([int32](-($size + $pad)))); $hb.AddRange($Data); $hb.AddRange([byte[]]::new($pad)); $off }
 $put = { param([byte[]]$Buf, [int]$At, [byte[]]$Data) [Array]::Copy($Data, 0, $Buf, $At, $Data.Length) }
 $key = { param([string]$Name, $Node)
  $kids = @(foreach ($k in @($Node.Keys)) { if ($k -ne '@') { & $key $k $Node[$k] } })
  $vals = @(foreach ($n in @(if ($Node['@']) { $Node['@'].Keys })) {
   $v = $Node['@'][$n]; $nameBytes = [Text.Encoding]::ASCII.GetBytes($n); $vk = [byte[]]::new(0x14 + $nameBytes.Length)
   & $put $vk 0 ([Text.Encoding]::ASCII.GetBytes('vk')); & $put $vk 2 ([BitConverter]::GetBytes([uint16]$nameBytes.Length)); & $put $vk 0x10 ([BitConverter]::GetBytes([uint16]1)); & $put $vk 0x14 $nameBytes
   if ($v -is [int]) { & $put $vk 4 ([BitConverter]::GetBytes([uint32]2147483652)); & $put $vk 8 ([BitConverter]::GetBytes([uint32]$v)); & $put $vk 0xC ([BitConverter]::GetBytes([uint32]4)) }
   else {
    $data = [Text.Encoding]::Unicode.GetBytes("$v" + [char]0); & $put $vk 0xC ([BitConverter]::GetBytes([uint32]2))
    if ($data.Length -le 4) { & $put $vk 4 ([BitConverter]::GetBytes([uint32](2147483648 + $data.Length))); & $put $vk 8 $data }
    else { & $put $vk 4 ([BitConverter]::GetBytes([uint32]$data.Length)); & $put $vk 8 ([BitConverter]::GetBytes([uint32](& $alloc $data))) }
   }
   & $alloc $vk })
  $nameBytes = [Text.Encoding]::ASCII.GetBytes($Name); $nk = [byte[]]::new(0x4C + $nameBytes.Length)
  & $put $nk 0 ([Text.Encoding]::ASCII.GetBytes('nk')); & $put $nk 2 ([BitConverter]::GetBytes([uint16]0x20)); & $put $nk 0x48 ([BitConverter]::GetBytes([uint16]$nameBytes.Length)); & $put $nk 0x4C $nameBytes
  & $put $nk 0x1C ([BitConverter]::GetBytes([uint32]::MaxValue)); & $put $nk 0x28 ([BitConverter]::GetBytes([uint32]::MaxValue))
  if ($kids.Count) { $lf = [byte[]]::new(4 + 8 * $kids.Count); & $put $lf 0 ([Text.Encoding]::ASCII.GetBytes('lf')); & $put $lf 2 ([BitConverter]::GetBytes([uint16]$kids.Count)); for ($i = 0; $i -lt $kids.Count; $i++) { & $put $lf (4 + 8 * $i) ([BitConverter]::GetBytes([uint32]$kids[$i])) }
   & $put $nk 0x14 ([BitConverter]::GetBytes([uint32]$kids.Count)); & $put $nk 0x1C ([BitConverter]::GetBytes([uint32](& $alloc $lf))) }
  if ($vals.Count) { $vl = [byte[]]::new(4 * $vals.Count); for ($i = 0; $i -lt $vals.Count; $i++) { & $put $vl (4 * $i) ([BitConverter]::GetBytes([uint32]$vals[$i])) }
   & $put $nk 0x24 ([BitConverter]::GetBytes([uint32]$vals.Count)); & $put $nk 0x28 ([BitConverter]::GetBytes([uint32](& $alloc $vl))) }
  & $alloc $nk }
 $root = & $key 'ROOT' $Tree
 while ($hb.Count % 4096) { $hb.Add(0) }
 $base = [byte[]]::new(4096); & $put $base 0 ([Text.Encoding]::ASCII.GetBytes('regf')); & $put $base 4 ([BitConverter]::GetBytes([uint32]7)); & $put $base 8 ([BitConverter]::GetBytes([uint32]$(if ($Dirty) { 6 } else { 7 })))
 & $put $base 0x24 ([BitConverter]::GetBytes([uint32]$root)); & $put $base 0x28 ([BitConverter]::GetBytes([uint32]$hb.Count))
 [byte[]]($base + $hb.ToArray())
}
# A user hive: Shell Folders values plus OneDrive accounts (name -> UserFolder, or an [int] for a non-string value).
function New-UserHive($Folders, $Accounts) {
 $acc = [ordered]@{}; foreach ($n in @(if ($Accounts) { $Accounts.Keys })) { $acc[$n] = [ordered]@{'@'=[ordered]@{UserFolder=$Accounts[$n];LastSignInTime=5}} }
 $sw = [ordered]@{Microsoft=[ordered]@{Windows=[ordered]@{CurrentVersion=[ordered]@{Explorer=[ordered]@{'User Shell Folders'=[ordered]@{'@'=$Folders}}}}}}
 if ($null -ne $Accounts) { $sw.Microsoft.OneDrive = [ordered]@{Accounts=$acc} }
 New-TestHive ([ordered]@{AppEvents=[ordered]@{}; Software=$sw})
}
$h = New-TestHive ([ordered]@{Software=[ordered]@{Zeta=[ordered]@{}; Alpha=[ordered]@{'@'=[ordered]@{Path='C:\x\y'; Short='C'; Count=5; Empty=''}; Deep=[ordered]@{}}}})
$k = Get-SmHiveKey $h 'software\ALPHA'
Assert ($k.Values['path'] -eq 'C:\x\y' -and $k.Values['short'] -eq 'C' -and $k.Values['empty'] -eq '' -and $k.Subkeys -contains 'Deep') 'Hive key read case-insensitively; inline and cell-stored strings decoded'
Assert ($k.Values.ContainsKey('count') -and $null -eq $k.Values['count']) 'A non-string value is present but never read as a path'
Assert ((Get-SmHiveKey $h 'Software').Subkeys.Count -eq 2 -and $null -eq (Get-SmHiveKey $h 'Software\Missing') -and $null -eq (Get-SmHiveKey $h 'Software\Alpha\Deep\Nope')) 'Absent keys are $null, not an error'
Throws { Get-SmHiveKey (New-TestHive ([ordered]@{Software=[ordered]@{}}) -Dirty) 'Software' } 'dirty'
Throws { Get-SmHiveKey ([byte[]]::new(9000)) 'Software' } 'Not a registry hive'
$far = [byte[]]$h.Clone(); [Array]::Copy([BitConverter]::GetBytes([uint32]0x7FFFFFF0), 0, $far, 0x24, 4)
Throws { Get-SmHiveKey $far 'Software' } 'out of range'
$bad = [byte[]]$h.Clone(); $rootData = 4096 + [BitConverter]::ToUInt32($bad, 0x24) + 4; $bad[$rootData] = 0x78
Throws { Get-SmHiveKey $bad 'Software' } 'Malformed hive key'
# A subkey index that points back at itself is refused, not walked forever.
$cyc = [byte[]]$h.Clone(); $listOff = [BitConverter]::ToUInt32($cyc, $rootData + 0x1C); $list = 4096 + $listOff + 4
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('ri'), 0, $cyc, $list, 2); [Array]::Copy([BitConverter]::GetBytes([uint16]1), 0, $cyc, $list + 2, 2); [Array]::Copy([BitConverter]::GetBytes([uint32]$listOff), 0, $cyc, $list + 4, 4)
Throws { Get-SmHiveKey $cyc 'Software' } 'cyclic'

# --- KFM state per profile. The hive read is mocked with fixture bytes; paths are generated.
$kroot = $userRoot + '\' + (& $rand); $od = $kroot + '\OneDrive - Org'; $od2 = $kroot + '\OneDrive - Other'; $odp = $kroot + '\OneDrive'
$sizesOk = [pscustomobject]@{OneDriveLocal=0;OutsideKfmFiles=0}
function Folders($Desktop, $Documents, $Pictures) { $f = [ordered]@{'My Music'='%USERPROFILE%\Music'}; if ($null -ne $Desktop) { $f.Desktop = $Desktop }; if ($null -ne $Documents) { $f.Personal = $Documents }; if ($null -ne $Pictures) { $f['My Pictures'] = $Pictures }; $f }
function KfmOf($Folders, $Accounts, $Root = $kroot) { $script:hiveBytes = New-UserHive $Folders $Accounts; $script:SmReadHive = { param($Path, $Root) $script:hiveReads++; $script:hiveBytes }; Get-SmKfmState $Root $sizesOk }
$allIn = Folders '%USERPROFILE%\OneDrive - Org\Desktop' ($od + '\Documents') ($od.ToUpperInvariant() + '\Pictures\')
$k = KfmOf $allIn @{Business1=$od}
Assert ($k.state -eq 'verified' -and $k.redirected -eq 3 -and $k.accounts -eq 1 -and $k.localOneDriveFiles -eq 0) "All three folders inside the sync root verify (expanded, absolute, case and trailing slash): $($k | ConvertTo-Json -Compress)"
Assert ((KfmOf (Folders ($od + '\Desktop') ($od2 + '\Documents') ($odp + '\Pictures')) ([ordered]@{Business1=$od; Business2=$od2; Personal=$odp})).state -eq 'verified') 'Folders split across several OneDrive accounts verify'
$kfmCases = @(
 @('Pictures not redirected', (Folders ($od + '\Desktop') ($od + '\Documents') '%USERPROFILE%\Pictures'), @{Business1=$od}, 'notRedirected'),
 @('Pictures value missing', (Folders ($od + '\Desktop') ($od + '\Documents') $null), @{Business1=$od}, 'notRedirected'),
 @('No OneDrive account in the hive', $allIn, $null, 'notRedirected'),
 @('Account without a UserFolder', $allIn, @{Business1=''}, 'notRedirected'),
 @('Non-string UserFolder', $allIn, @{Business1=7}, 'notRedirected'),
 @('Unknown account key name', $allIn, @{Business1x=$od}, 'notRedirected'),
 @('Folder in an old, unconfigured OneDrive folder', (Folders ($od2 + '\Desktop') ($od + '\Documents') ($od + '\Pictures')), @{Business1=$od}, 'notRedirected'),
 @('Name-prefix lookalike root', (Folders ($od + '2\Desktop') ($od + '\Documents') ($od + '\Pictures')), @{Business1=$od}, 'notRedirected'),
 @('Dot-dot escape', (Folders ($od + '\..\Desktop') ($od + '\Documents') ($od + '\Pictures')), @{Business1=$od}, 'notRedirected'),
 @('Trailing-dot alias', (Folders ($od + '.\Desktop') ($od + '\Documents') ($od + '\Pictures')), @{Business1=$od}, 'notRedirected'),
 @('Unexpanded variable', (Folders '%OneDrive%\Desktop' ($od + '\Documents') ($od + '\Pictures')), @{Business1=$od}, 'notRedirected'),
 @('Folder is the sync root itself', (Folders $od ($od + '\Documents') ($od + '\Pictures')), @{Business1=$od}, 'notRedirected'),
 @('Device path form', (Folders ('\\?\' + $od + '\Desktop') ($od + '\Documents') ($od + '\Pictures')), @{Business1=$od}, 'notRedirected'),
 @('Sync root on another drive', (Folders 'D:\OneDrive - Org\Desktop' 'D:\OneDrive - Org\Documents' 'D:\OneDrive - Org\Pictures'), @{Business1='D:\OneDrive - Org'}, 'syncRootNotWalked'),
 @('Sync root nested below the profile', (Folders ($kroot + '\Sync\OneDrive\Desktop') ($kroot + '\Sync\OneDrive\Documents') ($kroot + '\Sync\OneDrive\Pictures')), @{Business1=($kroot + '\Sync\OneDrive')}, 'syncRootNotWalked'),
 @('Sync root not named OneDrive*', (Folders ($kroot + '\Cloud\Desktop') ($kroot + '\Cloud\Documents') ($kroot + '\Cloud\Pictures')), @{Business1=($kroot + '\Cloud')}, 'syncRootNotWalked')
)
foreach ($c in $kfmCases) { $got = (KfmOf $c[1] $c[2]).state; Assert ($got -eq $c[3]) "$($c[0]): expected $($c[3]), got $got" }
$guidLocal = $allIn; $guidLocal['{F42EE2D3-909F-4907-8871-4C22FC0BF756}'] = '%USERPROFILE%\Documents'
Assert ((KfmOf $guidLocal @{Business1=$od}).state -eq 'notRedirected') 'A known-folder GUID value pointing outside OneDrive overrides a redirected legacy value'
$guidIn = Folders ($od + '\Desktop') ($od + '\Documents') ($od + '\Pictures'); $guidIn['{0DDD015D-B06C-45D5-8C4C-F59713854639}'] = $od + '\Pictures'
Assert ((KfmOf $guidIn @{Business1=$od}).state -eq 'verified') 'A matching GUID value still verifies'
$script:SmReadHive = { param($Path, $Root) throw 'The process cannot access the file because it is being used by another process.' }
$k = Get-SmKfmState $kroot $sizesOk
Assert ($k.state -eq 'unknown' -and $k.error -match 'being used' -and $k.error.Length -le 80) 'Locked or unreadable hive is unknown, with the reason'
$script:SmReadHive = { param($Path, $Root) New-TestHive ([ordered]@{Software=[ordered]@{}}) -Dirty }
Assert ((Get-SmKfmState $kroot $sizesOk).state -eq 'unknown') 'Dirty hive is unknown'
$k = Get-SmKfmState $kroot $null
Assert ($null -eq $k.localOneDriveFiles -and $null -eq $k.outsideKfmFiles) 'No byte walk means upload counts are unknown, not zero'
# The real reader: one bounded read of a regular file inside the profile; links and oversize files refused.
$hroot = Join-Path ([IO.Path]::GetTempPath()) ('profile-hive-' + [guid]::NewGuid().ToString('n')); $null = New-Item -ItemType Directory -Path $hroot
try {
 $read = $packageReadHive; $bytes = New-UserHive $allIn @{Business1=$od}; $ntuser = Join-Path $hroot 'NTUSER.DAT'
 [IO.File]::WriteAllBytes($ntuser, $bytes)
 $got = & $read $ntuser $hroot
 Assert ($got.Length -eq $bytes.Length -and (Get-SmHiveKey $got 'Software\Microsoft\OneDrive\Accounts').Subkeys -contains 'Business1') 'Real reader returns the hive bytes'
 $null = New-Item -ItemType Directory -Path (Join-Path $hroot 'linked'); $null = New-Item -ItemType SymbolicLink -Path (Join-Path $hroot 'linked/NTUSER.DAT') -Target $ntuser
 Throws { & $read (Join-Path $hroot 'linked/NTUSER.DAT') (Join-Path $hroot 'linked') } 'reparse point'
 Throws { & $read (Join-Path $hroot 'absent.dat') $hroot } 'missing'
 $big = Join-Path $hroot 'big'; $null = New-Item -ItemType Directory -Path $big; $fs = [IO.File]::Create((Join-Path $big 'NTUSER.DAT')); $fs.SetLength(67108865); $fs.Dispose()
 Throws { & $read (Join-Path $big 'NTUSER.DAT') $big } '64 MB'
} finally { Remove-Item -LiteralPath $hroot -Recurse -Force }

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
$script:pending = 0
function Get-SmProfileBytes { [pscustomobject]@{TotalBytes=500;Bytes=[ordered]@{ost=0;pst=0};Partial=$false;Light=$false;EntriesVisited=1;PstFiles=0;OneDriveLocal=$script:pending;OutsideKfmFiles=0;MediaFiles=0} }
$script:hiveReads = 0; $script:SmReadHive = { param($Path, $Root) $script:hiveReads++; throw 'locked' }
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
Assert ($by['CORP\leaver'].decision -eq 'ReviewKfmUnknown' -and $by['CORP\leaver'].kfm.error -eq 'locked' -and $by['CORP\leaver'].ageDays -eq 200 -and $by['CORP\leaver'].profileUnloadUtc -eq $now.AddDays(-200).ToString('yyyy-MM-ddTHH:mm:ssZ')) 'Leaver on a shared device with an unreadable hive stops at the KFM gate'
Assert ($script:hiveReads -eq 8) "Hive read once per age-stale profile, got $($script:hiveReads)"
Assert ($rep.EventLog.coverageDays -eq 365 -and $rep.DeviceClass.suggested -eq 'secondary' -and $rep.DeviceClass.topSidShare -eq 0.8 -and $rep.DeviceClass.configuredShared) 'Coverage and device class reported; shared match is case-insensitive'
Assert ($rep.Summary.profiles -eq 8 -and $rep.Summary.staleByAge -eq 8 -and $rep.Summary.candidates -eq 0 -and $rep.Summary.review -eq 1) 'Summary counts'
$leaver = @($assessed[-1])
# The only path to a candidate: every gate passes, KFM verified from the hive, nothing pending.
$lroot = $userRoot + '\leaver'; $lod = $lroot + '\OneDrive - Org'
$script:SmReadHive = { param($Path, $Root) New-UserHive (Folders ($lod + '\Desktop') ($lod + '\Documents') ($lod + '\Pictures')) @{Business1=$lod} }
$r = Get-SmProfileReport $args90 $leaver (New-Context) $now $sharedPc
Assert ($r.Profiles[0].decision -eq 'StaleCandidate' -and $r.Profiles[0].kfm.state -eq 'verified' -and $r.Summary.candidates -eq 1 -and $r.Summary.candidateBytes -eq 500) 'An all-pass leaver with verified KFM is reported as a candidate'
$script:pending = 1
Assert ((Get-SmProfileReport $args90 $leaver (New-Context) $now $sharedPc).Profiles[0].decision -eq 'ReviewKfmUploadUnproven') 'A local OneDrive file keeps a verified-KFM leaver in review'
$script:pending = 0
$script:hiveReads = 0; $script:SmReadHive = { param($Path, $Root) $script:hiveReads++; throw 'locked' }
$recentProfile = New-Assessed 'S-1-5-21-9-9-9-1109' 'CORP\active' ($userRoot + '\active') 'KeepRecentProfileService'
$r = Get-SmProfileReport $args90 @($recentProfile) (New-Context) $now $sharedPc
Assert ($script:hiveReads -eq 0 -and $null -eq $r.Profiles[0].kfm -and $r.Profiles[0].decision -eq 'KeepRecentProfileService') 'A profile that is not age-stale never has its hive read'
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
function Get-SmProfileBytes { [pscustomobject]@{TotalBytes=500;Bytes=[ordered]@{ost=0;pst=0};Partial=$true;Light=$false;EntriesVisited=1;PstFiles=0;OneDriveLocal=0;OutsideKfmFiles=0;MediaFiles=0} }
Assert ((Get-SmProfileReport $args90 $leaver (New-Context) $now $sharedPc).Profiles[0].decision -eq 'ReviewPst') 'Partial size walk cannot rule out a PST'
function Test-SmProfilePath($Path) { $false }
$p = (Get-SmProfileReport $args90 $leaver (New-Context) $now $sharedPc).Profiles[0]
Assert ($p.decision -eq 'ReviewPst' -and $null -eq $p.totalBytes -and $p.sizePartial) 'Unconventional profile path is never walked'
${function:Test-SmProfilePath} = $realProfilePath; ${function:Get-SmProfileBytes} = $realBytes; $script:SmReadHive = $packageReadHive

# --- Compact JSON: schema v2, bounded for a custom field, counts survive trimming.
$many = 1..200 | ForEach-Object { [pscustomobject][ordered]@{sid="S-1-5-21-1-2-3-$_";account=('A' * 300);path=('P' * 300);totalBytes=$_;decision=$(if($_ -eq 7){'ReviewKfmUnknown'}else{'Protected'});reason=('R' * 300);ageDecision='StaleCandidate'} }
$report = [pscustomobject]@{Mode='Report';Status='complete';Timestamp='2026-11-20T00:00:00Z';ReportPath='C:\ProgramData\RelianMaintenance\Storage\x.json';Before=@(@{DeviceID='C:';Size=256;FreeSpace=20});Errors=@();
 ProfileReport=[pscustomobject]@{EventLog=@{coverageDays=10};DeviceClass=@{suggested='shared'};Profiles=$many;Summary=[ordered]@{profiles=200;review=1};Errors=@()}}
$json = ConvertTo-SmProfileReportJson $report
$doc = $json | ConvertFrom-Json
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 9500) 'Custom-field JSON stays under the byte cap'
Assert ($doc.schemaVersion -eq 2 -and $doc.truncated -and $doc.summary.profiles -eq 200 -and $doc.volumes[0].freeBytes -eq 20) 'Schema v2 keeps counts and volumes when profiles are trimmed'
Assert ($doc.profiles[0].decision -eq 'ReviewKfmUnknown' -and $doc.profiles.Count -le 100) 'Review entries rank first; more than 100 entries can never fit'
# Detail is dropped before entries: lowest-ranked entries go slim first, and nothing is cut mid-structure.
$kfmDetail = [ordered]@{state='verified';redirected=3;accounts=1;localOneDriveFiles=0;outsideKfmFiles=0;error=$null}
$some = 1..30 | ForEach-Object { [pscustomobject][ordered]@{sid="S-1-5-21-1-2-3-$_";account="CORP\u$_";path="$userRoot\u$_";totalBytes=1000+$_;bytes=[ordered]@{ost=1;pst=0;oneDriveHydrated=2;oneDriveOnlineOnly=3;teamsCache=4;browserCache=5;temp=6;downloads=7;recycleBin=8;outsideKfm=9};kfm=$kfmDetail;decision=$(if($_ -le 2){'StaleCandidate'}else{'ReviewKfmUploadUnproven'});reason=('R' * 100);ageDecision='StaleCandidate'} }
$report.ProfileReport.Profiles = $some; $report.ProfileReport.Summary = [ordered]@{profiles=30}
$json = ConvertTo-SmProfileReportJson $report; $doc = $json | ConvertFrom-Json
$full = @($doc.profiles | Where-Object { $_.kfm }); $slim = @($doc.profiles | Where-Object { -not $_.kfm })
Assert ([Text.Encoding]::UTF8.GetByteCount($json) -le 9500 -and $doc.truncated -and $doc.profiles.Count -eq 30) "All 30 entries kept by slimming, size $([Text.Encoding]::UTF8.GetByteCount($json))"
Assert ($full.Count -ge 2 -and $slim.Count -ge 1 -and $doc.profiles[0].decision -eq 'StaleCandidate' -and $doc.profiles[0].kfm.state -eq 'verified' -and -not $doc.profiles[-1].kfm) 'Candidates keep their detail; the tail is slimmed first'
Assert (@($slim | Where-Object { -not $_.sid -or -not $_.decision }).Count -eq 0 -and @($doc.profiles | Select-Object -First $full.Count | Where-Object { -not $_.kfm }).Count -eq 0) 'Slim entries keep sid and decision; full entries form an unbroken prefix'

# --- HARD RULE: the report path deletes nothing and changes no setting.
# 1. Static: no report function names a mutating command or a removal hook.
$reportFunctions = @('Get-SmProfileBytes','Get-SmReportContext','Get-SmReportDecision','Get-SmProfileReport','ConvertTo-SmProfileReportJson','Get-SmHiveKey','Test-SmUnderPath','Get-SmKfmState')
$reportAsts = @(foreach ($fn in $reportFunctions) { ,@($fn, (Get-Command $fn).ScriptBlock.Ast) }) + @(,@('SmReadHive', $packageReadHive.Ast))
foreach ($entry in $reportAsts) {
 $fn = $entry[0]; $ast = $entry[1]
 $commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
 $bad = @($commands | Where-Object { $_ -match '^(Remove|Set|New|Clear|Rename|Move|Copy|Add|Disable|Enable|Stop|Start|Restart|Invoke|Register|Unregister|Write|Out)-' -and $_ -notin @('New-Object','Write-Verbose') })
 Assert ($bad.Count -eq 0) "$fn calls mutating commands: $($bad -join ',')"
 $text = $ast.Extent.Text
 Assert ($text -notmatch 'SmDelete|SmRemoveProfile|SmComponent|SmSave|Remove-CimInstance|\.Delete\(|DeleteKey|SetValue') "$fn references a removal or write hook"
 # A hive is parsed from bytes, never loaded or mounted; cloud files are listed, never opened.
 Assert ($text -notmatch 'reg(\.exe)?\s+load|RegLoad|LoadKey|OpenRead|\]::Read(All)?Bytes') "$fn loads a hive or opens file content"
}
$readText = $packageReadHive.Ast.Extent.Text
Assert ($readText -match '\[IO\.FileAccess\]::Read,' -and $readText -match "FileShare\]'ReadWrite, Delete'" -and $readText -match 'Dispose') 'The hive file is opened read-only, shared, and closed'
# 2. Dynamic: a full run with a deletable profile and an old temp file, every removal hook counted.
$root = Join-Path ([IO.Path]::GetTempPath()) ('profile-report-run-' + [guid]::NewGuid().ToString('n'))
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
 $script:SmComponent = { $script:mutations.Add('componentCleanup'); [pscustomobject]@{Status='commandCompleted';ExitCode=0} }
 $script:SmGuards = { [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
 $script:SmScanGuard = { [pscustomobject]@{Safe=$true;Light=$false;Reasons=@()} }
 $script:SmNativeMarker={ 'absent' }
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
 $auditDir = Join-Path $root 'audit'; $null = New-Item -ItemType Directory -Path $auditDir
 $script:SmAuditDirectory = { $auditDir }
 # Control: the same fixture in Cleanup mode, with the removal plan and recheck gate forced open,
 # does reach every removal hook, so the hooks are live.
 $realPlan = $script:SmRemovalPlan; $realRecheck = $script:SmRecheckGate
 $script:SmRemovalPlan = { param($A, $Report) [pscustomobject]@{Allowed=$true;Code='Ready';Candidates=@($Report.Profiles)} }
 $script:SmRecheckGate = { [pscustomobject]@{decision='StaleCandidate';lastLogon4624Utc=$null} }
 $null = Invoke-SmMaintenance (Get-SmArguments -Mode Cleanup -RemoveProfiles true -ComponentCleanup true)
 $script:SmRemovalPlan = $realPlan; $script:SmRecheckGate = $realRecheck
 Assert (($script:mutations -match '^removeProfile').Count -eq 1 -and ($script:mutations -match '^delete').Count -ge 1 -and $script:mutations -contains 'componentCleanup') ('Control run reaches removal hooks: ' + ($script:mutations -join ';'))
 $script:mutations.Clear(); $script:collectModes = @()
 $r = Invoke-SmMaintenance (Get-SmArguments -ProfileReport true -SharedDevices $sharedPc -ProfileAgeDays 90)
 Assert ($script:mutations.Count -eq 0 -and $r.Actions.Count -eq 0 -and (Test-Path -LiteralPath $old)) ('ProfileReport run mutated: ' + ($script:mutations -join ';'))
 Assert ($script:collectModes -contains 'Report' -and $r.ProfileReport.Profiles[0].ageDecision -eq 'StaleCandidate' -and $r.ProfileReport.Profiles[0].decision -eq 'ReviewKfmUnknown') 'Report collected identity context; deletable-by-age profile without a readable hive reported as review'
 $chain = Test-SmAuditChain $auditDir
 Assert ($chain.Valid -and $r.Audit.reportHash -eq $chain.Entries[-1].hash -and $chain.Entries[-1].kind -eq 'report' -and $chain.Entries[-2].kind -eq 'decision' -and $chain.Entries[-2].decision -eq 'ReviewKfmUnknown') 'A report run records its decisions and seals them on the audit chain'
 # A full candidate is still only a report line: same run with KFM verified reaches no removal hook.
 $realKfm = ${function:Get-SmKfmState}
 function Get-SmKfmState { [pscustomobject]@{state='verified';redirected=3;accounts=1;localOneDriveFiles=0;outsideKfmFiles=0;error=$null} }
 $r = Invoke-SmMaintenance (Get-SmArguments -ProfileReport true -SharedDevices $sharedPc -ProfileAgeDays 90)
 Assert ($r.ProfileReport.Profiles[0].decision -eq 'StaleCandidate' -and $r.ProfileReport.Summary.candidates -eq 1) 'Verified KFM makes the deletable-by-age profile a reported candidate'
 Assert ($script:mutations.Count -eq 0 -and $r.Actions.Count -eq 0 -and (Test-Path -LiteralPath $old) -and (Test-Path -LiteralPath $script:Profile.LocalPath)) ('A reported candidate was acted on: ' + ($script:mutations -join ';'))
 ${function:Get-SmKfmState} = $realKfm
 # A hand-built argument set that skips Get-SmArguments still cannot reach the mutating branch.
 $hostile = Get-SmArguments -Mode Cleanup -RemoveProfiles true -ComponentCleanup true; $hostile.ProfileReport = $true; $hostile.SharedDevices = @($sharedPc); $hostile.PrimaryUserHint = ''
 $r = Invoke-SmMaintenance $hostile
 Assert ($script:mutations.Count -eq 0 -and $r.Actions.Count -eq 0 -and (Test-Path -LiteralPath $old)) ('ProfileReport with Cleanup arguments mutated: ' + ($script:mutations -join ';'))
 $script:SmSave = { param($Report) }
 $out = Complete-SmRun $r 6>$null | Select-Object -Last 1
 Assert (($out | ConvertFrom-Json).schemaVersion -eq 2) 'ProfileReport run prints the v2 JSON'
 # A ProfileReport run never reaches the dialog; a plain Report run still does.
 $script:uiCalls = New-Object Collections.Generic.List[string]
 $script:SmUi = { param($Step) $script:uiCalls.Add($Step); 'shown' }
 $r = Invoke-SmMaintenance (Get-SmArguments -ProfileReport true -SharedDevices $sharedPc -ProfileAgeDays 90)
 Assert ($script:uiCalls.Count -eq 0 -and -not $script:SmUiOpen -and ($r.Notifications -contains 'suppressed')) ('ProfileReport run reached the UI: ' + ($script:uiCalls -join ';'))
 $r = Invoke-SmMaintenance (Get-SmArguments -Mode Report)
 Assert ($script:uiCalls.Count -ge 1 -and ($r.Notifications -contains 'shown')) 'Report run without ProfileReport still shows the UI'
 $script:SmUi = { param($Step) 'noUser' }
 # Guard light at start: no profile work, but the v2 output still says why.
 $script:SmGuards = { [pscustomobject]@{Safe=$false;Light=$true;Reasons=@('Setup')} }
 $r = Invoke-SmMaintenance (Get-SmArguments -ProfileReport true)
 Assert ($script:mutations.Count -eq 0 -and $r.ProfileReport.Errors[0] -match 'not collected') 'Light guard yields an explained empty profile report'
 ${function:Test-SmProfilePath} = $realProfilePath; ${function:Test-SmSafePath} = $realSafePath
} finally { Remove-Item -LiteralPath $root -Recurse -Force }

Write-Output 'storage-maintenance profile report tests passed'
