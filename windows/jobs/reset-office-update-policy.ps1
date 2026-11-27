# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Turns Office (Microsoft 365 Apps, Click-to-Run)
# automatic updates back on where a script switched them off, and changes nothing else. It removes only these values:
#   HKLM\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate
#     EnableAutomaticUpdates = 0, updatebranch = None, hideenabledisableupdates = 1
#   HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration
#     UpdateUrl = '' and UpdateToVersion = '' (empty strings only)
# and sets ClickToRun\Configuration UpdatesEnabled from False to True. A value with any other data (updates on, a real
# channel, a real update URL) is never touched, so Group Policy or Intune settings stay as they are.
# Before it changes anything it writes both keys (all values) and the change list to a new JSON file under
# C:\ProgramData\Relian\OfficeUpdatePolicyBackup, SYSTEM-only, and reads it back; a backup that fails stops the run with
# nothing changed. A backup is never overwritten. -Restore puts the changed values back from the newest backup (or
# -BackupName). -ReportOnly changes and writes nothing. It never starts an Office update, closes an app or restarts.
# Exit 0 done or unchanged, 1 drift with -ReportOnly, 2 failed. Prints one JSON line.
# The job loader forwards only -ReportOnly; -Restore and -BackupName reach the module only when it is run directly.
[CmdletBinding()]
param([switch]$ReportOnly, [switch]$Restore, [string]$BackupName)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:OuKeys = [ordered]@{
    pol = 'SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'
    c2r = 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
}
# key, value name, the data that means "updates switched off", and the fix: $null deletes, a string sets that string.
$script:OuRules = @(
    @{ key = 'pol'; name = 'updatebranch'; off = 'None'; fix = $null }
    @{ key = 'pol'; name = 'EnableAutomaticUpdates'; off = '0'; fix = $null }
    @{ key = 'pol'; name = 'hideenabledisableupdates'; off = '1'; fix = $null }
    @{ key = 'c2r'; name = 'UpdatesEnabled'; off = 'False'; fix = 'True' }
    @{ key = 'c2r'; name = 'UpdateUrl'; off = ''; fix = $null }
    @{ key = 'c2r'; name = 'UpdateToVersion'; off = ''; fix = $null }
)
$script:OuBackupDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\OfficeUpdatePolicyBackup'

# Registry64 reaches the real keys from a 32-bit process. A denied read throws, so it is never reported as absent.
function Open-OuHklm {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
}

# The values of one key as @(@{ name; kind; data }), or $null when the key is absent. Binary data is base64.
$script:OuReadKey = {
    param([string]$Key)
    $k = (Open-OuHklm).OpenSubKey($script:OuKeys[$Key])
    if (-not $k) { return $null }
    try {
        $values = @(foreach ($name in $k.GetValueNames()) {
            $data = $k.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($data -is [byte[]]) { $data = [Convert]::ToBase64String($data) }
            @{ name = $name; kind = [string]$k.GetValueKind($name); data = $data }
        })
        return ,$values
    } finally { $k.Dispose() }
}

$script:OuDeleteValue = {
    param([string]$Key, [string]$Name)
    $k = (Open-OuHklm).OpenSubKey($script:OuKeys[$Key], $true)
    if ($k) { try { $k.DeleteValue($Name, $false) } finally { $k.Dispose() } }
}

$script:OuSetValue = {
    param([string]$Key, [string]$Name, [string]$Kind, $Data)
    $k = (Open-OuHklm).CreateSubKey($script:OuKeys[$Key])
    try {
        if ($Kind -eq 'DWord') { $Data = [int]$Data } elseif ($Kind -eq 'QWord') { $Data = [long]$Data }
        elseif ($Kind -eq 'Binary') { $Data = [Convert]::FromBase64String([string]$Data) }
        elseif ($Kind -eq 'MultiString') { $Data = [string[]]@($Data) }
        $k.SetValue($Name, $Data, [Microsoft.Win32.RegistryValueKind]$Kind)
    } finally { $k.Dispose() }
}

$script:OuProtectDir = {
    param($Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('D:P(A;OICI;FA;;;SY)')
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Read-OuSnapshot {
    $s = [ordered]@{}
    foreach ($key in $script:OuKeys.Keys) { $s[$key] = & $script:OuReadKey $key }
    return $s
}

# Pure: the changes a snapshot needs, in rule order. Data compares as text, case-insensitive ('none' = 'None').
function Get-OuPlan {
    param($Snapshot)
    $plan = @()
    foreach ($rule in $script:OuRules) {
        $values = $Snapshot[$rule.key]
        if ($null -eq $values) { continue }
        foreach ($v in @($values)) {
            if ($v.name -ne $rule.name) { continue }
            if ($v.kind -notin @('String', 'ExpandString', 'DWord')) { continue }
            if ("$($v.data)" -ne $rule.off) { continue }
            $plan += [pscustomobject]@{ key = $rule.key; name = $v.name; kind = $v.kind; data = $v.data; fix = $rule.fix }
        }
    }
    return ,$plan
}

function Get-OuPlanText { param($Plan) return @($Plan | ForEach-Object { "$($_.key)\$($_.name)" }) }

# Writes a new backup file and reads it back. CreateNew: an existing file is never overwritten. Throws on any failure.
function Write-OuBackup {
    param($Snapshot, $Plan)
    $null = New-Item -ItemType Directory -Path $script:OuBackupDir -Force
    & $script:OuProtectDir $script:OuBackupDir
    $name = 'backup-{0}-{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $path = Join-Path $script:OuBackupDir $name
    $keys = [ordered]@{}
    foreach ($k in $Snapshot.Keys) { $keys[$k] = $(if ($null -eq $Snapshot[$k]) { $null } else { @($Snapshot[$k]) }) }
    $doc = [ordered]@{
        schemaVersion = 1; createdUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        paths = $script:OuKeys; keys = $keys
        changes = @($Plan | ForEach-Object { [ordered]@{ key = $_.key; name = $_.name; kind = $_.kind; data = $_.data } })
    }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($doc | ConvertTo-Json -Depth 8))
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
    $back = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json
    if (@($back.changes).Count -ne @($Plan).Count) { throw 'backup read-back differs' }
    for ($i = 0; $i -lt @($Plan).Count; $i++) {
        $want = @($Plan)[$i]; $got = @($back.changes)[$i]
        if ($got.name -ne $want.name -or "$($got.data)" -ne "$($want.data)" -or $got.kind -ne $want.kind) { throw "backup read-back differs for $($want.name)" }
    }
    return $name
}

function Read-OuBackup {
    param([string]$Name)
    if ($Name) {
        if ($Name -notmatch '\Abackup-\d{8}T\d{9}Z-[0-9a-f]{8}\.json\z') { throw 'bad backup name' }
    } else {
        $files = @(if (Test-Path -LiteralPath $script:OuBackupDir) { Get-ChildItem -LiteralPath $script:OuBackupDir -Filter 'backup-*.json' -File | Sort-Object Name })
        if ($files.Count -eq 0) { throw 'no backup found' }
        $Name = $files[-1].Name
    }
    $path = Join-Path $script:OuBackupDir $Name
    if (-not (Test-Path -LiteralPath $path)) { throw 'backup not found' }
    return @{ name = $Name; doc = ((Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json) }
}

function Invoke-OuJob {
    param([switch]$ReportOnly, [switch]$Restore, [string]$BackupName)
    $mode = $(if ($Restore) { 'restore' } elseif ($ReportOnly) { 'report' } else { 'run' })
    $r = @{ ExitCode = 2; Status = 'failed'; Mode = $mode; Plan = @(); Backup = $null; Error = '' }
    try {
        $snap = Read-OuSnapshot   # one snapshot: the backup and the change list both come from it
        $plan = Get-OuPlan $snap
        $r.Plan = Get-OuPlanText $plan
        if ($Restore) {
            $b = Read-OuBackup $BackupName
            $r.Backup = $b.name
            $r.Plan = @($b.doc.changes | ForEach-Object { "$($_.key)\$($_.name)" })
            if ($ReportOnly) { $r.Status = 'would-restore'; $r.ExitCode = 0 }
            else {
                foreach ($c in @($b.doc.changes)) {
                    if (-not $script:OuKeys.Contains([string]$c.key)) { throw 'backup names an unknown key' }
                    & $script:OuSetValue ([string]$c.key) ([string]$c.name) ([string]$c.kind) $c.data
                }
                $r.Status = 'restored'; $r.ExitCode = 0
            }
        } elseif (@($plan).Count -eq 0) {
            $r.Status = 'unchanged'; $r.ExitCode = 0
        } elseif ($ReportOnly) {
            $r.Status = 'drift'; $r.ExitCode = 1
        } else {
            # Fail closed: a throw here, before any change, leaves the registry as it was.
            $r.Backup = Write-OuBackup $snap $plan
            # Group Policy or a script can rewrite a value after the snapshot; changing then would leave a stale backup.
            if (((Get-OuPlanText (Get-OuPlan (Read-OuSnapshot))) -join ',') -ne ($r.Plan -join ',')) { throw 'values changed after the snapshot, nothing changed' }
            foreach ($p in $plan) {
                if ($null -eq $p.fix) { & $script:OuDeleteValue $p.key $p.name } else { & $script:OuSetValue $p.key $p.name $p.kind $p.fix }
            }
            $left = Get-OuPlan (Read-OuSnapshot)
            if (@($left).Count -eq 0) { $r.Status = 'fixed'; $r.ExitCode = 0 } else { $r.Error = 'values still present after the change: ' + ((Get-OuPlanText $left) -join ',') }
        }
    } catch {
        $r.Error = $_.Exception.Message
    }
    return [pscustomobject]$r
}

# Only characters JSON never escapes, so the line stays short and plain.
function Get-OuSafeText {
    param([AllowEmptyString()][string]$Text, [int]$Limit)
    $safe = $Text -replace '[^A-Za-z0-9 ._:()\\-]', '_'
    return $safe.Substring(0, [Math]::Min($safe.Length, $Limit))
}

function ConvertTo-OuJobLine {
    param([Parameter(Mandatory)]$Result)
    [ordered]@{
        job = 'reset-office-update-policy'; host = $env:COMPUTERNAME; utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        mode = $Result.Mode; status = $Result.Status; plan = @($Result.Plan); backup = $Result.Backup
        error = Get-OuSafeText $Result.Error 200
    } | ConvertTo-Json -Compress
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$jobResult = Invoke-OuJob -ReportOnly:$ReportOnly -Restore:$Restore -BackupName $BackupName
Write-Output (ConvertTo-OuJobLine $jobResult)
exit $jobResult.ExitCode
