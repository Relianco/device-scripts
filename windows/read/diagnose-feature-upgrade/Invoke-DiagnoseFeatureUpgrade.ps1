<#
.SYNOPSIS
    Read-only evidence for a failed or running Windows feature upgrade.
.DESCRIPTION
    Section is Summary (default), Rollback, Servicing, Setup, Boot or Maintenance. Prints bounded JSON to stdout. Reads fixed setup/rollback/servicing logs,
    allowlisted upgrade state and registry values, current setup process names,
    OS, boot, disk and hardware. No custom-field writes, WU scans, installers,
    service changes, state deletion, or restarts. Safe to inspect a running worker.
    Each log samples at most its last 2 MiB. Matching error context and the last
    lines are retained; omitted history is explicit. Stops starting sections after
    40 seconds; each CIM request has a five-second operation timeout. Serialized UTF-8 JSON <=8,000 bytes (below the runner output cap).
    Windows PowerShell 5.1+, run as SYSTEM through the Relian deploy runner.
#>
[CmdletBinding()]
param([string]$DeploymentType, [string]$Action, [string]$PinVersion, [ValidateSet('Summary','Rollback','Servicing','Setup','Boot','Maintenance')][string]$Section = 'Summary')
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
    $patterns = @('0x80070057','0x80070005','0x20003','KB5043080','CAddCbsPackage','ERROR_ACCESS_DENIED','STATUS_CANNOT_DELETE','Current phase','Current op','Current result','Setup360','PostRebootInstall','rollback failure|fatal error','!!!')
    $hits = @{}
    $firstAccessDenied = $null
    $firstDriverError = $null
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($null -eq $firstDriverError -and $lines[$i] -match '!!!') { $firstDriverError=$i }
        if ($null -eq $firstAccessDenied -and $lines[$i] -match '0x80070005') { $firstAccessDenied=$i }
        foreach ($pattern in $patterns) { if ($lines[$i] -match $pattern) { $hits[$pattern]=$i } }
    }
    $indices = @{}
    $selectedHits=@($hits.Values)
    if ($null -ne $firstAccessDenied) { $selectedHits += $firstAccessDenied }
    if ($null -ne $firstDriverError) { $selectedHits += $firstDriverError }
    foreach ($hit in $selectedHits) {
        for ($j=[Math]::Max(0,$hit-2); $j -le [Math]::Min($lines.Count-1,$hit+2); $j++) { $indices[$j]=$true }
    }
    $context = @($indices.Keys | Sort-Object | ForEach-Object { $lines[$_] })
    $r.Remove('text')
    $r.matches = @(Limit-DiagnosticLines -Lines $context)
    $r.tail = @(Limit-DiagnosticLines -Lines @($lines | Select-Object -Last 5) -MaxChars 2400)
    return $r
}

function Read-DiagnosticFileMetadata {
    param([string]$Path)
    try {
        $file=[IO.FileInfo]::new($Path)
        if (-not $file.Exists) { return @{status='missing'} }
        return @{status='present';sizeBytes=$file.Length;lastWriteUtc=$file.LastWriteTimeUtc.ToString('o')}
    } catch { return @{status='unavailable';error=$_.Exception.GetType().Name} }
}

function Read-DiagnosticBootEvents {
    try {
        $since=[datetime]::UtcNow.AddHours(-72).ToString('yyyyMMddHHmmss.000000+000')
        $filter="Logfile='System' AND TimeGenerated >= '$since' AND ((EventCode=41 AND SourceName='Microsoft-Windows-Kernel-Power') OR (EventCode=1001 AND SourceName='Microsoft-Windows-WER-SystemErrorReporting') OR (EventCode=6008 AND SourceName='EventLog'))"
        $events=@(Get-CimInstance -ClassName Win32_NTLogEvent -Filter $filter -Property TimeGenerated,SourceName,EventCode,Message -OperationTimeoutSec 5 -ErrorAction Stop | Sort-Object TimeGenerated -Descending | Select-Object -First 8)
        $safe=@(foreach ($event in $events) {
            [ordered]@{timestamp=$event.TimeGenerated.ToUniversalTime().ToString('o');source=Protect-DiagnosticText ([string]$event.SourceName) -Max 100;id=[int]$event.EventCode;message=Protect-DiagnosticText ([string]$event.Message) -Max 500}
        })
        return @{status='collected';windowHours=72;limit=8;events=$safe}
    } catch { return @{status='unavailable';error=$_.Exception.GetType().Name} }
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

# References to long text fields, allowing measured JSON-budget reductions without
# replacing the entire report (and losing its state/error evidence).
function Get-DiagnosticTextLeaves {
    param($Value)
    if ($Value -is [Collections.IDictionary]) { $keys=@($Value.Keys) }
    elseif ($Value -is [array]) { $keys=@(0..($Value.Count-1)); if (-not $Value.Count) { return } }
    else { return }
    foreach ($key in $keys) {
        $item=$Value[$key]
        if ($item -is [string]) {
            if ($item.Length -gt 64) {
                [pscustomobject]@{Container=$Value;Key=$key;Text=$item}
            }
        } else { Get-DiagnosticTextLeaves $item }
    }
}

function ConvertTo-BoundedDiagnosticJson {
    param($Report, [int]$MaxBytes = 8000)
    $Report['truncated'] = $false
    $json = $Report | ConvertTo-Json -Depth 8 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -le $MaxBytes) { return $json }
    $Report['truncated'] = $true
    # Targeted matches outrank generic tails; metadata is always serialized first.
    foreach ($log in @($Report.logs)) {
        if ($log.Contains('tail') -and $log.tail.Count) { $log.tail=@(); $log.tailOmitted=$true }
    }
    $json = $Report | ConvertTo-Json -Depth 8 -Compress
    while ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxBytes) {
        # Reduce log text before touching Summary failure details/current state.
        $leaf = Get-DiagnosticTextLeaves $Report.logs | Sort-Object { $_.Text.Length } -Descending | Select-Object -First 1
        if (-not $leaf) {
            foreach ($optional in @('notes','cpu','tpm','disk','secureBoot','processes','moSetup')) {
                if ($Report.Contains($optional)) { $Report.Remove($optional) }
            }
            $json = $Report | ConvertTo-Json -Depth 8 -Compress
            if ([Text.Encoding]::UTF8.GetByteCount($json) -le $MaxBytes) { return $json }
            $leaf = Get-DiagnosticTextLeaves $Report | Sort-Object { $_.Text.Length } -Descending | Select-Object -First 1
        }
        if ($leaf) {
            $limit=[Math]::Max(32,[int]($leaf.Text.Length/2))
            $head=[int][Math]::Floor($limit/2)
            # Servicing lines often put the HRESULT at the end. Keep both ends.
            $leaf.Container[$leaf.Key]=$leaf.Text.Substring(0,$head)+'[clipped]'+$leaf.Text.Substring($leaf.Text.Length-($limit-$head))
        } elseif ($Report.logs.Count) {
            # Only possible for a structurally large collection after all strings
            # are small. Preserve metadata and record which section was omitted.
            $Report.logs=@($Report.logs | Select-Object -First ($Report.logs.Count-1))
            $Report['logsOmitted']=$true
        } else {
            throw 'Diagnostic metadata exceeds the output budget.'
        }
        $json = $Report | ConvertTo-Json -Depth 8 -Compress
    }
    return $json
}

# Query only status properties for the system volume. Do not enumerate key
# protectors or call any recovery-password, unlock, suspend or encryption method.
function Read-DiagnosticBitLocker {
    param([string]$SystemDrive)
    try {
        # Microsoft's Properties section lists ConversionStatus and VolumeType
        # (read-only uint32), although its abbreviated Syntax block omits them:
        # https://learn.microsoft.com/en-us/windows/win32/secprov/win32-encryptablevolume#properties
        $volumes=@(Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$SystemDrive'" -Property ConversionStatus,ProtectionStatus,VolumeType -OperationTimeoutSec 5 -ErrorAction Stop)
        if ($volumes.Count -ne 1) { return @{status='unavailable';reason='systemVolumeNotFoundOrAmbiguous'} }
        $volume=$volumes[0]
        $result=[ordered]@{encryptionStatus='Unknown';protectionStatus='Unknown';lockStatus='Unknown';volumeType='Unknown'}
        $maps=@(
            @{Field='encryptionStatus';Property='ConversionStatus';Values=@{'0'='FullyDecrypted';'1'='FullyEncrypted';'2'='EncryptionInProgress';'3'='DecryptionInProgress';'4'='EncryptionPaused';'5'='DecryptionPaused'}},
            @{Field='protectionStatus';Property='ProtectionStatus';Values=@{'0'='Off';'1'='On';'2'='Unknown'}},
            @{Field='volumeType';Property='VolumeType';Values=@{'0'='OperatingSystem';'1'='FixedData';'2'='RemovableData'}}
        )
        foreach ($map in $maps) {
            $property=$volume.PSObject.Properties[$map.Property]
            if ($property -and $null -ne $property.Value -and $map.Values.ContainsKey([string]$property.Value)) { $result[$map.Field]=$map.Values[[string]$property.Value] }
        }
        try {
            $lock=Invoke-CimMethod -InputObject $volume -MethodName GetLockStatus -OperationTimeoutSec 5 -ErrorAction Stop
            if ($lock.PSObject.Properties['ReturnValue'] -and $null -ne $lock.ReturnValue -and $lock.ReturnValue -eq 0 -and $lock.PSObject.Properties['LockStatus']) {
                if ($null -ne $lock.LockStatus -and $lock.LockStatus -eq 0) { $result.lockStatus='Unlocked' }
                elseif ($lock.LockStatus -eq 1) { $result.lockStatus='Locked' }
            }
        } catch { } # Access/provider failures remain Unknown, without exception text.
        return $result
    } catch { return @{status='unavailable';error=$_.Exception.GetType().Name} }
}

# Numeric-only registry values: unknown names are listed, their values are never read.
function Read-DiagnosticNumericRegistry {
    param([string]$Path,[string[]]$Names,[switch]$ListUnknown)
    try {
        $key=Get-Item -LiteralPath $Path -ErrorAction Stop
        $all=@($key.GetValueNames())
        $values=[ordered]@{}
        foreach($name in $Names) {
            if($all -contains $name) {
                $value=$key.GetValue($name)
                if($value -is [ValueType] -and [string]$value -match '^-?\d{1,19}$') {
                    try { $values[$name]=[long]$value } catch { $values[$name]='invalidNumeric' }
                } elseif($value -is [string] -and $value -match '^\d{1,12}$') { $values[$name]=[long]$value }
                else { $values[$name]='nonNumericOmitted' }
            }
        }
        $result=[ordered]@{status='read';values=$values}
        if($ListUnknown) {
            $unknown=@($all | Where-Object { $_ -notin $Names })
            $result.unknownNames=@($unknown | Select-Object -First 12 | ForEach-Object { Protect-DiagnosticText ([string]$_) -Max 64 })
            $result.unknownCount=$unknown.Count
        }
        return $result
    } catch { return @{status='unavailable';error=$_.Exception.GetType().Name} }
}

# Windows Setup completion evidence from fixed locations; unknown states stay opaque.
function Read-DiagnosticImageState {
    param([switch]$Ini)
    $allowed=@('IMAGE_STATE_COMPLETE','IMAGE_STATE_UNDEPLOYABLE','IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE','IMAGE_STATE_GENERALIZE_RESEAL_TO_AUDIT','IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE','IMAGE_STATE_SPECIALIZE_RESEAL_TO_AUDIT')
    try {
        if($Ini) {
            $read=Read-DiagnosticBytes (Join-Path $env:SystemRoot 'Setup\State\State.ini') -MaxBytes 4096 -FromStart
            if($read.status -ne 'read') { return $read }
            if($read.truncated) { return @{status='oversize'} }
            $match=[regex]::Match($read.text,'(?im)^\s*ImageState\s*=\s*([^\r\n]+)')
            if(-not $match.Success) { return @{status='missingValue'} }
            $state=$match.Groups[1].Value.Trim()
            if($state.Length -ge 2 -and $state[0] -eq [char]34 -and $state[$state.Length-1] -eq [char]34) { $state=$state.Substring(1,$state.Length-2) }
        } else {
            $path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'
            if(-not (Test-Path -LiteralPath $path -ErrorAction Stop)) { return @{status='missing'} }
            $value=Get-ItemProperty -LiteralPath $path -ErrorAction Stop
            if(-not $value.PSObject.Properties['ImageState']) { return @{status='missingValue'} }
            $state=[string]$value.ImageState
        }
        if($state -notin $allowed) { return @{status='unknownValueOmitted'} }
        return @{status='read';value=$state}
    } catch { return @{status='unavailable';error=$_.Exception.GetType().Name} }
}

function Read-DiagnosticMaintenance {
    param($Clock)
    $r=[ordered]@{logs=@();notes=@('Read-only guard inputs; this report does not establish that servicing is safe or change maintenance guards.')}
    $r.imageState=@{registry=(Read-DiagnosticImageState);ini=(Read-DiagnosticImageState -Ini)}
    $r.os=Read-DiagnosticNumericRegistry 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' @('CurrentBuild','UBR','InstallDate')
    $r.setup=Read-DiagnosticNumericRegistry 'HKLM:\SYSTEM\Setup' @('SystemSetupInProgress','OOBEInProgress','SetupPhase','SetupType','RestartSetup')
    $r.moSetup=Read-DiagnosticNumericRegistry 'HKLM:\SYSTEM\Setup\MoSetup\Volatile' @('SetupHostResult','SetupHostError','SetupPhase','SetupSubPhase','SetupProgress','BoxResult','InstallScenario','DownlevelBuildNumber') -ListUnknown
    $r.sourceOS=@()
    try {
        $keys=@(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop | Where-Object { $_.PSChildName -like 'Source OS*' } | Select-Object -First 9)
        $r.sourceOSTruncated=$keys.Count -gt 8
        foreach($key in @($keys | Select-Object -First 8)) {
            if($Clock.Elapsed.TotalSeconds -gt 40) { $r.sourceOS+=@{status='timeBudget'}; break }
            $r.sourceOS+=Read-DiagnosticNumericRegistry $key.PSPath @('CurrentBuild','UBR','InstallDate')
        }
    } catch { $r.sourceOS=@(@{status='unavailable';error=$_.Exception.GetType().Name}) }
    $r.pendingReboot=[ordered]@{}
    foreach($entry in @(
        @('cbs','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'),
        @('windowsUpdate','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))) {
        try { $r.pendingReboot[$entry[0]]=Test-Path -LiteralPath $entry[1] -ErrorAction Stop } catch { $r.pendingReboot[$entry[0]]='unknown' }
    }
    try {
        $session=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        $renames=@(); if($session.PSObject.Properties['PendingFileRenameOperations']) { $renames=@($session.PendingFileRenameOperations | Where-Object { $null -ne $_ }) }
        $r.pendingReboot.renameEntryCount=$renames.Count
        $r.pendingReboot.renamePaths=@($renames | Select-Object -First 4 | ForEach-Object { Protect-DiagnosticText ([string]$_) -Max 160 })
        $r.pendingReboot.renamePathsTruncated=$renames.Count -gt 4
    } catch { $r.pendingReboot.renames='unknown' }
    $r.staging=@()
    foreach($name in @('$WINDOWS.~BT','$WINDOWS.~WS')) {
        try {
            $path=Join-Path $env:SystemDrive $name
            if(Test-Path -LiteralPath $path -ErrorAction Stop) {
                $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
                $r.staging+=@{name=$name;exists=$true;createdUtc=$item.CreationTimeUtc.ToString('o');ordinaryDirectory=($item.PSIsContainer -and (($item.Attributes -band 5120) -eq 0))}
            } else { $r.staging+=@{name=$name;exists=$false} }
        } catch { $r.staging+=@{name=$name;status='unavailable'} }
    }
    $r.nativeMarkers=[ordered]@{}
    foreach($relative in @('RelianMaintenance\native-active.json','Relian\Maintenance\native-active.json')) {
        try { $r.nativeMarkers[$relative]=Test-Path -LiteralPath (Join-Path $env:ProgramData $relative) -ErrorAction Stop } catch { $r.nativeMarkers[$relative]='unknown' }
    }
    # Existing bounded, allowlisted state reader excludes command lines and download URLs.
    $r.state=Read-DiagnosticState (Join-Path $env:ProgramData 'Relian\FeatureUpgrade\state.json')
    foreach($field in @('message','setupErr')) { $r.state.Remove($field) }
    foreach($probe in @('boot','processes')) {
        if($Clock.Elapsed.TotalSeconds -gt 40) { $r[$probe]=@{status='timeBudget'}; continue }
        try {
            if($probe -eq 'boot') { $r.boot=(Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o') }
            else {
                $rows=@(Get-CimInstance Win32_Process -Filter "Name='setup.exe' OR Name='setuphost.exe' OR Name='setupprep.exe' OR Name='dism.exe' OR Name='sfc.exe' OR Name='TiWorker.exe' OR Name='TrustedInstaller.exe' OR Name='msiexec.exe'" -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -First 21)
                $r.processesTruncated=$rows.Count -gt 20
                $r.processes=@($rows | Select-Object -First 20 | ForEach-Object {
                    $row=[ordered]@{name=Protect-DiagnosticText ([string]$_.Name) -Max 32;pid=[long]$_.ProcessId;createdUtc=$null;cpuSeconds=$null;executablePath=$null;parentProcessId=$null;sessionId=$null}
                    # Existing CIM row only: never read a command line or query a parent.
                    try { if($_.PSObject.Properties['ExecutablePath'] -and $_.ExecutablePath) { $row.executablePath=Protect-DiagnosticText ([string]$_.ExecutablePath) -Max 160 } } catch { }
                    foreach($field in @('ParentProcessId','SessionId')) {
                        try {
                            if($_.PSObject.Properties[$field] -and $null -ne $_.$field -and [string]$_.$field -match '^\d{1,10}$' -and [long]$_.$field -le [uint32]::MaxValue) { $row[$field]=[long]$_.$field }
                        } catch { }
                    }
                    if($_.CreationDate) { $row.createdUtc=([datetime]$_.CreationDate).ToUniversalTime().ToString('o') }
                    if($_.PSObject.Properties['KernelModeTime'] -and $_.PSObject.Properties['UserModeTime']) { $row.cpuSeconds=[Math]::Round(([double]$_.KernelModeTime+[double]$_.UserModeTime)/10000000,2) }
                    $row
                })
            }
        } catch { $r[$probe]=@{status='unavailable';error=$_.Exception.GetType().Name} }
    }
    return $r
}

function Invoke-FeatureUpgradeDiagnostic {
    param([ValidateSet('Summary','Rollback','Servicing','Setup','Boot','Maintenance')][string]$Section = 'Summary')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $report = [ordered]@{ version='5'; timestamp=[datetime]::UtcNow.ToString('o'); status='collected'; section=$Section }
    if($Section -eq 'Maintenance') {
        $data=Read-DiagnosticMaintenance $clock
        foreach($key in $data.Keys) { $report[$key]=$data[$key] }
        $report.elapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,1)
        return ConvertTo-BoundedDiagnosticJson $report
    }
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
    $probeSections = if ($Section -eq 'Summary') { @('boot','bitLocker','disk','processes','cpu','tpm') } else { @('boot') }
    foreach ($probe in $probeSections) {
        if ($clock.Elapsed.TotalSeconds -gt 40) { $report[$probe]=@{status='timeBudget'}; continue }
        try {
            switch ($probe) {
                'boot' { $report.boot = (Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o') }
                'bitLocker' { $report.bitLocker=Read-DiagnosticBitLocker -SystemDrive $drive }
                'disk' { $report.disk = @(Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'" -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object DeviceID,Size,FreeSpace) }
                'processes' { $report.processes = @(Get-CimInstance Win32_Process -Filter "Name='setup.exe' OR Name='setuphost.exe' OR Name='setupprep.exe' OR Name='dism.exe' OR Name='TiWorker.exe' OR Name='TrustedInstaller.exe'" -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -First 20 Name,ProcessId,CreationDate) }
                'cpu' { $report.cpu = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -First 2 Name,AddressWidth,NumberOfCores) }
                'tpm' { $report.tpm = @(Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftTpm' -ClassName Win32_Tpm -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object SpecVersion,IsEnabled_InitialValue,IsActivated_InitialValue) }
            }
        } catch { $report[$probe]=@{status='unavailable';error=$_.Exception.GetType().Name} }
    }
    # Fixed paths only, no recursive walks or archive extraction. Rollback and
    # offline-image servicing are first because they explain Safe OS failures.
    $paths = @(
        # Microsoft documents both flat and nested supplemental driver log locations.
        @('rollback-drivers', (Join-Path $bt 'Sources\Rollback\setupapi\setupapi.dev.log')),
        @('rollback-drivers-flat', (Join-Path $bt 'Sources\Rollback\setupapi.dev.log')),
        @('windows-drivers', (Join-Path $win 'INF\setupapi.dev.log')),
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
    $labels = switch ($Section) {
        'Summary' { @() }
        'Boot' { @('rollback-drivers','rollback-drivers-flat','windows-drivers') }
        'Rollback' { @('rollback-errors','rollback-actions') }
        'Servicing' { @('newos-cbs','newos-dism','host-cbs','host-dism') }
        'Setup' { @('panther-errors','panther-actions','windows-panther-errors','windows-panther-actions','mosetup') }
    }
    if ($Section -ne 'Summary') {
        foreach ($key in @('FailureData','FailureDetails','LastSetupOperation')) { $report.setupDiag.Remove($key) }
        foreach ($key in @('message','setupErr')) { $report.state.Remove($key) }
    }
    if ($Section -eq 'Boot') {
        # Dump metadata only: never open, hash or parse its contents.
        $report.setupMemoryDump=Read-DiagnosticFileMetadata (Join-Path $bt 'Sources\Rollback\setupmem.dmp')
        $report.bootEvents=if ($clock.Elapsed.TotalSeconds -gt 40) { @{status='timeBudget'} } else { Read-DiagnosticBootEvents }
    }
    $report.logs=@()
    foreach ($p in @($paths | Where-Object { $_[0] -in $labels })) {
        if ($clock.Elapsed.TotalSeconds -gt 40) { $entry=@{status='timeBudget'} }
        else { $entry=Read-DiagnosticLog $p[1] }
        $entry.label=$p[0]; $report.logs += $entry
    }
    $report.elapsedSeconds = [Math]::Round($clock.Elapsed.TotalSeconds,1)
    $report.notes = @('Logs sample only their final 2 MiB; older history may be omitted.', 'Matching context: 0x80070057, 0x80070005, 0x20003, KB5043080, CAddCbsPackage, ERROR_ACCESS_DENIED, STATUS_CANNOT_DELETE, Current phase/op/result, Setup360, PostRebootInstall, rollback/fatal failures, !!! driver errors.', 'No changes made. Setup and servicing may continue while this report is collected.')
    return ConvertTo-BoundedDiagnosticJson $report
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if ($Action -eq 'Uninstall') { Write-Output '{"status":"nothingToUninstall"}'; exit 0 }
if (@('Install','Update','Repair','Reinstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
try { Write-Output (Invoke-FeatureUpgradeDiagnostic -Section $Section); exit 0 }
catch { Write-Output ('{"status":"failed","error":"' + $_.Exception.GetType().Name + '"}'); exit 1 }
