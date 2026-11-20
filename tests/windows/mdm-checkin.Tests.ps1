$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/mdm-checkin/Invoke-MdmCheckin.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

$Guid = '01234567-89ab-cdef-0123-456789abcdef'
function Reset-Fake {
    param([bool]$WithTask = $true, [bool]$WithIme = $true, [string]$Provider = 'MS DM Server')
    $script:calls = New-Object System.Collections.Generic.List[string]
    $script:fakeTask = $WithTask
    $script:fakeIme = $WithIme
    $script:fakeProvider = $Provider
}
$script:McGetEnrollments = { @([pscustomobject]@{ Id = $Guid; ProviderID = $script:fakeProvider }, [pscustomobject]@{ Id = 'Context'; ProviderID = 'MS DM Server' }) }
$script:McGetTasks = {
    param([string]$EnrollmentId)
    $t = @([pscustomobject]@{ Name = 'PushLaunch'; State = 'Ready'; LastRunTime = $null; LastResult = 0; NextRunTime = $null })
    if ($script:fakeTask) { $t += [pscustomobject]@{ Name = 'Schedule #3 created by enrollment client'; State = 'Ready'; LastRunTime = '2026-01-01T00:00:00Z'; LastResult = 0; NextRunTime = $null } }
    return $t
}
$script:McStartTask = { param([string]$EnrollmentId, [string]$Name) $script:calls.Add("start $EnrollmentId|$Name") }
$script:McGetPolicy = { [ordered]@{ machine = 1 } }
$script:McGetService = { param([string]$Name) if ($Name -eq 'IntuneManagementExtension' -and -not $script:fakeIme) { return $null }; [ordered]@{ status = 'Running'; startType = 'Automatic' } }
$script:McRestartService = { param([string]$Name) $script:calls.Add("restart $Name") }
$script:McImeLogLastWrite = { '2026-01-01T00:00:00Z' }

# Modes.
if ((Get-McMode -Action 'Install' -Mode '') -ne 'Report') { Fail 'default is Report' }
if ((Get-McMode -Action 'Install' -Mode 'CheckIn') -ne 'CheckIn') { Fail 'CheckIn' }
if ((Get-McMode -Action 'Uninstall' -Mode 'CheckIn') -ne 'Report') { Fail 'Uninstall reports only' }
if ((Get-McMode -Action 'Install' -Mode 'CheckIn' -PinVersion '') -ne 'none') { Fail 'empty pin is off' }
$threw = $false; try { Get-McMode -Action 'Install' -Mode 'checkin' } catch { $threw = $true }
if (-not $threw) { Fail 'mode is case-sensitive' }
$threw = $false; try { Get-McMode -Action 'Bogus' -Mode '' } catch { $threw = $true }
if (-not $threw) { Fail 'bad action' }

# Only GUID-shaped MS DM Server enrollments count.
Reset-Fake
$ids = @(Get-McMdmEnrollmentIds -Enrollments @(& $script:McGetEnrollments))
if ($ids.Count -ne 1 -or $ids[0] -ne $Guid) { Fail "enrollment ids: $($ids -join ',')" }

# Report changes nothing.
Reset-Fake
$r = Invoke-McRun -Mode 'Report'
if ($script:calls.Count -ne 0) { Fail 'Report made changes' }
if ($r.exitCode -ne 0 -or $r.record.report.enrollments[0].id -ne $Guid -or $r.record.report.noCloudApplicationNotification.machine -ne 1) { Fail 'Report content' }
$json = $r.record | ConvertTo-Json -Depth 6 -Compress
if (($json -split "`n").Count -ne 1) { Fail 'one line of JSON' }

# CheckIn starts exactly the check-in task and restarts IME.
Reset-Fake
$r = Invoke-McRun -Mode 'CheckIn'
if ($r.exitCode -ne 0) { Fail "CheckIn exit $($r.exitCode): $($r.record.errors -join ';')" }
if (($script:calls -join ';') -ne "start $Guid|Schedule #3 created by enrollment client;restart IntuneManagementExtension") { Fail "CheckIn calls: $($script:calls -join ';')" }

# Missing pieces fail without starting anything else.
Reset-Fake -WithTask $false
$r = Invoke-McRun -Mode 'CheckIn'
if ($r.exitCode -ne 1 -or ($script:calls | Where-Object { $_ -like 'start*' })) { Fail 'no task must not start anything' }
Reset-Fake -Provider 'Other'
$r = Invoke-McRun -Mode 'CheckIn'
if ($r.exitCode -ne 1 -or @($r.record.errors) -notcontains 'no MDM enrollment') { Fail 'no enrollment' }
Reset-Fake -WithIme $false
$r = Invoke-McRun -Mode 'CheckIn'
if ($r.exitCode -ne 1 -or ($script:calls | Where-Object { $_ -like 'restart*' })) { Fail 'missing IME' }

Write-Output 'mdm-checkin tests passed'
