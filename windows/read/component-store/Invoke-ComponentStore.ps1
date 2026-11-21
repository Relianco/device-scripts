<#
.SYNOPSIS
    Read-only component store (WinSxS) report: DISM CheckHealth, a CBS.log summary, Windows Update failure events,
    build and pending-restart state, and the last run of the component-store-repair package.
.DESCRIPTION
    Works on Windows Server 2016 to 2025 and Windows 10 and 11. Everything it reads is language-neutral: registry values,
    the image health enum from Repair-WindowsImage, CBS.log (Windows writes it in English on every locale) and the
    named errorCode field of Windows Update client events 20 (install failed) and 31 (download failed) in the System log.
    - checkHealth: Repair-WindowsImage -Online -CheckHealth (DISM /CheckHealth). It reads the flag a previous scan left
      and changes nothing. Skipped while dism.exe runs (it would wait on the servicing lock); stopped after 45 seconds.
    - cbs: the last 16 MiB of CBS.log. Corruption rows a ScanHealth or RestoreHealth wrote ("(p)" rows; (n) is not
      repaired), the last "Total Detected/Repaired Corruption" totals, the 10 most frequent HRESULT codes with their
      symbolic name when the log gives one and the last time seen, and the last three Error lines.
    - wu: events 20 and 31 grouped by event id and error code with counts, first and last time and the newest KB numbers.
    - worker: state.json of the component-store-repair package (Scan, Repair or InstallMsu), when it has run.
    It never runs ScanHealth, RestoreHealth, SFC or an install, and writes no file, registry value or field.
    Prints one JSON line of at most 7,600 UTF-8 bytes; lists are trimmed to fit and the report says so.
    Windows PowerShell 5.1+, run as SYSTEM by the Relian read-job loader, which kills it after 120 seconds.
#>
[CmdletBinding()]
param([string]$DeploymentType, [string]$Action, [string]$PinVersion)
$ProgressPreference = 'SilentlyContinue'

$script:OutputMaxBytes = 7600
$script:CbsTailBytes = 16MB
$script:HealthSeconds = 45
$script:CodeRx = [regex]::new('\b(0x[8cC][0-9a-fA-F]{7})\b(?:\s*-\s*([A-Z][A-Z0-9_]{2,}))?')
$script:RowRx = [regex]::new('\(p\)\s+((?:CSI|CBS)[A-Za-z ]*?(?:Corrupt|Missing|Mismatch|Bad)[A-Za-z ]*?)\s+\(([a-z])\)\s+([^\t\r\n]+)')
$script:TimeRx = [regex]::new('\A(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)')
$script:CvKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$script:StatePath = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\ComponentStore\state.json'

# Seams. Tests replace them; the defaults read the real machine.
$script:CsRegValue = { param($Key, $Name) try { (Get-ItemProperty -LiteralPath $Key -Name $Name -ErrorAction Stop).$Name } catch { $null } }
$script:CsKeyExists = { param($Key) Test-Path -LiteralPath $Key }
$script:CsRenames = { @(& $script:CsRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations' | Where-Object { $_ }).Count }
$script:CsDismBusy = { [bool](Get-Process -Name 'dism', 'DismHost' -ErrorAction SilentlyContinue) }
$script:CsFreeGB = { [math]::Round(([IO.DriveInfo]::new($env:SystemDrive)).AvailableFreeSpace / 1GB, 1) }
$script:CsCheckHealth = {
    $ps = [powershell]::Create()
    [void]$ps.AddCommand('Repair-WindowsImage').AddParameter('Online').AddParameter('CheckHealth')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $handle = $ps.BeginInvoke()
    # Not disposed on timeout: Dispose waits for the pipeline. The loader ends the process anyway.
    if (-not $handle.AsyncWaitHandle.WaitOne(1000 * $script:HealthSeconds)) { [void]$ps.BeginStop($null, $null); return [ordered]@{ state = 'timeout'; error = $null; seconds = $script:HealthSeconds } }
    try {
        $out = @($ps.EndInvoke($handle))
        $err = if ($ps.Streams.Error.Count) { '0x' + ([uint32]($ps.Streams.Error[0].Exception.HResult -band 0xFFFFFFFFL)).ToString('x8') } else { $null }
        $state = if ($out.Count -and $out[0].PSObject.Properties['ImageHealthState']) { [string]$out[0].ImageHealthState } else { 'unknown' }
        return [ordered]@{ state = $state; error = $err; seconds = [int]$clock.Elapsed.TotalSeconds }
    } catch {
        return [ordered]@{ state = 'failed'; error = '0x' + ([uint32]($_.Exception.HResult -band 0xFFFFFFFFL)).ToString('x8'); seconds = [int]$clock.Elapsed.TotalSeconds }
    } finally { $ps.Dispose() }
}
# The tail of CBS.log, read shared (TrustedInstaller keeps it open). The first, partial line is dropped.
$script:CsCbsLines = {
    $file = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
    if (-not [IO.File]::Exists($file)) { return @() }
    $fs = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    try {
        $skip = [math]::Max(0L, $fs.Length - $script:CbsTailBytes)
        [void]$fs.Seek($skip, [IO.SeekOrigin]::Begin)
        $text = [IO.StreamReader]::new($fs).ReadToEnd()
    } finally { $fs.Dispose() }
    $lines = $text -split "\r?\n"
    if ($skip -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
    return $lines
}
$script:CsEvents = {
    $raw = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 20, 31 } -MaxEvents 2000 -ErrorAction SilentlyContinue)
    foreach ($e in $raw) {
        $data = @{}
        foreach ($d in @(([xml]$e.ToXml()).Event.EventData.Data)) { if ($d.Name) { $data[[string]$d.Name] = [string]$d.'#text' } }
        [pscustomobject]@{ Id = [int]$e.Id; Time = $e.TimeCreated; ErrorCode = $data['errorCode']; Title = $data['updateTitle'] }
    }
}
$script:CsState = { if ([IO.File]::Exists($script:StatePath)) { [IO.File]::ReadAllText($script:StatePath) } else { $null } }

function Protect-CsText {
    param([string]$Text, [int]$Max = 200)
    $t = $Text -replace '(?i)([a-z]:\\Users\\)[^\\\s]+', '$1[redacted]'
    $t = ($t -replace '[\x00-\x1F]', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '[clipped]' }
    return $t
}

function Format-CsHex {
    param($Value)
    $s = [string]$Value
    if ($s -match '\A0[xX][0-9a-fA-F]{1,8}\z') { return '0x' + $s.Substring(2).ToLowerInvariant().PadLeft(8, '0') }
    $n = 0L
    if ([long]::TryParse($s, [ref]$n)) { return '0x' + ([uint32]($n -band 0xFFFFFFFFL)).ToString('x8') }
    return Protect-CsText $s -Max 24
}

function Get-CsCbsSummary {
    param([AllowEmptyCollection()][string[]]$Lines)
    $kinds = [ordered]@{}
    $items = [Collections.Generic.List[string]]::new()
    $codes = @{}
    $errors = [Collections.Generic.List[string]]::new()
    $detected = $null; $repaired = $null; $unrepaired = 0
    foreach ($line in @($Lines)) {
        if (-not $line) { continue }
        $time = $script:TimeRx.Match($line)
        $time = if ($time.Success) { $time.Groups[1].Value } else { $null }
        $row = $script:RowRx.Match($line)
        if ($row.Success) {
            $kind = $row.Groups[1].Value.Trim()
            $kinds[$kind] = 1 + [int]$kinds[$kind]
            if ($row.Groups[2].Value -ne 'f') {
                $unrepaired++
                if ($items.Count -lt 8) { $items.Add((Protect-CsText ($kind + ' ' + $row.Groups[3].Value.Trim()) -Max 140)) }
            }
            continue
        }
        if ($line -match 'Total Detected Corruption:\s*(\d+)') { $detected = [int]$Matches[1] }
        if ($line -match 'Total Repaired Corruption:\s*(\d+)') { $repaired = [int]$Matches[1] }
        foreach ($m in $script:CodeRx.Matches($line)) {
            $code = $m.Groups[1].Value.ToLowerInvariant()
            if (-not $codes.ContainsKey($code)) { $codes[$code] = [ordered]@{ code = $code; name = $null; count = 0; last = $null } }
            $codes[$code].count++
            if ($m.Groups[2].Success) { $codes[$code].name = $m.Groups[2].Value }
            if ($time) { $codes[$code].last = $time }
        }
        if ($line -match ',\s+Error\s') { $errors.Add((Protect-CsText $line)); if ($errors.Count -gt 3) { $errors.RemoveAt(0) } }
    }
    $top = @($codes.Values | Sort-Object -Property @{ Expression = { $_.count }; Descending = $true }, @{ Expression = { $_.code } } | Select-Object -First 10)
    return [ordered]@{ detected = $detected; repaired = $repaired; kinds = $kinds; unrepaired = $unrepaired; items = @($items); codes = $top; lastErrors = @($errors) }
}

function Get-CsWuSummary {
    param([AllowEmptyCollection()]$Events)
    $groups = @(@($Events) | Where-Object { $_ } | Group-Object -Property { '' + $_.Id + '|' + (Format-CsHex $_.ErrorCode) })
    $out = foreach ($g in $groups) {
        $sorted = @($g.Group | Sort-Object -Property Time -Descending)
        $kbs = @($sorted | ForEach-Object { [regex]::Matches([string]$_.Title, 'KB\d{6,8}') | ForEach-Object { $_.Value } } | Select-Object -Unique -First 3)
        [ordered]@{ id = [int]$sorted[0].Id; code = (Format-CsHex $sorted[0].ErrorCode); count = $sorted.Count
            first = $sorted[-1].Time.ToString('s'); last = $sorted[0].Time.ToString('s'); kbs = $kbs }
    }
    return @($out | Sort-Object -Property @{ Expression = { $_.count }; Descending = $true })
}

function Get-CsReport {
    $cv = $script:CvKey
    $cbsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
    $os = [ordered]@{
        product = [string](& $script:CsRegValue $cv 'ProductName'); edition = [string](& $script:CsRegValue $cv 'EditionID')
        installationType = [string](& $script:CsRegValue $cv 'InstallationType'); displayVersion = [string](& $script:CsRegValue $cv 'DisplayVersion')
        build = '' + (& $script:CsRegValue $cv 'CurrentBuild') + '.' + (& $script:CsRegValue $cv 'UBR')
    }
    $pending = [ordered]@{
        cbsRebootPending = [bool](& $script:CsKeyExists "$cbsKey\RebootPending")
        cbsPackagesPending = [bool](& $script:CsKeyExists "$cbsKey\PackagesPending")
        wuRebootRequired = [bool](& $script:CsKeyExists 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        fileRenames = [int](& $script:CsRenames)
    }
    $health = if (& $script:CsDismBusy) { [ordered]@{ state = 'skipped: DISM running'; error = $null; seconds = 0 } } else { & $script:CsCheckHealth }
    $worker = $null
    $stateText = & $script:CsState
    if ($stateText) { try { $worker = $stateText | ConvertFrom-Json } catch { $worker = 'unreadable' } }
    $free = $null; try { $free = & $script:CsFreeGB } catch { }
    return [ordered]@{ schemaVersion = 1; os = $os; systemFreeGB = $free; pending = $pending; checkHealth = $health
        cbs = (Get-CsCbsSummary -Lines @(& $script:CsCbsLines)); wu = @(Get-CsWuSummary -Events @(& $script:CsEvents)); worker = $worker; truncated = $false }
}

# Trims the longest lists until the line fits.
function ConvertTo-CsJson {
    param($Report)
    $json = $Report | ConvertTo-Json -Depth 6 -Compress
    $steps = @(
        { $Report.cbs.lastErrors = @($Report.cbs.lastErrors | Select-Object -Last 1) },
        { $Report.cbs.items = @($Report.cbs.items | Select-Object -First 3) },
        { $Report.wu = @($Report.wu | Select-Object -First 4) },
        { $Report.cbs.lastErrors = @(); $Report.cbs.items = @() },
        { $Report.wu = @() }
    )
    foreach ($step in $steps) {
        if ([Text.Encoding]::UTF8.GetByteCount($json) -le $script:OutputMaxBytes) { break }
        & $step
        $Report.truncated = $true
        $json = $Report | ConvertTo-Json -Depth 6 -Compress
    }
    return $json
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
try {
    [Console]::Out.WriteLine((ConvertTo-CsJson (Get-CsReport)))
    exit 0
} catch {
    [Console]::Out.WriteLine('{"schemaVersion":1,"error":"report failed"}')
    exit 1
}
