$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/restart-notice/Invoke-RestartNotice.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Assert-Same {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" }
}

function Assert-Throws {
    param([scriptblock]$Block, [string]$Label)
    $threw = $false
    try { & $Block } catch { $threw = $true }
    if (-not $threw) { Fail "$Label did not throw" }
}

# The script run for real: Uninstall exits 0 and a bad argument exits 1, before anything is touched.
$saved = $env:RELIAN_DEPLOY_TEST
$env:RELIAN_DEPLOY_TEST = ''
$out = & pwsh -NoProfile -File $scriptPath -DeploymentType Uninstall -Action Uninstall -PinVersion 1
Assert-Same $LASTEXITCODE 0 'uninstall exit code'
Assert-Same "$out" 'Nothing to change. Nothing was installed.' 'uninstall output'
& pwsh -NoProfile -File $scriptPath -DeploymentType Install -Action Install -PinVersion 1 -SnoozeMinutes 'abc' 2>$null | Out-Null
Assert-Same $LASTEXITCODE 1 'bad SnoozeMinutes exit code'
& pwsh -NoProfile -File $scriptPath -DeploymentType Install -Action Install -PinVersion 1 -ReportOnly 'yes' 2>$null | Out-Null
Assert-Same $LASTEXITCODE 1 'bad ReportOnly exit code'
& pwsh -NoProfile -File $scriptPath -DeploymentType Install -Action Bogus -PinVersion 1 2>$null | Out-Null
Assert-Same $LASTEXITCODE 1 'bad action exit code'
$env:RELIAN_DEPLOY_TEST = $saved

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

# Arguments.
$a = Get-RnArgs -Message '' -SnoozeMinutes '' -PromptMinutes '' -CountdownMinutes ''
Assert-Same $a.SnoozeMinutes 60 'snooze default'
Assert-Same $a.PromptMinutes 10 'prompt default'
Assert-Same $a.CountdownMinutes 15 'countdown default'
Assert-Same $a.Message $RnDefaultMessage 'message default'
Assert-Same (Get-RnArgs -Message ' Hi ' -SnoozeMinutes '30' -PromptMinutes '' -CountdownMinutes '').Message 'Hi' 'message trimmed'
Assert-Throws { Get-RnArgs -Message '' -SnoozeMinutes '4' -PromptMinutes '' -CountdownMinutes '' } 'snooze too short'
Assert-Throws { Get-RnArgs -Message '' -SnoozeMinutes '' -PromptMinutes '56' -CountdownMinutes '' } 'prompt over the toolkit ceiling'
Assert-Throws { Get-RnArgs -Message '' -SnoozeMinutes '' -PromptMinutes '' -CountdownMinutes '0' } 'zero countdown'
Assert-Throws { Get-RnArgs -Message ('x' * 301) -SnoozeMinutes '' -PromptMinutes '' -CountdownMinutes '' } 'long message'
Assert-Same $a.ReportOnly $false 'report off by default'
Assert-Same (Get-RnArgs -Message '' -SnoozeMinutes '' -PromptMinutes '' -CountdownMinutes '' -ReportOnly 'true').ReportOnly $true 'report on'
Assert-Same (Get-RnArgs -Message '' -SnoozeMinutes '' -PromptMinutes '' -CountdownMinutes '' -ReportOnly 'false').ReportOnly $false 'report off'
foreach ($bad in @('TRUE', '1', 'yes', ' true')) {
    Assert-Throws { Get-RnArgs -Message '' -SnoozeMinutes '' -PromptMinutes '' -CountdownMinutes '' -ReportOnly $bad } "ReportOnly '$bad'"
}
Assert-Same (Get-RnSnoozeText 60) 'Snooze 1 hour' 'snooze label 60'
Assert-Same (Get-RnSnoozeText 120) 'Snooze 2 hours' 'snooze label 120'
Assert-Same (Get-RnSnoozeText 30) 'Snooze 30 minutes' 'snooze label 30'

# Pending decision.
$boot = [datetime]::new(2026, 11, 1, 6, 0, 0, [DateTimeKind]::Utc)
Assert-Same (@(Get-RnPendingReasons -Cbs $false -WindowsUpdate $false -FupState $null -CurrentBuild 19045 -LastBoot $boot).Count) 0 'nothing pending'
Assert-Same ((Get-RnPendingReasons -Cbs $true -WindowsUpdate $true -FupState $null -CurrentBuild 19045 -LastBoot $boot) -join ',') 'servicing,windowsUpdate' 'cbs and wu'
$staged = [pscustomobject]@{ status = 'staged'; time = '2026-11-01T08:00:00.0000000Z'; isoBuild = 26100 }
Assert-Same ((Get-RnPendingReasons -Cbs $false -WindowsUpdate $false -FupState $staged -CurrentBuild 19045 -LastBoot $boot) -join ',') 'featureUpgrade' 'staged upgrade pending'
Assert-Same (@(Get-RnPendingReasons -Cbs $false -WindowsUpdate $false -FupState $staged -CurrentBuild 26100 -LastBoot $boot).Count) 0 'upgrade already applied'
Assert-Same (@(Get-RnPendingReasons -Cbs $false -WindowsUpdate $false -FupState $staged -CurrentBuild 19045 -LastBoot $boot.AddHours(3)).Count) 0 'booted since staging (rolled back)'
$badTime = [pscustomobject]@{ status = 'staged'; time = 'not a time'; isoBuild = 26100 }
Assert-Same ((Get-RnPendingReasons -Cbs $true -WindowsUpdate $false -FupState $badTime -CurrentBuild 19045 -LastBoot $boot) -join ',') 'servicing' 'bad staged time ignored, not thrown'
$running = [pscustomobject]@{ status = 'running'; time = '2026-11-01T08:00:00.0000000Z'; isoBuild = 26100 }
Assert-Same (@(Get-RnPendingReasons -Cbs $false -WindowsUpdate $false -FupState $running -CurrentBuild 19045 -LastBoot $boot).Count) 0 'running upgrade not pending'

# User decision. Sessions are Get-ADTLoggedOnUser entries; the other names are the
# console user and explorer.exe owners.
function New-Session {
    param([string]$User, [int]$Id, [string]$State = 'WTSActive', [bool]$Console = $false, [bool]$Rdp = $false, $Idle = $null, [string]$Name = '', [bool]$IsUser = $true)
    [pscustomobject]@{ NTAccount = $User; SessionId = $Id; SessionName = $Name; IsUserSession = $IsUser; ConnectState = $State; IsConsoleSession = $Console; IsRdpSession = $Rdp; IdleTime = $Idle }
}
function Get-Presence {
    param($Raw = @(), $Others = @(), [bool]$Failed = $false)
    Get-RnUserPresence -Sessions @(ConvertTo-RnSessionReport $Raw) -OtherUsers $Others -ProbeFailed $Failed
}
$jdoe = New-Session 'CONTOSO\jdoe' 1 -Console $true
Assert-Same (Get-Presence -Failed $true) 'unknown' 'probe failed'
Assert-Same (Get-Presence) 'none' 'no sessions'
Assert-Same (Get-Presence -Others @($null, '', 'NT AUTHORITY\SYSTEM', 'Window Manager\DWM-1', 'Font Driver Host\UMFD-0', 'WORKGROUP\SYSTEM')) 'none' 'service accounts only'
Assert-Same (Get-Presence -Raw @($jdoe) -Others @('NT AUTHORITY\SYSTEM', 'contoso\JDOE')) 'present' 'a person, names compared without case'
Assert-Same (Get-Presence -Raw @((New-Session 'AzureAD\JaneDoe' 2 -Console $true)) -Others @('AzureAD\JaneDoe')) 'present' 'an Entra user'
# Not people: session 0, the Services session, the listening console and rdp-tcp
# entries with no user, service accounts, a placeholder state, a non-user session.
$notPeople = @(
    (New-Session 'CONTOSO\svc' 0 -Name 'Services'),
    (New-Session 'CONTOSO\svc' 5 -Name 'Services'),
    (New-Session '' 1 'WTSConnected' -Console $true -Name 'Console'),
    (New-Session $null 65536 'WTSListen' -Name 'rdp-tcp'),
    (New-Session 'CONTOSO\x' 3 'WTSListen' -Name 'rdp-tcp'),
    (New-Session 'CONTOSO\x' 4 'WTSDown'),
    (New-Session 'NT AUTHORITY\SYSTEM' 1 -Console $true),
    (New-Session 'Window Manager\DWM-1' 1 -Console $true),
    (New-Session 'CONTOSO\x' 6 -IsUser $false))
Assert-Same @(ConvertTo-RnSessionReport $notPeople).Count 0 'placeholder and service sessions dropped'
Assert-Same (Get-Presence -Raw $notPeople) 'none' 'placeholder and service sessions are nobody'
# A disconnected session (no explorer.exe needed) is a person who cannot see a dialog.
$gone = New-Session 'CONTOSO\rdpuser' 2 'WTSDisconnected' -Rdp $true
Assert-Same (Get-Presence -Raw @($gone)) 'disconnected' 'disconnected only'
Assert-Same (Get-Presence -Raw @($gone, $jdoe)) 'present' 'connected beats disconnected'
Assert-Same (Get-Presence -Raw @((New-Session 'CONTOSO\x' 2 'SomeNewState'))) 'present' 'an unrecognised state still counts'
# A console user or explorer.exe owner with no session of their own (a ghost
# session, a stuck logoff) disagrees with the session list: cannot tell, never none.
Assert-Same (Get-Presence -Others @('CONTOSO\ghost')) 'unknown' 'explorer owner with no session'
Assert-Same (Get-Presence -Raw @($jdoe) -Others @('CONTOSO\jdoe', 'CONTOSO\ghost')) 'unknown' 'one ghost among real users'

# Owner lookup: a failed GetOwner fails the probe instead of hiding a person.
Assert-Same (ConvertTo-RnOwnerName ([pscustomobject]@{ ReturnValue = 0; Domain = 'CONTOSO'; User = 'jdoe' })) 'CONTOSO\jdoe' 'owner name'
Assert-Throws { ConvertTo-RnOwnerName ([pscustomobject]@{ ReturnValue = 2; Domain = $null; User = $null }) } 'owner access denied'
Assert-Throws { ConvertTo-RnOwnerName $null } 'owner missing'

# Snooze decision.
$now = [datetime]::new(2026, 11, 2, 15, 0, 0, [DateTimeKind]::Utc)
Assert-Same (Get-RnSnoozeState -Marker $null -Now $now -LastBoot $boot) 'none' 'no marker'
$m = [pscustomobject]@{ SnoozeUntil = $now.AddMinutes(30).ToString('o'); SetAt = $now.AddMinutes(-30).ToString('o') }
Assert-Same (Get-RnSnoozeState -Marker $m -Now $now -LastBoot $boot) 'active' 'snooze running'
Assert-Same (Get-RnSnoozeState -Marker $m -Now $now.AddMinutes(31) -LastBoot $boot) 'used' 'snooze ran out'
Assert-Same (Get-RnSnoozeState -Marker $m -Now $now -LastBoot $now) 'stale' 'rebooted since the snooze'

# Prompt result.
Assert-Same (Get-RnButton -Result 'Restart now' -SnoozeText 'Snooze 1 hour') 'Restart now' 'restart button'
Assert-Same (Get-RnButton -Result 'Snooze 1 hour' -SnoozeText 'Snooze 1 hour') 'Snooze' 'snooze button'
Assert-Same (Get-RnButton -Result 'Timeout' -SnoozeText 'Snooze 1 hour') 'NoAnswer' 'timeout'
Assert-Same (Get-RnButton -Result $null -SnoozeText 'Snooze 1 hour') 'NotShown' 'not shown'

# Result JSON.
$raw = ConvertTo-RnJson (New-RnResult 'snoozed' 'x' @('servicing') 'Snooze' $true) $now
$j = $raw | ConvertFrom-Json
Assert-Same $j.status 'snoozed' 'json status'
Assert-Same $j.button 'Snooze' 'json button'
Assert-Same $j.snoozeUsed $true 'json snoozeUsed'
Assert-Same ($j.pending -join ',') 'servicing' 'json pending'
if (-not $raw.EndsWith('"timestamp":"2026-11-02T15:00:00Z"}')) { Fail "json timestamp in $raw" }
if ($raw.Contains("`n")) { Fail 'json is not one line' }

# The flow, with every side effect replaced. Each call is logged in order.
# Sessions are the toolkit's sessions, Users the console user and explorer owners.
function Reset-Mocks {
    param([string[]]$Pending = @('windowsUpdate'), $Marker = $null, $Sessions = @($jdoe), $Users = @('CONTOSO\jdoe'), [switch]$UserProbeFails, $PromptResult = 'Timeout', [int]$RestartCode = 0, [int]$PromptDelay = 0, [bool]$CanShow = $true, [scriptblock]$OnPrompt = {})
    $script:OnPrompt = $OnPrompt
    $script:MockCanShow = $CanShow
    $script:PromptDelay = $PromptDelay
    $script:Log = [System.Collections.Generic.List[string]]::new()
    $script:Fields = [System.Collections.Generic.List[object]]::new()
    $script:Marker = $Marker
    $script:MockPending = $Pending
    $script:MockUsers = $Users
    $script:MockUserFails = [bool]$UserProbeFails
    $script:MockPrompt = $PromptResult
    $script:MockRestart = $RestartCode
    $script:Clock = $now
    $script:RnNow = { $script:Clock }
    $script:RnLastBoot = { $boot }
    $script:RnGetPending = { $script:MockPending }
    $script:RnGetSnooze = { $script:Marker }
    $script:RnSetSnooze = { param($U, $S) $script:Log.Add('setSnooze'); $script:Marker = [pscustomobject]@{ SnoozeUntil = $U; SetAt = $S } }
    $script:RnClearSnooze = { $script:Log.Add('clearSnooze'); $script:Marker = $null }
    $script:RnPrompt = { param($T, $S, $Sec) $script:Log.Add("prompt:${S}:$Sec"); $script:Clock = $script:Clock.AddMinutes($script:PromptDelay); & $script:OnPrompt; $script:MockPrompt }
    $script:RnCanShow = { $script:MockCanShow }
    $script:RnCountdown = { param($T, $Sec) $script:Log.Add("countdown:$Sec") }
    $script:RnSleep = { param($Sec) $script:Log.Add("sleep:$Sec") }
    $script:RnRestart = { $script:Log.Add('restart'); $script:MockRestart }
    $script:RnSetField = { param($Json, $Name) $script:Log.Add('field'); $script:FieldNames.Add($Name); $script:Fields.Add(($Json | ConvertFrom-Json)); $true }
    $script:FieldNames = [System.Collections.Generic.List[string]]::new()
    $script:MockSessions = $Sessions
    $script:RnGetSessions = { if ($script:MockUserFails) { throw 'wts down' }; $script:MockSessions }
    $script:RnGetOtherUsers = { $script:MockUsers }
    $script:RnBuild = { 19045 }
}
function Get-Last { return $script:Fields[$script:Fields.Count - 1] }
function Assert-NoRestart { param([string]$Label) if ($script:Log -contains 'restart') { Fail "$Label restarted" } }
function Assert-FieldBeforeRestart {
    param([string]$Label)
    $f = $script:Log.IndexOf('field'); $r = $script:Log.IndexOf('restart')
    if ($r -lt 0 -or $f -lt 0 -or $f -gt $r) { Fail "$Label did not write the field before the restart" }
}
$args60 = Get-RnArgs -Message '' -SnoozeMinutes '' -PromptMinutes '' -CountdownMinutes ''

# 1. Nothing pending: none, marker cleared, no prompt, no restart.
Reset-Mocks -Pending @() -Marker $m
Assert-Same (Invoke-RnMain $args60) 0 'none exit'
Assert-Same (Get-Last).status 'none' 'none status'
Assert-Same $script:Marker $null 'none clears the marker'
Assert-NoRestart 'none'
if ($script:Log -match '^prompt') { Fail 'none prompted' }

# 2. Confirmed nobody signed in: restart now, field first.
Reset-Mocks -Sessions @() -Users @('NT AUTHORITY\SYSTEM')
Assert-Same (Invoke-RnMain $args60) 0 'no user exit'
Assert-Same (Get-Last).status 'restartedNoUser' 'no user status'
Assert-FieldBeforeRestart 'no user'
if ($script:Log -match '^prompt') { Fail 'no user prompted' }

# 2b. Cannot tell: treated as a user, so the prompt shows.
Reset-Mocks -UserProbeFails -PromptResult 'Snooze 1 hour'
$null = Invoke-RnMain $args60
Assert-Same (Get-Last).status 'snoozed' 'unknown user is prompted'
Assert-NoRestart 'unknown user'

# 2c. Only a disconnected user: no notice 1, the countdown waited out without a
# dialog, then restart.
Reset-Mocks -Sessions @($gone) -Users @() -PromptResult 'Restart now'
Assert-Same (Invoke-RnMain $args60) 0 'disconnected exit'
Assert-Same ($script:Log -join '|') 'field|sleep:900|field|restart' 'disconnected sequence'
Assert-Same (Get-Last).reason 'NotShown' 'disconnected reason'

# 2d. The first real run: the detector sees a user, the toolkit refuses notice 1
# (no suitable logged on users), and a second look finds nobody: restartedNoUser,
# the field written before the restart. The old code let the error end the run.
$noUser = { throw [NotSupportedException]::new('This deployment explicitly requires interactivity, however there are no suitable logged on users available and this process is running non-interactively.') }
Reset-Mocks -PromptResult $null -OnPrompt { $script:MockSessions = @(); $script:MockUsers = @(); & $noUser }
Assert-Same (Invoke-RnMain $args60) 0 'toolkit no user exit'
Assert-Same ($script:Log -join '|') 'prompt:Snooze 1 hour:600|field|restart' 'toolkit no user sequence'
Assert-Same (Get-Last).status 'restartedNoUser' 'toolkit no user status'
Assert-Same (Get-Last).reason 'toolkitNoUser' 'toolkit no user reason'
if ((Get-Last).message -notmatch 'toolkit saw no') { Fail "toolkit no user message $((Get-Last).message)" }
Assert-FieldBeforeRestart 'toolkit no user'

# 2e. The toolkit refuses and the second look still sees a person (a disconnected
# user who could come back, or cannot tell): countdown without a dialog, then restart.
foreach ($second in @(@{ S = @($gone); U = @() }, @{ S = @(); U = @('CONTOSO\ghost') })) {
    $script:Second = $second
    Reset-Mocks -PromptResult $null -OnPrompt { $script:MockSessions = $script:Second.S; $script:MockUsers = $script:Second.U; & $noUser }
    Assert-Same (Invoke-RnMain $args60) 0 'toolkit no user, person still there exit'
    Assert-Same ($script:Log -join '|') 'prompt:Snooze 1 hour:600|field|sleep:900|field|restart' 'toolkit no user, person still there sequence'
    Assert-Same (Get-Last).status 'restartedAfterCountdown' 'toolkit no user, person still there status'
    Assert-Same (Get-Last).reason 'NotShown' 'toolkit no user, person still there reason'
}

# 2f. The user leaves before the countdown dialog: the toolkit's refusal is not a
# failure, the countdown is waited out and the device restarts.
Reset-Mocks -PromptResult 'Timeout'
$script:RnCountdown = { param($T, $Sec) $script:Log.Add("countdown:$Sec"); & $noUser }
Assert-Same (Invoke-RnMain $args60) 0 'countdown refused exit'
Assert-Same ($script:Log -join '|') 'prompt:Snooze 1 hour:600|field|countdown:900|sleep:900|field|restart' 'countdown refused sequence'

# 2g. Any other error: result failed with the message, in the field, exit 1, no restart.
Reset-Mocks -OnPrompt { throw 'dialog broke' }
Assert-Same (Invoke-RnRun $args60) 1 'other error exit'
Assert-Same (Get-Last).status 'failed' 'other error status'
Assert-Same (Get-Last).message 'dialog broke' 'other error message'
Assert-Same ($script:FieldNames -join ',') 'relianRestartNotice' 'other error field'
Assert-NoRestart 'other error'
Reset-Mocks
$script:RnGetPending = { throw 'registry broke' }
Assert-Same (Invoke-RnRun (Get-RnArgs -Message '' -SnoozeMinutes '' -PromptMinutes '' -CountdownMinutes '' -ReportOnly 'true')) 1 'report error exit'
Assert-Same ($script:FieldNames -join ',') 'relianSessionState' 'report error field'
Assert-Same (Get-Last).status 'failed' 'report error status'

# 2h. Open-RnSession checks the toolkit's own rule first: with no active user it
# throws a catchable error and never calls Open-ADTSession (whose refusal ends the
# process). Detection never opens a session. A toolkit break is caught as a failure.
function Remove-ADTHashtableNullOrEmptyValues { param($Hashtable) $Hashtable }
function Open-ADTSession { $script:Log.Add('openSession'); if ($script:BreakOpen) { $Global:LASTEXITCODE = 1602; break } }
$script:RnToolkitLoaded = $true
$script:BreakOpen = $false
Reset-Mocks -Sessions @() -Users @()
$script:RnSessionOpen = $false
$null = Invoke-RnMain $args60
$null = Invoke-RnReport
if ($script:Log -contains 'openSession') { Fail 'detection opened a toolkit session' }
Reset-Mocks -CanShow $false
$err = $null
try { Open-RnSession } catch { $err = $_ }
if (-not $err -or -not (Test-RnNoUserError $err)) { Fail 'no active user did not throw the no-user error' }
if ($script:Log -contains 'openSession') { Fail 'Open-ADTSession called with no active user' }
Assert-Same $script:RnSessionOpen $false 'no session after refusal'
Reset-Mocks
$script:BreakOpen = $true
$err = $null
try { Open-RnSession } catch { $err = $_ }
if (-not $err -or "$err" -notmatch '1602') { Fail "toolkit break not turned into an error: $err" }
Assert-Same $script:RnSessionOpen $false 'no session after a toolkit break'
$script:BreakOpen = $false
Open-RnSession
Assert-Same $script:RnSessionOpen $true 'session opened'
$script:RnSessionOpen = $false
Assert-Same (Test-RnNoUserError ([Management.Automation.ErrorRecord]::new([Exception]::new('x', [NotSupportedException]::new('there are no suitable logged on users available')), 'id', 'NotSpecified', $null))) $true 'inner no-user error'
Assert-Same (Test-RnNoUserError ([Management.Automation.ErrorRecord]::new([NotSupportedException]::new('stream'), 'id', 'NotSpecified', $null))) $false 'other NotSupportedException'

# 3. Restart now on notice 1.
Reset-Mocks -PromptResult 'Restart now'
Assert-Same (Invoke-RnMain $args60) 0 'restart now exit'
Assert-Same (Get-Last).status 'restarted' 'restart now status'
Assert-Same (Get-Last).button 'Restart now' 'restart now button'
Assert-Same $script:Log[0] 'prompt:Snooze 1 hour:600' 'prompt label and timeout'
Assert-FieldBeforeRestart 'restart now'

# 4. Snooze with no marker: marker set to now+60m, no restart.
Reset-Mocks -PromptResult 'Snooze 1 hour'
Assert-Same (Invoke-RnMain $args60) 0 'snooze exit'
Assert-Same (Get-Last).status 'snoozed' 'snooze status'
Assert-Same (Get-Last).snoozeUsed $true 'snooze used'
Assert-Same (ConvertTo-RnUtc $script:Marker.SnoozeUntil) $now.AddMinutes(60) 'snooze until'
Assert-NoRestart 'snooze'

# 4a. Snooze clicked 70 minutes into the prompt: the hour runs from the click.
Reset-Mocks -PromptResult 'Snooze 1 hour' -PromptDelay 70
$null = Invoke-RnMain $args60
Assert-Same (ConvertTo-RnUtc $script:Marker.SnoozeUntil) $now.AddMinutes(130) 'snooze counted from the click'
Assert-Same (ConvertTo-RnUtc $script:Marker.SetAt) $now.AddMinutes(70) 'snooze set at the click'

# 4b. A snooze is running: snoozed, nothing shown, never a restart, even with nobody signed in.
foreach ($users in @(@('CONTOSO\jdoe'), @())) {
    Reset-Mocks -Marker $m -Users $users -PromptResult 'Restart now'
    Assert-Same (Invoke-RnMain $args60) 0 'active snooze exit'
    Assert-Same (Get-Last).status 'snoozed' 'active snooze status'
    Assert-NoRestart 'active snooze'
    if ($script:Log -match '^(prompt|countdown|sleep)') { Fail 'active snooze showed something' }
    Assert-Same "$($script:Marker.SnoozeUntil)" $m.SnoozeUntil 'active snooze not extended'
}

# 5. Snooze ran out: countdown with no second snooze, then restart.
$used = [pscustomobject]@{ SnoozeUntil = $now.AddMinutes(-1).ToString('o'); SetAt = $now.AddMinutes(-61).ToString('o') }
Reset-Mocks -Marker $used -PromptResult 'Snooze 1 hour'
Assert-Same (Invoke-RnMain $args60) 0 'snooze used exit'
Assert-Same ($script:Log -join '|') 'field|countdown:900|sleep:900|field|restart' 'snooze used sequence'
Assert-Same (Get-Last).status 'restartedAfterCountdown' 'snooze used status'
Assert-Same (Get-Last).reason 'snoozeUsed' 'snooze used reason'
Assert-Same (Get-Last).snoozeUsed $true 'snooze used flag'

# 5a. Snooze ran out and the user is disconnected: no toolkit dialog (it would restart
# at once), the countdown is waited out, then restart.
Reset-Mocks -Marker $used -CanShow $false
$null = Invoke-RnMain $args60
Assert-Same ($script:Log -join '|') 'field|sleep:900|field|restart' 'snooze used, no session sequence'
Assert-Same (Get-Last).reason 'NotShown' 'snooze used, no session reason'

# 5b. No answer on notice 1: countdown, then restart.
Reset-Mocks -PromptResult 'Timeout'
$null = Invoke-RnMain $args60
Assert-Same ($script:Log -join '|') 'prompt:Snooze 1 hour:600|field|countdown:900|sleep:900|field|restart' 'no answer sequence'
Assert-Same (Get-Last).reason 'NoAnswer' 'no answer reason'
Assert-Same (Get-Last).snoozeUsed $false 'no answer snooze flag'

# 5c. Prompt could not be shown: wait the countdown without the toolkit dialog, then restart.
Reset-Mocks -PromptResult $null
$null = Invoke-RnMain $args60
Assert-Same ($script:Log -join '|') 'prompt:Snooze 1 hour:600|field|sleep:900|field|restart' 'not shown sequence'

# 6. A marker from before the last boot is cleared and notice 1 shows again.
$old = [pscustomobject]@{ SnoozeUntil = $boot.AddMinutes(-10).ToString('o'); SetAt = $boot.AddMinutes(-70).ToString('o') }
Reset-Mocks -Marker $old -PromptResult 'Snooze 1 hour'
$null = Invoke-RnMain $args60
Assert-Same $script:Log[0] 'clearSnooze' 'stale marker cleared'
Assert-Same (Get-Last).status 'snoozed' 'stale marker allows a new snooze'

# 7. shutdown.exe fails: result failed, exit 1.
Reset-Mocks -PromptResult 'Restart now' -RestartCode 1190
Assert-Same (Invoke-RnMain $args60) 1 'restart failure exit'
Assert-Same (Get-Last).status 'failed' 'restart failure status'

# Report only: the same detection, nothing else. Every side effect except the
# field write is logged, so any prompt, countdown, sleep, restart or marker change fails.
function Invoke-Report {
    param($Sessions = @(), $Users = @(), [switch]$UserProbeFails, $Marker = $null)
    Reset-Mocks -Users $Users -UserProbeFails:$UserProbeFails -Marker $Marker
    $script:MockSessions = $Sessions
    Assert-Same (Invoke-RnReport) 0 'report exit'
    Assert-Same ($script:Log -join '|') 'field' 'report only writes the field'
    Assert-Same ($script:FieldNames -join ',') 'relianSessionState' 'report field name'
    $j = Get-Last
    foreach ($k in @('userPresent', 'reason', 'users', 'sessions', 'pending', 'lastBoot', 'build', 'snooze', 'timestamp')) {
        if (-not $j.PSObject.Properties[$k]) { Fail "report lacks $k" }
    }
    Assert-Same ($j.pending -join ',') 'windowsUpdate' 'report pending'
    # pwsh 7 ConvertFrom-Json turns the string into a [datetime]; the field holds the string.
    Assert-Same (ConvertTo-RnUtc "$(([datetime]$j.lastBoot).ToUniversalTime().ToString('o'))") $boot 'report last boot'
    Assert-Same $j.build 19045 'report build'
    return $j
}
$sys = [pscustomobject]@{ NTAccount = 'NT AUTHORITY\SYSTEM'; SessionId = 0; IsUserSession = $false; ConnectState = 'WTSActive'; IsConsoleSession = $false; IsRdpSession = $false; IdleTime = $null }

$r = Invoke-Report -Sessions @($sys) -Users @('NT AUTHORITY\SYSTEM', '')
Assert-Same $r.userPresent 'none' 'report no user'
Assert-Same $r.reason 'none' 'report no user reason'
Assert-Same @($r.sessions).Count 0 'report no user sessions'
Assert-Same @($r.users).Count 0 'report no user names'

$r = Invoke-Report -Sessions @($sys, (New-Session 'CONTOSO\jdoe' 1 -Console $true -Idle ([timespan]::FromSeconds(150)))) -Users @('CONTOSO\jdoe', 'CONTOSO\jdoe')
Assert-Same $r.userPresent 'present' 'report console user'
Assert-Same $r.reason 'console' 'report console reason'
Assert-Same ($r.users -join ',') 'CONTOSO\jdoe' 'report console names once'
Assert-Same @($r.sessions).Count 1 'report console one session'
Assert-Same $r.sessions[0].user 'CONTOSO\jdoe' 'report session user'
Assert-Same $r.sessions[0].id 1 'report session id'
Assert-Same $r.sessions[0].type 'console' 'report session type'
Assert-Same $r.sessions[0].state 'active' 'report session state'
Assert-Same $r.sessions[0].locked 'unknown' 'report lock not guessed'
Assert-Same $r.sessions[0].idleMinutes 2 'report idle minutes'

$r = Invoke-Report -Sessions @((New-Session 'CONTOSO\rdpuser' 2 -Rdp $true))
Assert-Same $r.reason 'rdp' 'report rdp reason'
Assert-Same $r.sessions[0].idleMinutes $null 'report idle not available'

$r = Invoke-Report -Sessions @((New-Session 'CONTOSO\rdpuser' 2 'WTSDisconnected' -Rdp $true))
Assert-Same $r.userPresent 'disconnected' 'report disconnected, not none'
Assert-Same $r.reason 'disconnected' 'report disconnected reason'
Assert-Same $r.sessions[0].state 'disconnected' 'report disconnected state'

$r = Invoke-Report -Sessions @((New-Session 'CONTOSO\a' 2 'WTSDisconnected' -Rdp $true), (New-Session 'CONTOSO\b' 1 -Console $true))
Assert-Same $r.reason 'console' 'report connected console beats disconnected'

# Cannot tell, with a stale and an active marker: reported, never cleared or written.
$r = Invoke-Report -UserProbeFails -Marker $old
Assert-Same $r.userPresent 'unknown' 'report cannot tell'
Assert-Same $r.reason 'cannotTell' 'report cannot tell reason'
Assert-Same $r.snooze 'stale' 'report stale marker'
Assert-Same "$($script:Marker.SnoozeUntil)" $old.SnoozeUntil 'report leaves a stale marker'
$r = Invoke-Report -Users @('CONTOSO\jdoe') -Marker $m
Assert-Same $r.snooze 'active' 'report active marker'
Assert-Same $r.userPresent 'unknown' 'report ghost: named only by console user or explorer'
Assert-Same $r.reason 'cannotTell' 'report ghost reason'
Assert-Same ($r.users -join ',') 'CONTOSO\jdoe' 'report ghost name listed'
# The same fixed detector as the decision: placeholders and service sessions are nobody.
$r = Invoke-Report -Sessions $notPeople
Assert-Same $r.userPresent 'none' 'report placeholder sessions'
Assert-Same @($r.sessions).Count 0 'report placeholder sessions not listed'

# Pin record and README.
$release = Get-Content -LiteralPath (Join-Path $repoRoot 'windows/releases/restart-notice.json') -Raw | ConvertFrom-Json
Assert-Same $release.ninjaField $RnFieldName 'pin record matches script field'
Assert-Same $release.kind 'notify' 'pin record kind'
if ($release.packageArguments.IndexOf('"ReportOnly"', [StringComparison]::Ordinal) -lt 0) { Fail 'pin record lacks ReportOnly' }
if ($release.packageArguments.IndexOf($RnReportField, [StringComparison]::Ordinal) -lt 0) { Fail 'pin record lacks the report field' }
$readme = [IO.File]::ReadAllText((Join-Path $repoRoot 'README.md'))
if ($readme.IndexOf('windows/packages/restart-notice/Invoke-RestartNotice.ps1', [StringComparison]::Ordinal) -lt 0) { Fail 'README lacks the package section' }

# End to end through the runner's argument parser.
$json = '{"Message":"Windows needs to restart. Save your work.","SnoozeMinutes":"60","PromptMinutes":"10","CountdownMinutes":"15","ReportOnly":"true"}'
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
Set-StrictMode -Off
. (Join-Path $repoRoot 'windows/runner/Invoke-RelianRunner.ps1')
Set-StrictMode -Version Latest
$pairs = ConvertFrom-RelianPackageArguments -PackageArguments $b64
Assert-Same (($pairs | ForEach-Object { $_.Name }) -join ',') 'Message,SnoozeMinutes,PromptMinutes,CountdownMinutes,ReportOnly' 'runner pair names'

# An early exit 0 would skip every assertion after it: the first exit 0 must be the last line.
$self = [IO.File]::ReadAllText($PSCommandPath)
if ($self.IndexOf("exit 0`n", [StringComparison]::Ordinal) -lt $self.IndexOf("Assert-Same ((`$pairs", [StringComparison]::Ordinal)) { Fail 'exit 0 comes before the last assertion' }

Write-Output 'restart-notice tests passed'
exit 0
