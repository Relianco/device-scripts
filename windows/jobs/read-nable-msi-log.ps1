# Diagnostic module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Strictly read-only: it reads the newest
# nable-msi-*.log that nable-agent-removal kept in C:\ProgramData\Relian\NableMsiLogs (no other path, no parameter)
# and reports facts about it instead of the raw file: where the first "Return value 3" is, the error lines, the custom
# actions with their return values, the properties that steer the uninstall and the last lines. It never writes,
# deletes or starts a process; the file is opened with FileShare ReadWrite|Delete so a log in use can be read.
# -ReportOnly is accepted because the loader forwards it, and ignored. Exit 0 ok, 2 when the log cannot be read.
# Prints one JSON line.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:RmDir = 'C:\ProgramData\Relian\NableMsiLogs'
$script:RmLineCap = 300
$script:RmJsonCap = 60000
$script:RmMachine = $env:COMPUTERNAME

# Seam: the log files of the one directory, or nothing when it is missing.
$script:RmList = {
    if (-not (Test-Path -LiteralPath $script:RmDir -PathType Container)) { return @() }
    @(Get-ChildItem -LiteralPath $script:RmDir -Filter 'nable-msi-*.log' -File)
}

# Seam: the bytes of one log, opened for reading only and shared with its writer.
$script:RmReadBytes = {
    param($Path)
    $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $ms = [IO.MemoryStream]::new()
        $fs.CopyTo($ms)
        return , $ms.ToArray()
    } finally { $fs.Dispose() }
}

# Name and text of the encoding: a BOM decides, then NULs in every other byte mean BOM-less UTF-16 LE, else ANSI.
function Get-RmDecoded {
    param([byte[]]$Bytes)
    $n = $Bytes.Length
    if ($n -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return @('UTF-16LE-BOM', [Text.Encoding]::Unicode.GetString($Bytes, 2, $n - 2)) }
    if ($n -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return @('UTF-16BE-BOM', [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $n - 2)) }
    if ($n -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return @('UTF-8-BOM', [Text.Encoding]::UTF8.GetString($Bytes, 3, $n - 3)) }
    $probe = [Math]::Min($n - ($n % 2), 400)
    $nuls = 0
    for ($i = 1; $i -lt $probe; $i += 2) { if ($Bytes[$i] -eq 0) { $nuls++ } }
    if ($probe -ge 4 -and $nuls -gt ($probe / 2) * 0.4) { return @('UTF-16LE', [Text.Encoding]::Unicode.GetString($Bytes)) }
    # 28591 is Latin-1: a byte-for-byte ANSI reading that exists on Windows PowerShell and pwsh alike.
    return @('ANSI', [Text.Encoding]::GetEncoding(28591).GetString($Bytes))
}

# One line with secrets, user names, emails, SIDs, IPs and the machine name masked, cut to 300 characters.
function Get-RmRedacted {
    param([AllowEmptyString()][string]$Line)
    $t = $Line -replace '(?i)(Property\(.\):\s*\w*(?:PASSWORD|PASSWD|PWD|TOKEN|KEY|SECRET)\w*\s*=\s*).*', '${1}<redacted>'
    $t = $t -replace '(?i)(\b\w*(?:PASSWORD|PASSWD|PWD|TOKEN|KEY|SECRET)\w*\s*=\s*)("[^"]*"|\S+)', '${1}<redacted>'
    $t = $t -replace '(?i)C:\\Users\\[^\\]+', 'C:\Users\<user>'
    $t = $t -replace '[\w.+-]+@[\w-]+(\.[\w-]+)+', '<email>'
    $t = $t -replace '(?i)\bS-1-\d+(-\d+)+', '<sid>'
    $t = $t -replace '\b\d{1,3}(\.\d{1,3}){3}\b', '<ip>'
    if ($script:RmMachine -and $script:RmMachine.Length -ge 2) { $t = $t -replace ('(?i)\b' + [regex]::Escape($script:RmMachine) + '\b'), '<machine>' }
    return $t.Substring(0, [Math]::Min($t.Length, $script:RmLineCap))
}

function Get-RmFacts {
    param([string[]]$Lines)
    $last = $Lines.Count - 1
    $rv3 = @()
    for ($i = 0; $i -le $last -and $rv3.Count -lt 3; $i++) {
        if ($Lines[$i] -match 'Return value 3') {
            $from = [Math]::Max(0, $i - 12); $to = [Math]::Min($last, $i + 6)
            $rv3 += , ([ordered]@{ line = $i + 1; context = @($Lines[$from..$to] | ForEach-Object { Get-RmRedacted $_ }) })
        }
    }
    $errors = [Collections.Generic.List[string]]::new(); $errorsMore = $false
    $actions = [Collections.Generic.List[object]]::new()
    $props = [ordered]@{}
    for ($i = 0; $i -le $last; $i++) {
        $l = $Lines[$i]
        if ($l -match '(?i)\bError\s+\d{1,5}\b' -or ($l -match 'CustomAction' -and $l -match '(?i)returned actual error code|failed')) {
            if ($errors.Count -lt 40) { $errors.Add("$($i + 1): $(Get-RmRedacted $l)") } else { $errorsMore = $true }
        }
        $m = [regex]::Match($l, 'Action start \d+:\d+:\d+: (?<n>[^.\s]+)\.')
        if ($m.Success) { $actions.Add([pscustomobject]@{ name = $m.Groups['n'].Value; returnValue = $null }); continue }
        $m = [regex]::Match($l, 'Action ended \d+:\d+:\d+: (?<n>[^.\s]+)\. Return value (?<v>-?\d+)')
        if ($m.Success) {
            for ($j = $actions.Count - 1; $j -ge 0; $j--) {
                if ($actions[$j].name -eq $m.Groups['n'].Value -and $null -eq $actions[$j].returnValue) { $actions[$j].returnValue = [int]$m.Groups['v'].Value; break }
            }
            continue
        }
        $m = [regex]::Match($l, 'Property\(.\): (?<n>\S+) = (?<v>.*)$')
        if ($m.Success -and -not $props.Contains($m.Groups['n'].Value) -and $props.Count -lt 30 -and
            $m.Groups['n'].Value -match '(?i)\A(REMOVE|INSTALLLEVEL|UILevel|INSTALLDIR|INSTALLLOCATION|TARGETDIR|\w*INSTALL(DIR|PATH|LOCATION)\w*|\w*_(DIR|PATH))\z') {
            $props[$m.Groups['n'].Value] = Get-RmRedacted $m.Groups['v'].Value
        }
    }
    # shortcut: the newest 60 actions are kept, as the failing one runs late; list all of them if that proves wrong.
    $actionsMore = $actions.Count -gt 60
    [pscustomobject]@{
        FirstReturnValue3 = $rv3; ErrorLines = @($errors); CustomActions = @($actions | Select-Object -Last 60 | ForEach-Object { [ordered]@{ name = (Get-RmRedacted $_.name); returnValue = $_.returnValue } })
        Properties = $props; Tail = @($Lines | Select-Object -Last 40 | ForEach-Object { Get-RmRedacted $_ }); Capped = ($errorsMore -or $actionsMore)
    }
}

function ConvertTo-RmLine {
    param($Out)
    $json = $Out | ConvertTo-Json -Compress -Depth 6
    # Halve the biggest sections until the line fits.
    while ($json.Length -gt $script:RmJsonCap) {
        $Out.truncated = $true
        $big = 'tail', 'errorLines', 'customActions', 'firstReturnValue3' | Sort-Object { @($Out[$_]).Count } -Descending | Select-Object -First 1
        if (@($Out[$big]).Count -eq 0) { break }
        $Out[$big] = @(@($Out[$big]) | Select-Object -First ([Math]::Floor(@($Out[$big]).Count / 2)))
        $json = $Out | ConvertTo-Json -Compress -Depth 6
    }
    return $json
}

function Invoke-ReadMsiLogJob {
    $out = [ordered]@{
        job = 'read-nable-msi-log'; status = 'ok'; file = $null; sizeBytes = $null; lastWriteUtc = $null; encoding = $null; lineCount = 0
        firstReturnValue3 = @(); errorLines = @(); customActions = @(); properties = [ordered]@{}; tail = @(); truncated = $false; error = ''
    }
    $exitCode = 0
    try {
        $file = @(& $script:RmList | Sort-Object { $_.LastWriteTimeUtc } -Descending | Select-Object -First 1)
        if ($file.Count -eq 0) {
            $out.error = 'no nable-msi log found'
        } else {
            $f = $file[0]
            $decoded = Get-RmDecoded ([byte[]](& $script:RmReadBytes $f.FullName))
            $lines = @($decoded[1] -split '\r?\n')
            if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines | Select-Object -SkipLast 1) }
            $facts = Get-RmFacts $lines
            $out.file = [string]$f.Name; $out.sizeBytes = [int64]$f.Length; $out.lastWriteUtc = ([DateTime]$f.LastWriteTimeUtc).ToString('yyyy-MM-ddTHH:mm:ssZ')
            $out.encoding = $decoded[0]; $out.lineCount = $lines.Count
            $out.firstReturnValue3 = @($facts.FirstReturnValue3); $out.errorLines = @($facts.ErrorLines); $out.customActions = @($facts.CustomActions)
            $out.properties = $facts.Properties; $out.tail = @($facts.Tail); $out.truncated = [bool]$facts.Capped
        }
    } catch {
        $exitCode = 2; $out.status = 'failed'; $out.error = Get-RmRedacted "log read failed: $($_.Exception.Message)"
    }
    [pscustomobject]@{ ExitCode = $exitCode; Line = (ConvertTo-RmLine $out) }
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$result = Invoke-ReadMsiLogJob
Write-Output $result.Line
exit $result.ExitCode
