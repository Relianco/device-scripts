<#
.SYNOPSIS
    Time zone package for the Relian deploy runner (NinjaOne script 374). Checks, and with Fix sets,
    a target time zone. The default target is British Columbia Standard Time (BC permanent UTC-7).

.DESCRIPTION
    British Columbia is permanent UTC-7 from 2026-11-01, while Pacific Standard Time falls back to
    UTC-8 in winter. Windows adds the British Columbia Standard Time zone in its cumulative updates;
    Pacific Standard Time itself is unchanged.

    TargetZone (default British Columbia Standard Time) is the zone to move to. FromZone is a
    comma-separated list of zones to move from (default Pacific Standard Time). A device on any other
    zone, a traveller for example, is left alone.

    When the target zone is not in the local time zone database and the device is on a FromZone, the
    run exits 3: the device needs the cumulative update that adds the zone. The package installs no
    update. FallbackZone (empty by default) is the explicit switch for the old behaviour: when the
    target is missing it sets the fallback (for example Yukon Standard Time) instead, and once the
    target exists it moves a device on the fallback to the target.

    By default this package is read-only. With Fix "true" it sets the zone, reads it back, and when
    the zone changed restarts the Comet Backup services (backup.delegate, backup.elevator) that are
    installed, so their schedules use the new offset. It never restarts the computer.

    The runner passes DeploymentType, Action and PinVersion, then each PackageArguments pair as
    -Name value. Fix, TargetZone, FromZone and FallbackZone are strings: base64 of {"Fix":"true"} is
    eyJGaXgiOiJ0cnVlIn0=. Install, Update, Repair and Reinstall all run the check (and the fix when
    Fix is "true"). Uninstall changes nothing and exits 0.

    The result is one line of compact JSON, printed last on stdout, with a short "verdict". The
    package writes no RMM field. Exit codes: 0 compliant, untouched or fixed; 3 the target zone is
    missing (needs the cumulative update); 1 a read, set, read-back or service restart failed.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM
    No external module dependencies
#>

# Not Mandatory: a mandatory param block prompts when this file is dot-sourced
# under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Fix = '',
    [string]$TargetZone = '',
    [string]$FromZone = '',
    [string]$FallbackZone = ''
)

$ProgressPreference = 'SilentlyContinue'

$BctzDefaultTarget = 'British Columbia Standard Time'
$BctzDefaultFrom = 'Pacific Standard Time'
$BctzCometServices = @('backup.delegate', 'backup.elevator')
$BctzNeedsUpdateExit = 3

function Write-BctzStatus {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$Level] $timestamp - $Message"
}

function Limit-BctzText {
    param([string]$Text, [int]$Max = 200)
    if ($null -eq $Text) { return $null }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '...' }
    return $t
}

# Seams for unit tests.
function Get-BctzCurrentZone {
    return (Get-TimeZone -ErrorAction Stop)
}

function Get-BctzAvailableZones {
    return @(Get-TimeZone -ListAvailable -ErrorAction Stop)
}

function Set-BctzZone {
    param([string]$Id)
    Set-TimeZone -Id $Id -ErrorAction Stop
}

# Running Comet service names, in restart order. A stopped service stays stopped.
function Get-BctzCometServices {
    return @($BctzCometServices | Where-Object { (Get-Service -Name $_ -ErrorAction SilentlyContinue).Status -eq 'Running' })
}

function Restart-BctzService {
    param([string]$Name)
    Restart-Service -Name $Name -ErrorAction Stop
}

function Get-BctzNow {
    return (Get-Date)
}

# Pure: 'check', 'fix' or 'none' for a runner Action, Fix string, and PinVersion. Throws on bad input.
# An empty PinVersion is the off switch: returns 'none' before validating Action or Fix.
function Get-BctzMode {
    param([string]$Action, [string]$Fix, [string]$PinVersion = '1.0.0')
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { return 'none' }
    if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) {
        throw 'Action must be Install, Update, Repair, Reinstall, or Uninstall.'
    }
    if ($Action -eq 'Uninstall') { return 'none' }
    if ($Fix -eq '' -or $Fix -eq 'false') { return 'check' }
    if ($Fix -eq 'true') { return 'fix' }
    throw 'Fix must be true or false.'
}

# Pure: picks the zone to set and whether the current zone needs changing.
# A device on a FromZone, or on the FallbackZone once the target exists, is flagged. Any other zone is left alone.
function Get-BctzPlan {
    param([string]$CurrentId, [string]$TargetZone, [string[]]$FromZones, [string]$FallbackZone, [string[]]$AvailableIds)
    $hasTarget = $AvailableIds -contains $TargetZone
    $useFallback = (-not $hasTarget) -and $FallbackZone -ne '' -and ($AvailableIds -contains $FallbackZone)
    $target = if ($useFallback) { $FallbackZone } else { $TargetZone }
    $needsChange = ($CurrentId -ne $target) -and (($FromZones -contains $CurrentId) -or ($hasTarget -and $FallbackZone -ne '' -and $CurrentId -eq $FallbackZone))
    return [ordered]@{
        target          = $target
        hasTarget       = $hasTarget
        needsChange     = $needsChange
        targetAvailable = ($hasTarget -or $useFallback)
    }
}

function Invoke-BctzRun {
    param(
        [switch]$Fix,
        [string]$TargetZone = $BctzDefaultTarget,
        [string]$FromZone = $BctzDefaultFrom,
        [string]$FallbackZone = ''
    )
    $mode = if ($Fix) { 'fix' } else { 'check' }
    $fromZones = @($FromZone -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $current = $null
    $available = @()
    try {
        $current = Get-BctzCurrentZone
        $available = @(Get-BctzAvailableZones | ForEach-Object { [string]$_.Id })
    } catch {
        $err = Limit-BctzText "$_" 160
        $nowErr = Get-BctzNow
        $record = [ordered]@{
            mode      = $mode
            before    = $null
            after     = $null
            target    = $TargetZone
            hasTarget = $false
            changed   = $false
            restarted = @()
            localTime = $nowErr.ToString('yyyy-MM-ddTHH:mm:sszzz')
            verdict   = "time zone read failed, not changed: $err"
            timestamp = $nowErr.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            version   = '1.1'
        }
        return [ordered]@{ record = $record; exitCode = 1 }
    }

    $beforeId = [string]$current.Id
    $plan = Get-BctzPlan -CurrentId $beforeId -TargetZone $TargetZone -FromZones $fromZones -FallbackZone $FallbackZone -AvailableIds $available

    $afterId = $beforeId
    $changed = $false
    $restarted = @()
    $code = 0
    $verdict = ''

    if (-not $plan.needsChange) {
        if ($beforeId -eq $plan.target) {
            $verdict = "compliant: $beforeId"
        } else {
            $verdict = "untouched zone: $beforeId"
        }
    } elseif (-not $plan.targetAvailable) {
        $code = $BctzNeedsUpdateExit
        $verdict = "needs update: $($plan.target) is not available on this device"
    } elseif (-not $Fix) {
        $verdict = "wrong zone: $beforeId (want $($plan.target))"
    } else {
        $setError = $null
        try {
            Set-BctzZone -Id $plan.target
        } catch {
            $setError = Limit-BctzText "$_" 160
        }
        $readAfterError = $null
        try {
            $afterId = [string](Get-BctzCurrentZone).Id
        } catch {
            $afterId = $null
            $changed = $null
            $readAfterError = Limit-BctzText "$_" 160
        }

        if ($setError) {
            $code = 1
            $verdict = "fix failed setting $($plan.target): $setError"
        } elseif ($readAfterError) {
            $code = 1
            $verdict = "fix not verified, read after set failed: $readAfterError"
        } elseif ($afterId -eq $plan.target) {
            $changed = ($afterId -ne $beforeId)
            $verdict = "fixed: set $afterId (was $beforeId)"
            # Comet schedules run on local time; restart so they pick up the new offset.
            if ($changed) {
                foreach ($svc in @(Get-BctzCometServices)) {
                    try {
                        Restart-BctzService -Name $svc
                        $restarted += $svc
                    } catch {
                        $code = 1
                        $verdict += "; restart failed $($svc): $(Limit-BctzText "$_" 120)"
                    }
                }
            }
        } else {
            $code = 1
            $changed = ($afterId -ne $beforeId)
            $verdict = "fix incomplete: still on $afterId (wanted $($plan.target))"
        }
    }

    $now = Get-BctzNow
    $record = [ordered]@{
        mode      = $mode
        before    = $beforeId
        after     = $afterId
        target    = $plan.target
        hasTarget = $plan.hasTarget
        changed   = $changed
        restarted = $restarted
        localTime = $now.ToString('yyyy-MM-ddTHH:mm:sszzz')
        verdict   = $verdict
        timestamp = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        version   = '1.1'
    }
    return [ordered]@{ record = $record; exitCode = $code }
}

function Invoke-Main {
    param([switch]$Fix, [string]$TargetZone, [string]$FromZone, [string]$FallbackZone)
    try {
        if ($TargetZone -eq '') { $TargetZone = $BctzDefaultTarget }
        if ($FromZone -eq '') { $FromZone = $BctzDefaultFrom }
        Write-BctzStatus "Time zone $(if ($Fix) { 'fix' } else { 'check' }) starting: target $(Limit-BctzText $TargetZone 64), from $(Limit-BctzText $FromZone 160), fallback '$(Limit-BctzText $FallbackZone 64)'"
        $run = Invoke-BctzRun -Fix:$Fix -TargetZone $TargetZone -FromZone $FromZone -FallbackZone $FallbackZone
        $json = $run.record | ConvertTo-Json -Depth 4 -Compress
        Write-BctzStatus "Verdict: $($run.record.verdict) (exit $($run.exitCode))"
        Write-Output $json
        exit $run.exitCode
    } catch {
        Write-BctzStatus "Time zone error: $_" 'ERROR'
        Write-BctzStatus $_.ScriptStackTrace 'ERROR'
        exit 1
    }
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') {
    try { $bctzMode = Get-BctzMode -Action $Action -Fix $Fix -PinVersion $PinVersion }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    if ($bctzMode -eq 'none') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
    Invoke-Main -Fix:($bctzMode -eq 'fix') -TargetZone $TargetZone -FromZone $FromZone -FallbackZone $FallbackZone
}
