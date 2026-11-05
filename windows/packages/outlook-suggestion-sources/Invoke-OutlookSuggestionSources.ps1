# Read-only check of what on this PC could hold or surface one address in Classic Outlook suggestions.
# It prints counts, relative paths, sizes, timestamps and Outlook profile settings. It never prints file content, neighbouring bytes, or Match.
[CmdletBinding()]
param(
 [string]$DeploymentType,
 [string]$Action,
 [string]$PinVersion,
 [string]$Match = '',
 [string]$Hours = '',
 [string]$Scope = '',
 [string]$Sections = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:OssVersion = '1'
$script:OssJsonPrefix = 'RELIAN_SOURCES_JSON: '
# Ninja activity output is cut at about 10000 characters, and the JSON line shares that budget with the text.
$script:OssMaxOutputChars = 9500
$script:OssMaxJsonBytes = 4000
$script:OssAllSections = @('processes', 'config', 'roots', 'inventory', 'roamcache')
$script:OssMaxFileBytes = 67108864
# Per root, so one big root cannot use up another root's share. Test-OssExpired is the overall bound.
$script:OssMaxFiles = 5000
$script:OssMaxSeconds = 150
$script:OssChunkBytes = 1048576
$script:OssMaxRegKeys = 5000
$script:OssHugeFiles = 2000
$script:OssHugeBytes = 536870912
$script:OssClock = $null
$script:OssUsersRoot = if ($env:SystemDrive) { "$($env:SystemDrive)\Users" } else { 'C:\Users' }
$script:OssLimitsNote = 'Compressed stores (LevelDB/Snappy, OST) can hide a match, so 0 hits there is not proof of absence. PST, OST and NST files are not scanned. Only loaded user hives are read.'

function Format-OssUtc {
 param($Time)
 if ($null -eq $Time) { return $null }
 return ([datetime]$Time).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
}

function Limit-OssText {
 param([string]$Text, [int]$MaxLength = 200)
 $clean = (([string]$Text) -replace '\s+', ' ').Trim()
 if ($clean.Length -le $MaxLength) { return $clean }
 # The tail of a path is the part that identifies the file.
 return '...' + $clean.Substring($clean.Length - $MaxLength)
}

function Get-OssOptions {
 param([string]$Action, [string]$Match = '', [string]$Hours = '', [string]$Scope = '', [string]$Sections = '')
 if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) {
  throw 'Action must be Install, Update, Repair, Reinstall, or Uninstall.'
 }
 if ($Action -eq 'Uninstall') { return [ordered]@{ Mode = 'none'; Match = ''; Hours = 0; Scope = ''; Sections = @() } }
 $address = if ($null -eq $Match) { '' } else { $Match.Trim() }
 # ponytail: ASCII addresses only, so one Latin-1 regex covers ASCII, UTF-8 and UTF-16LE. Decode IDN first if one ever matters.
 if ($address.Length -gt 254 -or $address -notmatch '\A[A-Za-z0-9!#$%&''*+/=?^_`{|}~.-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+\z') {
  throw 'Match must be one ASCII email address.'
 }
 $window = 72
 if (-not [string]::IsNullOrEmpty($Hours)) {
  if ($Hours -notmatch '\A\d{1,6}\z' -or [int]$Hours -lt 1) { throw 'Hours must be a whole number of at least 1.' }
  $window = [Math]::Min([int]$Hours, 720)
 }
 $area = if ([string]::IsNullOrWhiteSpace($Scope)) { 'all' } else { $Scope.Trim().ToLowerInvariant() }
 if (@('all', 'browser', 'outlook', 'office') -notcontains $area) { throw 'Scope must be all, browser, outlook, or office.' }
 # The inventory and RoamCache blocks are about Outlook, so a browser or Office run leaves their room to hit files.
 $blocks = if ($area -eq 'browser' -or $area -eq 'office') { @('processes', 'config', 'roots') } else { $script:OssAllSections }
 if (-not [string]::IsNullOrWhiteSpace($Sections)) {
  $asked = @($Sections.ToLowerInvariant() -split ',' | ForEach-Object { $_.Trim() })
  if ($asked.Count -eq 1 -and $asked[0] -eq 'all') { $blocks = $script:OssAllSections }
  elseif ($asked.Count -eq 1 -and $asked[0] -eq 'none') { $blocks = @() }
  else {
   foreach ($name in $asked) {
    if ($script:OssAllSections -notcontains $name) { throw "Sections must be all, none, or a comma list of $($script:OssAllSections -join ', ')." }
   }
   $blocks = $asked
  }
 }
 return [ordered]@{ Mode = 'check'; Match = $address; Hours = $window; Scope = $area; Sections = @($blocks) }
}

function Test-OssReparse {
 param($Info)
 return (($Info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-OssExpired {
 return ($null -ne $script:OssClock -and $script:OssClock.Elapsed.TotalSeconds -ge $script:OssMaxSeconds)
}

function Join-OssPath {
 param([string]$Base, [string]$Relative)
 return [IO.Path]::Combine($Base, ($Relative -replace '\\', [IO.Path]::DirectorySeparatorChar))
}

function Get-OssRootState {
 # Checks every folder from the profile down, so a junction at AppData is refused as well as one at the leaf.
 param([string]$Base, [string]$Relative)
 $current = $Base
 foreach ($part in ($Relative -split '\\')) {
  $current = [IO.Path]::Combine($current, $part)
  try {
   $info = [IO.DirectoryInfo]::new($current)
   if (-not $info.Exists) { return 'missing' }
   if (Test-OssReparse $info) { return 'reparse' }
  } catch { return 'unreadable' }
 }
 return 'ok'
}

function Get-OssWalk {
 # Reparse points are never followed or opened. That also leaves OneDrive placeholders unhydrated.
 param([string]$Root, [int]$MaxDepth = 12, [int]$MaxEntries = 50000, [string[]]$Extensions = @())
 $files = [System.Collections.Generic.List[object]]::new()
 $stack = [System.Collections.Generic.Stack[object]]::new()
 $stack.Push([pscustomobject]@{ Path = $Root; Depth = 0 })
 $visited = 0; $reparse = 0; $dirErrors = 0; $truncated = $false
 while ($stack.Count -gt 0 -and -not $truncated) {
  if (Test-OssExpired) { $truncated = $true; break }
  $dir = $stack.Pop()
  try { $entries = @([IO.DirectoryInfo]::new($dir.Path).GetFileSystemInfos()) }
  catch { $dirErrors++; continue }
  foreach ($entry in $entries) {
   $visited++
   if ($visited -gt $MaxEntries) { $truncated = $true; break }
   if (Test-OssReparse $entry) { $reparse++; continue }
   if ($entry -is [IO.DirectoryInfo]) {
    if ($dir.Depth -lt $MaxDepth) { $stack.Push([pscustomobject]@{ Path = $entry.FullName; Depth = $dir.Depth + 1 }) }
    else { $truncated = $true }
   } elseif ($Extensions.Count -eq 0 -or $Extensions -contains $entry.Extension) {
    $files.Add($entry)
   }
  }
 }
 return [pscustomobject]@{ Files = @($files.ToArray()); Truncated = $truncated; ReparseSkipped = $reparse; DirErrors = $dirErrors }
}

function Get-OssRelativePath {
 param([string]$Base, [string]$Path)
 return $Path.Substring($Base.TrimEnd([IO.Path]::DirectorySeparatorChar).Length + 1)
}

function New-OssScanner {
 param([string]$Address)
 $options = [Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'
 $utf16 = -join @($Address.ToCharArray() | ForEach-Object { [regex]::Escape([string]$_) + '\x00' })
 return [pscustomobject]@{
  Length = $Address.Length
  Ascii = [regex]::new([regex]::Escape($Address), $options)
  Utf16 = [regex]::new($utf16, $options)
 }
}

function Find-OssMatches {
 # Latin-1 maps each byte to one char, so a regex finds byte patterns without a slow byte loop in PowerShell and without Add-Type writing a temp DLL.
 param([string]$Path, $Scanner)
 $result = [pscustomobject]@{ Ascii = 0; Utf16 = 0; Complete = $false; Locked = $false }
 $latin1 = [Text.Encoding]::GetEncoding(28591)
 # A UTF-16 match is 2n bytes, so 2n-1 kept bytes can never hold a whole match and cannot count it twice.
 $keepMax = (2 * $Scanner.Length) - 1
 $stream = $null
 try {
  $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  $buffer = [byte[]]::new($script:OssChunkBytes + $keepMax)
  $carry = 0
  while ($true) {
   if (Test-OssExpired) { return $result }
   $read = $stream.Read($buffer, $carry, $script:OssChunkBytes)
   if ($read -le 0) { break }
   $length = $carry + $read
   $text = $latin1.GetString($buffer, 0, $length)
   # An ASCII match is n bytes, so anything starting before the last n-1 carried bytes was already counted.
   $asciiStart = [Math]::Max(0, $carry - ($Scanner.Length - 1))
   $result.Ascii += $Scanner.Ascii.Matches($text, $asciiStart).Count
   $result.Utf16 += $Scanner.Utf16.Matches($text, 0).Count
   $carry = [Math]::Min($length, $keepMax)
   [Array]::Copy($buffer, $length - $carry, $buffer, 0, $carry)
  }
  $result.Complete = $true
 } catch {
  $result.Locked = $true
 } finally {
  if ($null -ne $stream) { $stream.Dispose() }
 }
 return $result
}

function New-OssRoot {
 param([string]$ProfileName, [string]$ProfilePath, [string]$Relative, [string]$Preset = '', [string]$Kind = 'outlook', [switch]$HugeCheck)
 # Lowest rank scans first. Office\16.0 goes last because it can hold tens of thousands of files, and CacheStorage is the largest browser folder.
 $rank = 0
 if ($Kind -eq 'office') { $rank = 3 }
 elseif ($Kind -eq 'browser') { $rank = if ($Relative -like '*CacheStorage') { 2 } else { 1 } }
 return [pscustomobject]@{
  profile = $ProfileName; root = $Relative; kind = $Kind; status = $Preset
  filesFound = 0; filesScanned = 0; filesSkippedTooLarge = 0; filesLocked = 0; storeFilesSkipped = 0; reparseSkipped = 0; dirErrors = 0; hitFiles = 0
  ProfilePath = $ProfilePath; Rank = $rank; HugeCheck = [bool]$HugeCheck
 }
}

function Get-OssChildDirs {
 param([string]$Path)
 try { return @([IO.DirectoryInfo]::new($Path).GetDirectories() | Where-Object { -not (Test-OssReparse $_) }) }
 catch { return @() }
}

function Get-OssScanRoots {
 param($Prof)
 $rows = [System.Collections.Generic.List[object]]::new()
 foreach ($rel in @('AppData\Local\Microsoft\Outlook', 'AppData\Roaming\Microsoft\Outlook', 'AppData\Local\Microsoft\Olk')) {
  $rows.Add((New-OssRoot $Prof.Name $Prof.Path $rel))
 }
 $rows.Add((New-OssRoot $Prof.Name $Prof.Path 'AppData\Local\Microsoft\Windows\INetCache\Content.Outlook' -HugeCheck))
 $rows.Add((New-OssRoot $Prof.Name $Prof.Path 'AppData\Local\Microsoft\Office\16.0' -Kind 'office'))

 $storageDirs = @('IndexedDB', 'Local Storage', 'Service Worker\CacheStorage', 'Session Storage')
 foreach ($userData in @('AppData\Local\Microsoft\Edge\User Data', 'AppData\Local\Google\Chrome\User Data')) {
  $state = Get-OssRootState $Prof.Path $userData
  if ($state -ne 'ok') { $rows.Add((New-OssRoot $Prof.Name $Prof.Path $userData $state -Kind 'browser')); continue }
  $found = 0
  foreach ($child in @(Get-OssChildDirs (Join-OssPath $Prof.Path $userData))) {
   # A real profile folder always gets its rows. Any other folder, such as Crashpad, only when it holds browser storage.
   $present = @($storageDirs | Where-Object { (Get-OssRootState $child.FullName $_) -ne 'missing' })
   if ($present.Count -eq 0 -and $child.Name -notmatch '\A(Default|Profile \d+|Guest Profile)\z') { continue }
   $found++
   foreach ($sub in $storageDirs) { $rows.Add((New-OssRoot $Prof.Name $Prof.Path "$userData\$($child.Name)\$sub" -Kind 'browser')) }
  }
  if ($found -eq 0) { $rows.Add((New-OssRoot $Prof.Name $Prof.Path "$userData\<profile>" 'missing' -Kind 'browser')) }
 }

 $firefox = 'AppData\Roaming\Mozilla\Firefox\Profiles'
 $state = Get-OssRootState $Prof.Path $firefox
 if ($state -ne 'ok') {
  $rows.Add((New-OssRoot $Prof.Name $Prof.Path $firefox $state -Kind 'browser'))
 } else {
  foreach ($ff in @(Get-OssChildDirs (Join-OssPath $Prof.Path $firefox))) {
   $default = "$firefox\$($ff.Name)\storage\default"
   $sites = @()
   if ((Get-OssRootState $Prof.Path $default) -eq 'ok') {
    $sites = @(Get-OssChildDirs (Join-OssPath $Prof.Path $default) | Where-Object { $_.Name -like '*outlook*' })
   }
   if ($sites.Count -eq 0) { $rows.Add((New-OssRoot $Prof.Name $Prof.Path "$default\*outlook*" 'missing' -Kind 'browser')) }
   foreach ($site in $sites) { $rows.Add((New-OssRoot $Prof.Name $Prof.Path "$default\$($site.Name)" -Kind 'browser')) }
  }
 }
 return @($rows.ToArray())
}

function Invoke-OssScan {
 param([object[]]$Profiles, [string]$Address, [string]$Scope = 'all')
 $scanner = New-OssScanner $Address
 $hits = [System.Collections.Generic.List[object]]::new()
 $locked = [System.Collections.Generic.List[object]]::new()
 $listed = @($Profiles | ForEach-Object { Get-OssScanRoots $_ } | Where-Object { $Scope -eq 'all' -or $_.kind -eq $Scope })
 $roots = @(foreach ($rank in 0..3) { $listed | Where-Object { $_.Rank -eq $rank } })
 $timedOut = $false; $fileCapReached = $false
 $storeExtensions = @('.ost', '.pst', '.nst')
 $script:OssClock = [Diagnostics.Stopwatch]::StartNew()
 try {
  foreach ($root in $roots) {
   if ($root.status) { continue }
   if (Test-OssExpired) { $timedOut = $true }
   if ($timedOut) { $root.status = 'notReached'; continue }
   $state = Get-OssRootState $root.ProfilePath $root.root
   if ($state -ne 'ok') { $root.status = $state; continue }
   $path = Join-OssPath $root.ProfilePath $root.root
   $maxEntries = if ($root.HugeCheck) { $script:OssHugeFiles } else { 50000 }
   $walk = Get-OssWalk -Root $path -MaxEntries $maxEntries
   if ($root.HugeCheck) {
    $bytes = 0L
    foreach ($f in $walk.Files) { $bytes += $f.Length }
    if ($walk.Truncated -or $bytes -gt $script:OssHugeBytes) { $root.status = 'skippedHuge'; continue }
   }
   $root.filesFound = $walk.Files.Count
   $root.reparseSkipped = $walk.ReparseSkipped
   $root.dirErrors = $walk.DirErrors
   $root.status = if ($walk.Truncated) { 'partial' } else { 'scanned' }
   $attempts = 0
   foreach ($file in $walk.Files) {
    if (Test-OssExpired) { $timedOut = $true; break }
    if ($storeExtensions -contains $file.Extension) { $root.storeFilesSkipped++; continue }
    if ($file.Length -gt $script:OssMaxFileBytes) { $root.filesSkippedTooLarge++; continue }
    if ($attempts -ge $script:OssMaxFiles) { $fileCapReached = $true; $root.status = 'capped'; break }
    $attempts++
    $found = Find-OssMatches -Path $file.FullName -Scanner $scanner
    $relative = Get-OssRelativePath $root.ProfilePath $file.FullName
    if ($found.Locked) {
     $root.filesLocked++
     $locked.Add([pscustomobject]@{ profile = $root.profile; path = $relative })
    } elseif ($found.Complete) {
     $root.filesScanned++
    } else {
     $timedOut = $true
    }
    if (($found.Ascii + $found.Utf16) -gt 0) {
     $root.hitFiles++
     $hits.Add([pscustomobject]@{
       profile = $root.profile; path = $relative; sizeBytes = $file.Length; lastWriteUtc = (Format-OssUtc $file.LastWriteTime)
       asciiHits = $found.Ascii; utf16Hits = $found.Utf16; partial = (-not $found.Complete)
      })
    }
    if ($timedOut) { break }
   }
   if ($timedOut) { $root.status = 'partial' }
   if ($walk.Truncated -and (Test-OssExpired)) { $timedOut = $true }
  }
  $elapsed = [int]$script:OssClock.Elapsed.TotalSeconds
 } finally {
  $script:OssClock = $null
 }
 $total = { param($Name) [int]($roots | ForEach-Object { $_.$Name } | Measure-Object -Sum).Sum }
 return [pscustomobject]@{
  Summary = [ordered]@{
   filesScanned = (& $total 'filesScanned'); filesSkippedTooLarge = (& $total 'filesSkippedTooLarge'); filesLocked = (& $total 'filesLocked')
   storeFilesSkipped = (& $total 'storeFilesSkipped'); reparseSkipped = (& $total 'reparseSkipped'); dirErrors = (& $total 'dirErrors'); timedOut = $timedOut; fileCapReached = $fileCapReached
   elapsedSeconds = $elapsed; rootsTotal = $roots.Count; rootsMissing = @($roots | Where-Object { $_.status -eq 'missing' }).Count
   rootsCapped = @($roots | Where-Object { $_.status -eq 'capped' }).Count; rootsNotReached = @($roots | Where-Object { $_.status -eq 'notReached' }).Count
  }
  Roots = @($roots | Select-Object profile, root, kind, status, filesFound, filesScanned, filesSkippedTooLarge, filesLocked, storeFilesSkipped, reparseSkipped, dirErrors, hitFiles)
  Hits = @($hits.ToArray())
  Locked = @($locked.ToArray())
 }
}

function Get-OssInventory {
 param([object[]]$Profiles)
 $stores = [System.Collections.Generic.List[object]]::new()
 $roam = [System.Collections.Generic.List[object]]::new()
 $roots = [System.Collections.Generic.List[object]]::new()
 $specs = @(
  @{ Rel = 'AppData\Local\Microsoft\Outlook'; Depth = 12; Entries = 50000 }
  @{ Rel = 'Documents\Outlook Files'; Depth = 12; Entries = 50000 }
  @{ Rel = 'AppData\Roaming\Microsoft\Outlook'; Depth = 12; Entries = 50000 }
  @{ Rel = 'Documents'; Depth = 6; Entries = 20000 }
 )
 foreach ($prof in $Profiles) {
  $seen = @{}
  foreach ($spec in $specs) {
   $state = Get-OssRootState $prof.Path $spec.Rel
   $truncated = $false
   if ($state -eq 'ok') {
    $walk = Get-OssWalk -Root (Join-OssPath $prof.Path $spec.Rel) -MaxDepth $spec.Depth -MaxEntries $spec.Entries -Extensions @('.pst', '.ost')
    $truncated = $walk.Truncated
    foreach ($file in $walk.Files) {
     if ($seen.ContainsKey($file.FullName)) { continue }
     $seen[$file.FullName] = $true
     $stores.Add([pscustomobject]@{ profile = $prof.Name; path = (Get-OssRelativePath $prof.Path $file.FullName); sizeBytes = $file.Length; lastWriteUtc = (Format-OssUtc $file.LastWriteTime) })
    }
   }
   $roots.Add([pscustomobject]@{ profile = $prof.Name; root = $spec.Rel; status = $state; truncated = $truncated })
  }
  $roamRel = 'AppData\Local\Microsoft\Outlook\RoamCache'
  $state = Get-OssRootState $prof.Path $roamRel
  $roots.Add([pscustomobject]@{ profile = $prof.Name; root = $roamRel; status = $state; truncated = $false })
  if ($state -eq 'ok') {
   foreach ($file in (Get-OssWalk -Root (Join-OssPath $prof.Path $roamRel) -MaxDepth 0).Files) {
    $roam.Add([pscustomobject]@{ profile = $prof.Name; name = $file.Name; sizeBytes = $file.Length; lastWriteUtc = (Format-OssUtc $file.LastWriteTime) })
   }
  }
 }
 return [pscustomobject]@{ Stores = @($stores.ToArray()); RoamCache = @($roam.ToArray()); Roots = @($roots.ToArray()) }
}

$script:OssGetProcesses = {
 @(Get-Process -Name @('OUTLOOK', 'olk', 'msedge', 'chrome', 'firefox') -ErrorAction SilentlyContinue)
}

function Get-OssProcessSummary {
 $all = @(& $script:OssGetProcesses)
 foreach ($name in @('OUTLOOK', 'olk', 'msedge', 'chrome', 'firefox')) {
  $group = @($all | Where-Object { $_.ProcessName -eq $name })
  $earliest = $null
  foreach ($proc in $group) {
   try { if ($null -eq $earliest -or $proc.StartTime -lt $earliest) { $earliest = $proc.StartTime } } catch { }
  }
  [pscustomobject]@{
   name = $name; count = $group.Count; earliestStartUtc = (Format-OssUtc $earliest)
   sessionIds = @($group | ForEach-Object { [int]$_.SessionId } | Sort-Object -Unique)
  }
 }
}

function Get-OssProfiles {
 $root = [IO.DirectoryInfo]::new($script:OssUsersRoot)
 if (-not $root.Exists) { return }
 $excluded = @('Public', 'Default', 'Default User', 'All Users')
 foreach ($dir in @($root.GetDirectories())) {
  if ($excluded -contains $dir.Name -or $dir.Name -like 'defaultuser*') { continue }
  [pscustomobject]@{ Name = $dir.Name; Path = $dir.FullName; Reparse = (Test-OssReparse $dir) }
 }
}

$script:OssGetHives = {
 # HKCU under SYSTEM is the SYSTEM profile. A signed-in user's hive is HKEY_USERS\<SID>. NTUSER.DAT is never loaded.
 foreach ($key in @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction Stop)) {
  $sid = ([string]$key.Name -split '\\')[-1]
  if ($sid -notmatch '\AS-1-(5-21|12-1)-\d+(-\d+)+\z') { continue }
  $account = 'unresolved'
  try { $account = ([Security.Principal.SecurityIdentifier]$sid).Translate([Security.Principal.NTAccount]).Value } catch { }
  $profileName = ''
  try {
   $entry = Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop
   $profileName = (([string]$entry.ProfileImagePath) -split '\\')[-1]
  } catch { }
  [pscustomobject]@{ Sid = $sid; Account = $account; ProfileName = $profileName; Root = "Registry::HKEY_USERS\$sid" }
 }
}

$script:OssRegValues = {
 param([string]$Path)
 try {
  $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
  $values = @{}
  foreach ($prop in $item.PSObject.Properties) { if ($prop.Name -notlike 'PS*') { $values[$prop.Name] = $prop.Value } }
  return $values
 } catch { return @{} }
}

$script:OssRegSubKeys = {
 param([string]$Path)
 try { return @(Get-ChildItem -LiteralPath $Path -ErrorAction Stop | ForEach-Object { ([string]$_.Name -split '\\')[-1] }) }
 catch { return @() }
}

function ConvertFrom-OssRegText {
 # Outlook keeps these as REG_BINARY UTF-16LE with a trailing NUL.
 param($Value)
 if ($null -eq $Value) { return $null }
 if ($Value -is [byte[]]) {
  return ([Text.Encoding]::Unicode.GetString($Value) -split "`0")[0]
 }
 return [string]$Value
}

function Get-OssRegValue {
 param([string]$Path, [string]$Name)
 $values = & $script:OssRegValues $Path
 if ($values.ContainsKey($Name)) { return $values[$Name] }
 return $null
}

function Get-OssHiveConfig {
 param($Hive)
 $base = "$($Hive.Root)\Software\Microsoft\Office\16.0\Outlook"
 $policy = "$($Hive.Root)\Software\Policies\Microsoft\Office\16.0\Outlook\Preferences"
 $accounts = [System.Collections.Generic.List[object]]::new()
 $stores = @{}; $names = @{}
 $keysTruncated = $false
 $profileNames = @(& $script:OssRegSubKeys "$base\Profiles")
 foreach ($outlookProfile in $profileNames) {
  $profileKey = "$base\Profiles\$outlookProfile"
  $accountRoot = "$profileKey\9375CFF0413111d3B88A00104B2A6676"
  foreach ($id in @(& $script:OssRegSubKeys $accountRoot)) {
   $values = & $script:OssRegValues "$accountRoot\$id"
   $accountName = if ($values.ContainsKey('Account Name')) { ConvertFrom-OssRegText $values['Account Name'] } else { $null }
   $email = if ($values.ContainsKey('Email')) { ConvertFrom-OssRegText $values['Email'] } else { $null }
   if ($accountName -or $email) {
    $accounts.Add([pscustomobject]@{ sid = $Hive.Sid; outlookProfile = $outlookProfile; accountName = $accountName; email = $email })
   }
  }
  $stack = [System.Collections.Generic.Stack[string]]::new()
  $stack.Push($profileKey)
  $visited = 0
  while ($stack.Count -gt 0) {
   $visited++
   if ($visited -gt $script:OssMaxRegKeys) { $keysTruncated = $true; break }
   $key = $stack.Pop()
   $values = & $script:OssRegValues $key
   # 001f6700 is PR_PST_PATH_W. 001f6610 is PR_PROFILE_OFFLINE_STORE_PATH_W, where a cached-mode OST path is kept. 001f3001 is PR_DISPLAY_NAME_W.
   foreach ($tag in @('001f6700', '001f6610')) {
    if ($values.ContainsKey($tag)) { $text = ConvertFrom-OssRegText $values[$tag]; if ($text) { $stores[$text] = $true } }
   }
   if ($values.ContainsKey('001f3001')) { $text = ConvertFrom-OssRegText $values['001f3001']; if ($text) { $names[$text] = $true } }
   foreach ($sub in @(& $script:OssRegSubKeys $key)) { $stack.Push("$key\$sub") }
  }
 }
 return [pscustomobject]@{
  sid = $Hive.Sid; account = $Hive.Account; windowsProfile = $Hive.ProfileName
  defaultProfile = (ConvertFrom-OssRegText (Get-OssRegValue $base 'DefaultProfile'))
  outlookProfiles = $profileNames
  stores = @($stores.Keys | Sort-Object)
  displayNames = @($names.Keys | Sort-Object)
  showAutoSug = (Get-OssRegValue "$base\Preferences" 'ShowAutoSug')
  showAutoSugPolicy = (Get-OssRegValue $policy 'ShowAutoSug')
  useNewOutlook = (Get-OssRegValue "$base\Preferences" 'UseNewOutlook')
  keysTruncated = $keysTruncated
  Accounts = @($accounts.ToArray())
 }
}

$script:OssGetEvents = {
 param([hashtable]$Filter, [int]$Max)
 try { return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop) }
 catch {
  # Both ids mean an empty answer, not a failure, and do not depend on the OS language.
  if ($_.FullyQualifiedErrorId -match 'NoMatching') { return @() }
  throw
 }
}

function Get-OssEventSummary {
 # Message is read only to test for OUTLOOK.EXE. No message text leaves this function.
 param([int]$Hours)
 $since = (Get-Date).AddHours(-$Hours)
 $outlook = @(& $script:OssGetEvents @{ LogName = 'Application'; ProviderName = 'Outlook'; StartTime = $since } 5000)
 $byId = @($outlook | Group-Object -Property Id | ForEach-Object {
   [pscustomobject]@{
    id = [int]$_.Name; count = $_.Count
    latestUtc = (Format-OssUtc (@($_.Group | Sort-Object -Property TimeCreated -Descending)[0].TimeCreated))
   }
  } | Sort-Object -Property id)
 $faults = @(& $script:OssGetEvents @{ LogName = 'Application'; ProviderName = @('Application Error', 'Application Hang'); StartTime = $since } 2000)
 $crashes = @($faults | Where-Object { ([string]$_.Message) -like '*OUTLOOK.EXE*' } | ForEach-Object {
   [pscustomobject]@{ id = [int]$_.Id; timeUtc = (Format-OssUtc $_.TimeCreated) }
  } | Sort-Object -Property timeUtc -Descending)
 return [pscustomobject]@{ outlook = $byId; outlookEventsRead = $outlook.Count; crashesTotal = $crashes.Count; crashes = @($crashes | Select-Object -First 20) }
}

function Get-OssBrowserFolders {
 # One line per browser in a profile, because missing rows are not printed and the folders found must still be visible.
 param([object[]]$Roots)
 $seen = [ordered]@{}
 foreach ($root in $Roots) {
  if ($root.root -match '\\(Edge|Chrome)\\User Data\\([^\\<]+)\\') {
   $key = "$($root.profile) $($Matches[1])"
   if (-not $seen.Contains($key)) { $seen[$key] = [System.Collections.Generic.List[string]]::new() }
   if (-not $seen[$key].Contains($Matches[2])) { $seen[$key].Add($Matches[2]) }
  }
 }
 foreach ($key in @($seen.Keys | Sort-Object)) { "${key}: $(@($seen[$key] | Sort-Object) -join ', ')" }
}

function Invoke-OssRun {
 param([string]$Address, [int]$Hours, [string]$Scope = 'all', [string[]]$Sections = $script:OssAllSections)
 $errors = [System.Collections.Generic.List[string]]::new()
 $note = { param($Section, $Err) $errors.Add("${Section}: " + (Limit-OssText $Err.Exception.Message 160)) }

 $processes = @(); $profiles = @(); $hives = @(); $events = $null
 $inventory = [pscustomobject]@{ Stores = @(); RoamCache = @(); Roots = @() }
 $scan = [pscustomobject]@{ Summary = [ordered]@{}; Roots = @(); Hits = @(); Locked = @() }
 if ($Sections -contains 'processes') { try { $processes = @(Get-OssProcessSummary) } catch { & $note 'processes' $_ } }
 try { $profiles = @(Get-OssProfiles) } catch { & $note 'profiles' $_ }
 try {
  foreach ($hive in @(& $script:OssGetHives)) {
   try { $hives += Get-OssHiveConfig $hive } catch { & $note "hive $($hive.Sid)" $_ }
  }
 } catch { & $note 'hives' $_ }
 $safeProfiles = @($profiles | Where-Object { -not $_.Reparse })
 if ($Sections -contains 'inventory' -or $Sections -contains 'roamcache') {
  try { $inventory = Get-OssInventory $safeProfiles } catch { & $note 'inventory' $_ }
 }
 try { $scan = Invoke-OssScan -Profiles $safeProfiles -Address $Address -Scope $Scope } catch { & $note 'scan' $_ }
 try { $events = Get-OssEventSummary -Hours $Hours } catch { & $note 'events' $_ }

 # A profile earns its lines with a loaded hive, Outlook data, or a hit. The others are only counted.
 $loaded = @($hives | ForEach-Object { $_.windowsProfile })
 $keep = @{}
 foreach ($name in $loaded) { if ($name) { $keep[$name] = $true } }
 foreach ($row in @($scan.Hits) + @($inventory.Stores) + @($inventory.RoamCache)) { $keep[$row.profile] = $true }
 foreach ($root in @($scan.Roots | Where-Object { $_.kind -ne 'browser' -and $_.filesFound -gt 0 })) { $keep[$root.profile] = $true }

 # Nothing to say about these roots beyond how many there were.
 $omitted = [ordered]@{ missing = 0; notReached = 0; empty = 0; otherProfiles = 0 }
 $rows = [System.Collections.Generic.List[object]]::new()
 foreach ($root in @($scan.Roots)) {
  if ($root.hitFiles -gt 0) { $rows.Add($root) }
  elseif ($root.status -eq 'missing') { $omitted.missing++ }
  elseif ($root.status -eq 'notReached') { $omitted.notReached++ }
  elseif (-not $keep.ContainsKey($root.profile)) { $omitted.otherProfiles++ }
  elseif ($root.status -eq 'scanned' -and $root.filesFound -eq 0 -and $root.dirErrors -eq 0) { $omitted.empty++ }
  else { $rows.Add($root) }
 }
 $withOutlook = @($hives | Where-Object { @($_.outlookProfiles).Count -gt 0 -or @($_.Accounts).Count -gt 0 })
 $showConfig = $Sections -contains 'config'
 $shownProfiles = @($profiles | Where-Object { $keep.ContainsKey($_.Name) })
 return [ordered]@{
  version = $script:OssVersion
  utc = (Format-OssUtc (Get-Date))
  computer = $env:COMPUTERNAME
  hours = $Hours
  scope = $Scope
  sections = @($Sections)
  truncated = $false
  limits = $script:OssLimitsNote
  scan = $scan.Summary
  hitFilesTotal = $scan.Hits.Count
  hitFilesOmitted = 0
  hits = $scan.Hits
  events = $events
  accounts = $(if ($showConfig) { @($hives | ForEach-Object { $_.Accounts }) } else { @() })
  accountsOmitted = 0
  droppedSections = @()
  profilesTotal = $profiles.Count
  profilesOmitted = $profiles.Count - $shownProfiles.Count
  profiles = @($shownProfiles | ForEach-Object { [pscustomobject]@{ name = $_.Name; reparse = $_.Reparse; hiveLoaded = ($loaded -contains $_.Name) } })
  hivesWithoutOutlook = $hives.Count - $withOutlook.Count
  hives = $(if ($showConfig) { @($withOutlook | Select-Object sid, account, windowsProfile, defaultProfile, outlookProfiles, stores, displayNames, showAutoSug, showAutoSugPolicy, useNewOutlook, keysTruncated) } else { @() })
  processes = $processes
  errors = @($errors.ToArray())
  browserProfiles = @(Get-OssBrowserFolders @($scan.Roots | Where-Object { $keep.ContainsKey($_.profile) }))
  rootsOmitted = $omitted
  roots = $(if ($Sections -contains 'roots') { @($rows.ToArray()) } else { @() })
  lockedFiles = @($scan.Locked | Where-Object { $keep.ContainsKey($_.profile) })
  stores = $(if ($Sections -contains 'inventory') { $inventory.Stores } else { @() })
  inventoryRoots = $(if ($Sections -contains 'inventory') { @($inventory.Roots | Where-Object { $_.status -ne 'missing' -and $keep.ContainsKey($_.profile) }) } else { @() })
  roamCache = $(if ($Sections -contains 'roamcache') { $inventory.RoamCache } else { @() })
 }
}

function Format-OssText {
 # Most important first. Get-OssOutput cuts from the end when the budget runs out.
 param([System.Collections.IDictionary]$Report)
 $show = { param($Value) if ($null -eq $Value -or "$Value" -eq '') { 'NOT SET' } else { "$Value" } }
 $wants = { param($Name) @($Report.sections) -contains $Name }
 "=== Outlook suggestion sources v$($Report.version) ==="
 "utc: $($Report.utc)  computer: $($Report.computer)  scope: $($Report.scope)  sections: $(@($Report.sections) -join ',')"
 ''
 '=== Scan totals ==='
 foreach ($k in @($Report.scan.Keys)) { "${k}: $($Report.scan[$k])" }
 ''
 "=== Application events, last $($Report.hours) hours ==="
 if ($null -eq $Report.events) { 'not read' }
 else {
  foreach ($e in $Report.events.outlook) { "Outlook id=$($e.id) count=$($e.count) latestUtc=$($e.latestUtc)" }
  "OUTLOOK.EXE faults: $($Report.events.crashesTotal)"
  foreach ($e in $Report.events.crashes) { "OUTLOOK.EXE fault id=$($e.id) timeUtc=$($e.timeUtc)" }
 }
 ''
 "=== Files with hits: $($Report.hitFilesTotal) ==="
 foreach ($f in $Report.hits) { "[$($f.profile)] $($f.path): size=$($f.sizeBytes) lastWriteUtc=$($f.lastWriteUtc) asciiHits=$($f.asciiHits) utf16Hits=$($f.utf16Hits) partial=$($f.partial)" }
 ''
 '=== Limits ==='
 $Report.limits
 if (@($Report.errors).Count -gt 0) { '=== Partial failures ==='; $Report.errors }
 ''
 if (& $wants 'processes') {
  '=== Processes ==='
  foreach ($p in $Report.processes) { "$($p.name): count=$($p.count) earliestStartUtc=$(& $show $p.earliestStartUtc) sessionIds=$(@($p.sessionIds) -join ',')" }
  ''
 }
 "=== Windows profiles: $($Report.profilesTotal), not listed $($Report.profilesOmitted) (no hive, no Outlook data, no hits) ==="
 foreach ($p in $Report.profiles) { "$($p.name): hiveLoaded=$($p.hiveLoaded) reparseSkipped=$($p.reparse)" }
 foreach ($b in $Report.browserProfiles) { "browser folders, $b" }
 ''
 if (& $wants 'config') {
  foreach ($h in $Report.hives) {
   "=== Outlook config: $($h.account) ($($h.sid)) ==="
   "defaultProfile: $(& $show $h.defaultProfile)"
   "outlookProfiles: $(& $show (@($h.outlookProfiles) -join '; '))"
   foreach ($a in @($Report.accounts | Where-Object { $_.sid -eq $h.sid })) { "account [$($a.outlookProfile)]: name=$(& $show $a.accountName) email=$(& $show $a.email)" }
   foreach ($s in @($h.stores)) { "store: $s" }
   foreach ($n in @($h.displayNames)) { "displayName: $n" }
   "ShowAutoSug: $(& $show $h.showAutoSug)  policy: $(& $show $h.showAutoSugPolicy)  UseNewOutlook: $(& $show $h.useNewOutlook)  keysTruncated: $($h.keysTruncated)"
   ''
  }
  "Loaded hives with no Outlook profile: $($Report.hivesWithoutOutlook)"
  ''
 }
 if (& $wants 'roots') {
  $o = $Report.rootsOmitted
  "=== Scan roots (not listed: missing $($o.missing), notReached $($o.notReached), empty $($o.empty), other profiles $($o.otherProfiles)) ==="
  foreach ($r in $Report.roots) {
   "[$($r.profile)] $($r.root): $($r.status) found=$($r.filesFound) scanned=$($r.filesScanned) tooLarge=$($r.filesSkippedTooLarge) locked=$($r.filesLocked) stores=$($r.storeFilesSkipped) reparse=$($r.reparseSkipped) dirErrors=$($r.dirErrors) hitFiles=$($r.hitFiles)"
  }
  ''
 }
 if (& $wants 'inventory') {
  '=== PST and OST inventory ==='
  foreach ($r in $Report.inventoryRoots) { "root [$($r.profile)] $($r.root): $($r.status) truncated=$($r.truncated)" }
  foreach ($f in $Report.stores) { "file [$($f.profile)] $($f.path): size=$($f.sizeBytes) lastWriteUtc=$($f.lastWriteUtc)" }
  ''
 }
 if (& $wants 'roamcache') {
  '=== RoamCache files ==='
  foreach ($f in $Report.roamCache) { "[$($f.profile)] $($f.name): size=$($f.sizeBytes) lastWriteUtc=$($f.lastWriteUtc)" }
  ''
 }
 if (@($Report.lockedFiles).Count -gt 0) {
  '=== Locked files ==='
  foreach ($f in $Report.lockedFiles) { "[$($f.profile)] $($f.path)" }
 }
}

function ConvertTo-OssJsonLine {
 # Budget covers the whole line. Whole sections go first. Hit files, accounts and events are the last thing cut, and only when they alone do not fit.
 param([System.Collections.IDictionary]$Report, [int]$MaxBytes = $script:OssMaxJsonBytes)
 $copy = [ordered]@{}
 foreach ($k in @($Report.Keys)) { $copy[$k] = $Report[$k] }
 $render = { $script:OssJsonPrefix + ($copy | ConvertTo-Json -Depth 6 -Compress) }
 $fits = { param($Line) [Text.Encoding]::UTF8.GetByteCount($Line) -le $MaxBytes }
 $line = & $render
 if (& $fits $line) { return $line }

 $copy['truncated'] = $true
 $dropped = [System.Collections.Generic.List[string]]::new()
 foreach ($section in @('roamCache', 'roots', 'lockedFiles', 'inventoryRoots', 'stores', 'browserProfiles', 'processes', 'hives', 'profiles', 'errors', 'rootsOmitted', 'sections')) {
  $copy.Remove($section)
  $dropped.Add($section)
  $copy['droppedSections'] = @($dropped.ToArray())
  $line = & $render
  if (& $fits $line) { return $line }
 }

 # ponytail: pops one entry per render, at most ~120 renders of a small object. Per-entry byte accounting if this ever shows up in a run time.
 $hits = [System.Collections.Generic.List[object]]::new()
 foreach ($h in @($copy['hits'] | Select-Object -First 60)) {
  $hits.Add([pscustomobject]@{ profile = (Limit-OssText $h.profile 40); path = (Limit-OssText $h.path 120); sizeBytes = $h.sizeBytes; lastWriteUtc = $h.lastWriteUtc; asciiHits = $h.asciiHits; utf16Hits = $h.utf16Hits; partial = $h.partial })
 }
 $accounts = [System.Collections.Generic.List[object]]::new()
 foreach ($a in @($copy['accounts'] | Select-Object -First 60)) {
  $accounts.Add([pscustomobject]@{ sid = $a.sid; outlookProfile = (Limit-OssText $a.outlookProfile 60); accountName = (Limit-OssText $a.accountName 80); email = (Limit-OssText $a.email 120) })
 }
 $accountTotal = @($copy['accounts']).Count
 while ($true) {
  $copy['hits'] = @($hits.ToArray())
  $copy['accounts'] = @($accounts.ToArray())
  $copy['hitFilesOmitted'] = [int]$Report['hitFilesTotal'] - $hits.Count
  $copy['accountsOmitted'] = $accountTotal - $accounts.Count
  $line = & $render
  if (& $fits $line) { return $line }
  if ($hits.Count -eq 0 -and $accounts.Count -eq 0) { break }
  # The longer list gives way, so neither list empties while the other still has room to shrink.
  if ($hits.Count -ge $accounts.Count) { $hits.RemoveAt($hits.Count - 1) } else { $accounts.RemoveAt($accounts.Count - 1) }
 }
 $copy.Remove('events')
 $copy['droppedSections'] = @($dropped.ToArray()) + 'events'
 return (& $render)
}

function Get-OssOutput {
 # JSON first, so the summary survives any cut. Then text by priority, stopping inside the budget and saying so. Each line also costs its CRLF.
 param([System.Collections.IDictionary]$Report, [int]$MaxChars = $script:OssMaxOutputChars)
 $json = ConvertTo-OssJsonLine $Report
 $end = '=== End of report ==='
 $text = @(Format-OssText $Report)
 $left = $MaxChars - $json.Length - $end.Length - 90
 $json
 $printed = 0
 foreach ($line in $text) {
  $left -= ([string]$line).Length + 2
  if ($left -lt 0) { break }
  $line
  $printed++
 }
 if ($printed -lt $text.Count) { "... $($text.Count - $printed) text lines cut to stay under $MaxChars characters" }
 $end
}



if ($env:RELIAN_DEPLOY_TEST -ne '1') {
 try { $ossOptions = Get-OssOptions -Action $Action -Match $Match -Hours $Hours -Scope $Scope -Sections $Sections }
 catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
 if ($ossOptions.Mode -eq 'none') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
 try { Get-OssOutput (Invoke-OssRun -Address $ossOptions.Match -Hours $ossOptions.Hours -Scope $ossOptions.Scope -Sections $ossOptions.Sections) }
 catch { Write-Output "Partial failure: $(Limit-OssText $_.Exception.Message 200)" }
 exit 0
}
