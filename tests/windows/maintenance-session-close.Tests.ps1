$ErrorActionPreference='Stop'
$env:RELIAN_DEPLOY_TEST='1'
. (Join-Path $PSScriptRoot '../../windows/packages/storage-maintenance/Invoke-StorageMaintenance.ps1')
. (Join-Path $PSScriptRoot '../../windows/packages/update-maintenance/Invoke-UpdateMaintenance.ps1')
function Assert($Condition,$Message) { if(-not $Condition) { throw $Message } }
$script:events=New-Object Collections.Generic.List[string]
function Close-ADTInstallationProgress { $script:events.Add('progressClosed') }
function Close-ADTSession {
 [CmdletBinding()]param($ExitCode)
 $script:events.Add('sessionClosed:'+ $ExitCode)
 throw 'simulated terminal toolkit exit'
}
function ConvertTo-SmSummary { param($Report,$Path) '{"summary":"storage"}' }
function ConvertTo-UmSummary { param($Report) '{"summary":"update"}' }
$script:SmSave={ param($Report) $script:events.Add('saved') }
$script:UmSave={ param($Report) $script:events.Add('saved') }
foreach($case in @(@('storage','complete',0),@('storage','partial',0),@('storage','failed',1),@('update','reported',0),@('update','deferred',2),@('update','partial',1),@('update','failed',1))) {
 $script:events.Clear(); $script:SmUiOpen=$true; $script:UmUiOpen=$true
 $report=[pscustomobject]@{Status=$case[1];Mode='Report';Actions=@();Notifications=@();notification=@();Errors=@();ReportPath='unused'}
 $terminal=$false
 try {
  if($case[0] -eq 'storage') { Complete-SmRun $report | ForEach-Object { $script:events.Add('summary') } }
  else { Complete-UmRun $report | ForEach-Object { $script:events.Add('summary') } }
 } catch { $terminal=$_.Exception.Message -eq 'simulated terminal toolkit exit' }
 Assert $terminal 'Toolkit closure can terminate before returning'
 Assert (($script:events -join ',') -eq ('progressClosed,saved,summary,sessionClosed:'+$case[2])) 'Persist and emit before terminal close with correct code'
}
foreach($kind in @('storage','update')) {
 $script:events.Clear(); $script:SmUiOpen=$true; $script:UmUiOpen=$true
 $report=[pscustomobject]@{Status='complete';Mode='Report';Actions=@();Notifications=@();notification=@();Errors=@();ReportPath='unused'}
 $script:SmSave={ throw 'write failed' }; $script:UmSave={ throw 'write failed' }
 try {
  if($kind -eq 'storage') { Complete-SmRun $report | ForEach-Object { $script:events.Add('summary') } }
  else { Complete-UmRun $report | ForEach-Object { $script:events.Add('summary') } }
 } catch { }
 Assert ($script:events[$script:events.Count-1] -eq 'sessionClosed:1') 'Report persistence failure still closes toolkit with error code'
 Assert ($report.Status -eq 'failed') 'Persistence failure cannot claim success'
}
# Progress-dialog failure must not skip durable evidence or terminal session cleanup.
$script:events.Clear(); $script:SmUiOpen=$true
$script:SmSave={ param($Report) $script:events.Add('saved') }
function Close-ADTInstallationProgress { throw 'progress close failed' }
$report=[pscustomobject]@{Status='failed';Mode='Report';Actions=@();Notifications=@();Errors=@();ReportPath='unused'}
try { Complete-SmRun $report | ForEach-Object { $script:events.Add('summary') } } catch { }
Assert (($script:events -join ',') -eq 'saved,summary,sessionClosed:1') 'Progress failure still persists and closes session'
Assert ($report.Notifications.Count -eq 1) 'Progress close failure recorded'
# Without an opened toolkit session, finalization never tries to close one.
$script:events.Clear(); $script:SmUiOpen=$false; $script:UmUiOpen=$false
$script:SmSave={ param($Report) $script:events.Add('saved') }
$report=[pscustomobject]@{Status='complete';Mode='Report';Actions=@();Notifications=@();Errors=@();ReportPath='unused'}
Complete-SmRun $report | ForEach-Object { $script:events.Add('summary') }
Assert (($script:events -join ',') -eq 'saved,summary') 'No-session completion does not create or close a session'

# Exercise an actual nonreturning toolkit boundary in a child PowerShell host.
$scratch=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
$null=New-Item -ItemType Directory $scratch
try {
 $probe=Join-Path $scratch 'probe.ps1'
 @'
param($PackagePath,$Kind,$Status,$ReportPath)
$ErrorActionPreference='Stop'
$env:RELIAN_DEPLOY_TEST='1'
. $PackagePath
function Close-ADTInstallationProgress { }
function ConvertTo-SmSummary { param($Report,$Path) '{"status":"summaryPersisted"}' }
function ConvertTo-UmSummary { param($Report) '{"status":"summaryPersisted"}' }
function Close-ADTSession {
 [CmdletBinding()]param($ExitCode)
 if([IO.File]::ReadAllText($ReportPath) -ne 'saved') { exit 99 }
 exit $ExitCode
}
$script:SmSave={param($Report) [IO.File]::WriteAllText($Report.ReportPath,'saved')}
$script:UmSave={param($Report) [IO.File]::WriteAllText($Report.ReportPath,'saved')}
$script:SmUiOpen=$true; $script:UmUiOpen=$true
$r=[pscustomobject]@{Status=$Status;Mode='Report';Actions=@();Notifications=@();notification=@();Errors=@();ReportPath=$ReportPath}
if($Kind -eq 'storage') { Complete-SmRun $r } else { Complete-UmRun $r }
exit 98
'@ | Set-Content -LiteralPath $probe -Encoding UTF8
 foreach($case in @(@('storage','complete',0),@('storage','partial',0),@('storage','failed',1),@('update','reported',0),@('update','deferred',2),@('update','partial',1),@('update','failed',1))) {
  $name=if($case[0] -eq 'storage'){'storage-maintenance/Invoke-StorageMaintenance.ps1'}else{'update-maintenance/Invoke-UpdateMaintenance.ps1'}
  $package=Join-Path $PSScriptRoot ('../../windows/packages/'+$name)
  $output=@(& pwsh -NoProfile -File $probe $package $case[0] $case[1] (Join-Path $scratch 'report.json'))
  Assert ($LASTEXITCODE -eq $case[2]) 'Terminal toolkit receives actual package exit code'
  Assert (($output -join ' ') -match 'summaryPersisted') 'Summary emitted before actual terminal toolkit exit'
 }
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
Write-Output 'maintenance session closure tests passed' 
