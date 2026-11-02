$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'windows/packages/wu-policy/Invoke-WuPolicy.ps1'

function Fail {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL $Message")
    exit 1
}

function Assert-Same {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { Fail "$Label was [$Actual] expected [$Expected]" }
}

function Assert-Like {
    param([string]$Actual, [string]$Pattern, [string]$Label)
    if ($Actual -notlike $Pattern) { Fail "$Label was [$Actual] expected like [$Pattern]" }
}

$env:RELIAN_DEPLOY_TEST = '1'
Set-StrictMode -Off
. $scriptPath
Set-StrictMode -Version Latest

# A fake registry and Registry.pol. The mocks below read and change only this,
# and log every change in order.
function Reset-Fake {
    param($Au, $Wu, $Pol = [ordered]@{ exists = $false })
    $script:reg = @{ $WupAuKey = $Au; $WupKey = $Wu }
    $script:pol = $Pol
    $script:calls = New-Object System.Collections.Generic.List[string]
    $script:backupFails = $false
    $script:gpRestores = $false
}
function Copy-Map { param($m) if ($null -eq $m) { return $null }; $c = [ordered]@{}; foreach ($k in $m.Keys) { $c[$k] = $m[$k] }; $c }
function Get-WupState {
    [ordered]@{ wu = (Copy-Map $script:reg[$WupKey]); au = (Copy-Map $script:reg[$WupAuKey]); registryPol = (Copy-Map $script:pol); appraiserTask = 'Ready' }
}
function Backup-WupPolicy { param($Dir) if ($script:backupFails) { throw 'disk full' }; $script:calls.Add("backup $Dir") }
function Remove-WupValue { param($Key, $Name) $script:calls.Add("remove $Name"); $script:reg[$Key].Remove($Name) }
function Rename-WupPol { param($Stamp) $script:calls.Add('rename'); $script:pol = [ordered]@{ exists = $false }; "Registry.pol.bak-$Stamp" }
# gpupdate puts a value back when a Registry.pol that names it is still in place.
function Invoke-WupGpUpdate {
    $script:calls.Add('gpupdate')
    if ($script:gpRestores -and $script:pol.exists) { $script:reg[$WupAuKey]['NoAutoUpdate'] = 1 }
    0
}

# Guard: automatic updates on, or AUOptions 3 or above, means nothing to do, even with Fix.
Reset-Fake -Au ([ordered]@{ AUOptions = 4; NoAutoUpdate = 0 }) -Wu ([ordered]@{ TargetReleaseVersion = 1; TargetReleaseVersionInfo = '23H2' })
$run = Invoke-WupRun -Fix
Assert-Same $run.exitCode 0 'nothing to do exit'
Assert-Like $run.record.verdict 'nothing to do*still set: TargetReleaseVersion, TargetReleaseVersionInfo' 'nothing to do verdict'
Assert-Same $script:calls.Count 0 'nothing to do changes nothing'
Reset-Fake -Au $null -Wu $null
Assert-Same (Invoke-WupRun -Fix).record.verdict 'nothing to do: automatic updates not off by policy' 'no policy keys'
Assert-Same $script:calls.Count 0 'no policy keys changes nothing'

# Each guard value alone is enough; AUOptions 2 counts, a non-number does not.
Assert-Same ((Get-WupBlockers ([ordered]@{ au = [ordered]@{ AUOptions = 2 }; wu = $null })) -join ',') 'AUOptions' 'AUOptions 2'
Assert-Same ((Get-WupBlockers ([ordered]@{ au = [ordered]@{ AUOptions = 'x' }; wu = $null })) -join ',') '' 'AUOptions not a number'
Assert-Same ((Get-WupBlockers ([ordered]@{ au = $null; wu = [ordered]@{ DisableWindowsUpdateAccess = 1 } })) -join ',') 'DisableWindowsUpdateAccess' 'DisableWindowsUpdateAccess'

# WSUS: blocked values on a WSUS-managed device are reported, not changed.
Reset-Fake -Au ([ordered]@{ NoAutoUpdate = 1; AUOptions = 1; UseWUServer = 1 }) -Wu ([ordered]@{ WUServer = 'http://wsus:8530' })
$run = Invoke-WupRun -Fix
Assert-Same $run.exitCode 0 'WSUS exit'
Assert-Like $run.record.verdict 'WSUS-managed (http://wsus:8530), not changed: NoAutoUpdate, AUOptions*' 'WSUS verdict'
Assert-Same $script:calls.Count 0 'WSUS changes nothing'
Reset-Fake -Au ([ordered]@{ NoAutoUpdate = 1; UseWUServer = 1 }) -Wu $null
Assert-Like (Invoke-WupRun -Fix).record.verdict 'WSUS-managed (UseWUServer)*' 'UseWUServer alone is WSUS'
Assert-Same $script:calls.Count 0 'UseWUServer changes nothing'

# Check mode: blocked, but nothing is written.
$blockedAu = [ordered]@{ NoAutoUpdate = 1; AUOptions = 1; ScheduledInstallDay = 0 }
$blockedWu = [ordered]@{ DisableWindowsUpdateAccess = 1; SetDisableUXWUAccess = 1; DisableOSUpgrade = 1; DeferFeatureUpdatesPeriodInDays = 30; PauseFeatureUpdatesStartTime = '2025-01-01' }
Reset-Fake -Au (Copy-Map $blockedAu) -Wu (Copy-Map $blockedWu) -Pol ([ordered]@{ exists = $true; size = 158; wuValues = @() })
$run = Invoke-WupRun
Assert-Same $run.exitCode 0 'check exit'
Assert-Same $run.record.mode 'check' 'check mode'
Assert-Like $run.record.verdict 'automatic updates off by policy: NoAutoUpdate, AUOptions, DisableWindowsUpdateAccess*' 'check verdict'
Assert-Same $script:calls.Count 0 'check mode writes nothing'
Assert-Same $script:reg[$WupAuKey].Count 3 'check mode keeps AU values'
if (-not $run.record.Contains('registryPol') -or -not $run.record.Contains('appraiserTask')) { Fail 'check lacks Registry.pol or appraiser task' }

# Fix: backup first, then only the named values, then Registry.pol, then gpupdate.
$run = Invoke-WupRun -Fix
Assert-Same $run.exitCode 0 'fix exit'
Assert-Like $script:calls[0] "backup $WupBackupRoot*wu-policy-backup-*" 'backup is first'
Assert-Same (($script:calls | Select-Object -Skip 1) -join ',') 'remove NoAutoUpdate,remove AUOptions,remove DisableWindowsUpdateAccess,remove SetDisableUXWUAccess,rename,gpupdate' 'fix order'
Assert-Same (($script:reg[$WupAuKey].Keys) -join ',') 'ScheduledInstallDay' 'other AU values kept'
Assert-Same (($script:reg[$WupKey].Keys) -join ',') 'DisableOSUpgrade,DeferFeatureUpdatesPeriodInDays,PauseFeatureUpdatesStartTime' 'other WU values kept'
Assert-Like $run.record.verdict 'fixed: removed NoAutoUpdate, AUOptions, DisableWindowsUpdateAccess, SetDisableUXWUAccess; Registry.pol renamed to Registry.pol.bak-*; still set: DeferFeatureUpdatesPeriodInDays, PauseFeatureUpdatesStartTime, DisableOSUpgrade' 'fix verdict'

# Second run: nothing to do, nothing changed.
$script:calls.Clear()
$run = Invoke-WupRun -Fix
Assert-Same $run.exitCode 0 'second run exit'
Assert-Like $run.record.verdict 'nothing to do*' 'second run verdict'
Assert-Same $script:calls.Count 0 'second run is a no-op'

# A failed backup stops the fix before any delete.
Reset-Fake -Au (Copy-Map $blockedAu) -Wu $null
$script:backupFails = $true
$run = Invoke-WupRun -Fix
Assert-Same $run.exitCode 1 'failed backup exit'
Assert-Same $script:calls.Count 0 'failed backup deletes nothing'
Assert-Same $script:reg[$WupAuKey].NoAutoUpdate 1 'failed backup keeps NoAutoUpdate'

# SetDisableUXWUAccess 0 and NoAutoUpdate 0 stay; AUOptions 3+ stays.
Reset-Fake -Au ([ordered]@{ NoAutoUpdate = 0; AUOptions = 4 }) -Wu ([ordered]@{ DisableWindowsUpdateAccess = 1; SetDisableUXWUAccess = 0 })
$null = Invoke-WupRun -Fix
Assert-Same (($script:calls | Where-Object { $_ -like 'remove *' }) -join ',') 'remove DisableWindowsUpdateAccess' 'only the blocking value'

# A large Registry.pol without these values is left; one that names them is renamed.
$big = [ordered]@{ exists = $true; size = 4096; wuValues = @() }
Assert-Same (Get-WupPlan ([ordered]@{ au = [ordered]@{ NoAutoUpdate = 1 }; wu = $null; registryPol = $big })).renamePol $false 'large unrelated pol left'
$big.wuValues = @('NoAutoUpdate')
Assert-Same (Get-WupPlan ([ordered]@{ au = [ordered]@{ NoAutoUpdate = 1 }; wu = $null; registryPol = $big })).renamePol $true 'pol naming the value renamed'
Reset-Fake -Au ([ordered]@{ NoAutoUpdate = 1 }) -Wu $null -Pol ([ordered]@{ exists = $true; size = 4096; wuValues = @() })
$run = Invoke-WupRun -Fix
Assert-Same ($script:calls -contains 'rename') $false 'large pol not renamed'
Assert-Like $run.record.verdict '*Registry.pol left (4096 bytes, no WU values)' 'large pol said'

# Verify after gpupdate: a value the policy puts back fails the run.
Reset-Fake -Au ([ordered]@{ NoAutoUpdate = 1 }) -Wu $null -Pol ([ordered]@{ exists = $true; size = 4096; wuValues = @() })
$script:gpRestores = $true
$run = Invoke-WupRun -Fix
Assert-Same $run.exitCode 1 'value back after gpupdate exit'
Assert-Like $run.record.verdict 'fix incomplete: still set NoAutoUpdate*' 'value back after gpupdate verdict'

# Registry.pol scan: PReg entries are UTF-16LE.
$bytes = [Text.Encoding]::Unicode.GetBytes('PReg[Software\Policies\Microsoft\Windows\WindowsUpdate\AU;NoAutoUpdate;]')
Assert-Same ((Get-WupPolNames $bytes) -join ',') 'NoAutoUpdate' 'pol names'
Assert-Same @(Get-WupPolNames ([Text.Encoding]::Unicode.GetBytes('PReg[Software\Policies\Microsoft\Edge;HomepageLocation;]'))).Count 0 'pol without WU names'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wup-" + [guid]::NewGuid() + '.pol')
[IO.File]::WriteAllBytes($tmp, $bytes)
$info = Get-WupPolInfo $tmp
Remove-Item -LiteralPath $tmp
Assert-Same $info.size ([long]$bytes.Length) 'pol size'
Assert-Same ($info.wuValues -join ',') 'NoAutoUpdate' 'pol info names'
Assert-Same (Get-WupPolInfo $tmp).exists $false 'missing pol'

# Runner Action and Fix mapping.
foreach ($a in @('Install', 'Update', 'Repair', 'Reinstall')) {
    Assert-Same (Get-WupMode $a '') 'check' "$a is a read-only check"
    Assert-Same (Get-WupMode $a 'false') 'check' "$a with Fix false"
    Assert-Same (Get-WupMode $a 'true') 'fix' "$a with Fix true"
}
Assert-Same (Get-WupMode 'Uninstall' 'true') 'none' 'Uninstall ignores Fix'
foreach ($bad in @(@('Bogus', ''), @('', ''), @('Install', 'yes'), @('Install', '1'))) {
    $threw = $false
    try { $null = Get-WupMode $bad[0] $bad[1] } catch { $threw = $true }
    if (-not $threw) { Fail "Get-WupMode accepted [$($bad[0])] [$($bad[1])]" }
}

# The fix deletes only named values: no other registry write, no reboot, no upgrade, no service.
$source = [IO.File]::ReadAllText($scriptPath)
foreach ($bad in @('Set-ItemProperty', 'New-ItemProperty', 'Remove-Item ', 'reg add', 'reg delete', 'setup.exe', 'Restart-Computer', 'shutdown', 'Set-Service', 'Stop-Service', 'Start-Service', 'Start-ScheduledTask', 'Enable-ScheduledTask')) {
    if ($source.IndexOf($bad, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Fail "source contains $bad" }
}
foreach ($need in @('[string]$DeploymentType', '[string]$Action', '[string]$PinVersion', "[string]`$Fix = ''")) {
    if ($source.IndexOf($need, [StringComparison]::Ordinal) -lt 0) { Fail "param block lacks $need" }
}

# Pin record and script agree on the field; the package arguments example decodes to what the script reads.
$release = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'windows/releases/wu-policy.json') | ConvertFrom-Json
Assert-Same $release.installsSoftware $false 'pin record installsSoftware'
Assert-Same $WupFieldName $release.ninjaField 'script field name and pin record'
Assert-Same $WupFieldName 'relianWuPolicy' 'field name'
if ($release.packageArguments.IndexOf('eyJGaXgiOiJ0cnVlIn0=', [StringComparison]::Ordinal) -lt 0) { Fail 'pin record lacks the base64 example' }

# End to end through the runner's argument parser: Fix reaches the package as a named pair.
Set-StrictMode -Off
. (Join-Path $repoRoot 'windows/runner/Invoke-RelianRunner.ps1')
Set-StrictMode -Version Latest
$pairs = @(ConvertFrom-RelianPackageArguments -PackageArguments 'eyJGaXgiOiJ0cnVlIn0=')
Assert-Same $pairs.Count 1 'runner pair count'
Assert-Same $pairs[0].Name 'Fix' 'runner pair name'
Assert-Same $pairs[0].Value 'true' 'runner pair value'

# An early exit 0 would skip every assertion after it: the first exit 0 must be the last line.
$self = [IO.File]::ReadAllText($PSCommandPath)
if ($self.IndexOf("exit 0`n", [StringComparison]::Ordinal) -lt $self.IndexOf('Assert-Same $pairs[0].Value', [StringComparison]::Ordinal)) { Fail 'exit 0 comes before the last assertion' }

Write-Output 'wu-policy tests passed'
exit 0
