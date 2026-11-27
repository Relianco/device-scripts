<#
.SYNOPSIS
    Reports, sets up or starts a Microsoft Entra hybrid join of a domain-joined Windows device, for the Relian deploy
    runner (NinjaOne script 374).

.DESCRIPTION
    A domain-joined PC hybrid-joins when the built-in "\Microsoft\Windows\Workplace Join\Automatic-Device-Join" task
    finds the tenant. Without a service connection point (SCP) in Active Directory it can read a client-side SCP from
    HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CDJ\AAD (TenantId, TenantName). This package reads that state,
    writes the client-side SCP, and starts the join task.

    Mode (a PackageArguments string; default Report):
      Report  read-only. dsregcmd /status device facts, the CDJ\AAD values, the join task's state and last result,
              and whether the computer's AD domain answers.
      Scp     writes CDJ\AAD TenantId and TenantName, then reads them back. Needs TenantId (a GUID) and TenantName
              (a domain name, for example contoso.onmicrosoft.com); there are no defaults. The previous values are
              saved first to C:\ProgramData\Relian\hybrid-join\cdj-aad-<yyyyMMdd-HHmmss>-<id>.json, never overwriting an older one. Values already equal
              are left alone. Does not start the join task.
      Join    does Scp when TenantId and TenantName are given, then starts the join task, waits up to 90 seconds,
              and reports dsregcmd and the task again. A device already AzureAdJoined is reported and nothing is
              changed. "pending" means the task ran but the device is not joined yet: hybrid join finishes after
              the computer object syncs to Entra and the task runs again (at the next sign-in or restart).

    Scp and Join refuse (exit 1, nothing changed) a device whose dsregcmd DomainJoined is not YES.

    Rollback: the backup file holds keyExists, TenantId and TenantName as they were. When keyExists is false,
    delete the HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CDJ\AAD key; otherwise set the two values back.
    Leaving Entra (dsregcmd /leave) is the operator's call and this package never does it.

    The runner passes DeploymentType, Action and PinVersion, then each PackageArguments pair as -Name value. An empty
    PinVersion is the off switch. Uninstall reports only. The result is one line of compact JSON, at most 8,000
    UTF-8 bytes, printed last on stdout. Exit 1 on invalid arguments, a refusal, or a failed step.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM. No external module dependencies.
#>

# Not Mandatory: a mandatory param block prompts when this file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Mode = '',
    [string]$TenantId = '',
    [string]$TenantName = ''
)

$ProgressPreference = 'SilentlyContinue'
$script:HjAadKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CDJ\AAD'
$script:HjTaskPath = '\Microsoft\Windows\Workplace Join\'
$script:HjTaskName = 'Automatic-Device-Join'
$script:HjGuidPattern = '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z'
$script:HjDomainPattern = '\A(?=.{4,253}\z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}\z'
$script:HjFields = @('AzureAdJoined', 'EnterpriseJoined', 'DomainJoined', 'DomainName', 'TenantId', 'TenantName', 'DeviceId',
    'DeviceAuthStatus', 'KeySignTest', 'AzureAdPrt', 'WorkplaceJoined', 'Error', 'ErrorPhase', 'Client ErrorCode',
    'Server ErrorCode', 'Server Message', 'AD Connectivity Test', 'AD Configuration Test', 'DRS Discovery Test',
    'DRS Connectivity Test', 'Token acquisition Test', 'Fallback to Sync-Join', 'Attempt Status', 'Previous Registration',
    'Registration Type')
$script:HjCoreFields = @('AzureAdJoined', 'EnterpriseJoined', 'DomainJoined', 'DomainName', 'TenantId', 'TenantName', 'DeviceId')

# Seams. Tests replace them.
$script:HjDsreg = { @(& (Join-Path $env:SystemRoot 'System32\dsregcmd.exe') /status 2>&1 | ForEach-Object { [string]$_ }) }
$script:HjReadAad = {
    if (-not (Test-Path -LiteralPath $script:HjAadKey)) { return [ordered]@{ keyExists = $false; TenantId = $null; TenantName = $null } }
    $p = Get-ItemProperty -LiteralPath $script:HjAadKey -ErrorAction Stop
    $names = @($p.PSObject.Properties.Name)
    return [ordered]@{
        keyExists  = $true
        TenantId   = if ($names -contains 'TenantId') { [string]$p.TenantId } else { $null }
        TenantName = if ($names -contains 'TenantName') { [string]$p.TenantName } else { $null }
    }
}
$script:HjWriteAad = {
    param([string]$TenantId, [string]$TenantName)
    if (-not (Test-Path -LiteralPath $script:HjAadKey)) { [void](New-Item -Path $script:HjAadKey -Force -ErrorAction Stop) }
    [void](New-ItemProperty -LiteralPath $script:HjAadKey -Name 'TenantId' -Value $TenantId -PropertyType String -Force -ErrorAction Stop)
    [void](New-ItemProperty -LiteralPath $script:HjAadKey -Name 'TenantName' -Value $TenantName -PropertyType String -Force -ErrorAction Stop)
}
$script:HjBackupDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Relian\hybrid-join'
$script:HjWriteBackup = {
    param([string]$Json)
    [void][IO.Directory]::CreateDirectory($script:HjBackupDir)
    # A unique name and CreateNew: a second run never overwrites the backup of the first.
    $file = Join-Path $script:HjBackupDir ('cdj-aad-{0}-{1}.json' -f [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0, 8))
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Json)
    $fs = New-Object IO.FileStream($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    if ([IO.File]::ReadAllText($file) -cne $Json) { throw 'backup readback differs' }
    return $file
}
$script:HjGetTask = {
    $t = Get-ScheduledTask -TaskPath $script:HjTaskPath -TaskName $script:HjTaskName -ErrorAction SilentlyContinue
    if ($null -eq $t) { return $null }
    $i = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    return [ordered]@{
        state      = [string]$t.State
        lastRun    = if ($i -and $i.LastRunTime) { ([datetime]$i.LastRunTime).ToUniversalTime().ToString('o') } else { $null }
        lastResult = if ($i) { '0x{0:X8}' -f [int64]$i.LastTaskResult } else { $null }
    }
}
$script:HjStartTask = {
    Start-ScheduledTask -TaskPath $script:HjTaskPath -TaskName $script:HjTaskName -ErrorAction Stop
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do { Start-Sleep -Seconds 3 } while ($sw.Elapsed.TotalSeconds -lt 90 -and [string](Get-ScheduledTask -TaskPath $script:HjTaskPath -TaskName $script:HjTaskName).State -eq 'Running')
}
$script:HjDomain = {
    try {
        $d = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
        [void]$d.FindDomainController()
        return [ordered]@{ name = $d.Name; reachable = $true }
    } catch { return [ordered]@{ name = $null; reachable = $false } }
}

# Pure: Report | Scp | Join | none. Throws on bad input.
function Get-HjMode {
    param([string]$Action, [string]$Mode, [string]$PinVersion = '1.0.0', [string]$TenantId = '', [string]$TenantName = '')
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { return 'none' }
    if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -cnotcontains $Action) {
        throw 'Action must be Install, Update, Repair, Reinstall, or Uninstall.'
    }
    if ($Action -eq 'Uninstall' -or $Mode -eq '') { return 'Report' }
    if (@('Report', 'Scp', 'Join') -cnotcontains $Mode) { throw 'Mode must be Report, Scp or Join.' }
    if ($Mode -eq 'Report') { return $Mode }
    if ($Mode -eq 'Scp' -or $TenantId -ne '' -or $TenantName -ne '') {
        if ($TenantId -cnotmatch $script:HjGuidPattern) { throw 'TenantId must be a GUID.' }
        if ($TenantName -cnotmatch $script:HjDomainPattern) { throw 'TenantName must be a domain name.' }
    }
    return $Mode
}

# Pure: the known "Name : value" fields of dsregcmd /status, first occurrence, values cut at 200 characters.
function ConvertFrom-HjDsreg {
    param([string[]]$Lines)
    $out = [ordered]@{}
    foreach ($l in @($Lines)) {
        if ($l -match '^\s*([A-Za-z][A-Za-z -]*?)\s*:\s*(.*?)\s*$' -and $script:HjFields -ccontains $Matches[1] -and -not $out.Contains($Matches[1])) {
            $v = $Matches[2]
            $out[$Matches[1]] = if ($v.Length -gt 200) { $v.Substring(0, 200) } else { $v }
        }
    }
    return $out
}

# Pure: one compact JSON line, at most 8,000 UTF-8 bytes. Over that, dsregcmd keeps only the join facts and the
# CDJ\AAD values are cut to 256 characters; if it still does not fit, only mode, status and error remain.
function Format-HjLine {
    param([System.Collections.IDictionary]$Record)
    $line = $Record | ConvertTo-Json -Depth 5 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($line) -le 8000) { return $line }
    foreach ($k in 'device', 'after') {
        if ($null -eq $Record[$k]) { continue }
        $core = [ordered]@{}
        foreach ($f in $script:HjCoreFields) { if ($Record[$k].Contains($f)) { $core[$f] = $Record[$k][$f] } }
        $Record[$k] = $core
    }
    foreach ($k in 'aad', 'aadAfter') {
        if ($null -eq $Record[$k]) { continue }
        foreach ($f in 'TenantId', 'TenantName') {
            $v = [string]$Record[$k][$f]
            if ($v.Length -gt 256) { $Record[$k][$f] = $v.Substring(0, 256) }
        }
    }
    $Record['truncated'] = $true
    $line = $Record | ConvertTo-Json -Depth 5 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($line) -le 8000) { return $line }
    return ([ordered]@{ mode = $Record['mode']; status = $Record['status']; error = $Record['error']; truncated = $true } | ConvertTo-Json -Compress)
}

# Fills $Rec; returns the exit code. Each refusal returns before any change.
function Invoke-HjSteps {
    param([System.Collections.IDictionary]$Rec, [string]$Mode, [string]$TenantId, [string]$TenantName)
    $Rec.device = ConvertFrom-HjDsreg @(& $script:HjDsreg)
    $Rec.aad = & $script:HjReadAad
    $Rec.task = & $script:HjGetTask
    $Rec.domain = & $script:HjDomain
    if ($Mode -eq 'Report') { $Rec.status = 'report'; return 0 }
    if ($Rec.device['DomainJoined'] -cne 'YES') { $Rec.status = 'refused'; $Rec.error = 'not domain-joined'; return 1 }
    if ($Mode -eq 'Join' -and $Rec.device['AzureAdJoined'] -ceq 'YES') { $Rec.status = 'already-joined'; return 0 }
    if ($Mode -eq 'Join' -and $null -eq $Rec.task) { throw 'join task missing' }
    if ($TenantId -ne '') {
        if ($Rec.aad.TenantId -eq $TenantId -and $Rec.aad.TenantName -eq $TenantName) {
            $Rec.status = 'scp-unchanged'
        } else {
            $Rec.backup = & $script:HjWriteBackup ($Rec.aad | ConvertTo-Json -Compress)
            & $script:HjWriteAad -TenantId $TenantId -TenantName $TenantName
            $Rec.aadAfter = & $script:HjReadAad
            if ($Rec.aadAfter.TenantId -ne $TenantId -or $Rec.aadAfter.TenantName -ne $TenantName) { throw 'CDJ\AAD read-back differs' }
            $Rec.status = 'scp-written'
        }
    }
    if ($Mode -eq 'Join') {
        & $script:HjStartTask
        $Rec.after = ConvertFrom-HjDsreg @(& $script:HjDsreg)
        $Rec.taskAfter = & $script:HjGetTask
        $Rec.status = if ($Rec.after['AzureAdJoined'] -ceq 'YES') { 'joined' } else { 'pending' }
    }
    return 0
}

function Invoke-HjRun {
    param([string]$Mode, [string]$TenantId = '', [string]$TenantName = '')
    $rec = [ordered]@{ mode = $Mode; status = 'error'; device = $null; aad = $null; task = $null; domain = $null; backup = $null; aadAfter = $null; after = $null; taskAfter = $null; error = $null; version = '1.0' }
    try { $code = [int](Invoke-HjSteps -Rec $rec -Mode $Mode -TenantId $TenantId -TenantName $TenantName) }
    catch {
        $code = 1
        $rec.status = 'error'
        $rec.error = ("$($_.Exception.Message)" -replace '\s+', ' ').Trim()
        if ($rec.error.Length -gt 200) { $rec.error = $rec.error.Substring(0, 200) }
    }
    return [pscustomobject]@{ record = $rec; exitCode = $code }
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') {
    try { $hjMode = Get-HjMode -Action $Action -Mode $Mode -PinVersion $PinVersion -TenantId $TenantId -TenantName $TenantName }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    if ($hjMode -eq 'none') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
    $run = Invoke-HjRun -Mode $hjMode -TenantId $TenantId -TenantName $TenantName
    Write-Output (Format-HjLine $run.record)
    exit $run.exitCode
}
