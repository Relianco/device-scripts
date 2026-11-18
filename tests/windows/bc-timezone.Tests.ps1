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

function Reset-Fake {
    param(
        [string]$CurrentId = 'Pacific Standard Time',
        [string[]]$AvailableIds = @('Pacific Standard Time', 'Yukon Standard Time', 'Eastern Standard Time')
    )
    $script:fakeCurrent = $CurrentId
    $script:fakeAvailable = @($AvailableIds | ForEach-Object { [pscustomobject]@{ Id = $_ } })
    $script:calls = New-Object System.Collections.Generic.List[string]
    $script:readFails = $false
    $script:setFails = $false
    $script:readFailAfterSet = $false
    $script:setDoesNotStick = $false
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

function Get-BctzNow {
    return [datetimeoffset]::Parse('2026-11-18T13:23:00-07:00')
}

# 1. Unpatched machine on Pacific Standard Time (no British Columbia Standard Time available):
#    check mode reports wrong zone (want Yukon Standard Time) and changes nothing.
Reset-Fake -CurrentId 'Pacific Standard Time' -AvailableIds @('Pacific Standard Time', 'Yukon Standard Time')
$run = Invoke-BctzRun
Assert-Same $run.exitCode 0 'unpatched check exit'
Assert-Same $run.record.mode 'check' 'unpatched check mode'
Assert-Same $run.record.before 'Pacific Standard Time' 'unpatched check before'
Assert-Same $run.record.after 'Pacific Standard Time' 'unpatched check after'
Assert-Same $run.record.target 'Yukon Standard Time' 'unpatched check target'
Assert-Same $run.record.hasBritishColumbia $false 'unpatched hasBritishColumbia'
Assert-Same $run.record.changed $false 'unpatched check changed'
Assert-Same $run.record.verdict 'wrong zone: Pacific Standard Time (want Yukon Standard Time)' 'unpatched check verdict'
Assert-Same $script:calls.Count 0 'unpatched check writes nothing'

# 2. Unpatched machine on Pacific Standard Time with Fix: switches to Yukon Standard Time.
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 0 'unpatched fix exit'
Assert-Same $run.record.mode 'fix' 'unpatched fix mode'
Assert-Same $run.record.before 'Pacific Standard Time' 'unpatched fix before'
Assert-Same $run.record.after 'Yukon Standard Time' 'unpatched fix after'
Assert-Same $run.record.target 'Yukon Standard Time' 'unpatched fix target'
Assert-Same $run.record.changed $true 'unpatched fix changed'
Assert-Same $run.record.verdict 'fixed: set Yukon Standard Time (was Pacific Standard Time)' 'unpatched fix verdict'
Assert-Same ($script:calls -join ',') 'set Yukon Standard Time' 'unpatched fix call'

# 3. Second run on unpatched machine now on Yukon Standard Time: compliant, no change.
$script:calls.Clear()
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 0 'unpatched second run exit'
Assert-Same $run.record.changed $false 'unpatched second run changed'
Assert-Same $run.record.verdict 'compliant: Yukon Standard Time' 'unpatched second run verdict'
Assert-Same $script:calls.Count 0 'unpatched second run is a no-op'

# 4. Patched machine (has British Columbia Standard Time) still on Yukon Standard Time:
#    check mode flags it to upgrade from Yukon fallback to British Columbia Standard Time.
Reset-Fake -CurrentId 'Yukon Standard Time' -AvailableIds @('Pacific Standard Time', 'Yukon Standard Time', 'British Columbia Standard Time')
$run = Invoke-BctzRun
Assert-Same $run.exitCode 0 'patched on Yukon check exit'
Assert-Same $run.record.target 'British Columbia Standard Time' 'patched on Yukon target'
Assert-Same $run.record.hasBritishColumbia $true 'patched hasBritishColumbia'
Assert-Same $run.record.verdict 'wrong zone: Yukon Standard Time (want British Columbia Standard Time)' 'patched on Yukon check verdict'
Assert-Same $script:calls.Count 0 'patched on Yukon check writes nothing'

# 5. Patched machine on Yukon Standard Time with Fix: upgrades to British Columbia Standard Time.
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 0 'patched on Yukon fix exit'
Assert-Same $run.record.before 'Yukon Standard Time' 'patched on Yukon fix before'
Assert-Same $run.record.after 'British Columbia Standard Time' 'patched on Yukon fix after'
Assert-Same $run.record.changed $true 'patched on Yukon fix changed'
Assert-Same $run.record.verdict 'fixed: set British Columbia Standard Time (was Yukon Standard Time)' 'patched on Yukon fix verdict'
Assert-Same ($script:calls -join ',') 'set British Columbia Standard Time' 'patched on Yukon fix call'

# 6. Patched machine on Pacific Standard Time with Fix: switches directly to British Columbia Standard Time.
Reset-Fake -CurrentId 'Pacific Standard Time' -AvailableIds @('Pacific Standard Time', 'Yukon Standard Time', 'British Columbia Standard Time')
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 0 'patched on Pacific fix exit'
Assert-Same $run.record.after 'British Columbia Standard Time' 'patched on Pacific fix after'
Assert-Same $run.record.changed $true 'patched on Pacific fix changed'
Assert-Same ($script:calls -join ',') 'set British Columbia Standard Time' 'patched on Pacific fix call'

# 7. Patched machine already on British Columbia Standard Time: compliant in both check and fix modes.
$script:calls.Clear()
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 0 'patched compliant exit'
Assert-Same $run.record.changed $false 'patched compliant changed'
Assert-Same $run.record.verdict 'compliant: British Columbia Standard Time' 'patched compliant verdict'
Assert-Same $script:calls.Count 0 'patched compliant no-op'

# 8. Traveller on another zone (e.g. Eastern Standard Time or Mountain Standard Time): left untouched even with Fix.
foreach ($otherZone in @('Eastern Standard Time', 'Mountain Standard Time', 'UTC')) {
    Reset-Fake -CurrentId $otherZone -AvailableIds @('Pacific Standard Time', 'Yukon Standard Time', 'British Columbia Standard Time', $otherZone)
    $run = Invoke-BctzRun -Fix
    Assert-Same $run.exitCode 0 "traveller $otherZone exit"
    Assert-Same $run.record.before $otherZone "traveller $otherZone before"
    Assert-Same $run.record.after $otherZone "traveller $otherZone after"
    Assert-Same $run.record.changed $false "traveller $otherZone changed"
    Assert-Same $run.record.verdict "untouched non-Pacific zone: $otherZone" "traveller $otherZone verdict"
    Assert-Same $script:calls.Count 0 "traveller $otherZone writes nothing"
}

# 9. Error paths: initial read failure, missing target zone, Set-TimeZone failure, read-back failure, or zone did not stick.
Reset-Fake -CurrentId 'Pacific Standard Time'
$script:readFails = $true
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 1 'read failure exit'
Assert-Like $run.record.verdict 'time zone read failed, not changed:*' 'read failure verdict'
Assert-Same $script:calls.Count 0 'read failure writes nothing'

Reset-Fake -CurrentId 'Pacific Standard Time' -AvailableIds @('Pacific Standard Time')
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 1 'missing target zone exit'
Assert-Same $run.record.verdict 'target zone Yukon Standard Time is not available on this device' 'missing target zone verdict'
Assert-Same $script:calls.Count 0 'missing target zone writes nothing'

Reset-Fake -CurrentId 'Pacific Standard Time' -AvailableIds @('Pacific Standard Time', 'Yukon Standard Time')
$script:setFails = $true
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 1 'set failure exit'
Assert-Like $run.record.verdict 'fix failed setting Yukon Standard Time:*' 'set failure verdict'

Reset-Fake -CurrentId 'Pacific Standard Time' -AvailableIds @('Pacific Standard Time', 'Yukon Standard Time')
$script:readFailAfterSet = $true
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 1 'read-back failure exit'
Assert-Same $run.record.after $null 'read-back failure after is null'
Assert-Same $run.record.changed $null 'read-back failure changed is null'
Assert-Like $run.record.verdict 'fix not verified, read after set failed:*' 'read-back failure verdict'

Reset-Fake -CurrentId 'Pacific Standard Time' -AvailableIds @('Pacific Standard Time', 'Yukon Standard Time')
$script:setDoesNotStick = $true
$run = Invoke-BctzRun -Fix
Assert-Same $run.exitCode 1 'set did not stick exit'
Assert-Same $run.record.verdict 'fix incomplete: still on Pacific Standard Time (wanted Yukon Standard Time)' 'set did not stick verdict'

# 10. Runner Action and Fix mapping.
foreach ($a in @('Install', 'Update', 'Repair', 'Reinstall')) {
    Assert-Same (Get-BctzMode $a '') 'check' "$a is a read-only check"
    Assert-Same (Get-BctzMode $a 'false') 'check' "$a with Fix false"
    Assert-Same (Get-BctzMode $a 'true') 'fix' "$a with Fix true"
}
Assert-Same (Get-BctzMode 'Uninstall' 'true') 'none' 'Uninstall ignores Fix'
foreach ($bad in @(@('Bogus', ''), @('', ''), @('Install', 'yes'), @('Install', '1'))) {
    $threw = $false
    try { $null = Get-BctzMode $bad[0] $bad[1] } catch { $threw = $true }
    if (-not $threw) { Fail "Get-BctzMode accepted [$($bad[0])] [$($bad[1])]" }
}

# 11. Static checks on source and release metadata.
$source = [IO.File]::ReadAllText($scriptPath)
foreach ($bad in @('Restart-Computer', 'shutdown', 'Set-Service', 'Stop-Service', 'Start-Service')) {
    if ($source.IndexOf($bad, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Fail "source contains $bad" }
}
foreach ($need in @('[string]$DeploymentType', '[string]$Action', '[string]$PinVersion', "[string]`$Fix = ''")) {
    if ($source.IndexOf($need, [StringComparison]::Ordinal) -lt 0) { Fail "param block lacks $need" }
}

$release = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows/releases/bc-timezone.json') | ConvertFrom-Json
Assert-Same $release.installsSoftware $false 'pin record installsSoftware'
if ($release.PSObject.Properties.Name -contains 'ninjaField') { Fail 'pin record names an RMM field; the package reports on stdout only' }
if ($release.packageArguments.IndexOf('eyJGaXgiOiJ0cnVlIn0=', [StringComparison]::Ordinal) -lt 0) { Fail 'pin record lacks the base64 example' }

# End to end through the runner's argument parser: Fix reaches the package as a named pair.
Set-StrictMode -Off
. (Join-Path $repoRoot 'windows/runner/Invoke-RelianRunner.ps1')
Set-StrictMode -Version Latest
$pairs = @(ConvertFrom-RelianPackageArguments -PackageArguments 'eyJGaXgiOiJ0cnVlIn0=')
Assert-Same $pairs.Count 1 'runner pair count'
Assert-Same $pairs[0].Name 'Fix' 'runner pair name'
Assert-Same $pairs[0].Value 'true' 'runner pair value'

$self = [IO.File]::ReadAllText($PSCommandPath) -replace "`r`n", "`n"
$firstExit = $self.IndexOf("exit 0`n", [StringComparison]::Ordinal)
if ($firstExit -lt 0 -or $firstExit -lt $self.IndexOf('Assert-Same $pairs[0].Value', [StringComparison]::Ordinal)) { Fail 'exit 0 comes before the last assertion' }

Write-Output 'bc-timezone tests passed'
exit 0
