<#
.SYNOPSIS
    Keeps COMET_FORCE_VSS_PROVIDER=system in Comet Backup's service environment on QEMU/Proxmox guests.

.DESCRIPTION
    Without that line Comet can pick a non-default VSS provider (the QEMU guest agent's, or a leftover
    Hyper-V IC provider) and the snapshot fails with 0x8004230f; Comet then backs up a live disk.
    A Comet client update can rewrite the services' AppEnvironmentExtra, so this package is safe to
    run on a schedule.

    -Action Install (Update, Repair): add or normalise the line in REG_MULTI_SZ AppEnvironmentExtra of
      backup.delegate and backup.elevator, keeping every other entry and its order. Only on a QEMU
      guest unless -AllowNonQemu true. Restarts both services only when idle; while a backup-tool job
      runs it reports restartPending and leaves a marker so a later run restarts.
    -Action Uninstall: remove only that line, same restart rule.
    -Section Evidence: read-only report with any action. Nothing is written or restarted.
    Downloads nothing. Prints one JSON line.
#>
[CmdletBinding()]
param(
    [string]$DeploymentType = '',
    [string]$Action = '',
    [string]$PinVersion = '',
    [string]$Section = '',
    [string]$AllowNonQemu = ''
)

$ErrorActionPreference = 'Stop'
$script:CvLine = 'COMET_FORCE_VSS_PROVIDER=system'
$script:CvServices = @('backup.delegate', 'backup.elevator')
$script:CvMarkerKey = 'SOFTWARE\Relian\CometVssProvider'

function Test-CvVariant([string]$Text) { $Text -match '^\s*COMET_FORCE_VSS_PROVIDER\s*=' }

function Test-CvCompliant([string[]]$Lines) {
    $vss = @($Lines | Where-Object { Test-CvVariant $_ })
    $vss.Count -eq 1 -and $vss[0] -ceq $script:CvLine
}

function Set-CvVssLine([string[]]$Lines) {
    if (Test-CvCompliant $Lines) { return ,[string[]]@($Lines) }
    $out = [System.Collections.Generic.List[string]]::new()
    $placed = $false
    foreach ($l in @($Lines)) {
        if (Test-CvVariant $l) {
            if (-not $placed) { $out.Add($script:CvLine); $placed = $true }
        } else { $out.Add($l) }
    }
    if (-not $placed) { $out.Add($script:CvLine) }
    return ,[string[]]$out.ToArray()
}

function Remove-CvVssLine([string[]]$Lines) {
    return ,[string[]]@($Lines | Where-Object { -not (Test-CvVariant $_) })
}

function Protect-CvLine([string]$Text) {
    $name = $null; $value = $Text
    if ($Text -match '^([^=]+)=(.*)$') { $name = $Matches[1]; $value = $Matches[2] }
    $secretName = $name -match '(?i)pass|pwd|secret|token|key|auth|cred|cookie|session'
    $userInfo = $value -match '://[^/\s]*@'
    $tokenLike = $value -match '^[A-Za-z0-9+/=_\-\.]{24,}$'
    if ($secretName -or $userInfo -or $tokenLike) {
        if ($null -eq $name) { return '[redacted]' }
        return "$name=[redacted]"
    }
    return $Text
}

# Seams. Tests replace these; the defaults touch the real device.
$script:CvRead = {
    param($svc)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services\$svc\Parameters")
    if ($null -eq $key) { return [pscustomobject]@{ Exists = $false; Kind = $null; Lines = @() } }
    try {
        if ($key.GetValueNames() -notcontains 'AppEnvironmentExtra') {
            return [pscustomobject]@{ Exists = $true; Kind = 'MultiString'; Lines = @() }
        }
        $kind = [string]$key.GetValueKind('AppEnvironmentExtra')
        $raw = $key.GetValue('AppEnvironmentExtra', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [pscustomobject]@{ Exists = $true; Kind = $kind; Lines = @($raw) }
    } finally { $key.Dispose() }
}
$script:CvWrite = {
    param($svc, [string[]]$lines)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services\$svc\Parameters", $true)
    try { $key.SetValue('AppEnvironmentExtra', [string[]]$lines, [Microsoft.Win32.RegistryValueKind]::MultiString) } finally { $key.Dispose() }
}
$script:CvComputer = { Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object Manufacturer, Model }
$script:CvQemuAgent = {
    $svc = @(Get-Service -Name 'QEMU-GA', 'QEMU Guest Agent VSS Provider' -ErrorAction SilentlyContinue)
    $svc.Count -gt 0 -or (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\VSS\Providers\{3629d4ed-ee09-4e0e-9a5c-6d8ba2872aef}')
}
$script:CvProviders = {
    @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\VSS\Providers' -ErrorAction SilentlyContinue |
        ForEach-Object { [string]$_.GetValue('') })
}
$script:CvProcesses = { @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'backup-tool.exe'" | Select-Object Name, CommandLine) }
$script:CvRestart = { param($svc) Restart-Service -Name $svc -Force }
$script:CvGetMarker = {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:CvMarkerKey)
    if ($null -eq $key) { return $false }
    try { return [int]$key.GetValue('RestartPending', 0) -eq 1 } finally { $key.Dispose() }
}
$script:CvSetMarker = {
    param([bool]$on)
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($script:CvMarkerKey)
    try {
        if ($on) { $key.SetValue('RestartPending', 1, [Microsoft.Win32.RegistryValueKind]::DWord) }
        else { $key.DeleteValue('RestartPending', $false) }
    } finally { $key.Dispose() }
}

function Test-CvJobRunning {
    foreach ($p in @(& $script:CvProcesses)) {
        $cmd = [string]$p.CommandLine
        # Idle Comet keeps these helpers running; anything else (or an unreadable command line) is a job.
        # Match only after the executable token, so a path containing "stream" cannot hide a job.
        $args1 = if ($cmd -match '^\s*(?:"[^"]*"|\S+)\s*(.*)$') { $Matches[1] } else { $null }
        if ($null -eq $args1 -or $args1 -notmatch '(?i)^(cmd\s+)?(-(?!Action=)\w+=\S*\s+)*(-Action=)?(delegate-server|elevator-server|stream)(\s|$)') { return $true }
    }
    return $false
}

function Invoke-CvMain {
    param([string]$Action = '', [string]$Section = '', [string]$AllowNonQemu = '')
    $result = [ordered]@{ Package = 'comet-vss-provider'; Action = $Action; Section = $Section; Status = 'error' }
    if ($Section -notin @('', 'Evidence')) { $result.Reason = 'unsupported section'; return @{ ExitCode = 1; Result = $result } }
    $removing = $Action -eq 'Uninstall'
    if (-not $removing -and $Action -notin @('Install', 'Update', 'Repair') -and $Section -ne 'Evidence') {
        $result.Reason = 'unsupported action'; return @{ ExitCode = 1; Result = $result }
    }

    $cs = & $script:CvComputer
    $qemu = ("$($cs.Manufacturer) $($cs.Model)" -match '(?i)qemu') -or [bool](& $script:CvQemuAgent)
    $result.Manufacturer = [string]$cs.Manufacturer
    $result.Model = [string]$cs.Model
    $result.QemuGuest = $qemu
    $result.VssProviders = @(& $script:CvProviders)
    $result.JobRunning = Test-CvJobRunning
    $result.RestartPending = [bool](& $script:CvGetMarker)

    $states = @(foreach ($svc in $script:CvServices) {
        $r = & $script:CvRead $svc
        [pscustomobject]@{ Service = $svc; Exists = $r.Exists; Kind = $r.Kind; Lines = [string[]]@($r.Lines | Where-Object { $_ -ne '' }) }
    })
    $result.Services = @($states | ForEach-Object {
        [ordered]@{ Service = $_.Service; Exists = $_.Exists; Kind = $_.Kind; Compliant = (Test-CvCompliant $_.Lines); Lines = @($_.Lines | ForEach-Object { Protect-CvLine $_ }) }
    })

    $present = @($states | Where-Object { $_.Exists }).Count
    if ($Section -eq 'Evidence') { $result.Status = 'evidence'; return @{ ExitCode = 0; Result = $result } }
    if ($present -eq 0) { $result.Status = 'cometNotInstalled'; return @{ ExitCode = 0; Result = $result } }
    if ($present -ne $states.Count) { $result.Reason = 'only one Comet service key exists'; return @{ ExitCode = 1; Result = $result } }
    if (@($states | Where-Object { $_.Kind -ne 'MultiString' }).Count -gt 0) {
        $result.Reason = 'AppEnvironmentExtra is not REG_MULTI_SZ; not changed'; return @{ ExitCode = 1; Result = $result }
    }
    if (-not $removing -and -not $qemu -and $AllowNonQemu -ne 'true') {
        $result.Status = 'notQemuGuest'; $result.Reason = 'not a QEMU/Proxmox guest; pass AllowNonQemu=true to force'
        return @{ ExitCode = 0; Result = $result }
    }

    $changed = $false
    $before = @{}
    foreach ($s in $states) {
        $want = if ($removing) { Remove-CvVssLine $s.Lines } else { Set-CvVssLine $s.Lines }
        if (($want -join "`0") -cne ($s.Lines -join "`0")) {
            # Marker before the first write: a failure after it still leaves a restart owed.
            if (-not $changed) { & $script:CvSetMarker $true }
            $before[$s.Service] = $result.Services | Where-Object { $_.Service -eq $s.Service }
            & $script:CvWrite $s.Service $want
            $back = [string[]]@((& $script:CvRead $s.Service).Lines | Where-Object { $_ -ne '' })
            if (($back -join "`0") -cne ($want -join "`0")) { $result.Reason = "read-back mismatch on $($s.Service)"; return @{ ExitCode = 1; Result = $result } }
            $changed = $true
            # Report the post-write state; keep the pre-write lines as Before.
            $row = $before[$s.Service]
            $row.Before = $row.Lines
            $row.Lines = @($back | ForEach-Object { Protect-CvLine $_ })
            $row.Compliant = (Test-CvCompliant $back)
        }
    }

    if ($changed -or $result.RestartPending) {
        # Sample again: a job may have started while the values were read and written.
        $result.JobRunning = Test-CvJobRunning
        if ($result.JobRunning) {
            & $script:CvSetMarker $true
            $result.RestartPending = $true
            $result.Status = 'restartPending'
            $result.Reason = 'value set; a backup job is running, so the services were not restarted. Run again later.'
            return @{ ExitCode = 0; Result = $result }
        }
        # Marker stays set until both restarts succeed, so a failed restart is retried next run.
        & $script:CvSetMarker $true
        foreach ($svc in $script:CvServices) { & $script:CvRestart $svc }
        & $script:CvSetMarker $false
        $result.RestartPending = $false
        $result.Restarted = $true
        $result.Status = if ($removing) { 'removed' } else { 'applied' }
        return @{ ExitCode = 0; Result = $result }
    }
    $result.Status = if ($removing) { 'absent' } else { 'compliant' }
    return @{ ExitCode = 0; Result = $result }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1' -and $MyInvocation.InvocationName -eq '.') {
    return
}

try {
    $run = Invoke-CvMain -Action $Action -Section $Section -AllowNonQemu $AllowNonQemu
} catch {
    $run = @{ ExitCode = 1; Result = [ordered]@{ Package = 'comet-vss-provider'; Status = 'error'; Reason = $_.Exception.Message } }
}
Write-Output (ConvertTo-Json -InputObject $run.Result -Depth 6 -Compress)
exit $run.ExitCode
