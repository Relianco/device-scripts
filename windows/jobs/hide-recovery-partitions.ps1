# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Removes drive letters assigned to
# Windows Recovery (GPT {de94bba4-06d1-4d40-a16a-bfd50179d6ac}, MBR 0x27) or EFI System
# ({c12a7328-f81f-11d2-ba4b-00a0c93ec93b}) partitions that are 4 GiB or smaller.
# Never touches the OS drive letter ($env:SystemDrive), any IsBoot partition, any partition over 4 GiB, or any other
# partition type. Before removing a drive letter, writes a JSON snapshot under
# C:\ProgramData\Relian\RecoveryPartitionLetterBackup (SYSTEM-only, never overwritten) and reads it back.
# A failed backup or a partition change between snapshot and removal stops the run with nothing removed.
# -ReportOnly changes and writes nothing. Exit 0 unchanged or removed, 1 drift with -ReportOnly, 2 failed.
# Prints one JSON line on stdout.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:RpGptWinRe = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$script:RpGptEfi = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:RpMbrWinRe = 39
$script:RpMaxBytes = 4294967296L
$script:RpBackupDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\RecoveryPartitionLetterBackup'
$script:RpSystemDrive = $env:SystemDrive

$script:RpProtectDir = {
    param($Path)
    foreach ($d in @((Split-Path -Parent $Path), $Path)) {
        if ($d -and (Test-Path -LiteralPath $d) -and ((Get-Item -LiteralPath $d -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'refusing reparse point on backup path'
        }
    }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;SY)')
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$script:RpReadPartitions = {
    $parts = @(Get-Partition -ErrorAction Stop)
    $out = [Collections.Generic.List[object]]::new()
    foreach ($p in $parts) {
        $rawLetter = [string]$p.DriveLetter
        $letter = if ($rawLetter -and $rawLetter[0] -ne [char]0) { $rawLetter.Trim() } else { '' }
        $gpt = if ($p.PSObject.Properties['GptType'] -and $null -ne $p.GptType) { [string]$p.GptType } else { '' }
        $mbr = if ($p.PSObject.Properties['MbrType'] -and $null -ne $p.MbrType) { [int]$p.MbrType } else { $null }
        $guid = if ($p.PSObject.Properties['Guid'] -and $null -ne $p.Guid) { [string]$p.Guid } else { '' }
        $out.Add(@{
            diskNumber      = [int]$p.DiskNumber
            partitionNumber = [int]$p.PartitionNumber
            driveLetter     = $letter
            gptType         = $gpt
            mbrType         = $mbr
            size            = [long]$p.Size
            isBoot          = [bool]$p.IsBoot
            guid            = $guid
        })
    }
    return @($out)
}

$script:RpRemoveLetter = {
    param([int]$DiskNumber, [int]$PartitionNumber, [string]$DriveLetter)
    Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -AccessPath "${DriveLetter}:\" -ErrorAction Stop
}

function Get-RpOsLetter {
    param([AllowEmptyString()][string]$SystemDrive)
    if ($SystemDrive -match '\A\s*([A-Za-z])(?::|\\|\z)') {
        return $Matches[1].ToUpperInvariant()
    }
    throw 'cannot determine OS drive letter'
}

function Get-RpProp {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $Default
    }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

function Get-RpPartitionKind {
    param($Partition)
    $gptRaw = Get-RpProp $Partition 'gptType' ''
    $gpt = if ($null -ne $gptRaw) { ([string]$gptRaw).Trim().ToLowerInvariant() } else { '' }
    if ($gpt) {
        if ($gpt -eq $script:RpGptWinRe) { return 'gpt-winre' }
        if ($gpt -eq $script:RpGptEfi) { return 'gpt-efi' }
        return $null
    }
    $mbrRaw = Get-RpProp $Partition 'mbrType' $null
    if ($null -ne $mbrRaw -and [int]$mbrRaw -eq $script:RpMbrWinRe) { return 'mbr-winre' }
    return $null
}

# Pure: filters partitions to mounted Recovery or EFI System partitions that are safe to hide.
function Get-RpTargets {
    param($Partitions, [AllowEmptyString()][string]$SystemDrive = $script:RpSystemDrive)
    $osLetter = Get-RpOsLetter $SystemDrive
    $found = [Collections.Generic.List[object]]::new()
    foreach ($p in @($Partitions)) {
        if ($null -eq $p) { continue }
        $dlRaw = Get-RpProp $p 'driveLetter' ''
        $dl = if ($null -ne $dlRaw) { ([string]$dlRaw).Trim() } else { '' }
        if ($dl -notmatch '\A[A-Za-z]\z') { continue }
        $dlUpper = $dl.ToUpperInvariant()
        if ($dlUpper -eq $osLetter) { continue }
        if ([bool](Get-RpProp $p 'isBoot' $false)) { continue }
        $size = [long](Get-RpProp $p 'size' 0)
        if ($size -le 0 -or $size -gt $script:RpMaxBytes) { continue }
        $kind = Get-RpPartitionKind $p
        if (-not $kind) { continue }
        $found.Add([ordered]@{
            diskNumber      = [int](Get-RpProp $p 'diskNumber' 0)
            partitionNumber = [int](Get-RpProp $p 'partitionNumber' 0)
            driveLetter     = $dlUpper
            kind            = $kind
            gptType         = [string](Get-RpProp $p 'gptType' '')
            mbrType         = (Get-RpProp $p 'mbrType' $null)
            size            = $size
            guid            = [string](Get-RpProp $p 'guid' '')
        })
    }
    $sorted = @($found | Sort-Object @{ Expression = { $_.diskNumber } }, @{ Expression = { $_.partitionNumber } })
    return $sorted
}

function Get-RpSummary {
    param($Targets)
    $list = [Collections.Generic.List[object]]::new()
    foreach ($t in @($Targets)) {
        if ($null -eq $t) { continue }
        $list.Add([ordered]@{
            diskNumber      = [int](Get-RpProp $t 'diskNumber' 0)
            partitionNumber = [int](Get-RpProp $t 'partitionNumber' 0)
            driveLetter     = [string](Get-RpProp $t 'driveLetter' '')
            kind            = [string](Get-RpProp $t 'kind' '')
            size            = [long](Get-RpProp $t 'size' 0)
        })
    }
    return @($list)
}

function Test-RpTargetsEqual {
    param($Expected, $Actual)
    $a = @($Expected)
    $b = @($Actual)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ([int](Get-RpProp $a[$i] 'diskNumber' -1) -ne [int](Get-RpProp $b[$i] 'diskNumber' -1) -or
            [int](Get-RpProp $a[$i] 'partitionNumber' -1) -ne [int](Get-RpProp $b[$i] 'partitionNumber' -1) -or
            [string](Get-RpProp $a[$i] 'driveLetter' '') -ne [string](Get-RpProp $b[$i] 'driveLetter' '') -or
            [string](Get-RpProp $a[$i] 'kind' '') -ne [string](Get-RpProp $b[$i] 'kind' '') -or
            [long](Get-RpProp $a[$i] 'size' -1) -ne [long](Get-RpProp $b[$i] 'size' -1) -or
            [string](Get-RpProp $a[$i] 'guid' '') -ne [string](Get-RpProp $b[$i] 'guid' '')) {
            return $false
        }
    }
    return $true
}

# Writes a new backup file and reads it back. CreateNew: an existing file is never overwritten. Throws on any failure.
function Write-RpBackup {
    param($Partitions, $Targets)
    $null = New-Item -ItemType Directory -Path $script:RpBackupDir -Force
    & $script:RpProtectDir $script:RpBackupDir
    $name = 'backup-{0}-{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $path = Join-Path $script:RpBackupDir $name
    $targetList = @($Targets)
    $doc = [ordered]@{
        schemaVersion = 1
        createdUtc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        systemDrive   = $script:RpSystemDrive
        targets       = $targetList
        partitions    = @($Partitions)
    }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($doc | ConvertTo-Json -Depth 8))
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
    $back = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json
    $backTargets = @($back.targets)
    if (-not (Test-RpTargetsEqual $targetList $backTargets)) {
        throw 'backup read-back differs from targets'
    }
    return $name
}

function Invoke-RpJob {
    param([switch]$ReportOnly)
    $mode = $(if ($ReportOnly) { 'report' } else { 'run' })
    $r = @{ ExitCode = 2; Status = 'failed'; Mode = $mode; Before = @(); After = @(); Backup = $null; Error = '' }
    try {
        $partitions = @(& $script:RpReadPartitions)
        $targets = @(Get-RpTargets $partitions $script:RpSystemDrive)
        $r.Before = @(Get-RpSummary $targets)
        if ($targets.Count -eq 0) {
            $r.After = @()
            $r.Status = 'unchanged'
            $r.ExitCode = 0
        } elseif ($ReportOnly) {
            $r.After = $r.Before
            $r.Status = 'drift'
            $r.ExitCode = 1
        } else {
            $r.Backup = Write-RpBackup $partitions $targets
            $live = @(Get-RpTargets (& $script:RpReadPartitions) $script:RpSystemDrive)
            if (-not (Test-RpTargetsEqual $targets $live)) {
                throw 'partition targets changed after the snapshot, nothing removed'
            }
            $removeErr = ''
            foreach ($t in $targets) {
                try {
                    & $script:RpRemoveLetter $t.diskNumber $t.partitionNumber $t.driveLetter
                } catch {
                    $removeErr = $_.Exception.Message
                    break
                }
            }
            $after = @(Get-RpTargets (& $script:RpReadPartitions) $script:RpSystemDrive)
            $r.After = @(Get-RpSummary $after)
            if ($removeErr) {
                $r.Error = $removeErr
            } elseif ($after.Count -eq 0) {
                $r.Status = 'removed'
                $r.ExitCode = 0
            } else {
                $r.Error = 'drive letter still present after removal'
            }
        }
    } catch {
        $r.Error = $_.Exception.Message
    }
    return [pscustomobject]$r
}

# Only characters JSON never escapes, so the line stays short and plain.
function Get-RpSafeText {
    param([AllowEmptyString()][string]$Text, [int]$Limit)
    $safe = $Text -replace '[^A-Za-z0-9 ._:()-]', '_'
    return $safe.Substring(0, [Math]::Min($safe.Length, $Limit))
}

function ConvertTo-RpJobLine {
    param([Parameter(Mandatory)]$Result)
    [ordered]@{
        job    = 'hide-recovery-partitions'
        mode   = $Result.Mode
        status = $Result.Status
        before = @($Result.Before)
        after  = @($Result.After)
        backup = $Result.Backup
        error  = Get-RpSafeText $Result.Error 200
    } | ConvertTo-Json -Depth 6 -Compress
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$jobResult = Invoke-RpJob -ReportOnly:$ReportOnly
Write-Output (ConvertTo-RpJobLine $jobResult)
exit $jobResult.ExitCode
