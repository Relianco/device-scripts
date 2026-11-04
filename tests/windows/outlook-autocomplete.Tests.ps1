$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/outlook-autocomplete/Invoke-OutlookAutocomplete.ps1'

function Fail { param([string]$Message); [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label); if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label); if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }
function Assert-Like { param([string]$Actual, [string]$Pattern, [string]$Label); if ($Actual -notlike $Pattern) { Fail "$Label was [$Actual] expected like [$Pattern]" } }

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

function New-TestProp {
 param([uint16]$Id, [uint16]$Type, $Val)
 $b = [System.Collections.Generic.List[byte]]::new()
 $b.AddRange([BitConverter]::GetBytes([uint32](([uint32]$Id -shl 16) -bor [uint32]$Type)))
 $b.AddRange([BitConverter]::GetBytes([uint32]0))
 if ($Type -eq 0x0003) {
  $b.AddRange([BitConverter]::GetBytes([uint32]$Val))
  $b.AddRange([BitConverter]::GetBytes([uint32]0))
 } elseif ($Type -eq 0x001F) {
  $b.AddRange([BitConverter]::GetBytes([uint64]0))
  $bytes = [Text.Encoding]::Unicode.GetBytes([string]$Val + [char]0)
  $b.AddRange([BitConverter]::GetBytes([uint32]$bytes.Length)); $b.AddRange($bytes)
 } elseif ($Type -eq 0x001E) {
  $b.AddRange([BitConverter]::GetBytes([uint64]0))
  $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Val + [char]0)
  $b.AddRange([BitConverter]::GetBytes([uint32]$bytes.Length)); $b.AddRange($bytes)
 } elseif ($Type -eq 0x0102) {
  $b.AddRange([BitConverter]::GetBytes([uint64]0))
  $bytes = [byte[]]$Val
  $b.AddRange([BitConverter]::GetBytes([uint32]$bytes.Length)); $b.AddRange($bytes)
 } elseif ($Type -eq 0x101F) {
  $b.AddRange([BitConverter]::GetBytes([uint64]0))
  $arr = [string[]]$Val
  $b.AddRange([BitConverter]::GetBytes([uint32]$arr.Count))
  foreach ($v in $arr) {
   $bytes = [Text.Encoding]::Unicode.GetBytes($v + [char]0)
   $b.AddRange([BitConverter]::GetBytes([uint32]$bytes.Length)); $b.AddRange($bytes)
  }
 }
 return ,$b.ToArray()
}

function New-TestRow {
 param([byte[][]]$Props)
 $b = [System.Collections.Generic.List[byte]]::new()
 $b.AddRange([BitConverter]::GetBytes([uint32]$Props.Count))
 foreach ($p in $Props) { $b.AddRange([byte[]]$p) }
 return ,$b.ToArray()
}

function New-TestStream {
 param([byte[][]]$Rows, [byte[]]$ExtraInfo = @([byte]0xAA, [byte]0xBB, [byte]0xCC, [byte]0xDD))
 $b = [System.Collections.Generic.List[byte]]::new()
 $b.AddRange([BitConverter]::GetBytes([uint32]12))
 $b.AddRange([BitConverter]::GetBytes([uint32]14))
 $b.AddRange([BitConverter]::GetBytes([uint32]0))
 $b.AddRange([BitConverter]::GetBytes([uint32]$Rows.Count))
 foreach ($r in $Rows) { $b.AddRange([byte[]]$r) }
 $b.AddRange([BitConverter]::GetBytes([uint32]$ExtraInfo.Length))
 if ($ExtraInfo.Length -gt 0) { $b.AddRange($ExtraInfo) }
 $b.AddRange([BitConverter]::GetBytes([uint32]0x11223344))
 $b.AddRange([BitConverter]::GetBytes([uint32]0x55667788))
 return ,$b.ToArray()
}

$rowWork = New-TestRow @(
 (New-TestProp 0x3001 0x001F 'Targets Work'),
 (New-TestProp 0x3003 0x001F 'target.work@example.invalid'),
 (New-TestProp 0x0FFF 0x0102 ([byte[]]@(1, 2, 3, 4, 5))),
 (New-TestProp 0x6001 0x0003 42)
)
$rowPersonal = New-TestRow @(
 (New-TestProp 0x3001 0x001F 'Targets Personal'),
 (New-TestProp 0x39FE 0x001E 'personal.stale@example.invalid'),
 (New-TestProp 0x0FF6 0x0102 ([byte[]]@(9, 8, 7)))
)
$rowColleague = New-TestRow @(
 (New-TestProp 0x3001 0x001F 'Colleague User'),
 (New-TestProp 0x8000 0x101F @('colleague@example.invalid', 'alias@example.invalid')),
 (New-TestProp 0x6001 0x0003 7)
)

$streamBytes = New-TestStream -Rows @($rowWork, $rowPersonal, $rowColleague)

# 1. Binary parser accurately parses rows, properties, trailer, and case-insensitive match.
$parsed = Read-OaStream -Bytes $streamBytes -Match 'PERSONAL.STALE@example.invalid'
Assert-True $parsed.validFormat 'valid stream parsed'
Assert-Same $parsed.rowCount 3 '3 rows parsed'
Assert-Same $parsed.matchedRowCount 1 '1 row matched'
Assert-Same $parsed.rows[0].Matched $false 'row 0 not matched'
Assert-Same $parsed.rows[1].Matched $true 'row 1 matched'
Assert-Same $parsed.rows[2].Matched $false 'row 2 not matched'

# 2. Surgical row removal preserves header, non-matching rows, and trailer byte-for-byte.
$filteredBytes = Remove-OaStreamMatchedRows -Bytes $streamBytes -Parsed $parsed
$expectedBytes = New-TestStream -Rows @($rowWork, $rowColleague)
Assert-Same $filteredBytes.Length $expectedBytes.Length 'filtered stream byte length matches'
Assert-Same ([Convert]::ToBase64String($filteredBytes)) ([Convert]::ToBase64String($expectedBytes)) 'filtered stream bytes match'

$reparsed = Read-OaStream -Bytes $filteredBytes -Match 'personal.stale@example.invalid'
Assert-True $reparsed.validFormat 'reparsed stream is valid'
Assert-Same $reparsed.rowCount 2 'reparsed stream has 2 rows'
Assert-Same $reparsed.matchedRowCount 0 'reparsed stream has 0 matches'
Assert-Same (Read-OaStream -Bytes $filteredBytes -Match 'alias@example.invalid').matchedRowCount 1 'multi-string property preserved'

$singleRowStream = New-TestStream -Rows @(,$rowPersonal)
$zeroRowBytes = Remove-OaStreamMatchedRows -Bytes $singleRowStream -Parsed (Read-OaStream -Bytes $singleRowStream -Match 'personal.stale@example.invalid')
$parsedZero = Read-OaStream -Bytes $zeroRowBytes -Match 'personal.stale@example.invalid'
Assert-True $parsedZero.validFormat '0-row filtered stream is valid'
Assert-Same $parsedZero.rowCount 0 '0-row filtered stream has 0 rows'

# 3. Corrupt / truncated / malformed streams fail safely with validFormat = $false.
Assert-Same (Read-OaStream -Bytes ([byte[]]@(1, 2, 3)) -Match 'test@example.invalid').validFormat $false 'short stream rejected'
Assert-Same (Read-OaStream -Bytes ([byte[]]($streamBytes + @([byte]0xFF))) -Match 'test@example.invalid').validFormat $false 'trailing byte rejected'
Assert-Same (Read-OaStream -Bytes ([byte[]]$streamBytes[0..($streamBytes.Length - 5)]) -Match 'test@example.invalid').validFormat $false 'truncated stream rejected'

$badUtf16Row = [System.Collections.Generic.List[byte]]::new()
$badUtf16Row.AddRange([BitConverter]::GetBytes([uint32]1))
$badUtf16Row.AddRange([BitConverter]::GetBytes([uint32]0x3001001F))
$badUtf16Row.AddRange([BitConverter]::GetBytes([uint32]0))
$badUtf16Row.AddRange([BitConverter]::GetBytes([uint64]0))
$badUtf16Row.AddRange([BitConverter]::GetBytes([uint32]3))
$badUtf16Row.AddRange([byte[]]@(65, 0, 66))
Assert-Same (Read-OaStream -Bytes (New-TestStream -Rows @(,$badUtf16Row.ToArray())) -Match 'A').validFormat $false 'odd UTF-16 byte length rejected'

$overflowRow = [System.Collections.Generic.List[byte]]::new()
$overflowRow.AddRange([BitConverter]::GetBytes([uint32]1))
$overflowRow.AddRange([BitConverter]::GetBytes([uint32]0x3001001F))
$overflowRow.AddRange([BitConverter]::GetBytes([uint32]0))
$overflowRow.AddRange([BitConverter]::GetBytes([uint64]0))
$overflowRow.AddRange([BitConverter]::GetBytes([uint32]::MaxValue))
Assert-Same (Read-OaStream -Bytes (New-TestStream -Rows @(,$overflowRow.ToArray())) -Match 'A').validFormat $false 'uint32 MaxValue rejected without overflow'

# 4. End-to-end check and fix modes in a temporary filesystem fixture.
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('oa-test-' + [guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory -Path $tmpRoot -Force
try {
 $usersRoot = Join-Path $tmpRoot 'Users'; $backupRoot = Join-Path $tmpRoot 'Backups'
 $null = New-Item -ItemType Directory -Path $usersRoot -Force
 $prof1 = Join-Path $usersRoot 'userone'
 $roam1 = Join-Path $prof1 'AppData/Local/Microsoft/Outlook/RoamCache'
 $null = New-Item -ItemType Directory -Path $roam1 -Force
 $dat1 = Join-Path $roam1 'Stream_Autocomplete_0_11111111111111111111111111111111.dat'
 $dat2 = Join-Path $roam1 'Stream_Autocomplete_0_22222222222222222222222222222222.dat'
 [IO.File]::WriteAllBytes($dat1, $streamBytes)
 $cleanBytes = New-TestStream -Rows @($rowWork, $rowColleague)
 [IO.File]::WriteAllBytes($dat2, $cleanBytes)

 $prof2 = Join-Path $usersRoot 'usertwo'
 $null = New-Item -ItemType Directory -Path $prof2 -Force

 $script:OaBackupRoot = $backupRoot
 $script:OaGetProfiles = {
  @([pscustomobject]@{ Name = 'userone'; Path = $prof1; Root = $usersRoot }, [pscustomobject]@{ Name = 'usertwo'; Path = $prof2; Root = $usersRoot })
 }
 $script:OaGetOutlookProcesses = { @() }
 $script:stopCalled = 0
 $script:OaStopOutlookProcesses = { $script:stopCalled++ }

 # 4a. Check mode: reports match, writes no backup, modifies no file, does not leak non-matching email addresses.
 $checkRun = Invoke-OaRun -Match 'personal.stale@example.invalid'
 Assert-Same $checkRun.exitCode 0 'check mode exitCode 0'
 Assert-Same $checkRun.record.mode 'check' 'check mode label'
 Assert-Same $checkRun.record.matchedFiles 1 'check mode matched 1 file'
 Assert-Same $checkRun.record.matchedRows 1 'check mode matched 1 row'
 Assert-Same $checkRun.record.removedRows 0 'check mode removed 0 rows'
 Assert-Same (Test-Path -LiteralPath $backupRoot) $false 'check mode created no backup'
 Assert-Same ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dat1))) ([Convert]::ToBase64String($streamBytes)) 'check mode left dat1 untouched'
 $checkJson = ConvertTo-BoundedOaJson -Record $checkRun.record
 Assert-True ($checkJson.IndexOf('target.work@example.invalid', [StringComparison]::OrdinalIgnoreCase) -lt 0) 'non-matching email not leaked'
 Assert-True ($checkJson.IndexOf('colleague@example.invalid', [StringComparison]::OrdinalIgnoreCase) -lt 0) 'colleague email not leaked'

 # 4b. Fix mode when OUTLOOK.EXE is running and CloseOutlook is false: refuses before touching files.
 $script:OaGetOutlookProcesses = { @([pscustomobject]@{ Id = 4444; ProcessName = 'OUTLOOK' }) }
 $blockedRun = Invoke-OaRun -Match 'personal.stale@example.invalid' -Fix
 Assert-Same $blockedRun.exitCode 1 'fix blocked when Outlook is running without CloseOutlook'
 Assert-Like $blockedRun.record.verdict '*Outlook is running*' 'verdict states Outlook is running'
 Assert-Same ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dat1))) ([Convert]::ToBase64String($streamBytes)) 'blocked fix left dat1 untouched'
 Assert-Same $script:stopCalled 0 'Outlook not stopped when CloseOutlook is false'

 # 4c. Fix mode when OUTLOOK.EXE refuses to close: exits 1 before touching files.
 $stillRunningRun = Invoke-OaRun -Match 'personal.stale@example.invalid' -Fix -CloseOutlook
 Assert-Same $stillRunningRun.exitCode 1 'fix fails if Outlook still running'
 Assert-Same $script:stopCalled 1 'stop called once'
 Assert-Same ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dat1))) ([Convert]::ToBase64String($streamBytes)) 'dat1 untouched when Outlook failed to stop'

 # 4d. Fix mode when CloseOutlook stops Outlook: backs up dat1, removes the matched row, leaves dat2 untouched.
 $script:outlookAlive = $true
 $script:OaGetOutlookProcesses = { if ($script:outlookAlive) { return @([pscustomobject]@{ Id = 4444; ProcessName = 'OUTLOOK' }) }; return @() }
 $script:OaStopOutlookProcesses = { $script:stopCalled++; $script:outlookAlive = $false }
 $fixRun = Invoke-OaRun -Match 'personal.stale@example.invalid' -Fix -CloseOutlook
 Assert-Same $fixRun.exitCode 0 'fix mode exitCode 0'
 Assert-Same $fixRun.record.mode 'fix' 'fix mode label'
 Assert-Same $fixRun.record.matchedFiles 1 'fix mode matched 1 file'
 Assert-Same $fixRun.record.modifiedFiles 1 'fix mode modified 1 file'
 Assert-Same $fixRun.record.removedRows 1 'fix mode removed 1 row'
 Assert-True $fixRun.record.outlookClosed 'fix mode recorded outlookClosed'
 Assert-Same ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dat1))) ([Convert]::ToBase64String($expectedBytes)) 'dat1 updated to 2-row stream'
 Assert-Same ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dat2))) ([Convert]::ToBase64String($cleanBytes)) 'dat2 untouched'
 $backups = @(Get-ChildItem -LiteralPath $backupRoot -Recurse -Filter '*.dat' -File)
 Assert-Same $backups.Count 1 '1 backup dat file written'
 Assert-Same ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backups[0].FullName))) ([Convert]::ToBase64String($streamBytes)) 'backup matches original stream'

 # 4e. Second run is a clean no-op.
 $secondRun = Invoke-OaRun -Match 'personal.stale@example.invalid' -Fix
 Assert-Same $secondRun.exitCode 0 'second run exitCode 0'
 Assert-Same $secondRun.record.matchedRows 0 'second run matched 0 rows'
 Assert-Same $secondRun.record.modifiedFiles 0 'second run modified 0 files'
 Assert-Like $secondRun.record.verdict 'nothing to do*' 'second run verdict'

 # 4f. Failed backup aborts before modifying the stream file.
 [IO.File]::WriteAllBytes($dat1, $streamBytes)
 $realBackup = $script:OaBackupFile
 $script:OaBackupFile = { param($SourcePath, $BackupDir, $Prefix) throw 'disk full' }
 try {
  $failBackupRun = Invoke-OaRun -Match 'personal.stale@example.invalid' -Fix
  Assert-Same $failBackupRun.exitCode 1 'failed backup exits 1'
  Assert-Same ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dat1))) ([Convert]::ToBase64String($streamBytes)) 'failed backup leaves dat1 unmodified'
 } finally { $script:OaBackupFile = $realBackup }

 # 4g. Corrupt stream file is flagged as an error and exits 1 without modifying it.
 $corruptBytes = [byte[]]@(0x0C, 0x00, 0x00, 0x00, 0xFF, 0xFF)
 [IO.File]::WriteAllBytes($dat1, $corruptBytes)
 $corruptRun = Invoke-OaRun -Match 'personal.stale@example.invalid' -Fix
 Assert-Same $corruptRun.exitCode 1 'corrupt file exits 1'
 Assert-Same ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dat1))) ([Convert]::ToBase64String($corruptBytes)) 'corrupt file left untouched'
 [IO.File]::WriteAllBytes($dat1, $expectedBytes)

 # 4h. Symlink / reparse point inside RoamCache is refused and exits 1.
 $outsideFile = Join-Path $tmpRoot 'outside.dat'
 [IO.File]::WriteAllBytes($outsideFile, $streamBytes)
 $symlinkDat = Join-Path $roam1 'Stream_Autocomplete_0_99999999999999999999999999999999.dat'
 $null = New-Item -ItemType SymbolicLink -Path $symlinkDat -Target $outsideFile
 Assert-Same (Test-OaSafePath -Path $symlinkDat -Root $roam1) $false 'symlink dat rejected by Test-OaSafePath'
 $reparseRun = Invoke-OaRun -Match 'personal.stale@example.invalid' -Fix
 Assert-Same $reparseRun.exitCode 1 'reparse dat file causes exitCode 1'
 Assert-Same ([Convert]::ToBase64String([IO.File]::ReadAllBytes($outsideFile))) ([Convert]::ToBase64String($streamBytes)) 'outside symlink target untouched'
} finally {
 Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# 5. Parameter & mode validation.
foreach ($a in @('Install', 'Update', 'Repair', 'Reinstall')) {
 Assert-Same (Get-OaOptions -Action $a -Match 'user@example.invalid' -Fix '' -CloseOutlook '').Mode 'check' "$a default is check"
 Assert-Same (Get-OaOptions -Action $a -Match 'user@example.invalid' -Fix 'false' -CloseOutlook 'false').Mode 'check' "$a Fix false is check"
 $m3 = Get-OaOptions -Action $a -Match 'user@example.invalid' -Fix 'true' -CloseOutlook 'true'
 Assert-Same $m3.Mode 'fix' "$a Fix true is fix"
 Assert-Same $m3.CloseOutlook $true "$a CloseOutlook parsed"
}
Assert-Same (Get-OaOptions -Action 'Uninstall' -Match '' -Fix 'true' -CloseOutlook 'true').Mode 'none' 'Uninstall ignores Fix'

foreach ($bad in @(
 @('Bogus', 'user@example.invalid', '', ''), @('', 'user@example.invalid', '', ''),
 @('Install', 'user@example.invalid', 'yes', ''), @('Install', 'user@example.invalid', '1', ''),
 @('Install', 'user@example.invalid', '', 'yes'), @('Install', '', 'true', ''),
 @('Install', 'ab', 'true', ''), @('Install', "bad`nmatch", 'false', '')
)) {
 $threw = $false
 try { $null = Get-OaOptions -Action $bad[0] -Match $bad[1] -Fix $bad[2] -CloseOutlook $bad[3] } catch { $threw = $true }
 if (-not $threw) { Fail "Get-OaOptions accepted invalid tuple [$($bad -join '|')]" }
}

# 6. Bounded JSON output stays <= 8000 UTF-8 bytes even with many files/errors.
$bigRecord = [ordered]@{
 version = '1.0'; timestamp = '2026-11-04T00:00:00Z'; mode = 'check'; match = 'user@example.invalid'; verdict = 'checked'
 files = @(1..80 | ForEach-Object { [ordered]@{ profile = "user$_"; fileName = "Stream_Autocomplete_0_$('_' * 32).dat"; sizeBytes = 4096; validFormat = $true; rowCount = 20; matchedRowCount = 0; removedRowCount = 0 } })
 errors = @(1..50 | ForEach-Object { "error detail $_ " + ('x' * 120) })
}
$boundedJson = ConvertTo-BoundedOaJson -Record $bigRecord
Assert-True ([Text.Encoding]::UTF8.GetByteCount($boundedJson) -le 8000) 'bounded JSON stays within 8000 UTF-8 bytes'
$parsedBounded = $boundedJson | ConvertFrom-Json
Assert-True ([bool]$parsedBounded.truncated) 'bounded JSON sets truncated = true'
Assert-Same $parsedBounded.verdict 'checked' 'bounded JSON preserves verdict'

# 7. Entry param block and forbidden commands check.
$source = [IO.File]::ReadAllText($scriptPath)
foreach ($need in @('[string]$DeploymentType', '[string]$Action', '[string]$PinVersion', "[string]`$Match = ''", "[string]`$Fix = ''", "[string]`$CloseOutlook = ''")) {
 if ($source.IndexOf($need, [StringComparison]::Ordinal) -lt 0) { Fail "param block lacks $need" }
}
foreach ($bad in @('Restart-Computer', 'shutdown', 'setup.exe', 'Set-Service', 'Start-Service', 'Invoke-WebRequest', 'Invoke-RestMethod')) {
 if ($source.IndexOf($bad, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Fail "source contains forbidden token $bad" }
}

# 8. Release metadata and runner PackageArguments round-trip.
$release = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows/releases/outlook-autocomplete.json') | ConvertFrom-Json
Assert-Same $release.installsSoftware $false 'pin record installsSoftware is false'
Assert-Same $release.ninjaField 'relianOutlookAutocomplete' 'pin record ninjaField matches'
Assert-Same $OaFieldName $release.ninjaField 'script field name matches release JSON'

Set-StrictMode -Off
. (Join-Path $repoRoot 'windows/runner/Invoke-RelianRunner.ps1')
Set-StrictMode -Version Latest
$sampleJson = '{"Match":"personal.stale@example.invalid","Fix":"true","CloseOutlook":"true"}'
$sampleB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sampleJson))
$pairs = ConvertFrom-RelianPackageArguments -PackageArguments $sampleB64
Assert-Same $pairs.Count 3 'runner decoded 3 package argument pairs'
Assert-Same $pairs[0].Name 'Match' 'pair 0 name'
Assert-Same $pairs[0].Value 'personal.stale@example.invalid' 'pair 0 value'
Assert-Same $pairs[1].Name 'Fix' 'pair 1 name'
Assert-Same $pairs[1].Value 'true' 'pair 1 value'
Assert-Same $pairs[2].Name 'CloseOutlook' 'pair 2 name'
Assert-Same $pairs[2].Value 'true' 'pair 2 value'

# 9. Ensure exit 0 appears only at the very end of this test file.
$self = [IO.File]::ReadAllText($PSCommandPath) -replace "`r`n", "`n"
$firstExit = $self.IndexOf("exit 0`n", [StringComparison]::Ordinal)
if ($firstExit -lt 0 -or $firstExit -lt $self.IndexOf('Assert-Same $pairs[2].Value', [StringComparison]::Ordinal)) {
 Fail 'exit 0 comes before the last assertion'
}

Write-Output 'outlook-autocomplete tests passed'
exit 0
