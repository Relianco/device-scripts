<#
.SYNOPSIS
    Read-only Windows Update evidence: services, policy, update history, client events and a servicing-log error digest.
.DESCRIPTION
    Section is Summary (default), History, Events, Policy, Service or ServicingHistory. Prints one JSON line of at most
    7,600 UTF-8 bytes (the loader adds its envelope below its 8,000-byte cap); a list that does not fit loses its oldest
    rows and the report says truncated.
    Reads registry values, service and scheduled-task state, file metadata, the Windows Update client event log, the update
    history (COM QueryHistory, History only) and the CBS and DISM logs. It never scans for, downloads or installs updates,
    never starts, stops or reconfigures a service, never writes the registry or a file, never runs DISM, SFC or
    Get-WindowsUpdateLog (that one writes a merged log file). Creating the Windows Update COM session in History can
    demand-start wuauserv, as any read of the update history does; nothing else is triggered.
    ServicingHistory reads every line of CBS.log, dism.log and the CbsPersist_*.log files (never the .cab archives, whose
    names and dates are listed only) as a stream. It keeps a digest of distinct error codes with first and last timestamp
    (the device's local time, as the logs write it), counts and files, never bulk text, and stops at 75 seconds or 1 GiB
    read and says so.
    Windows PowerShell 5.1+, run as SYSTEM by the Relian read-job loader, which kills it after 120 seconds.
#>
[CmdletBinding()]
param([string]$DeploymentType, [string]$Action, [string]$PinVersion,
      [ValidateSet('Summary', 'History', 'Events', 'Policy', 'Service', 'ServicingHistory')][string]$Section = 'Summary')
$ProgressPreference = 'SilentlyContinue'

$script:OutputMaxBytes = 7600
$script:ProbeSeconds = 90
$script:ScanSeconds = 75
$script:ScanMaxBytes = 1GB
$script:Services = @('wuauserv', 'bits', 'cryptsvc', 'TrustedInstaller', 'UsoSvc', 'WaaSMedicSvc', 'DoSvc', 'msiserver')
$script:WuLog = 'Microsoft-Windows-WindowsUpdateClient/Operational'
$script:CodeRx = [regex]::new('0x[8cC][0-9a-fA-F]{7}\b|\b(?:CBS_E|ERROR|STATUS|PSFX_E|SPAPI_E|E)_[A-Z0-9_]{3,}\b', 'Compiled')
$script:LineRx = [regex]::new('0x[8cC][0-9a-fA-F]{7}\b|, Error |\b(?:CBS_E|ERROR|STATUS|PSFX_E|SPAPI_E|E)_[A-Z0-9_]{3,}\b', 'Compiled')
$script:MaxCodes = 300

function Protect-WuText {
    param([string]$Text, [int]$Max = 160)
    if ($Text -match '(?i)password|passwd|\bpwd\s*=|secret|token|authorization|bearer|credential|api.?key|accountkey|product.?key|command.?line') { return '[sensitive line omitted]' }
    $t = $Text -replace '(?i)[a-z][a-z0-9+.-]*://\S+', '[url omitted]'
    $t = $t -replace '(?i)([a-z]:\\Users\\)[^\\\s]+', '$1[redacted]'
    $t = ($t -replace '[\x00-\x1F]', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '[clipped]' }
    return $t
}

function Format-WuHex {
    param($Value)
    $s = [string]$Value
    if ($s -match '\A0[xX][0-9a-fA-F]{1,8}\z') { return '0x' + $s.Substring(2).ToLowerInvariant().PadLeft(8, '0') }
    $n = 0L
    if ([long]::TryParse($s, [ref]$n) -and $n -ge [int]::MinValue -and $n -le [uint32]::MaxValue) { return '0x' + ([uint32]($n -band [long]4294967295)).ToString('x8') }
    return Protect-WuText $s -Max 24
}

# -Utc: the Windows Update COM dates are UTC already (IUpdateHistoryEntry.Date, IAutomaticUpdatesResults) and carry no kind.
function Get-WuUtc {
    param($Date, [switch]$Utc)
    if ($null -eq $Date) { return $null }
    $d = if ($Utc) { [datetime]::SpecifyKind([datetime]$Date, [DateTimeKind]::Utc) } else { ([datetime]$Date).ToUniversalTime() }
    return $d.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-WuError { param($Record) return @{ status = 'unavailable'; error = $Record.Exception.GetType().Name } }

# Every value of one key, at most $Max names. Numbers as numbers; strings only when allowlisted ($Strings, clipped) or as a
# host ($Hosts: a WSUS URL keeps its host only); anything else is named but not read out.
function Read-WuKey {
    param([string]$Path, [string[]]$Strings = @(), [string[]]$Hosts = @(), [int]$Max = 25)
    try {
        if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { return @{ status = 'missing' } }
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        $names = @($key.GetValueNames() | Sort-Object)
        $values = [ordered]@{}
        foreach ($name in @($names | Select-Object -First $Max)) {
            $value = $key.GetValue($name)
            $label = if ($name) { $n = $name -replace '[\x00-\x1F]', ''; $n.Substring(0, [Math]::Min(64, $n.Length)) } else { '(default)' }
            if ($value -is [int] -or $value -is [long] -or $value -is [uint32] -or $value -is [uint64]) { $values[$label] = [long]$value }
            elseif ($Hosts -contains $name) {
                $uri = $null
                $values[$label] = if ([uri]::TryCreate([string]$value, [UriKind]::Absolute, [ref]$uri)) { 'host:' + (Protect-WuText $uri.Host -Max 80) } else { 'notAUrl' }
            }
            elseif ($Strings -contains $name -and $value -is [string]) { $values[$label] = Protect-WuText $value -Max 80 }
            else { $values[$label] = 'omitted' }
        }
        return [ordered]@{ status = 'read'; values = $values; moreNames = [Math]::Max(0, $names.Count - $Max) }
    } catch { return Get-WuError $_ }
}

function Read-WuPendingReboot {
    $r = [ordered]@{}
    $cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
    $au = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'
    foreach ($e in @(@('cbsRebootPending', "$cbs\RebootPending"), @('cbsRebootInProgress', "$cbs\RebootInProgress"), @('cbsPackagesPending', "$cbs\PackagesPending"),
                     @('wuRebootRequired', "$au\RebootRequired"), @('wuPostRebootReporting', "$au\PostRebootReporting"))) {
        try { $r[$e[0]] = Test-Path -LiteralPath $e[1] -ErrorAction Stop } catch { $r[$e[0]] = 'unknown' }
    }
    try {
        $updates = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Updates' -ErrorAction Stop
        $r.updateExeVolatile = if ($updates.PSObject.Properties['UpdateExeVolatile']) { [long]$updates.UpdateExeVolatile } else { $null }
    } catch { $r.updateExeVolatile = 'unknown' }
    try {
        # A count only: the paths carry profile names.
        $session = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        $r.fileRenameEntries = if ($session.PSObject.Properties['PendingFileRenameOperations']) { @($session.PendingFileRenameOperations | Where-Object { $_ }).Count } else { 0 }
    } catch { $r.fileRenameEntries = 'unknown' }
    return $r
}

function Read-WuServices {
    param([switch]$Brief)
    try {
        $filter = (@($script:Services | ForEach-Object { "Name='$_'" }) -join ' OR ')
        $rows = @(Get-CimInstance -ClassName Win32_Service -Filter $filter -OperationTimeoutSec 5 -ErrorAction Stop)
        $out = @()
        foreach ($name in $script:Services) {
            $row = @($rows | Where-Object { $_.Name -eq $name }) | Select-Object -First 1
            if (-not $row) { $out += [ordered]@{ name = $name; state = 'notInstalled' }; continue }
            $s = [ordered]@{ name = $name; state = [string]$row.State; startMode = [string]$row.StartMode }
            if ($row.PSObject.Properties['DelayedAutoStart'] -and $null -ne $row.DelayedAutoStart) { $s.delayed = [bool]$row.DelayedAutoStart }
            if (-not $Brief) {
                $s.account = Protect-WuText ([string]$row.StartName) -Max 40
                $s.exitCode = [long]$row.ExitCode
                $s.serviceExitCode = [long]$row.ServiceSpecificExitCode
                $s.processId = [long]$row.ProcessId
            }
            $out += $s
        }
        return $out
    } catch { return @(Get-WuError $_) }
}

function Read-WuOs {
    $os = Read-WuKey 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Strings @('CurrentBuild', 'DisplayVersion', 'EditionID', 'ProductName') -Max 200
    if ($os.Contains('values')) {
        $keep = [ordered]@{}
        foreach ($n in @('ProductName', 'EditionID', 'DisplayVersion', 'CurrentBuild', 'UBR', 'InstallDate')) { if ($os.values.Contains($n)) { $keep[$n] = $os.values[$n] } }
        return $keep
    }
    return $os
}

# Events of the Windows Update client log, newest first. Named fields only (the event XML), never the rendered message.
function Read-WuEvents {
    param([hashtable]$Filter, [int]$Max)
    try { $events = @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop) }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return @() }
        throw
    }
    foreach ($e in $events) {
        $row = [ordered]@{ time = Get-WuUtc $e.TimeCreated; id = [int]$e.Id; level = [int]$e.Level; code = $null; kb = $null }
        try {
            foreach ($d in @(([xml]$e.ToXml()).Event.EventData.Data)) {
                $name = [string]$d.Name; $text = [string]$d.'#text'
                if ($name -eq 'errorCode' -or ($null -eq $row.code -and $text -match '\A0x[0-9a-fA-F]{8}\z')) { $row.code = Format-WuHex $text }
                if ($name -eq 'updateTitle' -and $text -match 'KB[0-9]{6,8}') { $row.kb = $Matches[0] }
            }
        } catch { $row.code = 'unreadable' }
        $row
    }
}

function Read-WuSummary {
    param($Clock)
    $r = [ordered]@{}
    $r.os = Read-WuOs
    try { $r.lastBoot = Get-WuUtc (Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop).LastBootUpTime } catch { $r.lastBoot = 'unavailable' }
    $r.pendingReboot = Read-WuPendingReboot
    $r.services = Read-WuServices -Brief
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $flags = [ordered]@{}
    foreach ($p in @(@($policy, @('WUServer', 'DisableWindowsUpdateAccess', 'DoNotConnectToWindowsUpdateInternetLocations', 'SetPolicyDrivenUpdateSourceForQualityUpdates', 'SetPolicyDrivenUpdateSourceForFeatureUpdates', 'TargetReleaseVersion', 'TargetReleaseVersionInfo', 'DeferFeatureUpdatesPeriodInDays', 'DeferQualityUpdatesPeriodInDays')),
                     @("$policy\AU", @('UseWUServer', 'NoAutoUpdate', 'AUOptions')))) {
        $k = Read-WuKey $p[0] -Strings @('TargetReleaseVersionInfo') -Hosts @('WUServer') -Max 60
        if ($k.Contains('values')) { foreach ($n in $p[1]) { if ($k.values.Contains($n)) { $flags[$n] = $k.values[$n] } } }
    }
    $r.policy = $flags
    $results = [ordered]@{}
    foreach ($stage in @('Detect', 'Download', 'Install')) {
        $k = Read-WuKey "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\$stage" -Strings @('LastSuccessTime') -Max 10
        $results[$stage] = if ($k.Contains('values')) { $k.values } else { $k.status }
    }
    $r.lastResults = $results
    if ($Clock.Elapsed.TotalSeconds -gt $script:ProbeSeconds) { $r.recentErrors = @{ status = 'timeBudget' } }
    else {
        try {
            $errs = @(Read-WuEvents @{ LogName = $script:WuLog; Level = @(1, 2); StartTime = [datetime]::Now.AddDays(-30) } 500)
            $r.recentErrors = [ordered]@{ days = 30; count = $errs.Count; capped = $errs.Count -ge 500; latest = @($errs | Select-Object -First 5) }
        } catch { $r.recentErrors = Get-WuError $_ }
    }
    return $r
}

function Read-WuHistory {
    param($Clock)
    $r = [ordered]@{}
    try {
        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()
        $total = [int]$searcher.GetTotalHistoryCount()
        $count = [Math]::Min($total, 400)
        $r.historyTotal = $total; $r.historyQueried = $count
        $rows = @()
        if ($count -gt 0) {
            foreach ($h in @($searcher.QueryHistory(0, $count))) {
                $kb = if ([string]$h.Title -match 'KB[0-9]{6,8}') { $Matches[0] } else { $null }
                $rows += [ordered]@{ date = Get-WuUtc $h.Date -Utc; op = [int]$h.Operation; result = [int]$h.ResultCode; hr = Format-WuHex ([int]$h.HResult); kb = $kb; title = Protect-WuText ([string]$h.Title) -Max 70 }
            }
        }
        $rows = @($rows | Sort-Object { $_.date } -Descending)
        # ResultCode 4 failed, 5 aborted, 3 succeeded with errors: one row per HRESULT over everything queried.
        $failures = @{}
        foreach ($row in @($rows | Where-Object { $_.result -ge 3 })) {
            if (-not $failures.ContainsKey($row.hr)) { $failures[$row.hr] = [ordered]@{ hr = $row.hr; n = 0; first = $row.date; last = $row.date; kbs = @() } }
            $f = $failures[$row.hr]; $f.n++
            if ($row.date -lt $f.first) { $f.first = $row.date }
            if ($row.date -gt $f.last) { $f.last = $row.date }
            if ($row.kb -and $f.kbs -notcontains $row.kb -and $f.kbs.Count -lt 4) { $f.kbs += $row.kb }
        }
        $r.failures = @($failures.Values | Sort-Object { $_.last } -Descending | Select-Object -First 15)
        $r.recent = @($rows | Select-Object -First 25)
    } catch { $r.history = Get-WuError $_ }
    try {
        $results = (New-Object -ComObject 'Microsoft.Update.AutoUpdate').Results
        $r.autoUpdate = [ordered]@{ lastSearchSuccess = Get-WuUtc $results.LastSearchSuccessDate -Utc; lastInstallSuccess = Get-WuUtc $results.LastInstallationSuccessDate -Utc }
    } catch { $r.autoUpdate = Get-WuError $_ }
    try { $r.rebootRequired = [bool](New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired } catch { $r.rebootRequired = 'unknown' }
    if ($Clock.Elapsed.TotalSeconds -gt $script:ProbeSeconds) { $r.hotfixes = @(@{ status = 'timeBudget' }) }
    else {
        try {
            $fixes = @(Get-CimInstance -ClassName Win32_QuickFixEngineering -OperationTimeoutSec 10 -ErrorAction Stop | ForEach-Object {
                $when = [datetime]::MinValue
                $ok = [datetime]::TryParse([string]$_.InstalledOn, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$when)
                [ordered]@{ id = Protect-WuText ([string]$_.HotFixID) -Max 16; type = Protect-WuText ([string]$_.Description) -Max 24; installedOn = $(if ($ok) { $when.ToString('yyyy-MM-dd') } else { Protect-WuText ([string]$_.InstalledOn) -Max 24 }) }
            })
            $r.hotfixes = @($fixes | Sort-Object { $_.installedOn } -Descending | Select-Object -First 12)
        } catch { $r.hotfixes = @(Get-WuError $_) }
    }
    return $r
}

function Read-WuEventDigest {
    $r = [ordered]@{}
    try {
        $info = Get-WinEvent -ListLog $script:WuLog -ErrorAction Stop
        $newest = @(Read-WuEvents @{ LogName = $script:WuLog } 1)
        $r.log = [ordered]@{ enabled = [bool]$info.IsEnabled; records = [long]$info.RecordCount; sizeBytes = [long]$info.FileSize; maxBytes = [long]$info.MaximumSizeInBytes; newest = $(if ($newest.Count) { $newest[0].time } else { $null }) }
        try { $first = @(Get-WinEvent -LogName $script:WuLog -MaxEvents 1 -Oldest -ErrorAction Stop); $r.log.oldest = Get-WuUtc $first[0].TimeCreated } catch { $r.log.oldest = $null }
    } catch { $r.log = Get-WuError $_ }
    try {
        $errs = @(Read-WuEvents @{ LogName = $script:WuLog; Level = @(1, 2, 3); StartTime = [datetime]::Now.AddDays(-120) } 3000)
        $digest = @{}
        foreach ($e in $errs) {
            $k = "$($e.id)|$($e.code)"
            if (-not $digest.ContainsKey($k)) { $digest[$k] = [ordered]@{ id = $e.id; code = $e.code; n = 0; first = $e.time; last = $e.time; kbs = @() } }
            $d = $digest[$k]; $d.n++
            if ($e.time -lt $d.first) { $d.first = $e.time }
            if ($e.time -gt $d.last) { $d.last = $e.time }
            if ($e.kb -and $d.kbs -notcontains $e.kb -and $d.kbs.Count -lt 4) { $d.kbs += $e.kb }
        }
        $r.errors = [ordered]@{ days = 120; events = $errs.Count; capped = $errs.Count -ge 3000 }
        $r.codes = @($digest.Values | Sort-Object { $_.last } -Descending | Select-Object -First 25)
    } catch { $r.errors = Get-WuError $_ }
    try { $r.events = @(Read-WuEvents @{ LogName = $script:WuLog } 15) } catch { $r.events = @(Get-WuError $_) }
    return $r
}

function Read-WuPolicy {
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $pause = @('PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime', 'PauseUpdatesStartTime', 'PauseUpdatesExpiryTime')
    $r = [ordered]@{}
    $r.policy = [ordered]@{
        windowsUpdate = Read-WuKey $policy -Strings @('TargetReleaseVersionInfo', 'ProductVersion') -Hosts @('WUServer', 'WUStatusServer', 'UpdateServiceUrlAlternate')
        au            = Read-WuKey "$policy\AU"
        mdm           = Read-WuKey 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update' -Strings @('TargetReleaseVersion', 'ProductVersion') -Hosts @('UpdateServiceUrl', 'UpdateServiceUrlAlternate')
        policyState   = Read-WuKey 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState' -Strings (@('PolicySources', 'BranchReadinessLevel') + $pause)
    }
    $r.ux = Read-WuKey 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Strings $pause
    return $r
}

function Read-WuFileMeta {
    param([string]$Path)
    try {
        $f = [IO.FileInfo]::new($Path)
        if (-not $f.Exists) { return @{ status = 'missing' } }
        return [ordered]@{ sizeBytes = $f.Length; lastWriteUtc = Get-WuUtc $f.LastWriteTimeUtc }
    } catch { return Get-WuError $_ }
}

function Read-WuService {
    param($Clock)
    $r = [ordered]@{}
    $r.services = Read-WuServices
    $r.orchestrator = Read-WuKey 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator' -Max 20
    $r.tasks = @()
    foreach ($path in @('\Microsoft\Windows\UpdateOrchestrator\', '\Microsoft\Windows\WindowsUpdate\', '\Microsoft\Windows\WaaSMedic\')) {
        if ($Clock.Elapsed.TotalSeconds -gt $script:ProbeSeconds) { $r.tasks += @{ path = $path; status = 'timeBudget' }; continue }
        try {
            foreach ($t in @(Get-ScheduledTask -TaskPath $path -ErrorAction Stop | Select-Object -First 12)) {
                $row = [ordered]@{ name = Protect-WuText ([string]$t.TaskName) -Max 48; state = [string]$t.State }
                try {
                    $i = Get-ScheduledTaskInfo -InputObject $t -ErrorAction Stop
                    $row.lastRun = Get-WuUtc $i.LastRunTime; $row.lastResult = Format-WuHex ([long]$i.LastTaskResult); $row.nextRun = Get-WuUtc $i.NextRunTime
                } catch { $row.info = 'unavailable' }
                $r.tasks += $row
            }
        } catch { $r.tasks += [ordered]@{ path = $path; status = 'unavailable'; error = $_.Exception.GetType().Name } }
    }
    $win = $env:SystemRoot
    $logs = [ordered]@{
        dataStore       = Read-WuFileMeta (Join-Path $win 'SoftwareDistribution\DataStore\DataStore.edb')
        reportingEvents = Read-WuFileMeta (Join-Path $win 'SoftwareDistribution\ReportingEvents.log')
        legacyLog       = Read-WuFileMeta (Join-Path $win 'WindowsUpdate.log')
    }
    try {
        $etl = @(Get-ChildItem -LiteralPath (Join-Path $win 'Logs\WindowsUpdate') -Filter '*.etl' -File -ErrorAction Stop | Sort-Object LastWriteTimeUtc)
        $logs.etl = [ordered]@{ count = $etl.Count; totalBytes = [long](($etl | Measure-Object -Property Length -Sum).Sum)
                                oldestUtc = $(if ($etl.Count) { Get-WuUtc $etl[0].LastWriteTimeUtc } else { $null }); newestUtc = $(if ($etl.Count) { Get-WuUtc $etl[-1].LastWriteTimeUtc } else { $null }) }
    } catch { $logs.etl = Get-WuError $_ }
    $r.wuLogs = $logs
    return $r
}

# One log, line by line, into the shared code table. $State carries the byte budget and the clock across files.
function Read-WuLogDigest {
    param([string]$Path, [string]$Label, [hashtable]$Codes, $State)
    $f = [ordered]@{ label = $Label }
    $stream = $null; $reader = $null
    try {
        if (-not [IO.File]::Exists($Path)) { $f.status = 'missing'; return $f }
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $f.sizeBytes = $stream.Length; $f.lastWriteUtc = Get-WuUtc ([IO.File]::GetLastWriteTimeUtc($Path))
        # shortcut: ReadLine has no per-line cap, a multi-megabyte line without a newline is held whole; upgrade if a real log ever has one.
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 65536)
        $lines = 0L; $errorLines = 0L; $ts = $null; $firstTs = $null; $f.stoppedBy = $null
        while ($null -ne ($line = $reader.ReadLine())) {
            $lines++
            if (($lines -band 4095) -eq 0) {
                if ($State.Clock.Elapsed.TotalSeconds -gt $script:ScanSeconds) { $f.stoppedBy = 'time'; break }
                if ($State.BytesRead + $stream.Position -gt $script:ScanMaxBytes) { $f.stoppedBy = 'bytes'; break }
            }
            # CBS and DISM lines start 'yyyy-MM-dd HH:mm:ss,'; a continuation line keeps the last stamp.
            if ($line.Length -ge 19 -and $line[4] -eq '-' -and $line[7] -eq '-' -and $line[10] -eq ' ' -and $line[13] -eq ':' -and [char]::IsDigit($line[0])) {
                $ts = $line.Substring(0, 19)
                if ($null -eq $firstTs) { $firstTs = $ts }
            }
            if (-not $script:LineRx.IsMatch($line)) { continue }
            $hex = @(); $names = @()
            foreach ($m in $script:CodeRx.Matches($line)) {
                $v = $m.Value
                if ($v.StartsWith('0x') -or $v.StartsWith('0X')) { $hex += $v.ToLowerInvariant() } elseif (-not $v.EndsWith('_SUCCESS')) { $names += $v }
            }
            $keys = @(if ($hex.Count) { $hex } elseif ($names.Count) { $names } elseif ($line.Contains(', Error ')) { '(error line, no code)' })
            if (-not $keys.Count) { continue }
            $errorLines++
            foreach ($k in @($keys | Select-Object -Unique)) {
                if (-not $Codes.ContainsKey($k)) {
                    if ($Codes.Count -ge $script:MaxCodes) { $State.Untracked++; continue }
                    $Codes[$k] = [ordered]@{ code = $k; name = $null; n = 0L; first = $null; last = $null; files = @(); sample = $null }
                }
                $c = $Codes[$k]; $c.n++
                if ($ts) {
                    if ($null -eq $c.first -or $ts -lt $c.first) { $c.first = $ts }
                    if ($null -eq $c.last -or $ts -gt $c.last) { $c.last = $ts; $c.sample = $line }
                } elseif ($null -eq $c.sample) { $c.sample = $line }
                if ($hex.Count -and $names.Count -and -not $c.name) { $c.name = $names[0] }
                if ($c.files -notcontains $Label) { $c.files += $Label }
            }
        }
        $f.lines = $lines; $f.errorLines = $errorLines; $f.firstTime = $firstTs; $f.lastTime = $ts
        $f.complete = $null -eq $f.stoppedBy
        $State.BytesRead += $stream.Position
        return $f
    } catch { $f.status = 'unavailable'; $f.error = $_.Exception.GetType().Name; return $f }
    finally { if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() } }
}

function Read-WuServicingHistory {
    param($Clock)
    $win = $env:SystemRoot
    $cbsDir = Join-Path $win 'Logs\CBS'
    $targets = @(@('cbs', (Join-Path $cbsDir 'CBS.log')), @('dism', (Join-Path $win 'Logs\DISM\dism.log')))
    $r = [ordered]@{}
    try {
        # CbsPersist_<yyyyMMddHHmmss>: newest first, so a time stop drops the oldest history.
        $persist = @(Get-ChildItem -LiteralPath $cbsDir -Filter 'CbsPersist_*.log' -File -ErrorAction Stop | Sort-Object Name -Descending | Select-Object -First 16)
        foreach ($p in $persist) { $targets += , @(('persist-' + ($p.BaseName -replace '\ACbsPersist_', '')), $p.FullName) }
        $cabs = @(Get-ChildItem -LiteralPath $cbsDir -Filter 'CbsPersist_*.cab' -File -ErrorAction Stop | Sort-Object Name)
        $r.archives = [ordered]@{ count = $cabs.Count; oldest = $(if ($cabs.Count) { $cabs[0].BaseName -replace '\ACbsPersist_', '' } else { $null }); newest = $(if ($cabs.Count) { $cabs[-1].BaseName -replace '\ACbsPersist_', '' } else { $null }); note = 'not opened' }
    } catch { $r.archives = Get-WuError $_ }
    $codes = @{}
    $state = @{ Clock = $Clock; BytesRead = 0L; Untracked = 0L }
    $r.files = @()
    foreach ($t in $targets) {
        if ($Clock.Elapsed.TotalSeconds -gt $script:ScanSeconds) { $r.files += [ordered]@{ label = $t[0]; status = 'timeBudget' }; continue }
        $r.files += Read-WuLogDigest -Path $t[1] -Label $t[0] -Codes $codes -State $state
    }
    $sorted = @($codes.Values | Sort-Object @{ Expression = { [string]$_.last }; Descending = $true }, @{ Expression = { $_.n }; Descending = $true })
    $i = 0
    foreach ($c in $sorted) {
        # The latest line of each code as an example, redacted and clipped; only for the first five.
        $c.sample = if ($i -lt 5 -and $c.sample) { Protect-WuText ([string]$c.sample) -Max 160 } else { $null }
        if (-not $c.sample) { $c.Remove('sample') }
        if (-not $c.name) { $c.Remove('name') }
        $i++
    }
    $r.codesTracked = $codes.Count
    $r.untrackedHits = $state.Untracked
    $r.codes = @($sorted | Select-Object -First 30)
    return $r
}

# Arrays held by a dictionary key, anywhere in the report, with their serialized size.
function Get-WuLists {
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) {
            $item = $Value[$k]
            if ($item -is [array] -and $item.Count) { [pscustomobject]@{ Parent = $Value; Key = $k; Size = (ConvertTo-Json -InputObject $item -Depth 8 -Compress).Length } }
            Get-WuLists $item
        }
    } elseif ($Value -is [array]) { foreach ($x in $Value) { Get-WuLists $x } }
}

function ConvertTo-WuJson {
    param($Report, [int]$MaxBytes = $script:OutputMaxBytes)
    $Report['truncated'] = $false
    $json = $Report | ConvertTo-Json -Depth 8 -Compress
    while ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxBytes) {
        $Report['truncated'] = $true
        # Lists are newest first: the largest one loses its last (oldest) row.
        $list = @(Get-WuLists $Report | Sort-Object Size -Descending) | Select-Object -First 1
        if (-not $list) { throw 'Report exceeds the output budget.' }
        $rows = $list.Parent[$list.Key]
        $list.Parent[$list.Key] = @($rows | Select-Object -First ($rows.Count - 1))
        $json = $Report | ConvertTo-Json -Depth 8 -Compress
    }
    return $json
}

function Invoke-WindowsUpdateDiagnostic {
    param([ValidateSet('Summary', 'History', 'Events', 'Policy', 'Service', 'ServicingHistory')][string]$Section = 'Summary')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $report = [ordered]@{ version = '1'; timestamp = Get-WuUtc ([datetime]::UtcNow); status = 'collected'; section = $Section }
    $data = switch ($Section) {
        'Summary' { Read-WuSummary $clock }
        'History' { Read-WuHistory $clock }
        'Events' { Read-WuEventDigest }
        'Policy' { Read-WuPolicy }
        'Service' { Read-WuService $clock }
        'ServicingHistory' { Read-WuServicingHistory $clock }
    }
    foreach ($k in $data.Keys) { $report[$k] = $data[$k] }
    $report.elapsedSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
    return ConvertTo-WuJson $report
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if ($Action -eq 'Uninstall') { Write-Output '{"status":"nothingToUninstall"}'; exit 0 }
if (@('Install', 'Update', 'Repair', 'Reinstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
try { Write-Output (Invoke-WindowsUpdateDiagnostic -Section $Section); exit 0 }
catch { Write-Output ('{"status":"failed","error":"' + $_.Exception.GetType().Name + '"}'); exit 1 }
