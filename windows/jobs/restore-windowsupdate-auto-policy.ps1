# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Undoes reset-windowsupdate-auto-policy:
# writes NoAutoUpdate and AUOptions back under HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU from the newest
# backup in C:\ProgramData\Relian\WuAutoPolicyBackup. Writes only those two values, and only those the backup held.
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

function Get-WuSummary {
    param($Found)
    $s = [ordered]@{}
    foreach ($n in $script:WuTargets) { $s[$n] = $(if ($Found.Contains($n)) { $Found[$n] } else { $null }) }
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
        $r.Before = Get-WuSummary (& $script:WuReadTargets)
        $b = Read-WuNewestBackup
        $r.Backup = $b.name
        if ($ReportOnly) {
            $r.After = $r.Before; $r.Status = 'would-restore'; $r.ExitCode = 0
        } else {
            foreach ($n in $script:WuTargets) {
                $t = $b.doc.targets.$n
                if ($t -and $t.present) { & $script:WuSetValue 'AU' $n ([string]$t.kind) $t.data }
            }
            $r.After = Get-WuSummary (& $script:WuReadTargets)
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
