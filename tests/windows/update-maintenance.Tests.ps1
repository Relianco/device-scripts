$ErrorActionPreference='Stop'
$env:RELIAN_DEPLOY_TEST='1'
. "$PSScriptRoot/../../windows/packages/update-maintenance/Invoke-UpdateMaintenance.ps1"
$actualUmSave=$script:UmSave
$actualUmCache=$script:UmCache
$actualUmControl=$script:UmControl
function Assert($value,$message) { if(-not $value) { throw $message } }

# Strict historical inference is conjunctive; every missing or contradictory proof vetoes.
$proof=@{RegistryImage='IMAGE_STATE_COMPLETE'; IniImage='IMAGE_STATE_COMPLETE'; Setup=@{SystemSetupInProgress=0;OOBEInProgress=0;SetupPhase=0;SetupType=0;RestartSetup=0}; Values=@{SetupHostResult=0;DownlevelBuildNumber=26200;InstallScenario=1;DownlevelProductName='Windows'}; State=@{status='running';isoBuild=28000;time='2026-10-01T00:00:00Z'}; CurrentBuild=28000; PriorBuilds=@(26200); InstalledUtc=[datetime]'2026-10-02Z'; BootUtc=[datetime]'2026-10-03Z'}
Assert (Test-UmHistoricalUpgrade @proof) 'Complete bounded conjunction permits historical inference'
foreach($key in @('RegistryImage','IniImage','Setup','Values','State','PriorBuilds')) {
 $bad=$proof.Clone(); $bad[$key]=$null; Assert (-not (Test-UmHistoricalUpgrade @bad)) "Missing $key vetoes"
}
foreach($key in @('SystemSetupInProgress','OOBEInProgress','SetupPhase','SetupType','RestartSetup')) {
 $bad=$proof.Clone(); $bad.Setup=$proof.Setup.Clone(); $bad.Setup.Remove($key); Assert (-not (Test-UmHistoricalUpgrade @bad)) "Missing $key vetoes"
 $bad.Setup[$key]=1; Assert (-not (Test-UmHistoricalUpgrade @bad)) "Active $key vetoes"
}
foreach($change in @(@{SetupHostResult=1},@{SetupHostError=1},@{SetupPhase=1},@{Unknown=0},@{DownlevelBuildNumber=28000},@{DownlevelBuildNumber='invalid'})) {
 $bad=$proof.Clone(); $bad.Values=$proof.Values.Clone(); foreach($k in $change.Keys){$bad.Values[$k]=$change[$k]}; Assert (-not (Test-UmHistoricalUpgrade @bad)) 'Conflicting MoSetup vetoes'
}
foreach($target in @(27999,28001)) { $bad=$proof.Clone();$bad.State=$proof.State.Clone();$bad.State.isoBuild=$target; Assert (-not (Test-UmHistoricalUpgrade @bad)) 'Exact target required' }
foreach($stamp in @('bad','2026-10-03Z','2099-01-01Z')) { $bad=$proof.Clone();$bad.State=$proof.State.Clone();$bad.State.time=$stamp; Assert (-not (Test-UmHistoricalUpgrade @bad)) 'Invalid chronology vetoes' }


foreach($key in @('RegistryImage','IniImage')) { $bad=$proof.Clone();$bad[$key]='IMAGE_STATE_UNDEPLOYABLE';Assert (-not (Test-UmHistoricalUpgrade @bad)) 'Noncomplete image vetoes' }
foreach($key in @('SetupHostResult','DownlevelBuildNumber')) { $bad=$proof.Clone();$bad.Values=$proof.Values.Clone();$bad.Values.Remove($key);Assert (-not (Test-UmHistoricalUpgrade @bad)) 'Required MoSetup proof missing vetoes' }
$bad=$proof.Clone();$bad.PriorBuilds=@(28000);Assert (-not (Test-UmHistoricalUpgrade @bad)) 'Same build source vetoes'
$bad=$proof.Clone();$bad.BootUtc=[datetime]'2099-01-01Z';Assert (-not (Test-UmHistoricalUpgrade @bad)) 'Future boot vetoes'
$bad=$proof.Clone();$bad.Values=$proof.Values.Clone();$bad.Values.SetupHostError=0;$bad.Values.SetupPhase=0;Assert (Test-UmHistoricalUpgrade @bad) 'Optional error and phase numeric zero allowed'


# Confirmed marker absence uses dated matching Source OS provenance, never a broken marker.
$absentProof=$proof.Clone();$absentProof.State=$null;$absentProof.MarkerAbsent=$true;$absentProof.SourceEntries=@([pscustomobject]@{CurrentBuild=26200;InstallDate=1759276800})
Assert (Test-UmHistoricalUpgrade @absentProof) 'Confirmed absent marker with matching dated Source OS permits inference'
foreach($key in @('RegistryImage','IniImage','Setup','Values','PriorBuilds')) { $bad=$absentProof.Clone();$bad[$key]=$null;Assert (-not (Test-UmHistoricalUpgrade @bad)) "Absent-marker missing $key vetoes" }
$bad=$absentProof.Clone();$bad.Values=$absentProof.Values.Clone();$bad.Values.Unknown=0;Assert (-not (Test-UmHistoricalUpgrade @bad)) 'Absent-marker unknown metadata vetoes'

foreach($stamp in @($null,'bad',0,1790899200,4102444800,[double]::NaN)) { $bad=$absentProof.Clone();$bad.SourceEntries=@([pscustomobject]@{CurrentBuild=26200;InstallDate=$stamp});Assert (-not (Test-UmHistoricalUpgrade @bad)) "Missing malformed equal or future source time vetoes: $stamp" }
$bad=$absentProof.Clone();$bad.State=@{status='broken'};Assert (-not (Test-UmHistoricalUpgrade @bad)) 'Absence proof cannot accompany present marker'
$bad=$absentProof.Clone();$bad.SourceEntries=@([pscustomobject]@{CurrentBuild=28000;InstallDate=1759276800});Assert (-not (Test-UmHistoricalUpgrade @bad)) 'Same build source cannot prove historical upgrade'
$bad=$absentProof.Clone();$bad.SourceEntries=@();Assert (-not (Test-UmHistoricalUpgrade @bad)) 'Absent source proof vetoes'

foreach($helper in @('Grant-UmThemeReadAccess','Install-UmDialogTheme')) {
 $mandatory=@((Get-Command $helper).Parameters.Values | ForEach-Object { $_.Attributes } | Where-Object { $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory })
 Assert ($mandatory.Count -eq 0) 'Theme helpers cannot prompt for missing arguments'
 $refused=$false; try { & $helper } catch { $refused=$_.Exception.Message -match 'must not be empty' }
 Assert $refused 'Missing theme helper arguments fail explicitly before work'
}

$migrationData=$env:ProgramData; if(-not $env:ProgramData) { $env:ProgramData=[IO.Path]::GetTempPath() }

# Pilot regression: package evidence is independent of a pre-existing Relian root.
$paths=@(Get-UmNativeMarkerPaths)
Assert ($paths[0] -eq (Join-Path $env:ProgramData 'RelianMaintenance\native-active.json')) 'Owned maintenance marker root'
Assert ($paths[1] -eq (Join-Path $env:ProgramData 'Relian\Maintenance\native-active.json')) 'Legacy marker remains read-only guard evidence'
$initializer=${function:Initialize-UmSecureDirectory}.ToString()
Assert ($initializer.Contains("'RelianMaintenance'") -and $initializer.Contains('if(-not $created)')) 'Owned root itself is validated before existing-root reuse'
$env:ProgramData=$migrationData
# Run the real preparation block with only its ACL boundary replaced. Its requested
# destination must be the owned root, independently of the legacy Relian tree.
& {
 $scratch=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n')); $null=New-Item -ItemType Directory $scratch
 $priorData=$env:ProgramData; $env:ProgramData=$scratch
 try {
  function Initialize-UmSecureDirectory { param($Path) Assert ($Path.StartsWith((Join-Path $env:ProgramData 'RelianMaintenance'))) 'Actual preparation only requests owned root'; $scratch }
  function Test-UmSafePath { $true }
  $prepared=& $script:UmPrepare
  Assert ($prepared.StartsWith($scratch) -and (Test-Path -LiteralPath $scratch)) 'Actual evidence preparation succeeds with independent root'
 } finally { $env:ProgramData=$priorData; Remove-Item -LiteralPath $scratch -Recurse -Force }
}
# Exercise both guard marker branches before a deliberately unavailable registry.
& {
 $priorData=$env:ProgramData; $env:ProgramData=[IO.Path]::GetTempPath()
 try {
  function Get-CimInstance { @() }
  function Get-ItemProperty { throw 'offline registry boundary' }
  foreach($script:migrationMarker in @(Get-UmNativeMarkerPaths)) {
   function Test-Path { param($LiteralPath) $LiteralPath -eq $script:migrationMarker }
   $guard=Get-UmGuards
   Assert (-not $guard.Safe -and $guard.Light -and ($guard.Reasons -join ';') -match 'native-active marker present') 'New and legacy markers each fail closed'
  }
 } finally { $env:ProgramData=$priorData; Remove-Variable migrationMarker -Scope Script -ErrorAction SilentlyContinue }
}
Assert (${function:Get-UmGuards}.ToString().Contains('Relian\FeatureUpgrade\state.json')) 'FeatureUpgrade state remains at original read-only path'
if($env:OS -eq 'Windows_NT') {
 & {
  $priorData=$env:ProgramData; $root=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n')); $env:ProgramData=$root
  $null=New-Item -ItemType Directory -Path (Join-Path $root 'Relian') -Force
  $script:migrationAcl=[pscustomobject]@{Owner='S-1-5-18'}
  $script:migrationAcl | Add-Member ScriptMethod GetOwner { param($Type) [pscustomobject]@{Value=$this.Owner} }
  $script:migrationAcl | Add-Member ScriptMethod GetAccessRules { param($Explicit,$Inherited,$Type) @() }
  $script:migrationAclPaths=@()
  # Only the Windows ACL boundary is mocked. Path creation, ancestry walk,
  # existing-directory checks and reparse checks are the actual initializer.
  function Get-Acl { param($LiteralPath) $script:migrationAclPaths+=$LiteralPath; $script:migrationAcl }
  function Set-Acl { param($LiteralPath,$AclObject) $script:migrationAclPaths+=$LiteralPath }
  try {
   $owned=Join-Path $root 'RelianMaintenance'
   $result=Initialize-UmSecureDirectory (Join-Path $owned 'Update')
   Assert (Test-Path -LiteralPath $result) 'Actual initialization creates independent report directory'
   Assert (@($script:migrationAclPaths | Where-Object { -not $_.StartsWith($owned+'\') -and $_ -ne $owned }).Count -eq 0) 'Initialization never inspects or changes unrelated Relian ACL'
   $script:migrationAcl.Owner='S-1-5-21-1-2-3-1001'; $refused=$false
   try { Initialize-UmSecureDirectory $owned } catch { $refused=$_.Exception.Message -match 'untrusted owner' }
   Assert $refused 'Existing untrusted owned root refused even when terminal target'
  } finally { $env:ProgramData=$priorData; Remove-Item -LiteralPath $root -Recurse -Force; Remove-Variable migrationAcl,migrationAclPaths -Scope Script -ErrorAction SilentlyContinue }
 }
} else { 'Windows actual-directory initialization/ACL-boundary isolation test skipped on this platform' }
# Consolidated review regressions: malformed evidence never establishes completion.
foreach($state in @(@{status='staged';isoBuild=1;time='2026-11-04T00:00:00Z'},@{status='staged';isoBuild=26200;time='2099-01-01T00:00:00Z'})) {
 Assert ((Get-UmOwnUpgradeState $state 22631 ([datetime]'2026-11-03')) -eq 'unknown') 'Invalid/future staged evidence must block'
}
$aclSource=${function:Initialize-UmSecureDirectory}.ToString()
Assert ($aclSource.Contains('GetOwner') -and $aclSource.Contains('DeleteSubdirectoriesAndFiles')) 'Updater validates ordinary existing ancestor ACL trust'
Assert (${function:Wait-UmEventWorker}.ToString().Contains('UmGuard')) 'Event wait checks Setup transitions'

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
Assert ($source -match 'CreateProcess' -and $source -match 'UpdateProcThreadAttribute' -and $source -match 'creationTimeUtc' -and $source -match 'Global\\RelianWindowsMaintenance') 'Detached native shared guard contract'
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

# Round 2: exercise the real control adapter, only the Win32 syscall is mocked.
$script:recursiveCalls=0; $script:rawStops=0
$fake=[pscustomobject]@{Status='Running';Name='CryptSvc'}
$fake | Add-Member ScriptMethod Stop { $script:recursiveCalls++; throw 'dependent recursively stopped' }
$fake | Add-Member ScriptMethod Dispose {}
$script:UmGetController={ param($name) $fake }
$script:UmStopRequest={ param($controller) $script:rawStops++; 1051 }
$script:UmControl=$actualUmControl
$script:tick=0
$dependent=Invoke-UmServiceState 'CryptSvc' 'Stopped' 2
Assert ($dependent.outcome -eq 'failed' -and $dependent.nativeCode -eq 1051 -and $dependent.errorCategory -eq 'runningDependentServices') 'Running dependent safely refused by SCM'
Assert ($script:recursiveCalls -eq 0 -and $script:rawStops -eq 1) 'Never recursively stops dependent services'
'Nonrecursive SCM regression passed'
$script:states=@{BITS='Running';wuauserv='Stopped';CryptSvc='Running';DependentService='Running'}
$script:UmGetController={ param($name)
 $c=[pscustomobject]@{Name=$name;Status=$script:states[$name]}
 $c | Add-Member ScriptMethod Stop { $script:recursiveCalls++; $script:states.DependentService='Stopped' }
 $c | Add-Member ScriptMethod Start { $script:states[$this.Name]='Running' }
 $c | Add-Member ScriptMethod Dispose {}
 $c
}
$script:UmStopRequest={ param($controller)
 if($controller.Name -eq 'CryptSvc') { return 1051 }
 $script:states[$controller.Name]='Stopped'; 0
}
$script:tick=0; $dependentReport=@{actions=@();errors=@();cacheBackups=@()}; $refused=$false
try { & $actualUmCache $dependentReport } catch { $refused=$true }
Assert ($refused -and $script:states.DependentService -eq 'Running' -and $script:recursiveCalls -eq 0) 'Cache reset preserves live dependent'
Assert ($script:states.BITS -eq 'Running' -and $script:states.CryptSvc -eq 'Running') 'Cache finally restores only explicitly stopped services'
Assert (@($dependentReport.actions | Where-Object { $_.nativeCode -eq 1051 -and $_.service -eq 'CryptSvc' }).Count -eq 1) 'Dependent refusal persisted'
Assert (@($dependentReport.actions | Where-Object { $_.phase -eq 'cacheRename' }).Count -eq 0) 'Dependent refusal prevents rename'
'Nonrecursive cache restoration regression passed'

# A blocked event provider is a real disposable local process, never a live query.
$eventGuard=$script:UmGuard
$hang=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' -PassThru
try {
 $script:UmGuard={ @{Safe=$true;Reasons=@()} }
 $wait=Wait-UmEventWorker $hang 0.3
 Assert ($wait.outcome -eq 'timeout' -and $wait.elapsedSeconds -lt 3) 'Blocked event provider has parent deadline'
 Assert ($hang.WaitForExit(2000)) 'Timed-out evidence child stopped'
} finally { if(-not $hang.HasExited) { $hang.Kill() }; $hang.Dispose() }
$hang=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' -PassThru
try {
 $script:UmGuard={ @{Safe=$false;Light=$true;Reasons=@('Setup began')} }
 $wait=Wait-UmEventWorker $hang 10
 Assert ($wait.outcome -eq 'guardChanged' -and $wait.elapsedSeconds -lt 3) 'Setup transition interrupts event provider'
 Assert ($hang.WaitForExit(2000)) 'Servicing-interrupted evidence child stopped'
} finally { if(-not $hang.HasExited) { $hang.Kill() }; $hang.Dispose(); $script:UmGuard=$eventGuard }
# Compile the standalone Windows interop on every platform. Execution below is
# Windows-only: POSIX redirection is not evidence for Windows handle inheritance.
foreach($prefix in @('Um','Sm')) {
 if($prefix -eq 'Sm') { . "$PSScriptRoot/../../windows/packages/storage-maintenance/Invoke-StorageMaintenance.ps1" }
 $native=(Get-Item ('Function:Start-'+$prefix+'DurableProcess')).Definition
 $match=[regex]::Match($native,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
 Assert $match.Success 'Standalone native launcher source present'
 if(-not (('Relian'+$prefix+'Native') -as [type])) { Add-Type -TypeDefinition $match.Groups[1].Value }
 Assert ($native.Contains('0x20002') -and $native.Contains('3*IntPtr.Size') -and $native.Contains('ResumeThread')) 'Only exact three native handles inherited, exact identity acquired before resume'
}
if($env:OS -eq 'Windows_NT') {
 foreach($prefix in @('Um','Sm')) {
  $root=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n')); $null=New-Item -ItemType Directory $root
  $parent=$null; $nativeChild=$null; $nativeFailure=$null
  try {
   $late=Join-Path $root 'late.ps1'; $out=Join-Path $root 'native.out'; $err=Join-Path $root 'native.err'; $identity=Join-Path $root 'identity.xml'
   # The child writes after its launching PowerShell has already exited.
   'Start-Sleep -Seconds 6; [Console]::Out.WriteLine("late-out:"+$PID); [Console]::Error.WriteLine("late-error:"+$PID)' | Set-Content -LiteralPath $late
   $package=Join-Path $PSScriptRoot ('../../windows/packages/'+$(if($prefix -eq 'Um'){'update-maintenance/Invoke-UpdateMaintenance.ps1'}else{'storage-maintenance/Invoke-StorageMaintenance.ps1'}))
   $quote={param($v) "'"+$v.Replace("'","''")+"'"}
   $exe=(Get-Process -Id $PID).Path
   $command='$env:RELIAN_DEPLOY_TEST="1"; . '+(& $quote $package)+'; $p=Start-'+$prefix+'DurableProcess '+(& $quote $exe)+' '+(& $quote ('-NoProfile -NonInteractive -File "'+$late+'"'))+' '+(& $quote $out)+' '+(& $quote $err)+'; @{pid=$p.Id;start=$p.StartTime.ToUniversalTime().ToString("o")} | Export-Clixml -LiteralPath '+(& $quote $identity)
   $psi=New-Object Diagnostics.ProcessStartInfo
   $psi.FileName=$exe; $psi.Arguments='-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)); $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
   $parent=[Diagnostics.Process]::Start($psi); $parentOut=$parent.StandardOutput.ReadToEndAsync(); $parentErr=$parent.StandardError.ReadToEndAsync()
   Assert ($parent.WaitForExit(10000) -and $parent.ExitCode -eq 0) 'Native launching parent exits successfully'
   $nativeIdentity=Import-Clixml -LiteralPath $identity
   $observedChild=[Diagnostics.Process]::GetProcessById([int]$nativeIdentity.pid)
   # Retain a kernel process handle while alive, as the production launcher does.
   $null=$observedChild.Handle
   Assert ($observedChild.StartTime.ToUniversalTime().ToString('o') -eq $nativeIdentity.start) 'Synthetic child identity matches exact creation time'
   $nativeChild=$observedChild
   Assert ($parentOut.Wait(1000) -and $parentErr.Wait(1000)) 'Native child does not retain ancestor stdout/stderr pipes'
   Assert (-not $nativeChild.HasExited) 'Synthetic native child outlives its launching parent'
   # Output can arrive before process teardown closes its native log handles.
   # Observe process completion before opening/deleting logs, rather than racing it.
   $childCompleted=$nativeChild.WaitForExit(15000)
   $childExitCode=$null; if($childCompleted) { $childExitCode=$nativeChild.ExitCode }
   if(-not $childCompleted -or $childExitCode -ne 0) {
    Write-Host ('Native regression '+$prefix+': waited='+$childCompleted+'; hasExited='+$nativeChild.HasExited+'; exitCode='+$childExitCode+'; exitCodeNull='+($null -eq $childExitCode))
    foreach($log in @($out,$err)) {
     try { $logText=Get-Content -LiteralPath $log -Raw -ErrorAction Stop; if($logText -and $logText.Length -gt 4000) { $logText=$logText.Substring(0,4000) }; Write-Host ([IO.Path]::GetFileName($log)+': '+$logText) } catch { Write-Host ('Native log unavailable: '+$_.Exception.Message) }
    }
   }
   Assert $childCompleted 'Synthetic native child completion timed out after parent exit'
   Assert ($childExitCode -eq 0) ('Synthetic native child failed after parent exit: exitCode='+$childExitCode)
   Assert ((Get-Content -LiteralPath $out -Raw).Trim() -eq ('late-out:'+$nativeIdentity.pid)) 'Late stdout survives launcher exit with exact native PID'
   Assert ((Get-Content -LiteralPath $err -Raw).Trim() -eq ('late-error:'+$nativeIdentity.pid)) 'Late stderr survives launcher exit'
  } catch { $nativeFailure=$_; throw } finally {
   try {
    # Only this exact test-created process handle may be stopped on a failed test.
    if($nativeChild) {
     if(-not $nativeChild.HasExited -and -not $nativeChild.WaitForExit(15000)) { $nativeChild.Kill(); Assert ($nativeChild.WaitForExit(5000)) 'Synthetic child cleanup completed' }
     $nativeChild.Dispose()
    }
    if($parent) {
     if(-not $parent.HasExited) { $parent.Kill(); $null=$parent.WaitForExit(5000) }
     $parent.Dispose()
    }
    Remove-Item -LiteralPath $root -Recurse -Force
   } catch {
    if($nativeFailure) { Write-Warning ('Native regression cleanup also failed: '+$_.Exception.Message) } else { throw }
   }
  }
 }
 # Ordinary directory with untrusted ownership/rights must fail before child ACL
 # rewriting. This uses only an isolated temporary ProgramData substitute.
 $savedData=$env:ProgramData; $root=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
 try {
  $env:ProgramData=$root; $ancestor=Join-Path $root 'RelianMaintenance'; $null=New-Item -ItemType Directory -Path $ancestor -Force
  $acl=Get-Acl -LiteralPath $ancestor
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')),'Modify','ContainerInherit,ObjectInherit','None','Allow')))
  Set-Acl -LiteralPath $ancestor -AclObject $acl
  $refused=$false; try { Initialize-UmSecureDirectory (Join-Path $ancestor 'Maintenance\Update') } catch { $refused=$true }
  Assert $refused 'Ordinary untrusted common ancestor refused'
 } finally { $env:ProgramData=$savedData; Remove-Item -LiteralPath $root -Recurse -Force }
} else { 'Windows native parent-exit/pipe-inheritance and NTFS ACL execution tests skipped on this platform' }
'Consolidated final regressions passed'

$realPrepare=$script:UmPrepare
$script:UmPrepare={ throw 'Shared evidence ancestor grants untrusted modification rights' }
try { $failure=Invoke-UmMaintenance (Get-UmOptions); Assert ($failure.status -eq 'failed' -and $failure.errors[0].detail -eq 'EvidenceAncestorUntrustedRights') 'Initialization refusal carries sanitized actionable category' }
finally { $script:UmPrepare=$realPrepare }
$realEvents=$script:UmEvents; $realGuard=$script:UmGuard
try {
 $script:UmGuard={ @{Safe=$true;Light=$false;Reasons=@()} }
 $script:UmEvents={ @{outcome='timeout';events=@()} }
 $timeoutReport=Invoke-UmMaintenance (Get-UmOptions)
 Assert ($timeoutReport.eventEvidence.outcome -eq 'timeout' -and ($timeoutReport.omissions -join ';') -match 'timeout') 'Event deadline produces explicit omitted evidence'
 $script:UmEvents={ @{outcome='guardChanged';events=@();reasons=@('Setup began')} }
 $transitionReport=Invoke-UmMaintenance (Get-UmOptions -Mode Repair)
 Assert ($transitionReport.status -eq 'deferred' -and $transitionReport.actions.Count -eq 0) 'Event Setup transition defers repair before mutation'
} finally { $script:UmEvents=$realEvents; $script:UmGuard=$realGuard }
# Pilot regression: real create + two File.Replace checkpoints, including a
# serialized snapshot. Only Windows ACL/path validation boundaries are stubbed.
& {
 $root=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n')); $null=New-Item -ItemType Directory $root
 function Initialize-UmSecureDirectory { param($Path) $Path }
 function Test-UmSafePath { $true }
 function New-Object {
  param($TypeName)
  Assert ($TypeName -eq 'Security.AccessControl.FileSecurity') 'Only platform file ACL constructor is stubbed'
  $acl=[pscustomobject]@{}; $acl | Add-Member ScriptMethod SetSecurityDescriptorSddlForm { param($Sddl) }; $acl
 }
 function Set-Acl { param($LiteralPath,$AclObject) }
 try {
  $path=Join-Path $root 'report.json'
  Write-UmJson @{status='started';before=$null} $path
  Write-UmJson @{status='reported';before=@{services=@(@{Name='BITS';StartMode='Manual'});volumes=@(@{DeviceID='C:';FreeSpace=12345})}} $path
  $first=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  Assert ($first.before.volumes[0].FreeSpace -eq 12345) 'First real replacement persists JSON snapshot'
  Write-UmJson @{status='reported';before=$first.before;checkpoint=3} $path
  $last=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  Assert ($last.checkpoint -eq 3 -and $last.before.services[0].Name -eq 'BITS') 'Second real replacement preserves snapshot'
  Assert (-not (Test-Path -LiteralPath ($path+'.tmp'))) 'Real replacement consumes temporary checkpoint file'
  $savedSave=$script:UmSave; $savedPrepare=$script:UmPrepare; $savedGuard=$script:UmGuard; $savedEvents=$script:UmEvents; $savedSnapshot=$script:UmSnapshot
  try {
   $script:UmSave=$actualUmSave
   $script:UmPrepare={ Join-Path $root 'passive-report.json' }
   $script:UmGuard={ @{Safe=$true;Light=$false;Reasons=@()} }; $script:UmEvents={ @{outcome='complete';events=@()} }
   $script:UmSnapshot={ @{osLifecycle=@{status='unknown'};services=@(@{Name='BITS';StartMode='Manual'});volumes=@(@{DeviceID='C:';FreeSpace=12345})} }
   $passive=Invoke-UmMaintenance (Get-UmOptions -Notify false)
   Assert ($passive.status -eq 'reported' -and $passive.errors.Count -eq 0) 'Actual passive Report performs repeated real checkpoints successfully'
   $persisted=Get-Content -LiteralPath $passive.reportPath -Raw | ConvertFrom-Json
   Assert ($persisted.before.volumes[0].FreeSpace -eq 12345 -and $persisted.status -eq 'reported') 'Actual Report persists structured snapshot through real replacement'
   $passiveSummary=ConvertTo-UmSummary $passive | ConvertFrom-Json
   Assert ($passiveSummary.scan.outcome -eq 'notRequested' -and $null -eq $passiveSummary.scan.count -and $null -eq $passiveSummary.scan.hresult) 'Actual passive Report stdout has no invented scan count'
  } finally { $script:UmSave=$savedSave; $script:UmPrepare=$savedPrepare; $script:UmGuard=$savedGuard; $script:UmEvents=$savedEvents; $script:UmSnapshot=$savedSnapshot }

 } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

# Runtime guards retain independent vetoes while historical inference is re-evaluated.
& {
 $env:SystemDrive='/'; $env:SystemRoot='/'; $env:ProgramData='/tmp'
 $script:guardCase='clear';$script:guardStateAbsent=$false
 function Get-CimInstance { param($ClassName) if($script:guardCase -eq 'probeError'){throw 'probe failed'}; if($ClassName -eq 'Win32_OperatingSystem'){return [pscustomobject]@{LastBootUpTime=[datetime]'2026-10-03Z'}}; if($script:guardCase -eq 'process'){[pscustomobject]@{Name='setuphost.exe'}} }
 function Test-Path { param($LiteralPath) if($LiteralPath -match 'state.json'){if($script:guardCase -eq 'stateProbeError'){throw 'state probe failed'};if($script:guardCase -eq 'stateProbeUnknown'){return $null};return (-not $script:guardStateAbsent)};if($LiteralPath -match 'MoSetup'){return $true}; if($script:guardCase -eq 'native' -and $LiteralPath -match 'native-active'){return $true}; if($script:guardCase -eq 'staging' -and $LiteralPath -match '~BT'){return $true}; return $false }
 function Get-ItemProperty { param($Path,$LiteralPath)
  if(-not $Path){$Path=$LiteralPath}
  if($Path -match 'Session Manager'){return [pscustomobject]@{PendingFileRenameOperations=$(if($script:guardCase -eq 'rename'){@('pending')})}}
  if($Path -match 'CurrentVersion\\Setup\\State'){return [pscustomobject]@{ImageState='IMAGE_STATE_COMPLETE'}}
  if($Path -match 'Windows NT'){return [pscustomobject]@{CurrentBuild='28000';InstallDate=1790899200}}
  if($Path -eq 'prior'){if($script:guardCase -eq 'sourceReadError'){throw 'source read failed'};return [pscustomobject]@{CurrentBuild='26200';InstallDate=1759276800}}
  [pscustomobject]@{SystemSetupInProgress=0;OOBEInProgress=0;SetupPhase=0;SetupType=0;RestartSetup=0}
 }
 function Get-ChildItem { [pscustomobject]@{PSChildName='Source OS';PSPath='prior'} }
 function Get-Item { param($LiteralPath)
  if($LiteralPath -match '~BT'){return [pscustomobject]@{PSIsContainer=$true;Attributes=0;CreationTimeUtc=[datetime]'2026-10-01Z'}}
  $k=[pscustomobject]@{}; $k | Add-Member ScriptMethod GetValueNames { @('SetupHostResult','DownlevelBuildNumber','InstallScenario') }; $k | Add-Member ScriptMethod GetValueKind { param($n) 'DWord' }; $k | Add-Member ScriptMethod GetValue { param($n) switch($n){SetupHostResult{0};DownlevelBuildNumber{26200};InstallScenario{1}} }; $k
 }
 function Read-UmBoundedText { param($Path,$MaxBytes) if($script:guardCase -eq 'fileError'){throw 'unreadable'}; if($script:guardCase -eq 'badMarker' -and $Path -match 'state.json'){return '{broken'};if($Path -match 'State.ini'){return '[State]`nImageState="IMAGE_STATE_COMPLETE"'.Replace('`n',"`n")}; return '{"status":"running","isoBuild":28000,"time":"2026-10-01T00:00:00Z"}' }
 $g=Get-UmGuards; Assert ($g.Safe -and $g.HistoricalUpgradeInference) 'Runtime conjunction infers residue'
 $script:guardCase='rename';$g=Get-UmGuards; Assert (-not $g.Safe -and $g.HistoricalUpgradeInference) 'Pending rename always vetoes mutations'
 foreach($case in @('probeError','fileError','process','native','staging')) { $script:guardCase=$case;$g=Get-UmGuards; Assert (-not $g.Safe -and -not $g.HistoricalUpgradeInference) "Runtime $case vetoes inference" }
 $script:guardCase='badMarker';$g=Get-UmGuards;Assert (-not $g.Safe -and -not $g.HistoricalUpgradeInference) 'Present malformed marker never becomes absence'
 $script:guardStateAbsent=$true;$script:guardCase='clear';$g=Get-UmGuards;Assert ($g.Safe -and $g.HistoricalUpgradeInference -and $g.HistoricalUpgradeEvidence.MarkerAbsent) 'Runtime confirmed absence with dated source infers historical residue'
 $script:guardCase='rename';$g=Get-UmGuards;Assert (-not $g.Safe -and $g.HistoricalUpgradeInference) 'Absent marker still retains pending rename veto'
 foreach($case in @('probeError','fileError','process','native','staging','sourceReadError','stateProbeError','stateProbeUnknown')) { $script:guardCase=$case;$g=Get-UmGuards;Assert (-not $g.Safe -and -not $g.HistoricalUpgradeInference) "Absent-marker runtime $case vetoes" }

}
