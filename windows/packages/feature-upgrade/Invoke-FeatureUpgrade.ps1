<#
.SYNOPSIS
    In-place Windows upgrade from a pinned ISO, for the Relian deploy runner (NinjaOne script 374).

.DESCRIPTION
    The ISO is chosen only by the package arguments. Nothing about a release
    (24H2, 25H2, ...) is assumed: the ISO's build is read from the mounted image.

    PackageArguments (strings):
      IsoUrl               https URL of the ISO, no userinfo. Required.
      IsoSha256            64 hex characters. Required.
      BypassHardwareCheck  "true" or "false" (default). "true" adds /product server.

    One run, as SYSTEM:
      1. Checks the arguments. A bad value exits 1 before anything is touched.
      2. Takes the machine-wide mutex Global\RelianFeatureUpgrade. Held: reports busy.
      3. Reads the state left by an earlier attempt and reports it instead of
         starting another: starting/running, staged (reboot pending), finished,
         rolled back, failed. A finished or failed attempt is reported once and
         cleared; the next run starts a new attempt.
      4. Stops when Windows already has a reboot pending.
      5. Checks free space (ISO size plus 20 GB), then downloads the ISO into
         %ProgramData%\Relian\FeatureUpgrade with a streamed, resumable download,
         or reuses a file whose SHA256 already matches. A mismatch deletes the file
         and exits 1.
      6. Mounts the ISO, reads its build, dismounts. At or below the running build:
         exits 0 with status alreadyCurrent.
      7. Starts the upgrade detached and exits 0 with status started.

    Why detached: setup runs 1-3 hours on old hardware, longer than a NinjaOne job
    should, and a child of the job could be killed with it or hold the runner's
    output pipe open. So the run copies this script into the working folder
    (SYSTEM and Administrators only) and starts it as a one-shot SYSTEM scheduled
    task with -Worker true. The worker re-checks the hash, mounts, runs
    setup.exe /auto upgrade /quiet /noreboot /eula accept /dynamicupdate disable
    /copylogs <dir> through Start-Process -PassThru, waits up to 6 hours for the
    real exit code, always dismounts, writes the result to state.json and the
    device field, and removes its task. Exit 0 or 3010/1641 means staged: the
    upgrade finishes at the next reboot, which this package never starts.

    It never reboots, never touches security services, safe mode, Windows Update
    folders or IFEO keys.

    The result is one line of compact JSON, printed last on stdout and written to
    the NinjaOne device field relianFeatureUpgrade. Uninstall changes nothing and
    exits 0.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM
#>

# Not Mandatory: a mandatory param block prompts when this file is dot-sourced
# under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$IsoUrl = '',
    [string]$IsoSha256 = '',
    [string]$BypassHardwareCheck = '',
    [string]$Worker = ''
)

$ProgressPreference = 'SilentlyContinue'

$FupFieldName = 'relianFeatureUpgrade'
$FupMutexName = 'Global\RelianFeatureUpgrade'
$FupTaskName = 'Relian Feature Upgrade'
$FupMarginBytes = 20GB
# ponytail: assumed ISO size when the server sends no Content-Length.
$FupUnknownIsoBytes = 8GB
$FupDownloadMinutes = 180
$FupSetupHours = 6
# A "started" state with no worker after this long means the task never ran.
$FupStartGraceMinutes = 15
$FupDir = [IO.Path]::Combine("$env:ProgramData", 'Relian', 'FeatureUpgrade')

function Write-Status {
    param([string]$Message, [string]$Level = 'INFO')
    Write-Host "[$Level] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
}

# Pure: validated arguments as a hashtable. Throws on anything malformed.
function Get-FupArgs {
    param([string]$IsoUrl, [string]$IsoSha256, [string]$BypassHardwareCheck, [switch]$WorkerMode)
    if ($IsoSha256 -notmatch '\A[0-9A-Fa-f]{64}\z') { throw 'IsoSha256 must be 64 hex characters.' }
    $bypass = switch ($BypassHardwareCheck) {
        '' { $false } 'false' { $false } 'true' { $true }
        default { throw 'BypassHardwareCheck must be true or false.' }
    }
    if (-not $WorkerMode) {
        $uri = $null
        if (-not [Uri]::TryCreate($IsoUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or
            $uri.UserInfo -or $IsoUrl -match '[\s"]') {
            throw 'IsoUrl must be an https URL with no userinfo.'
        }
    }
    return @{ IsoUrl = $IsoUrl; IsoSha256 = $IsoSha256.ToUpperInvariant(); Bypass = $bypass }
}

# Pure: 'run' or 'none' for a runner Action. Throws on bad input.
function Get-FupMode {
    param([string]$Action)
    if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -notcontains $Action) {
        throw 'Action must be Install, Update, Repair, Reinstall, or Uninstall.'
    }
    if ($Action -eq 'Uninstall') { return 'none' }
    return 'run'
}

# Pure: setup.exe arguments. Each is one token; the log path is quoted for Start-Process.
function Get-FupSetupArgs {
    param([string]$LogDir, [bool]$Bypass)
    $a = @('/auto', 'upgrade', '/quiet', '/noreboot', '/eula', 'accept', '/dynamicupdate', 'disable', '/copylogs', "`"$LogDir`"")
    # ponytail: /product server skips the CPU/TPM/Secure Boot check in setup of 24H2 and later.
    if ($Bypass) { $a += @('/product', 'server') }
    return $a
}

# Pure: status for a setup exit code. Only 0 and the MSI reboot codes are success:
# Microsoft documents no other success code for /auto upgrade.
function Get-FupSetupStatus {
    param([long]$ExitCode)
    if (@(0, 3010, 1641) -contains $ExitCode) { return 'staged' }
    return 'failed'
}

# Pure: 0x-hex of an exit code (setup returns HRESULTs such as 0xC1900208).
function Format-FupHex {
    param([long]$ExitCode)
    return ('0x{0:X8}' -f ([long]$ExitCode -band 0xFFFFFFFFL))
}

# Pure: Windows build number from a version string ("10.0.26100.1742" -> 26100).
function ConvertTo-FupBuild {
    param([string]$Version)
    if ("$Version" -match '^\s*\d+\.\d+\.(\d+)') { return [int]$Matches[1] }
    return $null
}

# Pure: a round-trip ("o") time string as UTC. A plain [datetime] cast turns it into local time.
function ConvertTo-FupUtc {
    param([string]$Text)
    return [datetime]::Parse($Text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

# Pure: what an earlier attempt's state means now. $LastBoot and $Now are UTC.
# none | starting | interrupted | staged | finished | rolledBack | failed
function Get-FupStateVerdict {
    param($State, [int]$CurrentBuild, [datetime]$LastBoot, [datetime]$Now)
    if (-not $State -or -not $State.status) { return 'none' }
    switch ("$($State.status)") {
        'started' {
            # The worker holds the mutex while it runs, so a free mutex means it has not started yet or died.
            if (($Now - (ConvertTo-FupUtc $State.time)).TotalMinutes -le $FupStartGraceMinutes) { return 'starting' }
            return 'interrupted'
        }
        'running' { return 'interrupted' }
        'staged' {
            if ($State.isoBuild -and $CurrentBuild -ge [int]$State.isoBuild) { return 'finished' }
            if ($LastBoot -gt (ConvertTo-FupUtc $State.time)) { return 'rolledBack' }
            return 'staged'
        }
        'failed' { return 'failed' }
    }
    return 'none'
}

function Read-FupState {
    $p = Join-Path $FupDir 'state.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Write-FupState {
    param($State)
    $p = Join-Path $FupDir 'state.json'
    if ($null -eq $State) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; return }
    [IO.File]::WriteAllText($p, ($State | ConvertTo-Json -Compress))
}

function Get-FupOsBuild {
    return [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuild).CurrentBuild
}

function Get-FupLastBoot {
    return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
}

function Get-FupFreeBytes {
    return [long](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace
}

# A reboot Windows itself is waiting for (servicing or Windows Update).
function Test-FupRebootPending {
    foreach ($k in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path -LiteralPath $k) { return $true }
    }
    return $false
}

# Working folder, SYSTEM and Administrators only: the worker script copy runs as SYSTEM.
function Initialize-FupDir {
    if (-not (Test-Path -LiteralPath $FupDir)) { $null = New-Item -ItemType Directory -Path $FupDir -Force }
    $null = & icacls.exe $FupDir /setowner '*S-1-5-32-544' /T /C /Q
    $null = & icacls.exe $FupDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /C /Q
    if ($LASTEXITCODE -ne 0) { throw "icacls failed with $LASTEXITCODE" }
    $null = New-Item -ItemType Directory -Path (Join-Path $FupDir 'logs') -Force
}

function Get-FupFileHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

# Remote size in bytes, -1 when unknown.
function Get-FupRemoteSize {
    param([string]$Url)
    try {
        $req = [Net.HttpWebRequest]::Create($Url); $req.Method = 'HEAD'; $req.Timeout = 60000
        $resp = $req.GetResponse()
        try { return [long]$resp.ContentLength } finally { $resp.Close() }
    } catch { return -1 }
}

# Streams $Url into $Part, resuming from its current length. Throws on error or when
# the time budget runs out; the part file stays so the next run resumes.
function Save-FupDownload {
    param([string]$Url, [string]$Part, [int]$Minutes)
    $deadline = (Get-Date).AddMinutes($Minutes)
    $have = 0L
    if (Test-Path -LiteralPath $Part) { $have = (Get-Item -LiteralPath $Part).Length }
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Timeout = 60000; $req.ReadWriteTimeout = 120000
    if ($have -gt 0) { $req.AddRange($have) }
    try { $resp = $req.GetResponse() }
    catch [Net.WebException] {
        # 416: the part already holds the whole file (or more); start over.
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 416) {
            Remove-Item -LiteralPath $Part -Force
            return (Save-FupDownload -Url $Url -Part $Part -Minutes $Minutes)
        }
        throw
    }
    try {
        if ($resp.ResponseUri.Scheme -ne 'https') { throw 'download redirected away from https' }
        $mode = [IO.FileMode]::Append
        if ([int]$resp.StatusCode -ne 206) { $mode = [IO.FileMode]::Create; $have = 0 }
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Open($Part, $mode, [IO.FileAccess]::Write)
        try {
            $buf = New-Object byte[] (1MB)
            $lastLog = Get-Date
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n); $have += $n
                if ((Get-Date) -gt $deadline) { throw "download stopped after $Minutes minutes at $([math]::Round($have / 1GB, 2)) GB; run again to resume" }
                if (((Get-Date) - $lastLog).TotalMinutes -ge 5) { Write-Status "Downloaded $([math]::Round($have / 1GB, 2)) GB"; $lastLog = Get-Date }
            }
        } finally { $out.Close(); $in.Close() }
    } finally { $resp.Close() }
}

# Returns the path of a verified ISO. Reuses a matching file, deletes a bad one.
function Get-FupIso {
    param([string]$Url, [string]$Sha256)
    $iso = Join-Path $FupDir "$Sha256.iso"
    $part = "$iso.part"
    # Files from other pins only take space.
    Get-ChildItem -LiteralPath $FupDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.iso(\.part)?$' -and $_.Name -notlike "$Sha256.iso*" } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $iso) {
        if ((Get-FupFileHash $iso) -eq $Sha256) { Write-Status 'Reusing the downloaded ISO (hash matches)'; return $iso }
        Write-Status 'Existing ISO hash does not match; deleting it' 'WARN'
        Remove-Item -LiteralPath $iso -Force
    }
    Write-Status 'Downloading the ISO'
    Save-FupDownload -Url $Url -Part $part -Minutes $FupDownloadMinutes
    $got = Get-FupFileHash $part
    if ($got -ne $Sha256) {
        Remove-Item -LiteralPath $part -Force
        throw "ISO hash mismatch: expected $Sha256, got $got. File deleted."
    }
    Move-Item -LiteralPath $part -Destination $iso -Force
    return $iso
}

# Mounts the ISO and returns its drive root (E:\).
function Mount-FupIso {
    param([string]$Path)
    $img = Mount-DiskImage -ImagePath $Path -StorageType ISO -PassThru -ErrorAction Stop
    $letter = ($img | Get-Volume).DriveLetter
    if (-not $letter) { throw 'mounted ISO has no drive letter' }
    return "${letter}:\"
}

function Dismount-FupIso {
    param([string]$Path)
    try { $null = Dismount-DiskImage -ImagePath $Path -ErrorAction Stop } catch { Write-Status "Dismount failed: $_" 'WARN' }
}

# The image's version, from install.wim/esd, else from setup.exe.
function Get-FupIsoVersion {
    param([string]$Root)
    foreach ($name in @('install.wim', 'install.esd')) {
        $f = Join-Path $Root "sources\$name"
        if (Test-Path -LiteralPath $f) {
            try {
                $img = Get-WindowsImage -ImagePath $f -Index 1 -ErrorAction Stop
                if ($img.Version) { return "$($img.Version)" }
            } catch { }
        }
    }
    $setup = Join-Path $Root 'setup.exe'
    if (Test-Path -LiteralPath $setup) { return "$((Get-Item -LiteralPath $setup).VersionInfo.ProductVersion)" }
    return $null
}

# Mount, read the version, always dismount.
function Read-FupIsoVersion {
    param([string]$Iso)
    try {
        $root = Mount-FupIso $Iso
        return (Get-FupIsoVersion $root)
    } finally { Dismount-FupIso $Iso }
}

# Runs setup and returns its exit code. Always dismounts.
function Invoke-FupSetup {
    param([string]$Iso, [bool]$Bypass)
    try {
        $root = Mount-FupIso $Iso
        $setupArgs = Get-FupSetupArgs -LogDir (Join-Path $FupDir 'logs') -Bypass $Bypass
        Write-Status "setup.exe $($setupArgs -join ' ')"
        $p = Start-Process -FilePath (Join-Path $root 'setup.exe') -ArgumentList $setupArgs -PassThru -WindowStyle Hidden
        # Without a cached handle, ExitCode of a Start-Process object can come back empty.
        $null = $p.Handle
        if (-not $p.WaitForExit($FupSetupHours * 3600 * 1000)) {
            # The down-level phase changes nothing, so stopping it is safe.
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Get-Process SetupHost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            throw "setup still running after $FupSetupHours hours; stopped"
        }
        return [long]$p.ExitCode
    } finally { Dismount-FupIso $Iso }
}

function Get-FupSetupErr {
    $f = Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\Panther\setuperr.log'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    return @(Get-Content -LiteralPath $f -Tail 5 | ForEach-Object { $t = "$_".Trim(); if ($t.Length -gt 160) { $t.Substring(0, 160) } else { $t } })
}

# Copies this script into the working folder and starts it as a one-shot SYSTEM task.
function Start-FupWorker {
    param([string]$Sha256, [bool]$Bypass)
    $copy = Join-Path $FupDir 'worker.ps1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $copy -Force
    $arg = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$copy`" -Action Install -IsoSha256 $Sha256 -BypassHardwareCheck $(if ($Bypass) { 'true' } else { 'false' }) -Worker true"
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $taskAction = New-ScheduledTaskAction -Execute $ps -Argument $arg
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours ($FupSetupHours + 1)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $null = Register-ScheduledTask -TaskName $FupTaskName -Action $taskAction -Principal $principal -Settings $settings -Force
    Start-ScheduledTask -TaskName $FupTaskName
}

# Pure: quotes a value for a native command line under Windows PowerShell 5.1.
function ConvertTo-FupNativeArg {
    param([string]$Value)
    return [regex]::Replace($Value, '(\\*)"', { param($m) $m.Groups[1].Value + $m.Groups[1].Value + '\"' })
}

# Same write as the feature-update package: the agent CLI's stdin, then a read-back.
function Set-FupField {
    param([string]$Value)
    $cli = Join-Path $env:ProgramData 'NinjaRMMAgent\ninjarmm-cli.exe'
    if (Test-Path -LiteralPath $cli) {
        try {
            $null = $Value | & $cli set --stdin $FupFieldName 2>&1
            $back = (& $cli get $FupFieldName 2>$null) -join "`n"
            if ($back.Trim() -eq $Value) { return $true }
        } catch { }
    }
    if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) {
        try { Ninja-Property-Set $FupFieldName (ConvertTo-FupNativeArg $Value); return $true } catch { }
    }
    return $false
}

# Writes the field, keeps the JSON for the caller to print last, returns the exit code.
function Out-FupResult {
    param([System.Collections.Specialized.OrderedDictionary]$Result)
    $Result['timestamp'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $json = $Result | ConvertTo-Json -Depth 4 -Compress
    if (Set-FupField $json) { Write-Status "Written to $FupFieldName" }
    else { Write-Status 'Custom field not written; the JSON line below is the result' 'WARN' }
    $script:FupJson = $json
    if (@('failed', 'rolledBack', 'interrupted') -contains $Result['status']) { return 1 }
    return 0
}

function New-FupResult {
    param([string]$Status, [string]$Message)
    return [ordered]@{ status = $Status; message = $Message }
}

# Run by NinjaOne. Returns the exit code.
function Invoke-FupMain {
    param($A)
    $mutex = New-Object Threading.Mutex($false, $FupMutexName)
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { return (Out-FupResult (New-FupResult 'busy' 'another run or the upgrade worker holds the lock')) }
        Initialize-FupDir
        $build = Get-FupOsBuild
        $state = Read-FupState
        $verdict = Get-FupStateVerdict -State $state -CurrentBuild $build -LastBoot (Get-FupLastBoot) -Now (Get-Date).ToUniversalTime()
        $r = $null
        switch ($verdict) {
            'starting' { $r = New-FupResult 'starting' 'upgrade worker was started and has not taken the lock yet' }
            'staged' { $r = New-FupResult 'staged' 'upgrade staged; it finishes at the next reboot' }
            'finished' { $r = New-FupResult 'finished' "now on build $build" }
            'rolledBack' { $r = New-FupResult 'rolledBack' "rebooted after staging but still on build $build" }
            'interrupted' { $r = New-FupResult 'interrupted' 'the upgrade worker stopped without a result' }
            'failed' { $r = New-FupResult 'failed' 'the last attempt failed' }
        }
        if ($r) {
            $r['currentBuild'] = $build
            foreach ($k in @('message', 'isoBuild', 'isoVersion', 'exitCode', 'exitHex', 'time', 'setupErr')) {
                if ($state.PSObject.Properties[$k]) { $r[$k] = $state.$k }
            }
            # Terminal outcomes are reported once; the next run starts a new attempt.
            if (@('finished', 'rolledBack', 'interrupted', 'failed') -contains $verdict) {
                Write-FupState $null
                if ($verdict -eq 'finished') { Remove-Item -Path (Join-Path $FupDir '*.iso*') -Force -ErrorAction SilentlyContinue }
            }
            return (Out-FupResult $r)
        }

        if (Test-FupRebootPending) { return (Out-FupResult (New-FupResult 'rebootPending' 'Windows has a reboot pending; reboot, then run again')) }

        $iso = Join-Path $FupDir "$($A.IsoSha256).iso"
        $need = $FupMarginBytes
        if (-not (Test-Path -LiteralPath $iso)) {
            $size = Get-FupRemoteSize $A.IsoUrl
            if ($size -le 0) { $size = $FupUnknownIsoBytes }
            $part = "$iso.part"
            if (Test-Path -LiteralPath $part) { $size = [math]::Max(0, $size - (Get-Item -LiteralPath $part).Length) }
            $need += $size
        }
        $free = Get-FupFreeBytes
        if ($free -lt $need) {
            return (Out-FupResult (New-FupResult 'failed' "not enough free space: $([math]::Round($free / 1GB, 1)) GB free, $([math]::Round($need / 1GB, 1)) GB needed"))
        }

        $iso = Get-FupIso -Url $A.IsoUrl -Sha256 $A.IsoSha256
        $isoVersion = Read-FupIsoVersion $iso
        $isoBuild = ConvertTo-FupBuild $isoVersion
        if (-not $isoBuild) { throw "could not read the ISO's build (got '$isoVersion')" }
        Write-Status "ISO build $isoBuild ($isoVersion), running build $build"
        if ($isoBuild -le $build) {
            Remove-Item -LiteralPath $iso -Force -ErrorAction SilentlyContinue
            $r = New-FupResult 'alreadyCurrent' "running build $build is at or above the ISO's build $isoBuild; nothing to do"
            $r['currentBuild'] = $build; $r['isoBuild'] = $isoBuild; $r['isoVersion'] = $isoVersion
            return (Out-FupResult $r)
        }
        $now = (Get-Date).ToUniversalTime().ToString('o')
        Write-FupState ([ordered]@{ status = 'started'; time = $now; isoBuild = $isoBuild; isoVersion = $isoVersion; bypass = $A.Bypass })
        Start-FupWorker -Sha256 $A.IsoSha256 -Bypass $A.Bypass
        $r = New-FupResult 'started' 'upgrade started in the background; run again later for the result'
        $r['currentBuild'] = $build; $r['isoBuild'] = $isoBuild; $r['isoVersion'] = $isoVersion; $r['bypass'] = $A.Bypass
        return (Out-FupResult $r)
    } catch {
        Write-Status "$($_.ScriptStackTrace)" 'ERROR'
        return (Out-FupResult (New-FupResult 'failed' "$($_.Exception.Message)"))
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Run by the scheduled task. Returns the exit code.
function Invoke-FupWorker {
    param($A)
    $mutex = New-Object Threading.Mutex($false, $FupMutexName)
    $held = $false
    $state = $null
    try {
        try { $held = $mutex.WaitOne([TimeSpan]::FromMinutes(10)) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'could not take the lock' }
        $prev = Read-FupState
        $state = [ordered]@{ status = 'running'; time = (Get-Date).ToUniversalTime().ToString('o'); bypass = $A.Bypass }
        foreach ($k in @('isoBuild', 'isoVersion')) { if ($prev -and $prev.PSObject.Properties[$k]) { $state[$k] = $prev.$k } }
        Write-FupState $state
        $iso = Join-Path $FupDir "$($A.IsoSha256).iso"
        if (-not (Test-Path -LiteralPath $iso) -or (Get-FupFileHash $iso) -ne $A.IsoSha256) {
            Remove-Item -LiteralPath $iso -Force -ErrorAction SilentlyContinue
            throw 'ISO missing or hash mismatch before setup; file deleted'
        }
        $code = Invoke-FupSetup -Iso $iso -Bypass $A.Bypass
        $state.status = Get-FupSetupStatus $code
        $state.exitCode = $code
        $state.exitHex = Format-FupHex $code
        $state.time = (Get-Date).ToUniversalTime().ToString('o')
        if ($state.status -eq 'staged') {
            $state.message = 'upgrade staged; it finishes at the next reboot'
            # Setup copied what it needs to $WINDOWS.~BT.
            Remove-Item -LiteralPath $iso -Force -ErrorAction SilentlyContinue
        } else {
            $state.message = "setup exited $($state.exitHex)"
            $state.setupErr = Get-FupSetupErr
        }
    } catch {
        if (-not $state) { $state = [ordered]@{} }
        $state.status = 'failed'; $state.message = "$($_.Exception.Message)"
        $state.time = (Get-Date).ToUniversalTime().ToString('o')
    } finally {
        if ($held) {
            Write-FupState $state
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
        Unregister-ScheduledTask -TaskName $FupTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $r = [ordered]@{}
    foreach ($k in $state.Keys) { if ($k -ne 'time') { $r[$k] = $state[$k] } }
    $null = Out-FupResult $r
    if ($state['status'] -eq 'staged') { return 0 }
    return 1
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') {
    try {
        if ((Get-FupMode -Action $Action) -eq 'none') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
        $fupArgs = Get-FupArgs -IsoUrl $IsoUrl -IsoSha256 $IsoSha256 -BypassHardwareCheck $BypassHardwareCheck -WorkerMode:($Worker -eq 'true')
    } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $script:FupJson = $null
    if ($Worker -eq 'true') { $code = Invoke-FupWorker $fupArgs } else { $code = Invoke-FupMain $fupArgs }
    # Last stdout line is the JSON, so a log reader can find it.
    if ($script:FupJson) { Write-Output $script:FupJson }
    exit $code
}
