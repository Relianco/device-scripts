<#
.SYNOPSIS
    British Columbia permanent UTC-7 time zone package for the Relian deploy runner (NinjaOne script 374).
    Checks, and with Fix sets, British Columbia Standard Time (or Yukon Standard Time on unpatched builds).

.DESCRIPTION
    British Columbia is permanent UTC-7 from 2026-11-01, while Pacific Standard Time
    falls back to UTC-8 in winter. The British Columbia Standard Time zone ships in
    the 2026-09-22 preview / 2026-10-13 cumulative updates; unpatched builds use
    Yukon Standard Time (also permanent UTC-7, no DST since 2020) until they patch.

    By default this package is read-only. It checks the current time zone and whether
    British Columbia Standard Time is available in the local time zone database.
    It flags only Pacific Standard Time, or Yukon Standard Time once British Columbia
    Standard Time exists on the machine, so travellers on another time zone are left
    alone. It writes no registry value and no file in check mode.

    With -Fix true it switches a flagged machine to British Columbia Standard Time
    (when available) or Yukon Standard Time (when unpatched), then reads the active
    time zone back to verify the change.

    The runner passes DeploymentType, Action and PinVersion, then each
    PackageArguments pair as -Name value. Fix is the only one read, and it is a
    string: base64 of {"Fix":"true"} is eyJGaXgiOiJ0cnVlIn0=.
    Install, Update, Repair and Reinstall all run the check (and the fix when
    Fix is "true"). Uninstall changes nothing and exits 0.

    The result is one line of compact JSON, printed last on stdout, with a
    short "verdict". The package writes no RMM field: the caller reads stdout and
    the exit code. Exit 1 when a fix was attempted and the read-back does not match
    the target time zone, or when reading the time zone failed.

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
    [string]$Fix = ''
)

$ProgressPreference = 'SilentlyContinue'

$BctzBcId = 'British Columbia Standard Time'
$BctzYukonId = 'Yukon Standard Time'
$BctzPacificId = 'Pacific Standard Time'

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

# Pure: picks target zone and whether the current zone needs changing.
# Only Pacific Standard Time, or Yukon Standard Time when British Columbia Standard Time
# exists on the machine, is flagged for change. Any other zone (e.g. a traveller on
# Mountain or Eastern time) is left untouched.
function Get-BctzPlan {
    param([string]$CurrentId, [bool]$HasBritishColumbia, [bool]$HasYukon)
    $target = if ($HasBritishColumbia) { $BctzBcId } else { $BctzYukonId }
    $needsChange = ($CurrentId -eq $BctzPacificId) -or ($HasBritishColumbia -and ($CurrentId -eq $BctzYukonId))
    $targetAvailable = if ($target -eq $BctzBcId) { $HasBritishColumbia } else { $HasYukon }
    return [ordered]@{
        target          = $target
        needsChange     = $needsChange
        targetAvailable = $targetAvailable
    }
}

function Invoke-BctzRun {
    param([switch]$Fix)
    $mode = if ($Fix) { 'fix' } else { 'check' }
    $current = $null
    $available = @()
    try {
        $current = Get-BctzCurrentZone
        $available = @(Get-BctzAvailableZones)
    } catch {
        $err = Limit-BctzText "$_" 160
        $nowErr = Get-BctzNow
        $record = [ordered]@{
            mode               = $mode
            before             = $null
            after              = $null
            target             = $null
            hasBritishColumbia = $false
            changed            = $false
            localTime          = $nowErr.ToString('yyyy-MM-ddTHH:mm:sszzz')
            verdict            = "time zone read failed, not changed: $err"
            timestamp          = $nowErr.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            version            = '1.0'
        }
        return [ordered]@{ record = $record; exitCode = 1 }
    }

    $beforeId = [string]$current.Id
    $hasBc = @($available | Where-Object { $_.Id -eq $BctzBcId }).Count -gt 0
    $hasYukon = @($available | Where-Object { $_.Id -eq $BctzYukonId }).Count -gt 0
    $plan = Get-BctzPlan -CurrentId $beforeId -HasBritishColumbia $hasBc -HasYukon $hasYukon

    $afterId = $beforeId
    $changed = $false
    $code = 0
    $verdict = ''

    if (-not $plan.needsChange) {
        if ($beforeId -eq $plan.target) {
            $verdict = "compliant: $beforeId"
        } else {
            $verdict = "untouched non-Pacific zone: $beforeId"
        }
    } elseif (-not $plan.targetAvailable) {
        $code = 1
        $verdict = "target zone $($plan.target) is not available on this device"
    } elseif (-not $Fix) {
        $verdict = "wrong zone: $beforeId (want $($plan.target))"
    } else {
        $setError = $null
        try {
            Set-BctzZone -Id $plan.target
        } catch {
            $setError = Limit-BctzText "$_" 160
        }
        $afterZone = $null
        $readAfterError = $null
        try {
            $afterZone = Get-BctzCurrentZone
            $afterId = [string]$afterZone.Id
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
        } else {
            $code = 1
            $changed = ($afterId -ne $beforeId)
            $verdict = "fix incomplete: still on $afterId (wanted $($plan.target))"
        }
    }

    $now = Get-BctzNow
    $record = [ordered]@{
        mode               = $mode
        before             = $beforeId
        after              = $afterId
        target             = $plan.target
        hasBritishColumbia = $hasBc
        changed            = $changed
        localTime          = $now.ToString('yyyy-MM-ddTHH:mm:sszzz')
        verdict            = $verdict
        timestamp          = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        version            = '1.0'
    }
    return [ordered]@{ record = $record; exitCode = $code }
}

function Invoke-Main {
    param([switch]$Fix)
    try {
        Write-BctzStatus "BC time zone $(if ($Fix) { 'fix' } else { 'check' }) starting"
        $run = Invoke-BctzRun -Fix:$Fix
        $json = $run.record | ConvertTo-Json -Depth 4 -Compress
        Write-BctzStatus "Verdict: $($run.record.verdict) ($($json.Length) bytes)"
        Write-Output $json
        exit $run.exitCode
    } catch {
        Write-BctzStatus "BC time zone error: $_" 'ERROR'
        Write-BctzStatus $_.ScriptStackTrace 'ERROR'
        exit 1
    }
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') {
    try { $bctzMode = Get-BctzMode -Action $Action -Fix $Fix -PinVersion $PinVersion }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    if ($bctzMode -eq 'none') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
    Invoke-Main -Fix:($bctzMode -eq 'fix')
}
