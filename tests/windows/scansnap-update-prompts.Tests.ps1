# ScanSnap remediation module. The registry and process calls are seams on Linux.
# The real calls, from a 32-bit process, run in the windows-2022 CI job below.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'windows/jobs/scansnap-update-prompts.ps1'

function Fail { param([string]$Message) [Console]::Error.WriteLine("FAIL $Message"); exit 1 }
function Assert-True { param([bool]$Condition, [string]$Label) if (-not $Condition) { Fail $Label } }
function Assert-Same { param($Actual, $Expected, [string]$Label) if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" } }

$env:RELIAN_DEPLOY_TEST = '1'
. $modulePath

$run64 = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$run32 = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
$approved = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$disabled = [byte[]](3, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8)
$enabled = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

function Reset-Test {
    $script:Reg = @{}
    $script:Writes = [Collections.Generic.List[object]]::new()
    $script:Stops = 0
    $script:Watchers = 0
    $script:StopWorks = $true
    $script:WriteThrows = $false
}
$script:SsReadValues = { param($Path)
    if ($script:Reg.ContainsKey($Path)) { return $script:Reg[$Path] }
    return @{}
}
$script:SsWriteBinary = { param($Path, $Name, $Data)
    if ($script:WriteThrows) { throw 'Requested registry access is not allowed.' }
    $script:Writes.Add([pscustomobject]@{ Path = $Path; Name = $Name; Data = $Data })
    if (-not $script:Reg.ContainsKey($Path)) { $script:Reg[$Path] = @{} }
    $script:Reg[$Path][$Name] = $Data
}
$script:SsCountWatchers = { $script:Watchers }
$script:SsStopWatchers = { $script:Stops++; if ($script:StopWorks) { $script:Watchers = 0 } }

function Invoke-Job { param([switch]$ReportOnly)
    $r = Invoke-ScanSnapJob -ReportOnly:$ReportOnly
    [pscustomobject]@{ Code = $r.ExitCode; Line = (ConvertTo-ScanSnapJobLine $r); Json = (ConvertTo-ScanSnapJobLine $r | ConvertFrom-Json) }
}

# Healthy: no ScanSnap at all. Exit 0, compliant, no write, no stop.
Reset-Test
$r = Invoke-Job
Assert-Same $r.Code 0 'no ScanSnap exit'
Assert-Same $r.Json.status 'compliant' 'no ScanSnap status'
Assert-Same $r.Json.job 'scansnap-update-prompts' 'job name'
Assert-Same $r.Json.found 0 'no ScanSnap found'
Assert-Same $script:Writes.Count 0 'no ScanSnap writes'
Assert-Same $script:Stops 0 'no ScanSnap stops'

# Healthy: entries already disabled in both views. An unrelated Run entry is ignored.
Reset-Test
$script:Reg[$run64] = @{ 'ScanSnap Online Update' = 'C:\Program Files\PFU\SsUWatcher.exe'; 'OneDrive' = 'C:\OneDrive.exe' }
$script:Reg[$run32] = @{ 'scansnap onlineupdate watcher' = 'C:\x\y.exe' }
$script:Reg["$approved\Run"] = @{ 'ScanSnap Online Update' = $disabled; 'OneDrive' = $enabled }
$script:Reg["$approved\Run32"] = @{ 'scansnap onlineupdate watcher' = $disabled }
$r = Invoke-Job
Assert-Same $r.Code 0 'disabled exit'
Assert-Same $r.Json.status 'compliant' 'disabled status'
Assert-Same $r.Json.found 2 'disabled found (command match and case-insensitive exact name match)'
Assert-Same $script:Writes.Count 0 'a healthy run changes nothing, not even the timestamp'
Assert-Same $script:Stops 0 'disabled stops'

# Another product's entry does not match: it stays enabled and is not counted, by name or by command.
foreach ($case in @(
        @{ N = 'OtherVendor OnlineUpdate'; V = 'C:\OtherVendor\Updater.exe' },
        @{ N = 'OnlineUpdate'; V = 'C:\x\y.exe' },
        @{ N = 'OtherVendor'; V = 'C:\OtherVendor\OnlineUpdate.exe' },
        @{ N = 'ScanSnap OnlineUpdate Watcher 2'; V = 'C:\x\y.exe' },
        @{ N = 'SsUWatcher'; V = 'C:\x\y.exe' },
        @{ N = 'OtherVendor'; V = 'C:\NotSsUWatcher.exe' },
        @{ N = 'OtherVendor'; V = 'C:\SsUWatcherHelper.exe' },
        @{ N = 'OtherVendor'; V = 'C:\SsUWatcher\Other.exe' },
        @{ N = 'OtherVendor'; V = 'C:\OtherVendor.exe --watch SsUWatcher.exe' },
        @{ N = 'OtherVendor'; V = '"C:\Tools\Other.exe" --watch "C:\ScanSnap\SsUWatcher.exe"' },
        @{ N = 'OtherVendor'; V = 'C:\Tools\Other.exe --watch C:\ScanSnap\SsUWatcher.exe' },
        @{ N = 'OtherVendor'; V = 'C:\Program Files\Tools\Other.exe C:\ScanSnap\SsUWatcher.exe' },
        @{ N = 'OtherVendor'; V = 'other --watch C:\ScanSnap\SsUWatcher.exe' },
        @{ N = 'OtherVendor'; V = 'other /watch:C:\ScanSnap\SsUWatcher.exe' })) {
    Reset-Test
    $script:Reg[$run64] = @{ $case.N = $case.V }
    $r = Invoke-Job
    Assert-Same $r.Code 0 "another product exit [$($case.N)=$($case.V)]"
    Assert-Same $r.Json.status 'compliant' "another product status [$($case.N)=$($case.V)]"
    Assert-Same $r.Json.found 0 "another product is not counted [$($case.N)=$($case.V)]"
    Assert-Same $script:Writes.Count 0 "another product stays enabled [$($case.N)=$($case.V)]"
}

# The two ways to match: the exact name, or a command that runs the watcher, under any entry name.
foreach ($case in @(
        @{ N = 'ScanSnap OnlineUpdate Watcher'; V = 'C:\x\y.exe' },
        @{ N = 'SCANSNAP ONLINEUPDATE WATCHER'; V = '' },
        @{ N = 'Anything'; V = 'C:\PFU\SsUWatcher.exe' },
        @{ N = 'Anything'; V = 'C:\PFU\ssuwatcher.EXE' },
        @{ N = 'Anything'; V = '"C:\Program Files\PFU\SsUWatcher.exe" /background' },
        @{ N = 'Anything'; V = 'C:\Program Files\PFU\SsUWatcher.exe /background' },
        @{ N = 'Anything'; V = 'SsUWatcher.exe' },
        @{ N = 'Anything'; V = 'C:\PFU\SsUWatcher' })) {
    Reset-Test
    $script:Reg[$run64] = @{ $case.N = $case.V }
    $r = Invoke-Job
    Assert-Same $r.Json.found 1 "watcher entry is counted [$($case.N)=$($case.V)]"
    Assert-Same $r.Json.status 'fixed' "watcher entry is fixed [$($case.N)=$($case.V)]"
}

# The disabled check: only a binary value whose first byte is 3 counts.
foreach ($state in @($null, $enabled, 'not bytes', [int]3, [byte[]]@())) {
    Reset-Test
    $script:Reg[$run64] = @{ 'SsUWatcher' = 'C:\w\SsUWatcher.exe' }
    if ($null -ne $state) { $script:Reg["$approved\Run"] = @{ 'SsUWatcher' = $state } }
    $r = Invoke-Job -ReportOnly
    Assert-Same $r.Json.status 'drift' "disabled-byte check on [$state]"
}

# Fix: only the drifted entry, in the StartupApproved key of its own view, in Task Manager's format.
Reset-Test
$script:Reg[$run64] = @{ 'ScanSnap Online Update' = 'C:\PFU\SsUWatcher.exe'; 'ScanSnap OnlineUpdate Watcher' = 'C:\PFU\Updater.exe' }
$script:Reg[$run32] = @{ 'Watch32' = 'C:\x\SsUWatcher.exe' }
$script:Reg["$approved\Run"] = @{ 'ScanSnap OnlineUpdate Watcher' = $disabled }
$script:Watchers = 1
$before = [DateTime]::UtcNow.ToFileTimeUtc()
$r = Invoke-Job
Assert-Same $r.Code 0 'fix exit'
Assert-Same $r.Json.status 'fixed' 'fix status'
Assert-Same $r.Json.found 3 'fix found'
Assert-Same $r.Json.running 1 'fix reports what it found running'
Assert-Same (@($r.Json.enabled | Sort-Object) -join ',') 'ScanSnap Online Update,Watch32' 'fix reports what was enabled'
Assert-Same $script:Writes.Count 2 'fix writes drifted entries only'
$w64 = $script:Writes | Where-Object { $_.Name -eq 'ScanSnap Online Update' }
$w32 = $script:Writes | Where-Object { $_.Name -eq 'Watch32' }
Assert-Same $w64.Path "$approved\Run" '64-bit entry goes to StartupApproved\Run'
Assert-Same $w32.Path "$approved\Run32" 'WOW6432Node entry goes to StartupApproved\Run32'
Assert-True ($w64.Data -is [byte[]]) 'value is a byte array, or RegistryKey.SetValue(Binary) throws'
Assert-Same $w64.Data.Length 12 'value is 12 bytes'
Assert-Same $w64.Data[0] 3 'byte 0 is the disabled marker'
Assert-True ([BitConverter]::ToInt64($w64.Data, 4) -ge $before) 'bytes 4-11 are the time it was disabled'
Assert-Same $script:Stops 1 'fix stops the watcher'
$r = Invoke-Job
Assert-Same $r.Json.status 'compliant' 'second run is compliant'
Assert-Same $script:Writes.Count 2 'second run writes nothing'

# A running watcher alone is drift, and the fix does not touch the registry for it.
Reset-Test
$script:Reg[$run64] = @{ 'SsUWatcher' = 'C:\w\SsUWatcher.exe' }
$script:Reg["$approved\Run"] = @{ 'SsUWatcher' = $disabled }
$script:Watchers = 2
$r = Invoke-Job
Assert-Same $r.Json.status 'fixed' 'running only status'
Assert-Same $r.Json.running 2 'running only count'
Assert-Same $script:Writes.Count 0 'running only writes nothing'
Assert-Same $script:Stops 1 'running only stops'

# Report-only: drift is reported, nothing changes, exit is nonzero.
Reset-Test
$script:Reg[$run64] = @{ 'SsUWatcher' = 'C:\w\SsUWatcher.exe' }
$script:Watchers = 1
$r = Invoke-Job -ReportOnly
Assert-Same $r.Code 1 'report-only drift exit'
Assert-Same $r.Json.status 'drift' 'report-only drift status'
Assert-Same $r.Json.reportOnly $true 'report-only flag in the line'
Assert-Same $script:Writes.Count 0 'report-only writes nothing'
Assert-Same $script:Stops 0 'report-only stops nothing'
Reset-Test
$r = Invoke-Job -ReportOnly
Assert-Same $r.Code 0 'report-only healthy exit'
Assert-Same $r.Json.status 'compliant' 'report-only healthy status'

# Failure: a write that throws, a stop that does not take, and a read that throws.
Reset-Test
$script:Reg[$run64] = @{ 'SsUWatcher' = 'C:\w\SsUWatcher.exe' }
$script:WriteThrows = $true
$r = Invoke-Job
Assert-Same $r.Code 2 'write failure exit'
Assert-Same $r.Json.status 'failed' 'write failure status'
Assert-True ($r.Json.error -match 'registry access') 'write failure reason'
Reset-Test
$script:Watchers = 1
$script:StopWorks = $false
$r = Invoke-Job
Assert-Same $r.Code 2 'stop failure exit: fixed needs the re-detect to pass'
Assert-Same $r.Json.status 'failed' 'stop failure status'
Assert-Same $r.Json.running 1 'stop failure says what remains'
Reset-Test
$savedRead = $script:SsReadValues
$script:SsReadValues = { param($Path) throw 'Requested registry access is not allowed.' }
$r = Invoke-Job
Assert-Same $r.Code 2 'read failure is not compliant'
Assert-Same $r.Json.status 'failed' 'read failure status'
$script:SsReadValues = $savedRead

# Bounded: hostile names, many entries, a huge error. One line, valid JSON, at most 1024 chars.
Reset-Test
$huge = 'SsUWatcher"\<>&' + "`r`n`t`u{1}" + ('x' * 5000)
$values = @{}
foreach ($i in 1..500) { $values["$huge$i"] = 'C:\w\SsUWatcher.exe' }
$script:Reg[$run64] = $values
$script:Watchers = 1
$script:WriteThrows = $true
$r = Invoke-Job
Assert-True ($r.Line.Length -le 1024) "line is bounded, was $($r.Line.Length)"
Assert-True ($r.Line -notmatch "[`r`n]") 'line is one line'
Assert-Same $r.Json.found 500 'the count stays exact when the list is cut'
Assert-Same @($r.Json.enabled).Count 10 'the list is cut'
$script:SsWriteBinary = { param($Path, $Name, $Data) throw (('e"<' + "`n") * 5000) }
$r = Invoke-Job
Assert-True ($r.Line.Length -le 1024) "line with a huge error is bounded, was $($r.Line.Length)"
Assert-True ($r.Line -notmatch "[`r`n]") 'line with a huge error is one line'

# Static: explicit 64-bit view for every registry call, no provider paths, ASCII.
$source = [IO.File]::ReadAllText($modulePath)
Assert-True ($source -cmatch '\A[\x00-\x7F]*\z') 'module is ASCII'
Assert-True ($source -match 'OpenBaseKey\(\s*\[Microsoft\.Win32\.RegistryHive\]::LocalMachine\s*,\s*\[Microsoft\.Win32\.RegistryView\]::Registry64\s*\)') 'opens HKLM with the explicit 64-bit view'
Assert-True ($source -notmatch 'HKLM:|Get-ItemProperty|New-ItemProperty|Registry32|RegistryView\]::Default') 'no provider path: a 32-bit process would be redirected'
Assert-True ($source -notmatch 'PSAppDeployToolkit|Show-ADT|Ninja-Property') 'no toolkit, no dialog, no NinjaOne call'

$env:RELIAN_DEPLOY_TEST = $null
if ($env:OS -ne 'Windows_NT') {
    # A real process on a platform with no registry: the read throws, so this is failed and not compliant.
    $out = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $modulePath)
    Assert-Same $LASTEXITCODE 2 'real process failure exit'
    Assert-Same $out.Count 1 'real process prints one line'
    Assert-Same ($out[0] | ConvertFrom-Json).status 'failed' 'real process failure status'
    'scansnap-update-prompts: real registry cases skipped: they need Windows, and run in the windows-2022 CI job'
} elseif ($env:GITHUB_ACTIONS -ne 'true') {
    'scansnap-update-prompts: real registry cases skipped: they write HKLM, so they run only on a throwaway CI runner'
} else {
    # A 32-bit Windows PowerShell 5.1 process must read and write the 64-bit view.
    $ps32 = Join-Path $env:SystemRoot 'SysWOW64/WindowsPowerShell/v1.0/powershell.exe'
    $name = 'ScanSnap Online Update CI test'
    $savedPath = $env:PSModulePath
    $env:PSModulePath = $null
    function Invoke-Real { param([string[]]$Extra)
        $o = @(& $ps32 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $modulePath @Extra)
        Assert-Same $o.Count 1 'real run prints one line'
        [pscustomobject]@{ Code = $LASTEXITCODE; Json = ($o[0] | ConvertFrom-Json) }
    }
    function Get-RegBinary { param([string]$View, [string]$Key)
        (& reg.exe query "HKLM\$Key" /v $name "/reg:$View" 2>$null | Select-String 'REG_BINARY') -replace '.*REG_BINARY\s+', ''
    }
    $bitness = & $ps32 -NoProfile -Command '[IntPtr]::Size'
    Assert-Same $bitness 4 'the test process is really 32-bit'
    try {
        & reg.exe add "HKLM\$run64" /v $name /d 'C:\ci\SsUWatcher.exe' /f /reg:64 | Out-Null
        & reg.exe add "HKLM\$run64" /v $name /d 'C:\ci32\SsUWatcher.exe' /f /reg:32 | Out-Null
        $r = Invoke-Real @('-ReportOnly')
        Assert-Same $r.Code 1 'real report-only exit'
        Assert-Same $r.Json.status 'drift' 'real report-only sees both views'
        Assert-Same $r.Json.found 2 'real report-only found both views'
        Assert-True (-not (Get-RegBinary 64 "$approved\Run")) 'real report-only wrote nothing'
        $r = Invoke-Real @()
        Assert-Same $r.Code 0 'real fix exit'
        Assert-Same $r.Json.status 'fixed' 'real fix status'
        Assert-True ((Get-RegBinary 64 "$approved\Run") -like '03000000*') 'real fix wrote StartupApproved\Run in the 64-bit view'
        Assert-True ((Get-RegBinary 64 "$approved\Run32") -like '03000000*') 'real fix wrote StartupApproved\Run32 in the 64-bit view'
        Assert-True (-not (Get-RegBinary 32 "$approved\Run")) 'real fix did not write the redirected 32-bit view'
        $r = Invoke-Real @()
        Assert-Same $r.Code 0 'real second run exit'
        Assert-Same $r.Json.status 'compliant' 'real second run status'
    } finally {
        foreach ($view in @(64, 32)) {
            foreach ($key in @($run64, "$approved\Run", "$approved\Run32")) {
                & reg.exe delete "HKLM\$key" /v $name /f "/reg:$view" 2>$null | Out-Null
            }
        }
        $global:LASTEXITCODE = 0
        $env:PSModulePath = $savedPath
    }
    'scansnap-update-prompts: real 32-bit registry cases ran'
}

'scansnap-update-prompts tests passed'
exit 0
