$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../windows/packages/autoelevate/reference/ServiceRecovery.ps1')
$empty = [AeRecovery]::Empty()
if (-not (Test-AeRecoveryClear $empty)) { throw 'Empty snapshot must be clear' }
if ([AeRecovery]::WriteAccess($empty) -ne 2) { throw 'Clear needs CHANGE_CONFIG' }
$restart = [AeRecovery]::Empty()
$restart.Actions = @([AeRecovery+ActionItem]@{Type=1;Delay=300000})
if ([AeRecovery]::WriteAccess($restart) -ne 18) { throw 'Restoring RESTART requires CHANGE_CONFIG plus START' }
if (Test-AeRecoveryClear $restart) { throw 'Restart action must block termination' }
$empty.NonCrash = $true
if (Test-AeRecoveryClear $empty) { throw 'Noncrash recovery must block termination' }
$path = 'C:\Program Files (x86)\AutoElevate\AutoElevateAgent.exe'
$s = @{Name='AutoElevateAgent';ProcessId=42;PathName='"'+$path+'"'}
$p = @{Id=42;Path=$path}
if (-not (Test-AeServiceIdentity $s $p $path)) { throw 'Expected identity rejected' }
$p.Id=43
if (Test-AeServiceIdentity $s $p $path) { throw 'Changed PID accepted' }
$p.Id=42; $p.Path='C:\unexpected.exe'
if (Test-AeServiceIdentity $s $p $path) { throw 'Different executable accepted' }
$s.ProcessId=0; $p.Id=0; $p.Path=$path
if (Test-AeServiceIdentity $s $p $path) { throw 'PID zero accepted' }
if ((Get-AeStartupType 'Auto') -ne 'Automatic') { throw 'Startup mapping failed' }
$refused=$false
try { Get-AeStartupType 'unexpected' } catch { $refused=$true }
if (-not $refused) { throw 'Unknown startup mode accepted' }
Write-Output 'PASS: recovery access, clear and identity safeguards; no SCM calls or downloads'
