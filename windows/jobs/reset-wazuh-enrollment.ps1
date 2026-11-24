# Remediation module, run by windows/runner/Invoke-RelianJob.ps1 as SYSTEM. Forces a fresh Wazuh enrolment.
# The agent folder is the InstallLocation of the 'Wazuh Agent' uninstall entry (64-bit or WOW6432Node), else
# ossec-agent under Program Files (x86), then Program Files, as windows/packages/wazuh does.
# -ReportOnly (check): reports WazuhSvc status, client.keys length, whether authd.pass exists and the agent folder.
#   Changes nothing. File contents are never read into the output.
# Without -ReportOnly (the loader forwards only -ReportOnly, so this is the apply mode): stops WazuhSvc (bounded wait),
#   copies client.keys to %ProgramData%\Relian\wazuh\client.keys.bak-<UTC time> (SYSTEM and Administrators only,
#   inheritance off, set before any content is written), truncates client.keys to 0 bytes and leaves WazuhSvc stopped.
#   Intune's "Relian Managed - Wazuh Agent" detection then fails on the empty keys, and its install script writes a new
#   authd.pass and restarts the service, which enrols again. A failure before the truncate starts the service again.
# Undo, before Intune has re-enrolled the agent (an elevated PowerShell on the device, real paths from the JSON line):
#   [IO.File]::WriteAllBytes('<agentDir>\client.keys', [IO.File]::ReadAllBytes('<backup>')); Start-Service WazuhSvc
#   WriteAllBytes keeps the ACL client.keys already has.
# Exit 0 reset or unchanged (keys already empty), 1 drift with -ReportOnly, 2 failed. Prints one JSON line.
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:WrStopSeconds = 60
$script:WrBackupDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\wazuh'
$script:WrDefaultRoots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles)

# Same roots as Detect-Wazuh.ps1. A key that cannot be read is skipped.
$script:WrReadUninstall = {
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            try { Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop } catch { }
        }
    }
}

$script:WrServiceStatus = {
    $service = Get-Service -Name 'WazuhSvc' -ErrorAction SilentlyContinue
    if ($null -eq $service) { return '' }
    return [string]$service.Status
}

$script:WrStopService = {
    param([int]$Seconds)
    $service = Get-Service -Name 'WazuhSvc' -ErrorAction Stop
    if ($service.Status -ne 'Stopped') {
        if ($service.Status -ne 'StopPending') { $service.Stop() }
        # A timeout is not an error here: the caller re-reads the status.
        try { $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($Seconds)) } catch { }
    }
}

$script:WrStartService = { Start-Service -Name 'WazuhSvc' -ErrorAction Stop }

# SYSTEM and Administrators only, inheritance off.
$script:WrProtect = {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetSecurityDescriptorSddlForm('D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    } else {
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetSecurityDescriptorSddlForm('D:P(A;;FA;;;SY)(A;;FA;;;BA)')
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# Writes into a file that already exists, so it keeps the ACL that file has.
$script:WrCopyInto = {
    param([string]$Source, [string]$Destination)
    $bytes = [IO.File]::ReadAllBytes($Source)
    $stream = [IO.File]::Open($Destination, [IO.FileMode]::Truncate, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

$script:WrIsReparse = {
    param([string]$Path)
    return (Test-Path -LiteralPath $Path) -and [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Assert-WrNotReparse {
    foreach ($path in @((Split-Path -Parent $script:WrBackupDir), $script:WrBackupDir)) {
        if (& $script:WrIsReparse $path) { throw 'refusing a backup folder that is a reparse point' }
    }
}

# A new SYSTEM and Administrators file under the backup folder, protected while empty, then filled and read back.
function New-WrBackup {
    param([string]$KeysPath)
    Assert-WrNotReparse
    if (-not (Test-Path -LiteralPath $script:WrBackupDir)) {
        $null = New-Item -ItemType Directory -Path $script:WrBackupDir -Force
        Assert-WrNotReparse
    }
    & $script:WrProtect $script:WrBackupDir
    $path = Join-Path $script:WrBackupDir ('client.keys.bak-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
    # CreateNew: an existing file is never reused.
    [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None).Dispose()
    & $script:WrProtect $path
    & $script:WrCopyInto $KeysPath $path
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes($KeysPath))) {
        throw 'backup read-back differs from client.keys'
    }
    return $path
}

function Get-WrText {
    param($Object, [string]$Name)
    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) { return '' }
    return ([string]$Object.$Name).Trim()
}

# The agent folder and where it came from, or $null when there is none.
function Find-WrAgentDir {
    foreach ($entry in @(& $script:WrReadUninstall)) {
        if ((Get-WrText $entry 'DisplayName') -ne 'Wazuh Agent') { continue }
        $loc = (Get-WrText $entry 'InstallLocation').TrimEnd('\', '/')
        if ($loc -and (Test-Path -LiteralPath $loc -PathType Container)) { return @{ Path = $loc; Source = 'uninstall' } }
    }
    foreach ($root in @($script:WrDefaultRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $dir = Join-Path $root 'ossec-agent'
        if (Test-Path -LiteralPath $dir -PathType Container) { return @{ Path = $dir; Source = 'default' } }
    }
    return $null
}

function Get-WrKeysLength {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [int64]0 }
    return [int64](Get-Item -LiteralPath $Path -Force).Length
}

function Invoke-WrJob {
    param([switch]$ReportOnly)
    $r = [ordered]@{
        ExitCode = 2; Status = 'failed'; Mode = $(if ($ReportOnly) { 'report' } else { 'run' })
        Service = ''; KeysLength = [int64]-1; KeysAfter = [int64]-1; AuthdPass = $false
        AgentDir = ''; DirSource = ''; Backup = $null; Error = ''
    }
    $stopped = $false
    $truncated = $false
    try {
        $found = Find-WrAgentDir
        $r.Service = [string](& $script:WrServiceStatus)
        if ($null -eq $found -or -not $r.Service) { throw 'Wazuh agent folder or WazuhSvc not found' }
        $r.AgentDir = $found.Path
        $r.DirSource = $found.Source
        $keys = Join-Path $found.Path 'client.keys'
        $r.AuthdPass = Test-Path -LiteralPath (Join-Path $found.Path 'authd.pass') -PathType Leaf
        $r.KeysLength = Get-WrKeysLength $keys
        $r.KeysAfter = $r.KeysLength
        if ($r.KeysLength -eq 0) {
            $r.Status = 'unchanged'; $r.ExitCode = 0
        } elseif ($ReportOnly) {
            $r.Status = 'drift'; $r.ExitCode = 1
        } else {
            & $script:WrStopService $script:WrStopSeconds
            $r.Service = [string](& $script:WrServiceStatus)
            if ($r.Service -ne 'Stopped') { throw "WazuhSvc did not stop within $script:WrStopSeconds seconds" }
            $stopped = $true
            $r.Backup = New-WrBackup $keys
            [IO.File]::Open($keys, [IO.FileMode]::Truncate, [IO.FileAccess]::Write, [IO.FileShare]::None).Dispose()
            $truncated = $true
            $r.KeysAfter = Get-WrKeysLength $keys
            if ($r.KeysAfter -ne 0) { throw 'client.keys is not empty after the truncate' }
            $r.Status = 'reset'; $r.ExitCode = 0
        }
    } catch {
        $r.Error = $_.Exception.Message
        # Keys still intact: bring the agent back rather than leave it stopped.
        if ($stopped -and -not $truncated) {
            try { & $script:WrStartService; $r.Service = [string](& $script:WrServiceStatus) } catch { $r.Error += '; could not start WazuhSvc' }
        }
    }
    return [pscustomobject]$r
}

function ConvertTo-WrJobLine {
    param([Parameter(Mandatory)]$Result)
    [ordered]@{
        job        = 'reset-wazuh-enrollment'
        mode       = $Result.Mode
        status     = $Result.Status
        service    = $Result.Service
        keysLength = $Result.KeysLength
        keysAfter  = $Result.KeysAfter
        authdPass  = $Result.AuthdPass
        agentDir   = $Result.AgentDir
        dirSource  = $Result.DirSource
        backup     = $Result.Backup
        error      = ([string]$Result.Error -replace '[^A-Za-z0-9 ._:()\\-]', '_')
    } | ConvertTo-Json -Compress
}

# Dot-sourcing under test defines functions and changes nothing.
if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

$jobResult = Invoke-WrJob -ReportOnly:$ReportOnly
Write-Output (ConvertTo-WrJobLine $jobResult)
exit $jobResult.ExitCode
