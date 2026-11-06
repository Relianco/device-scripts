# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Stops ScanSnap Online Update
# prompting staff who cannot install updates. Marks the watcher's Run entry disabled the way Task Manager
# does and stops a running watcher. The Run entry and ScanSnap itself are untouched, so an admin can still
# run Start > ScanSnap Online Update. Machines without ScanSnap report compliant.
# Exit 0 compliant or fixed, 1 drift with -ReportOnly, 2 failed. Prints one JSON line of at most 1024 characters.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$approved = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$script:SsViews = @(
    @{ Run = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = "$approved\Run" },
    @{ Run = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "$approved\Run32" }
)

# Ninja's PowerShell bitness is unconfirmed, and a 32-bit process would be redirected away from the real
# keys. Registry64 reaches the same keys from either. A denied read throws, so it is never reported compliant.
function Open-SsHklm {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
}

$script:SsReadValues = {
    param($Path)
    $values = @{}
    $key = (Open-SsHklm).OpenSubKey($Path)
    if ($key) {
        try {
            foreach ($name in $key.GetValueNames()) { $values[$name] = $key.GetValue($name) }
        } finally {
            $key.Dispose()
        }
    }
    return $values
}

$script:SsWriteBinary = {
    param($Path, $Name, [byte[]]$Data)
    $key = (Open-SsHklm).CreateSubKey($Path)
    try {
        $key.SetValue($Name, $Data, [Microsoft.Win32.RegistryValueKind]::Binary)
    } finally {
        $key.Dispose()
    }
}

$script:SsCountWatchers = { @(Get-Process -Name SsUWatcher -ErrorAction SilentlyContinue).Count }

$script:SsStopWatchers = {
    # The re-detect decides the result, so a watcher that exits first or cannot be stopped is not an error here.
    foreach ($process in @(Get-Process -Name SsUWatcher -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $process.Id -Timeout 5 -ErrorAction SilentlyContinue
    }
}

function Get-ScanSnapState {
    $found = 0
    $enabled = [Collections.Generic.List[object]]::new()
    foreach ($view in $script:SsViews) {
        $states = & $script:SsReadValues $view.Approved
        $values = & $script:SsReadValues $view.Run
        # The source's PS* skip is gone: RegistryKey has none of the provider's synthetic PS* properties.
        foreach ($entry in $values.GetEnumerator()) {
            # Review finding rejected: this match stays as broad as the Intune Remediation it replaces,
            # because the maintainer asked for a faithful port. Another product's Run entry containing
            # OnlineUpdate is disabled too. Use -ReportOnly to see what matches, and narrow it if one appears.
            if ("$($entry.Key) $($entry.Value)" -notmatch 'SsUWatcher|OnlineUpdate') { continue }
            $found++
            # Task Manager's format: first byte 3 = disabled.
            $state = $states[$entry.Key]
            if (-not ($state -is [byte[]] -and $state.Length -gt 0 -and $state[0] -eq 3)) {
                $enabled.Add([pscustomobject]@{ Name = [string]$entry.Key; Approved = $view.Approved })
            }
        }
    }
    [pscustomobject]@{ Found = $found; Enabled = $enabled; Running = [int](& $script:SsCountWatchers) }
}

function Invoke-ScanSnapJob {
    param([switch]$ReportOnly)
    $state = [pscustomobject]@{ Found = 0; Enabled = @(); Running = 0 }
    $status = 'failed'
    $exitCode = 2
    $problem = ''
    try {
        $state = Get-ScanSnapState
        if ($state.Enabled.Count -eq 0 -and $state.Running -eq 0) {
            $status = 'compliant'
            $exitCode = 0
        } elseif ($ReportOnly) {
            $status = 'drift'
            $exitCode = 1
        } else {
            # Byte 0 = 3 is disabled. Bytes 4-11 are the time it was disabled. The cast matters: an
            # array sum is object[], which SetValue with RegistryValueKind.Binary rejects.
            $value = [byte[]]((3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()))
            foreach ($item in $state.Enabled) { & $script:SsWriteBinary $item.Approved $item.Name $value }
            & $script:SsStopWatchers
            $after = Get-ScanSnapState
            if ($after.Enabled.Count -eq 0 -and $after.Running -eq 0) {
                $status = 'fixed'
                $exitCode = 0
            } else {
                $state = $after
                $problem = 'still active after the fix'
            }
        }
    } catch {
        $problem = $_.Exception.Message
    }
    [pscustomobject]@{
        ExitCode = $exitCode; Status = $status; ReportOnly = [bool]$ReportOnly; Found = $state.Found
        Running = $state.Running; Enabled = $state.Enabled; Error = $problem
    }
}

# Only characters JSON never escapes, so the cuts below prove the bound on both PowerShell versions.
function Get-SsSafeText {
    param([AllowEmptyString()][string]$Text, [int]$Limit)
    $safe = $Text -replace '[^A-Za-z0-9 ._:()-]', '_'
    return $safe.Substring(0, [Math]::Min($safe.Length, $Limit))
}

function ConvertTo-ScanSnapJobLine {
    param([Parameter(Mandatory)]$Result)
    $names = @($Result.Enabled | Select-Object -First 10 | ForEach-Object { Get-SsSafeText $_.Name 64 })
    [ordered]@{
        job = 'scansnap-update-prompts'; status = $Result.Status; reportOnly = $Result.ReportOnly
        found = $Result.Found; running = $Result.Running; enabled = $names
        error = Get-SsSafeText $Result.Error 200
    } | ConvertTo-Json -Compress
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$jobResult = Invoke-ScanSnapJob -ReportOnly:$ReportOnly
Write-Output (ConvertTo-ScanSnapJobLine $jobResult)
exit $jobResult.ExitCode
