# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Undoes reset-windowsupdate-auto-policy:
# writes NoAutoUpdate and AUOptions back under HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU and spliced
# into GroupPolicy\Machine\Registry.pol from the newest backup in C:\ProgramData\Relian\WuAutoPolicyBackup.
# Writes only those values, and only those the backup held, preserving any other Registry.pol entries.
# -ReportOnly names the backup it would use and writes nothing. No backup: exit 2, nothing changed.
# Exit 0 restored or would restore, 2 failed. Prints one JSON line.
# The restore code is a copy of the reset module's -Restore path: a module runs alone from its hashed bytes.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:WuSubKey = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:WuTargets = @('NoAutoUpdate', 'AUOptions')
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

function Open-WuHklm {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
}

# The two target values now present under AU, as name -> data. A denied read throws.
$script:WuReadTargets = {
    $found = [ordered]@{}
    $key = (Open-WuHklm).OpenSubKey("$script:WuSubKey\AU")
    if ($key) {
        try {
            foreach ($n in $script:WuTargets) {
                $v = $key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($null -ne $v) { $found[$n] = $v }
            }
        } finally { $key.Dispose() }
    }
    return $found
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
            $targets[$matchedTarget] = @{ kind = 'DWord'; data = [long][BitConverter]::ToUInt32($Bytes, $dataOffset) }
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

function Get-WuSummary {
    param($Found, $PolTargets = $null)
    $s = [ordered]@{}
    foreach ($n in $script:WuTargets) {
        if ($Found.Contains($n)) { $s[$n] = $Found[$n] }
        elseif ($PolTargets -and $PolTargets.Contains($n)) { $s[$n] = $PolTargets[$n].data }
        else { $s[$n] = $null }
    }
    return $s
}

function Read-WuNewestBackup {
    $files = @(if (Test-Path -LiteralPath $script:WuBackupDir) { Get-ChildItem -LiteralPath $script:WuBackupDir -Filter 'backup-*.json' -File | Sort-Object Name })
    if ($files.Count -eq 0) { throw 'no backup found' }
    return @{ name = $files[-1].Name; doc = ((Get-Content -LiteralPath $files[-1].FullName -Raw -Encoding UTF8) | ConvertFrom-Json) }
}

function Invoke-WuRestoreJob {
    param([switch]$ReportOnly)
    $r = @{ ExitCode = 2; Status = 'failed'; Mode = $(if ($ReportOnly) { 'report' } else { 'restore' }); Before = $null; After = $null; Backup = $null; Error = '' }
    try {
        $beforeReg = & $script:WuReadTargets
        $beforePol = (Split-WuPolTargets (& $script:WuReadPolBytes)).targets
        $r.Before = Get-WuSummary $beforeReg $beforePol
        $b = Read-WuNewestBackup
        $r.Backup = $b.name
        if ($ReportOnly) {
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
            $afterReg = & $script:WuReadTargets
            $afterPol = (Split-WuPolTargets (& $script:WuReadPolBytes)).targets
            $r.After = Get-WuSummary $afterReg $afterPol
            foreach ($n in $script:WuTargets) {
                $t = $b.doc.targets.$n
                if ($t -and $t.present) {
                    if (-not $afterReg.Contains($n) -or "$($afterReg[$n])" -ne "$($t.data)") {
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
    } catch {
        $r.Error = $_.Exception.Message
    }
    return [pscustomobject]$r
}

function Get-WuSafeText {
    param([AllowEmptyString()][string]$Text, [int]$Limit)
    $safe = $Text -replace '[^A-Za-z0-9 ._:()-]', '_'
    return $safe.Substring(0, [Math]::Min($safe.Length, $Limit))
}

function ConvertTo-WuJobLine {
    param([Parameter(Mandatory)]$Result)
    [ordered]@{
        job = 'restore-windowsupdate-auto-policy'; mode = $Result.Mode; status = $Result.Status
        before = $Result.Before; after = $Result.After; backup = $Result.Backup
        error = Get-WuSafeText $Result.Error 200
    } | ConvertTo-Json -Compress
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$jobResult = Invoke-WuRestoreJob -ReportOnly:$ReportOnly
Write-Output (ConvertTo-WuJobLine $jobResult)
exit $jobResult.ExitCode
