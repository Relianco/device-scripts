<#
.SYNOPSIS
    Registers one Windows event log source, machine-wide, so a program that writes to it stops asking for admin rights to create it.

.DESCRIPTION
    Some programs check for their event log source on every start and, when it is missing, relaunch a helper
    elevated to create it. Registering the source once as SYSTEM stops that. Run it as SYSTEM through the deploy runner.

    Package arguments (base64 JSON in the runner's -PackageArguments), all string values. The runner decodes the
    JSON and passes each key to this script as a named parameter, so this script has no PackageArguments parameter:
      Source     required. 1 to 100 characters from [A-Za-z0-9 ._-].
      LogName    default Application. Same characters. Application is always allowed. Any other name must be a
                 custom log that already exists, or CreateLog=true must be passed. Trade-off: a custom log is a new
                 log with its own size and retention that the source is then bound to, so it is only worth it when
                 the program writes to that log name. System, Security, Setup and ForwardedEvents are never used.
      CreateLog  'true' lets Install create a missing custom log (CreateEventSource creates the log with the source).
      Section    'Evidence' is read-only: does the source exist, under which log, and its registry key. Nothing changes.

    -Action Install (Update, Repair): create the source when missing. Already there under the same log is a no-op.
      A source registered under a different log is refused and the log is named, because Windows keeps one log per source.
      The result is read back before it reports success.
    -Action Uninstall: remove only that source, and only when it is registered under the requested log.
      A log is never deleted.

    Uses [System.Diagnostics.EventLog]::CreateEventSource with EventSourceCreationData, which works on Windows
    PowerShell 5.1 and PowerShell 7. New-EventLog wraps the same call and does not exist in PowerShell 7.
    https://learn.microsoft.com/dotnet/api/system.diagnostics.eventlog.createeventsource
    An empty -PinVersion exits 0 and changes nothing, for every action.
    No download. Prints one JSON line, at most 2000 bytes. Exit 0 on success, 1 on any refusal or error.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType = '',
    [string]$Action = '',
    [string]$PinVersion = '',
    [string]$Section = '',
    [string]$Source = '',
    [string]$LogName = '',
    [string]$CreateLog = ''
)

$ErrorActionPreference = 'Stop'
$script:ElNamePattern = '\A[A-Za-z0-9 ._-]{1,100}\z'
$script:ElBuiltInLogs = @('System', 'Security', 'Setup', 'ForwardedEvents')
$script:ElKeyRoot = 'HKLM\SYSTEM\CurrentControlSet\Services\EventLog'
$script:ElMaxBytes = 2000

# Seams. Tests replace these; the defaults touch the real event log.
$script:ElSourceExists = { param($name) [System.Diagnostics.EventLog]::SourceExists($name) }
$script:ElLogOfSource = { param($name) [System.Diagnostics.EventLog]::LogNameFromSourceName($name, '.') }
$script:ElLogExists = { param($name) [System.Diagnostics.EventLog]::Exists($name) }
$script:ElCreate = {
    param($name, $log)
    [System.Diagnostics.EventLog]::CreateEventSource((New-Object System.Diagnostics.EventSourceCreationData($name, $log)))
}
$script:ElDelete = { param($name) [System.Diagnostics.EventLog]::DeleteEventSource($name) }

function Get-ElRegisteredLog([string]$Name) {
    if (-not [bool](& $script:ElSourceExists $Name)) { return $null }
    return [string](& $script:ElLogOfSource $Name)
}

function Test-ElSameLog([string]$A, [string]$B) { $A -ieq $B }

function Invoke-ElMain {
    param([string]$Action = '', [string]$Section = '', [string]$Source = '', [string]$LogName = '', [string]$CreateLog = '', [string]$PinVersion = 'pinned')
    $result = [ordered]@{ Package = 'eventlog-source'; Action = $Action; Section = $Section; Status = 'error' }
    # An empty pin is the off switch, as in the other packages: exit 0, change nothing, for every action.
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { $result.Status = 'disabled'; return @{ ExitCode = 0; Result = $result } }
    $fail = { param($reason) $result.Reason = $reason; return @{ ExitCode = 1; Result = $result } }

    if ($Section -notin @('', 'Evidence')) { return & $fail 'unsupported section' }
    $evidence = $Section -eq 'Evidence'
    $removing = $Action -eq 'Uninstall'
    if (-not $evidence -and -not $removing -and $Action -notin @('Install', 'Update', 'Repair')) { return & $fail 'unsupported action' }
    if ($CreateLog -notin @('', 'true', 'false')) { return & $fail 'CreateLog must be true or false' }
    if ($LogName -eq '') { $LogName = 'Application' }
    # Rejected values are not echoed, so the output stays bounded.
    if ($Source -cnotmatch $script:ElNamePattern) { return & $fail 'Source is required: 1 to 100 characters from A-Z a-z 0-9 space . _ -' }
    if ($LogName -cnotmatch $script:ElNamePattern) { return & $fail 'LogName must be 1 to 100 characters from A-Z a-z 0-9 space . _ -' }
    if ($script:ElBuiltInLogs -contains $LogName) { return & $fail "LogName $LogName is a built-in log and is not used" }
    $result.Source = $Source
    $result.LogName = $LogName

    $registered = Get-ElRegisteredLog $Source
    $result.SourceExists = $null -ne $registered
    $result.RegisteredLog = $registered
    $keyLog = if ($null -ne $registered) { $registered } else { $LogName }
    $result.RegistryKey = "$($script:ElKeyRoot)\$keyLog\$Source"

    if ($evidence) { $result.Status = 'evidence'; return @{ ExitCode = 0; Result = $result } }

    if ($removing) {
        if ($null -eq $registered) { $result.Status = 'absent'; return @{ ExitCode = 0; Result = $result } }
        if (-not (Test-ElSameLog $registered $LogName)) { return & $fail "Source is registered under log $registered, not $LogName; not removed" }
        & $script:ElDelete $Source
        if ($null -ne (Get-ElRegisteredLog $Source)) { return & $fail 'Source still registered after removal' }
        $result.Status = 'removed'
        return @{ ExitCode = 0; Result = $result }
    }

    if ($null -ne $registered) {
        if (-not (Test-ElSameLog $registered $LogName)) { return & $fail "Source is already registered under log $registered, not $LogName" }
        $result.Status = 'compliant'
        return @{ ExitCode = 0; Result = $result }
    }
    if ($LogName -ine 'Application' -and -not [bool](& $script:ElLogExists $LogName) -and $CreateLog -ne 'true') {
        return & $fail "log $LogName does not exist; pass CreateLog=true to create it"
    }
    & $script:ElCreate $Source $LogName
    $back = Get-ElRegisteredLog $Source
    if ($null -eq $back -or -not (Test-ElSameLog $back $LogName)) { return & $fail 'read-back after create did not find the source under the requested log' }
    $result.SourceExists = $true
    $result.RegisteredLog = $back
    $result.RegistryKey = "$($script:ElKeyRoot)\$back\$Source"
    $result.Status = 'applied'
    return @{ ExitCode = 0; Result = $result }
}

# One line, never more than ElMaxBytes: a long exception message is cut, not the fields around it.
function ConvertTo-ElLine($Result) {
    $line = ConvertTo-Json -InputObject $Result -Depth 3 -Compress
    if ([System.Text.Encoding]::UTF8.GetByteCount($line) -gt $script:ElMaxBytes -and $Result.Contains('Reason')) {
        $Result.Reason = ([string]$Result.Reason).Substring(0, [Math]::Min(200, ([string]$Result.Reason).Length))
        $line = ConvertTo-Json -InputObject $Result -Depth 3 -Compress
    }
    return $line
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

try {
    $run = Invoke-ElMain -Action $Action -Section $Section -Source $Source -LogName $LogName -CreateLog $CreateLog -PinVersion $PinVersion
} catch {
    $run = @{ ExitCode = 1; Result = [ordered]@{ Package = 'eventlog-source'; Status = 'error'; Reason = $_.Exception.Message } }
}
Write-Output (ConvertTo-ElLine $run.Result)
exit $run.ExitCode
