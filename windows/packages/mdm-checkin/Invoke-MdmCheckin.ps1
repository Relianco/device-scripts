<#
.SYNOPSIS
    Reports, or nudges, a Windows device's Intune (MDM) check-in, for the Relian deploy runner (NinjaOne script 374).

.DESCRIPTION
    A device whose push channel is down (for example a leftover NoCloudApplicationNotification=1 policy) only checks in
    on its own schedule, every 8 hours. This package shows why and can start a check-in on the device itself.

    Mode (a PackageArguments string; default Report):
      Report   read-only. For each MDM enrollment (HKLM\SOFTWARE\Microsoft\Enrollments\<GUID> with ProviderID
               "MS DM Server"): the GUID and the last and next run times of its EnterpriseMgmt tasks. Also the
               NoCloudApplicationNotification policy values (machine and loaded user hives), the dmwappushservice and
               IntuneManagementExtension services, and the IME log's last write time.
      CheckIn  starts the enrollment's "Schedule #3 created by enrollment client" task (the check-in that Company
               Portal "Sync" starts) and restarts the IntuneManagementExtension service (Win32 apps, Remediations),
               then reports as above. Nothing else is changed.

    The runner passes DeploymentType, Action and PinVersion, then each PackageArguments pair as -Name value. An empty
    PinVersion is the off switch. Uninstall reports only. The result is one line of compact JSON, printed last on
    stdout. Exit 1 when CheckIn finds no MDM enrollment or a step fails.

.NOTES
    Requirements: Windows PowerShell 5.1+, run as SYSTEM. No external module dependencies.
#>

# Not Mandatory: a mandatory param block prompts when this file is dot-sourced under RELIAN_DEPLOY_TEST.
[CmdletBinding()]
param(
    [string]$DeploymentType,
    [string]$Action,
    [string]$PinVersion,
    [string]$Mode = ''
)

$ProgressPreference = 'SilentlyContinue'
$script:McCheckinTask = 'Schedule #3 created by enrollment client'
$script:McGuidPattern = '\A\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?\z'

# Seams. Tests replace them.
$script:McGetEnrollments = {
    $root = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            $provider = if ($null -ne $p -and @($p.PSObject.Properties.Name) -contains 'ProviderID') { [string]$p.ProviderID } else { '' }
            [pscustomobject]@{ Id = $_.PSChildName; ProviderID = $provider }
        })
}
$script:McGetTasks = {
    param([string]$EnrollmentId)
    return @(Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\$EnrollmentId\" -ErrorAction SilentlyContinue | ForEach-Object {
            $i = $_ | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Name        = $_.TaskName
                State       = [string]$_.State
                LastRunTime = if ($i) { ([datetime]$i.LastRunTime).ToUniversalTime().ToString('o') } else { $null }
                LastResult  = if ($i) { [int64]$i.LastTaskResult } else { $null }
                NextRunTime = if ($i -and $i.NextRunTime) { ([datetime]$i.NextRunTime).ToUniversalTime().ToString('o') } else { $null }
            }
        })
}
$script:McStartTask = {
    param([string]$EnrollmentId, [string]$Name)
    Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\$EnrollmentId\" -TaskName $Name -ErrorAction Stop
}
$script:McGetPolicy = {
    $out = [ordered]@{}
    $machine = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'
    $v = Get-ItemProperty -LiteralPath $machine -Name 'NoCloudApplicationNotification' -ErrorAction SilentlyContinue
    $out['machine'] = if ($null -ne $v) { [int]$v.NoCloudApplicationNotification } else { $null }
    foreach ($hive in @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        if ($hive.PSChildName -notmatch '^S-1-(5-21|12-1)-[0-9-]+$') { continue }
        $k = "Registry::HKEY_USERS\$($hive.PSChildName)\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications"
        $u = Get-ItemProperty -LiteralPath $k -Name 'NoCloudApplicationNotification' -ErrorAction SilentlyContinue
        if ($null -ne $u) { $out[$hive.PSChildName] = [int]$u.NoCloudApplicationNotification }
    }
    return $out
}
$script:McGetService = {
    param([string]$Name)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $s) { return $null }
    return [ordered]@{ status = [string]$s.Status; startType = [string]$s.StartType }
}
$script:McRestartService = {
    param([string]$Name)
    Restart-Service -Name $Name -Force -ErrorAction Stop
}
$script:McImeLogLastWrite = {
    $f = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log'
    if (-not [IO.File]::Exists($f)) { return $null }
    return [IO.File]::GetLastWriteTimeUtc($f).ToString('o')
}

# Pure: Report | CheckIn | none. Throws on bad input.
function Get-McMode {
    param([string]$Action, [string]$Mode, [string]$PinVersion = '1.0.0')
    if ([string]::IsNullOrWhiteSpace($PinVersion)) { return 'none' }
    if (@('Install', 'Update', 'Repair', 'Reinstall', 'Uninstall') -cnotcontains $Action) {
        throw 'Action must be Install, Update, Repair, Reinstall, or Uninstall.'
    }
    if ($Action -eq 'Uninstall' -or $Mode -eq '') { return 'Report' }
    if (@('Report', 'CheckIn') -ccontains $Mode) { return $Mode }
    throw 'Mode must be Report or CheckIn.'
}

# Pure: the MDM enrollment ids (ProviderID "MS DM Server", GUID-shaped key names only).
function Get-McMdmEnrollmentIds {
    param([object[]]$Enrollments = @())
    return @($Enrollments | Where-Object { $_.ProviderID -ceq 'MS DM Server' -and $_.Id -match $script:McGuidPattern } | ForEach-Object { $_.Id })
}

function Get-McReport {
    $ids = @(Get-McMdmEnrollmentIds -Enrollments @(& $script:McGetEnrollments))
    return [ordered]@{
        enrollments                    = @($ids | ForEach-Object { [ordered]@{ id = $_; tasks = @(& $script:McGetTasks -EnrollmentId $_) } })
        noCloudApplicationNotification = & $script:McGetPolicy
        dmwappushservice               = & $script:McGetService -Name 'dmwappushservice'
        intuneManagementExtension      = & $script:McGetService -Name 'IntuneManagementExtension'
        imeLogLastWrite                = & $script:McImeLogLastWrite
    }
}

function Invoke-McRun {
    param([string]$Mode)
    $record = [ordered]@{ mode = $Mode; timestamp = [datetime]::UtcNow.ToString('o'); started = @(); errors = @() }
    $code = 0
    if ($Mode -eq 'CheckIn') {
        $ids = @(Get-McMdmEnrollmentIds -Enrollments @(& $script:McGetEnrollments))
        if ($ids.Count -eq 0) { $record.errors += 'no MDM enrollment'; $code = 1 }
        foreach ($id in $ids) {
            $names = @(& $script:McGetTasks -EnrollmentId $id | ForEach-Object { $_.Name })
            if ($names -cnotcontains $script:McCheckinTask) { $record.errors += "no check-in task for $id"; $code = 1; continue }
            try { & $script:McStartTask -EnrollmentId $id -Name $script:McCheckinTask; $record.started += "$id\$($script:McCheckinTask)" }
            catch { $record.errors += "start failed for $id"; $code = 1 }
        }
        if ($null -ne (& $script:McGetService -Name 'IntuneManagementExtension')) {
            try { & $script:McRestartService -Name 'IntuneManagementExtension'; $record.started += 'IntuneManagementExtension restart' }
            catch { $record.errors += 'IME restart failed'; $code = 1 }
        } else {
            $record.errors += 'IntuneManagementExtension service missing'; $code = 1
        }
    }
    $record.report = Get-McReport
    return [pscustomobject]@{ record = $record; exitCode = $code }
}

if ($env:RELIAN_DEPLOY_TEST -ne '1') {
    try { $mcMode = Get-McMode -Action $Action -Mode $Mode -PinVersion $PinVersion }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    if ($mcMode -eq 'none') { Write-Output 'Nothing to change. Nothing was installed.'; exit 0 }
    $run = Invoke-McRun -Mode $mcMode
    Write-Output ($run.record | ConvertTo-Json -Depth 6 -Compress)
    exit $run.exitCode
}
