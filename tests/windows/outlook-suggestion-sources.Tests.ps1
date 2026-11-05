$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/outlook-suggestion-sources/Invoke-OutlookSuggestionSources.ps1'
$onWindows = [IO.Path]::DirectorySeparatorChar -eq '\'

function Fail { param([string]$Message); [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label); if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label); if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }
function Assert-Throws { param([scriptblock]$Block, [string]$Label); $threw = $false; try { & $Block } catch { $threw = $true }; if (-not $threw) { Fail "$Label did not throw" } }

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

$address = 'Stale.Person@Example.invalid'
$secret = 'NEIGHBOUR-BYTES-MUST-NOT-PRINT'
$sandbox = [IO.Path]::Combine([IO.Path]::GetTempPath(), "oss-test-$([guid]::NewGuid().ToString('N'))")
$regSandbox = "Registry::HKEY_CURRENT_USER\Software\RelianOssTest-$([guid]::NewGuid().ToString('N'))"

function Join-Rel { param([string]$Base, [string]$Rel); return [IO.Path]::Combine($Base, ($Rel -replace '\\', [IO.Path]::DirectorySeparatorChar)) }
function Write-Fixture {
 param([string]$Base, [string]$Rel, [byte[]]$Bytes)
 $path = Join-Rel $Base $Rel
 $null = New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($path))
 [IO.File]::WriteAllBytes($path, $Bytes)
 return $path
}
function Get-Ascii { param([string]$Text); return [Text.Encoding]::ASCII.GetBytes($Text) }
function Get-Utf16 { param([string]$Text); return [Text.Encoding]::Unicode.GetBytes($Text) }
function New-DirLink {
 param([string]$Link, [string]$Target)
 $null = New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($Link))
 if ($onWindows) { $null = New-Item -ItemType Junction -Path $Link -Value $Target }
 else { $null = New-Item -ItemType SymbolicLink -Path $Link -Value $Target }
}
function Get-Row { param($Scan, [string]$Tail); return @($Scan.Roots | Where-Object { $_.root -like "*$Tail" })[0] }
function Invoke-Package {
 # A child process, so the exit code is the real one. The test switch must not leak into it.
 param([string[]]$PackageArgs)
 $saved = $env:RELIAN_DEPLOY_TEST
 $env:RELIAN_DEPLOY_TEST = ''
 try {
  $exe = (Get-Process -Id $PID).Path
  # Windows PowerShell wraps a child's stderr as an error record, which Stop would turn fatal.
  $ErrorActionPreference = 'Continue'
  $output = @(& $exe -NoProfile -File $scriptPath @PackageArgs 2>&1 | ForEach-Object { [string]$_ })
  return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
 } finally { $env:RELIAN_DEPLOY_TEST = $saved }
}

function Get-WriteViolations {
 # Allowlist of commands, so a writing cmdlet added later fails here without being named first.
 param([string]$Source)
 $tokens = $null; $parseErrors = $null
 $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$parseErrors)
 $bad = [System.Collections.Generic.List[string]]::new()
 foreach ($e in @($parseErrors)) { if ($e) { $bad.Add("parse: $($e.Message)") } }
 $local = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
 $allowed = @('Set-StrictMode', 'Get-ChildItem', 'Get-ItemProperty', 'Get-Process', 'Get-WinEvent', 'Get-Date', 'Write-Output', 'Select-Object', 'Sort-Object', 'Where-Object', 'ForEach-Object', 'Group-Object', 'Measure-Object', 'ConvertTo-Json')
 foreach ($c in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))) {
  $name = $c.GetCommandName()
  if ($name -and ($allowed -notcontains $name) -and ($local -notcontains $name)) { $bad.Add("command: $name") }
 }
 $badMembers = '^(Write(?!Line$).*|Create.*|Delete.*|MoveTo|CopyTo|Replace|OpenWrite|OpenOrCreate|Append.*|SetValue|SetLength|SetAccessControl|Encrypt|Decrypt|Kill|Flush)$'
 foreach ($m in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.MemberExpressionAst] }, $true))) {
  if ($m.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and $m.Member.Value -match $badMembers -and $m.Extent.Text -ne '[IO.FileShare]::Delete') { $bad.Add("member: $($m.Member.Value)") }
 }
 foreach ($t in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.TypeExpressionAst] }, $true))) {
  if ($t.TypeName.FullName -match '^(System\.)?(IO\.)?(File|Directory)$|Microsoft\.Win32|FileInfo$|StreamWriter|BinaryWriter') { $bad.Add("type: $($t.TypeName.FullName)") }
 }
 foreach ($r in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FileRedirectionAst] }, $true))) { $bad.Add("redirection: $($r.Extent.Text)") }
 foreach ($word in @('FileMode]::Create', 'FileMode]::Append', 'FileMode]::OpenOrCreate', 'FileMode]::Truncate', 'FileAccess]::Write', 'FileAccess]::ReadWrite', 'ninjarmm-cli', 'Ninja-Property', 'NTUSER', 'reg.exe')) {
  # The hive comment names NTUSER.DAT only to say it is never loaded, so comments are stripped first.
  $code = -join @($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text })
  if ($code.IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $bad.Add("word: $word") }
 }
 return @($bad.ToArray())
}

try {
 $null = New-Item -ItemType Directory -Force -Path $sandbox

 # 1. Arguments.
 $o = Get-OssOptions -Action 'Install' -Match "  $address "
 Assert-Same $o.Match $address 'Match is trimmed'
 Assert-Same $o.Hours 72 'Hours default'
 Assert-Same (Get-OssOptions -Action 'Update' -Match $address -Hours '5000').Hours 720 'Hours cap'
 Assert-Same (Get-OssOptions -Action 'Install' -Match $address -Hours '24').Hours 24 'Hours value'
 Assert-Same (Get-OssOptions -Action 'Uninstall').Mode 'none' 'Uninstall needs no Match'
 foreach ($badMatch in @('', 'nope', 'a@b', '@example.invalid', 'a b@example.invalid', 'a@example.invalid;b@example.invalid', 'p{1}@example.invalid\')) {
  Assert-Throws { Get-OssOptions -Action 'Install' -Match $badMatch } "bad Match [$badMatch]"
 }
 foreach ($badHours in @('0', '-1', 'x', '1.5', '1234567')) {
  Assert-Throws { Get-OssOptions -Action 'Install' -Match $address -Hours $badHours } "bad Hours [$badHours]"
 }

 # 2. Exit codes from a real child process.
 $run = Invoke-Package @('-Action', 'Install', '-Match', 'not-an-address')
 Assert-Same $run.Code 1 'bad Match exits 1'
 $run = Invoke-Package @('-Action', 'Install', '-Match', 'a@example.invalid', '-Hours', 'x')
 Assert-Same $run.Code 1 'bad Hours exits 1'
 $run = Invoke-Package @('-Action', 'Uninstall')
 Assert-Same $run.Code 0 'Uninstall exits 0'
 Assert-True (-not (($run.Output -join "`n") -like '*RELIAN_SOURCES_JSON*')) 'Uninstall does not scan'

 # 3. Scanner: every split point across a small buffer, in both encodings, with exact counts.
 $scanner = New-OssScanner $address
 $paddingLengths = @(0, 1, 5, 15, 16, 17, 31, 32, 33)
 $script:OssChunkBytes = 16
 foreach ($pad in $paddingLengths) {
  $padding = [string]::new([char]'x', $pad)
  $f = Write-Fixture $sandbox "split\a$pad.bin" (Get-Ascii ($padding + $address.ToUpperInvariant() + 'yy'))
  $r = Find-OssMatches -Path $f -Scanner $scanner
  Assert-Same $r.Ascii 1 "ASCII split at padding $pad"
  Assert-Same $r.Utf16 0 "no UTF-16 false hit at padding $pad"
  Assert-True $r.Complete "complete at padding $pad"
  $f = Write-Fixture $sandbox "split\u$pad.bin" (Get-Utf16 ($padding + $address.ToLowerInvariant() + 'yy'))
  $r = Find-OssMatches -Path $f -Scanner $scanner
  Assert-Same $r.Utf16 1 "UTF-16 split at padding $pad"
  Assert-Same $r.Ascii 0 "no ASCII false hit at padding $pad"
 }
 $f = Write-Fixture $sandbox 'split\many.bin' (Get-Ascii (($address + '-') * 9))
 Assert-Same (Find-OssMatches -Path $f -Scanner $scanner).Ascii 9 'no double count across carried bytes (ASCII)'
 $f = Write-Fixture $sandbox 'split\manyu.bin' (Get-Utf16 (($address + '-') * 9))
 Assert-Same (Find-OssMatches -Path $f -Scanner $scanner).Utf16 9 'no double count across carried bytes (UTF-16)'
 $script:OssChunkBytes = 1048576
 # The real chunk size, with the address straddling the first boundary.
 $big = [byte[]]::new(1048576 + 100)
 [Array]::Copy((Get-Ascii $address), 0, $big, 1048576 - 5, $address.Length)
 $f = Write-Fixture $sandbox 'split\real.bin' $big
 Assert-Same (Find-OssMatches -Path $f -Scanner $scanner).Ascii 1 'match across the real 1 MiB boundary'
 $f = Write-Fixture $sandbox 'split\none.bin' (Get-Ascii 'stale.person@example.invalie other@example.invalid')
 $r = Find-OssMatches -Path $f -Scanner $scanner
 Assert-Same ($r.Ascii + $r.Utf16) 0 'a near miss is not a hit'
 # The dot in the address is literal, not a regex wildcard.
 $f = Write-Fixture $sandbox 'split\dot.bin' (Get-Ascii 'staleXperson@example.invalid')
 Assert-Same (Find-OssMatches -Path $f -Scanner $scanner).Ascii 0 'dot is literal'

 # 4. A profile tree.
 $users = Join-Path $sandbox 'Users'
 $alice = Join-Path $users 'alice'
 $outside = Join-Path $sandbox 'outside'
 $null = Write-Fixture $outside 'target\linked.dat' (Get-Ascii "$secret$address$secret")
 $hitAscii = "$secret $address $secret"
 $null = Write-Fixture $alice 'AppData\Local\Microsoft\Outlook\RoamCache\Stream_Autocomplete_0.dat' (Get-Utf16 $hitAscii)
 $null = Write-Fixture $alice 'AppData\Local\Microsoft\Outlook\RoamCache\Stream_Other.dat' (Get-Ascii 'clean')
 $null = Write-Fixture $alice 'AppData\Local\Microsoft\Outlook\plain.nk2' (Get-Ascii $hitAscii.ToUpperInvariant())
 $null = Write-Fixture $alice 'AppData\Local\Microsoft\Outlook\mailbox.ost' (Get-Ascii $hitAscii)
 $null = Write-Fixture $alice 'AppData\Local\Microsoft\Outlook\archive.nst' (Get-Ascii $hitAscii)
 $null = Write-Fixture $alice 'AppData\Roaming\Microsoft\Outlook\signature.xml' (Get-Ascii 'clean')
 $null = Write-Fixture $alice 'AppData\Local\Microsoft\Olk\cache.json' (Get-Ascii $hitAscii)
 $null = Write-Fixture $alice 'AppData\Local\Microsoft\Edge\User Data\Default\IndexedDB\https_outlook.indexeddb.leveldb\000.log' (Get-Utf16 $hitAscii)
 $null = Write-Fixture $alice 'AppData\Local\Microsoft\Edge\User Data\Crashpad\metadata' (Get-Ascii $hitAscii)
 $null = Write-Fixture $alice 'AppData\Local\Google\Chrome\User Data\Profile 1\Service Worker\CacheStorage\abc\0' (Get-Ascii $hitAscii)
 $null = Write-Fixture $alice 'AppData\Roaming\Mozilla\Firefox\Profiles\x.default\storage\default\https+++outlook.office.com\idb\1.sqlite' (Get-Ascii $hitAscii)
 $null = Write-Fixture $alice 'AppData\Roaming\Mozilla\Firefox\Profiles\x.default\storage\default\https+++other.example\idb\1.sqlite' (Get-Ascii $hitAscii)
 $null = Write-Fixture $alice 'Documents\Outlook Files\old.pst' (Get-Ascii 'x')
 $null = Write-Fixture $alice 'Documents\a\b\deep.PST' (Get-Ascii 'x')
 $null = Write-Fixture $alice 'Documents\a\b\c\d\e\f\g\h\toodeep.pst' (Get-Ascii 'x')
 # Reparse points must not be followed: inside a root, and at a parent of a root.
 New-DirLink (Join-Rel $alice 'AppData\Local\Microsoft\Outlook\linkeddir') (Join-Path $outside 'target')
 New-DirLink (Join-Rel $alice 'Documents\linkeddir') (Join-Path $outside 'target')
 New-DirLink (Join-Rel $alice 'AppData\Local\Microsoft\Office') (Join-Path $outside 'target')
 # Oversize and locked.
 $null = Write-Fixture $alice 'AppData\Roaming\Microsoft\Outlook\oversize.bin' (Get-Ascii ("$hitAscii" + ('z' * 1000)))
 $lockedPath = Write-Fixture $alice 'AppData\Roaming\Microsoft\Outlook\locked.bin' (Get-Ascii $hitAscii)
 # Excluded and reparse profiles.
 $null = Write-Fixture $users 'Default\AppData\Local\Microsoft\Olk\x.bin' (Get-Ascii $hitAscii)
 $null = Write-Fixture $users 'defaultuser0\AppData\Local\Microsoft\Olk\x.bin' (Get-Ascii $hitAscii)
 $null = Write-Fixture $users 'Public\AppData\Local\Microsoft\Olk\x.bin' (Get-Ascii $hitAscii)
 $null = Write-Fixture $outside 'prof\AppData\Local\Microsoft\Olk\x.bin' (Get-Ascii $hitAscii)
 New-DirLink (Join-Path $users 'linkedprofile') (Join-Path $outside 'prof')

 $script:OssUsersRoot = $users
 $profs = @(Get-OssProfiles)
 Assert-Same (@($profs | ForEach-Object { $_.Name } | Sort-Object) -join ',') 'alice,linkedprofile' 'profile list skips default and public'
 Assert-True (@($profs | Where-Object { $_.Name -eq 'linkedprofile' })[0].Reparse) 'a linked profile is marked as reparse'

 # 5. Scan with oversize and locked present.
 $saved = $script:OssMaxFileBytes
 $script:OssMaxFileBytes = 300
 $holder = [IO.FileStream]::new($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
 try { $scan = Invoke-OssScan -Profiles @($profs | Where-Object { -not $_.Reparse }) -Address $address }
 finally { $holder.Dispose(); $script:OssMaxFileBytes = $saved }
 $hitPaths = @($scan.Hits | ForEach-Object { $_.path -replace '[\\/]', '\' })
 foreach ($expected in @(
   'AppData\Local\Microsoft\Outlook\RoamCache\Stream_Autocomplete_0.dat',
   'AppData\Local\Microsoft\Outlook\plain.nk2',
   'AppData\Local\Microsoft\Olk\cache.json',
   'AppData\Local\Microsoft\Edge\User Data\Default\IndexedDB\https_outlook.indexeddb.leveldb\000.log',
   'AppData\Local\Google\Chrome\User Data\Profile 1\Service Worker\CacheStorage\abc\0',
   'AppData\Roaming\Mozilla\Firefox\Profiles\x.default\storage\default\https+++outlook.office.com\idb\1.sqlite')) {
  Assert-True ($hitPaths -contains $expected) "hit found: $expected"
 }
 Assert-Same $hitPaths.Count 6 'no hit from a store, a non-Outlook Firefox site, a browser non-profile folder, or a reparse point'
 $utf = @($scan.Hits | Where-Object { $_.path -like '*Stream_Autocomplete_0.dat' })[0]
 Assert-Same $utf.utf16Hits 1 'UTF-16 hit counted'
 Assert-Same $utf.asciiHits 0 'UTF-16 hit is not an ASCII hit'
 Assert-Same @($scan.Hits | Where-Object { $_.path -like '*plain.nk2' })[0].asciiHits 1 'upper-case ASCII hit counted'
 Assert-True (@($scan.Hits | Where-Object { $_.path -like '*plain.nk2' })[0].lastWriteUtc -match 'Z$') 'lastWrite is UTC'
 Assert-Same $scan.Summary.filesLocked 1 'locked file is counted'
 Assert-Same @($scan.Locked).Count 1 'locked file is listed'
 Assert-Same $scan.Summary.filesSkippedTooLarge 1 'oversize file is counted'
 Assert-Same $scan.Summary.storeFilesSkipped 2 'OST and NST skips are recorded'
 Assert-True (-not $scan.Summary.timedOut) 'no timeout'
 Assert-Same (Get-Row $scan 'AppData\Local\Microsoft\Office\16.0').status 'reparse' 'junction at a parent of a root is refused'
 Assert-True ((Get-Row $scan 'AppData\Local\Microsoft\Outlook').reparseSkipped -ge 1) 'junction inside a root is counted'
 Assert-Same (Get-Row $scan 'INetCache\Content.Outlook').status 'missing' 'missing root is visible'
 Assert-Same (Get-Row $scan 'User Data\Default\Local Storage').status 'missing' 'missing browser subfolder is visible'
 Assert-Same (Get-Row $scan 'User Data\Default\IndexedDB').filesFound 1 'per-root count'
 Assert-Same @($scan.Roots | Where-Object { $_.root -like '*Crashpad*' }).Count 0 'a browser non-profile folder is not a root'
 $firefoxRow = Get-Row $scan 'https+++outlook.office.com'
 Assert-Same $firefoxRow.hitFiles 1 'Firefox Outlook site scanned'

 # 6. Caps.
 $safe = @($profs | Where-Object { -not $_.Reparse })
 $script:OssMaxFiles = 2
 $capped = Invoke-OssScan -Profiles $safe -Address $address
 $script:OssMaxFiles = 5000
 Assert-True $capped.Summary.fileCapReached 'file cap reported'
 Assert-Same ($capped.Summary.filesScanned + $capped.Summary.filesLocked) 2 'file cap stops at the cap'
 Assert-True (@($capped.Roots | Where-Object { $_.status -eq 'notReached' }).Count -gt 0) 'roots past the cap are visible'
 Assert-Same @($capped.Roots | Where-Object { $_.root -like '*Edge*' -and $_.status -eq 'scanned' }).Count 0 'browser roots wait behind Outlook roots'

 $script:OssMaxSeconds = 0
 $late = Invoke-OssScan -Profiles $safe -Address $address
 $script:OssMaxSeconds = 150
 Assert-True $late.Summary.timedOut 'timeout reported'
 Assert-Same $late.Summary.filesScanned 0 'nothing scanned after the deadline'

 foreach ($n in 1..4) { $null = Write-Fixture $alice "AppData\Local\Microsoft\Windows\INetCache\Content.Outlook\ABC\f$n.tmp" (Get-Ascii $hitAscii) }
 $small = Invoke-OssScan -Profiles $safe -Address $address
 Assert-Same (Get-Row $small 'INetCache\Content.Outlook').hitFiles 4 'Content.Outlook scanned when small'
 $script:OssHugeFiles = 3
 $huge = Invoke-OssScan -Profiles $safe -Address $address
 $script:OssHugeFiles = 2000
 Assert-Same (Get-Row $huge 'INetCache\Content.Outlook').status 'skippedHuge' 'Content.Outlook skipped by file count'
 $script:OssHugeBytes = 10
 $huge = Invoke-OssScan -Profiles $safe -Address $address
 $script:OssHugeBytes = 536870912
 Assert-Same (Get-Row $huge 'INetCache\Content.Outlook').status 'skippedHuge' 'Content.Outlook skipped by size'
 Assert-Same (Get-Row $huge 'INetCache\Content.Outlook').hitFiles 0 'a skipped root is not scanned'

 if (-not $onWindows) {
  # A folder that cannot be listed must be visible, or 0 hits would read as proof of absence. Windows has no chmod, and SYSTEM reads anyway.
  $noRead = Join-Rel $alice 'AppData\Roaming\Microsoft\Outlook\noread'
  $null = New-Item -ItemType Directory -Force -Path $noRead
  & chmod 000 $noRead
  $denied = Invoke-OssScan -Profiles $safe -Address $address
  & chmod 755 $noRead
  Assert-Same (Get-Row $denied 'AppData\Roaming\Microsoft\Outlook').dirErrors 1 'an unreadable folder is counted'
  Assert-Same $denied.Summary.dirErrors 1 'unreadable folders are in the totals'
 }

 # 7. Inventory.
 $inv = Get-OssInventory $safe
 $storePaths = @($inv.Stores | ForEach-Object { $_.path -replace '[\\/]', '\' })
 foreach ($expected in @('AppData\Local\Microsoft\Outlook\mailbox.ost', 'Documents\Outlook Files\old.pst', 'Documents\a\b\deep.PST')) {
  Assert-True ($storePaths -contains $expected) "inventory has $expected"
 }
 Assert-Same @($storePaths | Where-Object { $_ -eq 'Documents\Outlook Files\old.pst' }).Count 1 'a file under two inventory roots is listed once'
 Assert-Same @($storePaths | Where-Object { $_ -like '*toodeep*' }).Count 0 'Documents depth is bounded'
 $documents = @($inv.Roots | Where-Object { $_.root -eq 'Documents' })[0]
 Assert-True $documents.truncated 'Documents depth truncation is visible'
 Assert-Same (@($inv.RoamCache | ForEach-Object { $_.name } | Sort-Object) -join ',') 'Stream_Autocomplete_0.dat,Stream_Other.dat' 'RoamCache lists every file'
 $wide = Get-OssWalk -Root (Join-Rel $alice 'Documents') -MaxEntries 1
 Assert-True $wide.Truncated 'walk entry cap is visible'

 # 8. Hive config, through the same reader hooks the real provider uses.
 $u = { param([string]$T) ,[byte[]][Text.Encoding]::Unicode.GetBytes($T + [char]0) }
 $base = 'HIVE\Software\Microsoft\Office\16.0\Outlook'
 $acct = "$base\Profiles\Main\9375CFF0413111d3B88A00104B2A6676"
 $fakeValues = @{
  $base = @{ DefaultProfile = 'Main' }
  "$base\Preferences" = @{ ShowAutoSug = 1; UseNewOutlook = 0 }
  'HIVE\Software\Policies\Microsoft\Office\16.0\Outlook\Preferences' = @{ ShowAutoSug = 0 }
  "$acct\00000001" = @{ 'Account Name' = (& $u 'Work Mail'); Email = (& $u 'work@example.invalid') }
  "$acct\00000002" = @{ 'Account Name' = (& $u 'Extra Mail'); Email = (& $u 'extra@example.invalid') }
  "$acct\00000003" = @{ NoIdentity = 1 }
  "$base\Profiles\Main\aaa" = @{ '001f6700' = (& $u 'C:\Elsewhere\attached.pst'); '001f3001' = (& $u 'Shared Team Mailbox') }
  "$base\Profiles\Main\aaa\deep" = @{ '001f6610' = (& $u 'C:\Elsewhere\cached.ost') }
  "$base\Profiles\Main\bbb" = @{ '001f6700' = (& $u 'C:\Elsewhere\attached.pst') }
 }
 $fakeKeys = @{
  "$base\Profiles" = @('Main', 'Spare')
  "$base\Profiles\Main" = @('9375CFF0413111d3B88A00104B2A6676', 'aaa', 'bbb')
  $acct = @('00000001', '00000002', '00000003')
  "$base\Profiles\Main\aaa" = @('deep')
 }
 $realValues = $script:OssRegValues; $realKeys = $script:OssRegSubKeys; $realHives = $script:OssGetHives; $realEvents = $script:OssGetEvents; $realProcs = $script:OssGetProcesses
 $script:OssRegValues = { param($Path) if ($fakeValues.ContainsKey($Path)) { $fakeValues[$Path] } else { @{} } }
 $script:OssRegSubKeys = { param($Path) if ($fakeKeys.ContainsKey($Path)) { @($fakeKeys[$Path]) } else { @() } }
 $script:OssGetHives = { [pscustomobject]@{ Sid = 'S-1-12-1-1-2-3-4'; Account = 'AzureAD\alice'; ProfileName = 'alice'; Root = 'HIVE' } }
 $cfg = Get-OssHiveConfig (& $script:OssGetHives)
 Assert-Same $cfg.defaultProfile 'Main' 'default profile'
 Assert-Same ($cfg.outlookProfiles -join ',') 'Main,Spare' 'profile names'
 Assert-Same @($cfg.Accounts).Count 2 'accounts decoded, an account with no identity dropped'
 Assert-Same @($cfg.Accounts)[1].email 'extra@example.invalid' 'UTF-16 account email decoded with no trailing NUL'
 Assert-Same @($cfg.Accounts)[0].accountName 'Work Mail' 'UTF-16 account name decoded'
 Assert-Same ($cfg.stores -join ',') 'C:\Elsewhere\attached.pst,C:\Elsewhere\cached.ost' 'stores decoded, deduplicated, from any depth'
 Assert-Same ($cfg.displayNames -join ',') 'Shared Team Mailbox' 'section display names'
 Assert-Same $cfg.showAutoSug 1 'ShowAutoSug'
 Assert-Same $cfg.showAutoSugPolicy 0 'ShowAutoSug policy'
 Assert-Same $cfg.useNewOutlook 0 'UseNewOutlook'
 $script:OssMaxRegKeys = 1
 Assert-True (Get-OssHiveConfig (& $script:OssGetHives)).keysTruncated 'registry walk is bounded'
 $script:OssMaxRegKeys = 5000

 # 9. Events and processes.
 $when = [datetime]'2026-01-02T03:04:05Z'
 $eventMessage = "$secret outlook event body"
 $script:OssGetEvents = {
  param([hashtable]$Filter, [int]$Max)
  if ($Filter.ProviderName -eq 'Outlook') {
   @([pscustomobject]@{ Id = 27; TimeCreated = $when; Message = $eventMessage }, [pscustomobject]@{ Id = 27; TimeCreated = $when.AddHours(1); Message = $eventMessage }, [pscustomobject]@{ Id = 63; TimeCreated = $when; Message = $eventMessage })
  } else {
   @([pscustomobject]@{ Id = 1000; TimeCreated = $when; Message = "Faulting application name: OUTLOOK.EXE $secret" }, [pscustomobject]@{ Id = 1002; TimeCreated = $when; Message = 'The program other.exe stopped' })
  }
 }
 $ev = Get-OssEventSummary -Hours 72
 Assert-Same @($ev.outlook).Count 2 'Outlook events grouped by id'
 Assert-Same @($ev.outlook)[0].count 2 'event id count'
 Assert-Same @($ev.outlook)[0].latestUtc (Format-OssUtc $when.AddHours(1)) 'event id latest time'
 Assert-Same @($ev.crashes).Count 1 'only OUTLOOK.EXE faults are kept'
 Assert-Same @($ev.crashes)[0].id 1000 'fault id'
 Assert-Same (@($ev.crashes)[0].PSObject.Properties.Name -join ',') 'id,timeUtc' 'a fault row has time and id only'

 $script:OssGetProcesses = {
  @([pscustomobject]@{ ProcessName = 'OUTLOOK'; StartTime = $when.AddHours(2); SessionId = 3 }, [pscustomobject]@{ ProcessName = 'OUTLOOK'; StartTime = $when; SessionId = 1 }, [pscustomobject]@{ ProcessName = 'msedge'; StartTime = $when; SessionId = 3 })
 }
 $procs = @(Get-OssProcessSummary)
 Assert-Same $procs.Count 5 'every watched process name is reported, running or not'
 Assert-Same $procs[0].count 2 'process count'
 Assert-Same $procs[0].earliestStartUtc (Format-OssUtc $when) 'earliest start'
 Assert-Same (@($procs[0].sessionIds) -join ',') '1,3' 'session ids'
 Assert-Same @($procs | Where-Object { $_.name -eq 'firefox' })[0].count 0 'a stopped process counts 0'

 # 10. A whole run: nothing matched or neighbouring reaches the output.
 $report = Invoke-OssRun -Address $address -Hours 72
 $text = @(Format-OssText $report) -join "`n"
 $line = ConvertTo-OssJsonLine $report
 $everything = "$text`n$line"
 $utf16Printable = [Text.Encoding]::Unicode.GetString((Get-Ascii $address))
 foreach ($forbidden in @($address, $address.ToLowerInvariant(), $secret, $utf16Printable)) {
  Assert-True ($everything.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'matched text or neighbouring bytes reached the output'
 }
 foreach ($expected in @('=== Processes ===', '=== Files with hits ===', 'plain.nk2', 'work@example.invalid', 'attached.pst', 'old.pst', 'Stream_Other.dat', 'LevelDB/Snappy', 'OUTLOOK.EXE fault id=1000')) {
  Assert-True ($text.IndexOf($expected, [StringComparison]::Ordinal) -ge 0) "text block has $expected"
 }
 Assert-True ($line.StartsWith('RELIAN_SOURCES_JSON: {')) 'JSON prefix'
 Assert-True ([Text.Encoding]::UTF8.GetByteCount($line) -le 8000) 'JSON line within budget'
 $parsed = $line.Substring('RELIAN_SOURCES_JSON: '.Length) | ConvertFrom-Json
 Assert-True ($parsed.limits -like '*LevelDB/Snappy*') 'limits note in JSON'
 Assert-True (@($parsed.hits).Count -gt 0) 'hits in JSON'
 Assert-Same @($parsed.accounts).Count 2 'accounts in JSON'
 Assert-Same @($parsed.accounts)[1].email 'extra@example.invalid' 'account email in JSON'
 Assert-Same ($text.TrimEnd() -split "`n")[0] '=== Outlook suggestion sources v1 ===' 'text comes first'

 # 11. JSON budget: a huge hit list, then huge everything.
 $manyHits = @(foreach ($n in 1..4000) { [pscustomobject]@{ profile = 'alice'; path = ('AppData\Local\Microsoft\Edge\User Data\Default\IndexedDB\' + ('d' * 150) + "\$n.log"); sizeBytes = 123456; lastWriteUtc = '2026-01-02T03:04:05Z'; asciiHits = 1; utf16Hits = 2; partial = $false } })
 $bloated = [ordered]@{}
 foreach ($k in @($report.Keys)) { $bloated[$k] = $report[$k] }
 $bloated['hits'] = $manyHits
 $bloated['hitFilesTotal'] = $manyHits.Count
 $bloated['roamCache'] = @(foreach ($n in 1..500) { [pscustomobject]@{ profile = 'alice'; name = "Stream_$n.dat"; sizeBytes = 1; lastWriteUtc = '2026-01-02T03:04:05Z' } })
 $huge = ConvertTo-OssJsonLine $bloated
 Assert-True ([Text.Encoding]::UTF8.GetByteCount($huge) -le 8000) 'JSON under 8000 bytes with a huge hit list'
 $hugeParsed = $huge.Substring('RELIAN_SOURCES_JSON: '.Length) | ConvertFrom-Json
 Assert-True $hugeParsed.truncated 'truncated flag set'
 Assert-True (@($hugeParsed.hits).Count -ge 10) 'hit files kept under pressure'
 Assert-Same $hugeParsed.hitFilesTotal 4000 'total hit files kept'
 Assert-Same ($hugeParsed.hitFilesOmitted + @($hugeParsed.hits).Count) 4000 'omitted count is honest'
 Assert-Same @($hugeParsed.accounts).Count 2 'accounts kept under pressure'
 Assert-True (@($hugeParsed.droppedSections) -contains 'roamCache') 'dropped sections are named'
 Assert-True (@($hugeParsed.hits)[0].path -like '*.log') 'a shortened path keeps its file name'
 $manyAccounts = @(foreach ($n in 1..500) { [pscustomobject]@{ sid = 'S-1-12-1-1-2-3-4'; outlookProfile = 'Main'; accountName = "Account $n"; email = "user$n@example.invalid" } })
 $bloated['accounts'] = $manyAccounts
 $both = ConvertTo-OssJsonLine $bloated
 Assert-True ([Text.Encoding]::UTF8.GetByteCount($both) -le 8000) 'JSON under 8000 bytes with huge hits and accounts'
 $bothParsed = $both.Substring('RELIAN_SOURCES_JSON: '.Length) | ConvertFrom-Json
 Assert-True (@($bothParsed.hits).Count -gt 0 -and @($bothParsed.accounts).Count -gt 0) 'both lists keep entries'
 Assert-Same ($bothParsed.accountsOmitted + @($bothParsed.accounts).Count) 500 'omitted account count is honest'
 # Text stays complete whatever the JSON dropped.
 $fullText = @(Format-OssText $bloated) -join "`n"
 Assert-True ($fullText.IndexOf('\4000.log') -ge 0) 'text block keeps every hit file'

 # 12. Partial failures do not stop the run.
 $script:OssGetHives = { throw 'hive boom' }
 $script:OssGetEvents = { throw 'event boom' }
 $script:OssGetProcesses = { throw 'process boom' }
 $partial = Invoke-OssRun -Address $address -Hours 72
 Assert-Same @($partial.errors).Count 3 'each failed section is recorded'
 Assert-True (@($partial.hits).Count -gt 0) 'the scan survives other failed sections'
 $partialText = @(Format-OssText $partial) -join "`n"
 Assert-True ($partialText -like '*Partial failures*') 'failures are printed'
 Assert-True ((ConvertTo-OssJsonLine $partial).StartsWith('RELIAN_SOURCES_JSON: ')) 'JSON still printed'
 $script:OssRegValues = $realValues; $script:OssRegSubKeys = $realKeys; $script:OssGetHives = $realHives; $script:OssGetEvents = $realEvents; $script:OssGetProcesses = $realProcs

 # 13. Source: read-only by construction. The checker itself must catch each kind of write.
 $source = [IO.File]::ReadAllText($scriptPath)
 $violations = @(Get-WriteViolations $source)
 Assert-Same ($violations -join '; ') '' 'package source has no writing call'
 foreach ($snippet in @(
   'Set-Content -Path x -Value y', 'Out-File x', 'New-Item x', 'Remove-Item x', 'Stop-Process -Name x', 'Add-Type -TypeDefinition x', 'Set-ItemProperty x y z',
   '[IO.File]::ReadAllBytes("x")', '[IO.File]::WriteAllBytes("x", $b)', '$s.Write($b, 0, 1)', '$k.SetValue("a", 1)', '$d.CreateSubdirectory("x")', '$f.MoveTo("x")',
   '"x" > y', '"x" >> y', '[IO.FileStream]::new("x", [IO.FileMode]::Create)', '[IO.FileStream]::new("x", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)', 'ninjarmm-cli set x y', 'Ninja-Property-Set x y',
   '[Microsoft.Win32.Registry]::SetValue("a", "b", 1)', 'Invoke-Expression "x"', '[IO.StreamWriter]::new("x")', '$f.Delete()', 'Start-Process x')) {
  Assert-True (@(Get-WriteViolations $snippet).Count -gt 0) "checker misses: $snippet"
 }
 Assert-True ($source -match '\[IO\.FileShare\]::ReadWrite -bor \[IO\.FileShare\]::Delete') 'files open with shared read, write and delete'
 Assert-True ($source -notmatch 'Mandatory') 'no Mandatory parameter'
 foreach ($need in @('[string]$DeploymentType', '[string]$Action', '[string]$PinVersion', "[string]`$Match = ''", "[string]`$Hours = ''")) {
  Assert-True ($source.IndexOf($need, [StringComparison]::Ordinal) -ge 0) "param block lacks $need"
 }
 Assert-True (@([Text.Encoding]::UTF8.GetBytes($source) | Where-Object { $_ -gt 127 }).Count -eq 0) 'source is ASCII, so Windows PowerShell 5.1 reads it the same'

 # 14. Release metadata and the runner's PackageArguments round trip.
 $release = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows/releases/outlook-suggestion-sources.json') | ConvertFrom-Json
 Assert-Same $release.installsSoftware $false 'release installs nothing'
 Set-StrictMode -Off
 . (Join-Path $repoRoot 'windows/runner/Invoke-RelianRunner.ps1')
 Set-StrictMode -Version Latest
 $sampleJson = '{"Match":"personal.stale@example.invalid","Hours":"168"}'
 $pairs = ConvertFrom-RelianPackageArguments -PackageArguments ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sampleJson)))
 Assert-Same $pairs.Count 2 'runner decodes both arguments'
 Assert-Same $pairs[0].Name 'Match' 'first argument name'
 Assert-Same $pairs[0].Value 'personal.stale@example.invalid' 'first argument value'
 Assert-Same $pairs[1].Name 'Hours' 'second argument name'
 Assert-Same $pairs[1].Value '168' 'second argument value'
 Assert-True ($release.packageArguments -like '*eyJNYXRjaCI6InBlcnNvbmFsLnN0YWxlQGV4YW1wbGUuaW52YWxpZCJ9*') 'release documents the base64 sample'

 # 15. Native Windows only: the real registry provider against a throwaway key, and a real end-to-end run.
 if ($onWindows) {
  $hiveRoot = $regSandbox
  $outlookKey = "$hiveRoot\Software\Microsoft\Office\16.0\Outlook"
  $acctKey = "$outlookKey\Profiles\Main\9375CFF0413111d3B88A00104B2A6676\00000001"
  $sectionKey = "$outlookKey\Profiles\Main\section"
  $null = New-Item -Path $acctKey -Force
  $null = New-Item -Path $sectionKey -Force
  $null = New-Item -Path "$outlookKey\Preferences" -Force
  $null = New-ItemProperty -LiteralPath $outlookKey -Name 'DefaultProfile' -Value 'Main'
  $null = New-ItemProperty -LiteralPath $acctKey -Name 'Email' -PropertyType Binary -Value (& $u 'native@example.invalid')
  $null = New-ItemProperty -LiteralPath $sectionKey -Name '001f6700' -PropertyType Binary -Value (& $u 'C:\Native\attached.pst')
  $null = New-ItemProperty -LiteralPath "$outlookKey\Preferences" -Name 'ShowAutoSug' -PropertyType DWord -Value 1
  $native = Get-OssHiveConfig ([pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-4'; Account = 'test'; ProfileName = 'test'; Root = $hiveRoot })
  Assert-Same @($native.Accounts)[0].email 'native@example.invalid' 'real registry binary email'
  Assert-Same ($native.stores -join ',') 'C:\Native\attached.pst' 'real registry store path'
  Assert-Same $native.defaultProfile 'Main' 'real registry default profile'
  Assert-Same $native.showAutoSug 1 'real registry DWORD'
  $emptyEvents = & $script:OssGetEvents @{ LogName = 'Application'; ProviderName = 'RelianOssNoSuchProvider'; StartTime = (Get-Date) } 1
  Assert-Same @($emptyEvents).Count 0 'an unknown provider is an empty answer'
 }
 # End to end. On Linux there is no registry or event log, so this also proves those failures stay partial.
 $e2e = Invoke-Package @('-Action', 'Install', '-Match', 'absent.oss.check@example.invalid', '-Hours', '1')
 Assert-Same $e2e.Code 0 'a completed run exits 0'
 $last = $e2e.Output[-1]
 Assert-True ($last.StartsWith('RELIAN_SOURCES_JSON: ')) 'the JSON line is last'
 Assert-True ([Text.Encoding]::UTF8.GetByteCount($last) -le 8000) 'end-to-end JSON within budget'
 $e2eParsed = $last.Substring('RELIAN_SOURCES_JSON: '.Length) | ConvertFrom-Json
 Assert-Same $e2eParsed.hitFilesTotal 0 'end-to-end run finds nothing for an absent address'
 Assert-True ((($e2e.Output -join "`n").IndexOf('absent.oss.check') -lt 0)) 'end-to-end output never echoes Match'
} finally {
 $script:OssClock = $null
 Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
 if ($onWindows) { Remove-Item -LiteralPath $regSandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output 'outlook-suggestion-sources tests passed'
exit 0
