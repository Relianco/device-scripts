<#
.SYNOPSIS
    Read-only: the SentinelOne installer and upgrade logs from the last few days, to explain an installer
    exit code (for example a refused in-place upgrade).
.DESCRIPTION
    Looks for log and text files whose name mentions Sentinel, SC-exit-code or an installer, changed in the
    last Days days, in C:\Windows\Temp (two levels, which covers the s1-rebind package's relian-s1-* work
    folders) and C:\ProgramData\Sentinel (four levels). It lists each match (path, size, last write) and prints
    the last Lines lines of the newest MaxFiles files. It also lists SentinelOne and MsiInstaller events from
    the Application log in the same window.

    Nothing is written, started or changed. Every printed line is cut to 300 characters, whitespace is
    flattened, and anything token-shaped (32 or more base64 or hex characters) is replaced with [redacted],
    so a site token on an installer command line never leaves the device. The output is bounded to about
    12000 characters; the caller (the runner or the read-job loader) passes -DeploymentType, -Action and
    -PinVersion, which this ignores, and optionally:

      Days      1 to 14, default 3.
      Lines     10 to 200, default 60.
      MaxFiles  1 to 8, default 4.

    Prints plain text, one fact per line. Exit 0 when the search ran (even with no matches), 1 on bad input.
#>
# Parameters are not Mandatory: a mandatory param block prompts when this file is dot-sourced under test.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Days = '3',
    [string]$Lines = '60',
    [string]$MaxFiles = '4'
)
$ProgressPreference = 'SilentlyContinue'

$script:SlNamePattern = '(?i)(sentinel|sc-exit-code|install|upgrade)'
$script:SlBudget = 12000

# Seams. Tests replace them.
$script:SlNow = { [datetime]::UtcNow }
$script:SlFiles = {
    param([string]$Root, [int]$Depth)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    @(Get-ChildItem -LiteralPath $Root -Recurse -Depth $Depth -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match '^(?i)\.(log|txt)$' } |
        ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Name = $_.Name; Length = $_.Length; LastWriteUtc = $_.LastWriteTimeUtc } })
}
$script:SlTail = {
    param([string]$Path, [int]$Count)
    @(Get-Content -LiteralPath $Path -Tail $Count -ErrorAction Stop)
}
$script:SlEvents = {
    param([datetime]$SinceUtc)
    @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $SinceUtc.ToLocalTime() } -MaxEvents 2000 -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match '(?i)sentinel|MsiInstaller' } |
        ForEach-Object { [pscustomobject]@{ TimeUtc = $_.TimeCreated.ToUniversalTime(); Provider = $_.ProviderName; Id = $_.Id; Message = [string]$_.Message } })
}

# Pure: an integer in [Min, Max], or throws.
function ConvertTo-SlInt {
    param([string]$Value, [int]$Min, [int]$Max, [string]$Name)
    $n = 0
    if ($Value -cnotmatch '\A[0-9]{1,3}\z' -or -not [int]::TryParse($Value, [ref]$n) -or $n -lt $Min -or $n -gt $Max) {
        throw "$Name must be $Min to $Max."
    }
    return $n
}

# Pure: one safe output line.
function Protect-SlText {
    param([AllowEmptyString()][string]$Text, [int]$Max = 300)
    $t = (([string]$Text) -replace '[A-Za-z0-9+/=_-]{32,}', '[redacted]') -replace '\s+', ' '
    $t = $t.Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + '..' }
    return $t
}

# Pure: the matching files changed since SinceUtc, newest first.
function Select-SlFiles {
    param($Files, [datetime]$SinceUtc)
    @(@($Files) | Where-Object { $_ -and $_.Name -match $script:SlNamePattern -and $_.LastWriteUtc -ge $SinceUtc } |
        Sort-Object -Property LastWriteUtc -Descending)
}

function Invoke-SlReport {
    param([int]$Days, [int]$Lines, [int]$MaxFiles)
    $out = New-Object System.Collections.Generic.List[string]
    $since = (& $script:SlNow).AddDays(-$Days)
    $out.Add("s1-install-logs v1 since $($since.ToString('yyyy-MM-dd HH:mm'))Z")
    $found = @()
    foreach ($r in @(@{ Root = 'C:\Windows\Temp'; Depth = 2 }, @{ Root = 'C:\ProgramData\Sentinel'; Depth = 4 })) {
        $found += @(Select-SlFiles (& $script:SlFiles $r.Root $r.Depth) $since)
    }
    $found = @($found | Sort-Object -Property LastWriteUtc -Descending)
    $out.Add("files: $($found.Count)")
    foreach ($f in $found | Select-Object -First 30) {
        $out.Add(('file {0} {1}B {2}Z' -f (Protect-SlText $f.Path), $f.Length, $f.LastWriteUtc.ToString('yyyy-MM-dd HH:mm')))
    }
    foreach ($e in @(& $script:SlEvents $since) | Select-Object -First 25) {
        $out.Add(('ev {0}Z {1} {2}: {3}' -f $e.TimeUtc.ToString('MM-dd HH:mm'), $e.Provider, $e.Id, (Protect-SlText $e.Message 240)))
    }
    foreach ($f in $found | Select-Object -First $MaxFiles) {
        $out.Add("== tail $(Protect-SlText $f.Name 120)")
        try {
            foreach ($l in @(& $script:SlTail $f.Path $Lines)) { $t = Protect-SlText $l; if ($t) { $out.Add($t) } }
        } catch {
            $out.Add('(unreadable: ' + $_.Exception.GetType().Name + ')')
        }
    }
    # Keep the head (the file list) and cut the rest to the budget.
    $text = New-Object System.Text.StringBuilder
    foreach ($l in $out) {
        if ($text.Length + $l.Length + 1 -gt $script:SlBudget) { [void]$text.AppendLine('(output cut)'); break }
        [void]$text.AppendLine($l)
    }
    return $text.ToString()
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') { return }
if ($Action -eq 'Uninstall') { Write-Output 'Nothing to uninstall.'; exit 0 }
if (@('Install', 'Update', 'Repair', 'Reinstall') -notcontains $Action) { [Console]::Error.WriteLine('Unsupported action.'); exit 1 }
try {
    $d = ConvertTo-SlInt $Days 1 14 'Days'
    $n = ConvertTo-SlInt $Lines 10 200 'Lines'
    $m = ConvertTo-SlInt $MaxFiles 1 8 'MaxFiles'
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
Write-Output (Invoke-SlReport -Days $d -Lines $n -MaxFiles $m)
exit 0
