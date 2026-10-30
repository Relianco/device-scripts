<#
.SYNOPSIS
    Feature update readiness collector for Relian device inventory.
    Says why Windows Update has not moved a device to the next feature update.

.DESCRIPTION
    By default it is read-only. It reads the OS version, Windows Update policy (GPO, MDM and
    the effective policy state), the compatibility appraiser's upgrade
    indicators (safeguard holds), TPM, Secure Boot, free disk space, a Windows
    Update Agent search for updates that are not installed, recent Windows
    Update client errors, and logs from earlier setup attempts. It writes no
    registry value, changes no policy, and starts no upgrade.

    With -Fix it repairs only what keeps the compatibility appraiser from
    running: it enables the "Microsoft Compatibility Appraiser" task and,
    when the appraiser data is
    stale, starts that task without waiting (it runs 5 to 30 minutes; run the
    check again later to read the result). It never reboots, never starts the
    upgrade, and never touches DiagTrack, update policy, pins or telemetry
    policy. Each
    step runs only when needed, so a second run changes nothing.

    The loader passes -Fix through its ParametersBase64 parameter:
    base64 of {"Fix":true} is eyJGaXgiOnRydWV9.

    The result is one line of compact JSON, printed last on stdout, with a
    short "verdict". The JSON also goes to the NinjaOne device custom field
    relianFeatureUpdate when the NinjaOne agent is present.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM
    Timeout: the Windows Update search stops after 150 seconds
    No external module dependencies
#>

param([switch]$Fix)

$ProgressPreference = "SilentlyContinue"

# NinjaOne field names are alphanumeric only, so the loader's relian_<name> write cannot land.
$FurFieldName = "relianFeatureUpdate"
# ponytail: NinjaOne text fields hold about 10,000 characters; trim to stay under.
$FurMaxJson = 9500
$FurSearchSeconds = 150
# Build -> UBR of the last Home/Pro cumulative update after end of servicing:
# 22H2 ended 2024-10 at 22621.4317, 23H2 ended 2025-11 at 22631.6199.
$FurFinalUbr = @{ 22621 = 4317; 22631 = 6199 }

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Level] $timestamp - $Message"
}

function Limit-Text {
    param([string]$Text, [int]$Max = 200)
    if ($null -eq $Text) { return $null }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + "..." }
    return $t
}

# Values of one registry key as an ordered hashtable. Missing key = $null.
function Get-RegValues {
    param([string]$Path, [string[]]$Only)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $out = [ordered]@{}
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        foreach ($name in $key.GetValueNames()) {
            if ($Only -and ($Only -notcontains $name)) { continue }
            $v = $key.GetValue($name)
            if ($v -is [byte[]]) { continue }
            if ($v -is [string[]]) { $v = $v -join ',' }
            if ($v -is [string]) { $v = Limit-Text $v 200 }
            $out[$(if ($name) { $name } else { '(default)' })] = $v
        }
    } catch { return @{ error = (Limit-Text "$_" 120) } }
    return $out
}

function Test-Has {
    param($Map, [string]$Name)
    return ($null -ne $Map -and $Map.Contains($Name) -and $null -ne $Map[$Name] -and "$($Map[$Name])" -ne '')
}

# Pure: turns the collected record into a list of reasons, most decisive first.
function Get-FurVerdict {
    param($Record)
    $reasons = New-Object System.Collections.Generic.List[string]
    # No early exit for 24H2 and later: a 24H2 device can be blocked from 25H2 too.
    $current = ''
    if ($Record.os -and $Record.os.Contains('displayVersion')) { $current = "$($Record.os.displayVersion)" }

    $hw = $Record.hw
    if ($hw) {
        if ($hw.tpmPresent -eq $false) { $reasons.Add("hardware ineligible (no TPM)") }
        elseif ($hw.tpmVersion -and "$($hw.tpmVersion)" -notmatch '^2') { $reasons.Add("hardware ineligible (TPM $($hw.tpmVersion))") }
        if ($null -ne $hw.freeGB -and [double]$hw.freeGB -lt 20) { $reasons.Add("disk space ($($hw.freeGB) GB free)") }
    }

    $wu = $null; $au = $null; $mdm = $null; $state = $null
    if ($Record.policy) { $wu = $Record.policy.wu; $au = $Record.policy.au; $mdm = $Record.policy.mdm; $state = $Record.policy.policyState }

    $pin = $null
    if ((Test-Has $wu 'TargetReleaseVersion') -and [int]$wu.TargetReleaseVersion -eq 1 -and (Test-Has $wu 'TargetReleaseVersionInfo')) {
        $pin = "$($wu.TargetReleaseVersionInfo) (GPO)"
    } elseif (Test-Has $mdm 'TargetReleaseVersion') {
        $pin = "$($mdm.TargetReleaseVersion) (MDM)"
    }
    # A pin blocks unless it names a release newer than the installed one ("23H2" -lt "24H2").
    if ($pin -and -not ($current -and ($pin.Split(' ')[0] -gt $current))) { $reasons.Add("pinned to $pin") }

    # WSUS is a source, not a block: it may approve the upgrade, and scan-source
    # policy (0 = Windows Update) can send feature updates to WU anyway.
    if ((Test-Has $au 'UseWUServer') -and [int]$au.UseWUServer -eq 1) {
        $featureFromWu = (Test-Has $wu 'SetPolicyDrivenUpdateSourceForFeatureUpdates') -and [int]$wu.SetPolicyDrivenUpdateSourceForFeatureUpdates -eq 0
        if (-not $featureFromWu) {
            $server = if (Test-Has $wu 'WUServer') { $wu.WUServer } else { 'no server set' }
            $reasons.Add("update source is WSUS ($server)")
        }
    }
    if ((Test-Has $wu 'DoNotConnectToWindowsUpdateInternetLocations') -and [int]$wu.DoNotConnectToWindowsUpdateInternetLocations -eq 1) {
        $reasons.Add("WU internet locations disabled by policy")
    }
    # PausedFeatureStatus is the effective state; a leftover PauseFeatureUpdatesStartTime outlives the pause.
    if ((Test-Has $state 'PausedFeatureStatus') -and [int]$state.PausedFeatureStatus -eq 1) {
        $reasons.Add("feature updates paused")
    }

    $ind = $null
    if ($Record.appraiser) { $ind = $Record.appraiser.indicators }
    $targets = @()
    # Only records for releases newer than the installed one: an older record's
    # GatedBlockId or RedReason does not apply to the next upgrade.
    if ($ind) {
        # The goal is 24H2 or later, so a 23H2 record never decides, even on 22H2.
        $floor = if ($current -match '^\d\dH\d$' -and $current -gt '23H2') { $current } else { '23H2' }
        $targets = @($ind.Keys | Where-Object { $_ -match '(\d\dH\d)$' -and $Matches[1] -gt $floor } | Sort-Object)
    }
    # Staleness comes from the evaluation itself: no record past 23H2, or the
    # newest evaluation over 30 days old. Disabled task, DiagTrack or telemetry
    # are listed as likely causes only then; DiagTrack just uploads results.
    $a = $Record.appraiser
    $taskOff = $false; $expOff = $false; $diagOff = $false; $telOff = $false
    if ($a) {
        $taskOff = $a.Contains('task') -and $a.task -and $a.task.Contains('state') -and "$($a.task.state)" -eq 'Disabled'
        $expOff = "$(Get-FurExpTaskState $a)" -eq 'Disabled'
        $diagOff = $a.Contains('diagTrack') -and "$($a.diagTrack)" -match 'Disabled'
    }
    $dc = $null
    if ($Record.policy -and $Record.policy.Contains('dataCollection')) { $dc = $Record.policy.dataCollection }
    if ($dc) { foreach ($k in @('AllowTelemetry', 'AllowTelemetryLocal')) { if ((Test-Has $dc $k) -and [int]$dc[$k] -eq 0) { $telOff = $true } } }
    $oldEval = $null
    if ($a -and $a.Contains('lastEvaluated') -and $a.lastEvaluated -and $Record.Contains('timestamp')) {
        if (([datetime]$Record.timestamp - [datetime]$a.lastEvaluated).TotalDays -gt 30) { $oldEval = ([datetime]$a.lastEvaluated).ToString('yyyy-MM-dd') }
    }
    if ($targets.Count -eq 0) {
        $next = if ($floor -lt '24H2') { '24H2/25H2' } else { "a release after $floor" }
        $reasons.Add("appraiser never evaluated $next")
    }
    if ($targets.Count -eq 0 -or $oldEval) {
        $why = @()
        if ($taskOff) { $why += 'task disabled' }
        if ($expOff) { $why += 'Exp task disabled' }
        if ($diagOff) { $why += 'DiagTrack disabled' }
        if ($telOff) { $why += 'telemetry off' }
        if ($oldEval) { $why += "last evaluated $oldEval" }
        if ($why.Count -gt 0) { $reasons.Add("appraiser stale: " + ($why -join ' / ')) }
    } else {
        if ($taskOff) { $reasons.Add("appraiser task disabled") }
        if ($expOff) { $reasons.Add("appraiser Exp task disabled") }
        if ($telOff) { $reasons.Add("telemetry off") }
    }
    if ($targets.Count -gt 0) {
        $holds = New-Object System.Collections.Generic.List[string]
        foreach ($t in $targets) {
            $i = $ind[$t]
            if ((Test-Has $i 'GatedBlockId') -and "$($i.GatedBlockId)" -notmatch '^(None|0)$') {
                foreach ($id in ("$($i.GatedBlockId)" -split '[,; ]+' | Where-Object { $_ })) {
                    if (-not $holds.Contains($id)) { $holds.Add($id) }
                }
            }
        }
        if ($holds.Count -gt 0) { $reasons.Add("safeguard hold $($holds -join ',')") }
        $red = @($targets | ForEach-Object { $ind[$_] } | Where-Object { (Test-Has $_ 'RedReason') -and "$($_.RedReason)" -ne 'None' } | ForEach-Object { "$($_.RedReason)" } | Select-Object -Unique)
        if ($red.Count -gt 0) { $reasons.Add("hardware ineligible (appraiser: $($red -join ','))") }
        $full = @($targets | ForEach-Object { $ind[$_] } | Where-Object { (Test-Has $_ 'SystemDriveTooFull') -and [int]$_.SystemDriveTooFull -eq 1 })
        if ($full.Count -gt 0 -and -not ($reasons | Where-Object { $_ -like 'disk space*' })) { $reasons.Add("disk space (appraiser)") }
    }

    # Last cumulative update for Home/Pro on releases past end of servicing.
    # Enterprise and Education run a year longer and are not judged here.
    $os = $Record.os
    if ($os -and $os.Contains('build') -and $os.Contains('ubr') -and $null -ne $os.ubr -and "$($os.edition)" -match '^(Professional|Core)') {
        $b = [int]$os.build
        if ($FurFinalUbr.Contains($b)) {
            $final = $FurFinalUbr[$b]
            if ([int]$os.ubr -ge $final) { $reasons.Add("$current out of servicing (UBR $($os.ubr) is the last cumulative update)") }
            else { $reasons.Add("UBR $($os.ubr) behind last cumulative update $final") }
        }
    }

    $search = $Record.wuSearch
    # cumulativeOffered is computed from the full search result; titles is truncated.
    if ($search -and -not $search.error -and $search.Contains('cumulativeOffered') -and -not $search.cumulativeOffered) {
        $reasons.Add("no cumulative update offered")
    }
    if ($search) {
        if ($search.featureOffered) { $reasons.Add("ok/offered") }
        elseif ($search.error) { $reasons.Add("WU search failed ($($search.error))") }
        else { $reasons.Add("not offered by WU") }
    }
    return ($reasons -join '; ')
}

# Pure: true for a feature update offer, "Title [Category/Category]" as the search
# records it. Cumulative updates also name "Windows 11, version 23H2", so the title
# alone is not enough: the Upgrades category, or a title that starts as an upgrade.
function Test-FurFeatureUpdate {
    param([string]$Entry)
    # "{upgrade}" marks the language-independent Upgrades category ID; names and titles are localized.
    if ($Entry -match '\{upgrade\}\s*$') { return $true }
    if ($Entry -match '\[[^\]]*\bUpgrades\b[^\]]*\]\s*$') { return $true }
    return ($Entry -match '^(Feature update to Windows|Windows 1[01], version \d\dH\d\s*(\[|$))')
}

# Pure: newest appraiser evaluation across indicator records, as a UTC date.
function Get-FurLastEvaluated {
    param($Indicators)
    $max = 0
    if ($Indicators) {
        foreach ($k in @($Indicators.Keys)) {
            $v = $Indicators[$k]
            if ($v -and $v.Contains('TimestampEpochString') -and "$($v.TimestampEpochString)" -match '^\d+$') {
                $max = [math]::Max($max, [long]$v.TimestampEpochString)
            }
        }
    }
    if ($max -eq 0) { return $null }
    return ([DateTimeOffset]::FromUnixTimeSeconds($max)).UtcDateTime.ToString('yyyy-MM-dd HH:mm')
}

# Pure: true when any search entry is a Windows cumulative update.
function Test-FurCumulative {
    param($Entries)
    return [bool](@($Entries | Where-Object { "$_" -match '\{oscu\}\s*$|Cumulative Update for Windows' }).Count)
}

# Pure: JSON no longer than $Max. Drops the bulkiest optional parts first.
function ConvertTo-FurJson {
    param($Record, [int]$Max = $FurMaxJson)
    $json = $Record | ConvertTo-Json -Depth 6 -Compress
    $drops = @(
        @('setup', 'setupact'), @('setup', 'setuperr'), @('setup', 'setupDiag'),
        @('policy', 'policyState'), @('events', 'top'), @('wuSearch', 'titles'),
        @('policy', 'mdm'), @('appraiser', 'indicators')
    )
    foreach ($d in $drops) {
        if ($json.Length -le $Max) { break }
        $parent = $Record[$d[0]]
        if ($parent -and $parent.Contains($d[1])) {
            $parent.Remove($d[1])
            if (-not $Record.Contains('trimmed')) { $Record['trimmed'] = @() }
            $Record['trimmed'] += "$($d[0]).$($d[1])"
            $json = $Record | ConvertTo-Json -Depth 6 -Compress
        }
    }
    if ($json.Length -gt $Max) {
        $json = (@{ verdict = $Record.verdict; error = "result too large"; timestamp = $Record.timestamp } | ConvertTo-Json -Compress)
    }
    return $json
}

# Pure: groups Windows Update client events by id, code and title.
function Get-FurEventSummary {
    param($Events)
    $rows = @()
    foreach ($e in @($Events)) {
        $msg = "$($e.Message)"
        $code = if ($msg -match '0x[0-9A-Fa-f]{8}') { $Matches[0].ToLower() } else { '' }
        $title = if ($msg -match '.*:\s*(.+?)\.?\s*$') { Limit-Text $Matches[1] 90 } else { Limit-Text $msg 90 }
        $rows += [pscustomobject]@{ id = [int]$e.Id; code = $code; title = $title; time = $e.TimeCreated }
    }
    $top = @($rows | Group-Object id, code, title | Sort-Object Count -Descending | Select-Object -First 6 | ForEach-Object {
        $f = $_.Group[0]
        [ordered]@{ id = $f.id; code = $f.code; title = $f.title; n = $_.Count }
    })
    $last = $rows | Where-Object { $_.id -ne 19 } | Sort-Object time -Descending | Select-Object -First 1
    $lastOut = $null
    if ($last) { $lastOut = [ordered]@{ time = ([datetime]$last.time).ToString('yyyy-MM-dd'); id = $last.id; code = $last.code; title = $last.title } }
    return [ordered]@{ count = $rows.Count; top = $top; lastError = $lastOut }
}

function Get-TailLines {
    param([string]$Path, [int]$Lines = 12, [string]$Pattern)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $tail = Get-Content -LiteralPath $Path -Tail 4000 -ErrorAction Stop
        if ($Pattern) { $tail = @($tail | Where-Object { $_ -match $Pattern }) }
        return @($tail | Select-Object -Last $Lines | ForEach-Object { Limit-Text $_ 160 })
    } catch { return @("read failed: $(Limit-Text "$_" 80)") }
}

function Get-OsInfo {
    $cv = Get-RegValues 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Only @('CurrentBuild', 'UBR', 'DisplayVersion', 'EditionID', 'ProductName', 'InstallationType')
    return [ordered]@{
        build          = [int]$cv.CurrentBuild
        ubr            = $cv.UBR
        displayVersion = $cv.DisplayVersion
        edition        = $cv.EditionID
        installType    = $cv.InstallationType
    }
}

function Get-PolicyInfo {
    $wuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    return [ordered]@{
        wu             = Get-RegValues $wuKey
        au             = Get-RegValues "$wuKey\AU"
        policyState    = Get-RegValues 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState'
        mdm            = Get-RegValues 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
        dataCollection = Get-FurDataCollection
        uxSettings     = Get-RegValues 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Only @('IsContinuousInnovationOptedIn', 'PauseFeatureUpdatesEndTime', 'PauseUpdatesExpiryTime')
    }
}

# AllowTelemetry from Group Policy, and the local (non-policy) setting as AllowTelemetryLocal.
function Get-FurDataCollection {
    $out = [ordered]@{}
    $gpo = Get-RegValues 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Only @('AllowTelemetry', 'DisableOneSettingsDownloads')
    if ($gpo) { foreach ($k in $gpo.Keys) { $out[$k] = $gpo[$k] } }
    $local = Get-RegValues 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Only @('AllowTelemetry', 'MaxTelemetryAllowed')
    if ($local) {
        if ($local.Contains('AllowTelemetry')) { $out['AllowTelemetryLocal'] = $local['AllowTelemetry'] }
        if ($local.Contains('MaxTelemetryAllowed')) { $out['MaxTelemetryAllowed'] = $local['MaxTelemetryAllowed'] }
    }
    return $out
}

function Get-AppraiserInfo {
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\TargetVersionUpgradeExperienceIndicators'
    $keep = @('UpgEx', 'UpgExU', 'RedReason', 'GatedBlockId', 'GatedBlockReason', 'GatedFeature', 'SdbEntries',
        'DestBuildNum', 'SystemDriveTooFull', 'Timestamp', 'TimestampEpochString', 'AppraiserVersion', 'Version', 'UpgExUTimestamp')
    $ind = [ordered]@{}
    if (Test-Path -LiteralPath $root) {
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $ind[$k.PSChildName] = Get-RegValues $k.PSPath -Only $keep
        }
    }
    # The main appraiser task, plus its siblings (Exp, ProgramDataUpdater and so on).
    $task = $null
    $siblings = @()
    try {
        $all = @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -ErrorAction Stop)
        foreach ($t in $all) {
            $ti = $t | Get-ScheduledTaskInfo
            $row = [ordered]@{ name = $t.TaskName; state = "$($t.State)"; lastRun = $ti.LastRunTime.ToString('yyyy-MM-dd HH:mm'); lastResult = ('0x{0:x}' -f $ti.LastTaskResult) }
            if ($t.TaskName -eq 'Microsoft Compatibility Appraiser') { $task = $row } else { $siblings += $row }
        }
        if (-not $task) { $task = [ordered]@{ state = 'missing' } }
    } catch { $task = [ordered]@{ error = (Limit-Text "$_" 100) } }
    $diag = $null
    try { $diag = "$((Get-Service DiagTrack -ErrorAction Stop).Status)/$((Get-Service DiagTrack).StartType)" } catch { $diag = 'missing' }
    return [ordered]@{ task = $task; otherTasks = $siblings; diagTrack = $diag; lastEvaluated = (Get-FurLastEvaluated $ind); indicators = $ind }
}

function Get-HardwareInfo {
    $hw = [ordered]@{}
    try {
        $tpm = Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
        if ($tpm) {
            $hw.tpmPresent = $true
            $hw.tpmVersion = ("$($tpm.SpecVersion)" -split ',')[0].Trim()
            $hw.tpmReady = [bool]($tpm.IsEnabled_InitialValue -and $tpm.IsActivated_InitialValue)
        } else { $hw.tpmPresent = $false }
    } catch { $hw.tpmPresent = $null; $hw.tpmError = Limit-Text "$_" 80 }
    try { $hw.secureBoot = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) } catch { $hw.secureBoot = $null }
    try { $hw.cpu = Limit-Text ((Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name) 80 } catch { }
    try { $hw.ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB, 1) } catch { }
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction Stop
        $hw.freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
        $hw.sizeGB = [math]::Round($disk.Size / 1GB, 1)
    } catch { }
    return $hw
}

# Runs the WUA search in a job so a hung search cannot outlive the time budget.
function Invoke-WuSearch {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $job = Start-Job -ScriptBlock {
        $res = @{ titles = @(); error = $null; serverSelection = $null }
        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $res.serverSelection = $searcher.ServerSelection
            foreach ($criteria in @("IsInstalled=0 and IsHidden=0", "IsInstalled=0 and DeploymentAction='OptionalInstallation'")) {
                $found = $searcher.Search($criteria)
                foreach ($u in $found.Updates) {
                    $cats = @($u.Categories | ForEach-Object { $_.Name }) -join '/'
                    $ids = @($u.Categories | ForEach-Object { "$($_.CategoryID)".ToUpperInvariant() })
                    $mark = ''
                    if ($ids -contains '3689BDC8-B205-4AF4-8D4B-A63924C5E9D5') { $mark = ' {upgrade}' }
                    elseif ($ids -contains 'EBFC1FC5-71A4-4F7B-9ACA-3B9A503104A0') { $mark = ' {driver}' }
                    # Windows 11 or 10 product with Security Updates or Update Rollups classification,
                    # minus .NET, marks an OS cumulative update in any display language.
                    elseif ((($ids -contains '72E7624A-5B00-45D2-B92F-E561C0D2F7B7') -or ($ids -contains 'A3C2375D-0C8A-42F9-BCE0-28333E198407')) -and
                        (($ids -contains '0FA1201D-4330-4FA8-8AE9-B877473B6441') -or ($ids -contains '28BC880E-0592-4CBF-8F95-C79B17911D5F')) -and
                        "$($u.Title)" -notmatch '\.NET') { $mark = ' {oscu}' }
                    $res.titles += "$($u.Title) [$cats]$mark"
                }
            }
        } catch { $res.error = "$($_.Exception.Message)" }
        $res
    }
    $out = [ordered]@{}
    if (Wait-Job -Job $job -Timeout $FurSearchSeconds) {
        $r = Receive-Job -Job $job
        $titles = @($r.titles | Select-Object -Unique)
        $out.count = $titles.Count
        $out.serverSelection = $r.serverSelection
        if ($r.error) { $out.error = Limit-Text $r.error 120 }
        $feature = @($titles | Where-Object { Test-FurFeatureUpdate $_ })
        $out.featureOffered = ($feature.Count -gt 0)
        $out.cumulativeOffered = Test-FurCumulative $titles
        $out.featureTitles = @($feature | Select-Object -First 3 | ForEach-Object { Limit-Text $_ 120 })
        $out.titles = @($titles | Select-Object -First 10 | ForEach-Object { Limit-Text $_ 100 })
        $out.drivers = @($titles | Where-Object { $_ -match '\{driver\}\s*$|\[[^\]]*Drivers[^\]]*\]\s*$' } | Select-Object -First 8 | ForEach-Object { Limit-Text $_ 100 })
    } else {
        $out.error = "timeout after $FurSearchSeconds s"
        $out.featureOffered = $false
        Stop-Job -Job $job -ErrorAction SilentlyContinue
    }
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    $out.searchSec = [math]::Round($sw.Elapsed.TotalSeconds, 0)
    return $out
}

function Get-SetupInfo {
    $bt = Join-Path $env:SystemDrive '$WINDOWS.~BT'
    $panther = Join-Path $bt 'Sources\Panther'
    if (-not (Test-Path -LiteralPath $panther)) { $panther = Join-Path $env:SystemRoot 'Panther' }
    $info = [ordered]@{
        btExists = (Test-Path -LiteralPath $bt)
        panther  = $panther
        mosetup  = Get-RegValues 'HKLM:\SYSTEM\Setup\MoSetup\Volatile'
        setuperr = Get-TailLines (Join-Path $panther 'setuperr.log') 8
        setupact = Get-TailLines (Join-Path $panther 'setupact.log') 6 'Error|0x[0-9A-Fa-f]{8}|Result'
    }
    $sd = Get-RegValues 'HKLM:\SYSTEM\Setup\SetupDiag\Results' -Only @('FailureData', 'FailureDetails', 'ProfileName', 'Remediation', 'LastSetupOperation', 'DateTime')
    if ($sd) { $info.setupDiag = $sd }
    return $info
}

# Pure: quotes a value for a native command line under Windows PowerShell 5.1,
# which passes embedded double quotes through unescaped. Backslashes before a
# quote are doubled, then the quote is escaped (MSVCRT argument rules).
function ConvertTo-FurNativeArg {
    param([string]$Value)
    return [regex]::Replace($Value, '(\\*)"', { param($m) $m.Groups[1].Value + $m.Groups[1].Value + '\"' })
}

# The loader runs collectors in a child powershell.exe. Ninja-Property-Set
# there hands the value to the agent CLI as a native argument, and 5.1 strips
# the JSON's quotes. So write through the CLI's stdin and read it back.
function Set-FurField {
    param([string]$Value)
    $cli = Join-Path $env:ProgramData 'NinjaRMMAgent\ninjarmm-cli.exe'
    if (Test-Path -LiteralPath $cli) {
        try {
            $null = $Value | & $cli set --stdin $FurFieldName 2>&1
            $back = (& $cli get $FurFieldName 2>$null) -join "`n"
            if ($back.Trim() -eq $Value) { return $true }
        } catch { }
    }
    if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) {
        try { Ninja-Property-Set $FurFieldName (ConvertTo-FurNativeArg $Value); return $true } catch { }
    }
    return $false
}

# Hints at which tool turned the appraiser off. VDOT (Virtual Desktop
# Optimization Tool) disables the appraiser task and DiagTrack, unpacks into
# C:\Optimize and keeps its own event log. O&O ShutUp10 leaves OOSU10.exe or
# a .cfg behind. Existence and dates only.
function Get-FurToolHints {
    $h = [ordered]@{}
    $opt = Join-Path $env:SystemDrive 'Optimize'
    if (Test-Path -LiteralPath $opt) { $h.vdotFolder = (Get-Item -LiteralPath $opt).LastWriteTime.ToString('yyyy-MM-dd') }
    try {
        $log = Get-WinEvent -ListLog 'Virtual Desktop Optimization' -ErrorAction Stop
        $h.vdotLog = [ordered]@{ records = $log.RecordCount; lastWrite = $(if ($log.LastWriteTime) { $log.LastWriteTime.ToString('yyyy-MM-dd') } else { $null }) }
        $first = Get-WinEvent -LogName 'Virtual Desktop Optimization' -MaxEvents 1 -Oldest -ErrorAction SilentlyContinue
        if ($first) { $h.vdotLog.firstEvent = $first.TimeCreated.ToString('yyyy-MM-dd') }
    } catch { }
    $oo = @()
    foreach ($dir in @(($env:SystemDrive + '\'), $env:ProgramData, (Join-Path $env:SystemRoot 'Temp'), (Join-Path $env:SystemDrive 'Relian'))) {
        if (-not $dir) { continue }
        foreach ($name in @('OOSU10.exe', 'ooshutup10.cfg')) {
            $f = Join-Path $dir $name
            if (Test-Path -LiteralPath $f) { $oo += "$f $((Get-Item -LiteralPath $f).LastWriteTime.ToString('yyyy-MM-dd'))" }
        }
    }
    if ($oo.Count -gt 0) { $h.ooShutUp = $oo }
    return $h
}

# Pure: state of the "Microsoft Compatibility Appraiser Exp" task, which tools
# such as VDOT disable together with the main appraiser task. $null if absent.
function Get-FurExpTaskState {
    param($Appraiser)
    if (-not $Appraiser -or -not $Appraiser.Contains('otherTasks')) { return $null }
    $row = @($Appraiser.otherTasks | Where-Object { $_ -and "$($_.name)" -eq 'Microsoft Compatibility Appraiser Exp' }) | Select-Object -First 1
    if ($row) { return "$($row.state)" }
    return $null
}

# Pure: the repairs a record calls for, in order. Empty when nothing is needed.
function Get-FurFixPlan {
    param($Record)
    $plan = New-Object System.Collections.Generic.List[string]
    $a = $Record.appraiser
    if (-not $a) { return @() }
    # DiagTrack is reported only: the appraiser writes its results locally
    # without it; DiagTrack just uploads them.
    $task = if ($a.Contains('task')) { $a.task } else { $null }
    $state = if ($task -and $task.Contains('state')) { "$($task.state)" } else { '' }
    if ($state -eq 'Disabled') { $plan.Add('EnableAppraiserTask') }
    if ($state -eq 'Running' -or $state -eq 'missing' -or $state -eq '') { return @($plan) }

    # Stale: the newest evaluation is missing or over 30 days old (a task run is
    # no proof the scan succeeded), or no record exists for a release after 23H2.
    # A hold alone is not staleness: a fresh hold is real, and an old one shows
    # up as an old evaluation.
    $stale = $false
    $now = if ($Record.Contains('timestamp')) { [datetime]$Record.timestamp } else { Get-Date }
    if ($a.Contains('lastEvaluated') -and $a.lastEvaluated) {
        if (($now - [datetime]$a.lastEvaluated).TotalDays -gt 30) { $stale = $true }
    } else { $stale = $true }
    $ind = if ($a.Contains('indicators')) { $a.indicators } else { $null }
    $keys = @()
    if ($ind) { $keys = @($ind.Keys) }
    if (-not @($keys | Where-Object { $_ -match '(\d\dH\d)$' -and $Matches[1] -gt '23H2' }).Count) { $stale = $true }
    if ($stale) { $plan.Add('RunAppraiser') }
    return @($plan)
}

# Applies a plan. Returns what was done and what failed; never throws.
function Invoke-FurFix {
    param([string[]]$Plan)
    $done = @(); $errors = @()
    foreach ($step in $Plan) {
        try {
            switch ($step) {
                'EnableAppraiserTask' { $null = Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -TaskName 'Microsoft Compatibility Appraiser' -ErrorAction Stop }
                'RunAppraiser' {
                    # Asynchronous: the scan outlives the loader's 5-minute limit.
                    try { Start-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -TaskName 'Microsoft Compatibility Appraiser' -ErrorAction Stop }
                    catch {
                        $exe = Join-Path $env:SystemRoot 'System32\CompatTelRunner.exe'
                        $null = Start-Process -FilePath $exe -ArgumentList @('-m:appraiser.dll', '-f:DoScheduledTelemetryRun') -WindowStyle Hidden -ErrorAction Stop
                    }
                }
            }
            $done += $step
        } catch { $errors += "${step}: $(Limit-Text "$_" 100)" }
    }
    return [ordered]@{ done = $done; errors = $errors }
}

function Invoke-Main {
    try {
        Write-Status "Feature update readiness collection starting"
        $record = [ordered]@{}
        $record.os = Get-OsInfo
        $record.policy = Get-PolicyInfo
        $record.appraiser = Get-AppraiserInfo
        $record.toolHints = Get-FurToolHints
        $record.hw = Get-HardwareInfo
        Write-Status "Windows Update search (up to $FurSearchSeconds s)"
        $record.wuSearch = Invoke-WuSearch
        try {
            $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 20, 25, 31; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 300 -ErrorAction Stop
        } catch { $ev = @() }
        $record.events = Get-FurEventSummary $ev
        $record.setup = Get-SetupInfo
        $record.timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $record.verdict = Get-FurVerdict $record
        $record.version = "1.1"

        if ($Fix) {
            $plan = @(Get-FurFixPlan $record)
            $before = [ordered]@{ diagTrack = $record.appraiser.diagTrack; task = $record.appraiser.task.state; expTask = (Get-FurExpTaskState $record.appraiser); taskLastRun = $record.appraiser.task.lastRun }
            Write-Status "Fix plan: $(if ($plan.Count) { $plan -join ', ' } else { 'nothing to do' })"
            $result = Invoke-FurFix $plan
            $after = Get-AppraiserInfo
            $record.fix = [ordered]@{
                plan   = $plan
                done   = $result.done
                errors = $result.errors
                before = $before
                after  = [ordered]@{ diagTrack = $after.diagTrack; task = $after.task.state; expTask = (Get-FurExpTaskState $after); taskLastRun = $after.task.lastRun }
            }
        }

        $json = ConvertTo-FurJson $record
        Write-Status "Verdict: $($record.verdict) ($($json.Length) bytes)"
        if (Set-FurField $json) { Write-Status "Written to $FurFieldName" }
        else { Write-Status "Custom field not written; the JSON line below is the result" "WARN" }
        # Last stdout line is the JSON; the loader picks the last line that starts with "{".
        Write-Output $json
    } catch {
        Write-Status "Feature update readiness error: $_" "ERROR"
        Write-Status $_.ScriptStackTrace "ERROR"
        exit 1
    }
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') { Invoke-Main }
