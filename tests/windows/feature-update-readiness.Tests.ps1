$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/collectors/feature-update-readiness.ps1'

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

function New-Record {
    [ordered]@{
        os        = [ordered]@{ build = 22631; displayVersion = '23H2' }
        hw        = [ordered]@{ tpmPresent = $true; tpmVersion = '2.0'; freeGB = 120 }
        policy    = [ordered]@{ wu = $null; au = $null; mdm = $null; policyState = $null }
        appraiser = [ordered]@{ indicators = [ordered]@{ GE24H2 = [ordered]@{ UpgEx = 'Green'; RedReason = 'None'; GatedBlockId = 'None' } } }
        wuSearch  = [ordered]@{ featureOffered = $false; error = $null }
    }
}

# A 24H2 device is still checked for blockers; a pin to its own release blocks.
$r = New-Record; $r.os.build = 26100; $r.os.displayVersion = '24H2'
$r.appraiser.indicators['GE25H2'] = [ordered]@{ GatedBlockId = 'None'; RedReason = 'None' }
$r.policy.wu = [ordered]@{ TargetReleaseVersion = 1; TargetReleaseVersionInfo = '24H2' }
Assert-Same (Get-FurVerdict $r) 'pinned to 24H2 (GPO); not offered by WU' '24H2 pinned to 24H2'
$r.policy.wu.TargetReleaseVersionInfo = '25H2'
Assert-Same (Get-FurVerdict $r) 'not offered by WU' '24H2 pinned to 25H2'

# Nothing blocking, nothing offered.
Assert-Same (Get-FurVerdict (New-Record)) 'not offered by WU' 'clean device'

# Offered.
$r = New-Record; $r.wuSearch.featureOffered = $true
Assert-Same (Get-FurVerdict $r) 'ok/offered' 'offered'

# GPO pin to 23H2 blocks; pin to 24H2 does not.
$r = New-Record; $r.policy.wu = [ordered]@{ TargetReleaseVersion = 1; TargetReleaseVersionInfo = '23H2'; ProductVersion = 'Windows 11' }
Assert-Like (Get-FurVerdict $r) 'pinned to 23H2 (GPO)*' 'GPO pin'
$r.policy.wu.TargetReleaseVersionInfo = '24H2'
Assert-Same (Get-FurVerdict $r) 'not offered by WU' 'pin to 24H2'

# TargetReleaseVersion 0 is not a pin.
$r = New-Record; $r.policy.wu = [ordered]@{ TargetReleaseVersion = 0; TargetReleaseVersionInfo = '23H2' }
Assert-Same (Get-FurVerdict $r) 'not offered by WU' 'disabled pin'

# MDM pin.
$r = New-Record; $r.policy.mdm = [ordered]@{ TargetReleaseVersion = '23H2' }
Assert-Like (Get-FurVerdict $r) 'pinned to 23H2 (MDM)*' 'MDM pin'

# WSUS.
$r = New-Record; $r.policy.au = [ordered]@{ UseWUServer = 1 }; $r.policy.wu = [ordered]@{ WUServer = 'http://wsus:8530' }
Assert-Like (Get-FurVerdict $r) 'update source is WSUS (http://wsus:8530)*' 'WSUS'
$r.policy.wu['SetPolicyDrivenUpdateSourceForFeatureUpdates'] = 0
Assert-Same (Get-FurVerdict $r) 'not offered by WU' 'WSUS with feature updates from WU'

# Paused.
$r = New-Record; $r.policy.policyState = [ordered]@{ PausedFeatureStatus = 1 }
Assert-Like (Get-FurVerdict $r) 'feature updates paused*' 'paused'
$r = New-Record; $r.policy.wu = [ordered]@{ PauseFeatureUpdatesStartTime = '2025-01-01' }; $r.policy.policyState = [ordered]@{ PausedFeatureStatus = 0 }
Assert-Same (Get-FurVerdict $r) 'not offered by WU' 'expired pause start time'

# Feature update detection ignores cumulative updates that name a version.
Assert-Same (Test-FurFeatureUpdate 'Windows 11, version 25H2 [Upgrades]') $true 'feature by category'
Assert-Same (Test-FurFeatureUpdate 'Windows 11, version 24H2') $true 'feature by title'
Assert-Same (Test-FurFeatureUpdate 'Feature update to Windows 11, version 24H2 [Windows 11]') $true 'feature update title'
Assert-Same (Test-FurFeatureUpdate '2026-10 Cumulative Update for Windows 11, version 23H2 for x64-based Systems (KB5126653) [Security Updates/Windows 11]') $false 'cumulative 23H2'
Assert-Same (Test-FurFeatureUpdate 'Windows 11, Version 25H2 [Mises à niveau] {upgrade}') $true 'localized upgrade by category id'
Assert-Same (Test-FurFeatureUpdate 'Pilote AMD [Pilotes] {driver}') $false 'driver marker'
Assert-Same (Test-FurCumulative @('x', '2026-10 Cumulative Update for Windows 11, version 23H2 (KB5126653) [Security Updates]')) $true 'cumulative found'
Assert-Same (Test-FurCumulative @()) $false 'no cumulative'
Assert-Same (Test-FurCumulative @('Mise à jour cumulative 2026-10 pour Windows 11 (KB5126653) [Mises à jour de sécurité/Windows 11] {oscu}')) $true 'localized cumulative by category id'
Assert-Same (Test-FurCumulative @('AMD System Driver Update [Drivers] {driver}')) $false 'driver is not cumulative'
Assert-Same (Test-FurFeatureUpdate '2025-10 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5066835) [Security Updates]') $false 'cumulative 24H2'

# Safeguard hold, ids de-duplicated across targets.
$r = New-Record
$r.appraiser.indicators.GE24H2.GatedBlockId = '56318982'
$r.appraiser.indicators['GE25H2'] = [ordered]@{ GatedBlockId = '56318982,57575634'; RedReason = 'None' }
Assert-Like (Get-FurVerdict $r) 'safeguard hold 56318982,57575634*' 'safeguard'

# On 24H2, a stale 24H2 record is ignored; the 25H2 record decides.
$r = New-Record; $r.os.build = 26100; $r.os.displayVersion = '24H2'
$r.appraiser.indicators.GE24H2.GatedBlockId = '111'; $r.appraiser.indicators.GE24H2.RedReason = 'Old'
$r.appraiser.indicators['GE25H2'] = [ordered]@{ GatedBlockId = 'None'; RedReason = 'None' }
Assert-Same (Get-FurVerdict $r) 'not offered by WU' 'stale older record'
$r.appraiser.indicators.GE25H2.GatedBlockId = '222'
Assert-Same (Get-FurVerdict $r) 'safeguard hold 222; not offered by WU' 'newer record hold'

# Appraiser red reason and missing appraiser data.
$r = New-Record; $r.appraiser.indicators.GE24H2.RedReason = 'CpuFms'
Assert-Like (Get-FurVerdict $r) 'hardware ineligible (appraiser: CpuFms)*' 'red reason'
$r = New-Record; $r.appraiser.indicators = [ordered]@{ NI23H2 = [ordered]@{ UpgEx = 'Green' } }
Assert-Like (Get-FurVerdict $r) 'appraiser never evaluated 24H2/25H2*' 'no target data'

# Disabled appraiser task or DiagTrack is named, with or without target data.
$r = New-Record; $r.appraiser.indicators = [ordered]@{}
$r.appraiser['task'] = [ordered]@{ state = 'Disabled'; lastRun = '2023-11-27 08:48' }
$r.appraiser['diagTrack'] = 'Stopped/Disabled'
Assert-Same (Get-FurVerdict $r) 'appraiser never evaluated 24H2/25H2; appraiser stale: task disabled / DiagTrack disabled; not offered by WU' 'appraiser off'
$r = New-Record; $r.appraiser['task'] = [ordered]@{ state = 'Ready' }; $r.appraiser['diagTrack'] = 'Running/Automatic'
Assert-Same (Get-FurVerdict $r) 'not offered by WU' 'appraiser on'
$r = New-Record; $r.appraiser['task'] = [ordered]@{ state = 'Disabled' }
Assert-Same (Get-FurVerdict $r) 'appraiser stale: task disabled; not offered by WU' 'appraiser off with data'

# Telemetry off (policy or local) and an old evaluation both mark the appraiser stale.
$r = New-Record; $r.policy['dataCollection'] = [ordered]@{ AllowTelemetry = 0 }
Assert-Same (Get-FurVerdict $r) 'appraiser stale: telemetry off; not offered by WU' 'telemetry off policy'
$r = New-Record; $r.policy['dataCollection'] = [ordered]@{ AllowTelemetryLocal = 0 }
Assert-Same (Get-FurVerdict $r) 'appraiser stale: telemetry off; not offered by WU' 'telemetry off local'
$r = New-Record; $r.policy['dataCollection'] = [ordered]@{ AllowTelemetry = 1 }
Assert-Same (Get-FurVerdict $r) 'not offered by WU' 'telemetry basic'
$r = New-Record; $r.appraiser['lastEvaluated'] = '2023-11-27 17:08'; $r['timestamp'] = '2026-10-30T20:00:00Z'
Assert-Same (Get-FurVerdict $r) 'appraiser stale: last evaluated 2023-11-27; not offered by WU' 'old evaluation'
$r.appraiser['lastEvaluated'] = '2026-10-29 10:00'
Assert-Same (Get-FurVerdict $r) 'not offered by WU' 'fresh evaluation'

$source = [IO.File]::ReadAllText($scriptPath)

# Fix plan: enable the appraiser task when disabled, run it when its data is stale.
function New-FixRecord {
    $r = New-Record
    $r['timestamp'] = '2026-10-30T20:00:00Z'
    $r.appraiser['task'] = [ordered]@{ state = 'Ready'; lastRun = '2026-10-29 10:00' }
    $r.appraiser['diagTrack'] = 'Stopped/Disabled'
    $r.appraiser.indicators['GE25H2'] = [ordered]@{ GatedBlockId = 'None' }
    $r
}
Assert-Same ((Get-FurFixPlan (New-FixRecord)) -join ',') '' 'fresh and enabled: nothing, DiagTrack untouched'
$r = New-FixRecord; $r.appraiser.task.state = 'Disabled'; $r.appraiser.task.lastRun = '2023-11-23 12:27'
Assert-Same ((Get-FurFixPlan $r) -join ',') 'EnableAppraiserTask,RunAppraiser' 'disabled and old'
$r = New-FixRecord; $r.appraiser.task.state = 'Disabled'
Assert-Same ((Get-FurFixPlan $r) -join ',') 'EnableAppraiserTask' 'disabled but fresh'
$r = New-FixRecord; $r.appraiser.indicators = [ordered]@{ NI23H2 = [ordered]@{ GatedBlockId = 'None' } }
Assert-Same ((Get-FurFixPlan $r) -join ',') 'RunAppraiser' 'no record past 23H2'
$r = New-FixRecord; $r.appraiser.indicators['NI23H2'] = [ordered]@{ GatedBlockId = '47615939' }
Assert-Same ((Get-FurFixPlan $r) -join ',') 'RunAppraiser' 'stale hold'
$r = New-FixRecord; $r.appraiser.task.lastRun = '1999-11-30 00:00'
Assert-Same ((Get-FurFixPlan $r) -join ',') 'RunAppraiser' 'never ran'
$r = New-FixRecord; $r.appraiser.task.state = 'Running'; $r.appraiser.indicators = [ordered]@{}
Assert-Same ((Get-FurFixPlan $r) -join ',') '' 'already running: do not start again'
$r = New-FixRecord; $r.appraiser.task = [ordered]@{ state = 'missing' }
Assert-Same ((Get-FurFixPlan $r) -join ',') '' 'task missing: nothing'

# The verdict needs the timestamp, so it is set first.
$iTs = $source.IndexOf('$record.timestamp =', [StringComparison]::Ordinal)
$iVerdict = $source.IndexOf('$record.verdict =', [StringComparison]::Ordinal)
if ($iTs -lt 0 -or $iTs -gt $iVerdict) { Fail 'timestamp must be set before the verdict' }
# Tool hint directories: the first entry is parenthesized, or + swallows the array.
if ($source.IndexOf("@((`$env:SystemDrive + '\'),", [StringComparison]::Ordinal) -lt 0) { Fail 'tool hint directory list not parenthesized' }

# Fix mode never reboots, upgrades, or touches DiagTrack, policy or pins.
foreach ($bad in @('Set-Service', 'Start-Service', 'AllowTelemetry =', 'TargetReleaseVersion =')) {
    if ($source.IndexOf($bad, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Fail "source contains $bad" }
}

# Native argument quoting survives the MSVCRT parser.
Assert-Same (ConvertTo-FurNativeArg '{"a":"b"}') '{\"a\":\"b\"}' 'plain quotes'
Assert-Same (ConvertTo-FurNativeArg '{"p":"C:\\x\\"}') '{\"p\":\"C:\\x\\\\\"}' 'backslash before quote'
Assert-Same (ConvertTo-FurNativeArg 'none') 'none' 'no quotes'

# Out-of-servicing Pro releases, stale UBR, and a missing cumulative update.
$r = New-Record; $r.os['ubr'] = 6199; $r.os['edition'] = 'Professional'; $r.wuSearch['titles'] = @('AMD System Driver Update (23.19.0.6) [Drivers]'); $r.wuSearch['cumulativeOffered'] = $false
Assert-Same (Get-FurVerdict $r) '23H2 out of servicing (UBR 6199 is the last cumulative update); no cumulative update offered; not offered by WU' 'pro 23H2 final'
$r = New-Record; $r.os.build = 22621; $r.os.displayVersion = '22H2'; $r.os['ubr'] = 4000; $r.os['edition'] = 'Professional'
$r.appraiser.indicators = [ordered]@{ NI23H2 = [ordered]@{ GatedBlockId = '47615939'; GatedBlockReason = 'Other' } }
$r.wuSearch['titles'] = @(); $r.wuSearch['cumulativeOffered'] = $true
Assert-Same (Get-FurVerdict $r) 'appraiser never evaluated 24H2/25H2; UBR 4000 behind last cumulative update 4317; not offered by WU' '22H2 behind, older hold ignored'
$r = New-Record; $r.os['ubr'] = 6199; $r.os['edition'] = 'Enterprise'
Assert-Same (Get-FurVerdict $r) 'not offered by WU' 'enterprise not judged'

# Appraiser last evaluation date.
Assert-Same (Get-FurLastEvaluated ([ordered]@{ NI22H2 = [ordered]@{ TimestampEpochString = '1699994981' }; NI23H2 = [ordered]@{ TimestampEpochString = '1701104921' }; UNV = [ordered]@{} })) '2023-11-27 17:08' 'last evaluated'
Assert-Same (Get-FurLastEvaluated ([ordered]@{})) $null 'never evaluated'

# Disk and TPM.
$r = New-Record; $r.hw.freeGB = 8.5
Assert-Like (Get-FurVerdict $r) 'disk space (8.5 GB free)*' 'low disk'
$r = New-Record; $r.appraiser.indicators.GE24H2['SystemDriveTooFull'] = 1
Assert-Like (Get-FurVerdict $r) 'disk space (appraiser)*' 'appraiser disk'
$r = New-Record; $r.hw.tpmVersion = '1.2'
Assert-Like (Get-FurVerdict $r) 'hardware ineligible (TPM 1.2)*' 'tpm 1.2'

# Search failure, and several reasons joined in order.
$r = New-Record; $r.wuSearch.error = 'timeout after 150 s'
Assert-Same (Get-FurVerdict $r) 'WU search failed (timeout after 150 s)' 'search failed'
$r = New-Record; $r.policy.au = [ordered]@{ UseWUServer = 1 }; $r.appraiser.indicators.GE24H2.GatedBlockId = '1'
Assert-Same (Get-FurVerdict $r) 'update source is WSUS (no server set); safeguard hold 1; not offered by WU' 'joined'

# JSON stays under the cap and says what it dropped.
$r = New-Record
$r['setup'] = [ordered]@{ btExists = $true; setupact = @('x' * 3000); setuperr = @('y' * 3000) }
$r['verdict'] = 'v'
$json = ConvertTo-FurJson $r 2000
if ($json.Length -gt 2000) { Fail "json length $($json.Length) over cap" }
$parsed = $json | ConvertFrom-Json
Assert-Same ($parsed.trimmed -join ',') 'setup.setupact,setup.setuperr' 'trimmed list'
Assert-Same $parsed.setup.btExists $true 'kept btExists'
$small = ConvertTo-FurJson (New-Record) 9500
Assert-Same (($small | ConvertFrom-Json).PSObject.Properties.Name -contains 'trimmed') $false 'no trim when small'
$tiny = ConvertTo-FurJson ([ordered]@{ verdict = 'v'; timestamp = 't'; big = ('z' * 500) }) 100
Assert-Same (($tiny | ConvertFrom-Json).error) 'result too large' 'fallback when nothing to drop'

# Event summary groups by id, code and title.
$events = @(
    [pscustomobject]@{ Id = 20; TimeCreated = [datetime]'2026-10-01'; Message = 'Installation Failure: Windows failed to install the following update with error 0x800F0922: Feature update to Windows 11, version 24H2.' },
    [pscustomobject]@{ Id = 20; TimeCreated = [datetime]'2026-10-05'; Message = 'Installation Failure: Windows failed to install the following update with error 0x800F0922: Feature update to Windows 11, version 24H2.' },
    [pscustomobject]@{ Id = 31; TimeCreated = [datetime]'2026-10-03'; Message = 'Windows Update failed to download an update.' }
)
$s = Get-FurEventSummary $events
Assert-Same $s.count 3 'event count'
Assert-Same $s.top[0].n 2 'top group size'
Assert-Same $s.top[0].code '0x800f0922' 'top code'
Assert-Same $s.top[0].title 'Feature update to Windows 11, version 24H2' 'title after last colon'
Assert-Same $s.lastError.time '2026-10-05' 'last error date'
Assert-Same (Get-FurEventSummary @()).count 0 'empty events'

# Read-only: the collector must not write the registry or start setup.
$source = [IO.File]::ReadAllText($scriptPath)
foreach ($bad in @('Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'reg.exe', 'reg add', 'setup.exe', '.Install(', '.Download(', 'Restart-Computer')) {
    if ($source.IndexOf($bad, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Fail "source contains $bad" }
}

Write-Output 'feature-update-readiness tests passed'
exit 0
