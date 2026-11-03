<#
.SYNOPSIS
    Read-only evidence for a failed or running Windows feature upgrade.
.DESCRIPTION
    Prints bounded JSON to stdout. Reads fixed setup/rollback/servicing logs,
    allowlisted upgrade state and registry values, current setup process names,
    OS, boot, disk and hardware. No custom-field writes, WU scans, installers,
    service changes, state deletion, or restarts. Safe to inspect a running worker.
    Each log samples at most its last 2 MiB. Matching error context and the last
    lines are retained; omitted history is explicit. Stops starting sections after
    40 seconds; each CIM request has a five-second operation timeout. JSON <=40KB.
    Windows PowerShell 5.1+, run as SYSTEM through the Relian deploy runner.
#>
[CmdletBinding()]
param([string]$DeploymentType, [string]$Action, [string]$PinVersion)
$ProgressPreference = 'SilentlyContinue'

function Protect-DiagnosticText {
    param([string]$Text, [int]$Max = 1200)
    # Setup logs can echo arguments, URLs, credentials and profile paths. Never
    # print a line containing credential/command-line markers, even when clipped.
    if ($Text -match '(?i)password|passwd|\bpwd\s*=|secret|token|authorization|bearer|credential|api.?key|accountkey|product.?key|command.?line') { return '[sensitive line omitted]' }
    $t = $Text -replace '(?i)[a-z][a-z0-9+.-]*://\S+', '[url omitted]'
    $t = $t -replace '(?i)([a-z]:\\Users\\)[^\\\s]+', '$1[redacted]'
    $t = ($t -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '[clipped]' }
    return $t
}

function Read-DiagnosticBytes {
    param([string]$Path, [int]$MaxBytes = 2097152, [switch]$FromStart)
    if (-not [IO.File]::Exists($Path)) { return @{ status='missing' } }
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $length = $stream.Length
        $bom = New-Object byte[] 3
        $null = $stream.Read($bom, 0, 3)
        $unicode = $bom[0] -eq 255 -and $bom[1] -eq 254
        $bigEndian = $bom[0] -eq 254 -and $bom[1] -eq 255
        $start = if ($FromStart) { 0L } else { [Math]::Max(0L, $length - $MaxBytes) }
        if (($unicode -or $bigEndian) -and $start % 2) { $start++ }
        $null = $stream.Seek($start, [IO.SeekOrigin]::Begin)
        $count = [int][Math]::Min([long]$MaxBytes, $length - $start)
        $bytes = New-Object byte[] $count
        $read = 0
        while ($read -lt $count) {
            $n = $stream.Read($bytes, $read, $count - $read)
            if ($n -eq 0) { break }
            $read += $n
        }
        $encoding = if ($unicode) { [Text.Encoding]::Unicode } elseif ($bigEndian) { [Text.Encoding]::BigEndianUnicode } else { [Text.Encoding]::UTF8 }
        $text = $encoding.GetString($bytes, 0, $read).TrimStart([char]0xFEFF)
        # A seek may begin midway through a record; never return that partial line.
        if ($start -gt 0) { $nl = $text.IndexOf("`n"); $text = if ($nl -ge 0) { $text.Substring($nl + 1) } else { '' } }
        return @{ status='read'; text=$text; sizeBytes=$length; sampledBytes=$read; truncated=($length -gt $read); lastWriteUtc=[IO.File]::GetLastWriteTimeUtc($Path).ToString('o') }
    } catch { return @{ status='unavailable'; error=$_.Exception.GetType().Name } }
    finally { if ($stream) { $stream.Dispose() } }
}

function Limit-DiagnosticLines {
    param([string[]]$Lines, [int]$MaxChars = 4500)
    $out = [Collections.Generic.List[string]]::new()
    $used = 0
    foreach ($line in $Lines) {
        $safe = Protect-DiagnosticText $line
        if ($used + $safe.Length -gt $MaxChars) { $out.Add('[section clipped]'); break }
        $out.Add($safe); $used += $safe.Length
    }
    return $out.ToArray()
}

function Read-DiagnosticLog {
    param([string]$Path, [int]$MaxBytes = 2097152)
    $r = Read-DiagnosticBytes -Path $Path -MaxBytes $MaxBytes
    if ($r.status -ne 'read') { return $r }
    $lines = @($r.text -split '\r?\n' | Where-Object { $_.Trim() })
    # Keep the latest hit in each category, not just the final generic errors:
    # repeated HRESULT summaries must not hide the earlier package-add failure.
    $patterns = @('0x80070057','0x20003','KB5043080','CAddCbsPackage','rollback failure|fatal error')
    $hits = @{}
    for ($i=0; $i -lt $lines.Count; $i++) {
        foreach ($pattern in $patterns) { if ($lines[$i] -match $pattern) { $hits[$pattern]=$i } }
    }
    $indices = @{}
    foreach ($hit in $hits.Values) {
        for ($j=[Math]::Max(0,$hit-2); $j -le [Math]::Min($lines.Count-1,$hit+2); $j++) { $indices[$j]=$true }
    }
    $context = @($indices.Keys | Sort-Object | ForEach-Object { $lines[$_] })
    $r.Remove('text')
    $r.matches = @(Limit-DiagnosticLines -Lines $context)
    $r.tail = @(Limit-DiagnosticLines -Lines @($lines | Select-Object -Last 5) -MaxChars 2400)
    return $r
}

function Read-DiagnosticState {
    param([string]$Path)
    $r = Read-DiagnosticBytes -Path $Path -MaxBytes 32768 -FromStart
    if ($r.status -ne 'read') { return $r }
    if ($r.truncated) { return @{ status='oversize'; sizeBytes=$r.sizeBytes } }
    try {
        $state = $r.text | ConvertFrom-Json -ErrorAction Stop
        $out = [ordered]@{}
        foreach ($key in @('status','time','timestamp','currentBuild','isoBuild','isoVersion','exitCode','exitHex','message','setupErr','bypass')) {
            if ($state.PSObject.Properties[$key]) { $out[$key] = Protect-DiagnosticText ([string]$state.$key) -Max 2000 }
        }
        return $out
    } catch { return @{status='invalidJson'} }
}

function Read-DiagnosticRegistry {
    param([string]$Path, [string[]]$Names)
    try {
        $v = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        $r = [ordered]@{}
        foreach ($name in $Names) {
            if ($v.PSObject.Properties[$name]) { $r[$name] = Protect-DiagnosticText ([string]$v.$name) -Max 2000 }
        }
        return $r
    } catch { return @{status='unavailable';error=$_.Exception.GetType().Name} }
}

function ConvertTo-BoundedDiagnosticJson {
    param($Report, [int]$MaxBytes = 40000)
    $Report['truncated'] = $false
    $json = $Report | ConvertTo-Json -Depth 8 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -le $MaxBytes) { return $json }
    $Report['truncated'] = $true
    # Logs are priority ordered. Discard lower-priority sections explicitly first.
    for ($i=$Report.logs.Count-1; $i -ge 0; $i--) {
        $Report.logs[$i] = @{status='omittedForOutputLimit'; label=$Report.logs[$i].label}
        $json = $Report | ConvertTo-Json -Depth 8 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($json) -le $MaxBytes) { return $json }
    }
    return '{"status":"outputLimit","truncated":true}'
}

function Invoke-FeatureUpgradeDiagnostic {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $report = [ordered]@{ version='1'; timestamp=[datetime]::UtcNow.ToString('o'); status='collected'; logs=@(); notes=@() }
    $win = $env:SystemRoot
    $drive = $env:SystemDrive
    $fup = Join-Path $env:ProgramData 'Relian\FeatureUpgrade'
    $bt = Join-Path $drive '$WINDOWS.~BT'
    $report.state = Read-DiagnosticState (Join-Path $fup 'state.json')
    $report.setupDiag = Read-DiagnosticRegistry 'HKLM:\SYSTEM\Setup\SetupDiag\Results' @('ProfileName','DateTime','FailureData','FailureDetails','LastSetupOperation','UpgradeStartTime','UpgradeEndTime','TargetOSBuildString')
    $report.moSetup = Read-DiagnosticRegistry 'HKLM:\SYSTEM\Setup\MoSetup\Volatile' @('SetupPhase','SetupSubPhase','SetupProgress','SetupHostResult','BoxResult','InstallScenario')
    $report.os = Read-DiagnosticRegistry 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' @('CurrentBuild','UBR','DisplayVersion','EditionID')
    $report.secureBoot = Read-DiagnosticRegistry 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' @('UEFISecureBootEnabled')
    # No process command lines: these can contain credentials or private URLs.
    foreach ($section in @('boot','disk','processes','cpu','tpm')) {
        if ($clock.Elapsed.TotalSeconds -gt 40) { $report[$section]=@{status='timeBudget'}; continue }
        try {
            switch ($section) {
                'boot' { $report.boot = (Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o') }
                'disk' { $report.disk = @(Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'" -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object DeviceID,Size,FreeSpace) }
                'processes' { $report.processes = @(Get-CimInstance Win32_Process -Filter "Name='setup.exe' OR Name='setuphost.exe' OR Name='setupprep.exe' OR Name='dism.exe' OR Name='TiWorker.exe' OR Name='TrustedInstaller.exe'" -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -First 20 Name,ProcessId,CreationDate) }
                'cpu' { $report.cpu = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -First 2 Name,AddressWidth,NumberOfCores) }
                'tpm' { $report.tpm = @(Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftTpm' -ClassName Win32_Tpm -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object SpecVersion,IsEnabled_InitialValue,IsActivated_InitialValue) }
            }
        } catch { $report[$section]=@{status='unavailable';error=$_.Exception.GetType().Name} }
    }
    # Fixed paths only, no recursive walks or archive extraction. Rollback and
    # offline-image servicing are first because they explain Safe OS failures.
    $paths = @(
        @('rollback-errors', (Join-Path $bt 'Sources\Rollback\setuperr.log')),
        @('newos-cbs', (Join-Path $bt 'NewOS\Windows\Logs\CBS\CBS.log')),
        @('newos-dism', (Join-Path $bt 'NewOS\Windows\Logs\DISM\dism.log')),
        @('rollback-actions', (Join-Path $bt 'Sources\Rollback\setupact.log')),
        @('panther-errors', (Join-Path $bt 'Sources\Panther\setuperr.log')),
        @('panther-actions', (Join-Path $bt 'Sources\Panther\setupact.log')),
        @('windows-panther-errors', (Join-Path $win 'Panther\setuperr.log')),
        @('windows-panther-actions', (Join-Path $win 'Panther\setupact.log')),
        @('host-cbs', (Join-Path $win 'Logs\CBS\CBS.log')),
        @('host-dism', (Join-Path $win 'Logs\DISM\dism.log')),
        @('mosetup', (Join-Path $win 'Logs\MoSetup\BlueBox.log'))
    )
    foreach ($p in $paths) {
        if ($clock.Elapsed.TotalSeconds -gt 40) { $entry=@{status='timeBudget'} }
        else { $entry=Read-DiagnosticLog $p[1] }
        $entry.label=$p[0]; $report.logs += $entry
    }
    $report.elapsedSeconds = [Math]::Round($clock.Elapsed.TotalSeconds,1)
    $report.notes = @('Logs sample only their final 2 MiB; older history may be omitted.', 'Matching context: 0x80070057, 0x20003, KB5043080, CAddCbsPackage, rollback/fatal failures.', 'No changes made. Setup and servicing may continue while this report is collected.')
    return ConvertTo-BoundedDiagnosticJson $report
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if ($Action -eq 'Uninstall') { Write-Output '{"status":"nothingToUninstall"}'; exit 0 }
if (@('Install','Update','Repair','Reinstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
try { Write-Output (Invoke-FeatureUpgradeDiagnostic); exit 0 }
catch { Write-Output ('{"status":"failed","error":"' + $_.Exception.GetType().Name + '"}'); exit 1 }
