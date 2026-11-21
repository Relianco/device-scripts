$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/bc-timezone/Invoke-BcTimeZone.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Assert-Same {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" }
}

function Assert-Like {
    param([string]$Actual, [string]$Pattern, [string]$Label)
    if ($Actual -notlike $Pattern) { Fail "$Label was [$Actual] expected like [$Pattern]" }
}

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

$bc = 'British Columbia Standard Time'
$yukon = 'Yukon Standard Time'
$pacific = 'Pacific Standard Time'

function Reset-Fake {
    param(
        [string]$CurrentId = 'Pacific Standard Time',
        [string[]]$AvailableIds = @('Pacific Standard Time', 'Yukon Standard Time', 'Eastern Standard Time'),
        [string[]]$Comet = @()
    )
    $script:fakeCurrent = $CurrentId
    $script:fakeAvailable = @($AvailableIds | ForEach-Object { [pscustomobject]@{ Id = $_ } })
    $script:fakeComet = $Comet
    $script:calls = New-Object System.Collections.Generic.List[string]
    $script:readFails = $false
    $script:setFails = $false
    $script:readFailAfterSet = $false
    $script:setDoesNotStick = $false
    $script:restartFails = $false
}

function Get-BctzCurrentZone {
    if ($script:readFails) { throw 'registry read denied' }
    if ($script:readFailAfterSet -and $script:calls.Count -gt 0) { throw 'read-back failed' }
    return [pscustomobject]@{ Id = $script:fakeCurrent }
}

function Get-BctzAvailableZones {
    if ($script:readFails) { throw 'time zone list denied' }
    return $script:fakeAvailable
}

function Set-BctzZone {
    param([string]$Id)
    $script:calls.Add("set $Id")
    if ($script:setFails) { throw 'Set-TimeZone access denied' }
    if (-not $script:setDoesNotStick) { $script:fakeCurrent = $Id }
}

function Get-BctzCometServices {
    return @($script:fakeComet)
}

function Restart-BctzService {
    param([string]$Name)
    $script:calls.Add("restart $Name")
    if ($script:restartFails) { throw 'service did not stop' }
}

function Get-BctzNow {
    return [datetimeoffset]::Parse('2026-11-18T13:23:00-07:00')
}

# 1. Unpatched machine on Pacific Standard Time, no fallback: exit 3 (needs the update) in check mode, nothing written.
Reset-Fake -CurrentId $pacific -AvailableIds @($pacific, $yukon)
$run = Invoke-BctzRun
Assert-Same $run.exitCode 3 'unpatched check exit'
Assert-Same $run.record.mode 'check' 'unpatched check mode'
Assert-Same $run.record.before $pacific 'unpatched check before'
Assert-Same $run.record.after $pacific 'unpatched check after'
Assert-Same $run.record.target $bc 'unpatched check target'
Assert-Same $run.record.hasTarget $false 'unpatched hasTarget'
Assert-Same $run.record.changed $false 'unpatched check changed'
Assert-Same $run.record.verdict "needs update: $bc is not available on this device" 'unpatched check verdict'
Assert-Same $script:calls.Count 0 'unpatched check writes nothing'

# 2. Same with Fix: still exit 3, no silent fallback, nothing written.
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 3 'unpatched fix exit'
Assert-Same $run.record.verdict "needs update: $bc is not available on this device" 'unpatched fix verdict'
Assert-Same $script:calls.Count 0 'unpatched fix writes nothing'

# 3. Unpatched with the explicit Yukon fallback and Fix: switches to Yukon Standard Time.
$run = Invoke-BctzRun -Fix -FallbackZone $yukon
Assert-Same $run.exitCode 0 'fallback fix exit'
Assert-Same $run.record.after $yukon 'fallback fix after'
Assert-Same $run.record.target $yukon 'fallback fix target'
Assert-Same $run.record.changed $true 'fallback fix changed'
Assert-Same $run.record.verdict "fixed: set $yukon (was $pacific)" 'fallback fix verdict'
Assert-Same ($script:calls -join ',') "set $yukon" 'fallback fix call'

# 4. Second fallback run, now on Yukon: compliant, no change.
$script:calls.Clear()
$run = Invoke-BctzRun -Fix -FallbackZone $yukon
Assert-Same $run.exitCode 0 'fallback second run exit'
Assert-Same $run.record.verdict "compliant: $yukon" 'fallback second run verdict'
Assert-Same $script:calls.Count 0 'fallback second run is a no-op'

# 5. Patched machine on Yukon without the fallback switch: left alone (Yukon is UTC-7 already).
Reset-Fake -CurrentId $yukon -AvailableIds @($pacific, $yukon, $bc)
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 0 'patched on Yukon no-fallback exit'
Assert-Same $run.record.changed $false 'patched on Yukon no-fallback changed'
Assert-Same $run.record.verdict "untouched zone: $yukon" 'patched on Yukon no-fallback verdict'
Assert-Same $script:calls.Count 0 'patched on Yukon no-fallback writes nothing'

# 6. Patched machine on Yukon with the fallback switch: check flags it, Fix upgrades to the target.
$run = Invoke-BctzRun -FallbackZone $yukon
Assert-Same $run.record.verdict "wrong zone: $yukon (want $bc)" 'patched on Yukon check verdict'
Assert-Same $script:calls.Count 0 'patched on Yukon check writes nothing'
$run = Invoke-BctzRun -Fix -FallbackZone $yukon
Assert-Same $run.exitCode 0 'patched on Yukon fix exit'
Assert-Same $run.record.after $bc 'patched on Yukon fix after'
Assert-Same $run.record.verdict "fixed: set $bc (was $yukon)" 'patched on Yukon fix verdict'

# 7. Patched machine on Pacific with Comet installed: Fix switches, then restarts both Comet services.
Reset-Fake -CurrentId $pacific -AvailableIds @($pacific, $yukon, $bc) -Comet @('backup.delegate', 'backup.elevator')
$run = Invoke-BctzRun
Assert-Same $run.record.verdict "wrong zone: $pacific (want $bc)" 'patched on Pacific check verdict'
Assert-Same $script:calls.Count 0 'check mode restarts nothing'
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 0 'comet fix exit'
Assert-Same $run.record.changed $true 'comet fix changed'
Assert-Same ($script:calls -join ',') "set $bc,restart backup.delegate,restart backup.elevator" 'comet fix calls'
Assert-Same ($run.record.restarted -join ',') 'backup.delegate,backup.elevator' 'comet restarted list'

# 8. Already on the target with Comet installed: compliant, no restart.
$script:calls.Clear()
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 0 'compliant exit'
Assert-Same $run.record.verdict "compliant: $bc" 'compliant verdict'
Assert-Same $script:calls.Count 0 'compliant no-op, no restart'

# 9. Patched machine on Pacific without Comet: switches, restarts nothing.
Reset-Fake -CurrentId $pacific -AvailableIds @($pacific, $bc)
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 0 'no comet fix exit'
Assert-Same ($script:calls -join ',') "set $bc" 'no comet fix calls'
Assert-Same @($run.record.restarted).Count 0 'no comet restarted list'

# 10. Comet restart failure: zone changed, exit 1 so the run shows as failed.
Reset-Fake -CurrentId $pacific -AvailableIds @($pacific, $bc) -Comet @('backup.delegate')
$script:restartFails = $true
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 1 'restart failure exit'
Assert-Same $run.record.after $bc 'restart failure after'
Assert-Same $run.record.changed $true 'restart failure changed'
Assert-Like $run.record.verdict "fixed: set $bc (was $pacific); restart failed backup.delegate:*" 'restart failure verdict'

# 11. Travellers on other zones are left untouched even with Fix.
foreach ($otherZone in @('Eastern Standard Time', 'Mountain Standard Time', 'UTC')) {
    Reset-Fake -CurrentId $otherZone -AvailableIds @($pacific, $yukon, $bc, $otherZone) -Comet @('backup.delegate')
    $run = Invoke-BctzRun -Fix
    Assert-Same $run.exitCode 0 "traveller $otherZone exit"
    Assert-Same $run.record.changed $false "traveller $otherZone changed"
    Assert-Same $run.record.verdict "untouched zone: $otherZone" "traveller $otherZone verdict"
    Assert-Same $script:calls.Count 0 "traveller $otherZone writes nothing"
}
# A traveller is untouched even when the target is missing (no exit 3).
Reset-Fake -CurrentId 'Eastern Standard Time' -AvailableIds @($pacific, 'Eastern Standard Time')
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 0 'traveller unpatched exit'

# 12. Generic: another target and a list of source zones.
Reset-Fake -CurrentId 'Mountain Standard Time' -AvailableIds @('Mountain Standard Time', 'US Mountain Standard Time')
$run = Invoke-BctzRun -Fix -TargetZone 'US Mountain Standard Time' -FromZone 'Pacific Standard Time,Mountain Standard Time'
Assert-Same $run.exitCode 0 'generic fix exit'
Assert-Same $run.record.after 'US Mountain Standard Time' 'generic fix after'
Assert-Same ($script:calls -join ',') 'set US Mountain Standard Time' 'generic fix call'

# 13. Error paths.
Reset-Fake -CurrentId $pacific
$script:readFails = $true
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 1 'read failure exit'
Assert-Like $run.record.verdict 'time zone read failed, not changed:*' 'read failure verdict'
Assert-Same $script:calls.Count 0 'read failure writes nothing'

Reset-Fake -CurrentId $pacific -AvailableIds @($pacific, $bc) -Comet @('backup.delegate')
$script:setFails = $true
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 1 'set failure exit'
Assert-Like $run.record.verdict "fix failed setting $($bc):*" 'set failure verdict'
Assert-Same ($script:calls -join ',') "set $bc" 'set failure restarts nothing'

Reset-Fake -CurrentId $pacific -AvailableIds @($pacific, $bc)
$script:readFailAfterSet = $true
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 1 'read-back failure exit'
Assert-Same $run.record.after $null 'read-back failure after is null'
Assert-Same $run.record.changed $null 'read-back failure changed is null'
Assert-Like $run.record.verdict 'fix not verified, read after set failed:*' 'read-back failure verdict'

Reset-Fake -CurrentId $pacific -AvailableIds @($pacific, $bc)
$script:setDoesNotStick = $true
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 1 'set did not stick exit'
Assert-Same $run.record.verdict "fix incomplete: still on $pacific (wanted $bc)" 'set did not stick verdict'

# 14. Runner Action, Fix, and empty PinVersion mapping.
foreach ($a in @('Install', 'Update', 'Repair', 'Reinstall')) {
    Assert-Same (Get-BctzMode $a '') 'check' "$a is a read-only check"
    Assert-Same (Get-BctzMode $a 'false') 'check' "$a with Fix false"
    Assert-Same (Get-BctzMode $a 'true') 'fix' "$a with Fix true"
    Assert-Same (Get-BctzMode $a 'true' '') 'none' "$a with empty PinVersion is disabled"
    Assert-Same (Get-BctzMode $a 'yes' '   ') 'none' "$a with whitespace PinVersion exits before validation"
}
Assert-Same (Get-BctzMode 'Uninstall' 'true') 'none' 'Uninstall ignores Fix'
Assert-Same (Get-BctzMode 'Bogus' 'yes' '') 'none' 'empty PinVersion disables even invalid Action/Fix'
foreach ($bad in @(@('Bogus', ''), @('', ''), @('Install', 'yes'), @('Install', '1'))) {
    $threw = $false
    try { $null = Get-BctzMode $bad[0] $bad[1] '1.0.0' } catch { $threw = $true }
    if (-not $threw) { Fail "Get-BctzMode accepted [$($bad[0])] [$($bad[1])]" }
}

# 15. Static checks on source and release metadata.
$source = [IO.File]::ReadAllText($scriptPath)
foreach ($bad in @('Restart-Computer', 'shutdown', 'Set-Service', 'Stop-Service', 'Start-Service')) {
    # Restart-Service is allowed (Comet only); a bare Start-Service is not.
    if ($source -match ('(?i)(?<!Re)' + [regex]::Escape($bad))) { Fail "source contains $bad" }
}
if (([regex]::Matches($source, 'Restart-Service')).Count -ne 1) { Fail 'Restart-Service is used outside the Comet seam' }
foreach ($need in @('[string]$DeploymentType', '[string]$Action', '[string]$PinVersion', '[string]$Fix', '[string]$TargetZone', '[string]$FallbackZone', '[string]$FromZone')) {
    if ($source.IndexOf($need, [StringComparison]::Ordinal) -lt 0) { Fail "param block lacks $need" }
}

$release = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows/releases/bc-timezone.json') | ConvertFrom-Json
Assert-Same $release.installsSoftware $false 'pin record installsSoftware'
if ($release.PSObject.Properties.Name -contains 'ninjaField') { Fail 'pin record names an RMM field; the package reports on stdout only' }
if ($release.packageArguments.IndexOf('eyJGaXgiOiJ0cnVlIn0=', [StringComparison]::Ordinal) -lt 0) { Fail 'pin record lacks the base64 example' }

# End to end through the runner's argument parser: Fix and FallbackZone reach the package as named pairs.
Set-StrictMode -Off
. (Join-Path $repoRoot 'windows/runner/Invoke-RelianRunner.ps1')
Set-StrictMode -Version Latest
$pairs = @(ConvertFrom-RelianPackageArguments -PackageArguments 'eyJGaXgiOiJ0cnVlIn0=')
Assert-Same $pairs.Count 1 'runner pair count'
Assert-Same $pairs[0].Name 'Fix' 'runner pair name'
Assert-Same $pairs[0].Value 'true' 'runner pair value'
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"Fix":"true","FallbackZone":"Yukon Standard Time"}'))
$pairs = ConvertFrom-RelianPackageArguments -PackageArguments $b64
Assert-Same $pairs.Count 2 'runner fallback pair count'
Assert-Same ($pairs[1].Name + '=' + $pairs[1].Value) 'FallbackZone=Yukon Standard Time' 'runner fallback pairs'

$self = [IO.File]::ReadAllText($PSCommandPath) -replace "`r`n", "`n"
$firstExit = $self.IndexOf("exit 0`n", [StringComparison]::Ordinal)
if ($firstExit -lt 0 -or $firstExit -lt $self.IndexOf('runner fallback pairs', [StringComparison]::Ordinal)) { Fail 'exit 0 comes before the last assertion' }

Write-Output 'bc-timezone tests passed'
exit 0
