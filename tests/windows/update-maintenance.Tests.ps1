$ErrorActionPreference='Stop'
$env:RELIAN_DEPLOY_TEST='1'
. "$PSScriptRoot/../../windows/packages/update-maintenance/Invoke-UpdateMaintenance.ps1"
$actualUmCache=$script:UmCache
function Assert($value,$message) { if(-not $value) { throw $message } }
$a=Get-UmOptions
Assert ($a.Mode -eq 'Report' -and -not $a.Scan) 'Passive default'
foreach($bad in @('TRUE','1','yes')) { $threw=$false; try { Get-UmOptions -ResetCache $bad } catch { $threw=$true }; Assert $threw 'Strict boolean' }
Assert ((Get-UmLifecycle 'Professional' '22621' '22H2' ([datetime]'2026-11-04')).status -eq 'outOfSupport') '22H2 lifecycle'
Assert ((Get-UmLifecycle 'Professional' '22631' '23H2' ([datetime]'2025-11-11')).status -eq 'outOfSupport') '23H2 boundary'
Assert ((Get-UmLifecycle 'Enterprise' '22631' '23H2').status -eq 'unknown') 'Edition distinction'
Assert ((Get-UmLifecycle 'Professional' '22631' '22H2').status -eq 'unknown') 'Inconsistent release'
Assert ((@(Get-UmServicePlan @(@{Name='BITS';StartMode='Manual'},@{Name='UsoSvc';StartMode='Disabled'}))).Count -eq 0) 'Preserve manual/protected services'
Assert ((@(Get-UmServicePlan @(@{Name='BITS';StartMode='Disabled'}))).Count -eq 1) 'Recover disabled BITS'
$script:UmSnapshot={ @{osLifecycle=@{status='unknown'};services=@(@{Name='BITS';StartMode='Disabled'});policy=@{AUOptions=2}} }
$script:UmGuard={ @{Safe=$true;Reasons=@()} }
$script:UmSave={ param($r) }
$script:UmPrepare={ 'test-report.json' }
$script:UmAcquire={ $true }; $script:UmRelease={}
$script:UmUi={ param($s) 'noUser' }
$script:mutations=0; $script:scans=0
$script:UmService={ param($s) $script:mutations++; $script:UmSnapshot={ @{osLifecycle=@{status='unknown'};services=@();policy=@{AUOptions=2}} } }
$script:UmSearch={ param($a,$r) $script:scans++; @{outcome='scanSucceededNoApplicableUpdates';count=0} }
$r=Invoke-UmMaintenance (Get-UmOptions)
Assert ($script:mutations -eq 0 -and $script:scans -eq 0 -and $r.status -eq 'reported') 'Report is passive'
$script:UmGuard={ @{Safe=$false;Reasons=@('unknown staging')} }
$r=Invoke-UmMaintenance (Get-UmOptions -Mode Repair)
Assert ($r.status -eq 'deferred' -and $script:mutations -eq 0) 'Busy repair deferred'
$script:UmGuard={ @{Safe=$true;Reasons=@()} }
$r=Invoke-UmMaintenance (Get-UmOptions -Mode Repair)
Assert ($r.status -eq 'repaired' -and $script:mutations -eq 1 -and $r.scan.outcome -eq 'scanSucceededNoApplicableUpdates' -and $r.updateCurrency -eq 'notEstablished') 'Repair verified but currency unknown'
$script:UmSnapshot={ @{osLifecycle=@{status='unknown'};services=@(@{Name='BITS';StartMode='Disabled'});policy=@{AUOptions=2}} }
$script:UmService={ throw 'access denied' }
$r=Invoke-UmMaintenance (Get-UmOptions -Mode Repair)
Assert ($r.status -eq 'partial' -and $script:scans -eq 1) 'Service failure stops scan'
$script:UmSave={ throw 'persistence unavailable' }
$r=Invoke-UmMaintenance (Get-UmOptions -Mode Repair)
Assert ($r.status -eq 'failed') 'Persistence fail closed'

$script:UmSave={ param($r) }
$script:UmSnapshot={ @{osLifecycle=@{status='outOfSupport'};services=@();policy=@{AUOptions=2;TargetReleaseVersionInfo='23H2'}} }
$script:UmAcquire={ $false }
$r=Invoke-UmMaintenance (Get-UmOptions -Mode Repair)
Assert ($r.status -eq 'deferred') 'Contention'
$script:UmAcquire={ $true }
$script:UmUi={ throw 'UI failed' }
$r=Invoke-UmMaintenance (Get-UmOptions)
Assert ($r.status -eq 'reported' -and $r.notification -contains 'UI unavailable') 'UI independent'
$script:UmSearch={ param($a,$r) @{outcome='scanFailed';hresult=-1;count=0} }
$r=Invoke-UmMaintenance (Get-UmOptions -Mode Repair)
Assert ($r.status -eq 'failed' -and $r.scan.outcome -eq 'scanFailed') 'Failure is not empty success'
$script:natives=0
$script:UmNative={ param($p,$a,$r) $script:natives++; @{outcome='commandCompleted';exitCode=3010} }
$r=Invoke-UmMaintenance (Get-UmOptions -Mode Repair -RepairImage true)
Assert ($r.status -eq 'deferred' -and $r.rebootRequired -and $script:natives -eq 1) '3010 skips SFC and scan'
$script:UmNative={ param($p,$a,$r) $script:natives++; @{outcome='nativeStillRunning';pid=123} }
$r=Invoke-UmMaintenance (Get-UmOptions -Mode Repair -RepairImage true)
Assert ($r.status -eq 'deferred' -and $script:natives -eq 2) 'Surviving native deferred'
$script:UmNative={ param($p,$a,$r) $script:natives++; @{outcome='commandCompleted';exitCode=5} }
$r=Invoke-UmMaintenance (Get-UmOptions -Mode Repair -RepairImage true)
Assert ($r.status -eq 'partial' -and $script:natives -eq 3) 'DISM failure skips SFC'
$script:UmCache={ throw 'rename failed' }
$r=Invoke-UmMaintenance (Get-UmOptions -Mode Repair -ResetCache true)
Assert ($r.status -eq 'partial') 'Cache reset failure partial'
$script:checks=0
$script:UmGuard={ $script:checks++; @{Safe=($script:checks -lt 2);Reasons=@('race')} }
$r=Invoke-UmMaintenance (Get-UmOptions -Mode Repair -ResetCache true)
Assert ($r.status -eq 'failed') 'Fresh pre-step guard blocks race'
Assert ($r.before.policy.TargetReleaseVersionInfo -eq '23H2') 'Managed policy preserved'
$source=Get-Content "$PSScriptRoot/../../windows/packages/update-maintenance/Invoke-UpdateMaintenance.ps1" -Raw
Assert ($source -notmatch '(?i)Restart-Computer|shutdown\.exe|ResetBase|Ninja-Property|relian_git_deploy_token') 'No reboot or tenant APIs'
Assert ($source -match 'RedirectStandardOutput' -and $source -match 'creationTimeUtc' -and $source -match 'Global\\RelianWindowsMaintenance') 'Detached native shared guard contract'
'Update maintenance tests passed'
# Round 1 regressions exercise actual operation boundaries.
Assert ((Get-UmUpgradeDirectoryState @([datetime]'2026-10-01') 26200 @('22631') ([datetime]'2026-10-02') ([datetime]'2026-10-03')) -eq 'completedResidual') 'Completed upgrade keeps rollback directories without permanent block'
Assert ((Get-UmUpgradeDirectoryState @([datetime]'2026-10-04') 26200 @('22631') ([datetime]'2026-10-02') ([datetime]'2026-10-03')) -eq 'unknownStaging') 'New staging remains blocked'
Assert ((Get-UmUpgradeDirectoryState @([datetime]'2026-10-01') 26200 @() ([datetime]'2026-10-02') ([datetime]'2026-10-03')) -eq 'unknownStaging') 'Missing completion evidence blocked'
$script:UmGetController={ param($name) [pscustomobject]@{Status='StartPending'} }
$script:UmControl={ param($name,$desired) }
$script:UmDelay={}
$script:tick=0; $script:UmMilliseconds={ $script:tick+=1000; $script:tick }
$pending=Invoke-UmServiceState 'BITS' 'Running' 2
Assert ($pending.outcome -eq 'timeout' -and $pending.service -eq 'BITS') 'Pending service bounded'
# Actual descendant retains redirected output after shell process has exited.
if($IsLinux) {
 $root=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n')); $null=New-Item -ItemType Directory $root
 try {
  $childScript=Join-Path $root 'child.sh'; "sleep 3 &`nexit 0" | Set-Content $childScript
  $child=Start-Process /bin/sh -ArgumentList $childScript -RedirectStandardOutput (Join-Path $root 'out') -RedirectStandardError (Join-Path $root 'err') -PassThru
  while(-not $child.HasExited) { Start-Sleep -Milliseconds 10; $child.Refresh() }
  $watch=[diagnostics.stopwatch]::StartNew(); $completed=Complete-UmExitedProcess $child
  Assert ($watch.ElapsedMilliseconds -lt 700 -and $completed.outputComplete -eq 'notEstablished') 'Exited child never drains descendant-held streams'
 } finally { Remove-Item $root -Recurse -Force }
}
'Round 1 regressions passed'

# Exercise cache implementation: first stop succeeds, second remains pending,
# and finally records failed restoration rather than attempting any rename.
$script:UmCache=$actualUmCache
$script:UmGuard={ @{Safe=$true;Reasons=@()} }
$script:UmSave={ param($r) }
$script:states=@{BITS='Running';wuauserv='StopPending';CryptSvc='Running'}
$script:UmGetController={ param($name) [pscustomobject]@{Status=$script:states[$name]} }
$script:UmControl={ param($name,$desired) if($name -eq 'BITS') { if($desired -eq 'Running') { throw 'restoration denied' }; $script:states[$name]='Stopped' } }
$script:tick=0; $cacheReport=@{actions=@();errors=@();cacheBackups=@()}; $cacheFailed=$false
try { & $script:UmCache $cacheReport } catch { $cacheFailed=$true }
Assert ($cacheFailed -and @($cacheReport.actions | Where-Object { $_.phase -eq 'cacheRename' }).Count -eq 0) 'Partial stop never renames cache'
$restored=@($cacheReport.actions | Where-Object { $_.phase -eq 'cacheServiceRestoration' })
Assert ($restored.Count -eq 1 -and $restored[0].service -eq 'BITS' -and $restored[0].outcome -eq 'failed' -and $restored[0].errorCategory) 'Finally persists per-service restoration failure'
'Actual cache boundary regressions passed'
Assert ((Get-UmMoSetupState @{} $false) -eq 'residual') 'Empty historical MoSetup key'
Assert ((Get-UmMoSetupState @{SetupPhase=0} $true) -eq 'residual') 'Completed MoSetup phase'
Assert ((Get-UmMoSetupState @{SetupPhase=1} $true) -eq 'unknownOrActive') 'Positive MoSetup always blocks'
Assert ((Get-UmOwnUpgradeState @{status='staged';time='2026-10-01T00:00:00Z';isoBuild=26200} 26200 ([datetime]'2026-10-02')) -eq 'residual') 'Own marker build completed'
Assert ((Get-UmOwnUpgradeState @{status='staged';time='2026-10-03T00:00:00Z';isoBuild=26200} 22631 ([datetime]'2026-10-02')) -eq 'staged') 'Own staged pending reboot'
Assert ((Get-UmOwnUpgradeState @{status='staged';time='invalid';isoBuild=26200} 26200 ([datetime]'2026-10-02')) -eq 'unknown') 'Unreadable actual state blocks'
