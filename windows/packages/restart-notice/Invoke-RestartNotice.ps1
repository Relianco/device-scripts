<#
.SYNOPSIS
    Restarts a Windows device that is waiting for a restart, with a notice to the
    signed-in user, for the Relian deploy runner (NinjaOne script 374).

.DESCRIPTION
    One run, as SYSTEM:
      1. No restart pending (Windows servicing, Windows Update, or a feature upgrade
         staged by the feature-upgrade package): result none, snooze marker cleared.
      2. A snooze that has not run out: result snoozed. Nothing is shown.
      3. Nobody signed in (confirmed): result restartedNoUser, then restart now.
      4. Only a disconnected user: no notice can show; the countdown is waited
         out without one, then restart.
      5. Someone signed in, or it cannot tell: notice 1 with Restart now and one
         snooze. Restart now restarts. Snooze writes the marker and exits.
         No answer, or the snooze was already used: notice 2, a countdown with
         Restart now and no snooze, then restart. Restart now on the countdown
         restarts at once (result restarted, button Restart now). If the toolkit
         finds no user to show notice 1 to, a second check decides: nobody, restartedNoUser
         (reason toolkitNoUser); otherwise the countdown without a notice.
      Any other error: result failed, exit 1.

    The result is written to the NinjaOne device field relianRestartNotice before
    any restart, because nothing runs after it, and printed last on stdout.

    PackageArguments (all optional strings):
      Message           Body of notice 1. Default: a plain "needs to restart" line.
      SnoozeMinutes     5 to 240, default 60. The one snooze; never extended.
      PromptMinutes     1 to 55, default 10. How long notice 1 waits for an answer.
      CountdownMinutes  1 to 60, default 15. Countdown on notice 2.
      ReportOnly        true or false, default false. true: detection only, written
                        to the device field relianSessionState. No notice, no
                        snooze marker change, no restart.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM. Uninstall exits 0.
#>

# Not Mandatory: a mandatory param block prompts when this file is dot-sourced
# under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Message = '',
    [string]$SnoozeMinutes = '',
    [string]$PromptMinutes = '',
    [string]$CountdownMinutes = '',
    [string]$ReportOnly = '',
    [string]$MaintenanceRestart = 'false'
)

$ProgressPreference = 'SilentlyContinue'

$RnFieldName = 'relianRestartNotice'
$RnReportField = 'relianSessionState'
$RnMarkerKey = 'HKLM:\SOFTWARE\Relian\RestartNotice'
$RnFupState = [IO.Path]::Combine("$env:ProgramData", 'Relian', 'FeatureUpgrade', 'state.json')
$RnDefaultMessage = 'Windows needs to restart to finish an update. Save your work.'

function Write-Status {
    param([string]$Text, [string]$Level = 'INFO')
    Write-Host "[$Level] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Text"
}

# Pure: validated arguments. Throws on anything malformed.
function Get-RnArgs {
    param([string]$Message, [string]$SnoozeMinutes, [string]$PromptMinutes, [string]$CountdownMinutes, [string]$ReportOnly = '', [string]$MaintenanceRestart = 'false')
    $a = @{ Message = $RnDefaultMessage; SnoozeMinutes = 60; PromptMinutes = 10; CountdownMinutes = 15; ReportOnly = $false }
    if($MaintenanceRestart -cnotmatch '\A(true|false)\z') { throw 'MaintenanceRestart must be true or false.' }
    $a.MaintenanceRestart=$MaintenanceRestart -ceq 'true'
    if ($ReportOnly -ne '') {
        if ($ReportOnly -cnotmatch '\A(true|false)\z') { throw 'ReportOnly must be true or false.' }
        $a.ReportOnly = $ReportOnly -ceq 'true'
    }
    if ($Message.Trim()) {
        if ($Message.Length -gt 300) { throw 'Message must be 300 characters or fewer.' }
        $a.Message = $Message.Trim()
    }
    foreach ($p in @(
            @{ Name = 'SnoozeMinutes'; Value = $SnoozeMinutes; Min = 5; Max = 240 },
            # 55 minutes = 3300 s, the toolkit's ceiling for a prompt timeout.
            @{ Name = 'PromptMinutes'; Value = $PromptMinutes; Min = 1; Max = 55 },
            @{ Name = 'CountdownMinutes'; Value = $CountdownMinutes; Min = 1; Max = 60 })) {
        if ($p.Value -eq '') { continue }
        if ($p.Value -notmatch '\A\d{1,3}\z' -or [int]$p.Value -lt $p.Min -or [int]$p.Value -gt $p.Max) {
            throw "$($p.Name) must be a whole number from $($p.Min) to $($p.Max)."
        }
        $a[$p.Name] = [int]$p.Value
    }
    return $a
}

# Pure: a round-trip ("o") time string as UTC. A plain [datetime] cast turns it into local time.
function ConvertTo-RnUtc {
    param([string]$Text)
    return [datetime]::Parse($Text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

# Pure: why a restart is pending, empty when it is not.
# A feature upgrade counts while the feature-upgrade package's state.json says
# staged, the build has not reached the ISO's build, and the device has not
# booted since it was staged (the same test as that package's Get-FupStateVerdict).
function Get-RnPendingReasons {
    param([bool]$Cbs, [bool]$WindowsUpdate, $FupState, [int]$CurrentBuild, [datetime]$LastBoot, [bool]$MaintenanceRestart=$false, $PendingRename=@())
    $r = @()
    if($MaintenanceRestart -and (Test-RnPendingRenamePairs $PendingRename)) { $r += 'pendingFileRename' }
    if ($Cbs) { $r += 'servicing' }
    if ($WindowsUpdate) { $r += 'windowsUpdate' }
    if ($FupState -and "$($FupState.status)" -eq 'staged' -and $FupState.time) {
        $notBuilt = -not $FupState.isoBuild -or $CurrentBuild -lt [int]$FupState.isoBuild
        # A bad time is the feature-upgrade package's to clear; it is not a restart reason.
        $staged = $null
        try { $staged = ConvertTo-RnUtc "$($FupState.time)" } catch { }
        if ($notBuilt -and $staged -and $LastBoot -le $staged) { $r += 'featureUpgrade' }
    }
    return $r
}

# Pure: present | disconnected | none | unknown.
# The rule: the toolkit's Get-ADTLoggedOnUser (Windows terminal-services sessions)
# is the list of sessions. A session is a person's only when it has a user name
# that is a person (see Get-RnPeople), is not session 0 or "Services", and is not
# a placeholder state (listen, idle, down, init, reset: the listening "console" and
# "rdp-tcp" entries). Any connected one: present. Only disconnected ones:
# disconnected, still a person with unsaved work, but no dialog can show. None:
# none. The console user (Win32_ComputerSystem.UserName) and explorer.exe owners
# cross-check it: a person they name with no session of their own (a ghost
# session, a stuck logoff) is a disagreement, so unknown. A probe that failed is
# unknown. Unknown is treated as present.
function Get-RnUserPresence {
    param($Sessions, [string[]]$OtherUsers, [bool]$ProbeFailed)
    if ($ProbeFailed) { return 'unknown' }
    $sessions = @($Sessions | Where-Object { $null -ne $_ })
    $known = @($sessions | ForEach-Object { $_.user })
    if (@(Get-RnPeople $OtherUsers | Where-Object { $known -notcontains $_ }).Count) { return 'unknown' }
    if (@($sessions | Where-Object { $_.state -ne 'disconnected' }).Count) { return 'present' }
    if ($sessions.Count) { return 'disconnected' }
    return 'none'
}

# Pure: the names that are people (see Get-RnUserPresence), trimmed, each once.
function Get-RnPeople {
    param([string[]]$Users)
    $seen = @{}
    foreach ($u in @($Users)) {
        $name = "$u".Trim()
        if (-not $name -or $seen.ContainsKey($name)) { continue }
        $short = ($name -split '\\')[-1]
        if ($name -match '^(NT AUTHORITY|Font Driver Host|Window Manager)\\') { continue }
        if ($short -match '^(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$' -or $short -match '^(DWM|UMFD)-\d+$') { continue }
        $seen[$name] = $true
        $name
    }
}

# Pure: one entry per person's session from Get-ADTLoggedOnUser (the rule is at
# Get-RnUserPresence). ConnectState is the WTS state (WTSActive -> active); an
# unrecognised state counts, so a new state name cannot hide a person. Lock state
# is not in the toolkit's session data and a LogonUI.exe check is a guess, so
# locked is always unknown.
function ConvertTo-RnSessionReport {
    param($Sessions)
    foreach ($x in @($Sessions)) {
        if ($null -eq $x -or -not $x.IsUserSession -or -not @(Get-RnPeople @("$($x.NTAccount)")).Count) { continue }
        if ([int]$x.SessionId -eq 0 -or "$($x.SessionName)" -eq 'Services') { continue }
        $state = ("$($x.ConnectState)" -replace '^WTS', '').ToLowerInvariant()
        if (@('listen', 'listening', 'idle', 'down', 'init', 'initializing', 'reset') -contains $state) { continue }
        $kind = if ($x.IsConsoleSession) { 'console' } elseif ($x.IsRdpSession) { 'rdp' } else { 'other' }
        $idle = $null
        if ($x.IdleTime -is [timespan]) { $idle = [int][math]::Floor($x.IdleTime.TotalMinutes) }
        [ordered]@{ user = "$($x.NTAccount)".Trim(); id = [int]$x.SessionId; type = $kind; state = $state; locked = 'unknown'; idleMinutes = $idle }
    }
}

# Pure: why Get-RnUserPresence decided what it did: none | console | rdp |
# disconnected | cannotTell. A connected console session wins over RDP.
function Get-RnPresenceReason {
    param([string]$Presence, $Sessions)
    if ($Presence -eq 'unknown') { return 'cannotTell' }
    if ($Presence -ne 'present') { return $Presence }
    if (@(@($Sessions) | Where-Object { $_.state -ne 'disconnected' -and $_.type -eq 'console' }).Count) { return 'console' }
    return 'rdp'
}

# The one user detector, for Invoke-RnMain and Invoke-RnReport. It opens no
# toolkit session: an Interactive session with nobody signed in ends the process.
function Get-RnDetection {
    $sessions = @()
    $others = @()
    $failed = $false
    try {
        $sessions = @(ConvertTo-RnSessionReport @(& $script:RnGetSessions))
        $others = @(& $script:RnGetOtherUsers)
    } catch {
        $failed = $true
        Write-Status "user probe failed: $($_.Exception.Message)" 'WARN'
    }
    $presence = Get-RnUserPresence -Sessions $sessions -OtherUsers $others -ProbeFailed $failed
    return [ordered]@{
        presence = $presence
        reason   = Get-RnPresenceReason -Presence $presence -Sessions $sessions
        users    = @(Get-RnPeople (@($sessions | ForEach-Object { $_.user }) + $others))
        sessions = $sessions
    }
}

# Pure: true for the toolkit refusing an Interactive session because no user can
# see it (and for Open-RnSession's own check of the same thing).
function Test-RnNoUserError {
    param($ErrorRecord)
    for ($e = $ErrorRecord.Exception; $null -ne $e; $e = $e.InnerException) {
        if ($e.Message -match 'no suitable logged on users') { return $true }
    }
    return $false
}

# Pure: DOMAIN\user from a Win32_Process GetOwner result. A failed lookup throws, so
# the probe fails and the user counts as present: an unreadable owner can be a person.
function ConvertTo-RnOwnerName {
    param($Owner)
    if ($null -eq $Owner -or $Owner.ReturnValue -ne 0) { throw 'explorer.exe owner could not be read' }
    return "$($Owner.Domain)\$($Owner.User)"
}

# Pure: none | stale | active | used for the snooze marker.
# stale = set before the last boot, so the restart it was for has happened.
function Get-RnSnoozeState {
    param($Marker, [datetime]$Now, [datetime]$LastBoot)
    if (-not $Marker -or -not $Marker.SnoozeUntil -or -not $Marker.SetAt) { return 'none' }
    if ((ConvertTo-RnUtc $Marker.SetAt) -lt $LastBoot) { return 'stale' }
    if ($Now -lt (ConvertTo-RnUtc $Marker.SnoozeUntil)) { return 'active' }
    return 'used'
}

# Pure: Restart now | Snooze | NoAnswer | NotShown for what the prompt returned.
function Get-RnButton {
    param($Result, [string]$SnoozeText)
    if ($null -eq $Result) { return 'NotShown' }
    $b = "$Result".Trim()
    if ($b -eq 'Restart now') { return 'Restart now' }
    if ($b -eq $SnoozeText) { return 'Snooze' }
    if (-not $b) { return 'NotShown' }
    return 'NoAnswer'
}

# Pure: the snooze button text.
function Get-RnSnoozeText {
    param([int]$Minutes)
    if ($Minutes -eq 60) { return 'Snooze 1 hour' }
    if ($Minutes % 60 -eq 0) { return "Snooze $($Minutes / 60) hours" }
    return "Snooze $Minutes minutes"
}

# Pure: one line of compact JSON with a UTC timestamp.
function ConvertTo-RnJson {
    param([System.Collections.Specialized.OrderedDictionary]$Result, [datetime]$Now)
    $Result['timestamp'] = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    return ($Result | ConvertTo-Json -Depth 4 -Compress)
}

# Pure: quotes a value for a native command line under Windows PowerShell 5.1.
function ConvertTo-RnNativeArg {
    param([string]$Value)
    return [regex]::Replace($Value, '(\\*)"', { param($m) $m.Groups[1].Value + $m.Groups[1].Value + '\"' })
}

# Same write as the feature-upgrade package: the agent CLI's stdin, then a read-back.
function Set-RnField {
    param([string]$Value, [string]$Name = $RnFieldName)
    $cli = Join-Path $env:ProgramData 'NinjaRMMAgent\ninjarmm-cli.exe'
    if (Test-Path -LiteralPath $cli) {
        try {
            $null = $Value | & $cli set --stdin $Name 2>&1
            $back = (& $cli get $Name 2>$null) -join "`n"
            if ($back.Trim() -eq $Value) { return $true }
        } catch { }
    }
    if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) {
        try { Ninja-Property-Set $Name (ConvertTo-RnNativeArg $Value); return $true } catch { }
    }
    return $false
}

# Writes the field and keeps the JSON for the caller to print last.
function Out-RnResult {
    param([System.Collections.Specialized.OrderedDictionary]$Result, [string]$Field = $RnFieldName)
    $json = ConvertTo-RnJson $Result (& $script:RnNow)
    if (& $script:RnSetField $json $Field) { Write-Status "Written to $Field" }
    else { Write-Status 'Custom field not written; the JSON line below is the result' 'WARN' }
    $script:RnJson = $json
}

function New-RnResult {
    param([string]$Status, [string]$Text, [string[]]$Pending, [string]$Button = '', [bool]$SnoozeUsed = $false)
    return [ordered]@{ status = $Status; message = $Text; pending = @($Pending); button = $Button; snoozeUsed = $SnoozeUsed }
}

# REG_MULTI_SZ pairs: a nonempty source with an empty destination is a pending deletion.
function Test-RnPendingRenamePairs {
    param($Entries)
    $items=@($Entries)
    if($items.Count -eq 0) { return $false }
    if($items.Count % 2) { throw 'Pending rename pairs unavailable.' }
    $pending=$false
    for($i=0;$i -lt $items.Count;$i+=2) {
        if($items[$i] -isnot [string] -or $items[$i+1] -isnot [string]) { throw 'Invalid pending rename pair.' }
        if(-not [string]::IsNullOrWhiteSpace($items[$i])) { $pending=$true }
        elseif(-not [string]::IsNullOrWhiteSpace($items[$i+1])) { throw 'Invalid pending rename source.' }
    }
    return $pending
}

function Get-RnMaintenanceGuard {
    try {
        $processes=@(Get-CimInstance Win32_Process -Filter "Name='setup.exe' OR Name='setuphost.exe' OR Name='setupprep.exe' OR Name='dism.exe' OR Name='sfc.exe' OR Name='TiWorker.exe' OR Name='TrustedInstaller.exe' OR Name='msiexec.exe'" -OperationTimeoutSec 5 -ErrorAction Stop)
        if($processes.Count) { return @{Safe=$false;Reason='setupOrServicingProcess'} }
        $setup=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
        if($null -eq $setup) { throw 'Setup probe missing' }
        foreach($name in @('SystemSetupInProgress','OOBEInProgress','SetupPhase','SetupType','RestartSetup')) {
            if($setup.PSObject.Properties[$name]) {
                if([string]$setup.$name -notmatch '^\d{1,10}$') { throw 'Setup flag unknown' }
                if([long]$setup.$name -ne 0) { return @{Safe=$false;Reason='setupInProgress'} }
            } elseif($name -eq 'SystemSetupInProgress') { throw 'Setup state missing' }
        }
        foreach($relative in @('RelianMaintenance\native-active.json','Relian\Maintenance\native-active.json')) {
            if(Test-Path -LiteralPath (Join-Path $env:ProgramData $relative) -ErrorAction Stop) { return @{Safe=$false;Reason='nativeServicingMarker'} }
        }
        return @{Safe=$true;Reason='clear'}
    } catch { return @{Safe=$false;Reason='servicingStateUnknown'} }
}

# Every opt-in prompt and shutdown uses this fail-closed boundary. No diagnostic
# text, command line, legacy running marker or MoSetup assumption authorizes reboot.
function Test-RnMaintenanceDeferred {
    param([string[]]$Pending)
    if(-not $script:RnMaintenanceRestart) { return $false }
    $safe=$false
    try { $guard=& $script:RnMaintenanceGuard; $safe=($null -ne $guard -and $guard.Safe -is [bool] -and $guard.Safe) } catch { }
    if($safe) { return $false }
    Out-RnResult (New-RnResult 'deferred' 'maintenance restart deferred: setup/servicing is active or its safety state is unknown' $Pending)
    return $true
}

# Writes the result, then restarts. Returns the exit code.
function Invoke-RnRestartNow {
    param([System.Collections.Specialized.OrderedDictionary]$Result)
    Out-RnResult $Result
    if(Test-RnMaintenanceDeferred $Result.pending) { return 0 }
    $code = [int](& $script:RnRestart)
    if ($code -ne 0) {
        $Result['status'] = 'failed'
        $Result['message'] = "shutdown.exe exited $code"
        Out-RnResult $Result
        return 1
    }
    return 0
}

# The whole decision. Every side effect goes through a $script: block, so tests
# replace them. Returns the exit code.
function Invoke-RnMain {
    param($A)
    $script:RnMaintenanceRestart=$A.ContainsKey('MaintenanceRestart') -and $A.MaintenanceRestart
    if(Test-RnMaintenanceDeferred @()) { return 0 }
    $now = (& $script:RnNow).ToUniversalTime()
    try { $pending = @(& $script:RnGetPending) } catch {
        if(-not $script:RnMaintenanceRestart) { throw }
        Out-RnResult (New-RnResult 'deferred' 'maintenance restart deferred: pending-state probe failed' @())
        return 0
    }
    if ($pending.Count -eq 0) {
        & $script:RnClearSnooze
        Out-RnResult (New-RnResult 'none' 'no restart pending' @())
        return 0
    }

    $marker = & $script:RnGetSnooze
    $snooze = Get-RnSnoozeState -Marker $marker -Now $now -LastBoot (& $script:RnLastBoot)
    if ($snooze -eq 'stale') { & $script:RnClearSnooze; $snooze = 'none' }
    if ($snooze -eq 'active') {
        $r = New-RnResult 'snoozed' 'snoozed; the next run after the snooze shows the countdown' $pending '' $true
        $r['snoozeUntil'] = "$($marker.SnoozeUntil)"
        Out-RnResult $r
        return 0
    }

    $presence = (Get-RnDetection).presence
    if ($presence -eq 'none') {
        return (Invoke-RnRestartNow (New-RnResult 'restartedNoUser' 'nobody signed in; restarted' $pending))
    }

    $snoozeUsed = $snooze -eq 'used'
    $button = ''
    $reason = 'snoozeUsed'
    # Disconnected: a person, but no session can show notice 1. Straight to the
    # countdown without a dialog.
    if ($presence -eq 'disconnected') { $reason = 'NotShown' }
    elseif (-not $snoozeUsed) {
        $snoozeText = Get-RnSnoozeText $A.SnoozeMinutes
        $shown = $null
        if(Test-RnMaintenanceDeferred $pending) { return 0 }
        try { $shown = & $script:RnPrompt $A.Message $snoozeText ($A.PromptMinutes * 60) }
        catch {
            if (-not (Test-RnNoUserError $_)) { throw }
            # The toolkit saw no user where the detector saw one (or could not tell).
            # A second look decides: nobody now means restart now; anyone else (a
            # disconnected user who could come back, still cannot tell) gets the
            # countdown without a dialog.
            Write-Status "toolkit saw no user: $($_.Exception.Message)" 'WARN'
            if ((Get-RnDetection).presence -eq 'none') {
                $r = New-RnResult 'restartedNoUser' 'the toolkit saw no signed-in user and a second check agreed; restarted' $pending
                $r['reason'] = 'toolkitNoUser'
                return (Invoke-RnRestartNow $r)
            }
        }
        $button = Get-RnButton -Result $shown -SnoozeText $snoozeText
        if ($button -eq 'Restart now') {
            return (Invoke-RnRestartNow (New-RnResult 'restarted' 'user chose Restart now' $pending $button))
        }
        if ($button -eq 'Snooze') {
            # From the click, not the start of the run: the prompt may have waited minutes.
            $clicked = (& $script:RnNow).ToUniversalTime()
            $until = $clicked.AddMinutes($A.SnoozeMinutes).ToString('o')
            & $script:RnSetSnooze $until $clicked.ToString('o')
            $r = New-RnResult 'snoozed' "snoozed for $($A.SnoozeMinutes) minutes" $pending $button $true
            $r['snoozeUntil'] = $until
            Out-RnResult $r
            return 0
        }
        $reason = $button
    }

    # NotShown: no session can show the dialog (a disconnected user). The toolkit's
    # restart dialog would then restart at once, so the countdown is waited out here
    # without it. Checked on the used-snooze path too, where notice 1 was skipped.
    if ($reason -ne 'NotShown' -and -not (& $script:RnCanShow)) { $reason = 'NotShown' }

    if(Test-RnMaintenanceDeferred $pending) { return 0 }

    # Countdown, then restart. Written first: the dialog's own Restart now may restart
    # the device before this run gets another chance.
    $seconds = $A.CountdownMinutes * 60
    $r = New-RnResult 'restartedAfterCountdown' "countdown of $($A.CountdownMinutes) minutes ($reason), then restart" $pending $button $snoozeUsed
    $r['reason'] = $reason
    Out-RnResult $r
    if($script:RnMaintenanceRestart -and $reason -ne 'NotShown') {
        # This ordinary toolkit prompt cannot reboot independently. The parent
        # owns both its timeout and Restart now action, then rechecks servicing.
        $countdownWatch=[Diagnostics.Stopwatch]::StartNew()
        try {
            $choice=& $script:RnMaintenanceCountdown $A.Message $seconds
            if($choice -eq '__maintenanceDeferred') { return 0 }
            if((Get-RnButton $choice '') -eq 'Restart now') {
                $r['status']='restarted'; $r['button']='Restart now'; $r['message']='user chose Restart now on the maintenance countdown'
            } else {
                # A null/early return does not establish that the countdown elapsed.
                $left=[int][Math]::Ceiling($seconds-$countdownWatch.Elapsed.TotalSeconds)
                if($left -gt 0) { & $script:RnSleep $left }
            }
        } catch {
            if(-not (Test-RnNoUserError $_)) { throw }
            & $script:RnSleep $seconds
        }
        return (Invoke-RnRestartNow $r)
    }
    $waited = $false
    if ($reason -ne 'NotShown') {
        # The user left between the check and the dialog: the field is written, so
        # wait the countdown out without it.
        $shown = $true
        try { & $script:RnCountdown $A.Message $seconds }
        catch {
            if (-not (Test-RnNoUserError $_)) { throw }
            Write-Status "countdown not shown: $($_.Exception.Message)" 'WARN'
            $shown = $false
        }
        if ($shown) {
            $waited = $true
            # The dialog runs on its own and does not restart the device itself, so
            # Restart now there is seen here as the dialog closing early.
            if (Wait-RnCountdown $seconds) {
                $r['status'] = 'restarted'
                $r['message'] = "user chose Restart now on the countdown ($reason)"
                $r['button'] = 'Restart now'
                return (Invoke-RnRestartNow $r)
            }
        }
    }
    if (-not $waited) { & $script:RnSleep $seconds }
    return (Invoke-RnRestartNow $r)
}

# Waits out the countdown. True when the countdown dialog closed before the end:
# it has no close or minimize, so that is Restart now. The dialog counts as closed
# only after it was seen open (RnCountdownOpen says why the first poll sees it).
# Never seen: the countdown runs out, as before. A probe that fails waits the
# rest of the countdown, as before this check existed.
function Wait-RnCountdown {
    param([int]$Seconds)
    $end = (& $script:RnNow).AddSeconds($Seconds)
    $seen = $false
    try {
        while ($true) {
            $left = [int][math]::Ceiling(($end - (& $script:RnNow)).TotalSeconds)
            if ($left -le 0) { return $false }
            if (& $script:RnCountdownOpen) { $seen = $true }
            elseif ($seen) { return $true }
            & $script:RnSleep 1
        }
    } catch {
        Write-Status "countdown dialog not watched: $($_.Exception.Message)" 'WARN'
        $left = [int][math]::Ceiling(($end - (& $script:RnNow)).TotalSeconds)
        if ($left -gt 0) { & $script:RnSleep $left }
        return $false
    }
}

# Report only: the same probes and rules as Invoke-RnMain, written to
# relianSessionState. Reads only: no prompt, no snooze marker change (a stale
# marker is reported, not cleared), no restart. Returns the exit code.
function Invoke-RnReport {
    $now = (& $script:RnNow).ToUniversalTime()
    $boot = & $script:RnLastBoot
    $d = Get-RnDetection
    $r = [ordered]@{
        userPresent = $d.presence
        reason      = $d.reason
        users       = $d.users
        sessions    = $d.sessions
        pending     = @(& $script:RnGetPending)
        lastBoot    = $boot.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        build       = [int](& $script:RnBuild)
        snooze      = Get-RnSnoozeState -Marker (& $script:RnGetSnooze) -Now $now -LastBoot $boot
    }
    Out-RnResult $r $RnReportField
    return 0
}

# Runs one mode. Any error is written as failed (before anything else can end the
# run) and returns 1, so a run never ends silent.
function Invoke-RnRun {
    param($A)
    $script:RnMaintenanceRestart=$A.ContainsKey('MaintenanceRestart') -and $A.MaintenanceRestart
    try {
        if ($A.ReportOnly) { return (Invoke-RnReport) }
        return (Invoke-RnMain $A)
    } catch {
        Write-Status "$($_.Exception.Message) $($_.ScriptStackTrace)" 'ERROR'
        $outField = if ($A.ReportOnly) { $RnReportField } else { $RnFieldName }
        Out-RnResult (New-RnResult 'failed' "$($_.Exception.Message)" @()) $outField
        return 1
    }
}

# --- Real implementations. Tests replace these. -------------------------------

$script:RnMaintenanceRestart=$false
$script:RnMaintenanceGuard={ Get-RnMaintenanceGuard }
$script:RnMaintenanceCountdown={
    param($Text,$Seconds)
    Open-RnSession
    $remaining=$Seconds
    while($remaining -gt 0) {
        if(Test-RnMaintenanceDeferred @()) { return '__maintenanceDeferred' }
        $interval=[Math]::Min(3300,$remaining)
        $answer=Show-ADTInstallationPrompt -Message ($Text+" Windows will restart in $([Math]::Ceiling($remaining/60)) minutes. Save your work.") -ButtonLeftText 'Restart now' -Title 'Restart needed' -Subtitle 'Windows update' -NoExitOnTimeout -Timeout $interval
        if((Get-RnButton $answer '') -eq 'Restart now') { return $answer }
        $remaining-=$interval
    }
    return 'Timeout'
}
$script:RnNow = { (Get-Date).ToUniversalTime() }
$script:RnSetField = { param($Json, $Name) Set-RnField $Json $Name }
$script:RnSleep = { param($Seconds) Start-Sleep -Seconds $Seconds }
# /f: apps with unsaved work would otherwise block the restart and let it be cancelled.
$script:RnRestart = { & shutdown.exe /r /f /t 0; $LASTEXITCODE }
$script:RnLastBoot = { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime() }
$script:RnBuild = { [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuild).CurrentBuild }

$script:RnGetPending = {
    $probeError=if($script:RnMaintenanceRestart) { 'Stop' } else { 'Continue' }
    $cbs = Test-Path -ErrorAction $probeError -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wu = Test-Path -ErrorAction $probeError -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $state = $null
    if (Test-Path -LiteralPath $RnFupState) {
        try { $state = [IO.File]::ReadAllText($RnFupState) | ConvertFrom-Json } catch { $state = $null }
    }
    $renames=@()
    if($script:RnMaintenanceRestart) {
        $session=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        if($session.PSObject.Properties['PendingFileRenameOperations']) { $renames=@($session.PendingFileRenameOperations) }
    }
    $build = & $script:RnBuild
    Get-RnPendingReasons -MaintenanceRestart $script:RnMaintenanceRestart -PendingRename $renames -Cbs $cbs -WindowsUpdate $wu -FupState $state -CurrentBuild $build -LastBoot (& $script:RnLastBoot)
}

# The probes behind Get-RnDetection.
$script:RnGetSessions = {
    Import-RnToolkit
    @(Get-ADTLoggedOnUser -ErrorAction Stop)
}
$script:RnGetOtherUsers = {
    @((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName)
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)) {
        ConvertTo-RnOwnerName (Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop)
    }
}

$script:RnGetSnooze = {
    $v = Get-ItemProperty -LiteralPath $RnMarkerKey -ErrorAction SilentlyContinue
    if ($v -and $v.PSObject.Properties['SnoozeUntil'] -and $v.PSObject.Properties['SetAt']) {
        [pscustomobject]@{ SnoozeUntil = $v.SnoozeUntil; SetAt = $v.SetAt }
    }
}
$script:RnSetSnooze = {
    param($Until, $SetAt)
    $null = New-Item -Path $RnMarkerKey -Force
    $null = New-ItemProperty -LiteralPath $RnMarkerKey -Name SnoozeUntil -Value $Until -PropertyType String -Force
    $null = New-ItemProperty -LiteralPath $RnMarkerKey -Name SetAt -Value $SetAt -PropertyType String -Force
}
$script:RnClearSnooze = { Remove-Item -LiteralPath $RnMarkerKey -Recurse -Force -ErrorAction SilentlyContinue }

$script:RnSessionOpen = $false
$script:RnToolkitLoaded = $false
# The module only: Get-ADTLoggedOnUser needs no toolkit session, so report mode opens none.
function Import-RnToolkit {
    if ($script:RnToolkitLoaded) { return }
    $manifest = Join-Path $PSScriptRoot 'PSAppDeployToolkit\PSAppDeployToolkit.psd1'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "missing PSAppDeployToolkit module at $manifest" }
    Get-ChildItem -LiteralPath (Split-Path -Parent $manifest) -Recurse -File | Unblock-File -ErrorAction Ignore
    Import-Module -FullyQualifiedName @{ ModuleName = $manifest; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    $script:RnToolkitLoaded = $true
}

# Get-ADTLoggedOnUser initializes PSADT's cached assembly list before the theme
# DLL exists. Explicitly include the generated file when granting the same
# read/execute access PSADT grants its own client libraries; never grant write.
function Grant-RnThemeReadAccess {
    param([Parameter(Mandatory)][string]$Path)
    $sessions = @(Get-ADTLoggedOnUser -ErrorAction Stop | Where-Object { $_.IsActiveUserSession })
    if (-not $sessions.Count) { throw 'no active user session for dialog theme' }
    foreach ($session in $sessions) {
        [PSADT.ClientServer.ClientPermissions]::Remediate($session.ToRunAsActiveUser(), [IO.FileInfo[]]@($Path))
    }
}

# The user-check package's dialog theme, copied: the runner downloads each package
# as one file by hash, so the two cannot share a file. The mark and subtitle parts
# are left out. The toolkit's client process (PSADT.ClientServer.Client.exe, started
# in the user's session for notice 1, and again through its launcher for the
# countdown) loads this assembly as its AppDomainManager from the .exe.config, so it
# runs inside the process that owns the WPF window although this script runs as
# SYSTEM. A background thread polls the open windows every 150 ms, paints
# SidebarAccentFill and SidebarPanel black, recolours resource keys holding
# "Accent" (OnAccent and Foreground keys white) and whitens text on black buttons.
# It stops about 4 seconds after the last window closes, or after 4000 styled
# polls; what it painted stays. It never touches a dialog result.
function Install-RnDialogTheme {
    param([Parameter(Mandatory)][string]$ClientExe)
    $ErrorActionPreference = 'Stop'
    $dll = Join-Path (Split-Path -Parent $ClientExe) 'RelianRestartNoticeTheme.dll'
    $source = @'
using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

[assembly: AssemblyVersion("1.0.0.0")]

namespace Relian.RestartNoticeTheme
{
    public sealed class ThemeDomainManager : AppDomainManager
    {
        public override void InitializeNewDomain(AppDomainSetup appDomainInfo)
        {
            base.InitializeNewDomain(appDomainInfo);
            try
            {
                TryLog("manager loaded");
                var thread = new Thread(Watch);
                thread.IsBackground = true;
                thread.Start();
            }
            catch (Exception ex)
            {
                TryLog(ex.ToString());
            }
        }

        private static void Watch()
        {
            var missing = 0;
            var seen = 0;
            while (seen < 4000 && missing < 25)
            {
                Thread.Sleep(150);
                try
                {
                    var app = Application.Current;
                    if (app == null)
                    {
                        if (seen > 0)
                        {
                            missing++;
                        }
                        continue;
                    }
                    var found = (bool)app.Dispatcher.Invoke(new Func<bool>(StyleOpenWindows));
                    if (found)
                    {
                        seen++;
                        missing = 0;
                    }
                    else if (seen > 0)
                    {
                        missing++;
                    }
                }
                catch (Exception ex)
                {
                    TryLog(ex.Message);
                    if (seen > 0)
                    {
                        missing++;
                    }
                }
            }
        }

        private static bool StyleOpenWindows()
        {
            var app = Application.Current;
            if (app == null || app.Windows.Count == 0)
            {
                return false;
            }
            var black = new SolidColorBrush(Color.FromRgb(0, 0, 0));
            var white = new SolidColorBrush(Color.FromRgb(255, 255, 255));
            black.Freeze();
            white.Freeze();
            Recolor(app.Resources, black, white);
            var any = false;
            foreach (Window window in app.Windows)
            {
                any = true;
                Paint(window, "SidebarAccentFill", black);
                Paint(window, "SidebarPanel", black);
                WhitenBlackButtons(window, white);
            }
            if (any && Interlocked.Exchange(ref styledOnce, 1) == 0)
            {
                TryLog("styled");
            }
            return any;
        }

        private static int styledOnce;

        private static void Paint(DependencyObject root, string name, Brush brush)
        {
            var element = Find(root, name);
            if (element == null)
            {
                return;
            }
            var opacity = element.GetType().GetProperty("Opacity");
            if (opacity != null && opacity.CanWrite)
            {
                opacity.SetValue(element, 1.0, null);
            }
            var fill = element.GetType().GetProperty("Fill");
            if (fill != null && fill.CanWrite)
            {
                fill.SetValue(element, brush, null);
            }
            var background = element.GetType().GetProperty("Background");
            if (background != null && background.CanWrite)
            {
                background.SetValue(element, brush, null);
            }
        }

        private static void WhitenBlackButtons(Window window, Brush white)
        {
            foreach (var name in new[] { "ButtonLeft", "ButtonMiddle", "ButtonRight" })
            {
                var button = Find(window, name) as Button;
                if (button == null || !ButtonLooksBlack(button))
                {
                    continue;
                }
                button.Foreground = white;
                WhitenText(button, white);
            }
        }

        private static bool ButtonLooksBlack(Button button)
        {
            return LooksBlack(button.Background) || LooksBlack(button.BorderBrush) || AnyBlackFill(button);
        }

        private static bool AnyBlackFill(DependencyObject node)
        {
            var border = node as Border;
            if (border != null && LooksBlack(border.Background))
            {
                return true;
            }
            var count = VisualTreeHelper.GetChildrenCount(node);
            for (var i = 0; i < count; i++)
            {
                if (AnyBlackFill(VisualTreeHelper.GetChild(node, i)))
                {
                    return true;
                }
            }
            return false;
        }

        private static bool LooksBlack(Brush brush)
        {
            var solid = brush as SolidColorBrush;
            if (solid == null)
            {
                return false;
            }
            var color = solid.Color;
            return color.A > 200 && color.R < 40 && color.G < 40 && color.B < 40;
        }

        private static void WhitenText(DependencyObject node, Brush white)
        {
            var block = node as TextBlock;
            if (block != null)
            {
                block.Foreground = white;
            }
            var access = node as AccessText;
            if (access != null)
            {
                access.Foreground = white;
            }
            var count = VisualTreeHelper.GetChildrenCount(node);
            for (var i = 0; i < count; i++)
            {
                WhitenText(VisualTreeHelper.GetChild(node, i), white);
            }
        }

        private static FrameworkElement Find(DependencyObject node, string name)
        {
            var named = node as FrameworkElement;
            if (named != null && named.Name == name)
            {
                return named;
            }
            var window = node as Window;
            if (window != null)
            {
                var found = window.FindName(name) as FrameworkElement;
                if (found != null)
                {
                    return found;
                }
            }
            var count = VisualTreeHelper.GetChildrenCount(node);
            for (var i = 0; i < count; i++)
            {
                var child = Find(VisualTreeHelper.GetChild(node, i), name);
                if (child != null)
                {
                    return child;
                }
            }
            return null;
        }

        private static void Recolor(ResourceDictionary dictionary, Brush black, Brush white)
        {
            if (dictionary == null)
            {
                return;
            }
            try
            {
                var keys = new object[dictionary.Keys.Count];
                dictionary.Keys.CopyTo(keys, 0);
                foreach (var key in keys)
                {
                    var label = key == null ? string.Empty : key.ToString();
                    if (label.IndexOf("Accent", StringComparison.OrdinalIgnoreCase) < 0)
                    {
                        continue;
                    }
                    var lightText = label.IndexOf("OnAccent", StringComparison.OrdinalIgnoreCase) >= 0
                        || label.IndexOf("Foreground", StringComparison.OrdinalIgnoreCase) >= 0;
                    try
                    {
                        var value = dictionary[key];
                        if (value is SolidColorBrush)
                        {
                            dictionary[key] = lightText ? (object)white : black;
                        }
                        else if (value is Color)
                        {
                            dictionary[key] = lightText ? (object)Colors.White : Colors.Black;
                        }
                    }
                    catch
                    {
                    }
                }
            }
            catch
            {
            }
            foreach (ResourceDictionary child in dictionary.MergedDictionaries)
            {
                Recolor(child, black, white);
            }
        }

        private static void TryLog(string message)
        {
            try
            {
                var dir = Path.GetDirectoryName(typeof(ThemeDomainManager).Assembly.Location);
                File.AppendAllText(Path.Combine(dir, "relian-dialog-theme.log"), message + Environment.NewLine);
            }
            catch
            {
            }
        }
    }
}
'@

    if (Test-Path -LiteralPath $dll) { Remove-Item -LiteralPath $dll -Force }
    Add-Type -TypeDefinition $source -OutputAssembly $dll -ReferencedAssemblies @('System', 'System.Xaml', 'WindowsBase', 'PresentationCore', 'PresentationFramework')
    Grant-RnThemeReadAccess -Path $dll
    $fullName = [System.Reflection.AssemblyName]::GetAssemblyName($dll).FullName
    # The config is written last, after the assembly exists: a config naming a
    # missing or unreadable assembly would stop the client process from starting.
    $configPath = "$ClientExe.config"
    [xml]$config = [System.IO.File]::ReadAllText($configPath)
    $runtime = $config.configuration.runtime
    if ($null -eq $runtime) { throw 'client config has no runtime element' }
    foreach ($name in @('appDomainManagerAssembly', 'appDomainManagerType')) {
        foreach ($node in @($runtime.ChildNodes | Where-Object { $_.LocalName -eq $name })) { [void]$runtime.RemoveChild($node) }
    }
    $assemblyNode = $config.CreateElement('appDomainManagerAssembly')
    [void]$assemblyNode.SetAttribute('value', $fullName)
    [void]$runtime.AppendChild($assemblyNode)
    $typeNode = $config.CreateElement('appDomainManagerType')
    [void]$typeNode.SetAttribute('value', 'Relian.RestartNoticeTheme.ThemeDomainManager')
    [void]$runtime.AppendChild($typeNode)
    $config.Save($configPath)
    Write-Status 'dialog theme installed'
}

# An Interactive session needs a user the toolkit calls active (IsActiveUserSession,
# as Get-ADTRunAsActiveUser picks it). Without one, Open-ADTSession refuses
# ("no suitable logged on users") and then ends the process itself: exit 1602, or
# break when it thinks it runs at a prompt. No try/catch sees either, so the same
# test runs first and throws an error the caller can catch.
function Open-RnSession {
    if ($script:RnSessionOpen) { return }
    Import-RnToolkit
    if (-not (& $script:RnCanShow)) {
        throw [NotSupportedException]::new('no suitable logged on users: no active user session for the toolkit')
    }
    # Brand colours only, before the toolkit starts its client process. A failure
    # leaves the toolkit's own colours and changes nothing else.
    try { & $script:RnTheme } catch { Write-Status "dialog theme not installed: $($_.Exception.Message)" 'WARN' }
    $s = @{ AppVendor = ''; AppName = 'Restart needed'; AppVersion = '1'; RequireAdmin = $false; DeployAppScriptVersion = '4.1.8' }
    $s = Remove-ADTHashtableNullOrEmptyValues -Hashtable $s
    # The loop catches the toolkit's break, so a race (the user leaves after the
    # check) is a failed result, not a silent end. Its exit cannot be caught.
    $opened = $false
    foreach ($once in 1) {
        $null = Open-ADTSession @s -DeploymentType 'Install' -DeployMode 'Interactive' -PassThru
        $opened = $true
    }
    if (-not $opened) { throw "Open-ADTSession ended without a session (exit code $Global:LASTEXITCODE)" }
    $script:RnSessionOpen = $true
}

# Once per run, from Open-RnSession, so both notice 1 and the countdown get it.
$script:RnTheme = {
    $client = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'PSAppDeployToolkit') -Filter 'PSADT.ClientServer.Client.exe' -Recurse -File | Select-Object -First 1
    if ($null -eq $client) { throw 'missing PSADT client executable' }
    Install-RnDialogTheme -ClientExe $client.FullName
}

$script:RnPrompt = {
    param($Text, $SnoozeText, $TimeoutSeconds)
    Open-RnSession
    Show-ADTInstallationPrompt -Message $Text -ButtonLeftText 'Restart now' -ButtonRightText $SnoozeText -Title 'Restart needed' -Subtitle 'Windows update' -NoExitOnTimeout -Timeout $TimeoutSeconds
}

# True when a user session is active (connected), so a toolkit dialog can show.
# Needs no toolkit session; Open-RnSession uses it as its check.
$script:RnCanShow = {
    Import-RnToolkit
    [bool](@(Get-ADTLoggedOnUser | Where-Object { $_.IsActiveUserSession }).Count)
}

$script:RnCountdown = {
    param($Text, $Seconds)
    Open-RnSession
    # The restart dialog takes its words from the toolkit's string table, not from
    # parameters. Plain words replace "installation" text; on failure the defaults show.
    try {
        $t = (Get-ADTStringTable).RestartPrompt
        $t.ButtonRestartNow = 'Restart now'
        $t.Message.Install = $Text
        $t.MessageRestart = 'Windows restarts when the timer reaches zero.'
        $t.MessageTime = 'Save your work now.'
        $t.TimeRemaining = 'Restarting in:'
    } catch { Write-Status "restart dialog text not set: $($_.Exception.Message)" 'WARN' }
    # Asynchronous with a session: it returns at once. The caller waits, then restarts.
    Show-ADTInstallationRestartPrompt -CountdownSeconds $Seconds -CountdownNoHideSeconds $Seconds -Title 'Restart needed' -Subtitle 'Windows update'
}

# True while the countdown dialog is open. The async restart prompt starts
# PSADT.ClientServer.Client.Launcher.exe with -DialogType RestartDialog on its
# command line, and the launcher starts PSADT.ClientServer.Client.exe, which shows
# the dialog. Show-ADTInstallationRestartPrompt returns once the launcher process
# exists, so the first poll, a moment later, finds the launcher or its client:
# Wait-RnCountdown sees the dialog open before anyone can answer it. Tracked: any
# of the two whose command line names RestartDialog, and any child of a tracked
# process (the client may carry other arguments). Notice 1's client has neither.
# Throws when the process list cannot be read, so Wait-RnCountdown waits the
# countdown out.
$script:RnCountdownPids = @{}
$script:RnCountdownOpen = {
    $all = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'PSADT.ClientServer.Client%'" -ErrorAction Stop)
    foreach ($pass in 1, 2) {
        foreach ($p in $all) {
            if ("$($p.CommandLine)" -match '\bRestartDialog\b' -or $script:RnCountdownPids.ContainsKey([int]$p.ParentProcessId)) { $script:RnCountdownPids[[int]$p.ProcessId] = $true }
        }
    }
    [bool]@($all | Where-Object { $script:RnCountdownPids.ContainsKey([int]$_.ProcessId) }).Count
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) {
    [Console]::Error.WriteLine('Action must be Install, Update, Repair, Reinstall, or Uninstall.')
    exit 1
}
if ($Action -eq 'Uninstall') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
try {
    $rnArgs = Get-RnArgs -Message $Message -SnoozeMinutes $SnoozeMinutes -PromptMinutes $PromptMinutes -CountdownMinutes $CountdownMinutes -ReportOnly $ReportOnly -MaintenanceRestart $MaintenanceRestart
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }

$script:RnJson = $null
$code = Invoke-RnRun $rnArgs
# Last stdout line is the JSON, so a log reader can find it.
if ($script:RnJson) { Write-Output $script:RnJson }
# Close-ADTSession exits the process itself; the exit after it covers a session
# that cannot exit on close. An explicit code, because the runner maps 1602 to 1.
if ($script:RnSessionOpen) { Close-ADTSession -ExitCode $code }
exit $code
