# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Removes drive letters assigned to
# Windows Recovery (GPT {de94bba4-06d1-4d40-a16a-bfd50179d6ac}, MBR 0x27) or EFI System
# ({c12a7328-f81f-11d2-ba4b-00a0c93ec93b}) partitions that are 4 GiB or smaller.
# Never touches the OS drive letter ($env:SystemDrive), any IsBoot partition, any partition over 4 GiB, or any other
# partition type. Before removing a drive letter, writes a JSON snapshot under
# C:\ProgramData\Relian\RecoveryPartitionLetterBackup (SYSTEM-only, never overwritten) and reads it back.
# A failed backup or a partition change before removal stops the run.
# -ReportOnly changes and writes nothing. Exit 0 unchanged or removed, 1 drift with -ReportOnly, 2 failed.
# Prints one JSON line on stdout.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:RpGptWinRe = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$script:RpGptEfi = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:RpGptZero = '{00000000-0000-0000-0000-000000000000}'
$script:RpMbrWinRe = 39
$script:RpMaxBytes = 4294967296L
$script:RpLabelMaxBytes = 2147483648L
$script:RpBackupDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\RecoveryPartitionLetterBackup'
$script:RpSystemDrive = $env:SystemDrive

$script:RpReadSddl = { param($Path) (Get-Acl -LiteralPath $Path).Sddl }

$script:RpAssertNotReparse = {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $full = [IO.Path]::GetFullPath($p)
        $root = [IO.Path]::GetPathRoot($full)
        $cur = $(if ($full.Length -gt $root.Length) { $full.TrimEnd('\', '/') } else { $full })
        while ($cur -and $cur -ne $root) {
            if ((Test-Path -LiteralPath $cur) -and ((Get-Item -LiteralPath $cur -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'refusing reparse point on backup path'
            }
            $parent = Split-Path -Parent $cur
            if (-not $parent -or $parent -eq $cur) { break }
            $cur = $parent
        }
    }
}

$script:RpProtectDir = {
    param($Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;SY)')
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$script:RpReadPartitions = {
    $parts = @(Get-Partition -ErrorAction Stop)
    $volsByLetter = @{}
    foreach ($v in @(Get-Volume -ErrorAction Stop)) {
        $vl = if ($v.PSObject.Properties['DriveLetter'] -and $null -ne $v.DriveLetter) { [string]$v.DriveLetter } else { '' }
        if ($vl -and $vl[0] -ne [char]0 -and $vl.Trim() -match '\A[A-Za-z]\z') {
            $lbl = if ($v.PSObject.Properties['FileSystemLabel'] -and $null -ne $v.FileSystemLabel) { [string]$v.FileSystemLabel } else { '' }
            $volsByLetter[$vl.Trim().ToUpperInvariant()] = $lbl
        }
    }
    $out = [Collections.Generic.List[object]]::new()
    foreach ($p in $parts) {
        $rawLetter = [string]$p.DriveLetter
        $letter = if ($rawLetter -and $rawLetter[0] -ne [char]0) { $rawLetter.Trim() } else { '' }
        $gpt = if ($p.PSObject.Properties['GptType'] -and $null -ne $p.GptType) { [string]$p.GptType } else { '' }
        $mbr = if ($p.PSObject.Properties['MbrType'] -and $null -ne $p.MbrType) { [int]$p.MbrType } else { $null }
        $guid = if ($p.PSObject.Properties['Guid'] -and $null -ne $p.Guid) { [string]$p.Guid } else { '' }
        $label = if ($letter -and $volsByLetter.ContainsKey($letter.ToUpperInvariant())) { [string]$volsByLetter[$letter.ToUpperInvariant()] } else { '' }
        $out.Add(@{
            diskNumber      = [int]$p.DiskNumber
            partitionNumber = [int]$p.PartitionNumber
            driveLetter     = $letter
            gptType         = $gpt
            mbrType         = $mbr
            size            = [long]$p.Size
            isBoot          = [bool]$p.IsBoot
            guid            = $guid
            label           = $label
        })
    }
    return @($out)
}

$script:RpRemoveLetter = {
    param([int]$DiskNumber, [int]$PartitionNumber, [string]$DriveLetter)
    Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -AccessPath "${DriveLetter}:\" -ErrorAction Stop
}

# Owner must be SYSTEM or Administrators; DACL must be protected, inheritable to files, and allow SYSTEM only.
function Test-RpBackupAcl {
    param([AllowEmptyString()][string]$Sddl)
    return ($Sddl -match '\AO:(SY|BA)G:[^:]*D:([A-Z]*)(\(A;(?=[^;()]*OI)(?=[^;()]*CI)[A-Z]*;[^;()]*;;;SY\))+\z' -and $Matches[2].Contains('P'))
}

$script:RpSddlRightMap = @{
    'CC' = 0x00000001L; 'DC' = 0x00000002L; 'LC' = 0x00000004L; 'SW' = 0x00000008L
    'RP' = 0x00000010L; 'WP' = 0x00000020L; 'DT' = 0x00000040L; 'LO' = 0x00000080L
    'CR' = 0x00000100L; 'SD' = 0x00010000L; 'RC' = 0x00020000L; 'WD' = 0x00040000L
    'WO' = 0x00080000L; 'GA' = 0x10000000L; 'GX' = 0x20000000L; 'GW' = 0x40000000L
    'GR' = 0x80000000L; 'FA' = 0x001F01FFL; 'FR' = 0x00120089L; 'FW' = 0x00120116L
    'FX' = 0x001200A0L; 'KA' = 0x000F003FL; 'KR' = 0x00020019L; 'KW' = 0x00020006L
    'KX' = 0x00020019L
}

function ConvertFrom-RpSddlRights {
    param([AllowEmptyString()][string]$Rights)
    if ([string]::IsNullOrWhiteSpace($Rights)) { return -1L }
    if ($Rights -match '\A0x([0-9a-fA-F]{1,8})\z') {
        return [Convert]::ToInt64($Matches[1], 16)
    }
    if (($Rights.Length % 2) -ne 0) { return -1L }
    $mask = 0L
    for ($i = 0; $i -lt $Rights.Length; $i += 2) {
        $tok = $Rights.Substring($i, 2).ToUpperInvariant()
        if (-not $script:RpSddlRightMap.ContainsKey($tok)) { return -1L }
        $mask = $mask -bor $script:RpSddlRightMap[$tok]
    }
    return $mask
}

# Parent directory must be owned by SYSTEM or Administrators with no non-admin write, create, delete, or ownership-change ACEs.
function Test-RpParentAcl {
    param([AllowEmptyString()][string]$Sddl)
    if ($Sddl -notmatch '\AO:(SY|BA)G:[^:]*D:[^()]*((?:\([^()]+\))+)\z') { return $false }
    $aces = [regex]::Matches($Matches[2], '\(([^()]+)\)')
    foreach ($m in $aces) {
        $parts = $m.Groups[1].Value -split ';'
        if ($parts.Count -lt 6) { return $false }
        $aceType = $parts[0]
        $aceFlags = $parts[1]
        $rights = $parts[2]
        $trustee = $parts[5]
        if ($aceType -ne 'A') { continue }
        if ($trustee -in @('SY', 'BA')) { continue }
        if ($aceFlags -match 'IO') { continue }
        $mask = ConvertFrom-RpSddlRights $rights
        if ($mask -lt 0) { return $false }
        # Reject generic all/write, delete, delete-child (DT/0x40), write-dac, write-owner, write-data/create-file (DC/0x2), append-data/create-subdir (LC/0x4), write-ea (RP/0x10), write-attributes (CR/0x100).
        if (($mask -band 0x500D0156L) -ne 0) { return $false }
    }
    return $true
}

function Ensure-RpBackupDirectory {
    param([string]$BackupDir)
    $parent = Split-Path -Parent $BackupDir
    $chain = @($parent, $BackupDir)
    & $script:RpAssertNotReparse $chain
    if ($parent) {
        if (-not (Test-Path -LiteralPath $parent)) {
            $null = New-Item -ItemType Directory -Path $parent -Force
            & $script:RpAssertNotReparse @($parent)
            & $script:RpProtectDir $parent
        } elseif (-not (Test-RpParentAcl (& $script:RpReadSddl $parent))) {
            & $script:RpAssertNotReparse @($parent)
            & $script:RpProtectDir $parent
        }
        if (-not (Test-RpParentAcl (& $script:RpReadSddl $parent))) {
            throw 'refusing backup parent directory with untrusted owner or ACL'
        }
    }
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        $null = New-Item -ItemType Directory -Path $BackupDir -Force
        & $script:RpAssertNotReparse $chain
        & $script:RpProtectDir $BackupDir
    } elseif (-not (Test-RpBackupAcl (& $script:RpReadSddl $BackupDir))) {
        & $script:RpAssertNotReparse $chain
        & $script:RpProtectDir $BackupDir
    }
    if (-not (Test-RpBackupAcl (& $script:RpReadSddl $BackupDir))) {
        throw 'refusing backup directory with untrusted owner or ACL'
    }
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

function Get-RpOsLetter {
    param([AllowEmptyString()][string]$SystemDrive)
    if ($SystemDrive -match '\A\s*([A-Za-z])(?::|\\|\z)') {
        return $Matches[1].ToUpperInvariant()
    }
    throw 'cannot determine OS drive letter'
}

function Get-RpPartitionKind {
    param($Partition)
    $gptRaw = Get-RpProp $Partition 'gptType' ''
    $gpt = if ($null -ne $gptRaw) { ([string]$gptRaw).Trim().ToLowerInvariant() } else { '' }
    if ($gpt -and $gpt -ne $script:RpGptZero) {
        if ($gpt -eq $script:RpGptWinRe) { return 'gpt-winre' }
        if ($gpt -eq $script:RpGptEfi) { return 'gpt-efi' }
    } else {
        $mbrRaw = Get-RpProp $Partition 'mbrType' $null
        if ($null -ne $mbrRaw -and [int]$mbrRaw -eq $script:RpMbrWinRe) { return 'mbr-winre' }
    }
    $size = [long](Get-RpProp $Partition 'size' 0)
    $lblRaw = Get-RpProp $Partition 'label' ''
    $lbl = if ($null -ne $lblRaw) { ([string]$lblRaw).Trim() } else { '' }
    if ($size -gt 0 -and $size -le $script:RpLabelMaxBytes -and $lbl) {
        if ($lbl -imatch '\ASystem Reserved\z') { return 'label-system-reserved' }
        if ($lbl -imatch '\A(Recovery|WinRE|Windows RE tools)\z') { return 'label-recovery' }
    }
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
            label           = [string](Get-RpProp $p 'label' '')
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
            [string](Get-RpProp $a[$i] 'guid' '') -ne [string](Get-RpProp $b[$i] 'guid' '') -or
            [string](Get-RpProp $a[$i] 'label' '') -ne [string](Get-RpProp $b[$i] 'label' '')) {
            return $false
        }
    }
    return $true
}

# Writes a new backup file and reads it back. CreateNew: an existing file is never overwritten. Throws on any failure.
function Write-RpBackup {
    param($Partitions, $Targets)
    Ensure-RpBackupDirectory $script:RpBackupDir
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
                $liveNow = @(Get-RpTargets (& $script:RpReadPartitions) $script:RpSystemDrive)
                $match = @($liveNow | Where-Object { $_.diskNumber -eq $t.diskNumber -and $_.partitionNumber -eq $t.partitionNumber })
                if ($match.Count -ne 1 -or -not (Test-RpTargetsEqual @($t) $match)) {
                    $removeErr = 'partition target changed before removal'
                    break
                }
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
