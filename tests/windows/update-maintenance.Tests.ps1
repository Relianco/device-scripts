$ErrorActionPreference='Stop'
$env:RELIAN_DEPLOY_TEST='1'
. "$PSScriptRoot/../../windows/packages/update-maintenance/Invoke-UpdateMaintenance.ps1"
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
