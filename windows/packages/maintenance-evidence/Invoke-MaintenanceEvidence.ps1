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
  if($current -eq $owned -or $current.StartsWith($owned+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
   $acl=Get-Acl -LiteralPath $current -ErrorAction Stop
   if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Untrusted report owner' }
   $mask=[Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
   foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
    if($rule.AccessControlType -eq 'Allow' -and -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and ($rule.FileSystemRights -band $mask)) { throw 'Untrusted report modification rights' }
   }
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
function Get-MeSection {
 param($Report,[string]$Section,[int]$Ordinal)
 if($Ordinal -lt 0) { throw 'Invalid ordinal' }
 $sections=@('Index','Profiles','Snapshot','Policy','Scan','Actions','Errors','Guards','Evidence','Omissions')
 if($Section -notin $sections) { throw 'Unsupported section' }
 if($Section -eq 'Profiles') {
  $profiles=@($Report.Profiles | Where-Object { $null -ne $_ })
  if($Ordinal -ge $profiles.Count) { throw 'Profile ordinal outside report' }
  return $profiles[$Ordinal]
 }
 if($Ordinal -ne 0) { throw 'Ordinal is only supported for Profiles' }
 switch($Section) {
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
