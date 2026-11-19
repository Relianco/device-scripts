# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Removes exactly two policy values,
# NoAutoUpdate and AUOptions, under HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU and in local
# Group Policy (GroupPolicy\Machine\Registry.pol), and nothing else.
# Before it deletes, it writes the whole WindowsUpdate policy key and Registry.pol bytes to a new JSON file under
# C:\ProgramData\Relian\WuAutoPolicyBackup, SYSTEM-only. A backup that cannot be written and read back stops the run
# with nothing deleted. A backup is never overwritten. -Restore writes only those two values back (into the registry
# and spliced into Registry.pol) from the newest backup (or -BackupName). -ReportOnly changes and writes nothing, also
# with -Restore (a preview). Absent values: nothing changes, status unchanged.
# Exit 0 done or unchanged, 1 drift with -ReportOnly, 2 failed. Prints one JSON line.
# The job loader forwards only -ReportOnly; -Restore and -BackupName reach the module only when it is run directly.
[CmdletBinding()]
param([switch]$ReportOnly, [switch]$Restore, [string]$BackupName)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:WuSubKey = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:WuTargets = @('NoAutoUpdate', 'AUOptions')   # the only values this module ever deletes or restores
$script:WuBackupDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\WuAutoPolicyBackup'

function Get-WuPolPath {
    $root = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $sys = [Environment]::GetFolderPath('System')
        if ([string]::IsNullOrWhiteSpace($sys)) { return $null }
        return (Join-Path $sys 'GroupPolicy\Machine\Registry.pol')
    }
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        return (Join-Path $root 'Sysnative\GroupPolicy\Machine\Registry.pol')
    }
    return (Join-Path $root 'System32\GroupPolicy\Machine\Registry.pol')
}
$script:WuPolPath = Get-WuPolPath

# Registry64 reaches the real key from a 32-bit process. A denied read throws, so it is never reported as absent.
function Open-WuHklm {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
}

# The whole policy key as a list of @{ path; values = @(@{ name; kind; data }) }. path is relative: '' root, 'AU'.
# Binary data is base64; a missing key gives an empty list.
$script:WuReadTree = {
    $out = [Collections.Generic.List[object]]::new()
    $walk = $null
    $walk = {
        param($Key, [string]$Rel)
        $values = @()
        foreach ($name in $Key.GetValueNames()) {
            $kind = [string]$Key.GetValueKind($name)
            $data = $Key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($data -is [byte[]]) { $data = [Convert]::ToBase64String($data) }
            $values += @{ name = $name; kind = $kind; data = $data }
        }
        $out.Add(@{ path = $Rel; values = $values })
        foreach ($sub in $Key.GetSubKeyNames()) {
            $child = $Key.OpenSubKey($sub)
            try { & $walk $child $(if ($Rel) { "$Rel\$sub" } else { $sub }) } finally { $child.Dispose() }
        }
    }
    $root = (Open-WuHklm).OpenSubKey($script:WuSubKey)
    if ($root) { try { & $walk $root '' } finally { $root.Dispose() } }
    return @($out)
}

$script:WuDeleteValue = {
    param([string]$Rel, [string]$Name)
    $key = (Open-WuHklm).OpenSubKey("$script:WuSubKey\$Rel", $true)
    if ($key) { try { $key.DeleteValue($Name, $false) } finally { $key.Dispose() } }
}

$script:WuSetValue = {
    param([string]$Rel, [string]$Name, [string]$Kind, $Data)
    $key = (Open-WuHklm).CreateSubKey("$script:WuSubKey\$Rel")
    try {
        if ($Kind -eq 'DWord') { $Data = [int]$Data } elseif ($Kind -eq 'QWord') { $Data = [long]$Data }
        elseif ($Kind -eq 'Binary') { $Data = [Convert]::FromBase64String([string]$Data) }
        elseif ($Kind -eq 'MultiString') { $Data = [string[]]@($Data) }
        $key.SetValue($Name, $Data, [Microsoft.Win32.RegistryValueKind]$Kind)
    } finally { $key.Dispose() }
}

$script:WuProtectDir = {
    param($Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('D:P(A;OICI;FA;;;SY)')
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$script:WuReadPolBytes = {
    if ([string]::IsNullOrWhiteSpace($script:WuPolPath) -or -not (Test-Path -LiteralPath $script:WuPolPath)) { return $null }
    return ,([byte[]][IO.File]::ReadAllBytes($script:WuPolPath))
}

$script:WuWritePolBytes = {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if ([string]::IsNullOrWhiteSpace($script:WuPolPath)) { throw 'Registry.pol path unavailable' }
    $dir = Split-Path -Parent $script:WuPolPath
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    if (Test-Path -LiteralPath $script:WuPolPath) {
        $attr = [IO.File]::GetAttributes($script:WuPolPath)
        $clear = [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden
        if ($attr -band $clear) { [IO.File]::SetAttributes($script:WuPolPath, ($attr -band (-bnot $clear))) }
    }
    $tmp = "$script:WuPolPath.tmp-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    try {
        [IO.File]::WriteAllBytes($tmp, $Bytes)
        Move-Item -LiteralPath $tmp -Destination $script:WuPolPath -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { [IO.File]::Delete($tmp) }
    }
    $back = [IO.File]::ReadAllBytes($script:WuPolPath)
    if ($back.Length -ne $Bytes.Length) { throw 'Registry.pol read-back size mismatch' }
    for ($idx = 0; $idx -lt $Bytes.Length; $idx++) {
        if ($back[$idx] -ne $Bytes[$idx]) { throw 'Registry.pol read-back byte mismatch' }
    }
}

function Get-WuSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256CryptoServiceProvider]::new()
    try {
        return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-WuBytesEqual {
    param([AllowNull()][byte[]]$A, [AllowNull()][byte[]]$B)
    if ($null -eq $A -and $null -eq $B) { return $true }
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    for ($idx = 0; $idx -lt $A.Length; $idx++) {
        if ($A[$idx] -ne $B[$idx]) { return $false }
    }
    return $true
}

# Pure: parses PReg Registry.pol bytes, extracts target AU DWord records (with raw bytes), and builds filtered bytes.
# Throws on structural errors or non-DWORD target entries so a corrupt/unexpected file never gets modified.
function Split-WuPolTargets {
    param([AllowNull()][byte[]]$Bytes, [string[]]$OnlyNames = $script:WuTargets)
    if ($null -eq $Bytes) { return @{ present = $false; targets = [ordered]@{}; filteredBytes = $null } }
    if ($Bytes.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -ne 'PReg' -or [BitConverter]::ToUInt32($Bytes, 4) -ne 1) {
        throw 'malformed Registry.pol'
    }
    $u = [Text.Encoding]::Unicode
    $auKey = "$script:WuSubKey\AU"
    $targets = [ordered]@{}
    $ms = [IO.MemoryStream]::new()
    $ms.Write($Bytes, 0, 8)
    $i = 8
    while ($i -lt $Bytes.Length) {
        $recStart = $i
        if ($i + 2 -gt $Bytes.Length -or [BitConverter]::ToUInt16($Bytes, $i) -ne 0x5B) { throw 'malformed Registry.pol' }
        $i += 2
        $parts = @()
        foreach ($n in 1..2) {
            $start = $i
            while ($i + 1 -lt $Bytes.Length -and [BitConverter]::ToUInt16($Bytes, $i) -ne 0) { $i += 2 }
            if ($i + 4 -gt $Bytes.Length -or [BitConverter]::ToUInt16($Bytes, $i) -ne 0 -or [BitConverter]::ToUInt16($Bytes, $i + 2) -ne 0x3B) {
                throw 'malformed Registry.pol'
            }
            $parts += $u.GetString($Bytes, $start, $i - $start)
            $i += 4
        }
        if ($i + 12 -gt $Bytes.Length) { throw 'malformed Registry.pol' }
        $type = [BitConverter]::ToUInt32($Bytes, $i)
        if ([BitConverter]::ToUInt16($Bytes, $i + 4) -ne 0x3B) { throw 'malformed Registry.pol' }
        $sizeU32 = [BitConverter]::ToUInt32($Bytes, $i + 6)
        if ([BitConverter]::ToUInt16($Bytes, $i + 10) -ne 0x3B) { throw 'malformed Registry.pol' }
        if ($sizeU32 -gt [uint32]($Bytes.Length - ($i + 12) - 2)) { throw 'malformed Registry.pol' }
        $size = [int]$sizeU32
        $dataOffset = $i + 12
        $i = $dataOffset + $size
        if ($i + 2 -gt $Bytes.Length -or [BitConverter]::ToUInt16($Bytes, $i) -ne 0x5D) { throw 'malformed Registry.pol' }
        $i += 2
        $recEnd = $i

        $matchedTarget = $null
        if ($parts[0] -ieq $auKey) {
            if ($parts[1] -imatch '\A\*\*del\.(NoAutoUpdate|AUOptions)\z') {
                throw 'conflicting delete directive in Registry.pol'
            }
            foreach ($t in @($OnlyNames)) {
                if ($parts[1] -ieq $t) { $matchedTarget = $t; break }
            }
        }
        if ($null -ne $matchedTarget) {
            if ($type -ne 4 -or $size -ne 4) { throw 'unsupported target type in Registry.pol' }
            $valData = [long][BitConverter]::ToUInt32($Bytes, $dataOffset)
            $recLen = $recEnd - $recStart
            $recBytes = [byte[]]::new($recLen)
            [Array]::Copy($Bytes, $recStart, $recBytes, 0, $recLen)
            $targets[$matchedTarget] = @{ kind = 'DWord'; data = $valData; rawBase64 = [Convert]::ToBase64String($recBytes) }
        } else {
            $ms.Write($Bytes, $recStart, $recEnd - $recStart)
        }
    }
    return @{ present = $true; targets = $targets; filteredBytes = $ms.ToArray() }
}

function Merge-WuPolTargets {
    param([AllowNull()][byte[]]$CurrentPolBytes, $PolTargetsDoc)
    $namesToRestore = @($script:WuTargets | Where-Object {
        $pt = $PolTargetsDoc.$_
        $pt -and $pt.present -and $pt.rawBase64
    })
    $split = Split-WuPolTargets -Bytes $CurrentPolBytes -OnlyNames $namesToRestore
    $ms = [IO.MemoryStream]::new()
    if ($split.present) {
        $ms.Write($split.filteredBytes, 0, $split.filteredBytes.Length)
    } else {
        $ms.Write([Text.Encoding]::ASCII.GetBytes('PReg'), 0, 4)
        $ms.Write([BitConverter]::GetBytes([uint32]1), 0, 4)
    }
    foreach ($n in $namesToRestore) {
        $entryBytes = [Convert]::FromBase64String([string]$PolTargetsDoc.$n.rawBase64)
        $ms.Write($entryBytes, 0, $entryBytes.Length)
    }
    return ,($ms.ToArray())
}

# Pure: the two target values from a tree, as name -> @{ kind; data }. Absent values are not in the result.
function Get-WuTargets {
    param($Tree)
    $found = [ordered]@{}
    foreach ($node in @($Tree)) {
        # An absent policy key makes WuReadTree emit nothing, so $Tree is $null here.
        if ($null -eq $node -or $node.path -ne 'AU') { continue }
        foreach ($v in @($node.values)) {
            if ($script:WuTargets -contains $v.name) { $found[$v.name] = @{ kind = $v.kind; data = $v.data } }
        }
    }
    return $found
}

# Pure: merges registry targets and Registry.pol targets (registry wins if both present).
function Get-WuMergedTargets {
    param($RegTargets, $PolTargets)
    $merged = [ordered]@{}
    foreach ($n in $script:WuTargets) {
        if ($RegTargets.Contains($n)) { $merged[$n] = $RegTargets[$n] }
        elseif ($PolTargets.Contains($n)) { $merged[$n] = $PolTargets[$n] }
    }
    return $merged
}

# Pure: name -> data, $null when absent, for the JSON line.
function Get-WuSummary {
    param($Targets)
    $s = [ordered]@{}
    foreach ($n in $script:WuTargets) { $s[$n] = $(if ($Targets.Contains($n)) { $Targets[$n].data } else { $null }) }
    return $s
}

# Writes a new backup file and reads it back. CreateNew: an existing file is never overwritten. Throws on any failure.
function Write-WuBackup {
    param($Tree, $RegTargets, $PolTargets, [AllowNull()][byte[]]$PolBytes)
    $null = New-Item -ItemType Directory -Path $script:WuBackupDir -Force
    & $script:WuProtectDir $script:WuBackupDir
    $name = 'backup-{0}-{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $path = Join-Path $script:WuBackupDir $name
    $targetRecord = [ordered]@{}
    $polTargetRecord = [ordered]@{}
    foreach ($n in $script:WuTargets) {
        $targetRecord[$n] = $(if ($RegTargets.Contains($n)) { @{ present = $true; kind = $RegTargets[$n].kind; data = $RegTargets[$n].data } } else { @{ present = $false } })
        $polTargetRecord[$n] = $(if ($PolTargets.Contains($n)) { @{ present = $true; kind = $PolTargets[$n].kind; data = $PolTargets[$n].data; rawBase64 = $PolTargets[$n].rawBase64 } } else { @{ present = $false } })
    }
    $polRecord = $(if ($null -ne $PolBytes) {
        [ordered]@{ present = $true; sha256 = (Get-WuSha256 $PolBytes); base64 = [Convert]::ToBase64String($PolBytes) }
    } else {
        [ordered]@{ present = $false }
    })
    $doc = [ordered]@{
        schemaVersion = 1; createdUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        key = "HKLM\$script:WuSubKey"; targets = $targetRecord; polTargets = $polTargetRecord; registryPol = $polRecord; tree = @($Tree)
    }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($doc | ConvertTo-Json -Depth 8))
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
    $back = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json
    foreach ($n in $script:WuTargets) {
        $want = $targetRecord[$n]
        $got = $back.targets.$n
        if ($want.present -ne $got.present -or ($want.present -and "$($want.data)" -ne "$($got.data)")) { throw "backup read-back differs for $n" }
        $wantPol = $polTargetRecord[$n]
        $gotPol = $back.polTargets.$n
        if ($wantPol.present -ne $gotPol.present -or ($wantPol.present -and $wantPol.rawBase64 -ne $gotPol.rawBase64)) { throw "backup read-back differs for polTargets.$n" }
    }
    if (($null -ne $PolBytes) -ne [bool]$back.registryPol.present) { throw 'backup read-back differs for registryPol' }
    if ($null -ne $PolBytes -and $back.registryPol.base64 -ne $polRecord.base64) { throw 'backup read-back differs for registryPol.base64' }
    return $name
}

# The named backup, or the newest. Throws when there is none or the name is not one this module writes.
function Read-WuBackup {
    param([string]$Name)
    if ($Name) {
        if ($Name -notmatch '\Abackup-\d{8}T\d{9}Z-[0-9a-f]{8}\.json\z') { throw 'bad backup name' }
    } else {
        $files = @(if (Test-Path -LiteralPath $script:WuBackupDir) { Get-ChildItem -LiteralPath $script:WuBackupDir -Filter 'backup-*.json' -File | Sort-Object Name })
        if ($files.Count -eq 0) { throw 'no backup found' }
        $Name = $files[-1].Name
    }
    $path = Join-Path $script:WuBackupDir $Name
    if (-not (Test-Path -LiteralPath $path)) { throw 'backup not found' }
    return @{ name = $Name; doc = ((Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json) }
}

function Invoke-WuJob {
    param([switch]$ReportOnly, [switch]$Restore, [string]$BackupName)
    $mode = $(if ($Restore) { 'restore' } elseif ($ReportOnly) { 'report' } else { 'run' })
    $r = @{ ExitCode = 2; Status = 'failed'; Mode = $mode; Before = $null; After = $null; Backup = $null; Error = '' }
    try {
        $tree = @(& $script:WuReadTree)   # one snapshot: the backup and the delete list both come from it
        $beforeReg = Get-WuTargets $tree
        $polBytes = & $script:WuReadPolBytes
        $polSplit = Split-WuPolTargets $polBytes
        $before = Get-WuMergedTargets $beforeReg $polSplit.targets
        $r.Before = Get-WuSummary $before
        if ($Restore) {
            $b = Read-WuBackup $BackupName
            $r.Backup = $b.name
            if ($ReportOnly) {
                # -ReportOnly wins over -Restore: a preview writes nothing.
                $r.After = $r.Before; $r.Status = 'would-restore'; $r.ExitCode = 0
            } else {
                $polTargetsProp = $b.doc.PSObject.Properties['polTargets']
                $hasPolTargets = $false
                if ($polTargetsProp -and $polTargetsProp.Value) {
                    foreach ($n in $script:WuTargets) {
                        $pt = $polTargetsProp.Value.$n
                        if ($pt -and $pt.present) { $hasPolTargets = $true; break }
                    }
                }
                if ($hasPolTargets) {
                    $mergedPol = Merge-WuPolTargets (& $script:WuReadPolBytes) $polTargetsProp.Value
                    & $script:WuWritePolBytes $mergedPol
                }
                foreach ($n in $script:WuTargets) {
                    $t = $b.doc.targets.$n
                    if ($t -and $t.present) { & $script:WuSetValue 'AU' $n ([string]$t.kind) $t.data }
                }
                $afterReg = Get-WuTargets (& $script:WuReadTree)
                $afterPol = (Split-WuPolTargets (& $script:WuReadPolBytes)).targets
                $r.After = Get-WuSummary (Get-WuMergedTargets $afterReg $afterPol)
                foreach ($n in $script:WuTargets) {
                    $t = $b.doc.targets.$n
                    if ($t -and $t.present) {
                        if (-not $afterReg.Contains($n) -or "$($afterReg[$n].data)" -ne "$($t.data)") {
                            throw 'restored registry value missing or differs'
                        }
                    }
                    if ($hasPolTargets) {
                        $pt = $polTargetsProp.Value.$n
                        if ($pt -and $pt.present) {
                            if (-not $afterPol.Contains($n) -or "$($afterPol[$n].data)" -ne "$($pt.data)") {
                                throw 'restored Registry.pol value missing or differs'
                            }
                        }
                    }
                }
                $r.Status = 'restored'; $r.ExitCode = 0
            }
        } elseif ($before.Count -eq 0) {
            $r.After = $r.Before; $r.Status = 'unchanged'; $r.ExitCode = 0
        } elseif ($ReportOnly) {
            $r.After = $r.Before; $r.Status = 'drift'; $r.ExitCode = 1
        } else {
            # Fail closed: a throw here, before the delete/write, leaves the registry and Registry.pol as they were.
            $r.Backup = Write-WuBackup $tree $beforeReg $polSplit.targets $polBytes
            # Group Policy can rewrite a value after the snapshot; deleting then would leave a stale backup.
            $live = Get-WuTargets (& $script:WuReadTree)
            $livePolBytes = & $script:WuReadPolBytes
            $same = ($live.Count -eq $beforeReg.Count) -and (Test-WuBytesEqual $livePolBytes $polBytes)
            foreach ($n in @($beforeReg.Keys)) {
                if (-not $live.Contains($n) -or $live[$n].kind -ne $beforeReg[$n].kind -or "$($live[$n].data)" -ne "$($beforeReg[$n].data)") { $same = $false }
            }
            if (-not $same) { throw 'policy values changed after the snapshot, nothing deleted' }
            if ($polSplit.targets.Count -gt 0) { & $script:WuWritePolBytes $polSplit.filteredBytes }
            foreach ($n in @($beforeReg.Keys)) { & $script:WuDeleteValue 'AU' $n }
            $afterReg = Get-WuTargets (& $script:WuReadTree)
            $afterPol = Split-WuPolTargets (& $script:WuReadPolBytes)
            $after = Get-WuMergedTargets $afterReg $afterPol.targets
            $r.After = Get-WuSummary $after
            if ($after.Count -eq 0) { $r.Status = 'removed'; $r.ExitCode = 0 } else { $r.Error = 'value still present after delete' }
        }
    } catch {
        $r.Error = $_.Exception.Message
    }
    return [pscustomobject]$r
}

# Only characters JSON never escapes, so the line stays short and plain.
function Get-WuSafeText {
    param([AllowEmptyString()][string]$Text, [int]$Limit)
    $safe = $Text -replace '[^A-Za-z0-9 ._:()-]', '_'
    return $safe.Substring(0, [Math]::Min($safe.Length, $Limit))
}

function ConvertTo-WuJobLine {
    param([Parameter(Mandatory)]$Result)
    [ordered]@{
        job = 'reset-windowsupdate-auto-policy'; mode = $Result.Mode; status = $Result.Status
        before = $Result.Before; after = $Result.After; backup = $Result.Backup
        error = Get-WuSafeText $Result.Error 200
    } | ConvertTo-Json -Compress
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$jobResult = Invoke-WuJob -ReportOnly:$ReportOnly -Restore:$Restore -BackupName $BackupName
Write-Output (ConvertTo-WuJobLine $jobResult)
exit $jobResult.ExitCode
