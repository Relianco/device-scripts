# Read-only report of how the Intune Management Extension launched PowerShell for managed apps. Log reads are a seam.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'windows/jobs/inspect-ime-script-launch.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
. $modulePath

$ae = '11111111-2222-3333-4444-555555555555'
$wz = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$other = '99999999-8888-7777-6666-555555555555'
$fake = 'Q' * 24
$crlf = [string][char]13 + [char]10
function Entry { param($Text, $Time, $Date = '11-23-2026', $Thread = '1') "<![LOG[$Text]LOG]!><time=""$Time"" date=""$Date"" component=""x"" context="""" type=""1"" thread=""$Thread"" file="""">" }

# Shapes of IME log entries: the policy JSON names the app; AgentExecutor names the PowerShell it starts.
$appWorkload = (Entry ('[Win32App] Got policies: [{"Id":"' + $ae + '","Name":"Relian Managed - AutoElevate","Version":1,"InstallCommandLine":"x LICENSE=' + $fake + '"},{"Id":"' + $wz + '","Name":"Relian Managed - Wazuh"},{"Id":"' + $other + '","Name":"Some Other App"}]') '10:00:00.000') +
    $crlf + (Entry ("[Win32App][ActionProcessor] App with id: $ae, installer type: PowerShellScript, runAs32Bit: False") '10:00:01.000') +
    (Entry ('[Win32App] Got policies: [{"Id":"' + $ae + '","Name":"Relian Managed - AutoElevate"},{"Id":"' + $other + '","Name":"Some Other App","InstallEx":"{"RunAs32Bit":true}"}]') '10:05:00.000')
$agent = (Entry ("ExecutorLog AgentExecutor gets invoked" + $crlf + "powershell path is C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe") '10:00:02.000') +
    (Entry ("cmd line for running powershell is -NoProfile -executionPolicy bypass -file  ""C:\Windows\IMECache\$($ae)_1\install.ps1"" -Key $fake") '10:00:03.000') +
    (Entry ("powershell path is C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe") '11:30:00.000') +
    (Entry ("cmd line for running powershell is -NoProfile -file ""C:\Windows\IMECache\$($wz)_2\detect.ps1""") '11:30:01.000') +
    (Entry ("cmd line for running powershell is -file ""C:\Windows\IMECache\$($other)_1\install.ps1""") '11:31:00.000') +
    (Entry ("powershell path is C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe") '12:00:00.000' -Thread '7') +
    (Entry ("cmd line for running powershell is -file ""C:\Windows\IMECache\$($ae)_1\detect.ps1""") '12:00:01.000' -Thread '8')
$script:ImReadLogs = { @([pscustomobject]@{ Name = 'AppWorkload.log'; Text = $appWorkload }, [pscustomobject]@{ Name = 'AgentExecutor.log'; Text = $agent }) }

$r = Invoke-ImJob
Assert-Same $r.ExitCode 0 'exit'
Assert-True (-not $r.Line.Contains($fake)) 'no command-line value in output'
$j = $r.Line | ConvertFrom-Json
Assert-Same (($j.PSObject.Properties.Name) -join ',') 'job,status,apps,launches,error' 'output keys'
Assert-Same @($j.apps).Count 2 'only managed apps'
$a = @($j.apps | Where-Object { $_.id -eq $ae })[0]
Assert-Same $a.name 'Relian Managed - AutoElevate' 'app name from the policy JSON'
Assert-True (@($a.markers) -contains 'PowerShellScript') 'installer type marker'
Assert-True (@($a.markers) -contains 'runAs32Bit: False') 'runAs32Bit marker'
Assert-True (@($a.markers) -notcontains 'runAs32Bit: True') 'the next, unmanaged app policy is not this app''s'
$l = @($j.launches)
Assert-Same $l.Count 3 'three managed launches, the unmanaged app left out'
Assert-Same $l[0].appId $ae 'launch app id'
Assert-Same $l[0].app 'Relian Managed - AutoElevate' 'launch app name'
Assert-Same $l[0].powershell 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' 'powershell path paired with the next command line'
Assert-Same $l[0].script 'install.ps1' 'script file name only'
Assert-Same $l[0].time '2026-11-23 10:00:03' 'launch time'
Assert-Same $l[0].log 'AgentExecutor.log' 'log name'
Assert-Same $l[1].powershell 'C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe' 'SysWOW64 launch'
Assert-Same $l[1].script 'detect.ps1' 'detection script'
# A path logged on another thread is not this launch's: unknown.
Assert-Same $l[2].time '2026-11-23 12:00:01' 'cross-thread launch'
Assert-True ($null -eq $l[2].powershell) 'no path from another thread'

# No logs: ok with nothing; unreadable folder: failed.
$script:ImReadLogs = { @() }
Assert-Same ((Invoke-ImJob).Line | ConvertFrom-Json).status 'ok' 'no logs'
$script:ImReadLogs = { throw 'denied' }
$r = Invoke-ImJob
Assert-Same $r.ExitCode 2 'read failure exit'
Write-Output 'inspect-ime-script-launch: ok'
