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
  $stream=[IO.File]::OpenWrite($file); try { $stream.SetLength(16777217) } finally { $stream.Dispose() }
  Refuses { Read-MeReport $file } 'Oversize report refused before parse'
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
Write-Output 'maintenance-evidence tests passed'
