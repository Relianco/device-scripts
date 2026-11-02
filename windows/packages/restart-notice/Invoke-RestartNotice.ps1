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
      4. Someone signed in, or it cannot tell: notice 1 with Restart now and one
         snooze. Restart now restarts. Snooze writes the marker and exits.
         No answer, or the snooze was already used: notice 2, a countdown with
         Restart now and no snooze, then restart.

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
    [string]$ReportOnly = ''
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
    param([string]$Message, [string]$SnoozeMinutes, [string]$PromptMinutes, [string]$CountdownMinutes, [string]$ReportOnly = '')
    $a = @{ Message = $RnDefaultMessage; SnoozeMinutes = 60; PromptMinutes = 10; CountdownMinutes = 15; ReportOnly = $false }
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
    param([bool]$Cbs, [bool]$WindowsUpdate, $FupState, [int]$CurrentBuild, [datetime]$LastBoot)
    $r = @()
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

# Pure: present | none | unknown, from the owners of interactive sessions.
# The rule: a person is signed in when any of these names one: the toolkit's
# Get-ADTLoggedOnUser (Windows terminal-services sessions: console and RDP,
# connected or disconnected, RemoteApp too), the console user from
# Win32_ComputerSystem.UserName (set for a locked console too), or the owner of
# any explorer.exe. A disconnected user still counts: their unsaved work is still
# there. SYSTEM, service accounts and the DWM-/UMFD- session accounts are
# not people. A probe that failed is unknown, and unknown is treated as present.
function Get-RnUserPresence {
    param([string[]]$Users, [bool]$ProbeFailed)
    if ($ProbeFailed) { return 'unknown' }
    if (@(Get-RnPeople $Users).Count) { return 'present' }
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

# Pure: account names of the user sessions Get-ADTLoggedOnUser returned.
function Get-RnSessionUsers {
    param($Sessions)
    foreach ($x in @($Sessions)) {
        if ($null -ne $x -and $x.IsUserSession -and "$($x.NTAccount)") { "$($x.NTAccount)" }
    }
}

# Pure: one report entry per user session from Get-ADTLoggedOnUser. ConnectState
# is the WTS state (WTSActive -> active). Lock state is not in the toolkit's
# session data and a LogonUI.exe check is a guess, so locked is always unknown.
function ConvertTo-RnSessionReport {
    param($Sessions)
    foreach ($x in @($Sessions)) {
        if ($null -eq $x -or -not $x.IsUserSession -or -not "$($x.NTAccount)") { continue }
        $state = "$($x.ConnectState)" -replace '^WTS', ''
        $kind = if ($x.IsConsoleSession) { 'console' } elseif ($x.IsRdpSession) { 'rdp' } else { 'other' }
        $idle = $null
        if ($x.IdleTime -is [timespan]) { $idle = [int][math]::Floor($x.IdleTime.TotalMinutes) }
        [ordered]@{ user = "$($x.NTAccount)"; id = [int]$x.SessionId; type = $kind; state = $state.ToLowerInvariant(); locked = 'unknown'; idleMinutes = $idle }
    }
}

# Pure: why Get-RnUserPresence decided what it did: none | console | rdp |
# disconnected | cannotTell. A connected console session wins over RDP, and any
# connected session over a disconnected one.
function Get-RnPresenceReason {
    param([string]$Presence, $Sessions)
    if ($Presence -eq 'unknown') { return 'cannotTell' }
    if ($Presence -eq 'none') { return 'none' }
    $connected = @(@($Sessions) | Where-Object { $_.state -ne 'disconnected' })
    if (@($connected | Where-Object { $_.type -eq 'console' }).Count) { return 'console' }
    if ($connected.Count) { return 'rdp' }
    if (@($Sessions).Count) { return 'disconnected' }
    # ponytail: a person named only by the console user or an explorer.exe owner, with
    # no toolkit session, is taken as at the console.
    return 'console'
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

# Writes the result, then restarts. Returns the exit code.
function Invoke-RnRestartNow {
    param([System.Collections.Specialized.OrderedDictionary]$Result)
    Out-RnResult $Result
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
    $now = (& $script:RnNow).ToUniversalTime()
    $pending = @(& $script:RnGetPending)
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

    $users = @()
    $failed = $false
    try { $users = @(& $script:RnGetUsers) } catch { $failed = $true }
    $presence = Get-RnUserPresence -Users $users -ProbeFailed $failed
    if ($presence -eq 'none') {
        return (Invoke-RnRestartNow (New-RnResult 'restartedNoUser' 'nobody signed in; restarted' $pending))
    }

    $snoozeUsed = $snooze -eq 'used'
    $button = ''
    $reason = 'snoozeUsed'
    if (-not $snoozeUsed) {
        $snoozeText = Get-RnSnoozeText $A.SnoozeMinutes
        $button = Get-RnButton -Result (& $script:RnPrompt $A.Message $snoozeText ($A.PromptMinutes * 60)) -SnoozeText $snoozeText
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

    # Countdown, then restart. Written first: the dialog's own Restart now may restart
    # the device before this run gets another chance.
    $seconds = $A.CountdownMinutes * 60
    $r = New-RnResult 'restartedAfterCountdown' "countdown of $($A.CountdownMinutes) minutes ($reason), then restart" $pending $button $snoozeUsed
    $r['reason'] = $reason
    Out-RnResult $r
    if ($reason -ne 'NotShown') { & $script:RnCountdown $A.Message $seconds }
    & $script:RnSleep $seconds
    return (Invoke-RnRestartNow $r)
}

# Report only: the same probes and rules as Invoke-RnMain, written to
# relianSessionState. Reads only: no prompt, no snooze marker change (a stale
# marker is reported, not cleared), no restart. Returns the exit code.
function Invoke-RnReport {
    $now = (& $script:RnNow).ToUniversalTime()
    $boot = & $script:RnLastBoot
    $sessions = @()
    $users = @()
    $failed = $false
    try {
        $raw = @(& $script:RnGetSessions)
        $sessions = @(ConvertTo-RnSessionReport $raw)
        $users = @(Get-RnSessionUsers $raw) + @(& $script:RnGetOtherUsers)
    } catch { $failed = $true }
    $presence = Get-RnUserPresence -Users $users -ProbeFailed $failed
    $r = [ordered]@{
        userPresent = $presence
        reason      = Get-RnPresenceReason -Presence $presence -Sessions $sessions
        users       = @(Get-RnPeople $users)
        sessions    = $sessions
        pending     = @(& $script:RnGetPending)
        lastBoot    = $boot.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        build       = [int](& $script:RnBuild)
        snooze      = Get-RnSnoozeState -Marker (& $script:RnGetSnooze) -Now $now -LastBoot $boot
    }
    Out-RnResult $r $RnReportField
    return 0
}

# --- Real implementations. Tests replace these. -------------------------------

$script:RnNow = { (Get-Date).ToUniversalTime() }
$script:RnSetField = { param($Json, $Name) Set-RnField $Json $Name }
$script:RnSleep = { param($Seconds) Start-Sleep -Seconds $Seconds }
# /f: apps with unsaved work would otherwise block the restart and let it be cancelled.
$script:RnRestart = { & shutdown.exe /r /f /t 0; $LASTEXITCODE }
$script:RnLastBoot = { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime() }
$script:RnBuild = { [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuild).CurrentBuild }

$script:RnGetPending = {
    $cbs = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wu = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $state = $null
    if (Test-Path -LiteralPath $RnFupState) {
        try { $state = [IO.File]::ReadAllText($RnFupState) | ConvertFrom-Json } catch { $state = $null }
    }
    $build = & $script:RnBuild
    Get-RnPendingReasons -Cbs $cbs -WindowsUpdate $wu -FupState $state -CurrentBuild $build -LastBoot (& $script:RnLastBoot)
}

# The one user detector. Invoke-RnMain uses the names; Invoke-RnReport also the sessions.
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
$script:RnGetUsers = {
    Open-RnSession
    Get-RnSessionUsers @(& $script:RnGetSessions)
    & $script:RnGetOtherUsers
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

function Open-RnSession {
    if ($script:RnSessionOpen) { return }
    Import-RnToolkit
    $s = @{ AppVendor = ''; AppName = 'Restart needed'; AppVersion = '1'; RequireAdmin = $false; DeployAppScriptVersion = '4.1.8' }
    $s = Remove-ADTHashtableNullOrEmptyValues -Hashtable $s
    $null = Open-ADTSession @s -DeploymentType 'Install' -DeployMode 'Interactive' -PassThru
    $script:RnSessionOpen = $true
}

$script:RnPrompt = {
    param($Text, $SnoozeText, $TimeoutSeconds)
    Open-RnSession
    Show-ADTInstallationPrompt -Message $Text -ButtonLeftText 'Restart now' -ButtonRightText $SnoozeText -Title 'Restart needed' -Subtitle 'Windows update' -NoExitOnTimeout -Timeout $TimeoutSeconds
}

# True when a user session is active (connected), so a toolkit dialog can show.
$script:RnCanShow = {
    Open-RnSession
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

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) {
    [Console]::Error.WriteLine('Action must be Install, Update, Repair, Reinstall, or Uninstall.')
    exit 1
}
if ($Action -eq 'Uninstall') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
try {
    $rnArgs = Get-RnArgs -Message $Message -SnoozeMinutes $SnoozeMinutes -PromptMinutes $PromptMinutes -CountdownMinutes $CountdownMinutes -ReportOnly $ReportOnly
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }

$script:RnJson = $null
try {
    if ($rnArgs.ReportOnly) { $code = Invoke-RnReport } else { $code = Invoke-RnMain $rnArgs }
} catch {
    Write-Status "$($_.ScriptStackTrace)" 'ERROR'
    $outField = if ($rnArgs.ReportOnly) { $RnReportField } else { $RnFieldName }
    Out-RnResult (New-RnResult 'failed' "$($_.Exception.Message)" @()) $outField
    $code = 1
}
# Last stdout line is the JSON, so a log reader can find it.
if ($script:RnJson) { Write-Output $script:RnJson }
# Close-ADTSession exits the process itself; the exit after it covers a session
# that cannot exit on close. An explicit code, because the runner maps 1602 to 1.
if ($script:RnSessionOpen) { Close-ADTSession -ExitCode $code }
exit $code
