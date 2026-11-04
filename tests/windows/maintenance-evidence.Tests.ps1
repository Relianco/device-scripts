$ErrorActionPreference='Stop'
$env:RELIAN_DEPLOY_TEST='1'
. (Join-Path $PSScriptRoot '../../windows/packages/maintenance-evidence/Invoke-MaintenanceEvidence.ps1') -DeploymentType Install -Action Repair -PinVersion ''
function Assert($ok,$message) { if(-not $ok) { throw $message } }
function Refuses($block,$message) { $failed=$false; try { & $block } catch { $failed=$true }; Assert $failed $message }
Refuses { Get-MeReportPath Storage '../escape' } 'Traversal refused'
Refuses { Get-MeReportPath Other 'x' } 'Unknown package refused'
$r=[pscustomobject]@{Profiles=@([pscustomobject]@{Name=('é🙂'*3000)},[pscustomobject]@{Name='second'});Status='complete';Scan=@{Partial=$false}}
Refuses { Get-MeSection $r 'Unsupported' 0 } 'Unsupported section refused'
Refuses { Get-MeSection $r 'Profiles' 2 } 'Invalid profile ordinal refused'
$index=Get-MeSection $r Index 0
Assert ($index.ProfileCount -eq 2) 'Index contains profile count'
$value=Get-MeSection $r Profiles 0
$bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $value -Compress -Depth 30))
$joined=New-Object Collections.Generic.List[byte]
for($i=0;$i -lt [Math]::Ceiling($bytes.Length/2048);$i++) {
 $p=Get-MePage $value $i
 $joined.AddRange([Convert]::FromBase64String($p.Data))
 Assert ($p.SectionSha256 -eq (Get-MeHash $bytes)) 'Stable section hash'
 Assert (($p | ConvertTo-Json -Compress).Length -lt 7500) 'Bounded page'
}
Assert ([Convert]::ToBase64String($joined.ToArray()) -eq [Convert]::ToBase64String($bytes)) 'UTF8 pages reconstruct exactly'
Refuses { Get-MePage $value -1 } 'Negative page refused'
Refuses { Get-MePage $value 999 } 'Out of range page refused'
$scratch=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
$null=New-Item -ItemType Directory $scratch
try {
 $file=Join-Path $scratch 'report.json'; [IO.File]::WriteAllText($file,'{"Status":"ok"}')
 & {
  function Assert-MeTrustedPath { param($Path) }
  $before=[IO.File]::ReadAllBytes($file)
  $read=Read-MeReport $file
  Assert ($read.Report.Status -eq 'ok') 'Read stored JSON'
  Assert ((Get-MeHash $before) -eq (Get-MeHash ([IO.File]::ReadAllBytes($file)))) 'Read leaves file unchanged'
  # Valid JSON ensures a parse error cannot masquerade as the size guard.
  [IO.File]::WriteAllText($file, ('{"Value":"'+('x'*16777216)+'"}'))
  $sizeRefused=$false
  try { $null=Read-MeReport $file } catch {
   if ($_.Exception.Message -notlike 'Report size must be*') { throw }
   $sizeRefused=$true
  }
  Assert $sizeRefused 'Oversize valid JSON rejected by size guard'
 }
 $oldData=$env:ProgramData; $env:ProgramData=$scratch
 try {
  $owned=Join-Path $scratch 'RelianMaintenance'; $null=New-Item -ItemType Directory $owned
  $link=Join-Path $owned 'link'
  if($IsWindows -or $env:OS -eq 'Windows_NT') { $null=New-Item -ItemType Junction -Path $link -Target $scratch } else { $null=New-Item -ItemType SymbolicLink -Path $link -Target $scratch }
  Refuses { Assert-MeTrustedPath $link } 'Reparse report refused'
  Assert ((Get-MeReportPath Update ('a'*32)) -eq (Join-Path (Join-Path (Join-Path $owned 'Update') ('a'*32)) 'report.json')) 'Fixed update layout'
 } finally { $env:ProgramData=$oldData }
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
# Compact projections retain exact ordinals/counts without identifiers or paths.
$profiles=[pscustomobject]@{Profiles=@([pscustomobject]@{SID='private';Path='C:\Users\Private';Decision='StaleCandidate';Eligible=$true},[pscustomobject]@{Decision='Keep';Eligible=$false})}
$pi=Get-MeSection $profiles ProfileIndex 0
Assert ($pi.Count -eq 2 -and $pi.Rows[0].Ordinal -eq 0 -and $pi.Rows[0].Eligible) 'Compact profile ordinals and eligibility'
Assert (($pi | ConvertTo-Json -Depth 8) -notmatch 'private|C:') 'Profile index omits identifiers'
$actions=[pscustomobject]@{Actions=@(
 @{Kind='temp';Status='deleted';LogicalBytes=100},@{Kind='temp';Status='deleted';LogicalBytes=200},
 @{Kind='temp';Status='withheld';LogicalBytes=300;Error='Locked C:\Users\Private\file'},
 @{Kind='profile';Status='removedByCim'},@{Kind='componentCleanup';Status='commandCompleted'},
 @{phase='imageRepair';result=@{outcome='commandCompleted'}},@{phase='service';outcome='failed';errorCategory='AccessDenied'},
 @{unexpected='unknown'});Errors=@(@{category='ProbeFailed';detail='not available'})}
$summary=Get-MeSection $actions ActionSummary 0
Assert ($summary.Count -eq 8 -and $summary.LogicalBytesReported -eq 600 -and $summary.LogicalBytesCoverageCount -eq 3) 'Exact action count and known logical bytes'
$deleted=@($summary.Groups | Where-Object { $_.KindOrPhase -eq 'temp' -and $_.StatusOrOutcome -eq 'deleted' })
Assert ($deleted.Count -eq 1 -and $deleted[0].Count -eq 2 -and $deleted[0].LogicalBytesReported -eq 300) 'Grouped counts and logical-byte sums'
Assert ($summary.ErrorCount -eq 2 -and $summary.ReportErrorCount -eq 1 -and $summary.PartialCounts) 'Errors and unknown-action coverage explicit'
Assert (($summary | ConvertTo-Json -Depth 8) -notmatch 'Private|C:') 'Error samples omit paths'
Assert (@($summary.Groups | Where-Object { $_.KindOrPhase -eq 'imageRepair' -and $_.StatusOrOutcome -eq 'commandCompleted' }).Count -eq 1) 'Nested update result outcome supported'
$empty=Get-MeSection ([pscustomobject]@{Actions=@();Errors=@()}) ActionSummary 0
Assert ($empty.Count -eq 0 -and $empty.Groups.Count -eq 0 -and -not $empty.PartialCounts) 'Empty actions are an exact empty summary'
$many=Get-MeSection ([pscustomobject]@{Actions=@(1..20 | ForEach-Object { @{Kind='temp';Status='withheld';Error=('é'*500)} });Errors=@()}) ActionSummary 0
Assert ($many.ErrorSamples.Count -eq 5 -and $many.ErrorSamples[0].Message.Length -le 160) 'Error sample count and length bounded'
$summaryPage=Get-MePage $many 0
Assert (($summaryPage | ConvertTo-Json -Compress).Length -lt 7500) 'New summary uses bounded page transport'
Assert ((Get-MePage $many 0).SectionSha256 -eq $summaryPage.SectionSha256) 'Summary paging stable'


$beforeSummary=ConvertTo-Json -InputObject $actions -Depth 15 -Compress
$null=Get-MeSection $actions ActionSummary 0
Assert ((ConvertTo-Json -InputObject $actions -Depth 15 -Compress) -eq $beforeSummary) 'Projection never mutates full action evidence'
Refuses { Get-MeSection $actions ActionSummary 1 } 'Summary ordinal must be zero'
$updateOnly=Get-MeSection ([pscustomobject]@{Actions=@(@{phase='cacheRename';outcome='renamed'},@{phase='imageRepair';result=@{outcome='commandCompleted'}});Errors=@()}) ActionSummary 0
Assert ($updateOnly.Count -eq 2 -and -not $updateOnly.PartialCounts -and $updateOnly.PartialLogicalBytes -and $updateOnly.LogicalBytesCoverageCount -eq 0) 'Update summary distinguishes exact counts from absent logical byte coverage'
Assert ((Get-MeSection ([pscustomobject]@{}) ActionSummary 0).PartialCounts) 'Missing action collection is not an exact empty result'

$nullRow=Get-MeSection ([pscustomobject]@{Actions=@($null);Errors=@()}) ActionSummary 0
Assert ($nullRow.Count -eq 1 -and $nullRow.PartialCounts) 'Unrecognized null action row still counted'

Assert ((Get-MeSection ([pscustomobject]@{}) ProfileIndex 0).Partial) 'Missing profiles are unavailable, not exact empty'
Assert (-not (Get-MeSection ([pscustomobject]@{Profiles=@()}) ProfileIndex 0).Partial) 'Explicit empty profiles are exact'
Write-Output 'maintenance-evidence tests passed'
