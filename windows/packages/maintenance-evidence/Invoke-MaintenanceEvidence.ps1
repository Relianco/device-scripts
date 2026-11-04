# Read-only, bounded transport for existing maintenance reports. No scan or maintenance is started.
[CmdletBinding()]
param([string]$DeploymentType,[string]$Action,[string]$PinVersion,
 [string]$Package='Storage',[string]$ReportId='',[string]$Section='Index',[int]$Ordinal=0,[int]$Page=0)
$ErrorActionPreference='Stop'
function Get-MeHash {
 param([byte[]]$Bytes)
 $sha=[Security.Cryptography.SHA256]::Create()
 try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Get-MeReportPath {
 param([string]$Package,[string]$ReportId)
 if($Package -notin @('Storage','Update')) { throw 'Unsupported package' }
 if($Package -eq 'Storage') {
  if($ReportId -cnotmatch '^\d{8}T\d{6}-[a-f0-9]{32}$') { throw 'Expected storage report filename without .json' }
  return Join-Path (Join-Path (Join-Path $env:ProgramData 'RelianMaintenance') 'Storage') ($ReportId+'.json')
 }
 if($ReportId -cnotmatch '^[a-f0-9]{32}$') { throw 'Expected update run directory identifier' }
 Join-Path (Join-Path (Join-Path (Join-Path $env:ProgramData 'RelianMaintenance') 'Update') $ReportId) 'report.json'
}
function Assert-MeTrustedPath {
 param([string]$Path)
 # Inspect every ancestor, including ProgramData's ancestors. Never adopt or repair ACLs.
 $full=[IO.Path]::GetFullPath($Path)
 $owned=[IO.Path]::GetFullPath((Join-Path $env:ProgramData 'RelianMaintenance'))
 if(-not $full.StartsWith($owned+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Outside owned report root' }
 $current=$full
 while($current) {
  $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
  if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse evidence path refused' }
  $withinOwned=$current -eq $owned -or $current.StartsWith($owned+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
  $trusted=@('S-1-5-18','S-1-5-32-544')
  # Windows parents may be owned by TrustedInstaller; owned reports may not.
  if(-not $withinOwned) { $trusted+=@('S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464') }
  $acl=Get-Acl -LiteralPath $current -ErrorAction Stop
  if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'Untrusted evidence path owner' }
  $mask=[Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
  # Creating unrelated siblings in ProgramData does not authorize replacing this tree.
  if($withinOwned) { $mask=$mask -bor [Security.AccessControl.FileSystemRights]::Write }
  foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
   # Inherit-only ACEs do not grant rights on this object. Any effective inherited
   # grant on a descendant is checked when inspecting that descendant itself.
   if($rule.AccessControlType -eq 'Allow' -and -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and $rule.IdentityReference.Value -notin $trusted -and ($rule.FileSystemRights -band $mask)) { throw 'Untrusted evidence path replacement or modification rights' }
  }
  $current=[IO.Path]::GetDirectoryName($current)
 }
}
function Read-MeReport {
 param([string]$Path)
 Assert-MeTrustedPath $Path
 # Share read only: refuse a concurrent writer and prevent replacement while reading.
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try {
  if($stream.Length -lt 2 -or $stream.Length -gt 16777216) { throw 'Report size must be 2 bytes through 16 MiB' }
  $bytes=New-Object byte[] ([int]$stream.Length); $offset=0
  while($offset -lt $bytes.Length) { $n=$stream.Read($bytes,$offset,$bytes.Length-$offset); if($n -eq 0) { throw 'Incomplete report read' }; $offset+=$n }
  $utf8=New-Object Text.UTF8Encoding($false,$true)
  $json=$utf8.GetString($bytes).TrimStart([char]0xfeff)
  $report=$json | ConvertFrom-Json -ErrorAction Stop
  if($null -eq $report -or $report -is [array] -or $report -is [string]) { throw 'Expected report object' }
  [pscustomobject]@{Report=$report;Sha256=(Get-MeHash $bytes);Length=$bytes.Length}
 } finally { $stream.Dispose() }
}
function Get-MeField {
 param($Value,[string]$Name)
 if($null -eq $Value) { return $null }
 if($Value -is [Collections.IDictionary]) { return $Value[$Name] }
 $property=$Value.PSObject.Properties[$Name]
 if($property) { return $property.Value }
 return $null
}
function Protect-MeSample {
 param($Value,[int]$Max=160)
 $text=[string]$Value
 if($text -match '(?i)password|passwd|secret|token|authorization|bearer|credential|api.?key|accountkey|command.?line') { return '[sensitive text omitted]' }
 $text=$text -replace '(?i)[a-z][a-z0-9+.-]*://\S+','[url omitted]'
 $text=$text -replace '(?i)(?:[a-z]:\\|\\\\)[^\r\n]*','[path omitted]'
 $text=($text -replace '[\x00-\x1f]',' ').Trim()
 if($text.Length -gt $Max) { return $text.Substring(0,$Max) }
 return $text
}
function Get-MeProfileIndex {
 param($Report)
 $hasProfiles=if($Report -is [Collections.IDictionary]) { $Report.Contains('Profiles') -and $null -ne $Report['Profiles'] } else { $null -ne $Report.PSObject.Properties['Profiles'] -and $null -ne $Report.PSObject.Properties['Profiles'].Value }
 $rows=New-Object Collections.Generic.List[object]; $partial=(-not $hasProfiles)
 foreach($profile in @(Get-MeField $Report Profiles | Where-Object { $null -ne $_ })) {
  $decision=Get-MeField $profile Decision; $eligible=Get-MeField $profile Eligible
  if($decision -isnot [string] -or -not $decision -or $decision.Length -gt 64) { $decision='[unknown]'; $partial=$true }
  if($eligible -isnot [bool]) { $eligible=$null; $partial=$true }
  $rows.Add([ordered]@{Ordinal=$rows.Count;Decision=$decision;Eligible=$eligible})
 }
 [ordered]@{Count=$rows.Count;Partial=$partial;Rows=@($rows.ToArray())}
}
function Get-MeActionSummary {
 param($Report)
 $groups=[ordered]@{}; $samples=New-Object Collections.Generic.List[object]
 $hasActions=if($Report -is [Collections.IDictionary]) { $Report.Contains('Actions') -and $null -ne $Report['Actions'] } else { $null -ne $Report.PSObject.Properties['Actions'] -and $null -ne $Report.PSObject.Properties['Actions'].Value }
 $rows=@()
 if($hasActions) {
  if($Report -is [Collections.IDictionary]) { $rows=@($Report['Actions']) }
  else { $rows=@($Report.PSObject.Properties['Actions'].Value) }
 }
 $total=[decimal]0; $coverage=0; $errorCount=0; $partial=(-not $hasActions)
 foreach($row in $rows) {
  $kind=Get-MeField $row Kind; if(-not $kind) { $kind=Get-MeField $row phase }
  $status=Get-MeField $row Status; if(-not $status) { $status=Get-MeField $row outcome }
  $result=Get-MeField $row result; if(-not $status) { $status=Get-MeField $result outcome }
  if($kind -isnot [string] -or -not $kind -or $kind.Length -gt 80) { $kind='[unknown]'; $partial=$true }
  if($status -isnot [string] -or -not $status -or $status.Length -gt 80) { $status='[unknown]'; $partial=$true }
  # Length prefix avoids delimiter collisions; first-observed report order is stable.
  $key=[string]$kind.Length+':'+$kind+$status
  if(-not $groups.Contains($key)) { $groups[$key]=[ordered]@{KindOrPhase=$kind;StatusOrOutcome=$status;Count=0;LogicalBytesReported=[decimal]0;LogicalBytesCoverageCount=0;ErrorCount=0} }
  $group=$groups[$key]; $group.Count++
  $bytes=Get-MeField $row LogicalBytes
  if($null -ne $bytes -and [string]$bytes -match '^\d{1,28}$') {
   try {
    $amount=[decimal]::Parse([string]$bytes,[Globalization.CultureInfo]::InvariantCulture)
    # Compute both before assignment; overflow cannot silently corrupt totals.
    $newTotal=$total+$amount; $newGroup=$group.LogicalBytesReported+$amount
    $total=$newTotal; $group.LogicalBytesReported=$newGroup; $coverage++; $group.LogicalBytesCoverageCount++
   } catch { }
  }
  $errorValue=Get-MeField $row Error; if(-not $errorValue) { $errorValue=Get-MeField $result Error }
  $category=Get-MeField $row errorCategory; if(-not $category) { $category=Get-MeField $result errorCategory }
  if(-not $category) { $category=Get-MeField $errorValue category }
  $message=if($errorValue -is [string]) { $errorValue } else { Get-MeField $errorValue message }
  if($errorValue -or $category -or $status -match '(?i)fail|error') {
   $errorCount++; $group.ErrorCount++
   if($samples.Count -lt 5) { $samples.Add([ordered]@{Source='action';Category=(Protect-MeSample $category 64);Message=(Protect-MeSample $message)}) }
  }
 }
 $reportErrors=@(Get-MeField $Report Errors | Where-Object { $null -ne $_ })
 foreach($errorValue in $reportErrors) {
  if($samples.Count -ge 5) { break }
  $category=Get-MeField $errorValue category
  $message=if($errorValue -is [string]) { $errorValue } else { Get-MeField $errorValue message }
  if(-not $message) { $message=Get-MeField $errorValue detail }
  $samples.Add([ordered]@{Source='report';Category=(Protect-MeSample $category 64);Message=(Protect-MeSample $message)})
 }
 [ordered]@{Count=$rows.Count;PartialCounts=$partial;Groups=@($groups.Values);LogicalBytesReported=$total;LogicalBytesCoverageCount=$coverage;PartialLogicalBytes=($coverage -ne $rows.Count);BytesMeaning='Reported logical bytes only, including withheld actions; NOT reclaimed space.';ErrorCount=$errorCount;ReportErrorCount=$reportErrors.Count;ErrorSamples=@($samples.ToArray());ErrorSourcesMayOverlap=$true}
}

function Get-MeSection {
 param($Report,[string]$Section,[int]$Ordinal)
 if($Ordinal -lt 0) { throw 'Invalid ordinal' }
 $sections=@('Index','Profiles','ProfileIndex','ActionSummary','Snapshot','Policy','Scan','Actions','Errors','Guards','Evidence','Omissions')
 if($Section -notin $sections) { throw 'Unsupported section' }
 if($Section -eq 'Profiles') {
  $profiles=@($Report.Profiles | Where-Object { $null -ne $_ })
  if($Ordinal -ge $profiles.Count) { throw 'Profile ordinal outside report' }
  return $profiles[$Ordinal]
 }
 if($Ordinal -ne 0) { throw 'Ordinal is only supported for Profiles' }
 switch($Section) {
  ProfileIndex { return Get-MeProfileIndex $Report }
  ActionSummary { return Get-MeActionSummary $Report }
  Index { return [ordered]@{SchemaVersion=$Report.schemaVersion;Timestamp=$Report.Timestamp;RunId=$Report.runId;Status=$Report.Status;Mode=$Report.Mode;ProfileCount=@($Report.Profiles | Where-Object { $null -ne $_ }).Count;Sections=$sections;Properties=@($Report.PSObject.Properties.Name)} }
  Snapshot { return [ordered]@{Before=$Report.Before;After=$Report.After;FreeSpaceDelta=$Report.FreeSpaceDelta;UpdateCurrency=$Report.UpdateCurrency;FeatureOffer=$Report.FeatureOffer;RebootRequired=$Report.RebootRequired} }
  Policy { return $Report.before.policy }
  Guards { if($Report.Guards) { return $Report.Guards }; return $Report.guard }
  default { return $Report.$Section }
 }
}
function Get-MePage {
 param($Value,[int]$Page)
 $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 30 -Compress))
 $count=[int][Math]::Ceiling($bytes.Length/2048.0)
 if($Page -lt 0 -or $Page -ge $count) { throw 'Page outside section' }
 $offset=$Page*2048; $length=[Math]::Min(2048,$bytes.Length-$offset)
 [ordered]@{Encoding='base64-utf8-json';SectionSha256=(Get-MeHash $bytes);SectionBytes=$bytes.Length;Page=$Page;PageCount=$count;Offset=$offset;Data=[Convert]::ToBase64String($bytes,$offset,$length)}
}
if($env:RELIAN_DEPLOY_TEST -ne '1') {
 try {
  $read=Read-MeReport (Get-MeReportPath $Package $ReportId)
  $result=Get-MePage (Get-MeSection $read.Report $Section $Ordinal) $Page
  $result.Package=$Package; $result.ReportId=$ReportId; $result.ReportSha256=$read.Sha256; $result.ReportBytes=$read.Length; $result.Section=$Section; $result.Ordinal=$Ordinal
  $output=ConvertTo-Json -InputObject $result -Compress -Depth 8
  if([Text.Encoding]::UTF8.GetByteCount($output) -gt 7500) { throw 'Transport output bound exceeded' }
  Write-Output $output
  exit 0
 } catch { Write-Output '{"Status":"error","Reason":"Evidence request failed validation or read; check package, report identifier, section, ordinal, page, trust and 16 MiB size limit."}'; exit 1 }
}
