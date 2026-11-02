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

# User decision.
Assert-Same (Get-RnUserPresence -Users @() -ProbeFailed $true) 'unknown' 'probe failed'
Assert-Same (Get-RnUserPresence -Users @() -ProbeFailed $false) 'none' 'no sessions'
Assert-Same (Get-RnUserPresence -Users @($null, '', 'NT AUTHORITY\SYSTEM', 'Window Manager\DWM-1', 'Font Driver Host\UMFD-0', 'WORKGROUP\SYSTEM') -ProbeFailed $false) 'none' 'service accounts only'
Assert-Same (Get-RnUserPresence -Users @('NT AUTHORITY\SYSTEM', 'CONTOSO\jdoe') -ProbeFailed $false) 'present' 'a person'
Assert-Same (Get-RnUserPresence -Users @('AzureAD\JaneDoe') -ProbeFailed $false) 'present' 'an Entra user'

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
function Reset-Mocks {
    param([string[]]$Pending = @('windowsUpdate'), $Marker = $null, $Users = @('CONTOSO\jdoe'), [switch]$UserProbeFails, $PromptResult = 'Timeout', [int]$RestartCode = 0, [int]$PromptDelay = 0)
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
    $script:RnGetUsers = { if ($script:MockUserFails) { throw 'cim down' }; $script:MockUsers }
    $script:RnPrompt = { param($T, $S, $Sec) $script:Log.Add("prompt:${S}:$Sec"); $script:Clock = $script:Clock.AddMinutes($script:PromptDelay); $script:MockPrompt }
    $script:RnCountdown = { param($T, $Sec) $script:Log.Add("countdown:$Sec") }
    $script:RnSleep = { param($Sec) $script:Log.Add("sleep:$Sec") }
    $script:RnRestart = { $script:Log.Add('restart'); $script:MockRestart }
    $script:RnSetField = { param($Json) $script:Log.Add('field'); $script:Fields.Add(($Json | ConvertFrom-Json)); $true }
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
Reset-Mocks -Users @('NT AUTHORITY\SYSTEM')
Assert-Same (Invoke-RnMain $args60) 0 'no user exit'
Assert-Same (Get-Last).status 'restartedNoUser' 'no user status'
Assert-FieldBeforeRestart 'no user'
if ($script:Log -match '^prompt') { Fail 'no user prompted' }

# 2b. Cannot tell: treated as a user, so the prompt shows.
Reset-Mocks -UserProbeFails -PromptResult 'Snooze 1 hour'
$null = Invoke-RnMain $args60
Assert-Same (Get-Last).status 'snoozed' 'unknown user is prompted'
Assert-NoRestart 'unknown user'

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

# Pin record and README.
$release = Get-Content -LiteralPath (Join-Path $repoRoot 'windows/releases/restart-notice.json') -Raw | ConvertFrom-Json
Assert-Same $release.ninjaField $RnFieldName 'pin record matches script field'
Assert-Same $release.kind 'notify' 'pin record kind'
$readme = [IO.File]::ReadAllText((Join-Path $repoRoot 'README.md'))
if ($readme.IndexOf('windows/packages/restart-notice/Invoke-RestartNotice.ps1', [StringComparison]::Ordinal) -lt 0) { Fail 'README lacks the package section' }

# End to end through the runner's argument parser.
$json = '{"Message":"Windows needs to restart. Save your work.","SnoozeMinutes":"60","PromptMinutes":"10","CountdownMinutes":"15"}'
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
Set-StrictMode -Off
. (Join-Path $repoRoot 'windows/runner/Invoke-RelianRunner.ps1')
Set-StrictMode -Version Latest
$pairs = ConvertFrom-RelianPackageArguments -PackageArguments $b64
Assert-Same (($pairs | ForEach-Object { $_.Name }) -join ',') 'Message,SnoozeMinutes,PromptMinutes,CountdownMinutes' 'runner pair names'

# An early exit 0 would skip every assertion after it: the first exit 0 must be the last line.
$self = [IO.File]::ReadAllText($PSCommandPath)
if ($self.IndexOf("exit 0`n", [StringComparison]::Ordinal) -lt $self.IndexOf("Assert-Same ((`$pairs", [StringComparison]::Ordinal)) { Fail 'exit 0 comes before the last assertion' }

Write-Output 'restart-notice tests passed'
exit 0
