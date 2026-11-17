$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:RELIAN_DEPLOY_TEST = '1'
. (Join-Path $PSScriptRoot '../../windows/packages/autoelevate/Invoke-AutoElevate.ps1')
function Assert($ok, $message) { if (-not $ok) { throw "FAIL $message" } }

# Exercise the production service reader; replace only external Windows commands.
function Get-CimInstance {
    param($ClassName, $Filter, $ErrorAction)
    [pscustomobject]@{ State='Running'; StartMode='Auto'; AcceptStop=$false; ProcessId=4242 }
}
$script:ScExit = 0
function sc.exe {
    param($Operation, $Name)
    Assert ($Operation -eq 'qfailure' -and $Name -eq 'AutoElevateAgent') 'only reads service recovery configuration'
    $global:LASTEXITCODE = $script:ScExit
    $script:ScOutput -split "`n"
}
$script:ScOutput = @'
[SC] QueryServiceConfig2 SUCCESS

SERVICE_NAME: AutoElevateAgent
        RESET_PERIOD (in seconds)    : 86400
        REBOOT_MESSAGE               : REBOOT in a message is not an action
        COMMAND_LINE                 : helper.exe RESTART RUN PROCESS
        FAILURE_ACTIONS              : RESTART -- Delay = 60000 milliseconds.
                                       RESTART -- Delay = 60000 milliseconds.
                                       RESTART -- Delay = 60000 milliseconds.
'@
$r = & $script:GetAutoElevateService 'AutoElevateAgent'
Assert ($r.Recovery -ceq 'restart, restart, restart') 'headers and command text cannot invent recovery actions'
Assert ($r.Status -eq 'Running' -and $r.ProcessId -eq 4242 -and -not $r.CanStop) 'service state is unchanged'

$script:ScOutput = "[SC] QueryServiceConfig2 SUCCESS`n REBOOT_MESSAGE :`n FAILURE_ACTIONS :`n"
Assert ((& $script:GetAutoElevateService 'AutoElevateAgent').Recovery -eq 'none') 'explicit empty action list is none'
$script:ScOutput = "FAILURE_ACTIONS : RUN PROCESS -- Delay = 1000 milliseconds.`n REBOOT -- Delay = 2000 milliseconds.`n NONE -- Delay = 0 milliseconds."
Assert ((& $script:GetAutoElevateService 'AutoElevateAgent').Recovery -ceq 'run process, reboot, none') 'action rows retain order and all known types'
foreach ($output in @('', '[SC] OpenService FAILED 5: Access is denied.', 'ACTIONS_EN_CAS_ECHEC : REDEMARRER -- Delai = 60000 millisecondes.', 'FAILURE_ACTIONS : RESTART -- Delai = 60000 millisecondes.', "FAILURE_ACTIONS : RESTART -- Delay = 1 milliseconds.`n UNKNOWN -- Delay = 2 milliseconds.", 'RESTART -- Delay = 1 milliseconds.')) {
    $script:ScOutput = $output
    Assert ((& $script:GetAutoElevateService 'AutoElevateAgent').Recovery -eq 'unknown') 'unrecognized or absent evidence is unknown, never none or a partial list'
}
$script:ScOutput = 'FAILURE_ACTIONS : RESTART -- Delay = 1 milliseconds.'
$script:ScExit = 5
Assert ((& $script:GetAutoElevateService 'AutoElevateAgent').Recovery -eq 'unknown') 'native failure cannot report parsed recovery configuration'
Write-Output 'autoelevate-recovery tests passed'
