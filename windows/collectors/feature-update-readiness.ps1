<#
.SYNOPSIS
    Feature update readiness collector for Relian device inventory.
    Says why Windows Update has not moved a device to the next feature update.

.DESCRIPTION
    Read-only. It reads the OS version, Windows Update policy (GPO, MDM and
    the effective policy state), the compatibility appraiser's upgrade
    indicators (safeguard holds), TPM, Secure Boot, free disk space, a Windows
    Update Agent search for updates that are not installed, recent Windows
    Update client errors, and logs from earlier setup attempts. It writes no
    registry value, changes no policy, and starts no upgrade.

    The result is one line of compact JSON, printed last on stdout, with a
    short "verdict". The JSON also goes to the NinjaOne device custom field
    relianFeatureUpdate when the NinjaOne agent is present.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM
    Timeout: the Windows Update search stops after 150 seconds
    No external module dependencies
#>

$ProgressPreference = "SilentlyContinue"

# NinjaOne field names are alphanumeric only, so the loader's relian_<name> write cannot land.
$FurFieldName = "relianFeatureUpdate"
# ponytail: NinjaOne text fields hold about 10,000 characters; trim to stay under.
$FurMaxJson = 9500
$FurSearchSeconds = 150

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
    $os = $Record.os
    if ($os -and [int]$os.build -ge 26100) { return "already $($os.displayVersion)" }

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
    if ($pin -and $pin -notmatch '^(24H2|25H2|2[6-9]H\d)') { $reasons.Add("pinned to $pin") }

    if ((Test-Has $au 'UseWUServer') -and [int]$au.UseWUServer -eq 1) {
        $server = if (Test-Has $wu 'WUServer') { $wu.WUServer } else { 'no server set' }
        $reasons.Add("WSUS/policy blocks WU ($server)")
    }
    if ((Test-Has $wu 'DoNotConnectToWindowsUpdateInternetLocations') -and [int]$wu.DoNotConnectToWindowsUpdateInternetLocations -eq 1) {
        $reasons.Add("WSUS/policy blocks WU (no internet locations)")
    }
    if ((Test-Has $wu 'PauseFeatureUpdatesStartTime') -or ((Test-Has $state 'PausedFeatureStatus') -and [int]$state.PausedFeatureStatus -eq 1)) {
        $reasons.Add("feature updates paused")
    }

    $ind = $null
    if ($Record.appraiser) { $ind = $Record.appraiser.indicators }
    $targets = @()
    if ($ind) { $targets = @($ind.Keys | Where-Object { $_ -match '24H2|25H2' } | Sort-Object) }
    if ($targets.Count -eq 0) {
        $reasons.Add("appraiser has no 24H2/25H2 data")
    } else {
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

    $search = $Record.wuSearch
    if ($search) {
        if ($search.featureOffered) { $reasons.Add("ok/offered") }
        elseif ($search.error) { $reasons.Add("WU search failed ($($search.error))") }
        else { $reasons.Add("not offered by WU") }
    }
    return ($reasons -join '; ')
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
        dataCollection = Get-RegValues 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Only @('AllowTelemetry', 'DisableOneSettingsDownloads')
        uxSettings     = Get-RegValues 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Only @('IsContinuousInnovationOptedIn', 'PauseFeatureUpdatesEndTime', 'PauseUpdatesExpiryTime')
    }
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
    $task = $null
    try {
        $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -TaskName 'Microsoft Compatibility Appraiser' -ErrorAction Stop
        $ti = $t | Get-ScheduledTaskInfo
        $task = [ordered]@{ state = "$($t.State)"; lastRun = $ti.LastRunTime.ToString('yyyy-MM-dd HH:mm'); lastResult = ('0x{0:x}' -f $ti.LastTaskResult) }
    } catch { $task = @{ error = (Limit-Text "$_" 100) } }
    $diag = $null
    try { $diag = "$((Get-Service DiagTrack -ErrorAction Stop).Status)/$((Get-Service DiagTrack).StartType)" } catch { $diag = 'missing' }
    return [ordered]@{ task = $task; diagTrack = $diag; indicators = $ind }
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
                    $res.titles += "$($u.Title) [$cats]"
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
        $feature = @($titles | Where-Object { $_ -match '24H2|25H2|Feature update|Windows 11, version' })
        $out.featureOffered = ($feature.Count -gt 0)
        $out.featureTitles = @($feature | Select-Object -First 3 | ForEach-Object { Limit-Text $_ 120 })
        $out.titles = @($titles | Select-Object -First 10 | ForEach-Object { Limit-Text $_ 100 })
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

# The loader runs collectors in a child powershell.exe, where the NinjaOne
# cmdlets may not be loaded, so fall back to the agent CLI. --stdin keeps
# PowerShell 5.1 from mangling the quotes in the JSON argument.
function Set-FurField {
    param([string]$Value)
    if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) {
        try { Ninja-Property-Set $FurFieldName $Value; return $true } catch { }
    }
    $cli = Join-Path $env:ProgramData 'NinjaRMMAgent\ninjarmm-cli.exe'
    if (Test-Path -LiteralPath $cli) {
        try {
            $null = $Value | & $cli set --stdin $FurFieldName 2>&1
            return ($LASTEXITCODE -eq 0)
        } catch { }
    }
    return $false
}

function Invoke-Main {
    try {
        Write-Status "Feature update readiness collection starting"
        $record = [ordered]@{}
        $record.os = Get-OsInfo
        $record.policy = Get-PolicyInfo
        $record.appraiser = Get-AppraiserInfo
        $record.hw = Get-HardwareInfo
        Write-Status "Windows Update search (up to $FurSearchSeconds s)"
        $record.wuSearch = Invoke-WuSearch
        try {
            $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 20, 25, 31; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 300 -ErrorAction Stop
        } catch { $ev = @() }
        $record.events = Get-FurEventSummary $ev
        $record.setup = Get-SetupInfo
        $record.verdict = Get-FurVerdict $record
        $record.timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $record.version = "1.0"

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
