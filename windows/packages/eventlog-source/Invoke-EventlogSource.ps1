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
    -Action Uninstall: remove only a source this package created, and only under the requested log. Install writes an
      ownership marker, HKLM\SOFTWARE\Relian\EventlogSource\<LogName>\<Source> (value Created, a UTC timestamp), and
      Uninstall removes nothing without it. A source that was already there at Install has no marker and is never
      removed. Windows sources are refused even with a marker: a deny list (Application Error, Windows Error
      Reporting, MsiInstaller, Application Hang, .NET Runtime, SecurityCenter) and any source whose message file is
      under %SystemRoot%, except under %SystemRoot%\Microsoft.NET, which is where .NET points a source created
      without a message file. A log is never deleted.

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
$script:ElMarkerRoot = 'SOFTWARE\Relian\EventlogSource'
$script:ElDenySources = @('Application Error', 'Windows Error Reporting', 'MsiInstaller', 'Application Hang', '.NET Runtime', 'SecurityCenter')
$script:ElMessageFiles = {
    param($log, $name)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services\EventLog\$log\$name")
    if ($null -eq $key) { return @() }
    try {
        @('EventMessageFile', 'CategoryMessageFile', 'ParameterMessageFile') | ForEach-Object {
            $v = $key.GetValue($_, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($v) { [string]$v }
        }
    } finally { $key.Dispose() }
}
$script:ElMarkerGet = {
    param($log, $name)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("$($script:ElMarkerRoot)\$log\$name")
    if ($null -eq $key) { return $false }
    try { return $null -ne $key.GetValue('Created', $null) } finally { $key.Dispose() }
}
$script:ElMarkerSet = {
    param($log, $name)
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey("$($script:ElMarkerRoot)\$log\$name")
    try { $key.SetValue('Created', [DateTime]::UtcNow.ToString('o'), [Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
}
$script:ElMarkerClear = {
    param($log, $name)
    [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKey("$($script:ElMarkerRoot)\$log\$name", $false)
}

# A Windows-owned source: on the deny list, or a message file under the Windows directory
# (but not under Microsoft.NET, the default for a source created without a message file).
function Test-ElProtected([string]$Log, [string]$Name) {
    if ($script:ElDenySources -contains $Name) { return $true }
    foreach ($f in @(& $script:ElMessageFiles $Log $Name)) {
        $t = ([string]$f).Trim('"')
        $win = $t -match '^(%SystemRoot%|%windir%|[A-Za-z]:\\Windows)\\'
        $dotnet = $t -match '^(%SystemRoot%|%windir%|[A-Za-z]:\\Windows)\\Microsoft\.NET\\'
        if ($win -and -not $dotnet) { return $true }
    }
    return $false
}

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
        if (Test-ElProtected $registered $Source) { return & $fail 'Source is a Windows source and is never removed' }
        if (-not [bool](& $script:ElMarkerGet $registered $Source)) { return & $fail 'Source was not created by this package (no ownership marker); not removed' }
        & $script:ElDelete $Source
        & $script:ElMarkerClear $registered $Source
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
    & $script:ElMarkerSet $back $Source
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
