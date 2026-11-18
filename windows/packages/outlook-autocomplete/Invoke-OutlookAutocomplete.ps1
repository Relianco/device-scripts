# Classic Outlook RoamCache Stream_Autocomplete_*.dat [MS-OXOCFG] 2.2.5.1 check and surgical row removal.
[CmdletBinding()]
param(
 [string]$DeploymentType,
 [string]$Action,
 [string]$PinVersion,
 [string]$Match = '',
 [string]$Fix = '',
 [string]$CloseOutlook = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$oaProgramData = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
$script:OaBackupRoot = "$oaProgramData\Relian\OutlookAutocomplete"
$OaMaxStreamBytes = 67108864

function Get-OaString8Encoding {
 try { [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance) } catch { }
 $cp = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
 if ($cp -le 0) { $cp = 1252 }
 return [Text.Encoding]::GetEncoding($cp)
}
$script:OaString8Encoding = Get-OaString8Encoding

function Write-Status {
 param([string]$Message, [string]$Level = 'INFO')
 Write-Host "[$( (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') )] [$Level] [outlook-autocomplete] $Message"
}

function Limit-OaText {
 param([string]$Text, [int]$MaxLength = 160)
 if ($null -eq $Text) { return $null }
 $clean = ($Text -replace '\s+', ' ').Trim()
 if ($clean.Length -le $MaxLength) { return $clean }
 return $clean.Substring(0, $MaxLength)
}

function Test-OaSafePath {
 param([string]$Path, [string]$Root, [switch]$AllowRoot)
 try {
  if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
  if ($Path.IndexOfAny([char[]]'*?[]') -ge 0) { return $false }
  if ($Path -match '(^\\\\|:)+' -and $Path -notmatch '^[A-Za-z]:\\') { return $false }
  $sep = [IO.Path]::DirectorySeparatorChar
  $r = [IO.Path]::GetFullPath($Root).TrimEnd($sep)
  $p = [IO.Path]::GetFullPath($Path)
  if ($AllowRoot -and $p.TrimEnd($sep).Equals($r, [StringComparison]::OrdinalIgnoreCase)) {
  } elseif (-not $p.StartsWith($r + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $false }
  $badAttrs = [int64](1024 -bor 4096 -bor 262144 -bor 4194304)
  $cur = $p
  while ($cur) {
   $item = Get-Item -LiteralPath $cur -Force -ErrorAction Stop
   if (([int64]$item.Attributes -band $badAttrs) -ne 0) { return $false }
   $parent = [IO.Path]::GetDirectoryName($cur)
   if (-not $parent -or $parent -eq $cur) { break }
   $cur = $parent
  }
  return $true
 } catch { return $false }
}

function Get-OaOptions {
 param([string]$Action, [string]$Match = '', [string]$Fix = '', [string]$CloseOutlook = '')
 if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) {
  throw 'Action must be Install, Update, Repair, Reinstall, or Uninstall.'
 }
 if ($Action -eq 'Uninstall') {
  return [ordered]@{ Mode = 'none'; Match = ''; Fix = $false; CloseOutlook = $false }
 }
 if (@('', 'false', 'true') -notcontains $Fix) { throw 'Fix must be true or false.' }
 if (@('', 'false', 'true') -notcontains $CloseOutlook) { throw 'CloseOutlook must be true or false.' }
 if ($null -ne $Match -and $Match -match '[\x00-\x1F\x7F]') { throw 'Match must not contain control characters.' }
 $trimmed = if ($null -eq $Match) { '' } else { $Match.Trim() }
 if ($trimmed.Length -gt 256) { throw 'Match must not exceed 256 characters.' }
 $isFix = ($Fix -eq 'true')
 if ($isFix -and $trimmed.Length -lt 3) {
  throw 'Fix mode requires Match to be at least 3 non-whitespace characters.'
 }
 return [ordered]@{ Mode = $(if ($isFix) { 'fix' } else { 'check' }); Match = $trimmed; Fix = $isFix; CloseOutlook = ($CloseOutlook -eq 'true') }
}

function Read-OaStream {
 param([byte[]]$Bytes, [string]$Match = '')
 $fail = {
  param([string]$Reason)
  return [ordered]@{
   validFormat = $false; parseError = $Reason; majorVersion = $null; minorVersion = $null
   rowCount = 0; matchedRowCount = 0; rows = @(); trailerOffset = 0; trailerLength = 0
  }
 }
 if ($null -eq $Bytes -or $Bytes.Length -lt 28) { return (& $fail 'stream shorter than 28-byte minimum') }
 $totalLen = [int64]$Bytes.Length
 $needle = if ([string]::IsNullOrWhiteSpace($Match)) { '' } else { $Match.Trim() }
 $majorVer = [uint32][BitConverter]::ToUInt32($Bytes, 4)
 $minorVer = [uint32][BitConverter]::ToUInt32($Bytes, 8)
 $numRows = [uint32][BitConverter]::ToUInt32($Bytes, 12)
 if ($majorVer -lt 1 -or $majorVer -gt 32) { return (& $fail "unsupported majorVersion $majorVer") }
 if ($numRows -gt 100000) { return (& $fail "rowCount $numRows exceeds 100000 limit") }

 $offset = [int64]16
 $rows = [System.Collections.Generic.List[object]]::new()
 $matchedCount = 0

 for ($r = [int64]0; $r -lt $numRows; $r++) {
  $rowStart = $offset
  if (($offset + 4) -gt $totalLen) { return (& $fail "row $r truncated at NumProps") }
  $numProps = [uint32][BitConverter]::ToUInt32($Bytes, [int]$offset)
  $offset += 4
  if ($numProps -gt 1000) { return (& $fail "row $r NumProps $numProps exceeds 1000 limit") }

  $rowMatched = $false
  for ($p = [int64]0; $p -lt $numProps; $p++) {
   if (($offset + 16) -gt $totalLen) { return (& $fail "row $r prop $p truncated at header") }
   $propTag = [uint32][BitConverter]::ToUInt32($Bytes, [int]$offset)
   $propType = [int]($propTag -band 0xFFFF)
   $offset += 16

   if ($propType -in @(0x0000, 0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0006, 0x0007, 0x000A, 0x000B, 0x0014, 0x0040)) {
    continue
   }
   $count = [int64]1
   if ($propType -in @(0x101E, 0x101F, 0x1102)) {
    if (($offset + 4) -gt $totalLen) { return (& $fail "row $r prop $p truncated at mvCount") }
    $count = [int64][BitConverter]::ToUInt32($Bytes, [int]$offset)
    $offset += 4
    if ($count -lt 0 -or $count -gt 10000) { return (& $fail "row $r prop $p mvCount $count exceeds 10000") }
   } elseif ($propType -notin @(0x001E, 0x001F, 0x0102, 0x0048)) {
    return (& $fail ("row $r prop $p unsupported property type 0x{0:X4}" -f $propType))
   }
   $baseType = $propType -band 0x0FFF
   for ($m = [int64]0; $m -lt $count; $m++) {
    if (($offset + 4) -gt $totalLen) { return (& $fail "row $r prop $p item $m truncated at length") }
    $valLen = [int64][BitConverter]::ToUInt32($Bytes, [int]$offset)
    $offset += 4
    if ($valLen -lt 0 -or ($offset + $valLen) -gt $totalLen) { return (& $fail "row $r prop $p item $m length $valLen out of bounds") }
    if ($baseType -eq 0x001F) {
     if (($valLen % 2) -ne 0) { return (& $fail "row $r prop $p item $m UTF-16 length $valLen is odd") }
     if ($needle.Length -gt 0 -and -not $rowMatched -and $valLen -gt 0) {
      $str = [Text.Encoding]::Unicode.GetString($Bytes, [int]$offset, [int]$valLen).TrimEnd([char]0)
      if ($str.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $rowMatched = $true }
     }
    } elseif ($baseType -eq 0x001E -and $needle.Length -gt 0 -and -not $rowMatched -and $valLen -gt 0) {
     $str = $script:OaString8Encoding.GetString($Bytes, [int]$offset, [int]$valLen).TrimEnd([char]0)
     if ($str.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $rowMatched = $true }
    }
    $offset += $valLen
   }
  }
  if ($rowMatched) { $matchedCount++ }
  $rows.Add([pscustomobject]@{ Index = [int]$r; StartOffset = [int]$rowStart; Length = [int]($offset - $rowStart); Matched = [bool]$rowMatched })
 }

 $trailerStart = $offset
 if (($offset + 12) -gt $totalLen) { return (& $fail 'stream truncated before 12-byte trailer') }
 $extraLen = [int64][BitConverter]::ToUInt32($Bytes, [int]$offset)
 if (($offset + 4 + $extraLen + 8) -ne $totalLen) {
  return (& $fail "trailer length mismatch: expected $($offset + 4 + $extraLen + 8), actual $totalLen")
 }
 return [ordered]@{
  validFormat = $true; parseError = $null; majorVersion = [int]$majorVer; minorVersion = [int]$minorVer
  rowCount = [int]$numRows; matchedRowCount = [int]$matchedCount; rows = @($rows.ToArray())
  trailerOffset = [int]$trailerStart; trailerLength = [int]($totalLen - $trailerStart)
 }
}

function Remove-OaStreamMatchedRows {
 param([byte[]]$Bytes, $Parsed)
 if ($null -eq $Bytes -or $null -eq $Parsed -or -not $Parsed.validFormat) { throw 'Cannot filter an invalid autocomplete stream.' }
 $keptRows = @($Parsed.rows | Where-Object { -not $_.Matched })
 $keptBytesLen = [int64]0
 foreach ($kr in $keptRows) { $keptBytesLen += [int64]$kr.Length }
 $out = New-Object byte[] ([int](16 + $keptBytesLen + [int64]$Parsed.trailerLength))
 [Array]::Copy($Bytes, 0, $out, 0, 16)
 [Array]::Copy([BitConverter]::GetBytes([uint32]$keptRows.Count), 0, $out, 12, 4)
 $pos = 16
 foreach ($kr in $keptRows) {
  if ($kr.Length -gt 0) { [Array]::Copy($Bytes, [int]$kr.StartOffset, $out, $pos, [int]$kr.Length); $pos += [int]$kr.Length }
 }
 if ($Parsed.trailerLength -gt 0) { [Array]::Copy($Bytes, [int]$Parsed.trailerOffset, $out, $pos, [int]$Parsed.trailerLength) }
 return ,$out
}

$script:OaGetProfiles = {
 $usersRoot = if ($env:SystemDrive) { "$($env:SystemDrive)\Users" } else { 'C:\Users' }
 if (-not (Test-Path -LiteralPath $usersRoot)) { return @() }
 $excluded = @('Public', 'Default', 'Default User', 'All Users', 'Administrator')
 $seen = @{}; $list = [System.Collections.Generic.List[object]]::new()
 foreach ($dir in @(Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction Stop)) {
  if ($excluded -contains $dir.Name -or $dir.Name -like 'defaultuser*') { continue }
  $full = [IO.Path]::GetFullPath($dir.FullName)
  if (-not $seen.ContainsKey($full)) {
   $seen[$full] = $true
   $list.Add([pscustomobject]@{ Name = $dir.Name; Path = $full; Root = $usersRoot })
  }
 }
 return @($list.ToArray())
}

$script:OaGetOutlookProcesses = { @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue) }

$script:OaStopOutlookProcesses = {
 foreach ($p in @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)) {
  try { if ($p.MainWindowHandle -ne 0) { $null = $p.CloseMainWindow() } } catch { }
 }
 $deadline = [DateTime]::UtcNow.AddSeconds(5)
 while ([DateTime]::UtcNow -lt $deadline) {
  if (@(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue).Count -eq 0) { return }
  Start-Sleep -Milliseconds 250
 }
 foreach ($p in @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)) {
  try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
 }
 $forceDeadline = [DateTime]::UtcNow.AddSeconds(5)
 while ([DateTime]::UtcNow -lt $forceDeadline) {
  if (@(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue).Count -eq 0) { break }
  Start-Sleep -Milliseconds 250
 }
}

$script:OaReadFileBytes = {
 param([string]$Path)
 $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 try {
  $len = $fs.Length
  if ($len -gt $OaMaxStreamBytes) { throw "Autocomplete stream exceeds size limit ($len bytes)" }
  $buf = New-Object byte[] ([int]$len)
  $readOffset = 0
  while ($readOffset -lt $buf.Length) {
   $n = $fs.Read($buf, $readOffset, ($buf.Length - $readOffset))
   if ($n -le 0) { break }
   $readOffset += $n
  }
  if ($readOffset -ne $buf.Length) {
   $trimmed = New-Object byte[] $readOffset
   if ($readOffset -gt 0) { [Array]::Copy($buf, 0, $trimmed, 0, $readOffset) }
   return ,$trimmed
  }
  return ,$buf
 } finally {
  $fs.Dispose()
 }
}

function Initialize-OaBackupDirectory {
 param([string]$BackupDir)
 if ([string]::IsNullOrWhiteSpace($BackupDir) -or $BackupDir.IndexOfAny([char[]]'*?[]') -ge 0 -or ($BackupDir -match '(^\\\\|:)+' -and $BackupDir -notmatch '^[A-Za-z]:\\')) {
  throw "Invalid backup directory '$BackupDir'"
 }
 $sep = [IO.Path]::DirectorySeparatorChar
 $fullDir = [IO.Path]::GetFullPath($BackupDir).TrimEnd($sep)
 $volRoot = [IO.Path]::GetPathRoot($fullDir)
 if ([string]::IsNullOrWhiteSpace($volRoot)) { throw "Cannot resolve root for '$BackupDir'" }
 $probe = $fullDir; $existingAncestor = $null
 while ($probe) {
  if ($null -ne (Get-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue)) { $existingAncestor = $probe; break }
  $parent = [IO.Path]::GetDirectoryName($probe)
  if (-not $parent -or $parent -eq $probe) { break }
  $probe = $parent
 }
 if (-not $existingAncestor -or -not (Test-OaSafePath -Path $existingAncestor -Root $volRoot -AllowRoot)) {
  throw "Unsafe existing ancestor for backup directory '$BackupDir'"
 }
 $rel = $fullDir.Substring($existingAncestor.TrimEnd($sep).Length).TrimStart($sep)
 $cur = $existingAncestor.TrimEnd($sep)
 foreach ($part in @($rel.Split($sep) | Where-Object { $_ })) {
  if ($part -in @('.', '..')) { throw "Invalid segment in '$BackupDir'" }
  $cur = if ($cur.EndsWith([string]$sep)) { "$cur$part" } else { "$cur$sep$part" }
  if (-not (Test-Path -LiteralPath $cur)) { $null = New-Item -ItemType Directory -Path $cur -ErrorAction Stop }
  if (-not (Test-OaSafePath -Path $cur -Root $volRoot -AllowRoot)) { throw "Unsafe backup segment '$cur'" }
 }
 if ($env:OS -eq 'Windows_NT') {
  $acl = New-Object Security.AccessControl.DirectorySecurity
  $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
  Set-Acl -LiteralPath $fullDir -AclObject $acl -ErrorAction Stop
 }
 return $fullDir
}

$script:OaBackupFile = {
 param([string]$SourcePath, [string]$BackupDir, [string]$Prefix)
 $validDir = Initialize-OaBackupDirectory -BackupDir $BackupDir
 $safePrefix = ($Prefix -replace '[^A-Za-z0-9._-]', '_')
 $leaf = [IO.Path]::GetFileName($SourcePath)
 $destPath = Join-Path $validDir ("{0}-{1}-{2}" -f $safePrefix, [guid]::NewGuid().ToString('n').Substring(0, 8), $leaf)
 [IO.File]::Copy($SourcePath, $destPath, $false)
 if ((Get-Item -LiteralPath $destPath -Force -ErrorAction Stop).Length -ne (Get-Item -LiteralPath $SourcePath -Force -ErrorAction Stop).Length) {
  throw "Backup size mismatch for '$leaf'"
 }
 return $destPath
}

function New-OaFileSummary {
 param([string]$Profile, [string]$FileName, [int64]$SizeBytes = 0, $LastWriteUtc = $null, [bool]$Valid = $false, [int]$Rows = 0, [int]$Matched = 0)
 return [ordered]@{
  profile = $Profile; fileName = $FileName; sizeBytes = $SizeBytes; lastWriteTimeUtc = $LastWriteUtc
  validFormat = $Valid; rowCount = $Rows; matchedRowCount = $Matched; removedRowCount = 0; backedUp = $false; modified = $false
 }
}

function Invoke-OaRun {
 param([string]$Match = '', [switch]$Fix, [switch]$CloseOutlook)
 $opts = Get-OaOptions -Action 'Install' -Match $Match -Fix ($(if ($Fix) { 'true' } else { 'false' })) -CloseOutlook ($(if ($CloseOutlook) { 'true' } else { 'false' }))
 $needle = $opts.Match; $isFix = [bool]$opts.Fix; $allowClose = [bool]$opts.CloseOutlook
 $errors = [System.Collections.Generic.List[string]]::new()
 $fileSummaries = [System.Collections.Generic.List[object]]::new()
 $candidates = [System.Collections.Generic.List[object]]::new()
 $outlookClosed = $false
 $outlookStopAttempted = $false

 $profiles = @()
 try { $profiles = @(& $script:OaGetProfiles) } catch { $errors.Add("profile enumeration failed: $(Limit-OaText "$_" 140)") }

 foreach ($prof in $profiles) {
  if ($outlookStopAttempted -and -not $outlookClosed -and $errors.Count -gt 0) { break }
  $profName = [string]$prof.Name; $profPath = [string]$prof.Path; $profRoot = [string]$prof.Root
  if (-not (Test-OaSafePath -Path $profPath -Root $profRoot)) { $errors.Add("unsafe profile path for '$profName'"); continue }
  $curSub = $profPath; $roamMissing = $false; $roamUnsafe = $false
  foreach ($seg in @('AppData', 'Local', 'Microsoft', 'Outlook', 'RoamCache')) {
   $curSub = Join-Path $curSub $seg
   $subItem = $null
   try { $subItem = Get-Item -LiteralPath $curSub -Force -ErrorAction Stop }
   catch [Management.Automation.ItemNotFoundException] { $roamMissing = $true; break }
   catch {
    if (-not (Test-Path -LiteralPath $curSub)) { $roamMissing = $true }
    else { $errors.Add("cannot inspect '$seg' in '$profName': $(Limit-OaText "$_" 120)"); $roamUnsafe = $true }
    break
   }
   if (-not $subItem.PSIsContainer -or -not (Test-OaSafePath -Path $curSub -Root $profPath)) {
    $errors.Add("unsafe or non-directory Outlook path '$seg' in '$profName'"); $roamUnsafe = $true; break
   }
  }
  if ($roamMissing -or $roamUnsafe) { continue }

  $roamCache = $curSub
  $datEntries = @()
  try { $datEntries = @(Get-ChildItem -LiteralPath $roamCache -Force -ErrorAction Stop | Where-Object { $_.Name -like 'Stream_Autocomplete*.dat' } | Sort-Object Name) }
  catch { $errors.Add("cannot list RoamCache in '$profName': $(Limit-OaText "$_" 120)"); continue }

  foreach ($entry in $datEntries) {
   $fullPath = $entry.FullName
   if ($entry.PSIsContainer -or -not (Test-OaSafePath -Path $fullPath -Root $roamCache)) {
    $errors.Add("unsafe or reparse autocomplete stream '$($entry.Name)' in '$profName'")
    $fileSummaries.Add((New-OaFileSummary -Profile $profName -FileName $entry.Name)); continue
   }
   if ($isFix -and $allowClose -and -not $outlookStopAttempted) {
    $outlookStopAttempted = $true
    $runningPre = @()
    try { $runningPre = @(& $script:OaGetOutlookProcesses) } catch { $errors.Add("cannot query Outlook processes: $(Limit-OaText "$_" 120)"); break }
    if ($runningPre.Count -gt 0) {
     try { & $script:OaStopOutlookProcesses } catch { $errors.Add("failed to stop Outlook: $(Limit-OaText "$_" 120)"); break }
     $stillPre = @()
     try { $stillPre = @(& $script:OaGetOutlookProcesses) } catch { $errors.Add("cannot query Outlook processes: $(Limit-OaText "$_" 120)"); break }
     if ($stillPre.Count -gt 0) {
      $errors.Add("Outlook is still running after stop attempt ($($stillPre.Count) process(es))"); break
     }
     $outlookClosed = $true
     if (-not (Test-OaSafePath -Path $fullPath -Root $roamCache)) {
      $errors.Add("unsafe or reparse autocomplete stream '$($entry.Name)' in '$profName'")
      $fileSummaries.Add((New-OaFileSummary -Profile $profName -FileName $entry.Name)); continue
     }
     try { $entry = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop }
     catch { $errors.Add("cannot stat '$($entry.Name)' in '$profName' after closing Outlook: $(Limit-OaText "$_" 120)"); continue }
    }
   }
   $lw = $entry.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
   if ($entry.Length -gt $OaMaxStreamBytes) {
    $errors.Add("autocomplete stream '$($entry.Name)' in '$profName' exceeds size limit")
    $fileSummaries.Add((New-OaFileSummary -Profile $profName -FileName $entry.Name -SizeBytes $entry.Length -LastWriteUtc $lw)); continue
   }
   $bytes = $null
   try {
    $bytes = & $script:OaReadFileBytes $fullPath
   } catch {
    $readErr = $_
    $runningHint = ''
    try { if (@(& $script:OaGetOutlookProcesses).Count -gt 0) { $runningHint = " (Outlook is running; close Outlook or pass CloseOutlook='true')" } } catch { }
    $errors.Add("cannot read '$($entry.Name)' in '$profName': $(Limit-OaText "$readErr" 100)$runningHint")
    $fileSummaries.Add((New-OaFileSummary -Profile $profName -FileName $entry.Name -SizeBytes $entry.Length -LastWriteUtc $lw)); continue
   }
   $parsed = Read-OaStream -Bytes $bytes -Match $needle
   $summary = New-OaFileSummary -Profile $profName -FileName $entry.Name -SizeBytes $bytes.Length -LastWriteUtc $lw -Valid ([bool]$parsed.validFormat) -Rows ([int]$parsed.rowCount) -Matched ([int]$parsed.matchedRowCount)
   $fileSummaries.Add($summary)
   if (-not $parsed.validFormat) { $errors.Add("invalid stream '$($entry.Name)' in '$profName': $($parsed.parseError)"); continue }
   if ($parsed.matchedRowCount -gt 0) {
    $candidates.Add([pscustomobject]@{ ProfileName = $profName; FileName = $entry.Name; FilePath = $fullPath; RoamCachePath = $roamCache; Summary = $summary; Parsed = $parsed })
   }
  }
 }

 $matchedFiles = $candidates.Count; $matchedRows = 0
 foreach ($c in $candidates) { $matchedRows += [int]$c.Parsed.matchedRowCount }
 $modifiedFiles = 0; $removedRows = 0; $runBackupDir = $null

 if ($isFix -and $matchedFiles -gt 0 -and $errors.Count -eq 0) {
  $running = @()
  try { $running = @(& $script:OaGetOutlookProcesses) } catch { $errors.Add("cannot query Outlook processes: $(Limit-OaText "$_" 120)") }
  if ($errors.Count -eq 0 -and $running.Count -gt 0) {
   if (-not $allowClose) {
    $errors.Add("Outlook is running ($($running.Count) process(es)); close Outlook or pass CloseOutlook='true'")
   } else {
    try { & $script:OaStopOutlookProcesses } catch { $errors.Add("failed to stop Outlook: $(Limit-OaText "$_" 120)") }
    $stillRunning = @(& $script:OaGetOutlookProcesses)
    if ($stillRunning.Count -gt 0) { $errors.Add("Outlook is still running after stop attempt ($($stillRunning.Count) process(es))") }
    else { $outlookClosed = $true }
   }
  }

  if ($errors.Count -eq 0) {
   $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('n').Substring(0, 8)
   $runBackupDir = Join-Path $script:OaBackupRoot "backup-$stamp"

   foreach ($cand in $candidates) {
    if (@(& $script:OaGetOutlookProcesses).Count -gt 0) {
     $errors.Add("Outlook started during fix before updating '$($cand.FileName)' in '$($cand.ProfileName)'"); break
    }
    if (-not (Test-OaSafePath -Path $cand.FilePath -Root $cand.RoamCachePath)) {
     $errors.Add("unsafe path before updating '$($cand.FileName)' in '$($cand.ProfileName)'"); continue
    }
    # Re-read and re-parse from disk after Outlook closes so any stream state flushed on exit is backed up and filtered.
    $freshBytes = $null
    try {
     $freshItem = Get-Item -LiteralPath $cand.FilePath -Force -ErrorAction Stop
     if ($freshItem.PSIsContainer -or $freshItem.Length -gt $OaMaxStreamBytes) {
      $errors.Add("invalid stream '$($cand.FileName)' in '$($cand.ProfileName)' after Outlook close"); continue
     }
     $freshBytes = & $script:OaReadFileBytes $cand.FilePath
    } catch { $errors.Add("cannot re-read '$($cand.FileName)' in '$($cand.ProfileName)': $(Limit-OaText "$_" 120)"); continue }

    $freshParsed = Read-OaStream -Bytes $freshBytes -Match $needle
    if (-not $freshParsed.validFormat) {
     $errors.Add("invalid stream after re-read '$($cand.FileName)' in '$($cand.ProfileName)': $($freshParsed.parseError)"); continue
    }
    $cand.Summary.rowCount = [int]$freshParsed.rowCount
    $cand.Summary.matchedRowCount = [int]$freshParsed.matchedRowCount
    if ($freshParsed.matchedRowCount -eq 0) { continue }

    $newBytes = $null
    try { $newBytes = Remove-OaStreamMatchedRows -Bytes $freshBytes -Parsed $freshParsed }
    catch { $errors.Add("cannot filter '$($cand.FileName)' in '$($cand.ProfileName)': $(Limit-OaText "$_" 120)"); continue }

    $expectedRows = [int]$freshParsed.rowCount - [int]$freshParsed.matchedRowCount
    $verifyMem = Read-OaStream -Bytes $newBytes -Match $needle
    if (-not $verifyMem.validFormat -or $verifyMem.rowCount -ne $expectedRows -or $verifyMem.matchedRowCount -ne 0) {
     $errors.Add("in-memory verification failed for '$($cand.FileName)' in '$($cand.ProfileName)'"); continue
    }
    $backupPath = $null
    try { $backupPath = & $script:OaBackupFile $cand.FilePath $runBackupDir $cand.ProfileName; $cand.Summary.backedUp = $true }
    catch { $errors.Add("backup failed for '$($cand.FileName)' in '$($cand.ProfileName)': $(Limit-OaText "$_" 120)"); continue }

    if (-not (Test-OaSafePath -Path $cand.FilePath -Root $cand.RoamCachePath)) {
     $errors.Add("unsafe path before writing '$($cand.FileName)' in '$($cand.ProfileName)'"); continue
    }
    try {
     [IO.File]::WriteAllBytes($cand.FilePath, $newBytes)
     $diskBytes = & $script:OaReadFileBytes $cand.FilePath
     $verifyDisk = Read-OaStream -Bytes $diskBytes -Match $needle
     if (-not $verifyDisk.validFormat -or $verifyDisk.rowCount -ne $expectedRows -or $verifyDisk.matchedRowCount -ne 0) {
      [IO.File]::Copy($backupPath, $cand.FilePath, $true)
      $errors.Add("post-write verification failed for '$($cand.FileName)' in '$($cand.ProfileName)'; restored backup"); continue
     }
     $cand.Summary.modified = $true
     $cand.Summary.removedRowCount = [int]$freshParsed.matchedRowCount
     $cand.Summary.sizeBytes = [int64]$diskBytes.Length
     $modifiedFiles++; $removedRows += [int]$freshParsed.matchedRowCount
    } catch {
     try { if ($backupPath -and (Test-Path -LiteralPath $backupPath)) { [IO.File]::Copy($backupPath, $cand.FilePath, $true) } } catch { }
     $errors.Add("write failed for '$($cand.FileName)' in '$($cand.ProfileName)': $(Limit-OaText "$_" 120)")
    }
   }
   $matchedFiles = 0; $matchedRows = 0
   foreach ($s in $fileSummaries) {
    if ([int]$s.matchedRowCount -gt 0) { $matchedFiles++; $matchedRows += [int]$s.matchedRowCount }
   }
  }
 }

 $exitCode = 0
 if ($errors.Count -gt 0) { $exitCode = 1; $verdict = "error: $($errors[0])" }
 elseif ($matchedRows -eq 0) { $verdict = "nothing to do: 0 matching rows across $($fileSummaries.Count) stream file(s)" }
 elseif (-not $isFix) { $verdict = "matched $matchedRows row(s) in $matchedFiles of $($fileSummaries.Count) stream file(s)" }
 elseif ($modifiedFiles -eq $matchedFiles -and $removedRows -eq $matchedRows) { $verdict = "fixed: removed $removedRows row(s) across $modifiedFiles stream file(s)" }
 else { $exitCode = 1; $verdict = "fix incomplete: removed $removedRows of $matchedRows row(s) across $modifiedFiles of $matchedFiles file(s)" }

 $record = [ordered]@{
  version = '1.0'; timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  mode = $(if ($isFix) { 'fix' } else { 'check' }); match = $needle
  matchedFiles = $matchedFiles; matchedRows = $matchedRows; modifiedFiles = $modifiedFiles
  removedRows = $removedRows; outlookClosed = $outlookClosed; backupDir = $runBackupDir
  files = @($fileSummaries.ToArray()); errors = @($errors.ToArray()); verdict = $verdict
 }
 return [ordered]@{ record = $record; exitCode = $exitCode }
}

function ConvertTo-BoundedOaJson {
 param([System.Collections.IDictionary]$Record, [int]$MaxBytes = 8000)
 $copy = [ordered]@{}
 foreach ($k in $Record.Keys) { $copy[$k] = $Record[$k] }
 $json = $copy | ConvertTo-Json -Depth 6 -Compress
 if ([Text.Encoding]::UTF8.GetByteCount($json) -le $MaxBytes) { return $json }

 $copy['truncated'] = $true
 $filesList = @($copy['files'])
 $errList = @($copy['errors'] | ForEach-Object { Limit-OaText "$_" 120 })
 $copy['errors'] = $errList

 while ($filesList.Count -gt 0 -and [Text.Encoding]::UTF8.GetByteCount(($copy | ConvertTo-Json -Depth 6 -Compress)) -gt $MaxBytes) {
  $take = [Math]::Max(0, [int][Math]::Floor($filesList.Count / 2) - 1)
  if ($take -gt 0) { $filesList = @($filesList[0..($take - 1)]) } else { $filesList = @() }
  $copy['files'] = $filesList
 }
 while ($errList.Count -gt 1 -and [Text.Encoding]::UTF8.GetByteCount(($copy | ConvertTo-Json -Depth 6 -Compress)) -gt $MaxBytes) {
  $take = [Math]::Max(1, [int][Math]::Floor($errList.Count / 2))
  $errList = @($errList[0..($take - 1)])
  $copy['errors'] = $errList
 }
 $json = $copy | ConvertTo-Json -Depth 6 -Compress
 if ([Text.Encoding]::UTF8.GetByteCount($json) -le $MaxBytes) { return $json }
 return ([ordered]@{
  version = $copy['version']; timestamp = $copy['timestamp']; mode = $copy['mode']
  truncated = $true; verdict = Limit-OaText ([string]$copy['verdict']) 240
 } | ConvertTo-Json -Depth 4 -Compress)
}

function Invoke-Main {
 param([string]$Match = '', [switch]$Fix, [switch]$CloseOutlook)
 try {
  Write-Status "Outlook autocomplete $(if ($Fix) { 'fix' } else { 'check' }) starting"
  $run = Invoke-OaRun -Match $Match -Fix:$Fix -CloseOutlook:$CloseOutlook
  $json = ConvertTo-BoundedOaJson -Record $run.record
  Write-Status "Verdict: $($run.record.verdict) ($([Text.Encoding]::UTF8.GetByteCount($json)) bytes)"
  Write-Output $json
  exit $run.exitCode
 } catch {
  Write-Status "Outlook autocomplete error: $_" 'ERROR'
  Write-Status $_.ScriptStackTrace 'ERROR'
  exit 1
 }
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') {
 try { $oaOpts = Get-OaOptions -Action $Action -Match $Match -Fix $Fix -CloseOutlook $CloseOutlook }
 catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
 if ($oaOpts.Mode -eq 'none') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
 Invoke-Main -Match $oaOpts.Match -Fix:$oaOpts.Fix -CloseOutlook:$oaOpts.CloseOutlook
}
