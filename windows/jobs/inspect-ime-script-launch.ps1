# Diagnostic module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Strictly read-only: it reads the Intune
# Management Extension logs (AppWorkload, AgentExecutor, IntuneManagementExtension) and reports, for apps whose name
# starts with "Relian Managed - ", which PowerShell IME started (System32, SysWOW64 or Sysnative path), for which
# IMECache script file, and fixed installer markers (PowerShellScript, runAs32Bit, AgentExecutor). It never prints log
# text: only app ids and names from the policy JSON, the powershell.exe path, a .ps1 file name, times and markers
# from an allowlist. It writes nothing. -ReportOnly is accepted and ignored. Exit 0, 2 when the logs cannot be read.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:ImLogDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Microsoft\IntuneManagementExtension\Logs'
$script:ImGuid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:ImPowerShell = '(?i)[a-z]:\\windows\\(?:system32|syswow64|sysnative)\\windowspowershell\\v1\.0\\powershell\.exe'
$script:ImMarkers = [ordered]@{
    PowerShellScript = '(?i)PowerShellScript'
    AgentExecutor = '(?i)AgentExecutor'
    System32 = '(?i)\\System32\\'
    SysWOW64 = '(?i)\\SysWOW64\\'
    Sysnative = '(?i)\\Sysnative\\'
    msiexec = '(?i)\bmsiexec'
    'cmd.exe' = '(?i)\bcmd\.exe'
}

# Seam: the logs, oldest first. IME keeps them open, so share read and write.
$script:ImReadLogs = {
    if (-not (Test-Path -LiteralPath $script:ImLogDir)) { return @() }
    $files = foreach ($f in @('AppWorkload*.log', 'AgentExecutor*.log', 'IntuneManagementExtension*.log')) { Get-ChildItem -LiteralPath $script:ImLogDir -Filter $f -File }
    foreach ($file in @($files | Sort-Object LastWriteTimeUtc)) {
        $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            $reader = [IO.StreamReader]::new($stream)
            [pscustomobject]@{ Name = $file.Name; Text = $reader.ReadToEnd() }
        } finally { $stream.Dispose() }
    }
}

function Get-ImEntries {
    param([string]$Text)
    foreach ($m in [regex]::Matches($Text, '(?s)<!\[LOG\[(.*?)\]LOG\]!><time="(\d{1,2}:\d{2}:\d{2})[^"]*" date="(\d{1,2})-(\d{1,2})-(\d{4})"[^>]*?thread="([^"]*)"')) {
        [pscustomobject]@{
            Text = $m.Groups[1].Value
            Thread = $m.Groups[6].Value
            Time = '{0}-{1:00}-{2:00} {3}' -f $m.Groups[5].Value, [int]$m.Groups[3].Value, [int]$m.Groups[4].Value, $m.Groups[2].Value.PadLeft(8, '0')
        }
    }
}

function Invoke-ImJob {
    try { $logs = @(& $script:ImReadLogs) }
    catch {
        return [pscustomobject]@{ ExitCode = 2; Line = ([ordered]@{ job = 'inspect-ime-script-launch'; status = 'failed'; apps = @(); launches = @(); error = "log read failed: $($_.Exception.Message)" } | ConvertTo-Json -Compress) }
    }
    $parsed = @(foreach ($log in $logs) { [pscustomobject]@{ Name = [string]$log.Name; Entries = @(Get-ImEntries ([string]$log.Text)) } })

    # Managed app ids and names from the policy JSON.
    $names = @{}
    foreach ($log in $parsed) { foreach ($e in $log.Entries) {
        foreach ($m in [regex]::Matches($e.Text, ('"Id":"(' + $script:ImGuid + ')","Name":"(Relian Managed - [A-Za-z0-9 ._()+-]{1,80})"'))) { $names[$m.Groups[1].Value.ToLowerInvariant()] = $m.Groups[2].Value }
    } }

    # Markers: the text from one managed-app id to the next is that app's, so a policy list is not smeared over all apps.
    $apps = @{}
    foreach ($id in $names.Keys) { $apps[$id] = @{ markers = [Collections.Generic.SortedSet[string]]::new(); lastSeen = $null } }
    $launches = [Collections.Generic.List[object]]::new()
    foreach ($log in $parsed) {
        # A powershell.exe path pairs only with the next script line on the same thread, and only once.
        $current = @{}
        foreach ($e in $log.Entries) {
            $hits = @([regex]::Matches($e.Text, $script:ImGuid) | Where-Object { $names.ContainsKey($_.Value.ToLowerInvariant()) })
            for ($i = 0; $i -lt $hits.Count; $i++) {
                $id = $hits[$i].Value.ToLowerInvariant()
                $end = if ($i + 1 -lt $hits.Count) { $hits[$i + 1].Index } else { $e.Text.Length }
                $chunk = $e.Text.Substring($hits[$i].Index, $end - $hits[$i].Index)
                foreach ($k in $script:ImMarkers.Keys) { if ($chunk -match $script:ImMarkers[$k]) { [void]$apps[$id].markers.Add($k) } }
                $r32 = [regex]::Match($chunk, '(?i)runAs32Bit"?\s*[:=]\s*"?(true|false)')
                if ($r32.Success) { [void]$apps[$id].markers.Add('runAs32Bit: ' + (Get-Culture).TextInfo.ToTitleCase($r32.Groups[1].Value.ToLowerInvariant())) }
                $apps[$id].lastSeen = $e.Time
            }
            $ps = [regex]::Match($e.Text, $script:ImPowerShell)
            if ($ps.Success) { $current[$e.Thread] = $ps.Value }
            $script = [regex]::Match($e.Text, ('(?i)\\IMECache\\(?:HealthScripts\\)?(' + $script:ImGuid + ')_\d+\\([A-Za-z0-9._-]{1,60}\.ps1)'))
            if ($script.Success) {
                $id = $script.Groups[1].Value.ToLowerInvariant()
                $path = $current[$e.Thread]; $current.Remove($e.Thread)
                if ($names.ContainsKey($id)) { $launches.Add([ordered]@{ time = $e.Time; log = $log.Name; appId = $id; app = $names[$id]; powershell = $path; script = $script.Groups[2].Value }) }
            }
        }
    }

    $appList = @(foreach ($id in @($names.Keys | Sort-Object)) { [ordered]@{ id = $id; name = $names[$id]; lastSeen = $apps[$id].lastSeen; markers = @($apps[$id].markers) } })
    $recent = @($launches | Sort-Object { $_.time } | Select-Object -Last 20)
    [pscustomobject]@{
        ExitCode = 0
        Line = ([ordered]@{ job = 'inspect-ime-script-launch'; status = 'ok'; apps = $appList; launches = $recent; error = '' } | ConvertTo-Json -Compress -Depth 5)
    }
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$result = Invoke-ImJob
Write-Output $result.Line
exit $result.ExitCode
