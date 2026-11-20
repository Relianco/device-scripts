<#
.SYNOPSIS
    Extends the system volume (C:) online into unallocated space right after it, after a virtual disk was grown.

.DESCRIPTION
    For a VM whose system disk was made bigger on the host. Windows sees the new size only after a storage rescan,
    and the volume grows only into free space that directly follows it on the same disk. Run it as SYSTEM through
    the deploy runner. It never reboots, never moves, deletes or creates a partition, and never shrinks anything.

    Package arguments (base64 JSON in the runner's -PackageArguments), all string values:
      Section   'Evidence' is read-only: the system partition, its disk, the partitions on that disk, the largest size
                Windows supports for it and the unallocated bytes after it. Nothing changes (no rescan either).

    -Action Install (Update, Repair): rescan storage, then refuse when any partition starts after the system
      partition (a recovery partition there blocks a simple extend; moving it is a manual decision). Otherwise extend
      to the largest supported size and read it back. Less than 16 MiB to gain is 'compliant', no change.
    -Action Uninstall: refused. A volume is not shrunk by this package.
    An empty -PinVersion exits 0 and changes nothing.
    No download. Prints one JSON line, at most 2000 bytes. Exit 0 on success, 1 on any refusal or error.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType = '',
    [string]$Action = '',
    [string]$PinVersion = '',
    [string]$Section = ''
)

$ErrorActionPreference = 'Stop'
$script:EsMinGain = 16MB
$script:EsMaxBytes = 2000

# Seams. Tests replace these; the defaults touch the real disks.
$script:EsDriveLetter = { ([string]$env:SystemDrive).TrimEnd(':') }
$script:EsRescan = { Update-HostStorageCache }
$script:EsPartition = { param($letter) Get-Partition -DriveLetter $letter }
$script:EsDiskPartitions = { param($disk) @(Get-Partition -DiskNumber $disk) }
$script:EsDisk = { param($disk) Get-Disk -Number $disk }
$script:EsSupported = { param($letter) Get-PartitionSupportedSize -DriveLetter $letter }
$script:EsResize = { param($letter, $size) Resize-Partition -DriveLetter $letter -Size $size }

function Get-EsState {
    param([string]$Letter)
    $p = & $script:EsPartition $Letter
    $disk = & $script:EsDisk $p.DiskNumber
    $parts = @(& $script:EsDiskPartitions $p.DiskNumber)
    $after = @($parts | Where-Object { [uint64]$_.Offset -gt [uint64]$p.Offset })
    $s = & $script:EsSupported $Letter
    [ordered]@{
        DriveLetter      = $Letter
        DiskNumber       = [int]$p.DiskNumber
        PartitionStyle   = [string]$disk.PartitionStyle
        DiskSize         = [uint64]$disk.Size
        PartitionNumber  = [int]$p.PartitionNumber
        Offset           = [uint64]$p.Offset
        Size             = [uint64]$p.Size
        SizeMax          = [uint64]$s.SizeMax
        Gain             = [uint64][Math]::Max([double]0, [double]$s.SizeMax - [double]$p.Size)
        PartitionsAfter  = @($after | Select-Object -First 4 | ForEach-Object { [ordered]@{ Number = [int]$_.PartitionNumber; Offset = [uint64]$_.Offset; Size = [uint64]$_.Size; Type = [string]$_.Type } })
    }
}

function Invoke-EsMain {
    param([string]$Action = '', [string]$Section = '', [string]$PinVersion = 'pinned')
    $result = [ordered]@{ Package = 'extend-system-volume'; Action = $Action; Section = $Section; Status = 'error' }
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { $result.Status = 'disabled'; return @{ ExitCode = 0; Result = $result } }
    $fail = { param($reason) $result.Reason = $reason; return @{ ExitCode = 1; Result = $result } }
    if ($Section -notin @('', 'Evidence')) { return & $fail 'unsupported section' }
    $evidence = $Section -eq 'Evidence'
    if (-not $evidence) {
        if ($Action -eq 'Uninstall') { return & $fail 'Uninstall is refused: this package never shrinks a volume' }
        if ($Action -notin @('Install', 'Update', 'Repair')) { return & $fail 'unsupported action' }
    }
    $letter = [string](& $script:EsDriveLetter)
    if ($letter -cnotmatch '\A[A-Z]\z') { return & $fail 'system drive letter not found' }

    if ($evidence) {
        $result.Before = Get-EsState $letter
        $result.Status = 'evidence'
        return @{ ExitCode = 0; Result = $result }
    }

    & $script:EsRescan
    $before = Get-EsState $letter
    $result.Before = $before
    if ($before.PartitionsAfter.Count -gt 0) { return & $fail 'a partition follows the system partition; not extended (move or remove it by hand first)' }
    if ($before.Gain -lt $script:EsMinGain) { $result.Status = 'compliant'; return @{ ExitCode = 0; Result = $result } }
    & $script:EsResize $letter $before.SizeMax
    $after = Get-EsState $letter
    $result.After = $after
    if ($after.Size -lt $before.SizeMax - $script:EsMinGain) { return & $fail 'read-back size is smaller than requested' }
    $result.Status = 'extended'
    return @{ ExitCode = 0; Result = $result }
}

function ConvertTo-EsLine($Result) {
    $line = ConvertTo-Json -InputObject $Result -Depth 5 -Compress
    if ([System.Text.Encoding]::UTF8.GetByteCount($line) -gt $script:EsMaxBytes) {
        foreach ($k in @('After', 'Before')) { if ($Result.Contains($k)) { $Result[$k].PartitionsAfter = @() } }
        if ($Result.Contains('Reason')) { $Result.Reason = ([string]$Result.Reason).Substring(0, [Math]::Min(200, ([string]$Result.Reason).Length)) }
        $line = ConvertTo-Json -InputObject $Result -Depth 5 -Compress
    }
    return $line
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

try {
    $run = Invoke-EsMain -Action $Action -Section $Section -PinVersion $PinVersion
} catch {
    $run = @{ ExitCode = 1; Result = [ordered]@{ Package = 'extend-system-volume'; Status = 'error'; Reason = $_.Exception.Message } }
}
Write-Output (ConvertTo-EsLine $run.Result)
exit $run.ExitCode
