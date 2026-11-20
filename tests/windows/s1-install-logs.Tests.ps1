$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/read/s1-install-logs/Invoke-S1InstallLogs.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}
function Assert-True {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) { Fail $Label }
}

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

$now = [datetime]::new(2026, 11, 20, 18, 0, 0, [DateTimeKind]::Utc)
# Token-shaped but obviously fake, built at run time so the secret scanner has nothing to match.
$token = 'Fake' + ('Ab9_' * 12)
$script:SlNow = { $now }
$script:SlFiles = {
    param([string]$Root, [int]$Depth)
    if ($Root -ne 'C:\Windows\Temp') { return @() }
    @(
        [pscustomobject]@{ Path = 'C:\Windows\Temp\SentinelInstaller_20261119.log'; Name = 'SentinelInstaller_20261119.log'; Length = 900; LastWriteUtc = $now.AddHours(-20) },
        [pscustomobject]@{ Path = 'C:\Windows\Temp\SC-exit-code.txt'; Name = 'SC-exit-code.txt'; Length = 3; LastWriteUtc = $now.AddHours(-20) },
        [pscustomobject]@{ Path = 'C:\Windows\Temp\old-SentinelInstaller.log'; Name = 'old-SentinelInstaller.log'; Length = 5; LastWriteUtc = $now.AddDays(-9) },
        [pscustomobject]@{ Path = 'C:\Windows\Temp\unrelated.log'; Name = 'unrelated.log'; Length = 5; LastWriteUtc = $now.AddHours(-1) }
    )
}
$script:SlTail = {
    param([string]$Path, [int]$Count)
    if ($Path -like '*SC-exit-code*') { throw [UnauthorizedAccessException]::new('denied') }
    @('Upgrade refused: local upgrade not authorized', "cmd: SentinelOneInstaller.exe -t $token -q", ('x' * 500))
}
$script:SlEvents = { param([datetime]$SinceUtc) @([pscustomobject]@{ TimeUtc = $now.AddHours(-20); Provider = 'MsiInstaller'; Id = 11708; Message = 'Installation failed.' }) }

# 1. Input validation.
foreach ($bad in @('0', '15', '-1', 'x', '3.5', '1000')) {
    $threw = $false
    try { [void](ConvertTo-SlInt $bad 1 14 'Days') } catch { $threw = $true }
    Assert-True $threw "Days $bad rejected"
}
Assert-True ((ConvertTo-SlInt '3' 1 14 'Days') -eq 3) 'Days 3 accepted'

# 2. The report: recent matching files only, newest first, unreadable file noted, events listed.
$r = Invoke-SlReport -Days 3 -Lines 60 -MaxFiles 4
Assert-True ($r -match 'files: 2') 'two recent matching files (old and unrelated left out)'
Assert-True ($r -notmatch 'old-SentinelInstaller') 'old file left out'
Assert-True ($r -notmatch 'unrelated\.log') 'unrelated name left out'
Assert-True ($r -match 'Upgrade refused: local upgrade not authorized') 'tail line printed'
Assert-True ($r -match '\(unreadable: UnauthorizedAccessException\)') 'unreadable file noted, run continues'
Assert-True ($r -match 'ev 11-19 22:00Z MsiInstaller 11708: Installation failed\.') 'event listed'

# 3. No token leaves the device; long lines are cut.
Assert-True (-not $r.Contains($token)) 'token redacted'
Assert-True ($r -match '\[redacted\]') 'redaction marker present'
foreach ($l in $r -split "`r?`n") { Assert-True ($l.Length -le 302) "line too long: $($l.Length)" }

# 4. Output budget holds with many files.
$script:SlFiles = {
    param([string]$Root, [int]$Depth)
    @(1..40 | ForEach-Object { [pscustomobject]@{ Path = "C:\Windows\Temp\SentinelInstaller_$_.log"; Name = "SentinelInstaller_$_.log"; Length = 1; LastWriteUtc = $now.AddMinutes(-$_) } })
}
$script:SlTail = { param([string]$Path, [int]$Count) @(1..$Count | ForEach-Object { 'line ' + ('y' * 290) }) }
$r = Invoke-SlReport -Days 3 -Lines 200 -MaxFiles 8
Assert-True ($r.Length -le 12400) "output bounded ($($r.Length))"
Assert-True ($r -match '\(output cut\)') 'cut marker present'

Write-Output 's1-install-logs tests passed'
exit 0
