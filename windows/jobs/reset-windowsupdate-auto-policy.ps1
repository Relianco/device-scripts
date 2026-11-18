# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Removes exactly two policy values,
# NoAutoUpdate and AUOptions, under HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU, and nothing else.
# Before it deletes, it writes the whole WindowsUpdate policy key (all values, all subkeys) to a new JSON file under
# C:\ProgramData\Relian\WuAutoPolicyBackup, SYSTEM-only. A backup that cannot be written and read back stops the run
# with nothing deleted. A backup is never overwritten. -Restore writes the two values back from the newest backup
# (or -BackupName). -ReportOnly changes and writes nothing, also with -Restore (a preview). Absent values: nothing changes, status unchanged.
# Exit 0 done or unchanged, 1 drift with -ReportOnly, 2 failed. Prints one JSON line.
# The job loader forwards only -ReportOnly; -Restore and -BackupName reach the module only when it is run directly.
[CmdletBinding()]
param([switch]$ReportOnly, [switch]$Restore, [string]$BackupName)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:WuSubKey = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:WuTargets = @('NoAutoUpdate', 'AUOptions')   # the only values this module ever deletes or restores
$script:WuBackupDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\WuAutoPolicyBackup'

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

# Pure: name -> data, $null when absent, for the JSON line.
function Get-WuSummary {
    param($Targets)
    $s = [ordered]@{}
    foreach ($n in $script:WuTargets) { $s[$n] = $(if ($Targets.Contains($n)) { $Targets[$n].data } else { $null }) }
    return $s
}

# Writes a new backup file and reads it back. CreateNew: an existing file is never overwritten. Throws on any failure.
function Write-WuBackup {
    param($Tree, $Targets)
    $null = New-Item -ItemType Directory -Path $script:WuBackupDir -Force
    & $script:WuProtectDir $script:WuBackupDir
    $name = 'backup-{0}-{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $path = Join-Path $script:WuBackupDir $name
    $targetRecord = [ordered]@{}
    foreach ($n in $script:WuTargets) {
        $targetRecord[$n] = $(if ($Targets.Contains($n)) { @{ present = $true; kind = $Targets[$n].kind; data = $Targets[$n].data } } else { @{ present = $false } })
    }
    $doc = [ordered]@{
        schemaVersion = 1; createdUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        key = "HKLM\$script:WuSubKey"; targets = $targetRecord; tree = @($Tree)
    }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($doc | ConvertTo-Json -Depth 8))
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
    $back = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json
    foreach ($n in $script:WuTargets) {
        $want = $targetRecord[$n]
        $got = $back.targets.$n
        if ($want.present -ne $got.present -or ($want.present -and "$($want.data)" -ne "$($got.data)")) { throw "backup read-back differs for $n" }
    }
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
        $before = Get-WuTargets (& $script:WuReadTree)
        $r.Before = Get-WuSummary $before
        if ($Restore) {
            $b = Read-WuBackup $BackupName
            $r.Backup = $b.name
            if ($ReportOnly) {
                # -ReportOnly wins over -Restore: a preview writes nothing.
                $r.After = $r.Before; $r.Status = 'would-restore'; $r.ExitCode = 0
            } else {
                foreach ($n in $script:WuTargets) {
                    $t = $b.doc.targets.$n
                    if ($t -and $t.present) { & $script:WuSetValue 'AU' $n ([string]$t.kind) $t.data }
                }
                $r.After = Get-WuSummary (Get-WuTargets (& $script:WuReadTree))
                $r.Status = 'restored'; $r.ExitCode = 0
            }
        } elseif ($before.Count -eq 0) {
            $r.After = $r.Before; $r.Status = 'unchanged'; $r.ExitCode = 0
        } elseif ($ReportOnly) {
            $r.After = $r.Before; $r.Status = 'drift'; $r.ExitCode = 1
        } else {
            # Fail closed: a throw here, before the delete, leaves the registry as it was.
            $r.Backup = Write-WuBackup (& $script:WuReadTree) $before
            foreach ($n in @($before.Keys)) { & $script:WuDeleteValue 'AU' $n }
            $after = Get-WuTargets (& $script:WuReadTree)
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
